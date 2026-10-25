import Foundation
import Synchronization
import Testing
@testable import VoxClipCore

@Suite("Speech model catalogue and downloads")
struct ModelStoreTests {
    @Test func twiceInterruptedDownloadResumesFromActualPartialSize() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<3000).map { UInt8($0 % 251) })
        let ranges = Mutex<[String?]>([])
        let base = SpeechStubHTTP.registerStream { request in
            // Serve from the requested offset: under load a dropped connection can leave fewer bytes on disk.
            let range = request.value(forHTTPHeaderField: "Range")
            let attempt = ranges.withLock { $0.append(range); return $0.count }
            let offset = range.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
            let end = attempt < 3 ? min(offset + 1000, payload.count) : payload.count
            return SpeechStubHTTP.Reply(status: range == nil ? 200 : 206,
                headers: range == nil ? [:] : ["Content-Range": "bytes \(offset)-2999/3000"],
                body: payload.subdata(in: offset..<end),
                failure: attempt < 3 ? .networkConnectionLost : nil)
        }
        let model = SpeechTestFiles.model(base.appendingPathComponent("model.bin"), data: payload)
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: SpeechTestFiles.locations(root), configuration: SpeechStubHTTP.configuration(), confirm: { _, _ in true }, availableCapacity: { _ in Int64.max })
        try await store.install(id: model.id) { _ in }
        let requested = ranges.withLock { $0 }
        #expect(requested.count == 3 && requested.first == .some(nil))
        let offsets = requested.dropFirst().compactMap { $0.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } }
        #expect(offsets.count == 2 && offsets[0] > 0 && offsets[1] > offsets[0])
        #expect(try await store.verify(id: model.id))
    }
    @Test func sha256VectorsAndIncremental() throws {
        #expect(SpeechSHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SpeechSHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var hash = SpeechSHA256(); hash.update(Data("a".utf8)); hash.update(Data("bc".utf8))
        #expect(hash.hexDigest() == SpeechSHA256.hex(Data("abc".utf8)))
        let spanning = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        #expect(SpeechSHA256.hex(spanning) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        let repeated = Data(repeating: 0x61, count: 1_000_000)
        #expect(SpeechSHA256.hex(repeated) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
    @Test func catalogueIntegrityAndLanguageCodes() async throws {
        let catalog = BundledModelCatalog(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let models = try await catalog.models()
        #expect(models.count == 9)
        #expect(try await catalog.normalizeLanguage("est") == "et")
        #expect(try await catalog.normalizeLanguage("eng") == "en")
        #expect(try await catalog.normalizeLanguage("cmn") == "zh")
        #expect(try await catalog.normalizeLanguage("xyz") == "xyz")
        #expect(try await catalog.whisperLanguage("jv") == "jw")
        #expect(try await catalog.fromWhisperLanguage("jw") == "jv")
        #expect(try await catalog.fromWhisperLanguage("eng") == "en")
        let runtime = try await catalog.runtime(id: "taltech-et-verbatim-2604-q8_0")
        #expect(runtime.forcedLanguage == "et" && !runtime.verbatim)
        #expect(runtime.whisper?.initialPromptByLanguage.isEmpty == true)
    }
    @Test func installResumeVerifyAndRemoveFileURL() async throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data((0..<10000).map { UInt8($0 % 251) })
        let source = directory.appendingPathComponent("source.bin"); try payload.write(to: source)
        let model = SpeechTestFiles.model(source, data: payload)
        let locations = SpeechTestFiles.locations(directory)
        let modelDirectory = locations.models.appendingPathComponent("whispercpp/test-model")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try payload.prefix(1234).write(to: modelDirectory.appendingPathComponent("model.bin.partial"))
        let partial = ModelStore.Partial(url: source, bytes: Int64(payload.count), sha256: model.files[0].sha256)
        try JSONEncoder().encode(partial).write(to: modelDirectory.appendingPathComponent("model.bin.partial.json"))
        let confirmations = Mutex(0)
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: locations, confirm: { _, total in #expect(total == 10000); confirmations.withLock { $0 += 1 }; return true }, availableCapacity: { _ in Int64.max })
        let events = Mutex<[ModelDownloadProgress]>([])
        try await store.install(id: model.id) { value in events.withLock { $0.append(value) } }
        let finalProgress = try #require(events.withLock { $0.last })
        #expect(finalProgress.verifying)
        #expect(finalProgress.receivedBytes == finalProgress.totalBytes)
        #expect(try await store.installedModels() == [model.id])
        #expect(try await store.verify(id: model.id))
        #expect(try Data(contentsOf: modelDirectory.appendingPathComponent("model.bin")) == payload)
        try await store.install(id: model.id) { _ in }
        #expect(confirmations.withLock { $0 } == 1)
        try await store.remove(id: model.id)
        #expect(try await store.installedModels().isEmpty)
    }
    @Test func checksumFailureNeverInstalls() async throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("bad model".utf8), source = directory.appendingPathComponent("source.bin")
        try payload.write(to: source)
        let model = SpeechTestFiles.model(source, data: payload, hash: String(repeating: "0", count: 64))
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: SpeechTestFiles.locations(directory), confirm: { _, _ in true }, availableCapacity: { _ in Int64.max })
        do { try await store.install(id: model.id) { _ in }; Issue.record("Expected checksum failure") }
        catch let error as VoxClipError { #expect(error.code == .modelChecksumMismatch) }
        #expect(try await store.installedModels().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Models/whispercpp/test-model/model.bin.partial").path))
    }
    @Test(arguments: [200, 206])
    func httpRangeResumeOrRestart(_ status: Int) async throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("complete model payload".utf8)
        let base = SpeechStubHTTP.register { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=8-")
            return (status, status == 206 ? ["Content-Range": "bytes 8-\(payload.count - 1)/\(payload.count)"] : [:], status == 206 ? Data(payload.dropFirst(8)) : payload)
        }
        let source = base.appendingPathComponent("model.bin"), model = SpeechTestFiles.model(source, data: payload)
        let modelDirectory = directory.appendingPathComponent("Models/whispercpp/test-model")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try payload.prefix(8).write(to: modelDirectory.appendingPathComponent("model.bin.partial"))
        try JSONEncoder().encode(ModelStore.Partial(url: source, bytes: Int64(payload.count), sha256: model.files[0].sha256)).write(to: modelDirectory.appendingPathComponent("model.bin.partial.json"))
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: SpeechTestFiles.locations(directory), configuration: SpeechStubHTTP.configuration(), confirm: { _, _ in true }, availableCapacity: { _ in Int64.max })
        try await store.install(id: model.id) { _ in }
        #expect(try await store.verify(id: model.id))
    }
    @Test func consentCancellationDownloadsNothing() async throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("missing"), model = SpeechTestFiles.model(source, data: Data("test".utf8))
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: SpeechTestFiles.locations(directory), confirm: { _, _ in false }, availableCapacity: { _ in Int64.max })
        await #expect(throws: VoxClipError.cancelled) { try await store.install(id: model.id) { _ in } }
        #expect(try await store.installedModels().isEmpty)
    }
    @Test func cacheKeyCanonicalizationAndExplicitNulls() throws {
        let directory = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        var request = try SpeechTestFiles.request(directory, options: TranscriptionOptions(keyterms: ["z", "a"]))
        let identity = EngineRef(id: .elevenlabs, modelId: "scribe_v2", engineVersion: "scribe_v2")
        let first = SpeechRawCacheKey(request: request, identity: identity)
        request.plan.options.keyterms.reverse()
        let second = SpeechRawCacheKey(request: request, identity: identity)
        #expect(try first.digest() == second.digest())
        let object = try #require(JSONSerialization.jsonObject(with: first.canonicalData()) as? [String: Any])
        #expect(object["locale"] is NSNull && object["numSpeakers"] is NSNull && object["modelSha256"] is NSNull)
    }

    @Test func missingConsentHookNeverDownloads() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = SpeechTestFiles.model(root.appendingPathComponent("not-read.bin"), data: Data("test".utf8))
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: SpeechTestFiles.locations(root), availableCapacity: { _ in Int64.max })
        await #expect(throws: VoxClipError.cancelled) { try await store.install(id: model.id) { _ in } }
    }

    @Test(arguments: [false, true])
    func httpChecksumFailureRemovesPartial(_ oversized: Bool) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("valid".utf8)
        let base = SpeechStubHTTP.register { _ in (200, [:], Data((oversized ? "invalid and too long" : "wrong").utf8)) }
        let model = SpeechTestFiles.model(base.appendingPathComponent("model.bin"), data: expected)
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: SpeechTestFiles.locations(root), configuration: SpeechStubHTTP.configuration(), confirm: { _, _ in true }, availableCapacity: { _ in Int64.max })
        do { try await store.install(id: model.id) { _ in }; Issue.record("Expected checksum mismatch") }
        catch let error as VoxClipError { #expect(error.code == .modelChecksumMismatch) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/whispercpp/test-model/model.bin.partial").path))
        #expect(try await store.installedModels().isEmpty)
    }

    @Test func wrongResumeRangeDoesNotAppend() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("complete model payload".utf8)
        let base = SpeechStubHTTP.register { _ in (206, ["Content-Range": "bytes 0-20/21"], payload) }
        let model = SpeechTestFiles.model(base.appendingPathComponent("model.bin"), data: payload)
        let directory = root.appendingPathComponent("Models/whispercpp/test-model")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent("model.bin.partial")
        try payload.prefix(8).write(to: partial)
        try JSONEncoder().encode(ModelStore.Partial(url: model.files[0].url, bytes: Int64(payload.count), sha256: model.files[0].sha256)).write(to: directory.appendingPathComponent("model.bin.partial.json"))
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: SpeechTestFiles.locations(root), configuration: SpeechStubHTTP.configuration(), confirm: { _, _ in true }, availableCapacity: { _ in Int64.max })
        do { try await store.install(id: model.id) { _ in }; Issue.record("Expected invalid range") }
        catch let error as VoxClipError { #expect(error.code == .providerError) }
        #expect(try Data(contentsOf: partial) == payload.prefix(8))
    }

    @Test func changedCatalogueHashInvalidatesMarker() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("model".utf8), source = root.appendingPathComponent("source.bin")
        try payload.write(to: source)
        let model = SpeechTestFiles.model(source, data: payload)
        let locations = SpeechTestFiles.locations(root)
        let original = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: locations, confirm: { _, _ in true }, availableCapacity: { _ in Int64.max })
        try await original.install(id: model.id) { _ in }
        let changed = SpeechTestFiles.model(source, data: payload, hash: String(repeating: "0", count: 64))
        let updated = ModelStore(catalog: SpeechTestCatalog(entries: [changed]), locations: locations, availableCapacity: { _ in Int64.max })
        #expect(try await updated.installedModels().isEmpty)
    }

    @Test func diskSpaceFailsBeforeConsentOrNetwork() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = SpeechTestFiles.model(root.appendingPathComponent("absent.bin"), data: Data("x".utf8))
        let store = ModelStore(catalog: SpeechTestCatalog(entries: [model]), locations: SpeechTestFiles.locations(root), confirm: { _, _ in Issue.record("Consent should not run without disk space"); return false }, availableCapacity: { _ in 1024 })
        do { try await store.install(id: model.id) { _ in }; Issue.record("Expected diskFull") }
        catch let error as VoxClipError { #expect(error.code == .diskFull) }
    }
}
