import Observation
import SwiftUI
import VoxClipCore

// Rewrite never dead-ends (design.md R2 "Next steps", voice-lab.md §8.2.1): every stuck state of the Rewrite panel shows
// a row of chips. Built-in chips run the app's existing actions; AI chips (✦) come from the reply's `nextActions`. An AI
// chip or the free-text field re-asks in the same session: the Rewrite request goes again with the step's instruction as
// feedback, scoped to its phrases, and only those phrases can change (`RewriteScopedReply`). Every other change, edit,
// quote and take stays as it is.

/// A scoped re-ask: what the chip says, what is sent, and the phrases it may change.
struct RewriteReask: Equatable {
    let label: String
    let instruction: String
    let ordinals: [Int]
    let reason: RewriteBlockedPhrase.Reason
}

@MainActor @Observable final class RewriteReaskState {
    /// The re-ask in flight; the panel shows "Asking {AI}: “{label}”" with Stop.
    var running: RewriteReask?
    /// What the last re-ask did or why it did nothing, shown on the stuck state's chips.
    var notice = ""
    var noticeWarns = false
    /// A re-ask whose reply was not used (stale or stopped): its "Ask again" chip.
    var retry: RewriteReask?
    /// The last reply's valid AI-suggested next steps.
    var suggestions: [RewriteNextAction] = []
    @ObservationIgnored var token = UUID()
    @ObservationIgnored var work: Task<Void, Never>?
    @ObservationIgnored var lease: UUID?

    /// A new reply: nothing is asked again yet.
    func reset() {
        notice = ""; noticeWarns = false; retry = nil; suggestions = []
    }
}

/// The voice budget's figures while the included phrases are over it (voice-lab.md §8.2).
struct VoiceBudgetAdvice: Equatable {
    let voiceWords: Int
    let scopeWords: Int
    let limit: Int
}

extension RewriteSession {
    var isReasking: Bool { reasking.running != nil }

    // MARK: Re-asking

    /// Re-asks the AI with `request` in this session (an AI chip, the free-text field, Change fewer words). Paid takes
    /// are only discarded after the existing inline confirmation; the phrases outside `request.ordinals` stay frozen.
    func reask(_ request: RewriteReask) {
        guard current, !isProposing, ownProposal != nil, connector != nil, !request.ordinals.isEmpty else { return }
        if confirmPaidProposalChange(perform: { [weak self] in self?.reask(request) }) { return }
        stopWordingFit(refresh: false)
        stopReask(refresh: false)
        guard let connector, let shared = editor.app.shared else { return }
        reasking.retry = nil
        let feedback: String
        do { feedback = try reaskFeedback(request, shared: shared) } catch {
            showNotice(Self.refusal(error), warns: true)
            return
        }
        guard let lease = editor.llmRuns.acquire() else {
            showNotice(editor.finding ? "Find Clips is still running. Try again when it finishes." :
                "Another AI request on this project is still running. Try again when it finishes.", warns: true)
            return
        }
        let token = UUID(), expected = revision
        reasking.token = token; reasking.lease = lease; reasking.running = request
        reasking.notice = ""; reasking.noticeWarns = false
        reasking.suggestions.removeAll { $0.label == request.label && $0.instruction == request.instruction }
        showProposal()
        editor.announce("Asking \(aiName): \(request.label)")
        reasking.work = Task { [weak self] in
            guard let self else { return }
            defer {
                editor.llmRuns.release(lease)
                if reasking.token == token {
                    reasking.running = nil; reasking.lease = nil; reasking.work = nil
                    if let plan = takePlan { applyPendingExpressions(plan) }
                    if isOpen, case .proposal = task.state { showProposal() }
                }
            }
            let live: @MainActor () -> Bool = { [unowned self] in reasking.token == token && current && revision == expected && !Task.isCancelled }
            do {
                let prepared = try await prepareSend(connector, feedback: feedback)
                guard live() else { return staleReply(request, token: token) }
                guard await confirmSend() else {
                    if reasking.token == token { reasking.notice = "Nothing was sent. Nothing changed."; reasking.noticeWarns = false }
                    return
                }
                guard live() else { return staleReply(request, token: token) }
                guard let (checked, nextActions) = try await reply(prepared, connector: connector, accept: live) else {
                    return staleReply(request, token: token)
                }
                guard live() else { return staleReply(request, token: token) }
                try land(checked.changes, request: request, nextActions: nextActions)
            } catch {
                guard reasking.token == token, !Task.isCancelled else { return }
                let reason = (error as? LLMError).map { Self.proposalError($0, provider: aiName, model: connector.model) } ?? Self.refusal(error)
                reasking.notice = "Couldn't ask \(aiName). " + (reason.isEmpty ? "Nothing changed." : reason)
                reasking.noticeWarns = true
                reasking.retry = request
                retryReaskOnce(request)
            }
        }
    }

    /// Stop: the re-ask ends with nothing changed, and its chip can ask again.
    func stopReask(refresh: Bool = true) {
        guard let request = reasking.running else { return }
        reasking.token = UUID()
        reasking.work?.cancel(); reasking.work = nil
        if let lease = reasking.lease { editor.llmRuns.release(lease) }
        reasking.lease = nil; reasking.running = nil
        reasking.retry = request
        reasking.notice = "Stopped. Nothing changed."; reasking.noticeWarns = false
        if refresh, isOpen, case .proposal = task.state { showProposal() }
    }

    /// The free-text field of a failed or stale Rewrite: the whole scope asked again with the user's words as feedback.
    func askInstead(_ text: String) {
        guard let shared = editor.app.shared, let feedback = try? RewriteNextActionFeedback.open(instruction: text, shared: shared) else { return }
        editor.sendRewriteAgain(self, instruction: instruction, feedback: feedback)
    }

    private func staleReply(_ request: RewriteReask, token: UUID) {
        guard reasking.token == token, isOpen else { return }
        reasking.retry = request
        reasking.notice = "\(task.words.subject) changed while \(aiName) answered, so its reply was not used. Nothing changed."
        reasking.noticeWarns = true
        retryReaskOnce(request)
    }

    private func showNotice(_ text: String, warns: Bool) {
        reasking.notice = text; reasking.noticeWarns = warns
        if isOpen, case .proposal = task.state { showProposal() }
        editor.announce(text)
    }

    /// The feedback a re-ask sends: the instruction and, for each of its phrases, why it is blocked.
    func reaskFeedback(_ request: RewriteReask, shared: SharedResources) throws -> String {
        let readings = Dictionary(editor.changeReadings.map { ($0.change.ordinal, $0) }, uniquingKeysWith: { first, _ in first })
        let phrases = try request.ordinals.map { ordinal -> RewriteBlockedPhrase in
            guard let reading = readings[ordinal] else { throw CancellationError() }
            let timing = voiceReview(ordinal)?.timing
            let reason: RewriteBlockedPhrase.Reason = request.reason == .fit && timing == nil ? .asked : request.reason
            return RewriteBlockedPhrase(ordinal: ordinal, reason: reason, original: reading.removed.joined(separator: " "),
                proposed: reading.text, estimateSeconds: timing?.estimateSeconds, slotSeconds: timing?.slotSeconds)
        }
        let budget = voiceBudget.map { RewriteNextActionFeedback.Budget(voiceWords: $0.voiceWords, scopeWords: $0.scopeWords) }
            ?? RewriteNextActionFeedback.Budget(voiceWords: 0, scopeWords: task.words.wordCount)
        return try RewriteNextActionFeedback.scoped(instruction: request.instruction, phrases: phrases, budget: budget, shared: shared)
    }

    /// Lands a re-ask's reply: the asked phrases take the reply's change there, or keep their original words where the
    /// reply leaves them as recorded; a phrase whose reply reaches a frozen change stays as it was.
    private func land(_ reply: [RewriteChange], request: RewriteReask, nextActions: [RewriteNextAction]) throws {
        let asked = Set(request.ordinals.map { $0 - 1 })
        let outcomes = RewriteScopedReply.assign(current: changes.map(\.hunk), asked: asked, reply: reply.map(\.hunk))
        var replacements: [Int: RewriteChange] = [:], kept: Set<Int> = [], unchanged: [Int] = [], absorbed: Set<Int> = []
        for (index, outcome) in outcomes {
            switch outcome {
            case .replace(let found): replacements[index + 1] = reply[found]
            case .keepOriginal: kept.insert(index + 1)
            case .absorbed: absorbed.insert(index + 1)
            case .conflict: unchanged.append(index + 1)
            }
        }
        if replacements.isEmpty, kept.isEmpty {
            reasking.notice = "\(aiName)'s reply also changed other phrases, so it was not used. Nothing changed."
            reasking.noticeWarns = true; reasking.retry = request
            reasking.suggestions = nextActions
            return
        }
        try applyReask(replacing: replacements, keepingOriginal: kept, absorbing: absorbed)
        reasking.suggestions = absorbed.isEmpty ? nextActions : []
        func phrases(_ ordinals: [Int]) -> String {
            let sorted = ordinals.sorted().map(String.init)
            return (sorted.count == 1 ? "phrase " : "phrases ") + sorted.joined(separator: ", ")
        }
        var parts: [String] = []
        if !absorbed.isEmpty, let into = replacements.keys.min() {
            parts.append("\(aiName) merged \(phrases(Array(replacements.keys) + Array(absorbed))) into one phrase, now change \(into).")
        } else if !replacements.isEmpty { parts.append("\(aiName) reworded \(phrases(Array(replacements.keys))).") }
        if !kept.isEmpty { parts.append("Kept your original words for \(phrases(Array(kept))).") }
        if !unchanged.isEmpty { parts.append("\(phrases(unchanged).prefix(1).uppercased() + phrases(unchanged).dropFirst()) stayed as before: the reply also changed other words there.") }
        reasking.notice = parts.joined(separator: " ")
        reasking.noticeWarns = !unchanged.isEmpty
        editor.announce(reasking.notice)
    }

    // MARK: Stuck states

    /// The voice budget's figures while the reviewed phrases are over it (voice-lab.md §8.2), nil while they fit.
    var voiceBudget: VoiceBudgetAdvice? {
        let hunks = reviewedVoiceOrdinals.compactMap { changes.indices.contains($0 - 1) ? changes[$0 - 1].hunk : nil }
        let budget = VoiceLabPatchBudget.evaluate(hunks: hunks, transcript: transcript)
        guard budget.flag == .reRecordInstead else { return nil }
        return VoiceBudgetAdvice(voiceWords: budget.voiceTokenCount, scopeWords: task.words.wordCount,
                                 limit: min(60, budget.wordItems * 15 / 100))
    }

    /// The AI chips for `stuck` phrases: suggestions whose phrases include one of them, scoped to the proposal's phrases.
    private func suggestionChips(stuck: [Int], reason: RewriteBlockedPhrase.Reason, tried: [VoiceLabFitTried] = []) -> [NextStepChip] {
        guard connector != nil, !stuck.isEmpty, let proposal = ownProposal else { return [] }
        let known = Set(proposal.changes.map(\.ordinal))
        let triedKeys = Set(tried.map { VoiceLabFitTried.key($0.text) })
        var seen: Set<String> = []
        return reasking.suggestions.enumerated().compactMap { offset, suggestion in
            let ordinals = suggestion.ordinals.isEmpty ? stuck : suggestion.ordinals.filter(known.contains)
            guard !ordinals.isEmpty, !Set(ordinals).isDisjoint(with: stuck) else { return nil }
            // One chip per variant, and none that offers a wording already tried (voice-lab §8.2.2).
            let key = VoiceLabFitTried.key(suggestion.instruction)
            guard seen.insert(key).inserted, !triedKeys.contains(key), !triedKeys.contains(VoiceLabFitTried.key(suggestion.label)) else { return nil }
            let request = RewriteReask(label: suggestion.label, instruction: suggestion.instruction, ordinals: ordinals, reason: reason)
            return NextStepChip(action: PanelAction(id: "suggestion.\(offset)", title: suggestion.label) { [weak self] in
                guard let self else { return }
                editor.sendRewriteAgain(self, reask: request)
            }, suggested: true)
        }
    }
    private func freeText(_ id: String, stuck: [Int], reason: RewriteBlockedPhrase.Reason) -> NextStepAsk? {
        guard connector != nil, !stuck.isEmpty else { return nil }
        return NextStepAsk(id: id, placeholder: NextSteps.askPlaceholder) { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let label = trimmed.count > 40 ? String(trimmed.prefix(39)) + "…" : trimmed
            editor.sendRewriteAgain(self, reask: RewriteReask(label: label, instruction: trimmed, ordinals: stuck, reason: reason))
        }
    }
    func chip(_ id: String, _ title: String, perform: @escaping @MainActor () -> Void) -> NextStepChip {
        NextStepChip(action: PanelAction(id: id, title: title, perform: perform))
    }
    /// The chips of a stuck state while automatic fixes run: one "Choose yourself…" that opens them (design.md R2).
    /// What automatic fixes decided and phrases whose rounds ended stay in view, with their chips.
    private func collapsed(_ steps: [NextSteps]) -> [NextSteps] {
        guard !autoFix.choicesShown else { return steps }
        let kept = steps.filter { $0.id == "autoNotes" || $0.id.hasPrefix("kept.") }
        guard steps.count > kept.count else { return kept }
        return kept + [NextSteps(id: "choose", chips: [chip("chooseYourself", "Choose yourself…") { [weak self] in
            guard let self else { return }
            autoFix.showChoices = true
            showProposal()
        }])]
    }
    /// The phrases a merge would join, as the AI is asked to write them: a refused collision of the last plan.
    func mergeReask() -> RewriteReask? {
        guard let refusal = planRefusal, let earlier = refusal.earlier, connector != nil, let shared = editor.app.shared,
              let merge = try? RewriteNextActionFeedback.merge(first: earlier, second: refusal.phrase, shared: shared) else { return nil }
        return RewriteReask(label: "Merge with phrase \(earlier)", instruction: merge, ordinals: [earlier, refusal.phrase].sorted(), reason: .collision)
    }
    /// Where a change sits in the source, "5:40", for the chips that name it.
    func changeTime(_ ordinal: Int) -> String? {
        guard changes.indices.contains(ordinal - 1) else { return nil }
        let hunk = changes[ordinal - 1].hunk
        let seconds = hunk.sourceWordIds.first.flatMap { id in project.transcript?.words.first { $0.id == id }?.start } ?? hunk.anchorSeconds
        guard let seconds, seconds.isFinite else { return nil }
        let whole = Int(seconds.rounded(.down))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// Over the voice budget (voice-lab.md §8.2, advisory): the phrases are voiced anyway, and the chips under
    /// "Choose yourself…" offer Change fewer words, the AI's suggestions and, with free changes waiting, Keep text fixes only.
    func budgetSteps(_ advice: VoiceBudgetAdvice, freeChanges: Int) -> NextSteps {
        let voices = reviewedVoiceOrdinals
        var chips: [NextStepChip] = []
        if connector != nil, let shared = editor.app.shared, let fewer = try? RewriteNextActionFeedback.fewerWords(limit: advice.limit, shared: shared) {
            let request = RewriteReask(label: "Change fewer words", instruction: fewer, ordinals: voices, reason: .budget)
            chips.append(chip("changeFewerWords", "Change fewer words") { [weak self] in
                guard let self else { return }
                editor.sendRewriteAgain(self, reask: request)
            })
        }
        chips += suggestionChips(stuck: voices, reason: .budget)
        if freeChanges > 0 {
            chips.append(chip("keepTextFixes", "Keep text fixes only") { [weak self] in self?.applyFreeChanges() })
        }
        return NextSteps(id: "budget", chips: chips, ask: freeText("budget", stuck: voices, reason: .budget))
    }

    /// The next steps of every stuck state the proposal shows now, after its main cards: a phrase that still does not fit
    /// (its built-in steps are on its row), phrases whose takes all failed, phrases kept as recorded after their automatic
    /// rounds, and a refused surrounding sentence. One "Tell the AI what to do instead…" field closes them, scoped to
    /// every stuck phrase; chips that act on one phrase or change name it. While automatic fixes run the chips wait
    /// under "Choose yourself…".
    func stuckSteps() -> [NextSteps] {
        guard !wordingIsLocked, !isReasking, ownProposal != nil else { return [] }
        var steps: [NextSteps] = []
        var stuck: [Int] = []
        var reason: RewriteBlockedPhrase.Reason?
        func note(_ ordinals: [Int], _ why: RewriteBlockedPhrase.Reason) {
            stuck += ordinals
            if reason == nil { reason = why }
        }
        if let plan = planSteps() {
            steps.append(plan)
            if let refusal = planRefusal { note([refusal.earlier, refusal.phrase].compactMap { $0 }, .collision) }
        }
        let blocked = blockedVoiceOrdinals
        if !blocked.isEmpty {
            let chips = suggestionChips(stuck: blocked, reason: .fit)
            if !chips.isEmpty { steps.append(NextSteps(id: "fit", chips: chips)) }
            note(blocked, .fit)
        }
        if let plan = takePlan, !takesBusy {
            let several = plan.phrases.count > 1
            for phrase in plan.phrases where !phrase.leftOut {
                guard let why = stuckReason(phrase, plan: plan), autoFix.lines[phrase.id] == nil else { continue }
                if case .length(_, _, _, _, _, true) = why { continue }    // its row has the length steps
                let ordinals = takePhraseOrdinals(phrase)
                let name = several ? " for phrase \(phrase.id + 1)" : ""
                let keep = chip("keepOriginal.\(phrase.id)", "Keep original words" + name) { [weak self] in self?.keepOriginal(phrase: phrase.id) }
                var chips: [NextStepChip]
                if case .provider = why {
                    // The cause and its one fix (voice-lab §8.2.2): never wording chips.
                    chips = [chip("priceTake.\(phrase.id)", "Price a take" + name) { [weak self] in self?.priceAnotherTake(phrase: phrase.id) }, keep]
                } else {
                    chips = [chip("tryAnother.\(phrase.id)", "Try another" + name) { [weak self] in self?.priceAnotherTake(phrase: phrase.id) }, keep]
                    if why == .shortSpeech || why.rewords, canReviewSpeechContext(phrase: phrase) {
                        chips.append(chip("surrounding.\(phrase.id)", "Use surrounding sentence" + name) { [weak self] in
                            self?.reviewSpeechContext(phrase: phrase.id)
                        })
                    }
                    // Wording suggestions only for wording and fit failures, never one that repeats a tried wording.
                    if why.rewords { chips += suggestionChips(stuck: ordinals, reason: .take, tried: triedWordings(phrase, plan: plan)) }
                }
                steps.append(NextSteps(id: "take.\(phrase.id)", line: Self.stuckSentence(why, phrase: phrase.id + 1), chips: chips))
                note(ordinals, .take)
            }
            for phrase in plan.phrases where phrase.leftOut && autoFix.gaveUp.contains(phrase.id) {
                let tries = autoFix.rounds[phrase.id, default: RewriteAutoFixState.maximumRounds]
                steps.append(NextSteps(id: "kept.\(phrase.id)",
                    line: "Phrase \(phrase.id + 1) kept your original audio after \(tries) \(tries == 1 ? "try" : "tries").",
                    chips: [chip("undoKeep.\(phrase.id)", "Undo") { [weak self] in self?.undoKeepOriginal(phrase: phrase.id) },
                            chip("tryAnother.\(phrase.id)", "Try another for phrase \(phrase.id + 1)") { [weak self] in
                                self?.undoKeepOriginal(phrase: phrase.id); self?.priceAnotherTake(phrase: phrase.id) }]))
                note(takePhraseOrdinals(phrase), .take)
            }
        }
        let refused = speechContextRefusedOrdinals.filter(reviewedVoiceOrdinals.contains)
        if !speechContextProblem.isEmpty, !refused.isEmpty {
            let several = refused.count > 1
            var chips: [NextStepChip] = []
            for ordinal in refused {
                let name = several ? " \(ordinal)" : ""
                chips.append(chip("leaveOut.\(ordinal)", "Leave out this change" + name) { [weak self] in self?.leaveOutChange(ordinal) })
                if voiceReview(ordinal)?.window != nil, !blocked.contains(ordinal) || voiceReview(ordinal)?.timing != nil {
                    chips.append(chip("changedWordsOnly.\(ordinal)", "Voice just the changed words" + name) { [weak self] in
                        self?.phraseTimingAction(.priceAnyway, ordinals: [ordinal])
                    })
                }
            }
            if connector != nil {
                let request = RewriteReask(label: "Rewrite without changing the sentence around it", instruction: Self.withinSentenceInstruction,
                    ordinals: refused, reason: .context)
                chips.append(NextStepChip(action: PanelAction(id: "withinSentence", title: request.label) { [weak self] in
                    guard let self else { return }
                    editor.sendRewriteAgain(self, reask: request)
                }, suggested: true))
            }
            chips += suggestionChips(stuck: refused, reason: .context)
            let names = refused.map { ordinal in changeTime(ordinal).map { "Change \(ordinal) at \($0)" } ?? "Change \(ordinal)" }
            steps.append(NextSteps(id: "context", line: names.joined(separator: ", ") + ": " + speechContextProblem, chips: chips))
            note(refused, .context)
        }
        if !autoFix.notes.isEmpty { steps.insert(NextSteps(id: "autoNotes", line: autoFix.notes.joined(separator: "\n")), at: 0) }
        var shown = collapsed(steps.filter { !$0.chips.isEmpty || $0.id == "autoNotes" || $0.id.hasPrefix("kept.") || $0.line != nil })
        if autoFix.choicesShown, let reason, let ask = freeText("stuck", stuck: Array(Set(stuck)).sorted(), reason: reason) {
            if shown.isEmpty { shown = [NextSteps(id: "stuck")] }
            shown[shown.count - 1].ask = ask
        }
        return shown
    }

    /// Leave out this change: its text fixes still apply. A change voiced in the takes plan keeps its takes.
    func leaveOutChange(_ ordinal: Int) {
        speechContextProblem = ""; speechContextRefusedOrdinals.removeAll { $0 == ordinal }
        if surroundingSentenceOrdinal == ordinal { surroundingSentenceOrdinal = nil }
        if hasPaidTakes, let plan = takePlan {
            for phrase in plan.phrases where takePhraseOrdinals(phrase).contains(ordinal) { plan.leaveOut(phrase: phrase.id) }
            showProposal()
        } else { review(ordinal, .undo) }
    }

    // MARK: Takes plan failures

    /// The proposal ordinal of hunk `index` of the last takes plan.
    private func planOrdinal(_ index: Int) -> Int? { takePlanOrdinals.indices.contains(index) ? takePlanOrdinals[index] : nil }
    /// A placement refusal of the last plan: the refused phrase, and the earlier one it collides with.
    var planRefusal: (phrase: Int, earlier: Int?)? {
        guard case ClipTakePlan.Failure.placement(let reason, let index)? = takePlanFailure, let phrase = planOrdinal(index) else { return nil }
        if case .collidesWithChange(let earlier) = reason { return (phrase, planOrdinal(earlier)) }
        return (phrase, nil)
    }
    /// A takes plan failure as the panel says it: a collision names both phrases.
    func takePlanCopy(_ error: any Error) -> String {
        if case ClipTakePlan.Failure.placement(.collidesWithChange(let earlier), let index) = error,
           let phrase = planOrdinal(index), let other = planOrdinal(earlier) {
            return "Phrase \(phrase) is too close to phrase \(other) to voice separately."
        }
        return ClipTakePlan.copy(error)
    }
    /// The footer's line while the last plan failed: what needs a fix above, never a price (design.md R2).
    var takePlanBlocker: String? {
        guard let failure = takePlanFailure else { return nil }
        if let refusal = planRefusal { return "Phrase \(refusal.phrase) needs a fix above." }
        if case ClipTakePlan.Failure.noSelection = failure { return "Choose a video duration above to use takes." }
        return "Fix the problem above to go on."
    }

    /// Next steps for every takes failure the panel shows (`ClipTakePlan.copy`): a placement or collision, a stale plan,
    /// a missing duration choice, the spending limit and a spend that can't be checked. Each has at least one chip that
    /// acts now; the free-text field re-asks the refused phrases.
    func planSteps() -> NextSteps? {
        let failure = takePlanFailure ?? takePlan?.failure
        guard let failure, !takesBusy else { return nil }
        let freeChanges = editor.changeReadings.filter { $0.change.isFree && $0.change.state == .pending && !$0.applied }.count
        var chips: [NextStepChip] = []
        var stuck: [Int] = []
        // A plan's own problem already shows in its take rows; a refused or unusable plan shows its line here.
        let line: String? = takePlanFailure == nil ? nil : takePlanCopy(failure)
        if let refusal = planRefusal {
            stuck = [refusal.earlier, refusal.phrase].compactMap { $0 }.sorted()
            // A forced merge is not offered: placement already merges whenever the joined phrase can be placed, so a
            // collision that remains cannot be voiced as one phrase (voice-lab.md §8.4).
            chips.append(chip("keepOriginal", "Keep original words for phrase \(refusal.phrase)") { [weak self] in
                self?.phraseTimingAction(.original, ordinals: [refusal.phrase])
            })
            if freeChanges > 0 { chips.append(chip("keepTextFixes", "Keep text fixes only") { [weak self] in self?.applyFreeChanges() }) }
            if let request = mergeReask() {
                chips.append(NextStepChip(action: PanelAction(id: "mergePhrases", title: request.label) { [weak self] in
                    guard let self else { return }
                    editor.sendRewriteAgain(self, reask: request)
                }, suggested: true))
            }
            chips += suggestionChips(stuck: stuck, reason: .collision).filter { chip in !chips.contains { $0.action.title == chip.action.title } }
        } else {
            switch failure {
            case ClipTakePlan.Failure.noSelection:
                chips.append(chip("reviewTakes", "Choose durations") { [weak self] in
                    guard let self else { return }
                    takeRowsShown = true; showProposal()
                })
            case ClipTakePlan.Failure.spendingCap, ClipTakePlan.Failure.unknownSpend:
                chips.append(chip("voiceLabSettings", "Spending limit…") { openVoxClipSettings(pane: "voiceLab") })
            default: break
            }
            if usableTakeCount > 0, takePlan?.stillCurrent == true {
                chips.append(chip("useTakes", usableTakeCount == 1 ? "Use 1 Take" : "Use \(usableTakeCount) Takes") { [weak self] in self?.useTake() })
            }
            if !hasPaidTakes, !includedVoice.isEmpty {
                chips.append(chip("freshPrice", "Get a fresh price") { [weak self] in self?.makeTakes() })
            }
            if chips.isEmpty {
                chips.append(chip("reviewChanges", "Review Changes") { [weak self] in
                    guard let self else { return }
                    takeRowsShown = false; showProposal()
                })
            }
        }
        return NextSteps(id: "plan", line: line, chips: chips)
    }

    /// Puts the last re-ask's notice and its "Ask again" chip on the first stuck state's chips, or on their own.
    func withReaskNotice(_ steps: [NextSteps]) -> [NextSteps] {
        guard !isReasking, !reasking.notice.isEmpty || reasking.retry != nil else { return steps }
        var steps = steps
        let retry = reasking.retry.map { request in
            chip("askAgain", "Ask again") { [weak self] in
                guard let self else { return }
                editor.sendRewriteAgain(self, reask: request)
            }
        }
        if steps.isEmpty { steps = [NextSteps(id: "reask")] }
        steps[0].line = [reasking.notice.isEmpty ? nil : reasking.notice, steps[0].line].compactMap { $0 }.joined(separator: "\n")
        if let retry { steps[0].chips.insert(retry, at: 0) }
        return steps
    }

    /// R1x's next steps for a failed reply: back to the changes the run replaced, and the free-text field.
    var failureSteps: NextSteps? {
        guard connector != nil else { return nil }
        let back = canRestoreReplaced ? [chip("backToChanges", "Back to the changes") { [weak self] in self?.restoreReplaced() }] : []
        return NextSteps(id: "failure", chips: back, ask: NextStepAsk(id: "failure", placeholder: NextSteps.askPlaceholder) { [weak self] text in
            self?.askInstead(text)
        })
    }
}

/// A stuck state's chips (design.md R2 "Next steps"): what happened, then built-in and ✦ AI chips that wrap at any column
/// width, then "Tell the AI what to do instead…". Return in the field sends it.
@MainActor struct NextStepsCard: View {
    @Bindable var task: DirectorTask
    let steps: NextSteps
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let line = steps.line, !line.isEmpty {
                Text(line).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    .fixedSize(horizontal: false, vertical: true)
                    .columnLayoutEvidence("director.nextSteps.\(steps.id).line", text: line)
            }
            if !steps.chips.isEmpty {
                ExpressionFlow(spacing: 6) {
                    ForEach(steps.chips) { chip in NextStepChipButton(chip: chip) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let ask = steps.ask {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(ask.placeholder, text: $task.nextStepDraft)
                        .textFieldStyle(.plain).font(VCType.callout.font()).focused(focused)
                        .onSubmit { send(ask) }
                        .accessibilityLabel(String(ask.placeholder.dropLast()))
                    if !task.nextStepDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { send(ask) } label: { Image(systemName: "arrow.up.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Send to the AI").help("Send to the AI")
                    }
                }
                .padding(.horizontal, 8).frame(minHeight: 28)
                .background(DesignValues.color("bg.input"), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1))
                .columnLayoutEvidence("director.nextSteps.\(steps.id).ask", text: ask.placeholder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next steps")
        .columnLayoutEvidence("director.nextSteps.\(steps.id)")
    }

    private func send(_ ask: NextStepAsk) {
        let text = task.nextStepDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task.nextStepDraft = ""
        ask.submit(text)
    }
}

/// One chip: a bordered capsule; an AI suggestion starts with ✦ and VoiceOver hears "Suggested by the AI".
@MainActor private struct NextStepChipButton: View {
    let chip: NextStepChip
    var body: some View {
        Button(action: chip.action.perform) {
            Text(chip.suggested ? "✦ " + chip.action.title : chip.action.title)
                .font(VCType.callout.font(.medium)).foregroundStyle(DesignValues.color("text.primary"))
                .lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 4).frame(minHeight: 24)
                .background(DesignValues.color("bg.muted"), in: Capsule())
                .overlay { Capsule().strokeBorder(DesignValues.color(chip.suggested ? "line.strong" : "line.edge"), lineWidth: 1) }
                .contentShape(Capsule())
                .modifier(PanelButtonEvidence(action: chip.action))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.suggested ? "Suggested by the AI: \(chip.action.title)" : chip.action.title)
        .accessibilityIdentifier("voxclip.director.\(chip.action.id)")
        .columnLayoutEvidence("director.chip.\(chip.action.id)", text: chip.action.title)
    }
}
