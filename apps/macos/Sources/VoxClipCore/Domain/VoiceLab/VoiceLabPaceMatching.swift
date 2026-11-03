import Foundation

public enum VoiceLabPaceMatching {
    public static func measure(text: String, rate: Double, window: VoiceLabWindow,
                               incomingSilence: Double?, outgoingSilence: Double?, sourceSampleRate: Int,
                               supportsPace: Bool = true, audioTags: [VoiceLabAudioTag] = [], modelID: String = "") throws -> VoiceLabPhraseTiming {
        try match(seconds: VoiceLabPhraseTiming.estimate(text: text, rate: rate) + VoiceLabAudioTags.allowance(audioTags, text: text, modelID: modelID), window: window,
            incomingSilence: incomingSilence, outgoingSilence: outgoingSilence,
            sourceSampleRate: sourceSampleRate, supportsPace: supportsPace)
    }

    public static func match(seconds: Double, oldPace: Double = 1, window: VoiceLabWindow,
                             incomingSilence: Double?, outgoingSilence: Double?, sourceSampleRate: Int,
                             supportsPace: Bool = true) throws -> VoiceLabPhraseTiming {
        guard seconds.isFinite, seconds > 0, VoiceLabPace.isValid(oldPace) else {
            throw VoiceLabLengthBudgetError.invalidInput
        }
        let rate = Double(sourceSampleRate)
        func options(_ duration: Double) throws -> VoiceLabVideoDurationOptions {
            let fit = try VoiceLabPhraseTiming.preview(seconds: duration, window: window,
                incomingSilence: incomingSilence, outgoingSilence: outgoingSilence, sourceSampleRate: sourceSampleRate)
            return VoiceLabVideoDurationOptions(fit: fit, sourceSampleRate: sourceSampleRate, assetSampleRate: sourceSampleRate)
        }
        let probeSeconds = 2 * (window.end - window.start + (incomingSilence ?? 0) + (outgoingSilence ?? 0) + 1)
        let high = try VoiceLabPhraseTiming.preview(seconds: probeSeconds, window: window,
            incomingSilence: incomingSilence, outgoingSilence: outgoingSilence, sourceSampleRate: sourceSampleRate).plan
        let low = try VoiceLabPhraseTiming.preview(seconds: 1 / rate, window: window,
            incomingSilence: incomingSilence, outgoingSilence: outgoingSilence, sourceSampleRate: sourceSampleRate).plan
        let source = Double(window.endSample - window.startSample) / rate
        let expanded = Double(high.windowEndSample - high.windowStartSample) / rate
        let edge = Double(high.incoming.padFrames + high.outgoing.padFrames) / rate
        let padding = Double(low.outputFrames - 1) / rate
        let exactLower = max(1 / rate, source - padding)
        let exactUpper = expanded - edge
        let retimeLower = max(1 / rate, source / VoiceLabVideoDurationOptions.retimeRange.upperBound - padding)
        let retimeUpper = expanded / VoiceLabVideoDurationOptions.retimeRange.lowerBound - edge
        let target = max(1 / rate, (exactLower + exactUpper) / 2)
        let natural = seconds * oldPace
        let minimum = supportsPace ? VoiceLabPace.minimum : 1
        let maximum = supportsPace ? VoiceLabPace.maximum : 1
        func pace(lower: Double, upper: Double) -> Double? {
            guard upper >= lower, upper > 0 else { return nil }
            let slowest = max(minimum, ceil(natural / upper * 100) / 100)
            let fastest = min(maximum, floor(natural / lower * 100) / 100)
            guard slowest <= fastest else { return nil }
            let ideal = (natural / target * 100).rounded(.toNearestOrAwayFromZero) / 100
            return min(fastest, max(slowest, ideal))
        }
        let fallback = supportsPace ? VoiceLabPace.clamp((natural / target * 100).rounded(.toNearestOrAwayFromZero) / 100) : 1
        var chosen = fallback
        if let exact = pace(lower: exactLower, upper: exactUpper), try options(natural / exact).allows(.source) {
            chosen = exact
        } else if let retimed = pace(lower: retimeLower, upper: retimeUpper), try options(natural / retimed).allows(.retimed) {
            chosen = retimed
        }
        let predicted = natural / chosen
        let gate = try options(predicted)
        return VoiceLabPhraseTiming(estimateSeconds: predicted, slotSeconds: max(0, retimeUpper),
            fits: gate.allows(.source) || gate.allows(.retimed), pace: chosen)
    }
}
