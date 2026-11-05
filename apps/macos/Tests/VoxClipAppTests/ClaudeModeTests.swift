#if DEBUG
import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private final class ClaudeCalls: Sendable {
    private let value = Mutex<[String]>([])
    var all: [String] { value.withLock { $0 } }
    func record(_ call: String) { value.withLock { $0.append(call) } }
}

/// "✦ Claude does it all" (doc/design.md §6.6, §6.7) on a demo editor with its own data folder: the planner, the voice
/// and the music are stubs, settings live in memory, and nothing is sent, paid, copied to the pasteboard or read from
/// the keychain.
@Suite("Claude does it all", .serialized, .offlineFixtures)
@MainActor struct ClaudeModeTests {
    private struct Fixture {
        let root: URL
        let app: AppModel
        let editor: EditorModel
        let undo: UndoManager
        let calls: ClaudeCalls
    }

    /// The fixture's words: 0 So · 1 um, · 2 today · (pause) · 3 we · 4 ship · 5 uh · 6 the · 7 clipper. · 8 Thanks. Two
    /// suggestions: "clip-early" (0…1, score 9) and "clip-main" (2…7, score 7).
    private func fixture(mode: ClipsMode? = .claude, cap: Int = 2,
                         voice: @escaping @MainActor (MakeItRewriteRequest, Int) -> MakeItRewriteOutcome = { _, _ in
                             MakeItRewriteOutcome(result: .voiced(segments: []), spent: Decimal(string: "0.10")!) }) throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-claude-mode-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        if let mode { #expect(app.set(ClipsMode.key, .string(mode.rawValue))) }
        #expect(app.set(ClipsMode.capKey, .number(Double(cap))))
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let result = ProjectAIResult(id: "result-1", createdAt: Date(timeIntervalSince1970: 0), provider: "claude-code", model: "fixture",
            preset: .best, inputSha256: String(repeating: "0", count: 64),
            clips: [ProjectAIClip(title: "Suggested", reason: "Good", score: 7, startWordId: "w3", endWordId: "w8"),
                    ProjectAIClip(title: "Early", reason: "Best", score: 9, startWordId: "w1", endWordId: "w2")])
        project.ai.results = [result]
        project.edits.clips = [
            ClipRange(id: "clip-main", startWordId: "w3", endWordId: "w8", title: "Suggested", origin: .ai, aiResultId: "result-1", aiClipIndex: 0, selected: false),
            ClipRange(id: "clip-early", startWordId: "w1", endWordId: "w2", title: "Early", origin: .ai, aiResultId: "result-1", aiClipIndex: 1, selected: false),
        ]
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        editor.mediaResolved = true
        editor.refresh()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let calls = ClaudeCalls()
        editor.pasteboardOverride = { calls.record("copied \($0)") }
        editor.musicPanel.services = MusicPanelServices(suggest: { _, _ in MusicSuggestionResult(candidates: []) },
                                                        fetch: { _ in calls.record("fetch"); return Data() }, folder: { nil })
        var voiceCalls = 0
        editor.makeIt.services = MakeItServices(
            plan: { request, _, _ in
                calls.record("plan \(request.mode)")
                guard case .clips(let spans) = request.mode else { return ClipAutopilotSeries(plans: []) }
                return ClipAutopilotSeries(plans: spans.map { span in
                    span.lowerBound == 0
                        ? ClipAutopilotPlan(startWord: 0, endWord: 1, title: "Early", hook: "", captions: MakeItPostableTestsPlan.captions, postText: "Early.", score: 9, verdict: .postFirst)
                        : MakeItPostableTestsPlan.main
                })
            },
            voice: { request, _ in
                voiceCalls += 1
                calls.record("voice \(request.text) budget \(request.budget.map { "\($0)" } ?? "none")")
                return voice(request, voiceCalls)
            },
            voiceAvailable: { _ in true })
        return Fixture(root: root, app: app, editor: editor, undo: undo, calls: calls)
    }

    private func close(_ fixture: Fixture) { fixture.editor.close(); try? FileManager.default.removeItem(at: fixture.root) }

    /// Waits, without sleeping, until the run stops at the cap.
    private func waitAtCap(_ editor: EditorModel) async throws {
        for _ in 0..<20_000 where editor.claudeMode.budget?.needed == nil { await Task.yield() }
        #expect(editor.claudeMode.budget?.needed != nil, "the run waits at the cap")
    }

    // MARK: A · asked once

    @Test func theFirstRunCardAsksOnceAndTheChoicePersists() throws {
        let fixture = try fixture(mode: nil)
        defer { close(fixture) }
        let editor = fixture.editor
        #expect(editor.showsClipsModeCard && !editor.showsClipStyleCard, "card A asks before the clip style card")
        #expect(editor.statusClipStyle?.text == "Choose how clips are made")
        #expect(editor.claudeModeMeta == "Top 3 clips · up to $2.00 per video for voice and music · Opus, extra high")
        #expect(editor.claudeModeButtonTitle == "✦ Claude does it all · up to $2.00")
        editor.chooseClipsMode(.pick)
        #expect(fixture.app.settings.values[ClipsMode.key] == .string("pick"))
        #expect(!editor.showsClipsModeCard, "never asked again")
        #expect(editor.showsClipStyleCard, "I'll pick: the clip style card shows once, as before")
        #expect(editor.makeIt.series.isEmpty, "I'll pick never starts a run")
        // Another video in the same app: the choice holds.
        let other = EditorModel(document: VoxClipDocument(project: editor.project, demo: true), app: fixture.app, preview: DemoPreviewEngine())
        defer { other.close() }
        other.mediaResolved = true; other.refresh()
        #expect(!other.showsClipsModeCard)
        // Card B's mode control and Settings › Clips write the same keys.
        editor.chooseClipsMode(.claude)
        editor.setClaudeClipCount(5); editor.setClaudeSpendCap(0)
        #expect(fixture.app.settings.clipsAutopilot == ClipsAutopilotSettings(mode: .claude, count: 5, capUSD: 0))
        #expect(editor.statusClipStyle?.text == "✦ Claude does it all · top 5 · ≤$0")
        #expect(editor.claudeModeButtonTitle == "✦ Claude does it all")
        #expect(!editor.showsClipStyleCard, "Claude mode: the card shows only when reopened")
        editor.reopenClipStyleCard()
        #expect(editor.showsClipStyleCard)
        #expect(!fixture.app.set(ClipsMode.countKey, .number(4)), "a count the schema refuses is not stored")
    }

    // MARK: C · running by itself

    @Test func claudeModeStartsAfterFindClipsWithTheCapAsItsBudget() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        #expect(editor.claudeMode.phase == .waiting)
        // The transcript arrived and Find Clips (already found here) ended: the same hooks InlineTranscription and findClips call.
        let steps = editor.undoSteps
        editor.claudeModeTranscribed(started: false)
        #expect(editor.claudeMode.phase == .running && !editor.claudeMode.armed)
        #expect(editor.claudeMode.clipIDs == ["clip-early", "clip-main"], "best first, top 3 of 2")
        #expect(editor.claudeMode.budget?.cap == 2)
        #expect(editor.statusClipStyle?.text.hasPrefix("✦ Claude does it all · $") == true)
        #expect(editor.claudeClipState("clip-early") != nil)
        await editor.claudeMode.task?.value
        #expect(editor.claudeMode.phase == .done)
        #expect(fixture.calls.all.filter { $0.hasPrefix("plan clips") }.count == 1, "one request for the set: \(fixture.calls.all)")
        #expect(fixture.calls.all.contains("voice we finally ship budget 2"), "the voice gets the video's cap")
        #expect(editor.claudeModeReady.count == 2 && editor.claudeClipState("clip-main") == .ready)
        #expect(editor.undoSteps == steps + 2, "one undo step per clip")
        #expect(editor.claudeModeSummary.hasPrefix("Spent $0.10 of $2.00 · 1 phrase in your voice"))
        #expect(editor.claudeModeSteps.map(\.text).contains("Clip 1 “Early” ready"))
        #expect(editor.claudeModeNextStep == "Next: Export. Each post text is copied beside its video.")
        #expect(editor.statusClipStyle?.text == "✦ Claude does it all · top 3 · ≤$2")
    }

    @Test func aReopenedOrReadOnlyProjectNeverStarts() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        // Not a newly opened video (it already has its transcript and clips): Find Clips ending starts nothing.
        await editor.transcription.openOnImport()
        #expect(!editor.claudeMode.armed)
        editor.claudeModeFindEnded()
        editor.claudeModeTranscribed(started: false)
        #expect(editor.claudeMode.phase == .idle && editor.makeIt.series.isEmpty)
        // Read-only (the video is missing): armed, but nothing starts.
        editor.armClaudeMode()
        editor.mediaResolved = false; editor.refresh()
        editor.claudeModeFindEnded()
        #expect(editor.makeIt.series.isEmpty)
        // Once a run happened, the video is no longer new: a later Find Clips starts nothing more.
        editor.mediaResolved = true; editor.refresh()
        editor.claudeModeFindEnded()
        await editor.claudeMode.task?.value
        #expect(editor.claudeMode.phase == .done)
        let plans = fixture.calls.all.filter { $0.hasPrefix("plan") }.count
        editor.claudeModeFindEnded()
        #expect(fixture.calls.all.filter { $0.hasPrefix("plan") }.count == plans && !editor.claudeMode.armed)
    }

    @Test func withoutAnAIItSaysSoWithTheOneFix() throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        var project = editor.project
        project.ai.results = []; project.edits.clips = []
        fixture.undo.beginUndoGrouping(); editor.replace(project, name: "Clear"); fixture.undo.endUndoGrouping()
        editor.armClaudeMode()
        editor.claudeModeTranscribed(started: false)
        guard case .blocked(let blocker) = editor.claudeMode.phase else { Issue.record("not blocked: \(editor.claudeMode.phase)"); return }
        #expect(blocker == .setUp("Claude isn't set up yet. Choose Claude Code in Settings › AI, then Claude starts on its own."))
        #expect(blocker.action == "Set Up Claude Code…")
        #expect(editor.claudeMode.armed, "it starts on its own once fixed")
    }

    // MARK: Money

    @Test func theCapStopsTheRunAndContinueApprovesExactlyTheShortfall() async throws {
        // The first take would cost $1.40 after $0.10 spent: $0.50 past the $1 cap.
        let fixture = try fixture(cap: 1) { _, call in
            call == 1 ? MakeItRewriteOutcome(result: .overCap(nextUSD: Decimal(string: "1.40")), spent: Decimal(string: "0.10")!)
                      : MakeItRewriteOutcome(result: .voiced(segments: []), spent: Decimal(string: "1.40")!)
        }
        defer { close(fixture) }
        let editor = fixture.editor
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeFindEnded()
        try await waitAtCap(editor)
        let budget = try #require(editor.claudeMode.budget)
        #expect(budget.needed == Decimal(string: "0.50") && budget.spent == Decimal(string: "0.10"))
        #expect(editor.claudeModeFooter == "Spent $0.10 of $1.00 · Next: Continue, or Stop to keep what's done.")
        #expect(editor.makeIt.run(for: "clip-main")?.lines.last == "Needs about $0.50 more…")
        editor.continueClaudeMode()
        await editor.claudeMode.task?.value
        #expect(fixture.calls.all.contains("voice we finally ship budget 1.4"), "Continue approved exactly the shortfall")
        #expect(budget.approved == Decimal(string: "1.50") && budget.spent == budget.approved && budget.needed == nil)
        #expect(editor.makeIt.run(for: "clip-main")?.rows.first { $0.id == "rewrite-0" }?.undoable == true)
        #expect(editor.claudeMode.phase == .done)
    }

    @Test func aZeroCapNeverVoicesOrAsks() async throws {
        let fixture = try fixture(cap: 0)
        defer { close(fixture) }
        let editor = fixture.editor
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeFindEnded()
        await editor.claudeMode.task?.value
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice") }, "no paid voice at $0")
        let row = try #require(editor.makeIt.run(for: "clip-main")?.rows.first { $0.id == "rewrite-0" })
        #expect(row.kind == .note && row.detail.hasPrefix("Spend is $0"))
        #expect(editor.claudeMode.budget?.spent == 0 && editor.claudeMode.phase == .done)
    }

    @Test func stopAtTheCapKeepsWhatIsDone() async throws {
        let fixture = try fixture(cap: 1) { _, _ in MakeItRewriteOutcome(result: .overCap(nextUSD: Decimal(string: "1.40")), spent: Decimal(string: "0.10")!) }
        defer { close(fixture) }
        let editor = fixture.editor
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeFindEnded()
        try await waitAtCap(editor)
        editor.stopClaudeMode()
        await editor.claudeMode.task?.value
        #expect(editor.claudeMode.phase == .stopped)
        #expect(editor.claudeClipState("clip-early") == .ready && editor.claudeClipState("clip-main") == .stopped)
        let row = try #require(editor.makeIt.run(for: "clip-main")?.rows.first { $0.id == "rewrite-0" })
        #expect(row.text == "Kept your words for “we finally ship”" && row.detail.contains("this video's cap"))
        #expect(editor.claudeMode.budget?.spent == Decimal(string: "0.10") && editor.claudeMode.budget?.approved == 1, "nothing more was approved or spent")
        #expect(fixture.calls.all.filter { $0.hasPrefix("voice") }.count == 1)
        #expect(editor.project.edits.cutWordIds.contains("w6"), "the cuts made before Stop stay")
    }

    // MARK: D · Export all

    @Test(arguments: [false, true])
    func exportAllWritesEveryClipInEveryShapeWithItsPostText(failing: Bool) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-claude-export-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = AppModel(settingsStore: RegressionSettingsStore())
        #expect(app.set("export.folder", .string(folder.path)))
        let shell = WorkspaceShell(app: app)
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.id = UUID().uuidString.lowercased()
        project.export.folder = nil
        let exporter = RegressionExporter(failingJobs: failing ? [2] : [], writesFiles: true)
        await shell.attachForTesting(VoxClipDocument(project: project), selection: .fullTake, preview: DemoPreviewEngine(), exporter: exporter)
        let editor = try #require(shell.editor)
        defer { editor.close() }
        editor.mediaResolved = true; editor.mediaUnreadable = false; editor.refresh()
        var copied: [String] = []
        editor.pasteboardOverride = { copied.append($0) }
        for id in ["five-1", "five-2"] {
            let run = MakeItRun(clipID: id, cap: 2)
            run.phase = .ready
            run.postText = "Post for \(id)"
            editor.makeIt.insert(run)
        }
        editor.claudeMode.clipIDs = ["five-1", "five-2"]
        editor.claudeMode.phase = .done
        editor.makeIt.style = MakeItStyle(shapes: [.landscape, .portrait])
        #expect(editor.claudeExportAllTitle == "Export all 2 · 16:9 + 9:16" && editor.canClaudeExportAll)
        editor.claudeExportAll()
        await editor.exportTask?.value
        #expect(await exporter.jobs.count == 4, "2 clips × 2 shapes, past a failed file")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let videos = files.filter { $0.hasSuffix(".mp4") }, texts = files.filter { $0.hasSuffix(".txt") }
        #expect(videos.count == (failing ? 3 : 4) && texts.count == videos.count, "\(files)")
        for video in videos {
            let text = try String(contentsOf: folder.appendingPathComponent(video).deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            #expect(text.hasPrefix("Post for five-"), "\(video): \(text)")
        }
        #expect(copied == ["Post for five-1"], "the first post text is copied")
        #expect(editor.exportFileFailures.count == (failing ? 1 : 0))
        if failing { #expect(editor.exportFileFailures.first?.contains("9:16") == true && editor.exportError == nil) }
        #expect(editor.claudeModeNextStep.hasPrefix("Next: post them"))
    }
}

/// The Make it postable tests' main plan, shared so the two suites plan the same clip.
enum MakeItPostableTestsPlan {
    static let captions = ClipAutopilotPlan.Captions(styleId: "vox-bold", font: .init(family: "Roboto", weight: 900), textCase: .upper, wordsPerCaption: 3)
    static var main: ClipAutopilotPlan {
        ClipAutopilotPlan(startWord: 2, endWord: 7, title: "Ship day", hook: "We ship today",
            cuts: [.init(startWord: 5, endWord: 5, kind: .filler, reason: "Filler")],
            rewrites: [.init(startWord: 3, endWord: 4, text: "we finally ship", reason: "Stronger verb")],
            captions: captions,
            music: [.init(title: "Calm piano", mood: "calm piano", prompt: "Instrumental calm piano", reason: "Warm and quiet", underVoiceDb: 18)],
            musicPick: 0, postText: "We ship the clipper today.", score: 7, verdict: .post)
    }
}
#endif
