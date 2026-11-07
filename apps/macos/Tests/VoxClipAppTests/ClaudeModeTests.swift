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
                switch request.tone {
                case .fixed(let tone)?: calls.record("tone \(tone.id)")
                case .asSaid?: calls.record("tone as-said")
                case .auto?: calls.record("tone auto")
                case nil: calls.record("tone none")
                }
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
        #expect(editor.statusClipStyle?.text.hasPrefix("✦ Claude does it all · 0 of 2 ready · $") == true)
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

    /// Through the real Find Clips on a newly opened video: a scripted Claude Code on its plan answers, Find Clips sends with
    /// no click, and once its task has ended (and released the AI lease) the run starts by itself.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR; only stub connectors are called."))
    func aRealFindClipsOnANewVideoStartsTheRunWithNoClick() async throws {
        _ = NSApplication.shared
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.loadCatalogue()
        #expect(app.set(ClipsMode.key, .string(ClipsMode.claude.rawValue)))
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.edits.clips = []; project.ai.results = []
        let words = project.transcript?.words ?? []
        let fake = ClaudeModeSmokeConnector(reply: try DebugRewriteSmoke.claudeModeFindReply(words: words))
        app.connectorOverride = { _ in fake }
        app.connectorConsentOverride = { _, _, _ in true }
        #expect(app.set("llm.connector", .string("claude-code")))
        let provider = try #require(app.providers.first { $0.id == "claude-code" })
        _ = await app.connectorStatus(provider, using: fake)
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        // Find Clips registers its step from its task, as in the app; undo is covered by the tests above.
        editor.undoManager = nil
        editor.preset = .quotes
        editor.musicPanel.services = MusicPanelServices(suggest: { _, _ in MusicSuggestionResult(candidates: []) }, fetch: { _ in Data() }, folder: { nil })
        var planned: [ClipAutopilotRequest.Mode] = []
        editor.makeIt.services = MakeItServices(
            plan: { request, _, _ in
                planned.append(request.mode)
                guard case .clips(let spans) = request.mode else { return ClipAutopilotSeries(plans: []) }
                return ClipAutopilotSeries(plans: spans.map {
                    ClipAutopilotPlan(startWord: $0.lowerBound, endWord: $0.upperBound, title: "Clip \($0.lowerBound)", hook: "",
                                      captions: MakeItPostableTestsPlan.captions, postText: "Post.", score: 8, verdict: .post)
                })
            },
            voice: { _, _ in MakeItRewriteOutcome(result: .voiced(segments: []), spent: 0) },
            voiceAvailable: { _ in false })
        editor.armClaudeMode()
        editor.claudeModeTranscribed(started: editor.findClipsIfFree())
        #expect(editor.claudeMode.phase == .waiting)
        await editor.findTask?.value
        await editor.claudeMode.afterFind?.value
        await editor.claudeMode.task?.value
        #expect(await fake.requests.count == 1 && editor.suggestedClips.count + editor.keptClips.count >= 3)
        #expect(planned.count == 1, "one .clips request: \(planned)")
        #expect(editor.claudeMode.phase == .done && editor.claudeModeReady.count == 3, "\(editor.claudeMode.phase) \(editor.clipError ?? "")")
        #expect(!editor.llmRuns.isBusy && !editor.finding)
    }

    /// The automatic run plans with the clip style's effective tone, exactly as ✦ Make it postable does: the card's Tone,
    /// and "As I said it" whenever Rewording is "Never reword".
    @Test(arguments: [false, true])
    func theRunSendsTheClipStylesEffectiveTone(neverReword: Bool) async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        fixture.undo.beginUndoGrouping()
        editor.updateClipStyle { style in
            style.tone = .tone("viral-youtuber")
            if neverReword { style.rewording = .off }
        }
        fixture.undo.endUndoGrouping()
        #expect(editor.makeItStyle.tone == (neverReword ? .asSaid : .tone("viral-youtuber")))
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeTranscribed(started: false)
        await editor.claudeMode.task?.value
        #expect(fixture.calls.all.filter { $0.hasPrefix("tone") } == [neverReword ? "tone as-said" : "tone viral-youtuber"], "\(fixture.calls.all)")
        #expect(editor.claudeMode.phase == .done)
    }

    @Test func aReopenedOrReadOnlyProjectNeverStarts() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        // Not a newly opened video (it already has its transcript and clips): Find Clips ending starts nothing.
        await editor.transcription.openOnImport()
        #expect(!editor.claudeMode.armed)
        editor.claudeModeFindEnded(); await editor.claudeMode.afterFind?.value
        editor.claudeModeTranscribed(started: false)
        #expect(editor.claudeMode.phase == .idle && editor.makeIt.series.isEmpty)
        // Read-only (the video is missing): armed, but nothing starts.
        editor.armClaudeMode()
        editor.mediaResolved = false; editor.refresh()
        editor.claudeModeFindEnded(); await editor.claudeMode.afterFind?.value
        #expect(editor.makeIt.series.isEmpty)
        // Once a run happened, the video is no longer new: a later Find Clips starts nothing more.
        editor.mediaResolved = true; editor.refresh()
        editor.claudeModeFindEnded(); await editor.claudeMode.afterFind?.value
        await editor.claudeMode.task?.value
        #expect(editor.claudeMode.phase == .done)
        let plans = fixture.calls.all.filter { $0.hasPrefix("plan") }.count
        editor.claudeModeFindEnded(); await editor.claudeMode.afterFind?.value
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
        editor.claudeModeFindEnded(); await editor.claudeMode.afterFind?.value
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

    /// The Make it panel's footer carries the sidebar card's priced Continue (design.md §6.7 item 4): one action, the same
    /// title, exactly the shortfall. VOXCLIP_CLIP_FINISH_CAPTURES=<dir> writes the footer's picture.
    @Test func theMakeItPanelsFooterCarriesTheSameContinue() async throws {
        let fixture = try fixture(cap: 1) { _, call in
            call == 1 ? MakeItRewriteOutcome(result: .overCap(nextUSD: Decimal(string: "1.40")), spent: Decimal(string: "0.10")!)
                      : MakeItRewriteOutcome(result: .voiced(segments: []), spent: Decimal(string: "1.40")!)
        }
        defer { close(fixture) }
        let editor = fixture.editor
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeFindEnded(); await editor.claudeMode.afterFind?.value
        try await waitAtCap(editor)
        let run = try #require(editor.makeIt.run(for: "clip-main"))
        #expect(run.running && editor.makeItNextStep(run) == "Next: Continue, or Stop to keep what's done.")
        let card = try #require(editor.capContinueAction(id: "claudeMode.continue"))
        let footer = try #require(editor.capContinueAction(id: "makeIt.continue"))
        #expect(footer.title == "Continue · $0.50" && footer.priced && footer.title == card.title && card.priced)

        func markers(_ view: some View, height: CGFloat) -> (host: NSHostingView<AnyView>, frames: [String: CGRect]) {
            let host = NSHostingView(rootView: AnyView(view.environment(editor.app)))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 404, height: height)
            host.layoutSubtreeIfNeeded()
            return (host, DebugRightColumn.markers(in: host))
        }
        let panel = markers(MakeItPanel(model: editor, run: run).frame(width: 404, height: 520).background(DesignValues.color("bg.window")), height: 520)
        let button = try #require(panel.frames["director.button.makeIt.continue"], "the footer shows Continue")
        let next = try #require(panel.frames["makeIt.next"])
        #expect(panel.frames["makeIt.needsMore"] != nil && panel.frames["makeIt.stop"] != nil)
        #expect(button.minY > 520 / 2 && abs(button.midY - next.midY) < 80, "in the footer, by the next step")
        let sidebar = markers(ClaudeModeCard(editor: editor).frame(width: 224), height: 400)
        #expect(sidebar.frames["director.button.claudeMode.continue"] != nil, "the sidebar card shows the same Continue")
        if let folder = ProcessInfo.processInfo.environment["VOXCLIP_CLIP_FINISH_CAPTURES"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let rep = try #require(panel.host.bitmapImageRepForCachingDisplay(in: panel.host.bounds))
            panel.host.cacheDisplay(in: panel.host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("footer-continue.png"))
        }

        // The footer's button is the one action: it approves exactly the shortfall and the step goes on.
        footer.perform()
        await editor.claudeMode.task?.value
        let budget = try #require(editor.claudeMode.budget)
        #expect(budget.approved == Decimal(string: "1.50") && budget.spent == budget.approved && budget.needed == nil)
        #expect(fixture.calls.all.contains("voice we finally ship budget 1.4"))
        #expect(editor.capContinueAction(id: "makeIt.continue") == nil)
        #expect(markers(MakeItPanel(model: editor, run: run).frame(width: 404, height: 520), height: 520).frames["director.button.makeIt.continue"] == nil)
    }

    @Test func aZeroCapNeverVoicesOrAsks() async throws {
        let fixture = try fixture(cap: 0)
        defer { close(fixture) }
        let editor = fixture.editor
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeFindEnded(); await editor.claudeMode.afterFind?.value
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
        editor.claudeModeFindEnded(); await editor.claudeMode.afterFind?.value
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

    /// Each clip exports in its own caption look (design.md §6.6): three clips, three picks (two of Claude's, one the
    /// creator's), one Export all; every file's render and ledger entry carry its clip's style.
    @Test func exportAllRendersEachClipInItsOwnCaptionStyle() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-claude-looks-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = AppModel(settingsStore: RegressionSettingsStore())
        #expect(app.set("export.folder", .string(folder.path)))
        let shell = WorkspaceShell(app: app)
        let shared = try SharedResources.locate()
        let base = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")))
        var project = try DebugExplorer.fiveQuestions(from: base)
        project.id = UUID().uuidString.lowercased()
        project.export.folder = nil
        project.captions.styleId = "vox-highlight"
        let lower: [String: JSONValue] = ["text": .object(["transform": .string("lowercase")])]
        project.clipStyle = ClipStyle(preset: .auto, captions: .auto, music: .auto, maxLengthSec: 60, shapes: [.landscape], rewording: .fixOnly,
            captionPicks: ["five-1": ClipCaptionPick(styleId: "marker", reason: "Bold claims.", overrides: lower),
                           "five-2": ClipCaptionPick(styleId: "minimal", reason: "A quiet line."),
                           "five-3": ClipCaptionPick(styleId: "glow", reason: "", by: .user)])
        let exporter = RegressionExporter(writesFiles: true)
        await shell.attachForTesting(VoxClipDocument(project: project), selection: .fullTake, preview: DemoPreviewEngine(), exporter: exporter)
        let editor = try #require(shell.editor)
        defer { editor.close() }
        editor.mediaResolved = true; editor.mediaUnreadable = false; editor.refresh()
        editor.pasteboardOverride = { _ in }
        let ids = ["five-1", "five-2", "five-3"]
        for id in ids {
            let run = MakeItRun(clipID: id, cap: 2)
            run.phase = .ready
            editor.makeIt.insert(run)
        }
        editor.claudeMode.clipIDs = ids
        editor.claudeMode.phase = .done
        editor.makeIt.style = MakeItStyle(shapes: [.landscape])
        editor.claudeExportAll()
        await editor.exportTask?.value
        let jobs = await exporter.jobs
        try #require(jobs.count == 3)
        var styles: [String: String] = [:]
        for job in jobs {
            guard case .clip(let id) = job.target else { Issue.record("a full-take job"); continue }
            styles[id] = job.render.captionLayout?.style.id
            #expect(app.exportLedger.entry(projectID: editor.project.id, targetID: id, aspect: .landscape)?.styleId == styles[id], "\(id)")
        }
        #expect(styles == ["five-1": "marker", "five-2": "minimal", "five-3": "glow"])
        let marker = try #require(jobs.first { $0.target == .clip("five-1") }?.render.captionLayout)
        #expect(marker.style.text.transform == .lowercase, "Claude's case for that clip")
        #expect(editor.project.captions.styleId == "vox-highlight", "the project default is untouched")
        // The fingerprint follows each clip's look: a new style for one clip marks only that clip's export stale.
        let before = try ids.map { try ExportFingerprint.value(editor.project, target: .clip($0)) }
        var next = editor.project
        next.clipStyle?.captionPicks["five-2"] = ClipCaptionPick(styleId: "punch-in", reason: "", by: .user)
        let after = try ids.map { try ExportFingerprint.value(next, target: .clip($0)) }
        #expect(before[0] == after[0] && before[1] != after[1] && before[2] == after[2])
    }
}

/// The Make it postable tests' main plan, shared so the two suites plan the same clip.
// MARK: Each clip as soon as it is ready (ai.md §16.6)

/// A gate the stub planner waits at until the test opens it; never a sleep.
private actor StreamGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelled = false
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; let all = waiters; waiters = []; for waiter in all { waiter.resume() } }
    func cancel() { cancelled = true; open() }
}

extension ClaudeModeTests {
    private static var early: ClipAutopilotPlan {
        ClipAutopilotPlan(startWord: 0, endWord: 1, title: "Early", hook: "", rewrites: [.init(startWord: 0, endWord: 1, text: "so today", reason: "Clearer")],
                          captions: MakeItPostableTestsPlan.captions, postText: "Early.", score: 9, verdict: .postFirst)
    }

    /// The planner as the service streams it: clip 1 ("clip-early", the best) is ready at once; clip 2 waits at `gate`.
    private func streamingPlanner(_ fixture: Fixture, gate: StreamGate, failSecond: Bool = false, failFirst: Bool = false) {
        fixture.editor.makeIt.services?.plan = { request, _, progress in
            fixture.calls.record("plan \(request.mode) moments \(request.moments.map(\.title))")
            guard case .clips(let spans) = request.mode, spans.count == 2 else { return ClipAutopilotSeries(plans: []) }
            progress(.planning(clip: 0, of: 2)); progress(.planning(clip: 1, of: 2))
            if failFirst { progress(.failed(clip: 0, of: 2)) } else { progress(.ready(clip: 0, of: 2, Self.early)); progress(.planned(clip: 0, of: 2)) }
            await withTaskCancellationHandler { await gate.wait() } onCancel: { Task { await gate.cancel() } }
            if Task.isCancelled { throw CancellationError() }
            if failSecond { progress(.failed(clip: 1, of: 2)); return ClipAutopilotSeries(plans: failFirst ? [] : [Self.early]) }
            progress(.ready(clip: 1, of: 2, MakeItPostableTestsPlan.main)); progress(.planned(clip: 1, of: 2))
            return ClipAutopilotSeries(plans: (failFirst ? [] : [Self.early]) + [MakeItPostableTestsPlan.main])
        }
    }

    /// Yields (never sleeps) until `condition` holds or the bound runs out.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @Test func theFirstClipIsAppliedWhileTheOthersAreStillPlanned() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        let gate = StreamGate()
        streamingPlanner(fixture, gate: gate)
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeTranscribed(started: false)
        await until { editor.makeIt.run(for: "clip-early")?.phase == .ready }
        #expect(editor.makeIt.run(for: "clip-early")?.phase == .ready, "the best clip is ready before the second plan returns")
        #expect(editor.makeIt.run(for: "clip-main")?.phase == .planning)
        #expect(editor.claudeClipState("clip-early") == .ready && editor.claudeClipState("clip-main") == .making)
        #expect(editor.statusClipStyle?.text.hasPrefix("✦ Claude does it all · 1 of 2 ready · $") == true, "\(editor.statusClipStyle?.text ?? "")")
        #expect(editor.claudeModeSteps.contains { $0.id == "clip-early" && $0.state == .done } && editor.claudeModeSteps.contains { $0.id == "clip-main" && $0.state == .now })
        #expect(editor.llmRuns.isBusy == false, "the stub planner holds no lease; the voice step ran inside the shared window")
        await gate.open()
        await editor.claudeMode.task?.value
        #expect(editor.claudeMode.phase == .done && editor.claudeModeReady.count == 2)
        // One request, told Find Clips' titles so the series stays varied; one undo step per clip.
        #expect(fixture.calls.all.filter { $0.hasPrefix("plan") } == ["plan clips([ClosedRange(0...1), ClosedRange(2...7)]) moments [\"Early\", \"Suggested\"]"], "\(fixture.calls.all)")
        #expect(fixture.calls.all.filter { $0.hasPrefix("voice") }.first?.hasPrefix("voice so today") == true, "the best clip voiced first")
        // The run's stage times, numbers only.
        let line = try #require(editor.claudeMode.clock?.logLine())
        #expect(line.hasPrefix("claude-mode timings ") && line.contains("apply1=") && line.contains("apply2=") && line.contains(" first=") && !line.contains("Early"))
    }

    /// design.md §6.7 progress: "Finding clips…" in card C and the status bar while Find Clips runs, then each clip's row
    /// on its own and "N of M ready".
    @Test func progressSaysFindingClipsThenCountsReadyClips() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        editor.armClaudeMode()
        editor.finding = true
        #expect(editor.claudeModeSteps.first { $0.id == "found" } == EditorModel.ClaudeStep(id: "found", state: .now, text: "Finding clips…"))
        #expect(editor.statusClipStyle?.text == "✦ Claude does it all · Finding clips…")
        editor.finding = false
        #expect(editor.statusClipStyle?.text == "✦ Claude does it all · top 3 · ≤$2", "the summary again once it ends")
        let gate = StreamGate()
        streamingPlanner(fixture, gate: gate)
        await editor.makeIt.refreshVoiceReady(editor)
        editor.claudeModeTranscribed(started: false)
        #expect(editor.statusClipStyle?.text.hasPrefix("✦ Claude does it all · 0 of 2 ready · $") == true)
        await until { editor.makeIt.run(for: "clip-early")?.phase == .ready }
        #expect(editor.statusClipStyle?.text.hasPrefix("✦ Claude does it all · 1 of 2 ready · $") == true, "\(editor.statusClipStyle?.text ?? "")")
        await gate.open()
        await editor.claudeMode.task?.value
        #expect(editor.claudeMode.phase == .done && editor.statusClipStyle?.text == "✦ Claude does it all · top 3 · ≤$2")
    }

    @Test func stopCancelsEveryPlanStillInFlight() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        let gate = StreamGate()
        streamingPlanner(fixture, gate: gate)
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeTranscribed(started: false)
        await until { editor.makeIt.run(for: "clip-early")?.phase == .ready }
        editor.stopClaudeMode()
        await editor.claudeMode.task?.value
        #expect(await gate.cancelled, "the plan in flight was cancelled")
        #expect(editor.makeIt.run(for: "clip-early")?.phase == .ready, "what was done is kept")
        #expect(editor.makeIt.run(for: "clip-main")?.phase == .stopped)
        #expect(editor.claudeMode.phase == .stopped && editor.makeIt.running.isEmpty)
    }

    @Test(arguments: [false, true])
    func aFailedClipDoesNotStopTheOthers(firstFails: Bool) async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let editor = fixture.editor
        let gate = StreamGate()
        streamingPlanner(fixture, gate: gate, failSecond: !firstFails, failFirst: firstFails)
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeTranscribed(started: false)
        if firstFails { await until { if case .failed = editor.makeIt.run(for: "clip-early")?.phase { true } else { false } } }
        else { await until { editor.makeIt.run(for: "clip-early")?.phase == .ready } }
        await gate.open()
        await editor.claudeMode.task?.value
        let failed = firstFails ? "clip-early" : "clip-main", made = firstFails ? "clip-main" : "clip-early"
        if case .failed = editor.makeIt.run(for: failed)?.phase {} else { Issue.record("\(failed): \(String(describing: editor.makeIt.run(for: failed)?.phase))") }
        #expect(editor.makeIt.run(for: made)?.phase == .ready)
        #expect(editor.claudeMode.phase == .done && editor.claudeModeReady.map(\.clipID) == [made])
    }

    /// Both plans arrive at once, but clips are applied one at a time on the video's one pool: the second voice step sees
    /// only what the first left, and waits at the cap instead of spending past it.
    @Test func theCapCoversClipsPlannedAtOnce() async throws {
        let fixture = try fixture(cap: 2) { request, _ in
            let price = Decimal(string: "1.50")!
            guard let budget = request.budget, budget >= price else { return MakeItRewriteOutcome(result: .overCap(nextUSD: price)) }
            return MakeItRewriteOutcome(result: .voiced(segments: []), spent: price)
        }
        defer { close(fixture) }
        let editor = fixture.editor
        let gate = StreamGate()
        streamingPlanner(fixture, gate: gate)
        await gate.open()
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeTranscribed(started: false)
        try await waitAtCap(editor)
        let budget = try #require(editor.claudeMode.budget)
        #expect(budget.spent == Decimal(string: "1.50") && budget.spent <= budget.approved, "\(budget.spent) of \(budget.approved)")
        #expect(budget.needed == Decimal(string: "1.00"), "the second clip needs exactly the shortfall")
        #expect(fixture.calls.all.filter { $0.hasPrefix("voice") } == ["voice so today budget 2", "voice we finally ship budget 0.5"], "\(fixture.calls.all)")
        editor.stopClaudeMode()
        await editor.claudeMode.task?.value
        #expect(budget.spent == Decimal(string: "1.50"))
    }
}

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
// MARK: Revoice the whole clip (ADR-R46)

private final class Revoiced: Sendable {
    private let value = Mutex<[Decimal?]>([])
    var all: [Decimal?] { value.withLock { $0 } }
    func record(_ budget: Decimal?) { value.withLock { $0.append(budget) } }
}

extension ClaudeModeTests {
    private func record() -> WholeClipRevoiceRecord {
        WholeClipRevoiceRecord(id: "wholeclip-test", clipId: "clip-main", segmentIds: ["seg"], script: "we finally ship", consentRecordId: "r",
                               videoRetime: 0.99, lipsyncModel: WholeClipRevoice.Lipsync.lipsync2.rawValue, usd: 1.5, match: nil, createdAt: Date())
    }

    /// Runs Claude mode over the fixture with the whole clip quoted at `price` for `reason`; returns the run of "clip-main".
    private func runWholeClip(_ fixture: Fixture, reason: WholeClipRevoice.Reason?, price: Decimal, revoiced: Revoiced) async -> MakeItRun? {
        let editor = fixture.editor
        let made = record()
        editor.makeIt.services?.wholeClipQuote = { request, _ in
            fixture.calls.record("quote \(request.clipID) \(request.rewrites.map(\.text))")
            return WholeClipAutoQuote(reason: reason, price: price)
        }
        editor.makeIt.services?.revoiceWholeClip = { request, _ in
            revoiced.record(request.budget)
            return .revoiced(made, spent: price)
        }
        await editor.makeIt.refreshVoiceReady(editor)
        editor.armClaudeMode()
        editor.claudeModeTranscribed(started: false)
        await editor.claudeMode.task?.value
        return editor.claudeModeRuns.first { $0.clipID == "clip-main" }
    }

    @Test func withinTheCapAStitchedClipIsRevoicedWholeInsteadOfPatched() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let revoiced = Revoiced()
        let run = try #require(await runWholeClip(fixture, reason: .manyWords(revoiced: 3, spoken: 5), price: Decimal(string: "1.5")!, revoiced: revoiced))
        #expect(revoiced.all == [2], "revoiced once, within the video's cap: \(fixture.calls.all)")
        #expect(!fixture.calls.all.contains { $0.hasPrefix("voice ") }, "no phrase was patched: \(fixture.calls.all)")
        let row = try #require(run.rows.first { $0.id == "wholeClip" })
        #expect(row.text == "Revoiced the whole clip in your voice, lip synced" && row.undoable)
        if case .wholeClip(let saved)? = run.inverses["wholeClip"] { #expect(saved.id == "wholeclip-test") } else { Issue.record("no whole-clip inverse") }
        #expect(fixture.editor.claudeMode.budget?.spent == Decimal(string: "1.5"))
        #expect(!run.rows.contains { $0.id == "wholeClipOffer" })
    }

    @Test func overTheCapThePatchRunsAndTheOfferWaitsUnpaidUntilClicked() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let revoiced = Revoiced()
        let price = Decimal(string: "2.5")!
        let run = try #require(await runWholeClip(fixture, reason: .manyWords(revoiced: 3, spoken: 5), price: price, revoiced: revoiced))
        #expect(revoiced.all.isEmpty, "nothing spent on the whole clip over the cap")
        #expect(fixture.calls.all.contains("voice we finally ship budget 2"), "the phrase was patched as before")
        let offer = try #require(run.rows.first { $0.id == "wholeClipOffer" })
        #expect(offer.actionTitle == "Revoice the Whole Clip · ≈ $2.50" && offer.change == .wholeClip)
        #expect(fixture.editor.claudeMode.budget?.spent == Decimal(string: "0.10"))
        // The click is the approval for exactly the offered price.
        fixture.editor.makeItChange(.wholeClip, run: run)
        for _ in 0..<10_000 where revoiced.all.isEmpty { await Task.yield() }
        for _ in 0..<1_000 where !run.rows.contains(where: { $0.id == "wholeClip" }) { await Task.yield() }
        #expect(revoiced.all == [price])
        #expect(run.rows.contains { $0.id == "wholeClip" && $0.undoable })
    }

    @Test func aClipThatWouldNotSoundStitchedIsPatchedWithNoOffer() async throws {
        let fixture = try fixture()
        defer { close(fixture) }
        let revoiced = Revoiced()
        let run = try #require(await runWholeClip(fixture, reason: nil, price: 1, revoiced: revoiced))
        #expect(revoiced.all.isEmpty)
        #expect(fixture.calls.all.contains("voice we finally ship budget 2"))
        #expect(!run.rows.contains { $0.id == "wholeClipOffer" || $0.id == "wholeClip" })
    }
}
#endif
