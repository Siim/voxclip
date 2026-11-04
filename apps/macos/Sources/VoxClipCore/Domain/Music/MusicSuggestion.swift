import Foundation

/// What Claude (or the user's search) asks for; doc/spec/music.md §3. The autopilot planner's music suggestion maps onto
/// this: its mood and title become the library query, its Eleven Music prompt the generation prompt.
public struct MusicBrief: Sendable, Equatable {
    public var mood: String
    /// Free-library search words; the mood when empty.
    public var query: String
    /// The Eleven Music prompt; built from the mood when empty.
    public var prompt: String
    public var reason: String?

    public init(mood: String, query: String = "", prompt: String = "", reason: String? = nil) {
        self.mood = mood; self.query = query; self.prompt = prompt; self.reason = reason
    }

    /// The words the library search sends, at most 200 characters.
    public var searchText: String {
        let text = (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? mood : query).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(200))
    }

    /// The instrumental prompt Eleven Music receives, at most 2,000 characters.
    public var compositionPrompt: String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = text.isEmpty ? "Instrumental background music, \(mood.trimmingCharacters(in: .whitespacesAndNewlines)) mood, steady, sits under a voice" : text
        return String(base.prefix(2_000))
    }

    /// Lower-cased words of three or more letters, for matching the user's own file names.
    public var keywords: Set<String> {
        let words = (mood + " " + query).lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.map(String.init).filter { $0.count >= 3 })
    }
}

/// One playable choice in the Music section: a library match, a priced generation not yet made, or the user's file.
public struct MusicCandidate: Sendable, Equatable, Identifiable {
    public var id: String
    public var source: MusicSource
    public var title: String
    public var creator: String?
    public var license: MusicLicense
    public var attribution: String?
    /// The landing page (library).
    public var sourceUrl: String?
    /// The file to download (library) or the user's file (file); nil for a generation not yet made.
    public var audioURL: URL?
    /// The file extension the stored asset takes.
    public var fileExtension: String
    public var prompt: String?
    public var durationSeconds: Double?
    /// The quoted price (generated only).
    public var estimate: CostEstimate?
    public var reason: String?
    /// The source's tags and genres, used for ranking and shown as the reason when Claude gave none.
    public var tags: [String]

    public init(id: String, source: MusicSource, title: String, creator: String? = nil, license: MusicLicense, attribution: String? = nil,
                sourceUrl: String? = nil, audioURL: URL? = nil, fileExtension: String, prompt: String? = nil, durationSeconds: Double? = nil,
                estimate: CostEstimate? = nil, reason: String? = nil, tags: [String] = []) {
        self.id = id; self.source = source; self.title = title; self.creator = creator; self.license = license; self.attribution = attribution
        self.sourceUrl = sourceUrl; self.audioURL = audioURL; self.fileExtension = fileExtension; self.prompt = prompt
        self.durationSeconds = durationSeconds; self.estimate = estimate; self.reason = reason; self.tags = tags
    }

    /// Paid before it can play.
    public var needsGeneration: Bool { source == .generated && audioURL == nil }
}

/// The best three across sources for one brief. The autopilot planner calls this with its own suggestion.
public protocol MusicSuggesting: Sendable {
    func candidates(for brief: MusicBrief, clipSeconds: Double) async -> MusicSuggestionResult
}

public struct MusicSuggestionResult: Sendable, Equatable {
    /// At most one per source, ordered library, generated, file.
    public var candidates: [MusicCandidate]
    /// Why a source has nothing to offer (offline, rate-limited, no key), shown beside the list; never blocks the others.
    public var notes: [MusicSource: String]
    public init(candidates: [MusicCandidate] = [], notes: [MusicSource: String] = [:]) { self.candidates = candidates; self.notes = notes }
}

/// Eleven Music generation length and price; music.md §3.2 and the shared price catalog.
public enum MusicPricing {
    public static let operation = VoiceLabPricedOperation(provider: "elevenlabs", operation: "musicCompose", unit: "second")
    public static let model = "music_v1"
    /// The product's bounds: Eleven Music takes 3 s to 10 min; VoxClip asks for at most 5 min.
    public static let lengthRange = 3.0...300.0

    /// The whole-second length composed for a clip of `clipSeconds`: its length rounded up, within 3 s and 5 min.
    public static func lengthSeconds(forClip clipSeconds: Double) -> Int {
        guard clipSeconds.isFinite, clipSeconds > 0 else { return Int(lengthRange.lowerBound) }
        return Int(min(lengthRange.upperBound, max(lengthRange.lowerBound, clipSeconds.rounded(.up))))
    }

    public static func estimate(seconds: Int, catalog: VoiceLabPriceCatalog) throws -> CostEstimate {
        try VoiceLabPricing.estimate(operation: operation, model: model, units: Double(seconds), catalog: catalog)
    }

    /// "$0.15" style, cents rounded up so the label never under-states the charge.
    public static func label(_ estimate: CostEstimate) -> String? {
        guard let usd = estimate.usd else { return nil }
        let cents = VoiceLabMoney.rounded(usd * 100, scale: 0, .up)
        let whole = VoiceLabMoney.rounded(cents / 100, scale: 0, .down)
        let remainder = NSDecimalNumber(decimal: cents - whole * 100).intValue
        return "$" + VoiceLabMoney.canonical(whole) + "." + (remainder < 10 ? "0" : "") + String(remainder)
    }
}

/// Text the export's post carries; music.md §5.
public enum MusicCredits {
    /// The post text with the track's credit appended once, on its own line.
    public static func postText(_ text: String, music: ProjectMusic?) -> String {
        guard let line = music?.creditLine, !text.contains(line) else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? line : trimmed + "\n\n" + line
    }
}
