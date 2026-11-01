#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The Rewrite job's change list and Keep flow (impl-plan V15), headless: R2's footer cases (design.md R2 with item 25),
/// rows named "Change {i} of {c}" as the transcript names them, Keep and Undo per change from the list and from the
/// transcript, Keep All as one step, Apply, the task ending once every change is kept, and Voice Lab's Turn on. Each
/// scene is a real reply to Rewrite clip 1 (`DebugRewrite.proposalScenes`); nothing is sent.
@Suite("Rewrite change list", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are shown."))
@MainActor struct ChangeListTests {
    private func scenes() throws -> (AppModel, [DirectorScene]) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        return (app, DebugRewrite.proposalScenes(app: app, fixture: fixture))
    }
    /// One scene, with an undo manager, its session following the transcript again.
    private func scene(_ name: String, voiceLab: Bool = true) throws -> (EditorModel, RewriteSession, UndoManager, [DirectorScene]) {
        let (app, all) = try scenes()
        app.settings.values["voiceLab.enabled"] = .bool(voiceLab)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(voiceLab)
        let scene = try #require(all.first { $0.name == name })
        let editor = try #require(scene.editor)
        let session = try #require(editor.openRewrite)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        editor.announcements = []
        session.showProposal()
        return (editor, session, undo, all)
    }
    private func changes(_ session: RewriteSession) -> ChangeSet? { if case .proposal(let set) = session.task.state { set } else { nil } }
    private func step(_ undo: UndoManager, _ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
    /// Lets the change list follow a review made in the transcript, which reaches it on the main actor's next turns.
    private func settle(_ done: () -> Bool) async { for _ in 0..<500 where !done() { await Task.yield() } }

    /// Each footer case of design.md R2, in v2's grammar: its note, its secondary link (Keep All where changes wait for
    /// takes) and its one primary in the tint. Every R2 offers Ask again on the harness line.
    @Test func everyFooterCaseShowsItsNoteLinkAndPrimary() throws {
        let (_, scenes) = try scenes()
        defer { scenes.forEach { $0.editor?.close() } }
        let expected: [String: (note: String, link: String?, primary: String?)] = [
            "r2-free": ("No AI voice needed. Nothing is sent.", nil, "Apply 2 Changes"),
            "r2-voice-lab-off": ("1 phrase needs your voice. Voice Lab (beta) makes it from this clip.", "Turn On Voice Lab…", "Apply 2 Free Changes"),
            "r2-make-takes": ("Nothing paid yet.\nTakes < $0.01 on ElevenLabs.", "Keep All", "Make Takes"),
            "r2-make-voice": ("Nothing paid yet. Next: make your voice from this clip. Once.", "Keep All", "Make Your Voice"),
            "r2-use-take": ("Exports show AI MODIFIED on the video and in the post.", nil, "Use Take 1"),
            "r2-several-voices": (RewriteSession.onePassage, nil, "Apply 1 Free Change"),
            "r2-over-budget": ("Make Takes appears when the phrases fit.", nil, "Apply 1 Free Change"),
            "r2-nothing-included": ("Keep a change to apply it.", nil, nil),
        ]
        for scene in scenes {
            let task = scene.task
            #expect(task.contextAction?.title == "Ask again", "\(scene.name)")
            if let case_ = expected[scene.name] {
                #expect(task.footer.note == case_.note, "\(scene.name): \(task.footer.note ?? "no note")")
                #expect(task.footer.link?.title == case_.link, "\(scene.name): \(task.footer.link?.title ?? "no link")")
                #expect(task.footer.primary?.title == case_.primary, "\(scene.name): \(task.footer.primary?.title ?? "no primary")")
            }
        }
        let budget = try #require(scenes.first { $0.name == "r2-over-budget" })
        #expect(budget.task.cards.contains(.callout("These changes re-voice 15 words; a rewrite can re-voice 12. Undo a phrase or two, or re-record these sentences.")))
        let none = try #require(scenes.first { $0.name == "r2-no-changes" })
        #expect(none.task.headline.text == "No changes needed" && none.task.footer.primary?.title == "Ask for Something Else")
        #expect(none.task.cards == [.text("Claude Code found nothing to change in clip 1."), .ask(placeholder: "What should change in clip 1?")])
    }

    /// The rows follow f3: the focused change on top, a cut reads the words it removes and a phrase the words it would
    /// leave, each named "Change {i} of {c}: …" as the transcript's Proposed changes rotor names it (design.md §6.3.5).
    @Test func rowsNameEachChangeAsTheTranscriptDoes() throws {
        let (editor, session, _, scenes) = try scene("r2-make-takes")
        defer { scenes.forEach { $0.editor?.close() } }
        let set = try #require(changes(session))
        #expect(set.items.map(\.kind) == [.cut, .cut, .voice] && set.items.map(\.quote) == ["word12 word13", "word25", "fresh"] && set.focused == 1)
        #expect(set.items.map(\.state) == [.pending, .pending, .pending] && set.items.allSatisfy(\.reviewable))
        let rotor = try #require(editor.proposalDisplay).shown.map(\.description)
        #expect(set.items.map(\.spoken) == rotor.map { $0.replacingOccurrences(of: "Proposed change", with: "Change") })
        #expect(set.items.first?.spoken == "Change 1 of 3: removed word12 word13")
        #expect(session.task.headline == PanelHeadline(text: "3 changes", sub: "2 cuts · 1 phrase in your voice"))
        // ↓ in the list focuses the next change in the transcript too.
        session.review(2, .focus)
        #expect(changes(session)?.focused == 2 && editor.proposal?.focused == 2)
    }

    /// Undo leaves a change out (no project change, no undo step) and Keep applies it as one step, "Keep change 1": the
    /// round trip from the list or the transcript, which never shows R3. ⌘Z takes the Keep back to left out, ⌘⇧Z keeps it.
    @Test func undoAndKeepRoundTripOneChange() async throws {
        let (editor, session, undo, scenes) = try scene("r2-free")
        defer { scenes.forEach { $0.editor?.close() } }
        let before = editor.project
        session.review(1, .undo)
        #expect(changes(session)?.items.map(\.state) == [.excluded, .pending] && editor.project == before && !undo.canUndo)
        #expect(editor.proposalDisplay?.marks["r2-12"]?.role == .slot && editor.announcements == ["Undid change 1"])
        #expect(session.task.footer.primary?.title == "Apply 1 Change")
        step(undo) { session.review(1, .keep) }
        #expect(changes(session)?.items.map(\.state) == [.kept, .pending] && editor.cutWordIDs.contains("r2-12") && undo.undoActionName == "Keep change 1")
        #expect(session.isOpen && session.current && editor.announcements.last == "Kept change 1")
        undo.undo()
        await settle { changes(session)?.items.first?.state == .excluded }
        #expect(changes(session)?.items.map(\.state) == [.excluded, .pending] && editor.project.edits == before.edits && session.current)
        undo.redo()
        await settle { changes(session)?.items.first?.state == .kept }
        #expect(changes(session)?.items.map(\.state) == [.kept, .pending] && editor.cutWordIDs.contains("r2-12"))
        // The transcript's ⌘↩ on change 2 is the same Keep; the list follows, and with every change kept the task ends.
        step(undo) { editor.keepChange(2) }
        await settle { !session.isOpen }
        #expect(!session.isOpen && editor.openRewrite == nil && editor.proposal == nil && editor.project.edits.corrections["r2-20"] == "Word20")
    }

    /// Keep All (impl-plan item 7): the free changes apply as one undo step named for the scope and the phrase is included
    /// for takes; Rewrite stays open on Make Takes, and the tab's dot goes. ⌘Z takes every change back to waiting.
    @Test func keepAllIsOneStepAndLeavesTheTakes() async throws {
        let (editor, session, undo, scenes) = try scene("r2-make-takes")
        defer { scenes.forEach { $0.editor?.close() } }
        let before = editor.project
        #expect(session.hasUnreviewedChanges)
        step(undo) { session.task.footer.link?.perform() }
        #expect(undo.undoActionName == "Rewrite clip 1" && editor.undoSteps == 1 && editor.cutWordIDs.isSuperset(of: ["r2-12", "r2-13", "r2-25"]))
        #expect(changes(session)?.items.map(\.state) == [.kept, .kept, .kept] && session.isOpen && !session.hasUnreviewedChanges)
        #expect(session.task.footer.primary?.title == "Make Takes" && session.task.footer.link == nil && session.includedVoice == [3])
        undo.undo()
        await settle { changes(session)?.items.first?.state == .pending }
        #expect(editor.project.edits == before.edits && changes(session)?.items.map(\.state) == [.pending, .pending, .pending] && session.task.footer.link?.title == "Keep All")
    }

    /// Apply {c} Changes keeps every waiting change as one step named for the scope, announces it, closes Rewrite and
    /// takes the proposal out of the transcript; ⌘Z undoes the project alone.
    @Test func applyKeepsEveryChangeAndCloses() throws {
        let (editor, session, undo, scenes) = try scene("r2-free")
        defer { scenes.forEach { $0.editor?.close() } }
        let before = editor.project
        step(undo) { session.task.footer.primary?.perform() }
        #expect(undo.undoActionName == "Rewrite clip 1" && editor.undoSteps == 1 && editor.cutWordIDs.contains("r2-12") && editor.project.edits.corrections["r2-20"] == "Word20")
        #expect(!session.isOpen && editor.openRewrite == nil && editor.proposal == nil && editor.announcements.last == "Applied 2 changes" && editor.selectedWordIDs == ["r2-12"])
        undo.undo()
        #expect(editor.project.edits == before.edits && !undo.canUndo)
    }

    /// With Voice Lab off a phrase in your voice is left out with no review ("Needs Voice Lab (beta)"); Turn on gives it its
    /// review back, waiting, and the footer moves to Make Takes (design.md R2).
    @Test func turningOnVoiceLabIncludesThePhrase() async throws {
        let (editor, session, _, scenes) = try scene("r2-voice-lab-off", voiceLab: false)
        defer { scenes.forEach { $0.editor?.close() } }
        let voice = try #require(changes(session)?.items.last)
        #expect(voice.kind == .voice && voice.state == .excluded && !voice.reviewable && voice.note == "Needs Voice Lab (beta)" && voice.warns)
        #expect(editor.proposal?[3]?.state == .excluded && session.task.footer.link?.title == "Turn On Voice Lab…")
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        await settle { changes(session)?.items.last?.reviewable == true }
        #expect(changes(session)?.items.last?.state == .pending && editor.proposal?[3]?.state == .pending)
        #expect(session.task.footer.primary?.title == "Make Takes" && session.task.footer.link?.title == "Keep All")
    }
}
#endif
