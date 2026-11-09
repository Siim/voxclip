import Foundation

/// What a downloaded lip-sync result's length allows (voice-lab §9.3, ADR-R46 "fal.ai's results run short"). sync-3 keeps
/// the start and drops frames at the end: fal.ai's own example came back 130 frames for 135 (5.417 s for 5.625 s at
/// 24 fps). Every upload therefore carries `LipsyncLimits.tailMarginSeconds` past the needed length (the voice's), and the
/// import cuts the result back to the needed length from its start.
public struct LipsyncResultLength: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// At least the needed length: cut back to it from the start.
        case trim
        /// Short by `frames` (1 ... `LipsyncLimits.heldFrames`): the last frame is held to the needed length.
        case hold(frames: Int)
        /// Short by more than the hold allows.
        case short(frames: Int)
        /// Longer than was sent (the needed length plus the margin, and a frame).
        case long
    }

    /// The result's video length, its needed length (the voice's), what was uploaded (needed plus the margin) and its rate.
    public let got: Double
    public let needed: Double
    public let uploaded: Double
    public let fps: Double

    public init(got: Double, needed: Double, uploaded: Double, fps: Double) {
        self.got = got; self.needed = needed; self.uploaded = uploaded; self.fps = fps
    }

    /// Whole frames below the needed length, 0 when it reaches it.
    public var shortFrames: Int {
        let frames: Double = (needed - got) * fps
        return frames.isFinite ? max(0, Int(frames.rounded())) : Int.max
    }

    /// The frames fal.ai dropped from what was sent: the number to watch as windows grow (logged on every import).
    public var droppedFrames: Int {
        let frames: Double = (uploaded - got) * fps
        return frames.isFinite ? Int(frames.rounded()) : 0
    }

    public var outcome: Outcome {
        let frame: Double = 1 / fps
        guard got.isFinite, needed.isFinite, uploaded.isFinite, fps.isFinite, fps > 0, got > 0 else { return .short(frames: shortFrames) }
        if got > uploaded + frame { return .long }
        if got >= needed - frame / 2 { return .trim }
        let short = shortFrames
        return short <= LipsyncLimits.heldFrames ? .hold(frames: max(1, short)) : .short(frames: short)
    }

    public var accepted: Bool {
        switch outcome {
        case .trim, .hold: true
        case .short, .long: false
        }
    }

    /// `lipsync result check=duration got=5.417 expected=5.625 uploaded=6.025 fps=24 short_frames=5 dropped_frames=15 outcome=trim`
    public var logLine: String {
        let name: String
        switch outcome {
        case .trim: name = "trim"
        case .hold: name = "hold"
        case .short: name = "short"
        case .long: name = "long"
        }
        return "lipsync result check=duration got=\(Self.number(got)) expected=\(Self.number(needed)) uploaded=\(Self.number(uploaded))"
            + " fps=\(Self.number(fps)) short_frames=\(shortFrames) dropped_frames=\(droppedFrames) outcome=\(name)"
    }

    package static func number(_ value: Double) -> String {
        guard value.isFinite else { return "nan" }
        let text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        var trimmed = Substring(text)
        while trimmed.hasSuffix("0") { trimmed = trimmed.dropLast() }
        if trimmed.hasSuffix(".") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}

/// A downloaded lip-sync result failed one named check. `logLine` carries its name and numbers only (no URLs, keys or file
/// names); `copy` says what happened in plain words for the Stopped card and the phrase row.
public struct LipsyncResultCheck: Error, Sendable, Equatable {
    public enum Name: String, Sendable {
        case container, tracks, codec, transform, start, size, fps, duration
    }
    public let name: Name
    public let logLine: String
    public let copy: String
    /// The duration check's numbers, when it was the one that failed.
    public let length: LipsyncResultLength?

    init(name: Name, logLine: String, copy: String, length: LipsyncResultLength? = nil) {
        self.name = name; self.logLine = logLine; self.copy = copy; self.length = length
    }

    public static func duration(_ length: LipsyncResultLength) -> LipsyncResultCheck {
        let copy: String
        if case .long = length.outcome {
            copy = "fal.ai's video came back \(seconds(length.got - length.uploaded)) longer than what was sent."
        } else {
            copy = "fal.ai's video came back \(seconds(length.needed - length.got)) shorter than the voice."
        }
        return .init(name: .duration, logLine: length.logLine, copy: copy, length: length)
    }

    public static func size(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int) -> LipsyncResultCheck {
        .init(name: .size, logLine: "lipsync result check=size got=\(width)x\(height) expected=\(expectedWidth)x\(expectedHeight)",
              copy: "fal.ai's video came back at \(width) × \(height) instead of \(expectedWidth) × \(expectedHeight).")
    }

    public static func frameRate(_ got: Double, expected: Double) -> LipsyncResultCheck {
        .init(name: .fps, logLine: "lipsync result check=fps got=\(LipsyncResultLength.number(got)) expected=\(LipsyncResultLength.number(expected))",
              copy: "fal.ai's video came back at \(LipsyncResultLength.number(got)) fps instead of \(LipsyncResultLength.number(expected)) fps.")
    }

    /// A structural check (`container`, `tracks`, `codec`, `transform`, `start`) with its numbers, for example "videos=0 audios=1".
    public static func structure(_ name: Name, _ detail: String) -> LipsyncResultCheck {
        let what: String
        switch name {
        case .container: what = "isn't an MP4 file VoxClip can open"
        case .tracks: what = "doesn't have one video track"
        case .codec: what = "isn't H.264"
        case .transform: what = "is rotated"
        case .start: what = "doesn't start at its first frame"
        default: what = "can't be used"
        }
        return .init(name: name, logLine: "lipsync result check=\(name.rawValue) \(detail)", copy: "fal.ai's video \(what).")
    }

    /// "0.2 s", at least 0.1 s.
    static func seconds(_ value: Double) -> String {
        let tenths = max(1, (abs(value.isFinite ? value : 0) * 10).rounded())
        return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), tenths / 10)
    }
}
