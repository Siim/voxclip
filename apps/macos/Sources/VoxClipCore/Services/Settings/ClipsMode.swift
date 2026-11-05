import Foundation

/// Who makes the clips of every new video (design.md §6.6, settings `clips.mode`): Claude runs Make top N postable by
/// itself after transcription and Find Clips (§6.7), or the creator picks. Missing means not chosen yet, and the editor
/// asks once, inline.
public enum ClipsMode: String, CaseIterable, Sendable, Codable {
    case claude, pick

    public static let key = "clips.mode"
    public static let countKey = "clips.autopilot.count"
    public static let capKey = "clips.autopilot.capUSD"
    /// Top 1 / 3 / 5 per video.
    public static let counts = [1, 3, 5]
    /// Up to $0 / $1 / $2 / $5 per video for paid voice and generated music; $0 means none.
    public static let capsUSD = [0, 1, 2, 5]
    public static let defaultCount = 3
    public static let defaultCapUSD = 2
}

/// Claude mode's per-video choices, read from settings with their defaults.
public struct ClipsAutopilotSettings: Equatable, Sendable {
    /// Nil until the creator chooses.
    public var mode: ClipsMode?
    public var count: Int
    public var capUSD: Int

    public init(mode: ClipsMode? = nil, count: Int = ClipsMode.defaultCount, capUSD: Int = ClipsMode.defaultCapUSD) {
        self.mode = mode; self.count = count; self.capUSD = capUSD
    }

    /// "✦ Claude does it all · top 3 · ≤$2" (the status bar item in Claude mode).
    public var summary: String { "✦ Claude does it all · top \(count) · ≤$\(capUSD)" }
}

extension SettingsDocument {
    /// The mode, count and cap; a missing or invalid value reads as its default (mode: not chosen).
    public var clipsAutopilot: ClipsAutopilotSettings {
        var result = ClipsAutopilotSettings()
        if case .string(let text)? = values[ClipsMode.key] { result.mode = ClipsMode(rawValue: text) }
        if case .number(let number)? = values[ClipsMode.countKey], let count = ClipsMode.counts.first(where: { Double($0) == number }) { result.count = count }
        if case .number(let number)? = values[ClipsMode.capKey], let cap = ClipsMode.capsUSD.first(where: { Double($0) == number }) { result.capUSD = cap }
        return result
    }

    /// Stores the three keys. Throws `projectUnreadable` for a count or cap the settings schema refuses.
    public mutating func setClipsAutopilot(_ settings: ClipsAutopilotSettings) throws {
        guard ClipsMode.counts.contains(settings.count), ClipsMode.capsUSD.contains(settings.capUSD) else { throw VoxClipError.projectUnreadable("Invalid Claude mode setting") }
        values[ClipsMode.key] = settings.mode.map { .string($0.rawValue) }
        values[ClipsMode.countKey] = .number(Double(settings.count))
        values[ClipsMode.capKey] = .number(Double(settings.capUSD))
    }
}
