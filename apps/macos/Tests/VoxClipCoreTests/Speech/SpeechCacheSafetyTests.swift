import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("Paid speech cache safety", .timeLimit(.minutes(1)))
struct SpeechCacheSafetyTests {
    @Test(arguments: ["../x", "../../../../tmp/x", "en/x", "english"])
    func invalidLanguageCreatesNoFiles(_ language: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try SpeechTestFiles.request(root, language: .forced(language))
        let base = SpeechStubHTTP.register { _ in Issue.record("Invalid languages must not upload"); throw URLError(.badURL) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        await #expect(throws: VoxClipError.transcriptionLanguageUnsupported("ElevenLabs", language: "the selected model or language identifier")) { try await engine.transcribe(request) { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["audio-16k.wav"])
    }

    @Test(arguments: [
        ("engine", VoxClipErrorCode.transcriptionLanguageUnsupported, "ElevenLabs can't transcribe et."),
        ("model", .transcriptionFailed, "Transcription stopped: ElevenLabs requires the scribe_v2 model. Your video is still here."),
        ("short", .noSpeech, "We didn't hear any words. Check the audio track or choose the language."),
        ("long", .mediaTooLong, "ElevenLabs accepts up to 10 hours. This take is 10:00:01."),
        ("key", .keyMissing, "Add your ElevenLabs key in Settings to use it."),
        ("keyterm", .transcriptionFailed, "Transcription stopped: Invalid keyterm: invalid\r\nterm. Your video is still here."),
        ("keyterms", .transcriptionFailed, "Transcription stopped: At most 1000 keyterms are allowed. Your video is still here."),
        ("speakers", .transcriptionFailed, "Transcription stopped: Speaker count needs diarization and a value from 1 to 32. Your video is still here."),
        ("speakerRange", .transcriptionFailed, "Transcription stopped: Speaker count needs diarization and a value from 1 to 32. Your video is still here.")
    ])
    func rejectedRequestsCreateNoFiles(_ failure: String, _ expected: VoxClipErrorCode, _ copy: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var request = try SpeechTestFiles.request(root)
        switch failure {
        case "engine": request.plan.engine = .whispercpp
        case "model": request.plan.model = "unknown-model"
        case "short": request.audio.durationSeconds = 0.01
        case "long": request.audio.durationSeconds = 36_001
        case "keyterm": request.plan.options.keyterms = ["invalid\r\nterm"]
        case "keyterms": request.plan.options.keyterms = Array(repeating: "term", count: 1001)
        case "speakers": request.plan.options.numSpeakers = 2
        case "speakerRange": request.plan.options = TranscriptionOptions(diarize: true, numSpeakers: 33)
        default: break
        }
        let base = SpeechStubHTTP.register { _ in Issue.record("Rejected requests must not upload"); throw URLError(.badURL) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: failure == "key" ? nil : "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        do { _ = try await engine.transcribe(request) { _ in }; Issue.record("Expected request preflight failure") }
        catch let error as VoxClipError {
            #expect(error.code == expected)
            #expect(error.errorDescription == copy)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["audio-16k.wav"])
    }

    @Test(arguments: ["../model", "model/path", ".", ".."])
    func cacheURLRejectsInvalidModel(_ model: String) throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try SpeechTestFiles.request(root)
        let key = SpeechRawCacheKey(request: request, identity: EngineRef(id: .whispercpp, modelId: model, engineVersion: "test"))
        #expect(throws: VoxClipError.transcriptionLanguageUnsupported("Whisper", language: "the selected model or language identifier")) { try key.url(in: root) }
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
        let engine = WrappedSpeechEngine(base: ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog()))
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
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: catalog)
        do { _ = try await engine.transcribe(SpeechTestFiles.request(root)) { _ in }; Issue.record("Expected catalogue preflight failure") }
        catch let error as VoxClipError { #expect(error.code == .sharedResourcesMissing) }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test(arguments: [Data(#"{"transcripts":[]}"#.utf8), Data([0xff, 0x7b])])
    func mappingFailureKeepsPaidBytesWithoutRebilling(_ body: Data) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], body) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
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
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        let result = try await service.transcribeResult(request, using: engine, envelope: nil)
        #expect(result.fromCache)
        #expect(result.transcript.words.first?.text == "Tere,")
    }

    @Test(arguments: ["truncated", "binary", "newer schema"])
    func unreadableEntryIsSetAsideBeforeANewUpload(_ seed: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try SpeechTestFiles.request(root)
        let key = SpeechRawCacheKey(request: request, identity: EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2"))
        let directory = root.appendingPathComponent("Cache/synthetic-content/transcripts")
        let url = try key.url(in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch seed {
        case "truncated": try Data(#"{"schema":"voxclip-raw-transcript/1","key":"#.utf8).write(to: url)
        case "binary": try Data([0xff, 0x00, 0x7b]).write(to: url)
        default: try SpeechRawCacheEntry(schema: "voxclip-raw-transcript/2", key: key, raw: nil, providerResponse: nil, providerResponseBytes: RecordedSpeech.scribe).write(url)
        }
        let seeded = try Data(contentsOf: url)
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], RecordedSpeech.scribe) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        #expect(try await service.transcribeResult(request, using: engine, envelope: nil).fromCache == false)
        #expect(try await service.transcribeResult(request, using: engine, envelope: nil).fromCache)
        #expect(calls.withLock { $0 } == 1)
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != url.lastPathComponent }
        #expect(aside.count == 1)
        let name = try #require(aside.first)
        let prefix = url.lastPathComponent + ".unreadable-"
        #expect(name.hasPrefix(prefix) && Int64(name.dropFirst(prefix.count)) != nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == seeded)
        #expect(try SpeechRawCacheEntry.read(url).providerResponseBytes == RecordedSpeech.scribe)
    }

    @Test(arguments: ["missing", "number", "spaced", "offset"])
    func foreignCreatedAtStillServesThePaidResponse(_ form: String) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try SpeechTestFiles.request(root)
        let key = SpeechRawCacheKey(request: request, identity: EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2"))
        let directory = root.appendingPathComponent("Cache/synthetic-content/transcripts")
        let url = try key.url(in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SpeechRawCacheEntry(key: key, raw: nil, providerResponse: nil, providerResponseBytes: RecordedSpeech.scribe).write(url)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let foreign: [String: Any] = ["number": 783_000_000, "spaced": "2026-10-27 12:00:00", "offset": "2026-10-27T14:00:00+02:00"]
        object["createdAt"] = foreign[form]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let modified = Date(timeIntervalSince1970: 1_792_998_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        #expect(try SpeechRawCacheEntry.read(url).createdAt == modified)
        let base = SpeechStubHTTP.register { _ in Issue.record("A retained paid response must never upload"); throw URLError(.badURL) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        let result = try await TranscriptionService(locations: SpeechTestFiles.locations(root)).transcribeResult(request, using: engine, envelope: nil)
        #expect(result.fromCache)
        #expect(result.transcript.words.first?.text == "Tere,")
        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let createdAt = try #require(rewritten["createdAt"] as? String)
        #expect(createdAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil)
    }

    @Test(arguments: [1, 2, 3, 4])
    func paidResponseRetriesUnwritableCacheWithoutRebilling(_ restoreOnRetry: Int) async throws {
        let root = try SpeechTestFiles.directory()
        let directory = root.appendingPathComponent("Cache/synthetic-content/transcripts")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let calls = Mutex(0), delays = Mutex<[Double]>([])
        let base = SpeechStubHTTP.register { _ in
            calls.withLock { $0 += 1 }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            return (200, [:], RecordedSpeech.scribe)
        }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog(), sleep: { delay in
            let retry = delays.withLock { $0.append(delay); return $0.count }
            if retry == restoreOnRetry { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        })
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        let request = try SpeechTestFiles.request(root)
        let first = try await service.transcribeResult(request, using: engine, envelope: nil)
        let restored = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        let second = try await service.transcribeResult(request, using: restored, envelope: nil)
        #expect(first.transcript.words.first?.text == "Tere,")
        #expect(first.transcript.words == second.transcript.words)
        #expect(!first.fromCache && second.fromCache)
        #expect(calls.withLock { $0 } == 1)
        #expect(delays.withLock { $0 } == Array([0.05, 0.1, 0.05, 0.1].prefix(restoreOnRetry)))
        let key = SpeechRawCacheKey(request: request, identity: EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2"))
        let cached = try SpeechRawCacheEntry.read(key.url(in: directory))
        #expect(cached.providerResponseBytes == RecordedSpeech.scribe)
        #expect(cached.raw != nil)
    }

    @Test func paidTranscriptSurvivesExhaustedCacheWrites() async throws {
        let root = try SpeechTestFiles.directory()
        let directory = root.appendingPathComponent("Cache/synthetic-content/transcripts")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let calls = Mutex(0), delays = Mutex<[Double]>([])
        let base = SpeechStubHTTP.register { _ in
            calls.withLock { $0 += 1 }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            return (200, [:], RecordedSpeech.scribe)
        }
        let logger = SpeechTestLogger()
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog(), sleep: { delay in delays.withLock { $0.append(delay) } }, logger: logger)
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        let result = try await service.transcribeResult(SpeechTestFiles.request(root), using: engine, envelope: nil)
        #expect(result.transcript.words.first?.text == "Tere,")
        #expect(!result.fromCache)
        #expect(calls.withLock { $0 } == 1)
        #expect(delays.withLock { $0 } == [0.05, 0.1, 0.05, 0.1])
        let warnings = await logger.entries.filter { $0.level == .warn && $0.message.contains("cacheWriteFailed") }
        #expect(warnings.count == 2)
        #expect(warnings.allSatisfy { $0.category == "transcribe" && $0.message == "engine=elevenlabs cacheWriteFailed attempts=3 paidResponseRetainedForImport=true" })
    }

    @Test func cacheMustBeWritableBeforeUpload() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("Cache"))
        let base = SpeechStubHTTP.register { _ in Issue.record("A failed cache preflight must not upload"); throw URLError(.badURL) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog())
        let service = TranscriptionService(locations: SpeechTestFiles.locations(root))
        await #expect(throws: (any Error).self) { try await service.transcribe(SpeechTestFiles.request(root), using: engine, envelope: nil) }
    }

    @Test func directCallsPersistResponsesAndUseInjectedRedactor() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = Mutex(0)
        let base = SpeechStubHTTP.register { _ in calls.withLock { $0 += 1 }; return (200, [:], RecordedSpeech.scribe) }
        let logger = SpeechTestLogger()
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), catalog: try SpeechTestFiles.catalog(), logger: logger)
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
