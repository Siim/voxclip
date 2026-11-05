import Foundation

public struct VoiceLabPhraseTiming: Sendable, Equatable {
    public let estimateSeconds: Double
    public let slotSeconds: Double
    public let fits: Bool
    public var pace: Double = 1
    public var fitsWithVideoCut: Bool = false
    public var maximumSeconds: Double? = nil
    public var minimumSeconds: Double? = nil
    public var tooLong: Bool { estimateSeconds > (maximumSeconds ?? slotSeconds) }
    public var copy: String {
        let paceCopy = pace == 1 ? "" : " at \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), pace))× pace"
        return "≈ \(toFixed1(estimateSeconds)) s\(paceCopy) · slot \(toFixed1(slotSeconds)) s" +
            (fitsWithVideoCut ? " · fits with a video cut" : fits ? " · fits" : "")
    }
    public static let warning = "Too long for its slot. A take won't fit the video."
    public static let shortWarning = "Too short for its slot. A take won't fit the video."
    /// The calibrated prior (ADR-R41): how many times the speaker's letters per voiced second a cloned take speaks.
    /// Observed on 78 real Eleven v4 takes: the provider speaks at about the speaker's own letter rate, plus a fixed onset.
    public static let providerSpeechRateMultiplier = 1.2
    /// Fixed per-take speech overhead beyond the trim allowance: the onset and decay a take always has.
    public static let onsetSeconds = 0.4
    /// A sentence-ending group followed by more speech; a final group adds nothing, the trim cuts after the last word.
    public static let sentencePauseSeconds = 0.5
    /// A comma, semicolon, colon or dash group followed by more speech.
    public static let clausePauseSeconds = 0.1
    /// The prior's generation. Ratios measured against an older prior are not comparable and are not read.
    public static let priorVersion = 2

    public static func speakingRate(transcript: [TimedWord]) throws -> Double {
        _ = try VoiceLabLengthBudget.rate(transcript: transcript)
        var seconds = 0.0
        var letters = 0
        var previousEnd = 0.0
        for word in transcript where word.kind == .word {
            letters += VoiceLabTextLength.length(word.text)
            seconds += max(0, word.end - max(word.start, previousEnd))
            previousEnd = max(previousEnd, word.end)
        }
        guard seconds > 0, letters > 0 else { throw VoiceLabLengthBudgetError.rateUnavailable }
        return Double(letters) / seconds
    }

    public static func estimate(text: String, rate: Double) throws -> Double {
        guard rate.isFinite, rate > 0 else { throw VoiceLabLengthBudgetError.invalidInput }
        let speech = Double(VoiceLabTextLength.length(text)) / (rate * providerSpeechRateMultiplier)
        let fixed = VoiceLabPatchConstants.TTS_TRIM_LEAD + VoiceLabPatchConstants.TTS_TRIM_TAIL + onsetSeconds
        let estimate = speech + fixed + pauseSeconds(text)
        guard estimate.isFinite, estimate > 0 else { throw VoiceLabLengthBudgetError.invalidInput }
        return estimate
    }

    /// The pauses inside `text`: each punctuation group counts once, at its largest pause, and only when more speech
    /// follows it. A hyphen between two letters or digits joins a word ("A-10") and is no pause.
    public static func pauseSeconds(_ text: String) -> Double {
        let characters = Array(EditingPrimitives.nfc(text))
        var total = 0.0, pending = 0.0
        for (index, character) in characters.enumerated() {
            if ".!?…。！？".contains(character) { pending = max(pending, sentencePauseSeconds) }
            else if ",;:—–，；：".contains(character) { pending = max(pending, clausePauseSeconds) }
            else if character == "-" {
                let joined = index > 0 && index + 1 < characters.count && counts(characters[index - 1]) && counts(characters[index + 1])
                if !joined { pending = max(pending, clausePauseSeconds) }
            } else if counts(character) {
                total += pending
                pending = 0
            }
        }
        return total
    }

    private static func counts(_ character: Character) -> Bool { VoiceLabTextLength.length(String(character)) > 0 }

    public static func preview(seconds: Double, window: VoiceLabWindow, incomingSilence: Double?,
                               outgoingSilence: Double?, sourceSampleRate: Int, hardJoinSmoothing: Bool,
                               generatedText: String? = nil, pauseProfile: VoiceLabPauseProfile? = nil,
                               audioTags: [VoiceLabAudioTag] = [], allowPauseGrowth: Bool = true) throws -> VoiceLabFitResult {
        guard seconds.isFinite, seconds > 0, seconds <= 3_600, sourceSampleRate > 0,
              sourceSampleRate <= 1_000_000 else { throw VoiceLabLengthBudgetError.invalidInput }
        let rate = Double(sourceSampleRate)
        let frames = Int64(EditingPrimitives.jsRound(seconds * rate))
        guard frames > 0, frames < 1 << 31 else { throw VoiceLabLengthBudgetError.invalidInput }
        let duration = Double(frames) / rate
        let wordEnd = duration * rate > Double(frames) ? duration.nextDown : duration
        let size = VoiceLabGeometry.frameSize(rate)
        var words = [VoiceLabWord(text: "speech", start: 0, end: wordEnd, synthetic: true)]
        let tokens = generatedText?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        if tokens.count > 1, pauseProfile != nil {
            let gaps = tokens.dropLast().map { token -> Double in
                VoiceLabNaturalPacing.endsSentence(token) ? sentencePauseSeconds :
                    VoiceLabNaturalPacing.clauseBoundary(after: token, before: "") ? clausePauseSeconds : 0.06
            }
            let gapTotal = gaps.reduce(0, +)
            let speech = wordEnd - gapTotal
            if speech > Double(tokens.count) / rate {
                let letters = tokens.map { max(1, VoiceLabTextLength.length($0)) }
                let count = letters.reduce(0, +)
                var cursor = 0.0
                words = tokens.indices.map { index in
                    let end = index == tokens.count - 1 ? wordEnd : cursor + speech * Double(letters[index]) / Double(count)
                    let word = VoiceLabWord(text: tokens[index], start: cursor, end: end, synthetic: true)
                    cursor = end + (index < gaps.count ? gaps[index] : 0)
                    return word
                }
            }
        }
        let levels = (0..<Int(frames / size)).map { block -> Float in
            let start = Double(Int64(block) * size) / rate, end = Double(Int64(block + 1) * size) / rate
            return words.contains { $0.start < end && $0.end > start } ? 1 : 0
        }
        let envelope = AudioEnvelope(sampleRate: rate, levels: levels)
        let take = VoiceLabFitTake(assetFrames: frames, assetSampleRate: sourceSampleRate, trimStart: 0, trimEnd: duration,
            words: words, envelope: envelope)
        return try VoiceLabFitPlanner.plan(window: window, incomingSilence: incomingSilence, outgoingSilence: outgoingSilence,
            take: take, tokens: words.map(\.text), sourceSampleRate: rate, hardJoinSmoothing: hardJoinSmoothing,
            pauseProfile: pauseProfile, audioTags: audioTags, allowPauseGrowth: allowPauseGrowth)
    }
}
