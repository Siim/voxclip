import Foundation

/// Where the clip opens: the first frame the viewer sees (ADR-R48, design.md "Opens on a clear look at you").
public struct OpeningFrameChoice: Codable, Sendable, Equatable {
    /// Seconds to move the clip's start: 0 or negative, into the silence before its first word.
    public var shift: Double
    /// The source second of the chosen frame, `clip.start + shift`.
    public var time: Double
    public init(shift: Double, time: Double) { self.shift = shift; self.time = time }
}

public enum OpeningFrame {
    /// Frames this close to the clip's start count as its current opening frame.
    public static let startTolerance = 0.05

    /// The opening for `clip` from the opening scan. The clip already opens on a clear look: no shift. Otherwise the
    /// earliest clear look in the silence before its first word, no earlier than `FrameSampling.openingSpan` before it
    /// and never inside the transcript item before it (`FrameClip.leadInFloor`): the start moves only through silence,
    /// so no word is clipped and none is added. Nil when no frame there is a clear look; the start then stays.
    public static func choose(_ clip: FrameClip, scan: [FrameObservation]) -> OpeningFrameChoice? {
        let start: Double = clip.start
        let earliest: Double = start - FrameSampling.openingSpan - 1e-9
        let floor: Double = max(clip.leadInFloor, max(0, earliest))
        let ordered = scan.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        if let current = ordered.min(by: { abs($0.time - start) < abs($1.time - start) }),
           abs(current.time - start) <= startTolerance, current.isClearLook {
            return OpeningFrameChoice(shift: 0, time: start)
        }
        guard let chosen = ordered.first(where: { $0.time >= floor - 1e-9 && $0.time <= start + 1e-9 && $0.isClearLook }) else { return nil }
        let time = min(start, max(floor, chosen.time))
        return OpeningFrameChoice(shift: time - start, time: time)
    }
}

/// The 9:16 or 1:1 crop that follows the face (design.md "9:16 follows your face").
public struct FaceFollowPlan: Codable, Sendable, Equatable {
    /// The crop window's size as a share of the source picture's width and height.
    public var cropWidth: Double
    public var cropHeight: Double
    /// One centre for the whole clip: the median face centre, clamped so the crop stays inside the picture. It is what
    /// a renderer with one `faceX`/`faceY` uses.
    public var centerX: Double
    public var centerY: Double
    /// The smoothed centre at each sample time, for a renderer that moves the crop.
    public var path: [FaceFollowPoint]
    /// True when the path never moves.
    public var isStatic: Bool { path.allSatisfy { abs($0.x - (path.first?.x ?? 0)) < 1e-9 && abs($0.y - (path.first?.y ?? 0)) < 1e-9 } }
}

public struct FaceFollowPoint: Codable, Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}

public enum FaceFollowCrop {
    /// The centre holds while the face stays within this share of the crop's size of it (a dead zone).
    public static let deadZone = 0.15
    /// The centre moves at most this share of the crop's size per second, so a move is a slow pan, never a jump.
    public static let maximumSpeed = 0.5
    /// Samples a median runs over, so one wrong detection never moves the crop.
    public static let medianWindow = 5

    /// The crop for a picture of `sourceAspect` (display width over height) cut to `targetAspect` (9/16 or 1). Samples
    /// without a face hold the previous centre (the next face's before the first one); without any face the crop is
    /// centred. Nil for a non-positive aspect.
    public static func plan(_ samples: [(time: Double, face: ClipEffect.Rect?)], sourceAspect: Double, targetAspect: Double) -> FaceFollowPlan? {
        guard sourceAspect.isFinite, targetAspect.isFinite, sourceAspect > 0, targetAspect > 0 else { return nil }
        let cropWidth = min(1, targetAspect / sourceAspect)
        let cropHeight = min(1, sourceAspect / targetAspect)
        let ordered = samples.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        let faces = ordered.compactMap(\.face)
        guard !faces.isEmpty else {
            let path = ordered.map { FaceFollowPoint(t: $0.time, x: 0.5, y: 0.5) }
            return FaceFollowPlan(cropWidth: cropWidth, cropHeight: cropHeight, centerX: 0.5, centerY: 0.5, path: path)
        }
        var heldX = faces[0].midX, heldY = faces[0].midY
        var xs: [Double] = [], ys: [Double] = []
        for sample in ordered {
            if let face = sample.face { heldX = face.midX; heldY = face.midY }
            xs.append(heldX)
            ys.append(heldY)
        }
        let medianX = median(xs), medianY = median(ys)
        let centerX = clamp(medianX, size: cropWidth), centerY = clamp(medianY, size: cropHeight)
        let targetX = runningMedian(xs), targetY = runningMedian(ys)
        let times = ordered.map(\.time)
        // The moving crop starts on the first smoothed face, not on the clip's median.
        let pathX = follow(targetX, times: times, size: cropWidth, start: clamp(targetX[0], size: cropWidth))
        let pathY = follow(targetY, times: times, size: cropHeight, start: clamp(targetY[0], size: cropHeight))
        let path = times.indices.map { FaceFollowPoint(t: times[$0], x: pathX[$0], y: pathY[$0]) }
        return FaceFollowPlan(cropWidth: cropWidth, cropHeight: cropHeight, centerX: centerX, centerY: centerY, path: path)
    }

    /// The centre the crop shows over time: it holds while the target stays in the dead zone, then moves towards it no
    /// faster than `maximumSpeed`, and stays inside the picture.
    static func follow(_ targets: [Double], times: [Double], size: Double, start: Double) -> [Double] {
        guard size < 1 - 1e-9 else { return targets.map { _ in 0.5 } }
        var current = start
        var previousTime = times.first ?? 0
        var path: [Double] = []
        let zone = deadZone * size
        for (index, target) in targets.enumerated() {
            let elapsed = max(0, times[index] - previousTime)
            previousTime = times[index]
            let offset = target - current
            if abs(offset) > zone {
                let wanted = offset - (offset > 0 ? zone : -zone)
                let limit = maximumSpeed * size * elapsed
                current += max(-limit, min(limit, wanted))
            }
            current = clamp(current, size: size)
            path.append(current)
        }
        return path
    }

    static func runningMedian(_ values: [Double]) -> [Double] {
        let half = medianWindow / 2
        return values.indices.map { index in
            let low = max(0, index - half), high = min(values.count - 1, index + half)
            return median(Array(values[low...high]))
        }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0.5 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// A centre that keeps a crop of `size` inside 0–1.
    static func clamp(_ value: Double, size: Double) -> Double {
        let half = min(0.5, size / 2)
        return min(1 - half, max(half, value.isFinite ? value : 0.5))
    }
}

/// The cover: the frame the export's poster and `cover.jpg` show (design.md "Cover frame chosen").
public struct CoverFrameChoice: Codable, Sendable, Equatable {
    public var time: Double
    public var score: Double
    public init(time: Double, score: Double) { self.time = time; self.score = score }
}

public enum CoverFrame {
    /// A neighbour this close in time with closed eyes makes a frame part of a blink.
    public static let blinkWindow = 0.25
    /// Weights of the score's parts, which sum to 1.
    public static let qualityWeight = 0.4
    public static let centredWeight = 0.3
    public static let eyesWeight = 0.2
    public static let facingWeight = 0.1

    /// The score of a frame, 0–1, or nil when it cannot be a cover: no face, eyes not open, or a closed-eye neighbour
    /// within `blinkWindow` (`neighbours` are the other frames).
    public static func score(_ frame: FrameObservation, neighbours: [FrameObservation]) -> Double? {
        guard let face = frame.face, face.eyes == .open else { return nil }
        let blinking = neighbours.contains { other in
            other.time != frame.time && abs(other.time - frame.time) <= blinkWindow && other.face?.eyes == .closed
        }
        guard !blinking else { return nil }
        let quality = min(1, max(0, face.captureQuality ?? 0))
        let offset = hypot(face.rect.midX - 0.5, face.rect.midY - 0.5)
        let centred = max(0, 1 - 2 * offset)
        let ratios = [face.leftEyeAspect, face.rightEyeAspect].compactMap { $0 }
        let mean = ratios.isEmpty ? EyeAspect.closedBelow : ratios.reduce(0, +) / Double(ratios.count)
        let openness = min(1, max(0, (mean - EyeAspect.closedBelow) / 0.15))
        let facing: Double = face.facesCamera == false ? 0 : 1
        let weighted = qualityWeight * quality + centredWeight * centred
        return weighted + eyesWeight * openness + facingWeight * facing
    }

    /// The best-scoring frame; the earlier one on a tie. Nil when no frame can be a cover.
    public static func pick(_ frames: [FrameObservation]) -> CoverFrameChoice? {
        var best: CoverFrameChoice?
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            guard let value = score(frame, neighbours: frames) else { continue }
            if best == nil || value > best!.score + 1e-12 { best = CoverFrameChoice(time: frame.time, score: value) }
        }
        return best
    }
}

/// A stretch of the clip where a screen with text is visible: a blur suggestion (design.md "Blurred the phone screen
/// at …").
public struct FrameBlurSpan: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// The union of the screen's rects over the span.
    public var rect: ClipEffect.Rect
    /// Frames the screen was seen in.
    public var frames: Int
    public init(start: Double, end: Double, rect: ClipEffect.Rect, frames: Int) { self.start = start; self.end = end; self.rect = rect; self.frames = frames }
}

public enum FrameBlurSpans {
    /// Screens in two frames are one screen when their rects overlap at least this much (intersection over union).
    public static let minimumOverlap = 0.2

    /// Screens merged over time: a screen seen within `maxGap` seconds of a matching one extends its span, and the span
    /// grows by `pad` seconds on each side. Spans are in start order.
    public static func merge(_ frames: [FrameObservation], maxGap: Double, pad: Double = 0) -> [FrameBlurSpan] {
        struct Open { var first: Double; var last: Double; var lastRect: ClipEffect.Rect; var union: ClipEffect.Rect; var frames: Int }
        var spans: [Open] = []
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            for screen in frame.screens {
                let match = spans.indices.filter { frame.time - spans[$0].last <= maxGap + 1e-9 }
                    .max { FrameScreens.intersectionOverUnion(spans[$0].lastRect, screen.rect) < FrameScreens.intersectionOverUnion(spans[$1].lastRect, screen.rect) }
                if let match, FrameScreens.intersectionOverUnion(spans[match].lastRect, screen.rect) >= minimumOverlap {
                    spans[match].last = frame.time
                    spans[match].lastRect = screen.rect
                    spans[match].union = FrameScreens.union([spans[match].union, screen.rect])
                    spans[match].frames += 1
                } else {
                    spans.append(Open(first: frame.time, last: frame.time, lastRect: screen.rect, union: screen.rect, frames: 1))
                }
            }
        }
        return spans.map { FrameBlurSpan(start: max(0, $0.first - pad), end: $0.last + pad, rect: $0.union.clamped, frames: $0.frames) }
            .sorted { $0.start < $1.start }
    }
}
