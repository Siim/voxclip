import Foundation

public struct VoiceLabTakePreflight: Sendable {
    public let sourceLevel: Double
    public let roomTone: VoiceLabRoomTone?
}

public struct VoiceLabTakeAnalysis: Sendable {
    public let sampleRate: Int
    public let trimmed: [Float]
    public let gainDb: Double
    public let roomTone: VoiceLabRoomTone?
    public let fit: VoiceLabFitResult
    package init(sampleRate: Int, trimmed: [Float], gainDb: Double, roomTone: VoiceLabRoomTone?, fit: VoiceLabFitResult) {
        self.sampleRate = sampleRate; self.trimmed = trimmed; self.gainDb = gainDb; self.roomTone = roomTone; self.fit = fit
    }
}

public enum VoiceLabTakeProcessing {
    public static let maximumQASeconds = 290.0
    public static func preflight(_ input: VoiceLabTakeInput) throws -> VoiceLabTakePreflight {
        let rate = input.sourceSampleRate, total = input.source.totalFrames
        guard input.providerConsent, !input.contentKey.isEmpty, !input.text.isEmpty, input.text.unicodeScalars.count <= 5_000,
              (8_000...96_000).contains(rate), total > 0,
              input.window.startSample >= 0, input.window.endSample <= total,
              input.window.endSample > input.window.startSample, input.window.start.isFinite, input.window.end.isFinite,
              input.window.start >= 0, input.window.end > input.window.start,
              input.window.end <= Double(total) / Double(rate),
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
        let tone = input.cleanAudioOn ? nil : try VoiceLabRoomToneSelection.select(items: input.items, envelope: input.sourceEnvelope,
            sourceSampleRate: Double(rate), totalSamples: Int64(total))
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
    public static func process(_ result: VoiceLabAudioResult, input: VoiceLabTakeInput, preflight: VoiceLabTakePreflight) throws -> VoiceLabTakeAnalysis {
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
        return VoiceLabTakeAnalysis(sampleRate: rate, trimmed: trimmed, gainDb: gain, roomTone: preflight.roomTone, fit: fit)
    }
    private static func frames(_ seconds: Double, _ rate: Int) -> Int { Int(EditingPrimitives.jsRound(seconds * Double(rate))) }
}
