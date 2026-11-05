import Foundation
import VoxClipCore

/// Voices one planned rewrite with Rewrite's own session and take plan (doc/design.md §6.7): the planner's words are the
/// session's proposal, and the driver takes the steps a creator would, in the panel's own controls, within the run's
/// budget. Each priced step is checked against the budget before it runs; the click on ✦ Make it postable is its
/// approval, so the existing quote, approval and spend ledger paths authorize it. It never discards a paid take, never
/// sends the words to the AI again on its own, and stops (leaving Rewrite open) where the creator is needed.
@MainActor final class MakeItRewriteDriver {
    let editor: EditorModel
    let request: MakeItRewriteRequest
    private var session: RewriteSession?
    private var joinNotes: [Int] = []
    /// The control the last step pressed, for the smoke's observation.
    private var pressed: String?

    init(editor: EditorModel, request: MakeItRewriteRequest) { self.editor = editor; self.request = request }

    /// The footer, link and chip controls the driver may press, in the order a creator reaches for them. Discard, Done,
    /// Keep original words, Ask again and Try again are never pressed: each gives up a take or sends again.
    static let order = ["approveTakeQuote", "useTakes", "chooseTake", "takeQuote-", "prepareTakes", "makeTakes", "keepFixing",
                        "withinSentence", "revoiceAll", "mergePhrases", "freshPrice", "reviewTakes", "showTakes", "keepAll", "useTake"]
    /// Controls whose click costs money; they run only within the budget.
    static func pricedID(_ id: String) -> Bool { id.hasPrefix("takeQuote-") || id.hasPrefix("approveTakeQuote") || id.hasPrefix("keepFixing") }

    func run() async -> MakeItRewriteOutcome {
        guard editor.app.voiceLabRewriteEnabled else {
            return MakeItRewriteOutcome(result: .unavailable("Turn on Voice Lab and make your voice to voice rewrites. Nothing was sent."))
        }
        if let open = editor.openRewrite, open.isOpen {
            guard !open.hasPaidTakes else { return MakeItRewriteOutcome(result: .needsYou("Finish the open Rewrite first; its paid takes are kept.")) }
            editor.closeRewrite(returnFocus: false)
        }
        guard let session = open() else {
            return MakeItRewriteOutcome(result: .needsYou("Rewrite couldn't place these words. Change to try it yourself."))
        }
        self.session = session
        #if DEBUG
        await editor.makeItGeneration?(session)
        #endif
        let before = Set(editor.project.voiceLab.segments.map(\.id))
        var spent = Decimal(0)
        for _ in 0..<32 {
            await settle()
            spent = max(spent, session.takePlan?.spent.usd ?? 0)
            #if DEBUG
            if let pressed { await editor.makeItStepObserver?(pressed) }
            #endif
            pressed = nil
            guard session.isOpen else { break }
            if let blocked = await step(session, spent: spent) {
                spent = max(spent, session.takePlan?.spent.usd ?? 0)
                return MakeItRewriteOutcome(result: blocked, spent: spent, joinNotes: joinNotes)
            }
        }
        spent = max(spent, session.takePlan?.spent.usd ?? 0)
        let added = editor.project.voiceLab.segments.map(\.id).filter { !before.contains($0) }
        if !added.isEmpty, !session.isOpen { return MakeItRewriteOutcome(result: .voiced(segments: added), spent: spent, joinNotes: joinNotes) }
        let note = (session.task.footer.note ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return MakeItRewriteOutcome(result: .needsYou(note.isEmpty ? "Rewrite is waiting for you. Change to finish it." : note), spent: spent, joinNotes: joinNotes)
    }

    /// Opens Rewrite on the planned words: the session's reply is the planner's text, reviewed as any reply is.
    private func open() -> RewriteSession? {
        let app = editor.app
        let provider = app.providers.first { $0.id == app.string("llm.connector") }
        let connector = provider.map { provider in
            RewriteConnector(connector: app.connector(provider.id), model: app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? ""),
                             name: provider.shortName, group: provider.group, plan: provider.id == "codex" ? "ChatGPT plan" : "Claude plan")
        }
        let envelope = editor.waveform.map { AudioEnvelope(sampleRate: Double(editor.project.media.source.audio?.sampleRate ?? 48_000), levels: $0.fine) }
        let prices = app.shared.flatMap { try? VoiceLabPriceCatalog.load(shared: $0) }
        let session = RewriteSession(editor: editor, scope: .selection(request.range), envelope: envelope, connector: connector, prices: prices,
            consent: { [weak editor] in
                guard let editor, let provider else { return false }
                return await editor.rewriteConsent(provider: provider)
            })
        editor.openRewrite = session
        do { try session.receivePassage(request.text) } catch { editor.closeRewrite(returnFocus: false); return nil }
        session.finishRun(seconds: 0)
        guard session.isOpen, session.review != nil else { editor.closeRewrite(returnFocus: false); return nil }
        return session
    }

    /// One step: a question first (only the takes' own price may be approved), then a join-only take, then the
    /// furthest-reaching control. Nil to go on; a result to stop with.
    private func step(_ session: RewriteSession, spent: Decimal) async -> MakeItRewriteOutcome.Result? {
        let task = session.task
        if let confirm = task.confirm {
            guard confirm.confirm.id.hasPrefix("approveTakeQuote") else {
                if confirm.confirm.id == "allowVoiceProvider" { return .needsYou("Allow ElevenLabs in Rewrite to voice this fix. Nothing was sent.") }
                return .needsYou(confirm.question.split(separator: "\n").first.map(String.init) ?? "Rewrite is asking you something.")
            }
            return await press(confirm.confirm, session: session, spent: spent)
        }
        if acceptJoinOnlyTakes(session) { return nil }
        var actions = [task.footer.primary, task.footer.link].compactMap { $0 }
        for card in task.cards { if case .nextSteps(let steps) = card { actions += steps.chips.map(\.action) } }
        for id in Self.order {
            if let action = actions.first(where: { $0.id.hasPrefix(id) }) { return await press(action, session: session, spent: spent) }
        }
        return .needsYou((task.footer.note ?? "").split(separator: "\n").first.map(String.init) ?? "Rewrite is waiting for you.")
    }

    /// Presses `action`; a priced one only while its price fits what is left of the budget.
    private func press(_ action: PanelAction, session: RewriteSession, spent: Decimal) async -> MakeItRewriteOutcome.Result? {
        var price: Decimal?
        if action.priced || Self.pricedID(action.id) {
            price = action.id.hasPrefix("keepFixing") ? session.autoFix.capped?.usd : session.takePlan?.estimate?.usd
            guard let budget = request.budget, let price, spent + price <= budget else { return .overCap(nextUSD: price) }
        }
        let pending = session.takesTask
        pressed = "Make it postable presses [\(action.title)]"
        action.perform()
        // An approved price also lets Rewrite fix stuck phrases on its own; that allowance stays inside the budget.
        if let price, let budget = request.budget, session.autoFix.armed {
            session.autoFix.allowance = min(session.autoFix.allowance, max(0, budget - spent - price))
        }
        if let started = session.takesTask, pending.map({ $0 != started }) ?? true { await started.value }
        return nil
    }

    /// A take whose only problem is the join's loudness is chosen (lead decision for Make it postable); its review row
    /// says "join may sound slightly louder · ▶". True when one was chosen.
    private func acceptJoinOnlyTakes(_ session: RewriteSession) -> Bool {
        guard let plan = session.takePlan, !session.takesBusy else { return false }
        for phrase in plan.phrases where !phrase.leftOut {
            if let selected = phrase.selected, selected.row.selectable, !selected.row.requiresJoinAdvisoryAcceptance { continue }
            let candidate = phrase.selected.flatMap { $0.row.selectable && $0.row.requiresJoinAdvisoryAcceptance ? $0 : nil }
                ?? phrase.takes.first { $0.row.selectable && $0.row.requiresJoinAdvisoryAcceptance }
            guard let take = candidate else { continue }
            var chosen = false
            session.mutateLipsync(phrase: phrase.id) { chosen = plan.useAnyway(take: take.id, phrase: phrase.id) }
            if chosen {
                pressed = "Make it postable uses phrase \(phrase.id + 1)'s take (join advisory only)"
                joinNotes.append(phrase.id)
                session.autoChooseVideo(plan)
                session.showProposal()
                return true
            }
        }
        return false
    }

    /// Waits until the session has nothing in flight. The limit only stops a session that never settles.
    private func settle(timeout: Double = 600) async {
        let start = ProcessInfo.processInfo.systemUptime
        var calm = 0
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            if busy { calm = 0 } else { calm += 1; if calm >= 3 { return } }
            try? await Task.sleep(for: .milliseconds(calm > 0 ? 5 : 40))
        }
    }

    private var busy: Bool {
        guard let session, session.isOpen else { return false }
        if case .running = session.task.state { return true }
        if session.isProposing || session.takesBusy || session.isReasking || session.wordingFit.running { return true }
        if session.wordingFit.measured?.preparing == true || session.takePlan?.lipsync.usingTakes == true || session.autoFix.work != nil { return true }
        return false
    }
}
