#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The editor's tabs (impl-plan V3a): the tab model, the scope as a tab with no undo step
/// and no document change, Undo that keeps the tab, the Rewrite session that belongs to
/// its tab, ⌘W's rule, a Versions window and the tab bar's VoiceOver roles. Nothing is
/// shown and settings are never loaded, so nothing is written.
@Suite("Editor tabs", .serialized)
@MainActor struct EditorTabsTests {
    /// The "Five questions" fixture: four kept clips (five-1…five-4) and one suggestion (five-5).
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        return try DebugSidebar.fiveQuestions(from: base)
    }
    /// A shell with the fixture open on Full Take, its media treated as found, and one undo
    /// group per action, so "no undo step" means none.
    private func openShell() async throws -> (WorkspaceShell, EditorModel, UndoManager) {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel())
        await shell.attachForTesting(VoxClipDocument(project: try project(), demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (shell, editor, undo)
    }
    private func step(_ undo: UndoManager, _ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    // MARK: The model

    @Test func clipTabsOpenBeforeFullTakeAndOnePreviewAfterIt() {
        let tabs = EditorTabs()
        #expect(tabs.open == [.fullTake] && tabs.active == .fullTake)
        tabs.sync(kept: ["a", "b"], suggested: ["s", "t"], active: "a")
        tabs.sync(kept: ["a", "b"], suggested: ["s", "t"], active: "b")
        #expect(tabs.open == [.clip("a"), .clip("b"), .fullTake] && tabs.active == .clip("b"))
        tabs.sync(kept: ["a", "b"], suggested: ["s", "t"], active: "s")
        #expect(tabs.open == [.clip("a"), .clip("b"), .fullTake, .suggestion("s")] && tabs.preview == .suggestion("s"))
        // The next preview replaces it.
        tabs.sync(kept: ["a", "b"], suggested: ["s", "t"], active: "t")
        #expect(tabs.open == [.clip("a"), .clip("b"), .fullTake, .suggestion("t")] && tabs.active == .suggestion("t"))
        // A double-click keeps it open beside the clip tabs, and the next preview opens after Full Take.
        tabs.keepOpen(.suggestion("t"))
        tabs.sync(kept: ["a", "b"], suggested: ["s", "t"], active: "s")
        #expect(tabs.open == [.clip("a"), .clip("b"), .suggestion("t"), .fullTake, .suggestion("s")])
        tabs.sync(kept: ["a", "b"], suggested: ["s", "t"], active: nil)
        #expect(tabs.active == .fullTake && tabs.open.count == 5)
    }

    @Test func tabsFollowKeepDismissAndUndo() {
        let tabs = EditorTabs()
        tabs.sync(kept: ["a"], suggested: ["s"], active: "a")
        tabs.sync(kept: ["a"], suggested: ["s"], active: "s")
        tabs.dirty = [.suggestion("s")]
        // Keep: the preview becomes a clip tab before Full Take, and stays marked.
        tabs.sync(kept: ["a", "s"], suggested: [], active: "s")
        #expect(tabs.open == [.clip("a"), .clip("s"), .fullTake] && tabs.preview == nil && tabs.active == .clip("s") && tabs.dirty == [.clip("s")])
        // Undo of Keep: a suggestion again, in place.
        tabs.sync(kept: ["a"], suggested: ["s"], active: "s")
        #expect(tabs.open == [.clip("a"), .suggestion("s"), .fullTake] && tabs.active == .suggestion("s"))
        // Its clip goes: the tab closes, and a scope whose clip is gone is Full Take.
        tabs.sync(kept: ["a"], suggested: [], active: "s")
        #expect(tabs.open == [.clip("a"), .fullTake] && tabs.active == .fullTake && tabs.dirty.isEmpty)
        tabs.reset()
        #expect(tabs.open == [.fullTake] && tabs.active == .fullTake)
    }

    @Test func neighboursAndWrapping() {
        let tabs = EditorTabs()
        tabs.sync(kept: ["a", "b"], suggested: ["s"], active: "a")
        tabs.sync(kept: ["a", "b"], suggested: ["s"], active: "b")
        tabs.sync(kept: ["a", "b"], suggested: ["s"], active: "s")
        // [a, b, Full Take, s], s active.
        #expect(tabs.neighbour(of: .suggestion("s")) == .fullTake && tabs.neighbour(of: .clip("a")) == .clip("b"))
        #expect(tabs.adjacent(1) == .clip("a") && tabs.adjacent(-1) == .fullTake)
        tabs.remove(.fullTake)
        #expect(tabs.open.contains(.fullTake))
        tabs.remove(.clip("a"))
        #expect(tabs.open == [.clip("b"), .fullTake, .suggestion("s")])
    }

    /// impl-plan §3.5: natural widths when they fit; else shrinking together to 96; then
    /// at most 96 each, wider than the row.
    @Test func tabWidthsShrinkTo96ThenOverflow() {
        let naturals: [CGFloat] = [100, 102, 120, 170]
        #expect(EditorTabBarView.widths(naturals, available: 600) == naturals)
        let shrunk = EditorTabBarView.widths(naturals, available: 420)
        #expect(shrunk.allSatisfy { $0 >= 96 } && shrunk.reduce(0, +) <= 420 && shrunk[0] == 100 && shrunk[3] < 170)
        let overflow = EditorTabBarView.widths(naturals, available: 300)
        #expect(overflow == [96, 96, 96, 96])
    }

    // MARK: The scope as a tab

    /// Item 16: a tab switch writes activeClipId in memory, with no undo step and no change
    /// count, so the document is neither edited nor waiting to autosave.
    @Test func aTabSwitchIsNoUndoStepAndLeavesTheDocumentClean() async throws {
        let (shell, editor, undo) = try await openShell()
        defer { editor.close() }
        let document = editor.document, steps = editor.undoSteps
        shell.selection = .clip("five-1")
        shell.selection = .clip("five-2")
        shell.selectTab(.clip("five-1"))
        shell.selectTab(.fullTake)
        #expect(shell.tabs.open == [.clip("five-1"), .clip("five-2"), .fullTake] && editor.project.edits.activeClipId == nil)
        #expect(editor.undoSteps == steps && !undo.canUndo && !document.isDocumentEdited && !document.hasUnautosavedChanges)
        shell.selectTab(.clip("five-2"))
        #expect(editor.project.edits.activeClipId == "five-2" && shell.selection == .clip("five-2") && editor.undoSteps == steps)
        // VoiceOver hears the new scope's name, as the tab reads it.
        #expect(editor.lastAnnouncement == "Clip 2")
        // An apply that only sets the scope is a tab switch too.
        editor.apply(.setActiveClip(clipId: "five-1"), name: "Preview clip")
        #expect(editor.project.edits.activeClipId == "five-1" && shell.tabs.active == .clip("five-1") && editor.undoSteps == steps && !undo.canUndo && !document.hasUnautosavedChanges)
        #expect(editor.lastAnnouncement == "Clip 1")
    }

    @Test func undoAndRedoKeepTheTab() async throws {
        let (shell, editor, undo) = try await openShell()
        defer { editor.close() }
        let cut = try #require(editor.words.first { $0.text == "nobody" }).id
        step(undo) { editor.apply(.cutSelection(ids: [cut]), name: "Cut selection") }
        shell.selection = .clip("five-2")
        undo.undo()
        #expect(!editor.cutWordIDs.contains(cut) && shell.tabs.active == .clip("five-2") && editor.project.edits.activeClipId == "five-2")
        undo.redo()
        #expect(editor.cutWordIDs.contains(cut) && shell.tabs.active == .clip("five-2"))
    }

    /// The open clip removed by Undo falls back to Full Take, and so does the last row's
    /// Dismiss; Remove of an open clip hands the scope to the next row (design §3.4).
    @Test func removingTheOpenClipFallsBackToFullTake() async throws {
        let (shell, editor, undo) = try await openShell()
        defer { editor.close() }
        let words = editor.words
        let start = try #require(words.firstIndex { $0.text == "film" })
        editor.select(words[start].id)
        editor.select(words[start + 2].id, extend: true)
        let steps = editor.undoSteps
        step(undo) { editor.makeClip() }
        let made = try #require(editor.project.edits.activeClipId)
        #expect(shell.tabs.active == .clip(made) && editor.undoSteps == steps + 1)
        undo.undo()
        #expect(shell.tabs.active == .fullTake && editor.project.edits.activeClipId == nil && !shell.tabs.open.contains(.clip(made)))
        shell.selection = .clip("five-5")
        step(undo) { editor.dismiss("five-5") }
        #expect(shell.tabs.active == .fullTake && !shell.tabs.open.contains(.suggestion("five-5")))
        undo.undo()
        shell.selection = .clip("five-2")
        step(undo) { editor.removeClip("five-2") }
        #expect(shell.tabs.active == .clip("five-3") && !shell.tabs.open.contains(.clip("five-2")))
    }

    /// §3.3: a Rewrite session belongs to its tab. It survives a tab switch and an edit
    /// outside its clip and stays current, hidden on other tabs (`rewrite` and
    /// `rewriteScope` are nil there), shows again on its tab, and an edit inside its clip
    /// or its words shows R3 with its tab still dirty; undoing that edit shows the proposal (V13).
    @Test func aRewriteSessionSurvivesATabSwitch() async throws {
        let (shell, editor, undo) = try await openShell()
        defer { editor.close() }
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        shell.selection = .clip("five-1")
        let clips = editor.project.edits.clips
        let lower = try #require(clips.first { $0.id == "five-1" }.flatMap { editor.index($0.startWordId) })
        let other = try #require(clips.first { $0.id == "five-2" }.flatMap { editor.index($0.startWordId) })
        let session = RewriteSession(editor: editor, scope: .selection(lower...(lower + 2)), envelope: nil, connector: nil)
        editor.rewrite = session
        #expect(editor.rewrite === session && session.current && shell.dirtyTabs.isEmpty)
        try session.receivePassage("A different opening")
        session.finishRun(seconds: 1)
        let proposal = session.task.state
        #expect(shell.dirtyTabs == [.clip("five-1")])
        shell.selection = .clip("five-2")
        #expect(session.isOpen && editor.openRewrite === session && editor.rewrite == nil && editor.rewriteScope == nil)
        #expect(session.current && shell.dirtyTabs == [.clip("five-1")])
        step(undo) { editor.apply(.cutSelection(ids: [editor.words[other].id]), name: "Cut selection") }
        #expect(session.isOpen && editor.openRewrite === session)
        shell.selectTab(.clip("five-1"))
        #expect(editor.rewrite === session && editor.rewriteScope == .selection(lower...(lower + 2)) && session.project == editor.project && session.current)
        step(undo) { editor.apply(.cutSelection(ids: [editor.words[lower + 1].id]), name: "Cut selection") }
        #expect(session.isOpen && session.task.state == .changed && !session.current && shell.dirtyTabs == [.clip("five-1")])
        undo.undo()
        #expect(session.isOpen && session.task.state == proposal && session.current)
    }

    /// The session's own words count as inside it even past its clip's edge.
    @Test func anEditToTheSessionsWordsOutsideItsClipShowsR3() async throws {
        let (shell, editor, undo) = try await openShell()
        defer { editor.close() }
        shell.selection = .clip("five-1")
        let clip = try #require(editor.project.edits.clips.first { $0.id == "five-1" })
        let upper = try #require(editor.index(clip.endWordId))
        try #require(upper + 2 < editor.words.count)
        let session = RewriteSession(editor: editor, scope: .selection((upper - 1)...(upper + 2)), envelope: nil, connector: nil)
        editor.rewrite = session
        try session.receivePassage("A different ending")
        session.finishRun(seconds: 1)
        step(undo) { editor.apply(.cutSelection(ids: [editor.words[upper + 2].id]), name: "Cut selection") }
        #expect(session.isOpen && editor.openRewrite === session && session.task.state == .changed)
    }

    /// A Rewrite session closes with its tab, as Escape closes it: the active tab's × and
    /// an inactive tab's middle click (both `closeTab`), and a preview tab that the next
    /// preview replaces. Opening its clip again shows no session.
    @Test func closingASessionsTabClosesTheSession() async throws {
        let (shell, editor, undo) = try await openShell()
        defer { editor.close() }
        func open(on id: String) throws -> RewriteSession {
            shell.selection = .clip(id)
            let start = try #require(editor.project.edits.clips.first { $0.id == id }.flatMap { editor.index($0.startWordId) })
            let session = RewriteSession(editor: editor, scope: .selection(start...(start + 2)), envelope: nil, connector: nil)
            editor.rewrite = session
            try session.receivePassage("A different opening")
            session.finishRun(seconds: 1)
            return session
        }
        let active = try open(on: "five-1")
        #expect(shell.dirtyTabs == [.clip("five-1")])
        shell.closeTab(.clip("five-1"))
        #expect(!active.isOpen && editor.openRewrite == nil && shell.dirtyTabs.isEmpty)
        shell.selection = .clip("five-1")
        #expect(editor.rewrite == nil && editor.rewriteScope == nil)

        let inactive = try open(on: "five-1")
        shell.selection = .clip("five-2")
        #expect(inactive.isOpen && editor.openRewrite === inactive)
        shell.closeTab(.clip("five-1"))
        #expect(!inactive.isOpen && editor.openRewrite == nil && shell.tabs.active == .clip("five-2"))

        // A second suggestion, as DebugTabs adds it, so one preview can replace another.
        var project = editor.project
        var extra = try #require(project.edits.clips.first { $0.id == "five-5" })
        extra.id = "tabs-suggestion"
        extra.startWordId = project.edits.clips[0].startWordId
        extra.endWordId = project.edits.clips[0].endWordId
        project.edits.clips.append(extra)
        step(undo) { editor.replace(project, name: "Add suggestion fixture") }
        let preview = try open(on: "five-5")
        #expect(shell.tabs.preview == .suggestion("five-5") && preview.isOpen)
        shell.selection = .clip("tabs-suggestion")
        #expect(shell.tabs.preview == .suggestion("tabs-suggestion") && !preview.isOpen && editor.openRewrite == nil)
    }

    /// The consent before words go to a connector follows the session, not the tab or the
    /// project as it was when the session opened. After an edit in another clip, on another
    /// tab, it still asks and the words go. A connector change, or an edit inside the
    /// session's clip, while it asks refuses: nothing is sent and no consent is kept, and
    /// the edit shows R3 (V13). An API-key send also confirms its cost on every send, after
    /// the privacy consent (VS). ⇧⌘R runs at once; a declined sheet leaves the session open.
    @Test func rewriteConsentFollowsTheSessionAcrossTabs() async throws {
        let (shell, editor, undo) = try await openShell()
        defer { editor.close() }
        let app = editor.app
        let fake = ConsentFixtureConnector(id: .anthropic)
        app.connectorOverride = { _ in fake }
        defer { app.connectorOverride = nil; app.connectorConsentOverride = nil }
        for (key, value) in [("voiceLab.enabled", JSONValue.bool(true)), ("voiceLab.betaNoticeAccepted", .bool(true)),
                             ("llm.connector", .string("anthropic")), ("llm.model.anthropic", .string("fixture-local"))] {
            app.settings.values[key] = value
        }
        let consent = "llm.cloudConsent.anthropic"
        shell.selection = .clip("five-1")
        let clips = editor.project.edits.clips
        let lower = try #require(clips.first { $0.id == "five-1" }.flatMap { editor.index($0.startWordId) })
        let other = try #require(clips.first { $0.id == "five-2" }.flatMap { editor.index($0.startWordId) })
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 100_000))
        editor.selectedWordIDs = Set(editor.words[lower...(lower + 2)].map(\.id))
        let asks = ConsentAsks()
        // The run ⇧⌘R starts at once is declined, so the session waits with nothing sent.
        app.connectorConsentOverride = { _, _, _ in asks.count += 1; return false }
        editor.runRewrite()
        await editor.rewriteOpenTask?.value
        let session = try #require(editor.openRewrite)
        await session.actionTask?.value
        #expect(session.connector != nil && session.rewriteScope == .selection(lower...(lower + 2)) && session.scope == .clip("five-1"))
        #expect(asks.count == 1 && session.task.state == .ready && !app.bool(consent))
        #expect(await fake.sends == 0)

        shell.selection = .clip("five-2")
        step(undo) { editor.apply(.cutSelection(ids: [editor.words[other].id]), name: "Cut selection") }
        #expect(session.isOpen && editor.rewrite == nil && session.current)
        app.connectorConsentOverride = { _, action, _ in asks.count += 1; return action == .rewrite }
        #expect(await session.run())
        #expect(asks.count == 3 && app.bool(consent) && !session.changes.isEmpty)
        #expect(await fake.sends == 1)

        app.settings.values[consent] = .bool(false)
        app.connectorConsentOverride = { _, _, _ in
            asks.count += 1
            app.settings.values["llm.model.anthropic"] = .string("fixture-other")
            return true
        }
        #expect(await session.run() == false)
        #expect(asks.count == 4 && !app.bool(consent))
        #expect(await fake.sends == 1)

        app.settings.values["llm.model.anthropic"] = .string("fixture-local")
        #expect(session.current)
        app.connectorConsentOverride = { _, _, _ in
            asks.count += 1
            shell.selection = .clip("five-1")
            self.step(undo) { editor.apply(.cutSelection(ids: [editor.words[lower + 1].id]), name: "Cut selection") }
            return true
        }
        #expect(await session.run() == false)
        #expect(asks.count == 5 && !app.bool(consent) && session.isOpen && session.task.state == .changed)
        #expect(await fake.sends == 1)
    }

    /// A session on Full take reads every word: an edit to any word shows R3, and undoing
    /// it the proposal; a new clip lies outside it (V13).
    @Test func aFullTakeRewriteSessionReadsEveryWord() async throws {
        let (_, editor, undo) = try await openShell()
        defer { editor.close() }
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: nil, connector: nil)
        editor.rewrite = session
        let words = session.source.filter { $0.kind == .word }.map(\.text)
        try session.receivePassage((["Fresh"] + words.dropFirst()).joined(separator: " "))
        session.finishRun(seconds: 1)
        let proposal = session.task.state
        if case .proposal(let set) = proposal { #expect(set.items.count == 1) } else { Issue.record("no proposal: \(proposal)") }
        let last = try #require(editor.words.last(where: { $0.kind == .word }))
        step(undo) { editor.apply(.cutSelection(ids: [last.id]), name: "Cut selection") }
        #expect(session.isOpen && session.task.state == .changed && session.task.headline.text == "Full take changed")
        undo.undo()
        #expect(session.task.state == proposal && session.current)
        let renamed = try #require(editor.project.edits.clips.first)
        step(undo) { editor.apply(.renameClip(id: renamed.id, title: "Renamed"), name: "Rename clip") }
        #expect(session.task.state == proposal && session.current)
    }

    /// Item 5: ⌘W closes a clip or suggestion tab; Full Take is pinned and ⌘W stays Close
    /// Project there. Closing the active tab hands the scope to the tab before it.
    @Test func closingTabsAndTheCommandWRule() async throws {
        let (shell, editor, _) = try await openShell()
        defer { editor.close() }
        let steps = editor.undoSteps
        #expect(!shell.closesTab)
        shell.closeTab(.fullTake)
        #expect(shell.tabs.open == [.fullTake])
        shell.selection = .clip("five-1")
        shell.selection = .clip("five-2")
        #expect(shell.closesTab)
        shell.closeTab(shell.tabs.active)
        #expect(shell.tabs.open == [.clip("five-1"), .fullTake] && shell.tabs.active == .clip("five-1") && editor.project.edits.activeClipId == "five-1")
        shell.closeTab(.clip("five-1"))
        #expect(shell.tabs.open == [.fullTake] && shell.tabs.active == .fullTake && editor.project.edits.activeClipId == nil && editor.undoSteps == steps)
        // Home shows no tabs: ⌘W is Close Project's again.
        shell.selection = .clip("five-1")
        shell.selection = .home
        #expect(!shell.tabsShown && !shell.closesTab)
    }

    /// DebugTabs' close checks: once an edit is saved (here cleared, as a save clears it),
    /// closing tabs, inactive, an active preview and a clip, makes no undo step and leaves
    /// the document clean.
    @Test func closingTabsAfterASavedEditLeavesTheDocumentClean() async throws {
        let (shell, editor, undo) = try await openShell()
        defer { editor.close() }
        let document = editor.document
        let cut = try #require(editor.words.first { $0.text == "nobody" }).id
        step(undo) { editor.apply(.cutSelection(ids: [cut]), name: "Cut selection") }
        #expect(document.isDocumentEdited && document.hasUnautosavedChanges)
        document.updateChangeCount(.changeCleared)
        let steps = editor.undoSteps
        for id in ["five-1", "five-2", "five-5"] { shell.selection = .clip(id) }
        shell.closeTab(.clip("five-1"))
        shell.closeTab(.suggestion("five-5"))
        #expect(shell.tabs.active == .fullTake)
        shell.closeTab(.clip("five-2"))
        #expect(shell.tabs.open == [.fullTake] && editor.undoSteps == steps)
        #expect(!document.isDocumentEdited && !document.hasUnautosavedChanges)
    }

    /// The tab row's last 32 pt stay the title row's, so it moves the window there even
    /// when six tabs shrink to fit and when they overflow and scroll behind the chevron.
    @Test func theTabRowKeepsADragGapAfterItsTabs() async throws {
        let (shell, editor, _) = try await openShell()
        defer { editor.close() }
        for id in ["five-1", "five-2", "five-3", "five-4", "five-5"] { shell.selection = .clip(id) }
        let bar = EditorTabBarView(shell: shell, model: editor)
        defer { bar.tearDown() }
        let row = ShellBand(fill: "bg.window", bottomLine: true, movesWindow: true, region: "tabBar")
        row.set(leading: [bar], trailing: [])
        row.fillsLeading = bar
        // A 624 pt row leaves the tabs 616, as at 1280 with the Explorer and the right column shown.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 624, height: ShellMetrics.titleRow))
        host.addSubview(row)
        for (width, overflows) in [(CGFloat(624), false), (400, true)] {
            host.frame.size.width = width
            row.frame = host.bounds
            bar.render()
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            bar.layoutSubtreeIfNeeded()
            #expect(bar.order.count == 6 && bar.frame.width == width - 8 && bar.overflowing == overflows)
            // Any point in the last 32 pt: its start, middle and end.
            for inset in [CGFloat(31), 16, 1] {
                let point = NSPoint(x: bar.frame.maxX - inset, y: bar.frame.midY)
                #expect(row.hitTest(point) === row && row.movesWindow, "width \(width), \(inset) from the end: \(row.hitTest(point).map { String(describing: type(of: $0)) } ?? "nothing")")
            }
            let ends = overflows ? [bar.overflowButton.frame.maxX] : bar.order.compactMap { bar.items[$0]?.frame.maxX }
            #expect(ends.allSatisfy { $0 <= bar.bounds.width - 32 + 0.5 })
        }
    }

    @Test func aVersionsWindowSwitchesTabsAndNeverWritesThem() throws {
        _ = NSApplication.shared
        let version = VoxClipDocument(project: try project(), demo: true)
        version.versionForTesting = true
        let controller = VersionWindowController(version: version, app: AppModel())
        defer { version.close() }
        let shell = controller.shell
        let editor = try #require(shell.editor)
        shell.selection = .clip("five-1")
        shell.selectTab(.fullTake)
        shell.selectTab(.clip("five-1"))
        #expect(shell.tabs.active == .clip("five-1") && editor.project.edits.activeClipId == "five-1")
        #expect(!editor.capabilities.writable && !version.isDocumentEdited && !version.hasUnautosavedChanges)
    }

    // MARK: The tab bar

    /// The tab row holds the tab bar: an AppKit tab group of tab buttons named for their
    /// scope, the active one selected, a dirty one saying so; F6 focuses the active tab.
    @Test func theTabBarIsATabGroupOfTabButtons() async throws {
        let (shell, editor, _) = try await openShell()
        defer { editor.close() }
        shell.windowWidth = 1280
        shell.selection = .clip("five-1")
        let controller = EditorShellController(shell: shell)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        controller.apply(EditorShellState(shell: shell))
        defer { controller.tearDown() }
        let work = try #require(controller.editorWork)
        let bar = work.tabBar
        #expect(bar.superview === work.tabRow && work.tabRow.fillsLeading === bar)
        shell.tabs.dirty = [.clip("five-1")]
        bar.render()
        let active = try #require(bar.activeItem)
        #expect(bar.accessibilityRole() == .tabGroup && bar.order == [.clip("five-1"), .fullTake])
        #expect(active.accessibilityRole() == .radioButton && active.accessibilitySubrole() == .tabButtonSubrole && active.accessibilityLabel() == "Clip 1")
        #expect((active.accessibilityValue() as? NSNumber)?.intValue == 1 && (bar.items[.fullTake]?.accessibilityValue() as? NSNumber)?.intValue == 0)
        #expect(active.accessibilityHelp() == "Has unreviewed changes" && active.showsDot && !active.showsClose)
        #expect((bar.items[.fullTake]?.accessibilityCustomActions() ?? []).isEmpty && active.accessibilityCustomActions()?.map(\.name) == ["Close Tab"])
        // The tab's chrome is 67 pt beyond its name (f1's "Clip 1" is 100 wide).
        #expect(active.naturalWidth >= 95 && active.naturalWidth <= 105)
        editor.focusedPane = .sidebar
        shell.movePaneFocus(backward: false)
        #expect(editor.focusedPane == .tabs && window.firstResponder === active)
        // Show cuts' slot sits at the row's end and stays hidden until V8b.
        #expect(work.showCutsSlot.superview === work.tabRow && work.showCutsSlot.isHidden)
    }
}

/// How often the connector consent was asked for.
@MainActor private final class ConsentAsks { var count = 0 }
#endif
