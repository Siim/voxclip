#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

/// The Picture panel laid out offscreen at the widths of looks spec 2026-11-28, section 3.8: 296, 376 and 532 pt of content
/// (columns of 324, 404 and 560) and the 960 × 600 column (324 × 322). The header stays pinned while the body is at least
/// 300 pt tall and the title row carries the look and Compare otherwise; tiles take 4, 6 and 8 columns; nothing reaches past
/// the column; and the disabled reasons show. With `VOXCLIP_REVIEW_CAPTURES` set, each state is also written as a PNG.
@Suite("Picture panel layout", .serialized, .offlineFixtures)
@MainActor struct PicturePanelLayoutTests {
    /// The editor holds its undo manager weakly: the suite keeps it.
    private let undo = UndoManager()

    private func openShell() async throws -> (WorkspaceShell, EditorModel) {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.id = base.id
        project.export.aspect = .landscape
        // Its own settings and data folder: nothing is read from or written to the user's.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-picture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shell = WorkspaceShell(app: AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])))
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .clip("five-1"))
        let editor = try #require(shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        undo.groupsByEvent = false
        editor.undoManager = undo
        shell.choosePanelJob(.picture, for: editor)
        #expect(shell.panelJob(for: editor) == .picture && editor.renderedActiveClipID == "five-1")
        // The frame the looks preview on: a synthetic clip rendered at the project's 16:9.
        let still = try await Self.still()
        editor.looks.stills = { _ in still }
        return (shell, editor)
    }

    private nonisolated static func still() async throws -> ClipStillFrame {
        let source = try SharedResources.locate().root.appendingPathComponent("fixtures/media/bars-1080p.mp4")
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [MediaInterval(startSample: 0, endSample: 96000)])
        let request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30, videoBitrate: 4_000_000))
        return try await ClipStillFrame.capture(try await CompositionBuilder().build(request), renderedSeconds: 1)
    }

    private func step(_ editor: EditorModel, _ change: () -> Bool) {
        editor.undoManager?.beginUndoGrouping(); _ = change(); editor.undoManager?.endUndoGrouping()
    }

    /// The tile pixel size the grid asks for at `content` points across.
    private func tilePixels(_ content: CGFloat) -> Int {
        let columns = ClipLookTileGrid.columns(width: content)
        let side = max(ClipLookTileGrid.minimum, ((content - ClipLookTileGrid.gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        return min(144, Int((side * 2 / 16).rounded(.up)) * 16)
    }

    /// The panel at `size`, laid out until its tiles have their pictures; its markers and texts.
    private func layout(_ shell: WorkspaceShell, _ editor: EditorModel, size: CGSize, capture: String? = nil) async throws
        -> (markers: [String: CGRect], texts: [String: String]) {
        editor.refreshLookTiles(pixels: tilePixels(size.width - 28))
        await editor.looks.tileTask?.value
        let view = PanelHost(model: editor, shell: shell, width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        if let capture { try await ReviewCaptures.capture(view, name: capture, size: size) }
        return (DebugRightColumn.markers(in: host), DebugRightColumn.texts(in: host))
    }

    private func expectInside(_ markers: [String: CGRect], width: CGFloat, _ comment: String) {
        for (name, frame) in markers where name.hasPrefix("picture.") || name.hasPrefix("panel.") {
            #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5, Comment(rawValue: "\(name) \(frame) past \(width): \(comment)"))
        }
    }

    @Test func theHeaderPinsTilesFitAndTheShortColumnCarriesTheLookInItsTitleRow() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        editor.looks.auto["five-1"] = .measured(ClipColorFix(exposure: 10, temperature: -12))
        step(editor) { editor.chooseLook("warmPrint") == .changed }
        step(editor) { editor.setLookAmount(70) }
        step(editor) { editor.setLookSlider(.vibrance, value: 20) }
        step(editor) { editor.setLookSlider(.highlights, value: -15) }
        editor.app.settings.values["ui.pictureFineTuneOpen"] = .bool(true)
        for (size, columns, pinned) in [(CGSize(width: 404, height: 800), 6, true), (CGSize(width: 324, height: 640), 4, true),
                                        (CGSize(width: 560, height: 900), 8, true), (CGSize(width: 324, height: 322), 4, false)] {
            let name = "\(Int(size.width - 28))x\(Int(size.height))"
            let found = try await layout(shell, editor, size: size, capture: "picture-\(name)")
            let tiles = try #require(found.markers["picture.tiles"], Comment(rawValue: name))
            #expect(ClipLookTileGrid.columns(width: tiles.width) == columns, Comment(rawValue: "\(name): \(tiles)"))
            #expect((found.markers["picture.header"] != nil) == pinned, Comment(rawValue: name))
            #expect((found.markers["panel.compare"] != nil) == !pinned, Comment(rawValue: "the title row's Compare at \(name)"))
            if !pinned {
                #expect(found.texts["panel.context"] == "Warm Print, edited \u{00B7} 70%" && found.texts["panel.title"] == "Picture")
                // The look's whole name fits beside the folded switcher.
                let context = try #require(found.markers["panel.context"]), compare = try #require(found.markers["panel.compare"])
                #expect(context.maxX <= compare.minX && context.width >= 140, Comment(rawValue: "\(context)"))
            }
            #expect(found.texts["picture.look.value"] == "Warm Print, edited \u{00B7} 70%")
            expectInside(found.markers, width: size.width, name)
        }
    }

    @Test func theDisabledReasonsShowInline() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        editor.app.settings.values["ui.pictureFineTuneOpen"] = .bool(true)
        // As filmed: nothing to blend, compare or clear.
        var found = try await layout(shell, editor, size: CGSize(width: 404, height: 1500), capture: "picture-as-filmed")
        #expect(found.texts["picture.amount.reason"] == "As filmed has no look to blend")
        #expect(found.texts["picture.clear"] == "Nothing to clear")
        #expect(found.texts["picture.reset.light"] == "Nothing to reset")
        #expect(found.texts["picture.auto.reason"] == "VoxClip couldn't read this video's frames", "a demo has no frames to measure")
        // A black-and-white look mutes Vibrance and Saturation; Back to says the values match.
        step(editor) { editor.chooseLook("softBW") == .changed }
        found = try await layout(shell, editor, size: CGSize(width: 404, height: 1500), capture: "picture-soft-bw")
        #expect(found.texts["picture.vibrance.reason"] == "No effect on black and white")
        #expect(found.texts["picture.saturation.reason"] == "No effect on black and white")
        #expect(found.texts["picture.backto"] == "Matches Soft B&W")
        // A missing video disables everything with the editor's line.
        editor.mediaResolved = false
        found = try await layout(shell, editor, size: CGSize(width: 404, height: 800), capture: "picture-missing-video")
        #expect(found.texts["picture.reason"] == "Locate the video to change the look.")
        #expect(found.texts["picture.sample"] == "Previews need the source video. Looks still apply when it's back.")
        editor.mediaResolved = true
    }

    @Test func aTimedLookFromAskClaudeShowsWithRemove() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        let span = try #require(ClipControlsProject.sourceSpan(of: "five-1", in: editor.project))
        let effect = ClipEffect(id: "timed-bw", clipId: "five-1", kind: .colourLook, start: span.lowerBound + 1, end: span.lowerBound + 2, look: .bw)
        let next = try ClipEffects.adding([effect], to: editor.project)
        step(editor) { editor.replace(next, name: "Ask Claude"); return true }
        let found = try await layout(shell, editor, size: CGSize(width: 404, height: 900), capture: "picture-timed-look")
        #expect(found.texts["picture.timed"]?.hasPrefix("A timed B&W from Ask Claude replaces this look at ") == true, "\(found.texts["picture.timed"] ?? "none")")
        let id = try #require(editor.project.clipEffects.first { $0.kind == .colourLook }?.id)
        step(editor) { editor.removeTimedLook(id) }
        #expect(editor.project.clipEffects.isEmpty, "\(editor.project.clipEffects.map(\.id))")
        #expect(editor.undoManager?.undoActionName == "Remove timed look")
    }

    @Test func claudesPickHoverAndTheClipSectionAreCaptured() async throws {
        let (shell, editor) = try await openShell()
        defer { editor.close() }
        editor.looks.auto["five-1"] = .measured(ClipColorFix(temperature: -12))
        let look = ClipAutopilotPlan.Look(id: "warmPrint", amount: 70, alternatives: ["goldenHour", "softBW"], reason: "Warm lamp light suits a travel memory.")
        step(editor) { editor.apply(look: look, fix: ClipColorFix(temperature: -12)) }
        editor.looks.picks["five-1"] = ClipLookPick(look: look, fix: ClipColorFix(temperature: -12))
        editor.previewLook("goldenHour")
        await editor.looks.previewTask?.value
        var found = try await layout(shell, editor, size: CGSize(width: 404, height: 800), capture: "picture-claude-hover")
        #expect(found.texts["picture.claude"]?.hasPrefix("Claude chose Warm Print \u{00B7} 70%") == true)
        #expect(found.texts["viewer.look.badge"] == "Preview \u{00B7} Golden Hour")
        editor.previewLook(nil)
        editor.looks.category = ClipLookPanel.all
        found = try await layout(shell, editor, size: CGSize(width: 560, height: 900), capture: "picture-532-all")
        #expect(found.markers["picture.tiles"].map { ClipLookTileGrid.columns(width: $0.width) } == 8)
        step(editor) { editor.chooseLook("goldenHour") == .changed }
        editor.looks.category = ClipLookPanel.suggested
        found = try await layout(shell, editor, size: CGSize(width: 404, height: 800), capture: "picture-claude-use-it")
        #expect(found.texts["picture.claude"] == "Claude's pick: Warm Print \u{00B7} 70%")

        // The Clip section's compact form in the Captions panel's width.
        let clip = ClipSection(model: editor, expanded: true).frame(width: 376).padding(.horizontal, 14)
        let host = NSHostingView(rootView: clip.frame(width: 404, height: 520, alignment: .top))
        host.frame = CGRect(x: 0, y: 0, width: 404, height: 520)
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        let markers = DebugRightColumn.markers(in: host)
        let tiles = try #require(markers["clip.look.tiles"])
        #expect(tiles.maxX <= 404 + 0.5)
        #expect(DebugRightColumn.texts(in: host)["picture.look.value"] == "Golden Hour")
        try await ReviewCaptures.capture(clip, name: "clip-section-compact", size: CGSize(width: 404, height: 520))
    }

    /// `view` drawn on bg.surface in a dark window, read back in sRGB.
    private func dark<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(DesignValues.color("bg.surface")))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        return try DebugTimeline.sRGBBitmap(of: host)
    }

    /// The panel's text actions read at 4.5:1 on the dark panel, and brighter than their disabled form; the look's tick is
    /// drawn above the slider's filled track in the accent mark colour, not the fill's (the shipped dark Ink, #6D6F73, is
    /// under 4.5:1 there and matches the filled track).
    @Test func theLinksAndTheLooksTickReadOnTheDarkPanel() throws {
        func brightest(_ bitmap: NSBitmapImageRep) -> NSColor {
            var best = NSColor.black, luminance = -1.0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let pixel = DebugTimeline.pixel(bitmap, x: x, y: y)
                guard pixel.count == 3 else { continue }
                let value = 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
                if value > luminance { luminance = value; best = NSColor(srgbRed: pixel[0], green: pixel[1], blue: pixel[2], alpha: 1) }
            } }
            return best
        }
        let surface = NSColor(srgbRed: 0x1C / 255.0, green: 0x1D / 255.0, blue: 0x20 / 255.0, alpha: 1)
        let link = Button("Back to Warm Print") {}.buttonStyle(ClipLookLinkStyle()).font(VCType.callout.font())
        let enabled = brightest(try dark(link, size: CGSize(width: 140, height: 20)))
        let disabled = brightest(try dark(link.disabled(true), size: CGSize(width: 140, height: 20)))
        #expect(DesignValues.contrast(enabled, surface) >= 4.5, Comment(rawValue: "\(enabled)"))
        #expect(DesignValues.contrast(enabled, surface) > DesignValues.contrast(disabled, surface) + 3, Comment(rawValue: "\(enabled) \(disabled)"))

        let size = CGSize(width: 200, height: 24)
        let track = ClipLookTrack(value: 80, range: -100...100, tick: 30, dragging: .constant(false), draft: .constant(nil),
                                  preview: { _ in }, commit: { _ in }, reset: {})
        let bitmap = try dark(track, size: size)
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        // ClipLookTrack.tickMark: 6 pt in from each end, 130 of 200 along.
        let x = 6 + (size.width - 12) * 130 / 200
        let pixel = DebugTimeline.pixel(bitmap, x: Int(x * scale), y: Int(size.height / 2 * scale))
        let expected = try DebugTimeline.swatch("accent.text")
        #expect(pixel.count == 3 && zip(pixel, expected).allSatisfy { abs($0 - $1) < 4.0 / 255 },
                Comment(rawValue: "the tick over the filled track: \(pixel) for \(expected)"))
    }
}
#endif

#if DEBUG
/// View › Open Picture and View › Compare with As Filmed, in the menu and so the command palette, and the backslash key held
/// anywhere in the editor but a text field (looks spec 2026-11-28, sections 3.4 and 3.9).
@Suite("Picture commands", .serialized, .offlineFixtures)
@MainActor struct PictureCommandTests {
    @Test func openPictureAndCompareAreCommandsAndTheBackslashKeyHoldsCompare() async throws {
        _ = NSApplication.shared
        let old = NSApp.mainMenu
        defer { NSApp.mainMenu = old }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-picture-commands-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.id = base.id
        await app.shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .clip("five-1"), preview: DemoPreviewEngine())
        let controller = MainWindowController(shell: app.shell)
        defer { controller.window?.close(); app.shell.editor?.close() }
        let editor = try #require(app.shell.editor)
        editor.mediaResolved = true
        editor.refresh()
        let delegate = AppDelegate(model: app)
        delegate.installMenus()
        delegate.commandWindowForTesting = controller.window
        let main = try #require(NSApp.mainMenu)
        for result in DebugMenus.shortcutChecks(in: main) { #expect(result.passed, Comment(rawValue: result.name)) }
        let view = try #require(main.item(withTitle: "View")?.submenu)
        let open = try #require(view.item(withTag: 64)), compare = try #require(view.item(withTag: 78))
        #expect(open.title == "Open Picture" && compare.title == "Compare with As Filmed")
        #expect(compare.keyEquivalent == "\\" && compare.keyEquivalentModifierMask.isEmpty)
        // As filmed: nothing to compare, and the item says why.
        #expect(!delegate.validateMenuItem(compare) && compare.toolTip == "Nothing to compare: the clip is as filmed")
        #expect(editor.chooseLook("warm") == .changed)
        #expect(delegate.validateMenuItem(compare) && compare.state == .off && compare.toolTip == nil)
        let commands = MenuCommandIndex.items().map(\.menuItem.tag)
        #expect(commands.contains(64) && commands.contains(78))

        func key(_ type: NSEvent.EventType, repeating: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "\\", charactersIgnoringModifiers: "\\", isARepeat: repeating, keyCode: 42))
        }
        #expect(delegate.handleCompareKey(try key(.keyDown)) && editor.looks.comparing && editor.lastAnnouncement == "Showing as filmed")
        #expect(delegate.handleCompareKey(try key(.keyDown, repeating: true)) && editor.looks.comparing)
        #expect(delegate.validateMenuItem(compare) && compare.state == .on)
        #expect(delegate.handleCompareKey(try key(.keyUp)) && !editor.looks.comparing && editor.lastAnnouncement == "Showing Warm")
        // The menu item toggles.
        delegate.perform(Selector(("performEditorCommand:")), with: compare)
        #expect(editor.looks.comparing)
        delegate.perform(Selector(("performEditorCommand:")), with: compare)
        #expect(!editor.looks.comparing)
        // Text fields keep the key.
        #expect(AppDelegate.compareKeyAllowed(nil) && !AppDelegate.compareKeyAllowed(NSTextField()) && !AppDelegate.compareKeyAllowed(NSTextView()))
        // The bare \ never fires the menu item: in the Ask field, a rename or a correction it types; elsewhere the hold has it.
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        controller.window?.contentView?.addSubview(field)
        controller.window?.makeFirstResponder(field)
        delegate.commandEventForTesting = try key(.keyDown)
        #expect(!delegate.validateMenuItem(compare), "the backslash typed in a text view reaches the text view")
        delegate.perform(Selector(("performEditorCommand:")), with: compare)
        #expect(!editor.looks.comparing)
        editor.correctionID = editor.words.first?.id
        #expect(!delegate.handleCompareKey(try key(.keyDown)) && !delegate.validateMenuItem(compare), "a correction types it")
        editor.correctionID = nil
        // Chosen from the menu, the palette or with another key down, the item still toggles.
        delegate.commandEventForTesting = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(delegate.validateMenuItem(compare))
        delegate.commandEventForTesting = nil
        #expect(delegate.validateMenuItem(compare))
    }
}
#endif
