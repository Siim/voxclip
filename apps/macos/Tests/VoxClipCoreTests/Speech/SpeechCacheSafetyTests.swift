import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("Paid speech cache safety")
struct SpeechCacheSafetyTests {
    @Test(arguments: ["../x", "../../../../tmp/x", "en/x", "english"])
    func invalidLanguageCreatesNoFiles(_ language: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try SpeechTestFiles.request(root, language: .forced(language))
        let base = SpeechStubHTTP.register { _ in Issue.record("Invalid languages must not upload"); throw URLError(.badURL) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog())
        await #expect(throws: VoxClipError.transcriptionLanguageUnsupported("Invalid model or language identifier")) { try await engine.transcribe(request) { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["audio-16k.wav"])
    }

    @Test(arguments: [("scheme", VoxClipErrorCode.providerError), ("engine", .transcriptionLanguageUnsupported), ("model", .modelMissing), ("short", .noSpeech), ("long", .mediaTooLong), ("key", .keyMissing), ("keyterm", .providerError), ("speakers", .providerError)])
    func rejectedRequestsCreateNoFiles(_ failure: String, _ expected: VoxClipErrorCode) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var request = try SpeechTestFiles.request(root)
        switch failure {
        case "engine": request.plan.engine = .whispercpp
        case "model": request.plan.model = "unknown-model"
        case "short": request.audio.durationSeconds = 0.01
        case "long": request.audio.durationSeconds = 36_001
        case "keyterm": request.plan.options.keyterms = ["invalid\r\nterm"]
        case "speakers": request.plan.options.numSpeakers = 2
        default: break
        }
        let base = SpeechStubHTTP.register { _ in Issue.record("Rejected requests must not upload"); throw URLError(.badURL) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: failure == "key" ? nil : "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: failure == "scheme" ? URL(string: "http://example.invalid")! : base, catalog: try SpeechTestFiles.catalog())
        do { _ = try await engine.transcribe(request) { _ in }; Issue.record("Expected request preflight failure") }
        catch let error as VoxClipError { #expect(error.code == expected) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["audio-16k.wav"])
    }

    @Test(arguments: ["../model", "model/path", ".", ".."])
    func cacheURLRejectsInvalidModel(_ model: String) throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try SpeechTestFiles.request(root)
        let key = SpeechRawCacheKey(request: request, identity: EngineRef(id: .whispercpp, modelId: model, engineVersion: "test"))
        #expect(throws: VoxClipError.transcriptionLanguageUnsupported("Invalid model or language identifier")) { try key.url(in: root) }
    }

    @Test(arguments: [false, true])
    func wrappedEngineKeepsPaidResponse(_ retainedResponse: Bool) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try SpeechTestFiles.request(root.appendingPathComponent("Cache/synthetic-content"))
        let key = SpeechRawCacheKey(request: request, identity: EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2"))
        let directory = request.audio.wav16k.deletingLastPathComponent().appendingPathComponent("transcripts")
        let url = try key.url(in: directory)
        if retainedResponse {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try SpeechRawCacheEntry(key: key, raw: nil, providerResponse: nil, providerResponseBytes: RecordedSpeech.scribe).write(url)
        }
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], RecordedSpeech.scribe) }
        let engine = WrappedSpeechEngine(base: ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog()))
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        _ = try await service.transcribe(request, using: engine, envelope: nil)
        let entry = try SpeechRawCacheEntry.read(url)
        #expect(entry.key == key)
        #expect(entry.matchingRaw(for: key) != nil)
        #expect(entry.providerResponse != nil)
        #expect(entry.providerResponseBytes == RecordedSpeech.scribe)
        let cached = try await service.transcribeResult(request, using: engine, envelope: nil)
        #expect(cached.fromCache)
        #expect(calls.withLock { $0 } == (retainedResponse ? 0 : 1))
    }

    @Test(arguments: ["unavailable", "missing", "malformed", "unreadable"])
    func unavailableCatalogueNeverUploads(_ failure: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("catalog")
        if failure == "malformed" || failure == "unreadable" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("transcription-models.json")
            if failure == "malformed" { try Data("invalid JSON".utf8).write(to: file) }
            else { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
        }
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], RecordedSpeech.scribe) }
        let catalog = failure == "unavailable" ? nil : BundledModelCatalog(shared: SharedResources(root: root))
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: catalog)
        do { _ = try await engine.transcribe(SpeechTestFiles.request(root)) { _ in }; Issue.record("Expected catalogue preflight failure") }
        catch let error as VoxClipError { #expect(error.code == .sharedResourcesMissing) }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test(arguments: [Data(#"{"transcripts":[]}"#.utf8), Data([0xff, 0x7b])])
    func mappingFailureKeepsPaidBytesWithoutRebilling(_ body: Data) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], body) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog())
        let request = try SpeechTestFiles.request(root)
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        for _ in 0..<2 {
            do { _ = try await service.transcribe(request, using: engine, envelope: nil); Issue.record("Expected mapping failure") }
            catch let error as VoxClipError { #expect(error.code == .providerError) }
        }
        let key = SpeechRawCacheKey(request: request, identity: EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2"))
        let entry = try SpeechRawCacheEntry.read(key.url(in: root.appendingPathComponent("Cache/synthetic-content/transcripts")))
        #expect(entry.raw == nil)
        #expect(entry.providerResponseBytes == body)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func retainedResponseRemapsWithoutKeyAndReportsCacheHit() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try SpeechTestFiles.request(root)
        let key = SpeechRawCacheKey(request: request, identity: EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2"))
        let directory = root.appendingPathComponent("Cache/synthetic-content/transcripts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SpeechRawCacheEntry(key: key, raw: nil, providerResponse: nil, providerResponseBytes: RecordedSpeech.scribe).write(key.url(in: directory))
        let base = SpeechStubHTTP.register { _ in Issue.record("A retained paid response must never upload"); throw URLError(.badURL) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog())
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        let result = try await service.transcribeResult(request, using: engine, envelope: nil)
        #expect(result.fromCache)
        #expect(result.transcript.words.first?.text == "Tere,")
    }

    @Test func cacheMustBeWritableBeforeUpload() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("Cache"))
        let base = SpeechStubHTTP.register { _ in Issue.record("A failed cache preflight must not upload"); throw URLError(.badURL) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog())
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        await #expect(throws: (any Error).self) { try await service.transcribe(SpeechTestFiles.request(root), using: engine, envelope: nil) }
    }

    @Test func directCallsPersistResponsesAndUseInjectedRedactor() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], RecordedSpeech.scribe) }
        let logger = SpeechTestLogger()
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog(), logger: logger)
        let request = try SpeechTestFiles.request(root)
        _ = try await engine.transcribe(request) { _ in }
        _ = try await engine.transcribe(request) { _ in }
        #expect(calls.withLock { $0 } == 1)
        #expect(await logger.redact("synthetic-key-for-tests") == "[REDACTED]")
        let entries = await logger.entries
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.category == "transcribe" })
        #expect(entries.allSatisfy { !$0.message.contains("synthetic-key-for-tests") && !$0.message.contains("Tere,") && !$0.message.contains("(laughs)") })
    }
}

private struct WrappedSpeechEngine: Transcriber {
    let base: ElevenLabsTranscriber
    var engine: TranscriptEngine { base.engine }
    func capabilities(model: String?) -> TranscriberCapabilities { base.capabilities(model: model) }
    func supports(_ language: LanguageChoice, model: String?) async -> Bool { await base.supports(language, model: model) }
    func readiness(for plan: TranscriptionPlan) async -> Readiness { await base.readiness(for: plan) }
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws { try await base.prepare(for: plan, progress: progress) }
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript { try await base.transcribe(request, progress: progress) }
}
