import Foundation
import Synchronization

/// One stage from a video to its clips, as `voxclip-cli autopilot --timings` and the app's Claude mode log line name it.
public enum ClaudeModeStage: String, Sendable, CaseIterable, Codable {
    case probe, audio, transcribe, find, plan, apply, export
}

/// One stage's wall time: when it started and ended, in seconds from the run's start, and for a clip stage which clip
/// (1 is the best; the rank Find Clips gave it).
public struct ClaudeModeTiming: Sendable, Equatable, Codable {
    public let stage: ClaudeModeStage
    public let clip: Int?
    public let start: Double
    public let end: Double
    public var seconds: Double { max(0, end - start) }
    public init(stage: ClaudeModeStage, clip: Int? = nil, start: Double, end: Double) {
        self.stage = stage; self.clip = clip; self.start = start; self.end = end
    }
}

/// The wall times of one run from a video to its clips (ai.md §16.12): numbers only, never a title, a word or a path, so
/// they can go to the log and the CLI's JSON as they are. Thread-safe; stages may overlap (clips plan at once).
public final class ClaudeModeClock: Sendable {
    private let origin: ContinuousClock.Instant
    private let entries = Mutex<[ClaudeModeTiming]>([])
    private let open = Mutex<[String: Double]>([:])

    public init(origin: ContinuousClock.Instant = .now) { self.origin = origin }

    /// Seconds since the run started.
    public var elapsed: Double { Self.seconds(origin.duration(to: .now)) }

    /// Records `stage` as running from `start` (an earlier `elapsed`) until now.
    public func record(_ stage: ClaudeModeStage, clip: Int? = nil, since start: Double) {
        let end = elapsed
        entries.withLock { $0.append(ClaudeModeTiming(stage: stage, clip: clip, start: start, end: max(start, end))) }
    }

    /// Starts `stage` for `clip` now; `end` records it. A stage begun twice keeps its first start.
    public func begin(_ stage: ClaudeModeStage, clip: Int? = nil) {
        let now = elapsed
        open.withLock { if $0[Self.key(stage, clip)] == nil { $0[Self.key(stage, clip)] = now } }
    }

    /// Records `stage` for `clip` from its `begin` until now; nothing when it was not begun or has ended.
    public func end(_ stage: ClaudeModeStage, clip: Int? = nil) {
        guard let start = open.withLock({ $0.removeValue(forKey: Self.key(stage, clip)) }) else { return }
        record(stage, clip: clip, since: start)
    }

    private static func key(_ stage: ClaudeModeStage, _ clip: Int?) -> String { stage.rawValue + "#" + (clip.map(String.init) ?? "") }

    /// Times `body` as `stage`.
    public func measure<T>(_ stage: ClaudeModeStage, clip: Int? = nil, _ body: () throws -> T) rethrows -> T {
        let start = elapsed
        defer { record(stage, clip: clip, since: start) }
        return try body()
    }

    /// Every recorded stage, in the order each ended.
    public var timings: [ClaudeModeTiming] { entries.withLock { $0 } }

    /// When the first clip was postable: the end of the first clip's apply, seconds from the start; nil before one is.
    public var firstReady: Double? { timings.filter { $0.stage == .apply }.map(\.end).min() }

    /// The CLI's `timings` object: each stage with its clip and seconds (three decimals), the first postable clip and the
    /// whole run.
    public func json() -> JSONValue {
        func number(_ value: Double) -> JSONValue { .number((value * 1000).rounded() / 1000) }
        let stages: [JSONValue] = timings.map { timing in
            var fields: [String: JSONValue] = ["stage": .string(timing.stage.rawValue), "seconds": number(timing.seconds),
                                               "start": number(timing.start), "end": number(timing.end)]
            if let clip = timing.clip { fields["clip"] = .number(Double(clip)) }
            return .object(fields)
        }
        let total = timings.map(\.end).max() ?? 0
        return .object(["stages": .array(stages), "firstClipSeconds": firstReady.map(number) ?? .null, "totalSeconds": number(total)])
    }

    /// The app log's one line, numbers only: "claude-mode timings transcribe=53.1 find=41.2 plan1=61.0 apply1=1.4 … first=… total=…".
    public func logLine() -> String {
        let parts = timings.map { "\($0.stage.rawValue)\($0.clip.map(String.init) ?? "")=\(toFixed1($0.seconds))" }
        let total = timings.map(\.end).max() ?? 0
        return (["claude-mode timings"] + parts + [firstReady.map { "first=\(toFixed1($0))" } ?? "first=none", "total=\(toFixed1(total))"])
            .joined(separator: " ")
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
