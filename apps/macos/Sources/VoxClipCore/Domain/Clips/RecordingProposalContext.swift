import Foundation

public struct RecordingProposalContext: Codable, Equatable, Sendable {
    struct Recording: Codable, Equatable, Sendable {
        let key: String
        let label: String
        let words: ClosedRange<Int>
    }

    struct Version: Codable, Equatable, Sendable {
        let take: TakeMatch.Take
        let words: ClosedRange<Int>
    }

    struct Beat: Codable, Equatable, Sendable {
        let id: String
        let versions: [Version]
    }

    let recordings: [Recording]
    let beats: [Beat]
    let solo: [ClosedRange<Int>]

    public init?(clock: ProjectClock) {
        guard clock.regions.count > 1 else { return nil }
        let words = clock.words
        let indices = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let byKey = Dictionary(grouping: words.indices) { clock.region(of: words[$0].id)?.key }
        recordings = clock.regions.compactMap { region in
            guard let positions = byKey[region.key], let first = positions.first, let last = positions.last else { return nil }
            return Recording(key: region.key, label: region.label, words: first...last)
        }
        func range(_ start: String, _ end: String) -> ClosedRange<Int>? {
            guard let first = indices[start], let last = indices[end], first <= last else { return nil }
            return first...last
        }
        let match = TakeMatch.build(clock: clock)
        beats = match.beats.map { beat in
            Beat(id: beat.id, versions: beat.takes.compactMap { take in
                range(take.startWordId, take.endWordId).map { Version(take: take, words: $0) }
            })
        }
        solo = match.solo.compactMap { range($0.startWordId, $0.endWordId) }
    }

    public var canCompare: Bool { recordings.count >= 2 }

    func contains(_ range: ClosedRange<Int>) -> Bool {
        recordings.contains { $0.words.contains(range.lowerBound) && $0.words.contains(range.upperBound) }
    }

    func beatIDs(in range: ClosedRange<Int>) -> [String] {
        beats.filter { $0.versions.contains { $0.words.overlaps(range) } }.map(\.id)
    }

    func block(unit: String, bounds: (ClosedRange<Int>) -> ClosedRange<Int>) -> String {
        func describe(_ words: ClosedRange<Int>) -> String {
            let span = bounds(words)
            return "\(unit) \(span.lowerBound)–\(span.upperBound)"
        }
        let labels = Dictionary(uniqueKeysWithValues: recordings.map { ($0.key, $0.label) })
        let headers = recordings.map { "Recording \($0.label): \(describe($0.words))" }
        let versions = beats.flatMap { beat in
            ["Beat \(beat.id):"] + beat.versions.map { version in
                let take = version.take
                let signals = take.signals
                let flags = take.flags.isEmpty ? "none" : take.flags.joined(separator: ", ")
                return "- \(labels[take.key] ?? take.key) \(describe(version.words)); flags: \(flags); fillers: \(signals.fillers); longest pause: \(toFixed1(signals.longestPause))s; restarts: \(signals.restarts); cut off: \(signals.cutOff)"
            }
        }
        return (["<recordings>"] + headers + ["</recordings>", "<takes>"] + versions + solo.map { "Solo: \(describe($0))" } + ["</takes>"]).joined(separator: "\n")
    }
}
