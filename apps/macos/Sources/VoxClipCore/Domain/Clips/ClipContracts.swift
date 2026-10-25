import Foundation

/// Shared clip-finder preset identifiers; AI §11.7.
public enum ClipPresetID: String, Codable, Sendable, Hashable, CaseIterable {
    case best
    case hooks
    case topics
    case quotes
    case custom
}

/// Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
public struct ClipPreset: Codable, Sendable, Equatable {
    /// id; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var id: ClipPresetID
    /// label; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var label: String
    /// instruction; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var instruction: String
    /// minSeconds; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var minSeconds: Double
    /// maxSeconds; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var maxSeconds: Double
    /// maxClips; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var maxClips: Int
    /// noOverlap; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var noOverlap: Bool
    /// requiresInstructions; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var requiresInstructions: Bool
    /// placeholder; Loaded verbatim from shared/prompts/clip-finder.json; AI §11.4 and §11.7.
    public var placeholder: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: ClipPresetID, label: String, instruction: String, minSeconds: Double, maxSeconds: Double, maxClips: Int, noOverlap: Bool, requiresInstructions: Bool = false, placeholder: String = "") {
        self.id = id
        self.label = label
        self.instruction = instruction
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.maxClips = maxClips
        self.noOverlap = noOverlap
        self.requiresInstructions = requiresInstructions
        self.placeholder = placeholder
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case instruction
        case minSeconds
        case maxSeconds
        case maxClips
        case noOverlap
        case requiresInstructions
        case placeholder
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(ClipPresetID.self, forKey: .id)
        self.label = try values.decode(String.self, forKey: .label)
        self.instruction = try values.decode(String.self, forKey: .instruction)
        self.minSeconds = try values.decode(Double.self, forKey: .minSeconds)
        self.maxSeconds = try values.decode(Double.self, forKey: .maxSeconds)
        self.maxClips = try values.decode(Int.self, forKey: .maxClips)
        self.noOverlap = try values.decode(Bool.self, forKey: .noOverlap)
        self.requiresInstructions = try values.decodeIfPresent(Bool.self, forKey: .requiresInstructions) ?? false
        self.placeholder = try values.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(label, forKey: .label)
        try values.encode(instruction, forKey: .instruction)
        try values.encode(minSeconds, forKey: .minSeconds)
        try values.encode(maxSeconds, forKey: .maxSeconds)
        try values.encode(maxClips, forKey: .maxClips)
        try values.encode(noOverlap, forKey: .noOverlap)
        try values.encode(requiresInstructions, forKey: .requiresInstructions)
        try values.encode(placeholder, forKey: .placeholder)
    }

}

/// Absolute transcript numbering; AI §11.2.
public struct ClipWord: Codable, Sendable, Equatable {
    /// index; Absolute transcript numbering; AI §11.2.
    public var index: Int
    /// text; Absolute transcript numbering; AI §11.2.
    public var text: String
    /// start; Absolute transcript numbering; AI §11.2.
    public var start: Double
    /// end; Absolute transcript numbering; AI §11.2.
    public var end: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(index: Int, text: String, start: Double, end: Double) {
        self.index = index
        self.text = text
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case text
        case start
        case end
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try values.decode(Int.self, forKey: .index)
        self.text = try values.decode(String.self, forKey: .text)
        self.start = try values.decode(Double.self, forKey: .start)
        self.end = try values.decode(Double.self, forKey: .end)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.index, forKey: .index)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
    }

}

/// Lenient numeric response before finalization; AI §2.3 and §11.7.
public struct ClipCandidate: Codable, Sendable, Equatable {
    /// title; Lenient numeric response before finalization; AI §2.3 and §11.7.
    public var title: String
    /// reason; Lenient numeric response before finalization; AI §2.3 and §11.7.
    public var reason: String
    /// score; Lenient numeric response before finalization; AI §2.3 and §11.7.
    public var score: Double
    /// startWord; Lenient numeric response before finalization; AI §2.3 and §11.7.
    public var startWord: Double
    /// endWord; Lenient numeric response before finalization; AI §2.3 and §11.7.
    public var endWord: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(title: String, reason: String, score: Double, startWord: Double, endWord: Double) {
        self.title = title
        self.reason = reason
        self.score = score
        self.startWord = startWord
        self.endWord = endWord
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case reason
        case score
        case startWord = "start_word"
        case endWord = "end_word"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try values.decode(String.self, forKey: .title)
        self.reason = try values.decode(String.self, forKey: .reason)
        self.score = try values.decode(Double.self, forKey: .score)
        self.startWord = try values.decode(Double.self, forKey: .startWord)
        self.endWord = try values.decode(Double.self, forKey: .endWord)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.title, forKey: .title)
        try values.encode(self.reason, forKey: .reason)
        try values.encode(self.score, forKey: .score)
        try values.encode(self.startWord, forKey: .startWord)
        try values.encode(self.endWord, forKey: .endWord)
    }

}

/// Validated inclusive transcript index range; AI §11.7–11.8.
public struct ClipSuggestion: Codable, Sendable, Equatable {
    /// title; Validated inclusive transcript index range; AI §11.7–11.8.
    public var title: String
    /// reason; Validated inclusive transcript index range; AI §11.7–11.8.
    public var reason: String
    /// score; Validated inclusive transcript index range; AI §11.7–11.8.
    public var score: Int
    /// startWord; Validated inclusive transcript index range; AI §11.7–11.8.
    public var startWord: Int
    /// endWord; Validated inclusive transcript index range; AI §11.7–11.8.
    public var endWord: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(title: String, reason: String, score: Int, startWord: Int, endWord: Int) {
        self.title = title
        self.reason = reason
        self.score = score
        self.startWord = startWord
        self.endWord = endWord
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case reason
        case score
        case startWord
        case endWord
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try values.decode(String.self, forKey: .title)
        self.reason = try values.decode(String.self, forKey: .reason)
        self.score = try values.decode(Int.self, forKey: .score)
        self.startWord = try values.decode(Int.self, forKey: .startWord)
        self.endWord = try values.decode(Int.self, forKey: .endWord)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.title, forKey: .title)
        try values.encode(self.reason, forKey: .reason)
        try values.encode(self.score, forKey: .score)
        try values.encode(self.startWord, forKey: .startWord)
        try values.encode(self.endWord, forKey: .endWord)
    }

}

/// Finalizer runtime policy; AI §11.7.
public struct FinalizeClipsOptions: Codable, Sendable, Equatable {
    /// snap; Finalizer runtime policy; AI §11.7.
    public var snap: Bool
    /// cutWordIds; Finalizer runtime policy; AI §11.7.
    public var cutWordIds: Set<String>
    /// windowCount; Finalizer runtime policy; AI §11.7.
    public var windowCount: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(snap: Bool = true, cutWordIds: Set<String> = [], windowCount: Int = 1) {
        self.snap = snap
        self.cutWordIds = cutWordIds
        self.windowCount = windowCount
    }

    private enum CodingKeys: String, CodingKey {
        case snap
        case cutWordIds
        case windowCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.snap = try values.decodeIfPresent(Bool.self, forKey: .snap) ?? true
        self.cutWordIds = try values.decodeIfPresent(Set<String>.self, forKey: .cutWordIds) ?? []
        self.windowCount = try values.decodeIfPresent(Int.self, forKey: .windowCount) ?? 1
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.snap, forKey: .snap)
        try values.encode(self.cutWordIds, forKey: .cutWordIds)
        try values.encode(self.windowCount, forKey: .windowCount)
    }

}

/// Feature request without credentials; AI §11.1.
public struct ClipFinderRequest: Codable, Sendable, Equatable {
    /// transcript; Feature request without credentials; AI §11.1.
    public var transcript: Transcript
    /// corrections; Feature request without credentials; AI §11.1.
    public var corrections: [String: String]
    /// cutWordIds; Feature request without credentials; AI §11.1.
    public var cutWordIds: Set<String>
    /// preset; Feature request without credentials; AI §11.1.
    public var preset: ClipPreset
    /// instruction; Feature request without credentials; AI §11.1.
    public var instruction: String?
    /// snap; Feature request without credentials; AI §11.1.
    public var snap: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(transcript: Transcript, corrections: [String: String] = [:], cutWordIds: Set<String> = [], preset: ClipPreset, instruction: String? = nil, snap: Bool = true) {
        self.transcript = transcript
        self.corrections = corrections
        self.cutWordIds = cutWordIds
        self.preset = preset
        self.instruction = instruction
        self.snap = snap
    }

    private enum CodingKeys: String, CodingKey {
        case transcript
        case corrections
        case cutWordIds
        case preset
        case instruction
        case snap
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.transcript = try values.decode(Transcript.self, forKey: .transcript)
        self.corrections = try values.decodeIfPresent([String: String].self, forKey: .corrections) ?? [:]
        self.cutWordIds = try values.decodeIfPresent(Set<String>.self, forKey: .cutWordIds) ?? []
        self.preset = try values.decode(ClipPreset.self, forKey: .preset)
        self.instruction = try values.decodeIfPresent(String.self, forKey: .instruction) ?? nil
        self.snap = try values.decodeIfPresent(Bool.self, forKey: .snap) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.transcript, forKey: .transcript)
        try values.encode(self.corrections, forKey: .corrections)
        try values.encode(self.cutWordIds, forKey: .cutWordIds)
        try values.encode(self.preset, forKey: .preset)
        try values.encode(self.instruction, forKey: .instruction)
        try values.encode(self.snap, forKey: .snap)
    }

}

/// Canonical parsing and finalization; AI §4.5, §11.3 and §11.7.
public func formatTranscript(_ words: [ClipWord]) throws -> FormattedTranscript { throw VoxClipError.notImplemented("mac-ai") }
public func finalizeClips(_ candidates: [ClipCandidate], words: [TimedWord], preset: ClipPreset, lines: [TranscriptLine], options: FinalizeClipsOptions = FinalizeClipsOptions()) throws -> [ClipSuggestion] { throw VoxClipError.notImplemented("mac-ai") }
public enum CanonicalResponseParser {
    public static func parse(_ completion: RawCompletion, schema: JSONValue) throws -> JSONValue { throw VoxClipError.notImplemented("mac-ai") }
}
/// Pure M2 suggestions only, never applied automatically; AI §12.
public struct TightenEdit: Codable, Sendable, Equatable {
    public var startWord: Int
    public var endWord: Int
    public var reason: String
    public init(startWord: Int, endWord: Int, reason: String) { self.startWord = startWord; self.endWord = endWord; self.reason = reason }
}
