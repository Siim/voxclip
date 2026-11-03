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
    public init(ordinal: Int, original: String, proposed: String, estimateSeconds: Double, slotSeconds: Double,
                direction: String, target: VoiceLabWordTarget, measuredSeconds: Double? = nil, calibrated: Bool = false) {
        self.ordinal = ordinal; self.original = original; self.proposed = proposed; self.estimateSeconds = estimateSeconds
        self.slotSeconds = slotSeconds; self.direction = direction; self.target = target
        self.measuredSeconds = measuredSeconds; self.calibrated = calibrated
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
