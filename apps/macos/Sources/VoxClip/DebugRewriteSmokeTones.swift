#if DEBUG
import Foundation
import VoxClipCore

// S-tone-viral (doc/release.md; design.md §6.3.1 "Rewrite as"): the creator's default tone is ✦ Viral YouTuber; they select
// words, open the selection bar's strip and press its first chip. That one click opens Rewrite through the app's own path
// (the scripted AI stands in for the chosen one), the reply is voiced with the smoke's scripted ElevenLabs and Use applies
// it. I1–I7 are checked after every step, as for any Rewrite.

extension DebugRewriteSmoke {
    static var toneScenarios: [Definition] { [
        Definition(id: "S-tone-viral", title: "Rewrite as ✦ Viral YouTuber from the selection's strip: one chip rewrites, voice it, Use",
            fixture: Fixture(rewrites: [.passage(replace(twoChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.toneChipOnSelection()
        },
    ] }
}

extension DebugRewriteSmoke.Harness {
    func toneChipOnSelection() async throws {
        guard let editor, let connector, let scope = session?.rewriteScope, case .selection(let range) = scope else {
            throw DebugRewriteSmoke.Failure.setup("no editor or selection")
        }
        // The chip opens its own Rewrite, through the chosen AI: the scripted one as a local server that never asks, with
        // the model it lists.
        session?.close(); editor.rewrite = nil; session = nil
        let before = app.settings.values["llm.connector"]
        app.connectorOverride = { _ in connector }
        app.connectorConsentOverride = { _, _, _ in true }
        let model = app.settings.values["llm.model.ollama"]
        app.set("llm.connector", .string("ollama"))
        app.set("llm.model.ollama", .string("smoke"))
        defer {
            app.connectorOverride = nil; app.connectorConsentOverride = nil
            app.settings.values["llm.connector"] = before
            app.settings.values["llm.model.ollama"] = model
        }
        editor.updateClipStyle { $0.tone = .tone("viral-youtuber") }
        editor.selectedWordIDs = Set(editor.words[range].map(\.id))
        guard let chip = editor.rewriteStripItems.first, chip.id == "viral-youtuber", chip.isDefault,
              editor.selectionRewriteScope == .selection(range) else {
            throw DebugRewriteSmoke.Failure.setup("the strip does not lead with the default tone")
        }
        try await act("select the words, click [✦ Rewrite as ▾], then [\(chip.title) · your default]", clicked: "selectionStrip.tone.\(chip.id)") {
            editor.rewriteAs(chip, scope: editor.selectionRewriteScope)
            await editor.rewriteOpenTask?.value
        }
        guard let opened = editor.rewrite else { throw DebugRewriteSmoke.Failure.setup("the chip opened no Rewrite") }
        await adopt(opened)
        await opened.actionTask?.value
        await settle()
        try await observe("the reply arrives for the tone's instruction")
        let asked = opened.instruction, field = editor.rewriteInstruction
        try await finish()
        appendChecks([
            DebugRewriteSmoke.Check(invariant: "TV1", passed: asked == chip.instruction && opened.rewriteScope == .selection(range) && field == chip.instruction,
                detail: "asked “\(asked.prefix(48))…” on words \(range.lowerBound)–\(range.upperBound); the field shows it"),
            DebugRewriteSmoke.Check(invariant: "TV2", passed: applied, detail: applied ? "voiced and applied" : "not applied"),
        ])
    }

    /// Appends checks to the last observed step.
    func appendChecks(_ checks: [DebugRewriteSmoke.Check]) {
        guard let last = steps.popLast() else { return }
        var step = DebugRewriteSmoke.Step(index: last.index, action: last.action, snapshot: last.snapshot, checks: last.checks + checks, capture: last.capture)
        step.seconds = last.seconds; step.waits = last.waits
        steps.append(step)
    }
}
#endif
