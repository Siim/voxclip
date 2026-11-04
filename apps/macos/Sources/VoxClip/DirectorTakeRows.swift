import SwiftUI
import VoxClipCore

enum TakeFailurePresentation {
    static func joinAdvisory(_ row: VoiceLabTakeRow, number: Int) -> String? {
        guard row.hasJoinAdvisory, let audio = row.audio, let seams = row.qa?.joinSeams, !seams.isEmpty else { return nil }
        let duration = String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), Double(audio.fit.plan.outputFrames) / Double(audio.sampleRate))
        let side = seams.count > 1 ? "either" : seams[0].side.rawValue
        return "Take \(number) · \(duration) · The join may sound uneven (\(side) side). Listen before using."
    }
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
        // A take that failed before the checks still has its paid audio, which plays unchecked.
        let name = row.audio == nil && row.generated != nil ? "Take \(number) · not checked: " : "Take \(number): "
        return reason(for: row).map { name + $0 + " Left out." }
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
        let indices = takeQuotePhrase.map { [$0] } ?? takePlan?.phrases.map(\.id) ?? []
        let paces = indices.compactMap { index -> String? in
            guard let pace = takePlan?.phrasePace(index), pace != 1 else { return nil }
            return "Phrase \(index + 1) at \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), pace))× pace."
        }.joined(separator: " ")
        let sent = if let phrase = takeQuotePhrase { "Sends only phrase \(phrase + 1) and a short audio check to ElevenLabs with your key. No video." }
            else { "Sends the included phrases and a short audio check to ElevenLabs with your key. No video." }
        return paces.isEmpty ? sent : sent + " " + paces
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
        let verb = phrase.map { index in
            wordingFit.measured?.phrase == index && wordingFit.measured?.text != nil ? "Make Take" :
                Self.firstTakeVerb(hasTakes: plan.phrases.indices.contains(index) && !plan.phrases[index].takes.isEmpty)
        } ?? "Make Takes"
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
        wordingFit.measured = nil
        // The approved price covers automatic fixes of stuck phrases up to its cap (RewriteAutoFix.swift).
        if phrase == nil { armAutoFix(plan) }
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
    /// The phrase card's one status line, saying what happens next (design.md R2): the resolver's live line, the stuck
    /// phrase's reason, "Takes start after you approve the price." before payment, "Making takes…" while they run.
    func phraseStatus(_ phrase: ClipTakePlan.Phrase, plan: ClipTakePlan) -> String {
        if autoFix.running, let line = autoFix.lines[phrase.id] { return line }
        if phrase.leftOut { return "Keeps your original words. Its takes stay listed." }
        if let reason = stuckReason(phrase, plan: plan) {
            if case .length(_, _, _, _, _, true) = reason { return phrase.takeDetail }
            return Self.stuckSentence(reason, phrase: phrase.id + 1)
        }
        switch phrase.status {
        case .waiting:
            return plan.generating ? "Making takes…" : phrase.takes.isEmpty ? "Takes start after you approve the price." : "A new take starts after you approve its price."
        case .generating: return "Making takes…"
        default: return phrase.takeDetail
        }
    }
    func selectTake(number: Int) {
        guard let plan = takePlan, plan.phrases.indices.contains(focusedTakePhrase),
              let take = plan.phrases[focusedTakePhrase].takes.first(where: { $0.number == number }) else { return }
        let phrase = focusedTakePhrase
        if plan.phrases[phrase].selectedID == take.id { return }
        mutateLipsync(phrase: phrase) { _ = plan.select(take: take.id, phrase: phrase) }
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
        let effectivePace = selected.row.receipt?.pace ?? selected.row.quote?.synthesis.pace ?? 1
        let pace = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), effectivePace)
        let paceLabel = (VoiceLabNaturalPacing.NATURAL_PACE_MIN...VoiceLabNaturalPacing.NATURAL_PACE_MAX).contains(effectivePace) ? "natural pace" : "pace"
        if selected.fits { return "Take \(selected.number) · \(duration) · fits · \(paceLabel) \(pace)×" }
        let difference = length - originalLength
        let delta = String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), abs(difference))
        return "Take \(selected.number) · \(duration) · \(delta) \(difference < 0 ? "shorter" : "longer") · \(paceLabel) \(pace)×"
    }
}

@MainActor struct DirectorTakeRows: View {
    static let makeVoiceTitle = "Make Your Voice"
    static let rewriteModelLabel = "Eleven v4 · audio tags"
    static func speechModelName(_ model: VoiceLabModel) -> String {
        switch model.id {
        case "eleven_v3": "Eleven v3 · audio tags"
        case "eleven_v4": "Eleven v4 · audio tags"
        default: model.name
        }
    }
    @Bindable var session: RewriteSession
    @Bindable var generation: RewriteGenerationSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.rewriteModelLabel)
                .accessibilityLabel("Speech model: " + Self.rewriteModelLabel)
            if generation.voices.isEmpty {
                Text("No voice yet").font(VCType.callout.font())
                if session.editor.app.voiceLabSession.voicesUnavailable(projectLanguage: session.project.transcript?.language) {
                    Text(VoiceLabSession.languageUnavailableCopy)
                } else {
                    Button(Self.makeVoiceTitle) { session.editor.openVoiceJob() }
                    Button("Refresh Voices") { Task { await generation.discover(language: session.project.transcript?.language ?? "en") } }
                }
            } else if session.takesBusy || session.hasPaidTakes || generation.voices.count == 1 {
                // The voice can't change now (takes made with it are kept): its name, not a disabled picker.
                Text("Voice: " + (generation.voices.first { $0.id == generation.selectedVoiceID }?.voiceName ?? generation.voices[0].voiceName))
            } else {
                Picker("Voice", selection: Binding(get: { generation.selectedVoiceID ?? "" }, set: { generation.chooseVoice($0) })) {
                    ForEach(generation.voices) { Text($0.voiceName).tag($0.id) }
                }
            }
            if let plan = session.takePlan {
                ForEach(plan.phrases) { phrase in phraseRow(phrase, plan: plan) }
                if let disclosure = plan.lipsync.allDisclosure {
                    Text("Lip Sync All\n" + disclosure).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Lip Sync All approval. " + disclosure)
                }
                Text(AudioTagPhrase.explanation).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
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
        .onChange(of: session.editor.app.connectorReadinessRevision) { _, _ in Task { await session.takePlan?.lipsync.refresh() } }
        .onChange(of: session.editor.app.string("voiceLab.monthlyCapUsd.fal")) { _, _ in Task { await session.takePlan?.lipsync.refresh() } }
        .task(id: session.takePlan?.phrases.map { "\($0.selectedID?.uuidString ?? "")-\($0.videoChoice?.rawValue ?? "")-\($0.text)" }) {
            await session.takePlan?.lipsync.refresh()
        }
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
                AudioTagPhrase(text: phrase.text, tags: session.shownAudioTags(phrase), phrase: phrase.id + 1,
                    insertionBoundary: phrase.window.leftBridgeWordIds.compactMap { id in
                        session.project.transcript?.words.first { $0.id == id }?.text
                    }.flatMap { EditingPrimitives.splitWords($0) }.count,
                    omitted: !VoiceLabAudioTags.supports(session.currentSynthesisModel ?? "")) {
                        session.updateAudioTags($0, phrase: phrase)
                    }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                ForEach(phrase.takes) { take in
                    if take.row.selectable, !take.row.requiresJoinAdvisoryAcceptance, !session.takesBusy {
                        Button(String(take.number)) {
                            session.focusedTakePhrase = phrase.id
                            if phrase.selectedID != take.id {
                                session.mutateLipsync(phrase: phrase.id) { _ = plan.select(take: take.id, phrase: phrase.id) }
                            }
                        }
                        .buttonStyle(.plain).frame(width: 24, height: 24)
                        .background(phrase.selectedID == take.id ? DesignValues.color("bg.selectedRow") : .clear, in: .rect(cornerRadius: 4))
                        .accessibilityLabel("Phrase \(phrase.id + 1), take \(take.number), \(take.fits ? "fits" : "timing change required")\(phrase.beforeExpression.contains(take.id) ? ", before expression" : "")")
                        .help(take.fits ? "Select this checked take. It fits the phrase." : "This take passed checks but changes the video's duration. Choose a video duration below.")
                        .accessibilityAddTraits(phrase.selectedID == take.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                Text(session.phraseStatus(phrase, plan: plan)).font(VCType.small.font())
                    .foregroundStyle(DesignValues.color(session.autoFix.lines[phrase.id] == nil ? "text.secondary" : "text.primary"))
                    .columnLayoutEvidence("voice.phrase.\(phrase.id).status", text: session.phraseStatus(phrase, plan: plan))
            }
            if let note = session.autoFix.expressionNote[phrase.id] {
                Text(note).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
            if let pace = plan.phrasePace(phrase.id), pace != 1 {
                Text("Next take at \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), pace))× pace")
                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            if let best = phrase.bestMeasured, phrase.takes.filter({ $0.row.selectable }).count > 1,
               phrase.selectedID == best.id {
                Text("Best match").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            ForEach(TakeFailurePresentation.shortSpeechSummary(phrase.takes.map(\.row), selected: phrase.selectedID), id: \.self) { copy in
                Text(copy).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
            ForEach(phrase.takes.filter { $0.row.hasJoinAdvisory }) { take in
                if let copy = TakeFailurePresentation.joinAdvisory(take.row, number: take.number) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(copy).font(VCType.callout.font()).foregroundStyle(DesignValues.color("status.warning"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Phrase \(phrase.id + 1), join advisory. \(copy)")
                        if !session.takesBusy {
                            HStack(spacing: 8) {
                                let playing = plan.audition.isPlaying && plan.audition.takeId == take.id
                                Button(playing ? "Pause" : "Play") {
                                    session.focusedTakePhrase = phrase.id
                                    Task { await session.playTake(take.id, phrase: phrase.id) }
                                }.buttonStyle(.plain).frame(minHeight: 22)
                                    .accessibilityLabel("\(playing ? "Pause" : "Play") phrase \(phrase.id + 1), take \(take.number), join advisory")
                                Button("Use anyway") {
                                    session.focusedTakePhrase = phrase.id
                                    session.mutateLipsync(phrase: phrase.id) { _ = plan.useAnyway(take: take.id, phrase: phrase.id) }
                                }.buttonStyle(.plain).frame(minHeight: 22)
                                    .accessibilityLabel("Use take \(take.number) anyway, phrase \(phrase.id + 1), accept join advisory")
                                    .modifier(PanelButtonEvidence(id: "useAnyway.\(phrase.id).\(take.number)", title: "Use anyway"))
                            }.font(VCType.callout.font())
                        }
                    }
                }
            }
            ForEach(phrase.takes.filter { !$0.row.selectable }) { take in
                if let copy = TakeFailurePresentation.leftOut(take.row, number: take.number) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if take.playable, !session.takesBusy {
                            let playing = plan.audition.isPlaying && plan.audition.takeId == take.id
                            Button {
                                session.focusedTakePhrase = phrase.id
                                Task { await session.playTake(take.id, phrase: phrase.id) }
                            } label: {
                                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(playing ? "Pause" : "Play") phrase \(phrase.id + 1), take \(take.number)\(take.notChecked ? ", not checked" : "")")
                            .help(take.notChecked ? "Listen to this take as ElevenLabs returned it. It was not checked and stays left out."
                                                  : "Listen to this take. It stays left out.")
                        }
                        Text(copy).font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning"))
                    }
                }
            }
            // Duration and lip sync appear once a passing take is selected; before that they could not act.
            if phrase.selected?.row.selectable == true, !phrase.leftOut {
                VideoDurationChoiceView(availability: plan.videoAvailability(phrase: phrase.id), selection: phrase.videoChoice,
                    busy: session.takesBusy) { choice in
                        guard choice != phrase.videoChoice else { return }
                        session.mutateLipsync(phrase: phrase.id) {
                            guard plan.chooseVideo(choice, phrase: phrase.id) else { return }
                            Task { await plan.prepareVideoChoices(); await plan.lipsync.refresh() }
                        }
                    }
            }
            if plan.preparingVideo { ProgressView("Preparing video duration…").controlSize(.small) }
            if plan.lipsync.enabled, phrase.selected?.row.selectable == true, phrase.videoChoice != nil {
                RewriteLipsyncControls(session: plan.lipsync, phrase: phrase.id, busy: session.takesBusy,
                    play: { session.playLipsync(phrase: phrase.id) }, changed: { session.showProposal() })
            }
            if !session.takesBusy, session.autoFix.choicesShown, session.takeNeedsWordingRecovery(phrase, plan: plan) {
                if session.wordingFit.measured?.phrase == phrase.id {
                    MeasuredWordingFitRow(session: session, plan: plan)
                }
                PhraseTimingRecovery(tooLong: (phrase.lengthDifference ?? 0) >= 0, priceAnyway: false) { action in
                    let ordinals = session.takePhraseOrdinals(phrase)
                    if case .original = action {
                        session.phraseTimingAction(.original, ordinals: ordinals)
                    } else if case .surrounding = action {
                        session.reviewSpeechContext(phrase: phrase.id)
                    } else {
                        session.phraseTimingAction(action, ordinals: ordinals)
                    }
                }
            }
            if !session.takesBusy, session.autoFix.choicesShown, plan.spent.units > 0 || session.acceptedSpeechContext?.targetPhraseID == phrase.id {
                if let action = session.pricedTakeAction(phrase: phrase.id) {
                    Text(session.takeSendLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    PanelButton(action: action, kind: .ghost)
                } else {
                    Button(RewriteSession.firstTakeVerb(hasTakes: !phrase.takes.isEmpty) + "…") { session.priceAnotherTake(phrase: phrase.id) }
                        .buttonStyle(.plain).help("Prepare this phrase's price. Nothing is sent until you approve it.")
                        .modifier(PanelButtonEvidence(id: "priceAnother.\(phrase.id)", title: RewriteSession.firstTakeVerb(hasTakes: !phrase.takes.isEmpty) + "…"))
                }
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(session.focusedTakePhrase == phrase.id ? DesignValues.color("bg.selectedRow") : .clear, in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .contain).accessibilityLabel("Phrase \(phrase.id + 1) of \(plan.phrases.count)")
        .columnLayoutEvidence("voice.phrase.\(phrase.id)", text: phrase.takeDetail)
        .onTapGesture { session.focusedTakePhrase = phrase.id }
    }
}
