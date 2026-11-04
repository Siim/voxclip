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
                     prices: VoiceLabPriceCatalog? = VoiceLabPricingTests.catalogIfPresent,
                     logger: any Redacting = RedactingLogger(homeDirectory: "/synthetic-home"), diagnosticDirectory: URL? = nil) async throws -> ElevenLabsVoiceLab {
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
            logger: logger, prices: prices, validationDiagnosticDirectory: diagnosticDirectory)
        _ = try await client.models(); _ = try await client.voices()
        return client
    }
    private var voice: VoiceLabVoiceChoice { .stock(voiceID: "voice123") }
    @Test(arguments: ["eleven_v3", "eleven_v4", "eleven_multilingual_v2"])
    func tagRequestsAreModelGatedBilledAndApprovalBound(model: String) async throws {
        let recorder = RequestRecorder(), client = try await lab(response: response(), recorder: recorder)
        let annotations = [VoiceLabAudioTag(beforeToken: 1, tag: "laughs")]
        let text = VoiceLabAudioTags.requestText(words: "Hi", tags: annotations, modelID: model)
        let id = UUID(), options = VoiceLabSpeechOptions(seed: 0, previousText: "Before", nextText: "After")
        let quote = try await client.prepareSynthesis(text: text, modelID: model, voice: voice, language: "en", options: options, requestID: id)
        #expect(quote.estimate.units == Double(text.unicodeScalars.count))
        if VoiceLabAudioTags.supports(model) {
            await #expect(throws: VoiceLabError.consentRequired) {
                _ = try await client.synthesize(text: "Hi", modelID: model, voice: voice, language: "en", options: options,
                    requestID: id, authorization: VoiceLabAuthorization(quote: quote, approved: true))
            }
            #expect(recorder.paid.withLock { $0.isEmpty })
        }
        let freshID = UUID()
        let fresh = try await client.prepareSynthesis(text: text, modelID: model, voice: voice, language: "en", options: options, requestID: freshID)
        _ = try await client.synthesize(text: text, modelID: model, voice: voice, language: "en", options: options,
            requestID: freshID, authorization: VoiceLabAuthorization(quote: fresh, approved: true))
        let body = try #require(recorder.paid.withLock { $0.first?.body })
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = model == "eleven_v4" ? (object["inputs"] as? [[String: Any]])?.first?["text"] as? String : object["text"] as? String
        #expect(sent == text)
        if VoiceLabAudioTags.supports(model) {
            #expect(object["previous_text"] == nil && object["next_text"] == nil)
        }
    }
    @Test func normalizedNumberFallbackUsesRawSegmentIndices() async throws {
        let fixtures = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/audio-tag-cases.json")) as? [String: Any])
        for fixture in try #require(fixtures["dialogueFallbacks"] as? [[String: Any]]) {
            var row = try #require(JSONSerialization.jsonObject(with: response()) as? [String: Any])
            let text = try #require(fixture["typed"] as? String)
            let model = try #require(fixture["modelID"] as? String)
            let end = try #require(fixture["segmentEnd"] as? Int)
            row["alignment"] = fixture["alignment"]
            row["normalized_alignment"] = fixture["normalized_alignment"]
            row["voice_segments"] = [["voice_id": "voice123", "dialogue_input_index": 0,
                "character_start_index": 0, "character_end_index": end,
                "start_time_seconds": 0, "end_time_seconds": Double(end) / 2_000]]
            let client = try await lab(response: JSONSerialization.data(withJSONObject: row))
            let id = UUID(), options = VoiceLabSpeechOptions(seed: 0)
            let quote = try await client.prepareSynthesis(text: text, modelID: model, voice: voice, language: "en", options: options, requestID: id)
            let result = try await client.synthesize(text: text, modelID: model, voice: voice, language: "en", options: options,
                requestID: id, authorization: VoiceLabAuthorization(quote: quote, approved: true))
            #expect(result.alignment?.map(\.character).joined() == text)
        }
    }
    /// voice-lab §8.5 "Tolerant timing": every v4 reply a correct provider could send maps to the typed words with the
    /// shared fixture's times; replies whose words really differ are refused with the check the release log names.
    @Test func v4TimingVariantsMapToTypedWordsOrNameTheirCheck() async throws {
        let document = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/v4-timing-cases.json")) as? [String: Any])
        #expect(document["schema"] as? String == "voxclip-voice-lab-v4-timing-cases/1")
        let cases = try #require(document["cases"] as? [[String: Any]])
        #expect(cases.count == document["caseCount"] as? Int && cases.count >= 20)
        var problems: [String] = []
        for fixture in cases {
            let id = try #require(fixture["id"] as? String), typed = try #require(fixture["typed"] as? String)
            let samples = try #require(fixture["pcmSamples"] as? Int)
            let expected = try #require(fixture["expected"] as? [String: Any])
            let row: [String: Any] = ["audio_base64": Data(count: samples * 2).base64EncodedString(),
                "alignment": fixture["alignment"] ?? NSNull(), "normalized_alignment": fixture["normalized_alignment"] ?? NSNull(),
                "voice_segments": fixture["voice_segments"] ?? NSNull()]
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try await lab(response: JSONSerialization.data(withJSONObject: row),
                logger: RedactingLogger(homeDirectory: "/synthetic-home", directory: directory), diagnosticDirectory: directory)
            let id0 = UUID(), options = VoiceLabSpeechOptions(seed: 0)
            let quote = try await client.prepareSynthesis(text: typed, modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id0)
            do {
                let result = try await client.synthesize(text: typed, modelID: "eleven_v4", voice: voice, language: "en", options: options,
                    requestID: id0, authorization: VoiceLabAuthorization(quote: quote, approved: true))
                guard expected["outcome"] as? String == "accepted" else { problems.append("\(id): accepted, expected \(expected["check"] ?? "")"); continue }
                let timing = try #require(result.alignment)
                let words = try VoiceLabAlignment.words(characters: timing.map(\.character), starts: timing.map(\.start),
                    ends: timing.map(\.end), expectedText: typed)
                let want = try #require(expected["words"] as? [[String: Any]])
                let got = words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
                // Foundation's JSON reader may round 17-digit doubles by a few ULPs; the times are pinned to 1e-9 s.
                func close(_ left: [Double], _ right: [Double]) -> Bool { left.count == right.count && zip(left, right).allSatisfy { abs($0 - $1) < 1e-9 } }
                if words.map(\.text) != want.compactMap({ $0["text"] as? String })
                    || !close(words.map(\.start), want.compactMap { $0["start"] as? Double }) || !close(words.map(\.end), want.compactMap { $0["end"] as? Double }) {
                    problems.append("\(id): words \(got) expected \(want)")
                }
            } catch {
                guard expected["outcome"] as? String == "rejected" else { problems.append("\(id): refused \(error)"); continue }
                let check = try #require(expected["check"] as? String)
                // A segment refusal keeps the shared dialogue contract; the take run recovers that take (§8.5).
                let segment = expected["error"] as? String == "malformedResponse"
                if error as? VoiceLabError != (segment ? .malformedResponse : .invalidAlignment) { problems.append("\(id): \(error)") }
                let log = (try? String(contentsOf: directory.appendingPathComponent("voxclip.log"), encoding: .utf8)) ?? ""
                if !log.contains("voicelab speech timing failed check=\(check)\(segment ? "_" : " ")") { problems.append("\(id): log \(log)") }
                for word in typed.split(separator: " ") where word.count > 3 && log.contains(word) { problems.append("\(id): log has text") }
            }
        }
        #expect(problems == [])
    }
    @Test func diagnosticsUseTestOrExplicitDataRoot() {
        let explicit = ElevenLabsVoiceLab.defaultValidationDiagnosticDirectory(environment: ["VOXCLIP_DATA_DIR": "/tmp/isolated-tags"], arguments: ["Tests.xctest"])
        #expect(explicit.path == "/tmp/isolated-tags/Logs/Diagnostics/VoiceLab")
        let automatic = ElevenLabsVoiceLab.defaultValidationDiagnosticDirectory(environment: [:], arguments: ["Tests.xctest"])
        #expect(automatic.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!automatic.path.contains("Library/Logs"))
    }
    @Test func normalizedAlignmentCanReplaceNullOriginal() async throws {
        var row = try #require(JSONSerialization.jsonObject(with: response()) as? [String: Any])
        row["normalized_alignment"] = row["alignment"]
        row["alignment"] = NSNull()
        let client = try await lab(response: JSONSerialization.data(withJSONObject: row))
        let id = UUID(), options = VoiceLabSpeechOptions(seed: 0)
        let quote = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
        let result = try await client.synthesize(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options,
            requestID: id, authorization: VoiceLabAuthorization(quote: quote, approved: true))
        #expect(result.alignment?.map(\.character).joined() == "Hi")
    }
    private func response() throws -> Data {
        let cases = try #require(document()["responses"] as? [[String: Any]])
        return try JSONSerialization.data(withJSONObject: try #require(cases[0]["response"]))
    }
    @Test(arguments: ["eleven_v3", "eleven_v4"])
    func validationDiagnosticIsRedactedAndNamesUnicodeMismatch(model: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = RedactingLogger(homeDirectory: "/synthetic-home", directory: directory)
        var row = try #require(JSONSerialization.jsonObject(with: response()) as? [String: Any])
        // A curly apostrophe alone is tolerated (v4-timing-cases.json); a different word is refused.
        row["alignment"] = ["characters": ["I", "’", "d"],
            "character_start_times_seconds": [0, 0.005, 0.01], "character_end_times_seconds": [0.005, 0.01, 0.02]]
        row["normalized_alignment"] = ["characters": ["I am"]]
        row["voice_segments"] = [["voice_id": "voice123", "dialogue_input_index": 0,
            "character_start_index": 0, "character_end_index": 3, "start_time_seconds": 0, "end_time_seconds": 0.3,
            "extra": "synthetic-dialogue-key", "headers": ["Authorization": "secret-header"], "audio_base64": "secret-audio"]]
        row["headers"] = ["Authorization": "secret-envelope"]
        let recorder = RequestRecorder()
        let client = try await lab(response: JSONSerialization.data(withJSONObject: row), recorder: recorder,
            logger: logger, diagnosticDirectory: directory)
        let id = UUID(), options = VoiceLabSpeechOptions(seed: 0)
        let quote = try await client.prepareSynthesis(text: "I'm", modelID: model, voice: voice, language: "en", options: options, requestID: id)
        let acceptance = VoiceLabRequestAcceptance()
        await #expect(throws: VoiceLabError.invalidAlignment) {
            _ = try await client.synthesize(text: "I'm", modelID: model, voice: voice, language: "en", options: options,
                requestID: id, authorization: VoiceLabAuthorization(quote: quote, approved: true), acceptance: acceptance)
        }
        let file = directory.appendingPathComponent("speech-validation-\(id.uuidString).json")
        let bytes = try Data(contentsOf: file)
        let diagnostic = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(diagnostic["check"] as? String == "alignment_words_mismatch")
        #expect(diagnostic["index"] as? Int == 1)
        #expect(diagnostic["typed_scalar"] as? String == "U+0027")
        #expect(diagnostic["alignment_scalar"] as? String == "U+2019")
        #expect(diagnostic["typed_text"] as? String == "I'm")
        #expect(diagnostic["alignment_text"] as? String == "I’d")
        #expect(diagnostic["normalized_alignment_text"] as? String == "I am")
        #expect(diagnostic["model"] as? String == model)
        #expect(diagnostic["route"] as? String == (model == "eleven_v4" ? "textToDialogue" : "textToSpeech"))
        #expect(diagnostic["pcm_duration_seconds"] as? Double == 0.02)
        let starts = try #require(diagnostic["alignment_starts"] as? [String: Any])
        #expect(starts["first"] as? [Double] == [0, 0.005, 0.01])
        #expect(starts["last"] as? [Double] == [0, 0.005, 0.01])
        let segments = try #require(diagnostic["voice_segments"] as? [[String: Any]])
        #expect(segments[0]["character_end_index"] as? Int == 3)
        let serialized = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["audio_base64", "headers", "synthetic-dialogue-key", "secret-header", "secret-audio", "secret-envelope"] {
            #expect(!serialized.contains(forbidden))
        }
        let log = try String(contentsOf: directory.appendingPathComponent("voxclip.log"), encoding: .utf8)
        #expect(log.contains("[info] voice-lab: voicelab speech timing failed check=alignment_words_mismatch index=1 typed=U+0027 provider=U+2019"))
        #expect(!log.contains("I'm") && !log.contains("I’d"))
        #expect(acceptance.unalignedAudio?.pcm.isEmpty == false)
        #expect(recorder.paid.withLock { $0.count } == 1)
    }

    @Test(arguments: ["null_alignment", "alignment_count_mismatch", "alignment_time_order", "alignment_end_beyond_duration",
                      "segment_voice", "segment_character_range", "segment_end_beyond_duration"])
    func validationDiagnosticNamesExactRule(check: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var row = try #require(JSONSerialization.jsonObject(with: response()) as? [String: Any])
        var alignment = try #require(row["alignment"] as? [String: Any])
        var segments = try #require(row["voice_segments"] as? [[String: Any]])
        switch check {
        case "null_alignment": row["alignment"] = NSNull(); row["normalized_alignment"] = NSNull()
        case "alignment_count_mismatch": alignment["character_end_times_seconds"] = [0.1]; row["alignment"] = alignment
        case "alignment_time_order": alignment["character_start_times_seconds"] = [0.2, 0.1]; row["alignment"] = alignment
        case "alignment_end_beyond_duration": alignment["character_end_times_seconds"] = [0.2, 1.06]; row["alignment"] = alignment
        case "segment_voice": segments[0]["voice_id"] = "wrong"
        case "segment_character_range": segments[0]["character_end_index"] = 999
        default: segments[0]["end_time_seconds"] = 1.06
        }
        row["voice_segments"] = segments
        let client = try await lab(response: JSONSerialization.data(withJSONObject: row), diagnosticDirectory: directory)
        let id = UUID(), options = VoiceLabSpeechOptions(seed: 0)
        let quote = try await client.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options, requestID: id)
        let expected: VoiceLabError = check.hasPrefix("segment_") ? .malformedResponse : .invalidAlignment
        await #expect(throws: expected) {
            _ = try await client.synthesize(text: "Hi", modelID: "eleven_v4", voice: voice, language: "en", options: options,
                requestID: id, authorization: VoiceLabAuthorization(quote: quote, approved: true))
        }
        let bytes = try Data(contentsOf: directory.appendingPathComponent("speech-validation-\(id.uuidString).json"))
        let diagnostic = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(diagnostic["check"] as? String == check)
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
        #expect(quote.voiceID == "voice123")
        #expect(result.receipt.endpoint == quote.endpoint && result.receipt.modelID == "eleven_v4")
        #expect(result.alignment?.count == 2 && result.sampleRate == 24_000)
    }
    @Test func allSharedResponsesAreValidatedWithOneSendAndNoRetry() async throws {
        let rows = try #require(document()["responses"] as? [[String: Any]])
        #expect(rows.count == 25)
        for row in rows {
            let name = try #require(row["case"] as? String)
            let text = row["text"] as? String ?? "Hi"
            let bytes = try JSONSerialization.data(withJSONObject: try #require(row["response"]))
            let expected = name == "alignment_null" ? "success" : try #require(row["expected"] as? String)
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
