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
            HStack(spacing: VCTokens.spacingRowGap) {
                PanelButton(action: PanelAction(id: "clipsMode.claude", title: editor.claudeModeButtonTitle) { editor.chooseClipsMode(.claude) }, kind: .primary)
                PanelButton(action: PanelAction(id: "clipsMode.pick", title: "I'll pick") { editor.chooseClipsMode(.pick) }, kind: .ghost)
            }
            Text("Next: choose one. Change it any time: the status bar's mode item, or Settings › Clips.")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize(horizontal: false, vertical: true)
        }
        .claudeCard(highlighted: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Who makes the clips?")
        .accessibilityIdentifier("voxclip.clipsMode.card")
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
                ProgressView(value: progress).progressViewStyle(.linear).tint(DesignValues.color("ai.tint")).controlSize(.small)
            }
            if let needed = editor.claudeMode.budget?.needed {
                HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
                    Text("Needs about \(EditorModel.makeItDollars(needed)) more").font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .columnLayoutEvidence("claudeMode.needsMore", text: "Needs about \(EditorModel.makeItDollars(needed)) more")
                    Spacer(minLength: VCTokens.spacingRowGap)
                    PanelButton(action: PanelAction(id: "claudeMode.continue", title: "Continue · \(EditorModel.makeItDollars(needed))", priced: true) {
                        editor.continueClaudeMode()
                    }, kind: .primary)
                }
                Text("Continue approves exactly \(EditorModel.makeItDollars(needed)) more for voice or music on this video.")
                    .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize(horizontal: false, vertical: true)
            }
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
            HStack(spacing: VCTokens.spacingRowGap) {
                if ready > 0, editor.canClaudeExportAll {
                    PanelButton(action: PanelAction(id: "claudeMode.exportAll", title: editor.claudeExportAllTitle) { editor.claudeExportAll() }, kind: .primary)
                }
                if !editor.claudeModeRuns.isEmpty {
                    PanelButton(action: PanelAction(id: "claudeMode.review", title: "Review") { editor.reviewClaudeMode() }, kind: .ghost)
                }
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

    private func stepRow(_ step: EditorModel.ClaudeStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
            Text(Self.glyph(step.state)).font(.system(size: 12))
                .foregroundStyle(DesignValues.color(step.state == .done ? "status.success" : step.state == .now ? "ai.tint" : "text.tertiary"))
                .frame(width: 14, alignment: .leading).accessibilityHidden(true)
            Text(step.text).font(.system(size: 12))
                .foregroundStyle(DesignValues.color(step.state == .todo ? "text.tertiary" : "text.primary"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: VCTokens.spacing2)
            if !step.detail.isEmpty {
                Text(step.detail).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).monospacedDigit().fixedSize()
            }
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
