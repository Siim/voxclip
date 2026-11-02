#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// What follows the transcript's laid-out lines (the backdrop band, the selection, the caret
/// and the overview ruler's visible window) is current after AppKit's own layout pass, the
/// one that lays out TextKit 2's viewport, after a scroll, a cut that refolds a paragraph and
/// a resize. Nothing here calls the pane's `layout()`, which lays the viewport out itself.
/// `TranscriptViewportRelay` places them, not a `textViewportLayoutControllerDidLayout(_:)`
/// override: NSTextView declares that from macOS 27.
@Suite("Transcript viewport overlays", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are shown."))
@MainActor struct TranscriptViewportTests {
    /// Forty paragraphs of twenty words, each its own speaker's turn, so each wraps after
    /// word 13 at the 528 measure and after word 17 at 680 (with overlay scrollers). The open clip spans the two
    /// paragraphs either side of `paragraph`, whose word 15 the playhead is on and whose words
    /// 10–16 are selected. With paragraph 14, paragraph 13 starts near the top after
    /// `scrollToThirteen`.
    private func editor(paragraph: Int = 14) throws -> EditorModel {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.transcript?.words = (0..<800).map { index in
            TimedWord(id: "v\(index)", text: "word", start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.3, speaker: "s\(index / 20 % 4)")
        }
        project.transcript?.durationSeconds = 402
        project.media.source.durationSeconds = 402
        project.edits = ProjectEdits(cutWordIds: [])
        project.edits.clips = [ClipRange(id: "middle", startWordId: "v\((paragraph - 2) * 20)", endWordId: "v\((paragraph + 3) * 20 - 1)", title: "Middle")]
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
        model.activate(model.project.edits.clips[0])
        // These viewport tests scroll through paragraphs outside the active clip.
        model.showsSurroundingContext = true
        model.sourceTime = Double(paragraph * 20 + 15) * 0.5 + 0.1
        model.selectedWordIDs = Set((paragraph * 20 + 10...paragraph * 20 + 16).map { "v\($0)" })
        return model
    }

    private struct Overlays: Equatable, CustomStringConvertible {
        var band: TranscriptBackdropView.Band?, bandFrame: CGRect, bandHidden: Bool
        var selection: [CGRect], selectionHidden: Bool
        var caret: CGRect, caretHidden: Bool
        var ruler: ClosedRange<Double>?
        var description: String { "band \(bandHidden ? "hidden" : "\(bandFrame)") selection \(selectionHidden ? "hidden" : "\(selection)") caret \(caretHidden ? "hidden" : "\(caret)") ruler \(ruler.map { "\($0)" } ?? "nil")" }
    }
    private func overlays(_ pane: TranscriptPane) throws -> Overlays {
        let text = pane.text
        let backdrop = try #require(text.backdrop), selection = try #require(text.selectionLayer), caret = try #require(text.caret)
        return Overlays(band: backdrop.band, bandFrame: backdrop.frame, bandHidden: backdrop.isHidden, selection: selection.rects, selectionHidden: selection.isHidden,
                        caret: caret.frame, caretHidden: caret.isHidden, ruler: pane.scroll.overviewRuler.visibleSpan)
    }
    /// The overlays as they are, and as they are measured again from the laid-out lines now.
    private func current(_ pane: TranscriptPane) throws -> (shown: Overlays, measured: Overlays) {
        let shown = try overlays(pane)
        pane.text.viewportDidLayout()
        return (shown, try overlays(pane))
    }
    /// What the window's display cycle does before drawing: its layout pass.
    private func layoutPass(_ pane: TranscriptPane) {
        pane.window.layoutIfNeeded()
    }
    /// As `updateNSView` renders an edit, without laying anything out.
    private func render(_ pane: TranscriptPane) {
        pane.coordinator.updating = true
        defer { pane.coordinator.updating = false }
        TranscriptTextView.render(pane.model, coordinator: pane.coordinator)
        pane.scroll.overviewRuler.marks = TranscriptOverviewRuler.marks(model: pane.model)
        TranscriptTextView.select(model: pane.model, in: pane.text)
    }
    /// Scrolls the clip view, as a scroll wheel does, so paragraph 13 starts 24 pt below the top.
    private func scrollToThirteen(_ pane: TranscriptPane) throws {
        let line = try #require(pane.text.lineBox(atCharacter: pane.renderer.paragraphs[13].offset))
        pane.scroll.contentView.scroll(to: NSPoint(x: 0, y: line.minY - 24))
        pane.scroll.reflectScrolledClipView(pane.scroll.contentView)
    }
    private func caretOffset(_ pane: TranscriptPane) throws -> Int { try #require(pane.renderer.caretOffset) }

    @Test func aScrollMovesTheBandSelectionCaretAndRulerWindow() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488)); defer { pane.close() }
        let top = try overlays(pane)
        #expect(top.bandHidden && top.selectionHidden && top.caretHidden, "the clip, the selection and the caret start below the viewport: \(top)")
        try scrollToThirteen(pane)
        layoutPass(pane)
        #expect(!pane.text.needsLayout, "updating the overlays asks for no second layout pass")
        let (shown, measured) = try current(pane)
        #expect(shown == measured, "after the layout pass: \(shown), measured again: \(measured)")
        let visible = pane.text.visibleRect
        #expect(!shown.bandHidden && shown.bandFrame.minY <= visible.minY && shown.bandFrame.maxY < visible.maxY, "the band runs from above the viewport, where paragraph 12 starts, to paragraph 16: \(shown)")
        #expect(!shown.selectionHidden && shown.selection.count == 2 && shown.selection.allSatisfy { visible.contains($0) }, "the selection's two lines: \(shown)")
        let caretBox = try #require(pane.text.textBox(of: NSRange(location: try caretOffset(pane), length: 0)))
        #expect(!shown.caretHidden && abs(shown.caret.midX - caretBox.minX) < 0.5 && visible.contains(shown.caret), "the caret at word 15: \(shown), \(caretBox)")
        // The top line is paragraph 12's last.
        let twelve = Double(12 * 20) * 0.5 / 402, thirteen = Double(13 * 20) * 0.5 / 402
        #expect(shown.ruler != top.ruler && shown.ruler.map { (twelve..<thirteen).contains($0.lowerBound) } == true, "the ruler's window starts in paragraph 12: \(shown)")
    }

    @Test func aCutThatRefoldsAParagraphMovesWhatFollowsItsLines() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488)); defer { pane.close() }
        try scrollToThirteen(pane)
        layoutPass(pane)
        let before = try overlays(pane)
        let lines = { (index: Int) in pane.text.lineBox(atCharacter: pane.renderer.paragraphs[index].offset) }
        let fourteen = try #require(lines(14))
        // Twelve words of paragraph 13 fold to one dot, so it reads on one line, not two.
        for index in (13 * 20 + 2)...(13 * 20 + 13) { model.apply(.toggle(id: "v\(index)"), name: "Cut") }
        render(pane)
        #expect(DebugTranscriptPixels.displayed(pane.text)[13].contains("word•word"), "paragraph 13 folds")
        layoutPass(pane)
        #expect(!pane.text.needsLayout)
        let moved = try #require(lines(14)).minY - fourteen.minY
        #expect(abs(moved + 26) < 0.5, "paragraph 14 moves up one line (\(moved))")
        let (shown, measured) = try current(pane)
        #expect(shown == measured, "after the layout pass: \(shown), measured again: \(measured)")
        #expect(abs(shown.caret.minY - before.caret.minY - moved) < 0.5 && !shown.caretHidden, "the caret moves with its line: \(before) → \(shown)")
        #expect(shown.selection.count == before.selection.count && zip(shown.selection, before.selection).allSatisfy { abs($0.minY - $1.minY - moved) < 0.5 }, "the selection moves with its lines: \(before) → \(shown)")
        let bandBottom = try #require(shown.band?.bottom), oldBottom = try #require(before.band?.bottom)
        #expect(abs(bandBottom - oldBottom - moved) < 0.5, "the band ends one line higher, after paragraph 16: \(before) → \(shown)")
        #expect(shown.ruler != before.ruler, "the ruler's window reaches further into the take: \(before) → \(shown)")
    }

    /// At the take's top, where TextKit keeps the scroll position as lines rewrap.
    @Test func aResizeRewrapsWhatFollowsTheLines() throws {
        let model = try editor(paragraph: 2); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488)); defer { pane.close() }
        let before = try overlays(pane)
        #expect(!before.bandHidden && !before.caretHidden && before.selection.count == 2, "\(before)")
        pane.window.setContentSize(NSSize(width: 820, height: 488))
        layoutPass(pane)
        // A legacy scroller (a Mac with a mouse, the hosted runner) takes its width from the pane.
        let width: CGFloat = pane.scroll.contentSize.width
        let measure: CGFloat = CGFloat(TranscriptNSTextView.measure(forPane: Double(width)))
        #expect(width > 800 && pane.text.bounds.width == width, "the text view takes the clip view's \(width)")
        #expect(pane.text.textContainer?.containerSize.width == measure, "the \(measure) measure at \(width)")
        #expect(!pane.text.needsLayout)
        let (shown, measured) = try current(pane)
        #expect(shown == measured, "after the layout pass: \(shown), measured again: \(measured)")
        #expect(pane.text.visibleRect.minY == 0, "still at the top")
        #expect(shown.bandFrame.width == width && !shown.bandHidden, "the band spans the wider pane: \(before) → \(shown)")
        // Word 15 moves from the second line to the first at 680 (679 beside a legacy scroller), where eighteen fit.
        let caretBox = try #require(pane.text.textBox(of: NSRange(location: try caretOffset(pane), length: 0)))
        #expect(!shown.caretHidden && abs(shown.caret.midX - caretBox.minX) < 0.5 && shown.caret.minY < before.caret.minY && shown.caret.midX > before.caret.midX,
                "the caret follows word 15 up to the first line: \(before) → \(shown)")
        #expect(shown.selection.count == 1 && !shown.selectionHidden, "the selection rewraps onto one line: \(before) → \(shown)")
        #expect(shown.ruler != before.ruler, "more of the take fits: \(before) → \(shown)")
    }

    /// Where a layout pass leaves the viewport short of the visible rect, measuring lays it
    /// out first rather than placing the overlays from the lines of before the scroll.
    @Test func measuringAfterAScrollWithoutALayoutPassLaysTheViewportOutFirst() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488)); defer { pane.close() }
        let controller = try #require(pane.text.textLayoutManager).textViewportLayoutController
        try scrollToThirteen(pane)
        let origin = pane.text.textContainerOrigin
        #expect(controller.viewportBounds.minY + origin.y < pane.text.visibleRect.minY - 100, "the viewport is still the top's")
        pane.text.viewportDidLayout()
        let caught = try overlays(pane)
        #expect(abs(controller.viewportBounds.minY + origin.y - pane.text.visibleRect.minY) < 1, "measuring laid the viewport out for the visible rect")
        layoutPass(pane)
        let (shown, _) = try current(pane)
        #expect(caught == shown && !caught.caretHidden && !caught.selectionHidden, "the same overlays as after the layout pass: \(caught) vs \(shown)")
    }

    /// The relay's call after a layout only places the overlays. Laying the viewport out again
    /// from there would start a layout inside a layout, and TextKit 2 does not stop that
    /// recursion where the viewport stays short of the visible rect.
    @Test func theRelaysCallAfterALayoutNeverLaysTheViewportOutAgain() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488)); defer { pane.close() }
        let controller = try #require(pane.text.textLayoutManager).textViewportLayoutController
        let relay = try #require(controller.delegate as? TranscriptViewportRelay)
        try scrollToThirteen(pane)
        let top = controller.viewportBounds
        #expect(top.minY + pane.text.textContainerOrigin.y < pane.text.visibleRect.minY - 100, "the viewport is still the top's")
        relay.textViewportLayoutControllerDidLayout(controller)
        #expect(controller.viewportBounds == top, "the relay laid nothing out: \(top) → \(controller.viewportBounds)")
    }
}
#endif
