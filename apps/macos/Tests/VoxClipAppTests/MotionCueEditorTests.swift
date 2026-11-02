#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClip

private actor MotionCueTestSettings: SettingsStore {
    func load() async throws -> SettingsDocument { SettingsDocument(values: ["update.autoCheck": .bool(false)]) }
    func save(_ settings: SettingsDocument) async throws {}
    func flush() async throws {}
}

@Suite("Motion cue editor", .serialized, .offlineFixtures)
@MainActor struct MotionCueEditorTests {
    init() { _ = NSApplication.shared }

    private func editor() throws -> EditorModel {
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        project.media.source.durationSeconds = 60
        project.transcript?.durationSeconds = 60
        project.transcript?.words = (0..<60).map { index in
            TimedWord(id: "motion-word-\(index)", text: "word", start: Double(index), end: Double(index) + 0.8)
        }
        project.edits = ProjectEdits(cutWordIds: ["motion-word-14", "motion-word-15"], clips: [
            ClipRange(id: "motion-clip", startWordId: "motion-word-10", endWordId: "motion-word-29"),
            ClipRange(id: "other-clip", startWordId: "motion-word-30", endWordId: "motion-word-49")
        ], activeClipId: "motion-clip")
        let model = EditorModel(document: VoxClipDocument(project: project, demo: true),
            app: AppModel(settingsStore: MotionCueTestSettings()), preview: DemoPreviewEngine())
        model.mediaResolved = true
        model.refresh()
        return model
    }

    private func draft(_ model: EditorModel, start: Double = 11, end: Double = 13) throws -> MotionCueDraft {
        var draft = try #require(model.motionCueDraft())
        draft.sourceStart = start
        draft.sourceEnd = end
        return draft
    }

    private func grouped(_ undo: UndoManager, _ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    @Test func addChangeAndDeleteEachHaveOneUndoStepAndPreserveNarration() throws {
        let model = try editor(); defer { model.close() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let before = model.project
        let value = try draft(model)
        let baselineSteps = model.undoSteps
        grouped(undo) { #expect(model.applyMotionCue(value)) }
        #expect(model.project.schemaVersion == 4 && model.project.motionCues == [value.cue])
        #expect(model.undoSteps == baselineSteps + 1 && undo.undoActionName == "Add Motion Cue")
        #expect(model.project.transcript == before.transcript && model.project.media == before.media)
        let upgradedVoice = try VoiceLabProject.upgradeToV3(before).voiceLab
        #expect(model.project.edits == before.edits && model.project.voiceLab == upgradedVoice)
        undo.undo()
        #expect(model.project.motionCues.isEmpty && model.project.schemaVersion == before.schemaVersion)
        undo.redo()
        #expect(model.project.motionCues == [value.cue] && model.project.schemaVersion == 4)
        var changed = try #require(model.motionCueDraft(id: value.id))
        changed.keyframes[1] = MotionKeyframe(progress: 0.5, scale: 1.2, anchorX: 0.8, anchorY: 0.2)
        let changeSteps = model.undoSteps
        grouped(undo) { #expect(model.applyMotionCue(changed)) }
        #expect(model.undoSteps == changeSteps + 1 && undo.undoActionName == "Change Motion Cue")
        undo.undo()
        #expect(model.project.motionCues == [value.cue])
        undo.redo()
        #expect(model.project.motionCues == [changed.cue])
        let deleteSteps = model.undoSteps
        grouped(undo) { #expect(model.deleteMotionCue(changed.cue)) }
        #expect(model.project.motionCues.isEmpty && model.project.schemaVersion == 4)
        #expect(model.undoSteps == deleteSteps + 1 && undo.undoActionName == "Delete Motion Cue")
        undo.undo()
        #expect(model.project.motionCues == [changed.cue])
        undo.redo()
        #expect(model.project.motionCues.isEmpty)
        #expect(model.project.transcript == before.transcript && model.project.media == before.media)
    }

    @Test func draftChangesCancelWithoutTouchingTheProject() throws {
        let model = try editor(); defer { model.close() }
        let before = model.project
        let steps = model.undoSteps
        var value = try draft(model)
        value.keyframes[1] = MotionKeyframe(progress: 0.5, scale: 1.3)
        #expect(model.motionCueValidation(value) == nil)
        #expect(model.project == before && model.undoSteps == steps)
        #expect(!model.deleteMotionCue(value.cue))
    }

    @Test func removeClipAndUndoRedoKeepClipAndCuesInOneTransaction() throws {
        let model = try editor(); defer { model.close() }
        let first = try draft(model)
        #expect(model.applyMotionCue(first))
        var scoped = model.project
        scoped.edits.activeClipId = "other-clip"
        model.document.replaceProject(scoped); model.refresh()
        let second = try draft(model, start: 32, end: 34)
        #expect(model.applyMotionCue(second))
        scoped = model.project
        scoped.edits.activeClipId = "motion-clip"
        model.document.replaceProject(scoped); model.refresh()
        let before = model.project
        let otherClip = try #require(before.edits.clips.first(where: { $0.id == "other-clip" }))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let steps = model.undoSteps
        grouped(undo) { model.apply(.removeClip(id: "motion-clip"), name: "Remove Clip") }
        #expect(model.undoSteps == steps + 1 && undo.undoActionName == "Remove Clip")
        #expect(model.project.edits.clips == [otherClip] && model.project.motionCues == [second.cue])
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(model.project)).motionCues == [second.cue])
        undo.undo()
        #expect(model.project.edits.clips == before.edits.clips)
        #expect(model.project.motionCues == [first.cue, second.cue])
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(model.project)).motionCues == before.motionCues)
        undo.redo()
        #expect(model.project.edits.clips == [otherClip] && model.project.motionCues == [second.cue])
        #expect(model.project.transcript == before.transcript && model.project.media == before.media)
        #expect(model.project.edits.cutWordIds == before.edits.cutWordIds && model.project.edits.cutPauseIds == before.edits.cutPauseIds)
    }

    @Test func fullTakeOtherClipAndReadOnlyScopesCannotMutateTheCue() throws {
        let model = try editor(); defer { model.close() }
        let value = try draft(model)
        #expect(model.applyMotionCue(value))
        let saved = model.project.motionCues
        var scoped = model.project
        scoped.edits.activeClipId = nil
        model.document.replaceProject(scoped); model.refresh()
        #expect(model.motionCueDraft() == nil && !model.applyMotionCue(value) && !model.deleteMotionCue(value.cue))
        #expect(model.timelineMotionCues(on: .source).isEmpty && model.timelineMotionCues(on: .edited).isEmpty)
        scoped.edits.activeClipId = "other-clip"
        model.document.replaceProject(scoped); model.refresh()
        #expect(model.clipMotionCues.isEmpty && !model.deleteMotionCue(value.cue))
        scoped.edits.activeClipId = "motion-clip"
        model.document.replaceProject(scoped); model.refresh()
        model.document.versionForTesting = true
        #expect(!model.deleteMotionCue(value.cue) && model.motionCueUnavailableReason != nil)
        #expect(model.project.motionCues == saved)
    }

    @Test func invalidCutAndOverlappingRangesDoNotRegisterUndo() throws {
        let model = try editor(); defer { model.close() }
        let steps = model.undoSteps
        for bounds in [(-1.0, 2.0), (11.0, 11.01), (14.1, 15.5), (12.0, 11.0), (11.0, Double.nan)] {
            let value = try draft(model, start: bounds.0, end: bounds.1)
            #expect(model.motionCueValidation(value) != nil && !model.applyMotionCue(value))
        }
        #expect(model.undoSteps == steps && model.project.motionCues.isEmpty)
        let first = try draft(model)
        #expect(model.applyMotionCue(first))
        let overlap = try draft(model, start: 12, end: 16)
        #expect(model.motionCueValidation(overlap) != nil && !model.applyMotionCue(overlap))
        let noOp = try #require(model.motionCueDraft(id: first.id))
        let noOpSteps = model.undoSteps
        #expect(!model.applyMotionCue(noOp) && model.undoSteps == noOpSteps)
    }

    @Test func staleDraftCannotOverwriteAnExternalCueChange() throws {
        let model = try editor(); defer { model.close() }
        let value = try draft(model)
        #expect(model.applyMotionCue(value))
        var stale = try #require(model.motionCueDraft(id: value.id))
        var current = stale
        current.sourceEnd = 13.5
        #expect(model.applyMotionCue(current))
        stale.sourceEnd = 12.5
        #expect(!model.applyMotionCue(stale) && model.motionCueValidation(stale) != nil)
        #expect(model.project.motionCues == [current.cue])
    }

    @Test func sourceAndEditedLaneRangesFollowCutsWithoutChangingCueAnchors() throws {
        let model = try editor(); defer { model.close() }
        let value = try draft(model, start: 12, end: 18)
        #expect(model.applyMotionCue(value))
        let source = model.timelineMotionCues(on: .source)
        let edited = model.timelineMotionCues(on: .edited)
        #expect(source == [TimelineMotionCue(id: value.id, range: 12..<18)])
        #expect(edited.map(\.range) == value.cue.mappedIntervals(in: model.timelinePieces).map(\.edited))
        #expect(edited.count >= 2)
        model.toggleShowsCuts()
        #expect(model.project.motionCues == [value.cue])
        let lane = MotionLane()
        lane.state = MotionLane.State(viewport: TimelineViewport(axis: .source, ptPerSecond: 10, origin: 0, width: 800), cues: source, hasClip: true)
        #expect(lane.cueID(at: NSPoint(x: lane.headerWidth + 130, y: 10)) == value.id)
        #expect(lane.cueID(at: NSPoint(x: lane.headerWidth + 180, y: 10)) == nil)
    }

    @Test func cueLimitRejectsTheSixtyFifthAndFxControlIsDiscoverable() throws {
        let model = try editor(); defer { model.close() }
        let cues = (0..<MotionCue.maximumCuesPerClip).map { index in
            MotionCue(id: "limit-\(index)", clipID: "motion-clip", sourceStart: 10 + Double(index) * 0.15, sourceEnd: 10.1 + Double(index) * 0.15)
        }
        let project = try ContextDemoProject.settingMotionCues(cues, in: model.project)
        model.document.replaceProject(project); model.refresh()
        let value = try draft(model, start: 22, end: 23)
        #expect(model.clipMotionCues.count == 64 && !model.applyMotionCue(value))
        let canvas = TimelineCanvasView(model: model)
        defer { canvas.tearDown() }
        #expect(!canvas.headers[3].button.isHidden)
        #expect(canvas.headers[3].button.accessibilityLabel() == "Edit clip motion cues")
        #expect(canvas.motion.state.cues == model.timelineMotionCues(on: model.timelineAxis))
        canvas.openMotionCue(id: cues.first?.id)
        #expect(model.app.shell.panelJob(for: model) == .motion)
        #expect(model.motionCueEditing?.draft.original == cues.first)
    }

    private func settle(_ host: NSView, until done: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            host.layoutSubtreeIfNeeded()
            if done() { return true }
            await Task.yield()
        }
        return done()
    }

    @Test func fxButtonOpensTheMotionJobInTheExistingHostWithoutEditing() async throws {
        let model = try editor(); defer { model.close() }
        let shell = WorkspaceShell(app: model.app)
        let before = model.project, steps = model.undoSteps
        let canvas = TimelineCanvasView(model: model, shell: shell)
        defer { canvas.tearDown() }
        canvas.headers[3].button.performClick(nil)
        let editing = try #require(model.motionCueEditing)
        #expect(shell.panelJob(for: model) == .motion)
        #expect(editing.returnJob == .captions)
        let host = NSHostingView(rootView: PanelHost(model: model, shell: shell, width: 404, height: 522).environment(model.app))
        host.frame = CGRect(x: 0, y: 0, width: 404, height: 522)
        #expect(await settle(host) { DebugRightColumn.texts(in: host)["panel.title"] == "Motion" })
        #expect(DebugRightColumn.texts(in: host)["panel.context"] == "Clip 1")
        #expect(DebugRightColumn.markers(in: host)["motion.footer"] != nil)
        #expect(model.project == before && model.undoSteps == steps)
        #expect(model.focusedPane == .panel)
    }

    @Test func inlineDraftEditsApplyAsOneUndoStepAndCancelDoesNotUndoSavedWork() throws {
        let model = try editor(); defer { model.close() }
        let value = try draft(model)
        #expect(model.applyMotionCue(value))
        let before = model.project
        let shell = WorkspaceShell(app: model.app)
        let undo = UndoManager(); undo.groupsByEvent = false
        model.undoManager = undo
        let steps = model.undoSteps
        #expect(model.openMotionCueJob(id: value.id, in: shell))
        let editing = try #require(model.motionCueEditing)
        editing.draft.sourceEnd = 13.5
        editing.setFrameValue(.scale, to: 1.25)
        editing.setFrameValue(.anchorX, to: 0.8)
        editing.setFrameValue(.anchorY, to: 0.2)
        editing.addKeyframe()
        #expect(editing.draft.keyframes.count == value.keyframes.count + 1)
        let changed = editing.draft.cue
        #expect(model.project == before && model.undoSteps == steps && !undo.canUndo)
        grouped(undo) { #expect(editing.apply(model: model)) }
        #expect(model.project.motionCues == [changed])
        #expect(model.undoSteps == steps + 1 && undo.undoActionName == "Change Motion Cue")
        #expect(model.project.media == before.media && model.project.transcript == before.transcript)
        editing.draft.sourceEnd = 14
        model.closeMotionCueJob(in: shell)
        #expect(model.motionCueEditing == nil && shell.panelJob(for: model) == .captions)
        #expect(model.project.motionCues == [changed] && model.undoSteps == steps + 1)
        #expect(!editing.apply(model: model))
        undo.undo()
        #expect(model.project.motionCues == before.motionCues && !undo.canUndo)
        undo.redo()
        #expect(model.project.motionCues == [changed])
    }

    @Test(arguments: [false, true])
    func escapeFromTheInlineHostDiscardsTheDraftAndReturnsToThePreviousJob(fromField: Bool) async throws {
        let model = try editor(); defer { model.close() }
        let shell = WorkspaceShell(app: model.app)
        model.exportJob.isOpen = true
        shell.choosePanelJob(.export, for: model)
        shell.exportReturnJob = .demo
        let before = model.project, steps = model.undoSteps
        let host = NSHostingView(rootView: PanelHost(model: model, shell: shell, width: 404, height: 522).environment(model.app))
        host.frame = CGRect(x: 0, y: 0, width: 404, height: 522)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        #expect(model.openMotionCueJob(in: shell))
        let editing = try #require(model.motionCueEditing)
        editing.draft.sourceStart = 11
        editing.draft.sourceEnd = 13
        editing.setFrameValue(.scale, to: 1.3)
        #expect(await settle(host) { DebugRightColumn.texts(in: host)["panel.title"] == "Motion" })
        #expect(await settle(host) { DebugRightColumn.texts(in: host)["motion.keyboard"] == "focused" })
        #expect(window.firstResponder === host)
        if fromField {
            func field(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                for child in view.subviews { if let found = field(in: child) { return found } }
                return nil
            }
            let input = try #require(field(in: host))
            #expect(window.makeFirstResponder(input))
            #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        }
        #expect(!window.isVisible && window.attachedSheet == nil)
        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        #expect(await settle(host) { model.motionCueEditing == nil })
        #expect(shell.panelJob(for: model) == .export)
        #expect(shell.exportReturnJob == .demo)
        #expect(model.project == before && model.undoSteps == steps)
        #expect(model.focusedPane == .timeline)
        #expect(!editing.apply(model: model))
    }

    @Test(arguments: [CGSize(width: 324, height: 322), CGSize(width: 404, height: 522)])
    func inlineMotionKeepsItsFooterAndAScrollingBody(size: CGSize) async throws {
        let model = try editor(); defer { model.close() }
        let shell = WorkspaceShell(app: model.app)
        #expect(model.openMotionCueJob(in: shell))
        let host = NSHostingView(rootView: PanelHost(model: model, shell: shell, width: size.width, height: size.height).environment(model.app))
        host.frame = CGRect(origin: .zero, size: size)
        #expect(await settle(host) { DebugRightColumn.markers(in: host)["motion.footer"] != nil })
        let markers = DebugRightColumn.markers(in: host)
        let footer = try #require(markers["motion.footer"])
        let body = try #require(markers["panel.body"])
        let primary = try #require(markers["motion.apply"])
        #expect(footer.minX >= body.minX && footer.maxX <= body.maxX + 0.5)
        #expect(footer.maxY <= body.maxY + 0.5 && footer.minY >= body.minY)
        #expect(primary.height == 28)
        let scroll = try #require(DebugRightColumn.scrollViews(in: host).first)
        #expect(scroll.contentView.bounds.height >= 24)
    }

    @Test func leavingMotionOrChangingClipDiscardsTheDraftAndUnavailableScopesDoNotOpen() throws {
        let model = try editor(); defer { model.close() }
        let shell = WorkspaceShell(app: model.app)
        let before = model.project, steps = model.undoSteps
        #expect(model.openMotionCueJob(in: shell))
        let editing = try #require(model.motionCueEditing)
        editing.setFrameValue(.scale, to: 1.3)
        shell.choosePanelJob(.captions, for: model)
        #expect(model.motionCueEditing == nil && !editing.apply(model: model))
        #expect(model.project == before && model.undoSteps == steps)
        #expect(model.openMotionCueJob(in: shell))
        #expect(model.setScope("other-clip"))
        #expect(model.motionCueEditing == nil && shell.panelJob(for: model) == .captions)
        #expect(model.openMotionCueJob(in: shell))
        #expect(model.motionCueEditing?.draft.clipID == "other-clip")
        #expect(model.setScope(nil))
        #expect(!model.openMotionCueJob(in: shell) && model.motionCueEditing == nil)
        #expect(model.setScope("motion-clip"))
        model.document.versionForTesting = true
        #expect(!model.openMotionCueJob(in: shell) && model.motionCueEditing == nil)
        #expect(model.undoSteps == steps && model.project.motionCues.isEmpty)
    }
}
#endif
