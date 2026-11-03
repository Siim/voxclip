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

    public static func endsSentence(_ token: String) -> Bool {
        token.last.map { ".?!…。！？".contains($0) } ?? false
    }

    public static func clauseBoundary(after token: String, before next: String) -> Bool {
        (token.last.map { ",;:.?!，；：。！？".contains($0) } ?? false) ||
            ["and", "but", "so"].contains(next.lowercased().trimmingCharacters(in: .punctuationCharacters))
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
        let first = (lower + size - 1) / size
        let last = min(upper / size, Int64(envelope.levels.count))
        guard first < last else { return [] }
        let speech = items.filter { ($0.kind == .word || $0.kind == .unlabeledSpeech) && $0.end > Double(lower) / Double(sampleRate) && $0.start < Double(upper) / Double(sampleRate) }
        var runs: [(start: Int64, end: Int64, power: Double)] = []
        var start = first, power = 0.0
        for block in first...last {
            let lo = block * size, hi = lo + size
            let quiet = block < last && Double(envelope.levels[Int(block)]) < VoiceLabPatchConstants.VOICED_FRAME_LEVEL &&
                !speech.contains { $0.start < Double(hi) / Double(sampleRate) && $0.end > Double(lo) / Double(sampleRate) }
            if quiet {
                let level = Double(envelope.levels[Int(block)])
                power += level * level
            } else {
                if block > start { runs.append((start * size, lo, power / Double(block - start))) }
                start = block + 1; power = 0
            }
        }
        let ranked = runs.sorted { $0.power == $1.power ? $0.start < $1.start : $0.power < $1.power }
        var prefix = [Double](repeating: 0, count: envelope.levels.count + 1)
        for index in envelope.levels.indices {
            let level = Double(envelope.levels[index])
            prefix[index + 1] = prefix[index] + level * level * Double(size)
        }
        func energy(to sample: Int64) -> Double {
            let block = Int(sample / size)
            guard block < envelope.levels.count else { return prefix.last! }
            let level = Double(envelope.levels[block])
            return prefix[block] + level * level * Double(sample % size)
        }
        var best: (start: Int64, power: Double)?
        for run in runs where run.end - run.start >= needed {
            var candidates = Array(stride(from: run.start, through: run.end - needed, by: Int(size)))
            candidates.append(run.end - needed)
            for candidate in candidates {
                let power = energy(to: candidate + needed) - energy(to: candidate)
                if best == nil || power < best!.power - 1e-12 || (abs(power - best!.power) <= 1e-12 && candidate < best!.start) {
                    best = (candidate, power)
                }
            }
        }
        if let best {
            return [.init(startSample: best.start, endSample: best.start + needed)]
        }
        for firstIndex in ranked.indices {
            for secondIndex in ranked.indices where secondIndex > firstIndex {
                let left = ranked[firstIndex], right = ranked[secondIndex]
                guard left.end - left.start + right.end - right.start >= needed else { continue }
                let firstCount = min(left.end - left.start, needed / 2)
                let secondCount = min(right.end - right.start, needed - firstCount)
                let finalFirst = needed - secondCount
                return [VoiceLabVideoCut(startSample: left.start, endSample: left.start + finalFirst),
                        VoiceLabVideoCut(startSample: right.start, endSample: right.start + secondCount)].sorted { $0.startSample < $1.startSample }
            }
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
