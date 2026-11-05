#if DEBUG
import AppKit
import Foundation
import SwiftUI
import VoxClipCore
import VoxClipMedia

// ✦ Ask Claude in the Rewrite smoke (design.md §6.8, ai.md §18): the user selects words, opens the inline field, types,
// presses Return, and works the change list. A scripted Claude Code connector answers; nothing is paid or sent anywhere.

/// Claude Code on a plan, answering every Ask Claude request with `reply`.
actor AskClaudeSmokeConnector: LLMConnector {
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
    /// One op of the `ask_claude_ops` reply, every unused field at its empty value.
    nonisolated static func askOp(_ kind: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["kind": kind, "startWord": -1, "endWord": -1, "start": -1, "end": -1, "text": "", "target": "", "x": 0, "y": 0,
                                    "width": 0, "height": 0, "tracking": "", "position": "", "rate": 0, "scale": 0, "sound": "", "language": "",
                                    "choice": "", "reason": "the user asked for it"]
        for (key, field) in fields { value[key] = field }
        return value
    }
    nonisolated static func askReply(_ summary: String, _ ops: [[String: Any]]) -> String {
        (try? JSONSerialization.data(withJSONObject: ["summary": summary, "ops": ops])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// No takes are made, so the exact-length pass would only repeat these: their fixture counts as exact already.
    static var askFixture: Fixture { Fixture(rewrites: [.passage(baseScript)], voice: RewriteSmokeVoiceScript(exactFit: true)) }

    static var askClaudeScenarios: [Definition] { [
        // The mockup's example: words over an invoice on screen, "blur the invoice on screen and bleep the amount".
        Definition(id: "S-ask-bleep-blur", title: "Ask Claude: blur the invoice on screen and bleep the amount, undo one, Undo all",
                   requiresCompletion: false, fixture: askFixture) { harness in
            let reply = askReply("Blurred the invoice and bleeped the amount.", [
                askOp("blur", ["x": 0.55, "y": 0.2, "width": 0.35, "height": 0.3, "tracking": "none", "target": "the invoice"]),
                askOp("bleep", ["startWord": 7, "endWord": 8]),
            ])
            try await AskClaudeSmoke(harness, reply: reply).run(words: 6...10, instruction: "blur the invoice on screen and bleep the amount",
                expected: [.blur, .bleep], undoOne: .blur, masked: true)
        },
        Definition(id: "S-ask-overlay", title: "Ask Claude: a title, an emoji and an arrow; the paid rewrite waits for its priced click; Adjust; Undo all",
                   requiresCompletion: false, fixture: askFixture) { harness in
            let reply = askReply("Added a title, an emoji and an arrow.", [
                askOp("title", ["text": "Day 1", "position": "top"]),
                askOp("sticker", ["text": "\u{1F389}", "position": "topRight", "scale": 0.18]),
                askOp("arrow", ["x": 0.6, "y": 0.55, "width": 0.12, "height": 0.12, "target": "the button"]),
                askOp("rewrite", ["startWord": 13, "endWord": 19, "text": "film a quick clip in one go"]),
            ])
            try await AskClaudeSmoke(harness, reply: reply).run(words: 11...19, instruction: "add a title Day 1, an emoji and an arrow at the button",
                expected: [.title, .sticker, .arrow], undoOne: .sticker, masked: false, paidRows: 1, adjust: .title)
        },
    ] }
}

/// The consent prompts a scenario answered.
@MainActor final class ConsentLog { var actions: [ConnectorConsentAction] = [] }

/// Drives one Ask Claude scenario on the harness's editor and records a step, with its checks, after each user action.
@MainActor struct AskClaudeSmoke {
    let harness: DebugRewriteSmoke.Harness
    let fake: AskClaudeSmokeConnector
    init(_ harness: DebugRewriteSmoke.Harness, reply: String) { self.harness = harness; fake = AskClaudeSmokeConnector(reply: reply) }

    typealias Check = DebugRewriteSmoke.Check

    func run(words: ClosedRange<Int>, instruction: String, expected: [ClipEffect.Kind], undoOne: ClipEffect.Kind, masked: Bool,
             paidRows: Int = 0, adjust: ClipEffect.Kind? = nil) async throws {
        guard let editor = harness.editor else { throw DebugRewriteSmoke.Failure.setup("no editor") }
        let app = harness.app
        // Ask Claude, not the Rewrite this harness opens by default.
        harness.session?.close(); editor.rewrite = nil
        let connectorBefore = app.settings.values["llm.connector"]
        let fake = self.fake
        app.connectorOverride = { _ in fake }
        let consents = ConsentLog()
        app.connectorConsentOverride = { _, action, _ in consents.actions.append(action); return true }
        app.set("llm.connector", .string("claude-code"))
        defer {
            app.connectorOverride = nil; app.connectorConsentOverride = nil
            app.settings.values["llm.connector"] = connectorBefore
            editor.closeAskClaude()
        }
        let before = editor.project
        let syntheses = RewriteSmokeHTTP.script.withLock { $0.syntheses }

        // 1. Select the words, then the selection bar's ✦ Ask Claude.
        editor.selectedWordIDs = Set(editor.words[words].map(\.id))
        editor.openAskClaudeOnSelection()
        await record("select words \(words.lowerBound)\u{2013}\(words.upperBound), click [\u{2726} Ask Claude]", [
            Check(invariant: "A1", passed: editor.askClaude.isOpen && editor.askClaude.inView,
                  detail: "the inline field opens in the right panel: \(editor.askClaude.label)"),
            Check(invariant: "A2", passed: editor.askClaudeCostLine == "Free on your Claude plan", detail: "cost line: \(editor.askClaudeCostLine)"),
            Check(invariant: "A3", passed: await fake.requests.isEmpty, detail: "nothing is sent before Return"),
        ])

        // 2. A chip only fills the field; then the user's own words and Return.
        editor.askClaude.text = AskClaudeState.chips[0].text
        let chipSent = await fake.requests.count
        editor.askClaude.text = instruction
        editor.sendAskClaude()
        await editor.askClaude.task?.value
        let requests = await fake.requests
        let run = editor.askClaude.run
        let kinds = editor.project.clipEffects.map(\.kind)
        var answerChecks = [
            Check(invariant: "A3", passed: chipSent == 0, detail: "a chip filled the field and sent nothing"),
            Check(invariant: "A4", passed: requests.count == 1 && requests.first?.feature == .askClaude && requests.first?.effort == .xhigh
                    && requests.first?.instruction.contains("Instruction: \(instruction)") == true && consents.actions.count <= 1 && consents.actions.allSatisfy { $0 == .askClaude },
                  detail: "\(requests.count) request(s), feature \(requests.first?.feature.rawValue ?? "none"), consent \(consents.actions.map { "\($0)" })"),
            Check(invariant: "A5", passed: Set(kinds) == Set(expected) && kinds.count == expected.count,
                  detail: "applied: \(kinds.map(\.rawValue)) \(editor.askClaude.error ?? "")"),
            Check(invariant: "A6", passed: run.map { $0.rows.count == expected.count + paidRows && $0.appliedCount == expected.count } ?? false,
                  detail: "rows: \(run?.rows.map { "\($0.title) \($0.status)" } ?? [])"),
            Check(invariant: "A7", passed: run?.rows.allSatisfy(Self.canAct) ?? false, detail: "every row offers a control that acts"),
        ]
        answerChecks.append(contentsOf: await renderChecks(editor, masked: masked))
        if paidRows > 0 {
            let paid = run?.rows.filter { if case .paid(let price) = $0.status { price.hasPrefix("Voice it \u{00B7} ") } else { false } }.count ?? 0
            answerChecks.append(Check(invariant: "A9", passed: paid == paidRows && RewriteSmokeHTTP.script.withLock { $0.syntheses } == syntheses,
                                      detail: "\(paid) priced row(s) wait for their click; no voice was made"))
        }
        await record("type '\(instruction)', press Return", answerChecks)
        guard let run else { return }

        // 3. Adjust a row inline: nudge its time range by a frame's worth.
        if let adjust, let row = run.rows.first(where: { rowKind($0) == adjust }), let start = editor.askClaudeEffect(row.id)?.start {
            editor.askClaude.adjusting = row.id
            editor.adjustAskClaudeEffect(row.id) { $0.start += 0.1 }
            let moved = editor.askClaudeEffect(row.id)?.start ?? start
            await record("click [Adjust] on \(row.title), nudge its start", [
                Check(invariant: "A10", passed: abs(moved - start - 0.1) < 1e-6, detail: "start \(start) \u{2192} \(moved)"),
            ] + (await renderChecks(editor, masked: masked)))
            editor.askClaude.adjusting = nil
        }

        // 4. Undo one row: the others stay.
        if let row = run.rows.first(where: { rowKind($0) == undoOne }) {
            editor.undoAskClaudeRow(row.id)
            let left = editor.project.clipEffects.map(\.kind)
            await record("click [Undo] on \(row.title)", [
                Check(invariant: "A11", passed: !left.contains(undoOne) && left.count == expected.count - 1 && run.rows.first { $0.id == row.id }?.status == .undone,
                      detail: "left: \(left.map(\.rawValue))"),
            ])
        }

        // 5. Undo all, then Done.
        editor.undoAllAskClaude()
        await record("click [Undo all]", [
            Check(invariant: "A12", passed: editor.project.clipEffects.isEmpty && editor.project.edits == before.edits && run.appliedCount == 0,
                  detail: "effects left: \(editor.project.clipEffects.count)"),
            Check(invariant: "A3", passed: await fake.requests.count == 1, detail: "undo sent nothing"),
        ])
        editor.closeAskClaude()
        await record("click [Done]", [
            Check(invariant: "A1", passed: !editor.askClaude.isOpen, detail: "the field closes; the panel returns to captions"),
        ])
    }

    private func rowKind(_ row: AskClaudeRow) -> ClipEffect.Kind? {
        if case .effect(let effect) = row.operation.action { effect.kind } else { nil }
    }

    /// An applied row can be undone, a paid one has its priced click, a later one says why.
    static func canAct(_ row: AskClaudeRow) -> Bool {
        switch row.status {
        case .applied, .undone: true
        case .paid(let price): !price.isEmpty
        case .later(let reason): !reason.isEmpty
        }
    }

    /// The preview and the export carry the same effects (one render input path), and bleeped words read as × marks.
    private func renderChecks(_ editor: EditorModel, masked: Bool) async -> [Check] {
        do {
            let preview = try await editor.renderRequest()
            let export = try await editor.renderRequest(target: .fullEdit)
            let same = preview.effects?.effects == export.effects?.effects && !(preview.effects?.effects.isEmpty ?? true)
            var checks = [Check(invariant: "A8", passed: same, detail: "preview and export effects: \(preview.effects?.effects.map(\.id) ?? [])")]
            if masked {
                let blocks = export.captions.words.filter { $0.text.contains("\u{00D7}") }.count
                checks.append(Check(invariant: "A8", passed: blocks > 0, detail: "\(blocks) caption word(s) masked by the bleep"))
            }
            return checks
        } catch {
            return [Check(invariant: "A8", passed: false, detail: "render request failed: \(error)")]
        }
    }

    /// Lays the Ask Claude panel out offscreen and records the step; a failing step keeps a PNG of the panel.
    private func record(_ action: String, _ checks: [Check]) async {
        guard let editor = harness.editor else { return }
        var snapshot = DebugRewriteSmoke.Snapshot()
        snapshot.state = editor.askClaude.isOpen ? (editor.askClaude.run == nil ? "asking" : "answered") : "closed"
        snapshot.headline = editor.askClaude.run.map { "Done for \u{201C}\($0.instruction)\u{201D} \u{00B7} \($0.appliedCount) changes" } ?? editor.askClaude.label
        snapshot.texts = editor.askClaude.run?.rows.map { "\($0.title): \($0.detail)" } ?? []
        snapshot.footer = editor.askClaude.run == nil ? "\u{21B5} Ask Claude \u{00B7} \(editor.askClaudeCostLine)" : "Ask again \u{00B7} Done"
        snapshot.textFields = editor.askClaude.run == nil && editor.askClaude.isOpen ? 1 : 0
        let host = NSHostingView(rootView: AnyView(AskClaudePanel(model: editor).frame(width: 360).sceneAccent()))
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 900)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let index = harness.steps.count + 1
        var capture: String?
        if checks.contains(where: { !$0.passed }), let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let name = "rewrite-smoke-\(harness.scenario)-step\(index).png"
            if let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: harness.directory.appendingPathComponent(name))) != nil {
                capture = name
            }
        }
        harness.steps.append(DebugRewriteSmoke.Step(index: index, action: action, snapshot: snapshot, checks: checks, capture: capture))
        DebugRewriteSmoke.progress("\(harness.scenario) step \(index) \u{00B7} \(action.prefix(60))")
    }
}
#endif
