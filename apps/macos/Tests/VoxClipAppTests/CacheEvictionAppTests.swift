#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// A sleep that returns only when the test wakes it, recording what it was asked for.
private actor LaunchSleep {
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

/// Settings for a launch in a temporary data folder: no update check, and exports in that folder.
private actor TemporarySettingsStore: SettingsStore {
    let values: [String: JSONValue]
    init(exports: URL) { values = ["update.autoCheck": .bool(false), "export.folder": .string(exports.path)] }
    func load() async throws -> SettingsDocument { SettingsDocument(values: values) }
    func save(_ settings: SettingsDocument) async throws {}
    func flush() async throws {}
}

/// The app's side of the cache size limit (architecture §8.2): the launch pass, a pass after each import and when the
/// setting is lowered, and every window's open project leasing its key. Each test has its own data folder; caches are
/// sparse files, so they take no disk space.
@Suite("Headless cache size limit", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are opened."))
@MainActor struct CacheEvictionAppTests {
    static let mb: Int64 = 1_000_000
    static func key(_ character: Character) -> String { String(repeating: character, count: 64) }
    static let full = ["audio-16k.wav", "envelope-10ms.f32", "meta.json"]
    static let stripped = ["envelope-10ms.f32", "meta.json"]

    private func model() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-cache-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        let app = AppModel(settingsStore: TemporarySettingsStore(exports: root.appendingPathComponent("Exports")),
                           locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.voiceRecoveryForTests = {}
        return app
    }

    /// A scheduler for the app's data folder with a fixed limit and, when given, a sleep the test controls.
    private func scheduler(_ app: AppModel, limit: Int64, sleep: LaunchSleep? = nil) -> CacheEvictionScheduler {
        let store = CacheStore(locations: app.locations)
        guard let sleep else { return CacheEvictionScheduler(store: store, log: app.log, limitBytes: { limit }) }
        return CacheEvictionScheduler(store: store, log: app.log, limitBytes: { limit }, sleep: { await sleep.sleep($0) })
    }

    /// An editor for a project of the passage fixture with this id and content key, as one window holds it.
    private func editor(_ app: AppModel, id: String, key: String) throws -> EditorModel {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.id = id
        project.media.source.contentKey = key
        return EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
    }

    /// An entry as extraction leaves it, with sparse audio and envelope, last used `hours` ago.
    private func entry(_ key: String, in app: AppModel, audio: Int64, hoursAgo hours: Double) async throws -> URL {
        let directory = app.locations.cache.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = audio / 80
        for (name, bytes) in [("audio-16k.wav", audio), ("envelope-10ms.f32", envelope)] {
            let url = directory.appendingPathComponent(name)
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        }
        let used = Date().addingTimeInterval(-hours * 3_600)
        var meta = CacheEntry(contentKey: key, createdAt: used, lastAccessAt: used, bytes: audio + envelope)
        meta.envelope = CacheEnvelope(sampleRate: 48_000, count: Int(envelope / 4))
        try await CacheStore(locations: app.locations).record(meta)
        return directory
    }

    private func contents(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    /// Launch (`AppModel.start` → `CacheEvictionScheduler.scheduleAfterLaunch`) schedules a pass 30 s later; nothing is
    /// evicted before then.
    @Test func theLaunchRunsAPassThirtySecondsLater() async throws {
        let app = try model()
        defer { try? FileManager.default.removeItem(at: app.locations.root) }
        let old = try await entry(Self.key("a"), in: app, audio: 1_500 * Self.mb, hoursAgo: 72)
        let recent = try await entry(Self.key("b"), in: app, audio: 1_500 * Self.mb, hoursAgo: 24)
        let sleep = LaunchSleep()
        app.cacheEviction = scheduler(app, limit: 2_000_000_000, sleep: sleep)
        await app.start()
        try #require(app.cacheEviction.launchScheduled)
        await sleep.asleep()
        #expect(await sleep.requests == [.seconds(30)])
        #expect(contents(old) == Self.full && app.cacheEviction.completedRuns == 0)
        await sleep.wake()
        await app.cacheEviction.scheduleAfterLaunch().value
        await app.cacheEviction.waitUntilIdle()
        #expect(app.cacheEviction.completedRuns == 1)
        #expect(contents(old) == Self.stripped && contents(recent) == Self.full)
    }

    /// After an import, once the new project is open, `WorkspaceShell.importVideo` asks for a pass
    /// (`AppModel.requestCacheEviction`). It runs at once and leaves the imported video's entry alone.
    @Test func anImportRunsAPassThatSparesTheNewProject() async throws {
        let app = try model()
        defer { try? FileManager.default.removeItem(at: app.locations.root) }
        let imported = try await entry(Self.key("c"), in: app, audio: 1_500 * Self.mb, hoursAgo: 100)
        let old = try await entry(Self.key("a"), in: app, audio: 1_500 * Self.mb, hoursAgo: 72)
        let recent = try await entry(Self.key("b"), in: app, audio: 1_500 * Self.mb, hoursAgo: 24)
        app.cacheEviction = scheduler(app, limit: 0)
        let editor = try editor(app, id: "imported", key: Self.key("c"))
        defer { editor.close() }
        await editor.start()
        app.requestCacheEviction()
        await app.cacheEviction.waitUntilIdle()
        #expect(app.cacheEviction.completedRuns == 1)
        #expect(contents(imported) == Self.full)
        #expect(!FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: recent.path))
        await app.cacheTouches?.value
    }

    /// Lowering "Cache size limit" runs a background pass at once (`AppModel.set` → `requestCacheEviction`); raising it
    /// does not.
    @Test func loweringTheLimitEvictsAtOnce() async throws {
        let app = try model()
        defer { try? FileManager.default.removeItem(at: app.locations.root) }
        let old = try await entry(Self.key("a"), in: app, audio: 1_500 * Self.mb, hoursAgo: 72)
        let recent = try await entry(Self.key("b"), in: app, audio: 1_500 * Self.mb, hoursAgo: 24)
        #expect(app.set("cache.limitGB", .number(10)))
        await app.cacheEviction.waitUntilIdle()
        #expect(app.cacheEviction.completedRuns == 0)
        #expect(app.set("cache.limitGB", .number(2)))
        #expect(app.cacheLimitBytes == 2_000_000_000)
        await app.cacheEviction.waitUntilIdle()
        #expect(app.cacheEviction.completedRuns == 1)
        #expect(contents(old) == Self.stripped)
        #expect(contents(recent) == Self.full)
        #expect(app.set("cache.limitGB", .number(5)))
        await app.cacheEviction.waitUntilIdle()
        #expect(app.cacheEviction.completedRuns == 1)
    }

    /// Each window's editor leases its project's key as it starts (`EditorModel.holdCacheEntry`). Clear cache and
    /// background passes leave those entries alone, a key stays leased while any window still has its video open, a
    /// relink and its undo move the lease, and closing releases it.
    @Test func openProjectsInEveryWindowKeepTheirEntries() async throws {
        let app = try model()
        defer { try? FileManager.default.removeItem(at: app.locations.root) }
        let one = try await entry(Self.key("a"), in: app, audio: 4_000, hoursAgo: 72)
        let two = try await entry(Self.key("b"), in: app, audio: 4_000, hoursAgo: 71)
        let closed = try await entry(Self.key("c"), in: app, audio: 4_000, hoursAgo: 1)
        let first = try editor(app, id: "project-1", key: Self.key("a")), second = try editor(app, id: "project-2", key: Self.key("b"))
        // The same video open as another project in a third window.
        let third = try editor(app, id: "project-3", key: Self.key("b"))
        await first.start(); await second.start(); await third.start()
        // Marking each entry used leases it for a moment; those marks end before the leases are checked.
        await app.cacheTouches?.value
        #expect(app.cacheKeys.leasedKeys == [Self.key("a"), Self.key("b")])
        await app.cacheEviction.clearCache()
        #expect(contents(one) == Self.full && contents(two) == Self.full)
        #expect(contents(closed) == Self.stripped)
        first.close(); second.close()
        #expect(app.cacheKeys.leasedKeys == [Self.key("b")])
        // Relinking the third project to another video moves its lease (`replace` with "Locate media").
        let original = third.project
        var relinked = original
        relinked.media.source.contentKey = Self.key("c")
        third.replace(relinked, name: "Locate media")
        await app.cacheTouches?.value
        #expect(app.cacheKeys.leasedKeys == [Self.key("c")] && third.cacheLeaseKey == Self.key("c"))
        app.cacheEviction = scheduler(app, limit: 0)
        app.requestCacheEviction()
        await app.cacheEviction.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: one.path) && !FileManager.default.fileExists(atPath: two.path))
        #expect(contents(closed) == Self.stripped)
        // Undoing the relink moves it back.
        third.replace(original, name: "Locate media", restoringSnapshot: true)
        await app.cacheTouches?.value
        #expect(app.cacheKeys.leasedKeys == [Self.key("b")] && third.cacheLeaseKey == Self.key("b"))
        third.close()
        #expect(app.cacheKeys.leasedKeys.isEmpty)
    }

    /// Editors lease per window, not per project id. A Versions-browser window shows the project's id too, perhaps with
    /// the video it had before a relink; closing it leaves the main window's lease alone (architecture §8.2).
    @Test func editorsOfTheSameProjectHoldTheirOwnLeases() async throws {
        let app = try model()
        defer { try? FileManager.default.removeItem(at: app.locations.root) }
        let current = try await entry(Self.key("a"), in: app, audio: 4_000, hoursAgo: 72)
        let older = try await entry(Self.key("b"), in: app, audio: 4_000, hoursAgo: 71)
        let main = try editor(app, id: "project", key: Self.key("a"))
        let beforeRelink = try editor(app, id: "project", key: Self.key("b")), sameVideo = try editor(app, id: "project", key: Self.key("a"))
        await main.start(); await beforeRelink.start(); await sameVideo.start()
        await app.cacheTouches?.value
        #expect(app.cacheKeys.leasedKeys == [Self.key("a"), Self.key("b")])
        beforeRelink.close(); sameVideo.close()
        #expect(app.cacheKeys.leasedKeys == [Self.key("a")] && main.cacheLeaseKey == Self.key("a"))
        await app.cacheEviction.clearEverything()
        #expect(contents(current) == Self.full)
        #expect(!FileManager.default.fileExists(atPath: older.path))
        main.close()
        #expect(app.cacheKeys.leasedKeys.isEmpty && main.cacheLeaseKey == nil)
    }

    /// A reload of the document (a revert, or the .voxclip file changing on disk) moves the lease to the reloaded
    /// project at once. It holds even while the video is missing, when the envelope is all the audiogram has.
    @Test func aReloadMovesTheLeaseEvenWhenTheVideoIsMissing() async throws {
        let app = try model()
        defer { try? FileManager.default.removeItem(at: app.locations.root) }
        let opened = try await entry(Self.key("a"), in: app, audio: 4_000, hoursAgo: 72)
        let reverted = try await entry(Self.key("b"), in: app, audio: 4_000, hoursAgo: 71)
        // The fixture's video is not on this machine.
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.id = "missing-video"
        project.media.source.contentKey = Self.key("a")
        let document = VoxClipDocument(project: project)
        let editor = EditorModel(document: document, app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        await editor.start()
        await app.cacheTouches?.value
        #expect(!editor.mediaResolved && editor.cacheLeaseKey == Self.key("a"))
        var reloaded = project
        reloaded.media.source.contentKey = Self.key("b")
        document.replaceProject(reloaded)
        editor.reloadFromDocument(previousProjectID: project.id)
        #expect(app.cacheKeys.leasedKeys == [Self.key("b")])
        await editor.waitForPendingPreviewForAudit()
        #expect(!editor.mediaResolved && editor.cacheLeaseKey == Self.key("b"))
        await app.cacheTouches?.value
        await app.cacheEviction.clearEverything()
        #expect(contents(reverted) == Self.full)
        #expect(!FileManager.default.fileExists(atPath: opened.path))
    }

    /// Opening a project marks its entry used, so a video opened today outlives one extracted later but not opened since.
    @Test func openingAProjectMarksItsEntryUsed() async throws {
        let app = try model()
        defer { try? FileManager.default.removeItem(at: app.locations.root) }
        let reopened = try await entry(Self.key("a"), in: app, audio: 1_500 * Self.mb, hoursAgo: 72)
        let idle = try await entry(Self.key("b"), in: app, audio: 1_500 * Self.mb, hoursAgo: 24)
        let editor = try editor(app, id: "project-1", key: Self.key("a"))
        await editor.start()
        editor.close()
        await app.cacheTouches?.value
        app.cacheEviction = scheduler(app, limit: 2_000_000_000)
        app.requestCacheEviction()
        await app.cacheEviction.waitUntilIdle()
        #expect(contents(reopened) == Self.full)
        #expect(contents(idle) == Self.stripped)
    }
}
#endif
