#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The right column under its title row (impl-plan V4): the viewer as a fixed 16:9 box of
/// the column's width with the frame fitted in it, the panel header and its job switcher,
/// and the hover transport only with the timeline hidden. Nothing is shown and settings
/// are never loaded, so nothing is written.
@Suite("Right column: viewer and panel host", .serialized)
@MainActor struct PanelHostTests {
    /// The "Five questions" fixture: four kept clips (five-1…five-4) and one suggestion (five-5), 16:9.
    private func project() throws -> Project {
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugSidebar.fiveQuestions(from: base)
        project.export.aspect = .landscape
        return project
    }
    private func openShell() async throws -> (WorkspaceShell, EditorModel) {
        _ = NSApplication.shared
        let shell = WorkspaceShell(app: AppModel())
        await shell.attachForTesting(VoxClipDocument(project: try project(), demo: true), selection: .fullTake)
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        return (shell, editor)
    }
    /// `content` laid out offscreen at `size`, and its layout markers.
    private func markers(_ content: some View, size: CGSize) -> [String: CGRect] {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return DebugRightColumn.markers(in: host)
    }
    /// `content` in a borderless window that is never shown, so SwiftUI can give it keyboard focus.
    private func windowed(_ content: some View, size: CGSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        _ = window.makeFirstResponder(host)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }
    /// Lays `host` out until `done` holds, giving SwiftUI up to 100 turns to apply a change.
    @discardableResult private func settle(_ host: NSView, until done: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if done() { return true }
            await Task.yield()
        }
        return done()
    }

    // MARK: Geometry

    @Test func theViewerIsA169BoxOfTheColumnWidthWithTheFrameFittedInIt() {
        #expect(ViewerSection.boxHeight(forWidth: 404) == 227)
        #expect(ViewerSection.boxHeight(forWidth: 444) == 250)
        #expect(ViewerSection.boxHeight(forWidth: 300) == 169)
        let box = CGSize(width: 404, height: 227)
        #expect(ViewerSection.stageSize(ratio: 16 / 9, in: box) == box)
        // f5: a 9:16 frame is pillarboxed 128 wide.
        #expect(ViewerSection.stageSize(ratio: 9 / 16, in: box) == CGSize(width: 128, height: 227))
        #expect(ViewerSection.stageSize(ratio: 1, in: box) == CGSize(width: 227, height: 227))
        // A wider frame than 16:9 is letterboxed.
        #expect(ViewerSection.stageSize(ratio: 2.39, in: box) == CGSize(width: 404, height: 169))
        // The panel body keeps 160 below the 30 pt header; then the box gives way and pillarboxes 16:9.
        #expect(PanelHost.viewerHeight(width: 404, height: 522) == 227)
        #expect(PanelHost.viewerHeight(width: 404, height: 422) == 227)
        #expect(PanelHost.viewerHeight(width: 324, height: 322) == 132)
        #expect(PanelHost.viewerHeight(width: 404, height: 300) == 110)
        #expect(ViewerSection.stageSize(ratio: 16 / 9, in: CGSize(width: 404, height: 110)) == CGSize(width: 196, height: 110))
    }

    /// The 960 × 600 window minimum with the default timeline leaves the column 324 × 322. The
    /// box gives way so the panel keeps a usable body: Captions' gallery scrolls in more than
    /// two rows' height under its fixed header (it was 4 pt with the full box), and so does
    /// Rewrite's scroll above its footer.
    @Test func theShortestColumnKeepsThePanelUsable() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let size = CGSize(width: 324, height: 322)
        func measure() async -> (markers: [String: CGRect], viewport: CGRect?) {
            let host = NSHostingView(rootView: PanelHost(model: editor, shell: shell, width: size.width, height: size.height))
            host.frame = CGRect(origin: .zero, size: size)
            await settle(host) { !DebugRightColumn.scrollViews(in: host).isEmpty }
            return (DebugRightColumn.markers(in: host), DebugRightColumn.scrollViews(in: host).first.map { $0.convert($0.bounds, to: host) })
        }
        let captions = await measure()
        #expect(captions.markers["viewer.box"] == CGRect(x: 0, y: 0, width: 324, height: 132))
        #expect(captions.markers["panel.body"] == CGRect(x: 0, y: 162, width: 324, height: 160))
        let gallery = try #require(captions.viewport)
        // Two 24 pt rows at least; the audit's floor in every state is one (DebugRightColumn.minimumViewport).
        #expect(gallery.height >= 48, Comment(rawValue: "Captions' gallery scrolls in \(gallery)"))

        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        editor.rewrite = RewriteSession(editor: editor, range: 3...5, envelope: nil, connector: nil)
        let rewrite = await measure()
        #expect(rewrite.markers["viewer.box"] == CGRect(x: 0, y: 0, width: 324, height: 132), "no Rewrite compaction")
        let scroll = try #require(rewrite.viewport)
        #expect(scroll.minY >= 162 && scroll.height >= 48, Comment(rawValue: "Rewrite scrolls in \(scroll)"))
    }

    /// No Rewrite compaction: a session leaves the viewer at its size (design.md's 146 pt stage is gone).
    @Test func theViewerKeepsItsSizeWhileRewriteIsOpen() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let size = CGSize(width: 404, height: 422)
        let before = markers(PanelHost(model: editor, shell: shell, width: size.width, height: size.height), size: size)
        editor.rewrite = RewriteSession(editor: editor, range: 3...5, envelope: nil, connector: nil)
        let after = markers(PanelHost(model: editor, shell: shell, width: size.width, height: size.height), size: size)
        for found in [before, after] {
            #expect(found["viewer.box"] == CGRect(x: 0, y: 0, width: 404, height: 227))
            #expect(found["viewer.stage"] == CGRect(x: 0, y: 0, width: 404, height: 227))
            #expect(found["panel.header"] == CGRect(x: 0, y: 227, width: 404, height: 30))
            #expect(found["panel.body"] == CGRect(x: 0, y: 257, width: 404, height: 165))
        }
        #expect(before["panel.job.rewrite"] == nil && after["panel.job.rewrite"] != nil)
    }

    /// notes.md §1 at 1280 × 800 with fresh defaults: viewer 876,38 404 × 227; header 876,265
    /// 404 × 30; body 876,295 404 × 265. Measured in the shell's own tree.
    @Test func theViewerAndPanelRowsAreTheNotesRegionsAt1280() async throws {
        let (shell, _) = try await openShell()
        defer { shell.editor?.close() }
        shell.windowWidth = 1280
        let controller = EditorShellController(shell: shell)
        defer { controller.tearDown() }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        controller.apply(EditorShellState(shell: shell))
        func matches(_ region: ShellRegion, _ regions: [ShellRegion: CGRect]) -> Bool {
            guard let frame = regions[region] else { return false }
            let reference = region.reference
            return abs(frame.minX - reference.minX) <= 1 && abs(frame.minY - reference.minY) <= 1 && abs(frame.width - reference.width) <= 1 && abs(frame.height - reference.height) <= 1
        }
        var regions: [ShellRegion: CGRect] = [:]
        // The dividers are placed a turn after the first layout; give it up to 200 turns.
        for _ in 0..<200 {
            controller.view.layoutSubtreeIfNeeded()
            regions = DebugShell.regions(in: window)
            if [ShellRegion.viewer, .panelHeader, .panelBody, .rightTitle].allSatisfy({ matches($0, regions) }) { break }
            await Task.yield()
        }
        #expect(ShellRegion.viewer.reference == CGRect(x: 876, y: 38, width: 404, height: 227))
        for region in [ShellRegion.rightTitle, .viewer, .panelHeader, .panelBody] {
            #expect(matches(region, regions), Comment(rawValue: "\(region): \(regions[region].map { "\($0)" } ?? "missing") vs \(region.reference)"))
        }
    }

    // MARK: The one tag

    @Test func theStageCarriesOneTag() async throws {
        let shared = try SharedResources.locate()
        // The fixture with one enabled Voice Lab segment.
        let voiced = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let segment = try #require(voiced.voiceLab.segments.first { $0.enabled })
        let model = EditorModel(document: VoxClipDocument(project: voiced, demo: true), app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        model.sourceTime = segment.replace.start + 0.01
        #expect(ViewerSection.tag(for: model, standIn: true) == .aiVoice)
        model.sourceTime = max(0, segment.replace.start - 0.5)
        #expect(ViewerSection.tag(for: model, standIn: true) == .aiModified)
        #expect(ViewerTag.aiVoice.text == "AI voice" && ViewerTag.aiModified.text == "AI modified")

        let (_, plain) = try await openShell()
        defer { plain.close() }
        // The demo stand-in's chip is the tag when nothing is AI; a video shows none.
        #expect(ViewerSection.tag(for: plain, standIn: true) == .media("Demo · no video"))
        #expect(ViewerSection.tag(for: plain, standIn: false) == nil)
        let found = markers(ViewerSection(model: plain, columnWidth: 404), size: CGSize(width: 404, height: 227))
        let stage = try #require(found["viewer.stage"]), tag = try #require(found["viewer.tag"])
        #expect(tag.minX == stage.minX + 10 && tag.minY == stage.minY + 10 && found["viewer.transport"] == nil)
    }

    // MARK: Hover transport

    @Test func theHoverTransportShowsOnlyWithTheTimelineHidden() async throws {
        #expect(!ViewerSection.showsTransport(timelineVisible: true, hovering: true, focused: true, voiceOver: true))
        #expect(!ViewerSection.showsTransport(timelineVisible: false, hovering: false, focused: false, voiceOver: false))
        #expect(ViewerSection.showsTransport(timelineVisible: false, hovering: true, focused: false, voiceOver: false))
        #expect(ViewerSection.showsTransport(timelineVisible: false, hovering: false, focused: true, voiceOver: false))
        #expect(ViewerSection.showsTransport(timelineVisible: false, hovering: false, focused: false, voiceOver: true))

        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let size = CGSize(width: 404, height: 522)
        func transport(hovering: Bool) -> CGRect? {
            markers(PanelHost(model: editor, shell: shell, width: size.width, height: size.height, hovering: hovering), size: size)["viewer.transport"]
        }
        #expect(transport(hovering: true) == nil)
        shell.toggleTimeline()
        #expect(!shell.layout.timelineVisible)
        #expect(transport(hovering: false) == nil)
        // Along the box's bottom edge: a 32 pt bar 8 in from the edges.
        #expect(transport(hovering: true) == CGRect(x: 0, y: 227 - 48, width: 404, height: 48))
        // With the right column hidden too nothing would carry play and the timecode, so the timeline stays.
        shell.toggleTimeline()
        shell.toggleViewer()
        shell.toggleTimeline()
        #expect(!shell.layout.rightVisible && shell.layout.timelineVisible)
    }

    /// The transport is never only a hover target: keyboard focus inside the viewer (the box
    /// that takes its keys, Play, Edited / Source) keeps it, though the pane's own focus
    /// (`isFocused`, the nearest focusable ancestor) is off then.
    @Test func theHoverTransportStaysWhileFocusIsInsideTheViewer() async throws {
        #expect(ViewerSection.showsTransport(timelineVisible: false, hovering: false, focused: false, focusInside: true, voiceOver: false))
        #expect(!ViewerSection.showsTransport(timelineVisible: true, hovering: false, focused: false, focusInside: true, voiceOver: false))
        let (_, editor) = try await openShell()
        defer { editor.close() }
        let size = CGSize(width: 404, height: 227)
        let (window, focused) = windowed(ViewerSection(model: editor, columnWidth: 404, timelineVisible: false).focusing(.box), size: size)
        defer { window.close() }
        let shows = await settle(focused) { DebugRightColumn.markers(in: focused)["viewer.transport"] != nil }
        #expect(shows, "focus on the viewer's box shows the transport")
        let (plainWindow, plain) = windowed(ViewerSection(model: editor, columnWidth: 404, timelineVisible: false), size: size)
        defer { plainWindow.close() }
        await settle(plain) { false }
        #expect(DebugRightColumn.markers(in: plain)["viewer.transport"] == nil, "no focus and no pointer: no transport")
        let (timelineWindow, timeline) = windowed(ViewerSection(model: editor, columnWidth: 404, timelineVisible: true).focusing(.box), size: size)
        defer { timelineWindow.close() }
        await settle(timeline) { false }
        #expect(DebugRightColumn.markers(in: timeline)["viewer.transport"] == nil, "the timeline shows play and the time")
    }

    /// impl-plan V4's named risk, caption drag in the fixed box. A low caption (Clean Subtitle
    /// and Lower Third at y 0.9, Vox Highlight at 0.8) sits under the transport; the bar takes
    /// the pointer only on Play and Edited / Source, so the handle keeps a wide strip on the
    /// bar to press, and the bar steps aside while a caption is dragged. The press itself
    /// needs a real window (DebugViewer's caption drag in -uiSelfTest).
    @Test func aLowCaptionKeepsAPressableStripUnderTheTransport() async throws {
        #expect(!ViewerSection.showsTransport(timelineVisible: false, hovering: true, focused: true, voiceOver: true, captionDragging: true))
        for style in ["clean-subtitle", "lower-third", "vox-highlight"] {
            for aspect in [AspectRatio.landscape, .portrait, .square] {
                var project = try project()
                project.captions.styleId = style
                project.export.aspect = aspect
                // Not a demo, so the caption can move; nothing is edited here.
                let model = EditorModel(document: VoxClipDocument(project: project, demo: false), app: AppModel(), preview: DemoPreviewEngine())
                defer { model.close() }
                model.mediaResolved = true
                #expect(model.canMoveCaptions)
                let found = markers(ViewerSection(model: model, columnWidth: 404, timelineVisible: false, hovering: true), size: CGSize(width: 404, height: 227))
                let name = Comment(rawValue: "\(style) \(aspect.rawValue): \(found.filter { $0.key.hasPrefix("caption.") || $0.key.hasPrefix("viewer.") })")
                let handle = try #require(found["caption.handle"], name), bar = try #require(found["viewer.transport"], name)
                let play = try #require(found["viewer.play"], name), axis = try #require(found["viewer.axis"], name)
                let inner = bar.insetBy(dx: 8, dy: 8)
                let strip = CGRect(x: max(handle.minX, play.maxX), y: max(handle.minY, inner.minY), width: min(handle.maxX, axis.minX) - max(handle.minX, play.maxX), height: min(handle.maxY, inner.maxY) - max(handle.minY, inner.minY))
                #expect(handle.intersects(inner), name)
                #expect(strip.width >= 44 && strip.height >= 8, name)
            }
        }
    }

    // MARK: The panel's job

    @Test func theSwitcherShowsOnlyJobsThatCanActAndAJobSwitchIsNoEdit() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        #expect(PanelJob.available(in: editor) == [.captions] && shell.panelJob(for: editor) == .captions)
        // Rewrite can't be picked while no session can show it.
        shell.choosePanelJob(.rewrite, for: editor)
        #expect(shell.panelJob(for: editor) == .captions)

        shell.selection = .clip("five-1")
        let lower = try #require(editor.activeClip.flatMap { editor.index($0.startWordId) })
        let session = RewriteSession(editor: editor, range: lower...(lower + 2), envelope: nil, connector: nil)
        editor.rewrite = session
        #expect(PanelJob.available(in: editor) == [.captions, .rewrite] && shell.panelJob(for: editor) == .rewrite)
        // The switcher shows Captions beside the open session, with no undo step and no document change.
        shell.choosePanelJob(.captions, for: editor)
        #expect(shell.panelJob(for: editor) == .captions && session.isOpen)
        #expect(!undo.canUndo && !editor.document.isDocumentEdited && !editor.document.hasUnautosavedChanges)
        // The pick holds across a tab switch and back.
        shell.selection = .clip("five-2")
        #expect(PanelJob.available(in: editor) == [.captions] && shell.panelJob(for: editor) == .captions)
        shell.selectTab(.clip("five-1"))
        #expect(editor.rewrite === session && shell.panelJob(for: editor) == .captions)
        shell.choosePanelJob(.rewrite, for: editor)
        #expect(shell.panelJob(for: editor) == .rewrite)
        shell.choosePanelJob(.captions, for: editor)
        // A new session shows Rewrite again, as opening one always has.
        editor.closeRewrite(returnFocus: false)
        #expect(shell.panelJob(for: editor) == .captions)
        let next = RewriteSession(editor: editor, range: lower...(lower + 1), envelope: nil, connector: nil)
        editor.rewrite = next
        #expect(shell.panelJob(for: editor) == .rewrite)
        // Voice Lab's Rewrite off hides the job.
        editor.app.settings.values["voiceLab.enabled"] = .bool(false)
        #expect(PanelJob.available(in: editor) == [.captions] && shell.panelJob(for: editor) == .captions)
        #expect(!undo.canUndo && !editor.document.isDocumentEdited)
    }

    /// The header shows the job and the open tab's name, and follows a tab switch and a
    /// Rewrite session in the one panel it heads.
    @Test func theHeaderNamesTheJobAndTheOpenTab() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        #expect(PanelJob.allCases.map(\.title) == ["Captions", "Rewrite", "Voice", "Takes", "Director"])
        let found = markers(PanelHeader(model: editor, shell: shell, job: .captions).frame(width: 404), size: CGSize(width: 404, height: 30))
        #expect(found["panel.header"]?.size == CGSize(width: 404, height: 30))
        #expect(found["panel.job.captions"]?.size == CGSize(width: 26, height: 22))
        #expect(found["panel.job.captions"].map { abs($0.maxX - 398) <= 0.5 } == true)

        let size = CGSize(width: 404, height: 522)
        let host = NSHostingView(rootView: PanelHost(model: editor, shell: shell, width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        func shown() -> [String?] { let texts = DebugRightColumn.texts(in: host); return [texts["panel.title"], texts["panel.context"]] }
        await settle(host) { shown() == ["Captions", "Full Take"] }
        #expect(shown() == ["Captions", "Full Take"])
        shell.selection = .clip("five-1")
        await settle(host) { shown() == ["Captions", "Clip 1"] }
        #expect(shown() == ["Captions", "Clip 1"])
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let lower = try #require(editor.activeClip.flatMap { editor.index($0.startWordId) })
        editor.rewrite = RewriteSession(editor: editor, range: lower...(lower + 2), envelope: nil, connector: nil)
        await settle(host) { shown() == ["Rewrite", "Clip 1"] }
        #expect(shown() == ["Rewrite", "Clip 1"])
        shell.selection = .clip("five-2")
        await settle(host) { shown() == ["Captions", "Clip 2"] }
        #expect(shown() == ["Captions", "Clip 2"])
    }

    /// impl-plan V4: "the stage label is unchanged". The stage reads as before V4: the scope,
    /// AI speech, then the media state, for Full Take, a clip and a take with AI speech.
    @Test func theStageLabelIsUnchanged() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let host = NSHostingView(rootView: ViewerSection(model: editor, columnWidth: 404))
        host.frame = CGRect(x: 0, y: 0, width: 404, height: 227)
        func label() -> String? { DebugRightColumn.texts(in: host)["viewer.stage"] }
        await settle(host) { label() != nil }
        #expect(label() == "Video preview, full take, demo project, no video")
        shell.selection = .clip("five-1")
        await settle(host) { label() == "Video preview, clip 1, demo project, no video" }
        #expect(label() == "Video preview, clip 1, demo project, no video")

        let shared = try SharedResources.locate()
        let voiced = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let model = EditorModel(document: VoxClipDocument(project: voiced, demo: true), app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        let ai = NSHostingView(rootView: ViewerSection(model: model, columnWidth: 404))
        ai.frame = CGRect(x: 0, y: 0, width: 404, height: 227)
        await settle(ai) { DebugRightColumn.texts(in: ai)["viewer.stage"] != nil }
        // The fixture's clip 1 holds the AI speech.
        #expect(DebugRightColumn.texts(in: ai)["viewer.stage"] == "Video preview, clip 1, contains AI-modified speech, demo project, no video")
        #expect(ViewerSection.stageLabel(for: model) == DebugRightColumn.texts(in: ai)["viewer.stage"])
    }

    // MARK: Playback

    /// The viewer's Back 3 s button is gone (V4), so Playback › Back 3 Seconds works from the
    /// menu wherever focus is, as Forward 3 Seconds does. The J key it shares with Shuttle
    /// Back reaches it only from the transcript, as before.
    @Test func backThreeSecondsWorksFromTheMenuAndJOnlyFromTheTranscript() throws {
        let item = NSMenuItem(title: "Back 3 Seconds", action: nil, keyEquivalent: "j")
        item.keyEquivalentModifierMask = []
        func key(_ characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
        }
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let elsewhere: [NSResponder?] = [nil, NSView(), NSButton()]
        for responder in elsewhere {
            #expect(AppDelegate.backStepEnabled(item, event: nil, responder: responder))
            #expect(AppDelegate.backStepEnabled(item, event: click, responder: responder))
            // Arrow keys in an open menu are not its key equivalent.
            #expect(AppDelegate.backStepEnabled(item, event: try key(String(UnicodeScalar(NSDownArrowFunctionKey)!)), responder: responder))
            #expect(!AppDelegate.backStepEnabled(item, event: try key("j"), responder: responder))
        }
        #expect(AppDelegate.backStepEnabled(item, event: try key("j"), responder: TranscriptNSTextView()))
    }
}
#endif
