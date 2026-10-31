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

/// The v2 shell's layout (ux/v2 notes.md §1, impl-plan V1a, V1b, item 18 and §3.5). Settings stay in
/// memory, except for the launch, which uses a temporary data folder and a settings store
/// that keeps its saves in memory.
@Suite("v2 shell layout")
@MainActor struct WorkspaceLayoutTests {
    @Test func theRightColumnFollowsTheV2Formula() {
        #expect(VCTokens.sizeSidebarIdeal == 224 && VCTokens.sizeRightColumnIdeal == 404)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1280) == 404)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1440) == 444)
        // Narrowed so the editor keeps 604 beside a 224 Explorer, and wider without it.
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1180) == 352)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1128) == 300)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1024) == 300)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 1024, explorer: 0) == 340)
        #expect(WorkspaceLayout.rightColumnWidth(windowWidth: 960, explorer: 0) == 324)
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
        #expect(shell.layout.rightVisible && !shell.layout.explorerVisible && shell.rightWidth == 340)
        shell.windowWidth = 1180
        #expect(shell.layout.rightVisible && shell.layout.explorerVisible && shell.rightWidth == 352)
        shell.windowWidth = 900
        #expect(!shell.layout.explorerVisible && !shell.layout.rightVisible)
        shell.toggleSidebar()
        #expect(shell.sidebarOverlay && !shell.layout.explorerVisible)
        shell.toggleViewer()
        #expect(shell.rightOverlay && !shell.layout.rightVisible)
        shell.windowWidth = 1440
        #expect(shell.layout.explorerVisible && shell.layout.rightVisible && shell.layout.timelineVisible && !shell.sidebarOverlay && !shell.rightOverlay)
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
        // The width rule hides the right column the same way, below 904.
        shell.windowWidth = 900
        #expect(!shell.layout.rightVisible && shell.layout.timelineVisible)
    }

    /// impl-plan §3.2: Explorer, tab and clip-bar rows, transcript, viewer, panel, timeline,
    /// status bar; a hidden pane is no stop, an overlay is one.
    @Test func aHiddenPaneIsNoF6Stop() {
        #expect(EditorPane.order(explorerVisible: true, viewerVisible: true, timelineVisible: true) == [.sidebar, .tabs, .transcript, .viewer, .panel, .timeline, .status])
        #expect(EditorPane.order(explorerVisible: true, viewerVisible: false, timelineVisible: true) == [.sidebar, .tabs, .transcript, .timeline, .status])
        #expect(EditorPane.order(explorerVisible: true, viewerVisible: true, timelineVisible: false) == [.sidebar, .tabs, .transcript, .viewer, .panel, .status])
        #expect(EditorPane.order(explorerVisible: false, viewerVisible: true, timelineVisible: true) == [.tabs, .transcript, .viewer, .panel, .timeline, .status])
        let shell = WorkspaceShell(app: AppModel())
        shell.windowWidth = 900
        #expect(shell.paneOrder == [.tabs, .transcript, .timeline, .status])
        shell.toggleSidebar(); shell.toggleViewer()
        #expect(shell.paneOrder == [.sidebar, .tabs, .transcript, .viewer, .panel, .timeline, .status])
    }

    /// impl-plan §3.5: below 1,128 the Explorer collapses first, below 904 the right column;
    /// each comes back as the window widens unless the user hid it.
    @Test func theExplorerCollapsesBelow1128AndTheRightColumnBelow904() {
        let shell = WorkspaceShell(app: AppModel())
        shell.windowWidth = 1128
        #expect(shell.explorerCollapseWidth == 1128 && WorkspaceShell.rightCollapseWidth == 904)
        #expect(shell.layout.explorerVisible && shell.layout.rightVisible && shell.rightWidth == 300)
        shell.windowWidth = 1127
        #expect(!shell.layout.explorerVisible && shell.layout.rightVisible)
        shell.windowWidth = 904
        #expect(shell.layout.rightVisible && shell.rightWidth == 300)
        shell.windowWidth = 903
        #expect(!shell.layout.rightVisible && !shell.rightOverlay)
        shell.toggleViewer()
        #expect(shell.rightOverlay && shell.viewerShown && shell.rightWidth == 300)
        shell.windowWidth = 1280
        #expect(shell.layout.explorerVisible && shell.layout.rightVisible && !shell.rightOverlay && shell.rightWidth == 404)
        // The user hid the Explorer: a narrow resize and back leaves it hidden.
        shell.toggleSidebar()
        shell.windowWidth = 1000; shell.windowWidth = 1280
        #expect(!shell.layout.explorerVisible)
    }

    /// A docked Explorer hides at any width. A stored Explorer width this window has no room
    /// for (320, dragged in a wider window) puts the threshold past the window's width; ⌃⌘S
    /// and Find Clips must still act on the docked pane, not open the overlay over it.
    @Test func aDockedExplorerHidesAtAnyWidthAndFindClipsLeavesIt() {
        let shell = WorkspaceShell(app: AppModel())
        shell.windowWidth = 1200
        #expect(shell.layout.explorerVisible && shell.explorerMaximumWidth == 296)
        shell.layout.rememberExplorerWidth(320)
        #expect(shell.explorerCollapseWidth > shell.windowWidth && shell.layout.explorerVisible)
        shell.revealSidebar()
        #expect(shell.layout.explorerVisible && !shell.sidebarOverlay)
        shell.toggleSidebar()
        #expect(!shell.layout.explorerVisible && !shell.sidebarOverlay && !shell.sidebarShown)
        // Shown again here it has no room beside both columns, so it opens over the editor.
        shell.toggleSidebar()
        #expect(!shell.layout.explorerVisible && shell.sidebarOverlay)
        // The Explorer's drag limit keeps 904 beside it, within its own 220–320.
        shell.windowWidth = 1440
        #expect(shell.explorerMaximumWidth == 320)
        shell.windowWidth = 1000
        #expect(shell.explorerMaximumWidth == 220)
    }

    /// An overlay the user asked for at a narrow width docks when its column fits again, even
    /// where the user had hidden the column before: showing it was the last request.
    @Test func anOverlayDocksWhenItsColumnFitsAgain() {
        let shell = WorkspaceShell(app: AppModel())
        shell.windowWidth = 1000
        shell.toggleViewer()
        #expect(!shell.layout.rightVisible)
        shell.windowWidth = 800
        shell.toggleViewer()
        #expect(shell.rightOverlay)
        shell.windowWidth = 1280
        #expect(shell.layout.rightVisible && !shell.rightOverlay && shell.viewerShown)
        // The Explorer the same way: hidden by the user at 1280, shown over the editor at 1000.
        shell.toggleSidebar()
        #expect(!shell.layout.explorerVisible)
        shell.windowWidth = 1000
        shell.toggleSidebar()
        #expect(shell.sidebarOverlay)
        shell.windowWidth = 1280
        #expect(shell.layout.explorerVisible && !shell.sidebarOverlay)
        // An overlay hidden again before the window widens leaves the hidden column hidden.
        shell.toggleSidebar()
        shell.windowWidth = 1000
        shell.toggleSidebar(); shell.toggleSidebar()
        shell.windowWidth = 1280
        #expect(!shell.layout.explorerVisible && !shell.sidebarOverlay)
    }

    /// impl-plan §3.5: the timeline starts at 216, or 40% of a short work area; a dragged
    /// height is the user's and is not clamped to it.
    @Test func theTimelineStartsAt216OrFortyPercentOfTheWorkArea() {
        let app = AppModel()
        let layout = WorkspaceLayout(app: app)
        layout.workHeight = 776
        #expect(layout.timelineHeight == 216)
        layout.workHeight = 456
        #expect(layout.timelineHeight == 182)
        layout.rememberTimelineHeight(260)
        #expect(layout.timelineHeight == 260)
    }

    /// notes.md §1 at 1280 × 800, and the same rules at the other sizes of impl-plan §3.5.
    @Test func theRegionRulesMatchTheNotesAt1280AndFollowTheNarrowRule() {
        let at1280 = Dictionary(uniqueKeysWithValues: ShellRegion.allCases.map { ($0, $0.reference) })
        #expect(at1280[.explorer] == CGRect(x: 0, y: 0, width: 224, height: 776))
        #expect(at1280[.tabBar] == CGRect(x: 224, y: 0, width: 652, height: 38))
        #expect(at1280[.transcript] == CGRect(x: 224, y: 72, width: 652, height: 488))
        #expect(at1280[.rightBody] == CGRect(x: 876, y: 38, width: 404, height: 522))
        #expect(at1280[.timeline] == CGRect(x: 224, y: 560, width: 1056, height: 216))
        #expect(at1280[.statusBar] == CGRect(x: 0, y: 776, width: 1280, height: 24))
        #expect(ShellRegion.rightTitle.reference(in: CGSize(width: 1440, height: 900)) == CGRect(x: 996, y: 0, width: 444, height: 38))
        #expect(ShellRegion.tabBar.reference(in: CGSize(width: 1128, height: 800)) == CGRect(x: 224, y: 0, width: 604, height: 38))
        #expect(ShellRegion.explorer.reference(in: CGSize(width: 960, height: 600)) == nil)
        #expect(ShellRegion.rightBody.reference(in: CGSize(width: 960, height: 600)) == CGRect(x: 636, y: 38, width: 324, height: 322))
        #expect(ShellRegion.rightTitle.reference(in: CGSize(width: 800, height: 600)) == nil)
        #expect(ShellRegion.transcript.reference(in: CGSize(width: 800, height: 600)) == CGRect(x: 0, y: 72, width: 800, height: 288))
        #expect(ShellRegion.timeline.reference(in: CGSize(width: 800, height: 600)) == CGRect(x: 0, y: 360, width: 800, height: 216))
    }
}
