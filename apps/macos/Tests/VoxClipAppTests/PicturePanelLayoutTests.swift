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
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
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
}
#endif
