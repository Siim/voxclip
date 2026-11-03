import SwiftUI
import VoxClipCore

// The Rewrite job's proposal (R2, design.md §6.3.6) in notes.md §7's grammar (impl-plan V15): the harness line with a
// borderless "Ask again", "{c} changes" with its sub-line, one row per change (the green bar while it waits, its kind's
// glyph, its words, then voice, cut or text) and the pinned footer: "Nothing paid yet", Keep All and the one primary in
// the tint. The rows read the transcript's proposal (`EditorModel.proposal`, V14), so a Keep or an Undo in the
// transcript, in the list or from VoiceOver is one review of one change with one ordinal (impl-plan item 7).

/// R2's content for the task's panel: what `RewriteSession.showProposal()` shows.
struct ProposalContent {
    let set: ChangeSet
    let headline: PanelHeadline
    let cards: [PanelCard]
    let footer: PanelFooter
    let askAgain: PanelAction?
}

/// Why a voice change can't be made now: its row's line, and whether it is a warning.
struct VoiceUnavailable: Equatable {
    let text: String
    let warns: Bool
}

extension RewriteSession {
    /// The voice review (`RewriteReview.voiceHunks`) of each of the reply's voice changes, by ordinal.
    private var voiceReviews: [Int: RewriteHunkReview] {
        let ordinals = changes.enumerated().filter { $0.element.hunk.kind == .voice }.map { $0.offset + 1 }
        return Dictionary(zip(ordinals, review?.voiceHunks ?? []).map { ($0, $1) }, uniquingKeysWith: { first, _ in first })
    }
    /// The voice review of the voice change `ordinal`.
    func voiceReview(_ ordinal: Int) -> RewriteHunkReview? {
        guard var result = voiceReviews[ordinal] else { return nil }
        guard let selectedModel = currentSynthesisModel, let timing = result.timing, let window = result.window,
              (selectedModel == "eleven_v4") != (synthesisModel == "eleven_v4"),
              let silence = try? VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: window),
              let matched = try? VoiceLabPaceMatching.match(seconds: timing.estimateSeconds * timing.pace, window: window,
                  incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                  sourceSampleRate: project.media.source.audio?.sampleRate ?? 48_000,
                  supportsPace: selectedModel != "eleven_v4") else { return result }
        result.timing = matched
        return result
    }
    /// The ordinals of the voice changes takes are made for: those the list includes that can be made, as the AI wrote
    /// them (a change edited in the popover needs a new review first).
    var reviewedVoiceOrdinals: [Int] {
        guard let proposal = ownProposal else { return [] }
        let unavailable = voiceUnavailable
        return proposal.changes.filter { change in
            change.kind == .voice && change.state != .excluded && unavailable(change.ordinal) == nil && replyParts[change.ordinal] == change.parts
        }.map(\.ordinal)
    }
    var includedVoice: [Int] {
        if let takePlan, !takePlan.isRetired, !takePlanOrdinals.isEmpty, hasPaidTakes {
            return reviewedVoiceOrdinals.filter { takePlanOrdinals.contains($0) }
        }
        return reviewedVoiceOrdinals.filter {
            voiceReview($0)?.timing?.fits != false || pricedAnyway.contains($0) ||
                acceptedSpeechContext?.plan.request.expandingHunkIndices.contains($0 - 1) == true
        }
    }
    /// Why the voice change `ordinal` can't be made, nil when it can (design.md R2's voice rows): Voice Lab is off, the
    /// project's language has no calibrated voice check, the take refused its placement, or the review built again after
    /// an edit outside the scope failed (`move`, its `problem`). Such a change has no review and stays left out.
    var voiceUnavailable: (Int) -> VoiceUnavailable? {
        let app = editor.app
        let reviews = voiceReviews
        let enabled = app.voiceLabRewriteEnabled
        let language: Bool = enabled && app.voiceLabSession.voicesUnavailable(projectLanguage: project.transcript?.language)
        let refused = review == nil && !problem.isEmpty ? problem : nil
        return { ordinal in
            if !enabled { return VoiceUnavailable(text: "Needs Voice Lab (beta)", warns: true) }
            if language { return VoiceUnavailable(text: "Your voice works in English projects only for now.", warns: true) }
            if let refused { return VoiceUnavailable(text: refused, warns: true) }
            if let refusal = reviews[ordinal]?.refusal { return VoiceUnavailable(text: refusal, warns: false) }
            return nil
        }
    }

    /// Shows R2 from the transcript's proposal, and shows it again as the proposal, Voice Lab, the takes or the project's
    /// AI lease change: every value `proposalContent` reads is observed. With every change kept the task stays open, so ⌘Z
    /// of the last Keep brings that change back for review (design.md §6.3.5); Close ends it.
    func showProposal() {
        guard isOpen else { return }
        leaveOutUnavailableVoices()
        followIncludedVoice()
        proposalObservation += 1
        let observation = proposalObservation
        let content = withObservationTracking { proposalContent() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, isOpen, proposalObservation == observation, case .proposal = task.state else { return }
                showProposal()
            }
        }
        task.review = { [weak self] ordinal, review in self?.review(ordinal, review) }
        task.phraseTimingAction = { [weak self] ordinal, action in self?.phraseTimingAction(action, ordinal: ordinal) }
        task.show(.proposal(content.set), headline: content.headline, cards: content.cards, footer: content.footer, contextAction: content.askAgain)
    }

    /// Leaves out the voice changes that can't be made now, with no review in the transcript either (`reviewable`), and
    /// includes again those it left out that now can: Voice Lab's Turn on gives them back their review (design.md R2). The
    /// focus moves off a change it leaves out to the first change that waits. No project change and no undo step.
    private func leaveOutUnavailableVoices() {
        guard var proposal = ownProposal else { return }
        let unavailable = voiceUnavailable
        var changed = false
        for index in proposal.changes.indices where proposal.changes[index].kind == .voice {
            let ordinal = proposal.changes[index].ordinal
            if unavailable(ordinal) != nil {
                guard proposal.changes[index].reviewable else { continue }
                proposal.changes[index].reviewable = false
                if proposal.changes[index].state != .excluded { proposal.changes[index].state = .excluded; leftOutUnavailable.insert(ordinal) }
                if proposal.focused == ordinal { proposal.focused = proposal.changes.first { $0.reviewable && $0.state == .pending }?.ordinal ?? ordinal }
                changed = true
            } else if !proposal.changes[index].reviewable {
                proposal.changes[index].reviewable = true
                if leftOutUnavailable.remove(ordinal) != nil, proposal.changes[index].state == .excluded { proposal.changes[index].state = .pending }
                changed = true
            }
        }
        if changed { editor.proposal = proposal }
    }

    /// A changed inclusion set needs a fresh complete-set placement and quote, never the old set's paid authorization.
    private func followIncludedVoice() {
        let included = includedVoice
        guard included != includedVoicesSeen || takePlan.map({ !$0.isRetired && !$0.stillCurrent }) == true else { return }
        includedVoicesSeen = included
        if hasPaidTakes {
            takePlan?.invalidate()
            generation?.inputsChanged(prepareNewQuote: false)
            generation?.fail("Your paid takes are kept. Leave this review and confirm discarding them before making a fresh takes plan.")
            return
        }
        takePlan?.invalidate(); takePlan = nil
        generation?.inputsChanged()
    }

    /// R2's set, cards, footer and Ask again, by design.md R2's footer cases.
    func proposalContent() -> ProposalContent {
        let readings = ownProposal == nil ? [] : editor.changeReadings
        let unavailable = voiceUnavailable
        let items = readings.map { item($0, of: readings.count, unavailable: $0.change.kind == .voice ? unavailable($0.change.ordinal) : nil) }
        let set = ChangeSet(items: items, focused: ownProposal?.focused)
        // The Beta tag shows with phrases in your voice while Voice Lab is on (design.md §6.3.4).
        var headline = PanelHeadline(text: set.headline, sub: set.subline, tag: showsVoiceLab && set.voiceCount > 0 ? "Beta" : nil)
        // Ask again can't run while another AI request holds the project (Find Clips); it comes back as that ends.
        var askAgain = editor.llmRuns.isBusy ? nil : PanelAction(id: "askAgain", title: sendAsksFirst ? "Ask again…" : "Ask again") { [weak self] in
            guard let self else { return }
            editor.runRewrite(scope: rewriteScope)
        }
        guard !items.isEmpty else {
            return ProposalContent(set: set, headline: headline,
                                   cards: [.text("\(aiName) found nothing to change in \(task.words.name)."), .ask(placeholder: AskField.placeholder(task.words))],
                                   footer: PanelFooter(primary: askForSomethingElse), askAgain: askAgain)
        }
        let footer = proposalFooter(set)
        var cards: [PanelCard] = [.changes(set)]
        if let callout = footer.callout { cards.append(.callout(callout)) }
        // Why Make Takes could not go on (finding the voices failed); a refused review is on the voice rows instead.
        if review != nil, !problem.isEmpty { cards.append(.callout(problem)) }
        if (footer.takes || surroundingSentenceOrdinal != nil), takeRowsShown {
            cards = blockedVoiceOrdinals.isEmpty ? [.takes] : [.changes(set), .takes]
            let count = takePlan?.phrases.count ?? includedVoice.count
            headline.text = count == 1 ? "1 phrase in your voice" : "\(count) phrases in your voice"
            headline.sub = "Listen, pick a take, then use them."
            if takesBusy {
                headline.stop = PanelAction(id: "stopTakes", title: "Stop") { [weak self] in self?.stopTakes() }
            }
        } else if footer.takes {
            askAgain = PanelAction(id: "showTakes", title: "Review Takes") { [weak self] in
                self?.takeRowsShown = true; self?.showProposal()
            }
        }
        return ProposalContent(set: set, headline: headline, cards: cards, footer: footer.footer, askAgain: askAgain)
    }

    /// A change's row: its words (a cut's removed words; otherwise the words it would leave), its state, and the line
    /// under it for a voice change that can't be made or one that adds something you didn't say.
    private func item(_ reading: TranscriptChangeReading, of count: Int, unavailable: VoiceUnavailable?) -> ProposalItem {
        let change = reading.change
        let kind: ProposalItem.Kind = change.kind == .voice ? .voice : change.kind == .fix ? .fix : .cut
        var state: ProposalItem.State = switch change.state {
        case .pending: reading.applied ? .kept : .pending
        case .kept: .kept
        case .excluded: .excluded
        }
        if unavailable != nil { state = .excluded }
        let checkThis = changes.indices.contains(change.ordinal - 1) && changes[change.ordinal - 1].checkThis
        let note = unavailable?.text ?? (checkThis ? "Check this: it adds something you didn't say." : nil)
        func quoted(_ text: String) -> String {
            // A phrase reads without the comma or stop it ends on, as notes.md's rows do.
            var text = text.trimmingCharacters(in: .whitespaces)
            while let last = text.last, kind != .fix, ",;.".contains(last) { text.removeLast() }
            return text
        }
        let timing = kind == .voice ? voiceReview(change.ordinal)?.timing : nil
        let spoken = change.description(prefix: "Change", count: count, removed: reading.removed, inserted: reading.inserted)
        return ProposalItem(timing: timing,
                            pricedAnyway: pricedAnyway.contains(change.ordinal),
                            ordinal: change.ordinal, kind: kind, sourceWordIDs: change.span, newWords: change.parts.flatMap(\.newTokens),
                            oldWords: reading.removed, checkThis: checkThis, state: state,
                            quote: quoted(kind == .cut ? reading.removed.joined(separator: " ") : reading.text),
                            note: note, warns: unavailable?.warns ?? checkThis, reviewable: unavailable == nil,
                            spoken: spoken + (timing.map { ". " + $0.copy } ?? "") + (note.map { ". " + $0 } ?? ""))
    }

    /// R2's footer cases (design.md R2), with "Nothing paid yet" and Keep All in v2's grammar (notes.md §7):
    /// - Voice Lab off with voice changes: Turn On Voice Lab, and Apply {k} Free Changes.
    /// - Voice changes over the budget: the callout, and Apply {k} Free Changes.
    /// - Included voice changes: Make Your Voice with no voice yet, Make Takes, or Use Takes once takes passed,
    ///   with Keep All while changes wait.
    /// - Only cuts and fixes: Apply {c} Changes. Nothing included: the note alone. Every change kept: its note alone, and
    ///   Close ends the task.
    private func proposalFooter(_ set: ChangeSet) -> (footer: PanelFooter, callout: String?, takes: Bool) {
        let pending = set.items.filter { $0.state == .pending && $0.reviewable }
        let free = pending.filter { $0.kind != .voice }.count
        let voices = set.items.filter { $0.kind == .voice }
        let included = voices.filter { $0.reviewable && $0.state != .excluded }
        // Read from `set`, not the task's state, which `showProposal` writes while it observes this. "Apply {k} Free
        // Changes" beside voice changes the footer can't make, "Apply {c} Changes" when only cuts and fixes are included.
        func apply(beside voice: Bool) -> PanelAction? {
            Self.applyTitle(free: free, voice: voice).map { title in PanelAction(id: "apply", title: title) { [weak self] in self?.applyFreeChanges() } }
        }
        let keepAll = pending.isEmpty ? nil : PanelAction(id: "keepAll", title: "Keep All") { [weak self] in self?.keepAll() }
        func phrases(_ count: Int) -> String { count == 1 ? "1 phrase needs" : "\(count) phrases need" }
        if !editor.app.voiceLabRewriteEnabled, !voices.isEmpty {
            let turnOn = PanelAction(id: "turnOnVoiceLab", title: "Turn On Voice Lab") { [weak self] in self?.editor.openVoiceJob() }
            return (PanelFooter(note: "\(phrases(voices.count)) your voice. Voice Lab (beta) makes it from this \(task.words.noun).", link: turnOn, primary: apply(beside: true)), nil, false)
        }
        if !included.isEmpty, let over = overBudget {
            return (PanelFooter(note: "Make Takes appears when the phrases fit.", primary: apply(beside: true)), over, false)
        }
        let blocked = blockedVoiceOrdinals.count
        if blocked > 0 {
            let priceable = included.filter { includedVoice.contains($0.ordinal) }
            guard let voice = priceable.first else {
                return (PanelFooter(note: timingBlockedNote, link: keepAll, primary: apply(beside: true)), nil, false)
            }
            var footer = takesFooter(voice, keepAll: keepAll)
            let paidNote = takePlan == nil ? nil : footer.note
            footer.note = [timingBlockedNote, paidNote].compactMap { $0 }.joined(separator: "\n")
            return (footer, nil, takePlan != nil)
        }
        if let voice = included.first {
            return (takesFooter(voice, keepAll: keepAll), nil, generation != nil)
        }
        if free > 0 { return (PanelFooter(note: "No AI voice needed. Nothing is sent.", primary: apply(beside: false)), nil, false) }
        if set.items.allSatisfy({ $0.state == .kept }) { return (PanelFooter(note: Self.everyChangeKept), nil, false) }
        return (PanelFooter(note: "Keep a change to apply it."), nil, false)
    }
    /// The voice budget (voice-lab.md §8.2) over the voice changes the list includes, as design.md R2's callout reads it;
    /// nil while they fit. Leaving a phrase out can bring Make Takes back.
    var overBudget: String? {
        let hunks = reviewedVoiceOrdinals.compactMap { changes.indices.contains($0 - 1) ? changes[$0 - 1].hunk : nil }
        let budget = VoiceLabPatchBudget.evaluate(hunks: hunks, transcript: transcript)
        guard budget.flag == .reRecordInstead else { return nil }
        let limit = min(60, budget.wordItems * 15 / 100)
        return "These changes re-voice \(budget.voiceTokenCount) words; a rewrite can re-voice \(limit). Undo a phrase or two, or re-record these sentences."
    }
    /// R2's note once every change is kept: nothing is left to apply; ⌘Z of a Keep brings its change back for review.
    static let everyChangeKept = "Every change is kept."

    /// Every footer action that only finds the voices and prices the set; nothing is sent until the priced
    /// "Make Takes · ≈ $x" that replaces it is pressed. A first "Make Takes" that only priced read as a failed click.
    /// The footer prepares one plan for the entire included set. V18 supplies the phrase rows.
    private func takesFooter(_ voice: ProposalItem, keepAll: PanelAction?) -> PanelFooter {
        if let takePlan {
            guard !takesBusy else { return PanelFooter(note: takeSpendLine) }
            if usableTakeCount > 0, takePlan.stillCurrent {
                let title = usableTakeCount == takePlan.phrases.count ? "Use Takes" : "Use \(usableTakeCount) \(usableTakeCount == 1 ? "Take" : "Takes")"
                return PanelFooter(note: "Exports show AI MODIFIED on the video. The post disclosure is optional.",
                    primary: PanelAction(id: "useTakes", title: title) { [weak self] in self?.useTake() })
            }
            if takePlan.spent.units > 0 { return PanelFooter(note: "Left out until a take fits. " + takeSpendLine) }
            if let action = pricedTakeAction() { return PanelFooter(note: takeSendLine, link: keepAll, primary: action) }
            return PanelFooter(note: takePlan.problem.isEmpty ? "Prepare a fresh price to make takes." : takePlan.problem,
                link: keepAll, primary: PanelAction(id: "prepareTakes", title: Self.priceTitle(includedVoice.count)) { [weak self] in self?.makeTakes() })
        }
        if let parts = replyParts[voice.ordinal], ownProposal?[voice.ordinal]?.parts != parts {
            return PanelFooter(note: "Takes are made from the AI's words. Rewrite again to make takes of an edited change.", link: keepAll)
        }
        let unpaid = "Nothing paid yet."
        guard let generation else {
            let estimate = review?.summary?.costEstimate?.usd.map { usd in
                let amount = VoiceLabCostPresentation.format(usd)
                return "\nTakes " + (amount.hasPrefix("<") ? amount : "≈ " + amount) + " on ElevenLabs."
            } ?? ""
            return PanelFooter(note: unpaid + estimate, link: keepAll, primary: PanelAction(id: "makeTakes", title: Self.priceTitle(includedVoice.count)) { [weak self] in self?.makeTakes() })
        }
        if generation.voices.isEmpty {
            let make = PanelAction(id: "makeVoice", title: "Make Your Voice") { [weak self] in
                self?.editor.openVoiceJob()
            }
            return PanelFooter(note: unpaid + " Next: make your voice from this \(task.words.noun). Once.", link: keepAll, primary: make)
        }
        return PanelFooter(note: unpaid + " " + takeSendLine, link: keepAll,
            primary: PanelAction(id: "prepareTakes", title: Self.priceTitle(includedVoice.count)) { [weak self] in self?.makeTakes() })
    }

    /// The proposal has changes waiting for review, shown or set aside by R3: its tab shows the dirty dot (notes.md §5).
    var hasUnreviewedChanges: Bool {
        guard isOpen else { return false }
        switch task.state {
        case .proposal: return ownProposal.map { editor.hasUnreviewedChanges(clipID: $0.clipID) } ?? false
        case .changed: return setAside?.proposal?.changes.contains { $0.state == .pending } ?? false
        default: return false
        }
    }

    /// A row's Keep, Undo, focus or edit (impl-plan item 7): the transcript's own review, so the list and the hunks agree.
    func review(_ ordinal: Int, _ review: ChangeReview) {
        guard isOpen, case .proposal = task.state, ownProposal != nil else { return }
        switch review {
        case .focus: editor.focusChange(ordinal, announcing: false)
        case .keep: editor.keepChange(ordinal)
        case .undo: editor.excludeChange(ordinal)
        case .edit: editChange(ordinal)
        }
        // The list shows the review at once; a review in the transcript reaches it through `showProposal`'s observation.
        if isOpen, case .proposal = task.state { showProposal() }
    }
    /// Keep All (impl-plan item 7): the free changes apply as one undo step named for the scope, and the voice changes are
    /// included for takes. Rewrite stays open for the takes.
    func keepAll() {
        guard current, !isProposing, ownProposal != nil else { return }
        editor.keepAllChanges()
        if isOpen, case .proposal = task.state { showProposal() }
    }
    /// Return on a row (design.md §6.3.5): focuses the change and opens its edit popover in the transcript, which takes
    /// the keyboard, as Return on the focused change there does. A change with no review, or a kept cut or fix, has none.
    private func editChange(_ ordinal: Int) {
        editor.focusChange(ordinal, announcing: false)
        guard editor.proposalDisplay?.focused == ordinal, editor.proposalDisplay?.actions.isEmpty == false, focusTranscript(in: editor.window),
              let transcript = editor.window?.firstResponder as? TranscriptNSTextView else { return }
        // The focused change keeps its buttons' blank in the text: lay it out before the popover is placed under it.
        transcript.renderNow()
        _ = transcript.accessibleEditChange()
    }
    /// Make Takes: finds the consented voices first (asking for ElevenLabs once), then makes takes of the included voice
    /// change, asking first when the cost confirms (voice-lab.md §3.1). A footer drawn before the list's inclusions
    /// changed makes no takes of a phrase other than the one the quote is for.
    func makeTakes() {
        guard current, !includedVoice.isEmpty || surroundingSentenceOrdinal != nil else { return }
        guard !takesBusy else { return }
        takeRowsShown = true
        guard generation != nil else {
            takesTask = Task { [weak self] in await self?.discoverVoices() }
            return
        }
        guard !hasPaidTakes else { return }
        if let ordinal = surroundingSentenceOrdinal { reviewTimingSpeechContext(ordinal: ordinal); return }
        takesTask = Task { [weak self] in await self?.prepareTakes() }
    }
    /// Use Take {n}: the take with the free changes still pending, one undo step.
    func useTake() {
        takesTask?.cancel()
        takesTask = Task { [weak self] in _ = await self?.acceptTakes() }
    }
}

/// R2's change list (notes.md `.hrow`): 26 pt rows, 8 pt in, the focused change on `bg.selectedRow`. A click focuses the
/// change in the transcript; Keep and Undo are the row's menu and VoiceOver actions, as in the transcript.
@MainActor struct ChangeListCard: View {
    let set: ChangeSet
    let task: DirectorTask
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(set.items) { item in
                ChangeRow(item: item, focused: item.ordinal == set.focused,
                    timingAction: { task.phraseTimingAction?(item.ordinal, $0) }, review: { task.review?(item.ordinal, $0) })
            }
        }
        .padding(.horizontal, -8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes")
        .columnLayoutEvidence("director.changes")
    }
}

@MainActor private struct ChangeRow: View {
    let item: ProposalItem
    let focused: Bool
    let timingAction: (PhraseTimingAction) -> Void
    let review: (ChangeReview) -> Void

    /// Keep and Undo where they can act, then Edit, as the transcript offers them: a waiting change Keep and Undo, a change
    /// left out Keep, a kept voice change Undo. A kept cut or fix is in the project; ⌘Z takes it back.
    private var actions: [ChangeReview] {
        guard item.reviewable else { return [] }
        switch item.state {
        case .pending: return [.keep, .undo, .edit]
        case .excluded: return [.keep, .edit]
        case .kept: return item.kind == .voice ? [.undo, .edit] : []
        }
    }
    private var glyph: String {
        switch item.kind {
        case .voice: "waveform"
        case .cut: "scissors"
        case .fix: "pencil"
        }
    }
    /// The trailing label: the kind while the change waits, then how it was reviewed.
    private var label: String {
        switch item.state {
        case .pending: item.kind == .voice ? "voice" : item.kind == .cut ? "cut" : "text"
        case .kept: "kept"
        case .excluded: "left out"
        }
    }
    static func title(_ review: ChangeReview, _ ordinal: Int) -> String {
        switch review {
        case .keep: "Keep change \(ordinal)"
        case .undo: "Undo change \(ordinal)"
        case .focus: "Show change \(ordinal)"
        case .edit: "Edit change \(ordinal)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(item.state == .pending ? DesignValues.color("change.add") : .clear)
                    .frame(width: 3, height: 14)
                Image(systemName: glyph).font(.system(size: 12)).foregroundStyle(DesignValues.color("text.tertiary")).frame(width: 14)
                Text(item.quote).font(VCType.callout.font())
                    .foregroundStyle(DesignValues.color(item.state == .pending ? "text.primary" : item.state == .kept ? "text.secondary" : "text.tertiary"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(label).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize()
            }
            .frame(height: 26)
            if let timing = item.timing {
                Text(timing.copy).font(VCType.small.font().monospaced())
                    .foregroundStyle(DesignValues.color("text.tertiary"))
                    .padding(.leading, 33).padding(.bottom, 6)
                if !timing.fits, item.state != .excluded {
                    PhraseTimingRecovery(tooLong: timing.tooLong, priceAnyway: !item.pricedAnyway, action: timingAction)
                        .padding(.leading, 33).padding(.bottom, 8)
                }
            }
            if let note = item.note {
                Label { Text(note).fixedSize(horizontal: false, vertical: true) } icon: {
                    if item.warns { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)) }
                }
                .labelStyle(.titleAndIcon)
                .font(VCType.small.font())
                .foregroundStyle(DesignValues.color(item.warns ? "status.warning" : "text.secondary"))
                .padding(.leading, 33).padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? DesignValues.color("bg.selectedRow") : .clear, in: .rect(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { review(.focus) }
        .contextMenu {
            ForEach(actions, id: \.self) { action in
                Button(action == .keep ? "Keep Change" : action == .undo ? "Undo Change" : "Edit Change") { review(action) }
            }
        }
        .accessibilityElement(children: item.timing?.fits == false ? .contain : .ignore)
        .accessibilityLabel(item.spoken)
        .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { review(.focus) }
        .modifier(ChangeRowActions(actions: actions, ordinal: item.ordinal, review: review))
        .columnLayoutEvidence("director.change.\(item.ordinal)", text: item.spoken)
    }
}

/// The row's VoiceOver actions, "Keep change {i}", "Undo change {i}" and "Edit change {i}", as the transcript's custom
/// actions name them.
private struct ChangeRowActions: ViewModifier {
    let actions: [ChangeReview]
    let ordinal: Int
    let review: (ChangeReview) -> Void
    func body(content: Content) -> some View {
        actions.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: Text(ChangeRow.title(action, ordinal))) { review(action) })
        }
    }
}

@MainActor struct RewriteTakesCard: View {
    let model: EditorModel?
    var body: some View {
        if let session = model?.rewrite, let generation = session.generation {
            DirectorTakeRows(session: session, generation: generation)
        }
    }
}

extension Array {
    /// The array's one element, nil when it has none or several.
    var only: Element? { count == 1 ? first : nil }
}
