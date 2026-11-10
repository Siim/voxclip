@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision
import VoxClipCore

/// On-device Vision for Ask Claude (ai.md §18.1 and §18.5): what is on screen in a selection (faces and text boxes, the
/// text-only fallback when a connector cannot take images), and the track a blur or pixelate follows. Every rect is in
/// picture space: normalized to the frame as it plays, top-left origin. Nothing leaves the Mac.
public enum ClipEffectVision {
    /// Frames sampled for detections over a selection.
    public static let detectionFrames = 4

    /// Faces and text boxes seen in source seconds `start..<end`, labelled D1, D2… in the order they appear. A face seen
    /// in several frames is one detection over the frames it was seen in; text with the same words likewise.
    public static func detect(source: URL, start: Double, end: Double, frames: Int = detectionFrames,
                              isolation: isolated (any Actor)? = #isolation) async throws -> [AskClaudeDetection] {
        guard end > start, frames > 0 else { return [] }
        let step = (end - start) / Double(frames)
        let times = (0..<frames).map { start + step * (Double($0) + 0.5) }
        var faces: [(rect: ClipEffect.Rect, first: Double, last: Double)] = []
        var texts: [String: (rect: ClipEffect.Rect, first: Double, last: Double)] = [:]
        var order: [String] = []
        for (time, image) in try await images(source: source, times: times) {
            try Task.checkCancellation()
            let found = try await VisionQueue.run(image) { try observe($0, text: true) }
            for face in found.faces {
                if let index = faces.indices.max(by: { iou(faces[$0].rect, face) < iou(faces[$1].rect, face) }), iou(faces[index].rect, face) > 0.25 {
                    faces[index].last = time
                } else { faces.append((face, time, time)) }
            }
            for (text, rect) in found.texts {
                if texts[text] == nil { order.append(text); texts[text] = (rect, time, time) } else { texts[text]?.last = time }
            }
        }
        let half = step / 2
        var detections = faces.map { AskClaudeDetection(label: "", kind: .face, start: max(start, $0.first - half), end: min(end, $0.last + half), rect: $0.rect) }
        detections += order.compactMap { text in
            texts[text].map { AskClaudeDetection(label: "", kind: .text, start: max(start, $0.first - half), end: min(end, $0.last + half), rect: $0.rect, text: text) }
        }
        detections.sort { ($0.start, $0.rect.x) < ($1.start, $1.rect.x) }
        return detections.enumerated().map { index, detection in var labelled = detection; labelled.label = "D\(index + 1)"; return labelled }
    }

    /// The smoothed track for a blur or pixelate that follows a face or the most salient region, sampled every
    /// `ClipEffect.trackInterval`. Each sample picks the detection nearest the previous rect; a frame where nothing is found
    /// holds the previous rect. A face rect grows by a quarter so the blur covers hair and chin. Empty for `none`.
    public static func track(source: URL, effect: ClipEffect, isolation: isolated (any Actor)? = #isolation) async throws -> [ClipEffect.TrackSample] {
        guard let mode = effect.tracking, mode != .none, var previous = effect.rect else { return [] }
        let times = ClipEffects.trackTimes(start: effect.start, end: effect.end)
        var raw: [ClipEffect.TrackSample] = []
        for (time, image) in try await images(source: source, times: times) {
            try Task.checkCancellation()
            let candidates: [ClipEffect.Rect]
            if mode == .face { candidates = try await VisionQueue.run(image) { try observe($0, text: false) }.faces.map { grown($0, by: 0.25) } }
            else { candidates = try await VisionQueue.run(image) { try salient($0) } }
            if let best = candidates.min(by: { distance($0, previous) < distance($1, previous) }) { previous = best.clamped }
            raw.append(.init(t: time, rect: previous))
        }
        return ClipEffects.smoothed(raw)
    }

    // MARK: Frames and requests

    static func images(source: URL, times: [Double], isolation: isolated (any Actor)? = #isolation) async throws -> [(Double, CGImage)] {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let tolerance = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var result: [(Double, CGImage)] = []
        for time in times {
            try Task.checkCancellation()
            let image = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
            result.append((time, image))
        }
        return result
    }

    /// Synchronous Vision: call it only through `VisionQueue.run`.
    static func observe(_ image: CGImage, text: Bool) throws -> (faces: [ClipEffect.Rect], texts: [(String, ClipEffect.Rect)]) {
        VisionQueue.assertOnQueue()
        let faces = VNDetectFaceRectanglesRequest()
        let words = VNRecognizeTextRequest()
        words.recognitionLevel = .accurate
        words.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform(text ? [faces, words] : [faces])
        let found = (faces.results ?? []).map { rect($0.boundingBox) }
        let lines: [(String, ClipEffect.Rect)] = text ? (words.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            let string = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : (string, rect(observation.boundingBox))
        } : []
        return (found, lines)
    }

    /// Synchronous Vision: call it only through `VisionQueue.run`.
    static func salient(_ image: CGImage) throws -> [ClipEffect.Rect] {
        VisionQueue.assertOnQueue()
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results?.first?.salientObjects ?? []).map { rect($0.boundingBox) }
    }

    /// Vision's bottom-left normalized box as a picture-space rect.
    static func rect(_ box: CGRect) -> ClipEffect.Rect {
        ClipEffect.Rect(x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width), height: Double(box.height)).clamped
    }

    static func grown(_ rect: ClipEffect.Rect, by fraction: Double) -> ClipEffect.Rect {
        let width = rect.width * (1 + fraction), height = rect.height * (1 + fraction)
        return ClipEffect.Rect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height).clamped
    }

    static func distance(_ a: ClipEffect.Rect, _ b: ClipEffect.Rect) -> Double { hypot(a.midX - b.midX, a.midY - b.midY) }

    static func iou(_ a: ClipEffect.Rect, _ b: ClipEffect.Rect) -> Double {
        let left = max(a.x, b.x), right = min(a.x + a.width, b.x + b.width)
        let top = max(a.y, b.y), bottom = min(a.y + a.height, b.y + b.height)
        guard right > left, bottom > top else { return 0 }
        let overlap = (right - left) * (bottom - top)
        return overlap / (a.width * a.height + b.width * b.height - overlap)
    }
}
