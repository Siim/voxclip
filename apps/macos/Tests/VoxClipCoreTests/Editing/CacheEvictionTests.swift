import Foundation
import Testing
@testable import VoxClipCore

/// A sleep that returns only when the test wakes it, recording what it was asked for.
private actor ManualSleep {
    private(set) var requests: [Duration] = []
    private var sleeper: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func sleep(_ duration: Duration) async {
        requests.append(duration)
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { sleeper = $0 }
    }
    /// Returns once something sleeps.
    func asleep() async {
        guard sleeper == nil else { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func wake() { sleeper?.resume(); sleeper = nil }
}

/// Holds whatever calls `hold()` until the test opens it.
private actor HoldGate {
    private var held: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var opened = false
    func hold() async {
        guard !opened else { return }
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { held = $0 }
    }
    /// Returns once something is held.
    func reached() async {
        guard held == nil else { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func open() { opened = true; held?.resume(); held = nil }
}

/// Writes the audio, then waits for the gate before it writes the envelope, as a long extraction would.
private struct HeldExtractor: AudioExtractor {
    let gate: HoldGate
    func extract(_ request: AudioExtractionRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioExtractionResult {
        try FileManager.default.createDirectory(at: request.cacheDirectory, withIntermediateDirectories: true)
        let wav = request.cacheDirectory.appendingPathComponent("audio-16k.wav")
        try Data(repeating: 1, count: 4000).write(to: wav)
        await gate.hold()
        try Data(repeating: 0, count: 64).write(to: request.cacheDirectory.appendingPathComponent("envelope-10ms.f32"))
        return AudioExtractionResult(audio: ExtractedAudio(wav16k: wav, sampleCount: 16, durationSeconds: 0.001),
                                     envelope: AudioEnvelope(sampleRate: 44100, levels: Array(repeating: 0.5, count: 16)))
    }
}

/// A local engine that transcribes only once the gate opens.
private struct HeldEngine: Transcriber {
    let gate: HoldGate
    var engine: TranscriptEngine { .whispercpp }
    func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .native, verbatim: true, autoLanguage: false, onDevice: true) }
    func supports(_ language: LanguageChoice, model: String?) async -> Bool { true }
    func readiness(for plan: TranscriptionPlan) async -> Readiness { .ready }
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        await gate.hold()
        return RawTranscript(engine: EngineRef(id: .whispercpp, modelId: nil, engineVersion: "test"), grouping: GroupingRule(end: .lastToken, conf: .single, bracketEvents: false),
                             tokens: [RawToken(text: "hello", start: 0.1, end: 0.4, kind: .word)], language: "en", verbatim: true, timing: .native)
    }
}

/// Background eviction under the cache size limit, leases, Clear cache and Clear everything (architecture §8.2). Sizes
/// are logical: audio and envelopes are sparse files, so a gigabyte-scale cache takes no disk space.
@Suite("Cache eviction", .serialized, .timeLimit(.minutes(1)))
struct CacheEvictionTests {
    static let gb = CacheEvictionScheduler.bytesPerGB
    static let mb: Int64 = 1_000_000
    /// The injected clock's now.
    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    static func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
    static func key(_ character: Character) -> String { String(repeating: character, count: 64) }

    func locations() throws -> DataLocations {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-cache-eviction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        return DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
    }

    /// A file of `bytes` logical bytes that takes no disk space.
    static func sparse(_ url: URL, _ bytes: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    /// An entry as extraction leaves it, with meta.json, last used at `used`.
    @discardableResult
    func entry(_ key: String, in locations: DataLocations, audio: Int64, envelope: Int64, transcript: Bool = false, thumbs: Bool = false,
               used: Date) async throws -> URL {
        let directory = locations.cache.appendingPathComponent(key, isDirectory: true)
        try Self.sparse(directory.appendingPathComponent("audio-16k.wav"), audio)
        try Self.sparse(directory.appendingPathComponent("envelope-10ms.f32"), envelope)
        if transcript { try Self.sparse(directory.appendingPathComponent("transcripts/whispercpp-none-en-00000000.json"), 2_000) }
        if thumbs { try Self.sparse(directory.appendingPathComponent("thumbs/strip-160.jpg"), 500_000) }
        var meta = CacheEntry(contentKey: key, createdAt: used, lastAccessAt: used, bytes: audio + envelope)
        meta.envelope = CacheEnvelope(sampleRate: 48_000, count: Int(envelope / 4))
        try await CacheStore(locations: locations).record(meta)
        return directory
    }

    /// An entry without meta.json, everything in it last written at `written`.
    @discardableResult
    func unindexed(_ key: String, in locations: DataLocations, files: [String: Int64], written: Date) throws -> URL {
        let directory = locations.cache.appendingPathComponent(key, isDirectory: true)
        for (name, bytes) in files { try Self.sparse(directory.appendingPathComponent(name), bytes) }
        try Self.touch(directory, at: written)
        return directory
    }

    static func touch(_ directory: URL, at date: Date) throws {
        let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for item in items + [directory] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path) }
    }

    fileprivate func scheduler(_ locations: DataLocations, limit: Int64, sleep: ManualSleep = ManualSleep()) -> CacheEvictionScheduler {
        CacheEvictionScheduler(store: CacheStore(locations: locations), log: EditingTestLogger(), limitBytes: { limit },
                               sleep: { await sleep.sleep($0) }, now: { Self.now })
    }

    static func exists(_ url: URL, _ name: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (name.map { url.appendingPathComponent($0) } ?? url).path)
    }
    static func contents(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
    static let stripped = ["envelope-10ms.f32", "meta.json"]

    /// Yields until `condition` holds; the suite time limit ends a test that never gets there.
    static func until(_ condition: () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    @Test func theLaunchPassWaitsThirtySeconds() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let old = try await entry(Self.key("a"), in: locations, audio: 1_500 * Self.mb, envelope: 19 * Self.mb, used: Self.ago(hours: 72))
        let recent = try await entry(Self.key("b"), in: locations, audio: 1_500 * Self.mb, envelope: 19 * Self.mb, used: Self.ago(hours: 24))
        let sleep = ManualSleep()
        let scheduler = scheduler(locations, limit: 2 * Self.gb, sleep: sleep)
        let launch = scheduler.scheduleAfterLaunch()
        await sleep.asleep()
        #expect(await sleep.requests == [.seconds(30)])
        #expect(scheduler.scheduleAfterLaunch() == launch)
        // Nothing is evicted before the delay is over.
        #expect(Self.exists(old, "audio-16k.wav") && scheduler.completedRuns == 0)
        await sleep.wake()
        await launch.value
        await scheduler.waitUntilIdle()
        #expect(scheduler.completedRuns == 1)
        #expect(Self.contents(old) == Self.stripped)
        #expect(Self.exists(recent, "audio-16k.wav"))
        #expect(await sleep.requests == [.seconds(30)])
    }

    /// After an import, and when the limit is lowered, the pass runs at once.
    @Test func aRequestedPassRunsAtOnce() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let old = try await entry(Self.key("a"), in: locations, audio: 1_500 * Self.mb, envelope: 19 * Self.mb, used: Self.ago(hours: 72))
        let recent = try await entry(Self.key("b"), in: locations, audio: 1_500 * Self.mb, envelope: 19 * Self.mb, used: Self.ago(hours: 24))
        let sleep = ManualSleep()
        let scheduler = scheduler(locations, limit: 2 * Self.gb, sleep: sleep)
        scheduler.requestRun()
        await scheduler.waitUntilIdle()
        #expect(scheduler.completedRuns == 1)
        #expect(await sleep.requests.isEmpty)
        #expect(Self.contents(old) == Self.stripped)
        #expect(Self.exists(recent, "audio-16k.wav"))
    }

    /// At the 2 GB setting, the least recently used entries lose their audio, thumbnails and faces until the cache fits;
    /// they keep their envelopes and raw transcripts, and newer entries keep everything.
    @Test func theLimitStripsTheLeastRecentlyUsedAudioFirst() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        var entries: [URL] = []
        for (index, character) in ["a", "b", "c", "d"].enumerated() {
            // A 700 MB extraction is about 6 hours of 16 kHz audio; its envelope is 1.25% of that.
            entries.append(try await entry(Self.key(Character(character)), in: locations, audio: 700 * Self.mb, envelope: 8_750_000,
                                           transcript: true, thumbs: true, used: Self.ago(hours: Double(100 - index))))
        }
        let scheduler = scheduler(locations, limit: CacheEvictionScheduler.limitBytes(gigabytes: 2))
        scheduler.requestRun()
        await scheduler.waitUntilIdle()
        for stripped in entries[0...1] {
            #expect(Self.contents(stripped) == ["envelope-10ms.f32", "meta.json", "transcripts"])
        }
        let meta = try #require(try await CacheStore(locations: locations).entry(contentKey: Self.key("a")))
        #expect(meta.bytes == 8_750_000 + 2_000)
        for kept in entries[2...3] {
            #expect(Self.contents(kept) == ["audio-16k.wav", "envelope-10ms.f32", "meta.json", "thumbs", "transcripts"])
        }
    }

    /// Whole entries go only once every entry not in use has lost its audio: the newest unused entry is stripped before
    /// the oldest are removed. The open project's entry is never touched, though it is the oldest and still counts.
    @Test func wholeEntriesGoOnlyAfterEveryUnusedEntryLostItsAudio() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let open = try await entry(Self.key("0"), in: locations, audio: 1_972 * Self.mb, envelope: 25 * Self.mb, used: Self.ago(hours: 200))
        var unused: [URL] = []
        for (index, character) in ["a", "b", "c"].enumerated() {
            unused.append(try await entry(Self.key(Character(character)), in: locations, audio: 160 * Self.mb, envelope: 2 * Self.mb,
                                          used: Self.ago(hours: Double(100 - index))))
        }
        let lease = CacheStore(locations: locations).keys.leaseNow(Self.key("0"))
        defer { lease.release() }
        let scheduler = scheduler(locations, limit: CacheEvictionScheduler.limitBytes(gigabytes: 2))
        scheduler.requestRun()
        await scheduler.waitUntilIdle()
        #expect(Self.contents(open) == ["audio-16k.wav", "envelope-10ms.f32", "meta.json"])
        #expect(!Self.exists(unused[0]) && !Self.exists(unused[1]))
        #expect(Self.contents(unused[2]) == Self.stripped)
    }

    /// Two windows each with a project open lease their keys, as each `EditorModel` does; even Clear everything
    /// leaves both entries alone, and a key stays in use while any window still has it open.
    @Test func openProjectsInTwoWindowsKeepTheirEntries() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let first = try await entry(Self.key("a"), in: locations, audio: 4_000, envelope: 64, used: Self.ago(hours: 72))
        let second = try await entry(Self.key("b"), in: locations, audio: 4_000, envelope: 64, used: Self.ago(hours: 71))
        let unused = try await entry(Self.key("c"), in: locations, audio: 4_000, envelope: 64, used: Self.now)
        let store = CacheStore(locations: locations), keys = store.keys
        let windowOne = keys.leaseNow(Self.key("a")), windowTwo = keys.leaseNow(Self.key("b")), sameSource = keys.leaseNow(Self.key("b"))
        #expect(keys.leasedKeys == [Self.key("a"), Self.key("b")])
        try await store.evict(limitBytes: 0, protectedKeys: [])
        #expect(Self.exists(first, "audio-16k.wav") && Self.exists(second, "audio-16k.wav") && !Self.exists(unused))
        windowOne.release(); windowTwo.release(); windowOne.release()
        #expect(keys.leasedKeys == [Self.key("b")])
        try await store.evict(limitBytes: 0, protectedKeys: [])
        #expect(!Self.exists(first) && Self.exists(second, "audio-16k.wav"))
        sameSource.release()
        #expect(keys.leasedKeys.isEmpty)
    }

    /// A transcription holds its source's key from start to end, so not even Clear everything takes its audio.
    @Test func aRunningTranscriptionKeepsItsEntry() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let key = Self.key("e")
        let directory = try await entry(key, in: locations, audio: 64_000, envelope: 800, used: Self.ago(hours: 72))
        let gate = HoldGate()
        let service = TranscriptionService(locations: locations, gate: SpeechJobGate())
        let request = TranscriptionRequest(plan: TranscriptionPlan(engine: .whispercpp, language: .forced("en")),
                                           audio: ExtractedAudio(wav16k: directory.appendingPathComponent("audio-16k.wav"), sampleCount: 32_000, durationSeconds: 2),
                                           contentKey: key)
        let job = Task { try await service.transcribeResult(request, using: HeldEngine(gate: gate), envelope: nil) }
        await gate.reached()
        let store = CacheStore(locations: locations)
        try await store.evict(limitBytes: 0, protectedKeys: [])
        #expect(Self.exists(directory, "audio-16k.wav"))
        #expect(store.keys.isLeased(key))
        await gate.open()
        _ = try? await job.value
        #expect(!store.keys.isLeased(key))
        try await store.evict(limitBytes: 0, protectedKeys: [])
        #expect(!Self.exists(directory))
    }

    /// An extraction under way holds its key, so Clear everything from another store leaves the half-written entry.
    @Test func anExtractionUnderWayKeepsItsEntry() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let key = Self.key("f"), directory = locations.cache.appendingPathComponent(key)
        let gate = HoldGate()
        let extracting = CacheStore(locations: locations)
        let job = Task { try await extracting.extractAudio(sourceURL: locations.root, contentKey: key, durationSeconds: 1, using: HeldExtractor(gate: gate)) { _ in } }
        await gate.reached()
        try await CacheStore(locations: locations).evict(limitBytes: 0, protectedKeys: [])
        #expect(Self.contents(directory) == ["audio-16k.wav"])
        await gate.open()
        _ = try await job.value
        #expect(Self.contents(directory) == ["audio-16k.wav", "envelope-10ms.f32", "meta.json"])
    }

    /// Background passes, and Clear cache, take turns: while one runs the next waits, and requests made while a pass is
    /// queued join it.
    @Test func passesNeverOverlap() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let old = try await entry(Self.key("a"), in: locations, audio: 1_500 * Self.mb, envelope: 19 * Self.mb, used: Self.ago(hours: 72))
        let recent = try await entry(Self.key("b"), in: locations, audio: 1_500 * Self.mb, envelope: 19 * Self.mb, used: Self.ago(hours: 24))
        let scheduler = scheduler(locations, limit: 2 * Self.gb)
        let keys = CacheStore(locations: locations).keys
        // Another pass holds the turn.
        await keys.beginEviction()
        scheduler.requestRun()
        await Self.until { keys.waitingEvictions == 1 }
        // The first request is waiting for the turn; the next queues behind it and the last joins that one.
        scheduler.requestRun()
        scheduler.requestRun()
        let clear = Task { await scheduler.clearCache() }
        await Self.until { keys.waitingEvictions == 2 }
        #expect(Self.exists(old, "audio-16k.wav") && Self.exists(recent, "audio-16k.wav") && scheduler.completedRuns == 0)
        keys.endEviction()
        await clear.value
        await scheduler.waitUntilIdle()
        #expect(scheduler.completedRuns == 2)
        #expect(Self.contents(old) == Self.stripped && Self.contents(recent) == Self.stripped)
        #expect(keys.waitingEvictions == 0)
    }

    /// A pass leaves an entry without readable metadata alone while anything in it was written in the last hour: it may
    /// be an extraction under way in the CLI, which holds no lease in the app. After an hour it goes like any other.
    @Test func passesSpareEntriesWithoutMetadataForAnHour() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let indexed = try await entry(Self.key("a"), in: locations, audio: 4_000, envelope: 64, used: Self.ago(hours: 72))
        let fresh = try unindexed(Self.key("b"), in: locations, files: ["audio-16k.wav": 4_000], written: Self.ago(hours: 0.5))
        let corrupt = try unindexed(Self.key("c"), in: locations, files: ["audio-16k.wav": 4_000, "meta.json": 3], written: Self.ago(hours: 0.9))
        let stale = try unindexed(Self.key("d"), in: locations, files: ["audio-16k.wav": 4_000, "transcripts/raw.json": 10], written: Self.ago(hours: 2))
        let scheduler = scheduler(locations, limit: 0)
        scheduler.requestRun()
        await scheduler.waitUntilIdle()
        #expect(Self.contents(fresh) == ["audio-16k.wav"])
        #expect(Self.contents(corrupt) == ["audio-16k.wav", "meta.json"])
        #expect(!Self.exists(indexed) && !Self.exists(stale))
        // Clear cache keeps the same hour.
        await scheduler.clearCache()
        #expect(Self.contents(fresh) == ["audio-16k.wav"] && Self.contents(corrupt) == ["audio-16k.wav", "meta.json"])
        try Self.touch(fresh, at: Self.ago(hours: 1.01))
        scheduler.requestRun()
        await scheduler.waitUntilIdle()
        #expect(!Self.exists(fresh) && Self.exists(corrupt, "audio-16k.wav"))
    }

    /// Stripping an entry without metadata keeps its folder's time, so it never looks freshly written to a later pass.
    @Test func strippingAnEntryWithoutMetadataKeepsItsTime() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let paid = try unindexed(Self.key("a"), in: locations, files: ["transcripts/elevenlabs-scribe_v2-auto-00000000.json": 10, "thumbs/strip-160.jpg": 500],
                                 written: Self.ago(hours: 2))
        let scheduler = scheduler(locations, limit: 2 * Self.gb)
        await scheduler.clearCache()
        #expect(Self.contents(paid) == ["transcripts"])
        let time = try #require(try FileManager.default.attributesOfItem(atPath: paid.path)[.modificationDate] as? Date)
        #expect(abs(time.timeIntervalSince(Self.ago(hours: 2))) < 1)
    }

    /// Clear cache is still the first pass with a limit of 0, now taking its turn and honouring leases: entries keep their
    /// envelopes and raw transcripts, an entry with neither goes, and open projects are untouched. Files kept at the cache
    /// root and folders that are not entries are never evicted.
    @Test func clearCacheIsStillThePassOneClear() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let cache = locations.cache
        let used = try await entry(Self.key("a"), in: locations, audio: 4_000, envelope: 64, transcript: true, thumbs: true, used: Self.ago(hours: 72))
        let open = try await entry(Self.key("b"), in: locations, audio: 4_000, envelope: 64, thumbs: true, used: Self.ago(hours: 100))
        let bare = try unindexed(Self.key("c"), in: locations, files: ["thumbs/poster-0-560x316.jpg": 500], written: Self.ago(hours: 2))
        let paid = try unindexed(Self.key("d"), in: locations, files: ["transcripts/elevenlabs-scribe_v2-auto-00000000.json": 10, "thumbs/strip-160.jpg": 500],
                                 written: Self.ago(hours: 2))
        let rootFiles = ["encoders.json", "llm-models.json", "microphone-settings-uri.txt", "training-result.json"]
        for name in rootFiles + ["audio-16k.wav"] { try Data("x".utf8).write(to: cache.appendingPathComponent(name)) }
        try Self.sparse(cache.appendingPathComponent("voice-consent/\(UUID().uuidString)/statement.wav"), 1_000)
        let lease = CacheStore(locations: locations).keys.leaseNow(Self.key("b"))
        defer { lease.release() }
        let scheduler = scheduler(locations, limit: 2 * Self.gb)
        await scheduler.clearCache()
        #expect(Self.contents(used) == ["envelope-10ms.f32", "meta.json", "transcripts"])
        #expect(Self.contents(open) == ["audio-16k.wav", "envelope-10ms.f32", "meta.json", "thumbs"])
        #expect(!Self.exists(bare))
        #expect(Self.contents(paid) == ["transcripts"])
        #expect(scheduler.completedRuns == 0)
        // A background pass at a limit of 0 removes entries, never the files and folders kept at the root.
        let everything = self.scheduler(locations, limit: 0)
        everything.requestRun()
        await everything.waitUntilIdle()
        #expect(Self.contents(cache) == (rootFiles + [Self.key("b"), "voice-consent"]).sorted())
        #expect(Self.contents(cache.appendingPathComponent("voice-consent")).count == 1)
    }

    /// Opening a project marks its entry used (`CacheStore.touch`), so least recently used means least recently opened,
    /// not least recently extracted. An entry without metadata gains none.
    @Test func aTouchedEntryIsTheMostRecentlyUsed() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let reopened = try await entry(Self.key("a"), in: locations, audio: 1_500 * Self.mb, envelope: 19 * Self.mb, used: Self.ago(hours: 72))
        let idle = try await entry(Self.key("b"), in: locations, audio: 1_500 * Self.mb, envelope: 19 * Self.mb, used: Self.ago(hours: 24))
        let posters = try unindexed(Self.key("c"), in: locations, files: ["thumbs/poster-0-560x316.jpg": 500], written: Self.ago(hours: 0.5))
        let store = CacheStore(locations: locations)
        await store.touch(contentKey: Self.key("a"))
        await store.touch(contentKey: Self.key("c"))
        #expect(Self.contents(posters) == ["thumbs"])
        let scheduler = scheduler(locations, limit: 2 * Self.gb)
        scheduler.requestRun()
        await scheduler.waitUntilIdle()
        #expect(Self.contents(reopened) == ["audio-16k.wav", "envelope-10ms.f32", "meta.json"])
        #expect(Self.contents(idle) == Self.stripped)
    }

    /// An extraction marks its entry used as it starts, so a long one into an old entry is the last the app's eviction
    /// would strip even where it holds no lease, as when the CLI extracts. `createdAt` is kept.
    @Test func anExtractionMarksItsEntryUsedAsItStarts() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let key = Self.key("f")
        let directory = try await entry(key, in: locations, audio: 4_000, envelope: 64, used: Self.ago(hours: 72))
        let gate = HoldGate()
        let store = CacheStore(locations: locations)
        let started = Date()
        let job = Task { try await store.extractAudio(sourceURL: locations.root, contentKey: key, durationSeconds: 1, using: HeldExtractor(gate: gate)) { _ in } }
        await gate.reached()
        let meta = try #require(await store.readEntry(directory))
        #expect(meta.lastAccessAt >= started.addingTimeInterval(-1) && meta.createdAt == Self.ago(hours: 72))
        await gate.open()
        _ = try await job.value
    }

    /// Clear everything runs both passes at a limit of 0: every entry not in use goes, its envelope and raw transcripts
    /// with it. An open project's entry and the files kept at the cache root stay.
    @Test func clearEverythingRemovesEveryEntryNotInUse() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let used = try await entry(Self.key("a"), in: locations, audio: 4_000, envelope: 64, transcript: true, used: Self.ago(hours: 72))
        let open = try await entry(Self.key("b"), in: locations, audio: 4_000, envelope: 64, used: Self.ago(hours: 100))
        try Data("x".utf8).write(to: locations.cache.appendingPathComponent("encoders.json"))
        let lease = CacheStore(locations: locations).keys.leaseNow(Self.key("b"))
        defer { lease.release() }
        let scheduler = scheduler(locations, limit: 2 * Self.gb)
        await scheduler.clearEverything()
        #expect(!Self.exists(used))
        #expect(Self.contents(open) == ["audio-16k.wav", "envelope-10ms.f32", "meta.json"])
        #expect(Self.contents(locations.cache) == ["encoders.json", Self.key("b")].sorted())
        #expect(scheduler.completedRuns == 0)
    }

    @Test func theSettingIsInDecimalGigabytes() {
        #expect(CacheEvictionScheduler.limitBytes(gigabytes: 2) == 2_000_000_000)
        #expect(CacheEvictionScheduler.limitBytes(gigabytes: 20) == 20_000_000_000)
        #expect(CacheEvictionScheduler.limitBytes(gigabytes: .nan) == CacheEvictionScheduler.defaultLimitBytes)
        #expect(CacheEvictionScheduler.defaultLimitBytes == 5_000_000_000)
    }
}
