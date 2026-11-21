import SwiftUI
import VoxClipCore

@MainActor struct RewriteLipsyncControls: View {
    @Bindable var session: RewriteLipsyncSession
    let phrase: Int
    let busy: Bool
    let play: @MainActor () -> Void
    let changed: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            Text("Lip sync").font(VCType.callout.font()).fontWeight(.medium)
            if let state = session.states[phrase] {
                switch state {
                case .running(let started, let progress):
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Lip syncing on fal.ai · \(Self.elapsed(context.date.timeIntervalSince(started)))")
                    }
                    ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
                        .accessibilityLabel("Lip sync progress, phrase \(phrase + 1)")
                    Button("Cancel") { session.cancel(phrase); changed() }
                        .accessibilityIdentifier("lipsync-cancel-\(phrase)")
                        .accessibilityLabel(Self.cancelLabel(phrase))
                    Text("Usually under a minute. You can keep choosing takes for other phrases.")
                case .done(let seconds, let price):
                    Text("✓ Lip synced · \(Self.elapsed(seconds))")
                    HStack(spacing: VCTokens.spacingGroupGap) {
                        Button("▶ Play", action: play)
.accessibilityLabel(Self.playLabel(phrase))
                            .accessibilityIdentifier("lipsync-play-\(phrase)")
                        Button("Undo") {
                            session.undo(phrase); changed()
                            Task { await session.refresh() }
                        }.accessibilityLabel(Self.undoLabel(phrase))
                            .accessibilityIdentifier("lipsync-undo-\(phrase)")
                    }
                    Text("\(price) on your fal.ai account. Undo keeps your original video for this phrase.")
                    if session.applied[phrase]?.result.colorWarning == true {
                        Text("The lip-sync clip's colours differ slightly.").foregroundStyle(DesignValues.color("status.warning"))
                    }
                case .failed:
                    Text(session.failureLine(phrase) ?? "").foregroundStyle(DesignValues.color("status.warning"))
                    failedActions
                case .cancelled(let price):
                    Text("Lip sync cancelled. fal.ai may still charge \(price). Your original video is kept.")
                    approval(retry: true)
                }
            } else { approval(retry: false) }
            if !session.problem.isEmpty { Text(session.problem).foregroundStyle(DesignValues.color("status.warning")) }
        }
        .font(VCType.small.font()).buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain).accessibilityLabel("Lip sync, phrase \(phrase + 1)")
        .columnLayoutEvidence("voice.lipsync.\(phrase)", text: buttonLabels.joined(separator: "\n"))
    }

    @ViewBuilder private func approval(retry: Bool) -> some View {
        if !session.keyAvailable {
            Text("Lip sync needs your fal.ai key.")
            Button("Open Settings → Voice Lab") { openVoxClipSettings(pane: "voiceLab") }
                .accessibilityLabel(Self.settingsLabel)
        } else if let offer = currentOffer {
            if !session.consentAccepted { Text(RewriteLipsyncSession.firstUse) }
            if let warning = session.capWarning(for: offer) { Text(warning).foregroundStyle(DesignValues.color("status.warning")) }
            if offer.free {
                // The click gets back the result already paid for these takes: nothing is sent, nothing charged.
                Text(RewriteLipsyncSession.freeLine(phrases: 1))
            } else {
                let seconds = offer.windows.reduce(0) { $0 + $1.uploadSeconds(sampleRate: offer.request.timeline.sampleRate) }
                let duration = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
                Text("Uploads this phrase's \(duration) s of video and its new audio to fal.ai (sync-3) with your key. Exports say “Lip movement generated with AI.”")
            }
            let verb = retry ? "Try Again" : "Lip Sync"
            let price = offer.charge
            // Shown only while it can act: takes running or Use Takes waiting hide it (design.md: no disabled buttons).
            if !busy, !session.usingTakes {
                Button("\(verb) · \(price)") { session.press(offer); changed() }
                    .accessibilityIdentifier("lipsync-approve-\(phrase)")
                    .accessibilityLabel(Self.approveLabel(verb: verb, phrase: phrase, price: price))
            }
        } else { notReady }
    }

    /// The phrase's offer, while it is still current: one made over takes that changed since is never clickable (the rows
    /// refresh it when they see it go stale).
    private var currentOffer: RewriteLipsyncSession.Offer? { session.offers[phrase].flatMap { $0.isCurrent() ? $0 : nil } }

    /// No offer for this phrase now: being prepared, or why not, with Prepare Lip Sync Again when making it failed.
    @ViewBuilder private var notReady: some View {
        if session.refreshing { ProgressView("Preparing lip-sync price…").controlSize(.small) }
        else if session.offersFailed || session.offers[phrase] != nil {
            if session.offers[phrase] != nil { Text("The takes changed since this price was made.") }
            Button("Prepare Lip Sync Again") { Task { await session.refresh() } }
                .accessibilityIdentifier("lipsync-prepare-\(phrase)")
        } else if session.problem.isEmpty {
            Text("Lip sync isn't ready for this part. Choose a passing take and its video duration.")
        }
    }

    /// A stopped row's actions (`RewriteLipsyncSession.failedActions`): each one can succeed. A retry needs the phrase's
    /// fresh offer; without one the row says why (or prepares it again).
    @ViewBuilder private var failedActions: some View {
        let actions = session.failedActions(phrase)
        let offer = currentOffer
        if !session.keyAvailable {
            Text("Lip sync needs your fal.ai key.")
            Button("Open Settings → Voice Lab") { openVoxClipSettings(pane: "voiceLab") }.accessibilityLabel(Self.settingsLabel)
        } else if !busy, !session.usingTakes {
            VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
                ForEach(actions.indices, id: \.self) { index in
                    action(actions[index], offer: offer)
                }
            }
            if offer == nil, actions.contains(where: Self.needsOffer) { notReady }
        }
    }

    @ViewBuilder private func action(_ action: RewriteLipsyncSession.FailedAction, offer: RewriteLipsyncSession.Offer?) -> some View {
        switch action {
        case .keepOriginal:
            Button("Keep Original Video") { session.keepOriginal(phrase); changed() }
                .accessibilityIdentifier("lipsync-keep-\(phrase)").accessibilityLabel(Self.keepLabel(phrase))
        case .settings:
            Button("Open Settings → Voice Lab") { openVoxClipSettings(pane: "voiceLab") }.accessibilityLabel(Self.settingsLabel)
        case .checkedFal:
            if let offer {
                let title = Self.title(action, offer: offer)
                Button(title) { session.pressAfterCheckingFal(offer); changed() }
                .accessibilityIdentifier("lipsync-checked-\(phrase)")
                .accessibilityLabel(Self.label(action, phrase: phrase, offer: offer))
            }
        default:
            if let offer {
                let title = Self.title(action, offer: offer)
                Button(title) { session.press(offer); changed() }
                    .accessibilityIdentifier("lipsync-approve-\(phrase)")
                    .accessibilityLabel(Self.label(action, phrase: phrase, offer: offer))
            }
        }
    }

    static func needsOffer(_ action: RewriteLipsyncSession.FailedAction) -> Bool {
        switch action { case .keepOriginal, .settings: false; default: true }
    }

    /// A stopped row's button title: what it does and what it costs.
    static func title(_ action: RewriteLipsyncSession.FailedAction, offer: RewriteLipsyncSession.Offer) -> String {
        switch action {
        case .tryAgain(let free): "Try Again · \(price(offer, free: free))"
        case .lipSyncAgain: "Lip Sync Again · \(offer.charge)"
        case .checkAgain: "Check Again · free"
        case .checkedFal: "I Checked fal.ai · Lip Sync Again · \(offer.charge)" + (offer.free ? "" : " (fal.ai may charge twice)")
        case .settings: "Open Settings → Voice Lab"
        case .keepOriginal: "Keep Original Video"
        }
    }

    private static func label(_ action: RewriteLipsyncSession.FailedAction, phrase: Int, offer: RewriteLipsyncSession.Offer) -> String {
        switch action {
        case .tryAgain(let free): approveLabel(verb: "Try Again", phrase: phrase, price: price(offer, free: free))
        case .lipSyncAgain: approveLabel(verb: "Lip Sync Again", phrase: phrase, price: offer.charge)
        case .checkAgain: approveLabel(verb: "Check Again", phrase: phrase, price: "free")
        case .checkedFal: approveLabel(verb: "I checked fal.ai, lip sync again", phrase: phrase, price: offer.charge + (offer.free ? "" : ", fal.ai may charge twice"))
        case .settings: settingsLabel
        case .keepOriginal: keepLabel(phrase)
        }
    }

    /// The VoiceOver names of the buttons this state shows, in order (the layout audit's evidence).
    private var buttonLabels: [String] {
        func approval(_ verb: String) -> [String] {
            if !session.keyAvailable { return [Self.settingsLabel] }
            return currentOffer.map { [Self.approveLabel(verb: verb, phrase: phrase, price: $0.charge)] } ?? []
        }
        switch session.states[phrase] {
        case .running: return [Self.cancelLabel(phrase)]
        case .done: return [Self.playLabel(phrase), Self.undoLabel(phrase)]
        case .failed:
            if !session.keyAvailable { return [Self.settingsLabel] }
            let offer = currentOffer
            return session.failedActions(phrase).compactMap { action in
                if action == .keepOriginal { return Self.keepLabel(phrase) }
                if action == .settings { return Self.settingsLabel }
                return offer.map { Self.label(action, phrase: phrase, offer: $0) }
            }
        case .cancelled: return approval("Try Again")
        case nil: return approval("Lip Sync")
        }
    }
    static let settingsLabel = "Open Settings, Voice Lab, add fal.ai key"
    static func keepLabel(_ phrase: Int) -> String { "Keep original video, phrase \(phrase + 1)" }
    /// "free" for a Try Again that re-imports the kept paid result, else what the offer's click charges ("free" when every
    /// window gets back a result already paid for).
    static func price(_ offer: RewriteLipsyncSession.Offer, free: Bool) -> String { free ? "free" : offer.charge }
    static func cancelLabel(_ phrase: Int) -> String { "Cancel lip sync, phrase \(phrase + 1)" }
    static func playLabel(_ phrase: Int) -> String { "Play lip-synced phrase \(phrase + 1)" }
    static func undoLabel(_ phrase: Int) -> String { "Undo lip sync, phrase \(phrase + 1), keep original video" }
    static func approveLabel(verb: String, phrase: Int, price: String) -> String {
        "\(verb), phrase \(phrase + 1), \(price.replacingOccurrences(of: "≈ ", with: "approximately ")), upload video and audio to fal.ai sync-3"
    }

    static func elapsed(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
