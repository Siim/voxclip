import Foundation
import VoxClipCore

/// One clip's rewrites, for ✦ Claude does it all's whole-clip revoice (ADR-R46).
struct WholeClipAutoRequest {
    let clipID: String
    /// The clip's transcript range and each planned rewrite's range and words.
    let range: ClosedRange<Int>
    let rewrites: [(range: ClosedRange<Int>, text: String)]
    /// What it may spend, USD; nil when no paid step may run.
    let budget: Decimal?
}

/// The rule's reason and the whole clip's price from the tables, nil price when the tables have none.
struct WholeClipAutoQuote: Equatable {
    let reason: WholeClipRevoice.Reason?
    let price: Decimal?
}

enum WholeClipAutoOutcome: Equatable {
    case revoiced(WholeClipRevoiceRecord, spent: Decimal)
    /// It stopped with nothing paid, in a way a later try could pass: the changed phrases are voiced instead.
    case failed(String, spent: Decimal)
    case submissionUnconfirmed(String, spent: Decimal)
    /// The whole clip can't be done here, with nothing paid: a part that can't be placed, a stop before anything was sent, a
    /// picture that can't be matched or a lip sync that can't run on this Mac before the voice. The changed phrases are
    /// voiced instead, with the line saying why (ADR-R46).
    case patchInstead(String, spent: Decimal)
    /// It stopped holding paid work the automatic run couldn't finish within its rules (a voice that can't fit, a lip sync
    /// that failed, a part still unverified after its one Try Again, both paid steps done but Use refused): Rewrite stays open
    /// with it, nothing is voiced on top, and the review sends the creator there (ai.md §12.9).
    case needsYou(String, spent: Decimal)

    /// What a finished automatic run comes to. A run that paid for anything never patches: the patch would pay again for
    /// words the whole clip's voice already says. `holdsPaidWork` is whether its Rewrite stays open with paid work in it,
    /// the one predicate the live run also closes Rewrite by (`RewriteSession.hasUnusedPaidWork`); by default the whole
    /// clip's own share of it (`WholeClipRevoiceSession.holdsPaidWork`).
    @MainActor init(_ session: WholeClipRevoiceSession, holdsPaidWork: Bool? = nil) {
        let holds = holdsPaidWork ?? session.holdsPaidWork
        switch session.phase {
        case .used:
            self = session.record.map { .revoiced($0, spent: session.spent) } ?? .failed("The whole clip couldn't be put in.", spent: session.spent)
        case .stopped(let line) where session.submissionUnconfirmed:
            self = .submissionUnconfirmed(line, spent: session.spent)
        case .stopped(let line) where holds:
            self = .needsYou(line, spent: session.spent)
        case .stopped(let line):
            // A stop that would only repeat, or a Fit stop, patches; with nothing paid, so does any other stop (`failed`).
            let patches = session.failure?.repeats == true || session.failure?.step == .fit
            self = patches ? .patchInstead(line, spent: session.spent) : .failed(line, spent: session.spent)
        default:
            self = holds ? .needsYou("The whole clip didn't finish.", spent: session.spent)
                : .failed("The whole clip didn't finish.", spent: session.spent)
        }
    }
}

extension WholeClipRevoiceSession {
    /// Paid work this whole clip holds that is not in the clip: a run under way, or a stop after something was paid (a
    /// voice or verified parts of one, a lip sync, fal.ai's charge for a failed one whose result is kept). The whole clip's
    /// share of `RewriteSession.hasPaidWork`, by the same rule: a voice adopted for free (spent 0) is no paid work.
    var holdsPaidWork: Bool { running || (spent > 0 && phase != .used && phase != .choose) }

    /// What Claude mode's one automatic Try Again would pay (ai.md §12.9, "Auto-resolve stuck states"), or nil when it may not
    /// take it within `budget`, what the run could spend when it started. A lip sync whose paid result is kept is re-imported
    /// for free; a voice that stopped in a way a retry can pass (a part that failed its checks, a provider error) is voiced
    /// again when the retry's whole price fits what is left. Never after a charge fal.ai can't confirm (only the creator's
    /// "I checked fal.ai" goes on from there), a stale stop, a stop the paid voice no longer matches, or one that waits for
    /// something outside the card (a voice chosen, Voice Lab ready, an Undo: `waitsForReadiness`).
    func automaticRetryUSD(budget: Decimal) -> Decimal? {
        guard isStopped, !submissionUnconfirmed, !waitsForReadiness, let failure, Self.retriesOnItsOwn(failure), let usd = retryUSD else { return nil }
        if lipsyncKept, usd == 0 { return 0 }
        guard failure.step == .voice, !failure.repeats, usd <= budget - spent else { return nil }
        return usd
    }

    /// A stop a retry over the same inputs could pass: not stale, and not one the paid voice no longer matches, read from the
    /// failure's own type and case (`RewriteSession.failureKind`).
    static func retriesOnItsOwn(_ failure: Failure) -> Bool {
        !["case=stale", "StaleStop", "case=voiceInputsChanged"].contains { failure.kind.contains($0) }
    }

    /// Claude mode's run of this whole clip: `start` with what the run may spend, then at most one automatic Try Again
    /// (`automaticRetryUSD`), and what it came to, `holdsPaidWork` read once it ended (the live run's Rewrite predicate; by
    /// default the whole clip's own). Both starts get the same `budget`: the session takes what it already spent off it
    /// (`start(automatic:budget:)`), so a reworded voice is voiced only within what is left. `report` gets the retry's log
    /// line.
    func runAutomatically(budget: Decimal, holdsPaidWork: (@MainActor () -> Bool)? = nil, start: @MainActor (Decimal) -> Void,
                          report: @MainActor (String) -> Void = { _ in }) async -> WholeClipAutoOutcome {
        start(budget)
        await waitForRun()
        if let usd = automaticRetryUSD(budget: budget) {
            report("make-it whole clip try again step=\(failure?.step ?? .voice) usd=\(usd)")
            start(budget)
            await waitForRun()
        }
        return WholeClipAutoOutcome(self, holdsPaidWork: holdsPaidWork?())
    }
}

extension EditorModel {
    struct WholeClipStep {
        /// The review row for a revoice, or a failed one.
        var row: MakeItRow?
        /// The over-cap offer row: "Revoice the Whole Clip · ≈ $X", nothing spent until it is clicked.
        var offer: MakeItRow?
        /// True when the whole clip was revoiced, so the per-phrase voice steps don't run.
        var revoiced = false
        /// The whole clip stopped holding paid work, kept in Rewrite for the creator (`WholeClipAutoOutcome.needsYou`): the
        /// per-phrase voice steps don't run over it, as they would pay again for the same words. Music still runs.
        var holdsPaidWork = false
        /// The row says the changed phrases are voiced instead; if they aren't (Stop), it says the words were kept.
        var patchFollows = false
    }

    /// Claude mode only (a run with the video's spend pool): revoices the whole clip in place of patching when the rule says
    /// the patch would sound stitched and the price fits what is left of the cap; over the cap, the patch goes on and an
    /// offer row waits. Outside Claude mode nil: the Rewrite panel's card asks instead.
    func makeItWholeClip(_ rewrites: [ClipAutopilotOperation], run: MakeItRun, services: MakeItServices) async -> WholeClipStep? {
        guard run.budget != nil, let request = makeItWholeClipRequest(rewrites, run: run),
              let quote = await services.wholeClipQuote(request, self) else { return nil }
        switch WholeClipRevoice.autoChoice(quote.reason, price: quote.price, remaining: run.remaining) {
        case .patch:
            return nil
        case .patchAndOffer(let price):
            run.wholeClipOffer = request
            return WholeClipStep(offer: makeItWholeClipOfferRow(price: price, reason: quote.reason))
        case .revoice:
            run.line("Revoicing the whole clip…")
            let outcome = await services.revoiceWholeClip(request, self)
            return WholeClipStep(row: makeItWholeClipRow(outcome, request: request, run: run, reason: quote.reason), revoiced: outcome.isRevoiced,
                                 holdsPaidWork: outcome.holdsPaidWork, patchFollows: outcome.patches)
        }
    }

    private func makeItWholeClipRequest(_ rewrites: [ClipAutopilotOperation], run: MakeItRun) -> WholeClipAutoRequest? {
        guard let clip = project.edits.clips.first(where: { $0.id == run.clipID }), let lower = index(clip.startWordId),
              let upper = index(clip.endWordId), lower <= upper else { return nil }
        let planned = rewrites.compactMap { operation -> (range: ClosedRange<Int>, text: String)? in
            guard case .rewrite(let scope, let text) = operation.action, case .selection(let range) = scope else { return nil }
            return (range, text)
        }
        guard !planned.isEmpty else { return nil }
        return WholeClipAutoRequest(clipID: run.clipID, range: lower...upper, rewrites: planned, budget: run.remaining)
    }

    private func makeItWholeClipOfferRow(price: Decimal, reason: WholeClipRevoice.Reason?) -> MakeItRow {
        let title = "Revoice the Whole Clip · " + VoiceLabCostPresentation.format(price)
        let why = reason.map(WholeClipRevoice.callout) ?? ""
        return MakeItRow(id: "wholeClipOffer", kind: .choice, text: "Patched your phrases in your voice",
                         detail: why + " Revoicing the whole clip passes this video's cap; nothing is spent until you click it.",
                         change: .wholeClip, actionTitle: title)
    }

    private func makeItWholeClipRow(_ outcome: WholeClipAutoOutcome, request: WholeClipAutoRequest, run: MakeItRun, reason: WholeClipRevoice.Reason?) -> MakeItRow {
        switch outcome {
        case .revoiced(let record, let spent):
            run.charge(spent)
            run.voiceSpent += spent
            run.inverses["wholeClip"] = .wholeClip(record)
            let model = WholeClipRevoice.Lipsync(rawValue: record.lipsyncModel)?.name ?? "lip sync"
            return MakeItRow(id: "wholeClip", text: "Revoiced the whole clip in your voice, lip synced",
                             detail: (reason.map(WholeClipRevoice.callout) ?? "") + " Laid out on the clip as edited"
                                 + " · \(model) · " + VoiceLabCostPresentation.format(spent),
                             play: nil, undoable: true)
        case .submissionUnconfirmed(let line, let spent):
            // The per-video budget cannot authorize more work while the charge for this job is unknown.
            run.charge(spent); run.voiceSpent += spent; run.cancelled = true
            return MakeItRow(id: "wholeClip", kind: .note, text: "Stopped to check the lip-sync charge", detail: line)
        case .failed(let line, let spent):
            run.charge(spent)
            run.voiceSpent += spent
            return MakeItRow(id: "wholeClip", kind: .note, text: "Voiced only the changed phrases: the whole clip didn't finish", detail: line)
        case .needsYou(let line, let spent):
            // Its paid voice (and any lip sync) stays in Rewrite; Change shows it there, and nothing is voiced on top.
            run.charge(spent)
            run.voiceSpent += spent
            let log = app.log
            Task { await log.write(LogEntry(level: .info, category: "voice-lab", message: "make-it whole clip kept in rewrite for the creator")) }
            return MakeItRow(id: "wholeClip", kind: .note, text: "Finish the whole clip in Rewrite: its paid voice is kept", detail: line,
                             change: .phrase(request.range), actionTitle: "Show in Rewrite")
        case .patchInstead(let line, let spent):
            run.charge(spent)
            run.voiceSpent += spent
            let log = app.log
            Task { await log.write(LogEntry(level: .info, category: "voice-lab", message: "make-it whole clip fell back to the changed phrases")) }
            return MakeItRow(id: "wholeClip", kind: .note, text: "Voiced only the changed phrases: the whole clip couldn't be revoiced here", detail: line)
        }
    }

    /// The offer row's click: its approval for exactly the shown price, as one undo step.
    func makeItRevoiceOffered(_ run: MakeItRun) {
        guard let request = run.wholeClipOffer, let index = run.rows.firstIndex(where: { $0.id == "wholeClipOffer" }), !run.running else { return }
        let services = makeIt.services ?? .live
        run.wholeClipOffer = nil
        run.rows[index].text = "Revoicing the whole clip…"
        run.rows[index].change = nil
        Task { [weak self, weak run] in
            guard let self, let run else { return }
            guard let quote = await services.wholeClipQuote(request, self), let price = quote.price else {
                run.rows[index].text = "The whole clip has no price now. Nothing was spent."; return
            }
            let approved = WholeClipAutoRequest(clipID: request.clipID, range: request.range, rewrites: request.rewrites, budget: price)
            let outcome = await services.revoiceWholeClip(approved, self)
            guard run.rows.indices.contains(index) else { return }
            run.rows[index] = makeItWholeClipRow(outcome, request: approved, run: run, reason: quote.reason)
            run.seconds = makeItRenderedSeconds(run.clipID)
        }
    }
}

extension WholeClipAutoOutcome {
    var isRevoiced: Bool { if case .revoiced = self { true } else { false } }
    /// Its Rewrite stays open with paid work the creator finishes (`needsYou`), or a lip-sync charge to check
    /// (`submissionUnconfirmed`): no phrase is voiced on top of it.
    var holdsPaidWork: Bool {
        switch self {
        case .needsYou, .submissionUnconfirmed: true
        case .revoiced, .failed, .patchInstead: false
        }
    }
    /// The changed phrases are voiced on their own next: nothing was paid and nothing waits on the creator.
    var patches: Bool {
        switch self {
        case .failed, .patchInstead: true
        case .revoiced, .submissionUnconfirmed, .needsYou: false
        }
    }
}

// MARK: - The live services

extension MakeItServices {
    /// The clip with every planned rewrite in place, as Rewrite's reply over the whole clip (the cut words stay in it, so
    /// the reply changes only the rewrites).
    @MainActor static func wholeClipPassage(_ request: WholeClipAutoRequest, editor: EditorModel) -> String {
        let words = RewriteSession.corrected(editor.project)
        var parts: [String] = []
        var index = request.range.lowerBound
        while index <= request.range.upperBound {
            if let rewrite = request.rewrites.first(where: { $0.range.lowerBound == index }) {
                parts.append(rewrite.text)
                index = rewrite.range.upperBound + 1
                continue
            }
            if words.indices.contains(index), words[index].kind == .word { parts.append(words[index].text) }
            index += 1
        }
        return parts.joined(separator: " ")
    }

    /// Opens Rewrite over the whole clip with the planned words, its voice discovered, and its whole-clip card made. An open
    /// Rewrite holding unused or running paid work (takes, a whole clip's voice or lip sync) is never closed for it: nil.
    @MainActor static func openWholeClip(_ request: WholeClipAutoRequest, editor: EditorModel) async -> RewriteSession? {
        // The quote's session goes on to the revoice: one Rewrite, one voice plan, nothing quoted twice.
        if let open = editor.openRewrite, open.isOpen, open.project.edits.activeClipId == request.clipID,
           open.rewriteScope == .selection(request.range), let whole = open.wholeClip,
           whole.phase == .choose, !open.hasUnusedPaidWork {
            await whole.refreshQuote()
            return open
        }
        if let open = editor.openRewrite, open.isOpen {
            guard !open.asksBeforeClosing, editor.closeRewrite(returnFocus: false) else { return nil }
        }
        guard let session = MakeItRewriteDriver.openSession(editor: editor, clipID: request.clipID, range: request.range,
                                                            text: wholeClipPassage(request, editor: editor)) else { return nil }
        #if DEBUG
        await editor.makeItGeneration?(session)
        #endif
        if session.generation == nil { await session.discoverVoices() }
        guard session.wholeClipCard() != nil, let whole = session.wholeClip else { editor.closeRewrite(returnFocus: false); return nil }
        await whole.refreshQuote()
        return session
    }

    @MainActor static func liveWholeClipQuote(_ request: WholeClipAutoRequest, editor: EditorModel) async -> WholeClipAutoQuote? {
        // The session stays open for the revoice; the patch's own Rewrite closes it (nothing in it is paid).
        guard editor.app.voiceLabRewriteEnabled, let session = await openWholeClip(request, editor: editor) else { return nil }
        guard let quote = session.wholeClip?.quote else { editor.closeRewrite(returnFocus: false); return nil }
        return WholeClipAutoQuote(reason: quote.reason, price: quote.wholeUSD)
    }

    /// Claude mode's revoice: the run within the request's budget, at most one automatic Try Again
    /// (`WholeClipRevoiceSession.runAutomatically`), and Rewrite closed only when it holds no paid work. A paid voice or lip
    /// sync the run couldn't finish stays in Rewrite for the creator (`needsYou`); Claude mode never discards it.
    @MainActor static func liveRevoiceWholeClip(_ request: WholeClipAutoRequest, editor: EditorModel) async -> WholeClipAutoOutcome {
        guard let session = await openWholeClip(request, editor: editor), let whole = session.wholeClip else {
            return .failed("Rewrite couldn't open this clip. Nothing was sent.", spent: 0)
        }
        // One predicate decides both what the run comes to and whether Rewrite stays open: its unused paid work.
        var keepsOpen = false
        defer { if session.isOpen, !keepsOpen { editor.closeRewrite(returnFocus: false) } }
        guard let price = whole.quote?.wholeUSD, let budget = request.budget, price <= budget else {
            return .failed("Revoicing the whole clip passes this video's cap. Nothing was sent.", spent: 0)
        }
        let log = editor.app.log
        // B's automatic start: a reworded voice is voiced only within the budget, else it waits for the creator's priced
        // click (`Stop.shorterWordingReady`), which Claude mode never gives.
        let outcome = await whole.runAutomatically(budget: budget, holdsPaidWork: { [weak session] in session?.hasUnusedPaidWork ?? false }, start: { [weak session] budget in
            session?.startWholeClip(automatic: true, budget: budget)
        }, report: { line in Task { await log.write(LogEntry(level: .info, category: "voice-lab", message: line)) } })
        keepsOpen = outcome.holdsPaidWork
        // A patch closes this Rewrite (nothing paid is in it) and leaves no pick: a pick is for its own proposal, so the
        // patch's Rewrite and any later one offer the whole clip from the default again (`wholeClipCard`).
        return outcome
    }
}
