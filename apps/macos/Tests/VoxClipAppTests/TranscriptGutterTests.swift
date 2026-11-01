#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The v2 transcript (impl-plan V6), headless: the measure and gutter geometry, display
/// paragraphs, out-of-clip styles, the scope restyle, the AI waveform's place at every zoom,
/// the overview ruler's marks and the Clips rotor. The DEBUG pixel checks
/// (DebugTranscriptPixels) draw the same pane.
@Suite("Transcript gutter, band and paragraphs", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are opened."))
@MainActor struct TranscriptGutterTests {
    /// Three speakers' paragraphs of 6, 4 and 5 words, a kept clip over the second paragraph
    /// and a suggested clip that starts inside the third.
    private func editor() throws -> EditorModel {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        let speakers = ["a", "a", "a", "a", "a", "a", "b", "b", "b", "b", "c", "c", "c", "c", "c"]
        project.transcript?.words = speakers.enumerated().map { index, speaker in
            TimedWord(id: "g\(index)", text: index == 5 || index == 9 ? "end." : "word", start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.3, speaker: speaker)
        }
        project.transcript?.durationSeconds = 8
        project.media.source.durationSeconds = 8
        project.edits = ProjectEdits()
        project.edits.clips = [ClipRange(id: "kept", startWordId: "g6", endWordId: "g9", title: "Second paragraph"),
                               ClipRange(id: "suggested", startWordId: "g12", endWordId: "g14", title: "Tail", origin: .ai, selected: false)]
        return EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
    }
    private func pane(_ model: EditorModel) throws -> (TranscriptNSTextView, TranscriptRenderer, TranscriptScrollView, TranscriptTextView.Coordinator) {
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let scroll = TranscriptTextView.makeScrollView(model: model, coordinator: coordinator, width: 652, height: 488)
        let text = try #require(scroll.documentView as? TranscriptNSTextView)
        coordinator.renderer.rebuild(model: model)
        coordinator.renderer.update(appearance(model))
        return (text, coordinator.renderer, scroll, coordinator)
    }
    private func appearance(_ model: EditorModel) -> TranscriptAppearance {
        TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, scope: model.scopeBounds, activeClipID: model.activeClip?.id, playhead: model.sourceTime)
    }
    private func color(_ renderer: TranscriptRenderer, _ id: String) -> NSColor? { renderer.attributes[id]?[.foregroundColor] as? NSColor }

    @Test func theMeasureLeavesTheGutterAndFortyFourPointsOfRightPadding() {
        #expect(TranscriptGutter.width == 80 && TranscriptGutter.trailing == 44)
        #expect(TranscriptNSTextView.measure(forPane: 652) == 528, "notes.md §1: the 652 buffer at 1280")
        #expect(TranscriptNSTextView.measure(forPane: 604) == 480, "impl-plan §3.5: the editor's 604 minimum")
        #expect(TranscriptNSTextView.measure(forPane: 772) == 648 && TranscriptNSTextView.measure(forPane: 1000) == 680)
        #expect(TranscriptNSTextView.measure(forPane: 500) == 420, "never wider than the pane after the gutter")
    }

    @Test func timecodesAreTakeTimeInMinutesAndSeconds() {
        #expect(TranscriptGutter.timecode(0) == "0:00" && TranscriptGutter.timecode(9.99) == "0:09")
        #expect(TranscriptGutter.timecode(65.9) == "1:05" && TranscriptGutter.timecode(3_725) == "62:05")
        #expect(TranscriptGutter.timecode(-1) == "0:00" && TranscriptGutter.timecode(.nan) == "0:00")
    }

    @Test func aScopeChangeRestylesOnlyTheWordsWhoseInClipStateChanged() {
        typealias Renderer = TranscriptRenderer
        #expect(Renderer.scopeDifference(nil, nil, count: 10).isEmpty)
        #expect(Renderer.scopeDifference(3...5, 3...5, count: 10).isEmpty)
        #expect(Renderer.scopeDifference(nil, 3...5, count: 10) == [0..<3, 6..<10], "Full Take to a clip: the words outside it")
        #expect(Renderer.scopeDifference(3...5, nil, count: 10) == [0..<3, 6..<10])
        #expect(Renderer.scopeDifference(3...5, 4...8, count: 10) == [3..<4, 6..<9], "a trim or an overlapping clip: the edges")
        #expect(Renderer.scopeDifference(5...6, 0...1, count: 10) == [0..<2, 5..<7], "neighbouring clips: both")
        #expect(Renderer.scopeDifference(nil, 0...9, count: 10).isEmpty && Renderer.scopeDifference(8...20, nil, count: 10) == [0..<8])
    }

    @Test func theTranscriptShowsTheTakesParagraphsAndNoClipMarkers() throws {
        let model = try editor(); defer { model.close() }
        let (text, renderer, _, _) = try pane(model)
        #expect(renderer.paragraphs.map(\.firstWord) == [0, 6, 10])
        #expect(renderer.paragraphs.map(\.start) == [0, 3, 5])
        #expect(text.string.components(separatedBy: "\n").count == 3)
        #expect(text.map.spans.allSatisfy { $0.selectable }, "no badge or bracket spans")
        #expect(renderer.clipMarks["kept"].map { (text.string as NSString).substring(with: $0.range) } == "word word word end.")
        #expect(renderer.clipMarks["suggested"]?.suggested == true && renderer.clipMarks["kept"]?.suggested == false)
        let clipped = text.string
        var project = model.project
        project.edits.clips = []
        model.document.replaceProject(project); model.refresh()
        renderer.rebuild(model: model)
        #expect(text.string == clipped, "clips never change the text, so paragraphs never reflow per clip")
        #expect(renderer.paragraph(atCharacter: 0) == 0 && renderer.paragraph(atCharacter: renderer.paragraphs[2].offset) == 2 && renderer.paragraph(atCharacter: renderer.paragraphs[2].offset - 1) == 1)
        #expect(renderer.paragraph(atTime: -1) == 0 && renderer.paragraph(atTime: 3.1) == 1 && renderer.paragraph(atTime: 100) == 2)
    }

    @Test func aLongMonologueLaysOutInParagraphsOfAtMost150Words() throws {
        let model = try editor(); defer { model.close() }
        var project = model.project
        project.transcript?.words = (0..<400).map { TimedWord(id: "m\($0)", text: $0 % 97 == 96 ? "word." : "word", start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.3, speaker: "solo") }
        project.edits = ProjectEdits()
        model.document.replaceProject(project); model.refresh()
        let (text, renderer, _, _) = try pane(model)
        #expect(renderer.paragraphs.map(\.firstWord) == [0, 97, 194, 291, 388], "a sentence end after 80 words breaks, before any 150-word cap")
        #expect(text.string.components(separatedBy: "\n").count == 5)
    }

    @Test func wordsOutsideTheOpenClipAreWordOutsideAndItsParagraphsAreInScope() throws {
        let model = try editor(); defer { model.close() }
        let (_, renderer, _, _) = try pane(model)
        #expect(color(renderer, "g0") === DesignValues.nsColor("word.text"), "Full Take: every word is in scope")
        #expect((0..<3).allSatisfy(renderer.isInScope(paragraph:)))
        model.activate(model.project.edits.clips[0])
        let before = renderer.scopeRestyles
        renderer.update(appearance(model))
        #expect(renderer.scopeRestyles - before == 11, "the eleven words outside the clip")
        #expect(color(renderer, "g0") === DesignValues.nsColor("word.outside") && color(renderer, "g14") === DesignValues.nsColor("word.outside"))
        #expect(color(renderer, "g6") === DesignValues.nsColor("word.text") && color(renderer, "g9") === DesignValues.nsColor("word.text"))
        #expect(!renderer.isInScope(paragraph: 0) && renderer.isInScope(paragraph: 1) && !renderer.isInScope(paragraph: 2))
        model.activate(model.project.edits.clips[1])
        let switched = renderer.scopeRestyles
        renderer.update(appearance(model))
        #expect(renderer.scopeRestyles - switched == 7, "the kept clip's four words and the suggestion's three")
        #expect(color(renderer, "g10") === DesignValues.nsColor("word.outside") && color(renderer, "g12") === DesignValues.nsColor("word.text"))
        #expect(renderer.isInScope(paragraph: 2), "a paragraph a clip starts inside is in scope")
    }

    @Test func thePlayheadsParagraphIsCurrentAndItsFragmentRedraws() throws {
        let model = try editor(); defer { model.close() }
        let (text, renderer, _, _) = try pane(model)
        #expect(renderer.currentParagraph == 0)
        model.sourceTime = 5.6
        renderer.update(appearance(model))
        #expect(renderer.currentParagraph == 2)
        let manager = try #require(text.textLayoutManager), content = try #require(manager.textContentManager)
        func redrawn(_ paragraph: Int) -> Bool {
            guard let location = content.location(content.documentRange.location, offsetBy: renderer.paragraphs[paragraph].offset) else { return false }
            var found = false
            manager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in found = attributes[.vcGutter] != nil; return false }
            return found
        }
        #expect(redrawn(0) && redrawn(2) && !redrawn(1), "a rendering attribute on the old and new paragraphs' first characters redraws their gutters")
    }

    /// Draws the layout fragment holding `character` as the text view does, onto black, and
    /// returns the rows of `line` (text view coordinates) with ai.tint ink at x 49–63.
    private func glyphInk(_ text: TranscriptNSTextView, atCharacter character: Int, line: CGRect) throws -> ClosedRange<CGFloat>? {
        let manager = try #require(text.textLayoutManager), content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: character))
        let fragment = try #require(manager.textLayoutFragment(for: location))
        let origin = text.textContainerOrigin, frame = fragment.layoutFragmentFrame
        let top = origin.y + frame.minY, width = 96, height = Int(frame.height.rounded(.up))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { fragment.draw(at: CGPoint(x: origin.x + frame.minX, y: 0), in: context) }
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let rows = (max(0, Int(line.minY - top))..<min(height, Int((line.maxY - top).rounded(.up)))).filter { row in
            (49...63).contains { column in
                let pixel = pixels + row * width * 4 + column * 4
                return Int(pixel[2]) - Int(pixel[0]) > 60
            }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return (CGFloat(first) + top)...(CGFloat(last + 1) + top)
    }

    @Test(arguments: [13.0, 15.0, 28.0]) func theAIWaveformIsCentredOnItsLineAtEveryTextSize(size: Double) throws {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        model.textSize = size; model.refresh()
        let (text, renderer, _, _) = try pane(model)
        let ai = try #require(text.map.spans.first { renderer.aiWordIDs.contains($0.id) })
        let line = try #require(text.lineBox(atCharacter: ai.range.location))
        #expect(abs(line.height - (size * 26 / 15).rounded()) < 0.5, "the line is \(line.height) high at \(size) pt")
        let ink = try #require(try glyphInk(text, atCharacter: ai.range.location, line: line), "the waveform draws on the AI line")
        let centre = (ink.lowerBound + ink.upperBound) / 2
        #expect(abs(centre - line.midY) <= 1, "the waveform's ink centre \(centre) sits on the line's centre \(line.midY) at \(size) pt")
        #expect(TranscriptGutter.glyphBox(left: 0, line: line) == CGRect(x: 49, y: line.midY - 7, width: 14, height: 14))
    }

    @Test func theOverviewRulerMarksTheClipTheSelectionAndAIWordsByTakeTime() throws {
        let model = try editor(); defer { model.close() }
        #expect(TranscriptOverviewRuler.marks(model: model).isEmpty)
        model.activate(model.project.edits.clips[0])
        model.selectedWordIDs = ["g11", "g13"]
        let marks = TranscriptOverviewRuler.marks(model: model)
        let clip = TranscriptOverviewRuler.Mark(kind: .clip, lower: 3.0 / 8, upper: 4.8 / 8)
        let selection = TranscriptOverviewRuler.Mark(kind: .selection, lower: 5.5 / 8, upper: 6.8 / 8)
        #expect(marks == [clip, selection])
        let ai: [TranscriptOverviewRuler.Mark] = [.init(kind: .ai, lower: 0.1, upper: 0.1), .init(kind: .ai, lower: 0.5, upper: 0.6), .init(kind: .ai, lower: 0.605, upper: 0.7), .init(kind: .clip, lower: 0, upper: 1)]
        let rows = TranscriptOverviewRuler.rows(ai, kind: .ai, height: 108)
        #expect(rows == [14...16, 54...74], "at least 2 pt tall, and marks less than a point apart merge")
        #expect(TranscriptOverviewRuler.rows(marks, kind: .clip, height: 108) == [41.5...64])
    }

    @Test func theOverviewRulerSitsAtTheRightEdgeAndPassesClicksOn() throws {
        let model = try editor(); defer { model.close() }
        let (_, _, scroll, _) = try pane(model)
        scroll.tile()
        let ruler = scroll.overviewRuler
        // Overlay scrollers draw over the ruler 2 pt from the edge; a legacy scroller keeps it to its left.
        let legacy = scroll.scrollerStyle == .legacy && scroll.verticalScroller?.isHidden == false
        let right = legacy ? (scroll.verticalScroller?.frame.minX ?? 652) : 652
        #expect(ruler.superview === scroll && ruler.frame == NSRect(x: right - 12, y: 0, width: 10, height: 488))
        if let scroller = scroll.verticalScroller, let index = scroll.subviews.firstIndex(of: scroller) {
            #expect(scroll.subviews.firstIndex(of: ruler).map { $0 < index } == true, "the scroller draws over the ruler")
        }
        #expect(ruler.hitTest(NSPoint(x: 645, y: 100)) == nil && !ruler.isAccessibilityElement())
    }

    @Test func theClipsRotorNamesEachClipAsTheExplorerDoes() throws {
        let model = try editor(); defer { model.close() }
        let (text, _, _, _) = try pane(model)
        let rotor = NSAccessibilityCustomRotor(label: "Clips", itemSearchDelegate: text)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        var labels: [String] = []
        while labels.count < 4, let item = text.rotor(rotor, resultFor: parameters) {
            labels.append(item.customLabel ?? "")
            parameters.currentItem = item
        }
        #expect(labels == ["Clip 1, Second paragraph", "Suggested clip 2, Tail"])
        #expect(text.accessibilityValue() == text.string && !text.string.contains("0:0"), "timecodes are drawn, never read as words")
    }
}
#endif
