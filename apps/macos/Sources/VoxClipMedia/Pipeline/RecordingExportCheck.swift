@preconcurrency import AVFoundation
import CoreImage
import Foundation
import VoxClipCore

enum RecordingExportCheck {
    static func measure(export: URL, render: RenderRequest, edit: ExportCheckExpectation.Edit,
                        isolation: isolated (any Actor)? = #isolation) async throws -> [ExportCheckInput.RecordingMeasurement] {
        guard !edit.recordingBoundaries.isEmpty else { return [] }
        let decoded = generator(export)
        let sources = Dictionary(uniqueKeysWithValues: render.recordings.map { ($0.key, generator($0.url)) })
        let spans = try CompositionVideoSpan.build(render)
        let context = CIContext()
        let timing = render.speedTiming, timeline = render.timeline
        let covered = render.footage.compactMap { input -> Range<Double>? in
            let start = timing.rendered(timeline.mapTime(input.entry.start))
            let end = timing.rendered(timeline.mapEndTime(input.entry.end))
            return start < end ? start..<end : nil
        }
        var result: [ExportCheckInput.RecordingMeasurement] = []
        for boundary in edit.recordingBoundaries {
            try Task.checkCancellation()
            let sample = visibleSample(boundary.right, fps: render.output.fps, covered: covered)
            var wrong: String?
            if let time = sample, let span = spans.first(where: {
                let edited = timing.edited(time)
                return $0.recordingKey == boundary.toKey && $0.output.start.seconds <= edited && edited < $0.output.end.seconds
            }), let observed = try await frame(decoded, at: time),
               let actual = fingerprint(CIImage(cgImage: observed), context: context) {
                let edited = timing.edited(time)
                let progress = (edited - span.output.start.seconds) / span.output.duration.seconds
                let local = span.localSource.start.seconds + progress * span.localSource.duration.seconds
                var distances: [String: Double] = [:]
                for recording in render.recordings {
                    let duration = Double(recording.region.durationSamples) / render.timeline.sampleRate
                    guard let source = sources[recording.key],
                          let image = try await frame(source, at: min(local, max(0, duration - 1.0 / 30))) else { continue }
                    let picture = ClipPicture.orient(CIImage(cgImage: image), controls: render.clipControls)
                    let size = CGSize(width: render.output.size.width, height: render.output.size.height)
                    let crop = FrameCompositor.aspectCrop(source: picture.extent, output: size, controls: render.clipControls, part: span.partReframe)
                    let fitted = CompositionFrameGeometry.fill(picture, crop: crop, output: size)
                    if let fingerprint = fingerprint(fitted, context: context) {
                        distances[recording.key] = zip(actual, fingerprint).reduce(0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / 256
                    }
                }
                if let expected = distances[boundary.toKey],
                   let best = distances.filter({ $0.key != boundary.toKey }).min(by: { ($0.value, $0.key) < ($1.value, $1.key) }),
                   best.value + 1 < expected {
                    wrong = render.recordings.first { $0.key == best.key }?.region.label
                }
            }
            func speech(in window: Range<Double>) -> [Range<Double>] {
                edit.words.compactMap { word in
                    let start = max(word.start, window.lowerBound), end = min(word.end, window.upperBound)
                    return start < end ? start..<end : nil
                }
            }
            let left = try await RecordingLoudness.measure(export, ranges: speech(in: boundary.left))
            let right = try await RecordingLoudness.measure(export, ranges: speech(in: boundary.right))
            result.append(.init(seam: boundary.seam, wrongPictureLabel: wrong, levelDelta: left.flatMap { lhs in right.map { $0 - lhs } }))
        }
        return result
    }

    private static func visibleSample(_ window: Range<Double>, fps: Double, covered: [Range<Double>]) -> Double? {
        guard fps.isFinite, fps > 0, fps <= 60, !window.isEmpty else { return nil }
        let first = Int(ceil(window.lowerBound * fps - 1e-6))
        let end = Int(ceil(window.upperBound * fps - 1e-6))
        let preferred = window.lowerBound + min(0.2, (window.upperBound - window.lowerBound) / 2)
        return (first..<end).lazy.map { Double($0) / fps }.filter { time in
            !covered.contains { $0.contains(time) }
        }.min { abs($0 - preferred) < abs($1 - preferred) }
    }

    private static func generator(_ url: URL) -> AVAssetImageGenerator {
        let result = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        result.appliesPreferredTrackTransform = true
        result.requestedTimeToleranceBefore = .zero
        result.requestedTimeToleranceAfter = .zero
        return result
    }

    private static func frame(_ generator: AVAssetImageGenerator, at time: Double,
                              isolation: isolated (any Actor)? = #isolation) async throws -> CGImage? {
        do { return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)).image }
        catch { try Task.checkCancellation(); return nil }
    }

    private static func fingerprint(_ image: CIImage, context: CIContext) -> [UInt8]? {
        guard let raster = context.createCGImage(image, from: image.extent),
              let grey = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = grey.data else { return nil }
        grey.interpolationQuality = .high
        grey.draw(raster, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        return Array(UnsafeBufferPointer(start: pixels.assumingMemoryBound(to: UInt8.self), count: 256))
    }
}
