#if DEBUG
import AppKit
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private final class Calls: Sendable {
    private let value = Mutex<[String]>([])
    var all: [String] { value.withLock { $0 } }
    func record(_ call: String) { value.withLock { $0.append(call) } }
}

/// ✦ Make it postable (doc/design.md §6.6) on a demo editor with its own data folder: the planner, the voice and the
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
            plan: { request, _ in
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
        #expect(editor.makeItHeadline(run) == "Ready to post · \(durationLabel(run.editedSeconds)) · score 8/10")
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
        editor.makeIt.services?.plan = { _, _ in
            ClipAutopilotSeries(plans: [ClipAutopilotPlan(startWord: 7, endWord: 8, title: "Two", hook: "", captions: Self.plan().captions,
                music: Self.plan().music, musicPick: 0, postText: "Two.", score: 6, verdict: .casualPost)])
        }
        _ = try await run(fixture, clip: "clip-two")
        let first = try #require(MusicProject.entry(for: "clip-main", in: editor.project))
        let second = try #require(MusicProject.entry(for: "clip-two", in: editor.project))
        #expect(first.asset == second.asset && first.id != second.id && second.id == first.id + "-2")
        #expect(editor.makeIt.run(for: "clip-two")?.rows.first { $0.id == "music" }?.undoable == true)
    }

    @Test func theDriverPressesOnlyPricedStepsWithinItsBudgetAndNeverGivesUpATake() {
        #expect(MakeItRewriteDriver.pricedID("takeQuote-1") && MakeItRewriteDriver.pricedID("approveTakeQuote-1") && MakeItRewriteDriver.pricedID("keepFixing"))
        for id in ["discardChanges", "closeRewrite", "keepOriginal", "askAgain", "tryAgain", "rewriteAgain"] {
            #expect(!MakeItRewriteDriver.order.contains { id.hasPrefix($0) }, "\(id) is never pressed")
        }
    }

    @Test func clipMenuAndPaletteOfferMakeItPostable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/VoxClip/VoxClipApp.swift"), encoding: .utf8)
        #expect(app.contains("command(clip, \"Make It Postable\", 62)"))
        #expect(app.contains("case 62: if let id = makeItClipID(editor) { editor.makeItPostable(id) }"))
    }
}
#endif
