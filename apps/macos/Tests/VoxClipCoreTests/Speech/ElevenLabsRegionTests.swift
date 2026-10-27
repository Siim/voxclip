import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("ElevenLabs regional routing", .timeLimit(.minutes(1)))
struct ElevenLabsRegionTests {
    @Test(arguments: [
        ("default", "https://api.elevenlabs.io"),
        ("us", "https://api.us.elevenlabs.io"),
        ("eu", "https://api.eu.residency.elevenlabs.io"),
        ("in", "https://api.in.residency.elevenlabs.io"),
        ("sg", "https://api.sg.residency.elevenlabs.io")
    ])
    func settingsRouteEveryUploadToTheFixedHost(_ stored: String, _ base: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Mutex(0)
        let handler = SpeechStubHTTP.register { request in
            #expect(request.url?.absoluteString == base + "/v1/speech-to-text")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-region-key")
            calls.withLock { $0 += 1 }
            return (200, [:], RecordedSpeech.scribe)
        }
        let logger = SpeechTestLogger()
        let settings = SettingsDocument(values: ["transcription.elevenlabs.region": .string(stored)])
        let engine = await ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-region-key"), settings: settings, session: URLSession(configuration: SpeechStubHTTP.configuration(for: handler)), catalog: try SpeechTestFiles.catalog(), logger: logger)
        #expect(engine.region.rawValue == stored)
        #expect(await logger.entries.isEmpty)
        _ = try await engine.transcribe(SpeechTestFiles.request(root)) { _ in }
        #expect(calls.withLock { $0 } == 1)
        let production = await ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), settings: settings, logger: logger)
        #expect(production.region == engine.region)
    }

    @Test(arguments: [JSONValue.string("unknown"), .string("US"), .string("https://example.invalid"), .string(""), .number(1), .null])
    func unknownStoredRegionFallsBackWithWarning(_ stored: JSONValue) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let handler = SpeechStubHTTP.register { request in
            #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
            return (200, [:], RecordedSpeech.scribe)
        }
        let logger = SpeechTestLogger()
        let settings = SettingsDocument(values: ["transcription.elevenlabs.region": stored])
        let engine = await ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-region-key"), settings: settings, session: URLSession(configuration: SpeechStubHTTP.configuration(for: handler)), catalog: try SpeechTestFiles.catalog(), logger: logger)
        #expect(engine.region == .default)
        let warnings = await logger.entries.filter { $0.level == .warn }
        #expect(warnings.count == 1)
        #expect(warnings.first?.category == "transcribe")
        #expect(warnings.first?.message == "Unknown ElevenLabs region setting; using Default.")
        _ = try await engine.transcribe(SpeechTestFiles.request(root)) { _ in }
    }

    @Test func missingRegionUsesDefaultWithoutWarning() async {
        let logger = SpeechTestLogger()
        let engine = await ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), settings: SettingsDocument(), logger: logger)
        #expect(engine.region == .default)
        #expect(await logger.entries.isEmpty)
    }

    @Test func regionsReuseTheSamePaidCacheEntry() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Mutex(0)
        let handler = SpeechStubHTTP.register { request in
            #expect(request.url?.host == "api.us.elevenlabs.io")
            calls.withLock { $0 += 1 }
            return (200, [:], RecordedSpeech.scribe)
        }
        let session = URLSession(configuration: SpeechStubHTTP.configuration(for: handler))
        let catalog = try SpeechTestFiles.catalog()
        let original = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-region-key"), session: session, region: .us, catalog: catalog)
        let relocated = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: session, region: .eu, catalog: catalog)
        let request = try SpeechTestFiles.request(root)
        let first = try await original.transcribe(request) { _ in }
        let cached = try await relocated.transcribe(request) { _ in }
        #expect(first == cached)
        #expect(calls.withLock { $0 } == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("transcripts").path)
        #expect(files.count == 1)
    }

    @Test func regionEnumMatchesTheSharedSettingsSchema() throws {
        let shared = try FixtureLoader.sharedRoot()
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.appendingPathComponent("schemas/settings.schema.json"))) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let region = try #require(properties["transcription.elevenlabs.region"] as? [String: Any])
        let values = try #require(region["enum"] as? [String])
        #expect(Set(values) == Set(ElevenLabsRegion.allCases.map(\.rawValue)))
        #expect(region["default"] as? String == ElevenLabsRegion.default.rawValue)
    }
}
