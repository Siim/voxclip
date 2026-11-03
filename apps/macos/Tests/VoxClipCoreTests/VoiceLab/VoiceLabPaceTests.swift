#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite("Speech pace contract", .offlineFixtures)
struct VoiceLabPaceTests {
    private var voice: VoiceLabVoiceChoice { .stock(voiceID: "voice123") }
    private func document() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/pace-cases.json")) as? [String: Any])
    }
    private func client(_ recorder: RequestRecorder) async throws -> ElevenLabsVoiceLab {
        let root = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/dialogue-cases.json")) as? [String: Any])
        let discovery = try #require(root["discovery"] as? [String: Any])
        let models = try JSONSerialization.data(withJSONObject: try #require(discovery["models"]))
        let voices = try JSONSerialization.data(withJSONObject: try #require(discovery["voices"]))
        let rows = try #require(root["responses"] as? [[String: Any]])
        let response = try JSONSerialization.data(withJSONObject: try #require(rows.first?["response"]))
        let base = SpeechStubHTTP.register { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            default:
                let body = try VoiceLabRequestFixtures.body(request)
                recorder.paid.withLock { $0.append(RecordedRequest(request: request, body: body)) }
                return (200, [:], response)
            }
        }
        let lab = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-key"),
            session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), prices: VoiceLabPricingTests.catalogIfPresent)
        _ = try await lab.models(); _ = try await lab.voices()
        return lab
    }
    private func prepare(_ lab: ElevenLabsVoiceLab, model: String, options: VoiceLabSpeechOptions, id: UUID) async throws -> VoiceLabQuote {
        try await lab.prepareSynthesis(text: "Hi", modelID: model, voice: voice, language: "en", options: options, requestID: id)
    }
    private func send(_ lab: ElevenLabsVoiceLab, model: String, options: VoiceLabSpeechOptions, id: UUID,
                      quote: VoiceLabQuote) async throws -> VoiceLabAudioResult {
        try await lab.synthesize(text: "Hi", modelID: model, voice: voice, language: "en", options: options,
            requestID: id, authorization: VoiceLabAuthorization(quote: quote, approved: true))
    }
    @Test(arguments: ["tts_default", "tts_explicit_default", "tts_slow", "tts_fast", "tts_round_half_up", "tts_round_to_default",
                      "tts_minimum", "tts_maximum", "tts_below_range", "tts_before_rounding_low", "tts_before_rounding_high",
                      "dialogue_default", "dialogue_explicit_default", "dialogue_nondefault", "dialogue_rounded_default_refused"])
    func sharedRequestsAndRefusals(name: String) async throws {
        let root = try document()
        #expect(root["schema"] as? String == "voxclip-voice-lab-pace-cases/1")
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(root["caseCount"] as? Int == 15 && cases.count == 15)
        let row = try #require(cases.first { $0["case"] as? String == name })
        let model = try #require(row["modelId"] as? String)
        let options = VoiceLabSpeechOptions(seed: 7, pace: row["pace"] as? Double)
        let recorder = RequestRecorder(), lab = try await client(recorder), id = UUID()
        if row["expected"] as? String == "invalidInput" {
            await #expect(throws: VoiceLabError.invalidInput) { try await prepare(lab, model: model, options: options, id: id) }
            let quote = try await prepare(lab, model: model, options: .init(seed: 7), id: id)
            await #expect(throws: VoiceLabError.invalidInput) { try await send(lab, model: model, options: options, id: id, quote: quote) }
            #expect(recorder.paid.withLock { $0.isEmpty })
            return
        }
        let quote = try await prepare(lab, model: model, options: options, id: id)
        let result = try await send(lab, model: model, options: options, id: id, quote: quote)
        let calls = recorder.paid.withLock { $0 }
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.request.url?.path == row["path"] as? String)
        #expect(call.request.url?.query == "output_format=pcm_24000")
        let expected = try #require(row["canonicalJSON"] as? String)
        let parsed = try #require(JSONSerialization.jsonObject(with: call.body) as? NSDictionary)
        let expectedJSON = try #require(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? [String: Any])
        #expect(parsed.isEqual(to: expectedJSON))
        if row["exactBytes"] as? Bool == true { #expect(call.body == Data(expected.utf8)) }
        #expect(quote.pace == (options.pace ?? 1))
        #expect(result.receipt.pace == row["receiptPace"] as? Double)
        let defaultQuote = try await prepare(lab, model: model, options: .init(seed: 7), id: UUID())
        #expect(quote.estimate == defaultQuote.estimate)
    }
    @Test(arguments: [(0.8, 0.9), (0.8, 1.0), (1.0, 0.8), (0.801, 0.802)])
    func approvalCannotChangePace(paces: (Double, Double)) async throws {
        let recorder = RequestRecorder(), lab = try await client(recorder), id = UUID()
        let quote = try await prepare(lab, model: "eleven_multilingual_v2", options: .init(seed: 7, pace: paces.0), id: id)
        await #expect(throws: VoiceLabError.consentRequired) {
            try await send(lab, model: "eleven_multilingual_v2", options: .init(seed: 7, pace: paces.1), id: id, quote: quote)
        }
        #expect(recorder.paid.withLock { $0.isEmpty })
    }
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonfinitePaceNeverQuotesOrSends(pace: Double) async throws {
        let recorder = RequestRecorder(), lab = try await client(recorder), id = UUID()
        await #expect(throws: VoiceLabError.invalidInput) {
            try await prepare(lab, model: "eleven_multilingual_v2", options: .init(seed: 7, pace: pace), id: id)
        }
        let quote = try await prepare(lab, model: "eleven_multilingual_v2", options: .init(seed: 7), id: id)
        await #expect(throws: VoiceLabError.invalidInput) {
            try await send(lab, model: "eleven_multilingual_v2", options: .init(seed: 7, pace: pace), id: id, quote: quote)
        }
        #expect(recorder.paid.withLock { $0.isEmpty })
    }
    @Test func nilAndDefaultShareApprovalWithoutAddingSettings() async throws {
        let recorder = RequestRecorder(), lab = try await client(recorder), id = UUID()
        let quote = try await prepare(lab, model: "eleven_multilingual_v2", options: .init(seed: 7), id: id)
        _ = try await send(lab, model: "eleven_multilingual_v2", options: .init(seed: 7, pace: 1), id: id, quote: quote)
        let body = try #require(recorder.paid.withLock { $0.first?.body })
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["voice_settings"] as? [String: Any])?["speed"] == nil)
    }
    @Test func clampAndOldProjectProvenance() throws {
        #expect(VoiceLabPace.clamp(0.5) == 0.7 && VoiceLabPace.clamp(2) == 1.2)
        #expect(VoiceLabPace.clamp(.nan) == 1 && VoiceLabPace.clamp(0.8) == 0.8)
        #expect(VoiceLabPace.clamp(.infinity) == 1.2 && VoiceLabPace.clamp(-.infinity) == 0.7)
        let project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        var provenance = try #require(project.voiceLab.segments[0].candidates[0].recipe?.provenance)
        #expect(provenance.pace == nil)
        let oldBytes = try JSONEncoder().encode(provenance)
        #expect(!String(decoding: oldBytes, as: UTF8.self).contains("\"pace\""))
        provenance.pace = 0.8
        let roundTrip = try JSONDecoder().decode(VoiceLabProvenance.self, from: JSONEncoder().encode(provenance))
        #expect(roundTrip.pace == 0.8)
        var paced = project
        paced.voiceLab.segments[0].provenance.pace = 0.8
        paced.voiceLab.segments[0].candidates[0].recipe?.provenance.pace = 0.8
        let decoded = try JSONProjectStore.decode(JSONProjectStore.encode(paced))
        #expect(decoded.voiceLab.segments[0].provenance.pace == 0.8)
        #expect(decoded.voiceLab.segments[0].candidates[0].recipe?.provenance.pace == 0.8)
    }
    @Test(arguments: ["0.5", "1.3", "null", "\"0.8\""])
    func projectRefusesInvalidPaceInSegmentAndRecipe(value: String) throws {
        for recipe in [false, true] {
            var json = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip")) as? [String: Any])
            var voiceLab = try #require(json["voiceLab"] as? [String: Any])
            var segments = try #require(voiceLab["segments"] as? [[String: Any]])
            let pace = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
            if recipe {
                var candidates = try #require(segments[0]["candidates"] as? [[String: Any]])
                var storedRecipe = try #require(candidates[0]["recipe"] as? [String: Any])
                var provenance = try #require(storedRecipe["provenance"] as? [String: Any])
                provenance["pace"] = pace; storedRecipe["provenance"] = provenance
                candidates[0]["recipe"] = storedRecipe; segments[0]["candidates"] = candidates
            } else {
                var provenance = try #require(segments[0]["provenance"] as? [String: Any])
                provenance["pace"] = pace; segments[0]["provenance"] = provenance
            }
            voiceLab["segments"] = segments; json["voiceLab"] = voiceLab
            let bytes = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try JSONProjectStore.decode(bytes) }
        }
    }
}
#endif
