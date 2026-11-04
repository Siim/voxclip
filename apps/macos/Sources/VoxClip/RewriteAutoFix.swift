import Foundation
import Observation
import VoxClipCore

// Rewrite fixes its own stuck phrases (design.md R2 "Automatic fixes", voice-lab.md §8.2.2). Once the user approves
// Get Price and takes run, every phrase whose takes are stuck is handled phrase by phrase with no click, through the
// paths the chips use: a measured reword for a take that is too long or too short, one more take for a failed check,
// then a scoped reword with easier words. Each phrase gets at most three automatic rounds; after the last its original
// words are kept. Automatic spend is capped at max($0.10, the approved price); the next step past it waits for
// [Keep fixing · ≈ $y]. New takes are added beside the old ones, never in place of a paid one. Stop keeps everything
// made so far and shows the chips.

/// Why a phrase's takes are stuck: what the resolver fixes and what the phrase's one plain sentence says.
enum StuckTakeReason: Equatable {
    /// The closest take is too long (or too short) for its slot even with every duration choice.
    case length(tooLong: Bool, measured: Double, slot: Double, take: UUID, number: Int, selected: Bool)
    /// Every take failed the word check (not a homophone of the asked words: those pass, voice-lab §8.11).
    case words
    /// Every take failed the speaker check.
    case voice
    /// The phrase is too short to check the voice on its own words: it needs its whole sentence.
    case shortSpeech
    /// The provider refused or could not finish the takes (key, credit, permission, rate, network): its cause and
    /// its one fix show; no wording round can help.
    case provider(VoiceLabError)
    /// No word timing even after recovery from the word check and on device (voice-lab §8.5): one more take.
    case timing
    /// Any other failed check, in the take row's own words.
    case other(String)

    /// Only wording and fit failures are fixed by rewording (voice-lab §8.2.2).
    var rewords: Bool {
        switch self {
        case .length, .words: true
        default: false
        }
    }
}

/// The step past the spending cap: what [Keep fixing · ≈ $y] approves.
struct AutoFixCap: Equatable {
    let phrase: Int
    let usd: Decimal?
    /// The step was a take whose quote is ready: Keep fixing makes it.
    var take = false
}

@MainActor @Observable final class RewriteAutoFixState {
    /// Rounds per phrase before its original words are kept.
    static let maximumRounds = 3
    /// The least automatic fixes may spend after an approved price.
    static let minimumAllowance: Decimal = Decimal(string: "0.10")!
    /// The approved Get Price armed the resolver for this plan.
    var armed = false
    /// Stop, or a spending limit, ended it: the chips show.
    var stopped = false
    var stopReason = ""
    /// What automatic fixes may spend: max($0.10, the approved price), raised by Keep fixing.
    var allowance: Decimal = 0
    /// What automatic fixes spent so far: takes, and AI sends billed to a key.
    var spent: Decimal = 0
    var capped: AutoFixCap?
    /// Automatic rounds used, by takes-plan phrase.
    var rounds: [Int: Int] = [:]
    /// Phrases that had their one automatic Try another.
    var triedAnother: Set<Int> = []
    /// The live line of each phrase being fixed.
    var lines: [Int: String] = [:]
    /// Phrases whose rounds ended: their original words are kept.
    var gaveUp: Set<Int> = []
    /// What automatic fixes decided on their own, for the summary: a change voiced on its own words, one left out.
    var notes: [String] = []
    /// "Choose yourself…" was opened: the chips show while fixes run.
    var showChoices = false
    /// Re-asks already retried once after a failure or a stale reply.
    var retried: Set<String> = []
    /// Collisions already sent to the AI as one sentence.
    var merged: Set<String> = []
    /// Expressions chosen while a request ran, by takes-plan phrase: shown at once, applied when it ends.
    var pendingExpressions: [Int: [VoiceLabAudioTag]] = [:]
    var expressionNote: [Int: String] = [:]
    /// Wordings the AI suggested that were not used (a repeat, or not moving toward the slot), by takes-plan phrase:
    /// the next round is told about them with the wordings that were voiced.
    var refused: [Int: [VoiceLabFitTried]] = [:]
    @ObservationIgnored var applyingExpression = false
    @ObservationIgnored var token = UUID()
    @ObservationIgnored var work: Task<Void, Never>?
    @ObservationIgnored weak var plan: ClipTakePlan?
    /// Fixing without a click right now.
    var running: Bool { armed && !stopped && capped == nil }
    /// The chips show: after Stop, at the cap, or once asked for.
    var choicesShown: Bool { !running || showChoices }

    func reset() {
        token = UUID(); work?.cancel(); work = nil; plan = nil
        armed = false; stopped = false; stopReason = ""; allowance = 0; spent = 0; capped = nil
        rounds = [:]; triedAnother = []; lines = [:]; gaveUp = []; notes = []; showChoices = false
        pendingExpressions = [:]; expressionNote = [:]; applyingExpression = false; refused = [:]
    }
}

extension RewriteSession.PreparedSend {
    /// The send's price, as its quote has it.
    var estimate: CostEstimate {
        switch self {
        case .passage(_, let quote, _): quote.estimate
        case .scope(_, let quote, _): quote.estimate
        }
    }
}

extension RewriteSession {
    static let clearerInstruction = "Avoid words that are hard to say or hear; keep the meaning."
    static let withinSentenceInstruction = "Rewrite this change without changing any words outside it."

    // MARK: Arming and the cap

    /// What automatic fixes may spend after this price: max($0.10, the price).
    static func autoFixAllowance(_ estimate: CostEstimate?) -> Decimal {
        max(RewriteAutoFixState.minimumAllowance, estimate?.usd ?? 0)
    }
    static func dollars(_ usd: Decimal) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), NSDecimalNumber(decimal: usd).doubleValue)
    }
    /// The line under Get Price's priced button (design.md R2): what the approval also covers.
    var autoFixAllowanceLine: String? {
        guard let plan = takePlan, takeQuotePhrase == nil, plan.approvalID != nil else { return nil }
        return "Automatic fixes may spend up to \(Self.dollars(Self.autoFixAllowance(plan.estimate))) more."
    }
    /// The approved Get Price: stuck phrases of `plan` are fixed from now on.
    func armAutoFix(_ plan: ClipTakePlan) {
        autoFix.reset()
        autoFix.armed = true; autoFix.plan = plan
        autoFix.allowance = Self.autoFixAllowance(plan.estimate)
        plan.keepsEveryTake = true
    }
    /// Counts `usd` against the allowance. Past it, the step waits for Keep fixing and its round is given back.
    func autoFixCharge(_ usd: Decimal?, phrase: Int) -> Bool {
        guard let usd, autoFix.spent + usd <= autoFix.allowance else {
            autoFix.capped = AutoFixCap(phrase: phrase, usd: usd)
            autoFix.rounds[phrase] = max(0, autoFix.rounds[phrase, default: 1] - 1)
            autoFix.lines = [:]
            return false
        }
        autoFix.spent += usd
        return true
    }
    /// An AI send billed to a key counts against the cap; a subscription or local AI costs nothing extra.
    func autoFixChargeSend(_ estimate: CostEstimate, phrase: Int) -> Bool {
        sendAsksFirst ? autoFixCharge(estimate.usd, phrase: phrase) : true
    }
    /// [Keep fixing · ≈ $y]: approves the next step and goes on.
    func keepFixing() {
        guard let cap = autoFix.capped else { return }
        autoFix.allowance = autoFix.spent + max(cap.usd ?? 0, RewriteAutoFixState.minimumAllowance)
        autoFix.capped = nil
        if cap.take, let plan = takePlan, plan.approvalID != nil, takeQuotePhrase == cap.phrase {
            autoFix.rounds[cap.phrase, default: 0] += 1
            runAutoStep(cap.phrase, line: "Fixing phrase \(cap.phrase + 1): making a take…") { [weak self] plan in
                await self?.startAutomaticTakes(plan, phrase: cap.phrase)
            }
            return
        }
        advanceAutoFix()
    }
    /// Stop: keeps everything made so far; the chips show.
    func stopAutoFix(reason: String = "") {
        guard autoFix.armed, !autoFix.stopped else { return }
        autoFix.stopped = true; autoFix.stopReason = reason
        autoFix.token = UUID(); autoFix.work?.cancel(); autoFix.work = nil
        autoFix.lines = [:]
        stopWordingFit(refresh: false)
        if takesBusy, let plan = takePlan { takesTask = Task { await plan.stop() } }
        if isOpen, case .proposal = task.state { showProposal() }
    }

    // MARK: Why a phrase is stuck

    func stuckReason(_ phrase: ClipTakePlan.Phrase, plan: ClipTakePlan) -> StuckTakeReason? {
        guard !phrase.leftOut, !phrase.takes.isEmpty else { return nil }
        if case .generating = phrase.status { return nil }
        guard !phrase.takes.contains(where: { $0.row.voiceCheck == .waiting }) else { return nil }
        let current = phrase.takes.filter { !phrase.beforeExpression.contains($0.id) }
        guard !current.isEmpty else { return nil }
        let slot = phrase.originalLength
        if let selected = phrase.selected, selected.row.selectable {
            guard takeNeedsWordingRecovery(phrase, plan: plan), let length = selected.length else { return nil }
            return .length(tooLong: length > slot, measured: length, slot: slot, take: selected.id, number: selected.number, selected: true)
        }
        // A passing take not chosen yet (a join to listen to first) is the user's pick, not a stuck phrase.
        if current.contains(where: { $0.row.selectable }) { return nil }
        if let closest = current.filter({ $0.length != nil }).min(by: { abs($0.length! - slot) < abs($1.length! - slot) }),
           let length = closest.length {
            if !plan.lengthFits(take: closest) {
                return .length(tooLong: length > slot, measured: length, slot: slot, take: closest.id, number: closest.number, selected: false)
            }
        }
        let providerFailures = current.compactMap { take -> VoiceLabError? in
            if case .provider(let error) = take.row.failure, Self.isAccountFailure(error) { return error }
            return nil
        }
        if providerFailures.count == current.count, let error = providerFailures.last { return .provider(error) }
        if current.allSatisfy({ take in
            take.length == nil && (take.row.failure == .invalidAlignment || take.row.failure == .provider(.invalidAlignment))
        }) { return .timing }
        let failures = current.flatMap { take -> [VoiceLabTakeQAFailure] in
            if case .qa(let failed) = take.row.failure { return failed }
            return take.row.qa?.hardFailures ?? []
        }
        if failures.contains(.insufficientGeneratedSpeech) || current.contains(where: { $0.row.voiceCheck.evidence?.mode == .unmeasured }) {
            return .shortSpeech
        }
        if failures.contains(.transcript) { return .words }
        if failures.contains(.speaker) { return .voice }
        return .other(current.last.flatMap { TakeFailurePresentation.reason(for: $0.row) } ?? "Its takes did not pass the checks.")
    }

    /// A takes-plan phrase the estimate holds back ("Change N needs a shorter wording before takes") with no take that
    /// fits yet: the resolver rewords it from its closest measured take and makes a take of the new wording, with no
    /// click, as for a take too long. A phrase with a passing take that fits is voiced and never held back.
    func estimateBlockedReason(_ phrase: ClipTakePlan.Phrase, blocked: Set<Int>) -> StuckTakeReason? {
        guard !phrase.leftOut, !blocked.isDisjoint(with: takePhraseOrdinals(phrase)) else { return nil }
        if case .generating = phrase.status { return nil }
        guard !phrase.takes.contains(where: { $0.row.voiceCheck == .waiting }) else { return nil }
        let slot = phrase.originalLength
        let measured = phrase.takes.filter { $0.length != nil && !phrase.beforeExpression.contains($0.id) }
        guard let take = phrase.selected ?? measured.min(by: { abs($0.length! - slot) < abs($1.length! - slot) }),
              let length = take.length else { return nil }
        let tooLong = takePhraseOrdinals(phrase).compactMap { voiceReview($0)?.timing?.tooLong }.first ?? (length > slot)
        return .length(tooLong: tooLong, measured: length, slot: slot, take: take.id, number: take.number,
                       selected: phrase.selectedID == take.id)
    }

    /// Provider failures no wording round can fix (voice-lab §8.2.2): each has one fix (`ClipTakePlan.nextStep`).
    static func isAccountFailure(_ error: VoiceLabError) -> Bool {
        switch error {
        case .quotaExceeded, .unauthorized, .missingKey, .permissionMissing, .rateLimited, .network, .providerFailure,
             .subscriptionRequired, .featureUnavailable, .voiceAccessDenied, .modelAccessDenied: true
        default: false
        }
    }
    /// The phrase's one plain sentence for `reason` (design.md R2): what went wrong, never a list of checks.
    static func stuckSentence(_ reason: StuckTakeReason, phrase: Int) -> String {
        func seconds(_ value: Double) -> String { String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), value) }
        switch reason {
        case .length(let tooLong, let measured, let slot, _, let number, let selected):
            let subject = selected ? "Take \(number)" : "Its closest take"
            return "Phrase \(phrase): \(subject) runs \(seconds(measured)) for a \(seconds(slot)) slot, too \(tooLong ? "long" : "short") to fit."
        case .words: return "Phrase \(phrase): the word check heard different words in every take."
        case .voice: return "Phrase \(phrase): no take sounded enough like your voice."
        case .shortSpeech: return "Phrase \(phrase): too short to check your voice on its own words."
        case .provider(let error):
            let fix = ClipTakePlan.nextStep(.provider(error)).map { " " + $0 } ?? ""
            return "Phrase \(phrase): \(TakeFailurePresentation.reason(for: .provider(error)))\(fix)"
        case .timing: return "Phrase \(phrase): its take's word timing couldn't be read, even from the word check."
        case .other(let reason): return "Phrase \(phrase): \(reason)"
        }
    }

    // MARK: The resolver

    /// Takes the next automatic step, if one is due: one phrase, one step at a time. Called whenever the takes settle.
    func advanceAutoFix() {
        guard let plan = takePlan, plan === autoFix.plan else { return }
        applyPendingExpressions(plan)
        guard autoFix.running, current, plan.stillCurrent, !takesBusy, !wordingIsLocked, !isReasking,
              autoFix.work == nil, wordingFit.measuredWork == nil, task.confirm == nil else { return }
        switch plan.failure {
        case ClipTakePlan.Failure.spendingCap?, ClipTakePlan.Failure.unknownSpend?:
            stopAutoFix(reason: plan.problem)
            return
        default: break
        }
        let blocked = Set(blockedVoiceOrdinals)
        for phrase in plan.phrases {
            guard let reason = stuckReason(phrase, plan: plan) ?? estimateBlockedReason(phrase, blocked: blocked) else {
                autoFix.lines[phrase.id] = nil; continue
            }
            // A provider failure shows its cause and its one fix; a round of new words can't help it.
            if case .provider = reason { autoFix.lines[phrase.id] = nil; autoFix.showChoices = true; continue }
            let used = autoFix.rounds[phrase.id, default: 0]
            guard used < RewriteAutoFixState.maximumRounds else { giveUp(phrase.id, plan: plan); continue }
            if case .timing = reason, autoFix.triedAnother.contains(phrase.id) { giveUp(phrase.id, plan: plan); continue }
            autoFix.rounds[phrase.id] = used + 1
            let number = phrase.id + 1
            switch reason {
            case .length(let tooLong, let measured, _, let take, let takeNumber, let selected):
                runAutoStep(phrase.id, line: "Fixing phrase \(number): asking \(aiName) for a \(tooLong ? "shorter" : "longer") wording…") { [weak self] plan in
                    await self?.rewordForLength(plan, phrase: phrase.id, take: take, number: takeNumber, measured: measured,
                        tooLong: tooLong, selected: selected)
                }
            case .shortSpeech where canReviewSpeechContext(phrase: phrase):
                runAutoStep(phrase.id, line: "Fixing phrase \(number): voicing its whole sentence…") { [weak self] plan in
                    await self?.widenToSentence(plan, phrase: phrase.id)
                }
            case .words where autoFix.triedAnother.contains(phrase.id):
                runAutoStep(phrase.id, line: "Fixing phrase \(number): asking \(aiName) for words that are easier to say…") { [weak self] plan in
                    await self?.rewordClearer(plan, phrase: phrase.id)
                }
            default:
                autoFix.triedAnother.insert(phrase.id)
                runAutoStep(phrase.id, line: "Fixing phrase \(number): trying another take…") { [weak self] plan in
                    guard let self else { return }
                    takeQuotePhrase = phrase.id
                    await plan.prepareAnother(phrase: phrase.id)
                    await startAutomaticTakes(plan, phrase: phrase.id)
                }
            }
            return
        }
        if isOpen, case .proposal = task.state { showProposal() }
    }

    private func runAutoStep(_ phrase: Int, line: String, _ body: @escaping @MainActor (ClipTakePlan) async -> Void) {
        guard let plan = takePlan else { return }
        autoFix.lines = [phrase: line]
        editor.announce(line)
        let token = autoFix.token
        autoFix.work = Task { [weak self, weak plan] in
            guard let self, let plan else { return }
            await body(plan)
            guard autoFix.token == token else { return }
            autoFix.work = nil
            autoFix.lines[phrase] = nil
            advanceAutoFix()
            if isOpen, case .proposal = task.state { showProposal() }
        }
        if isOpen, case .proposal = task.state { showProposal() }
    }

    /// Makes the take of the quote a step prepared, within the cap.
    func startAutomaticTakes(_ plan: ClipTakePlan, phrase: Int) async {
        guard current, takePlan === plan, plan.stillCurrent, !takesBusy, let quoteID = plan.approvalID, takeQuotePhrase == phrase else { return }
        let usd: Decimal? = if case .confirm? = plan.cost { nil } else { plan.estimate?.usd }
        guard autoFixCharge(usd, phrase: phrase) else { autoFix.capped?.take = true; return }
        autoFix.lines[phrase] = "Fixing phrase \(phrase + 1): making a take…"
        wordingFit.measured = nil
        await plan.tryAnother(phrase: phrase, approved: true, quoteID: quoteID)
    }

    /// A take too long or too short: one measured reword from that take, then a take of the new wording.
    private func rewordForLength(_ plan: ClipTakePlan, phrase: Int, take: UUID, number: Int, measured: Double, tooLong: Bool, selected: Bool) async {
        guard connector != nil, plan.phrases.indices.contains(phrase) else { return }
        wordingFit.token = UUID()
        wordingFit.measured = MeasuredWordingSuggestion(phrase: phrase, take: take, number: number, measuredSeconds: measured,
            slotSeconds: plan.phrases[phrase].originalLength, tooLong: tooLong, unselected: !selected)
        await rewordMeasuredTake(plan, approved: true, automatic: true)
        guard let suggestion = wordingFit.measured else { return }
        if suggestion.keepOriginal { giveUp(phrase, plan: plan); return }
        guard suggestion.text != nil, suggestion.problem.isEmpty else { return }
        autoFix.lines[phrase] = "Fixing phrase \(phrase + 1): making a take of the new wording…"
        await startAutomaticTakes(plan, phrase: phrase)
    }

    /// Takes that failed the word check twice: the AI rewords this phrase alone with easier words, kept in the takes
    /// plan (like a measured reword) so no other phrase's takes change, then a take of it is made.
    private func rewordClearer(_ plan: ClipTakePlan, phrase id: Int) async {
        guard let connector, let shared = editor.app.shared, plan.phrases.indices.contains(id) else { return }
        let phrase = plan.phrases[id]
        guard phrase.indices.count == 1, let ordinal = takePhraseOrdinals(phrase).first, changes.indices.contains(ordinal - 1) else { return }
        let tried = triedWordings(phrase, plan: plan)
        let history = (try? VoiceLabFitTried.block(tried, shared: shared)?.text).flatMap { $0 } ?? ""
        let request = RewriteReask(label: "Easier words", instruction: Self.clearerInstruction + (history.isEmpty ? "" : "\n" + history),
                                   ordinals: [ordinal], reason: .take)
        do {
            let feedback = try reaskFeedback(request, shared: shared)
            let prepared = try await prepareSend(connector, feedback: feedback)
            guard current, takePlan === plan, autoFixChargeSend(prepared.estimate, phrase: id) else { return }
            guard await confirmSend(), current, takePlan === plan else { return }
            guard let lease = editor.llmRuns.acquire() else { return }
            defer { editor.llmRuns.release(lease) }
            let expected = revision
            guard let (checked, _) = try await reply(prepared, connector: connector, accept: { [unowned self] in
                current && revision == expected && !Task.isCancelled
            }) else { return }
            let outcomes = RewriteScopedReply.assign(current: changes.map(\.hunk), asked: [ordinal - 1], reply: checked.changes.map(\.hunk))
            switch outcomes[ordinal - 1] {
            case .replace(let found)?:
                let hunk = checked.changes[found].hunk
                guard hunk.sourceWordIds == changes[ordinal - 1].hunk.sourceWordIds else { return }
                let texts = Dictionary(Self.corrected(try editor.voiceLabReviewProject(localCommands: localCommands)).map { ($0.id, $0.text) },
                                       uniquingKeysWith: { first, _ in first })
                let text = (phrase.window.leftBridgeWordIds.compactMap { texts[$0] } + hunk.newTokens +
                    phrase.window.rightBridgeWordIds.compactMap { texts[$0] }).joined(separator: " ")
                guard !text.utf8.elementsEqual(phrase.text.utf8) else { return }
                // A wording already tried is never voiced again: the next round hears that it repeated.
                guard !tried.contains(where: { VoiceLabFitTried.key($0.text) == VoiceLabFitTried.key(text) }) else {
                    autoFix.refused[id, default: []].append(VoiceLabFitTried(text: text, result: "repeat"))
                    return
                }
                takeQuotePhrase = id
                await plan.prepareRewording(text, phrase: id)
                autoFix.lines[id] = "Fixing phrase \(id + 1): making a take of the new wording…"
                await startAutomaticTakes(plan, phrase: id)
            case .keepOriginal?: giveUp(id, plan: plan)
            default: return
            }
        } catch { return }
    }

    /// A phrase too short to check on its own: its whole sentence is voiced instead, when it fits the clip.
    private func widenToSentence(_ plan: ClipTakePlan, phrase: Int) async {
        reviewSpeechContext(phrase: phrase)
        guard speechContextReview != nil else { return }
        await acceptSpeechContextReview()
        guard takePlan === plan, takeQuotePhrase == phrase, plan.approvalID != nil else { return }
        autoFix.notes.append("Phrase \(phrase + 1) is voiced as its whole sentence, so your voice can be checked.")
        await startAutomaticTakes(plan, phrase: phrase)
    }

    /// The rounds ended: the phrase keeps its original words; its takes stay listed and its text fixes still apply.
    private func giveUp(_ phrase: Int, plan: ClipTakePlan) {
        guard !autoFix.gaveUp.contains(phrase) else { return }
        plan.leaveOut(phrase: phrase)
        autoFix.gaveUp.insert(phrase); autoFix.lines[phrase] = nil
        editor.announce("Phrase \(phrase + 1) kept your original audio after \(autoFix.rounds[phrase, default: RewriteAutoFixState.maximumRounds]) tries.")
    }

    /// Keep original words for one takes-plan phrase: no take of it is used, every take stays (never a discard).
    func keepOriginal(phrase: Int) {
        guard let plan = takePlan, !takesBusy else { return }
        plan.leaveOut(phrase: phrase)
        autoFix.lines[phrase] = nil
        showProposal()
    }
    /// Undo of Keep original words or of the resolver's fallback: the phrase's best passing take is used again.
    func undoKeepOriginal(phrase: Int) {
        guard let plan = takePlan else { return }
        autoFix.gaveUp.remove(phrase)
        plan.restore(phrase: phrase)
        showProposal()
    }

    // MARK: What the loop already tried

    /// The wordings this phrase already had, oldest first, each with its latest measured result, then the AI's
    /// wordings that were not used. One entry per variant (`VoiceLabFitTried.key`).
    func triedWordings(_ phrase: ClipTakePlan.Phrase, plan: ClipTakePlan) -> [VoiceLabFitTried] {
        var result: [VoiceLabFitTried] = []
        func add(_ row: VoiceLabFitTried) {
            let key = VoiceLabFitTried.key(row.text)
            guard !key.isEmpty else { return }
            if let index = result.firstIndex(where: { VoiceLabFitTried.key($0.text) == key }) { result[index] = row } else { result.append(row) }
        }
        for take in phrase.takes {
            guard let text = plan.measuredInput(take: take.id)?.text else { continue }
            let failed: [VoiceLabTakeQAFailure] = if case .qa(let list) = take.row.failure { list } else { take.row.qa?.hardFailures ?? [] }
            if failed.contains(.transcript) { add(VoiceLabFitTried(text: text, result: "words")); continue }
            guard let length = take.length else { add(VoiceLabFitTried(text: text, result: "unchecked")); continue }
            let difference = length - phrase.originalLength
            if plan.lengthFits(take: take) { add(VoiceLabFitTried(text: text, result: "fit")) }
            else { add(VoiceLabFitTried(text: text, result: difference > 0 ? "tooLong" : "tooShort", seconds: abs(difference))) }
        }
        for row in autoFix.refused[phrase.id] ?? [] { add(row) }
        return result
    }

    /// "Round k of 3 · tried: …" under a phrase the loop rewords (voice-lab §8.2.2), so its learning is visible.
    func autoFixHistoryLine(_ phrase: ClipTakePlan.Phrase, plan: ClipTakePlan) -> String? {
        guard autoFix.armed, let round = autoFix.rounds[phrase.id], round > 0 else { return nil }
        let tried = triedWordings(phrase, plan: plan)
        guard !tried.isEmpty else { return nil }
        func seconds(_ value: Double?) -> String { String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), value ?? 0) }
        let items = tried.suffix(4).map { row -> String in
            let result = switch row.result {
            case "tooLong": "\(seconds(row.seconds)) long"
            case "tooShort": "\(seconds(row.seconds)) short"
            case "words": "words misheard"
            case "fit": "fits"
            case "repeat": "repeat, not used"
            case "notShorter": "not shorter, not used"
            case "notLonger": "not longer, not used"
            default: "not checked"
            }
            return "“\(row.text)” (\(result))"
        }
        return "Round \(min(round, RewriteAutoFixState.maximumRounds)) of \(RewriteAutoFixState.maximumRounds) · tried: " + items.joined(separator: ", ")
    }

    // MARK: Before takes: refusals, collisions, failed re-asks

    /// A refused surrounding sentence, handled without a click (design.md R2): voice just the changed words when that
    /// window is valid; otherwise ask the AI to rewrite inside the change; otherwise leave the change out, text fixes kept.
    func resolveRefusedContext() {
        guard !autoFix.stopped, !speechContextProblem.isEmpty else { return }
        let refused = speechContextRefusedOrdinals.filter(reviewedVoiceOrdinals.contains)
        guard !refused.isEmpty else { return }
        let plain = refused.filter { voiceReview($0)?.window != nil && voiceReview($0)?.refusal == nil }
        if !hasPaidTakes, plain.count == refused.count {
            surroundingSentenceOrdinal = nil
            pricedAnyway.formUnion(refused)
            speechContextProblem = ""; speechContextRefusedOrdinals = []
            autoFix.notes.append("\(Self.changeNames(refused)) \(refused.count == 1 ? "is" : "are") voiced on \(refused.count == 1 ? "its" : "their") own words: the whole sentence doesn't fit this clip.")
            showProposal()
            return
        }
        let key = "context:" + refused.map(String.init).joined(separator: ",")
        if !hasPaidTakes, connector != nil, !autoFix.merged.contains(key) {
            autoFix.merged.insert(key)
            editor.sendRewriteAgain(self, reask: RewriteReask(label: "Rewrite inside the change", instruction: Self.withinSentenceInstruction,
                ordinals: refused, reason: .context))
            return
        }
        for ordinal in refused {
            if let plan = takePlan, let phrase = plan.phrases.first(where: { takePhraseOrdinals($0).contains(ordinal) }) {
                plan.leaveOut(phrase: phrase.id)
            } else if !hasPaidTakes { review(ordinal, .undo) }
        }
        speechContextProblem = ""; speechContextRefusedOrdinals = []; surroundingSentenceOrdinal = nil
        autoFix.notes.append("\(Self.changeNames(refused)) left out: the whole sentence doesn't fit this clip. Text fixes still apply.")
        showProposal()
    }
    static func changeNames(_ ordinals: [Int]) -> String {
        let names = ordinals.sorted().map(String.init)
        guard let last = names.last else { return "" }
        return names.count == 1 ? "Change \(last)" : "Changes \(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// A takes plan refused for a collision: the two phrases go to the AI once as one sentence.
    func resolveCollision() {
        guard !autoFix.stopped, !hasPaidTakes, let request = mergeReask() else { return }
        let key = "merge:" + request.ordinals.map(String.init).joined(separator: ",")
        guard !autoFix.merged.contains(key) else { return }
        autoFix.merged.insert(key)
        editor.sendRewriteAgain(self, reask: request)
    }

    /// A re-ask that failed or came back stale is sent once more on its own.
    func retryReaskOnce(_ request: RewriteReask) {
        guard !autoFix.stopped, autoFix.retried.insert(request.label + "\u{1F}" + request.instruction).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self, isOpen, !isReasking else { return }
            editor.sendRewriteAgain(self, reask: request)
        }
    }

    // MARK: Expressions

    /// An expression on a takes-panel phrase (design.md R2 "Expressions"): that phrase alone. With a takes plan the tag
    /// goes into the plan's phrase, its takes stay listed as "Before expression", and a fresh quote is prepared for it;
    /// the resolver makes its take within the cap. While a request runs the tag shows at once and is applied after.
    func updateAudioTags(_ tags: [VoiceLabAudioTag], phrase: ClipTakePlan.Phrase) {
        guard let plan = takePlan, !plan.isRetired, plan.phrases.indices.contains(phrase.id) else {
            updateAudioTagsWithoutPlan(tags, phrase: phrase)
            return
        }
        let validated = VoiceLabAudioTags.validated(tags, text: phrase.text)
        autoFix.pendingExpressions[phrase.id] = validated
        if expressionBlocker(plan, phrase: phrase.id) != nil {
            autoFix.expressionNote[phrase.id] = expressionBlocker(plan, phrase: phrase.id)
            showProposal()
            return
        }
        applyPendingExpressions(plan)
    }
    /// Why an expression can't go in now; nil when it can.
    private func expressionBlocker(_ plan: ClipTakePlan, phrase: Int) -> String? {
        if isProposing || isReasking { return "The expression is added when \(aiName) answers." }
        if wordingIsLocked { return "The expression is added when the wording fit ends." }
        if takesBusy { return "The expression is added when the current takes finish." }
        if plan.lipsync.blocksMutation(phrase) { return "The expression is added when lip sync finishes." }
        return nil
    }
    /// Applies expressions chosen while something ran, one phrase at a time, once nothing runs.
    func applyPendingExpressions(_ plan: ClipTakePlan) {
        guard let (phrase, tags) = autoFix.pendingExpressions.min(by: { $0.key < $1.key }) else { return }
        guard takePlan === plan, plan.phrases.indices.contains(phrase) else { autoFix.pendingExpressions = [:]; return }
        guard !autoFix.applyingExpression else { return }
        if let blocker = expressionBlocker(plan, phrase: phrase) { autoFix.expressionNote[phrase] = blocker; return }
        autoFix.expressionNote[phrase] = nil
        guard tags != plan.phrases[phrase].audioTags else { autoFix.pendingExpressions[phrase] = nil; return }
        let hadTakes = !plan.phrases[phrase].takes.isEmpty
        // Before any take the whole set is priced again; after, only this phrase.
        takeQuotePhrase = plan.spent.units > 0 ? phrase : nil
        autoFix.applyingExpression = true
        takesTask = Task { [weak self, weak plan] in
            guard let self, let plan else { return }
            await plan.prepareExpression(tags, phrase: phrase)
            // The quote shows the tag from the click on: the pending tags give way to the phrase's own only now.
            autoFix.applyingExpression = false
            if plan.phrases.indices.contains(phrase), plan.phrases[phrase].audioTags == tags { autoFix.pendingExpressions[phrase] = nil }
            else { autoFix.expressionNote[phrase] = "The expression couldn't be added yet. It is added when the takes are free." }
            guard takePlan === plan else { return }
            // Takes already ran: the resolver makes this phrase's new take within the cap (one round).
            if hadTakes, autoFix.running, plan === autoFix.plan {
                autoFix.lines[phrase] = "Fixing phrase \(phrase + 1): making a take with the expression…"
                await startAutomaticTakes(plan, phrase: phrase)
                autoFix.lines[phrase] = nil
            }
            showProposal()
        }
        showProposal()
    }
    /// The tags a phrase card shows: a pending expression at once, else the phrase's own.
    func shownAudioTags(_ phrase: ClipTakePlan.Phrase) -> [VoiceLabAudioTag] {
        autoFix.pendingExpressions[phrase.id] ?? phrase.audioTags
    }
}
