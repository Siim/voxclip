import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabNaturalPacingTests {
    @Test func sharedHardWindowReservesAgreeBeforeAndAfterPayment() throws {
        struct Document: Decodable {
            struct Row: Decodable {
                let windowSeconds: Double
                let reserveSeconds: Double
                let speechSeconds: Double
            }
            let schema: String
            let sourceSampleRate: Int
            let caseCount: Int
            let cases: [Row]
        }
        let fixture = try FixtureLoader.decode(Document.self, at: "fixtures/voice-lab/natural-pacing-cases.json")
        #expect(fixture.schema == "voxclip-natural-pacing/2" && fixture.caseCount == 2 && fixture.cases.count == 2)
        for row in fixture.cases {
            #expect(abs(VoiceLabHardJoin.pauseSeconds(windowDuration: row.windowSeconds) - row.reserveSeconds) < 1e-9)
            let source = window(row.windowSeconds)
            let fit = try VoiceLabPhraseTiming.preview(seconds: row.speechSeconds, window: source,
                incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: fixture.sourceSampleRate, hardJoinSmoothing: true)
            guard case .exact(let plan) = fit else { Issue.record("one word must retain its slot"); continue }
            #expect(plan.incoming.padFrames == Int64(row.reserveSeconds * Double(fixture.sourceSampleRate)))
            #expect(plan.outgoing.padFrames == plan.incoming.padFrames)
            let timing = try VoiceLabPaceMatching.match(seconds: row.speechSeconds, window: source,
                incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: fixture.sourceSampleRate,
                supportsPace: false, hardJoinSmoothing: true)
            #expect(timing.fits && timing.pace == 1)
            let rate = 6 / ((row.speechSeconds - 0.09) * VoiceLabPhraseTiming.providerSpeechRateMultiplier)
            let measured = try VoiceLabPaceMatching.measure(text: "speech", rate: rate, window: source,
                incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: fixture.sourceSampleRate,
                supportsPace: false, hardJoinSmoothing: true)
            #expect(measured.fits && abs(measured.estimateSeconds - row.speechSeconds) < 1e-9)
        }
    }
    private func window(_ duration: Double) -> VoiceLabWindow {
        let end = Int64(EditingPrimitives.jsRound(duration * 48_000))
        return VoiceLabWindow(firstWordId: "first", lastWordId: "last", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 0, end: duration, startSample: 0, endSample: end,
            leftSeam: .init(kind: .hard, time: 0, sample: 0, fadeSamples: 240),
            rightSeam: .init(kind: .hard, time: duration, sample: end, fadeSamples: 240))
    }

    @Test func sharedQuietBoundaryCuts() throws {
        struct Document: Decodable {
            struct Row: Decodable {
                struct Speech: Decodable { let kind: String; let start: Double; let end: Double }
                let id: String
                let windowStartSample: Int64; let windowEndSample: Int64; let outputSamples: Int64
                let quietBlocks: [[Int]]; let levels: [[Double]]; let speech: [Speech]; let expected: [[Int64]]
            }
            let sourceSampleRate: Int; let cutCaseCount: Int; let cutCases: [Row]
        }
        let fixture = try FixtureLoader.decode(Document.self, at: "fixtures/voice-lab/natural-pacing-cases.json")
        #expect(fixture.cutCaseCount == 13 && fixture.cutCases.count == fixture.cutCaseCount)
        for row in fixture.cutCases {
            var levels: [Float] = (0..<500).map { block in
                row.quietBlocks.contains { ($0[0]..<$0[1]).contains(block) } ? 0.005 : 1
            }
            for override in row.levels { levels[Int(override[0])] = Float(override[1]) }
            let items = row.speech.enumerated().map { index, item in
                TimedWord(id: "speech-\(index)", text: "speech", kind: item.kind == "word" ? .word : .unlabeledSpeech,
                          start: item.start, end: item.end)
            }
            let cuts = VoiceLabNaturalPacing.cuts(windowStartSample: row.windowStartSample,
                windowEndSample: row.windowEndSample, outputSamples: row.outputSamples, sampleRate: fixture.sourceSampleRate,
                envelope: .init(sampleRate: Double(fixture.sourceSampleRate), levels: levels), items: items)
            #expect(cuts.map { [$0.startSample, $0.endSample] } == row.expected, "\(row.id)")
        }
    }

    @Test func sharedTaggedPauseEdits() throws {
        struct Document: Decodable {
            struct Row: Decodable {
                let id: String; let windowSeconds: Double; let beforeToken: Int; let kind: String; let editedGap: Int
            }
            let pauseCaseCount: Int; let pauseCases: [Row]
        }
        let fixture = try FixtureLoader.decode(Document.self, at: "fixtures/voice-lab/natural-pacing-cases.json")
        #expect(fixture.pauseCaseCount == 3 && fixture.pauseCases.count == fixture.pauseCaseCount)
        let words = [VoiceLabWord(text: "hello,", start: 0, end: 0.3, synthetic: true),
                     VoiceLabWord(text: "world,", start: 0.6, end: 0.9, synthetic: true),
                     VoiceLabWord(text: "again", start: 1.2, end: 1.5, synthetic: true)]
        let levels: [Float] = (0..<150).map { (30..<60).contains($0) || (90..<120).contains($0) ? 0 : 1 }
        let take = VoiceLabFitTake(assetFrames: 72_000, assetSampleRate: 48_000, trimStart: 0, trimEnd: 1.5,
            words: words, envelope: .init(sampleRate: 48_000, levels: levels))
        for row in fixture.pauseCases {
            for tag in VoiceLabAudioTags.definitions {
                let fit = try VoiceLabFitPlanner.plan(window: window(row.windowSeconds), incomingSilence: nil, outgoingSilence: nil,
                    take: take, tokens: words.map(\.text), sourceSampleRate: 48_000, hardJoinSmoothing: false,
                    pauseProfile: .init(withinSentence: [0.1, 0.5, 0.7], betweenSentences: []),
                    audioTags: [.init(beforeToken: row.beforeToken, tag: tag.tag)])
                #expect(fit.plan.edits.count == 1, "\(row.id): \(tag.tag)")
                #expect(fit.plan.edits.allSatisfy { edit in
                    edit.kind.rawValue == row.kind && (row.editedGap == 1 ? edit.start < 28_800 : edit.start >= 43_200)
                }, "\(row.id): \(tag.tag)")
            }
        }
    }

    @Test func sourceQuantilesBoundRoomToneGrowthWithoutTouchingWords() throws {
        let profile = VoiceLabPauseProfile(withinSentence: [0.2, 0.3, 0.7, 1.2], betweenSentences: [0.4, 0.6, 1.0, 1.5])
        #expect(profile.withinSentence.p25 == 0.2 && profile.withinSentence.p75 == 0.7 && profile.withinSentence.p90 == 1.2)
        #expect(profile.distribution(after: "finished.").p75 == 1)
        let words = [VoiceLabWord(text: "hello,", start: 0, end: 0.3, synthetic: true),
                     VoiceLabWord(text: "world", start: 0.5, end: 1, synthetic: true)]
        let levels: [Float] = (0..<100).map { (30..<50).contains($0) ? 0 : 1 }
        let take = VoiceLabFitTake(assetFrames: 48_000, assetSampleRate: 48_000, trimStart: 0, trimEnd: 1,
            words: words, envelope: .init(sampleRate: 48_000, levels: levels))
        let fit = try VoiceLabFitPlanner.plan(window: window(1.5), incomingSilence: nil, outgoingSilence: nil,
            take: take, tokens: words.map(\.text), sourceSampleRate: 48_000, hardJoinSmoothing: false, pauseProfile: profile)
        guard case .exact(let plan) = fit else { Issue.record("natural pauses should exactly fill this window"); return }
        #expect(plan.edits.count == 1 && plan.edits[0].roomTone)
        #expect(plan.edits[0].count == 24_000)
        #expect(plan.words[0] == words[0])
        #expect(plan.words[1].start == 1 && plan.words[1].end == 1.5)
        let bounded = try VoiceLabFitPlanner.plan(window: window(3), incomingSilence: nil, outgoingSilence: nil,
            take: take, tokens: words.map(\.text), sourceSampleRate: 48_000, hardJoinSmoothing: false, pauseProfile: profile)
        #expect(bounded.plan.edits[0].count == 24_000)
        #expect(bounded.plan.outputFrames < 144_000)
        let shorter = try VoiceLabFitPlanner.plan(window: window(0.9), incomingSilence: nil, outgoingSilence: nil,
            take: take, tokens: words.map(\.text), sourceSampleRate: 48_000, hardJoinSmoothing: false,
            pauseProfile: .init(withinSentence: [0.1, 0.2, 0.7], betweenSentences: []))
        guard case .exact(let shrunk) = shorter else { Issue.record("shrink pauses before changing pace"); return }
        #expect(shrunk.edits.first?.kind == .remove && shrunk.edits.first?.count == 4_800)
        #expect(shrunk.words[0] == words[0] && abs(shrunk.words[1].start - 0.4) < 1e-9)
    }

    @Test func cutReadyFitUsesSpokenTakeWithoutPartialPauseGrowth() throws {
        let words = [VoiceLabWord(text: "hello,", start: 0, end: 0.3, synthetic: true),
                     VoiceLabWord(text: "world", start: 0.5, end: 1, synthetic: true)]
        let take = VoiceLabFitTake(assetFrames: 48_000, assetSampleRate: 48_000, trimStart: 0, trimEnd: 1,
            words: words, envelope: .init(sampleRate: 48_000, levels: (0..<100).map { (30..<50).contains($0) ? 0 : 1 }))
        let profile = VoiceLabPauseProfile(withinSentence: [0.1, 0.7, 0.8], betweenSentences: [])
        let source = AudioEnvelope(sampleRate: 48_000, levels: (0..<240).map {
            (50..<56).contains($0) || (190..<196).contains($0) ? 0.001 : 1
        })
        let grown = try VoiceLabFitPlanner.plan(window: window(2.4), incomingSilence: nil, outgoingSilence: nil,
            take: take, tokens: words.map(\.text), sourceSampleRate: 48_000, hardJoinSmoothing: false, pauseProfile: profile)
        #expect(grown.plan.edits.first?.count == 28_800)
        let fit = try VoiceLabNaturalPacing.fit(window: window(2.4), incomingSilence: nil, outgoingSilence: nil,
            take: take, sourceSampleRate: 48_000, hardJoinSmoothing: false, pauseProfile: profile, audioTags: [],
            sourceEnvelope: source, items: [])
        #expect(fit.plan.edits.isEmpty && fit.plan.outputFrames == 48_000 && fit.plan.words == words)
        #expect(fit.plan.videoCuts == [.init(startSample: 24_000, endSample: 91_200)])
        let options = VoiceLabVideoDurationOptions(fit: fit, sourceSampleRate: 48_000, assetSampleRate: 48_000)
        #expect(options.allows(.cut) && options.addedPauseSeconds == 0 && options.removedVideoSeconds == 1.4)
        var paidRateTake = take
        paidRateTake.assetSampleRate = 24_000
        paidRateTake.assetFrames = 24_000
        paidRateTake.envelope = .init(sampleRate: 24_000, levels: take.envelope.levels)
        let paidRateFit = try VoiceLabNaturalPacing.fit(window: window(2.4), incomingSilence: nil, outgoingSilence: nil,
            take: paidRateTake, sourceSampleRate: 48_000, hardJoinSmoothing: false, pauseProfile: profile, audioTags: [],
            sourceEnvelope: source, items: [])
        #expect(paidRateFit.plan.outputFrames == 24_000 && paidRateFit.plan.videoCuts == fit.plan.videoCuts)
        let noCut = try VoiceLabNaturalPacing.fit(window: window(2.4), incomingSilence: nil, outgoingSilence: nil,
            take: take, sourceSampleRate: 48_000, hardJoinSmoothing: false, pauseProfile: profile, audioTags: [],
            sourceEnvelope: .init(sampleRate: 48_000, levels: Array(repeating: 1, count: 240)), items: [])
        #expect(noCut == grown)
    }

    @Test func unsupportedModelDoesNotProtectAnUnspokenTag() throws {
        let tags = [VoiceLabAudioTag(beforeToken: 1, tag: "long pause")]
        #expect(VoiceLabAudioTags.recorded(tags, modelID: "eleven_multilingual_v2") == nil)
        #expect(VoiceLabAudioTags.recorded(tags, modelID: "eleven_v3") == tags)
    }

    @Test func existingAlignedPausesGrowBeforeNewConjunctionPauses() throws {
        let words = [VoiceLabWord(text: "one", start: 0, end: 0.3, synthetic: true),
                     VoiceLabWord(text: "two", start: 0.5, end: 0.7, synthetic: true),
                     VoiceLabWord(text: "and", start: 0.76, end: 0.9, synthetic: true),
                     VoiceLabWord(text: "three", start: 0.9, end: 1, synthetic: true)]
        let levels: [Float] = (0..<100).map { (30..<50).contains($0) || (70..<76).contains($0) ? 0 : 1 }
        let take = VoiceLabFitTake(assetFrames: 48_000, assetSampleRate: 48_000, trimStart: 0, trimEnd: 1,
            words: words, envelope: .init(sampleRate: 48_000, levels: levels))
        let fit = try VoiceLabFitPlanner.plan(window: window(1.08), incomingSilence: nil, outgoingSilence: nil,
            take: take, tokens: words.map(\.text), sourceSampleRate: 48_000, hardJoinSmoothing: false,
            pauseProfile: .init(withinSentence: [0.7], betweenSentences: []))
        #expect(fit.plan.edits.count == 1)
        #expect(fit.plan.edits.first?.count == 3_840)
        #expect(abs(fit.plan.words[1].start - 0.58) < 1e-9)
    }

    @Test func automaticPaceMovesOnlyForAnExactNaturalFit() throws {
        let source = window(5)
        let exact = try VoiceLabPaceMatching.match(seconds: 5.1, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: false)
        #expect(exact.pace == 1.02 && exact.fits)
        let tooLong = try VoiceLabPaceMatching.match(seconds: 7, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: true)
        #expect(tooLong.pace == 1 && !tooLong.fits && tooLong.tooLong)
        let dialogue = try VoiceLabPaceMatching.match(seconds: 5.1, window: source,
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, supportsPace: false, hardJoinSmoothing: true)
        #expect(dialogue.pace == 1 && !dialogue.copy.contains("pace"))
        #expect(VoiceLabPace.isValid(0.7) && VoiceLabPace.isValid(1.2))
    }

    @Test func cutsPreferOneQuietBoundaryPairAndNeverSpeechBoundariesOrEdges() throws {
        func envelope(_ ranges: [Range<Int>]) -> AudioEnvelope {
            .init(sampleRate: 48_000, levels: (0..<500).map { block in ranges.contains { $0.contains(block) } ? 0.001 : 1 })
        }
        let one = VoiceLabNaturalPacing.cuts(windowStartSample: 0, windowEndSample: 240_000, outputSamples: 144_000,
            sampleRate: 48_000, envelope: envelope([100..<400]), items: [])
        #expect(one.first?.startSample == 48_000)
        for kind in [WordKind.word, .unlabeledSpeech] {
            let spoken = [TimedWord(id: "spoken", text: "speech", kind: kind, start: 0.5, end: 4)]
            #expect(VoiceLabNaturalPacing.cuts(windowStartSample: 0, windowEndSample: 240_000, outputSamples: 144_000,
                sampleRate: 48_000, envelope: envelope([100..<400]), items: spoken).isEmpty)
        }
        let piece = VoiceLabOutputPiece(kind: .synth, sourceStartSample: 0, sourceEndSample: 240_000,
            outputStartSample: 0, outputEndSample: 144_000, segmentId: "cut", assetId: nil, audio: nil)
        var timeline = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 240_000, pieces: [piece], captions: [], scope: .full)
        timeline.videoCuts = ["cut": one]
        #expect(timeline.mapTime(2) == 1 && timeline.sourceTime(1) == 3 && timeline.sourceTime(2) == 4)
        let two = VoiceLabNaturalPacing.cuts(windowStartSample: 0, windowEndSample: 240_000, outputSamples: 144_000,
            sampleRate: 48_000, envelope: envelope([50..<150, 250..<350]), items: [])
        #expect(two == [.init(startSample: 24_000, endSample: 120_000)])
        #expect(VoiceLabNaturalPacing.cuts(windowStartSample: 0, windowEndSample: 240_000, outputSamples: 24_000,
            sampleRate: 48_000, envelope: envelope([0..<500]), items: []).isEmpty)
        var video = VoiceLabVideoRecipe(mode: .cut, sourceStartSample: 0, sourceEndSample: 240_000, outputSamples: 144_000,
            retimeFactor: nil, zoom: 1.06, faceX: 0.5, faceY: 0.5, assetId: nil, provider: nil, model: nil, requestId: nil,
            windowStartSample: nil, windowEndSample: nil, syncMode: nil)
        video.cuts = one
        #expect(VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000))
        let decoded = try JSONDecoder().decode(VoiceLabVideoRecipe.self, from: JSONEncoder().encode(video))
        #expect(decoded == video)
        video.cuts = [.init(startSample: 0, endSample: 96_000)]
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000))
        video.cuts = two; video.zoom = 1.12
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000))
    }

    @Test func pauseHeavyPhrasesNeverChooseProviderMinimum() throws {
        for (seconds, slot) in [(4.1, 5.4), (1.3, 2.2), (2.7, 5.5)] {
            let end = Int64(slot * 48_000)
            let window = VoiceLabWindow(firstWordId: "first", lastWordId: "last", leftBridgeWordIds: [], rightBridgeWordIds: [],
                start: 0, end: slot, startSample: 0, endSample: end,
                leftSeam: .init(kind: .hard, time: 0, sample: 0, fadeSamples: 240),
                rightSeam: .init(kind: .hard, time: slot, sample: end, fadeSamples: 240))
            let timing = try VoiceLabPaceMatching.match(seconds: seconds, window: window,
                incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000, hardJoinSmoothing: true)
            #expect(timing.pace == 1, "\(seconds)/\(slot): \(timing.pace)")
        }
    }

    @Test func wordingTargetsIncludeNaturalInternalPauseCapacity() throws {
        let profile = VoiceLabPauseProfile(withinSentence: [0.3, 0.7], betweenSentences: [0.6, 1])
        let plain = try VoiceLabPaceMatching.match(seconds: 2, window: window(3), incomingSilence: nil,
            outgoingSilence: nil, sourceSampleRate: 48_000, supportsPace: false, hardJoinSmoothing: true)
        let natural = try VoiceLabPaceMatching.match(seconds: 2, window: window(3), incomingSilence: nil,
            outgoingSilence: nil, sourceSampleRate: 48_000, supportsPace: false, hardJoinSmoothing: true,
            generatedText: "Hello, world. Welcome back.", pauseProfile: profile)
        #expect(try #require(natural.minimumSeconds) < #require(plain.minimumSeconds))
        #expect(natural.pace == 1)
    }
}
