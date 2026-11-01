import SwiftUI
import VoxClipCore

extension RewriteSession {
    var takesBusy: Bool { takePlan.map { $0.preparing || $0.generating || $0.publishing } ?? false }
    var usableTakeCount: Int { takePlan?.phrases.filter { $0.selected?.fits == true }.count ?? 0 }
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
        let verb = phrase == nil ? "Make Takes" : "Try Another"
        let title: String = switch cost {
        case .inline(let amount): amount.isEmpty ? verb : verb + " · " + (amount.hasPrefix("<") ? amount : "≈ " + amount)
        case .confirm: verb + "…"
        }
        return PanelAction(id: "takeQuote-\(quoteID)", title: title, priced: true) { [weak self, weak plan] in
            guard let self, let plan, current, takePlan === plan, plan.approvalID == quoteID, !takesBusy else { return }
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
        guard current, takePlan === plan, !takesBusy, plan.approvalID == quoteID else { return }
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
        case .generating(let message), .stopped(let message), .failed(let message): return message
        case .waiting: return "Waiting. Nothing sent for this phrase."
        case .ready: break
        }
        guard let selected, let length = selected.length else { return "Left out until a take fits." }
        let duration = String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), length)
        if selected.fits { return "Take \(selected.number) · \(duration) · fits" }
        let difference = length - originalLength
        let delta = String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), abs(difference))
        return "Take \(selected.number) · \(duration) · \(delta) \(difference < 0 ? "shorter" : "longer"). Edit the words or try another take."
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
                .disabled(session.takesBusy || session.hasPaidTakes)
            }
            if let plan = session.takePlan {
                ForEach(plan.phrases) { phrase in phraseRow(phrase, plan: plan) }
                if plan.preparing { ProgressView("Preparing price…").controlSize(.small) }
                if !plan.problem.isEmpty { Text(plan.problem).foregroundStyle(DesignValues.color("status.warning")) }
                Text(session.takeSpendLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            if !generation.problem.isEmpty { Text(generation.problem).foregroundStyle(DesignValues.color("status.warning")) }
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
                if phrase.selected != nil, !session.takesBusy {
                    Button {
                        session.focusedTakePhrase = phrase.id
                        Task { await plan.play(phrase: phrase.id) }
                    } label: {
                        Image(systemName: plan.audition.isPlaying && plan.audition.takeId == phrase.selectedID ? "pause.fill" : "play.fill")
                            .frame(width: 28, height: 28)
                    }.buttonStyle(.plain).accessibilityLabel("\(plan.audition.isPlaying && plan.audition.takeId == phrase.selectedID ? "Pause" : "Play") phrase \(phrase.id + 1)")
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
                        .accessibilityLabel("Phrase \(phrase.id + 1), take \(take.number)")
                        .accessibilityAddTraits(phrase.selectedID == take.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                Text(phrase.takeDetail).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
            if phrase.takes.filter({ $0.row.selectable }).count > 1,
               phrase.selectedID == phrase.takes.filter({ $0.row.selectable }).max(by: { ($0.row.score ?? 0) < ($1.row.score ?? 0) })?.id {
                Text("Best match").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            ForEach(phrase.takes.filter { !$0.row.selectable }) { take in
                Text("Take \(take.number) didn't pass the speech check. Left out.")
                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning"))
            }
            if phrase.selected?.fits != true, !phrase.takes.isEmpty {
                Text("Left out until a take fits. Changed-duration video is not available in this build.")
                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
            if !session.takesBusy, plan.spent.units > 0 {
                if let action = session.pricedTakeAction(phrase: phrase.id) {
                    Text(session.takeSendLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    PanelButton(action: action, kind: .ghost)
                } else {
                    Button(phrase.takes.isEmpty ? "Try Again…" : "Try Another…") { session.priceAnotherTake(phrase: phrase.id) }
                        .buttonStyle(.plain).help("Prepare this phrase's price. Nothing is sent until you approve it.")
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
