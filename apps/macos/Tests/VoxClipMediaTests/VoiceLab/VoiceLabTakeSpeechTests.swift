#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

private actor GeneratedSpeechProbe: SpeakerEmbedder {
    nonisolated let modelID = "fixture-generated-speech"
    nonisolated let dimension = 2
    let retainedFrames: Int?
    let vector: [Float]
    let availabilityError: VoiceConsentError?
    let voicedError: VoiceConsentError?
    let invalidVoicedSample: Bool
    var validations = 0
    var voicedInputs: [[Float]] = []
    var embeddedWindows: [[Float]] = []

    init(retainedFrames: Int? = nil, vector: [Float] = [3, 4], availabilityError: VoiceConsentError? = nil,
         voicedError: VoiceConsentError? = nil, invalidVoicedSample: Bool = false) {
        self.retainedFrames = retainedFrames; self.vector = vector; self.availabilityError = availabilityError
        self.voicedError = voicedError; self.invalidVoicedSample = invalidVoicedSample
    }
    func validateAvailability() async throws {
        validations += 1
        if let availabilityError { throw availabilityError }
    }
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] {
        voicedInputs.append(pcm16k)
        if let voicedError { throw voicedError }
        var voiced = Array(pcm16k.prefix(retainedFrames ?? pcm16k.count))
        if invalidVoicedSample { voiced.append(.nan) }
        return voiced
    }
    func embed(_ pcm16k: [Float]) async throws -> [Float] {
        embeddedWindows.append(pcm16k)
        return vector
    }
}

@Suite("Generated take speech evidence", .offlineFixtures)
struct VoiceLabTakeSpeechTests {
    private func samples(frames: Int) -> [Float] {
        (0..<frames).map { Float(sin(Double($0) * 0.071) * 0.2) }
    }
    private func check(_ embedder: GeneratedSpeechProbe) -> VoiceSpeakerCheck {
        VoiceSpeakerCheck(embedder: embedder, calibratedThreshold: 0.45, language: "en")
    }

    @Test(arguments: [32_640, 57_600, 59_520, 71_040, 71_999])
    func shortGeneratedAudioReachesVADButNotEmbedding(frames: Int) async throws {
        let probe = GeneratedSpeechProbe()
        await #expect(throws: VoiceSpeakerCheck.GeneratedSpeechError.insufficientSpeech) {
            try await check(probe).generatedEmbedding(samples(frames: frames), sampleRate: 24_000)
        }
        #expect(await probe.validations == 1)
        #expect(await probe.voicedInputs.count == 1)
        #expect(await probe.embeddedWindows.isEmpty)
    }

    @Test(arguments: [72_000, 108_000])
    func sufficientSpeechUsesIdenticalCalibratedPreprocessing(frames: Int) async throws {
        let generated = samples(frames: frames)
        let resampled = VoiceConsentAudio.resample(generated, rate: 24_000)
        let probe = GeneratedSpeechProbe(), canonical = GeneratedSpeechProbe()
        let actual = try await check(probe).generatedEmbedding(generated, sampleRate: 24_000)
        let expected = try await check(canonical).embedding(resampled)
        #expect(actual == expected)
        #expect(await probe.validations == 2)
        #expect(await probe.voicedInputs == [resampled])
        let actualWindows = await probe.embeddedWindows
        let canonicalWindows = await canonical.embeddedWindows
        #expect(actualWindows == (try SpeakerAudio.windows(resampled)))
        #expect(actualWindows == canonicalWindows)
    }

    @Test(arguments: [0, 47_999])
    func longEnoughFileWithTooLittleVoicedSpeechIsNotASpeakerMismatch(retainedFrames: Int) async throws {
        let probe = GeneratedSpeechProbe(retainedFrames: retainedFrames)
        await #expect(throws: VoiceSpeakerCheck.GeneratedSpeechError.insufficientSpeech) {
            try await check(probe).generatedEmbedding(samples(frames: 74_880), sampleRate: 24_000)
        }
        #expect(await probe.validations == 1)
        #expect(await probe.voicedInputs.count == 1)
        #expect(await probe.embeddedWindows.isEmpty)
    }

    @Test func exactlyThreeSecondsOfRetainedSpeechIsNotPaddedOrRepeated() async throws {
        let generated = samples(frames: 96_000)
        let voiced = Array(VoiceConsentAudio.resample(generated, rate: 24_000).prefix(48_000))
        let probe = GeneratedSpeechProbe(retainedFrames: 48_000)
        let vector = try await check(probe).generatedEmbedding(generated, sampleRate: 24_000)
        #expect(vector == (try SpeakerAudio.normalized([3, 4])))
        #expect(await probe.embeddedWindows == [voiced])
    }

    @Test(arguments: [[Float](repeating: 0, count: 2), [1], [.nan, 1]])
    func malformedVectorsAreNotMisreportedAsShortSpeech(vector: [Float]) async throws {
        let probe = GeneratedSpeechProbe(vector: vector)
        await #expect(throws: VoiceConsentError.speakerMismatch) {
            try await check(probe).generatedEmbedding(samples(frames: 72_000), sampleRate: 24_000)
        }
        #expect(await probe.embeddedWindows.count == 1)
    }

    @Test func malformedShortVADOutputIsNotMisreportedAsSpeechDuration() async throws {
        let probe = GeneratedSpeechProbe(retainedFrames: 47_998, invalidVoicedSample: true)
        await #expect(throws: VoiceConsentError.speakerMismatch) {
            try await check(probe).generatedEmbedding(samples(frames: 72_000), sampleRate: 24_000)
        }
        #expect(await probe.embeddedWindows.isEmpty)
    }

    @Test func unavailableAssetsRemainUnavailable() async throws {
        let probe = GeneratedSpeechProbe(availabilityError: .speakerUnavailable)
        await #expect(throws: VoiceConsentError.speakerUnavailable) {
            try await check(probe).generatedEmbedding(samples(frames: 72_000), sampleRate: 24_000)
        }
        #expect(await probe.validations == 1)
        #expect(await probe.voicedInputs.isEmpty)
        #expect(await probe.embeddedWindows.isEmpty)
    }

    @Test func VADFailureIsNotRelabeledWithoutDurationEvidence() async throws {
        let probe = GeneratedSpeechProbe(voicedError: .speakerMismatch)
        await #expect(throws: VoiceConsentError.speakerMismatch) {
            try await check(probe).generatedEmbedding(samples(frames: 72_000), sampleRate: 24_000)
        }
        #expect(await probe.embeddedWindows.isEmpty)
    }

    @Test func invalidAudioNeverReachesSpeakerServices() async throws {
        let probe = GeneratedSpeechProbe()
        await #expect(throws: VoiceLabError.invalidAudio) {
            try await check(probe).generatedEmbedding([.nan], sampleRate: 24_000)
        }
        await #expect(throws: VoiceLabError.invalidAudio) {
            try await check(probe).generatedEmbedding(samples(frames: 72_000), sampleRate: 0)
        }
        #expect(await probe.validations == 0)
        #expect(await probe.voicedInputs.isEmpty)
        #expect(await probe.embeddedWindows.isEmpty)
    }
}
#endif
