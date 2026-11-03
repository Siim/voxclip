import SwiftUI
import VoxClipCore

@MainActor struct RewriteLipsyncControls: View {
    @Bindable var session: RewriteLipsyncSession
    let phrase: Int
    let busy: Bool
    let play: @MainActor () -> Void
    let changed: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    HStack(spacing: 12) {
                        Button("▶ Play", action: play).accessibilityLabel(Self.playLabel(phrase))
                            .accessibilityIdentifier("lipsync-play-\(phrase)")
                        Button("Undo") {
                            session.undo(phrase); changed()
                            Task { await session.refresh() }
                        }.accessibilityLabel(Self.undoLabel(phrase))
                            .accessibilityIdentifier("lipsync-undo-\(phrase)")
                    }
                    Text("≈ \(price) on your fal.ai account. Undo keeps your original video for this phrase.")
                    if session.applied[phrase]?.result.colorWarning == true {
                        Text("The lip-sync clip's colours differ slightly.").foregroundStyle(DesignValues.color("status.warning"))
                    }
                case .failed(let reason, let price, let mayBill):
                    Text("Couldn't lip sync phrase \(phrase + 1): \(reason)" + (mayBill ? " fal.ai may still charge ≈ \(price)." : " No upload or charge."))
                        .foregroundStyle(DesignValues.color("status.warning"))
                    approval(retry: true)
                    Text("or keep the original video")
                case .cancelled(let price):
                    Text("Lip sync cancelled. fal.ai may still charge ≈ \(price). Your original video is kept.")
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
        } else if let offer = session.offers[phrase] {
            if !session.consentAccepted { Text(RewriteLipsyncSession.firstUse) }
            if let warning = session.capWarning(for: offer) { Text(warning).foregroundStyle(DesignValues.color("status.warning")) }
            let seconds = offer.windows.reduce(0) { $0 + $1.seconds(sampleRate: offer.request.timeline.sampleRate) }
            let duration = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            Text("Uploads this phrase's \(duration) s of video and its new audio to fal.ai (sync-3) with your key. Exports say “Lip movement generated with AI.”")
            let verb = retry ? "Try Again" : "Lip Sync"
            Button("\(verb) · ≈ \(offer.price)") { session.start(offer); changed() }
                .accessibilityIdentifier("lipsync-approve-\(phrase)")
                .disabled(busy || session.usingTakes)
                .accessibilityLabel(Self.approveLabel(verb: verb, phrase: phrase, price: offer.price))
        } else if session.refreshing { ProgressView("Preparing lip-sync price…").controlSize(.small) }
        else { Text("Lip sync isn't ready for this part. Choose a passing take and its video duration.") }
    }

    /// The VoiceOver names of the buttons this state shows, in order (the layout audit's evidence).
    private var buttonLabels: [String] {
        func approval(_ verb: String) -> [String] {
            if !session.keyAvailable { return [Self.settingsLabel] }
            return session.offers[phrase].map { [Self.approveLabel(verb: verb, phrase: phrase, price: $0.price)] } ?? []
        }
        switch session.states[phrase] {
        case .running: return [Self.cancelLabel(phrase)]
        case .done: return [Self.playLabel(phrase), Self.undoLabel(phrase)]
        case .failed, .cancelled: return approval("Try Again")
        case nil: return approval("Lip Sync")
        }
    }
    static let settingsLabel = "Open Settings, Voice Lab, add fal.ai key"
    static func cancelLabel(_ phrase: Int) -> String { "Cancel lip sync, phrase \(phrase + 1)" }
    static func playLabel(_ phrase: Int) -> String { "Play lip-synced phrase \(phrase + 1)" }
    static func undoLabel(_ phrase: Int) -> String { "Undo lip sync, phrase \(phrase + 1), keep original video" }
    static func approveLabel(verb: String, phrase: Int, price: String) -> String {
        "\(verb), phrase \(phrase + 1), approximately \(price), upload video and audio to fal.ai sync-3"
    }

    static func elapsed(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
