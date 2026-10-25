import Foundation

/// Derived source pause; editing §2.4.
public struct Pause: Codable, Sendable, Equatable {
    /// id; Derived source pause; editing §2.4.
    public var id: String
    /// afterIndex; Derived source pause; editing §2.4.
    public var afterIndex: Int
    /// start; Derived source pause; editing §2.4.
    public var start: Double
    /// end; Derived source pause; editing §2.4.
    public var end: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: String, afterIndex: Int, start: Double, end: Double) {
        self.id = id
        self.afterIndex = afterIndex
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case afterIndex
        case start
        case end
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.afterIndex = try values.decode(Int.self, forKey: .afterIndex)
        self.start = try values.decode(Double.self, forKey: .start)
        self.end = try values.decode(Double.self, forKey: .end)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.afterIndex, forKey: .afterIndex)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
    }
    public var duration: Double { end - start }
    public var label: String { "pause " + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), duration) + "s" }
}

/// Half-open source sample interval; editing §2.7.
public struct MediaInterval: Codable, Sendable, Equatable {
    /// startSample; Half-open source sample interval; editing §2.7.
    public var startSample: Int64
    /// endSample; Half-open source sample interval; editing §2.7.
    public var endSample: Int64

    /// Creates an explicit value without I/O or generated identifiers.
    public init(startSample: Int64, endSample: Int64) {
        self.startSample = startSample
        self.endSample = endSample
    }

    private enum CodingKeys: String, CodingKey {
        case startSample
        case endSample
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.startSample = try values.decode(Int64.self, forKey: .startSample)
        self.endSample = try values.decode(Int64.self, forKey: .endSample)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.startSample, forKey: .startSample)
        try values.encode(self.endSample, forKey: .endSample)
    }
    public var count: Int64 { endSample - startSample }
}

/// Source seconds interval; editing §7.2.
public struct TimeRange: Codable, Sendable, Equatable {
    /// start; Source seconds interval; editing §7.2.
    public var start: Double
    /// end; Source seconds interval; editing §7.2.
    public var end: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.start = try values.decode(Double.self, forKey: .start)
        self.end = try values.decode(Double.self, forKey: .end)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
    }

}

/// Reducer state; editing §2.5. ProjectEdits is the serialized subset.
public struct EditState: Codable, Sendable, Equatable {
    /// transcript; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var transcript: Transcript
    /// pauses; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var pauses: [Pause]
    /// pauseThresholdSeconds; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var pauseThresholdSeconds: Double
    /// pauseKeepSeconds; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var pauseKeepSeconds: Double
    /// cutWordIds; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var cutWordIds: Set<String>
    /// cutPauseIds; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var cutPauseIds: Set<String>
    /// corrections; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var corrections: [String: String]
    /// clips; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var clips: [ClipRange]
    /// activeClipId; Reducer state; editing §2.5. ProjectEdits is the serialized subset.
    public var activeClipId: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(transcript: Transcript, pauses: [Pause] = [], pauseThresholdSeconds: Double = 1, pauseKeepSeconds: Double = 0.15, cutWordIds: Set<String> = [], cutPauseIds: Set<String> = [], corrections: [String: String] = [:], clips: [ClipRange] = [], activeClipId: String? = nil) {
        self.transcript = transcript
        self.pauses = pauses
        self.pauseThresholdSeconds = pauseThresholdSeconds
        self.pauseKeepSeconds = pauseKeepSeconds
        self.cutWordIds = cutWordIds
        self.cutPauseIds = cutPauseIds
        self.corrections = corrections
        self.clips = clips
        self.activeClipId = activeClipId
    }

    private enum CodingKeys: String, CodingKey {
        case transcript
        case pauses
        case pauseThresholdSeconds
        case pauseKeepSeconds
        case cutWordIds
        case cutPauseIds
        case corrections
        case clips
        case activeClipId
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.transcript = try values.decode(Transcript.self, forKey: .transcript)
        self.pauses = try values.decodeIfPresent([Pause].self, forKey: .pauses) ?? []
        self.pauseThresholdSeconds = try values.decodeIfPresent(Double.self, forKey: .pauseThresholdSeconds) ?? 1
        self.pauseKeepSeconds = try values.decodeIfPresent(Double.self, forKey: .pauseKeepSeconds) ?? 0.15
        self.cutWordIds = try values.decodeIfPresent(Set<String>.self, forKey: .cutWordIds) ?? []
        self.cutPauseIds = try values.decodeIfPresent(Set<String>.self, forKey: .cutPauseIds) ?? []
        self.corrections = try values.decodeIfPresent([String: String].self, forKey: .corrections) ?? [:]
        self.clips = try values.decodeIfPresent([ClipRange].self, forKey: .clips) ?? []
        self.activeClipId = try values.decodeIfPresent(String.self, forKey: .activeClipId) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.transcript, forKey: .transcript)
        try values.encode(self.pauses, forKey: .pauses)
        try values.encode(self.pauseThresholdSeconds, forKey: .pauseThresholdSeconds)
        try values.encode(self.pauseKeepSeconds, forKey: .pauseKeepSeconds)
        try values.encode(self.cutWordIds, forKey: .cutWordIds)
        try values.encode(self.cutPauseIds, forKey: .cutPauseIds)
        try values.encode(self.corrections, forKey: .corrections)
        try values.encode(self.clips, forKey: .clips)
        try values.encode(self.activeClipId, forKey: .activeClipId)
    }

}

/// Explicit segment identity; editing §2.6. Never infer it from IDs.
public enum EditSegmentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case word
    case pause
    case range
}

/// Planner input; editing §2.6.
public struct EditSegment: Codable, Sendable, Equatable {
    /// id; Planner input; editing §2.6.
    public var id: String
    /// kind; Planner input; editing §2.6.
    public var kind: EditSegmentKind
    /// wordKind; Planner input; editing §2.6.
    public var wordKind: WordKind
    /// text; Planner input; editing §2.6.
    public var text: String
    /// start; Planner input; editing §2.6.
    public var start: Double
    /// end; Planner input; editing §2.6.
    public var end: Double
    /// cut; Planner input; editing §2.6.
    public var cut: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: String, kind: EditSegmentKind, wordKind: WordKind = .word, text: String = "", start: Double, end: Double, cut: Bool) {
        self.id = id
        self.kind = kind
        self.wordKind = wordKind
        self.text = text
        self.start = start
        self.end = end
        self.cut = cut
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case wordKind
        case text
        case start
        case end
        case cut
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.kind = try values.decode(EditSegmentKind.self, forKey: .kind)
        self.wordKind = try values.decodeIfPresent(WordKind.self, forKey: .wordKind) ?? .word
        self.text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.start = try values.decode(Double.self, forKey: .start)
        self.end = try values.decode(Double.self, forKey: .end)
        self.cut = try values.decode(Bool.self, forKey: .cut)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.kind, forKey: .kind)
        try values.encode(self.wordKind, forKey: .wordKind)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
        try values.encode(self.cut, forKey: .cut)
    }

}

/// Join fades on the edited sample grid; architecture §5.3.
public struct Join: Codable, Sendable, Equatable {
    /// outSample; Join fades on the edited sample grid; architecture §5.3.
    public var outSample: Int64
    /// fadeOutLen; Join fades on the edited sample grid; architecture §5.3.
    public var fadeOutLen: Int64
    /// fadeInLen; Join fades on the edited sample grid; architecture §5.3.
    public var fadeInLen: Int64

    /// Creates an explicit value without I/O or generated identifiers.
    public init(outSample: Int64, fadeOutLen: Int64, fadeInLen: Int64) {
        self.outSample = outSample
        self.fadeOutLen = fadeOutLen
        self.fadeInLen = fadeInLen
    }

    private enum CodingKeys: String, CodingKey {
        case outSample
        case fadeOutLen
        case fadeInLen
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.outSample = try values.decode(Int64.self, forKey: .outSample)
        self.fadeOutLen = try values.decode(Int64.self, forKey: .fadeOutLen)
        self.fadeInLen = try values.decode(Int64.self, forKey: .fadeInLen)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.outSample, forKey: .outSample)
        try values.encode(self.fadeOutLen, forKey: .fadeOutLen)
        try values.encode(self.fadeInLen, forKey: .fadeInLen)
    }

}

/// Sample-grid plan; editing §2.7 and §7.4–7.7.
public struct EditPlan: Codable, Sendable, Equatable {
    /// sampleRate; Sample-grid plan; editing §2.7 and §7.4–7.7.
    public var sampleRate: Double
    /// totalSamples; Sample-grid plan; editing §2.7 and §7.4–7.7.
    public var totalSamples: Int64
    /// cuts; Sample-grid plan; editing §2.7 and §7.4–7.7.
    public var cuts: [MediaInterval]
    /// kept; Sample-grid plan; editing §2.7 and §7.4–7.7.
    public var kept: [MediaInterval]
    /// outputSamples; Sample-grid plan; editing §2.7 and §7.4–7.7.
    public var outputSamples: Int64
    /// joins; Sample-grid plan; editing §2.7 and §7.4–7.7.
    public var joins: [Join]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(sampleRate: Double, totalSamples: Int64, cuts: [MediaInterval] = [], kept: [MediaInterval] = [], outputSamples: Int64, joins: [Join] = []) {
        self.sampleRate = sampleRate
        self.totalSamples = totalSamples
        self.cuts = cuts
        self.kept = kept
        self.outputSamples = outputSamples
        self.joins = joins
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate
        case totalSamples
        case cuts
        case kept
        case outputSamples
        case joins
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        self.totalSamples = try values.decode(Int64.self, forKey: .totalSamples)
        self.cuts = try values.decodeIfPresent([MediaInterval].self, forKey: .cuts) ?? []
        self.kept = try values.decodeIfPresent([MediaInterval].self, forKey: .kept) ?? []
        self.outputSamples = try values.decode(Int64.self, forKey: .outputSamples)
        self.joins = try values.decodeIfPresent([Join].self, forKey: .joins) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.sampleRate, forKey: .sampleRate)
        try values.encode(self.totalSamples, forKey: .totalSamples)
        try values.encode(self.cuts, forKey: .cuts)
        try values.encode(self.kept, forKey: .kept)
        try values.encode(self.outputSamples, forKey: .outputSamples)
        try values.encode(self.joins, forKey: .joins)
    }

    public var duration: Double { sampleRate > 0 ? Double(outputSamples) / sampleRate : 0 }
    /// mac-editing supplies validation and the exact fixture-tested planner.
    public static func build(transcript: Transcript, editState: EditState, activeClip: ClipRange?, duration: Double, sampleRate: Double) throws -> EditPlan {
        throw VoxClipError.notImplemented("mac-editing")
    }
    /// Placeholder: identity mapping until mac-editing implements §7.5.
    public func mapTime(_ source: Double) -> Double {
        // TODO(mac-editing)
        return source
    }
    /// Placeholder: identity mapping until mac-editing implements §7.5.
    public func sourceTime(_ edited: Double) -> Double {
        // TODO(mac-editing)
        return edited
    }
    public func editedTime(fromSource source: Double) -> Double { mapTime(source) }
    public func sourceTime(fromEdited edited: Double) -> Double { sourceTime(edited) }
    /// Placeholder unity gain; never call an unbuilt skeleton plan for export.
    public func joinGain(at sample: Int64) -> Double {
        // TODO(mac-editing)
        return 1
    }
}

/// Scoped summary; editing §6.4.
public struct EditSummary: Codable, Sendable, Equatable {
    /// fillerCount; Scoped summary; editing §6.4.
    public var fillerCount: Int
    /// cutWordCount; Scoped summary; editing §6.4.
    public var cutWordCount: Int
    /// pauseCount; Scoped summary; editing §6.4.
    public var pauseCount: Int
    /// cutPauseCount; Scoped summary; editing §6.4.
    public var cutPauseCount: Int
    /// canCutFillers; Scoped summary; editing §6.4.
    public var canCutFillers: Bool
    /// canTighten; Scoped summary; editing §6.4.
    public var canTighten: Bool
    /// hasEdits; Scoped summary; editing §6.4.
    public var hasEdits: Bool
    /// canExport; Scoped summary; editing §6.4.
    public var canExport: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(fillerCount: Int = 0, cutWordCount: Int = 0, pauseCount: Int = 0, cutPauseCount: Int = 0, canCutFillers: Bool = false, canTighten: Bool = false, hasEdits: Bool = false, canExport: Bool = false) {
        self.fillerCount = fillerCount
        self.cutWordCount = cutWordCount
        self.pauseCount = pauseCount
        self.cutPauseCount = cutPauseCount
        self.canCutFillers = canCutFillers
        self.canTighten = canTighten
        self.hasEdits = hasEdits
        self.canExport = canExport
    }

    private enum CodingKeys: String, CodingKey {
        case fillerCount
        case cutWordCount
        case pauseCount
        case cutPauseCount
        case canCutFillers
        case canTighten
        case hasEdits
        case canExport
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.fillerCount = try values.decodeIfPresent(Int.self, forKey: .fillerCount) ?? 0
        self.cutWordCount = try values.decodeIfPresent(Int.self, forKey: .cutWordCount) ?? 0
        self.pauseCount = try values.decodeIfPresent(Int.self, forKey: .pauseCount) ?? 0
        self.cutPauseCount = try values.decodeIfPresent(Int.self, forKey: .cutPauseCount) ?? 0
        self.canCutFillers = try values.decodeIfPresent(Bool.self, forKey: .canCutFillers) ?? false
        self.canTighten = try values.decodeIfPresent(Bool.self, forKey: .canTighten) ?? false
        self.hasEdits = try values.decodeIfPresent(Bool.self, forKey: .hasEdits) ?? false
        self.canExport = try values.decodeIfPresent(Bool.self, forKey: .canExport) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.fillerCount, forKey: .fillerCount)
        try values.encode(self.cutWordCount, forKey: .cutWordCount)
        try values.encode(self.pauseCount, forKey: .pauseCount)
        try values.encode(self.cutPauseCount, forKey: .cutPauseCount)
        try values.encode(self.canCutFillers, forKey: .canCutFillers)
        try values.encode(self.canTighten, forKey: .canTighten)
        try values.encode(self.hasEdits, forKey: .hasEdits)
        try values.encode(self.canExport, forKey: .canExport)
    }

}

/// Reducer commands; editing §6.3. IDs are caller-supplied so Domain never generates randomness.
public enum EditCommand: Sendable, Equatable {
    case toggle(id: String)
    case cutSelection(ids: [String])
    case restoreSelection(ids: [String])
    case cutFillers, tightenPauses, restoreCuts
    case correct(id: String, text: String)
    case setActiveClip(clipId: String?)
    case addClip(ClipRange)
    /// Adds one prepared batch; callers supply ids, and the reducer deduplicates ranges. Editing §6.3.
    case addAIClips(resultId: String, clips: [ClipRange])
    case updateClip(id: String, startIndex: Int, endIndex: Int)
    case renameClip(id: String, title: String?)
    case setClipSelected(id: String, selected: Bool)
    case removeClip(id: String)
    case setPauseKeep(seconds: Double)
    case setPauseThreshold(seconds: Double)
}

/// Pure reducer entry point; editing §6.3. Placeholder preserves all edits.
public enum EditReducer {
    public static func reduce(_ state: EditState, command: EditCommand) -> EditState {
        // TODO(mac-editing)
        return state
    }
}

/// Snapshot history, capped at 500 operations; architecture §4.4 and editing §6.3.
public struct EditHistory: Sendable, Equatable {
    public private(set) var state: EditState
    public private(set) var undoStates: [EditState] = []
    public private(set) var redoStates: [EditState] = []
    public init(state: EditState) { self.state = state }
    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }
    public mutating func apply(_ command: EditCommand) {
        let next = EditReducer.reduce(state, command: command)
        guard next != state else { return }
        undoStates.append(state)
        if undoStates.count > 500 { undoStates.removeFirst() }
        redoStates.removeAll()
        state = next
    }
    public mutating func undo() {
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(state)
        state = previous
    }
    public mutating func redo() {
        guard let next = redoStates.popLast() else { return }
        undoStates.append(state)
        state = next
    }
}

/// Shared editing algorithm entry points; editing §5–7. Throwing skeleton operations never fabricate edits.
public func detectPauses(_ words: [TimedWord], thresholdSeconds: Double) throws -> [Pause] { throw VoxClipError.notImplemented("mac-editing") }
public func isFillerText(_ text: String) throws -> Bool { throw VoxClipError.notImplemented("mac-editing") }
public func refineWordBoundaries(_ words: [TimedWord], envelope: AudioEnvelope) throws -> [TimedWord] { throw VoxClipError.notImplemented("mac-editing") }
/// Attaches matching final-text punctuation without moving source times; editing §5.3.
public func alignTranscriptWords(_ words: [RawWord], finalText: String) throws -> [RawWord] { throw VoxClipError.notImplemented("mac-editing") }
/// Returns raw, unlabelled estimates within the supplied segment; editing §5.4. Not persisted as v1 TimedWord.
public func estimateTranscriptWords(_ text: String, start: Double, end: Double) throws -> [RawWord] { throw VoxClipError.notImplemented("mac-editing") }
public func buildSegments(_ state: EditState, activeClip: ClipRange?) throws -> [EditSegment] { throw VoxClipError.notImplemented("mac-editing") }
public func clipTimes(_ words: [TimedWord], startIndex: Int, endIndex: Int) throws -> TimeRange { throw VoxClipError.notImplemented("mac-editing") }
public func cutRange(_ segment: EditSegment, segments: [EditSegment], pauseKeepSeconds: Double) throws -> TimeRange { throw VoxClipError.notImplemented("mac-editing") }
public func buildEditPlan(_ segments: [EditSegment], duration: Double, sampleRate: Double, pauseKeepSeconds: Double = 0.15) throws -> EditPlan { throw VoxClipError.notImplemented("mac-editing") }
