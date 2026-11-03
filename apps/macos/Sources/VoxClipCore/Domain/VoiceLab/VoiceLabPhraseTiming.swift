import Foundation

public struct VoiceLabPhraseTiming: Sendable, Equatable {
    public let estimateSeconds: Double
    public let slotSeconds: Double
    public let fits: Bool
    public var tooLong: Bool { estimateSeconds > slotSeconds }
    public var copy: String {
        "≈ \(toFixed1(estimateSeconds)) s · slot \(toFixed1(slotSeconds)) s" + (fits ? " · fits" : "")
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

    public static func measure(text: String, rate: Double, window: VoiceLabWindow,
                               incomingSilence: Double?, outgoingSilence: Double?, sourceSampleRate: Int) throws -> Self {
        let estimate = try estimate(text: text, rate: rate)
        let probeDuration = 2 * (window.end - window.start + (incomingSilence ?? 0) + (outgoingSilence ?? 0) + 1)
        let probe = try preview(seconds: probeDuration, window: window, incomingSilence: incomingSilence,
                                outgoingSilence: outgoingSilence, sourceSampleRate: sourceSampleRate)
        let plan = probe.plan
        let expandedWindow = Double(plan.windowEndSample - plan.windowStartSample) / Double(sourceSampleRate)
        let edgePadding = Double(plan.incoming.padFrames + plan.outgoing.padFrames) / Double(sourceSampleRate)
        let slot = expandedWindow / VoiceLabVideoDurationOptions.retimeRange.lowerBound - edgePadding
        let fit = try preview(seconds: estimate, window: window, incomingSilence: incomingSilence,
                              outgoingSilence: outgoingSilence, sourceSampleRate: sourceSampleRate)
        let options = VoiceLabVideoDurationOptions(fit: fit, sourceSampleRate: sourceSampleRate, assetSampleRate: sourceSampleRate)
        return Self(estimateSeconds: estimate, slotSeconds: max(0, slot), fits: options.allows(.source) || options.allows(.retimed))
    }

    public static func preview(seconds: Double, window: VoiceLabWindow, incomingSilence: Double?,
                               outgoingSilence: Double?, sourceSampleRate: Int) throws -> VoiceLabFitResult {
        guard seconds.isFinite, seconds > 0, seconds <= 3_600, sourceSampleRate > 0,
              sourceSampleRate <= 1_000_000 else { throw VoiceLabLengthBudgetError.invalidInput }
        let rate = Double(sourceSampleRate)
        let frames = Int64(EditingPrimitives.jsRound(seconds * rate))
        guard frames > 0, frames < 1 << 31 else { throw VoiceLabLengthBudgetError.invalidInput }
        let duration = Double(frames) / rate
        let wordEnd = duration * rate > Double(frames) ? duration.nextDown : duration
        let size = VoiceLabGeometry.frameSize(rate)
        let envelope = AudioEnvelope(sampleRate: rate, levels: [Float](repeating: 1, count: Int(frames / size)))
        let take = VoiceLabFitTake(assetFrames: frames, assetSampleRate: sourceSampleRate, trimStart: 0, trimEnd: duration,
            words: [VoiceLabWord(text: "speech", start: 0, end: wordEnd, synthetic: true)], envelope: envelope)
        return try VoiceLabFitPlanner.plan(window: window, incomingSilence: incomingSilence, outgoingSilence: outgoingSilence,
                                           take: take, tokens: ["speech"], sourceSampleRate: rate)
    }
}
