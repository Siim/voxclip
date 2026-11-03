import Foundation

public struct VoiceLabMicroPause: Codable, Sendable, Equatable {
    public var wordStartSeconds: Double
    public var wordEndSeconds: Double
    public init(wordStartSeconds: Double, wordEndSeconds: Double) {
        self.wordStartSeconds = wordStartSeconds; self.wordEndSeconds = wordEndSeconds
    }
}

public struct VoiceLabEdgeGainWord: Codable, Sendable, Equatable {
    public var gainDb: Double
    public var wordSeconds: VoiceLabMicroPause
    public init(gainDb: Double, wordSeconds: VoiceLabMicroPause) {
        self.gainDb = gainDb; self.wordSeconds = wordSeconds
    }
}

public struct VoiceLabEdgeGain: Codable, Sendable, Equatable {
    public var `in`: VoiceLabEdgeGainWord?
    public var out: VoiceLabEdgeGainWord?
    public init(in incoming: VoiceLabEdgeGainWord? = nil, out: VoiceLabEdgeGainWord? = nil) {
        self.in = incoming; self.out = out
    }
}

public enum VoiceLabHardJoin {
    public static let pauseSeconds = 0.140
    public static let windowPauseFraction = 0.20

    public static func pauseSeconds(windowDuration: Double) -> Double {
        guard windowDuration.isFinite, windowDuration > 0 else { return 0 }
        return min(pauseSeconds, windowDuration * windowPauseFraction)
    }
    public static let generatedFadeSeconds = 0.025
    public static let sourceFadeSeconds = 0.020
    public static let gainRampSeconds = 0.020
    public static let acousticSearchSeconds = 0.120
    public static let maximumGainDb = 6.0
    public static let toleranceLu = 2.0
    public static let roomToneMaximumGainDb = 48.0

    public static func fadeExtent(_ seam: VoiceLabSeam, incoming: Bool, sampleRate: Double) -> (left: Int64, right: Int64) {
        if seam.microPause != nil {
            let frames = Int64(EditingPrimitives.jsRound(sourceFadeSeconds * sampleRate))
            return incoming ? (frames, 0) : (0, frames)
        }
        let left = seam.fadeSamples / 2
        return (left, seam.fadeSamples - left)
    }

    public static func matchedRoomTone(_ room: VoiceLabRoomTone, input: VoiceLabTakeInput, speechLevel: Double) throws -> VoiceLabRoomTone {
        let rate = input.sourceSampleRate, size = max(1, Int(EditingPrimitives.jsRound(Double(rate) * 0.01))), count = size * 10
        guard let run = input.source.samples(Int(room.sourceStartSample)..<Int(room.sourceEndSample)) else { throw VoiceLabError.invalidInput }
        func level(_ samples: [Float]) -> Double {
            let weighted = VoiceLabLoudness.kWeighted(samples, count: samples.count, sampleRate: rate)
            let power = weighted.reduce(0.0) { $0 + $1 * $1 } / Double(weighted.count)
            return power > 0 ? -0.691 + 10 * log10(power) : -.infinity
        }
        let runLevel = level(Array(run))
        guard runLevel.isFinite else { throw VoiceLabGeometryError.roomToneUnavailable }
        func target(_ seam: Int) -> Double? {
            let lower = max(0, seam - 3 * rate), upper = min(input.source.totalFrames - count, seam + 3 * rate)
            guard upper >= lower else { return nil }
            var best: (distance: Int, level: Double)?
            for start in stride(from: lower / size * size, through: upper, by: size) {
                let end = start + count
                guard !input.items.contains(where: { $0.kind == .word && $0.end > Double(start) / Double(rate) && $0.start < Double(end) / Double(rate) }),
                      let samples = input.source.samples(start..<end) else { continue }
                let frames = start / size..<(end / size)
                guard frames.upperBound <= input.sourceEnvelope.levels.count,
                      frames.allSatisfy({ Double(input.sourceEnvelope.levels[$0]) <= VoiceLabPatchConstants.VOICED_FRAME_LEVEL }) else { continue }
                let distance = abs(start + count / 2 - seam)
                if best == nil || distance < best!.distance {
                    let measured = level(Array(samples))
                    if measured.isFinite { best = (distance, min(measured, speechLevel - 12)) }
                }
            }
            return best?.level
        }
        let left = target(Int(input.window.startSample)), right = target(Int(input.window.endSample))
        func gain(_ target: Double?) -> Double {
            min(roomToneMaximumGainDb, max(-roomToneMaximumGainDb, min(target ?? runLevel, speechLevel - 12) - runLevel))
        }
        let first = gain(left ?? right), last = gain(right ?? left)
        return .init(sourceStartSample: room.sourceStartSample, sourceEndSample: room.sourceEndSample,
                     gainDb: first, endGainDb: abs(last - first) >= 1 ? last : nil)
    }

    public static func pause(words: [VoiceLabWord], duration: Double, incoming: Bool) -> VoiceLabMicroPause? {
        guard let word = incoming ? words.first : words.last else { return nil }
        let join = incoming ? 0 : duration
        return .init(wordStartSeconds: word.start - join, wordEndSeconds: word.end - join)
    }

    public static func generatedWeight(seconds: Double, duration: Double, incoming: VoiceLabMicroPause?, outgoing: VoiceLabMicroPause?) -> Double {
        var weight = 1.0
        if let incoming {
            let fraction = min(1, max(0, (seconds - incoming.wordStartSeconds + generatedFadeSeconds) / generatedFadeSeconds))
            weight *= sin(.pi * fraction / 2)
        }
        if let outgoing {
            let fraction = min(1, max(0, (seconds - duration - outgoing.wordEndSeconds + generatedFadeSeconds) / generatedFadeSeconds))
            weight *= fraction >= 1 ? 0 : cos(.pi * fraction / 2)
        }
        return weight
    }

    public static func sourceWeight(secondsFromJoin: Double, incoming: Bool) -> Double {
        let fraction = min(1, max(0, incoming ? -secondsFromJoin / sourceFadeSeconds : secondsFromJoin / sourceFadeSeconds))
        return sin(.pi * fraction / 2)
    }

    public static func edgeGainDb(seconds: Double, duration: Double, edgeGain: VoiceLabEdgeGain?) -> Double {
        func value(_ edge: VoiceLabEdgeGainWord?, incoming: Bool) -> Double {
            guard let edge else { return 0 }
            let time = seconds - (incoming ? 0 : duration)
            let start = edge.wordSeconds.wordStartSeconds, end = edge.wordSeconds.wordEndSeconds
            guard time >= start - 1e-9, time <= end + 1e-9 else { return 0 }
            let fraction = incoming ? (end - time) / gainRampSeconds : (time - start) / gainRampSeconds
            return edge.gainDb * min(1, max(0, fraction))
        }
        return max(value(edgeGain?.in, incoming: true), value(edgeGain?.out, incoming: false))
    }

    public static func bedWeight(seconds: Double, duration: Double, words: [VoiceLabWord], incoming: VoiceLabMicroPause?, outgoing: VoiceLabMicroPause?) -> Double {
        let voice = generatedWeight(seconds: seconds, duration: duration, incoming: incoming, outgoing: outgoing)
        if let incoming, seconds < incoming.wordStartSeconds { return sqrt(max(0, 1 - voice * voice)) }
        if let outgoing, seconds >= duration + outgoing.wordEndSeconds - generatedFadeSeconds { return sqrt(max(0, 1 - voice * voice)) }
        var distance = sourceFadeSeconds
        var lower = 0, upper = words.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if words[middle].end < seconds { lower = middle + 1 } else { upper = middle }
        }
        func near(_ index: Int) -> Double {
            guard words.indices.contains(index) else { return sourceFadeSeconds }
            let word = words[index]
            return max(0, max(word.start - seconds, seconds - word.end))
        }
        distance = min(distance, near(lower - 1), near(lower))
        let pause = sin(.pi * min(1, distance / sourceFadeSeconds) / 2)
        return max(pause, sqrt(max(0, 1 - voice * voice)))
    }

    public static func validate(seams: VoiceLabSeams, edgeGain: VoiceLabEdgeGain?, duration: Double, windowDuration: Double? = nil) throws {
        if seams.in.microPause == nil && seams.out.microPause == nil && edgeGain == nil { return }
        guard duration.isFinite, duration > 0, duration <= 290,
              edgeGain == nil || edgeGain?.in != nil || edgeGain?.out != nil else { throw VoiceLabProjectError.invalidFadeHandles }
        func valid(_ word: VoiceLabMicroPause, incoming: Bool) -> Bool {
            let start = word.wordStartSeconds, end = word.wordEndSeconds
            return start.isFinite && end.isFinite && end > start &&
                (incoming ? start >= pauseSeconds(windowDuration: windowDuration ?? duration) - 0.001 && end <= duration : start >= -duration && end <= -pauseSeconds(windowDuration: windowDuration ?? duration) + 0.001)
        }
        for incoming in [true, false] {
            let seam = incoming ? seams.in : seams.out
            if let pause = seam.microPause {
                guard seam.kind == .hard, valid(pause, incoming: incoming) else { throw VoiceLabProjectError.invalidFadeHandles }
            }
            if let gain = incoming ? edgeGain?.in : edgeGain?.out {
                guard let pause = seam.microPause, gain.wordSeconds == pause, gain.gainDb.isFinite,
                      (0...maximumGainDb).contains(gain.gainDb) else { throw VoiceLabProjectError.invalidFadeHandles }
            }
        }
    }

    public static func refine(words: [VoiceLabWord], samples: [Float], sampleRate: Int, incoming refineIncoming: Bool = true, outgoing refineOutgoing: Bool = true) -> [VoiceLabWord] {
        guard !words.isEmpty else { return words }
        var refined = words
        let rate = Double(sampleRate), frame = max(1, sampleRate / 200)
        for incoming in [true, false] {
            if incoming ? !refineIncoming : !refineOutgoing { continue }
            let index = incoming ? 0 : words.count - 1
            let word = refined[index]
            let boundary = incoming ? word.start : word.end
            let lower = max(0, Int(((incoming ? boundary - acousticSearchSeconds : word.start) * rate).rounded(.down)))
            let upper = min(samples.count, Int(((incoming ? word.end : boundary + acousticSearchSeconds) * rate).rounded(.up)))
            guard upper > lower else { continue }
            var levels: [(Int, Int, Double)] = []
            var start = lower
            while start < upper {
                let end = min(upper, start + frame)
                var power = 0.0
                for offset in start..<end { power += Double(samples[offset]) * Double(samples[offset]) }
                levels.append((start, end, power / Double(end - start)))
                start = end
            }
            let threshold = max(0.00000001, (levels.map { $0.2 }.max() ?? 0) * 0.001)
            let active = levels.filter { $0.2 > threshold }
            if incoming, let first = active.first {
                refined[index].start = min(word.start, Double(first.0) / rate)
            } else if let last = active.last {
                let limit = index + 1 < words.count ? words[index + 1].start : Double(samples.count) / rate
                refined[index].end = min(limit, max(word.end, Double(last.1) / rate))
            }
        }
        return refined
    }

    public static func voicedLevel(_ samples: [Float], sampleRate: Int, range: Range<Int>) throws -> Double? {
        guard range.lowerBound >= 0, range.upperBound <= samples.count, !range.isEmpty else { throw VoiceLabAudioMathError.invalidInput }
        return try VoiceLabLoudness.voicedRmsDb(Array(samples[range]), sampleRate: sampleRate)
    }

    public static func speechStep(_ samples: [Float], sampleRate: Int, seam: Int, pause: VoiceLabMicroPause, incoming: Bool) throws -> Double {
        let rate = Double(sampleRate)
        let start = seam + Int(EditingPrimitives.jsRound(pause.wordStartSeconds * rate))
        let end = seam + Int(EditingPrimitives.jsRound(pause.wordEndSeconds * rate))
        let count = Int(EditingPrimitives.jsRound(0.4 * rate))
        let edge = incoming ? start..<min(end, start + count) : max(start, end - count)..<end
        let source = incoming ? max(0, seam - count)..<seam : seam..<min(samples.count, seam + count)
        let edgeLevel = try voicedLevel(samples, sampleRate: sampleRate, range: edge)
        let sourceLevel = try voicedLevel(samples, sampleRate: sampleRate, range: source)
        guard let edgeLevel, let sourceLevel else { throw VoiceLabAudioMathError.noVoicedAudio }
        return incoming ? edgeLevel - sourceLevel : sourceLevel - edgeLevel
    }

    public static func sourceStep(_ samples: [Float], sampleRate: Int, seam: Int) throws -> Double {
        let count = Int(EditingPrimitives.jsRound(0.4 * Double(sampleRate)))
        let left = try voicedLevel(samples, sampleRate: sampleRate, range: max(0, seam - count)..<seam)
        let right = try voicedLevel(samples, sampleRate: sampleRate, range: seam..<min(samples.count, seam + count))
        guard let left, let right else { throw VoiceLabAudioMathError.noVoicedAudio }
        return right - left
    }

    public static func matchingGain(edge: [Float], source: [Float], sampleRate: Int, incoming: Bool = false) throws -> Double {
        let count = min(edge.count, Int(EditingPrimitives.jsRound(0.4 * Double(sampleRate))))
        let speech = incoming ? Array(edge.prefix(count)) : Array(edge.suffix(count))
        guard let from = try VoiceLabLoudness.voicedRmsDb(speech, sampleRate: sampleRate),
              let to = try VoiceLabLoudness.voicedRmsDb(source, sampleRate: sampleRate) else { return 0 }
        let peak = try VoiceLabLoudness.truePeakDbtp(edge, sampleRate: sampleRate)
        return max(0, min(maximumGainDb, to - from, -1 - peak))
    }
}
