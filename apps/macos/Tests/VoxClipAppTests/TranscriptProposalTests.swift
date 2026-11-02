#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Inline diff hunks (impl-plan V14), headless: a Rewrite proposal's changes in the
/// transcript, the inserted runs in the range map, Keep, Undo and Keep All (item 7), the keys,
/// the marker budget, the edit popover's local rediff, and C2's hunks from a canned reply. The
/// proposal scene (DebugTranscriptPixels.proposal) draws f3's changes offscreen and checks their
/// pixels and buttons; one test runs it.
@Suite("Transcript proposal hunks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are shown."), .offlineFixtures)
@MainActor struct TranscriptProposalTests {
    private func fixture() throws -> Project {
        let shared = try SharedResources.locate()
        return try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
    }
    /// f3's Clip 1 with its five changes, change 1 focused.
    private func editor() throws -> EditorModel {
        let model = EditorModel(document: VoxClipDocument(project: DebugTranscriptPixels.proposalProject(from: try fixture()), demo: true), app: AppModel(), preview: DemoPreviewEngine())
        model.mediaResolved = true; model.refresh()
        model.activate(model.project.edits.clips[0])
        model.proposal = DebugTranscriptPixels.proposal(for: model)
        return model
    }
    private func id(_ model: EditorModel, _ index: Int) -> String { model.words[index].id }
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func aVoicePartsNewWordsStandAroundItsBridgesAndAFixGroupsItsChangedWords() {
        let texts = ["a": "source", "b": "directory", "c": "to,", "d": "to", "e": "the", "f": "cloud", "g": "code", "h": "here"]
        let voice = TranscriptChange.Part(kind: .voice, sourceWordIDs: ["a", "b", "c", "d", "e"], newTokens: ["your", "source", "directory", "in", "the"], bridgeWordIDs: ["a", "b"])
        #expect(TranscriptChangeSegment.segments(voice) { texts[$0] ?? "" } == [.new("your"), .kept("a"), .kept("b"), .old("c"), .old("d"), .old("e"), .new("in the")])
        let fix = TranscriptChange.Part(kind: .textOnly, sourceWordIDs: ["f", "g", "h"], newTokens: ["Claude", "Code", "here"], correctedTexts: ["Claude", "Code", "here"])
        #expect(TranscriptChangeSegment.segments(fix) { texts[$0] ?? "" } == [.old("f"), .old("g"), .new("Claude Code"), .kept("h")])
        let cut = TranscriptChange.Part(kind: .cut, sourceWordIDs: ["c", "d"])
        #expect(TranscriptChangeSegment.segments(cut) { texts[$0] ?? "" } == [.old("c"), .old("d")])
        // A bridge whose words the new tokens do not hold is removed, and the words follow.
        let unmatched = TranscriptChange.Part(kind: .voice, sourceWordIDs: ["a", "b"], newTokens: ["new", "words"], bridgeWordIDs: ["a"])
        #expect(TranscriptChangeSegment.segments(unmatched) { texts[$0] ?? "" } == [.old("a"), .old("b"), .new("new words")])
    }

    @Test func theProposalScenePassesEveryCheck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-v14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try DebugTranscriptPixels.proposal(app: AppModel(), fixture: try fixture(), directory: directory)
        #expect(results.count > 20)
        for result in results where !result.passed { Issue.record("\(result.name)") }
    }

    /// The 30-change performance scene's structure (its time budgets hold in the profile build only).
    @Test func thirtyChangesWriteOnlyTheirParagraphs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-v14-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try DebugTranscriptPerformance.proposal(app: AppModel(), fixture: try fixture(), directory: directory)
        #expect(results.count == 6)
        for result in results where !result.passed { Issue.record("\(result.name)") }
    }

    @Test func aProposalShowsOnlyInItsOwnTab() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        #expect(pane.text.map.spans.contains { $0.kind == .inserted })
        model.activate(nil)
        pane.update()
        #expect(model.proposalDisplay == nil && !pane.text.map.spans.contains { $0.change != nil } && pane.text.proposalLayer?.isHidden == true)
        #expect(!model.hasUnreviewedChanges(clipID: nil) && model.hasUnreviewedChanges(clipID: "hunk-clip"), "the clip's tab keeps its dirty dot")
    }

    @Test func contextTogglePreservesPendingProposalAndItsInsertedMappings() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let original = model.project, steps = model.undoSteps
        let focused = model.proposalDisplay?.focused
        let inserted = pane.text.map.spans.filter { $0.kind == .inserted }.map(\.id)
        #expect(!model.showsSurroundingContext && !inserted.isEmpty)
        for showsContext in [true, false] {
            model.showsSurroundingContext = showsContext
            pane.update()
            #expect(model.proposalDisplay?.focused == focused)
            #expect(pane.text.map.spans.filter { $0.kind == .inserted }.map(\.id) == inserted)
            #expect(pane.text.map.spans.filter { $0.kind == .inserted }.allSatisfy { !$0.selectable && $0.ids.isEmpty })
            #expect(Set(pane.renderer.attributes.keys) == Set(pane.text.map.spans.map(\.id)))
            #expect(model.project == original && model.undoSteps == steps)
        }
    }

    @Test func theKeysWalkKeepAndUndoTheFocusedChange() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        defer { model.undoManager = nil }
        let text = pane.text
        text.keyDown(with: key(125, .option))
        #expect(model.proposalDisplay?.focused == 2, "⌥↓ walks to the next change")
        text.keyDown(with: key(126, .option))
        text.keyDown(with: key(126, .option))
        #expect(model.proposalDisplay?.focused == 1, "⌥↑ stops at the first")
        #expect(model.announcements.last == "Proposed change 1 of 5: removed to, to the; inserted your, in the")
        text.keyDown(with: key(51, .command))
        #expect(model.proposal?[1]?.state == .excluded && model.proposalDisplay?.focused == 2 && !undo.canUndo, "⌘⌫ leaves it out and moves on")
        model.focusChange(3)
        undo.beginUndoGrouping()
        text.keyDown(with: key(36, .command))
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Keep change 3" && model.proposalDisplay?.shown(3) == nil && model.proposalDisplay?.focused == 4, "⌘↩ keeps a cut as one step")
        // Return on the focused change with nothing selected opens its edit popover.
        model.selectedWordIDs = []
        pane.update()
        text.keyDown(with: key(36, [], "\r"))
        #expect(text.popoverChange == 4 && model.correctionID == nil)
        text.hideChangePopover(refocus: false)
        // Return on a word outside every change still corrects it.
        model.selectedWordIDs = [id(model, 40)]
        text.keyDown(with: key(36, [], "\r"))
        #expect(text.popoverChange == nil && model.correctionID == id(model, 40))
    }

    /// A click leaves a word selected almost always; walking the changes lets it go, so Return
    /// edits the change walked to, not the word (design.md §6.3.5).
    @Test func returnAfterWalkingEditsTheFocusedChangeNotAWordLeftSelected() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let text = pane.text
        model.selectedWordIDs = [id(model, 40)]
        pane.update()
        text.keyDown(with: key(125, .option))
        text.keyDown(with: key(125, .option))
        #expect(model.proposalDisplay?.focused == 3 && model.selectedWordIDs.isEmpty, "⌥↓ lets go of a word outside the change")
        pane.update()
        text.keyDown(with: key(36, [], "\r"))
        #expect(text.popoverChange == 3 && model.correctionID == nil, "Return edits the change walked to")
        text.hideChangePopover(refocus: false)
        // A selection inside the change walked to stays.
        model.selectedWordIDs = [id(model, 61)]
        pane.update()
        text.keyDown(with: key(126, .option))
        #expect(model.proposalDisplay?.focused == 2 && model.selectedWordIDs == [id(model, 61)])
        // The rotor's focus lets go of a word outside its change too.
        model.selectedWordIDs = [id(model, 40)]
        pane.update()
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        _ = text.rotor(NSAccessibilityCustomRotor(label: "Proposed changes", itemSearchDelegate: text), resultFor: parameters)
        #expect(model.proposalDisplay?.focused == 1 && model.selectedWordIDs.isEmpty)
        // A selection over several changes, as a Rewrite's scope is, edits the focused one.
        model.selectedWordIDs = Set((32...61).map { id(model, $0) })
        pane.update()
        text.keyDown(with: key(36, [], "\r"))
        #expect(text.popoverChange == 1 && model.correctionID == nil)
        text.hideChangePopover(refocus: false)
    }

    /// F2 on a focused change scrolled out of view brings it and its popover into view, so the
    /// field that takes the keys is never off screen.
    @Test func editingAChangeOutOfViewBringsItAndItsPopoverIntoView() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 240))
        defer { pane.close() }
        let text = pane.text
        pane.scroll(toCharacter: (text.string as NSString).length - 1)
        let range = try #require(pane.renderer.changeRange(1))
        let line = try #require(text.lineBox(atCharacter: range.location))
        #expect(!text.visibleRect.intersects(line), "change 1 starts out of view")
        text.keyDown(with: key(120))
        let popover = try #require(text.changePopoverAuditView)
        let shown = try #require(text.lineBox(atCharacter: range.location))
        #expect(text.popoverChange == 1 && text.visibleRect.contains(popover.frame) && text.visibleRect.intersects(shown), "\(popover.frame) in \(text.visibleRect)")
        text.hideChangePopover(refocus: false)
    }

    /// notes.md §5: after Keep the change is gone like a commit. Restoring its words or
    /// correcting them again never brings it back, and Keep All never applies it again.
    @Test func aKeptCutOrFixStaysKeptWhenItsWordsChangeAgain() throws {
        let model = try editor(); defer { model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        defer { model.undoManager = nil }
        func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
        let site = (78...86).map { id(model, $0) }
        step { model.keepChange(3) }
        #expect(model.proposal?[3]?.state == .kept && model.cutWordIDs.isSuperset(of: site))
        step { model.apply(.restoreCuts, name: "Restore cuts") }
        #expect(model.cutWordIDs.isDisjoint(with: site) && model.proposalDisplay?.shown(3) == nil && model.proposal?[3]?.state == .kept, "Restore All Cuts brings no hunk back")
        step { model.keepAllChanges() }
        #expect(model.cutWordIDs.isDisjoint(with: site) && model.cutWordIDs.contains(id(model, 91)), "Keep All leaves the restored words alone")
        // ⌘Z of Keep All, of the restore and of the Keep: the change waits again.
        undo.undo(); undo.undo(); undo.undo()
        #expect(model.proposal?[3]?.state == .pending && model.proposalDisplay?.shown(3) != nil && model.cutWordIDs.isDisjoint(with: site))

        let word = id(model, 87)  // "and"
        model.proposal = TranscriptProposal(clipID: "hunk-clip", title: "Rewrite clip 1", changes: [
            TranscriptChange(ordinal: 1, parts: [.init(kind: .textOnly, sourceWordIDs: [word], newTokens: ["And"], correctedTexts: ["And"])])
        ])
        step { model.keepChange(1) }
        step { model.apply(.correct(id: word, text: "Also"), name: "Correct spelling") }
        #expect(model.proposalDisplay?.shown.isEmpty == true && !model.hasUnreviewedChanges(clipID: "hunk-clip"), "a corrected word brings no fix back")
        var applied = true
        step { applied = model.keepAllChanges() }
        #expect(!applied && model.text(model.words[87]) == "Also", "and Keep All writes nothing over the correction")
    }

    /// The undo of a Keep puts the change back as it was, and only into its own proposal.
    @Test func theUndoOfAKeepPutsBackItsOwnProposalsStatesOnly() throws {
        let model = try editor(); defer { model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        defer { model.undoManager = nil }
        func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
        let site = (78...86).map { id(model, $0) }
        // Keep on a change left out, then ⌘Z: left out again, and Keep All leaves it out.
        model.excludeChange(3)
        step { model.keepChange(3) }
        #expect(model.proposal?[3]?.state == .kept && model.cutWordIDs.isSuperset(of: site))
        undo.undo()
        #expect(model.proposal?[3]?.state == .excluded && model.cutWordIDs.isDisjoint(with: site))
        step { model.keepAllChanges() }
        #expect(model.proposal?[3]?.state == .excluded && model.cutWordIDs.isDisjoint(with: site) && model.cutWordIDs.contains(id(model, 91)))
        // An edit made after Keep All stays through its undo: only the states go back.
        model.editChange(5, text: "automatic clipper")
        undo.undo()
        #expect(model.proposal?[5]?.state == .pending && model.proposal?[5]?.kind == .fix && !model.cutWordIDs.contains(id(model, 91)))
        undo.redo()
        #expect(model.proposal?[4]?.state == .kept && model.cutWordIDs.contains(id(model, 91)))
        // Once another proposal stands in its place, ⌘Z undoes the project alone.
        var next = DebugTranscriptPixels.proposal(for: model)
        next.title = "Rewrite clip 1, again"
        model.proposal = next
        undo.undo()
        #expect(model.proposal == next && !model.cutWordIDs.contains(id(model, 91)))
        undo.redo()
        #expect(model.proposal == next && model.cutWordIDs.contains(id(model, 91)))
    }

    /// The undo of a Keep puts back only the reviews that Keep made: a change left out or kept
    /// after it keeps that later review through ⌘Z and ⌘⇧Z, so a phrase the user left out never
    /// comes back waiting for takes.
    @Test func theUndoOfAKeepLeavesTheReviewsMadeAfterIt() throws {
        let model = try editor(); defer { model.close() }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        defer { model.undoManager = nil }
        func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
        func states() -> [TranscriptChange.State] { model.proposal?.changes.map(\.state) ?? [] }
        let site = (78...86).map { id(model, $0) }
        // Keep cut 3, then leave phrase 1 out and keep phrase 2 (no undo steps of their own).
        step { model.keepChange(3) }
        #expect(model.excludeChange(1) && model.keepChange(2))
        #expect(states() == [.excluded, .kept, .kept, .pending, .pending] && undo.undoActionName == "Keep change 3")
        undo.undo()
        #expect(states() == [.excluded, .kept, .pending, .pending, .pending] && model.cutWordIDs.isDisjoint(with: site), "⌘Z of the Keep: \(states())")
        #expect(model.unreviewedChanges(clipID: "hunk-clip").map(\.ordinal) == [3, 4, 5])
        undo.redo()
        #expect(states() == [.excluded, .kept, .kept, .pending, .pending] && model.cutWordIDs.isSuperset(of: site), "⌘⇧Z: \(states())")
        // Keep All, then phrase 5 left out after it: ⌘Z takes cut 4 back to waiting and leaves phrase 5 out.
        step { model.keepAllChanges() }
        #expect(states() == [.excluded, .kept, .kept, .kept, .kept] && model.excludeChange(5))
        undo.undo()
        #expect(states() == [.excluded, .kept, .kept, .pending, .excluded] && !model.cutWordIDs.contains(id(model, 91)), "⌘Z of Keep All: \(states())")
        undo.redo()
        #expect(states() == [.excluded, .kept, .kept, .kept, .excluded] && model.cutWordIDs.contains(id(model, 91)), "⌘⇧Z of Keep All: \(states())")
    }

    /// VoiceOver hears what a change left out would have done, and new words as proposed when
    /// it reads a line as attributed text, as it does word by word.
    @Test func anExcludedChangeAndNewWordsReadInFull() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let text = pane.text
        let inserted = try #require(text.map.spans.first { $0.kind == .inserted })
        let removed = try #require(text.map.span(id: id(model, 34)))
        let line = text.accessibilityAttributedString(for: NSRange(location: 0, length: (text.string as NSString).length))
        #expect(line?.attribute(.accessibilityCustomText, at: inserted.range.location, effectiveRange: nil) as? [String] == ["proposed"])
        #expect(line?.attribute(.accessibilityCustomText, at: removed.range.location, effectiveRange: nil) as? [String] == ["proposed removal"])
        #expect(text.spoken(inserted) == "your, proposed")
        model.excludeChange(1)
        #expect(model.proposalDisplay?.shown(1)?.description == "Proposed change 1 of 5: removed to, to the; inserted your, in the, left out")
    }

    @Test func aFocusMoveWritesOnlyTheParagraphsOfTheTwoChanges() throws {
        let model = try editor(); defer { model.close() }
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let renderer = pane.renderer
        let before = (paragraphs: renderer.paragraphReplacements, documents: renderer.documentRebuilds)
        model.focusChange(2)
        pane.update()
        #expect(renderer.paragraphReplacements - before.paragraphs == 2 && renderer.documentRebuilds == before.documents)
        // Changes 4 and 5 share a paragraph: one paragraph is written.
        model.focusChange(4); pane.update()
        let shared = renderer.paragraphReplacements
        model.focusChange(5); pane.update()
        #expect(renderer.paragraphReplacements - shared == 1 && renderer.documentRebuilds == before.documents)
        #expect(renderer.spacerID == "spacer:5" && pane.text.proposalLayer?.isHidden == false)
    }

    @Test func aiWordsKeepOnlyTheirGlyphWhileChangesWait() throws {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        model.mediaResolved = true; model.refresh()
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let renderer = pane.renderer
        let ai = try #require(pane.text.map.spans.first { renderer.aiWordIDs.contains($0.id) })
        #expect(renderer.attributes[ai.id]?[.vcUnderline] != nil && pane.text.map.spans.contains { $0.kind == .ai })
        let target = try #require(model.words.first { !renderer.aiWordIDs.contains($0.id) && $0.kind == .word })
        model.proposal = TranscriptProposal(clipID: model.project.edits.activeClipId, title: "Rewrite full take", changes: [TranscriptChange(ordinal: 1, parts: [.init(kind: .cut, sourceWordIDs: [target.id])])])
        pane.update()
        #expect(renderer.attributes[ai.id]?[.vcUnderline] == nil && !pane.text.map.spans.contains { $0.kind == .ai }, "the AI marker and underline step back while a change waits")
        model.excludeChange(1)
        pane.update()
        #expect(renderer.attributes[ai.id]?[.vcUnderline] != nil && pane.text.map.spans.contains { $0.kind == .ai }, "and return once none waits")
    }

    @Test func punctuationOnlyFixesAreNeverShownButKeepAllAppliesThem() throws {
        let model = try editor(); defer { model.close() }
        let comma = id(model, 77)  // "site,"
        let capital = id(model, 87)  // "and"
        model.proposal = TranscriptProposal(clipID: "hunk-clip", title: "Rewrite clip 1", changes: [
            TranscriptChange(ordinal: 1, parts: [.init(kind: .textOnly, sourceWordIDs: [comma], newTokens: ["site."], correctedTexts: ["site."])]),
            TranscriptChange(ordinal: 2, parts: [.init(kind: .textOnly, sourceWordIDs: [capital], newTokens: ["And"], correctedTexts: ["And"])])
        ])
        #expect(model.proposalDisplay?.shown.map(\.ordinal) == [2], "a comma-only fix is no hunk; a capital is")
        #expect(model.proposalDisplay?.shown.first?.kind == .fix)
        model.keepAllChanges()
        #expect(model.text(model.words[77]) == "site." && model.text(model.words[87]) == "And" && model.proposalDisplay?.shown.isEmpty == true)
    }

    @Test func theEditPopoverRediffsTheChangeLocally() throws {
        let model = try editor(); defer { model.close() }
        #expect(model.changeText(1) == "your source directory in the" && model.changeText(3) == "" && model.changeText(5) == "an automatic")
        model.editChange(2, text: "an interesting way")
        #expect(model.proposal?[2]?.kind == .voice && model.changeText(2) == "an interesting way")
        model.editChange(2, text: "interesting way how")
        #expect(model.proposal?[2]?.state == .excluded, "the words it would leave as they are leave nothing to change")
        model.editChange(5, text: "automatic clipper")
        #expect(model.proposal?[5]?.kind == .fix && model.proposal?[5]?.parts.first?.correctedTexts == ["clipper"], "a text-only edit becomes a fix")
        model.editChange(5, text: "")
        #expect(model.proposal?[5]?.kind == .cut && model.changeText(5) == "")
        #expect(model.changeFit(1, text: "your words") == nil, "no fit meter without the take's audio envelope")
    }

    @Test func pendingChangesMarkTheOverviewRulerAndTheTimeline() throws {
        let model = try editor(); defer { model.close() }
        #expect(model.pendingChangeSpans.count == 5)
        #expect(TranscriptOverviewRuler.marks(model: model).filter { $0.kind == .change }.count == 5)
        model.keepChange(1)
        model.excludeChange(2)
        #expect(model.pendingChangeSpans.count == 3 && model.pendingChangeSpans.first?.lowerBound == model.words[78].start)
    }

    /// Fixtures first (impl-plan V14): the canned reply of patch-rewrite-cases.json's
    /// "in-range-correction", over the case's words as a Full take, through `ScopeRewritePlan`,
    /// `PatchRewriteService` with a stub connector and `ScopeRewriteDiff`, shows as a change.
    @Test func c2HunksFromACannedReplyShowAsChanges() async throws {
        let shared = try SharedResources.locate()
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/patch-rewrite-cases.json")))
        let words = try document[ai: "entries"].aiArray.enumerated().map { offset, entry in
            TimedWord(id: "case-\(offset)", text: try #require(entry[ai: "text"].aiString), start: try #require(entry[ai: "start"].aiDouble), end: try #require(entry[ai: "end"].aiDouble), speaker: "s0")
        }
        let item = try #require(document[ai: "cases"].aiArray.first { $0[ai: "id"].aiString == "in-range-correction" })
        let canned = try #require(item[ai: "reply"].aiString)
        var project = try fixture()
        project.transcript?.words = words
        project.transcript?.durationSeconds = 8; project.media.source.durationSeconds = 8
        project.edits = ProjectEdits()
        let plan = try ScopeRewritePlan.make(project: project, scope: .fullTake, instruction: try #require(item[ai: "instruction"].aiString), language: "en", envelope: nil)
        // The canned edit, addressed to the plan's own first line.
        let fixtureLine = try #require(document[ai: "ranges"].aiArray.first?[ai: "line"].aiString)
        let reply = canned.replacingOccurrences(of: fixtureLine, with: try #require(plan.lines.first?.line))
        let service = PatchRewriteService(shared: shared)
        let quote = try await service.prepare(plan.request, connector: .openai, model: "selected-model")
        let proposal = try await service.propose(plan.request, connector: CannedConnector(output: reply), model: "selected-model", authorization: PatchRewriteAuthorization(quote: quote, approved: true))
        let hunks = try ScopeRewriteDiff.hunks(plan: plan, proposal: proposal)
        #expect(hunks.count == 1)

        let model = EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
        defer { model.close() }
        model.mediaResolved = true; model.refresh()
        model.proposal = TranscriptProposal(clipID: nil, title: "Rewrite full take", hunks: hunks, firstItemID: plan.lines.first?.itemIDs.first)
        let pane = try TranscriptPane(model: model, size: NSSize(width: 652, height: 488))
        defer { pane.close() }
        let shown = DebugTranscriptPixels.displayed(pane.text).joined(separator: " ")
        #expect(shown.hasPrefix("So last year, in 2024, 2025,") && shown.contains("we moved to Tartu."), "\(shown)")
        let old = try #require(pane.text.map.span(id: "case-4"))
        #expect(old.change?.role == .old && pane.renderer.attributes[old.id]?[.vcStrike] as? Bool == true)
        let inserted = pane.text.map.spans.filter { $0.kind == .inserted }
        #expect(inserted.count == 1 && (pane.text.string as NSString).substring(with: inserted[0].range) == "2025,")
        #expect(model.proposalDisplay?.shown.first?.description == "Proposed change 1 of 1: removed 2024; inserted 2025")
    }
}

/// An LLM connector that answers every send with one canned reply.
private actor CannedConnector: LLMConnector {
    nonisolated let id = ConnectorID.openai
    let output: String
    init(output: String) { self.output = output }
    func status() async -> ConnectorStatus { .ready }
    func models(refresh: Bool) async throws -> [LLMModel] { [LLMModel(id: "selected-model", name: "selected-model", contextTokens: 64_000, source: .custom)] }
    func contextTokens(model: String) async -> Int? { 64_000 }
    func send(_ request: LLMRequest, model: String) async throws -> RawCompletion { RawCompletion(text: output, model: model, stop: .complete) }
}
#endif
