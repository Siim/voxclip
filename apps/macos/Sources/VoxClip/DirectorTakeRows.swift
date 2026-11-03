import SwiftUI
import VoxClipCore

enum TakeFailurePresentation {
    static func shortSpeechSummary(_ rows: [VoiceLabTakeRow], selected: UUID?) -> [String] {
        let selectedRow = rows.first { $0.id == selected && $0.selectable && $0.voiceCheck.evidence != nil }
        let measured = rows.last { $0.selectable && $0.voiceCheck.evidence?.mode == .pooled }
        let available = rows.last { $0.selectable && $0.voiceCheck.evidence != nil }
        let display = selectedRow ?? measured ?? available ?? rows.last { $0.voiceCheck.evidence != nil }
        guard let row = display, let copy = row.shortPhraseCopy else { return [] }
        if row.voiceCheck.evidence?.mode == .unmeasured, row.selectable {
            return [copy, "Selectable for your own clone."]
        }
        return [copy]
    }

    static func reason(for row: VoiceLabTakeRow) -> String? {
        guard !row.selectable else { return nil }
        if row.voiceCheck == .waiting { return nil }
        if row.voiceCheck.evidence?.mode == .unmeasured, row.qa?.failures.contains(.speaker) == true {
            return "A previous voice check for this voice failed. Try another take to check it again."
        }
        if let failure = row.failure { return reason(for: failure, qa: row.qa?.values) }
        if let qa = row.qa, !qa.passed { return reason(for: .qa(qa.failures), qa: qa.values) }
        if row.qa?.passed == true { return "The checked audio is unavailable." }
        return "The required checks did not complete. No result is available."
    }

    static func reason(for failure: VoiceLabTakeFailure, qa: VoiceLabQA? = nil) -> String {
        switch failure {
        case .qa(let failures):
            let reasons = failures.map { check in
                switch check {
                case .insufficientGeneratedSpeech:
                    return "Not enough generated speech for the speaker check. It requires at least 3 seconds of voiced speech; this take could not be verified."
                case .transcript:
                    return qa?.transcriptMatch?.isFinite == true
                        ? "The recognized words did not pass the word check."
                        : "The word check did not complete. No word-match result is available."
                case .speaker:
                    return qa?.speakerScore?.isFinite == true
                        ? "The voice did not pass the speaker-match check."
                        : "The speaker check did not complete. No speaker-match result is available."
                case .clipping:
                    return qa?.peakDbfs?.isFinite == true
                        ? "The audio did not pass the clipping check."
                        : "The clipping check did not complete."
                case .loudness:
                    return qa?.lufsJumpLu?.isFinite == true
                        ? "The audio did not pass the loudness check at the joins."
                        : "The loudness check at the joins did not complete."
                }
            }
            return reasons.isEmpty ? "The required checks did not complete. No result is available." : reasons.joined(separator: " ")
        case .invalidAudio: return "The take's audio could not be validated."
        case .invalidAlignment: return "The take's word timing could not be validated."
        case .consent(.speakerUnavailable): return "The speaker check is unavailable. This take could not be verified."
        case .consent(.speakerMismatch): return "The speaker verification did not complete successfully. No generated-voice match result is available."
        case .consent(.invalidRecord): return "The voice consent record could not be verified. Checks may be incomplete."
        case .consent(.cancelled): return "The request was stopped. Checks may be incomplete."
        case .consent(let error): return RewriteSession.refusal(error)
        case .provider(let error):
            switch error {
            case .network: return "The provider request failed because of a connection problem. Checks may be incomplete."
            case .malformedResponse: return "The provider returned an unreadable response. Checks may be incomplete."
            case .cancelled: return "The request was stopped. Checks may be incomplete."
            case .invalidAlignment: return "The take's word timing could not be validated."
            case .invalidAudio: return "The take's audio could not be validated."
            case .speakerMismatch:
                return "The speaker verification did not complete successfully. No generated-voice match result is available."
            case .unauthorized, .subscriptionRequired, .featureUnavailable, .voiceAccessDenied, .modelAccessDenied:
                return RewriteSession.refusal(error)
            case .permissionMissing: return "The ElevenLabs key is missing a required permission. Your edits are saved."
            case .missingKey: return "An ElevenLabs key is required. Your edits are saved."
            case .quotaExceeded: return "ElevenLabs says this account is out of credit or over its quota. Your edits are saved."
            case .rateLimited: return "ElevenLabs is rate limiting this request. Nothing is retried automatically."
            case .providerFailure(let status): return "ElevenLabs could not complete the request (\(status)). Checks may be incomplete."
            case .unsupportedFormat: return "The audio format is not supported for this request."
            case .unsupportedModel, .unsupportedEndpoint: return "The selected speech model or operation is not supported."
            case .responseTooLarge: return "The provider response was too large to process. Checks may be incomplete."
            case .invalidInput: return "The request inputs could not be validated."
            case .consentRequired: return "Voice consent could not be verified for this request. Your edits are saved."
            case .planUnavailable: return "This request is unavailable on the current provider plan."
            case .noVoiceSlots: return "The ElevenLabs account has no available voice slots."
            }
        }
    }

    static func leftOut(_ row: VoiceLabTakeRow, number: Int) -> String? {
        if row.voiceCheck == .waiting { return "Take \(number) · waiting for the voice check" }
        return reason(for: row).map { "Take \(number): " + $0 + " Left out." }
    }
}

extension RewriteSession {
    func playTake(phrase: Int) async {
        guard current, let takePlan, takePlan.stillCurrent else { return }
        editor.transport("k")
        await takePlan.play(phrase: phrase)
    }
    func playTake(_ take: UUID, phrase: Int) async {
        guard current, let takePlan, takePlan.stillCurrent else { return }
        editor.transport("k")
        await takePlan.play(take: take, phrase: phrase)
    }
    var takesBusy: Bool { takePlan.map { $0.preparing || $0.generating || $0.publishing || $0.preparingVideo } ?? false }
    var usableTakeCount: Int { takePlan.map { $0.canAccept ? $0.phrases.filter { $0.selected?.row.selectable == true }.count : 0 } ?? 0 }
    var takeSendLine: String {
        if let phrase = takeQuotePhrase { return "Sends only phrase \(phrase + 1) and a short audio check to ElevenLabs with your key. No video." }
        return "Sends the included phrases and a short audio check to ElevenLabs with your key. No video."
    }
    var takeSpendLine: String {
        guard let takePlan else { return "Nothing paid yet." }
        let count = Int(takePlan.spent.units)
        guard count > 0 else { return "Nothing paid yet." }
        let cost = takePlan.spent.usd.map { " · " + VoiceLabCostPresentation.format($0) } ?? " · cost unavailable"
        return "Made \(count) \(count == 1 ? "take" : "takes")\(cost) on your ElevenLabs account."
    }
    func pricedTakeAction(phrase: Int? = nil) -> PanelAction? {
        guard let plan = takePlan, plan.stillCurrent, !takesBusy, takeQuotePhrase == phrase,
              let quoteID = plan.approvalID, let cost = plan.cost else { return nil }
        let verb = phrase == nil ? "Make Takes" : "Try another"
        let title: String = switch cost {
        case .inline: VoiceLabCostPresentation.buttonTitle(verb, kind: cost)
        case .confirm: verb + "…"
        }
        return PanelAction(id: "takeQuote-\(quoteID)", title: title, priced: true) { [weak self, weak plan] in
            guard let self, let plan, current, takePlan === plan, plan.stillCurrent, plan.approvalID == quoteID, !takesBusy else { return }
            if case .confirm(let copy) = cost {
                let confirmID = "approveTakeQuote-\(quoteID)"
                task.ask(PanelConfirm(question: takeSendLine + "\n" + copy,
                    cancel: PanelAction(id: "cancelTakeQuote", title: "Keep Working") { [weak self] in self?.task.dismissConfirm() },
                    confirm: PanelAction(id: confirmID, title: verb + " · billed to your key", priced: true) { [weak self, weak plan] in
                        guard let self, let plan, task.confirm?.confirm.id == confirmID else { return }
                        task.dismissConfirm()
                        startTakes(plan, phrase: phrase, quoteID: quoteID)
                    }))
            } else { startTakes(plan, phrase: phrase, quoteID: quoteID) }
        }
    }
    private func startTakes(_ plan: ClipTakePlan, phrase: Int?, quoteID: UUID) {
        guard current, takePlan === plan, plan.stillCurrent, !takesBusy, plan.approvalID == quoteID else { return }
        takesTask = Task { [weak self, weak plan] in
            guard let self, let plan, current, takePlan === plan else { return }
            if let phrase { await plan.tryAnother(phrase: phrase, approved: true, quoteID: quoteID) }
            else { await plan.start(approved: true, quoteID: quoteID) }
        }
    }
    func priceAnotherTake(phrase: Int) {
        guard current, let plan = takePlan, !takesBusy else { return }
        focusedTakePhrase = phrase; takeQuotePhrase = phrase
        takesTask = Task { [weak self, weak plan] in
            guard let self, let plan, current, takePlan === plan else { return }
            await plan.prepareAnother(phrase: phrase)
        }
    }
    func selectTake(number: Int) {
        guard let plan = takePlan, plan.phrases.indices.contains(focusedTakePhrase),
              let take = plan.phrases[focusedTakePhrase].takes.first(where: { $0.number == number }) else { return }
        _ = plan.select(take: take.id, phrase: focusedTakePhrase)
    }
    func moveTakePhrase(backward: Bool) {
        guard let plan = takePlan, !plan.phrases.isEmpty else { return }
        plan.stopAudition()
        focusedTakePhrase = min(plan.phrases.count - 1, max(0, focusedTakePhrase + (backward ? -1 : 1)))
        editor.announce("Phrase \(focusedTakePhrase + 1) of \(plan.phrases.count). " + plan.phrases[focusedTakePhrase].takeDetail)
    }
    func stopTakes() {
        guard let plan = takePlan else { return }
        takesTask = Task { await plan.stop() }
    }
}

extension ClipTakePlan.Phrase {
    var takeDetail: String {
        switch status {
        case .generating(let message), .stopped(let message): return message
        case .failed(let message):
            if message == "These takes didn't sound right. Edit the words or try again." {
                return "No usable take. Review the reasons below."
            }
            return message
        case .waiting: return "Waiting. Nothing sent for this phrase."
        case .ready: break
        }
        guard let selected, selected.row.selectable, let length = selected.length else {
            return takes.isEmpty ? "No take selected." : "No usable take selected. Review the reasons below."
        }
        let duration = String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), length)
        if selected.fits { return "Take \(selected.number) · \(duration) · fits" }
        let difference = length - originalLength
        let delta = String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), abs(difference))
        return "Take \(selected.number) · \(duration) · \(delta) \(difference < 0 ? "shorter" : "longer"). Choose video duration below."
    }
}

@MainActor struct DirectorTakeRows: View {
    static let makeVoiceTitle = "Make Your Voice"
    @Bindable var session: RewriteSession
    @Bindable var generation: RewriteGenerationSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if generation.voices.isEmpty {
                Text("No voice yet").font(VCType.callout.font())
                if session.editor.app.voiceLabSession.voicesUnavailable(projectLanguage: session.project.transcript?.language) {
                    Text(VoiceLabSession.languageUnavailableCopy)
                } else {
                    Button(Self.makeVoiceTitle) { session.editor.openVoiceJob() }
                    Button("Refresh Voices") { Task { await generation.discover(language: session.project.transcript?.language ?? "en") } }
                }
            } else {
                Picker("Voice", selection: Binding(get: { generation.selectedVoiceID ?? "" }, set: { generation.chooseVoice($0) })) {
                    ForEach(generation.voices) { Text($0.voiceName).tag($0.id) }
                }
                .disabled(session.takesBusy || session.hasPaidTakes)
                Picker("Speech model", selection: Binding(get: { generation.selectedModelID ?? "" }, set: { generation.chooseModel($0) })) {
                    ForEach(generation.models, id: \.id) { Text($0.name).tag($0.id) }
                }
                // After a run the model still changes for Try another; the takes already made keep theirs.
                .disabled(session.takesBusy || (session.hasPaidTakes && session.takePlan?.stillCurrent != true))
            }
            if let plan = session.takePlan {
                ForEach(plan.phrases) { phrase in phraseRow(phrase, plan: plan) }
                if plan.preparing { ProgressView("Preparing price…").controlSize(.small) }
                if !plan.problem.isEmpty { Text(plan.problem).foregroundStyle(DesignValues.color("status.warning")) }
                Text(session.takeSpendLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            if !generation.problem.isEmpty { Text(generation.problem).foregroundStyle(DesignValues.color("status.warning")) }
            RewriteSpeechContextReviewView(session: session)
            Button("Review Changes") { session.takeRowsShown = false; session.showProposal() }.buttonStyle(.plain)
        }
        .font(VCType.callout.font())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain).accessibilityLabel("Phrase takes")
        .onChange(of: session.editor.app.bool("voiceLab.providerConsent.elevenlabs")) { _, _ in generation.inputsChanged() }
        .onChange(of: session.editor.app.voiceLabSession.records) { _, _ in generation.inputsChanged() }
        .onDisappear { session.takePlan?.stopAudition() }
    }
    private func phraseRow(_ phrase: ClipTakePlan.Phrase, plan: ClipTakePlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if phrase.selected?.row.selectable == true, !session.takesBusy {
                    Button {
                        session.focusedTakePhrase = phrase.id
                        Task { await session.playTake(phrase: phrase.id) }
                    } label: {
                        Image(systemName: plan.audition.isPlaying && plan.audition.takeId == phrase.selectedID ? "pause.fill" : "play.fill")
                            .frame(width: 28, height: 28)
                    }.buttonStyle(.plain).accessibilityLabel("\(plan.audition.isPlaying && plan.audition.takeId == phrase.selectedID ? "Pause" : "Play") phrase \(phrase.id + 1)")
                        .help(phrase.selected?.fits == true ? "Listen to the selected fitting take." : "Listen to the checked take. Its timing must fit before it can be used.")
                }
                Text("“" + phrase.text + "”").frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                ForEach(phrase.takes) { take in
                    if take.row.selectable, !session.takesBusy {
                        Button(String(take.number)) {
                            session.focusedTakePhrase = phrase.id
                            _ = plan.select(take: take.id, phrase: phrase.id)
                        }
                        .buttonStyle(.plain).frame(width: 24, height: 24)
                        .background(phrase.selectedID == take.id ? DesignValues.color("bg.selectedRow") : .clear, in: .rect(cornerRadius: 4))
                        .accessibilityLabel("Phrase \(phrase.id + 1), take \(take.number), \(take.fits ? "fits" : "timing change required")")
                        .help(take.fits ? "Select this checked take. It fits the phrase." : "This take passed checks but does not fit. Changed-duration video is not available in this build.")
                        .accessibilityAddTraits(phrase.selectedID == take.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                Text(phrase.takeDetail).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
            if let best = phrase.bestMeasured, phrase.takes.filter({ $0.row.selectable }).count > 1,
               phrase.selectedID == best.id {
                Text("Best match").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            ForEach(TakeFailurePresentation.shortSpeechSummary(phrase.takes.map(\.row), selected: phrase.selectedID), id: \.self) { copy in
                Text(copy).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
            ForEach(phrase.takes.filter { !$0.row.selectable }) { take in
                if let copy = TakeFailurePresentation.leftOut(take.row, number: take.number) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if take.row.audio != nil, !session.takesBusy {
                            let playing = plan.audition.isPlaying && plan.audition.takeId == take.id
                            Button {
                                session.focusedTakePhrase = phrase.id
                                Task { await session.playTake(take.id, phrase: phrase.id) }
                            } label: {
                                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(playing ? "Pause" : "Play") phrase \(phrase.id + 1), take \(take.number)")
                            .help("Listen to this take. It stays left out.")
                        }
                        Text(copy).font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning"))
                    }
                }
            }
            VideoDurationChoiceView(availability: plan.videoAvailability(phrase: phrase.id), selection: phrase.videoChoice,
                busy: session.takesBusy) { choice in
                    guard plan.chooseVideo(choice, phrase: phrase.id) else { return }
                    Task { await plan.prepareVideoChoices() }
                }
            if plan.preparingVideo { ProgressView("Preparing video duration…").controlSize(.small) }
            if !session.takesBusy, plan.spent.units > 0 || session.acceptedSpeechContext?.targetPhraseID == phrase.id {
                if let action = session.pricedTakeAction(phrase: phrase.id) {
                    Text(session.takeSendLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    PanelButton(action: action, kind: .ghost)
                } else {
                    Button(phrase.takes.isEmpty ? "Try Again…" : "Try another…") { session.priceAnotherTake(phrase: phrase.id) }
                        .buttonStyle(.plain).help("Prepare this phrase's price. Nothing is sent until you approve it.")
                }
            }
            if session.canReviewSpeechContext(phrase: phrase) {
                Button("Use surrounding sentence") { session.reviewSpeechContext(phrase: phrase.id) }
                    .disabled(session.takesBusy)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(session.focusedTakePhrase == phrase.id ? DesignValues.color("bg.selectedRow") : .clear, in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .contain).accessibilityLabel("Phrase \(phrase.id + 1) of \(plan.phrases.count)")
        .columnLayoutEvidence("voice.phrase.\(phrase.id)", text: phrase.takeDetail)
        .onTapGesture { session.focusedTakePhrase = phrase.id }
    }
}
