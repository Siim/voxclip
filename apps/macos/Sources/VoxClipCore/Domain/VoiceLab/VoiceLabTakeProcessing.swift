import Foundation

public struct VoiceLabTakePreflight: Sendable {
    public let sourceLevel: Double
    public let roomTone: VoiceLabRoomTone?
    /// The spectrum of the speech beside the window, from the level match's sides (§8.7 item 2b). Nil when unmeasured.
    public var sourceTone: VoiceLabTilt.Bands? = nil
}

public struct VoiceLabTakeAnalysis: Sendable {
    public let sampleRate: Int
    public let trimmed: [Float]
    public let gainDb: Double
    public let roomTone: VoiceLabRoomTone?
    public let fit: VoiceLabFitResult
    /// The tone match applied before `gainDb` (§8.7 item 2b); `trimmed` already has it. Nil leaves the take as it is.
    public let tiltDbPerOctave: Double?
    package init(sampleRate: Int, trimmed: [Float], gainDb: Double, roomTone: VoiceLabRoomTone?, fit: VoiceLabFitResult, tiltDbPerOctave: Double? = nil) {
        self.sampleRate = sampleRate; self.trimmed = trimmed; self.gainDb = gainDb; self.roomTone = roomTone; self.fit = fit
        self.tiltDbPerOctave = tiltDbPerOctave
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
        guard keepsBridgeWords(input.text, bridge: try bridgeWords(input)) else { throw VoiceLabError.invalidInput }
        let level = try VoiceLabLoudness.neighbourhoodVoicedRmsDb(input.source, sampleRate: rate, window: range)
        var tone = input.cleanAudioOn ? nil : try VoiceLabRoomToneSelection.select(items: input.items, envelope: input.sourceEnvelope,
            sourceSampleRate: Double(rate), totalSamples: Int64(total),
            excludeDigitalSilence: VoiceLabRoomToneSelection.excludeDigitalSilence(items: input.items, envelope: input.sourceEnvelope,
                sampleRate: Double(rate), totalSamples: Int64(total), window: input.window, hardJoinSmoothing: input.hardJoinSmoothing))
        // The quietest run of the whole take can sit well under the noise beside the window (a car vlog), and the patch's
        // pads and pauses would dip; the loop plays at the background level measured at the seams.
        if let selected = tone {
            guard let run = input.source.samples(Int(selected.sourceStartSample)..<Int(selected.sourceEndSample)) else { throw VoiceLabError.invalidInput }
            let background = try VoiceLabLoudness.seamBackgroundRmsDb(input.source, sampleRate: rate, window: range)
            tone?.gainDb = try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: background, run: Array(run))
            // When the background differs on the two sides, no one level meets both seams: the bed ramps from the
            // left side's level to the right side's across the window, linearly in dB.
            let sides = try VoiceLabLoudness.seamBackgroundSidesRmsDb(input.source, sampleRate: rate, window: range)
            if let left = sides.left, let right = sides.right, abs(right - left) >= VoiceLabLoudness.roomToneRampMinimumDb {
                let start = try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: left, run: Array(run))
                let end = try VoiceLabLoudness.roomToneGainDb(seamBackgroundRmsDb: right, run: Array(run))
                tone?.gainDb = start
                tone?.endGainDb = end == start ? nil : end
            }
        }
        if input.hardJoinSmoothing, input.window.leftSeam.kind == .hard || input.window.rightSeam.kind == .hard, let selected = tone {
            tone = try VoiceLabHardJoin.matchedRoomTone(selected, input: input, speechLevel: level)
        }
        return VoiceLabTakePreflight(sourceLevel: level, roomTone: tone,
            sourceTone: VoiceLabTilt.neighbourhoodBands(input.source, sampleRate: rate, window: range))
    }
    /// The bridge words a take's text must begin and end with (voice-lab §8.4): the unchanged words that join the change
    /// to the source around it, as the input's items spell them. Throws when a bridge word is cut or not a word.
    public static func bridgeWords(_ input: VoiceLabTakeInput) throws -> (leading: [String], trailing: [String]) {
        func texts(_ ids: [String]) throws -> [String] {
            try ids.map { id in
                guard !input.cutWordIDs.contains(id), let word = input.items.first(where: { $0.id == id && $0.kind == .word }) else { throw VoiceLabError.invalidInput }
                return word.text
            }
        }
        return (try texts(input.window.leftBridgeWordIds), try texts(input.window.rightBridgeWordIds))
    }
    /// Whether `text` begins with the leading bridge words and ends with the trailing ones, compared as the word check
    /// compares words (case, punctuation and tags aside). A wording that drops them can't be placed or priced.
    public static func keepsBridgeWords(_ text: String, bridge: (leading: [String], trailing: [String])) -> Bool {
        let tokens = VoiceLabTakeQuality.tokens(text)
        let leading = bridge.leading.flatMap(VoiceLabTakeQuality.tokens), trailing = bridge.trailing.flatMap(VoiceLabTakeQuality.tokens)
        return !tokens.isEmpty && Array(tokens.prefix(leading.count)) == leading && Array(tokens.suffix(trailing.count)) == trailing
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
    /// `matchTone`: a generated take is tilted towards the speech beside it (§8.7 item 2b); the user's own recorded take
    /// is their real voice and is left as it is.
    public static func process(_ result: VoiceLabAudioResult, input: VoiceLabTakeInput, preflight: VoiceLabTakePreflight,
                               matchTone: Bool = false) throws -> VoiceLabTakeAnalysis {
        let rate = result.sampleRate
        guard rate == 24_000, !result.pcm.isEmpty, result.pcm.count.isMultiple(of: 2),
              result.pcm.count / 2 <= rate * 289, let alignment = result.alignment else { throw VoiceLabError.invalidAlignment }
        let samples: [Float] = result.pcm.withUnsafeBytes { bytes in
            (0..<(bytes.count / 2)).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768 }
        }
        let duration = Double(samples.count) / Double(rate)
        // The provider may time the last character to the end of its PCM or a little past it (the client accepts 50 ms);
        // Eleven v3 ends its audio on the last word. No frame lies past the asset, so times are clamped to its last frame.
        let last = lastAlignedTime(frames: samples.count, rate: rate)
        var words: [VoiceLabWord] = try VoiceLabAlignment.words(characters: alignment.map(\.character), starts: alignment.map { min($0.start, last) },
            ends: alignment.map { min($0.end, last) }, expectedText: input.text)
        let taggedModel = VoiceLabAudioTags.supports(input.modelID)
        let tokenCount = EditingPrimitives.splitWords(input.text).count
        if input.hardJoinSmoothing {
            words = VoiceLabHardJoin.refine(words: words, samples: samples, sampleRate: rate,
                incoming: input.window.leftSeam.kind == .hard && !(taggedModel && input.audioTags.contains { $0.beforeToken == 0 }),
                outgoing: input.window.rightSeam.kind == .hard && !(taggedModel && input.audioTags.contains { $0.beforeToken == tokenCount }))
        }
        words = VoiceLabAudioTags.edgeExtent(words: words, samples: samples, sampleRate: rate, tags: input.audioTags,
            tokenCount: tokenCount, modelID: input.modelID, characters: alignment)
        let trim = try VoiceLabAlignment.trim(words: words, assetDuration: duration)
        let trimStart = frames(trim.start, rate), trimEnd = frames(trim.end, rate)
        guard trimEnd <= samples.count, trimStart < trimEnd else { throw VoiceLabError.invalidAlignment }
        // The tone match runs over the whole asset from its first frame, as every reader of the take runs it; the level is
        // then measured on the tilted take, so the gain still meets the speech beside it.
        let tilt = matchTone ? preflight.sourceTone.flatMap { source in
            VoiceLabTilt.match(source: source, take: VoiceLabTilt.bands([samples[trimStart..<trimEnd]], sampleRate: rate))
        } : nil
        let tilted = tilt.map { VoiceLabTilt.apply(samples, sections: VoiceLabTilt.sections(tiltDbPerOctave: $0, sampleRate: rate)) } ?? samples
        let trimmed = Array(tilted[trimStart..<trimEnd])
        let gain = try VoiceLabLoudness.levelGainDb(sourceVoicedRmsDb: preflight.sourceLevel,
            candidateVoicedRmsDb: VoiceLabLoudness.voicedRmsDb(trimmed, sampleRate: rate),
            candidateTruePeakDbtp: VoiceLabLoudness.truePeakDbtp(trimmed, sampleRate: rate))
        let take = VoiceLabFitTake(assetFrames: Int64(samples.count), assetSampleRate: rate, trimStart: trim.start, trimEnd: trim.end,
                                  words: words, envelope: envelope(samples, sampleRate: rate))
        let profile = input.pauseProfile ?? VoiceLabPauseProfile.measure(items: input.items, envelope: input.sourceEnvelope,
            start: 0, end: .greatestFiniteMagnitude)
        let fit = try VoiceLabNaturalPacing.fit(window: input.window, incomingSilence: input.incomingSilence,
            outgoingSilence: input.outgoingSilence, take: take, sourceSampleRate: input.sourceSampleRate,
            hardJoinSmoothing: input.hardJoinSmoothing, pauseProfile: profile,
            audioTags: VoiceLabAudioTags.recorded(input.audioTags, modelID: input.modelID) ?? [],
            sourceEnvelope: input.sourceEnvelope, items: input.items)
        return VoiceLabTakeAnalysis(sampleRate: rate, trimmed: trimmed, gainDb: gain, roomTone: preflight.roomTone, fit: fit, tiltDbPerOctave: tilt)
    }
    private static func frames(_ seconds: Double, _ rate: Int) -> Int { Int(EditingPrimitives.jsRound(seconds * Double(rate))) }
    /// The latest time whose frame span, `ceil(t × rate)` as the fit planner rounds a word's end, stays inside `frames`:
    /// `frames / rate`, or the double just below it when binary64 rounds the product up (1.36 s × 24 kHz).
    static func lastAlignedTime(frames: Int, rate: Int) -> Double {
        var time = Double(frames) / Double(rate)
        while time > 0 && (time * Double(rate)).rounded(.up) > Double(frames) { time = time.nextDown }
        return time
    }
}
