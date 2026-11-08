#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

/// `-layoutAudit <dir> -claudeModeCaptures`: "✦ Claude does it all" (design.md §6.6, §6.7) drawn offscreen
/// (DebugSpacing.draw: a window parked off every screen, cacheDisplay) on the five-questions fixture, dark and light:
/// A (who makes the clips, asked once), B (the clip style card in Claude mode), C (running by itself, then waiting at
/// the cap) and D (done, with Export all). The planner, voice and music are stubs; nothing is sent or paid.
@MainActor enum DebugClaudeMode {
    /// Releases a stubbed voice step the capture holds open.
    @MainActor final class Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private(set) var held = false
        func hold() async { held = true; await withCheckedContinuation { waiting = $0 } }
        func release() { held = false; waiting?.resume(); waiting = nil }
    }

    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let project = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let saved = app.settings
        defer { app.settings = saved }
        for key in [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey, ClipsMode.key] { app.settings.values.removeValue(forKey: key) }
        app.settings.values[ClipsMode.countKey] = .number(3)
        app.settings.values[ClipsMode.capKey] = .number(2)
        var results: [DebugUISuite.Result] = []
        func capture(_ name: String, _ shell: WorkspaceShell) async {
            for dark in [true, false] {
                let suffix = dark ? "" : "-light"
                do {
                    try await DebugSpacing.draw(WorkspaceView(shell: shell).environment(app), name: name + "-window" + suffix,
                                                size: NSSize(width: 1280, height: 800), dark: dark, mainWindow: true, directory: directory)
                    try await DebugSpacing.draw(ExplorerView(shell: shell).environment(app), name: name + "-sidebar" + suffix,
                                                size: NSSize(width: 300, height: 760), dark: dark, mainWindow: false, directory: directory)
                    results.append(.init(name: "claude-mode capture \(name)\(suffix)", passed: true))
                } catch { results.append(.init(name: "claude-mode capture \(name)\(suffix): \(error)", passed: false)) }
            }
        }

        let shell = WorkspaceShell(app: app)
        shell.windowWidth = 1280
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true))
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        // D shows Export all as on a real video (the demo has none to export; nothing is exported here).
        editor.smokeExportsDemo = true
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 300_000))
        let titles = try newVideo(editor)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.05, count: 48_000), rate: 16_000)
        editor.musicPanel.services = MusicPanelServices(suggest: { _, _ in MusicSuggestionResult(candidates: [DebugRewriteSmoke.makeItLibraryTrack]) },
                                                        fetch: { _ in wav }, folder: { nil })
        let gate = Gate()
        var calls = 0
        editor.makeIt.services = MakeItServices(plan: { request, _, _, _ in
                let spans: [ClosedRange<Int>] = switch request.mode { case .clip(let span): [span]; case .clips(let chosen): chosen; case .series: [] }
                return ClipAutopilotSeries(plans: spans.map { plan($0, title: titles[$0.lowerBound] ?? "Clip") })
            },
            voice: { request, _ in
                calls += 1
                // Clip 2's rewrite: held for C, then its next take ($1.80) is past what is left, for C at the cap; Continue
                // approves the $0.10 shortfall and voices it. Like the real driver, a take never spends past its budget.
                if calls == 2 {
                    await gate.hold()
                    return MakeItRewriteOutcome(result: .overCap(nextUSD: Decimal(string: "1.80")), spent: Decimal(string: "0.18")!)
                }
                let price = Decimal(string: calls == 1 ? "0.12" : calls == 3 ? "1.75" : "0.04")!
                guard price <= (request.budget ?? 0) else { return MakeItRewriteOutcome(result: .overCap(nextUSD: price), spent: 0) }
                return MakeItRewriteOutcome(result: .voiced(segments: []), spent: price)
            },
            voiceAvailable: { _ in true })
        await editor.makeIt.refreshVoiceReady(editor)
        shell.choose(.fullTake, byClick: false)

        // A: the first video, asked once.
        editor.armClaudeMode()
        await capture("claude-a", shell)

        // B: Claude mode chosen; the clip style card reopened from the status bar.
        app.settings.values[ClipsMode.key] = .string(ClipsMode.claude.rawValue)
        editor.reopenClipStyleCard()
        await capture("claude-b", shell)
        editor.collapseClipStyleCard()

        // C: running by itself (clip 1 ready, clip 2 voicing, clip 3 waiting), then waiting at the cap.
        editor.claudeModeFindEnded()
        for _ in 0..<20_000 where !gate.held { await Task.yield() }
        await capture("claude-c", shell)
        gate.release()
        for _ in 0..<20_000 where editor.claudeMode.budget?.needed == nil { await Task.yield() }
        await capture("claude-c-cap", shell)
        editor.continueClaudeMode()
        await editor.claudeMode.task?.value

        // D: done.
        await capture("claude-d", shell)
        results.append(.init(name: "claude-mode run: \(editor.claudeModeReady.count) of \(editor.claudeMode.clipIDs.count) ready, \(editor.claudeModeSpent)",
                             passed: editor.claudeMode.phase == .done && editor.claudeModeReady.count == 3
                                && (editor.claudeMode.budget.map { $0.spent <= $0.approved } ?? false)))
        try JSONEncoder().encode(results.map(\.name)).write(to: directory.appendingPathComponent("claude-mode-captures.json"), options: .atomic)
        return results
    }

    /// The fixture as a newly dropped video right after Find Clips: no kept clips, four suggestions with scores.
    /// Returns each suggestion's title by its first word.
    private static func newVideo(_ editor: EditorModel) throws -> [Int: String] {
        let words = editor.words
        var project = editor.project
        project.edits.clips = []
        project.ai.results = []
        let names = ["Most founders price wrong", "The $9 plan nobody buys", "Ship before you're ready", "One habit for a bad week"]
        let step = max(14, (words.count - 24) / 4)
        let starts = (0..<4).map { 10 + $0 * step }.filter { $0 + 12 < words.count }
        let clips = starts.enumerated().map { offset, start in
            ProjectAIClip(title: names[offset % 4], reason: "One idea, cleanly said", score: [8, 8, 7, 6][offset % 4],
                          startWordId: words[start].id, endWordId: words[start + 12].id)
        }
        project.ai.results = [ProjectAIResult(id: "claude-mode-result", createdAt: Date(timeIntervalSince1970: 0), provider: "claude-code", model: "fixture",
                                              preset: .best, inputSha256: String(repeating: "0", count: 64), clips: clips)]
        project.edits.clips = clips.enumerated().map { offset, clip in
            ClipRange(id: "claude-\(offset)", startWordId: clip.startWordId, endWordId: clip.endWordId, title: clip.title, origin: .ai,
                      aiResultId: "claude-mode-result", aiClipIndex: offset, selected: false)
        }
        editor.replace(project, name: "Find clips")
        var titles: [Int: String] = [:]
        for (offset, start) in starts.enumerated() { titles[start] = clips[offset].title }
        return titles
    }

    /// A plan for any span: a cut, one phrase reworded, captions, music and the post text.
    private static func plan(_ span: ClosedRange<Int>, title: String) -> ClipAutopilotPlan {
        ClipAutopilotPlan(startWord: span.lowerBound, endWord: span.upperBound, title: title,
            hook: "", cuts: [.init(startWord: span.lowerBound + 1, endWord: span.lowerBound + 1, kind: .other, reason: "Not needed")],
            rewrites: [.init(startWord: span.lowerBound + 3, endWord: span.lowerBound + 5, text: "in plain words", reason: "Plainer")],
            captions: .init(styleId: "vox-bold", font: .init(family: "Roboto", weight: 900), textCase: .upper, wordsPerCaption: 3),
            music: [.init(title: "Calm piano", mood: "calm piano", prompt: "Instrumental calm piano", reason: "Warm under the voice", underVoiceDb: 18)],
            musicPick: 0, postText: "One idea, cleanly said.", score: 8, verdict: .post)
    }
}
#endif
