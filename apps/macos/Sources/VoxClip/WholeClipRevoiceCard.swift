import AVFoundation
import SwiftUI
import VoxClipCore

/// The Rewrite panel's "How should it sound?" card (design.md R2, ADR-R46, the approved mockup): Choose, Running, Review.
/// Every button acts; prices come from the pricing tables; nothing here is a sheet or an alert.
@MainActor struct WholeClipRevoiceCard: View {
    let model: EditorModel?

    var body: some View {
        if let rewrite = model?.openRewrite, let session = rewrite.wholeClip {
            WholeClipRevoiceContent(rewrite: rewrite, session: session)
        }
    }
}

@MainActor private struct SavedVoicePreview: View {
    let rewrite: RewriteSession
    @State private var playing = false
    @State private var failed = false

    var body: some View {
        PanelButton(action: PanelAction(id: "wholeClipPlaySavedVoice", title: playing ? "Stop Preview" : "Play Saved Voice") {
            failed = false; playing.toggle()
        }, kind: .bordered)
        .task(id: playing) {
            guard playing else { return }
            do {
                try await rewrite.previewSavedVoice { wav in
                    let player = try AVAudioPlayer(data: wav)
                    guard player.play() else { throw VoiceLabError.invalidAudio }
                    defer { player.stop() }
                    while player.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
                }
            } catch { if !Task.isCancelled { failed = true } }
            if !Task.isCancelled { playing = false }
        }
        if failed { Text("Couldn’t play the saved voice. Nothing was sent.").foregroundStyle(DesignValues.color("status.warning")) }
    }
}

@MainActor private struct WholeClipRevoiceContent: View {
    let rewrite: RewriteSession
    @Bindable var session: WholeClipRevoiceSession

    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            switch session.phase {
            case .choose: choose
            case .running: running
            case .review: review
            case .used: Text(session.usedVoiceOnly ? "✓ The whole clip's voice is in your clip, without lip sync. Undo takes it back."
                                                   : "✓ Whole clip revoiced and in your clip. Undo takes it back.")
                    .foregroundStyle(DesignValues.color("text.secondary"))
            case .stopped(let line): stopped(line)
            }
        }
        .font(VCType.callout.font())
        .padding(VCTokens.spacingCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { RoundedRectangle(cornerRadius: VCTokens.radiusMd).strokeBorder(DesignValues.color("line.default"), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How should it sound")
        .columnLayoutEvidence("director.wholeClip", text: evidence)
        // A fal.ai key saved in Settings, or a voice made or removed: the actions are derived again (the price, or Settings).
        .task(id: "\(rewrite.editor.app.connectorReadinessRevision):\(rewrite.editor.app.voiceLabSession.records.count)") {
            await session.refreshReadiness()
        }
    }

    private var quote: WholeClipRevoiceSession.Quote? { session.quote }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Voice").font(VCType.body.font(.semibold))
            if let quote {
                Text("Clip \(quote.clipNumber) · \(WholeClipRevoiceSession.clock(quote.clipSeconds)) · \(quote.spokenWords) words")
                    .foregroundStyle(DesignValues.color("text.secondary"))
            }
        }
    }

    @ViewBuilder private var choose: some View {
        if rewrite.wholeClipCompact { compact } else { full }
    }

    /// After the patch was picked: one row, so the whole clip stays findable and redoable.
    @ViewBuilder private var compact: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let action = rewrite.wholeClipInsteadAction() { PanelButton(action: action, kind: .bordered) }
            Spacer(minLength: 0)
        }
        if session.keyAvailable {
            Text("Says the whole clip again in one voice and lip syncs it. Sends the clip's new words to ElevenLabs and its video to fal.ai with your keys.")
                .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary")).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var full: some View {
        header
        if let reason = quote?.reason {
            VStack(alignment: .leading, spacing: 6) {
                Text(WholeClipRevoice.callout(reason)).fixedSize(horizontal: false, vertical: true)
                if let action = rewrite.wholeClipChipAction() {
                    ExpressionFlow(spacing: VCTokens.spacingChipGap) {
                        PanelButton(action: action, kind: .bordered)
                        if let fewer = rewrite.changeFewerWordsAction() { PanelButton(action: fewer, kind: .bordered) }
                    }
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignValues.color("bg.muted"), in: RoundedRectangle(cornerRadius: 6))
        }
        Text("How should it sound?").font(VCType.callout.font(.semibold))
        let replacing = rewrite.wholeClipReplacement != nil
        option(whole: false, title: "Only the changed phrases", price: quote?.patchUSD, available: !replacing,
               lines: [replacing ? RewriteReplacement.undoCopy : "Your recording stays. \(phrases) in your voice, joined to it."])
        option(whole: true, title: "The whole clip in one voice, with lip sync", price: quote?.wholeUSD,
               available: !replacing || quote != nil, lines: wholeLines)
        if let primary = rewrite.wholeClipPrimary() { PanelButton(action: primary, kind: .primary) }
        else if replacing {
            Button("Revoice Whole Clip") {}.disabled(true)
            Text(session.quoting ? "Checking whether the whole clip can be revoiced…" : RewriteReplacement.undoCopy)
                .foregroundStyle(DesignValues.color("text.secondary"))
        }
    }

    private var phrases: String { (quote?.phrases ?? 0) == 1 ? "1 phrase" : "\(quote?.phrases ?? 0) phrases" }

    private var wholeLines: [String] {
        guard let quote else { return [] }
        let voice = quote.voiceName + (quote.voiceNote.isEmpty ? "" : " (\(quote.voiceNote))")
        let seconds = WholeClipRevoiceSession.clock(quote.clipSeconds)
        let sends = "Sends the clip's new words to ElevenLabs (\(quote.voicePassUSD.map(VoiceLabCostPresentation.format) ?? "price unknown")), and its \(seconds) of video with the new audio to fal.ai \(WholeClipRevoice.Lipsync.standard.name) (\(quote.lipsyncUSD.map(VoiceLabCostPresentation.format) ?? "price unknown")), with your keys. Exports say “\(WholeClipRevoice.disclosureLine)”"
        let lines = ["All \(seconds) said again in \(voice), fitted to the clip's length, then lip synced. No seams.", sends]
        return rewrite.wholeClipReplacement == nil ? lines : lines + ["Rewrite starts from your recording’s words. The earlier revoice stays until you use the new one."]
    }

    private func option(whole: Bool, title: String, price: Decimal?, available: Bool = true, lines: [String]) -> some View {
        Button { session.wholeSelected = whole } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: session.wholeSelected == whole ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(DesignValues.color(session.wholeSelected == whole ? "tint.default" : "text.tertiary"))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(VCType.callout.font(.semibold)).foregroundStyle(DesignValues.color("text.primary"))
                        Spacer(minLength: 8)
                        if available {
                            Text(price.map(VoiceLabCostPresentation.format) ?? "Get Price").monospacedDigit()
                                .foregroundStyle(DesignValues.color("text.primary"))
                        }
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(line).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DesignValues.color(session.wholeSelected == whole ? "tint.default" : "line.default"), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(title + (price.map { ", " + VoiceLabCostPresentation.format($0) } ?? ""))
        .accessibilityAddTraits(session.wholeSelected == whole ? .isSelected : [])
    }

    @ViewBuilder private var running: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Revoicing the whole clip").font(VCType.body.font(.semibold))
            if let started = session.started {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(RewriteLipsyncControls.elapsed(context.date.timeIntervalSince(started))).monospacedDigit()
                        .foregroundStyle(DesignValues.color("text.secondary"))
                }
            }
        }
        stepList
        if case .running = session.steps[.lipsync] {
            ProgressView(value: session.progress).progressViewStyle(.linear).controlSize(.small)
                .accessibilityLabel("Lip sync progress")
        }
        HStack {
            Text("You can keep editing other clips.").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            Spacer()
            PanelButton(action: PanelAction(id: "wholeClipCancel", title: "Cancel") { [weak session] in session?.cancel() }, kind: .bordered)
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(WholeClipRevoiceSession.Step.allCases) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(mark(step)).foregroundStyle(DesignValues.color(color(step))).frame(width: 14)
                    Text(line(step)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(session.price(of: step)).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func mark(_ step: WholeClipRevoiceSession.Step) -> String {
        switch session.steps[step] ?? .waiting {
        case .done: "✓"
        case .running: "◐"
        case .failed: "!"
        case .waiting: "○"
        }
    }

    private func color(_ step: WholeClipRevoiceSession.Step) -> String {
        switch session.steps[step] ?? .waiting {
        case .done: "status.success"
        case .running: "tint.default"
        case .failed: "status.warning"
        case .waiting: "text.tertiary"
        }
    }

    private func line(_ step: WholeClipRevoiceSession.Step) -> String {
        switch session.steps[step] ?? .waiting {
        case .done(let text), .running(let text), .failed(let text): return text
        case .waiting:
            switch step {
            case .script: return "Script"
            case .voice: return "Voice"
            case .fit: return "Fit"
            case .lipsync: return "Lip sync · fal.ai \(WholeClipRevoice.Lipsync.standard.name)"
            }
        }
    }

    @ViewBuilder private var review: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("✓ Whole clip revoiced").font(VCType.body.font(.semibold))
            if let quote {
                Text("\(WholeClipRevoiceSession.clock(quote.clipSeconds)) · \(VoiceLabCostPresentation.format(session.spent)) on your keys")
                    .foregroundStyle(DesignValues.color("text.secondary"))
            }
        }
        HStack(spacing: 8) {
            PanelButton(action: PanelAction(id: "wholeClipPlay", title: "▶ Play") { [weak rewrite] in rewrite?.wholeClip?.backend?.play(false) }, kind: .bordered)
            PanelButton(action: PanelAction(id: "wholeClipAB", title: "A / B with your recording") { [weak rewrite] in rewrite?.wholeClip?.backend?.play(true) }, kind: .bordered)
        }
        if let match = session.match {
            Text(WholeClipRevoiceCardLines.matchLine(match, voice: rewrite.wholeClipAnchorName)).font(VCType.small.font())
                .foregroundStyle(DesignValues.color("text.secondary")).fixedSize(horizontal: false, vertical: true)
        }
        if let note = session.upgradeNote {
            Text(note).font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning")).fixedSize(horizontal: false, vertical: true)
        }
        if let upgrade = rewrite.wholeClipUpgradeAction() {
            PanelButton(action: upgrade, kind: .bordered)
        }
        HStack {
            Text("Undo keeps your original audio and video.").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            Spacer()
            PanelButton(action: PanelAction(id: "wholeClipUndo", title: "Undo") { [weak rewrite] in rewrite?.discardWholeClip() }, kind: .bordered)
            PanelButton(action: PanelAction(id: "wholeClipUse", title: "Use Whole Clip") { [weak rewrite] in rewrite?.useWholeClip() }, kind: .primary)
        }
    }

    @ViewBuilder private func stopped(_ line: String) -> some View {
        header
        if !session.steps.isEmpty { stepList }
        Text(line).foregroundStyle(DesignValues.color("status.warning")).fixedSize(horizontal: false, vertical: true)
        if let restored = session.restoredVoiceNote {
            Text(restored).fixedSize(horizontal: false, vertical: true)
                .columnLayoutEvidence("director.wholeClip.restored", text: restored)
        }
        if rewrite.canPlaySavedWholeClipVoice { SavedVoicePreview(rewrite: rewrite) }
        if session.voice != nil, !session.stoppedForInputs {
            Text("Your whole-clip voice take is kept in this session. Switching to changed phrases gives up this take and starts a separate voice workflow.")
                .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                .fixedSize(horizontal: false, vertical: true)
        }
        ExpressionFlow(spacing: VCTokens.spacingChipGap) {
            let actions = rewrite.wholeClipStoppedActions()
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                PanelButton(action: action, kind: index == 0 ? .primary : .bordered)
            }
        }
    }

    private var evidence: String {
        switch session.phase {
        case .choose: "choose"
        case .running: "running"
        case .review: "review"
        case .used: "used"
        case .stopped(let line): "stopped:" + line
        }
    }
}

/// The card's lines that tests read.
enum WholeClipRevoiceCardLines {
    /// "Sounds like you: 0.81 · siim's earlier takes 0.54 · your real speech 0.86".
    static func matchLine(_ match: WholeClipRevoiceRecord.Match, voice: String) -> String {
        func score(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
        var parts = ["Sounds like you: \(score(match.take))"]
        if let baseline = match.anchorBaseline { parts.append("\(voice)'s earlier takes \(score(baseline))") }
        if let real = match.realSpeech { parts.append("your real speech \(score(real))") }
        return parts.joined(separator: " · ")
    }

}
