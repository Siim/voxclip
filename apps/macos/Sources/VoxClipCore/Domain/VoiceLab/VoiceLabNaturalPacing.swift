import Foundation

public struct VoiceLabPauseDistribution: Sendable, Equatable {
    public let p25: Double
    public let p75: Double
    public let p90: Double

    public init(seconds: [Double]) {
        let sorted = seconds.filter { $0.isFinite && $0 > 0 }.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        p25 = percentile(0.25); p75 = percentile(0.75); p90 = percentile(0.90)
    }

    /// No pause of this class was measured: every percentile is zero, so it bounds neither growth nor shrinking.
    public var isEmpty: Bool { p25 <= 0 }
}

public struct VoiceLabPauseProfile: Sendable, Equatable {
    public let withinSentence: VoiceLabPauseDistribution
    public let betweenSentences: VoiceLabPauseDistribution

    public init(withinSentence: [Double], betweenSentences: [Double]) {
        self.withinSentence = .init(seconds: withinSentence)
        self.betweenSentences = .init(seconds: betweenSentences)
    }

    public func distribution(after token: String) -> VoiceLabPauseDistribution {
        VoiceLabNaturalPacing.endsSentence(token) ? betweenSentences : withinSentence
    }

    public static func measure(items: [TimedWord], envelope: AudioEnvelope, start: Double, end: Double) -> Self {
        let words = items.filter { $0.kind == .word && $0.start >= start && $0.end <= end }
        var within: [Double] = [], between: [Double] = []
        guard words.count > 1 else { return .init(withinSentence: [], betweenSentences: []) }
        guard envelope.sampleRate.isFinite, envelope.sampleRate > 0 else {
            return .init(withinSentence: [], betweenSentences: [])
        }
        let size = VoiceLabGeometry.frameSize(envelope.sampleRate)
        for index in 0..<(words.count - 1) {
            let lower = max(0, Int(ceil(words[index].end * envelope.sampleRate / Double(size))))
            let upper = min(envelope.levels.count, Int(floor(words[index + 1].start * envelope.sampleRate / Double(size))))
            guard lower < upper else { continue }
            var longest = 0, run = 0
            for block in lower..<upper {
                run = Double(envelope.levels[block]) < VoiceLabPatchConstants.VOICED_FRAME_LEVEL ? run + 1 : 0
                longest = max(longest, run)
            }
            let seconds = Double(longest * Int(size)) / envelope.sampleRate
            if VoiceLabNaturalPacing.endsSentence(words[index].text) { between.append(seconds) }
            else { within.append(seconds) }
        }
        return .init(withinSentence: within, betweenSentences: between)
    }
}

public struct VoiceLabVideoCut: Codable, Sendable, Equatable {
    public let startSample: Int64
    public let endSample: Int64
    public init(startSample: Int64, endSample: Int64) {
        self.startSample = startSample; self.endSample = endSample
    }
}

public enum VoiceLabNaturalPacing {
    public static let NATURAL_PACE_MIN = 0.90
    public static let NATURAL_PACE_MAX = 1.10
    public static let CUT_EDGE_GUARD = 0.30
    public static let CUT_PUNCH_IN = 1.06
    public static let CUT_QUIET_RUN = 0.04

    public static func endsSentence(_ token: String) -> Bool {
        token.last.map { ".?!…。！？".contains($0) } ?? false
    }

    public static func clauseBoundary(after token: String, before next: String) -> Bool {
        (token.last.map { ",;:.?!，；：。！？".contains($0) } ?? false) ||
            ["and", "but", "so"].contains(next.lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    public static func fit(window: VoiceLabWindow, incomingSilence: Double?, outgoingSilence: Double?, take: VoiceLabFitTake,
                           sourceSampleRate: Int, hardJoinSmoothing: Bool, pauseProfile: VoiceLabPauseProfile,
                           audioTags: [VoiceLabAudioTag], sourceEnvelope: AudioEnvelope, items: [TimedWord]) throws -> VoiceLabFitResult {
        func plan(allowGrowth: Bool) throws -> VoiceLabFitResult {
            try VoiceLabFitPlanner.plan(window: window, incomingSilence: incomingSilence, outgoingSilence: outgoingSilence,
                take: take, tokens: take.words.map(\.text), sourceSampleRate: Double(sourceSampleRate),
                hardJoinSmoothing: hardJoinSmoothing, pauseProfile: pauseProfile, audioTags: audioTags, allowPauseGrowth: allowGrowth)
        }
        let fitted = try plan(allowGrowth: true)
        guard case .changedDuration = fitted else { return fitted }
        let spoken = try plan(allowGrowth: false)
        var cutPlan = spoken.plan
        // The same output the video-duration options and the recipe use, so a paid take's cut passes `validCuts`.
        let rounded = EditingPrimitives.jsRound(VoiceLabVideoDurationOptions.videoDuration(spoken) * Double(sourceSampleRate))
        guard rounded.isFinite, rounded > 0, rounded < Double(Int64.max) else { return fitted }
        cutPlan.videoCuts = cuts(windowStartSample: cutPlan.windowStartSample, windowEndSample: cutPlan.windowEndSample,
            outputSamples: Int64(rounded), sampleRate: sourceSampleRate, envelope: sourceEnvelope, items: items)
        guard !cutPlan.videoCuts.isEmpty else { return fitted }
        switch spoken {
        case .exact: return .exact(cutPlan)
        case .changedDuration(_, let natural, let residual): return .changedDuration(cutPlan, naturalOut: natural, residualSeconds: residual)
        }
    }

    public static func cuts(windowStartSample: Int64, windowEndSample: Int64, outputSamples: Int64,
                            sampleRate: Int, envelope: AudioEnvelope, items: [TimedWord]) -> [VoiceLabVideoCut] {
        guard sampleRate > 0, envelope.sampleRate == Double(sampleRate), outputSamples > 0,
              windowStartSample >= 0, windowEndSample > windowStartSample else { return [] }
        let needed = windowEndSample - windowStartSample - outputSamples
        let edge = VoiceLabGeometry.samples(CUT_EDGE_GUARD, Double(sampleRate))
        let lower = windowStartSample + edge, upper = windowEndSample - edge
        guard needed > 0, upper > lower, needed <= upper - lower else { return [] }
        let size = VoiceLabGeometry.frameSize(Double(sampleRate))
        let minimumRun = VoiceLabGeometry.samples(CUT_QUIET_RUN, Double(sampleRate))
        let reach = (minimumRun + size - 1) / size
        let first = max(0, lower / size - reach)
        let last = min(upper / size + reach + 1, Int64(envelope.levels.count))
        guard first < last else { return [] }
        let speech = items.filter { ($0.kind == .word || $0.kind == .unlabeledSpeech) && $0.end > Double(first * size) / Double(sampleRate) && $0.start < Double(last * size) / Double(sampleRate) }
        var eligible = [Bool](repeating: false, count: Int(last - first))
        var runStarts = [Int64](repeating: -1, count: Int(last - first))
        var start = first
        for block in first...last {
            let lo = block * size, hi = lo + size
            let quiet = block < last && Double(envelope.levels[Int(block)]) < VoiceLabPatchConstants.VOICED_FRAME_LEVEL &&
                !speech.contains { $0.start < Double(hi) / Double(sampleRate) && $0.end > Double(lo) / Double(sampleRate) }
            if !quiet {
                if (block - start) * size >= minimumRun {
                    for member in start..<block {
                        eligible[Int(member - first)] = true
                        runStarts[Int(member - first)] = start
                    }
                }
                start = block + 1
            }
        }
        func isEligible(_ block: Int64) -> Bool {
            block >= first && block < last && eligible[Int(block - first)]
        }
        func boundaryPower(_ sample: Int64, from startSample: Int64) -> Double? {
            guard sample >= lower, sample <= upper else { return nil }
            var block = sample / size
            if !isEligible(block) {
                let startBlock = startSample / size
                guard sample % size == 0, isEligible(block - 1), isEligible(startBlock),
                      runStarts[Int(startBlock - first)] == runStarts[Int(block - 1 - first)] else { return nil }
                block -= 1
            }
            let level = Double(envelope.levels[Int(block)])
            return level * level
        }
        let starts: [(sample: Int64, power: Double)] = (first..<last).compactMap { block in
            let sample = block * size
            guard isEligible(block), sample >= lower, sample < upper else { return nil }
            let level = Double(envelope.levels[Int(block)])
            return (sample, level * level)
        }
        var best: (power: Double, start: Int64)?
        for candidate in starts {
            if let endPower = boundaryPower(candidate.sample + needed, from: candidate.sample) {
                let scored = (candidate.power + endPower, candidate.sample)
                if best == nil || scored < best! { best = scored }
            }
        }
        if let best {
            return [.init(startSample: best.start, endSample: best.start + needed)]
        }
        let phases = needed % size == 0 ? [Int64(0)] : [0, needed % size]
        let endings = (first...last).flatMap { block in phases.map { block * size + $0 } }.sorted().compactMap { sample in
            boundaryPower(sample, from: sample - size).map { (sample: sample, power: $0) }
        }
        var endingIndex = 0
        var leftByLength: [Int64: (power: Double, start: Int64, end: Int64)] = [:]
        var bestTwo: (power: Double, firstStart: Int64, firstEnd: Int64, secondStart: Int64)?
        for right in starts {
            while endingIndex < endings.count && endings[endingIndex].sample < right.sample {
                let end = endings[endingIndex]
                for left in starts {
                    let count = end.sample - left.sample
                    if count <= 0 { break }
                    guard count < needed else { continue }
                    guard let endPower = boundaryPower(end.sample, from: left.sample) else { continue }
                    let scored = (left.power + endPower, left.sample, end.sample)
                    if leftByLength[count] == nil || scored < leftByLength[count]! { leftByLength[count] = scored }
                }
                endingIndex += 1
            }
            for (count, left) in leftByLength {
                guard let endPower = boundaryPower(right.sample + needed - count, from: right.sample) else { continue }
                let scored = (left.power + right.power + endPower, left.start, left.end, right.sample)
                if bestTwo == nil || scored < bestTwo! { bestTwo = scored }
            }
        }
        if let bestTwo {
            let remaining = needed - (bestTwo.firstEnd - bestTwo.firstStart)
            return [.init(startSample: bestTwo.firstStart, endSample: bestTwo.firstEnd),
                    .init(startSample: bestTwo.secondStart, endSample: bestTwo.secondStart + remaining)]
        }
        return []
    }

    public static func validCuts(_ video: VoiceLabVideoRecipe, sampleRate: Double) -> Bool {
        guard let cuts = video.cuts, (1...2).contains(cuts.count), sampleRate.isFinite, sampleRate > 0,
              video.outputSamples > 0, video.zoom == CUT_PUNCH_IN, video.faceX == 0.5, video.faceY == 0.5,
              video.retimeFactor == nil, video.assetId == nil, video.provider == nil, video.model == nil,
              video.requestId == nil, video.windowStartSample == nil, video.windowEndSample == nil, video.syncMode == nil else { return false }
        let edge = VoiceLabGeometry.samples(CUT_EDGE_GUARD, sampleRate)
        var cursor = video.sourceStartSample + edge, removed: Int64 = 0
        for cut in cuts {
            guard cut.startSample >= cursor, cut.endSample > cut.startSample,
                  cut.endSample <= video.sourceEndSample - edge else { return false }
            removed += cut.endSample - cut.startSample
            cursor = cut.endSample + 1
        }
        return video.sourceEndSample - video.sourceStartSample - removed == video.outputSamples
    }
}
