import Observation
import SwiftUI
import VoxClipCore

/// A phrase card's three ways to its words (design.md §6.3 "Your own words"): the AI's suggestion, the user's own typed
/// words read by their cloned voice, or the user saying the phrase into the microphone (MicrophoneTake.swift). Suggested
/// is the default; switching keeps every take, and all of them stay in the phrase's one take list.
enum PhraseWording: String, CaseIterable, Identifiable {
    case suggested, ownWords, microphone
    var id: String { rawValue }
    var title: String {
        switch self {
        case .suggested: "✦ Suggested"
        case .ownWords: "My words"
        case .microphone: "● Say it myself"
        }
    }
    var shortTitle: String {
        switch self {
        case .suggested: "✦ AI"
        case .ownWords: "Mine"
        case .microphone: "● Say"
        }
    }
    /// The words My words starts from: the phrase's change, without the bridge words it keeps from the recording.
    static func change(of phrase: ClipTakePlan.Phrase) -> String {
        let words = EditingPrimitives.splitWords(phrase.text)
        let left = min(words.count, phrase.window.leftBridgeWordIds.count), right = min(words.count - left, phrase.window.rightBridgeWordIds.count)
        return words.dropFirst(left).dropLast(right).joined(separator: " ")
    }
}

/// My words' live length line: the plan's own estimate of how long the cloned voice takes to read the words.
struct OwnWordsFit: Equatable {
    let words: Int
    let seconds: Double
    let gap: Double
    let lower: Double
    let upper: Double
    /// The plan's own verdict for these words in this gap (`VoiceLabPhraseTiming`).
    let fits: Bool
    let tooLong: Bool
    var line: String {
        let about = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        let slot = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), gap)
        let verdict = fits ? "✓" : tooLong ? "· likely too long" : "· likely too short"
        return "Your voice reads this. \(words) \(words == 1 ? "word" : "words") · about \(about) s, the gap is \(slot) s \(verdict)"
    }
}

/// The AI's shorter or longer version of the user's words: it fills the field and sends nothing for takes.
@MainActor @Observable final class OwnWordsAdvice {
    var phrase: Int?
    var running = false
    /// A send billed to the user's key waits for its inline [Send · ≈ $x].
    var awaiting: CostEstimate?
    var problem = ""
    @ObservationIgnored var request: VoiceLabFitPhrase?
}

extension RewriteSession {
    /// The bridge words a phrase keeps from the recording on each side of its change.
    func bridgeWords(_ phrase: ClipTakePlan.Phrase) -> (left: [String], right: [String]) {
        let texts = Dictionary(Self.corrected(project).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let words = { (ids: [String]) in ids.compactMap { texts[$0] }.flatMap { EditingPrimitives.splitWords($0) } }
        return (words(phrase.window.leftBridgeWordIds), words(phrase.window.rightBridgeWordIds))
    }
    /// The whole phrase as the cloned voice reads it: the bridge words around the user's own words. nil before any words.
    func ownWordsText(_ phrase: ClipTakePlan.Phrase) -> String? {
        let typed = EditingPrimitives.splitWords(phrase.ownWords ?? "")
        guard !typed.isEmpty else { return nil }
        let bridges = bridgeWords(phrase)
        return (bridges.left + typed + bridges.right).joined(separator: " ")
    }
    func ownWordsFit(_ phrase: ClipTakePlan.Phrase) -> OwnWordsFit? {
        guard let text = ownWordsText(phrase) else { return nil }
        do {
            let spoken = RewriteReview.timingTranscript(reviewInputs)
            let rate = try VoiceLabPhraseTiming.speakingRate(transcript: spoken)
            let calibrated = VoiceLabWordingFit.multiplier(project.voiceLab.speakingRateSamples?[VoiceLabWordingFit.modelID] ?? [])
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: phrase.window)
            let tags = VoiceLabAudioTags.validated(phrase.audioTags, text: text)
            let timing = try VoiceLabPaceMatching.measure(text: text, rate: rate, window: phrase.window,
                incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                sourceSampleRate: project.media.source.audio?.sampleRate ?? 48_000, supportsPace: false,
                hardJoinSmoothing: true, audioTags: tags, modelID: VoiceLabWordingFit.modelID,
                sourceItems: spoken, sourceEnvelope: envelope, rateMultiplier: calibrated)
            let lower = timing.minimumSeconds ?? timing.slotSeconds
            return OwnWordsFit(words: EditingPrimitives.splitWords(text).count, seconds: timing.estimateSeconds,
                gap: phrase.originalLength, lower: lower, upper: max(lower, timing.maximumSeconds ?? timing.slotSeconds),
                fits: timing.fits, tooLong: timing.tooLong)
        } catch { return nil }
    }

    func chooseWording(_ wording: PhraseWording, phrase index: Int) {
        guard let plan = takePlan, plan.phrases.indices.contains(index) else { return }
        focusedTakePhrase = index
        if phraseMicrophone.phrase == index, wording != .microphone { phraseMicrophone.cancel() }
        plan.chooseWording(wording, phrase: index)
        if wording == .ownWords { ownWordsEditing = index }
        if ownWordsAdvice.phrase == index { ownWordsAdvice.phrase = nil; ownWordsAdvice.awaiting = nil }
        showProposal()
    }
    func editOwnWords(_ text: String, phrase index: Int) {
        guard let plan = takePlan else { return }
        plan.editOwnWords(text, phrase: index)
        if ownWordsAdvice.phrase == index, !ownWordsAdvice.running { ownWordsAdvice.phrase = nil; ownWordsAdvice.awaiting = nil }
    }
    /// The quote [Make take · ≈ $x] approves: the user's words, priced for this phrase alone. Nothing is sent.
    func priceOwnWords(phrase index: Int) async {
        guard current, let plan = takePlan, plan.phrases.indices.contains(index), !takesBusy,
              let text = ownWordsText(plan.phrases[index]), !plan.quotes(text, phrase: index) else { return }
        takeQuotePhrase = index; focusedTakePhrase = index
        await plan.prepareRewording(text, phrase: index)
        showProposal()
    }
    /// [Make take · ≈ $x] for the user's words: the existing priced, approved path, once its quote is for these words.
    func ownWordsTakeAction(phrase index: Int) -> PanelAction? {
        guard let plan = takePlan, plan.phrases.indices.contains(index), let text = ownWordsText(plan.phrases[index]),
              plan.quotedText(phrase: index) == text, let action = pricedTakeAction(phrase: index), let cost = plan.cost else { return nil }
        let title: String = switch cost {
        case .inline: VoiceLabCostPresentation.buttonTitle("Make take", kind: cost)
        case .confirm: "Make take…"
        }
        return PanelAction(id: action.id, title: title, priced: true, perform: action.perform)
    }

    /// [✦ Shorten my words] or [✦ Lengthen my words]: the AI fits the user's words to the gap. Its reply fills the field.
    func adviseOwnWords(phrase index: Int, approved: Bool = false) async {
        guard current, let plan = takePlan, plan.phrases.indices.contains(index), let connector, let shared = editor.app.shared,
              !ownWordsAdvice.running, let text = ownWordsText(plan.phrases[index]), let fit = ownWordsFit(plan.phrases[index]) else { return }
        let phrase = plan.phrases[index]
        ownWordsAdvice.phrase = index; ownWordsAdvice.problem = ""; ownWordsAdvice.running = true
        defer { ownWordsAdvice.running = false; showProposal() }
        do {
            let spoken = RewriteReview.timingTranscript(reviewInputs).filter { $0.kind == .word }
            let rate = try VoiceLabPhraseTiming.speakingRate(transcript: RewriteReview.timingTranscript(reviewInputs))
            let characters = spoken.reduce(0) { $0 + VoiceLabTextLength.length($1.text) }
            let wordsPerSecond = rate * Double(spoken.count) / Double(max(1, characters))
            let calibrated = VoiceLabWordingFit.multiplier(project.voiceLab.speakingRateSamples?[VoiceLabWordingFit.modelID] ?? [])
            let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: wordsPerSecond, multiplier: calibrated,
                minimumSeconds: fit.lower, maximumSeconds: fit.upper, overheadSeconds: 0)
            let ordinal = takePhraseOrdinals(phrase).first ?? phrase.id + 1
            let readings = editor.changeReadings.filter { takePhraseOrdinals(phrase).contains($0.change.ordinal) }
            let request = VoiceLabFitPhrase(ordinal: ordinal, original: readings.flatMap(\.removed).joined(separator: " "),
                proposed: text, estimateSeconds: fit.seconds, slotSeconds: phrase.originalLength,
                direction: fit.tooLong ? "shorter" : "longer", target: target, measuredSeconds: nil, calibrated: true)
            let service = VoiceLabWordingFitService(shared: shared), language = project.transcript?.language ?? "en"
            let quote = try await service.prepare([request], connector: connector.connector.id, model: connector.model, language: language)
            guard current, takePlan === plan else { return }
            if sendAsksFirst, !approved {
                ownWordsAdvice.awaiting = quote.estimate
                return
            }
            ownWordsAdvice.awaiting = nil
            guard let lease = editor.llmRuns.acquire() else { throw LLMError.unavailable(reason: "Another AI request on this project is still running.") }
            defer { editor.llmRuns.release(lease) }
            let updates = try await service.propose([request], connector: connector.connector, model: connector.model,
                language: language, quote: quote, approved: true)
            guard current, takePlan === plan, plan.phrases.indices.contains(index), let update = updates.first, !update.keepOriginal else { return }
            let bridges = bridgeWords(plan.phrases[index])
            var words = EditingPrimitives.splitWords(update.text)
            if words.starts(with: bridges.left) { words.removeFirst(bridges.left.count) }
            if words.count >= bridges.right.count, Array(words.suffix(bridges.right.count)) == bridges.right { words.removeLast(bridges.right.count) }
            editOwnWords(words.joined(separator: " "), phrase: index)
            ownWordsEditing = index
        } catch {
            guard current else { return }
            ownWordsAdvice.problem = reported(error, stage: "ownWords")
        }
    }
}

/// The segmented control under a phrase's original line, and the segment it shows (design.md §6.3).
@MainActor struct PhraseWordingSection: View {
    @Bindable var session: RewriteSession
    @Bindable var plan: ClipTakePlan
    let phrase: ClipTakePlan.Phrase
    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            // Full labels where the column allows, short ones in a narrow column, else a menu: never clipped.
            ViewThatFits(in: .horizontal) {
                picker(short: false).pickerStyle(.segmented).fixedSize()
                picker(short: true).pickerStyle(.segmented).fixedSize()
                picker(short: false).pickerStyle(.menu).fixedSize()
            }
            .controlSize(.small)
            .modifier(PanelButtonEvidence(id: "wording.\(phrase.id)", title: phrase.wording.title))
            switch phrase.wording {
            case .suggested: EmptyView()
            case .ownWords: ownWords
            case .microphone: PhraseMicrophoneRow(session: session, microphone: session.phraseMicrophone, plan: plan, phrase: phrase)
            }
        }
    }

    private func picker(short: Bool) -> some View {
        Picker("Words for phrase \(phrase.id + 1)", selection: Binding(get: { phrase.wording },
            set: { session.chooseWording($0, phrase: phrase.id) })) {
            ForEach(PhraseWording.allCases) { Text(short ? $0.shortTitle : $0.title).tag($0) }
        }
        .labelsHidden().accessibilityLabel("Words for phrase \(phrase.id + 1)")
    }

    @ViewBuilder private var ownWords: some View {
        // At most one free-text field shows (house rule): the phrase being edited; another phrase's words read as a line.
        if session.ownWordsEditing == phrase.id {
            TextField("Your words for phrase \(phrase.id + 1)", text: Binding(get: { phrase.ownWords ?? "" },
                set: { session.editOwnWords($0, phrase: phrase.id) }), axis: .vertical)
                .lineLimit(1...3).font(VCType.callout.font()).vcFieldChrome(multiline: true)
                .onSubmit { Task { await session.priceOwnWords(phrase: phrase.id) } }
                .task(id: phrase.ownWords) {
                    // The price follows the words once typing pauses; nothing is sent until [Make take · ≈ $x].
                    do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                    await session.priceOwnWords(phrase: phrase.id)
                }
                .accessibilityLabel("Your words for phrase \(phrase.id + 1)")
        } else if let words = phrase.ownWords, !words.isEmpty {
            HStack(spacing: VCTokens.spacingLabelGap) {
                Text("My words: “\(words)”").font(VCType.callout.font()).frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit") { session.ownWordsEditing = phrase.id; session.focusedTakePhrase = phrase.id }
                    .buttonStyle(.plain).modifier(PanelButtonEvidence(id: "ownWords.edit.\(phrase.id)", title: "Edit"))
            }
        }
        if let fit = session.ownWordsFit(phrase) {
            Text(fit.line).font(VCType.small.font())
                .foregroundStyle(DesignValues.color(fit.fits ? "text.secondary" : "status.warning"))
                .columnLayoutEvidence("voice.phrase.\(phrase.id).ownWords.line", text: fit.line)
            if !fit.fits, !session.takesBusy { advice(fit) }
        }
        if !session.takesBusy, let action = session.ownWordsTakeAction(phrase: phrase.id) {
            Text(session.takeSendLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            PanelButton(action: action, kind: .ghost)
        } else if plan.preparing, session.takeQuotePhrase == phrase.id {
            ProgressView("Pricing your words…").controlSize(.small)
        }
        Text(PhraseOwnWordsCopy.ownWordsFooter).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            .columnLayoutEvidence("voice.phrase.\(phrase.id).ownWords.next.line", text: PhraseOwnWordsCopy.ownWordsFooter)
    }

    /// A likely misfit's advice, with actions that fill the field and send no take. The speech model has no pace setting
    /// (Eleven v4), so no pace control shows: it could not act.
    @ViewBuilder private func advice(_ fit: OwnWordsFit) -> some View {
        let advice = session.ownWordsAdvice
        let title = fit.tooLong ? "✦ Shorten my words" : "✦ Lengthen my words"
        if advice.phrase == phrase.id, advice.running {
            ProgressView("Asking \(session.aiName) to fit your words…").controlSize(.small)
        } else if advice.phrase == phrase.id, let estimate = advice.awaiting {
            Text("Sends your words to \(session.aiName) with your key. It fills the field; no take is made.")
                .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            HStack(spacing: VCTokens.spacingRowGap) {
                PanelButton(action: PanelAction(id: "ownWords.send.\(phrase.id)",

                    title: "Send · " + (estimate.usd.map(VoiceLabCostPresentation.format) ?? "price unavailable"), priced: true) {
                        Task { await session.adviseOwnWords(phrase: phrase.id, approved: true) }
                    }, kind: .ghost)
                PanelButton(action: PanelAction(id: "ownWords.cancel.\(phrase.id)", title: "Cancel") {
                    advice.awaiting = nil; advice.phrase = nil
                }, kind: .ghost)
            }
        } else if session.connector != nil {
            Button(title) { Task { await session.adviseOwnWords(phrase: phrase.id) } }
                .buttonStyle(.plain).help("Ask \(session.aiName) to fit your words to the gap. It fills the field; nothing is sent to ElevenLabs.")
                .modifier(PanelButtonEvidence(id: "ownWords.fit.\(phrase.id)", title: title))
        }
        if advice.phrase == phrase.id, !advice.problem.isEmpty {
            Text(advice.problem).font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning"))
        }
    }
}

enum PhraseOwnWordsCopy {
    static let ownWordsFooter = "Next: listen, then Use. Lip sync follows if it's on."
    static let microphoneFooter = "Next: Use, then Export. No ElevenLabs cost for your own take."
}
