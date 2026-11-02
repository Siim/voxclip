import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabRecipeBuilderTests {
    @Test(arguments: [0, 1, 2], ["consent-record.json", "consent-record-project.json"])
    func paidAndFittedRecipesPassV3WithoutChangingSource(policy: Int, recordFile: String) throws {
        let fitted = policy == 1
        let unmeasured = policy == 2
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        let previous = project
        let stored = project.voiceLab.segments[0]
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: FixtureLoader.data("fixtures/voice-lab/\(recordFile)"))
        let asset = try #require(project.voiceLab.assets?.first)
        var audio = stored.audio; audio.stretch = 1
        var assets = [asset]
        if fitted {
            var derived = asset; derived.id = "fitted-test"; derived.file = try VoiceLabAssetNaming.file(projectId: project.id, assetId: derived.id, extension: "wav")
            assets.append(derived); audio.assetId = derived.id
        }
        let window = VoiceLabWindow(firstWordId: stored.replace.firstWordId, lastWordId: stored.replace.lastWordId,
            leftBridgeWordIds: [], rightBridgeWordIds: [], start: 2.5, end: 3.2, startSample: 2500, endSample: 3200,
            leftSeam: .init(kind: .gap, time: 2.5, sample: 2500, fadeSamples: 20), rightSeam: .init(kind: .gap, time: 3.2, sample: 3200, fadeSamples: 20))
        let words = try #require(stored.words)
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 2400, trimEndFrame: 19200, windowStart: 2.5, windowEnd: 3.2, windowStartSample: 2500, windowEndSample: 3200,
            outputFrames: 16800, words: words)
        let input = VoiceLabTakeInput(text: "new words", modelID: "fixture-model", recordID: record.id, language: "en", seed: 7,
            contentKey: project.media.source.contentKey, source: [], sourceSampleRate: 1000, items: project.transcript!.words,
            window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let take = VoiceLabTakeAudio(sampleRate: 24000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0, roomTone: stored.candidates[0].recipe?.roomTone, fit: .exact(plan))
        let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "test", usd: 0.1, basis: "test")
        let quote = VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: estimate,
            region: .default, endpoint: "v1/text-to-speech/fixture/with-timestamps", languageMode: .explicit("en"), fingerprint: "test")
        let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: quote.endpoint, modelID: input.modelID,
            voiceID: record.voiceId, requestID: quote.requestID, providerRequestID: nil, spendWarning: nil)
        let evidence = VoiceLabShortSpeechEvidence(mode: .unmeasured, recordID: record.id,
            consentMethod: record.consentMethod, voicedFrames: 16_800, takeCount: 1)
        var values = stored.qa
        if unmeasured { values.speakerScore = nil }
        let row = VoiceLabTakeRow(id: quote.requestID, index: 0, seed: 7, receipt: receipt, audio: take,
            qa: VoiceLabTakeQAResult(values: values, failures: []), score: 0.9,
            quote: .init(index: 0, seed: 7, synthesis: quote, qa: quote), voiceCheck: unmeasured ? .shortSpeech(evidence) : .perTake)
        let published = VoiceLabPublishedTake(assets: assets, audio: audio, outDuration: 3.2 - 2.5, words: words,
            chunks: stored.candidates[0].recipe!.chunks)
        let candidate = try VoiceLabRecipeBuilder.candidate(row: row, input: input, published: published, record: record,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), videoChoice: .source)
        #expect(candidate.recipe?.audio.assetId == (fitted ? "fitted-test" : asset.id))
        #expect(candidate.recipe?.chunks[0].assetId == asset.id)
        #expect(candidate.recipe?.cost.usd == 0.2)
        #expect(candidate.recipe?.qa.shortSpeech == (unmeasured ? evidence : nil))
        #expect(candidate.recipe?.qa.speakerPassed == !unmeasured)
        #expect((candidate.recipe?.qa.speakerScore == nil) == unmeasured)
        let segment = try VoiceLabRecipeBuilder.segment(id: "accepted-test", candidates: [candidate], selected: 0, input: input, plan: plan)
        project.voiceLab.segments = []; project.voiceLab.assets = []; project.voiceLab.voices = []
        project = try VoiceLabProject.addVoiceReference(.init(id: record.id, provider: record.provider, voiceId: record.voiceId,
            consentRecordId: record.id, displayName: record.voiceName, status: .active), to: project)
        let accepted = try VoiceLabProject.accept(segment, assets: assets, into: project)
        try VoiceLabProject.validate(accepted)
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(accepted)) == accepted)
        #expect(accepted.transcript == previous.transcript && accepted.edits == previous.edits)
        _ = try VoiceLabRenderContract.prepare(accepted, scope: .full, labelPosition: .topRight)
        if unmeasured {
            if SchemaPython.enabled {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-short-speech-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("accepted.voxclip")
                try JSONProjectStore.encode(accepted).write(to: file)
                try SchemaPython.validate([file])
            }
            var forged = accepted
            forged.voiceLab.segments[0].candidates[0].recipe?.qa.shortSpeech = nil
            #expect(throws: VoiceLabProjectError.qaRejected) { try VoiceLabProject.validate(forged) }
            forged = accepted
            forged.voiceLab.segments[0].candidates[0].recipe?.qa.speakerPassed = true
            #expect(throws: VoiceLabProjectError.qaRejected) { try VoiceLabProject.validate(forged) }
        }
        for duration in [Double.infinity, .nan, .greatestFiniteMagnitude, -1] {
            let invalid = VoiceLabPublishedTake(assets: assets, audio: audio, outDuration: duration, words: words, chunks: published.chunks)
            #expect(throws: VoiceLabProjectError.self) {
                try VoiceLabRecipeBuilder.candidate(row: row, input: input, published: invalid, record: record,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000), videoChoice: nil)
            }
        }
        var longerPlan = plan
        longerPlan.trimEndFrame = 20_400; longerPlan.outputFrames = 18_000
        let longerTake = VoiceLabTakeAudio(sampleRate: 24000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0,
            roomTone: take.roomTone, fit: .changedDuration(longerPlan, naturalOut: 0.75, residualSeconds: 0.05))
        let longerRow = VoiceLabTakeRow(id: row.id, index: row.index, seed: row.seed, receipt: receipt, audio: longerTake,
            qa: row.qa, score: row.score, quote: row.quote, voiceCheck: row.voiceCheck)
        var longerAudio = audio; longerAudio.trimEnd = 0.85
        var chunk = stored.candidates[0].recipe!.chunks[0]; chunk.assembledEndFrame = 20_400
        let longerPublished = VoiceLabPublishedTake(assets: assets, audio: longerAudio, outDuration: (3.2 - 2.5) + 0.05,
            words: words, chunks: [chunk])
        for choice: VoiceLabVideoMode? in [nil, .lipsync] {
            #expect(throws: VoiceLabProjectError.videoModeUnsupported) {
                try VoiceLabRecipeBuilder.candidate(row: longerRow, input: input, published: longerPublished, record: record,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000), videoChoice: choice)
            }
        }
        let retimed = try VoiceLabRecipeBuilder.candidate(row: longerRow, input: input, published: longerPublished, record: record,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), videoChoice: .retimed)
        let retimedSegment = try VoiceLabRecipeBuilder.segment(id: "retimed", candidates: [retimed], selected: 0, input: input, plan: longerPlan)
        let retimedProject = try VoiceLabProject.accept(retimedSegment, assets: assets, into: project)
        try VoiceLabProject.validate(retimedProject)
        #expect(retimed.recipe?.video.mode == .zoomCover && retimed.recipe?.video.zoom == 1.12)
        _ = try VoiceLabRenderContract.prepare(retimedProject, scope: .full, labelPosition: .topRight)
        var failed = row
        failed = VoiceLabTakeRow(id: row.id, index: 0, seed: 7, receipt: receipt, audio: take,
            qa: VoiceLabTakeQAResult(values: stored.qa, failures: [.speaker]), quote: row.quote)
        #expect(throws: VoiceLabProjectError.qaRejected) {
            try VoiceLabRecipeBuilder.candidate(row: failed, input: input, published: published, record: record, createdAt: Date(), videoChoice: nil)
        }
    }
}
