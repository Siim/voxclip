#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite("Eleven v4 dialogue contract", .offlineFixtures)
struct VoiceLabDialogueTests {
    private func document() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/dialogue-cases.json")) as? [String: Any])
    }
    private func lab(response: Data, status: Int = 200, recorder: RequestRecorder = RequestRecorder(), multiplier: Double? = nil, maximum: Int? = nil,
                     prices: VoiceLabPriceCatalog? = VoiceLabPricingTests.catalogIfPresent) async throws -> ElevenLabsVoiceLab {
        let discovery = try #require(document()["discovery"] as? [String: Any])
        var modelRows = try #require(discovery["models"] as? [[String: Any]])
        if let index = modelRows.firstIndex(where: { $0["model_id"] as? String == "eleven_v4" }) {
            if let multiplier { modelRows[index]["model_rates"] = ["character_cost_multiplier": multiplier] }
            if let maximum { modelRows[index]["maximum_text_length_per_request"] = maximum }
        }
        let models = try JSONSerialization.data(withJSONObject: modelRows)
        let voices = try JSONSerialization.data(withJSONObject: try #require(discovery["voices"]))
        let base = SpeechStubHTTP.register { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            default:
                let body = try VoiceLabRequestFixtures.body(request)
                recorder.paid.withLock { $0.append(RecordedRequest(request: request, body: body)) }
                return (status, [:], response)
            }
        }
        let client = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-dialogue-key"),
            session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)),
            prices: prices)
        _ = try await client.models(); _ = try await client.voices()
        return client
    }
    private var voice: VoiceLabVoiceChoice { .stock(voiceID: "voice123") }
    private func response() throws -> Data {
        let cases = try #require(document()["responses"] as? [[String: Any]])
        return try JSONSerialization.data(withJSONObject: try #require(cases[0]["response"]))
    }
    @Test func sharedModelRoutesOfferV4AndKeepMultilingualDefault() async throws {
        let client = try await lab(response: response())
        let models = try await client.models()
        let takes = models.filter(\.supportsTimestampedTTS)
        #expect(takes.contains { $0.id == "eleven_v4" })
        #expect(!takes.contains { $0.id == "eleven_v4_turbo" })
        #expect(VoiceLabModel.patchDefault(models)?.id == "eleven_multilingual_v2")
        for row in try #require(document()["routes"] as? [[String: Any]]) {
            let id = try #require(row["modelId"] as? String)
            let canSpeak = try #require(row["can_do_text_to_speech"] as? Bool)
            let model = VoiceLabModel(id: id, name: id, languages: ["en"], canSpeak: canSpeak,
                canConvert: false, maximumTextLength: nil, characterCostMultiplier: nil)
            #expect(model.speechRoute?.rawValue == row["route"] as? String, Comment(rawValue: id))
            #expect(model.supportsTimestampedTTS == (row["route"] as? String != nil), Comment(rawValue: id))
        }
    }
    @Test func sharedRequestUsesExactDialogueBytesAndNoContext() async throws {
        let row = try #require((document()["requests"] as? [[String: Any]])?.first)
        let golden = try #require(row["request"] as? [String: Any])
        let recorder = RequestRecorder(), client = try await lab(response: response(), recorder: recorder)
        let options = VoiceLabSpeechOptions(seed: .max, previousText: "Never sent before", nextText: "Never sent after")
        let id = UUID()
        let quote = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
        #expect(quote.endpoint == "v1/text-to-dialogue/with-timestamps")
        #expect(quote.modelID == "eleven_v4" && quote.languageMode == .explicit("en"))
        let result = try await client.synthesize(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en",
            options: VoiceLabSpeechOptions(seed: .max, previousText: "Changed before", nextText: "Changed after"),
            requestID: id, authorization: VoiceLabAuthorization(quote: quote, approved: true))
        let calls = recorder.paid.withLock { $0 }
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.request.httpMethod == golden["method"] as? String)
        #expect(call.request.url?.path == golden["path"] as? String)
        #expect(call.request.url?.query == "output_format=pcm_24000")
        #expect(call.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: call.body, as: UTF8.self) == golden["bodyUTF8"] as? String)
        #expect(call.body.count == golden["bodyLength"] as? Int)
        #expect(VoiceLabFingerprint.bytes(call.body) == golden["bodySha256"] as? String)
        #expect(result.receipt.endpoint == quote.endpoint && result.receipt.modelID == "eleven_v4")
        #expect(result.alignment?.count == 2 && result.sampleRate == 24_000)
    }
    @Test func allSharedResponsesAreValidatedWithOneSendAndNoRetry() async throws {
        let rows = try #require(document()["responses"] as? [[String: Any]])
        #expect(rows.count == 21)
        for row in rows {
            let name = try #require(row["case"] as? String)
            let text = row["text"] as? String ?? "Hi"
            let bytes = try JSONSerialization.data(withJSONObject: try #require(row["response"]))
            let expected = try #require(row["expected"] as? String)
            let recorder = RequestRecorder(), client = try await lab(response: bytes, recorder: recorder)
            let id = UUID(), options = VoiceLabSpeechOptions(seed: 0)
            do {
                let quote = try await client.prepareSynthesis(text: text, modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
                let auth = VoiceLabAuthorization(quote: quote, approved: true)
                do {
                    let result = try await client.synthesize(text: text, modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id, authorization: auth)
                    #expect(expected == "success", Comment(rawValue: name))
                    #expect(result.alignment?.map(\.character).joined() == text)
                } catch {
                    let wanted: VoiceLabError = expected == "invalidAlignment" ? .invalidAlignment : .malformedResponse
                    #expect(expected != "success" && error as? VoiceLabError == wanted, Comment(rawValue: name))
                }
                await #expect(throws: VoiceLabError.consentRequired) {
                    _ = try await client.synthesize(text: text, modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id, authorization: auth)
                }
            } catch { Issue.record(error, Comment(rawValue: name)) }
            #expect(recorder.paid.withLock { $0.count } == 1, Comment(rawValue: name))
        }
    }
    @Test func approvalCannotCrossRoutesInEitherDirection() async throws {
        let recorder = RequestRecorder(), client = try await lab(response: response(), recorder: recorder)
        let id = UUID(), options = VoiceLabSpeechOptions(seed: 7)
        let tts = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v3", voice: voice, language: "en", options: options, requestID: id)
        let dialogue = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
        #expect(tts.endpoint != dialogue.endpoint)
        #expect(tts.endpoint == "v1/text-to-speech/voice123/with-timestamps")
        #expect(dialogue.endpoint == "v1/text-to-dialogue/with-timestamps")
        for (quote, sent) in [(tts, "eleven_v4"), (dialogue, "eleven_v3")] {
            await #expect(throws: VoiceLabError.consentRequired) {
                _ = try await client.synthesize(text: "Hi", modelID: sent, voice: voice, language: "en", options: options, requestID: id,
                    authorization: VoiceLabAuthorization(quote: quote, approved: true))
            }
        }
        #expect(recorder.paid.withLock { $0.isEmpty })
    }
    @Test func dialogueTextLimitRefusesBeforeSend() async throws {
        let recorder = RequestRecorder(), client = try await lab(response: response(), recorder: recorder)
        let options = VoiceLabSpeechOptions(seed: 0), id = UUID()
        for count in [2_000, 2_001, 5_000, 5_001] {
            let text = String(repeating: "a", count: count)
            if count <= 2_000 {
                _ = try await client.prepareSynthesis(text: text, modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
            } else {
                await #expect(throws: VoiceLabError.invalidInput) {
                    _ = try await client.prepareSynthesis(text: text, modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
                }
            }
        }
        let quote = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
        await #expect(throws: VoiceLabError.invalidInput) {
            _ = try await client.synthesize(text: String(repeating: "a", count: 2_001), modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id,
                authorization: VoiceLabAuthorization(quote: quote, approved: true))
        }
        #expect(recorder.paid.withLock { $0.isEmpty })
    }
    @Test func dialogueUsesTheCatalogMultiplierAndPreservesUnknownPrices() async throws {
        let options = VoiceLabSpeechOptions(seed: 0)
        let client = try await lab(response: response(), multiplier: 2)
        let priced = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: UUID())
        #expect(priced.estimate.units == 2 && priced.estimate.unit == "character")
        #expect(priced.estimate.usd == Decimal(string: "0.00016") && priced.estimate.credits == 4)
        var catalog = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("catalog/voice-lab.json")) as? [String: Any])
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        catalog["entries"] = entries.filter { $0["model"] as? String != "eleven_v4" }
        let missing = try VoiceLabPriceCatalog(data: JSONSerialization.data(withJSONObject: catalog))
        let unpriced = try await lab(response: response(), prices: missing)
        let quote = try await unpriced.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: UUID())
        #expect(quote.estimate.usd == nil && quote.estimate.credits == nil && quote.estimate.basis == "unknown")
    }
    @Test func dialogueHonorsTheSmallerDiscoveredLimit() async throws {
        let client = try await lab(response: response(), maximum: 1)
        await #expect(throws: VoiceLabError.invalidInput) {
            _ = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: VoiceLabSpeechOptions(seed: 0), requestID: UUID())
        }
    }
    @Test func dialoguePermissionFailuresNameTheTTSPermission() async throws {
        let recorder = RequestRecorder()
        let client = try await lab(response: Data(#"{"detail":{"status":"missing_permissions"}}"#.utf8), status: 403, recorder: recorder)
        let id = UUID(), options = VoiceLabSpeechOptions(seed: 0)
        let quote = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
        await #expect(throws: VoiceLabError.permissionMissing("text_to_speech")) {
            _ = try await client.synthesize(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id,
                authorization: VoiceLabAuthorization(quote: quote, approved: true))
        }
        #expect(recorder.paid.withLock { $0.count } == 1)
    }
    @Test(arguments: [429, 500]) func dialogueFailuresNeverRetry(status: Int) async throws {
        let recorder = RequestRecorder(), client = try await lab(response: Data(), status: status, recorder: recorder)
        let id = UUID(), options = VoiceLabSpeechOptions(seed: 0)
        let quote = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
        do {
            _ = try await client.synthesize(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id,
                authorization: VoiceLabAuthorization(quote: quote, approved: true))
            Issue.record("Expected provider refusal")
        } catch { #expect(error as? VoiceLabError == (status == 429 ? .rateLimited : .providerFailure(status))) }
        #expect(recorder.paid.withLock { $0.count } == 1)
    }
}
#endif
