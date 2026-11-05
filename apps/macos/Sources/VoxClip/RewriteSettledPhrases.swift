import SwiftUI
import VoxClipCore
import VoxClipMedia

// Phrases settled for this Rewrite (design.md R2 "Not your voice here"): the use-time guard refused a phrase's speech
// (voice-lab §6.9) and no retry can change that. Its row says the stop once with [● Say it myself] [Keep as recorded],
// the footer's count and next step cover only the phrases that can be voiced, and no priced control is offered for it
// again, in this plan or a later one of the same Rewrite. ✦ Make it postable and ✦ Claude does it all keep it as recorded
// on their own (MakeItRewriteDriver).

extension RewriteSession {
    /// Called by a plan when the guard settles one of its phrases: its changes stay settled in a later plan of this Rewrite.
    func rememberBlocked(phrase index: Int, reason: String, plan: ClipTakePlan) {
        guard plan.phrases.indices.contains(index) else { return }
        for ordinal in takePhraseOrdinals(plan.phrases[index]) { guardBlocked[ordinal] = reason }
        showProposal()
    }
    /// A new plan's phrases whose changes the guard already settled in this Rewrite: blocked before anything is priced.
    func applyRememberedBlocks(to plan: ClipTakePlan) {
        for phrase in plan.phrases {
            guard let reason = takePhraseOrdinals(phrase).lazy.compactMap({ self.guardBlocked[$0] }).first else { continue }
            plan.block(phrase: phrase.id, reason: reason)
        }
    }
    /// The voice changes a price covers: those included, less the ones the guard settled.
    var priceableVoiceCount: Int { includedVoice.filter { guardBlocked[$0] == nil }.count }

    /// A blocked phrase with neither a take of the user's own nor Keep as recorded yet.
    static func waitsOnBlock(_ phrase: ClipTakePlan.Phrase) -> Bool { phrase.blocked != nil && !phrase.leftOut && phrase.selected == nil }

    /// Every phrase of the plan is blocked and none has a take of its own: the stop is said once, at the top.
    func everyPhraseBlocked(_ plan: ClipTakePlan) -> Bool {
        !plan.phrases.isEmpty && plan.phrases.allSatisfy(Self.waitsOnBlock)
    }

    /// The top-of-Rewrite card when the guard blocked every phrase: the stop once, with the rows' two actions.
    func everyPhraseBlockedSteps(_ plan: ClipTakePlan) -> NextSteps? {
        guard everyPhraseBlocked(plan), let first = plan.phrases.first, let reason = first.blocked else { return nil }
        let count = plan.phrases.count
        let line = reason + (count == 1 ? "" : " This holds for all \(count) phrases.")
        return NextSteps(id: "guardBlocked", line: line, chips: [
            chip("guardSayItMyself", PhraseWording.microphone.title) { [weak self] in self?.chooseWording(.microphone, phrase: first.id) },
            chip("guardKeepAll", count == 1 ? "Keep as recorded" : "Keep all as recorded") { [weak self] in self?.keepBlockedAsRecorded() },
        ])
    }

    /// Keep as recorded for every blocked phrase still waiting: no take of it is used, nothing is sent.
    func keepBlockedAsRecorded() {
        guard let plan = takePlan, !takesBusy else { return }
        for phrase in plan.phrases where Self.waitsOnBlock(phrase) { plan.leaveOut(phrase: phrase.id) }
        showProposal()
    }

    /// The footer once nothing is left to price: every phrase is blocked or kept as recorded. Its one primary finishes
    /// the Rewrite: it keeps the blocked phrases as recorded and applies the text fixes, or ends with the words as
    /// recorded. No priced control.
    func settledFooter(_ plan: ClipTakePlan) -> PanelFooter {
        let waiting = plan.phrases.filter(Self.waitsOnBlock).map(\.id)
        var note = "Your original audio is kept."
        if !waiting.isEmpty {
            let names = ClipTakePlan.phraseList(waiting.map { $0 + 1 })
            note = names.prefix(1).uppercased() + names.dropFirst() + (waiting.count == 1 ? " keeps its" : " keep their") + " original audio. Nothing was sent."
        }
        return finishingFooter(note: note, keeping: waiting, plan: plan)
    }

    /// A price that failed on the source itself, which can't be read as the project says (`rangeOutsideMedia`, no audio
    /// track, an unsupported rate or format): Get Price would fail the same way, so it is not offered again. A source
    /// that can't be opened right now (`unreadable`) can be retried once the file is back.
    static func settlesPlan(_ error: (any Error)?) -> Bool {
        guard let error = error as? VoiceLabSourceAudioError else { return false }
        switch error {
        case .unreadable, .altered: return false
        case .unsupportedRate, .rateMismatch, .rangeOutsideMedia, .tooShort, .tooLong, .tooLarge, .noAudioTrack, .unsupportedFormat, .invalidAudio:
            return true
        }
    }
    /// The footer after such a failure, before anything was sent: the problem once, and the step that finishes the
    /// Rewrite with every phrase as recorded.
    func settledSourceFooter(_ plan: ClipTakePlan, keepAll: PanelAction?) -> PanelFooter? {
        guard Self.settlesPlan(plan.failure), plan.spent.units == 0, !plan.preparing, !plan.generating else { return nil }
        let keeping = plan.phrases.filter { !$0.leftOut && $0.selected == nil }.map(\.id)
        return finishingFooter(note: plan.problem + " Nothing was sent; your original audio is kept.", keeping: keeping, plan: plan)
    }

    /// Keeps `keeping` as recorded, then applies the text fixes, or ends the Rewrite with the words as recorded.
    private func finishingFooter(note: String, keeping: [Int], plan: ClipTakePlan) -> PanelFooter {
        let fixes = editor.changeReadings.filter { $0.change.isFree && $0.change.state == .pending && !$0.applied }.count
        let line = note + (plan.spent.units > 0 ? "\n" + takeSpendLine : "")
        let finish: @MainActor () -> Void = { [weak plan] in
            guard let plan else { return }
            for index in keeping { plan.leaveOut(phrase: index) }
        }
        if fixes > 0 {
            let title = fixes == 1 ? "Apply 1 text fix" : "Apply \(fixes) text fixes"
            return PanelFooter(note: line, primary: PanelAction(id: "apply", title: title) { [weak self] in
                guard let self else { return }
                finish()
                applyingTextFixesOnly = true
                defer { applyingTextFixesOnly = false }
                applyFreeChanges()
            })
        }
        return PanelFooter(note: line, primary: PanelAction(id: "closeRewrite", title: "Done") { [weak self] in
            finish()
            self?.editor.closeRewrite()
        })
    }

    /// A blocked phrase's status line: the stop, once; a short line when the card at the top already says it.
    func blockedStatus(_ phrase: ClipTakePlan.Phrase, plan: ClipTakePlan) -> String? {
        guard Self.waitsOnBlock(phrase), let reason = phrase.blocked else { return nil }
        return everyPhraseBlocked(plan) ? "Not voiced. Nothing sent." : reason
    }

    /// Beside Use: what it does with the blocked phrases still waiting.
    func blockedUseLine(_ plan: ClipTakePlan) -> String? {
        let waiting = plan.phrases.filter(Self.waitsOnBlock).map { $0.id + 1 }
        guard !waiting.isEmpty else { return nil }
        let names = ClipTakePlan.phraseList(waiting)
        return "Use keeps \(names)'s original audio."
    }
}

/// A blocked phrase's two actions, under its status line (`RewriteSession.phraseStatus`, which says the stop once), and
/// its recorder once Say it myself is chosen. A take of the user's own needs no clone, so the guard does not apply to it.
@MainActor struct BlockedPhraseRow: View {
    @Bindable var session: RewriteSession
    @Bindable var plan: ClipTakePlan
    let phrase: ClipTakePlan.Phrase
    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            if !session.takesBusy, RewriteSession.waitsOnBlock(phrase) {
                HStack(spacing: VCTokens.spacing3) {
                    Button(PhraseWording.microphone.title) { session.chooseWording(.microphone, phrase: phrase.id) }
                        .buttonStyle(.plain).help("Record this phrase yourself. Your own recording needs no clone and is checked on this Mac.")
                        .modifier(PanelButtonEvidence(id: "blocked.sayItMyself.\(phrase.id)", title: PhraseWording.microphone.title))
                    Button("Keep as recorded") { session.keepOriginal(phrase: phrase.id) }
                        .buttonStyle(.plain).help("Keep this phrase's original audio. Nothing is sent.")
                        .modifier(PanelButtonEvidence(id: "blocked.keep.\(phrase.id)", title: "Keep as recorded"))
                }
            }
            if phrase.wording == .microphone {
                PhraseMicrophoneRow(session: session, microphone: session.phraseMicrophone, plan: plan, phrase: phrase)
            }
        }
    }
}
