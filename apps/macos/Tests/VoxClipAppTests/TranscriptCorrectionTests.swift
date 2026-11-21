#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The inline correction field (design §4.2) ends like an inline rename: leaving it keeps valid text, Esc keeps the word.
@Suite("Headless inline correction", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are opened."), .offlineFixtures)
@MainActor struct TranscriptCorrectionTests {
    private func editor() throws -> EditorModel {
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        return EditorModel(document: VoxClipDocument(project: project, demo: true), app: AppModel(), preview: DemoPreviewEngine())
    }
    private func correcting(_ model: EditorModel, _ id: String, text: String) throws {
        model.selectedWordIDs = [id]
        model.beginCorrection()
        try #require(model.correctionID == id)
        model.correctionText = text
    }

    private func key(_ chars: String, code: UInt16, window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: code))
    }

    @Test func typingAShuttleLetterReplacesOneWordAndSavesOneUndoableCorrection() throws {
        _ = NSApplication.shared
        let model = try editor(); defer { model.close() }
        let original = model.project
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.select("w3")
        let pane = try TranscriptPane(model: model, size: NSSize(width: 420, height: 360)); defer { pane.close() }
        try #require(pane.window.makeFirstResponder(pane.text))
        let j = try key("j", code: 38, window: pane.window)
        try #require(pane.text.acceptsWordTyping(j))
        pane.text.keyDown(with: j)
        let field = try #require(pane.text.correctionFieldForTests)
        let input = try #require(field.currentEditor() as? NSTextView)
        #expect(pane.window.firstResponder === input && input.string == "j" && !model.isPlaying)
        input.keyDown(with: try key("a", code: 0, window: pane.window))
        #expect(input.string == "ja" && !undo.canUndo)
        undo.beginUndoGrouping()
        input.keyDown(with: try key("\r", code: 36, window: pane.window))
        undo.endUndoGrouping()
        #expect(model.correctionID == nil && model.project.edits.corrections["w3"] == "ja")
        let saved = try JSONProjectStore.decode(JSONProjectStore.encode(model.project))
        #expect(saved.edits.corrections["w3"] == "ja" && saved.transcript == original.transcript && saved.voiceLab == original.voiceLab)
        #expect(model.rewrite == nil && undo.canUndo)
        undo.undo()
        #expect(model.project.edits == original.edits && !undo.canUndo)
    }

    @Test func compactToolbarEditsInPlaceAndRangeOrUnfocusedKeysKeepTheirMeaning() throws {
        _ = NSApplication.shared
        let model = try editor(); defer { model.close() }
        model.select("w3")
        let pane = try TranscriptPane(model: model, size: NSSize(width: 348, height: 360)); defer { pane.close() }
        let j = try key("j", code: 38, window: pane.window)
        _ = pane.window.makeFirstResponder(pane.text)
        #expect(!pane.text.acceptsWordTyping(try key(" ", code: 49, window: pane.window)))
        #expect(!pane.text.acceptsWordTyping(try key("z", code: 6, window: pane.window, flags: .command)))
        pane.text.showSelectionBar()
        let host = try #require(pane.text.selectionBarAuditView as? NSHostingView<SelectionBar>)
        let open = try #require(host.rootView.editWord)
        open()
        let field = try #require(pane.text.correctionFieldForTests)
        let input = try #require(field.currentEditor() as? NSTextView)
        #expect(input.string == "today" && input.selectedRange().length == 5 && !pane.text.selectionBarVisible)
        input.keyDown(with: try key("r", code: 15, window: pane.window))
        input.keyDown(with: try key("\u{1b}", code: 53, window: pane.window))
        #expect(model.project.edits.corrections.isEmpty && model.correctionID == nil)
        _ = pane.window.makeFirstResponder(nil)
        #expect(!pane.text.acceptsWordTyping(j))
        _ = pane.window.makeFirstResponder(pane.text)
        model.select("w4", extend: true); pane.update()
        #expect(!pane.text.acceptsWordTyping(j))
        #expect(model.project.edits.corrections.isEmpty && model.rewrite == nil)
    }

    @Test func selectingAnotherWordSavesTheOpenCorrection() throws {
        let model = try editor(); defer { model.close() }
        try correcting(model, "w3", text: "Today")
        model.selectedWordIDs = ["w5"]
        #expect(model.correctionID == nil)
        #expect(model.project.edits.corrections["w3"] == "Today")
        #expect(model.selectedWordIDs == ["w5"])
    }

    @Test func extendingTheSelectionSavesTheOpenCorrection() throws {
        let model = try editor(); defer { model.close() }
        try correcting(model, "w3", text: "Today")
        model.selectedWordIDs = ["w3", "w5"]
        #expect(model.correctionID == nil)
        #expect(model.project.edits.corrections["w3"] == "Today")
    }

    @Test func playSavesTheOpenCorrectionAndPlays() throws {
        let model = try editor(); defer { model.close() }
        try correcting(model, "w3", text: "Today")
        model.transport(" ")
        #expect(model.correctionID == nil)
        #expect(model.project.edits.corrections["w3"] == "Today")
        #expect(model.isPlaying)
    }

    /// Saving the correction pauses, so Space must toggle from the playing state before the save: it pauses.
    @Test func pauseWithTheCorrectionOpenSavesItAndStaysPaused() throws {
        let model = try editor(); defer { model.close() }
        model.transport(" ")
        try #require(model.isPlaying)
        try correcting(model, "w3", text: "Today")
        model.transport(" ")
        #expect(model.correctionID == nil)
        #expect(model.project.edits.corrections["w3"] == "Today")
        #expect(!model.isPlaying && !model.preview.isPlaying)
    }

    @Test func textThatCannotBeSavedClosesTheFieldAndKeepsTheWord() throws {
        let model = try editor(); defer { model.close() }
        try correcting(model, "w3", text: "  ")
        model.selectedWordIDs = ["w5"]
        #expect(model.correctionID == nil)
        #expect(model.project.edits.corrections["w3"] == nil)
        try correcting(model, "w5", text: "")
        model.transport(" ")
        #expect(model.correctionID == nil && model.isPlaying)
        #expect(model.project.edits.corrections["w5"] == nil)
    }

    @Test(arguments: ["Today\n", "\rToday", "to\u{2028}day", "to\u{2029}day", String(repeating: "a", count: EditingLimits.maxCorrectionScalars + 1)])
    func unsavableDraftIsDroppedOnFocusLoss(_ draft: String) throws {
        let model = try editor(); defer { model.close() }
        try correcting(model, "w3", text: draft)
        model.endCorrection()
        #expect(model.correctionID == nil)
        #expect(model.project.edits.corrections["w3"] == nil)
    }

    @Test(arguments: ["", String(repeating: "a", count: EditingLimits.maxCorrectionScalars + 1)], [false, true])
    func returnAndTabKeepUnsavableDraftsOpen(draft: String, advance: Bool) throws {
        let model = try editor(); defer { model.close() }
        try correcting(model, "w3", text: draft)
        model.saveCorrection(advance: advance)
        #expect(model.correctionID == "w3")
        #expect(model.correctionText == draft)
        #expect(model.selectedWordIDs == ["w3"])
        #expect(model.project.edits.corrections["w3"] == nil)
    }

    @Test func tabSavesAndOpensTheNextWord() throws {
        let model = try editor(); defer { model.close() }
        try correcting(model, "w3", text: "Today")
        model.saveCorrection(advance: true)
        #expect(model.project.edits.corrections["w3"] == "Today")
        #expect(model.correctionID == "w4")
        #expect(model.selectedWordIDs == ["w4"])
        #expect(model.correctionText == "we")
    }

    @Test func focusLeavingTheFieldSavesTheTypedTextAndRemovesTheField() throws {
        let model = try editor(); defer { model.close() }
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.model = model
        try correcting(model, "w3", text: "today")
        let field = NSTextField(string: "today")
        text.correctionFieldForTests = field
        field.stringValue = "Today"
        text.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(model.correctionText == "Today")
        text.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(model.correctionID == nil)
        #expect(model.project.edits.corrections["w3"] == "Today")
        #expect(field.superview == nil && text.correctionFieldForTests == nil)
    }

    @Test func escapeKeepsTheWordAndTheRemovedFieldsEndIsIgnored() throws {
        let model = try editor(); defer { model.close() }
        let text = TranscriptNSTextView(usingTextLayoutManager: true)
        text.model = model
        try correcting(model, "w3", text: "today")
        let field = NSTextField(string: "Today")
        text.correctionFieldForTests = field
        #expect(text.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(model.correctionID == nil && field.superview == nil)
        text.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(model.project.edits.corrections["w3"] == nil)
    }
}
#endif
