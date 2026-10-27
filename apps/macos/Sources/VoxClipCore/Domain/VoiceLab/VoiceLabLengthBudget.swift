import Foundation

public enum VoiceLabLengthBudgetError: Error, Equatable, Sendable { case invalidInput, rateUnavailable }
public enum VoiceLabSpeechRateSource: String, Sendable { case transcript, candidates }
public struct VoiceLabRateCandidate: Sendable, Equatable {
    public let text: String
    public let firstCharStart: Double
    public let lastCharEnd: Double
    public init(text: String, firstCharStart: Double, lastCharEnd: Double) {
        self.text = text; self.firstCharStart = firstCharStart; self.lastCharEnd = lastCharEnd
    }
}
public struct VoiceLabSpeechRate: Sendable, Equatable {
    public let charactersPerSecond: Double
    public let source: VoiceLabSpeechRateSource
    public let textLength: Int
    public let voicedSeconds: Double
}
public struct VoiceLabLengthRange: Sendable, Equatable {
    public let targetSeconds: Double
    public let edgePadSeconds: Double
    public let bridgeLength: Int
    public let minChars: Int
    public let maxChars: Int
    public let advisory: Bool
}

public enum VoiceLabLengthBudget {
    public static func rate(transcript: [TimedWord], pauseThresholdSeconds: Double = 1,
                            candidates: [VoiceLabRateCandidate] = []) throws -> VoiceLabSpeechRate {
        var length: Int = 0
        var seconds: Double = 0
        if !candidates.isEmpty {
            for candidate in candidates {
                guard candidate.firstCharStart.isFinite, candidate.lastCharEnd.isFinite,
                      candidate.firstCharStart >= 0, candidate.lastCharEnd > candidate.firstCharStart else {
                    throw VoiceLabLengthBudgetError.invalidInput
                }
                length += VoiceLabTextLength.length(candidate.text)
                seconds += candidate.lastCharEnd - candidate.firstCharStart
            }
        } else {
            try validate(transcript)
            guard pauseThresholdSeconds.isFinite, pauseThresholdSeconds > 0 else { throw VoiceLabLengthBudgetError.invalidInput }
            let pauses: [Pause] = try detectPauses(transcript, thresholdSeconds: pauseThresholdSeconds)
            let breaks: Set<Int> = Set(pauses.map(\.afterIndex))
            var spanStart: Double?
            var spanEnd: Double = 0
            for (index, word) in transcript.enumerated() {
                if word.kind != .word || (index > 0 && breaks.contains(index - 1)) {
                    if let start = spanStart { seconds += spanEnd - start }
                    spanStart = nil
                }
                if word.kind == .word {
                    length += VoiceLabTextLength.length(word.text)
                    if spanStart == nil { spanStart = word.start }
                    spanEnd = word.end
                }
            }
            if let start = spanStart { seconds += spanEnd - start }
        }
        guard length > 0, seconds.isFinite, seconds > 0 else { throw VoiceLabLengthBudgetError.rateUnavailable }
        let characters: Double = Double(length)
        let value: Double = characters / seconds
        guard value.isFinite, value > 0 else { throw VoiceLabLengthBudgetError.rateUnavailable }
        return VoiceLabSpeechRate(charactersPerSecond: value, source: candidates.isEmpty ? .transcript : .candidates,
                                  textLength: length, voicedSeconds: seconds)
    }

    public static func estimate(text: String, rate: Double) throws -> Double {
        guard rate.isFinite, rate > 0 else { throw VoiceLabLengthBudgetError.invalidInput }
        let length: Double = Double(VoiceLabTextLength.length(text))
        let speech: Double = length / rate
        let lead: Double = speech + VoiceLabPatchConstants.TTS_TRIM_LEAD
        let result: Double = lead + VoiceLabPatchConstants.TTS_TRIM_TAIL
        guard result.isFinite else { throw VoiceLabLengthBudgetError.invalidInput }
        return result
    }

    public static func calculate(window: VoiceLabWindow, incomingSilence: Double?, outgoingSilence: Double?,
                                 bridgeLength: Int, rate: Double) throws -> VoiceLabLengthRange {
        let geometry = try geometry(window: window, incomingSilence: incomingSilence, outgoingSilence: outgoingSilence)
        return try range(target: geometry.target, edge: geometry.edge, bridge: bridgeLength, rate: rate, advisory: false)
    }

    public static func passage(window: VoiceLabWindow, transcript: [TimedWord], incomingSilence: Double?,
                               outgoingSilence: Double?, rate: Double) throws -> VoiceLabLengthRange {
        let ids: [String] = window.leftBridgeWordIds + window.rightBridgeWordIds
        var bridge: Int = 0
        var seen: Set<String> = []
        for id in ids {
            guard seen.insert(id).inserted, let word = transcript.first(where: { $0.id == id && $0.kind == .word }) else {
                throw VoiceLabLengthBudgetError.invalidInput
            }
            bridge += VoiceLabTextLength.length(word.text)
        }
        return try calculate(window: window, incomingSilence: incomingSilence, outgoingSilence: outgoingSilence,
                             bridgeLength: bridge, rate: rate)
    }

    public static func fullTake(transcript: [TimedWord], rate: Double) throws -> VoiceLabLengthRange {
        try validate(transcript)
        let words: [TimedWord] = transcript.filter { $0.kind == .word }
        guard let first = words.first, let last = words.last else { throw VoiceLabLengthBudgetError.invalidInput }
        let target: Double = last.end - first.start
        return try range(target: target, edge: 0, bridge: 0, rate: rate, advisory: true)
    }

    static func geometry(window: VoiceLabWindow, incomingSilence: Double?, outgoingSilence: Double?) throws -> (target: Double, edge: Double) {
        guard window.start.isFinite, window.end.isFinite, window.start >= 0, window.end > window.start else {
            throw VoiceLabLengthBudgetError.invalidInput
        }
        let kinds: [VoiceLabSeamKind] = [window.leftSeam.kind, window.rightSeam.kind]
        let silences: [Double?] = [incomingSilence, outgoingSilence]
        for index in kinds.indices {
            guard kinds[index] != .synthToSynth else { throw VoiceLabLengthBudgetError.invalidInput }
            if kinds[index] == .hard {
                guard silences[index] == nil else { throw VoiceLabLengthBudgetError.invalidInput }
            } else {
                guard let silence = silences[index], silence.isFinite, silence >= 0 else { throw VoiceLabLengthBudgetError.invalidInput }
            }
        }
        let incoming: Double = kinds[0] == .none ? max(0, incomingSilence! - VoiceLabPatchConstants.TTS_TRIM_LEAD) : 0
        let outgoing: Double = kinds[1] == .none ? max(0, outgoingSilence! - VoiceLabPatchConstants.TTS_TRIM_TAIL) : 0
        let edge: Double = incoming + outgoing
        let duration: Double = window.end - window.start
        let target: Double = duration - edge
        guard target.isFinite, target > 0 else { throw VoiceLabLengthBudgetError.invalidInput }
        return (target, edge)
    }

    private static func range(target: Double, edge: Double, bridge: Int, rate: Double, advisory: Bool) throws -> VoiceLabLengthRange {
        guard target.isFinite, target > 0, rate.isFinite, rate > 0, bridge >= 0 else { throw VoiceLabLengthBudgetError.invalidInput }
        let lowAim: Double = VoiceLabPatchConstants.LENGTH_AIM_MIN * target
        let lowLead: Double = lowAim - VoiceLabPatchConstants.TTS_TRIM_LEAD
        let lowTail: Double = lowLead - VoiceLabPatchConstants.TTS_TRIM_TAIL
        let lowScaled: Double = lowTail * rate
        let highAim: Double = VoiceLabPatchConstants.LENGTH_AIM_MAX * target
        let highLead: Double = highAim - VoiceLabPatchConstants.TTS_TRIM_LEAD
        let highTail: Double = highLead - VoiceLabPatchConstants.TTS_TRIM_TAIL
        let highScaled: Double = highTail * rate
        let bridgeCount: Double = Double(bridge)
        let minimum: Double = max(1, floor(lowScaled) - bridgeCount)
        let maximum: Double = max(minimum, ceil(highScaled) - bridgeCount)
        guard minimum.isFinite, maximum.isFinite, maximum <= Double(Int32.max) else { throw VoiceLabLengthBudgetError.invalidInput }
        return VoiceLabLengthRange(targetSeconds: target, edgePadSeconds: edge, bridgeLength: bridge,
                                   minChars: Int(minimum), maxChars: Int(maximum), advisory: advisory)
    }

    private static func validate(_ transcript: [TimedWord]) throws {
        var previous: Double = 0
        for word in transcript {
            guard word.start.isFinite, word.end.isFinite, word.start >= previous, word.end >= word.start else {
                throw VoiceLabLengthBudgetError.invalidInput
            }
            previous = word.start
        }
    }
}
