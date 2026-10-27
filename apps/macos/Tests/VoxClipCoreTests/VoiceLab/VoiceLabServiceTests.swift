import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("Voice Lab offline service", .timeLimit(.minutes(1)))
struct VoiceLabServiceTests {
    private let key = "synthetic-voice-lab-key"
    private let speech = VoiceLabSpeechOptions(seed: 7)
    private var models: Data { Data("[{\"model_id\":\"new_speech_model\",\"name\":\"New\",\"can_do_text_to_speech\":true,\"can_do_voice_conversion\":false,\"maximum_text_length_per_request\":5000,\"languages\":[{\"language_id\":\"en\"}]},{\"model_id\":\"new_sts_model\",\"can_do_text_to_speech\":false,\"can_do_voice_conversion\":true,\"languages\":[{\"language_id\":\"en\"}]}]".utf8) }
    private var plan: Data { Data("{\"tier\":\"starter\",\"status\":\"active\",\"character_count\":0,\"character_limit\":10000,\"can_use_instant_voice_cloning\":true,\"voice_slots_used\":0,\"voice_limit\":10}".utf8) }
    private var voices: Data { Data("{\"voices\":[{\"voice_id\":\"own123\",\"name\":\"Mine\",\"category\":\"cloned\",\"is_owner\":true,\"voice_verification\":{\"requires_verification\":false,\"is_verified\":true}},{\"voice_id\":\"stock123\",\"name\":\"Stock\",\"category\":\"premade\",\"is_owner\":false}],\"has_more\":false}".utf8) }
    private var policy: OwnVoicePolicy { OwnVoicePolicy(recordID: "record-1", cloneVoiceID: "own123", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true) }
    private func approve(_ quote: VoiceLabQuote, approved: Bool = true) -> VoiceLabAuthorization {
        VoiceLabAuthorization(quote: quote, approved: approved)
    }
    private func clone(_ name: String = "My voice", trainingFill: Int = 1) -> VoiceLabCloneRequest {
        VoiceLabCloneRequest(displayName: name, language: "en", samples: [
            VoiceLabCloneSample(role: .consentStatement, wav: VoiceLabRequestFixtures.wav(rate: 8_000, frames: 40_000)),
            VoiceLabCloneSample(role: .training, wav: VoiceLabRequestFixtures.wav(rate: 8_000, frames: 40_000, fill: trainingFill))
        ], createdAt: Date(timeIntervalSince1970: 1_793_000_000), removeBackgroundNoise: false)
    }
    private func wav(_ pcm: Data, rate: Int = 24_000) -> Data {
        var result = Data("RIFF".utf8)
        func le32(_ value: Int) { result.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func le16(_ value: Int) { result.append(contentsOf: (0..<2).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        le32(36 + pcm.count); result.append(Data("WAVEfmt ".utf8)); le32(16)
        le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
        result.append(Data("data".utf8)); le32(pcm.count); result.append(pcm)
        return result
    }
    private func conversionInput(_ row: [String: Any]) throws -> Data {
        let rate = row["rate"] as? Int ?? 24_000
        let frames = row["frames"] as? Int ?? 2_400
        let mutation = row["mutation"] as? String ?? ""
        func little(_ value: Int, _ width: Int) -> Data {
            Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func chunk(_ name: String, _ payload: Data, declaredSize: Int? = nil) -> Data {
            var result = Data(name.utf8)
            result.append(little(declaredSize ?? payload.count, 4))
            result.append(payload)
            if !payload.count.isMultiple(of: 2) { result.append(0) }
            return result
        }
        var format = Data()
        format.append(little(mutation == "floatFormat" ? 3 : 1, 2))
        format.append(little(mutation == "stereo" ? 2 : 1, 2))
        format.append(little(rate, 4))
        format.append(little(rate * 2 + (mutation == "badByteRate" ? 1 : 0), 4))
        format.append(little(mutation == "badAlign" ? 1 : 2, 2))
        format.append(little(mutation == "pcm8" ? 8 : 16, 2))
        if mutation == "fmt18" { format.append(little(0, 2)) }
        var pcm = Data(repeating: 0, count: frames * 2)
        if mutation == "oddPayload" { pcm.append(0) }
        let fmt = chunk("fmt ", format, declaredSize: mutation == "overflowChunk" ? Int(UInt32.max) : nil)
        let data = chunk("data", pcm, declaredSize: mutation == "truncatedChunk" ? pcm.count + 2 : nil)
        var chunks: [Data] = []
        if row["ancillary"] as? Bool == true { chunks.append(chunk("JUNK", Data([1, 2, 3]))) }
        if mutation == "dataBeforeFmt" { chunks.append(data) }
        if mutation != "missingFmt" { chunks.append(fmt) }
        if mutation == "duplicateFmt" { chunks.append(fmt) }
        if row["ancillary"] as? Bool == true { chunks.append(chunk("LIST", Data([4, 5]))) }
        if mutation != "missingData" && mutation != "dataBeforeFmt" { chunks.append(data) }
        if mutation == "duplicateData" { chunks.append(data) }
        if row["ancillary"] as? Bool == true { chunks.append(chunk("cue ", Data([6]))) }
        if mutation == "missingPad" {
            var unpadded = chunk("JUNK", Data([7]))
            unpadded.removeLast()
            chunks.append(unpadded)
        }
        var result = Data("RIFF".utf8)
        result.append(little(4 + chunks.reduce(0) { $0 + $1.count }, 4))
        result.append(Data("WAVE".utf8))
        for item in chunks { result.append(item) }
        switch mutation {
        case "riffShort": result.replaceSubrange(4..<8, with: little(result.count - 9, 4))
        case "riffLong": result.replaceSubrange(4..<8, with: little(result.count - 7, 4))
        case "truncateFile": result.removeLast()
        default: break
        }
        if row["slice"] as? Bool == true {
            var wrapped = Data([0xA5])
            wrapped.append(result)
            let sliced = wrapped.dropFirst()
            #expect(sliced.startIndex != 0)
            return sliced
        }
        return result
    }
    private func pcm(_ samples: Int = 2400) -> Data { Data(repeating: 0, count: samples * 2) }
    private func timing(_ text: String, audio: Data, alignment: String? = nil) -> Data {
        let times = alignment ?? "\"alignment\":{\"characters\":[\"H\",\"i\"],\"character_start_times_seconds\":[0,0.02],\"character_end_times_seconds\":[0.02,0.04]}"
        return Data("{\"audio_base64\":\"\(audio.base64EncodedString())\",\(times)}".utf8)
    }
    private func service(_ handler: @escaping SpeechStubHTTP.Handler, region: ElevenLabsRegion = .eu) -> ElevenLabsVoiceLab {
        let base = SpeechStubHTTP.register(handler)
        return ElevenLabsVoiceLab(keys: SpeechTestKeys(value: key), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), region: region, logger: SpeechTestLogger())
    }
    private func fixture(_ key: String) throws -> [[String: Any]] {
        let data = try FixtureLoader.data("fixtures/voice-lab/contract.json")
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(document["version"] as? Int == 1)
        return try #require(document[key] as? [[String: Any]])
    }

    @Test func regionalDiscoveryAndGenerationWire() async throws {
        let models = self.models, plan = self.plan, voices = self.voices, audio = pcm()
        let calls = Mutex<[String]>([])
        let service = service { request in
            let url = try #require(request.url)
            #expect(url.host == ElevenLabsRegion.eu.baseURL.host)
            #expect(url.query?.contains("key") != true)
            #expect(request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-voice-lab-key")
            calls.withLock { $0.append("\(request.httpMethod ?? "") \(url.path)") }
            switch url.path {
            case "/v1/models": return (200, [:], models)
            case "/v1/user/subscription": return (200, [:], plan)
            case "/v2/voices": return (200, [:], voices)
            case "/v1/text-to-speech/own123/with-timestamps":
                #expect(url.query == "output_format=pcm_24000")
                let body = try VoiceLabRequestFixtures.body(request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? NSDictionary)
                #expect(json == ["text": "Hi", "model_id": "new_speech_model", "language_code": "en", "seed": 7,
                                 "voice_settings": ["stability": 0.5, "similarity_boost": 0.8], "previous_text": "Before",
                                 "next_text": "After", "apply_text_normalization": "auto"] as NSDictionary)
                return (200, ["request-id": "synthetic-request"], timing("Hi", audio: audio))
            case "/v1/voice-changer/stock123":
                #expect(url.query == "output_format=pcm_24000")
                let body = try VoiceLabRequestFixtures.body(request)
                let text = String(decoding: body, as: UTF8.self)
                #expect(text.contains("name=\"model_id\"\r\n\r\nnew_sts_model\r\n"))
                #expect(text.contains("name=\"audio\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav"))
                #expect(text.contains("name=\"voice_settings\"\r\n\r\n{\"stability\":0.5,\"similarity_boost\":0.75}\r\n"))
                #expect(text.contains("name=\"seed\"\r\n\r\n7\r\n"))
                #expect(text.contains("name=\"remove_background_noise\"\r\n\r\ntrue\r\n"))
                return (200, [:], audio)
            default: throw URLError(.badURL)
            }
        }
        #expect(try await service.models().count == 2)
        #expect(try await service.plan().canClone)
        #expect(try await service.voices().count == 2)
        let estimate = try await service.estimate(.textToSpeech, units: 2, unit: "characters")
        #expect(estimate.usd == nil && estimate.credits == nil)
        let id = UUID()
        let context = VoiceLabSpeechOptions(seed: 7, previousText: " Before ", nextText: "After\n")
        let speechQuote = try await service.prepareSynthesis(text: "Hi", modelID: "new_speech_model", voice: .own(voiceID: "own123", policy: policy), language: "en", options: context, requestID: id)
        #expect(speechQuote.languageMode == .explicit("en"))
        do {
            _ = try await service.synthesize(text: "Hi", modelID: "new_speech_model", voice: .own(voiceID: "own123", policy: policy), language: "en", options: VoiceLabSpeechOptions(seed: 8, previousText: "Before", nextText: "After"), requestID: id, authorization: approve(speechQuote))
            Issue.record("Expected seed binding")
        } catch VoiceLabError.consentRequired {}
        let spoken = try await service.synthesize(text: "Hi", modelID: "new_speech_model", voice: .own(voiceID: "own123", policy: policy), language: "en", options: VoiceLabSpeechOptions(seed: 7, previousText: "Before", nextText: "After"), requestID: id, authorization: approve(speechQuote))
        #expect(spoken.pcm == audio && spoken.sampleRate == 24_000)
        #expect(spoken.alignment?.count == 2 && spoken.receipt.providerRequestID == "synthetic-request")
        let sourceWAV = wav(pcm())
        let conversionQuote = try await service.prepareConversion(audio: sourceWAV, modelID: "new_sts_model", voice: .stock(voiceID: "stock123"), language: "en", seed: 7, cleanAudioOn: false, requestID: id)
        #expect(conversionQuote.languageMode == .autoDetected(expected: "en"))
        do {
            _ = try await service.convert(audio: sourceWAV, modelID: "new_sts_model", voice: .stock(voiceID: "stock123"), language: "en", seed: 7, cleanAudioOn: true, requestID: id, authorization: approve(conversionQuote))
            Issue.record("Expected clean-audio binding")
        } catch VoiceLabError.consentRequired {}
        let converted = try await service.convert(audio: sourceWAV, modelID: "new_sts_model", voice: .stock(voiceID: "stock123"), language: "en", seed: 7, cleanAudioOn: false, requestID: id, authorization: approve(conversionQuote))
        #expect(converted.pcm == audio && converted.alignment == nil)
        #expect(calls.withLock { $0 }.count == 5)
    }

    @Test func cloneLifecycleAndPolicy() async throws {
        let plan = self.plan, voices = self.voices
        let calls = Mutex<[String]>([])
        let service = service { request in
            let path = request.url?.path ?? ""
            calls.withLock { $0.append(path) }
            switch path {
            case "/v1/user/subscription": return (200, [:], plan)
            case "/v2/voices": return (200, [:], voices)
            case "/v1/voices/add":
                let body = String(decoding: try VoiceLabRequestFixtures.body(request), as: UTF8.self)
                #expect(body.contains("name=\"files[]\"; filename=\"consent-statement.wav\"\r\nContent-Type: audio/wav"))
                #expect(body.contains("name=\"files[]\"; filename=\"sample-02.wav\"\r\nContent-Type: audio/wav"))
                #expect(body.contains("name=\"name\"\r\n\r\nMy voice (VoxClip)\r\n"))
                return (200, [:], Data("{\"voice_id\":\"newclone\",\"requires_verification\":true}".utf8))
            case "/v1/voices/own123":
                #expect(request.httpMethod == "DELETE")
                return (200, [:], Data("{\"status\":\"ok\"}".utf8))
            default: throw URLError(.badURL)
            }
        }
        _ = try await service.plan()
        let denied = OwnVoicePolicy(recordID: "record-1", recordActive: true, providerConsentGranted: false, statementVerified: true, speakerMatched: true)
        let deniedID = UUID()
        do { _ = try await service.prepareClone(clone(), policy: denied, requestID: deniedID); Issue.record("Expected consent failure") }
        catch VoiceLabError.consentRequired {}
        #expect(calls.withLock { $0 }.count == 1)
        let createID = UUID()
        let createQuote = try await service.prepareClone(clone(), policy: policy, requestID: createID)
        do { _ = try await service.createOwnClone(clone(trainingFill: 2), policy: policy, requestID: createID, authorization: approve(createQuote)); Issue.record("Expected sample binding") }
        catch VoiceLabError.consentRequired {}
        #expect(calls.withLock { $0 }.count == 1)
        let created = try await service.createOwnClone(clone(), policy: policy, requestID: createID, authorization: approve(createQuote))
        #expect(created.requiresVerification && created.consentRecordID == "record-1")
        #expect(try await service.listOwnClones().map(\.id) == ["own123"])
        let deleteID = UUID()
        let deleteQuote = try await service.prepareDelete(voiceID: "own123", policy: policy, requestID: deleteID)
        _ = try await service.deleteOwnClone(voiceID: "own123", policy: policy, requestID: deleteID, authorization: approve(deleteQuote))
        #expect(calls.withLock { $0 }.count == 4)
    }

    @Test func failuresAreSingleAttemptAndDoNotInventAudio() async throws {
        let models = self.models, voices = self.voices, plan = self.plan, audio = pcm()
        let status = Mutex(429)
        let mutationCalls = Mutex(0)
        let service = service { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            case "/v1/user/subscription": return (200, [:], plan)
            case "/v1/voices/add":
                mutationCalls.withLock { $0 += 1 }
                return (status.withLock { $0 }, [:], Data("busy".utf8))
            case "/v1/text-to-speech/stock123/with-timestamps":
                return (200, [:], timing("Hi", audio: audio, alignment: "\"alignment\":null"))
            default: throw URLError(.badURL)
            }
        }
        _ = try await service.plan()
        for code in [429, 403, 500] {
            status.withLock { $0 = code }
            let id = UUID()
            let quote = try await service.prepareClone(clone("Mine"), policy: policy, requestID: id)
            do { _ = try await service.createOwnClone(clone("Mine"), policy: policy, requestID: id, authorization: approve(quote)); Issue.record("Expected failure") }
            catch let error as VoiceLabError { #expect(error == (code == 429 ? .rateLimited : code == 403 ? .permissionMissing("create_instant_voice_clone") : .providerFailure(500))) }
        }
        #expect(mutationCalls.withLock { $0 } == 3)
        _ = try await service.models(); _ = try await service.voices()
        let id = UUID()
        let speechQuote = try await service.prepareSynthesis(text: "Hi", modelID: "new_speech_model", voice: .stock(voiceID: "stock123"), language: "en", options: speech, requestID: id)
        do { _ = try await service.synthesize(text: "Hi", modelID: "new_speech_model", voice: .stock(voiceID: "stock123"), language: "en", options: speech, requestID: id, authorization: approve(speechQuote)); Issue.record("Expected missing alignment") }
        catch VoiceLabError.invalidAlignment {}
        do { _ = try await service.synthesize(text: "Hi", modelID: "new_speech_model", voice: .stock(voiceID: "stock123"), language: "en", options: speech, requestID: id, authorization: approve(speechQuote)); Issue.record("Expected approval mismatch") }
        catch VoiceLabError.consentRequired {}
    }

    @Test func malformedAudioAndAlignmentAreRejected() async throws {
        let models = self.models, voices = self.voices
        let response = Mutex(Data("{\"audio_base64\":\"%%%\",\"alignment\":null}".utf8))
        let service = service { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            case "/v1/text-to-speech/stock123/with-timestamps": return (200, [:], response.withLock { $0 })
            case "/v1/voice-changer/stock123": return (200, [:], Data([0]))
            default: throw URLError(.badURL)
            }
        }
        _ = try await service.models(); _ = try await service.voices()
        let id = UUID()
        func speak() async throws -> VoiceLabAudioResult {
            let quote = try await service.prepareSynthesis(text: "Hi", modelID: "new_speech_model", voice: .stock(voiceID: "stock123"), language: "en", options: speech, requestID: id)
            return try await service.synthesize(text: "Hi", modelID: "new_speech_model", voice: .stock(voiceID: "stock123"), language: "en", options: speech, requestID: id, authorization: approve(quote))
        }
        do { _ = try await speak(); Issue.record("Expected invalid base64") }
        catch VoiceLabError.invalidAudio {}
        response.withLock { $0 = timing("Hi", audio: Data([0, 1, 2])) }
        do { _ = try await speak(); Issue.record("Expected odd PCM") }
        catch VoiceLabError.invalidAudio {}
        response.withLock { $0 = timing("Hi", audio: wav(pcm())) }
        do { _ = try await speak(); Issue.record("Expected encoded audio rejection") }
        catch VoiceLabError.invalidAudio {}
        response.withLock { $0 = timing("Hi", audio: pcm(), alignment: "\"alignment\":{\"characters\":[\"H\",\"i\"],\"character_start_times_seconds\":[0,0.2],\"character_end_times_seconds\":[0.02,0.3]}") }
        do { _ = try await speak(); Issue.record("Expected bad character timing") }
        catch VoiceLabError.invalidAlignment {}
        do { _ = try await service.prepareConversion(audio: Data([0, 1]), modelID: "new_sts_model", voice: .stock(voiceID: "stock123"), language: "en", seed: 7, cleanAudioOn: false, requestID: id); Issue.record("Expected WAV input validation") }
        catch VoiceLabError.unsupportedFormat {}
        let badOutputQuote = try await service.prepareConversion(audio: wav(pcm()), modelID: "new_sts_model", voice: .stock(voiceID: "stock123"), language: "en", seed: 7, cleanAudioOn: false, requestID: id)
        do { _ = try await service.convert(audio: wav(pcm()), modelID: "new_sts_model", voice: .stock(voiceID: "stock123"), language: "en", seed: 7, cleanAudioOn: false, requestID: id, authorization: approve(badOutputQuote)); Issue.record("Expected bad converted PCM") }
        catch VoiceLabError.invalidAudio {}
    }

    @Test func dialogueOnlyModelIsNotSentToTTSEndpoint() async throws {
        let models = Data("[{\"model_id\":\"eleven_v4\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"}]}]".utf8)
        let voices = self.voices
        let calls = Mutex(0)
        let service = service { request in
            calls.withLock { $0 += 1 }
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            default: throw URLError(.badURL)
            }
        }
        let discovered = try await service.models()
        #expect(discovered.count == 1 && !discovered[0].supportsTimestampedTTS)
        _ = try await service.voices()
        let id = UUID()
        do { _ = try await service.prepareSynthesis(text: "Hi", modelID: "eleven_v4", voice: .stock(voiceID: "stock123"), language: "en", options: speech, requestID: id); Issue.record("Expected endpoint gate") }
        catch VoiceLabError.unsupportedEndpoint {}
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func multilingualModelMarksAutoDetectionAndOmitsLanguageField() async throws {
        let models = Data("[{\"model_id\":\"eleven_multilingual_v2\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"}]}]".utf8)
        let voices = self.voices, audio = pcm()
        let lab = service { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            default:
                let body = try VoiceLabRequestFixtures.body(request)
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(payload["language_code"] == nil)
                return (200, [:], timing("Hi", audio: audio))
            }
        }
        _ = try await lab.models(); _ = try await lab.voices()
        let id = UUID(), voice = VoiceLabVoiceChoice.stock(voiceID: "stock123")
        let quote = try await lab.prepareSynthesis(text: "Hi", modelID: "eleven_multilingual_v2", voice: voice, language: "en", options: speech, requestID: id)
        #expect(quote.languageMode == .autoDetected(expected: "en"))
        _ = try await lab.synthesize(text: "Hi", modelID: "eleven_multilingual_v2", voice: voice, language: "en", options: speech, requestID: id, authorization: approve(quote))
    }

    @Test func cancelledBeforeUploadAndPlanGate() async throws {
        let deniedPlan = Data("{\"tier\":\"free\",\"status\":\"free\",\"character_count\":0,\"character_limit\":100,\"can_use_instant_voice_cloning\":false,\"voice_slots_used\":0,\"voice_limit\":0}".utf8)
        let calls = Mutex(0)
        let service = service { request in
            calls.withLock { $0 += 1 }
            return (200, [:], deniedPlan)
        }
        #expect(try await service.plan().isNonCommercial)
        let id = UUID()
        do { _ = try await service.prepareClone(clone("Mine"), policy: policy, requestID: id); Issue.record("Expected plan gate") }
        catch VoiceLabError.planUnavailable {}
        #expect(calls.withLock { $0 } == 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.models()
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch VoiceLabError.cancelled {}
        catch is CancellationError {}
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func sharedVoiceCategoryRightsBlockPaidCalls() async throws {
        for row in try fixture("voiceChoices") {
            let category = try #require(row["category"] as? String)
            let owner = try #require(row["owner"] as? Bool)
            let choice = try #require(row["choice"] as? String)
            let allowed = try #require(row["allowed"] as? Bool)
            let voiceJSON = "{\"voices\":[{\"voice_id\":\"candidate\",\"name\":\"Candidate\",\"category\":\"\(category)\",\"is_owner\":\(owner),\"voice_verification\":{\"requires_verification\":\(choice == "own_unverified"),\"is_verified\":false}}],\"has_more\":false}"
            let models = self.models, audio = pcm(), sends = Mutex(0)
            let service = service { request in
                switch request.url?.path {
                case "/v1/models": return (200, [:], models)
                case "/v2/voices": return (200, [:], Data(voiceJSON.utf8))
                default:
                    sends.withLock { $0 += 1 }
                    return (200, [:], timing("Hi", audio: audio))
                }
            }
            _ = try await service.models(); _ = try await service.voices()
            let id = UUID()
            let selected: VoiceLabVoiceChoice = choice.hasPrefix("own")
                ? .own(voiceID: "candidate", policy: OwnVoicePolicy(recordID: "record-1", cloneVoiceID: "candidate", recordActive: choice != "own_inactive", providerConsentGranted: true, statementVerified: true, speakerMatched: true))
                : .stock(voiceID: "candidate")
            do {
                let quote = try await service.prepareSynthesis(text: "Hi", modelID: "new_speech_model", voice: selected, language: "en", options: speech, requestID: id)
                _ = try await service.synthesize(text: "Hi", modelID: "new_speech_model", voice: selected, language: "en", options: speech, requestID: id, authorization: approve(quote))
                #expect(allowed)
            } catch VoiceLabError.consentRequired { #expect(!allowed) }
            #expect(sends.withLock { $0 } == (allowed ? 1 : 0), "category=\(category), choice=\(choice)")
        }
    }

    @Test func discoveryDuplicatesAndPaginationAreTypedFailures() async throws {
        let models = self.models
        for row in try fixture("discovery") {
            let event = try #require(row["event"] as? String)
            let pages = Mutex(0)
            let service = service { request in
                if request.url?.path == "/v1/models" {
                    return (200, [:], event == "duplicate_model_id" ? Data("[{\"model_id\":\"same\"},{\"model_id\":\"same\"}]".utf8) : models)
                }
                let page = pages.withLock { value -> Int in value += 1; return value }
                let id = event == "duplicate_voice_id_same_page" || event == "duplicate_voice_id_next_page" ? "same" : "id\(page)"
                let entries = event == "duplicate_voice_id_same_page" ? "{\"voice_id\":\"same\",\"name\":\"A\",\"category\":\"premade\"},{\"voice_id\":\"same\",\"name\":\"B\",\"category\":\"premade\"}" : "{\"voice_id\":\"\(id)\",\"name\":\"A\",\"category\":\"premade\"}"
                let next = event == "repeated_cursor" ? "repeat" : "page\(page)"
                let body = "{\"voices\":[\(entries)],\"has_more\":true,\"next_page_token\":\"\(next)\"}"
                return (200, [:], Data(body.utf8))
            }
            do {
                if event == "duplicate_model_id" { _ = try await service.models() }
                else { _ = try await service.voices() }
                Issue.record("Expected discovery error: \(event)")
            } catch let error as VoiceLabError {
                #expect(error == (event == "page_21" ? .responseTooLarge : .malformedResponse))
            }
        }
    }

    @Test(arguments: ["\n", "\r\n", " "])
    func providerIDsRejectTrailingLineBreaksAndSpaces(_ suffix: String) async throws {
        let badModels = try JSONSerialization.data(withJSONObject: [["model_id": "model" + suffix, "can_do_text_to_speech": true] as [String: Any]])
        let badVoices = try JSONSerialization.data(withJSONObject: ["voices": [["voice_id": "voice" + suffix, "name": "Bad", "category": "premade"]], "has_more": false] as [String: Any])
        let bad = service { request in (200, [:], request.url?.path == "/v1/models" ? badModels : badVoices) }
        do { _ = try await bad.models(); Issue.record("Expected model ID rejection") }
        catch VoiceLabError.malformedResponse {}
        do { _ = try await bad.voices(); Issue.record("Expected voice ID rejection") }
        catch VoiceLabError.malformedResponse {}
        let models = self.models, voices = self.voices
        let sends = Mutex(0)
        let lab = service { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            default: sends.withLock { $0 += 1 }; throw URLError(.badURL)
            }
        }
        _ = try await lab.models(); _ = try await lab.voices()
        do {
            _ = try await lab.prepareSynthesis(text: "Hi", modelID: "new_speech_model", voice: .stock(voiceID: "stock123" + suffix), language: "en", options: speech, requestID: UUID())
            Issue.record("Expected voice ID rejection")
        } catch VoiceLabError.invalidInput {}
        do {
            _ = try await lab.prepareSynthesis(text: "Hi", modelID: "new_speech_model" + suffix, voice: .stock(voiceID: "stock123"), language: "en", options: speech, requestID: UUID())
            Issue.record("Expected model ID rejection")
        } catch VoiceLabError.unsupportedModel {}
        let deletePolicy = OwnVoicePolicy(recordID: "record-1", cloneVoiceID: "own123" + suffix, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        do { _ = try await lab.prepareDelete(voiceID: "own123" + suffix, policy: deletePolicy, requestID: UUID()); Issue.record("Expected voice ID rejection") }
        catch VoiceLabError.consentRequired {}
        #expect(sends.withLock { $0 } == 0)
    }

    @Test func quoteBindsInputsAndIsSingleUse() async throws {
        let models = Data("[{\"model_id\":\"first\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"},{\"language_id\":\"et\"}]},{\"model_id\":\"other_model\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"}]}]".utf8)
        let voices = Data("{\"voices\":[{\"voice_id\":\"stock123\",\"name\":\"Stock\",\"category\":\"premade\"},{\"voice_id\":\"other_voice\",\"name\":\"Other\",\"category\":\"premade\"},{\"voice_id\":\"own123\",\"name\":\"Mine\",\"category\":\"cloned\",\"is_owner\":true}],\"has_more\":false}".utf8)
        let sends = Mutex(0), audio = pcm()
        let handler: SpeechStubHTTP.Handler = { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            default:
                sends.withLock { $0 += 1 }
                return (200, [:], self.timing("Hi", audio: audio))
            }
        }
        let lab = service(handler), otherRegion = service(handler, region: .us)
        _ = try await lab.models(); _ = try await lab.voices()
        _ = try await otherRegion.models(); _ = try await otherRegion.voices()
        for row in try fixture("quoteMutations") {
            let field = try #require(row["field"] as? String)
            let allowed = try #require(row["allowed"] as? Bool)
            if field == "audioByte" { continue } // Conversion byte binding is checked below.
            let id = UUID(), original = VoiceLabVoiceChoice.stock(voiceID: "stock123")
            let quote = try await lab.prepareSynthesis(text: "Hi", modelID: "first", voice: original, language: "en", options: speech, requestID: id)
            var target = lab, text = "Hi", model = "first", voice = original, language = "en", approval = approve(quote)
            switch field {
            case "text": text = "Changed words"
            case "model": model = "other_model"
            case "voice": voice = .stock(voiceID: "other_voice")
            case "region": target = otherRegion
            case "language": language = "et"
            case "consentRecord": voice = .own(voiceID: "own123", policy: OwnVoicePolicy(recordID: "other_record", cloneVoiceID: "own123", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true))
            case "estimate":
                let changed = CostEstimate(provider: quote.estimate.provider, operation: quote.estimate.operation, units: 99, unit: quote.estimate.unit, basis: quote.estimate.basis)
                approval = approve(VoiceLabQuote(id: quote.id, operation: quote.operation, requestID: quote.requestID, estimate: changed, region: quote.region, endpoint: quote.endpoint, languageMode: quote.languageMode, fingerprint: quote.fingerprint))
            default: break
            }
            let before = sends.withLock { $0 }
            do { _ = try await target.synthesize(text: text, modelID: model, voice: voice, language: language, options: speech, requestID: id, authorization: approval); #expect(allowed) }
            catch VoiceLabError.consentRequired { #expect(!allowed) }
            #expect(sends.withLock { $0 } == before + (allowed ? 1 : 0), "field=\(field)")
            if allowed {
                do { _ = try await lab.synthesize(text: "Hi", modelID: "first", voice: original, language: "en", options: speech, requestID: id, authorization: approval); Issue.record("Expected replay rejection") }
                catch VoiceLabError.consentRequired {}
                #expect(sends.withLock { $0 } == before + 1)
            }
        }
        let ownID = UUID()
        let originalOwn = VoiceLabVoiceChoice.own(voiceID: "own123", policy: OwnVoicePolicy(recordID: "first-record", cloneVoiceID: "own123", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true))
        let ownQuote = try await lab.prepareSynthesis(text: "Hi", modelID: "first", voice: originalOwn, language: "en", options: speech, requestID: ownID)
        let changedOwn = VoiceLabVoiceChoice.own(voiceID: "own123", policy: OwnVoicePolicy(recordID: "second-record", cloneVoiceID: "own123", recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true))
        let beforeOwn = sends.withLock { $0 }
        do { _ = try await lab.synthesize(text: "Hi", modelID: "first", voice: changedOwn, language: "en", options: speech, requestID: ownID, authorization: approve(ownQuote)); Issue.record("Expected consent identity binding") }
        catch VoiceLabError.consentRequired {}
        #expect(sends.withLock { $0 } == beforeOwn)
        let input = wav(pcm()), id = UUID(), voice = VoiceLabVoiceChoice.stock(voiceID: "stock123")
        let conversionModels = Data("[{\"model_id\":\"first\",\"can_do_voice_conversion\":true,\"languages\":[{\"language_id\":\"en\"}]}]".utf8)
        let conversionSends = Mutex(0)
        let converter = service { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], conversionModels)
            case "/v2/voices": return (200, [:], voices)
            default: conversionSends.withLock { $0 += 1 }; return (200, [:], audio)
            }
        }
        _ = try await converter.models(); _ = try await converter.voices()
        let conversionQuote = try await converter.prepareConversion(audio: input, modelID: "first", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: id)
        var changed = input; changed[44] ^= 1
        do { _ = try await converter.convert(audio: changed, modelID: "first", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: id, authorization: approve(conversionQuote)); Issue.record("Expected audio hash rejection") }
        catch VoiceLabError.consentRequired {}
        #expect(conversionSends.withLock { $0 } == 0)
    }

    @Test func concurrentDuplicateAndFailedSendNeedFreshQuote() async throws {
        let models = self.models, voices = self.voices, audio = pcm()
        let sends = Mutex(0), outcome = Mutex(200)
        let base = SpeechStubHTTP.registerStream { request in
            switch request.url?.path {
            case "/v1/models": return SpeechStubHTTP.Reply(status: 200, headers: [:], body: models)
            case "/v2/voices": return SpeechStubHTTP.Reply(status: 200, headers: [:], body: voices)
            default:
                sends.withLock { $0 += 1 }
                Thread.sleep(forTimeInterval: 0.03)
                let code = outcome.withLock { $0 }
                if code == -1 { return SpeechStubHTTP.Reply(status: 200, headers: [:], body: Data(), failure: .networkConnectionLost) }
                return SpeechStubHTTP.Reply(status: code, headers: [:], body: code == 200 ? self.timing("Hi", audio: audio) : Data("busy".utf8))
            }
        }
        let lab = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: key), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), region: .eu, logger: SpeechTestLogger())
        _ = try await lab.models(); _ = try await lab.voices()
        let voice = VoiceLabVoiceChoice.stock(voiceID: "stock123"), id = UUID()
        let quote = try await lab.prepareSynthesis(text: "Hi", modelID: "new_speech_model", voice: voice, language: "en", options: speech, requestID: id)
        let approved = approve(quote)
        let first = Task { try await lab.synthesize(text: "Hi", modelID: "new_speech_model", voice: voice, language: "en", options: speech, requestID: id, authorization: approved) }
        let second = Task { try await lab.synthesize(text: "Hi", modelID: "new_speech_model", voice: voice, language: "en", options: speech, requestID: id, authorization: approved) }
        let outcomes = await [first.result, second.result]
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(sends.withLock { $0 } == 1)
        for code in [429, -1, 200] {
            outcome.withLock { $0 = code }
            let retryID = UUID()
            let next = try await lab.prepareSynthesis(text: "Hi", modelID: "new_speech_model", voice: voice, language: "en", options: speech, requestID: retryID)
            if code == 200 { continue }
            do { _ = try await lab.synthesize(text: "Hi", modelID: "new_speech_model", voice: voice, language: "en", options: speech, requestID: retryID, authorization: approve(next)); Issue.record("Expected failed send") }
            catch let error as VoiceLabError { #expect(error == (code == 429 ? .rateLimited : .network)) }
            let count = sends.withLock { $0 }
            do { _ = try await lab.synthesize(text: "Hi", modelID: "new_speech_model", voice: voice, language: "en", options: speech, requestID: retryID, authorization: approve(next)); Issue.record("Expected consumed quote") }
            catch VoiceLabError.consentRequired {}
            #expect(sends.withLock { $0 } == count)
        }
    }

    @Test func validNegativeSamplesAndRealContainersFollowSharedFixture() async throws {
        let models = self.models, voices = self.voices
        let output = Mutex(pcm())
        let lab = service { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            default: return (200, [:], self.timing("Hi", audio: output.withLock { $0 }))
            }
        }
        _ = try await lab.models(); _ = try await lab.voices()
        for row in try fixture("audio") {
            let format = try #require(row["format"] as? String)
            let valid = try #require(row["valid"] as? Bool)
            let prefix = try #require(row["prefixHex"] as? String)
            var bytes = pcm()
            switch format {
            case "riff_wave_container": bytes = wav(pcm())
            case "id3_container": bytes.replaceSubrange(0..<10, with: [0x49,0x44,0x33,0x04,0,0,0,0,0,0])
            case "two_mp3_frames":
                bytes.replaceSubrange(0..<4, with: [0xFF,0xFB,0x90,0x64])
                bytes.replaceSubrange(417..<421, with: [0xFF,0xFB,0x90,0x64])
            case "mp4_container": bytes.replaceSubrange(0..<16, with: [0,0,0,24,0x66,0x74,0x79,0x70,0x69,0x73,0x6f,0x6d,0,0,0,0])
            case "odd_pcm_length": bytes.removeLast()
            default:
                let pairs = stride(from: 0, to: prefix.count, by: 2).compactMap { UInt8(prefix.dropFirst($0).prefix(2), radix: 16) }
                bytes.replaceSubrange(0..<pairs.count, with: pairs)
            }
            output.withLock { $0 = bytes }
            let id = UUID(), voice = VoiceLabVoiceChoice.stock(voiceID: "stock123")
            let quote = try await lab.prepareSynthesis(text: "Hi", modelID: "new_speech_model", voice: voice, language: "en", options: speech, requestID: id)
            do {
                let result = try await lab.synthesize(text: "Hi", modelID: "new_speech_model", voice: voice, language: "en", options: speech, requestID: id, authorization: approve(quote))
                #expect(valid && result.pcm == bytes)
            } catch VoiceLabError.invalidAudio { #expect(!valid) }
        }
    }

    @Test func conversionInputFollowsSharedFixtureWithoutUnreviewedSends() async throws {
        let models = self.models, voices = self.voices, output = pcm()
        for row in try fixture("conversionInputs") {
            let name = try #require(row["case"] as? String)
            let valid = try #require(row["valid"] as? Bool)
            let input = try conversionInput(row)
            let paths = Mutex<[String]>([])
            let lab = service { request in
                let path = request.url?.path ?? ""
                paths.withLock { $0.append(path) }
                switch path {
                case "/v1/models": return (200, [:], models)
                case "/v2/voices": return (200, [:], voices)
                case "/v1/voice-changer/stock123":
                    let body = try VoiceLabRequestFixtures.body(request)
                    #expect(body.range(of: input) != nil, "\(name): upload must contain the exact input bytes")
                    return (200, ["Content-Type": "audio/pcm"], output)
                default: throw URLError(.badURL)
                }
            }
            _ = try await lab.models()
            _ = try await lab.voices()
            #expect(paths.withLock { $0.count } == 2)
            let id = UUID(), voice = VoiceLabVoiceChoice.stock(voiceID: "stock123")
            if valid {
                let quote = try await lab.prepareConversion(audio: input, modelID: "new_sts_model", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: id)
                #expect(paths.withLock { $0.count } == 2, "\(name): prepare must be local")
                let result = try await lab.convert(audio: input, modelID: "new_sts_model", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: id, authorization: approve(quote))
                #expect(result.pcm == output)
                #expect(paths.withLock { $0.count } == 3, "\(name): one paid send")
            } else {
                do {
                    _ = try await lab.prepareConversion(audio: input, modelID: "new_sts_model", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: id)
                    Issue.record("\(name): expected unsupported WAV")
                } catch VoiceLabError.unsupportedFormat {
                    #expect(paths.withLock { $0.count } == 2, "\(name): invalid WAV must send nothing")
                }
            }
        }
    }

    @Test func invalidConversionAtDispatchDoesNotSendOrConsumeQuote() async throws {
        let models = self.models, voices = self.voices, output = pcm()
        let paths = Mutex<[String]>([])
        let lab = service { request in
            let path = request.url?.path ?? ""
            paths.withLock { $0.append(path) }
            switch path {
            case "/v1/models": return (200, [:], models)
            case "/v2/voices": return (200, [:], voices)
            case "/v1/voice-changer/stock123": return (200, ["Content-Type": "audio/pcm"], output)
            default: throw URLError(.badURL)
            }
        }
        _ = try await lab.models()
        _ = try await lab.voices()
        let input = wav(pcm()), id = UUID(), voice = VoiceLabVoiceChoice.stock(voiceID: "stock123")
        let quote = try await lab.prepareConversion(audio: input, modelID: "new_sts_model", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: id)
        var malformed = input
        malformed.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        do {
            _ = try await lab.convert(audio: malformed, modelID: "new_sts_model", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: id, authorization: approve(quote))
            Issue.record("Expected invalid WAV before dispatch")
        } catch VoiceLabError.unsupportedFormat {
            #expect(paths.withLock { $0.count } == 2)
        }
        _ = try await lab.convert(audio: input, modelID: "new_sts_model", voice: voice, language: "en", seed: 7, cleanAudioOn: false, requestID: id, authorization: approve(quote))
        #expect(paths.withLock { $0.count } == 3)
    }

    @Test func redirectAndDeclaredOversizeNeverForwardCredentialsOrBody() async throws {
        let requests = Mutex<[URLRequest]>([]), status = Mutex(302)
        let lab = service { request in
            requests.withLock { $0.append(request) }
            if status.withLock({ $0 }) == 302 {
                return (302, ["Location": "https://untrusted.example.invalid/collect"], Data())
            }
            return (200, ["Content-Length": "999999999"], Data("[]".utf8))
        }
        do { _ = try await lab.models(); Issue.record("Expected redirect rejection") }
        catch VoiceLabError.providerFailure(302) {}
        #expect(requests.withLock { $0.count } == 1)
        #expect(requests.withLock { $0.first?.url?.host } == ElevenLabsRegion.eu.baseURL.host)
        status.withLock { $0 = 200 }
        do { _ = try await lab.models(); Issue.record("Expected size rejection") }
        catch VoiceLabError.responseTooLarge {}
        #expect(requests.withLock { $0.count } == 2)
    }
}

private actor RewriteStub: LLMConnector {
    nonisolated let id: ConnectorID = .openai
    let output: String
    private(set) var calls = 0
    init(output: String) { self.output = output }
    func status() async -> ConnectorStatus { .ready }
    func models(refresh: Bool) async throws -> [LLMModel] { [LLMModel(id: "selected-model", name: "Selected", contextTokens: 12_000, source: .custom)] }
    func contextTokens(model: String) async -> Int? { 12_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion {
        calls += 1
        #expect(request.feature == .voiceRewrite && request.schemaName == "voice_rewrite_proposal")
        #expect(request.cachedBlock?.contains("SOURCE TRANSCRIPT") == true)
        return RawCompletion(text: output, model: model, stop: .complete)
    }
}

@Suite("Voice rewrite review")
struct VoiceRewriteServiceTests {
    private let speech = VoiceLabSpeechOptions(seed: 7)

    @Test func concurrentRewriteApprovalSendsOnce() async throws {
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let connector = RewriteStub(output: "{\"rewrite\":\"Hello\"}")
        let input = VoiceRewriteRequest(id: UUID(), scope: .passage,
                                        sourceWords: [TimedWord(id: "w1", text: "Hi", start: 0, end: 0.3)],
                                        instruction: "Improve", language: "en")
        let quote = try await service.prepare(input, connector: .openai, model: "selected-model")
        let authorization = VoiceRewriteAuthorization(quote: quote, approved: true)
        let first = Task { try await service.propose(input, connector: connector, model: "selected-model", authorization: authorization) }
        let second = Task { try await service.propose(input, connector: connector, model: "selected-model", authorization: authorization) }
        let results = await [first.result, second.result]
        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(await connector.calls == 1)
    }

    @Test func sharedRewriteQuoteMutationsAndReplay() async throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let service = VoiceRewriteService(shared: shared)
        let connector = RewriteStub(output: "{\"rewrite\":\"Hello\"}")
        let document = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/contract.json")) as? [String: Any])
        let rows = try #require(document["rewriteMutations"] as? [[String: Any]])
        for row in rows {
            let field = try #require(row["field"] as? String)
            let allowed = try #require(row["allowed"] as? Bool)
            let words = [TimedWord(id: "w1", text: "Hi", start: 0, end: 0.3)]
            let input = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: words, instruction: "Improve", language: "en")
            let quote = try await service.prepare(input, connector: field == "connector" ? .anthropic : .openai, model: "selected-model")
            var changedWords = words
            if field == "sourceText" { changedWords[0].text = "Bye" }
            if field == "sourceTiming" { changedWords[0].end = 0.4 }
            let changed = VoiceRewriteRequest(id: input.id, scope: field == "scope" ? .fullTake : .passage,
                                              sourceWords: changedWords, instruction: field == "instruction" ? "Make longer" : "Improve",
                                              language: field == "language" ? "et" : "en")
            let before = await connector.calls
            do {
                _ = try await service.propose(changed, connector: connector, model: field == "model" ? "other-model" : "selected-model",
                                              authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
                #expect(allowed)
            } catch VoiceLabError.consentRequired { #expect(!allowed) }
            #expect(await connector.calls == before + (allowed ? 1 : 0), "field=\(field)")
            if allowed {
                do { _ = try await service.propose(input, connector: connector, model: "selected-model", authorization: VoiceRewriteAuthorization(quote: quote, approved: true)); Issue.record("Expected replay failure") }
                catch VoiceLabError.consentRequired {}
                #expect(await connector.calls == before + 1)
            }
        }
    }
    /// `\A…\z`, not `^…$`: ICU lets `$` match before a final line break, which would put "en\n" into the prompt.
    @Test(arguments: ["en\n", "en\r\n", "en "])
    func rewriteLanguageRejectsTrailingLineBreaksAndSpaces(_ language: String) async throws {
        let service = VoiceRewriteService(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let input = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: [TimedWord(id: "w1", text: "Hi", start: 0, end: 0.3)],
                                        instruction: "Improve", language: language)
        do { _ = try await service.prepare(input, connector: .openai, model: "selected-model"); Issue.record("Expected language rejection") }
        catch VoiceLabError.invalidInput {}
    }
    @Test func proposalPreservesSourceAndNeverSynthesizes() async throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let connector = RewriteStub(output: "{\"rewrite\":\"Better words for a quick vlog.\"}")
        let source = [TimedWord(id: "w1", text: "Original", start: 1, end: 1.4), TimedWord(id: "w2", text: "words", start: 1.5, end: 1.8)]
        let request = VoiceRewriteRequest(id: UUID(), scope: .fullTake, sourceWords: source, instruction: "Make it concise", language: "en")
        let service = VoiceRewriteService(shared: shared)
        let estimate = try await service.estimate(request, connector: .openai)
        #expect(estimate.usd == nil && estimate.credits == nil)
        let authorization = VoiceRewriteAuthorization(quote: try await service.prepare(request, connector: .openai, model: "selected-model"), approved: true)
        let proposal = try await service.propose(request, connector: connector, model: "selected-model", authorization: authorization)
        #expect(proposal.proposedText == "Better words for a quick vlog.")
        #expect(proposal.sourceWords == source && proposal.sourceText == "Original words")
        #expect(proposal.scope == .fullTake && proposal.connector == .openai)
        #expect(await connector.calls == 1)
    }
    @Test func rejectsModelGeneratedURL() async throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let connector = RewriteStub(output: "{\"rewrite\":\"Visit https://example.invalid\"}")
        let request = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: [TimedWord(id: "w1", text: "Hi", start: 0, end: 0.3)], instruction: "", language: "en")
        let service = VoiceRewriteService(shared: shared)
        let authorization = VoiceRewriteAuthorization(quote: try await service.prepare(request, connector: .openai, model: "selected-model"), approved: true)
        do { _ = try await service.propose(request, connector: connector, model: "selected-model", authorization: authorization); Issue.record("Expected inert text validation") }
        catch LLMError.invalidOutput {}
    }
    @Test func rewriteNeedsItsOwnApproval() async throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let connector = RewriteStub(output: "{\"rewrite\":\"Hello\"}")
        let request = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: [TimedWord(id: "w1", text: "Hi", start: 0, end: 0.3)], instruction: "", language: "en")
        let service = VoiceRewriteService(shared: shared)
        let authorization = VoiceRewriteAuthorization(quote: try await service.prepare(request, connector: .openai, model: "selected-model"), approved: true)
        let changed = VoiceRewriteRequest(id: request.id, scope: .fullTake, sourceWords: request.sourceWords, instruction: request.instruction, language: request.language)
        do { _ = try await service.propose(changed, connector: connector, model: "selected-model", authorization: authorization); Issue.record("Expected approval failure") }
        catch VoiceLabError.consentRequired {}
        #expect(await connector.calls == 0)
    }
    @Test func reviewedProposalRequiresSeparateSynthesisApproval() async throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let rewrite = VoiceRewriteService(shared: shared)
        let connector = RewriteStub(output: "{\"rewrite\":\"Hello\"}")
        let request = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: [TimedWord(id: "w1", text: "Hi", start: 0, end: 0.3)], instruction: "Improve", language: "en")
        let review = VoiceRewriteAuthorization(quote: try await rewrite.prepare(request, connector: .openai, model: "selected-model"), approved: true)
        let proposal = try await rewrite.propose(request, connector: connector, model: "selected-model", authorization: review)
        let generated = Mutex(0)
        let base = SpeechStubHTTP.register { request in
            switch request.url?.path {
            case "/v1/models": return (200, [:], Data("[{\"model_id\":\"speech_model\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"}]}]".utf8))
            case "/v2/voices": return (200, [:], Data("{\"voices\":[{\"voice_id\":\"stock123\",\"name\":\"Stock\",\"category\":\"premade\"}],\"has_more\":false}".utf8))
            case "/v1/text-to-speech/stock123/with-timestamps":
                generated.withLock { $0 += 1 }
                let pcm = Data(repeating: 0, count: 4_800).base64EncodedString()
                let response = "{\"audio_base64\":\"\(pcm)\",\"alignment\":{\"characters\":[\"H\",\"e\",\"l\",\"l\",\"o\"],\"character_start_times_seconds\":[0,0.01,0.02,0.03,0.04],\"character_end_times_seconds\":[0.01,0.02,0.03,0.04,0.05]}}"
                return (200, [:], Data(response.utf8))
            default: throw URLError(.badURL)
            }
        }
        let voice = ElevenLabsVoiceLab(keys: SpeechTestKeys(value: "synthetic-voice-lab-key"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), logger: SpeechTestLogger())
        _ = try await voice.models(); _ = try await voice.voices()
        let speechQuote = try await voice.prepareSynthesis(text: proposal.proposedText, modelID: "speech_model", voice: .stock(voiceID: "stock123"), language: "en", options: speech, requestID: proposal.id)
        let denied = VoiceLabAuthorization(quote: speechQuote, approved: false)
        do { _ = try await voice.synthesize(proposal: proposal, modelID: "speech_model", voice: .stock(voiceID: "stock123"), language: "en", options: speech, authorization: denied); Issue.record("Expected separate synthesis approval") }
        catch VoiceLabError.consentRequired {}
        #expect(generated.withLock { $0 } == 0)
        let approved = VoiceLabAuthorization(quote: speechQuote, approved: true)
        let result = try await voice.synthesize(proposal: proposal, modelID: "speech_model", voice: .stock(voiceID: "stock123"), language: "en", options: speech, authorization: approved)
        #expect(result.alignment?.count == 5 && generated.withLock { $0 } == 1)
        #expect(proposal.sourceWords[0].text == "Hi")
    }
}
