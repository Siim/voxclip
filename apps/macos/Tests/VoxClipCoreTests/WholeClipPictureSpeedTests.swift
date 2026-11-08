import Foundation
import Testing
@testable import VoxClipCore

/// ADR-R46 "Your own pace" (2026-11-08): a whole clip's voice is kept as generated (provider pace 1.0, never stretched); a
/// shorter voice first speeds the picture up evenly, to at most 1.2×, then the pause layout and the trim take what is left.
@Suite(.offlineFixtures) struct WholeClipPictureSpeedTests {
    private struct File: Decodable { let usersClip: WholeClipFitReplayTests.UsersClip }

    @Test func theSpeedIsTheClipOverTheVoiceFromOneToTheCap() {
        #expect(WholeClipRevoice.maximumPictureSpeed == 1.2)
        #expect(WholeClipRevoice.pictureSpeed(voiceSeconds: 20.2, videoSeconds: 31.3) == 1.2, "the user's MVP45 voice hits the cap")
        #expect(abs(WholeClipRevoice.pictureSpeed(voiceSeconds: 28, videoSeconds: 31.3) - 31.3 / 28) < 1e-12)
        #expect(WholeClipRevoice.pictureSpeed(voiceSeconds: 32, videoSeconds: 31.3) == 1, "a longer voice keeps the picture's pace")
        #expect(WholeClipRevoice.pictureSpeed(voiceSeconds: .nan, videoSeconds: 31.3) == 1)
        #expect(WholeClipRevoice.pictureSpeed(voiceSeconds: 0, videoSeconds: 31.3) == 1)
    }

    @Test func theFitLineNamesTheSpeed() {
        #expect(WholeClipRevoice.spedCopy(speed: 1.2, laidOut: true) == "picture 1.20× and laid out on the clip's pauses")
        #expect(WholeClipRevoice.spedCopy(speed: 31.3 / 28, laidOut: false) == "picture 1.12× to fit")
    }

    @Test func theRecordHoldsTheSpeed() {
        #expect(WholeClipRevoice.validRetime(1.2) && WholeClipRevoice.validRetime(1) && WholeClipRevoice.validRetime(0.92))
        #expect(!WholeClipRevoice.validRetime(1.21) && !WholeClipRevoice.validRetime(0.91) && !WholeClipRevoice.validRetime(.infinity))
    }

    /// The edited picture may carry one even speed-up: kept ÷ output within 1e-6 of a declared factor in (1, 1.2].
    @Test func aSpedEditedCutValidatesOnlyWithItsOwnFactor() {
        // 4 s of source, 1 s cut: 3 s kept, played in 2.5 s (1.2×).
        var video = VoiceLabVideoRecipe(mode: .cut, sourceStartSample: 0, sourceEndSample: 192_000, outputSamples: 120_000,
            retimeFactor: 1.2, zoom: VoiceLabNaturalPacing.EDITED_CUT_ZOOM, faceX: 0.5, faceY: 0.5, assetId: nil, provider: nil,
            model: nil, requestId: nil, windowStartSample: nil, windowEndSample: nil, syncMode: nil)
        video.cuts = [VoiceLabVideoCut(startSample: 96_000, endSample: 144_000)]
        #expect(VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000))
        video.retimeFactor = nil
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000), "kept ≠ output needs its factor")
        video.retimeFactor = 1.1
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000), "a factor the samples don't say")
        video.outputSamples = 117_000; video.retimeFactor = 144_000.0 / 117_000
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000), "faster than the cap")
        video.outputSamples = 144_000; video.retimeFactor = 1
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000), "1× is written as no factor")
        video.retimeFactor = nil
        #expect(VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000))
        video.zoom = VoiceLabNaturalPacing.CUT_PUNCH_IN; video.outputSamples = 120_000; video.retimeFactor = 1.2
        #expect(!VoiceLabNaturalPacing.validCuts(video, sampleRate: 48_000), "a pause's jump cut never speeds up")
    }

    /// The edited timeline maps a sped piece's kept offsets evenly, both ways, and the lip-sync window reads it alike.
    @Test func aSpedPieceMapsEvenly() throws {
        let synth = VoiceLabOutputPiece(kind: .synth, sourceStartSample: 48_000, sourceEndSample: 240_000, outputStartSample: 48_000,
            outputEndSample: 168_000, segmentId: "s", assetId: "a", audio: nil)
        let tail = VoiceLabOutputPiece(kind: .source, sourceStartSample: 240_000, sourceEndSample: 288_000, outputStartSample: 168_000,
            outputEndSample: 216_000, segmentId: nil, assetId: nil, audio: nil)
        let head = VoiceLabOutputPiece(kind: .source, sourceStartSample: 0, sourceEndSample: 48_000, outputStartSample: 0,
            outputEndSample: 48_000, segmentId: nil, assetId: nil, audio: nil)
        var plan = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 288_000, pieces: [head, synth, tail], captions: [], scope: .full)
        plan.videoCuts["s"] = [VoiceLabVideoCut(startSample: 144_000, endSample: 192_000)]
        #expect(VoiceLabOutputPlan.cutScale(synth, cuts: plan.videoCuts["s"]!) == (kept: 144_000, output: 120_000))
        // 1 s into the piece's source is 1 s ÷ 1.2 into its output.
        #expect(abs(plan.mapTime(2) - (1 + 1 / 1.2)) < 1e-9)
        // Past the cut: 2 s kept before 4 s of source.
        #expect(abs(plan.mapTime(4.5) - (1 + 2.5 / 1.2)) < 1e-9)
        #expect(abs(plan.sourceTime(1 + 1 / 1.2) - 2) < 1e-4)
        #expect(abs(plan.sourceTime(1 + 2.5 / 1.2) - 4.5) < 1e-4)
        #expect(abs(plan.mapTime(5.5) - 4) < 1e-9, "the source after the piece follows its 2.5 s output")
        let window = try LipsyncRenderWindow(source: LipsyncWindow.make(seamIn: 96_000, seamOut: 216_000, totalSamples: 288_000,
            sampleRate: 48_000, phraseID: 0), plan: plan)
        #expect(window.outputEndSample <= plan.outputSamples && window.outputStartSample < window.outputEndSample)
        // An unsped cut piece maps exactly as before.
        var plain = plan
        plain.videoCuts["s"] = [VoiceLabVideoCut(startSample: 144_000, endSample: 216_000)]
        #expect(plain.mapTime(2) == 2 && plain.sourceTime(2.5) == 2.5)
        #expect(plain.mapTime(4.5) == 3 && plain.sourceTime(3) == 4.5)
    }

    /// The user's MVP45 run (2026-11-08), as numbers: the clip 0:31.3 as edited (the MVP44 clip's numbers, unchanged), a
    /// 52-word voice of 20.2 s. It used to be laid out at 1× (−35.4%, a third of the picture trimmed) and the lip sync was
    /// priced on 31.3 s. With the rule, the picture plays 1.2×, the pauses and the trim take the rest, the recipe
    /// validates, and the lip sync is priced on the picture's output length.
    @Test func theUsersClipSpeedsThePictureUp() throws {
        let clip = try JSONDecoder().decode(File.self, from: FixtureLoader.data("fixtures/voice-lab/whole-clip-fit-cases.json")).usersClip
        let project = try WholeClipFitReplayTests.usersProject(clip)
        let plan = try VoiceLabOutputPlanner.build(project, scope: .clip("clip-users"))
        let rate = plan.sampleRate
        let words = try #require(project.transcript?.words)
        let start = Int64(EditingPrimitives.jsRound(words[clip.clipFirstWord].start * rate))
        let end = Int64(EditingPrimitives.jsRound(words[clip.clipLastWord].end * rate))
        let edited = WholeClipRevoice.editedCuts(plan, startSample: start, endSample: end)
        let editedSeconds = WholeClipRevoice.editedSeconds(edited, startSample: start, endSample: end, sampleRate: rate)
        #expect(abs(editedSeconds - 31.3) < 0.2, "\(editedSeconds) s as edited")
        let voice = 20.2
        #expect(WholeClipRevoice.fit(voiceSeconds: voice, videoSeconds: editedSeconds, words: 52, round: 0) == .laidOut(factor: voice / editedSeconds))
        // A 20.2 s take of the clip's sentences with 0.3 s between them.
        let sentences = clip.words[clip.clipFirstWord...clip.clipLastWord].filter { $0[2] == 0 && $0[3] == 1 }.count
        let pause = 0.3
        let said = (voice - Double(sentences - 1) * pause) / Double(sentences)
        let take = WholeClipLayoutTests.take(sentences: Array(repeating: said, count: sentences), pause: pause, assetRate: 24_000)
        let window = VoiceLabWindow(firstWordId: "w\(clip.clipFirstWord)", lastWordId: "w\(clip.clipLastWord)", leftBridgeWordIds: [],
            rightBridgeWordIds: [], start: Double(start) / rate, end: Double(end) / rate, startSample: start, endSample: end,
            leftSeam: .init(kind: .gap, time: Double(start) / rate, sample: start, fadeSamples: 960),
            rightSeam: .init(kind: .gap, time: Double(end) / rate, sample: end, fadeSamples: 960))
        func layout(_ speed: Double) throws -> VoiceLabFitResult {
            try VoiceLabNaturalPacing.layout(window: window, incomingSilence: 0, outgoingSilence: 0, take: take,
                sourceSampleRate: Int(rate), hardJoinSmoothing: true,
                pauseProfile: WholeClipRevoice.layoutPauseProfile(pauseThresholdSeconds: clip.pauseThresholdSeconds),
                audioTags: [], editedCuts: edited, tailSeconds: WholeClipRevoice.layoutPauseBound(clip.pauseThresholdSeconds),
                maximumSpeed: speed)
        }
        let before = try layout(1)
        #expect(before.plan.pictureSpeed == 1)
        let result = try layout(WholeClipRevoice.maximumPictureSpeed)
        let laid = result.plan
        #expect(laid.pictureSpeed > 1.199 && laid.pictureSpeed <= 1.2, "\(laid.pictureSpeed)")
        let options = VoiceLabVideoDurationOptions(fit: result, sourceSampleRate: Int(rate), assetSampleRate: 24_000)
        #expect(options.allows(.cut), "the sped picture is a valid cut: \(result)")
        #expect(options.cutRetimeFactor == laid.pictureSpeed)
        var video = VoiceLabVideoRecipe(mode: .cut, sourceStartSample: laid.windowStartSample, sourceEndSample: laid.windowEndSample,
            outputSamples: options.outputSamples ?? 0, retimeFactor: options.cutRetimeFactor, zoom: VoiceLabVideoDurationOptions.cutZoom(laid),
            faceX: 0.5, faceY: 0.5, assetId: nil, provider: nil, model: nil, requestId: nil, windowStartSample: nil, windowEndSample: nil, syncMode: nil)
        video.cuts = options.cuts
        #expect(VoiceLabNaturalPacing.validCuts(video, sampleRate: rate))
        #expect(Array(laid.videoCuts.prefix(edited.count)) == edited || laid.videoCuts.count >= edited.count, "the clip's own cuts stay")
        let output = Double(options.outputSamples ?? 0) / rate
        let beforeOutput = Double(VoiceLabVideoDurationOptions(fit: before, sourceSampleRate: Int(rate), assetSampleRate: 24_000).outputSamples ?? 0) / rate
        let trimmed = editedSeconds - output * laid.pictureSpeed
        let beforeTrimmed = editedSeconds - beforeOutput
        #expect(output < editedSeconds / 1.2 + 0.01 && output >= voice, "\(output) s of picture")
        #expect(trimmed < beforeTrimmed - 4, "far less of the clip is trimmed: \(trimmed) s, was \(beforeTrimmed) s")
        let catalog = try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
        let price = try WholeClipRevoice.lipsyncPrice(videoSeconds: output + 2, lipsync: .lipsync2, catalog: catalog)
        let old = try WholeClipRevoice.lipsyncPrice(videoSeconds: editedSeconds + 2, lipsync: .lipsync2, catalog: catalog)
        #expect((price.usd ?? 0) < (old.usd ?? 0))
        let growth = laid.edits.filter { $0.kind == .insert }.reduce(0.0) { $0 + Double($1.count) / 24_000 }
        print("USERS-CASE edited", editedSeconds, "speed", laid.pictureSpeed, "output", output, "pause growth", growth,
              "tail", Double(laid.outgoing.padFrames) / 24_000, "trimmed", trimmed, "was", beforeOutput, beforeTrimmed,
              "lipsync", price.usd ?? 0, "was", old.usd ?? 0)
    }
}
