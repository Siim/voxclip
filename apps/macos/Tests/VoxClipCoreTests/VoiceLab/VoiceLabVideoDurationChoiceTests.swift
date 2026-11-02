import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct VoiceLabVideoDurationChoiceTests {
    private func row(sourceSamples: Int64 = 4_000, outputSamples: Int64 = 4_000, sourceRate: Int = 1_000,
                     exact: Bool = true, passed: Bool = true) -> VoiceLabTakeRow {
        let duration = Double(outputSamples) / Double(sourceRate)
        let frames = Int64(EditingPrimitives.jsRound(duration * 24_000))
        let window = Double(sourceSamples) / Double(sourceRate)
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: frames, windowStart: 0, windowEnd: window,
            windowStartSample: 0, windowEndSample: sourceSamples, outputFrames: frames,
            words: [.init(text: "Reviewed", start: 0.01, end: duration - 0.01, synthetic: true)])
        let fit: VoiceLabFitResult = exact ? .exact(plan) : .changedDuration(plan, naturalOut: duration, residualSeconds: duration - window)
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0, roomTone: nil, fit: fit)
        return VoiceLabTakeRow(id: UUID(), index: 0, seed: 7, audio: audio,
            qa: .init(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10, speakerScore: 0.9), failures: passed ? [] : [.speaker]), score: 0.9)
    }

    @Test(arguments: [3_200, 5_000])
    func inclusiveVideoSpeedLimitsUseSourceOverOutput(output: Int) {
        let options = VoiceLabVideoDurationOptions(row: row(outputSamples: Int64(output), exact: false), sourceSampleRate: 1_000)
        #expect(options.retimeFactor == 4_000 / Double(output))
        #expect(options.outputSamples == Int64(output) && options.allows(.retimed))
        #expect(!options.allows(.source) && !options.allows(.zoomCover) && !options.allows(.lipsync))
    }

    @Test(arguments: [3_199, 5_001])
    func justOutsideVideoSpeedLimitsIsUnavailable(output: Int) {
        let options = VoiceLabVideoDurationOptions(row: row(outputSamples: Int64(output), exact: false), sourceSampleRate: 1_000)
        #expect(!options.allows(.retimed))
        #expect(options.changedUnavailableReason?.contains("0.80×–1.25×") == true)
    }

    @Test func unchangedDurationRequiresVerifiedExactSilenceOnlyFit() {
        let exact = VoiceLabVideoDurationOptions(row: row(), sourceSampleRate: 1_000)
        #expect(exact.allows(.source) && exact.allows(.retimed))
        let unverified = VoiceLabVideoDurationOptions(row: row(exact: false), sourceSampleRate: 1_000)
        #expect(!unverified.allows(.source) && unverified.unchangedUnavailableReason?.contains("not verified") == true)
        let long = VoiceLabVideoDurationOptions(row: row(outputSamples: 4_500, exact: false), sourceSampleRate: 1_000)
        #expect(long.unchangedUnavailableReason?.contains("cannot be shortened") == true)
        let short = VoiceLabVideoDurationOptions(row: row(outputSamples: 3_500, exact: false), sourceSampleRate: 1_000)
        #expect(short.unchangedUnavailableReason?.contains("cannot fill") == true)
    }

    @Test func exactFitKeepsSourceGridWhenAssetGridRoundsDifferently() {
        let options = VoiceLabVideoDurationOptions(row: row(sourceSamples: 10_001, outputSamples: 10_001, sourceRate: 44_100), sourceSampleRate: 44_100)
        #expect(options.outputSamples == 10_001 && options.allows(.source) && options.retimeFactor == 1)
    }

    @Test(arguments: [0, -1])
    func invalidRatesAndFailedQAOfferNeitherChoice(rate: Int) {
        let options = VoiceLabVideoDurationOptions(row: row(), sourceSampleRate: rate)
        #expect(!options.allows(.source) && !options.allows(.retimed))
        let failed = VoiceLabVideoDurationOptions(row: row(passed: false), sourceSampleRate: 1_000)
        #expect(!failed.allows(.source) && !failed.allows(.retimed))
    }

    private func project(duration: Double = 0.8) throws -> Project {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        var segment = project.voiceLab.segments[0]
        var recipe = try #require(segment.candidates[0].recipe)
        recipe.audio.stretch = 1
        recipe.outDuration = duration
        recipe.audio.trimEnd = recipe.audio.trimStart + duration
        recipe.chunks[0].assembledEndFrame = Int64(EditingPrimitives.jsRound(recipe.audio.trimEnd * 24_000))
        var words = try #require(recipe.words)
        words[1].end = min(0.6, duration - 0.05)
        recipe.words = words
        recipe.video.mode = .zoomCover
        recipe.video.outputSamples = Int64(EditingPrimitives.jsRound(duration * 1_000))
        recipe.video.retimeFactor = 700 / Double(recipe.video.outputSamples)
        recipe.video.zoom = 1.12; recipe.video.faceX = 0.5; recipe.video.faceY = 0.5
        segment.candidates = [segment.candidates[0]]
        segment.candidates[0].recipe = recipe
        segment.audio = recipe.audio; segment.outDuration = duration; segment.words = recipe.words
        project.voiceLab.segments = [segment]
        project.voiceLab.assets?[0].durationSeconds = 1.5
        return project
    }

    @Test(arguments: [0.875, 0.56, 0.8, 0.625])
    func naturalAudioAndVideoShareExactOutputSampleGrid(duration: Double) throws {
        let project = try project(duration: duration)
        let originalWords = project.transcript
        let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        let selected = try #require(prepared.selectedSegmentRecipes.first)
        #expect(selected.recipe.audio.stretch == 1)
        #expect(selected.recipe.video.retimeFactor == 700 / Double(selected.recipe.video.outputSamples))
        #expect(selected.recipe.video.zoom == 1.12 && selected.recipe.video.faceX == 0.5 && selected.recipe.video.faceY == 0.5)
        #expect(selected.piece.outputEndSample - selected.piece.outputStartSample == selected.recipe.video.outputSamples)
        #expect(prepared.outputPlan.outputSamples == 7_000 - 700 + selected.recipe.video.outputSamples)
        #expect(prepared.outputPlan.mapTime(2.5) == 2.5)
        #expect(abs(prepared.outputPlan.mapTime(3.2) - (2.5 + duration)) < 1e-9)
        #expect(abs(prepared.outputPlan.mapTime(2.85) - (2.5 + duration / 2)) < 1e-9)
        #expect(abs(prepared.outputPlan.sourceTime(2.5 + duration / 2) - 2.85) <= 0.001)
        #expect(project.transcript == originalWords)
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(project)) == project)
    }

    @Test(arguments: [3, 4])
    func cleanAudioRemainsRefusedForVoiceSemanticsSupersets(version: Int) throws {
        var project = try project()
        project.schemaVersion = version
        project.voiceLab.cleanAudio = VoiceLabCleanAudio(mode: .on, assetId: try #require(project.voiceLab.assets?.first?.id), mix: 1)
        project.voiceLab.segments[0].candidates[0].recipe?.roomTone = nil
        #expect(throws: VoiceLabProjectError.cleanAudioUnsupported) {
            try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        }
    }

    @Test func malformedRecipesNeverGainChangedDurationAcceptance() throws {
        let good = try project()
        let mutations: [(inout VoiceLabRenderRecipe) -> Void] = [
            { $0.video.outputSamples += 1 }, { $0.video.sourceEndSample += 1 },
            { $0.video.retimeFactor = 1 / ($0.video.retimeFactor ?? 1) },
            { $0.video.retimeFactor = .nan }, { $0.video.zoom = nil },
            { $0.video.faceX = .infinity }, { $0.audio.stretch = 1.01 },
            { $0.qa.speakerPassed = false }, { $0.qa.transcriptMatch = 0 },
            { $0.chunks.removeAll() }, { $0.seams.in.assetHandleFrames = 0 }
        ]
        for mutate in mutations {
            var bad = good
            var recipe = try #require(bad.voiceLab.segments[0].candidates[0].recipe)
            mutate(&recipe)
            bad.voiceLab.segments[0].candidates[0].recipe = recipe
            bad.voiceLab.segments[0].audio = recipe.audio
            #expect(throws: VoiceLabProjectError.self) { try VoiceLabRenderContract.prepare(bad, scope: .full, labelPosition: .topRight) }
        }
        var missing = good
        missing.voiceLab.segments[0].candidates[0].recipe = nil
        #expect(throws: VoiceLabProjectError.missingRenderPolicy) { try VoiceLabRenderContract.prepare(missing, scope: .full, labelPosition: .topRight) }
    }

    @Test func legacyRetimedStillFailsAndPreparedChoiceIsProjectBound() throws {
        let good = try project()
        let prepared = try VoiceLabRenderContract.prepare(good, scope: .clip("clip-main"), labelPosition: .topRight)
        var changed = good
        changed.edits.corrections["w3"] = "Changed after review"
        #expect(throws: VoiceLabProjectError.staleRenderContract) { try prepared.verify(project: changed, scope: .clip("clip-main"), labelPosition: .topRight) }
        #expect(throws: VoiceLabProjectError.staleRenderContract) { try prepared.verify(project: good, scope: .full, labelPosition: .topRight) }
        changed = good
        changed.voiceLab.segments[0].candidates[0].recipe?.video.mode = .retimed
        changed.voiceLab.segments[0].candidates[0].recipe?.video.zoom = nil
        changed.voiceLab.segments[0].candidates[0].recipe?.video.faceX = nil
        changed.voiceLab.segments[0].candidates[0].recipe?.video.faceY = nil
        #expect(throws: VoiceLabProjectError.videoModeUnsupported) { try VoiceLabRenderContract.prepare(changed, scope: .full, labelPosition: .topRight) }
    }

    @Test(arguments: [false, true])
    func recipeBuilderRequiresExplicitChoiceAndPreservesPaidAudio(changed: Bool) throws {
        let project = try project(duration: changed ? 0.8 : 0.7)
        let segment = project.voiceLab.segments[0]
        let recipe = try #require(segment.candidates[0].recipe)
        let words = try #require(recipe.words)
        let text = try #require(segment.text)
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: FixtureLoader.data("fixtures/voice-lab/consent-record.json"))
        let window = VoiceLabWindow(firstWordId: segment.replace.firstWordId, lastWordId: segment.replace.lastWordId,
            leftBridgeWordIds: [], rightBridgeWordIds: [], start: 2.5, end: 3.2, startSample: 2_500, endSample: 3_200,
            leftSeam: .init(kind: .gap, time: 2.5, sample: 2_500, fadeSamples: 20),
            rightSeam: .init(kind: .gap, time: 3.2, sample: 3_200, fadeSamples: 20))
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 2_400, trimEndFrame: recipe.chunks[0].assembledEndFrame, windowStart: 2.5, windowEnd: 3.2,
            windowStartSample: 2_500, windowEndSample: 3_200, outputFrames: Int64(EditingPrimitives.jsRound(recipe.outDuration * 24_000)), words: words)
        let fit: VoiceLabFitResult = changed ? .changedDuration(plan, naturalOut: recipe.outDuration, residualSeconds: recipe.outDuration - (3.2 - 2.5)) : .exact(plan)
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0, roomTone: recipe.roomTone, fit: fit)
        let input = VoiceLabTakeInput(text: text.new, modelID: "fixture-model", recordID: record.id, language: "en", seed: 7,
            contentKey: project.media.source.contentKey, source: [], sourceSampleRate: 1_000, items: project.transcript!.words,
            window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "test", usd: 0.1, basis: "test")
        let quote = VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: estimate,
            region: .default, endpoint: "v1/text-to-speech/fixture/with-timestamps", languageMode: .explicit("en"), fingerprint: "reviewed")
        let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: quote.endpoint, modelID: input.modelID,
            voiceID: record.voiceId, requestID: quote.requestID, providerRequestID: nil, spendWarning: nil)
        let row = VoiceLabTakeRow(id: quote.requestID, index: 0, seed: 7, receipt: receipt, audio: audio,
            qa: .init(values: segment.qa, failures: []), score: 0.9, quote: .init(index: 0, seed: 7, synthesis: quote, qa: quote))
        let publication = VoiceLabPublishedTake(assets: project.voiceLab.assets ?? [], audio: recipe.audio,
            outDuration: recipe.outDuration, words: words, chunks: recipe.chunks)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: VoiceLabProjectError.videoModeUnsupported) {
            try VoiceLabRecipeBuilder.candidate(row: row, input: input, published: publication, record: record, createdAt: date, videoChoice: nil)
        }
        let chosen = try VoiceLabRecipeBuilder.candidate(row: row, input: input, published: publication, record: record,
            createdAt: date, videoChoice: changed ? .retimed : .source)
        #expect(chosen.recipe?.video.mode == (changed ? VoiceLabVideoMode.zoomCover : VoiceLabVideoMode.source))
        #expect(chosen.recipe?.audio == publication.audio && chosen.recipe?.words == publication.words)
        #expect(chosen.recipe?.chunks == publication.chunks && chosen.recipe?.provenance.requestId == receipt.requestID.uuidString)
        if changed {
            #expect(chosen.recipe?.video.zoom == 1.12 && chosen.recipe?.video.retimeFactor == 0.875)
            #expect(throws: VoiceLabProjectError.videoModeUnsupported) {
                try VoiceLabRecipeBuilder.candidate(row: row, input: input, published: publication, record: record, createdAt: date, videoChoice: .source)
            }
        }
    }
}
