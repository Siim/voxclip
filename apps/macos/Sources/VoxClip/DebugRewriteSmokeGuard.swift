#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

// S-guard-* (doc/release.md): the use-time voice check (voice-lab §6.9) with the smoke's scripted embedder
// (`RewriteSmokeSpeaker`), which hears a guest's 200 Hz words and road noise as someone else.
// - S-guard-blocked: a guest speaks the middle phrase. It is settled as blocked; the run voices the other two, Use applies
//   them, and nothing offers Get Price, Make Takes or a phrase price for it again (G1, G2).
// - S-guard-noisy: road noise fills every gap between the words. The old raw 10 s window would be mostly noise; the guard
//   hears the words only, and both phrases are voiced (G3).
// - S-guard-claude: ✦ Make it postable (the driver ✦ Claude does it all runs too) on a sentence a guest speaks: the phrase is
//   kept as recorded with no click, nothing is spent, and the run finishes ready to export (G4). Its sentence is too short
//   for the guest's voice to be checked at all, the guard's other settled stop.

extension DebugRewriteSmoke {
    /// Three voice changes: the second is in sentence 4, which S-guard-blocked gives a guest, the third in sentence 5.
    nonisolated static let threeChanges = twoChanges + [("sent to a voice service", "passed to any speech provider")]

    static var guardScenarios: [Definition] { [
        Definition(id: "S-guard-blocked", title: "a guest speaks phrase 2: the voice check blocks it once, phrases 1 and 3 are voiced, Use; no Get Price again",
            voiced: 2, fixture: Fixture(rewrites: [.passage(replace(threeChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2), guestSentence: 4)) { harness in
            try await harness.start()
            let blockedAt = try await harness.runUntilBlocked(phrase: 1)
            try await harness.finish()
            harness.guardNeverRepriced(phrase: 1, from: blockedAt)
        },
        Definition(id: "S-guard-noisy", title: "road noise between every word: the voice check hears the words only, both phrases are voiced",
            voiced: 2, fixture: Fixture(rewrites: [.passage(replace(twoChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2), roadNoise: true)) { harness in
            try await harness.start()
            try await harness.finish()
            harness.guardNeverBlocked()
        },
        Definition(id: "S-guard-claude", title: "✦ Make it postable on a sentence a guest speaks: kept as recorded with no click, nothing spent, ready to export",
            requiresCompletion: false, fixture: Fixture(rewrites: [], voice: RewriteSmokeVoiceScript(offset: -0.2), guestSentence: 1)) { harness in
            try await harness.makeItGuardBlocked()
        },
    ] }

    /// Controls that price, or take a priced step for, phrase `phrase` (0-based) or every phrase.
    static func repricing(_ id: String, phrase: Int) -> Bool {
        ["prepareTakes", "makeTakes", "takeQuote-", "approveTakeQuote", "priceTake.\(phrase)", "priceAnother.\(phrase)", "freshPrice"]
            .contains { id.hasPrefix($0) }
    }
}

extension DebugRewriteSmoke.Harness {
    /// Clicks Get Price and Make Takes as a user does until phrase `phrase` is settled as blocked and nothing runs; returns
    /// the step that showed it. G1: that step's footer offers Use for the phrases that were voiced, and the phrase's row
    /// says the stop with its two actions.
    func runUntilBlocked(phrase: Int) async throws -> Int {
        for _ in 0..<6 {
            if let session, let plan = session.takePlan, !session.takesBusy, plan.phrases.indices.contains(phrase), plan.phrases[phrase].blocked != nil {
                let footer = session.task.footer
                let others = plan.phrases.filter { $0.id != phrase }
                let drawn = steps.last?.snapshot.controls.filter { $0.source == "evidence" }.map(\.id) ?? []
                let rowActions = drawn.contains("blocked.sayItMyself.\(phrase)") && drawn.contains("blocked.keep.\(phrase)")
                // Use, or the click a voiced phrase's unmeasured take waits for (ADR-R37) before Use: never a price.
                let next = footer.primary.map { ["useTakes", "chooseTake"].contains($0.id) } ?? false
                let passed = next && others.allSatisfy { !$0.takes.isEmpty } && plan.phrases[phrase].takes.isEmpty && rowActions
                makeItAppend([DebugRewriteSmoke.Check(invariant: "G1", passed: passed,
                    detail: "footer [\(footer.primary?.title ?? "none")] '\(footer.note ?? "")' · phrase \(phrase + 1): \(session.phraseStatus(plan.phrases[phrase], plan: plan))"
                        + (rowActions ? " · Say it myself, Keep as recorded" : " · row actions missing"))])
                return steps.count
            }
            try await click(["approveTakeQuote", "takeQuote-", "prepareTakes", "makeTakes"])
        }
        throw DebugRewriteSmoke.Failure.setup("phrase \(phrase + 1) was never blocked by the voice check")
    }

    /// G2: from the step that showed the block on, no footer, chip or row offered to price phrase `phrase` again, and the
    /// Rewrite ended with the other phrases voiced.
    func guardNeverRepriced(phrase: Int, from step: Int) {
        let offered = steps.filter { $0.index >= step }.flatMap { step in
            step.snapshot.controls.filter { DebugRewriteSmoke.repricing($0.id, phrase: phrase) }.map { "step \(step.index) [\($0.title)]" }
        }
        makeItAppend([DebugRewriteSmoke.Check(invariant: "G2", passed: offered.isEmpty && completed,
            detail: offered.isEmpty ? "no priced control for phrase \(phrase + 1) after the block; Rewrite \(completed ? "applied" : "not applied")"
                : "offered again: " + offered.prefix(4).joined(separator: ", "))])
    }

    /// G3: no step said the voice check stopped a phrase.
    func guardNeverBlocked() {
        let stop = VoiceConsentError.voiceOwnerMismatch.errorDescription ?? "voice owner"
        let shown = steps.filter { $0.snapshot.texts.contains { $0.contains(stop) } }.map(\.index)
        makeItAppend([DebugRewriteSmoke.Check(invariant: "G3", passed: shown.isEmpty,
            detail: shown.isEmpty ? "the voice check passed every phrase" : "blocked at step \(shown.map(String.init).joined(separator: ", "))")])
    }

    /// ✦ Make it postable rewrites sentence 1, which a guest speaks: the driver keeps it as recorded with no click.
    func makeItGuardBlocked() async throws {
        let editor = try makeItPrepare { range, words in
            guard let first = DebugRewriteSmoke.wordIndex("we", in: words, from: range.lowerBound),
                  let last = DebugRewriteSmoke.wordIndex("take", in: words, from: first) else { return nil }
            return DebugRewriteSmoke.makeItPlan(span: range, cut: nil, rewrite: (first...last, "we film a quick clip in one take."),
                                                zoom: nil, music: false, score: 8, title: "Edit video like a doc")
        }
        let words = editor.project.transcript?.words ?? []
        guard let start = DebugRewriteSmoke.wordIndex("first", in: words), let end = DebugRewriteSmoke.wordIndex("drag", in: words, from: start) else {
            throw DebugRewriteSmoke.Failure.setup("the script lost its second to fourth sentences")
        }
        editor.apply(.addClip(ClipRange(id: "smoke-clip", startWordId: words[start].id, endWordId: words[end].id, title: "Smoke clip",
                                        origin: .manual, selected: true)), name: "Make clip")
        _ = editor.setScope("smoke-clip")
        await editor.makeIt.refreshVoiceReady(editor)
        let segments = editor.project.voiceLab.segments.count
        try await act("click [\(editor.makeItTitle(clipID: "smoke-clip"))]", clicked: "makeIt") {
            editor.makeItPostable("smoke-clip")
            await editor.makeIt.run(for: "smoke-clip")?.task?.value
        }
        ended = true
        guard let run = editor.makeIt.run(for: "smoke-clip") else { throw DebugRewriteSmoke.Failure.setup("no run") }
        let rewrite = run.rows.first { $0.id == "rewrite-0" }
        let next = editor.makeItNextStep(run)
        let kept = rewrite.map { $0.text.hasPrefix("Kept your words") && $0.detail.contains("doesn't sound like your voice") } ?? false
        completed = kept
        makeItAppend([DebugRewriteSmoke.Check(invariant: "G4",
            passed: kept && run.phase == .ready && next.hasPrefix("Next: Export") && run.spent == 0
                && editor.project.voiceLab.segments.count == segments && editor.openRewrite?.isOpen != true,
            detail: (rewrite.map { "\($0.text) · \($0.detail)" } ?? "no rewrite row") + " · \(next) · spent \(EditorModel.makeItDollars(run.spent))"
                + (editor.openRewrite?.isOpen == true ? " · Rewrite left open" : ""))])
    }
}
#endif
