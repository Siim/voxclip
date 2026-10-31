#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The inline correction field (design §4.2) ends like an inline rename: leaving it keeps valid text, Esc keeps the word.
@Suite("Headless inline correction", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are opened."))
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

    @Test func selectingAnotherWordSavesTheOpenCorrection() throws {
        let model = try editor(); defer { model.close() }
        try correcting(model, "w3", text: "Today")
        model.selectedWordIDs = ["w5"]
        #expect(model.correctionID == nil)
        #expect(model.project.edits.corrections["w3"] == "Today")
        #expect(model.selectedWordIDs == ["w5"])
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
