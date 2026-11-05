#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

// S-claude-does-it-all (doc/release.md, design.md §6.6, §6.7): in Claude mode a newly transcribed video runs Find Clips,
// then Make top 3 postable within the $2 cap, with no click; then one click on Export all renders every clip in its
// shapes, each with its post text beside it. A scripted Claude Code connector answers Find Clips, the planner and music
// are the Make it smoke's stubs, and the export is the real one into the smoke's own folder.

/// Claude Code on a plan, answering Find Clips with `reply`.
actor ClaudeModeSmokeConnector: LLMConnector {
    nonisolated let id: ConnectorID = .claudeCode
    let reply: String
    private(set) var requests: [LLMRequest] = []
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func knownCLIAuthMethod() async -> String? { "claude.ai" }
    func models(refresh: Bool) -> [LLMModel] { [LLMModel(id: "smoke-claude", name: "Smoke Claude", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests.append(request)
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}

extension DebugRewriteSmoke {
    /// No takes are made, so the exact-length pass would only repeat it.
    static var claudeModeScenarios: [Definition] { [
        Definition(id: "S-claude-does-it-all", title: "✦ Claude does it all: drop a video, wait, then Export all, with no click in between",
                   requiresCompletion: false, fixture: Fixture(rewrites: [], voice: RewriteSmokeVoiceScript(exactFit: true))) { harness in
            try await harness.claudeDoesItAll()
        },
    ] }
}

extension DebugRewriteSmoke.Harness {
    func claudeDoesItAll() async throws {
        let editor = try makeItPrepare { range, words in
            DebugRewriteSmoke.makeItPlan(span: range, cut: range.count > 4 ? range.lowerBound + 1 : nil, rewrite: nil, zoom: nil,
                                         music: true, score: words[range.lowerBound].text.count % 3 + 7, title: "Clip at \(range.lowerBound)")
        }
        let app = self.app
        let keys = [ClipsMode.key, ClipsMode.countKey, ClipsMode.capKey, "llm.connector", "export.folder"]
        let before = keys.map { app.settings.values[$0] }
        let words = editor.project.transcript?.words ?? []
        let starts = ["first", "then", "the", "finally"].compactMap { DebugRewriteSmoke.wordIndex($0, in: words) }
        guard starts.count == 4 else { throw DebugRewriteSmoke.Failure.setup("the script lost a sentence") }
        let scores = [6, 9, 7, 5]
        let clips: [[String: Any]] = starts.enumerated().map { offset, start in
            ["title": "Moment \(offset + 1)", "start_word": start, "end_word": min(words.count - 1, start + 5), "reason": "Smoke", "score": scores[offset]]
        }
        let reply = (try? JSONSerialization.data(withJSONObject: ["clips": clips])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let fake = ClaudeModeSmokeConnector(reply: reply)
        let consents = ConsentLog()
        var copied: [String] = []
        app.connectorOverride = { _ in fake }
        app.connectorConsentOverride = { _, action, _ in consents.actions.append(action); return true }
        editor.pasteboardOverride = { copied.append($0) }
        defer {
            app.connectorOverride = nil; app.connectorConsentOverride = nil
            editor.smokeExportsDemo = false; editor.pasteboardOverride = nil
            for (key, value) in zip(keys, before) { app.settings.values[key] = value }
        }
        let folder = directory.appendingPathComponent("S-claude-does-it-all", isDirectory: true).appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        app.set("llm.connector", .string("claude-code"))
        app.set("export.folder", .string(folder.path))
        app.set(ClipsMode.key, .string(ClipsMode.claude.rawValue))
        app.set(ClipsMode.countKey, .number(3))
        app.set(ClipsMode.capKey, .number(2))
        // Detection, as the harness picker runs it: Claude Code on a plan, so Find Clips sends with no click.
        if let provider = app.providers.first(where: { $0.id == ConnectorID.claudeCode.rawValue }) { _ = await app.connectorStatus(provider, using: fake) }
        // The newly dropped video: its transcript, and no clips yet.
        var project = editor.project
        project.ai.results = []
        project.edits.clips = []
        project.export.folder = nil
        editor.replace(project, name: "New video")
        editor.smokeExportsDemo = true
        let steps = editor.undoSteps

        try await act("drop a new video; it is transcribed on this Mac; then wait (no clicks)") {
            // What InlineTranscription does as the import's transcription ends (InlineTranscription+Run.swift).
            editor.armClaudeMode()
            editor.claudeModeTranscribed(started: editor.findClipsIfFree())
            await editor.findTask?.value
            await editor.claudeMode.task?.value
        }
        let runs = editor.claudeModeRuns
        let budget = editor.claudeMode.budget
        let requests = await fake.requests
        makeItAppend([
            DebugRewriteSmoke.Check(invariant: "C1", passed: requests.count == 1 && requests.first?.feature == .clipFinder && consents.actions.allSatisfy { $0 == .findClips },
                detail: "\(requests.count) Find Clips request(s), consent asked \(consents.actions.count)×"),
            DebugRewriteSmoke.Check(invariant: "C2", passed: editor.claudeMode.phase == .done && runs.count == 3 && runs.allSatisfy { $0.phase == .ready }
                    && planRequests.count == 1 && editor.makeIt.series == editor.claudeMode.clipIDs,
                detail: runs.map { "\($0.clipID) \(editor.makeItHeadline($0))" }.joined(separator: "; ") + " · \(planRequests.count) plan request(s)"),
            DebugRewriteSmoke.Check(invariant: "C3", passed: budget.map { $0.cap == 2 && $0.spent <= $0.approved && $0.approved == 2 } ?? false,
                detail: editor.claudeModeSpent),
            DebugRewriteSmoke.Check(invariant: "C4", passed: editor.undoSteps - steps == 4,
                detail: "\(editor.undoSteps - steps) undo steps: Find clips, then one per clip"),
            DebugRewriteSmoke.Check(invariant: "C5", passed: editor.canClaudeExportAll && editor.claudeExportAllTitle == "Export all 3 · 16:9 + 9:16"
                    && editor.statusClipStyle?.text == "✦ Claude does it all · top 3 · ≤$2",
                detail: "\(editor.claudeExportAllTitle) · \(editor.claudeModeNextStep) · status \(editor.statusClipStyle?.text ?? "none")"),
        ])

        try await act("click [\(editor.claudeExportAllTitle)]", clicked: "claudeMode.exportAll") {
            editor.claudeExportAll()
            await editor.exportTask?.value
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let videos = files.filter { $0.hasSuffix(".mp4") }, texts = files.filter { $0.hasSuffix(".txt") }
        let posts = Set(runs.map { editor.makeItPostCopy($0) })
        let written = Set(texts.compactMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) })
        completed = videos.count == 6 && editor.exportFileFailures.isEmpty; ended = true
        makeItAppend([
            DebugRewriteSmoke.Check(invariant: "E1", passed: videos.count == 6 && editor.exportFileFailures.isEmpty && editor.exportError == nil,
                detail: "\(videos.count) videos: \(videos.joined(separator: ", ")) \(editor.exportFileFailures) \(editor.exportError ?? "")"),
            DebugRewriteSmoke.Check(invariant: "E2", passed: texts.count == 6 && written == posts && copied.first == runs.first.map { editor.makeItPostCopy($0) },
                detail: "\(texts.count) post texts beside them; the first copied"),
            DebugRewriteSmoke.Check(invariant: "E3", passed: editor.claudeModeNextStep.hasPrefix("Next: post them"), detail: editor.claudeModeNextStep),
        ])
    }
}
#endif
