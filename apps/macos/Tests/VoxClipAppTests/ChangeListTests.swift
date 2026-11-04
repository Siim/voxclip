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
@Suite("Rewrite change list", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows are shown."), .offlineFixtures)
@MainActor struct ChangeListTests {
    private func scenes() throws -> (AppModel, [DirectorScene]) {
        let app = AppModel(settingsStore: RegressionSettingsStore())
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        return (app, DebugRewrite.proposalScenes(app: app, fixture: fixture))
    }
    /// One scene, with an undo manager, its session following the transcript again.
    private func scene(_ name: String, voiceLab: Bool = true,
                       verifiablePhrases: Bool = false) throws -> (EditorModel, RewriteSession, UndoManager, [DirectorScene]) {
        let (app, all) = try scenes()
        app.settings.values["voiceLab.enabled"] = .bool(voiceLab)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(voiceLab)
        let scene = try #require(all.first { $0.name == name })
        let editor = try #require(scene.editor)
        let session = try #require(editor.openRewrite)
        if verifiablePhrases {
            let passage = session.source.compactMap { word -> String? in
                guard let index = Int(word.text.dropFirst(4)) else { return word.text }
                if index == 12 || (21...25).contains(index) || (39...43).contains(index) { return nil }
                if index == 20 || index == 38 { return "Comprehensive terminology demonstrates exceptionally natural pronunciation." }
                return word.text
            }.joined(separator: " ")
            try session.receivePassage(passage)
            session.finishRun(seconds: 14)
            for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        }
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        editor.announcements = []
        session.showProposal()
        return (editor, session, undo, all)
    }
    private func changes(_ session: RewriteSession) -> ChangeSet? { if case .proposal(let set) = session.task.state { set } else { nil } }
    private func step(_ undo: UndoManager, _ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
    /// Lets the change list follow a review made in the transcript, which reaches it on the main actor's next turns. Work
    /// off the main actor (a plan preparing its price) can take longer than a fixed number of turns on a loaded host, so
    /// after 500 turns it keeps waiting, a millisecond at a time, for up to 10 s.
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() { await Task.yield() }
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// Each footer case of design.md R2, in v2's grammar: its note, its secondary link (Keep All where changes wait for
    /// takes) and its one primary in the tint. Every R2 offers Ask again on the harness line.
    @Test func everyFooterCaseShowsItsNoteLinkAndPrimary() throws {
        let (_, scenes) = try scenes()
        defer { scenes.forEach { $0.editor?.close() } }
        let expected: [String: (note: String, link: String?, primary: String?)] = [
            "r2-free": ("No AI voice needed. Nothing is sent.", nil, "Apply 2 Changes"),
            "r2-voice-lab-off": ("1 phrase needs your voice. Voice Lab (beta) makes it from this clip.", "Turn On Voice Lab", "Apply 2 Free Changes"),
            "r2-make-takes": ("Nothing paid yet.\nTakes < $0.01 on ElevenLabs.", "Keep All", "Get Price · 1 phrase"),
            "r2-make-voice": ("Nothing paid yet. Next: make your voice from this clip. Once.", "Keep All", "Make Your Voice"),
            "r2-use-take": ("Exports show AI MODIFIED on the video. The post disclosure is optional.", nil, "Use Takes"),
            "r2-several-voices": ("Nothing paid yet.\nTakes < $0.01 on ElevenLabs.", "Keep All", "Get Price · 2 phrases"),
            "r2-over-budget": ("Change 2 needs wording that fits before takes.", "Keep All", "Apply 1 Free Change"),
            "r2-nothing-included": ("Keep a change to apply it.", nil, "Done"),
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
        #expect(budget.task.cards.contains(.callout("These changes re-voice 15 words, a lot for a \(budget.task.words.wordCount)-word clip. Long stretches in your voice can sound stitched; Rewrite goes on.")))
        let none = try #require(scenes.first { $0.name == "r2-no-changes" })
        #expect(none.task.headline.text == "No changes needed" && none.task.footer.primary?.title == "Ask for Something Else")
        #expect(none.task.cards == [.text("Claude Code found nothing to change in clip 1."), .ask(placeholder: "What should change in clip 1?")])
    }

    /// Over the voice budget Rewrite goes on (voice-lab.md §8.2): the advisory is a note, Make Takes is offered as in the
    /// budget, and the chips (Change fewer words, Keep text fixes only) wait under "Choose yourself…".
    @Test func overTheVoiceBudgetRewriteGoesOnWithANote() throws {
        let (_, session, _, scenes) = try scene("r2-over-budget")
        defer { scenes.forEach { $0.editor?.close() } }
        let collapsed = try #require(session.task.nextSteps.first { $0.id == "budget" })
        #expect(collapsed.chips.map(\.action.id) == ["chooseYourself"] && collapsed.ask == nil)
        #expect(session.task.cards.contains { if case .callout(let text) = $0 { text.hasSuffix("Rewrite goes on.") } else { false } })
        collapsed.chips[0].action.perform()
        let budget = try #require(session.task.nextSteps.first { $0.id == "budget" })
        #expect(budget.chips.map(\.action.id) == ["changeFewerWords", "keepTextFixes"])
        #expect(budget.chips.map(\.action.title) == ["Change fewer words", "Keep text fixes only"])
        #expect(budget.ask?.placeholder == NextSteps.askPlaceholder)
        // This scene's phrase still needs a fitting wording first; priced anyway, the footer makes takes.
        #expect(session.task.footer.note?.hasPrefix(session.timingBlockedNote) == true)
        for ordinal in session.blockedVoiceOrdinals { session.phraseTimingAction(.priceAnyway, ordinal: ordinal) }
        let primary = try #require(session.task.footer.primary)
        #expect(["makeTakes", "makeVoice", "prepareTakes"].contains(primary.id), "\(primary.id)")
    }

    /// Keep text fixes only applies the free changes and leaves the phrases in your voice out, as Apply does.
    @Test func overTheVoiceBudgetKeepTextFixesOnlyAppliesTheFreeChanges() throws {
        let (editor, session, _, scenes) = try scene("r2-over-budget")
        defer { scenes.forEach { $0.editor?.close() } }
        session.task.nextSteps.first { $0.id == "budget" }?.chips.first?.action.perform()
        let chip = try #require(session.task.nextSteps.first { $0.id == "budget" }?.chips.last)
        #expect(chip.action.id == "keepTextFixes")
        chip.action.perform()
        #expect(!session.isOpen && editor.openRewrite == nil && !editor.project.edits.cutWordIds.isEmpty)
    }

    /// A phrase whose takes all failed the checks says why in one sentence and offers Try another, Keep original words
    /// and the AI's suggestions; the stuck area has exactly one "Tell the AI what to do instead…" field.
    @Test func aPhraseWhoseTakesAllFailedSaysWhyAndOffersNextSteps() throws {
        let (_, session, _, scenes) = try scene("r2-make-takes")
        defer { scenes.forEach { $0.editor?.close() } }
        try DebugRewriteGeneration.install("none-passed", in: session)
        session.reasking.suggestions = [RewriteNextAction(label: "Say it plainly", instruction: "Say the phrase in plain words.")]
        session.showProposal()
        let take = try #require(session.task.nextSteps.first { $0.id == "take.0" })
        #expect(take.chips.map(\.action.id) == ["tryAnother.0", "keepOriginal.0", "surrounding.0", "suggestion.0"] && take.chips.last?.suggested == true, "\(take.chips.map(\.action.id))")
        #expect(take.line == "Phrase 1: the word check heard different words in every take.")
        #expect(session.task.nextSteps.compactMap(\.ask).count == 1 && session.task.nextSteps.last?.ask != nil)
        // Keep original words keeps the paid takes: the phrase is left out, nothing is discarded, and Undo brings it back.
        let plan = try #require(session.takePlan)
        let takes = plan.phrases[0].takes.map(\.id)
        take.chips[1].action.perform()
        #expect(session.task.confirm == nil && session.takePlan === plan && plan.phrases[0].leftOut && plan.phrases[0].takes.map(\.id) == takes)
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
        for (item, description) in zip(set.items, rotor) {
            let timing = item.timing.map { ". " + $0.copy } ?? ""
            #expect(item.spoken == description.replacingOccurrences(of: "Proposed change", with: "Change") + timing)
        }
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
        #expect(session.task.footer.primary?.title == "Get Price · 1 phrase" && session.task.footer.link == nil && session.includedVoice == [3])
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
        #expect(session.task.footer.primary?.title == "Get Price · 1 phrase" && session.task.footer.link?.title == "Keep All")
    }

    @Test func aMissingDurationChoiceIsNamedInsteadOfLeftOut() async throws {
        let (editor, session, _, scenes) = try scene("r2-several-voices", verifiablePhrases: true)
        defer { scenes.forEach { $0.editor?.close() } }
        editor.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        session.review(3, .undo)
        try DebugRewriteGeneration.install("ready", in: session)
        session.showProposal()
        let plan = try #require(session.takePlan)
        #expect(plan.stillCurrent && !plan.canAccept && session.usableTakeCount == 0)
        let note = try #require(session.task.footer.note)
        #expect(note.hasPrefix("Choose the video duration for phrase 1. ") && session.task.footer.primary == nil)
        #expect(!note.contains("Left out until a take fits."))
        #expect(plan.chooseVideo(.source, phrase: 0))
        session.showProposal()
        #expect(plan.acceptanceBlocker == nil && session.task.footer.primary?.title == "Use Takes")
        #expect(ClipTakePlan.phraseList([2]) == "phrase 2" && ClipTakePlan.phraseList([2, 4]) == "phrases 2 and 4")
        #expect(ClipTakePlan.phraseList([1, 2, 4]) == "phrases 1, 2 and 4")
    }

    @Test func takesStayWithTheirPhrase() async throws {
        let (editor, session, _, scenes) = try scene("r2-several-voices", verifiablePhrases: true)
        defer { scenes.forEach { $0.editor?.close() } }
        editor.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        #expect(session.includedVoice == [2, 3] && session.task.footer.primary?.title == "Get Price · 2 phrases")
        session.review(3, .undo)
        #expect(session.includedVoice == [2] && session.task.footer.primary?.title == "Get Price · 1 phrase")
        // Phrase 2's takes: one passed. Nothing is quoted or sent here.
        try DebugRewriteGeneration.install("ready", in: session)
        if let plan = session.takePlan {
            for index in plan.phrases.indices { #expect(plan.chooseVideo(.source, phrase: index)) }
        }
        let generation = try #require(session.generation)
        var quotes = 0
        generation.prepareQuote = { quotes += 1 }
        session.showProposal()
        let plan = try #require(session.takePlan)
        #expect(session.includedVoicesSeen == [2] && session.usableTakeCount == 1 && session.task.footer.primary?.title == "Use Takes")
        let before = editor.proposal
        session.review(3, .keep)
        #expect(session.task.confirm != nil && editor.proposal == before)
        #expect(session.takePlan === plan && plan.stillCurrent && session.usableTakeCount == 1)
        session.task.confirm?.cancel.perform()
        session.review(2, .undo)
        #expect(session.task.confirm != nil && editor.proposal == before)
        await generation.finishQuotePreparationForTests()
        #expect(session.includedVoice == [2] && session.includedVoicesSeen == [2] && quotes == 0)
        #expect(session.takePlan === plan && plan.stillCurrent && session.hasPaidTakes && plan.spent.units > 0)
        session.task.confirm?.cancel.perform()
        #expect(editor.proposal == before && session.task.footer.primary?.title == "Use Takes")
        session.review(3, .keep)
        session.task.confirm?.confirm.perform()
        #expect(plan.isRetired && session.takePlan == nil && !session.hasPaidTakes)
        session.review(2, .undo)
        await generation.finishQuotePreparationForTests()
        #expect(session.includedVoice == [3] && session.includedVoicesSeen == [3] && quotes > 0)
        #expect(!generation.readyToAccept && editor.project.voiceLab.segments.isEmpty)
        #expect(session.task.footer.primary?.title == "Get Price · 1 phrase")
    }

    /// A footer drawn for one phrase's quote makes no takes of another: a Make Takes the transcript's reviews left on screen
    /// for a turn sends nothing, and the footer waits for the new phrase's quote.
    @Test func makeTakesForALeftOutPhraseSendsNothing() async throws {
        let (editor, session, _, scenes) = try scene("r2-several-voices", verifiablePhrases: true)
        defer { scenes.forEach { $0.editor?.close() } }
        editor.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        session.review(3, .undo)
        try DebugRewriteGeneration.install("none-passed", in: session)
        let generation = try #require(session.generation)
        session.takePlan?.invalidate(); session.takePlan = nil; generation.invalidate()
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
        #expect(stale.title == "Get Price · 1 phrase" && session.pricedTakeAction() == nil && generation.canExecute)
        // ⌘↩ on phrase 3 and ⌘⌫ on phrase 2 in the transcript; the list follows them on a later turn.
        editor.keepChange(3); editor.excludeChange(2)
        stale.perform()
        #expect(generation.phase != .generating)
        await settle { session.includedVoicesSeen == [3] && quotes == 1 && session.task.footer.primary?.title == "Get Price · 1 phrase" }
        #expect(session.includedVoice == [3] && quotes == 1 && generation.quote == nil && session.task.footer.primary?.title == "Get Price · 1 phrase",
            "footer: \(session.task.footer.primary?.title ?? "none"), note: \(session.task.footer.note ?? "none")")
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
        #expect(session.task.footer.primary?.title == "Get Price · 1 phrase")
        session.reportGenerationProblem(nil)
        await settle { session.task.cards.count == 1 }
        #expect(session.task.cards.count == 1)
    }
}
#endif
