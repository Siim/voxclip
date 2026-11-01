import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Transcript II (impl-plan V8b), headless: folds, the filler-comma rule, Show cuts, the
/// outside-clip rule, the selection, the caret, opening and restoring a fold, and how a fold
/// reads. The fold scene (DebugTranscriptPixels.folds) draws the same take offscreen and
/// checks its pixels; the last test runs it.
@Suite("Transcript folds, Show cuts, selection and caret", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are shown."))
@MainActor struct TranscriptFoldTests {
    private func fixture() throws -> Project {
        let shared = try SharedResources.locate()
        return try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
    }
    /// The mockup's two Clip 1 paragraphs: fillers and pauses cut (DebugTranscriptPixels.foldProject).
    private func editor() throws -> EditorModel {
        EditorModel(document: VoxClipDocument(project: DebugTranscriptPixels.foldProject(from: try fixture()), demo: true), app: AppModel(), preview: DemoPreviewEngine())
    }
    private func pane(_ model: EditorModel) throws -> (TranscriptNSTextView, TranscriptRenderer, TranscriptTextView.Coordinator) {
        let coordinator = TranscriptTextView.Coordinator(model: model)
        let scroll = TranscriptTextView.makeScrollView(model: model, coordinator: coordinator, width: 652, height: 488)
        let text = try #require(scroll.documentView as? TranscriptNSTextView)
        render(model, coordinator.renderer)
        return (text, coordinator.renderer, coordinator)
    }
    /// As updateNSView renders: the text and its selection changes are the model's, not the user's.
    private func render(_ model: EditorModel, _ renderer: TranscriptRenderer) {
        let coordinator = renderer.text?.delegate as? TranscriptTextView.Coordinator
        coordinator?.updating = true
        defer { coordinator?.updating = false }
        renderer.rebuild(model: model)
        renderer.update(TranscriptAppearance(cutWords: model.cutWordIDs, cutPauses: model.cutPauseIDs, scope: model.scopeBounds, activeClipID: model.activeClip?.id, playhead: model.sourceTime))
        if let manager = renderer.text?.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
    }
    private func id(_ model: EditorModel, _ index: Int) -> String { model.words[index].id }

    @Test func eachRunOfRemovalsIsOneFoldGluedToTheWordBeforeIt() throws {
        let model = try editor(); defer { model.close() }
        let (text, _, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(DebugTranscriptPixels.displayed(text) == ["So•while you're speaking,•it•examines your•app, makes videos, and adds clip in between your speech.",
                                                          "And one cool feature I added is when you want to represent your project, you include•source directory."])
        let folds = text.map.spans.filter { $0.kind == .fold }
        #expect(folds.count == 5 && folds.allSatisfy { !$0.selectable })
        // A run reaches over its pauses: "your, {1.0} uh, {0.8} app" is one fold of three.
        #expect(text.map.span(id: "pause-after-\(id(model, 8))")?.ids == ["pause-after-\(id(model, 8))", id(model, 9), "pause-after-\(id(model, 9))"])
        // No space surrounds a fold: the word before it ends at the joiner and the next word starts after the break.
        let string = text.string as NSString
        for fold in folds {
            #expect(string.substring(with: fold.range) == TranscriptFold.text)
            #expect(fold.range.location == 0 || string.character(at: fold.range.location - 1) != 0x20)
            #expect(NSMaxRange(fold.range) == string.length || string.character(at: NSMaxRange(fold.range)) != 0x20)
        }
    }

    @Test func aCommaThatOnlyExistsForAFillerFoldsWithIt() throws {
        let model = try editor(); defer { model.close() }
        let (text, _, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let lines = DebugTranscriptPixels.displayed(text)
        #expect(lines[1].contains("include•source"), "include, uh, um, source")
        #expect(lines[0].contains("speaking,•it"), "a fold of a pause alone keeps the comma")
        #expect(lines[0].hasPrefix("So•while") && lines[0].contains("it•examines your•app,"))
        // The transcript keeps the comma: only the display drops it.
        #expect(model.words[0].text == "So," && model.text(model.words[35]) == "include,")
    }

    @Test func showCutsOpensEveryFoldWithStruckWordsPauseLengthsAndGreyCommas() throws {
        let model = try editor(); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let rebuilds = renderer.documentRebuilds
        model.toggleShowsCuts()
        render(model, renderer)
        #expect(renderer.documentRebuilds == rebuilds + 1, "Show cuts writes the document once")
        #expect(DebugTranscriptPixels.displayed(text)[0] == "So, 1.4\u{00A0}s uh, while you're speaking, 0.9\u{00A0}s it, uh, 1.2\u{00A0}s examines your, 1.0\u{00A0}s uh, 0.8\u{00A0}s app, makes videos, and adds clip in between your speech.")
        let gone = DesignValues.nsColor("word.gone")
        #expect(renderer.attributes[id(model, 1)]?[.vcStrike] as? Bool == true && renderer.attributes[id(model, 1)]?[.foregroundColor] as? NSColor === gone, "a removed word is struck in word.gone")
        #expect(renderer.attributes["comma:\(id(model, 0))"]?[.foregroundColor] as? NSColor === gone && renderer.attributes["comma:\(id(model, 0))"]?[.vcStrike] == nil, "a folded comma is word.gone, unstruck")
        #expect(renderer.attributes["pause-after-\(id(model, 0))"]?[.foregroundColor] as? NSColor === gone && renderer.attributes["pause-after-\(id(model, 0))"]?[.vcStrike] == nil, "a pause length is word.gone, unstruck")
        #expect(text.map.span(id: "pause-after-\(id(model, 0))").map { (text.string as NSString).substring(with: $0.range) } == "1.4\u{00A0}s")
        #expect(renderer.attributes[id(model, 3)]?[.vcStrike] as? Bool == false && renderer.attributes[id(model, 3)]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.text"))
        // A removed word is selectable under Show cuts, so ⇧⌫ restores it.
        #expect(text.map.span(id: id(model, 1))?.selectable == true)
        model.toggleShowsCuts()
        render(model, renderer)
        #expect(text.map.spans.filter { $0.kind == .fold }.count == 5)
    }

    @Test func outsideTheOpenClipWordsReadAsSaidWithNoFoldsStrikesOrPauses() throws {
        let model = try editor(); defer { model.close() }
        var project = model.project
        project.edits.clips = [ClipRange(id: "second", startWordId: id(model, 20), endWordId: id(model, model.words.count - 1), title: "Second")]
        model.document.replaceProject(project); model.refresh()
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        model.activate(model.project.edits.clips[0])
        render(model, renderer)
        let lines = DebugTranscriptPixels.displayed(text)
        #expect(lines[0] == "So, uh, while you're speaking, it, uh, examines your, uh, app, makes videos, and adds clip in between your speech.")
        #expect(lines[1].contains("include•source"))
        #expect(!text.map.spans(inParagraph: 0).contains { $0.kind != .text || $0.pause })
        #expect(renderer.attributes[id(model, 1)]?[.vcStrike] as? Bool == false && renderer.attributes[id(model, 1)]?[.foregroundColor] as? NSColor === DesignValues.nsColor("word.outside"))
        // Show Pauses shows uncut pauses in the open clip only.
        model.showPauses = true
        render(model, renderer)
        #expect(!text.map.spans(inParagraph: 0).contains { $0.pause })
    }

    @Test func aClickOpensOneFoldAndSelectsItsWordsUntilTheSelectionLeaves() throws {
        let model = try editor(); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let fold = try #require(text.map.span(id: id(model, 6)))
        model.expandFold(fold.ids)
        render(model, renderer)
        #expect(DebugTranscriptPixels.displayed(text)[0] == "So•while you're speaking,•it, uh, 1.2\u{00A0}s examines your•app, makes videos, and adds clip in between your speech.")
        #expect(model.selectedWordIDs == [id(model, 6)] && model.selectedPauseIDs == ["pause-after-\(id(model, 6))"])
        // Selecting inside it keeps it open; selecting elsewhere folds it again.
        model.selectedPauseIDs = []
        render(model, renderer)
        #expect(text.map.span(id: id(model, 6))?.kind == .text && model.openFoldEnds == [id(model, 6)])
        model.select(id(model, 3))
        #expect(model.openFoldEnds.isEmpty)
        render(model, renderer)
        #expect(text.map.span(id: id(model, 6))?.kind == .fold)
    }

    @Test func restoringAFoldIsOneUndoStep() throws {
        let model = try editor(); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let fold = try #require(text.map.span(id: "pause-after-\(id(model, 8))"))
        undo.beginUndoGrouping(); model.restoreFold(fold.ids); undo.endUndoGrouping()
        render(model, renderer)
        #expect(undo.undoActionName == "Restore cut" && !model.cutWordIDs.contains(id(model, 9)) && model.cutPauseIDs.isDisjoint(with: fold.ids))
        #expect(DebugTranscriptPixels.displayed(text)[0].contains("examines your, 1.0\u{00A0}s uh,") == false && DebugTranscriptPixels.displayed(text)[0].contains("examines your, uh, app,"))
        undo.undo()
        render(model, renderer)
        #expect(text.map.span(id: id(model, 9))?.kind == .fold && !undo.canUndo)
    }

    @Test func aFoldReadsWhatItRemovedAndTheCutsRotorLandsOnIt() throws {
        let model = try editor(); defer { model.close() }
        let (text, _, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let fold = try #require(text.map.span(id: id(model, 6)))
        #expect(text.spoken(fold) == "1 cut: uh, pause 1.2 seconds")
        #expect(text.accessibilityString(for: fold.range) == "1 cut: uh, pause 1.2 seconds")
        #expect(text.accessibilityValue()?.contains(TranscriptFold.glyph) == false, "the fold's characters read as spaces in the value")
        let rotor = NSAccessibilityCustomRotor(label: "Cuts", itemSearchDelegate: text)
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        var labels: [String] = []
        while labels.count < 8, let item = text.rotor(rotor, resultFor: parameters) {
            labels.append(item.customLabel ?? "")
            #expect(text.map.intersecting(item.targetRange).first?.kind == .fold)
            parameters.currentItem = item
        }
        #expect(labels == ["1 cut: pause 1.4 seconds, uh, Cuts", "1 cut: pause 0.9 seconds, Cuts", "1 cut: uh, pause 1.2 seconds, Cuts",
                           "1 cut: pause 1.0 seconds, uh, pause 0.8 seconds, Cuts", "1 cut: uh, pause 1.0 seconds, um, Cuts"])
    }

    @Test func aSelectionAcrossAFoldSelectsTheWordsAroundItAndWhatItHolds() throws {
        let model = try editor(); defer { model.close() }
        let (text, _, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let so = try #require(text.map.span(id: id(model, 0))), whilst = try #require(text.map.span(id: id(model, 2)))
        text.setSelectedRange(NSRange(location: so.range.location, length: NSMaxRange(whilst.range) - so.range.location))
        #expect(model.selectedWordIDs == [id(model, 0), id(model, 1), id(model, 2)] && model.selectedPauseIDs == ["pause-after-\(id(model, 0))"])
        #expect(model.openFoldEnds.isEmpty, "the fold between the ends stays folded")
        // A click on a fold's characters selects the nearest word, never the fold.
        let fold = try #require(text.map.span(id: id(model, 1)))
        text.setSelectedRange(NSRange(location: fold.range.location + 1, length: 0))
        #expect(model.selectedWordIDs.count == 1 && !model.selectedWordIDs.contains(id(model, 1)))
    }

    @Test func thePlayheadMovesTheCaretAndRestylesNoSpan() throws {
        let model = try editor(); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let applied = renderer.attributeUpdates, styled = renderer.rebuildStyles, scoped = renderer.scopeRestyles
        var offsets: [Int?] = []
        for index in [3, 4, 5, 10] {
            model.sourceTime = model.words[index].start + 0.1
            render(model, renderer)
            offsets.append(renderer.caretOffset)
        }
        #expect(offsets == [3, 4, 5, 10].map { text.map.span(id: id(model, $0))?.range.location })
        #expect(renderer.attributeUpdates == applied && renderer.rebuildStyles == styled && renderer.scopeRestyles == scoped, "a tick restyles no span")
        // In a removed word or a cut pause the caret stands at the fold; in a gap, at the next word.
        model.sourceTime = model.words[1].start + 0.1
        render(model, renderer)
        #expect(renderer.caretOffset == text.map.span(id: id(model, 1))?.range.location)
        model.sourceTime = model.words[3].end + 0.05
        render(model, renderer)
        #expect(renderer.caretOffset == text.map.span(id: id(model, 4))?.range.location)
        model.sourceTime = 1_000
        render(model, renderer)
        #expect(renderer.caretOffset == text.map.span(id: model.words.last?.id ?? "").map { NSMaxRange($0.range) })
    }

    @Test func noLineStartsWithAFoldAtThreeMeasures() throws {
        let model = try editor(); defer { model.close() }
        // Many short words with a fold after every third, so lines break near folds.
        var project = model.project
        let words = (0..<240).map { index in TimedWord(id: "glue-\(index)", text: ["So", "while", "you're", "speaking,", "examines", "your", "app,"][index % 7], start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.3, speaker: "s") }
        project.transcript?.words = words
        project.edits = ProjectEdits(cutWordIds: words.indices.filter { $0 % 3 == 2 }.map { words[$0].id })
        model.document.replaceProject(project); model.refresh()
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        let manager = try #require(text.textLayoutManager), content = try #require(manager.textContentManager)
        for width in [480.0, 528.0, 648.0] {
            text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            manager.ensureLayout(for: manager.documentRange)
            var lines = 0, foldStarts = 0
            manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
                guard let element = fragment.textElement?.elementRange else { return false }
                let base = content.offset(from: content.documentRange.location, to: element.location)
                for line in fragment.textLineFragments {
                    lines += 1
                    let start = base + line.characterRange.location
                    // A paragraph whose first word is removed starts with its fold: there is no word before it.
                    let leadsParagraph = line.characterRange.location == 0 && model.cutWordIDs.contains(model.words[renderer.paragraphs[renderer.paragraph(atCharacter: base) ?? 0].firstWord].id)
                    if !leadsParagraph, text.map.intersecting(NSRange(location: start, length: 1)).contains(where: { $0.kind == .fold && NSLocationInRange(start, $0.range) }) { foldStarts += 1 }
                }
                return true
            }
            #expect(lines > 10 && foldStarts == 0, "at \(width): \(foldStarts) of \(lines) lines start with a fold")
        }
        // The fold is 13 pt: from the end of the word before to the start of the word after.
        let fold = try #require(text.map.spans.first { $0.kind == .fold })
        let paragraph = try #require(renderer.paragraph(atCharacter: fold.range.location))
        let base = renderer.paragraphs[paragraph].offset
        var gap: CGFloat?
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(fold.range.location - base, $0.characterRange) && NSLocationInRange(NSMaxRange(fold.range) - base, $0.characterRange) }) else { return true }
            gap = text.glyphX(line, local: NSMaxRange(fold.range) - base) - line.locationForCharacter(at: fold.range.location - base).x
            return false
        }
        #expect(gap.map { abs($0 - 13) < 0.01 } == true, "the fold replaces the word space with 13 pt (\(gap ?? 0))")
    }

    @Test func theTranscriptDrawsNoNativeSelectionAndTheSelectionIsTheTextsHeight() throws {
        let model = try editor(); defer { model.close() }
        let (text, renderer, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(text.selectedTextAttributes.isEmpty)
        model.selectedWordIDs = [id(model, 3), id(model, 4), id(model, 5)]
        coordinator.updating = true
        TranscriptTextView.select(model: model, in: text)
        coordinator.updating = false
        let rects = text.selectionRects()
        let font = renderer.font
        #expect(rects.count == 1 && rects.allSatisfy { abs($0.height - (font.ascender - font.descender)) < 0.01 })
        let first = try #require(text.map.span(id: id(model, 3))), box = try #require(text.lineBox(atCharacter: first.range.location))
        #expect(rects.first.map { $0.minY > box.minY + 2 && $0.maxY < box.maxY - 2 } == true, "inside the 26 pt line, with its leading left out")
        model.selectedWordIDs = []
        coordinator.updating = true
        TranscriptTextView.select(model: model, in: text)
        coordinator.updating = false
        #expect(text.selectionRects().isEmpty)
    }

    // MARK: Review fixes

    /// The pane as the editor renders it (`TranscriptTextView.render` and `select`), in a
    /// window that is never shown.
    private func shown(_ model: EditorModel, height: CGFloat = 488) throws -> TranscriptPane {
        try TranscriptPane(model: model, size: NSSize(width: 652, height: height))
    }

    @Test func aDragAcrossAFoldHoldsItsWordsAndPausesAsShiftArrowsDo() throws {
        let model = try editor(); defer { model.close() }
        let pane = try shown(model); defer { pane.close() }
        let text = pane.text
        let include = try #require(text.map.span(id: id(model, 35))), source = try #require(text.map.span(id: id(model, 38)))
        let fold = try #require(text.map.span(id: id(model, 36)))
        text.setSelectedRange(NSRange(location: include.range.location, length: NSMaxRange(source.range) - include.range.location))
        let words = Set((35...38).map { id(model, $0) }), pauses: Set = ["pause-after-\(id(model, 36))"]
        #expect(model.selectedWordIDs == words && model.selectedPauseIDs == pauses, "a drag across include•source holds uh, um and the pause between them")
        pane.update()
        #expect(DebugTranscriptPixels.displayed(text)[1].contains("include•source"), "a fold between the selection's ends stays folded")
        let rects = text.selectionRects(), box = try #require(text.foldBox(fold))
        #expect(rects.count == 1 && rects.first.map { $0.minX < box.minX && $0.maxX > box.maxX } == true, "the tint runs over the fold")
        // ⇧→ three times from include selects the same words and pauses.
        model.select(id(model, 35))
        for _ in 0..<3 { model.step(1, extend: true) }
        #expect(model.selectedWordIDs == words && model.selectedPauseIDs == pauses)
        // ⇧⌫ after the drag restores what the fold held, as its popover's Restore does.
        text.setSelectedRange(NSRange(location: include.range.location, length: NSMaxRange(source.range) - include.range.location))
        model.cutSelection(restore: true)
        #expect(model.cutWordIDs.isDisjoint(with: words) && model.cutPauseIDs.isDisjoint(with: pauses))
    }

    @Test func theFoldTheSelectionEndsInOpensSoTheSelectionShows() throws {
        let model = try editor(); defer { model.close() }
        let pane = try shown(model); defer { pane.close() }
        let text = pane.text
        func shows(_ index: Int) -> Bool { text.map.span(id: id(model, index))?.kind == .text }
        func tinted(_ index: Int) -> Bool {
            guard let span = text.map.span(id: id(model, index)), span.selectable else { return false }
            return text.selectedRanges.map(\.rangeValue) == [span.range] && text.selectionRects().count == 1
        }
        // → from include onto the cut uh opens its fold and tints uh.
        model.select(id(model, 35)); pane.update()
        model.step(1); pane.update()
        #expect(model.selectedWordIDs == [id(model, 36)] && tinted(36))
        #expect(DebugTranscriptPixels.displayed(text)[1].contains("include, uh, 1.0\u{00A0}s um, source"), "\(DebugTranscriptPixels.displayed(text)[1])")
        model.step(1); pane.update()
        #expect(model.selectedWordIDs == [id(model, 37)] && tinted(37))
        // Onto the kept word after it, the fold closes.
        model.step(1); pane.update()
        #expect(model.selectedWordIDs == [id(model, 38)] && tinted(38) && !shows(36) && DebugTranscriptPixels.displayed(text)[1].contains("include•source"))
        // Find Next on a cut filler opens its fold.
        model.query = "um"; model.findNext(); pane.update()
        #expect(model.selectedWordIDs == [id(model, 37)] && tinted(37))
        model.query = ""
        // Delete cuts the word, which stays in view, struck, while it is selected: a second Delete visibly restores it.
        model.select(id(model, 11)); pane.update()
        model.toggleSelectionCut(); pane.update()
        #expect(model.cutWordIDs.contains(id(model, 11)) && model.selectedWordIDs == [id(model, 11)] && tinted(11))
        #expect(pane.renderer.attributes[id(model, 11)]?[.vcStrike] as? Bool == true)
        model.toggleSelectionCut(); pane.update()
        #expect(!model.cutWordIDs.contains(id(model, 11)) && tinted(11))
        // Once the selection moves on, the cut word folds.
        model.toggleSelectionCut(); model.select(id(model, 12)); pane.update()
        #expect(text.map.span(id: id(model, 11))?.kind == .fold && DebugTranscriptPixels.displayed(text)[0].contains("app,•videos,") && tinted(12))
    }

    @Test func aRunOfRemovalsIsOneFoldAcrossAnotherClipsEdge() throws {
        let model = try editor(); defer { model.close() }
        var project = model.project
        project.edits.clips = [ClipRange(id: "starts-in-a-fold", startWordId: id(model, 9), endWordId: id(model, 19), title: "A"),
                               ClipRange(id: "ends-in-a-fold", startWordId: id(model, 20), endWordId: id(model, 36), title: "B")]
        model.document.replaceProject(project); model.refresh()
        let (text, _, coordinator) = try pane(model)
        defer { withExtendedLifetime(coordinator) {} }
        #expect(DebugTranscriptPixels.displayed(text) == ["So•while you're speaking,•it•examines your•app, makes videos, and adds clip in between your speech.",
                                                          "And one cool feature I added is when you want to represent your project, you include•source directory."])
        #expect(text.map.span(id: id(model, 9))?.ids == ["pause-after-\(id(model, 8))", id(model, 9), "pause-after-\(id(model, 9))"])
        #expect(text.map.span(id: id(model, 36))?.ids == [id(model, 36), "pause-after-\(id(model, 36))", id(model, 37)])
    }

    @Test func theFoldScenePassesEveryCheck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-v8b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try DebugTranscriptPixels.folds(app: AppModel(), fixture: try fixture(), directory: directory)
        #expect(results.count > 20)
        for result in results where !result.passed { Issue.record("\(result.name)") }
    }
}
