import SwiftUI
import VoxClipCore

// "✦ Claude does it all" in the Clips section (doc/design.md §6.6, §6.7): card A asks once who makes the clips; the run
// card shows Claude making them (C), what blocks it, and the result with Export all (D). Inline, never a sheet.

/// A: "Who makes the clips?", asked once, above the clip list. The choice is remembered in Settings for every new video.
@MainActor struct ClipsModeCard: View {
    let editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingGroupGap) {
            Text("Who makes the clips?").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignValues.color("text.primary")).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
                choice(title: "✦ Claude does it all", primary: true,
                       detail: "Every new video: best moments, cuts, rewording in your voice, captions, music and shape. You review and Export.",
                       meta: editor.claudeModeMeta, mode: .claude)
                choice(title: "I'll pick", primary: false,
                       detail: "Claude suggests clips; you press ✦ Make it postable on the ones you want.", meta: nil, mode: .pick)
            }
            // Side by side when they fit the column, else stacked.
            // Side by side when they fit the column, else stacked; in the narrowest column the cap moves under the button.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VCTokens.spacingRowGap) { buttons }
                VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) { buttons }
                VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
                    PanelButton(action: PanelAction(id: "clipsMode.claude", title: "✦ Claude does it all") { editor.chooseClipsMode(.claude) }, kind: .primary)
                    if editor.clipsAutopilot.capUSD > 0 {
                        Text("Up to \(EditorModel.makeItDollars(Decimal(editor.clipsAutopilot.capUSD))) per video for voice and music")
                            .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")).fixedSize(horizontal: false, vertical: true)
                    }
                    PanelButton(action: PanelAction(id: "clipsMode.pick", title: "I'll pick") { editor.chooseClipsMode(.pick) }, kind: .ghost)
                }
            }
            Text("Next: choose one. Change it any time: the status bar's mode item, or Settings › Clips.")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize(horizontal: false, vertical: true)
        }
        .claudeCard(highlighted: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Who makes the clips?")
        .accessibilityIdentifier("voxclip.clipsMode.card")
    }

    @ViewBuilder private var buttons: some View {
        PanelButton(action: PanelAction(id: "clipsMode.claude", title: editor.claudeModeButtonTitle) { editor.chooseClipsMode(.claude) }, kind: .primary)
        PanelButton(action: PanelAction(id: "clipsMode.pick", title: "I'll pick") { editor.chooseClipsMode(.pick) }, kind: .ghost)
    }

    /// The whole choice is a button too: it chooses at once.
    private func choice(title: String, primary: Bool, detail: String, meta: String?, mode: ClipsMode) -> some View {
        Button { editor.chooseClipsMode(mode) } label: {
            VStack(alignment: .leading, spacing: VCTokens.spacing2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignValues.color(primary ? "ai.tint" : "text.primary"))
                Text(detail).font(.system(size: 12)).foregroundStyle(DesignValues.color("text.secondary"))
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                if let meta {
                    Text(meta).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VCTokens.spacingFieldPaddingX)
            .background(primary ? DesignValues.color("ai.tint").opacity(0.12) : DesignValues.color("bg.muted"), in: .rect(cornerRadius: VCTokens.radiusPane))
            .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusPane)
                .strokeBorder(primary ? DesignValues.color("ai.tint").opacity(0.55) : DesignValues.color("line.default")))
            .contentShape(.rect(cornerRadius: VCTokens.radiusPane))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title, detail, meta].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("voxclip.clipsMode.choice.\(mode.rawValue)")
        .modifier(PanelButtonEvidence(id: "clipsMode.choice.\(mode.rawValue)", title: title))
    }
}

/// C and D: Claude making the video's clips, what blocks it, and the finished set with Export all.
@MainActor struct ClaudeModeCard: View {
    @Bindable var editor: EditorModel

    var body: some View {
        let state = editor.claudeMode
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            switch state.phase {
            case .idle: EmptyView()
            case .waiting, .running: running
            case .blocked(let blocker): blocked(blocker)
            case .done, .stopped: finished
            }
        }
        .claudeCard(highlighted: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude does it all")
        .accessibilityIdentifier("voxclip.claudeMode.card")
    }

    private var title: String {
        let count = editor.clipsAutopilot.count
        let making = editor.claudeMode.clipIDs.isEmpty ? count : editor.claudeMode.clipIDs.count
        return "✦ Claude is making \(making) \(making == 1 ? "clip" : "clips")"
    }

    // C: running by itself.
    private var running: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
                Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    .columnLayoutEvidence("claudeMode.title", text: title)
                Spacer(minLength: VCTokens.spacingRowGap)
                if editor.claudeMode.running {
                    PanelButton(action: PanelAction(id: "claudeMode.stop", title: "Stop") { editor.stopClaudeMode() }, kind: .small)
                }
            }
            ForEach(editor.claudeModeSteps) { step in stepRow(step) }
            if editor.claudeMode.running {
                GeometryReader { proxy in
                    Capsule().fill(DesignValues.color("bg.muted"))
                        .overlay(alignment: .leading) { Capsule().fill(DesignValues.color("ai.tint")).frame(width: proxy.size.width * progress) }
                }
                .frame(height: 4)
                .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int(progress * 100)) percent")
            }
            CapContinueBlock(editor: editor, id: "claudeMode.continue")
            footer(editor.claudeMode.running ? editor.claudeModeFooter : "Next: wait. Claude starts once the clips are found.")
        }
    }

    private var progress: Double {
        let runs = editor.claudeModeRuns
        guard !runs.isEmpty else { return 0 }
        let done = runs.filter { !$0.running }.count
        let half = runs.contains { $0.phase == .applying } ? 0.5 : 0
        return min(1, (Double(done) + half) / Double(runs.count))
    }

    private func blocked(_ blocker: ClaudeModeBlocker) -> some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            Text("✦ Claude does it all is waiting").font(.system(size: 13, weight: .semibold))
            ForEach(editor.claudeModeSteps.filter { $0.id == "transcribed" }) { step in stepRow(step) }
            Text(blocker.reason).font(.system(size: 12)).foregroundStyle(DesignValues.color("text.secondary"))
                .fixedSize(horizontal: false, vertical: true)
                .columnLayoutEvidence("claudeMode.blocked", text: blocker.reason)
            PanelButton(action: PanelAction(id: "claudeMode.fix", title: blocker.action) { editor.fixClaudeModeBlocker() }, kind: .primary)
            footer("Next: \(blocker.action.replacingOccurrences(of: "…", with: "")), then Claude starts on its own.")
        }
    }

    // D: done (or stopped, keeping what was done).
    private var finished: some View {
        let ready = editor.claudeModeReady.count
        let headline = editor.claudeMode.phase == .done ? "✦ \(ready) \(ready == 1 ? "clip" : "clips") ready" : "✦ Stopped · \(ready) \(ready == 1 ? "clip" : "clips") ready"
        return VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            Text(headline).font(.system(size: 13, weight: .semibold)).columnLayoutEvidence("claudeMode.title", text: headline)
            Text(editor.claudeModeSummary).font(.system(size: 12)).foregroundStyle(DesignValues.color("text.secondary"))
                .fixedSize(horizontal: false, vertical: true)
            if editor.claudeMode.phase == .stopped {
                ForEach(editor.claudeModeSteps.filter { $0.state == .note }) { step in stepRow(step) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VCTokens.spacingRowGap) { finishedButtons(ready: ready) }
                VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) { finishedButtons(ready: ready) }
                VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) { finishedButtons(ready: ready, narrow: true) }
            }
            if editor.exporting, editor.claudeModeExportRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(editor.exportStatus(at: context.date)).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
                        .monospacedDigit().columnLayoutEvidence("claudeMode.exportStatus", text: editor.exportStatus(at: context.date))
                }
            }
            ForEach(editor.exportFileFailures, id: \.self) { failure in
                Label(failure, systemImage: "exclamationmark.triangle").font(.system(size: 11))
                    .foregroundStyle(DesignValues.color("text.primary")).fixedSize(horizontal: false, vertical: true)
            }
            if ready > 0, !editor.canClaudeExportAll, !editor.exporting, let reason = editor.exportUnavailable {
                Text(reason).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")).fixedSize(horizontal: false, vertical: true)
            }
            footer(ready > 0 ? editor.claudeModeNextStep : "Next: Review, or ✦ Make it postable on a clip.")
            Text("Drop the next video: Claude starts on its own.")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
                .frame(maxWidth: .infinity).padding(VCTokens.spacingRowGap)
                .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusControl).strokeBorder(DesignValues.color("line.strong"), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    /// `narrow`: the shapes go under the button ("Export all 3", then "16:9 + 9:16").
    @ViewBuilder private func finishedButtons(ready: Int, narrow: Bool = false) -> some View {
        if ready > 0, editor.canClaudeExportAll {
            PanelButton(action: PanelAction(id: "claudeMode.exportAll", title: narrow ? "Export all \(ready)" : editor.claudeExportAllTitle) { editor.claudeExportAll() }, kind: .primary)
            if narrow {
                Text(editor.claudeModeShapes.map(\.rawValue).joined(separator: " + ")).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
            }
        }
        if !editor.claudeModeRuns.isEmpty {
            PanelButton(action: PanelAction(id: "claudeMode.review", title: "Review") { editor.reviewClaudeMode() }, kind: .ghost)
        }
    }

    private func stepRow(_ step: EditorModel.ClaudeStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
            Text(Self.glyph(step.state)).font(.system(size: 12))
                .foregroundStyle(DesignValues.color(step.state == .done ? "status.success" : step.state == .now ? "ai.tint" : "text.tertiary"))
                .frame(width: 14, alignment: .leading).accessibilityHidden(true)
            // The detail ("4 · top 3 kept", "0:41", "$0.18") flows after the text, so a narrow column wraps whole words.
            (Text(step.text).foregroundStyle(DesignValues.color(step.state == .todo ? "text.tertiary" : "text.primary"))
             + Text(step.detail.isEmpty ? "" : "  " + step.detail).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")))
                .font(.system(size: 12)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .columnLayoutEvidence("claudeMode.step.\(step.id)", text: step.text)
    }

    static func glyph(_ state: EditorModel.ClaudeStep.State) -> String {
        switch state { case .done: "✓"; case .now: "✦"; case .todo: "○"; case .note: "·" }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize(horizontal: false, vertical: true)
            .columnLayoutEvidence("claudeMode.footer", text: text)
    }
}

/// The clip row's pill while Claude mode makes it: Ready, Making… or Waiting.
@MainActor struct ClaudeClipPill: View {
    let state: EditorModel.ClaudeClipState
    var body: some View {
        let (text, foreground, background): (String, String, String) = switch state {
        case .ready: ("Ready", "status.success", "status.successBackground")
        case .making: ("Making…", "ai.tint", "bg.muted")
        case .waiting: ("Waiting", "text.tertiary", "bg.muted")
        case .stopped: ("Stopped", "text.secondary", "bg.muted")
        case .failed: ("Not made", "text.secondary", "bg.muted")
        }
        Text(text).font(.system(size: 11)).foregroundStyle(DesignValues.color(foreground)).lineLimit(1).fixedSize()
            .padding(.horizontal, VCTokens.spacingLabelGap).padding(.vertical, VCTokens.spacing1)
            .background(DesignValues.color(background), in: .capsule)
            .columnLayoutEvidence("explorer.claudePill", text: text)
    }
}

extension View {
    /// The Clips section's card look: surface, hairline, and a faint ✦ edge on Claude's cards.
    func claudeCard(highlighted: Bool) -> some View {
        self
            .padding(VCTokens.spacingCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignValues.color("bg.surface"), in: .rect(cornerRadius: VCTokens.radiusPane))
            .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusPane)
                .strokeBorder(highlighted ? DesignValues.color("ai.tint").opacity(0.45) : DesignValues.color("line.default")))
            .padding(.vertical, VCTokens.spacingLabelGap)
    }
}

/// The video's cap reached (design.md §6.7, Claude does it all, item 4): "Needs about $0.40 more", the priced primary
/// **Continue · $0.40** and what it approves. The sidebar card and the Make it panel's footer show the same block, and
/// both press the one action, `continueClaudeMode()`, which approves exactly the shortfall. Nothing shows while no step
/// waits.
@MainActor struct CapContinueBlock: View {
    let editor: EditorModel
    /// The evidence id of this entry point's button: "claudeMode.continue" or "makeIt.continue".
    let id: String

    var body: some View {
        if let action = editor.capContinueAction(id: id), let needed = editor.claudeMode.budget?.needed {
            VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
                        needsMore(needed).fixedSize()
                        Spacer(minLength: VCTokens.spacingRowGap)
                        PanelButton(action: action, kind: .primary)
                    }
                    VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
                        needsMore(needed).fixedSize(horizontal: false, vertical: true)
                        PanelButton(action: action, kind: .primary)
                    }
                }
                Text(EditorModel.capContinueNote(needed))
                    .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func needsMore(_ needed: Decimal) -> some View {
        Text("Needs about \(EditorModel.makeItDollars(needed)) more").font(.system(size: 12, weight: .medium))
            .columnLayoutEvidence(id.replacingOccurrences(of: ".continue", with: ".needsMore"), text: "Needs about \(EditorModel.makeItDollars(needed)) more")
    }
}
