import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabRecipeBuilderTests {
    @Test(arguments: [false, true])
    func paidAndFittedRecipesPassV3WithoutChangingSource(fitted: Bool) throws {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        let previous = project
        let stored = project.voiceLab.segments[0]
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: FixtureLoader.data("fixtures/voice-lab/consent-record.json"))
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
        let row = VoiceLabTakeRow(id: quote.requestID, index: 0, seed: 7, receipt: receipt, audio: take,
            qa: VoiceLabTakeQAResult(values: stored.qa, failures: []), score: 0.9, quote: .init(index: 0, seed: 7, synthesis: quote, qa: quote))
        let published = VoiceLabPublishedTake(assets: assets, audio: audio, outDuration: 3.2 - 2.5, words: words,
            chunks: stored.candidates[0].recipe!.chunks)
        let candidate = try VoiceLabRecipeBuilder.candidate(row: row, input: input, published: published, record: record,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), videoChoice: nil)
        #expect(candidate.recipe?.audio.assetId == (fitted ? "fitted-test" : asset.id))
        #expect(candidate.recipe?.chunks[0].assetId == asset.id)
        #expect(candidate.recipe?.cost.usd == 0.2)
        let segment = try VoiceLabRecipeBuilder.segment(id: "accepted-test", candidates: [candidate], selected: 0, input: input, plan: plan)
        project.voiceLab.segments = []; project.voiceLab.assets = []; project.voiceLab.voices = []
        project = try VoiceLabProject.addVoiceReference(.init(id: record.id, provider: record.provider, voiceId: record.voiceId,
            consentRecordId: record.id, displayName: record.voiceName, status: .active), to: project)
        let accepted = try VoiceLabProject.accept(segment, assets: assets, into: project)
        try VoiceLabProject.validate(accepted)
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(accepted)) == accepted)
        #expect(accepted.transcript == previous.transcript && accepted.edits == previous.edits)
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
            qa: row.qa, score: row.score, quote: row.quote)
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
        try VoiceLabProject.validate(VoiceLabProject.accept(retimedSegment, assets: assets, into: project))
        var failed = row
        failed = VoiceLabTakeRow(id: row.id, index: 0, seed: 7, receipt: receipt, audio: take,
            qa: VoiceLabTakeQAResult(values: stored.qa, failures: [.speaker]), quote: row.quote)
        #expect(throws: VoiceLabProjectError.qaRejected) {
            try VoiceLabRecipeBuilder.candidate(row: failed, input: input, published: published, record: record, createdAt: Date(), videoChoice: nil)
        }
    }
}
