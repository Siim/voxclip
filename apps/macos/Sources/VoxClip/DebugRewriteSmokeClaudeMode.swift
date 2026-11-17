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
        Definition(id: "S-claude-check-pending", title: "✦ Claude does it all on a video transcribed before Claude Code's status check: it waits, then goes on",
                   requiresCompletion: false, fixture: Fixture(rewrites: [], voice: RewriteSmokeVoiceScript(exactFit: true))) { harness in
            try await harness.claudeModeCheckPending()
        },
    ] }
}

extension DebugRewriteSmoke {
    /// Find Clips' reply for `words`, as the lines that hold each span: up to four clips the Quotes preset keeps (5–15 s), each from a word on to a sentence's
    /// end 6–14 s later, one after another, scored 6, 9, 7, 5.
    static func claudeModeFindReply(words: [TimedWord]) throws -> String {
        var clips: [[String: Any]] = []
        var first = 0
        let scores: [Int] = [6, 9, 7, 5]
        while clips.count < 4, first < words.count {
            var last = first
            while last + 1 < words.count, words[last].end - words[first].start < 6 { last += 1 }
            while last + 1 < words.count, !words[last].text.hasSuffix("."), words[last + 1].end - words[first].start <= 14 { last += 1 }
            guard words[last].end - words[first].start >= 5 else { break }
            let lines = ClipRequestBuilder.lineRange(of: first...last, words: words)
            let clip: [String: Any] = ["title": "Moment \(clips.count + 1)", "start_line": lines.lowerBound, "end_line": lines.upperBound, "reason": "Smoke",
                                       "score": scores[clips.count]]
            clips.append(clip)
            first = last + 1
        }
        guard clips.count >= 3 else { throw Failure.setup("the script is too short for three clips") }
        return (try? JSONSerialization.data(withJSONObject: ["clips": clips])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// A Claude mode scenario's editor and scripted Claude Code, with the settings to put back.
@MainActor struct ClaudeModeSmokeStage {
    let editor: EditorModel
    let fake: ClaudeModeSmokeConnector
    let consents: ConsentLog
    let folder: URL
    let restore: () -> Void
}

extension DebugRewriteSmoke.Harness {
    /// A newly dropped, transcribed video with no clips, Claude mode on (top 3, $2) and Claude Code chosen. `detected`
    /// runs Claude Code's status check first, as the harness picker does; otherwise nothing has checked it yet.
    func claudeModeStage(_ scenario: String, detected: Bool, copied: @escaping (String) -> Void) async throws -> ClaudeModeSmokeStage {
        // Claude picks each clip's caption look, as in the hand-edited benchmark: three clips, three styles.
        let looks = ["marker", "minimal", "punch-in"]
        var picked: [Int: String] = [:]
        let editor = try makeItPrepare { range, words in
            let style = picked[range.lowerBound] ?? looks[picked.count % looks.count]
            picked[range.lowerBound] = style
            return DebugRewriteSmoke.makeItPlan(span: range, cut: range.count > 4 ? range.lowerBound + 1 : nil, rewrite: nil, zoom: nil,
                                                music: true, score: words[range.lowerBound].text.count % 3 + 7, title: "Clip at \(range.lowerBound)",
                                                captionStyle: style)
        }
        let app = self.app
        let keys = [ClipsMode.key, ClipsMode.countKey, ClipsMode.capKey, "llm.connector", "export.folder"]
        let before = keys.map { app.settings.values[$0] }
        let words = editor.project.transcript?.words ?? []
        let reply = try DebugRewriteSmoke.claudeModeFindReply(words: words)
        let fake = ClaudeModeSmokeConnector(reply: reply)
        let consents = ConsentLog()
        let methods = app.knownCLIAuthMethods, statuses = app.detectedConnectorStatus
        app.connectorOverride = { _ in fake }
        app.connectorConsentOverride = { _, action, _ in consents.actions.append(action); return true }
        editor.pasteboardOverride = copied
        let presetBefore = editor.preset
        let restore = {
            app.connectorOverride = nil; app.connectorConsentOverride = nil
            editor.smokeExportsDemo = false; editor.pasteboardOverride = nil
            for (key, value) in zip(keys, before) { app.settings.values[key] = value }
            app.knownCLIAuthMethods = methods; app.detectedConnectorStatus = statuses
            editor.preset = presetBefore
        }
        let folder = directory.appendingPathComponent(scenario, isDirectory: true).appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        app.set("llm.connector", .string("claude-code"))
        app.set("export.folder", .string(folder.path))
        app.set(ClipsMode.key, .string(ClipsMode.claude.rawValue))
        app.set(ClipsMode.countKey, .number(3))
        app.set(ClipsMode.capKey, .number(2))
        // The script's sentences are 4–8 s: Quotes (5–15 s) keeps them, where Best wants 20 s or more.
        editor.preset = .quotes
        if detected {
            // Detection, as the harness picker runs it: Claude Code on a plan, so Find Clips sends with no click.
            if let provider = app.providers.first(where: { $0.id == ConnectorID.claudeCode.rawValue }) { _ = await app.connectorStatus(provider, using: fake) }
        } else {
            // Nothing has checked Claude Code yet in this app: its sign-in is unknown.
            app.knownCLIAuthMethods = methods.filter { !$0.key.hasPrefix(ConnectorID.claudeCode.rawValue + ":") }
            app.detectedConnectorStatus[ConnectorID.claudeCode.rawValue] = nil
        }
        // The newly dropped video: its transcript, and no clips yet.
        var project = editor.project
        project.ai.results = []
        project.edits.clips = []
        project.export.folder = nil
        editor.replace(project, name: "New video")
        editor.smokeExportsDemo = true
        return ClaudeModeSmokeStage(editor: editor, fake: fake, consents: consents, folder: folder, restore: restore)
    }

    func claudeDoesItAll() async throws {
        var copied: [String] = []
        let stage = try await claudeModeStage("S-claude-does-it-all", detected: true) { copied.append($0) }
        defer { stage.restore() }
        let editor = stage.editor, fake = stage.fake, consents = stage.consents, folder = stage.folder
        let steps = editor.undoSteps

        try await act("drop a new video; it is transcribed on this Mac; then wait (no clicks)") {
            // What InlineTranscription does as the import's transcription ends (InlineTranscription+Run.swift).
            editor.armClaudeMode()
            editor.claudeModeTranscribed(started: editor.findClipsIfFree())
            await editor.findTask?.value
            await editor.claudeMode.afterFind?.value
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
                detail: runs.map { "\($0.clipID) \(editor.makeItHeadline($0))" }.joined(separator: "; ") + " · \(planRequests.count) plan request(s)"
                    + " · \(editor.claudeMode.phase) · \(editor.suggestedClips.count) suggestions" + (editor.clipError.map { " · " + $0 } ?? "")),
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
            claudeModeLooksCheck(editor, runs: runs),
        ])
    }
}
extension DebugRewriteSmoke.Harness {
    /// MVP53: the transcript lands before anything has checked Claude Code. The card waits on the free status check
    /// ("Checking Claude Code…"), never says it isn't installed, and goes on with no click once the check finds it on its plan.
    func claudeModeCheckPending() async throws {
        let stage = try await claudeModeStage("S-claude-check-pending", detected: false) { _ in }
        defer { stage.restore() }
        let editor = stage.editor, fake = stage.fake
        let unknown = app.cliSignIn(.claudeCode) == nil
        var waited = "", setUpShown: [String] = []
        func note() { if case .blocked(.setUp(let reason)) = editor.claudeMode.phase { setUpShown.append(reason) } }
        try await act("drop a new video; it is transcribed before Claude Code is checked; then wait (no clicks)") {
            editor.armClaudeMode()
            editor.claudeModeTranscribed(started: editor.findClipsIfFree())
            note()
            waited = "\(editor.claudeMode.phase) · " + editor.claudeModeSteps.map(\.text).joined(separator: " / ")
            let checking = editor.claudeMode.checking == "Claude Code" && editor.claudeModeSteps.contains { $0.text == "Checking Claude Code…" }
            if !checking { waited += " · no check shown" }
            await editor.claudeMode.detection?.value
            note()
            await editor.findTask?.value
            await editor.claudeMode.afterFind?.value
            note()
            await editor.claudeMode.task?.value
            note()
        }
        let runs = editor.claudeModeRuns
        let requests = await fake.requests
        completed = editor.claudeMode.phase == .done; ended = true
        makeItAppend([
            DebugRewriteSmoke.Check(invariant: "P1", passed: unknown && waited.hasPrefix("waiting · ") && !waited.contains("no check shown"),
                detail: "sign-in unknown at open: \(unknown) · \(waited)"),
            DebugRewriteSmoke.Check(invariant: "P2", passed: setUpShown.isEmpty, detail: setUpShown.isEmpty ? "never asked to set up" : setUpShown.joined(separator: "; ")),
            DebugRewriteSmoke.Check(invariant: "P3", passed: requests.count == 1 && stage.consents.actions.allSatisfy { $0 == .findClips }
                    && editor.claudeMode.phase == .done && runs.count == 3 && runs.allSatisfy { $0.phase == .ready },
                detail: "\(requests.count) Find Clips request(s) · \(editor.claudeMode.phase) · " + runs.map { "\($0.clipID) \(editor.makeItHeadline($0))" }.joined(separator: "; ")
                    + (editor.clipError.map { " · " + $0 } ?? "")),
        ])
    }

    /// E4: each exported clip carries its own caption look (design.md §6.6). The export ledger records the style every
    /// file rendered in; each clip's equals Claude's pick for it, and the three differ.
    func claudeModeLooksCheck(_ editor: EditorModel, runs: [MakeItRun]) -> DebugRewriteSmoke.Check {
        let shapes = editor.makeItStyle.shapes
        var rendered: [String] = []
        var matched = true
        for run in runs {
            let picked = editor.project.clipStyle?.captionPicks[run.clipID]?.styleId
            for shape in shapes {
                let style = app.exportLedger.entry(projectID: editor.project.id, targetID: run.clipID, aspect: shape)?.styleId
                if style == nil || style != picked { matched = false }
            }
            rendered.append("\(run.clipID) \(picked ?? "none")")
        }
        let distinct = Set(runs.compactMap { editor.project.clipStyle?.captionPicks[$0.clipID]?.styleId }).count
        return DebugRewriteSmoke.Check(invariant: "E4", passed: matched && distinct == runs.count && runs.count == 3,
                                       detail: rendered.joined(separator: "; ") + " · \(distinct) styles")
    }
}
#endif
