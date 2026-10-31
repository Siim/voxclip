import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

#if DEBUG
/// Settings for a launch in a temporary data folder: the stored values, and every save.
private actor LaunchSettings: SettingsStore {
    let values: [String: JSONValue]
    private(set) var saved: [SettingsDocument] = []
    init(values: [String: JSONValue]) { self.values = values }
    func load() async throws -> SettingsDocument { SettingsDocument(values: values) }
    func save(_ settings: SettingsDocument) async throws { saved.append(settings) }
    func flush() async throws {}
}
#endif

/// The v2 shell's layout (ux/v2 notes.md §1, impl-plan V1a and item 18). Settings stay in
/// memory, except for the launch, which uses a temporary data folder and a settings store
/// that keeps its saves in memory.
@Suite("v2 shell layout")
@MainActor struct WorkspaceLayoutTests {
    @Test func theRightColumnFollowsTheV2Formula() {
        #expect(VCTokens.sizeSidebarIdeal == 224 && VCTokens.sizeRightColumnIdeal == 404)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1280) == 404)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1440) == 444)
        // Narrowed so the transcript keeps 596 beside a 224 Explorer.
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1180) == 360)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1024) == 300)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 2400) == 560)
    }

    @Test func aFreshWindowHasTheNotesSizes() {
        let shell = WorkspaceShell(app: AppModel())
        shell.windowWidth = 1280
        #expect(shell.layout.explorerWidth == 224 && shell.rightWidth == 404 && shell.layout.timelineHeight == 216)
        #expect(shell.layout.explorerVisible && shell.layout.rightVisible && shell.layout.timelineVisible)
    }

    @Test func theOldRightColumnWidthIsIgnored() {
        let app = AppModel()
        app.settings.values[WorkspaceLayout.retiredRightWidthKey] = .number(500)
        let shell = WorkspaceShell(app: app)
        shell.windowWidth = 1280
        #expect(shell.rightWidth == 404)
    }

    #if DEBUG
    /// Launch (`AppModel.start`) drops the pre-v2 width from the loaded settings, keeps the
    /// rest, and the settings are saved without it.
    @Test func launchRetiresTheOldRightColumnWidth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-shell-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LaunchSettings(values: [
            "update.autoCheck": .bool(false), "export.folder": .string(root.appendingPathComponent("Exports").path),
            WorkspaceLayout.retiredRightWidthKey: .number(500), WorkspaceLayout.rightWidthKey: .number(420)
        ])
        let app = AppModel(settingsStore: store, locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.voiceRecoveryForTests = {}
        app.cacheEviction = CacheEvictionScheduler(store: CacheStore(locations: app.locations), log: app.log, limitBytes: { .max }, sleep: { _ in throw CancellationError() })
        await app.start()
        #expect(app.settingsLoaded)
        #expect(app.settings.values[WorkspaceLayout.retiredRightWidthKey] == nil)
        #expect(app.settings.values[WorkspaceLayout.rightWidthKey] == .number(420))
        await app.flushSettings()
        let saved = try #require(await store.saved.last)
        #expect(saved.values[WorkspaceLayout.retiredRightWidthKey] == nil)
        #expect(saved.values[WorkspaceLayout.rightWidthKey] == .number(420))
    }
    #endif

    @Test func draggedSizesAreKeptForEveryWindowAndClamped() {
        let app = AppModel()
        let layout = WorkspaceLayout(app: app)
        layout.rememberRightWidth(420.4)
        layout.rememberExplorerWidth(400)
        layout.rememberTimelineHeight(10)
        #expect(app.settings.values[WorkspaceLayout.rightWidthKey] == .number(420))
        #expect(layout.rightWidth == 420 && layout.explorerWidth == 320 && layout.timelineHeight == 72)
        #expect(WorkspaceLayout(app: app).rightWidth == 420)
    }

    @Test func togglesAndTheWidthRuleStoreNoSize() {
        let app = AppModel()
        let shell = WorkspaceShell(app: app)
        shell.windowWidth = 1440
        shell.toggleViewer(); shell.toggleViewer()
        shell.toggleSidebar(); shell.toggleSidebar()
        shell.toggleTimeline(); shell.toggleTimeline()
        shell.windowWidth = 1024
        #expect(!shell.layout.rightVisible && shell.layout.explorerVisible)
        shell.windowWidth = 1180
        #expect(shell.layout.rightVisible && shell.rightWidth == 360)
        shell.windowWidth = 900
        #expect(!shell.layout.explorerVisible)
        shell.toggleSidebar()
        #expect(shell.sidebarOverlay && !shell.layout.explorerVisible)
        shell.windowWidth = 1440
        #expect(shell.layout.explorerVisible && shell.layout.rightVisible && shell.layout.timelineVisible && !shell.sidebarOverlay)
        for key in [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey] {
            #expect(app.settings.values[key] == nil)
        }
    }

    /// Until V4's hover transport the timeline panel carries play and the timecode while the
    /// right column is hidden (notes.md §1), so it shows then.
    @Test func theTimelineShowsWhileTheRightColumnIsHidden() {
        let shell = WorkspaceShell(app: AppModel())
        shell.windowWidth = 1280
        shell.toggleTimeline()
        #expect(!shell.layout.timelineVisible)
        shell.toggleViewer()
        #expect(!shell.layout.rightVisible && shell.layout.timelineVisible)
        shell.toggleTimeline()
        #expect(shell.layout.timelineVisible)
        shell.toggleViewer()
        shell.toggleTimeline()
        #expect(shell.layout.rightVisible && !shell.layout.timelineVisible)
        // The width rule hides the right column the same way.
        shell.windowWidth = 1024
        #expect(!shell.layout.rightVisible && shell.layout.timelineVisible)
    }

    @Test func aHiddenPaneIsNoF6Stop() {
        #expect(EditorPane.order(viewerVisible: true, timelineVisible: true) == [.sidebar, .transcript, .viewer, .panel, .timeline])
        #expect(EditorPane.order(viewerVisible: false, timelineVisible: true) == [.sidebar, .transcript, .timeline])
        #expect(EditorPane.order(viewerVisible: true, timelineVisible: false) == [.sidebar, .transcript, .viewer, .panel])
    }
}
