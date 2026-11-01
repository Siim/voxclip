import SwiftUI
import VoxClipCore

/// The passage panel, interim (impl-plan V13): the Rewrite job's proposal (R2) and its field while the task waits for a
/// new instruction. Until the clip bar's Ask field (V3b) its field is the Ask field, with design.md §6.3.1's suggestions,
/// and its Rewrite sends again on the session's scope; V15's change list replaces the rest and deletes it.
@MainActor struct RewritePanel: View {
    @Bindable var session: RewriteSession
    @FocusState private var instructionFocused: Bool
    @State private var approvalTask: Task<Void, Never>?
    private var editor: EditorModel { session.editor }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { contents }
            Divider()
            footer
        }
        .background(DesignValues.color("bg.surface"))
        .accessibilityElement(children: .contain).accessibilityIdentifier("voxclip.rewrite")
        .focusSection()
        .onExitCommand { editor.closeRewrite() }
        // The panel also goes when its tab or the panel's job changes (impl-plan V3a, V4);
        // the session stays open then, and so does a send it approved. Closing it cancels its own work.
        .onDisappear { if !session.isOpen { approvalTask?.cancel() } }
        // The field takes the keyboard after Ask for Something Else and back from a run that had it; a reply that arrives
        // while the user works elsewhere leaves focus there.
        .task {
            if session.task.takeKeyboardHandover() { instructionFocused = true }
            await session.detectConnector()
        }
        .onChange(of: editor.paneFocusRequest) { _, _ in
            if editor.focusedPane == .panel { instructionFocused = true }
        }
        .onChange(of: instructionFocused) { _, focused in
            if focused { editor.focusedPane = .panel }
            session.task.keyboardInPanel = focused
        }
        .onChange(of: editor.capabilities) { _, _ in
            if !session.current { editor.closeRewrite(returnFocus: false) }
        }
    }
    var contents: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            AskField(editor: editor, focused: $instructionFocused) { rewrite() }
            RewriteProposalControls(session: session, rewrite: rewrite)
            Divider()
            if case .proposal(let set) = session.task.state { changeList(set) }
            if let review = session.review {
                ForEach(review.voiceHunks.indices, id: \.self) { index in
                    if let meter = review.voiceHunks[index].meter {
                        Text(meter.copy).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if let refusal = review.voiceHunks[index].refusal {
                        Text(refusal).font(.system(size: 11)).foregroundStyle(DesignValues.color("status.warning"))
                    }
                }
                if let copy = review.budget.copy { Text(copy).font(.system(size: 12)).foregroundStyle(DesignValues.color("status.warning")).fixedSize(horizontal: false, vertical: true) }
                if let summary = review.summary, !review.voiceHunks.isEmpty { Text(summary.copy).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if !session.problem.isEmpty { InlineNotice(text: session.problem) }
            if session.showsVoiceLab {
                Divider()
                if let generation = session.generation { RewriteTakesView(session: session, generation: generation, generate: generate) }
                else { Button("Choose Voice…") { approvalTask = Task { await session.discoverVoices() } } }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.showsVoiceLab {
                Label("Exports show AI MODIFIED on the video and in the post.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // design.md R2 "Voice changes, Voice Lab off": the one-time beta sheet turns it on.
            if session.offersVoiceLab { Button("Turn On Voice Lab…") { editor.showVoiceLabOptIn = true } }
            if let title = session.applyTitle {
                Button(title) { session.applyFreeChanges() }
                    .disabled(!session.current || session.isProposing)
            }
            if let generation = session.generation, editor.app.voiceLabRewriteEnabled {
                Button(generation.acceptTitle) { approvalTask = Task { await session.acceptTakes() } }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!session.current || !generation.readyToAccept || session.isProposing || !editor.capabilities.edit)
                if !generation.problem.isEmpty { InlineNotice(text: generation.problem) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    /// The proposal's headline and one row per change: its removed words struck, its new words in the tint.
    private func changeList(_ set: ChangeSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.task.headline.text).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let sub = session.task.headline.sub { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(set.items) { item in
                change(item).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.spokenDescription(of: set.items.count, prefix: "Change"))
            }
        }
    }
    private func change(_ item: ProposalItem) -> Text {
        var result = AttributedString()
        if !item.oldWords.isEmpty {
            var old = AttributedString(item.oldWords.joined(separator: " "))
            old.strikethroughStyle = .single; old.foregroundColor = Color.secondary
            result.append(old)
        }
        if !item.newWords.isEmpty {
            var new = AttributedString((item.oldWords.isEmpty ? "" : " ") + item.newWords.joined(separator: " "))
            new.foregroundColor = DesignValues.accentText
            result.append(new)
        }
        return Text(result)
    }
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
            Text(session.task.words.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if session.showsVoiceLab {
                Text("Beta").font(.system(size: 11)).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
            }
            Spacer(minLength: 4)
            Button { editor.closeRewrite() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel(EditorIconAction.closeRewrite.name).help("Close Rewrite (Esc)")
        }
    }
    #if DEBUG
    var snapshot: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(editor.rewriteInstruction.isEmpty ? AskField.placeholder(session.task.words) : editor.rewriteInstruction).font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(DesignValues.color("bg.surface"))
            if case .proposal(let set) = session.task.state { changeList(set) }
            Divider()
            if let generation = session.generation { RewriteTakesView(session: session, generation: generation, generate: {}).snapshot }
            Divider()
            footer
        }.padding(16).background(DesignValues.color("bg.surface"))
    }
    #endif
    /// Rewrite on the session's scope with the field's text: it sends again and replaces the proposal (design.md §6.3.1).
    private func rewrite() {
        editor.runRewrite(scope: session.rewriteScope)
    }
    private func generate() {
        guard let generation = session.generation, generation.canExecute else { return }
        generation.approve(true, confirmation: { copy in
            guard let window = session.editor.window else { return false }
            return await RewriteApprovalSheet(title: "Generate Takes", copy: copy, parent: window).confirm()
        })
    }
}

/// Rewrite's Ask field (design.md §6.3.1), bound to `EditorModel.rewriteInstruction`: the scope's placeholder, Return runs
/// Rewrite, and a trailing menu lists the suggestions, which fill the field and do not send. The clip bar (V3b) hosts it.
@MainActor struct AskField: View {
    @Bindable var editor: EditorModel
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void
    /// "What should change in clip 1?", "… in this video?", "… in these words?".
    static func placeholder(_ words: DirectorScope) -> String {
        switch words.kind {
        case .clip(let number): "What should change in clip \(number)?"
        case .fullTake: "What should change in this video?"
        case .selection: "What should change in these words?"
        }
    }
    private var words: DirectorScope {
        editor.rewrite?.task.words ?? DirectorScope(kind: .fullTake, wordCount: 0)
    }
    var body: some View {
        let placeholder = Self.placeholder(words)
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(placeholder, text: $editor.rewriteInstruction)
                .textFieldStyle(.plain).focused(focused)
                .onSubmit(submit)
                .accessibilityLabel(String(placeholder.dropLast()))
            Menu {
                ForEach(editor.app.rewriteSuggestions(for: editor.project.id)) { suggestion in
                    Button(suggestion.menuTitle) { editor.rewriteInstruction = suggestion.title }
                }
            } label: { Image(systemName: "chevron.down") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Suggestions").help("Suggestions")
        }
        .padding(.horizontal, 8).frame(minHeight: 28)
        .background(DesignValues.color("bg.input"), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignValues.color("line.strong").opacity(0.4)))
    }
}

@MainActor struct RewriteProposalControls: View {
    let session: RewriteSession
    let rewrite: () -> Void
    var body: some View {
        // Running shows R1, and the connector's fixes show in R1x (DirectorPanel), not here.
        VStack(alignment: .leading, spacing: 12) {
            Button(session.proposalButton, action: rewrite).disabled(!session.editor.capabilities.ai || session.isProposing)
                .accessibilityLabel(session.task.words.title)
            Text(session.sendLine).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
