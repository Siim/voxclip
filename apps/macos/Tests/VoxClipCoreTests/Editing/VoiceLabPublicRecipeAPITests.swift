import Foundation
import Testing
import VoxClipCore

@Suite struct VoiceLabPublicRecipeAPITests {
    @Test func externalCallerCanConstructCompleteV3Recipe() {
        let assetId = "new-voice-take"
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let roomTone = VoiceLabRoomTone(sourceStartSample: 0, sourceEndSample: 500, gainDb: -12)
        let videoAsset = VoiceLabVideoAsset(id: "new-video", file: "new-video.mov", sha256: String(repeating: "a", count: 64),
                                             durationSeconds: 0.7, frameRate: 30, width: 1920, height: 1080)
        let incoming = VoiceLabSeam(kind: .gap, fadeSamples: 20, sourceHandleSamples: 10, assetHandleFrames: 480)
        let outgoing = VoiceLabSeam(kind: .gap, fadeSamples: 20, sourceHandleSamples: 10, assetHandleFrames: 480)
        let seams = VoiceLabSeams(in: incoming, out: outgoing)
        let chunk = VoiceLabChunk(sourceStartSample: 1000, sourceEndSample: 1700, requestId: "new-request", seed: 7,
                                  assetId: assetId, assetSha256: String(repeating: "b", count: 64),
                                  assembledStartFrame: 0, assembledEndFrame: 33_600)
        let video = VoiceLabVideoRecipe(mode: .source, sourceStartSample: 1000, sourceEndSample: 1700, outputSamples: 700,
                                        retimeFactor: nil, zoom: nil, faceX: nil, faceY: nil, assetId: nil,
                                        provider: nil, model: nil, requestId: nil, windowStartSample: nil,
                                        windowEndSample: nil, syncMode: nil)
        let qa = VoiceLabRenderQA(transcriptTokens: 1, transcriptExact: true, transcriptMatch: 1,
                                  lufsJumpLu: 1, peakDbfs: -3, speakerScore: 0.95, speakerThreshold: 0.8,
                                  speakerModel: "review-model", speakerPassed: true)
        let cost = VoiceLabCost(quoteId: "new-quote", usd: nil)
        let audio = VoiceLabAudio(assetId: assetId, trimStart: 0, trimEnd: 0.7, stretch: 1, gainDb: 0)
        let provenance = VoiceLabProvenance(provider: "example", endpoint: "v1/text-to-speech/voice/with-timestamps",
                                            model: "example-model", voiceId: "voice", consentRecordId: "consent",
                                            requestId: "new-request", seed: 7, createdAt: createdAt)
        let recipe = VoiceLabRenderRecipe(audio: audio, words: [VoiceLabWord(text: "Hello", start: 0, end: 0.7, synthetic: true)],
                                          outDuration: 0.7, seed: 7, chunks: [chunk], roomTone: roomTone,
                                          seams: seams, video: video, qa: qa, provenance: provenance, cost: cost,
                                          voiceSource: .own, voiceRefId: "voice-ref", consentVerifiedAt: createdAt)
        var candidate = VoiceLabCandidate(assetId: assetId, score: 0.95)
        candidate.recipe = recipe

        #expect(candidate.recipe == recipe)
        #expect(candidate.recipe?.seams.in == incoming)
        #expect(videoAsset.id == "new-video")
    }
}
