import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite("Real CPU speaker parity", .serialized)
struct SpeakerModelTests {
    static var modelDirectory: String? { ProcessInfo.processInfo.environment["VOXCLIP_SPEAKER_MODEL_DIR"] }
    @Test(.enabled(if: modelDirectory != nil, "Weights are not committed. Set VOXCLIP_SPEAKER_MODEL_DIR to the verified local model/VAD cache; tests never download."))
    func vectorsMatchRealONNXAndSilero() async throws {
        let shared = try SharedResources.locate()
        let model = try SpeakerModelCatalog(shared: shared).entry
        let directory = URL(fileURLWithPath: try #require(Self.modelDirectory))
        let embedder = try ONNXSpeakerEmbedder(model: model, directory: directory)
        let check = VoiceSpeakerCheck(embedder: embedder, calibratedThreshold: model.calibratedThreshold())
        struct Vectors: Decodable {
            struct Clip: Decodable { let id: String; let sha256: String; let ranges: [[Int]]; let embedding: [Float] }
            let clips: [Clip]
            let embeddingAbsoluteTolerance: Float
            let scoreAbsoluteTolerance: Double
        }
        let root = shared.root.appendingPathComponent("fixtures/voice-lab/speaker")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("vectors.json")))
        var actual: [[Float]] = []
        for clip in vectors.clips {
            let data = try Data(contentsOf: root.appendingPathComponent(clip.id + ".wav"))
            #expect(SpeechSHA256.hex(data) == clip.sha256)
            let pcm = try VoiceConsentAudio.pcm16k(data)
            let ranges = try SpeakerVAD.ranges(pcm, model: directory.appendingPathComponent("ggml-silero-v6.2.0.bin"))
            #expect(ranges.map { [$0.lowerBound, $0.upperBound] } == clip.ranges)
            let result = try await check.embedding(pcm)
            #expect(result.count == 256)
            for index in result.indices { #expect(abs(result[index] - clip.embedding[index]) <= vectors.embeddingAbsoluteTolerance) }
            actual.append(result)
        }
        for left in actual.indices {
            for right in actual.indices where right > left {
                let score = try VoiceSpeakerCheck.cosine(actual[left], actual[right])
                let expected = try VoiceSpeakerCheck.cosine(vectors.clips[left].embedding, vectors.clips[right].embedding)
                #expect(abs(score - expected) <= vectors.scoreAbsoluteTolerance)
            }
        }
    }
    @Test func missingModelNeverCreatesRuntime() throws {
        let model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        #expect(throws: (any Error).self) { try ONNXSpeakerEmbedder(model: model, directory: URL(fileURLWithPath: "/voxclip-no-model")) }
    }
}
