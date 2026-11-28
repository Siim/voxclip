#if DEBUG
import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

@MainActor private final class StopCount { var count = 0 }

private final class Calls: Sendable {
    private let value = Mutex<[String]>([])
    var all: [String] { value.withLock { $0 } }
    func record(_ call: String) { value.withLock { $0.append(call) } }
}

private struct RefusingAssetHTTP: MusicHTTP {
    let calls: Calls

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.record("asset request")
        throw URLError(.unsupportedURL)
    }
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

    private func fixture(plan: ClipAutopilotPlan = Self.plan(), candidates: [MusicCandidate]? = nil,
                         notes: [MusicSource: String] = [:],
                         voice: MakeItRewriteOutcome = MakeItRewriteOutcome(result: .voiced(segments: []), spent: Decimal(string: "0.01")!),
                         suggestion: Bool = false, projectFixture: String = "passage-render-v3") throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-make-it-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/\(projectFixture).voxclip")))
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
        let available = candidates ?? (plan.music.isEmpty ? [] : [Self.library])
        editor.musicPanel.services = MusicPanelServices(suggest: { brief, _ in
            calls.record("music search \(brief.searchText)"); return MusicSuggestionResult(candidates: available, notes: notes)
        }, fetch: { candidate in calls.record("fetch \(candidate.id)"); return bytes }, folder: { root.appendingPathComponent("source-music") })
        editor.makeIt.services = MakeItServices(
            plan: { request, _, _, _ in
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

    @Test func anIllustrationOverTheCapDoesNotDispatch() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = MakeItRun(clipID: "clip-main", cap: 0)
        let asset = ClipPlanAsset(id: "fixture-illustration", kind: .illustration, clipID: run.clipID, start: 1, end: 2, text: "a paper boat")
        let operation = ClipAutopilotOperation(id: "fixture-illustration", decision: .overlay, action: .asset(asset), reason: "Show the example.")
        let row = await fixture.editor.makeItAssetStep(asset, operation: operation, run: run, client: ClipPlanAssets(http: RefusingAssetHTTP(calls: fixture.calls)))
        #expect(row.text.contains("over the spend cap"))
        #expect(fixture.calls.all.isEmpty)
        #expect(fixture.editor.project.clipEffects == fixture.original.clipEffects)
    }

    private func run(_ fixture: Fixture, clip: String = "clip-main") async throws -> MakeItRun {
        await fixture.editor.makeIt.refreshVoiceReady(fixture.editor)
        fixture.editor.makeItPostable(clip)
        let run = try #require(fixture.editor.makeIt.run(for: clip))
        await run.task?.value
        return run
    }

    @Test func changingMusicOpensThePlannerAlternativesWithoutFetchingOrReplacingTheTrack() throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, run = MakeItRun(clipID: "clip-main", cap: nil)
        var plan = Self.plan()
        plan.music.append(.init(title: "Night drive", mood: "soft synth pulse", prompt: "Low instrumental synth pulse",
                                reason: "Keeps pace with the reveal", underVoiceDb: 20))
        plan.musicPick = 1
        run.plan = plan
        var opened: PanelJob?
        editor.onShowPanelJob = { opened = $0 }
        let original = editor.project.music, previousSteps = editor.undoSteps
        editor.makeItChange(.music, run: run)
        let choices = editor.musicPanel.directions
        #expect(opened == .music)
        #expect(choices.prefix(2).map(\.mood) == ["Night drive", "Calm piano"])
        #expect(choices.first?.query == "soft synth pulse" && choices.first?.prompt == "Low instrumental synth pulse")
        #expect(fixture.calls.all.isEmpty && original == editor.project.music && editor.undoSteps == previousSteps)
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
        // The caption look is the clip's own pick (design.md §6.6); the project default stays.
        let look = project.captionSettings(forClip: "clip-main")
        #expect(look.styleId == "vox-bold" && look.overrides["text"]?.aiObject?["transform"] == .string("uppercase"))
        #expect(project.captions == fixture.original.captions)
        #expect(project.clipStyle?.captionPicks["clip-main"]?.by == .ai)
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

    @Test func directionalZoomReviewNamesTheActualPhraseAndOpensTheSavedCue() async throws {
        var plan = Self.plan(music: false, rewrite: false)
        plan.zooms = [.init(word: 6, untilWord: 7, scale: 1.12, reason: "Release on the reveal", direction: .zoomOut)]
        let fixture = try fixture(plan: plan)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let run = try await run(fixture)
        let cue = try #require(fixture.editor.project.motionCues.first)
        let row = try #require(run.rows.first { $0.id == "zoom-0" })
        let change = try #require(row.change)
        #expect(cue.id == "clip-main-zoom-6-7" && change == .motion(cueID: cue.id))
        #expect(row.text == "Zoom out from 1.12×" && row.detail == "“the clipper.” · Release on the reveal")
        fixture.editor.makeItChange(change, run: run)
        #expect(fixture.editor.motionCueEditing?.draft.original == cue)
    }

    @Test(arguments: [true, false])
    func plannerDoesNotApplyAfterTranscriptOrClipRangeChanges(retimeTranscript: Bool) async throws {
        let plan = Self.plan(music: false, rewrite: false)
        let fixture = try fixture(plan: plan)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        var services = try #require(fixture.editor.makeIt.services)
        services.plan = { _, model, _, _ in
            var changed = model.project
            if retimeTranscript { changed.transcript?.words[6].start += 0.01 }
            else { changed.edits.clips[0].startWordId = "w4" }
            model.document.replaceProject(changed)
            model.refresh()
            return ClipAutopilotSeries(plans: [plan])
        }
        fixture.editor.makeIt.services = services
        let run = try await run(fixture)
        #expect(run.phase == .failed("This clip changed. Nothing was changed."))
        #expect(run.rows.isEmpty && fixture.editor.project.motionCues.isEmpty)
        #expect(fixture.editor.project.edits.cutWordIds == fixture.original.edits.cutWordIds)
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
        #expect(!editor.project.edits.cutWordIds.contains("w6") && editor.project.motionCues.count == 1)
        #expect(editor.project.captionSettings(forClip: "clip-main").styleId == "vox-bold")
        #expect(run.rows.first { $0.id == "cut-0" }?.undone == true)
        step(fixture.undo) { editor.makeItUndo("captions", in: run) }
        #expect(editor.project.captionSettings(forClip: "clip-main") == fixture.original.captions)
        #expect(editor.project.clipStyle?.captionPicks["clip-main"] == nil)
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
        #expect(editor.project.captionSettings(forClip: "clip-main") == fixture.original.captions)
        #expect(editor.project.motionCues == fixture.original.motionCues && editor.project.music == fixture.original.music)
        #expect(editor.project.share.captions["clip-main"] == fixture.original.share.captions["clip-main"])
        #expect(editor.project.clipEffects == fixture.original.clipEffects, "the hook's card goes too")
        #expect(editor.makeIt.run(for: "clip-main") == nil)
    }

    @Test func missingCueUsesAPlayableLibraryTrackWithCreditAndUndo() async throws {
        let fixture = try fixture(plan: Self.plan(music: false, rewrite: false), candidates: [Self.generated("0.01"), Self.library])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, result = try await run(fixture)
        let entry = try #require(MusicProject.entry(for: "clip-main", in: editor.project))
        let url = MusicRenderInput.url(for: entry.asset, dataRoot: fixture.root)
        #expect(try await MusicBedRenderer.durationSeconds(url) == 2)
        #expect(entry.source == .library && entry.title == Self.library.title && entry.gainDb == ProjectMusic.defaultGainDb)
        #expect(fixture.calls.all.filter { $0.hasPrefix("fetch") } == ["fetch \(Self.library.id)"] && result.spent == 0)
        let credit = try #require(entry.creditLine)
        #expect(editor.makeItPostCopy(result).contains(credit))
        step(fixture.undo) { editor.makeItUndo("music", in: result) }
        #expect(editor.currentMusic == nil && !editor.makeItPostCopy(result).contains(credit))
        fixture.undo.undo()
        #expect(editor.currentMusic == entry && editor.makeItPostCopy(result).contains(credit))
    }

    @Test func unplayableFreeMatchesFallThroughToARealFolderTrackWithoutPaying() async throws {
        let fixture = try fixture(candidates: [Self.library, Self.generated("0.01")])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, calls = fixture.calls, folder = fixture.root.appendingPathComponent("source-music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = try Self.wav()
        try Data([0]).write(to: folder.appendingPathComponent("Calm piano.wav"))
        try wav.write(to: folder.appendingPathComponent("My bed.wav"))
        editor.musicPanel.services?.fetch = { candidate in calls.record("fetch \(candidate.id)"); return Data([0]) }
        let result = try await run(fixture)
        let entry = try #require(editor.currentMusic)
        #expect(entry.source == .file && entry.title == "My bed" && entry.gainDb == -18)
        #expect(try Data(contentsOf: MusicRenderInput.url(for: entry.asset, dataRoot: fixture.root)) == wav)
        #expect(result.rows.first { $0.id == "music" }?.undoable == true)
        #expect(!calls.all.contains("fetch eleven-1"))
        editor.claudeMode.clipIDs = ["clip-main"]
        #expect(editor.claudeModeSummary.contains("music from your folder") && !editor.claudeModeSummary.contains("free library"))
    }

    @Test func anOmittedCueDoesNotAuthorizeEvenAnAffordableGeneration() async throws {
        let fixture = try fixture(plan: Self.plan(music: false, rewrite: false), candidates: [Self.generated("0.001")])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let result = try await run(fixture)
        let row = try #require(result.rows.first { $0.id == "music" })
        #expect(row.kind == .note && !row.undoable && row.text == "No music added" && row.detail.contains("only free tracks"))
        #expect(fixture.editor.currentMusic == nil && !fixture.calls.all.contains { $0.hasPrefix("fetch") } && result.spent == 0)
    }

    @Test func acceptedGenerationCountsAgainstTheCapEvenWhenAudioCannotBeImported() async throws {
        let fixture = try fixture(plan: Self.plan(rewrite: false), candidates: [Self.generated("0.001")])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let calls = fixture.calls
        fixture.editor.musicPanel.services?.generate = { candidate, accepted in
            calls.record("compose " + candidate.id); await accepted(); return Data([0])
        }
        let result = try await run(fixture)
        #expect(fixture.editor.currentMusic == nil && result.spent == Decimal(string: "0.001")!)
        #expect(result.rows.first { $0.id == "music" }?.text == "No music added")
        #expect(calls.all.filter { $0.hasPrefix("compose") } == ["compose eleven-1"])
    }

    @Test func anExplicitCueCanStillUseItsApprovedGeneration() async throws {
        let fixture = try fixture(plan: Self.plan(rewrite: false), candidates: [Self.generated("0.001")])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let result = try await run(fixture)
        #expect(fixture.editor.currentMusic?.source == .generated && result.spent == Decimal(string: "0.001")!)
        #expect(fixture.calls.all.filter { $0.hasPrefix("fetch") } == ["fetch eleven-1"])
    }

    @Test(arguments: [true, false]) func undoThenChangeReusesPaidMusicAndKeepsTheOriginalCap(reuseByID: Bool) async throws {
        let fixture = try fixture(plan: Self.plan(rewrite: false), candidates: [Self.generated("0.001")])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await run(fixture)
        let track = try #require(fixture.editor.currentMusic)
        let file = MusicRenderInput.url(for: track.asset, dataRoot: fixture.root)
        fixture.editor.undoCreativeProposal(first)
        #expect(fixture.editor.currentMusic == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        fixture.editor.makeIt.services?.plan = { request, _, _, _ in
            #expect(request.revision?.instruction == "Change the title")
            #expect(request.musicTracks[track.id] == track.title)
            var revised = try #require(request.revision?.plan)
            revised.title = "A revised title"
            revised.savedMusicTrackId = reuseByID ? track.id : nil
            return ClipAutopilotSeries(plans: [revised])
        }
        fixture.editor.reviseCreativeProposal(first, instruction: "Change the title")
        await first.task?.value
        let revised = try #require(fixture.editor.makeIt.run(for: first.clipID))
        #expect(revised.phase == .ready)
        #expect(revised.plan?.title == "A revised title")
        #expect(fixture.editor.currentMusic?.asset == track.asset)
        #expect(revised.spent == first.spent && revised.cap == first.cap)
        #expect(fixture.calls.all.filter { $0.hasPrefix("fetch") } == ["fetch eleven-1"])
    }

    @Test func undoThenChangeReusesAnUnchangedPaidPhrase() async throws {
        let fixture = try fixture(plan: Self.plan(music: false))
        let editor = fixture.editor
        defer { editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let segment = try #require(editor.project.voiceLab.segments.first)
        let asset = try #require(editor.project.voiceLab.assets?.first { $0.id == segment.audio.assetId })
        let file = fixture.root.appendingPathComponent("VoiceLab").appendingPathComponent(asset.file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.wav().write(to: file)
        editor.document.replaceProject(try VoiceLabProject.setEnabled(false, id: segment.id, in: editor.project))
        editor.refresh()
        editor.makeIt.services?.voice = { _, editor in
            fixture.calls.record("voice charge")
            do {
                editor.replace(try VoiceLabProject.setEnabled(true, id: segment.id, in: editor.project), name: "Use take")
                return MakeItRewriteOutcome(result: .voiced(segments: [segment.id]), spent: 0.01)
            } catch {
                Issue.record("Couldn't place the fixture take: \(error)")
                return MakeItRewriteOutcome(result: .unavailable("Fixture take failed"))
            }
        }
        let first = try await run(fixture)
        #expect(first.phase == .ready && first.spent == 0.01)
        editor.undoCreativeProposal(first)
        #expect(editor.project.voiceLab.segments.first?.enabled == false)
        #expect(FileManager.default.fileExists(atPath: file.path))
        editor.makeIt.services?.plan = { request, _, _, _ in
            var revised = try #require(request.revision?.plan)
            revised.title = "A revised title"
            return ClipAutopilotSeries(plans: [revised])
        }
        editor.reviseCreativeProposal(first, instruction: "Change the title")
        await first.task?.value
        let revised = try #require(editor.makeIt.run(for: first.clipID))
        #expect(revised.phase == .ready && revised.plan?.title == "A revised title")
        #expect(editor.project.voiceLab.segments.first?.enabled == true)
        #expect(revised.spent == first.spent)
        #expect(fixture.calls.all.filter { $0 == "voice charge" }.count == 1)
    }

    @Test func undoThenChangeDoesNotOfferToRaiseTheVideoCap() async throws {
        let fixture = try fixture(plan: Self.plan(music: false, rewrite: false),
                                  voice: MakeItRewriteOutcome(result: .overCap(nextUSD: 3)), suggestion: true)
        let editor = fixture.editor
        defer { editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let budget = MakeItBudget(cap: 2)
        await editor.makeIt.refreshVoiceReady(editor)
        editor.makeTopPostable(1, budget: budget)
        await editor.makeIt.waitForQueue()
        let first = try #require(editor.makeIt.run(for: "clip-main"))
        editor.undoCreativeProposal(first)
        editor.makeIt.services?.plan = { _, _, _, _ in ClipAutopilotSeries(plans: [Self.plan(music: false)]) }
        editor.reviseCreativeProposal(first, instruction: "Make the verb stronger")
        for _ in 0..<20_000 where editor.makeIt.active != nil && budget.needed == nil { await Task.yield() }
        #expect(budget.needed == nil)
        budget.decline()
        await first.task?.value
        let revised = try #require(editor.makeIt.run(for: first.clipID))
        #expect(revised.phase == .ready && revised.spent == 0 && budget.approved == 2)
        #expect(revised.rows.contains { $0.text.hasPrefix("Kept your words") })
    }

    @Test func undoThenChangeReusesTheWholeClipVoiceAndLipSync() async throws {
        let fixture = try fixture(plan: Self.plan(music: false), suggestion: true, projectFixture: "whole-clip-revoice-project")
        let editor = fixture.editor
        defer { editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        var project = editor.project
        let segment = try #require(project.voiceLab.segments.first)
        var record = try #require(project.voiceLab.wholeClipRevoices?.first)
        record.segmentIds = [segment.id]
        let audio = try #require(project.voiceLab.assets?.first { $0.id == segment.audio.assetId })
        let videoID = try #require(segment.candidates.first?.recipe?.video.assetId)
        let video = try #require(project.voiceLab.videoAssets?.first { $0.id == videoID })
        let files = [audio.file, video.file].map { fixture.root.appendingPathComponent("VoiceLab").appendingPathComponent($0) }
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: file)
        }
        project.voiceLab.wholeClipRevoices = nil
        editor.document.replaceProject(try VoiceLabProject.setEnabled(false, id: segment.id, in: project))
        editor.refresh()
        let first = try await claudeModeRun(fixture) { _ in
            fixture.calls.record("lip-sync charge")
            do {
                var current = try VoiceLabProject.setEnabled(true, id: segment.id, in: editor.project)
                current.voiceLab.wholeClipRevoices = [record]
                editor.replace(current, name: "Use lip sync")
                return .revoiced(record, spent: 1.50)
            } catch {
                Issue.record("Couldn't place the fixture lip sync: \(error)")
                return .failed("Fixture lip sync failed", spent: 0)
            }
        }
        #expect(first.spent == 1.50 && editor.project.voiceLab.wholeClipRevoices == [record])
        editor.undoCreativeProposal(first)
        #expect(editor.project.voiceLab.wholeClipRevoices == nil)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        editor.makeIt.services?.plan = { request, _, _, _ in
            var revised = try #require(request.revision?.plan)
            revised.title = "A revised title"
            return ClipAutopilotSeries(plans: [revised])
        }
        editor.reviseCreativeProposal(first, instruction: "Change the title")
        await first.task?.value
        let revised = try #require(editor.makeIt.run(for: first.clipID))
        #expect(revised.phase == .ready && revised.spent == first.spent)
        #expect(editor.project.voiceLab.wholeClipRevoices == [record])
        #expect(fixture.calls.all.filter { $0 == "lip-sync charge" }.count == 1)
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice ") })
    }

    @Test(arguments: ["Add an ElevenLabs key in Settings to make music for this clip.", "No current estimate is available."])
    func noTrackReportsTheGeneratedSourceNote(reason: String) async throws {
        let fixture = try fixture(plan: Self.plan(rewrite: false), candidates: [], notes: [.generated: reason])
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let result = try await run(fixture)
        let row = try #require(result.rows.first { $0.id == "music" })
        #expect(row.text == "No music added" && !row.undoable && row.detail.contains(reason) && !row.detail.contains("cap"))
        #expect(fixture.editor.currentMusic == nil && result.spent == 0)
    }

    @Test func anExistingTrackAndItsMixAreNeverReplacedOrOwnedByTheRun() async throws {
        let fixture = try fixture(plan: Self.plan(rewrite: false))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        var entry = try await MusicAssetStore.importing(Self.wav(), candidate: Self.library, projectId: editor.project.id, clipId: "clip-main", dataRoot: fixture.root)
        entry.gainDb = -31; entry.ducking = false
        let original = try MusicProject.setting(entry, clipId: "clip-main", in: editor.project)
        step(fixture.undo) { editor.replace(original, name: "Choose my track") }
        let result = try await run(fixture)
        let row = try #require(result.rows.first { $0.id == "music" })
        #expect(editor.currentMusic == entry && !row.undoable && row.text.contains("Kept music"))
        #expect(!fixture.calls.all.contains { $0.hasPrefix("music search") || $0.hasPrefix("fetch") })
        editor.makeItUndoAll(result)
        #expect(MusicProject.entry(for: "clip-main", in: editor.project) == entry)
    }

    @Test func undoingAnAutomaticPickKeepsALaterManualChoice() async throws {
        let fixture = try fixture(plan: Self.plan(rewrite: false))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor, result = try await run(fixture)
        var own = try #require(editor.currentMusic)
        own.source = .file; own.license = .own; own.attribution = nil; own.sourceUrl = nil; own.title = "My own track"; own.gainDb = -30
        let changed = try MusicProject.setting(own, clipId: "clip-main", in: editor.project)
        step(fixture.undo) { editor.replace(changed, name: "Choose my track") }
        step(fixture.undo) { editor.makeItUndo("music", in: result) }
        #expect(editor.currentMusic == own && !editor.makeItPostCopy(result).contains("CC BY"))
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
        editor.makeIt.services?.plan = { _, _, _, _ in
            ClipAutopilotSeries(plans: [ClipAutopilotPlan(startWord: 7, endWord: 8, title: "Two", hook: "", captions: Self.plan().captions,
                music: Self.plan().music, musicPick: 0, postText: "Two.", score: 6, verdict: .casualPost)])
        }
        _ = try await run(fixture, clip: "clip-two")
        let first = try #require(MusicProject.entry(for: "clip-main", in: editor.project))
        let second = try #require(MusicProject.entry(for: "clip-two", in: editor.project))
        #expect(first.asset == second.asset && first.id != second.id && second.id == first.id + "-2")
        #expect(editor.makeIt.run(for: "clip-two")?.rows.first { $0.id == "music" }?.undoable == true)
    }

    /// Looks spec §9.6 and §11.6, the regression: Claude's Warm Print at 70% with the Fix replaces the clip's whole colour
    /// state, the row names it with Claude's alternatives first under Change, and the row's Undo puts back the clip's look,
    /// fine-tuning and grade byte for byte. With no frames there is no measurement, so the clip's own Fix stays.
    @Test func undoAfterClaudesLookRestoresTheWholeColourState() async throws {
        var plan = Self.plan(music: false, rewrite: false)
        plan.look = .init(id: "warmPrint", amount: 70, fix: true, alternatives: ["goldenHour", "bw"], reason: "Soft window light suits a memory")
        let fixture = try fixture(plan: plan)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        var before = ClipControlsProject.controls(for: "clip-main", in: editor.project) ?? ProjectClipControls(clipId: "clip-main")
        before.look = .muted
        before.colorAdjustments = ClipColorAdjustments(brightness: 12, contrast: -8, saturation: 0, warmth: 20)
        before.colorGrade = ClipColorGrade(amount: 80, exposure: 15, temperature: -10, highlights: -20, vibrance: 30, fade: 10)
        let tuned = try ClipControlsProject.setting(before, in: editor.project)
        step(fixture.undo) { editor.replace(tuned, name: "Fine-tune") }
        let saved = try ProjectJSON.encode(editor.project)
        let run = try await run(fixture)
        let after = try #require(ClipControlsProject.controls(for: "clip-main", in: editor.project))
        let looks = try #require(ClipLookLibrary.app)
        #expect(looks.match(after) == .applied(try #require(looks.look("warmPrint"))))
        #expect(after.colorGrade?.preset == "warmPrint" && after.colorGrade?.amount == 70)
        #expect(after.colorGrade?.fix == ClipColorFix(exposure: 15, temperature: -10), "no frames, no measurement: the clip's Fix stays")
        let row = try #require(run.rows.first { $0.id == "look" })
        #expect(row.text == "Claude chose Warm Print at 70%" && row.detail == "Soft window light suits a memory" && row.undoable)
        #expect(row.options.prefix(3) == ["✦ Golden Hour", "✦ B&W", "Vintage Fade"] && row.options.last == "All looks in Picture ›")
        #expect(row.options.contains("As filmed") && row.options.contains("100%") && !row.options.contains("70%"))
        let ran = editor.project
        step(fixture.undo) { editor.makeItUndo("look", in: run) }
        // Only the colour goes back, and it is the clip's colour before the run, byte for byte.
        var expected = ran
        let index = try #require(expected.clipControls.firstIndex { $0.clipId == "clip-main" })
        expected.clipControls[index].colorState = before.colorState
        expected.modifiedAt = editor.project.modifiedAt
        #expect(try ProjectJSON.encode(editor.project) == ProjectJSON.encode(expected), "the look, fine-tuning and grade go back, nothing else")
        let original = try #require(try ProjectJSON.decode(saved).clipControls.first { $0.clipId == "clip-main" })
        let restored = try #require(ClipControlsProject.controls(for: "clip-main", in: editor.project))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        #expect(restored.look == original.look && restored.colorState == before.colorState)
        #expect(try encoder.encode(restored.colorAdjustments) == encoder.encode(original.colorAdjustments))
        #expect(try encoder.encode(restored.colorGrade) == encoder.encode(original.colorGrade))
    }

    /// Looks spec §9.4: a look this build doesn't have comes back as As filmed, and the row says so.
    @Test func anUnavailableLookIsKeptAsFilmedAndSaysSo() async throws {
        var plan = Self.plan(music: false, rewrite: false)
        plan.look = .original
        plan.repairs = [.init(field: "look", action: .repaired, detail: "unknown look “Neon”; original")]
        let fixture = try fixture(plan: plan)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let run = try await run(fixture)
        let row = try #require(run.rows.first { $0.id == "look" })
        #expect(row.text == "Claude's look wasn't available; kept as filmed" && !row.undoable && row.change == .look)
        #expect(fixture.editor.project.clipControls.first { $0.clipId == "clip-main" }?.colorState ?? ClipColorState() == ClipColorState())
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
        #expect(look.kind == .choice && look.text == "Claude chose Warm" && look.detail == "Friendly")
        #expect(look.change == .look && look.undoable && look.play == max(0, clipStart - 0.5))
        #expect(look.options == ["Golden Hour", "Peach Tone", "As filmed", "50%", "70%", "85%", "All looks in Picture ›"])
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
        step(fixture.undo) { editor.makeItChoose("70%", rowID: "look", run: run) }
        #expect(ClipControlsProject.controls(for: "clip-main", in: editor.project)?.colorGrade == ClipColorGrade(preset: "warm", amount: 70))
        #expect(run.rows.first { $0.id == "look" }?.text == "You chose Warm at 70%")
        step(fixture.undo) { editor.makeItChoose("As filmed", rowID: "look", run: run) }
        #expect(ClipControlsProject.controls(for: "clip-main", in: editor.project)?.colorState == ClipColorState())
        #expect(run.rows.first { $0.id == "look" }?.text == "You chose As filmed")
        #expect(run.rows.first { $0.id == "look" }?.options == ["Muted", "Natural Boost", "Soft Skin", "All looks in Picture ›"])
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
    /// The review reads the hook's card, not the run's stored hook: an edit from the timeline, an undo of the row's
    /// Change, or any other edit of the card (as Ask Claude's Adjust stores one) updates the row and the post text.
    @Test func anAdjustedHookUpdatesTheReviewAndThePostText() async throws {
        let fixture = try fixture(plan: Self.plan(music: false, rewrite: false))
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let run = try await run(fixture)
        let card = try #require(ClipHookTitle.existing(clipID: "clip-main", in: editor.project))
        func row() throws -> String { editor.makeItRowText(try #require(run.rows.first { $0.id == "hook" }), run: run) }
        #expect(try row() == "Claude chose the hook “We ship today”")
        // The timeline edits the persisted card without changing which run is in review.
        run.openChoice = nil
        editor.adjustAskClaudeEffect(fromTimeline: card.id)
        #expect(editor.timelineEffectsOpen && editor.timelineEffectID == card.id && run.openChoice == nil)
        step(fixture.undo) { editor.makeItSetHook("Ship it now", rowID: "hook", run: run) }
        #expect(try row() == "You chose the hook “Ship it now”" && editor.makeItPostCopy(run).hasPrefix("Ship it now\n\n"))
        // ⌘Z puts Claude's words back on the card, and the review follows.
        fixture.undo.undo()
        #expect(ClipHookTitle.existing(clipID: "clip-main", in: editor.project)?.text == "We ship today")
        #expect(try row() == "Claude chose the hook “We ship today”" && editor.makeItPostCopy(run).hasPrefix("We ship today\n\n"))
        // An edit of the card from elsewhere, stored as Ask Claude's Adjust stores one (the same effect, new text).
        var adjusted = try #require(ClipHookTitle.existing(clipID: "clip-main", in: editor.project))
        adjusted.text = "Shipping, finally"
        step(fixture.undo) { editor.replace(try! ClipEffects.adding([adjusted], to: editor.project), name: "Adjust Title") }
        #expect(try row() == "You chose the hook “Shipping, finally”")
        #expect(editor.makeItPostCopy(run) == "Shipping, finally\n\nWe ship the clipper today.")
        // Row Undo still removes the card; the post text keeps the hook it last showed.
        step(fixture.undo) { editor.makeItUndo("hook", in: run) }
        #expect(ClipHookTitle.existing(clipID: "clip-main", in: editor.project) == nil)
        #expect(run.rows.first { $0.id == "hook" }?.undone == true && editor.makeItPostCopy(run).hasPrefix("Shipping, finally\n\n"))
        #expect(editor.makeItEditHook(effectID: card.id) == false, "no card, nothing to open")
    }

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
        #expect(editor.makeItRowText(try #require(run.rows.last), run: run) == "You chose the hook “Ship it today”")
        #expect(editor.makeItPostCopy(run).hasPrefix("Ship it today\n\n"))
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
        editor.makeIt.services?.plan = { request, _, _, _ in
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
        #expect(!fixture.calls.all.contains { $0.hasPrefix("music search") || $0.hasPrefix("fetch") })
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
        editor.makeIt.services?.plan = { request, _, _, progress in
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
        let music = editor.project.music.filter { ["clip-early", "clip-main"].contains($0.clipId ?? "") }
        #expect(music.count == 2 && Set(music.map(\.id)).count == 2 && music.allSatisfy { $0.title == Self.library.title })
    }

    @Test func theDriverPressesOnlyPricedStepsWithinItsBudgetAndNeverGivesUpATake() {
        #expect(MakeItRewriteDriver.pricedID("takeQuote-1") && MakeItRewriteDriver.pricedID("approveTakeQuote-1") && MakeItRewriteDriver.pricedID("keepFixing"))
        for id in ["discardChanges", "closeRewrite", "keepOriginal", "askAgain", "tryAgain", "rewriteAgain"] {
            #expect(!MakeItRewriteDriver.order.contains { id.hasPrefix($0) }, "\(id) is never pressed")
        }
        // ai.md §12.9, MVP32 Clip 7: the steps that settle what can't fit the video never wait on the creator.
        for id in ["keepMyWords", "useTakes", "freshPrice"] {
            #expect(MakeItRewriteDriver.order.contains(id), "\(id) is pressed with no click")
        }
        // Keep My Original Audio leaves out every paid take Use couldn't put in: the run stops there instead.
        #expect(!MakeItRewriteDriver.order.contains("keepOriginalAudio"))
    }

    // MARK: Paid work stays in Rewrite (Claude mode never discards it)

    /// The take fixture's Rewrite (five questions, words 12…25, the reply `passage`) with paid takes.
    private func paidTakesSession(passage: String = "A clearer way to explain what happened in this passage.") throws -> (EditorModel, RewriteSession) {
        _ = NSApplication.shared
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let shared = try SharedResources.locate()
        let project = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true
        editor.refresh()
        let connector = RewriteConnector(connector: RewriteFixtureConnector(), model: "fixture-local", name: "Fixture", group: "local", plan: "")
        let session = RewriteSession(editor: editor, scope: .selection(12...25),
            envelope: AudioEnvelope(sampleRate: 48_000, levels: Array(repeating: 0.01, count: 10_000)), connector: connector)
        editor.rewrite = session
        try session.receivePassage(passage)
        session.finishRun(seconds: 1)
        try DebugRewriteGeneration.install("ready", in: session)
        session.showProposal()
        return (editor, session)
    }

    /// Use couldn't put the paid takes in (a stale plan after Keep Working, or here a failure of its own): the footer's
    /// Keep My Original Audio would leave every take out. The run stops with "needs you" and the takes kept, and names why.
    @Test(arguments: [ClipTakePlan.Failure.stale, .lipsyncBusy]) func useThatCantPutPaidTakesInStopsWithTheTakesKept(failure: ClipTakePlan.Failure) throws {
        let (editor, session) = try paidTakesSession()
        defer { editor.close() }
        let plan = try #require(session.takePlan)
        session.takePlanFailure = failure
        session.showProposal()
        try #require(session.task.footer.primary?.id == "keepOriginalAudio" && session.task.confirm == nil, "\(session.task.footer)")
        guard case .stop(.needsYou(let line)) = MakeItRewriteDriver.next(in: session) else {
            Issue.record("the driver goes on past paid takes Use couldn't put in"); return
        }
        #expect(line.hasPrefix("Use couldn't put the takes in: " + ClipTakePlan.copy(failure).prefix(20)) && line.hasSuffix(" Your paid takes are kept in Rewrite."), "\(line)")
        #expect(plan.phrases.allSatisfy { !$0.leftOut } && session.isOpen && session.hasUnusedPaidWork)
    }

    /// S-duration-claude (DC1): every phrase keeps its recorded audio by Rewrite's own rules, so none of its paid takes can
    /// go in. The run keeps the words as recorded and the Rewrite closes, with no question left up, although Done over
    /// those takes now asks the creator first.
    @Test func paidTakesNoPhraseCanUseCloseTheSettledRewriteUnasked() async throws {
        let (editor, session) = try paidTakesSession()
        defer { editor.close() }
        let plan = try #require(session.takePlan)
        for index in plan.phrases.indices { plan.leaveOut(phrase: index) }
        session.showProposal()
        try #require(session.task.footer.primary?.id == "closeRewrite" && session.asksBeforeClosing, "\(session.task.footer)")
        let driver = MakeItRewriteDriver(editor: editor, request: MakeItRewriteRequest(range: 12...25, text: "A clearer way.", clipID: "", budget: 1))
        let result = await driver.finishAsRecorded(session, spent: 0)
        guard case .keptAsRecorded = result else { Issue.record("\(String(describing: result))"); return }
        #expect(!session.isOpen && editor.openRewrite == nil && session.task.confirm == nil)
        #expect(!editor.announcements.contains { $0.hasPrefix("Close Rewrite and discard") })
    }

    /// The same with a text fix pending: the footer's primary is Apply 1 text fix, whose own close asked over the paid takes
    /// and left the Rewrite open, so every later rewrite of the run stopped with "Finish the open Rewrite first". The fix
    /// goes in and the Rewrite closes with no question left up.
    @Test func paidTakesNoPhraseCanUseCloseTheSettledRewriteAfterItsTextFix() async throws {
        // "Um," is cut (a free text fix) and "one" is said in your voice.
        let (editor, session) = try paidTakesSession(passage: "invites one story rather than a yes or no answer. how do you")
        defer { editor.close() }
        let plan = try #require(session.takePlan)
        for index in plan.phrases.indices { plan.leaveOut(phrase: index) }
        session.showProposal()
        try #require(session.task.footer.primary?.id == "apply" && session.asksBeforeClosing, "\(session.task.footer)")
        let driver = MakeItRewriteDriver(editor: editor, request: MakeItRewriteRequest(range: 12...25, text: "A clearer way.", clipID: "", budget: 1))
        let result = await driver.finishAsRecorded(session, spent: 0)
        guard case .keptAsRecorded(let line) = result else { Issue.record("\(String(describing: result))"); return }
        #expect(line.hasSuffix(" Its text fixes are applied."), "\(line)")
        #expect(!session.isOpen && editor.openRewrite == nil && session.task.confirm == nil)
        #expect(!editor.announcements.contains { $0.hasPrefix("Close Rewrite and discard") })
        #expect(editor.editState()?.cutWordIds.contains("fq-23") == true, "the text fix is in")
    }

    /// Make it postable's Rewrite never closes an open Rewrite holding a paid whole clip: it stops with "needs you", and the
    /// whole clip stays in Review. It used to close it (the guard read only the patch's takes).
    @Test func theDriverNeverClosesARewriteHoldingAPaidWholeClip() async throws {
        let fixture = try fixture()
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        let open = RewriteSession(editor: editor, scope: .selection(3...4), envelope: nil, connector: nil)
        editor.rewrite = open
        try open.receivePassage("we finally ship")
        open.finishRun(seconds: 1)
        let whole = WholeClipRevoiceSession()
        whole.backend = WholeClipRevoiceSessionTests.backend(WholeClipRevoiceSessionTests.Stubs())
        whole.start(); await whole.waitForRun()
        try #require(whole.phase == .review && whole.spent > 0)
        open.wholeClip = whole
        try #require(!open.hasPaidTakes && open.hasUnusedPaidWork)
        let outcome = await MakeItRewriteDriver(editor: editor, request: MakeItRewriteRequest(range: 6...7, text: "the shipper.", clipID: "clip-main",
                                                                                          budget: 1)).run()
        guard case .needsYou(let line) = outcome.result else { Issue.record("\(outcome)"); return }
        #expect(line == "Finish the open Rewrite first. Your paid whole-clip voice is kept.")
        #expect(open.isOpen && editor.openRewrite === open && whole.phase == .review && open.task.confirm == nil)
    }

    /// Claude mode over the fixture's suggestion, with the whole clip quoted at $1.50 of a $2 cap and revoiced by `revoice`.
    private func claudeModeRun(_ fixture: Fixture, revoice: @escaping @MainActor (WholeClipAutoRequest) async -> WholeClipAutoOutcome) async throws -> MakeItRun {
        let editor = fixture.editor
        editor.makeIt.services?.wholeClipQuote = { _, _ in WholeClipAutoQuote(reason: .manyWords(revoiced: 3, spoken: 5), price: Decimal(string: "1.5")!) }
        editor.makeIt.services?.revoiceWholeClip = { request, _ in await revoice(request) }
        await editor.makeIt.refreshVoiceReady(editor)
        editor.makeTopPostable(1, budget: MakeItBudget(cap: 2))
        await editor.makeIt.waitForQueue()
        return try #require(editor.makeIt.run(for: "clip-main"))
    }

    /// The live automatic run's mapping and its one Try Again (`runAutomatically`) over stub steps.
    private func automatically(_ backend: WholeClipRevoiceSession.Backend, request: WholeClipAutoRequest) async -> WholeClipAutoOutcome {
        let session = WholeClipRevoiceSession()
        session.backend = backend
        // As the live service does: the card's free price first (`openWholeClip`), which Try Again is priced from.
        await session.refreshQuote()
        return await session.runAutomatically(budget: request.budget ?? 0) { session.start(automatic: true, budget: $0) }
    }

    /// A lip sync that failed with its paid result kept is tried again on its own, for free, and the whole clip is revoiced:
    /// the patch never runs on top. It used to close Rewrite, drop the paid voice and pay for the phrases.
    @Test func aKeptLipSyncIsTriedAgainForFreeAndThePatchNeverRuns() async throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        stubs.recoveredRequest = "request-1"
        var backend = WholeClipRevoiceSessionTests.backend(stubs)
        let lipsync = backend.lipsync
        backend.lipsync = { voice, factor, model, progress in
            guard stubs.lipsyncs.isEmpty else { return try await lipsync(voice, factor, model, progress) }
            stubs.lipsyncs.append(model)
            throw WholeClipRevoiceSession.LipsyncFailed(error: LipsyncError.invalidResponse, local: false, usd: Decimal(string: "1.55"),
                                                       requestID: "request-1", freeRetry: true)
        }
        let run = try await claudeModeRun(fixture) { await automatically(backend, request: $0) }
        #expect(stubs.voices.count == 1 && stubs.lipsyncs.count == 2 && stubs.used == 1, "one voice, the lip sync again for free, then Use")
        #expect(run.rows.first { $0.id == "wholeClip" }?.text == "Revoiced the whole clip in your voice, lip synced")
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice ") }, "no phrase was patched: \(fixture.calls.all)")
        #expect(run.spent == Decimal(string: "1.61"), "the kept result is paid once")
    }

    /// A voice part that failed its checks is voiced again on its own when the retry fits what is left of the cap, and the
    /// patch never runs.
    @Test func anUnfinishedVoicePartIsTriedAgainWithinTheCap() async throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        var backend = WholeClipRevoiceSessionTests.backend(stubs)
        let voice = backend.voice
        let stopped = StopCount()
        backend.voice = { script, progress in
            guard stopped.count > 0 else {
                stopped.count += 1
                throw WholeClipRevoiceSession.Stop.partVoice(part: 2, reason: "The take dropped a word.", checks: [])
            }
            return try await voice(script, progress)
        }
        let run = try await claudeModeRun(fixture) { await automatically(backend, request: $0) }
        #expect(stopped.count == 1 && stubs.voices.count == 1 && stubs.used == 1, "the part is voiced again, then the clip is used")
        #expect(run.rows.first { $0.id == "wholeClip" }?.text == "Revoiced the whole clip in your voice, lip synced")
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice ") }, "no phrase was patched: \(fixture.calls.all)")
    }

    /// A whole clip that stops holding paid work the run can't finish (here a lip sync that fails twice with nothing kept)
    /// is left in Rewrite for the creator: the row says so and the phrases are not voiced on top.
    @Test func aPaidWholeClipThatCantFinishNeedsYouAndIsNotPatched() async throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        stubs.failLipsync = true
        let backend = WholeClipRevoiceSessionTests.backend(stubs)
        let run = try await claudeModeRun(fixture) { await automatically(backend, request: $0) }
        #expect(stubs.voices.count == 1 && stubs.lipsyncs.count == 1, "a paid lip sync is never retried on its own: \(stubs.lipsyncs)")
        let row = try #require(run.rows.first { $0.id == "wholeClip" })
        let shows = if case .phrase? = row.change { true } else { false }
        #expect(row.text == "Finish the whole clip in Rewrite: its paid voice is kept" && shows && row.actionTitle == "Show in Rewrite", "\(row)")
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice ") }, "no phrase was patched: \(fixture.calls.all)")
        #expect(run.spent == Decimal(string: "0.06"), "only the voice was paid")
    }

    /// What an in-place autosave does to the open project: the document writes it, then puts the save time, the writer
    /// and the path into the project in memory, with no edit and no follow. The document goes back to untitled after, so
    /// no scheduled autosave outlives the test's folder.
    private func autosave(_ editor: EditorModel, root: URL) async throws {
        let url = root.appendingPathComponent("autosaved-\(UUID().uuidString).voxclip")
        editor.document.fileURL = url
        let before = editor.project
        let saved = await withTestDeadline(returning: false) { continuation in
            editor.document.save(to: url, ofType: UTType.voxclipProject.identifier, for: .autosaveInPlaceOperation) { error in
                continuation.resume(returning: error == nil)
            }
        }
        try #require(saved)
        #expect(editor.project.modifiedAt != before.modifiedAt && editor.project != before)
        editor.document.fileURL = nil
    }

    /// Claude mode's live whole clip (`MakeItServices.liveWholeClipQuote` and `liveRevoiceWholeClip` over Rewrite's own
    /// session, its budget and the real currency of what the voice is made from), with only the paid providers stubbed
    /// (`stubs`). `beforeVoice` runs as each voice starts, after the voice plan's currency is captured; the picture, the lip
    /// sync and Use read that currency after it. This fixture's take has no audio to place a phrase on, so the whole clip is
    /// attached to the session the live quote opens rather than offered by its card.
    private func installLiveWholeClip(_ fixture: Fixture, stubs: WholeClipRevoiceSessionTests.Stubs,
                                      beforeVoice: @escaping @MainActor () async throws -> Void = {}) {
        let editor = fixture.editor
        editor.app.settings.values["voiceLab.enabled"] = .bool(true)
        editor.app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        editor.app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        editor.makeIt.services?.wholeClipQuote = { request, editor in
            if editor.openRewrite?.wholeClip == nil,
               let session = MakeItRewriteDriver.openSession(editor: editor, clipID: request.clipID, range: request.range,
                                                             text: MakeItServices.wholeClipPassage(request, editor: editor)) {
                try? DebugRewriteGeneration.install("voice", in: session)
                let whole = WholeClipRevoiceSession()
                session.configureWholeClip(whole)
                guard let live = whole.backend else { Issue.record("the whole clip has no live backend"); return nil }
                let stubbed = WholeClipRevoiceSessionTests.backend(stubs)
                var backend = stubbed
                backend.script = live.script
                backend.voiceReadiness = live.voiceReadiness
                backend.voice = { script, progress in
                    stubs.isCurrent = session.wholeClipInputsStillCurrent()
                    try await beforeVoice()
                    return try await stubbed.voice(script, progress)
                }
                whole.backend = backend
                whole.proposalID = session.proposalID
                session.wholeClip = whole
            }
            return await MakeItServices.liveWholeClipQuote(request, editor: editor)
        }
        editor.makeIt.services?.revoiceWholeClip = { request, editor in await MakeItServices.liveRevoiceWholeClip(request, editor: editor) }
    }

    /// makeit-false-stale-double-pay: the run's own "Make it postable" edit dirties the document, and an autosave lands
    /// while the voice is made. A save changes nothing the voice and lip sync are made from (`wholeClipInputsStillCurrent`), so
    /// the run ends revoiced and no phrase is voiced on top. It used to go stale at the Fit, drop the paid voice and pay for
    /// the patch.
    @Test func anAutosaveDuringTheVoiceStillRevoicesAndNeverPatches() async throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let editor = fixture.editor
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        stubs.video = 30.6
        stubs.canReword = false
        let autosaves = StopCount()
        installLiveWholeClip(fixture, stubs: stubs) {
            try await self.autosave(editor, root: fixture.root)
            autosaves.count += 1
        }
        let run = try await claudeModeRunLive(fixture)
        #expect(autosaves.count == 1, "the autosave landed during the voice")
        #expect(stubs.voices.count == 1 && stubs.lipsyncs.count == 1 && stubs.used == 1, "voiced once, lip synced once, used: \(stubs.order)")
        #expect(run.rows.first { $0.id == "wholeClip" }?.text == "Revoiced the whole clip in your voice, lip synced",
                "\(run.rows.map { "\($0.id): \($0.text) \($0.detail ?? "")" })")
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice ") }, "no phrase was patched: \(fixture.calls.all)")
        #expect(editor.openRewrite == nil, "a used whole clip leaves nothing paid in Rewrite")
    }

    /// Claude mode passes its budget to the whole clip's automatic start (`startWholeClip(automatic:budget:)`): a voice
    /// longer than the clip is reworded and the shorter wording voiced within what is left of the cap, with no click and no
    /// patch. Without the budget the shorter wording waited for the creator's priced click over the paid first voice.
    @Test func aRewordedVoiceWithinTheCapIsVoicedWithNoClick() async throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        stubs.video = 30.6
        stubs.voiceSeconds = [40, 30.4]
        stubs.reword = WholeClipScript.assemble(words: Array(WholeClipRevoiceSessionTests.script.sentences.flatMap(\.sourceWordIds).prefix(4)).enumerated().map {
            TimedWord(id: $0.element, text: "Short", start: Double($0.offset), end: Double($0.offset) + 0.8)
        }, cutWordIds: [], voiceHunks: [])
        installLiveWholeClip(fixture, stubs: stubs)
        let run = try await claudeModeRunLive(fixture)
        #expect(stubs.rewords.count == 1 && stubs.voices.count == 2 && stubs.used == 1, "reworded once, voiced again, used: \(stubs.order)")
        #expect(run.rows.first { $0.id == "wholeClip" }?.text == "Revoiced the whole clip in your voice, lip synced",
                "\(run.rows.map { "\($0.id): \($0.text) \($0.detail ?? "")" })")
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice ") }, "no phrase was patched: \(fixture.calls.all)")
    }

    /// A whole clip Claude mode can't do here with nothing paid (a stop before anything was sent) patches, and leaves no
    /// pick behind: a pick is for its own proposal, so the patch's Rewrite and any later one start from the default (the
    /// whole clip) again. It used to write a patch pick that the next card cleared anyway, with a comment that said the
    /// clip's Rewrites wouldn't offer the whole clip again.
    @Test func aClaudeModePatchLeavesNoPickForTheClip() async throws {
        let fixture = try fixture(suggestion: true)
        defer { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let stubs = WholeClipRevoiceSessionTests.Stubs()
        stubs.video = 30.6
        stubs.voiceError = WholeClipRevoiceSession.Unsent(error: ClipTakePlan.Failure.nothingToVoice)
        installLiveWholeClip(fixture, stubs: stubs)
        let run = try await claudeModeRunLive(fixture)
        #expect(stubs.voices.isEmpty && stubs.lipsyncs.isEmpty, "nothing was paid for the whole clip: \(stubs.order)")
        #expect(fixture.calls.all.contains { $0.hasPrefix("voice ") }, "the changed phrases were voiced instead: \(fixture.calls.all)")
        #expect(fixture.editor.wholeClipPicks["clip-main"]?.whole != false, "Claude mode's patch writes no patch pick: \(String(describing: fixture.editor.wholeClipPicks["clip-main"]))")
        #expect(run.rows.contains { $0.id == "wholeClip" }, "\(run.rows.map { "\($0.id): \($0.text)" })")
    }

    /// Claude mode over the fixture's suggestion with the live whole-clip services the test installed.
    private func claudeModeRunLive(_ fixture: Fixture) async throws -> MakeItRun {
        let editor = fixture.editor
        await editor.makeIt.refreshVoiceReady(editor)
        editor.makeTopPostable(1, budget: MakeItBudget(cap: 2))
        await editor.makeIt.waitForQueue()
        return try #require(editor.makeIt.run(for: "clip-main"))
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
        editor.makeIt.services = MakeItServices(plan: { request, editor, _, progress in
            tones.record(request.tone.map { tone -> String in
                switch tone { case .auto: "auto"; case .asSaid: "as-said"; case .fixed(let tone): tone.id }
            } ?? "none")
            return try await services.plan(request, editor, nil, progress)
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
