#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The tab row's Show cuts toggle (impl-plan V8b) without a window: its place before ⋯, that
/// it follows View › Show Cuts, and its keyboard focus ring. Settings are never loaded.
@Suite("Show cuts toggle", .serialized)
@MainActor struct ShowCutsToggleTests {
    private func editor(_ app: AppModel) throws -> EditorModel {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        return EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
    }

    @Test func theToggleSitsBeforeTheOverflowAndFollowsViewShowCuts() async throws {
        let app = AppModel()
        let model = try editor(app); defer { model.close() }
        let work = EditorWorkController(model: model, shell: WorkspaceShell(app: app))
        defer { work.tearDown() }
        let trailing = work.tabRow.trailing
        let index = try #require(trailing.firstIndex { $0 === work.showCuts })
        #expect(index + 1 < trailing.count && trailing[index + 1] === work.overflow, "Show cuts, then ⋯")
        #expect(work.showCuts.state == .off && !model.showsCuts)
        // View › Show Cuts (tag 60) calls toggleShowsCuts; the tab row's observation follows it.
        model.toggleShowsCuts()
        for _ in 0..<20 where work.showCuts.state != .on { await Task.yield() }
        #expect(work.showCuts.state == .on)
        // A click on the toggle turns it off again, for the menu's checkmark too.
        work.showCuts.performClick(nil)
        #expect(!model.showsCuts && work.showCuts.state == .off)
    }

    @Test func theToggleDrawsAFocusRingAroundItsRoundedBox() throws {
        let app = AppModel()
        let model = try editor(app); defer { model.close() }
        let toggle = ShowCutsToggle(model: model)
        toggle.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        #expect(toggle.focusRingMaskBounds == toggle.bounds)
        // The mask AppKit outlines: the rounded box, so its middle is filled and its corner is not.
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.black.setFill()
        toggle.drawFocusRingMask()
        NSGraphicsContext.restoreGraphicsState()
        #expect((bitmap.colorAt(x: 60, y: 12)?.alphaComponent ?? 0) > 0.9 && (bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.5)
    }
}
#endif
