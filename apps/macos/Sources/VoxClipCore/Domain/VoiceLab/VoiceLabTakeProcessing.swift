import Foundation

public struct VoiceLabTakePreflight: Sendable {
    public let sourceLevel: Double
    public let roomTone: VoiceLabRoomTone?
}

public enum VoiceLabTakeProcessing {
    public static let maximumQASeconds = 290.0
    public static func preflight(_ input: VoiceLabTakeInput, envelope: AudioEnvelope) throws -> VoiceLabTakePreflight {
        let rate = input.sourceSampleRate
        guard input.providerConsent, !input.contentKey.isEmpty, !input.text.isEmpty, input.text.unicodeScalars.count <= 5_000,
              (8_000...96_000).contains(rate), !input.source.isEmpty,
              input.window.startSample >= 0, input.window.endSample <= input.source.count,
              input.window.endSample > input.window.startSample, input.window.start.isFinite, input.window.end.isFinite,
              input.window.start >= 0, input.window.end > input.window.start,
              input.window.end <= Double(input.source.count) / Double(rate),
              frames(input.window.start, rate) == input.window.startSample,
              frames(input.window.end, rate) == input.window.endSample else { throw VoiceLabError.invalidInput }
        let range = Int(input.window.startSample)..<Int(input.window.endSample)
        let tokens = VoiceLabTakeQuality.tokens(input.text)
        guard !tokens.isEmpty else { throw VoiceLabError.invalidInput }
        func bridgeTokens(_ ids: [String]) throws -> [String] {
            try ids.flatMap { id in
                guard !input.cutWordIDs.contains(id), let word = input.items.first(where: { $0.id == id && $0.kind == .word }) else { throw VoiceLabError.invalidInput }
                return VoiceLabTakeQuality.tokens(word.text)
            }
        }
        let leading = try bridgeTokens(input.window.leftBridgeWordIds), trailing = try bridgeTokens(input.window.rightBridgeWordIds)
        guard Array(tokens.prefix(leading.count)) == leading, Array(tokens.suffix(trailing.count)) == trailing else { throw VoiceLabError.invalidInput }
        let level = try VoiceLabLoudness.neighbourhoodVoicedRmsDb(input.source, sampleRate: rate, window: range)
        let tone = input.cleanAudioOn ? nil : try VoiceLabRoomToneSelection.select(items: input.items, envelope: envelope,
            sourceSampleRate: Double(rate), totalSamples: Int64(input.source.count))
        return VoiceLabTakePreflight(sourceLevel: level, roomTone: tone)
    }
    public static func envelope(_ samples: [Float], sampleRate: Int) -> AudioEnvelope {
        let frame = max(1, Int(EditingPrimitives.jsRound(Double(sampleRate) * 0.01)))
        var levels: [Float] = []
        var start = 0
        while samples.count - start >= frame {
            var power = 0.0
            for index in start..<(start + frame) { power += Double(samples[index]) * Double(samples[index]) }
            levels.append(Float(sqrt(power / Double(frame))))
            start += frame
        }
        return AudioEnvelope(sampleRate: Double(sampleRate), levels: levels)
    }
    public static func process(_ result: VoiceLabAudioResult, input: VoiceLabTakeInput, preflight: VoiceLabTakePreflight,
                               sourceAtAssetRate source: [Float]) throws -> VoiceLabTakeAudio {
        let rate = result.sampleRate
        guard rate == 24_000, !result.pcm.isEmpty, result.pcm.count.isMultiple(of: 2),
              result.pcm.count / 2 <= rate * 289, let alignment = result.alignment else { throw VoiceLabError.invalidAlignment }
        let samples: [Float] = result.pcm.withUnsafeBytes { bytes in
            (0..<(bytes.count / 2)).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768 }
        }
        let duration = Double(samples.count) / Double(rate)
        let words: [VoiceLabWord] = try VoiceLabAlignment.words(characters: alignment.map(\.character), starts: alignment.map(\.start),
            ends: alignment.map(\.end), expectedText: input.text)
        let trim = try VoiceLabAlignment.trim(words: words, assetDuration: duration)
        let trimStart = frames(trim.start, rate), trimEnd = frames(trim.end, rate)
        guard trimEnd <= samples.count, trimStart < trimEnd else { throw VoiceLabError.invalidAlignment }
        let trimmed = Array(samples[trimStart..<trimEnd])
        let gain = try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: preflight.sourceLevel,
            candidateVoicedRmsDb: VoiceLabLoudness.voicedRmsDb(trimmed, sampleRate: rate),
            candidateTruePeakDbtp: VoiceLabLoudness.truePeakDbtp(trimmed, sampleRate: rate))
        let take = VoiceLabFitTake(assetFrames: Int64(samples.count), assetSampleRate: rate, trimStart: trim.start, trimEnd: trim.end,
                                  words: words, envelope: envelope(samples, sampleRate: rate))
        let fit = try VoiceLabFitPlanner.plan(window: input.window, incomingSilence: input.incomingSilence,
            outgoingSilence: input.outgoingSilence, take: take, tokens: words.map(\.text), sourceSampleRate: Double(input.sourceSampleRate))
        let plan = fit.plan
        let body = try fitted(samples, plan: plan, rate: rate)
        let sourceStart = frames(plan.windowStart, rate), sourceEnd = frames(plan.windowEnd, rate)
        guard sourceStart >= 0, sourceEnd <= source.count, sourceStart < sourceEnd else { throw VoiceLabError.invalidAudio }
        let lead = min(rate / 2, sourceStart), tail = min(rate / 2, source.count - sourceEnd)
        guard lead + body.count + tail <= Int(maximumQASeconds) * rate else { throw VoiceLabError.invalidAudio }
        let tone: [Float]
        if let range = preflight.roomTone {
            let start = frames(Double(range.sourceStartSample) / Double(input.sourceSampleRate), rate)
            let end = frames(Double(range.sourceEndSample) / Double(input.sourceSampleRate), rate)
            guard start >= 0, end <= source.count, end > start else { throw VoiceLabError.invalidAudio }
            tone = Array(source[start..<end])
        } else { tone = [] }
        let amplitude = Float(pow(10, gain / 20))
        func signal(_ index: Int) -> Float {
            let speech: Float
            if body.indices.contains(index) { speech = body[index] }
            else if index < 0, plan.incoming.padFrames == 0 {
                let original = Int(plan.trimStartFrame) + index
                speech = samples.indices.contains(original) ? samples[original] : 0
            } else if index >= body.count, plan.outgoing.padFrames == 0 {
                let original = Int(plan.trimEndFrame) + index - body.count
                speech = samples.indices.contains(original) ? samples[original] : 0
            } else { speech = 0 }
            return speech * amplitude + toneSample(tone, at: index, rate: rate)
        }
        var mixed: [Float] = []
        mixed.reserveCapacity(lead + body.count + tail)
        mixed.append(contentsOf: source[(sourceStart - lead)..<sourceStart])
        for index in body.indices { mixed.append(signal(index)) }
        mixed.append(contentsOf: source[sourceEnd..<(sourceEnd + tail)])
        var seams: [Int] = []
        for incoming in [true, false] {
            let placement = incoming ? input.window.leftSeam : input.window.rightSeam
            guard placement.kind != .none else { continue }
            let fade = frames(Double(placement.fadeSamples) / Double(input.sourceSampleRate), rate)
            guard fade > 0 else { throw VoiceLabError.invalidAudio }
            let before = fade / 2, after = fade - before
            let seam = lead + (incoming ? 0 : body.count)
            let sourceSeam = incoming ? sourceStart : sourceEnd
            guard seam >= before, seam + after <= mixed.count,
                  sourceSeam >= before, sourceSeam + after <= source.count else { throw VoiceLabError.invalidAudio }
            if incoming, plan.incoming.padFrames == 0, plan.trimStartFrame < before { throw VoiceLabError.invalidAudio }
            if !incoming, plan.outgoing.padFrames == 0, plan.trimEndFrame + Int64(after) > samples.count { throw VoiceLabError.invalidAudio }
            for offset in 0..<fade {
                let local = offset - before
                let position = Double(offset) / Double(max(1, fade - 1))
                let old = source[sourceSeam + local]
                let generated = signal((incoming ? 0 : body.count) + local)
                let left: Float = incoming ? old : generated
                let right: Float = incoming ? generated : old
                let leftGain: Float = Float(cos(Double.pi * position / 2))
                let rightGain: Float = Float(sin(Double.pi * position / 2))
                let leftSample: Float = left * leftGain
                let rightSample: Float = right * rightGain
                mixed[seam + local] = leftSample + rightSample
            }
            seams.append(seam)
        }
        return VoiceLabTakeAudio(sampleRate: rate, trimmed: trimmed, mixed: mixed, patchRange: lead..<(lead + body.count),
                                 seams: seams, gainDb: gain, roomTone: preflight.roomTone, fit: fit)
    }
    private static func fitted(_ samples: [Float], plan: VoiceLabFitPlan, rate: Int) throws -> [Float] {
        var result = [Float](repeating: 0, count: Int(plan.incoming.padFrames))
        var cursor = Int(plan.trimStartFrame)
        var joins: [(output: Int, before: Int, after: Int)] = []
        for edit in plan.edits.sorted(by: { $0.start < $1.start }) {
            let start = Int(edit.start), end = start + Int(edit.count)
            guard start >= cursor, end <= plan.trimEndFrame, end > start else { throw VoiceLabError.invalidAudio }
            result.append(contentsOf: samples[cursor..<start])
            if edit.kind == .insert {
                result.append(contentsOf: samples[start..<end])
                joins.append((result.count, end, start))
                result.append(contentsOf: samples[start..<end])
            } else { joins.append((result.count, start, end)) }
            cursor = end
        }
        guard cursor <= plan.trimEndFrame, plan.trimEndFrame <= samples.count else { throw VoiceLabError.invalidAudio }
        result.append(contentsOf: samples[cursor..<Int(plan.trimEndFrame)])
        result.append(contentsOf: repeatElement(Float(0), count: Int(plan.outgoing.padFrames)))
        let fade = frames(VoiceLabPatchConstants.SEAM_FADE, rate), before = fade / 2, after = fade - before
        for join in joins {
            guard join.output >= before, join.output + after <= result.count,
                  join.before >= before, join.before + after <= samples.count,
                  join.after >= before, join.after + after <= samples.count else { throw VoiceLabError.invalidAudio }
            for offset in 0..<fade {
                let local = offset - before, phase = Double(offset) / Double(max(1, fade - 1))
                let leftGain = Float(cos(Double.pi * phase / 2)), rightGain = Float(sin(Double.pi * phase / 2))
                let leftSample: Float = samples[join.before + local] * leftGain
                let rightSample: Float = samples[join.after + local] * rightGain
                result[join.output + local] = leftSample + rightSample
            }
        }
        guard result.count == plan.outputFrames else { throw VoiceLabError.invalidAudio }
        return result
    }
    private static func toneSample(_ tone: [Float], at frame: Int, rate: Int) -> Float {
        guard !tone.isEmpty else { return 0 }
        let fade = min(tone.count / 2, frames(0.05, rate)), period = tone.count - fade
        if frame >= 0 && frame < period { return tone[frame] }
        let index = ((frame % period) + period) % period
        guard index < fade else { return tone[index] }
        let phase = Double(index) / Double(max(1, fade - 1))
        let left: Float = tone[period + index] * Float(cos(Double.pi * phase / 2))
        let right: Float = tone[index] * Float(sin(Double.pi * phase / 2))
        return left + right
    }
    private static func frames(_ seconds: Double, _ rate: Int) -> Int { Int(EditingPrimitives.jsRound(seconds * Double(rate))) }
}
