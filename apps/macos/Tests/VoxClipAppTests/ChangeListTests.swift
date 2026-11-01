#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// The Rewrite job's change list and Keep flow (impl-plan V15), headless: R2's footer cases (design.md R2 with item 25),
/// rows named "Change {i} of {c}" as the transcript names them, Keep and Undo per change from the list and from the
/// transcript, Keep All as one step, Apply, ⌘Z of the last Keep, Voice Lab's Turn on, takes that stay with their phrase,
/// phrases that can't be made, the list's keys, Ask again and Make Takes' problem. Each scene is a real reply to Rewrite
/// clip 1 (`DebugRewrite.proposalScenes`); nothing is sent.
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
            "r2-voice-lab-off": ("1 phrase needs your voice. Voice Lab (beta) makes it from this clip.", "Turn On Voice Lab", "Apply 2 Free Changes"),
            "r2-make-takes": ("Nothing paid yet.\nTakes < $0.01 on ElevenLabs.", "Keep All", "Make Takes"),
            "r2-make-voice": ("Nothing paid yet. Next: make your voice from this clip. Once.", "Keep All", "Make Your Voice"),
            "r2-use-take": ("Exports show AI MODIFIED on the video. The post disclosure is optional.", nil, "Use Takes"),
            "r2-several-voices": ("Nothing paid yet.\nTakes < $0.01 on ElevenLabs.", "Keep All", "Make Takes"),
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
        // The Beta tag shows with phrases in your voice while Voice Lab is on (design.md §6.3.4).
        let tags = Dictionary(scenes.map { ($0.name, $0.task.headline.tag) }, uniquingKeysWith: { first, _ in first })
        #expect(tags["r2-make-takes"] == "Beta" && tags["r2-several-voices"] == "Beta" && tags["r2-use-take"] == "Beta")
        #expect(tags["r2-free"] == .some(nil) && tags["r2-voice-lab-off"] == .some(nil) && tags["r2-no-changes"] == .some(nil))
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
        #expect(session.task.headline == PanelHeadline(text: "3 changes", sub: "2 cuts · 1 phrase in your voice", tag: "Beta"))
        // ↓ in the list focuses the next change in the transcript too.
        session.review(2, .focus)
        #expect(changes(session)?.focused == 2 && editor.proposal?.focused == 2)
    }

    /// Undo leaves a change out (no project change, no undo step) and Keep applies it as one step, "Keep change 1": the
    /// round trip from the list or the transcript, which never shows R3. ⌘Z takes the Keep back to left out, ⌘⇧Z keeps it.
    /// With every change kept the task stays open, so ⌘Z of the last Keep brings that change back for review (§6.3.5).
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
        // The transcript's ⌘↩ on change 2 is the same Keep; the list follows, and with every change kept it stays.
        step(undo) { editor.keepChange(2) }
        await settle { changes(session)?.items.last?.state == .kept }
        #expect(changes(session)?.items.map(\.state) == [.kept, .kept] && editor.project.edits.corrections["r2-20"] == "Word20")
        #expect(session.isOpen && editor.openRewrite === session && editor.proposal != nil && !session.hasUnreviewedChanges)
        #expect(session.task.footer == PanelFooter(note: RewriteSession.everyChangeKept))
        undo.undo()
        await settle { changes(session)?.items.last?.state == .pending }
        #expect(changes(session)?.items.map(\.state) == [.kept, .pending] && editor.project.edits.corrections["r2-20"] == nil)
        #expect(editor.proposal?[2]?.state == .pending && session.task.footer.primary?.title == "Apply 1 Change" && session.hasUnreviewedChanges)
        session.task.close.perform()
        #expect(!session.isOpen && editor.openRewrite == nil && editor.proposal == nil)
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

    /// ⌘Z of a Keep puts back only what that Keep reviewed: the phrase left out after it stays out, so the footer offers no
    /// takes for it, and the tab, the status bar and the Outline count only the cut that waits again.
    @Test func theUndoOfAKeepLeavesAPhraseLeftOutAfterItOut() async throws {
        let (editor, session, undo, scenes) = try scene("r2-make-takes")
        defer { scenes.forEach { $0.editor?.close() } }
        #expect(changes(session)?.items.map(\.kind) == [.cut, .cut, .voice] && session.includedVoice == [3])
        step(undo) { session.review(1, .keep) }
        session.review(3, .undo)
        await settle { changes(session)?.items.last?.state == .excluded }
        #expect(changes(session)?.items.map(\.state) == [.kept, .pending, .excluded] && session.includedVoice.isEmpty)
        #expect(session.task.footer.primary?.id == "apply" && !session.task.cards.contains(.takes))
        undo.undo()
        await settle { changes(session)?.items.first?.state == .pending }
        #expect(changes(session)?.items.map(\.state) == [.pending, .pending, .excluded] && session.includedVoice.isEmpty)
        #expect(session.task.footer.primary?.id == "apply" && session.task.footer.primary?.title.hasPrefix("Make") == false && !session.task.cards.contains(.takes))
        #expect(editor.unreviewedChanges(clipID: editor.proposal?.clipID).map(\.ordinal) == [1, 2])
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
        #expect(editor.proposal?[3]?.state == .excluded && session.task.footer.link?.title == "Turn On Voice Lab")
        let before = editor.proposal
        session.task.footer.link?.perform()
        #expect(editor.hasVoiceJob && editor.app.voiceLabSession.flow.state == .firstUse)
        #expect(editor.proposal == before && editor.app.voiceLabSession.confirmation == nil)
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        await settle { changes(session)?.items.last?.reviewable == true }
        #expect(changes(session)?.items.last?.state == .pending && editor.proposal?[3]?.state == .pending)
        #expect(session.task.footer.primary?.title == "Make Takes" && session.task.footer.link?.title == "Keep All")
    }

    /// A take is made for one phrase (impl-plan item 25). With two phrases, Undo of one leaves the other's footer; once a
    /// take of it passed, including the other phrase alone instead never offers that take's Use Take: the takes no longer
    /// fit and the other phrase is quoted. Coming back to a phrase quotes it again too.
    @Test func takesStayWithTheirPhrase() async throws {
        let (editor, session, _, scenes) = try scene("r2-several-voices")
        defer { scenes.forEach { $0.editor?.close() } }
        editor.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        #expect(session.includedVoice == [2, 3] && session.task.footer.primary?.title == "Make Takes")
        session.review(3, .undo)
        #expect(session.includedVoice == [2] && session.task.footer.primary?.title == "Make Takes")
        // Phrase 2's takes: one passed. Nothing is quoted or sent here.
        try DebugRewriteGeneration.install("ready", in: session)
        let generation = try #require(session.generation)
        var quotes = 0
        generation.prepareQuote = { quotes += 1 }
        session.showProposal()
        #expect(session.includedVoicesSeen == [2] && session.usableTakeCount == 1 && session.task.footer.primary?.title == "Use Takes")
        // Keep phrase 3 too: several phrases, no takes. Then leave phrase 2 out: phrase 3 alone.
        session.review(3, .keep)
        #expect(session.task.footer.note?.contains("Rewrite one passage") == false)
        session.review(2, .undo)
        await settle { quotes == 1 }
        #expect(session.includedVoice == [3] && session.includedVoicesSeen == [3] && !generation.readyToAccept && quotes == 1)
        #expect(session.task.footer.primary?.title == "Prepare Takes" && session.task.footer.note?.hasPrefix("Nothing paid yet.") == true)
        #expect(await session.acceptTakes() == false && editor.project.voiceLab.segments.isEmpty)
        // Back to phrase 2 alone: its takes no longer fit either, and it is quoted again.
        session.review(2, .keep); session.review(3, .undo)
        await settle { quotes == 2 }
        #expect(session.includedVoice == [2] && session.includedVoicesSeen == [2] && quotes == 2 && session.task.footer.primary?.title == "Prepare Takes")
    }

    /// A footer drawn for one phrase's quote makes no takes of another: a Make Takes the transcript's reviews left on screen
    /// for a turn sends nothing, and the footer waits for the new phrase's quote.
    @Test func makeTakesForALeftOutPhraseSendsNothing() async throws {
        let (editor, session, _, scenes) = try scene("r2-several-voices")
        defer { scenes.forEach { $0.editor?.close() } }
        editor.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        session.review(3, .undo)
        try DebugRewriteGeneration.install("none-passed", in: session)
        let generation = try #require(session.generation)
        var quotes = 0
        generation.prepareQuote = { quotes += 1 }
        generation.prepareForTests = { _ in
            let takes = (0..<3).map { index in
                let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "take", usd: Decimal(string: "0.01"), basis: "test")
                let quote = VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: estimate, region: .default,
                                          endpoint: "test", languageMode: nil, fingerprint: "test")
                return VoiceLabTakeQuote(index: index, seed: UInt32(index), synthesis: quote, qa: quote)
            }
            return VoiceLabTakeRunQuote(id: UUID(), takes: takes, preparedAt: Date())
        }
        generation.executeForTests = { _, _, _ in
            Issue.record("No takes are made of a phrase the list left out")
            return VoiceLabTakeRunResult(rows: [], end: .cancelled)
        }
        let review = try #require(session.voiceReview(2)), window = try #require(review.window)
        await generation.prepare(VoiceLabTakeInput(text: try #require(review.patchText), modelID: try #require(generation.selectedModelID),
            recordID: try #require(generation.selectedVoiceID), language: "en", seed: 7, contentKey: "test", source: [], sourceSampleRate: 48_000,
            items: [], window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true))
        session.showProposal()
        let stale = try #require(session.task.footer.primary)
        #expect(stale.title == "Prepare Takes" && session.pricedTakeAction() == nil && generation.canExecute)
        // ⌘↩ on phrase 3 and ⌘⌫ on phrase 2 in the transcript; the list follows them on a later turn.
        editor.keepChange(3); editor.excludeChange(2)
        stale.perform()
        #expect(generation.phase != .generating)
        await settle { session.includedVoicesSeen == [3] && quotes == 1 }
        #expect(session.includedVoice == [3] && quotes == 1 && generation.quote == nil && session.task.footer.primary?.title == "Prepare Takes")
        await generation.finishGenerationForTests()
    }

    /// A phrase left out because it can't be made (Voice Lab off) has no review in the transcript either: no Keep or Undo
    /// buttons or custom actions and no edit, and ⌘↩ on it keeps and announces nothing (design.md R2). A reply that opens
    /// on such a phrase focuses the first change that waits.
    @Test func aPhraseThatCantBeMadeHasNoReviewInTheTranscript() throws {
        let (editor, session, _, scenes) = try scene("r2-voice-lab-off", voiceLab: false)
        defer { scenes.forEach { $0.editor?.close() } }
        #expect(editor.proposal?[3]?.reviewable == false && editor.proposal?[1]?.reviewable == true && editor.proposal?.focused == 1)
        editor.focusChange(3, announcing: false)
        editor.announcements = []
        #expect(editor.proposalDisplay?.focused == 3 && editor.proposalDisplay?.actions == [] && editor.changeForReturn == nil)
        #expect(!editor.keepFocusedChange() && !editor.excludeFocusedChange() && !editor.editChange(3, text: "other"))
        #expect(editor.proposal?[3]?.state == .excluded && editor.announcements.isEmpty && changes(session)?.items.last?.state == .excluded)
        // A reply that opens on a phrase in your voice.
        let words = session.source.map(\.text).compactMap { $0 == "word12" ? nil : $0 == "word10" ? "fresh" : $0 }
        try session.receivePassage(words.joined(separator: " "))
        session.finishRun(seconds: 1)
        #expect(editor.proposal?[1]?.kind == .voice && editor.proposal?[1]?.reviewable == false && editor.proposal?.focused == 2)
        #expect(editor.proposalDisplay?.focused == 2 && editor.proposalDisplay?.actions == [.keep, .undo])
    }

    /// The change list's keys (design.md §10, "Rewrite without a pointer"): Return edits the focused change and never runs
    /// the footer's primary, Space leaves the focused change out or keeps it, and ⌘Return runs the primary.
    @Test func returnEditsSpaceReviewsAndCommandReturnApplies() throws {
        let (editor, session, undo, scenes) = try scene("r2-free")
        defer { scenes.forEach { $0.editor?.close() } }
        let before = editor.project
        session.review(2, .focus)
        step(undo) { #expect(session.task.pressReturn(command: false)) }
        #expect(editor.project == before && session.isOpen && editor.proposal?.focused == 2 && undo.undoActionName.isEmpty)
        #expect(changes(session)?.items.map(\.state) == [.pending, .pending])
        #expect(session.task.pressSpace())
        #expect(changes(session)?.items.map(\.state) == [.pending, .excluded] && editor.project == before && changes(session)?.focused == 1)
        session.review(2, .focus)
        step(undo) { #expect(session.task.pressSpace()) }
        #expect(changes(session)?.items.map(\.state) == [.pending, .kept] && undo.undoActionName == "Keep change 2")
        // A kept fix is in the project: Space leaves it there.
        session.review(2, .focus)
        #expect(!session.task.pressSpace() && changes(session)?.items.last?.state == .kept)
        step(undo) { #expect(session.task.pressReturn(command: true)) }
        #expect(!session.isOpen && editor.cutWordIDs.contains("r2-12") && undo.undoActionName == "Rewrite clip 1")
    }

    /// Ask again can't run while another AI request holds the project, so it isn't offered; it comes back as that ends.
    @Test func askAgainWaitsForTheProjectsAIRequest() async throws {
        let (editor, session, _, scenes) = try scene("r2-free")
        defer { scenes.forEach { $0.editor?.close() } }
        #expect(session.task.contextAction?.id == "askAgain")
        let lease = try #require(editor.llmRuns.acquire())
        await settle { session.task.contextAction == nil }
        #expect(session.task.contextAction == nil && changes(session)?.items.count == 2)
        editor.llmRuns.release(lease)
        await settle { session.task.contextAction != nil }
        #expect(session.task.contextAction?.title == "Ask again")
    }

    /// Why Make Takes couldn't go on before takes exist (finding the voices failed) shows as R2's callout, and goes as
    /// Make Takes tries again.
    @Test func makeTakesProblemShowsInR2() async throws {
        let (_, session, _, scenes) = try scene("r2-make-takes")
        defer { scenes.forEach { $0.editor?.close() } }
        session.reportGenerationProblem(VoiceLabError.unauthorized)
        await settle { session.task.cards.count > 1 }
        #expect(session.task.cards.last == .callout("ElevenLabs rejected the key (401). Your edits are saved."))
        #expect(session.task.footer.primary?.title == "Make Takes")
        session.reportGenerationProblem(nil)
        await settle { session.task.cards.count == 1 }
        #expect(session.task.cards.count == 1)
    }
}
#endif
