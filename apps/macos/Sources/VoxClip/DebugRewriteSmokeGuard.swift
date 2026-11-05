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
// - S-guard-learns (ADR-R41): the creator recorded sentences 1–4 in a car (150 Hz, below τ against the statement) and the
//   rest on a closer mic (135 Hz, passing). Get Price checks every phrase first: phrase 3 passes and teaches this video's
//   reference, phrase 1 passes through it, and all three are voiced (G5). Forget learned references makes phrase 1 blocked
//   again (G6).
// - S-guard-guest: the same recording with a guest speaking phrase 2: references are learned, and the guest's phrase is
//   still settled as blocked before any price (G7), and never priced again (G1, G2).

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
        Definition(id: "S-guard-learns", title: "phrase 1 in a car, below τ: phrase 3 teaches this video's reference, all three are voiced; Forget blocks phrase 1 again",
            voiced: 3, fixture: Fixture(rewrites: [.passage(replace(threeChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2),
                                        ownerPitches: learningPitches)) { harness in
            try await harness.start()
            try await harness.finish()
            harness.guardNeverBlocked()
            try await harness.guardLearnedAndForgets(phrase: 0)
        },
        Definition(id: "S-guard-guest", title: "a guest speaks phrase 2 of a video that teaches references: still blocked before any price, never priced again",
            voiced: 2, fixture: Fixture(rewrites: [.passage(replace(threeChanges))], voice: RewriteSmokeVoiceScript(offset: -0.2), guestSentence: 4,
                                        ownerPitches: learningPitches)) { harness in
            try await harness.start()
            let blockedAt = try await harness.runUntilBlocked(phrase: 1)
            try await harness.guardBlockedBeforePricing(phrase: 1)
            try await harness.finish()
            harness.guardNeverRepriced(phrase: 1, from: blockedAt)
        },
    ] }

    /// Sentences 0–3 in a car (150 Hz), 4–7 on a closer mic (135 Hz): `Fixture.ownerPitches`.
    nonisolated static let learningPitches: [Int: Double] = [0: 150, 1: 150, 2: 150, 3: 150, 4: 135, 5: 135, 6: 135, 7: 135]

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
            // The guard settles the phrase at Get Price now (ADR-R41), before the others are voiced: judge once nothing is
            // left to price or make for them.
            let pricing = session?.task.footer.primary.map { ["approveTakeQuote", "takeQuote-", "prepareTakes", "makeTakes"].contains(where: $0.id.hasPrefix) } ?? false
            if let session, let plan = session.takePlan, !session.takesBusy, !pricing, plan.phrases.indices.contains(phrase), plan.phrases[phrase].blocked != nil {
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

    /// G5: the video taught its reference, and phrase `phrase`, below τ on its own, was voiced through it. G6: Forget
    /// learned references, then the same check blocks that phrase again.
    func guardLearnedAndForgets(phrase: Int) async throws {
        guard let store, let record = try await store.activeVoices().first, lastPlanInputs.indices.contains(phrase),
              lastPlanVoiced.indices.contains(phrase) else { throw DebugRewriteSmoke.Failure.setup("no voice or plan") }
        let contentKey = lastPlanInputs[phrase].contentKey
        let learned = record.speaker.references?.map(\.contentKey) ?? []
        let check = VoiceSpeakerCheck.rewriteSmoke
        let speech = try VoiceLabTakeRun.guardSpeech(lastPlanInputs[phrase])
        let alone = try VoiceSpeakerCheck.cosine(VoiceConsentRecord.decodeEmbedding(record.speaker.embedding) ?? [], await check.embedding(speech))
        let voiced = lastPlanVoiced[phrase]
        makeItAppend([DebugRewriteSmoke.Check(invariant: "G5", passed: learned == [contentKey] && alone < record.speaker.threshold && voiced && completed,
            detail: "references \(learned.count) (this video: \(learned.contains(contentKey))) · phrase \(phrase + 1) alone \(String(format: "%.2f", alone)) < τ "
                + "\(record.speaker.threshold) · \(voiced ? "voiced" : "not voiced")")])
        let forgotten = try await store.forgetReferences(recordID: record.id)
        let verdicts = await VoiceUseGuard(store: store, check: check).screen(contentKey: contentKey, recordID: record.id, speech: [speech])
        makeItAppend([DebugRewriteSmoke.Check(invariant: "G6", passed: forgotten.speaker.references == nil && verdicts == [.blocked(.voiceOwnerMismatch)],
            detail: "after Forget: \(verdicts.map { String(describing: $0) }.joined())")])
    }

    /// G7: references were learned from this video, and the guest's phrase was settled before anything was priced for it.
    func guardBlockedBeforePricing(phrase: Int) async throws {
        guard let store, let record = try await store.activeVoices().first, let plan = session?.takePlan else {
            throw DebugRewriteSmoke.Failure.setup("no voice or plan")
        }
        let learned = record.speaker.references?.count ?? 0
        let priced = plan.phrases[phrase].takes.contains { $0.row.quote != nil || $0.row.receipt != nil }
        makeItAppend([DebugRewriteSmoke.Check(invariant: "G7", passed: learned > 0 && plan.phrases[phrase].blocked != nil && !priced,
            detail: "\(learned) reference(s) learned · phrase \(phrase + 1) \(plan.phrases[phrase].blocked != nil ? "blocked" : "not blocked")"
                + (priced ? " · priced" : " · never priced"))])
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
