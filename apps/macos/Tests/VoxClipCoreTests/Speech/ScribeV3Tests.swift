import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

/// Scribe v3 upgrade: one model id from the catalogue, legacy scribe_v2 plans and projects, tolerant replies; transcription §8.
@Suite("ElevenLabs Scribe v3", .timeLimit(.minutes(1)), .offlineFixtures)
struct ScribeV3Tests {
    @Test func modelIDMatchesBothCatalogues() throws {
        let models = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("catalog/transcription-models.json")) as? [String: Any])
        let engine = try #require((models["engines"] as? [[String: Any]])?.first { $0["id"] as? String == "elevenlabs" })
        #expect(engine["modelId"] as? String == ElevenLabsScribe.modelID)
        let prices = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("catalog/voice-lab.json")) as? [String: Any])
        let rows = try #require(prices["entries"] as? [[String: Any]]).filter { $0["operation"] as? String == "speechToText" }
        #expect(rows.count == 1 && rows.first?["model"] as? String == ElevenLabsScribe.modelID)
        #expect(ElevenLabsScribe.modelID == "scribe_v3" && !ElevenLabsScribe.legacyModelIDs.contains(ElevenLabsScribe.modelID))
    }

    @Test(arguments: [nil, "scribe_v2", "scribe_v3"] as [String?])
    func everyAcceptedPlanSendsTheCurrentModelWithoutV3OnlyFields(_ model: String?) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bodies = Mutex<[String]>([])
        let base = SpeechStubHTTP.register { _ in
            let bodyURL = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "multipart" })
            let body = try String(contentsOf: bodyURL, encoding: .utf8)
            bodies.withLock { $0.append(body) }
            return (200, [:], RecordedSpeech.scribe)
        }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        var request = try SpeechTestFiles.request(root)
        request.plan.model = model
        let raw = try await engine.transcribe(request) { _ in }
        #expect(raw.engine == EngineRef(id: .elevenlabs, modelId: "scribe_v3", engineVersion: "scribe_v3"))
        let body = try #require(bodies.withLock { $0 }.first)
        #expect(body.contains("name=\"model_id\"\r\n\r\nscribe_v3\r\n"))
        for absent in ["scribe_v2", "numbers_format", "secondary_language_codes"] { #expect(!body.contains(absent), "\(absent)") }
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("transcripts"), includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent).allSatisfy { $0.hasPrefix("elevenlabs-scribe_v3-et-") } && files.count == 1)
    }

    @Test func anUnknownModelNamesTheCurrentOne() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], RecordedSpeech.scribe) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        var request = try SpeechTestFiles.request(root)
        request.plan.model = "scribe_v1"
        await #expect(throws: VoxClipError.transcriptionFailed("ElevenLabs requires the scribe_v3 model")) { _ = try await engine.transcribe(request) { _ in } }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func aScribeV2CacheEntryIsNotServedForAV3Request() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], RecordedSpeech.scribe) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        let request = try SpeechTestFiles.request(root)
        let legacy = EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2")
        let legacyKey = SpeechRawCacheKey(request: request, identity: legacy)
        let current = SpeechRawCacheKey(request: request, identity: ElevenLabsTranscriber.identity)
        #expect(try legacyKey.digest() != current.digest())
        let legacyRaw = RawTranscript(engine: legacy, grouping: GroupingRule(end: .lastToken, conf: .single, bracketEvents: false),
            tokens: [RawToken(text: "legacy", start: 0, end: 1, conf: 1, speaker: nil, kind: nil)], language: "et", languageProbability: 1,
            verbatim: true, timing: .native, providerRequestID: nil)
        // Even a v2 entry sitting at the v3 path is refused by its key.
        let directory = root.appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SpeechRawCacheEntry(key: legacyKey, raw: legacyRaw, providerResponse: nil).write(legacyKey.url(in: directory))
        try SpeechRawCacheEntry(key: legacyKey, raw: legacyRaw, providerResponse: nil).write(current.url(in: directory))
        let raw = try await engine.transcribe(request) { _ in }
        #expect(calls.withLock { $0 } == 1)
        #expect(raw.engine.modelId == "scribe_v3" && !raw.tokens.contains { $0.text == "legacy" })
        #expect(try SpeechRawCacheEntry.read(legacyKey.url(in: directory)).raw == legacyRaw)
    }

    @Test(arguments: ["projects/interview-take", "projects/five-questions", "voice-lab/full-take-project"])
    func aScribeV2ProjectOpensWithItsTranscriptAndEngineUnchanged(_ name: String) throws {
        let data = try FixtureLoader.data("fixtures/\(name).voxclip")
        let recorded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recordedTranscript = try #require(recorded["transcript"] as? [String: Any])
        let recordedWords = try #require(recordedTranscript["words"] as? [[String: Any]])
        let project = try JSONProjectStore.decode(data)
        let transcript = try #require(project.transcript)
        #expect(transcript.engine == EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: transcript.engine.engineVersion))
        #expect(transcript.words.map(\.id) == recordedWords.compactMap { $0["id"] as? String })
        #expect(transcript.words.map(\.text) == recordedWords.compactMap { $0["text"] as? String })
        let saved = try JSONProjectStore.decode(JSONProjectStore.encode(project))
        #expect(saved == project && saved.transcript?.engine.modelId == "scribe_v2")
    }

    @Test(arguments: [#""language_code":null,"#, ""])
    func aReplyWithoutALanguageCodeKeepsItsWords(_ field: String) async throws {
        let reply = Data(#"{\#(field)"language_probability":0.9,"future_field":{"nested":[1,2]},"words":[{"text":"Tere","type":"word","start":0.1,"end":0.4,"logprob":-0.01,"new_word_field":"x"},{"text":" ","type":"spacing","start":0.4,"end":0.5},{"text":"täna","type":"word","start":0.5,"end":0.9,"logprob":-0.1}],"transcription_id":"abc123"}"#.utf8)
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: .shared, catalog: try SpeechTestFiles.catalog())
        let forced = try await engine.mapResponse(reply, diarize: false, language: .forced("et"))
        #expect(forced.language == "et" && forced.tokens.map(\.text) == ["Tere", "täna"])
        let auto = try await engine.mapResponse(reply, diarize: false, language: .auto)
        #expect(auto.language == nil && auto.tokens.map(\.text) == ["Tere", "täna"])
    }

    @Test func anAudioHourCostsTwentyCents() throws {
        let catalog = try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
        let hour = try VoiceLabPricing.estimate(operation: .elevenLabsSpeechToText, model: ElevenLabsScribe.modelID, units: 3600, catalog: catalog)
        #expect(hour.usd.map(VoiceLabMoney.canonical) == "0.2")
        let entry = try #require(catalog.entry(for: .elevenLabsSpeechToText, model: ElevenLabsScribe.modelID))
        #expect(entry.checked == "2026-11-19")
    }
}
