import Foundation

public enum VoiceLabPaceMatching {
    public static func measure(text: String, rate: Double, window: VoiceLabWindow,
                               incomingSilence: Double?, outgoingSilence: Double?, sourceSampleRate: Int,
                               supportsPace: Bool = true, hardJoinSmoothing: Bool,
                               sourceItems: [TimedWord] = [], sourceEnvelope: AudioEnvelope? = nil) throws -> VoiceLabPhraseTiming {
        try match(seconds: VoiceLabPhraseTiming.estimate(text: text, rate: rate), window: window,
            incomingSilence: incomingSilence, outgoingSilence: outgoingSilence,
            sourceSampleRate: sourceSampleRate, supportsPace: supportsPace, hardJoinSmoothing: hardJoinSmoothing,
            sourceItems: sourceItems, sourceEnvelope: sourceEnvelope, generatedText: text)
    }

    public static func match(seconds: Double, oldPace: Double = 1, window: VoiceLabWindow,
                             incomingSilence: Double?, outgoingSilence: Double?, sourceSampleRate: Int,
                             supportsPace: Bool = true, hardJoinSmoothing: Bool,
                             sourceItems: [TimedWord] = [], sourceEnvelope: AudioEnvelope? = nil,
                             generatedText: String? = nil, pauseProfile: VoiceLabPauseProfile? = nil) throws -> VoiceLabPhraseTiming {
        guard seconds.isFinite, seconds > 0, VoiceLabPace.isValid(oldPace) else {
            throw VoiceLabLengthBudgetError.invalidInput
        }
        let rate = Double(sourceSampleRate)
        let profile = pauseProfile ?? sourceEnvelope.map { VoiceLabPauseProfile.measure(items: sourceItems, envelope: $0, start: 0, end: .greatestFiniteMagnitude) }
        func fit(_ duration: Double) throws -> VoiceLabFitResult {
            try VoiceLabPhraseTiming.preview(seconds: duration, window: window,
                incomingSilence: incomingSilence, outgoingSilence: outgoingSilence, sourceSampleRate: sourceSampleRate,
                hardJoinSmoothing: hardJoinSmoothing, generatedText: generatedText, pauseProfile: profile)
        }
        func options(_ duration: Double) throws -> VoiceLabVideoDurationOptions {
            VoiceLabVideoDurationOptions(fit: try fit(duration), sourceSampleRate: sourceSampleRate, assetSampleRate: sourceSampleRate)
        }
        let probeSeconds = 2 * (window.end - window.start + (incomingSilence ?? 0) + (outgoingSilence ?? 0) + 1)
        let high = try VoiceLabPhraseTiming.preview(seconds: probeSeconds, window: window,
            incomingSilence: incomingSilence, outgoingSilence: outgoingSilence, sourceSampleRate: sourceSampleRate, hardJoinSmoothing: hardJoinSmoothing).plan
        let low = try VoiceLabPhraseTiming.preview(seconds: 1 / rate, window: window,
            incomingSilence: incomingSilence, outgoingSilence: outgoingSilence, sourceSampleRate: sourceSampleRate, hardJoinSmoothing: hardJoinSmoothing).plan
        let source = Double(window.endSample - window.startSample) / rate
        let expanded = Double(high.windowEndSample - high.windowStartSample) / rate
        let edge = Double(high.incoming.padFrames + high.outgoing.padFrames) / rate
        let padding = Double(low.outputFrames - 1) / rate
        let exactLower = max(1 / rate, source - padding)
        let exactUpper = expanded - edge
        let retimeUpper = expanded / VoiceLabVideoDurationOptions.retimeRange.lowerBound - edge
        let natural = seconds * oldPace
        let minimum = supportsPace ? VoiceLabNaturalPacing.NATURAL_PACE_MIN : 1
        let maximum = supportsPace ? VoiceLabNaturalPacing.NATURAL_PACE_MAX : 1
        func pace(lower: Double, upper: Double) -> Double? {
            guard upper >= lower, upper > 0 else { return nil }
            let slowest = max(minimum, ceil(natural / upper * 100) / 100)
            let fastest = min(maximum, floor(natural / lower * 100) / 100)
            guard slowest <= fastest else { return nil }
            return min(fastest, max(slowest, 1))
        }
        var chosen = 1.0
        if profile != nil, !(try options(natural).allows(.source)), supportsPace {
            let candidates: [Double] = (90...110).map { Double($0) / 100 }
            let grid: [Double] = candidates.sorted { left, right in
                let leftDistance: Double = abs(left - 1)
                let rightDistance: Double = abs(right - 1)
                return leftDistance == rightDistance ? left < right : leftDistance < rightDistance
            }
            for candidate in grid where try options(natural / candidate).allows(.source) { chosen = candidate; break }
        } else if !(try options(natural).allows(.source)), let exact = pace(lower: exactLower, upper: exactUpper),
           try options(natural / exact).allows(.source) {
            chosen = exact
        }
        let predicted = natural / chosen
        let gate = try options(predicted)
        let preview = try fit(predicted).plan
        let cuts = sourceEnvelope.map {
            VoiceLabNaturalPacing.cuts(windowStartSample: preview.windowStartSample, windowEndSample: preview.windowEndSample,
                outputSamples: preview.outputFrames, sampleRate: sourceSampleRate, envelope: $0, items: sourceItems)
        } ?? []
        return VoiceLabPhraseTiming(estimateSeconds: predicted, slotSeconds: source,
            fits: gate.allows(.source) || gate.allows(.retimed) || !cuts.isEmpty, pace: chosen,
            fitsWithVideoCut: !gate.allows(.source) && !cuts.isEmpty, maximumSeconds: max(0, retimeUpper))
    }
}
