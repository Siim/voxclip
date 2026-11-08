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
    case failed(String, spent: Decimal)
    /// The whole clip can't be done here: a part that can't be placed, a stop before anything was sent, a picture that can't
    /// be matched, a lip sync that failed on this Mac, or a voice that can't fit the clip as edited within these rules (its
    /// voice paid). The changed phrases are voiced instead, with the line saying why (ADR-R46).
    case patchInstead(String, spent: Decimal)

    /// What a finished automatic run comes to.
    @MainActor init(_ session: WholeClipRevoiceSession) {
        switch session.phase {
        case .used:
            self = session.record.map { .revoiced($0, spent: session.spent) } ?? .failed("The whole clip couldn't be put in.", spent: session.spent)
        case .stopped(let line):
            // A stop that would only repeat (whatever was paid for the voice is charged to the run) or a Fit stop patches.
            let patches = session.failure?.repeats == true || session.failure?.step == .fit
            self = patches ? .patchInstead(line, spent: session.spent) : .failed(line, spent: session.spent)
        default: self = .failed("The whole clip didn't finish.", spent: session.spent)
        }
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
            return WholeClipStep(row: makeItWholeClipRow(outcome, run: run, reason: quote.reason), revoiced: outcome.isRevoiced)
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

    private func makeItWholeClipRow(_ outcome: WholeClipAutoOutcome, run: MakeItRun, reason: WholeClipRevoice.Reason?) -> MakeItRow {
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
        case .failed(let line, let spent):
            run.charge(spent)
            run.voiceSpent += spent
            return MakeItRow(id: "wholeClip", kind: .note, text: "Kept your words: the whole clip couldn't be revoiced", detail: line)
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
            run.rows[index] = makeItWholeClipRow(outcome, run: run, reason: quote.reason)
            run.seconds = makeItRenderedSeconds(run.clipID)
        }
    }
}

extension WholeClipAutoOutcome {
    var isRevoiced: Bool { if case .revoiced = self { true } else { false } }
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

    /// Opens Rewrite over the whole clip with the planned words, its voice discovered, and its whole-clip card made.
    @MainActor static func openWholeClip(_ request: WholeClipAutoRequest, editor: EditorModel) async -> RewriteSession? {
        // The quote's session goes on to the revoice: one Rewrite, one voice plan, nothing quoted twice.
        if let open = editor.openRewrite, open.isOpen, open.rewriteScope == .selection(request.range), let whole = open.wholeClip,
           whole.phase == .choose, !open.hasPaidTakes {
            await whole.refreshQuote()
            return open
        }
        if let open = editor.openRewrite, open.isOpen {
            guard !open.hasPaidTakes else { return nil }
            editor.closeRewrite(returnFocus: false)
        }
        guard let session = MakeItRewriteDriver.openSession(editor: editor, range: request.range, text: wholeClipPassage(request, editor: editor)) else { return nil }
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

    @MainActor static func liveRevoiceWholeClip(_ request: WholeClipAutoRequest, editor: EditorModel) async -> WholeClipAutoOutcome {
        guard let session = await openWholeClip(request, editor: editor), let whole = session.wholeClip else {
            return .failed("Rewrite couldn't open this clip. Nothing was sent.", spent: 0)
        }
        defer { if session.isOpen { editor.closeRewrite(returnFocus: false) } }
        guard let price = whole.quote?.wholeUSD, let budget = request.budget, price <= budget else {
            return .failed("Revoicing the whole clip passes this video's cap. Nothing was sent.", spent: 0)
        }
        session.startWholeClip(automatic: true)
        await whole.waitForRun()
        let outcome = WholeClipAutoOutcome(whole)
        // The patch goes on: this clip's pick is the patch, so its phrases' Rewrites don't offer the whole clip again.
        if case .patchInstead = outcome { editor.wholeClipPicks[request.clipID] = false }
        return outcome
    }
}
