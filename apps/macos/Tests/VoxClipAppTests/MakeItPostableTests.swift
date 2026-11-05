#if DEBUG
import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private final class Calls: Sendable {
    private let value = Mutex<[String]>([])
    var all: [String] { value.withLock { $0 } }
    func record(_ call: String) { value.withLock { $0.append(call) } }
}

/// ✦ Make it postable (doc/design.md §6.7) on a demo editor with its own data folder: the planner, the voice and the
/// music sources are stubs, so nothing is sent, paid or read from the keychain.
@Suite("Make it postable", .serialized, .offlineFixtures)
@MainActor struct MakeItPostableTests {
    private struct Fixture {
        let root: URL
        let editor: EditorModel
        let undo: UndoManager
        let calls: Calls
        let original: Project
    }

    /// The fixture's words: 0 So · 1 um, · 2 today · (pause) · 3 we · 4 ship · 5 uh · 6 the · 7 clipper. · 8 Thanks; the
    /// clip "clip-main" spans 2…7.
    static func plan(music: Bool = true, rewrite: Bool = true, questions: [ClipAutopilotPlan.Question] = []) -> ClipAutopilotPlan {
        ClipAutopilotPlan(startWord: 2, endWord: 7, title: "Ship day", hook: "We ship today",
            cuts: [.init(startWord: 5, endWord: 5, kind: .filler, reason: "Filler")],
            pauseCuts: [.init(afterWord: 2, reason: "Long pause")],
            rewrites: rewrite ? [.init(startWord: 3, endWord: 4, text: "we finally ship", reason: "Stronger verb")] : [],
            captions: .init(styleId: "vox-bold", font: .init(family: "Roboto", weight: 900), textCase: .upper, wordsPerCaption: 3),
            music: music ? [.init(title: "Calm piano", mood: "calm piano", prompt: "Instrumental calm piano", reason: "Warm and quiet", underVoiceDb: 18)] : [],
            musicPick: music ? 0 : nil,
            zooms: [.init(word: 6, untilWord: 7, scale: 1.2, reason: "Punch the reveal")],
            postText: "We ship the clipper today.", score: 8, verdict: .post, scoreReason: "Clear hook, one idea",
            questions: questions)
    }

    static let library = MusicCandidate(id: "openverse-piano", source: .library, title: "Quiet piano", creator: "Artist", license: .by,
                                        attribution: "\"Quiet piano\" by Artist is licensed under CC BY 3.0.",
                                        sourceUrl: "https://www.jamendo.com/track/1", audioURL: URL(string: "https://example.com/piano.mp3"),
                                        fileExtension: "wav", durationSeconds: 120, reason: "calm, piano")
    static func generated(_ usd: String) -> MusicCandidate {
        MusicCandidate(id: "eleven-1", source: .generated, title: "Calm piano", license: .generated, fileExtension: "wav",
                       prompt: "Instrumental calm piano", durationSeconds: 30,
                       estimate: CostEstimate(provider: "elevenlabs", operation: "musicCompose", units: 30, unit: "second", usd: Decimal(string: usd), basis: "list"))
    }

    private static func wav() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-make-it-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PCMFile(url: url, rate: 48_000, channels: 2, float: false)
        try file.append(Data(count: 96_000 * 2 * 2))
        try file.finish()
        return try Data(contentsOf: url)
    }

    private func fixture(plan: ClipAutopilotPlan = Self.plan(), candidates: [MusicCandidate] = [Self.library],
                         voice: MakeItRewriteOutcome = MakeItRewriteOutcome(result: .voiced(segments: []), spent: Decimal(string: "0.01")!),
                         suggestion: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-make-it-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        if suggestion {
            let result = ProjectAIResult(id: "result-1", createdAt: Date(timeIntervalSince1970: 0), provider: "claude-code", model: "fixture",
                preset: .best, inputSha256: String(repeating: "0", count: 64),
                clips: [ProjectAIClip(title: "Suggested", reason: "Good", score: 7, startWordId: "w3", endWordId: "w8")])
            project.ai.results = [result]
            project.edits.clips = [ClipRange(id: "clip-main", startWordId: "w3", endWordId: "w8", title: "Suggested", origin: .ai,
                                             aiResultId: "result-1", aiClipIndex: 0, selected: false)]
        }
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let calls = Calls()
        let bytes = try Self.wav()
        editor.musicPanel.services = MusicPanelServices(suggest: { _, _ in MusicSuggestionResult(candidates: candidates) },
            fetch: { candidate in calls.record("fetch \(candidate.id)"); return bytes }, folder: { nil })
        editor.makeIt.services = MakeItServices(
            plan: { request, _, _ in
                calls.record("plan \(request.mode)")
                return ClipAutopilotSeries(plans: [plan])
            },
            voice: { request, _ in
                calls.record("voice \(request.text) budget \(request.budget.map { "\($0)" } ?? "none")")
                return voice
            },
            voiceAvailable: { _ in true })
        return Fixture(root: root, editor: editor, undo: undo, calls: calls, original: editor.project)
    }

    private func step(_ undo: UndoManager, _ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }

    private func run(_ fixture: Fixture, clip: String = "clip-main") async throws -> MakeItRun {
        await fixture.editor.makeIt.refreshVoiceReady(fixture.editor)
        fixture.editor.makeItPostable(clip)
        let run = try #require(fixture.editor.makeIt.run(for: clip))
        await run.task?.value
        return run
    }

    @Test func oneClickAppliesEveryKindOfDecisionAndListsItInTheReview() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let run = try await run(fixture)
        #expect(run.phase == .ready)
        #expect(run.lines.prefix(4) == ["Reading the clip…", "Making 2 cuts…", "Voicing 1 fix…", "Picking music…"])
        let project = editor.project
        #expect(project.edits.cutWordIds.contains("w6"), "the filler is cut")
        #expect(!project.edits.cutPauseIds.isEmpty, "the long pause is tightened")
        #expect(project.edits.clips.first { $0.id == "clip-main" }?.title == "Ship day")
        #expect(project.captions.styleId == "vox-bold" && project.captions.overrides["text"]?.aiObject?["transform"] == .string("uppercase"))
        #expect(project.motionCues.map(\.id) == ["clip-main-zoom-0"])
        #expect(project.share.captions["clip-main"] == "We ship the clipper today.")
        let music = try #require(MusicProject.entry(for: "clip-main", in: project))
        #expect(music.title == "Quiet piano" && music.gainDb == -18)
        #expect(fixture.calls.all.contains("fetch openverse-piano"))
        #expect(fixture.calls.all.contains { $0.hasPrefix("voice we finally ship budget ") })
        let ids = run.rows.map(\.id)
        for id in ["cut-0", "pause-0", "title", "rewrite-0", "captions", "zoom-0", "music", "hook"] { #expect(ids.contains(id), "row \(id)") }
        #expect(run.rows.first { $0.id == "captions" }?.text.hasPrefix("Claude chose ") == true)
        #expect(run.rows.first { $0.id == "rewrite-0" }?.text == "Voiced “we finally ship” in your voice")
        #expect(run.postText.hasPrefix("We ship the clipper today.") && run.postText.contains("Quiet piano"), "the music credit joins the post text")
        #expect(editor.makeItHeadline(run) == "Ready to post · \(durationLabel(run.seconds)) · score 8/10")
        #expect(editor.makeItNextStep(run) == "Next: Export. The post text is copied with it.")
        #expect(editor.makeIt.scores["clip-main"]?.score == 8)
    }

    @Test func theWholeRunIsOneUndoStepAndEachDecisionUndoesOnItsOwn() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let steps = editor.undoSteps
        let run = try await run(fixture)
        #expect(editor.undoSteps == steps + 1, "one undo step for the whole run")
        #expect(fixture.undo.undoActionName == "Make it postable")
        // Undo one: only the filler comes back.
        let cutRow = try #require(run.rows.first { $0.id == "cut-0" })
        #expect(cutRow.undoable && cutRow.play != nil)
        step(fixture.undo) { editor.makeItUndo("cut-0", in: run) }
        #expect(!editor.project.edits.cutWordIds.contains("w6") && editor.project.motionCues.count == 1 && editor.project.captions.styleId == "vox-bold")
        #expect(run.rows.first { $0.id == "cut-0" }?.undone == true)
        step(fixture.undo) { editor.makeItUndo("captions", in: run) }
        #expect(editor.project.captions == fixture.original.captions)
        // ⌘Z takes back the row undos, then the whole run in one step.
        fixture.undo.undo(); fixture.undo.undo()
        #expect(editor.project.edits.cutWordIds.contains("w6"))
        fixture.undo.undo()
        #expect(editor.project.edits == fixture.original.edits)
        #expect(editor.project.captions == fixture.original.captions && editor.project.motionCues == fixture.original.motionCues)
        #expect(editor.project.share == fixture.original.share && editor.project.music == fixture.original.music)
        fixture.undo.redo()
        #expect(editor.project.edits.cutWordIds.contains("w6") && editor.project.motionCues.count == 1)
    }

    @Test func undoAllTakesBackEveryDecisionAsOneStep() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let run = try await run(fixture)
        let steps = editor.undoSteps
        editor.makeItUndoAll(run)
        #expect(editor.undoSteps == steps + 1)
        #expect(editor.project.edits.cutWordIds == fixture.original.edits.cutWordIds && editor.project.captions == fixture.original.captions)
        #expect(editor.project.motionCues == fixture.original.motionCues && editor.project.music == fixture.original.music)
        #expect(editor.project.share.captions["clip-main"] == fixture.original.share.captions["clip-main"])
        #expect(editor.project.clipEffects == fixture.original.clipEffects, "the hook's card goes too")
        #expect(editor.makeIt.run(for: "clip-main") == nil)
    }

    @Test func thePriceIsTheCapAndAPriceAboveWhatIsLeftStopsBeforeThatStep() async throws {
        // No free track fits; the generated one costs more than this click's whole cap.
        let fixture = try fixture(candidates: [Self.generated("0.50")])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        await editor.makeIt.refreshVoiceReady(editor)
        let cap = try #require(editor.makeItCap(clipID: "clip-main"))
        #expect(cap < Decimal(string: "0.50")!)
        #expect(editor.makeItTitle(clipID: "clip-main") == "✦ Make it postable · up to " + EditorModel.makeItDollars(cap))
        let run = try await run(fixture)
        #expect(run.cap == cap)
        #expect(!fixture.calls.all.contains { $0.hasPrefix("fetch") }, "the generated track is never made")
        #expect(MusicProject.entry(for: "clip-main", in: editor.project) == nil)
        let row = try #require(run.rows.first { $0.id == "music" })
        #expect(row.kind == .note && row.detail.contains("cap"))
        #expect(fixture.calls.all.contains("voice we finally ship budget \(cap)"), "the voice gets the whole cap first")
        #expect(run.spent <= cap)
    }

    @Test func aVoiceStepPastTheCapKeepsTheWordsAndSaysWhy() async throws {
        let fixture = try fixture(voice: MakeItRewriteOutcome(result: .overCap(nextUSD: Decimal(string: "0.20")), spent: 0))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let run = try await run(fixture)
        let row = try #require(run.rows.first { $0.id == "rewrite-0" })
        #expect(row.kind == .note && row.text == "Kept your words for “we finally ship”" && !row.undoable)
        #expect(row.detail.contains("$0.20") && row.change == .phrase(3...4))
        #expect(run.phase == .ready, "the rest of the plan still applies")
    }

    @Test func nothingThatCostsMoneyMeansNoAmountOnTheButton() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        editor.makeIt.style = MakeItStyle(generatedMusic: false)
        editor.makeIt.services?.voiceAvailable = { _ in false }
        await editor.makeIt.refreshVoiceReady(editor)
        #expect(editor.makeItCap(clipID: "clip-main") == nil)
        #expect(editor.makeItTitle(clipID: "clip-main") == "✦ Make it postable")
    }

    @Test func aQuestionShowsItsPrePickedAnswerAndNeverBlocks() async throws {
        let question = ClipAutopilotPlan.Question(question: "Is it “clipper” or “Clipper”?", answer: "Clipper", options: ["clipper", "Clipper"])
        let fixture = try fixture(plan: Self.plan(questions: [question]))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let run = try await run(fixture)
        #expect(run.phase == .ready)
        let row = try #require(run.rows.first { $0.id == "question-0" })
        #expect(row.kind == .question && row.text == question.question && row.detail == "Claude chose “Clipper”")
        #expect(row.options == ["clipper"])
        editor.makeItChange(.question(0), run: run)
        #expect(run.openQuestion == 0, "Change shows the other answers inline")
        editor.makeItAnswer("clipper", question: 0, run: run)
        let again = try #require(editor.makeIt.run(for: "clip-main"))
        await again.task?.value
        #expect(fixture.calls.all.filter { $0.hasPrefix("plan") }.count == 2)
        #expect(again.phase == .ready)
    }

    @Test func aSuggestedClipIsKeptFirstInTheSameUndoStep() async throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        #expect(editor.isSuggestion("clip-main") && editor.suggestionScore(editor.suggestedClips[0]) == 7)
        let steps = editor.undoSteps
        let run = try await run(fixture)
        #expect(run.phase == .ready)
        #expect(!editor.isSuggestion("clip-main") && editor.keptClips.map(\.id) == ["clip-main"])
        #expect(editor.undoSteps == steps + 1, "keep and every decision are one step")
        fixture.undo.undo()
        #expect(editor.isSuggestion("clip-main") && editor.project.edits.cutWordIds == fixture.original.edits.cutWordIds)
    }

    @Test func suggestionsRankByThePlannersScoreThenFindClips() throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        var project = editor.project
        project.ai.results[0].clips.append(ProjectAIClip(title: "Better", reason: "Best", score: 9, startWordId: "w1", endWordId: "w2"))
        project.edits.clips.append(ClipRange(id: "clip-early", startWordId: "w1", endWordId: "w2", title: "Better", origin: .ai,
                                             aiResultId: "result-1", aiClipIndex: 1, selected: false))
        step(fixture.undo) { editor.replace(project, name: "Find clips") }
        #expect(editor.suggestedClips.map(\.id) == ["clip-early", "clip-main"], "9 before 7")
        editor.makeIt.record(score: 10, verdict: .postFirst, for: "clip-main")
        #expect(editor.suggestedClips.map(\.id) == ["clip-main", "clip-early"], "the planner's score wins once it has one")
    }

    @Test func stopEndsAtTheNextSafePointAndKeepsWhatIsDone() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        editor.makeIt.services?.voice = { _, editor in
            editor.stopMakeIt()
            return MakeItRewriteOutcome(result: .voiced(segments: []), spent: 0)
        }
        let run = try await run(fixture)
        #expect(run.phase == .stopped)
        #expect(editor.project.edits.cutWordIds.contains("w6"), "the cuts made before Stop stay")
        #expect(MusicProject.entry(for: "clip-main", in: editor.project) == nil, "music came after Stop and was never added")
        #expect(editor.makeItHeadline(run) == "Stopped · what was done is kept")
    }

    /// A series uses the same free track on several clips: each clip keeps its own entry (found by the series capture,
    /// where the third clip's music failed as a duplicate id).
    @Test func theSameTrackCanSitUnderTwoClips() async throws {
        let fixture = try fixture(plan: Self.plan(rewrite: false))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        _ = try await run(fixture)
        step(fixture.undo) {
            editor.apply(.addClip(ClipRange(id: "clip-two", startWordId: "w8", endWordId: "w9", title: "Two", origin: .manual, selected: true)), name: "Make clip")
        }
        editor.makeIt.services?.plan = { _, _, _ in
            ClipAutopilotSeries(plans: [ClipAutopilotPlan(startWord: 7, endWord: 8, title: "Two", hook: "", captions: Self.plan().captions,
                music: Self.plan().music, musicPick: 0, postText: "Two.", score: 6, verdict: .casualPost)])
        }
        _ = try await run(fixture, clip: "clip-two")
        let first = try #require(MusicProject.entry(for: "clip-main", in: editor.project))
        let second = try #require(MusicProject.entry(for: "clip-two", in: editor.project))
        #expect(first.asset == second.asset && first.id != second.id && second.id == first.id + "-2")
        #expect(editor.makeIt.run(for: "clip-two")?.rows.first { $0.id == "music" }?.undoable == true)
    }

    /// Planner v2: a misheard word is corrected through `correct` and undoes on its own. The look and the speed render
    /// (clip controls, design.md §6.9): both apply in the run's one undo step, each row's Undo takes back only its own
    /// choice, a chip under Change applies another as one undo step, and the headline and the export use the rendered
    /// length (edited ÷ speed).
    @Test func correctionsApplyAndTheLookAndSpeedRender() async throws {
        var plan = Self.plan(music: false, rewrite: false)
        plan.corrections = [.init(word: 7, heard: "clipper.", text: "Clipper.", reason: "The product's name")]
        plan.look = .init(id: .warm, reason: "Friendly")
        plan.speed = .init(rate: 1.1, reason: "A slow start")
        plan.seconds = 62
        plan.flags = [.init(kind: .overLength, detail: "62 s is over 60 s.")]
        let fixture = try fixture(plan: plan)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let steps = editor.undoSteps
        let run = try await run(fixture)
        #expect(editor.undoSteps == steps + 1, "the look and the speed join the run's one undo step")
        #expect(editor.project.edits.corrections["w8"] == "Clipper.")
        let correction = try #require(run.rows.first { $0.id == "correction-0" })
        #expect(correction.text == "Corrected “clipper.” → “Clipper.”" && correction.undoable && correction.play != nil)
        // Both are on the clip, as the Clip section sets them.
        let controls = try #require(editor.project.clipControls.first { $0.clipId == "clip-main" })
        #expect(controls.look == .warm && controls.speed == 1.1)
        let clipStart = try #require(editor.words.first { $0.id == "w3" }).start
        let look = try #require(run.rows.first { $0.id == "look" })
        #expect(look.kind == .choice && look.text == "Claude chose the warm look" && look.detail == "Friendly")
        #expect(look.change == .look && look.undoable && look.play == max(0, clipStart - 0.5))
        #expect(look.options == ["original", "muted", "black and white"])
        let speed = try #require(run.rows.first { $0.id == "speed" })
        #expect(speed.text == "Claude chose 1.1× speed" && speed.change == .speed && speed.undoable && speed.play == look.play)
        #expect(speed.options == ["0.75×", "1×", "1.25×", "1.5×", "2×"])
        // The headline and the export use the rendered length.
        let edited = editor.editedDuration(editor.project.edits.clips.first { $0.id == "clip-main" })
        #expect(abs(run.seconds - edited / 1.1) < 1e-9 && edited > 0)
        #expect(editor.makeItHeadline(run) == "Ready to post · \(durationLabel(edited / 1.1)) · score 8/10")
        let request = try await editor.renderRequest(target: .clip("clip-main"))
        #expect(request.clipControls?.speed == 1.1 && request.clipControls?.look == .warm)
        #expect(abs(request.renderedDuration - run.seconds) < 0.001, "\(request.renderedDuration) vs \(run.seconds)")
        let notes = editor.makeItLengthNotes(run)
        #expect(notes.first == "Claude's cut: \(durationLabel(62)) finished at 1.1×")
        #expect(notes.contains("⚠ 62 s is over 60 s."))

        // Change on the speed row shows the other speeds; a chip applies at once as one undo step.
        editor.makeItChange(.speed, run: run)
        #expect(run.openChoice == "speed")
        let chosen = editor.undoSteps
        step(fixture.undo) { editor.makeItChoose("1.25×", rowID: "speed", run: run) }
        #expect(editor.undoSteps == chosen + 1 && fixture.undo.undoActionName == "Change speed")
        #expect(ClipControlsProject.controls(for: "clip-main", in: editor.project)?.speed == 1.25)
        let changed = try #require(run.rows.first { $0.id == "speed" })
        #expect(changed.text == "You chose 1.25× speed" && changed.options.contains("1.1×") && !changed.options.contains("1.25×"))
        #expect(run.openChoice == nil && abs(run.seconds - edited / 1.25) < 1e-9)
        editor.makeItChange(.look, run: run)
        #expect(run.openChoice == "look")
        step(fixture.undo) { editor.makeItChoose("black and white", rowID: "look", run: run) }
        #expect(ClipControlsProject.controls(for: "clip-main", in: editor.project)?.look == .bw)
        #expect(run.rows.first { $0.id == "look" }?.text == "You chose the black and white look")
        // Undo on the look row goes back to the clip's look before the run; the speed stays.
        step(fixture.undo) { editor.makeItUndo("look", in: run) }
        #expect(ClipControlsProject.controls(for: "clip-main", in: editor.project)?.look == .original)
        #expect(ClipControlsProject.controls(for: "clip-main", in: editor.project)?.speed == 1.25)
        #expect(run.rows.first { $0.id == "look" }?.undone == true)
        // And the speed row's Undo goes back to 1×, the clip's speed before the run.
        step(fixture.undo) { editor.makeItUndo("speed", in: run) }
        #expect(editor.project.clipControls.isEmpty && abs(run.seconds - edited) < 1e-9)
        // ⌘Z brings the speed back.
        fixture.undo.undo()
        #expect(ClipControlsProject.controls(for: "clip-main", in: editor.project)?.speed == 1.25)
        step(fixture.undo) { editor.makeItUndo("correction-0", in: run) }
        #expect(editor.project.edits.corrections["w8"] == nil)
        // Undo all takes back the rest.
        editor.makeItUndoAll(run)
        #expect(editor.project.edits.corrections["w8"] == nil && editor.makeIt.run(for: "clip-main") == nil)
    }

    /// The hook is a title card (design.md §6.7): the run adds it in its one undo step over the clip's first ~2 s, its row
    /// comes last with ▶ and Undo, Change edits its text inline as one undo step, Undo removes the card, and the post text
    /// still opens with the hook.
    @Test func theHookIsATitleCardWithInlineChangeAndUndo() async throws {
        let fixture = try fixture(plan: Self.plan(music: false, rewrite: false))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let steps = editor.undoSteps
        let run = try await run(fixture)
        #expect(editor.undoSteps == steps + 1, "the card joins the run's one undo step")
        let card = try #require(ClipHookTitle.existing(clipID: "clip-main", in: editor.project))
        #expect(card.kind == .title && card.text == "We ship today" && card.position == .top && card.clipId == "clip-main")
        // The first ~2 s of the clip as it renders: from just before its first frame to two edited seconds later.
        let timeline = try RenderCallerInputs.timeline(project: editor.project, clipID: "clip-main")
        #expect(abs(timeline.mapTime(card.end) - min(2, timeline.duration)) < 0.01)
        #expect(card.start <= timeline.sourceTime(0) && card.opacity(at: timeline.sourceTime(0)) > 0.999)
        // It renders: the clip's render request carries it.
        let request = try await editor.renderRequest(target: .clip("clip-main"))
        #expect(request.effects?.picture.contains(card) == true)
        let row = try #require(run.rows.last)
        #expect(row.id == "hook" && row.kind == .choice && row.text == "Claude chose the hook “We ship today”")
        #expect(row.detail == "Title card for the first 2 s · the post text keeps it" && row.undoable && row.change == .hook && row.play != nil)
        #expect(!row.detail.contains("once title cards ship"))
        #expect(editor.makeItPostCopy(run) == "We ship today\n\nWe ship the clipper today.")

        try await ReviewCaptures.capture(MakeItPanel(model: editor, run: run).environment(editor.app), name: "make-it-hook-row", size: CGSize(width: 404, height: 760))
        // Change opens the row's field; Return applies the new text to the card as one undo step.
        editor.makeItChange(.hook, run: run)
        #expect(run.openChoice == "hook")
        try await ReviewCaptures.capture(MakeItPanel(model: editor, run: run).environment(editor.app), name: "make-it-hook-change", size: CGSize(width: 404, height: 760))
        let changed = editor.undoSteps
        step(fixture.undo) { editor.makeItSetHook("  Ship it today ", rowID: "hook", run: run) }
        #expect(editor.undoSteps == changed + 1 && fixture.undo.undoActionName == "Change hook" && run.openChoice == nil)
        #expect(ClipHookTitle.existing(clipID: "clip-main", in: editor.project)?.text == "Ship it today")
        #expect(run.rows.last?.text == "You chose the hook “Ship it today”" && editor.makeItPostCopy(run).hasPrefix("Ship it today\n\n"))
        // The same text again changes nothing.
        editor.makeItSetHook("Ship it today", rowID: "hook", run: run)
        #expect(editor.undoSteps == changed + 1)
        // Undo removes the card; the post text still carries the hook.
        step(fixture.undo) { editor.makeItUndo("hook", in: run) }
        #expect(ClipHookTitle.existing(clipID: "clip-main", in: editor.project) == nil && run.rows.last?.undone == true)
        #expect(editor.makeItPostCopy(run).hasPrefix("Ship it today\n\n"))
        // ⌘Z brings the card back; ⌘Z twice more goes back to the clip before the run.
        fixture.undo.undo()
        #expect(ClipHookTitle.existing(clipID: "clip-main", in: editor.project)?.text == "Ship it today")
        fixture.undo.undo(); fixture.undo.undo()
        #expect(editor.project.clipEffects == fixture.original.clipEffects)
    }

    /// ClipStyle (design.md §6.6): a fixed caption style is the planner's preference, Auto leaves it to Claude, Off keeps
    /// the captions; music Off adds none; Rewording Off keeps the words; Length and Rewording go in the note; Shape is
    /// Export's shapes.
    @Test func theClipStyleDecidesWhatThePlannerMayChange() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        var notes: [String?] = [], preferences: [String?] = []
        editor.makeIt.services?.plan = { request, _, _ in
            notes.append(request.note); preferences.append(request.captionPreference?.styleId)
            return ClipAutopilotSeries(plans: [Self.plan()])
        }
        let auto = try #require(editor.cardClipStyle)
        #expect(editor.makeItStyle == MakeItStyle(auto))
        #expect(editor.makeItStyle.captionPreference == nil && editor.makeItStyle.shapes == auto.shapes)
        var fixed = auto
        fixed.captions = .style("marker"); fixed.music = .off; fixed.rewording = .off; fixed.maxLengthSec = 30; fixed.shapes = [.portrait]
        var project = editor.project
        project.clipStyle = fixed
        step(fixture.undo) { editor.replace(project, name: "Choose clip style") }
        let run = try await run(fixture)
        #expect(preferences == ["marker"])
        #expect(notes.first??.contains("at most 30 s") == true && notes.first??.contains("Never reword") == true)
        #expect(run.rows.first { $0.id == "rewrite-0" }?.kind == .note, "Rewording Off: the words stay")
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice") })
        #expect(MusicProject.entry(for: "clip-main", in: editor.project) == nil && run.rows.first { $0.id == "music" } == nil)
        #expect(editor.makeItStyle.shapes == [.portrait])
        var off = fixed
        off.captions = .off
        #expect(MakeItStyle(off).captions == false && MakeItStyle(off).captionPreference == nil)
    }

    /// ✦ Make top 3 postable sends one `.clips` request (planned three at once on the lanes), then applies each clip as its
    /// own run and undo step, kept first, best first.
    @Test func makeTopThreeIsOneClipsRequestAndOneStepPerClip() async throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        var project = editor.project
        project.ai.results[0].clips.append(ProjectAIClip(title: "Early", reason: "Best", score: 9, startWordId: "w1", endWordId: "w2"))
        project.edits.clips.append(ClipRange(id: "clip-early", startWordId: "w1", endWordId: "w2", title: "Early", origin: .ai,
                                             aiResultId: "result-1", aiClipIndex: 1, selected: false))
        step(fixture.undo) { editor.replace(project, name: "Find clips") }
        var modes: [ClipAutopilotRequest.Mode] = []
        editor.makeIt.services?.plan = { request, _, progress in
            modes.append(request.mode)
            progress(.planning(clip: 0, of: 2)); progress(.planning(clip: 1, of: 2))
            // Ranked by score, as the service returns them.
            return ClipAutopilotSeries(plans: [
                ClipAutopilotPlan(startWord: 0, endWord: 1, title: "Early", hook: "", captions: Self.plan().captions, postText: "Early.", score: 9, verdict: .postFirst),
                Self.plan(music: false, rewrite: false)])
        }
        await editor.makeIt.refreshVoiceReady(editor)
        let steps = editor.undoSteps
        editor.makeTopPostable(3)
        #expect(editor.makeIt.series == ["clip-early", "clip-main"])
        await editor.makeIt.waitForQueue()
        #expect(modes == [.clips([0...1, 2...7])])
        #expect(editor.makeIt.run(for: "clip-early")?.phase == .ready && editor.makeIt.run(for: "clip-main")?.phase == .ready)
        #expect(editor.makeIt.run(for: "clip-early")?.lines.first == "Waiting for Claude…")
        #expect(editor.makeIt.run(for: "clip-early")?.lines.contains("Reading clip 1 of 2…") == true)
        #expect(editor.keptClips.map(\.id).sorted() == ["clip-early", "clip-main"] && editor.undoSteps == steps + 2)
    }

    @Test func theDriverPressesOnlyPricedStepsWithinItsBudgetAndNeverGivesUpATake() {
        #expect(MakeItRewriteDriver.pricedID("takeQuote-1") && MakeItRewriteDriver.pricedID("approveTakeQuote-1") && MakeItRewriteDriver.pricedID("keepFixing"))
        for id in ["discardChanges", "closeRewrite", "keepOriginal", "askAgain", "tryAgain", "rewriteAgain"] {
            #expect(!MakeItRewriteDriver.order.contains { id.hasPrefix($0) }, "\(id) is never pressed")
        }
    }

    // MARK: Tones (design.md §6.6 Tone row, §6.7 review row)

    @Test func theCardsToneReachesThePlannerAndNeverRewordDisablesIt() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        // No clip style yet: Auto offers the catalogue's tones.
        guard case .auto(let offered)? = editor.makeItRequest("clip-main")?.tone else { Issue.record("not auto"); return }
        #expect(offered.map(\.id).first == "viral-youtuber" && offered.count == 8)
        // The card's Tone row stores the tone with the clip style and the Settings default.
        step(fixture.undo) { editor.updateClipStyle { $0.tone = .tone("viral-youtuber") } }
        #expect(editor.project.clipStyle?.tone == .tone("viral-youtuber") && editor.savedClipStyle?.tone == .tone("viral-youtuber"))
        guard case .fixed(let tone)? = editor.makeItRequest("clip-main")?.tone else { Issue.record("not fixed"); return }
        #expect(tone.id == "viral-youtuber" && tone.title == "Viral YouTuber")
        #expect(editor.makeItStyle.plannerNote?.contains("or what the tone needs") == true)
        // A tone this Mac does not know plans as Auto.
        step(fixture.undo) { editor.updateClipStyle { $0.tone = .tone("my-gone") } }
        if case .auto? = editor.makeItRequest("clip-main")?.tone {} else { Issue.record("an unknown tone should plan as Auto") }
        // Rewording "Never reword" keeps the words: the planner gets As I said it whatever the tone.
        step(fixture.undo) { editor.updateClipStyle { $0.tone = .tone("funny"); $0.rewording = .off } }
        #expect(editor.makeItRequest("clip-main")?.tone == .asSaid && editor.project.clipStyle?.tone == .tone("funny"))
        let row = ClipStyleToneRow(editor: editor, style: try #require(editor.project.clipStyle))
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/ClipStyleToneRow.swift"), encoding: .utf8)
        #expect(source.contains(".disabled(never || catalog == nil)") && source.contains("Rewording is “Never reword”"))
        // A preset chip keeps the card's Tone.
        step(fixture.undo) { editor.chooseClipPreset(.punchy) }
        #expect(editor.project.clipStyle?.tone == .tone("funny") && editor.project.clipStyle?.preset == .punchy)
    }

    @Test func theReviewNamesTheToneAndChangeReplansInOneUndoStep() async throws {
        var plan = Self.plan(music: false)
        plan.tone = .init(id: "viral-youtuber", title: "Viral YouTuber", summary: "Hook first, two lines tightened")
        let fixture = try fixture(plan: plan, voice: MakeItRewriteOutcome(result: .voiced(segments: []), spent: Decimal(string: "0.18")!))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let tones = Calls()
        let services = try #require(editor.makeIt.services)
        editor.makeIt.services = MakeItServices(plan: { request, editor, progress in
            tones.record(request.tone.map { tone -> String in
                switch tone { case .auto: "auto"; case .asSaid: "as-said"; case .fixed(let tone): tone.id }
            } ?? "none")
            return try await services.plan(request, editor, progress)
        }, voice: services.voice, voiceAvailable: services.voiceAvailable)
        var first = try await run(fixture)
        #expect(first.phase == .ready)
        let row = try #require(first.rows.first)
        #expect(row.id == "tone" && row.text == "✦ Claude wrote it as Viral YouTuber")
        #expect(row.detail == "Hook first, two lines tightened · voiced 1 phrase, $0.18")
        #expect(row.change == .tone && row.undoable && row.play != nil)
        // Change shows the tones as chips (the catalogue, then As I said it), not Rewrite's fixes.
        editor.makeItChange(.tone, run: first)
        #expect(first.openChoice == "tone")
        #expect(editor.makeItToneChoices.map(\.id) == ["viral-youtuber", "punchy-reel", "storyteller", "clear-explainer", "linkedin-pro",
                                                       "funny", "hype-launch", "calm-sincere", "as-said"])
        // Picking Punchy Reel takes this clip's decisions back and plans it again in that tone: one undo step.
        let afterFirst = editor.project, steps = editor.undoSteps
        editor.makeItChooseTone("punchy-reel", run: first)
        first = try #require(editor.makeIt.run(for: "clip-main"))
        await first.task?.value
        #expect(first.phase == .ready)
        #expect(tones.all == ["auto", "punchy-reel"])
        #expect(editor.undoSteps == steps + 1 && fixture.undo.undoActionName == "Change tone")
        // The second plan's request also kept the run's cap rules: voicing went through the stub within a budget.
        #expect(fixture.calls.all.filter { $0.hasPrefix("voice we finally ship budget ") }.count == 2)
        fixture.undo.undo()
        #expect(editor.project == afterFirst)
        fixture.undo.redo()
        // As I said it takes the tone's rewording back and names the creator's choice.
        let ready = try #require(editor.makeIt.run(for: "clip-main"))
        editor.makeItChooseTone("as-said", run: ready)
        #expect(ready.rows.first?.text == "You chose As I said it" && ready.rows.first?.change == nil)
    }

    @Test func clipMenuAndPaletteOfferMakeItPostable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/VoxClipApp.swift"), encoding: .utf8)
        #expect(app.contains("command(clip, \"Make It Postable\", 62)"))
        #expect(app.contains("case 62: if let id = makeItClipID(editor) { editor.makeItPostable(id) }"))
    }
}
#endif
