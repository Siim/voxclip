import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("ElevenLabs Scribe v2")
struct ElevenLabsTests {
    @Test(arguments: [false, true])
    func responseMapping(diarize: Bool) async throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let transcriber = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: .shared, catalog: BundledModelCatalog(shared: shared))
        let raw = try await transcriber.mapResponse(RecordedSpeech.scribe, diarize: diarize)
        #expect(raw.language == "et")
        #expect(raw.tokens.count == 5)
        #expect(raw.tokens[0].text == "Tere,")
        #expect(abs((raw.tokens[0].conf ?? 0) - exp(-0.02)) < 0.000001)
        #expect(raw.tokens[1].text == "ee")
        #expect(raw.tokens[3].kind == .event && raw.tokens[3].conf == nil)
        #expect(raw.tokens[0].speaker == (diarize ? "speaker_0" : nil))
        let words = try SpeechEditingImportAdapter.cleanWords(WordAssembler.group(raw.tokens, rule: raw.grouping, timelineStart: 0), timing: raw.timing)
        #expect(words.count == 4)
        #expect(raw.verbatim && raw.timing == .native)
    }
    @Test func multipartOrderAndPrivacy() throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try SpeechTestFiles.request(directory, options: TranscriptionOptions(diarize: true, numSpeakers: 2, keyterms: ["VoxClip", "TalTech"]))
        let bodyURL = try ElevenLabsTranscriber.multipart(request, boundary: "0123456789abcdef0123456789abcdef")
        let body = try String(contentsOf: bodyURL, encoding: .utf8)
        let names = ["model_id", "language_code", "timestamps_granularity", "tag_audio_events", "diarize", "num_speakers", "keyterms", "file"]
        var cursor = body.startIndex
        for name in names {
            let range = try #require(body.range(of: "name=\"\(name)\"", range: cursor..<body.endIndex))
            cursor = range.upperBound
        }
        #expect(body.contains("scribe_v2") && body.contains("filename=\"audio.wav\""))
        #expect(body.contains("Content-Type: audio/wav\r\n\r\nsynthetic audio bytes"))
        for forbidden in ["no_verbatim", "file_format", "enable_logging", "source_url"] { #expect(!body.contains(forbidden)) }
        let auto = try ElevenLabsTranscriber.multipart(SpeechTestFiles.request(directory, language: .auto), boundary: "test")
        #expect(try !String(contentsOf: auto, encoding: .utf8).contains("language_code"))
    }
    @Test(arguments: ["bad[term", String(repeating: "a", count: 50), "six words are far too many", "\r\nheader"])
    func invalidKeyterms(_ term: String) throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let request = try SpeechTestFiles.request(directory, options: TranscriptionOptions(keyterms: [term]))
        #expect(throws: VoxClipError.self) { try ElevenLabsTranscriber.multipart(request, boundary: "test") }
    }
    @Test(arguments: [(401, "invalid", VoxClipErrorCode.keyRejected), (401, "missing permission", .keyPermissionMissing), (403, "denied", .keyPermissionMissing), (422, "invalid", .providerError), (429, "busy", .rateLimited), (400, "credit quota", .quotaExceeded)])
    func errors(_ status: Int, _ body: String, _ code: VoxClipErrorCode) {
        #expect(ElevenLabsTranscriber.providerError(status: status, data: Data(body.utf8), key: "synthetic").code == code)
    }
    @Test func mockedUploadRetriesAndCachesPaidResponse() async throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Mutex(0), delays = Mutex<[Double]>([])
        let base = SpeechStubHTTP.register { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/speech-to-text")
            #expect(request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-key-for-tests")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "VoxClip/0.1.0 (macOS \(SpeechRuntimeVersion.macOS); arm64)")
            let attempt = calls.withLock { $0 += 1; return $0 }
            return attempt == 1 ? (429, ["Retry-After": "0"], Data("busy".utf8)) : (200, [:], RecordedSpeech.scribe)
        }
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: BundledModelCatalog(shared: shared), sleep: { delay in delays.withLock { $0.append(delay) } })
        let service = TranscriptionService(locations: SpeechTestFiles.locations(directory))
        let request = try SpeechTestFiles.request(directory)
        let firstResult = try await service.transcribeResult(request, using: engine, envelope: nil)
        let secondResult = try await service.transcribeResult(request, using: engine, envelope: nil)
        #expect(!firstResult.fromCache && secondResult.fromCache)
        #expect(!TranscriptionResult(transcript: firstResult.transcript).fromCache)
        let first = firstResult.transcript, second = secondResult.transcript
        #expect(calls.withLock { $0 } == 2)
        #expect(delays.withLock { $0 } == [0])
        #expect(first.words == second.words)
        #expect(first.rawKey == second.rawKey)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Cache/synthetic-content/transcripts"), includingPropertiesForKeys: nil)
        let cached = try SpeechRawCacheEntry.read(#require(files.first))
        #expect(cached.providerResponse != nil)
        #expect(cached.raw?.providerRequestID == "synthetic-recording-1")
        #expect(cached.providerResponseBytes == RecordedSpeech.scribe)
        let withoutKey = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil))
        let reused = try await service.transcribe(request, using: withoutKey, envelope: nil)
        #expect(reused.words == first.words)
        #expect(calls.withLock { $0 } == 2)
    }
    @Test func unexpectedResponseAndNoKey() async throws {
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil))
        await #expect(throws: VoxClipError.self) { try await engine.mapResponse(Data(#"{"transcripts":[]}"#.utf8), diarize: false) }
        #expect(await engine.readiness(for: TranscriptionPlan(engine: .elevenlabs)) == .needsKey(provider: "elevenlabs"))
    }
    @Test func limitsFailBeforeNetwork() async throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        var request = try SpeechTestFiles.request(directory)
        request.audio.durationSeconds = 36001
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key"), session: URLSession(configuration: SpeechStubHTTP.configuration()), catalog: try SpeechTestFiles.catalog())
        do { _ = try await engine.transcribe(request) { _ in }; Issue.record("Expected mediaTooLong") }
        catch let error as VoxClipError { #expect(error.code == .mediaTooLong) }
        request.audio.durationSeconds = 0.01
        do { _ = try await engine.transcribe(request) { _ in }; Issue.record("Expected noSpeech") }
        catch let error as VoxClipError { #expect(error.code == .noSpeech) }
    }
    @Test(arguments: [(400, VoxClipErrorCode.providerError), (401, .keyRejected), (403, .keyPermissionMissing), (422, .providerError), (429, .rateLimited), (529, .providerError)])
    func httpErrorsUseBoundedRetries(_ status: Int, _ expected: VoxClipErrorCode) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let attempts = Mutex(0), delays = Mutex<[Double]>([])
        let base = SpeechStubHTTP.register { _ in
            attempts.withLock { $0 += 1 }
            return (status, ["Retry-After": "90"], Data(#"{"detail":[{"msg":"invalid synthetic-key-for-tests"}]}"#.utf8))
        }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog(), sleep: { delay in delays.withLock { $0.append(delay) } })
        do { _ = try await engine.transcribe(SpeechTestFiles.request(root)) { _ in }; Issue.record("Expected HTTP error") }
        catch let error as VoxClipError {
            #expect(error.code == expected)
            #expect(error.errorDescription?.contains("synthetic-key-for-tests") != true)
        }
        let retryable = status == 429 || status >= 500
        #expect(attempts.withLock { $0 } == (retryable ? 3 : 1))
        #expect(delays.withLock { $0 } == (retryable ? [30, 30] : []))
    }

    @Test func transportFailuresRetryAndCancelDuringBackoff() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let attempts = Mutex(0)
        let base = SpeechStubHTTP.register { _ in attempts.withLock { $0 += 1 }; throw URLError(.networkConnectionLost) }
        let engine = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog(), sleep: { _ in })
        do { _ = try await engine.transcribe(SpeechTestFiles.request(root)) { _ in }; Issue.record("Expected offline") }
        catch let error as VoxClipError { #expect(error.code == .offline) }
        #expect(attempts.withLock { $0 } == 3)
        let cancelled = ElevenLabsTranscriber(keys: SpeechTestKeys(value: "synthetic-key-for-tests"), session: URLSession(configuration: SpeechStubHTTP.configuration()), base: base, catalog: try SpeechTestFiles.catalog(), sleep: { _ in throw CancellationError() })
        await #expect(throws: VoxClipError.cancelled) { _ = try await cancelled.transcribe(SpeechTestFiles.request(root)) { _ in } }
    }

    @Test func languageAutoIsOmittedAndSpeakerCountIsValidated() throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let invalid = try SpeechTestFiles.request(root, options: TranscriptionOptions(diarize: false, numSpeakers: 2))
        #expect(throws: VoxClipError.self) { try ElevenLabsTranscriber.multipart(invalid, boundary: "fixture") }
        let tooMany = try SpeechTestFiles.request(root, options: TranscriptionOptions(diarize: true, numSpeakers: 33))
        #expect(throws: VoxClipError.self) { try ElevenLabsTranscriber.multipart(tooMany, boundary: "fixture") }
    }
}
