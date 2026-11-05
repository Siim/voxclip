#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore
import VoxClipMedia

/// `-layoutAudit <dir> -makeItCaptures`: ✦ Make it postable's states drawn offscreen (DebugSpacing.draw: a window parked
/// off every screen, cacheDisplay), on the five-questions fixture. The planner, voice and music are stubs; nothing is sent.
/// Writes make-it-button, make-it-progress, make-it-review (dark and light, and with the speed row's choices open),
/// ask-claude-stretch (a partial stretch's whole-clip offer, then applied) and make-it-series.
@MainActor enum DebugMakeIt {
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let root = app.shared?.root else { throw VoxClipError.sharedResourcesMissing }
        let project = try DemoEditing.loadFixture(root.appendingPathComponent("fixtures/projects/five-questions.voxclip"))
        let saved = app.settings
        defer { app.settings = saved }
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        for key in [WorkspaceLayout.explorerWidthKey, WorkspaceLayout.rightWidthKey, WorkspaceLayout.timelineHeightKey] { app.settings.values.removeValue(forKey: key) }
        var results: [DebugUISuite.Result] = []
        func capture(_ name: String, size: NSSize, dark: Bool = true, mainWindow: Bool = false, _ content: some View) async {
            do {
                try await DebugSpacing.draw(content.environment(app), name: name, size: size, dark: dark, mainWindow: mainWindow, directory: directory)
                results.append(.init(name: "make-it capture \(name)", passed: true))
            } catch { results.append(.init(name: "make-it capture \(name): \(error)", passed: false)) }
        }

        let shell = WorkspaceShell(app: app)
        shell.windowWidth = 1280
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true))
        guard let editor = shell.editor else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true; editor.refresh()
        editor.waveform = WaveformData(fine: Array(repeating: 0.01, count: 300_000))
        try addSuggestions(editor)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.05, count: 48_000), rate: 16_000)
        editor.musicPanel.services = MusicPanelServices(suggest: { _, _ in MusicSuggestionResult(candidates: [DebugRewriteSmoke.makeItLibraryTrack]) },
                                                        fetch: { _ in wav }, folder: { nil })
        editor.makeIt.services = MakeItServices(plan: { request, _, _ in
                let spans: [ClosedRange<Int>] = switch request.mode { case .clip(let span): [span]; case .clips(let chosen): chosen; case .series: [] }
                return ClipAutopilotSeries(plans: spans.compactMap { plan($0, words: request.transcript.words) })
            },
            voice: { _, _ in MakeItRewriteOutcome(result: .voiced(segments: []), spent: Decimal(string: "0.02")!, joinNotes: [0]) },
            voiceAvailable: { _ in true })
        await editor.makeIt.refreshVoiceReady(editor)

        guard let clip = editor.keptClips.first else { throw CocoaError(.coderValueNotFound) }
        shell.choose(.clip(clip.id), byClick: false)
        await capture("make-it-button", size: NSSize(width: 1280, height: 800), mainWindow: true, WorkspaceView(shell: shell))

        // While Claude works: a run part-way through its steps.
        let working = MakeItRun(clipID: clip.id, cap: editor.makeItCap(clipID: clip.id))
        working.phase = .applying
        for line in ["Reading the clip…", "Cutting 6 fillers…", "Voicing 2 fixes…"] { working.line(line) }
        editor.makeIt.insert(working)
        shell.choosePanelJob(.makeIt, for: editor)
        await capture("make-it-progress", size: NSSize(width: 404, height: 520), MakeItPanel(model: editor, run: working))
        editor.makeIt.forget(clip.id)

        // The one review.
        editor.makeItPostable(clip.id)
        await editor.makeIt.run(for: clip.id)?.task?.value
        guard let run = editor.makeIt.run(for: clip.id) else { throw CocoaError(.coderValueNotFound) }
        shell.choosePanelJob(.makeIt, for: editor)
        await capture("make-it-review", size: NSSize(width: 404, height: 860), MakeItPanel(model: editor, run: run))
        await capture("make-it-review-light", size: NSSize(width: 404, height: 860), dark: false, MakeItPanel(model: editor, run: run))
        await capture("make-it-review-window", size: NSSize(width: 1280, height: 800), mainWindow: true, WorkspaceView(shell: shell))
        // Change on the speed row: the other speeds as chips in the row.
        editor.makeItChange(.speed, run: run)
        await capture("make-it-review-change", size: NSSize(width: 404, height: 860), MakeItPanel(model: editor, run: run))
        editor.makeItChange(.speed, run: run)
        try await askClaudeStretch(editor, clip: clip, shell: shell) { name, size, dark, main, view in
            await capture(name, size: size, dark: dark, mainWindow: main, view)
        }

        // ✦ Make top 3 postable.
        editor.makeTopPostable(3)
        await editor.makeIt.waitForQueue()
        if let last = editor.makeIt.series.last { editor.makeIt.shownClipID = last }
        if let shown = editor.makeIt.shown {
            await capture("make-it-series", size: NSSize(width: 404, height: 900), MakeItPanel(model: editor, run: shown))
        }
        let ready = editor.makeIt.series.compactMap { editor.makeIt.run(for: $0) }.filter { $0.phase == .ready }.count
        results.append(.init(name: "make-it series ran \(ready) of \(editor.makeIt.series.count)", passed: ready == editor.makeIt.series.count && ready > 0))
        try JSONEncoder().encode(results.map(\.name)).write(to: directory.appendingPathComponent("make-it-captures.json"), options: .atomic)
        return results
    }

    /// Ask Claude's "Slow this bit down" on words inside the clip, with a title: the title applies, and the speed row
    /// offers "Apply 0.75× to the whole clip" (ask-claude-stretch); its click applies it (ask-claude-stretch-applied).
    private static func askClaudeStretch(_ editor: EditorModel, clip: ClipRange, shell: WorkspaceShell,
                                         capture: (String, NSSize, Bool, Bool, AskClaudePanel) async -> Void) async throws {
        guard let shared = editor.app.shared, let first = editor.index(clip.startWordId) else { throw VoxClipError.sharedResourcesMissing }
        let selection = AskClaudeSelection(scope: .words((first + 2)...(first + 6)), clipID: clip.id)
        let scope = try AskClaudeScope.resolve(selection, in: editor.project)
        func op(_ kind: String, _ fields: [String: JSONValue]) -> JSONValue {
            var value: [String: JSONValue] = ["kind": .string(kind), "startWord": .number(-1), "endWord": .number(-1), "start": .number(-1), "end": .number(-1),
                                              "reason": .string("As asked")]
            for (key, field) in fields { value[key] = field }
            return .object(value)
        }
        let reply = JSONValue.object(["summary": .string("Slowed the bit down and added a title."), "ops": .array([
            op("speed", ["rate": .number(0.75)]), op("title", ["text": .string("Day 1"), "position": .string("top")])])])
        let answer = AskClaudeValidator(prompt: try AskClaudePrompt.load(shared: shared), scope: scope, project: editor.project, detections: []).answer(reply)
        editor.askClaude.label = editor.askClaudeLabel(scope)
        editor.applyAskClaude(answer, instruction: "slow this bit down and add a title Day 1", selection: selection)
        editor.askClaude.inView = true
        shell.choosePanelJob(.askClaude, for: editor)
        await capture("ask-claude-stretch", NSSize(width: 404, height: 560), true, false, AskClaudePanel(model: editor))
        if let row = editor.askClaude.run?.rows.first(where: { if case .wholeClip = $0.status { true } else { false } }) {
            editor.applyAskClaudeStretchToClip(row.id)
        }
        await capture("ask-claude-stretch-applied", NSSize(width: 404, height: 560), true, false, AskClaudePanel(model: editor))
        editor.undoAllAskClaude()
        editor.closeAskClaude()
        shell.choosePanelJob(.makeIt, for: editor)
    }

    /// Three suggestions with Find Clips' scores, so Suggested ranks them and ✦ Make top 3 postable shows.
    private static func addSuggestions(_ editor: EditorModel) throws {
        guard editor.suggestedClips.count < 3 else { return }
        let words = editor.words
        var project = editor.project
        let starts = stride(from: 30, to: min(words.count - 12, 30 + 3 * 40), by: 40).map { $0 }
        let clips = starts.enumerated().map { offset, start in
            ProjectAIClip(title: ["Film once a week", "Think in sentences", "Five questions"][offset % 3], reason: "One idea, cleanly said",
                          score: [7, 9, 6][offset % 3], startWordId: words[start].id, endWordId: words[start + 10].id)
        }
        project.ai.results.append(ProjectAIResult(id: "make-it-result", createdAt: Date(timeIntervalSince1970: 0), provider: "claude-code", model: "fixture",
                                                  preset: .best, inputSha256: String(repeating: "0", count: 64), clips: clips))
        project.edits.clips += clips.enumerated().map { offset, clip in
            ClipRange(id: "make-it-\(offset)", startWordId: clip.startWordId, endWordId: clip.endWordId, title: clip.title, origin: .ai,
                      aiResultId: "make-it-result", aiClipIndex: offset, selected: false)
        }
        editor.replace(project, name: "Find clips")
    }

    /// A plan like Claude's for any clip: a filler or two cut, a phrase reworded, Vox Bold captions, a zoom, music, a
    /// question it answered itself, the hook and the post text.
    private static func plan(_ span: ClosedRange<Int>, words: [TimedWord]) -> ClipAutopilotPlan? {
        let rewriteStart = span.lowerBound + 2
        let cuts = span.filter { ($0 < rewriteStart || $0 > rewriteStart + 3) && ["um", "uh", "like"].contains(words[$0].text.lowercased().filter(\.isLetter)) }.prefix(6)
            .map { ClipAutopilotPlan.Cut(startWord: $0, endWord: $0, kind: .filler, reason: "Filler") }
        let rewrite = rewriteStart + 3 <= span.upperBound
            ? [ClipAutopilotPlan.Rewrite(startWord: rewriteStart, endWord: rewriteStart + 3,
                text: ([words[rewriteStart].text, "really"] + words[(rewriteStart + 1)...(rewriteStart + 3)].map(\.text)).joined(separator: " "),
                reason: "Lands the point")] : []
        return ClipAutopilotPlan(startWord: span.lowerBound, endWord: span.upperBound, title: ["Film once, post all week", "One idea per clip", "Answer out loud"][span.lowerBound % 3],
            hook: "One take, eight clips", cuts: Array(cuts),
            corrections: [.init(word: span.upperBound, heard: words[span.upperBound].text, text: words[span.upperBound].text.capitalized, reason: "A name, spelled as said elsewhere")],
            rewrites: rewrite,
            captions: .init(styleId: "marker", font: .init(family: "Roboto", weight: 900), textCase: .upper, wordsPerCaption: 3, reason: "Bold for a tip"),
            look: .init(id: .warm, reason: "Warm suits a friendly tip"), speed: .init(rate: 1.1, reason: "A slow start"),
            music: [.init(title: "Calm piano", mood: "calm piano", prompt: "Instrumental calm piano", reason: "Warm under a talking voice", underVoiceDb: 18)],
            musicPick: 0,
            zooms: [.init(word: span.lowerBound, untilWord: min(span.upperBound, span.lowerBound + 4), scale: 1.15, reason: "Opens on the face")],
            postText: "I film once a week and post every day. The trick: think in sentences, not videos.", score: 8, verdict: .post,
            scoreReason: "One clear idea with a payoff", seconds: 41,
            questions: [.init(question: "Keep “um” in the first line?", answer: "Cut it", options: ["Cut it", "Keep it"])])
    }
}
#endif
