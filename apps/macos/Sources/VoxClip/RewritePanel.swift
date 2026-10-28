import SwiftUI
import VoxClipCore

@MainActor struct RewritePanel: View {
    @Bindable var session: RewriteSession
    @FocusState private var instructionFocused: Bool
    @FocusState private var wordsFocused: Bool
    @State private var approvalTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { contents }
            Divider()
            footer
        }
        .background(DesignValues.color("bg.surface"))
        .focusSection()
        .onExitCommand { session.editor.closeRewrite() }
        .onDisappear { approvalTask?.cancel() }
        .task { instructionFocused = true; await session.prepare() }
        .task(id: session.quote?.id) { if let id = session.quote?.id { session.markEstimateShown(id) } }
        .onChange(of: session.editor.paneFocusRequest) { _, _ in
            if session.editor.focusedPane == .panel { instructionFocused = true }
        }
        .onChange(of: instructionFocused) { _, focused in if focused { session.editor.focusedPane = .panel } }
        .onChange(of: wordsFocused) { _, focused in if focused { session.editor.focusedPane = .panel } }
        .onChange(of: session.editor.capabilities) { _, _ in
            if !session.current { session.editor.closeRewrite(returnFocus: false) }
        }
    }
    var contents: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text("What should change?").font(.system(size: 12, weight: .semibold))
            TextField("What should change?", text: Binding(get: { session.instruction }, set: { session.setInstruction($0) }), axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder).focused($instructionFocused)
                .accessibilityLabel("What should change?")
            RewriteProposalControls(session: session, propose: approveAndPropose)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("New words").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(session.review?.changeSummary ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TextField("New words", text: Binding(get: { session.newWords }, set: { session.edit($0) }), axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.roundedBorder).focused($wordsFocused).accessibilityLabel("New words")
            if let review = session.review {
                diffLine(review).font(.system(size: 12)).textSelection(.enabled)
                    .accessibilityLabel(review.accessibleDescription)
                ForEach(review.voiceHunks.indices, id: \.self) { index in
                    if let meter = review.voiceHunks[index].meter {
                        Text(meter.copy).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let refusal = review.voiceHunks[index].refusal {
                        Text(refusal).font(.system(size: 11)).foregroundStyle(DesignValues.color("status.warning"))
                    }
                }
                if let copy = review.budget.copy { Text(copy).font(.system(size: 12)).foregroundStyle(DesignValues.color("status.warning")) }
                if let summary = review.summary, !review.voiceHunks.isEmpty { Text(summary.copy).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if !session.problem.isEmpty { InlineNotice(text: session.problem) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exports show AI MODIFIED on the video and in the post.", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let action = session.localAction {
                Button(action) { if session.applyLocalChanges() { session.editor.closeRewrite() } }
                    .disabled(!session.current || session.isProposing)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
            Text("Rewrite").font(.system(size: 13, weight: .semibold))
            Text("Beta").font(.system(size: 10)).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
            Spacer(minLength: 4)
            Text(session.header).font(DesignValues.mono(10)).foregroundStyle(.secondary)
            Button { session.editor.closeRewrite() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel(EditorIconAction.closeRewrite.name).help("Close Rewrite (Esc)")
        }
    }
    private func diffLine(_ review: RewriteReview) -> Text {
        var result = AttributedString()
        for run in review.runs {
            var text = AttributedString(run.text + " ")
            switch run.kind {
            case .removed: text.strikethroughStyle = .single; text.foregroundColor = Color.secondary
            case .inserted: text.foregroundColor = DesignValues.accentText
            case .bridge: text.foregroundColor = Color.secondary
            case .equal: break
            }
            result.append(text)
        }
        return Text(result)
    }
    private func approveAndPropose() {
        guard let quote = session.quote, session.canPropose else { return }
        approvalTask = Task {
            var approved = true
            if case .confirm(let copy) = session.estimate {
                guard let window = session.editor.window else { return }
                approved = await RewriteApprovalSheet(title: "Rewrite", copy: copy, parent: window).confirm()
            }
            await session.propose(quote, affirmative: approved)
        }
    }
}

@MainActor struct RewriteProposalControls: View {
    let session: RewriteSession
    let propose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(session.proposalButton, action: propose).disabled(!session.canPropose)
                .accessibilityLabel(session.proposalButton)
            if session.isProposing { ProgressView().controlSize(.small).accessibilityLabel("Rewriting") }
            Text(session.sendLine).font(.system(size: 11)).foregroundStyle(.secondary)
            if session.connector == nil { Button("Open Settings") { openVoxClipSettings(pane: "ai") } }
            if !session.estimateCopy.isEmpty { Text(session.estimateCopy).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
