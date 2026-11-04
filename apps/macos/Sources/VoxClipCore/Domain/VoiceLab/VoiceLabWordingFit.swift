import Foundation

public struct VoiceLabRateSample: Codable, Sendable, Equatable {
    public let id: String
    public let ratio: Double
    public init(id: String, ratio: Double) { self.id = id; self.ratio = ratio }
}

public struct VoiceLabWordTarget: Codable, Sendable, Equatable {
    public let minimum: Int
    public let maximum: Int
}

public enum VoiceLabWordingFit {
    public static let modelID = "eleven_v4"
    public static let maximumRounds = 3

    public static func multiplier(_ samples: [VoiceLabRateSample]) -> Double {
        let ratios = samples.filter { $0.ratio.isFinite && $0.ratio > 0 }.suffix(10).map(\.ratio).sorted()
        guard ratios.count >= 2 else { return 1 }
        let middle = ratios.count / 2
        return ratios.count.isMultiple(of: 2) ? ratios[middle - 1] / 2 + ratios[middle] / 2 : ratios[middle]
    }

    public static func recording(_ samples: [VoiceLabRateSample], id: String, measured: Double,
                                 estimated: Double) -> [VoiceLabRateSample] {
        guard measured.isFinite, estimated.isFinite, measured > 0, estimated > 0,
              (measured / estimated).isFinite, measured / estimated > 0, !samples.contains(where: { $0.id == id }) else { return samples }
        return Array((samples + [.init(id: id, ratio: measured / estimated)]).suffix(10))
    }

    public static func wordTarget(wordsPerSecond: Double, multiplier: Double, minimumSeconds: Double,
                                  maximumSeconds: Double, overheadSeconds: Double, bridgeWords: Int = 0) throws -> VoiceLabWordTarget {
        guard [wordsPerSecond, multiplier, minimumSeconds, maximumSeconds, overheadSeconds].allSatisfy(\.isFinite),
              wordsPerSecond > 0, multiplier > 0, minimumSeconds >= 0, maximumSeconds >= minimumSeconds,
              overheadSeconds >= 0, bridgeWords >= 0 else { throw VoiceLabLengthBudgetError.invalidInput }
        let rate = wordsPerSecond * VoiceLabPhraseTiming.providerSpeechRateMultiplier / multiplier
        let lower = max(0, minimumSeconds - overheadSeconds) * rate - Double(bridgeWords)
        let upper = max(0, maximumSeconds - overheadSeconds) * rate - Double(bridgeWords)
        guard lower.isFinite, upper.isFinite else { throw VoiceLabLengthBudgetError.invalidInput }
        let minimum = max(1, Int(max(0, min(2_000, ceil(lower)))))
        let maximum = max(minimum, min(2_000, Int(max(0, min(2_000, floor(upper))))))
        return VoiceLabWordTarget(minimum: minimum, maximum: maximum)
    }

    public static func nextOrdinals(roundsCompleted: Int, candidates: [Int], fitting: Set<Int>,
                                    kept: Set<Int>, stopped: Bool) -> [Int] {
        guard !stopped, roundsCompleted < maximumRounds else { return [] }
        return Array(Set(candidates).subtracting(fitting).subtracting(kept)).sorted()
    }

    public static func reword(_ hunk: VoiceLabDiffHunk, text: String, tags: [VoiceLabAudioTag]) -> VoiceLabDiffHunk {
        var result = VoiceLabDiffHunk(kind: hunk.kind, sourceWordIds: hunk.sourceWordIds,
            newTokens: EditingPrimitives.splitWords(text), correctedTexts: hunk.correctedTexts,
            absorbedItemIds: hunk.absorbedItemIds, bridgeWordIds: hunk.bridgeWordIds,
            sourceStartIndex: hunk.sourceStartIndex, sourceEndIndex: hunk.sourceEndIndex, anchorSeconds: hunk.anchorSeconds)
        result.audioTags = tags
        return result
    }
}

public struct VoiceLabFitPhrase: Codable, Sendable, Equatable {
    public let ordinal: Int
    public let original: String
    public let proposed: String
    public let estimateSeconds: Double
    public let slotSeconds: Double
    public let direction: String
    public let target: VoiceLabWordTarget
    public let measuredSeconds: Double?
    public let calibrated: Bool
    /// The wordings already tried for this phrase with their measured results (voice-lab §8.2.2); nil encodes as absent.
    public var tried: [VoiceLabFitTried]?
    /// The bridge words the reworded phrase must keep (voice-lab §8.2.2); nil encodes as absent.
    public var bridge: VoiceLabFitBridge?
    public init(ordinal: Int, original: String, proposed: String, estimateSeconds: Double, slotSeconds: Double,
                direction: String, target: VoiceLabWordTarget, measuredSeconds: Double? = nil, calibrated: Bool = false,
                tried: [VoiceLabFitTried]? = nil, bridge: VoiceLabFitBridge? = nil) {
        self.ordinal = ordinal; self.original = original; self.proposed = proposed; self.estimateSeconds = estimateSeconds
        self.slotSeconds = slotSeconds; self.direction = direction; self.target = target
        self.measuredSeconds = measuredSeconds; self.calibrated = calibrated; self.tried = tried; self.bridge = bridge
    }
}

/// The unchanged words that join a reworded phrase to the recording around it (voice-lab §8.2.2, §8.4). A measured
/// round rewords the whole phrase, these words included; a reply without them can't be placed or priced, so the
/// request names them and the reply is checked before it counts as a round.
public struct VoiceLabFitBridge: Codable, Sendable, Equatable {
    public let leading: [String]
    public let trailing: [String]
    public init(leading: [String], trailing: [String]) { self.leading = leading; self.trailing = trailing }
    /// The take input's bridge words; nil when its window has none.
    public init?(input: VoiceLabTakeInput) throws {
        let words = try VoiceLabTakeProcessing.bridgeWords(input)
        guard !words.leading.isEmpty || !words.trailing.isEmpty else { return nil }
        self.init(leading: words.leading, trailing: words.trailing)
    }
    /// Whether a reworded phrase keeps them, as the take's preflight checks it.
    public func keeps(_ text: String) -> Bool { VoiceLabTakeProcessing.keepsBridgeWords(text, bridge: (leading, trailing)) }
    /// The words for a person: "I use … as".
    public var display: String { [leading.joined(separator: " "), trailing.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " … ") }
    /// The line that requires them, from the shared template (`voice-rewrite-tried.json` `bridge`).
    public func line(shared: SharedResources) throws -> (text: String, sha256: String) {
        let prompt = try VoiceLabLLMChecks.readPrompt(shared, "prompts/voice-rewrite-tried.json")
        let key = leading.isEmpty ? "trailing" : trailing.isEmpty ? "leading" : "both"
        guard prompt.document[ai: "schemaVersion"].aiInt == 1, let template = prompt.document[ai: "bridge"][ai: key].aiString else {
            throw VoxClipError.sharedResourcesMissing
        }
        let text = template.replacingOccurrences(of: "{leading}", with: leading.joined(separator: " "))
            .replacingOccurrences(of: "{trailing}", with: trailing.joined(separator: " "))
        return (text, prompt.sha256)
    }
}

/// One wording a stuck phrase already had, and what came of it: the fix loop's memory (voice-lab §8.2.2).
public struct VoiceLabFitTried: Codable, Sendable, Equatable {
    /// `tooLong`, `tooShort`, `words`, `fit`, `repeat`, `notShorter`, `notLonger`, `missingBridge` or `unchecked`
    /// (`shared/prompts/voice-rewrite-tried.json` `results`).
    public let text: String
    public let result: String
    public let seconds: Double?
    public init(text: String, result: String, seconds: Double? = nil) { self.text = text; self.result = result; self.seconds = seconds }

    /// Case-, punctuation- and spacing-blind identity of a wording: two wordings with one key are one variant.
    public static func key(_ text: String) -> String {
        EditingPrimitives.splitWords(VoiceLabAudioTags.strippingTags(text))
            .map { EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// The history block sent with every reworded round, from the shared template; nil when nothing was tried.
    public static func block(_ tried: [VoiceLabFitTried], shared: SharedResources) throws -> (text: String, sha256: String)? {
        guard !tried.isEmpty else { return nil }
        let prompt = try VoiceLabLLMChecks.readPrompt(shared, "prompts/voice-rewrite-tried.json")
        let document = prompt.document
        guard document[ai: "schemaVersion"].aiInt == 1, let header = document[ai: "header"].aiString,
              let line = document[ai: "line"].aiString else { throw VoxClipError.sharedResourcesMissing }
        let lines = try tried.prefix(12).map { row -> String in
            guard let template = document[ai: "results"][ai: row.result].aiString else { throw VoxClipError.sharedResourcesMissing }
            let result = template.replacingOccurrences(of: "{seconds}", with: row.seconds.map(toFixed1) ?? "?")
            let text = row.text.count > 400 ? String(row.text.prefix(399)) + "…" : row.text
            return line.replacingOccurrences(of: "{text}", with: text).replacingOccurrences(of: "{result}", with: result)
        }
        return (([header] + lines).joined(separator: "\n"), prompt.sha256)
    }
}

public struct VoiceLabFitUpdate: Sendable, Equatable {
    public let ordinal: Int
    public let keepOriginal: Bool
    public let text: String
    public let audioTags: [VoiceLabAudioTag]
    public init(ordinal: Int, keepOriginal: Bool, text: String, audioTags: [VoiceLabAudioTag] = []) {
        self.ordinal = ordinal; self.keepOriginal = keepOriginal; self.text = text; self.audioTags = audioTags
    }
}
