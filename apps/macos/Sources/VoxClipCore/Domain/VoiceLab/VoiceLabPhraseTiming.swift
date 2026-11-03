import Foundation

public struct VoiceLabPhraseTiming: Sendable, Equatable {
    public let estimateSeconds: Double
    public let slotSeconds: Double
    public let fits: Bool
    public var pace: Double = 1
    public var fitsWithVideoCut: Bool = false
    public var maximumSeconds: Double? = nil
    public var tooLong: Bool { estimateSeconds > (maximumSeconds ?? slotSeconds) }
    public var copy: String {
        let paceCopy = pace == 1 ? "" : " at \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), pace))× pace"
        return "≈ \(toFixed1(estimateSeconds)) s\(paceCopy) · slot \(toFixed1(slotSeconds)) s" +
            (fitsWithVideoCut ? " · fits with a video cut" : fits ? " · fits" : "")
    }
    public static let warning = "Too long for its slot. A take won't fit the video."
    public static let shortWarning = "Too short for its slot. A take won't fit the video."
    public static let providerSpeechRateMultiplier = 1.8

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
        var punctuationSeconds = 0.0
        var punctuationGroup = 0.0
        for character in text {
            let pause: Double
            if ".!?…。！？".contains(character) { pause = 0.22 }
            else if ",;:—–-，；：".contains(character) { pause = 0.12 }
            else { pause = 0 }
            if pause > 0 { punctuationGroup = max(punctuationGroup, pause) }
            else {
                punctuationSeconds += punctuationGroup
                punctuationGroup = 0
            }
        }
        punctuationSeconds += punctuationGroup
        let speech = Double(VoiceLabTextLength.length(text)) / (rate * providerSpeechRateMultiplier)
        let lead = speech + VoiceLabPatchConstants.TTS_TRIM_LEAD
        let trimmed = lead + VoiceLabPatchConstants.TTS_TRIM_TAIL
        let estimate = trimmed + punctuationSeconds
        guard estimate.isFinite, estimate > 0 else { throw VoiceLabLengthBudgetError.invalidInput }
        return estimate
    }

    public static func preview(seconds: Double, window: VoiceLabWindow, incomingSilence: Double?,
                               outgoingSilence: Double?, sourceSampleRate: Int, hardJoinSmoothing: Bool,
                               generatedText: String? = nil, pauseProfile: VoiceLabPauseProfile? = nil) throws -> VoiceLabFitResult {
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
                VoiceLabNaturalPacing.endsSentence(token) ? 0.22 :
                    VoiceLabNaturalPacing.clauseBoundary(after: token, before: "") ? 0.12 : 0.06
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
            take: take, tokens: words.map(\.text), sourceSampleRate: rate, hardJoinSmoothing: hardJoinSmoothing, pauseProfile: pauseProfile)
    }
}
