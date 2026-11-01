import SwiftUI
import VoxClipCore

// A task's panel in the right column (design.md §6.3.4, in notes.md §7's grammar): the
// context line with the close button, the headline, the cards and the pinned footer. It
// draws whatever the task holds and owns no state of its own, so Rewrite and Phase 1's
// Director share it. Every button it shows can act (design.md: no disabled buttons).

@MainActor struct DirectorPanel: View {
    @Bindable var task: DirectorTask
    /// The editor whose F6 order the panel joins; nil in scenes outside an editor.
    var model: EditorModel?
    @FocusState private var keyFieldFocused: Bool
    /// The Ask field (`.ask`) has the keyboard.
    @FocusState private var askFocused: Bool
    /// The keyboard is in the panel: on the pane itself (F6, a handover) or a field inside it.
    @FocusState private var keyboardWithin: Bool
    /// The handover's focus took, once; after that the user may move it away.
    @State private var handoverTook = false
    /// The question's safe answer, Keep Working, has the keyboard: a question takes it as it appears (lead decision,
    /// MVP integration), so Return, Space and Esc all keep the work.
    @FocusState private var answerFocused: Bool
    /// Where the keyboard was when a question took it, given back once the question is answered, as the sheet it
    /// replaced gave it back. Nil when the user moved the keyboard away from the answer meanwhile.
    @State private var keyboardBeforeQuestion: KeyboardSpot?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    contextRow
                    PanelHeadlineView(headline: task.headline)
                        .padding(.top, 6).padding(.bottom, task.cards.isEmpty ? 0 : 10)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(task.cards) { card in cardView(card) }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A question (`PanelConfirm`) stands in the footer's place until it is answered: inline, not an alert (§13.1).
            if let confirm = task.confirm {
                PanelFooterView(footer: PanelFooter(note: confirm.question, link: confirm.confirm, primary: confirm.cancel), asks: true, answerFocus: $answerFocused)
            } else if task.footer != PanelFooter() { PanelFooterView(footer: task.footer) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.words.title)
        .accessibilityIdentifier("voxclip.director")
        .modifier(EditorPaneFocus(model: model, pane: .panel))
        // Whether the keyboard is anywhere in the panel, for the handover between the panel's views.
        .focused($keyboardWithin)
        // Esc and ⌘. (design.md §8): the safe answer to a question the panel asks, Stop while the task runs, which closes
        // it too, else Close.
        .onExitCommand { (task.confirm?.cancel ?? task.headline.stop ?? task.close).perform() }
        // ⌘Return from anywhere in the panel: the primary. Return outside a text field edits the focused change of a change
        // list, else runs the primary; Space leaves the focused change out or keeps it (`DirectorTask.pressReturn`).
        .onKeyPress(keys: [.return], phases: [.down, .repeat]) { press in
            let command = press.modifiers.contains(.command)
            guard command || !keyFieldFocused && !askFocused else { return .ignored }
            guard press.phase == .down else { return .handled }
            let now = Date()
            let eventDate = VoiceLabSession.paidEventDate(timestamp: NSApp.currentEvent?.timestamp, now: now)
            return task.pressReturn(command: command, now: now, eventDate: eventDate) ? .handled : .ignored
        }
        .onKeyPress(keys: [.space], phases: [.down, .repeat]) { press in
            guard press.modifiers.isEmpty, !keyFieldFocused, !askFocused else { return .ignored }
            if task.cards.contains(.takes), task.confirm == nil {
                if press.phase == .down { model?.transport(" ") }
                return .handled
            }
            return task.pressSpace() ? .handled : .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123"), phases: [.down, .repeat]) { press in
            guard task.cards.contains(.takes), task.confirm == nil, !keyFieldFocused, !askFocused, press.modifiers.isEmpty else { return .ignored }
            if press.phase == .down, let number = Int(press.characters) { model?.rewrite?.selectTake(number: number) }
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard !keyFieldFocused, !askFocused else { return .ignored }
            if task.cards.contains(.takes), task.confirm == nil {
                model?.rewrite?.moveTakePhrase(backward: press.key == .upArrow)
                return .handled
            }
            if let rows = chooserRows, !rows.isEmpty {
                let index = rows.firstIndex { $0.id == task.choice } ?? -1
                let next = press.key == .upArrow ? max(0, index - 1) : min(rows.count - 1, index + 1)
                task.choose(rows[next].id)
                return .handled
            }
            // ↑ and ↓ walk the change list, as ⌥↑ and ⌥↓ walk the hunks.
            guard let changes = task.changes, !changes.items.isEmpty else { return .ignored }
            let index = changes.items.firstIndex { $0.ordinal == changes.focused } ?? -1
            let next = press.key == .upArrow ? max(0, index - 1) : min(changes.items.count - 1, index + 1)
            task.review?(changes.items[next].ordinal, .focus)
            return .handled
        }
        .onChange(of: task.focusRequest) { _, _ in
            if task.cards.contains(where: { if case .ask = $0 { true } else { false } }) { askFocused = true } else { keyFieldFocused = true }
        }
        .onChange(of: keyboardWithin) { _, _ in reportKeyboard() }
        .onChange(of: keyFieldFocused) { _, _ in reportKeyboard() }
        .onChange(of: askFocused) { _, _ in reportKeyboard() }
        .onChange(of: answerFocused) { _, focused in
            reportKeyboard()
            // The user moved the keyboard away from a waiting question: it stays where they put it once it is answered.
            if !focused, task.confirm != nil { keyboardBeforeQuestion = nil }
        }
        // Replacing the passage panel that had the keyboard, it takes it, so Esc, ⌘. and Return still act (design.md R1).
        .task {
            guard task.takeKeyboardHandover() else { return }
            let keyField = task.cards.contains(where: { if case .keyField = $0 { true } else { false } })
            await Self.askForFocus(until: { handoverTook }) { if keyField { keyFieldFocused = true } else { keyboardWithin = true } }
        }
        // A question moves the keyboard to its safe answer, wherever it was; VoiceOver hears the question as it appears.
        // Answered, it gives the keyboard back: to the transcript or the clip bar's Ask field, or the panel itself.
        .task(id: task.confirm?.question) {
            guard task.confirm != nil else {
                if let spot = keyboardBeforeQuestion { keyboardBeforeQuestion = nil; await giveKeyboardBack(to: spot) }
                return
            }
            if keyboardBeforeQuestion == nil { keyboardBeforeQuestion = keyboardSpot }
            await Self.askForFocus(until: { answerFocused }) { answerFocused = true }
        }
        // The producer's own work as the panel appears (Rewrite detects its AI), beside the handover's.
        .task { await task.appeared?() }
        .columnLayoutEvidence("director.panel")
    }

    /// Tells the task whether the keyboard is anywhere in the panel; once it is, the handover took.
    private func reportKeyboard() {
        let within = keyboardWithin || keyFieldFocused || askFocused || answerFocused
        task.keyboardInPanel = within
        if within { handoverTook = true }
    }
    /// Makes `request` until `took` holds, every 20 ms for half a second at most, and never once it took: the user may
    /// have moved the keyboard since. macOS 26 drops a focus request made as the view that had the keyboard lets go of it
    /// or as the focused view appears (hosted CI's 26.6 left the window first responder); one a moment later takes.
    private static func askForFocus(until took: () -> Bool, _ request: () -> Void) async {
        for _ in 0..<25 {
            if took() || Task.isCancelled { return }
            request()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Where a question found the keyboard: the panel's Ask field, its key field, the panel itself, or a view outside it.
    private enum KeyboardSpot {
        case ask, keyField, pane
        case outside(WeakView)
        struct WeakView { weak var view: NSView? }
        /// The view with the window's keyboard: a text field rather than the field editor that edits it.
        @MainActor static func view(holding window: NSWindow) -> NSView? {
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSView }
            return window.firstResponder as? NSView
        }
    }
    /// Where the keyboard is now; nil outside an editor's window.
    private var keyboardSpot: KeyboardSpot? {
        if askFocused { return .ask }
        if keyFieldFocused { return .keyField }
        if keyboardWithin { return .pane }
        guard let window = model?.window, let view = KeyboardSpot.view(holding: window) else { return nil }
        return .outside(KeyboardSpot.WeakView(view: view))
    }
    /// Puts the keyboard back where a question found it, asking as the handover does.
    private func giveKeyboardBack(to spot: KeyboardSpot) async {
        switch spot {
        case .ask: await Self.askForFocus(until: { askFocused }) { askFocused = true }
        case .keyField: await Self.askForFocus(until: { keyFieldFocused }) { keyFieldFocused = true }
        case .pane: await Self.askForFocus(until: { keyboardWithin }) { keyboardWithin = true }
        case .outside(let held):
            guard let view = held.view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return }
            await Self.askForFocus(until: { KeyboardSpot.view(holding: window) === view }) { window.makeFirstResponder(view) }
        }
    }

    private var chooserRows: [ConnectorChoice]? {
        for case .chooser(let rows, _) in task.cards { return rows }
        return nil
    }

    /// The AI, its model and the send's state, then Close (notes.md §7's harness line).
    private var contextRow: some View {
        HStack(spacing: 6) {
            if let context = task.context {
                Circle().fill(Self.dotColor(context.readiness)).frame(width: 6, height: 6).accessibilityHidden(true)
                let rest = [context.model, context.stateText].compactMap { $0 }.filter { !$0.isEmpty }.map { " · " + $0 }.joined()
                Text("\(Text(context.name).foregroundStyle(DesignValues.color("text.secondary")).fontWeight(.medium))\(rest)")
                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(context.text)
                    .columnLayoutEvidence("director.context", text: context.text)
            }
            Spacer(minLength: 4)
            // R2's "Ask again" (notes.md §7): borderless, before Close.
            if let again = task.contextAction {
                Button(action: again.perform) {
                    Label(again.title, systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
                        .font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                        .padding(.horizontal, 6).frame(height: 22).contentShape(Rectangle())
                        .modifier(PanelButtonEvidence(action: again))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(again.title)
                .accessibilityIdentifier("voxclip.director.\(again.id)")
            }
            Button(action: task.close.perform) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignValues.color("text.tertiary"))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
                    .modifier(PanelButtonEvidence(action: task.close))
            }
            .buttonStyle(.plain)
            .help("\(task.close.title) (Esc)")
            .accessibilityLabel(task.close.title)
        }
        .frame(minHeight: 22)
    }

    /// The status dot's colour. It repeats the context line's words, so it is decorative.
    static func dotColor(_ readiness: DirectorContext.Readiness) -> Color {
        switch readiness {
        case .ready: DesignValues.color("status.success")
        case .asksFirst: DesignValues.color("status.warning")
        case .unavailable: DesignValues.color("text.disabled")
        }
    }

    @ViewBuilder private func cardView(_ card: PanelCard) -> some View {
        switch card {
        case .asked(let preset, let text): AskedCard(preset: preset, text: text)
        case .activity(let steps): ActivityCard(steps: steps)
        case .text(let text):
            Text(text).font(VCType.callout.font()).lineSpacing(3).foregroundStyle(DesignValues.color("text.primary"))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .columnLayoutEvidence("director.text", text: text)
        case .chooser(let rows, let saveKey): ChooserCard(task: task, rows: rows, saveKey: saveKey, keyFieldFocused: $keyFieldFocused)
        case .keyField(let provider, let label):
            KeyField(label: label, text: $task.keyDraft, focused: $keyFieldFocused) { task.footer.primary?.perform() }
                .columnLayoutEvidence("director.key.\(provider)")
        case .changes(let set): ChangeListCard(set: set, task: task)
        case .callout(let text):
            Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(VCType.callout.font()).foregroundStyle(DesignValues.color("status.warning"))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("line.default"), lineWidth: 1) }
                .accessibilityElement(children: .combine)
                .columnLayoutEvidence("director.callout", text: text)
        case .ask(let placeholder):
            // The Ask field, bound to the editor; Return runs Rewrite on the task's scope. The clip bar holds it from V3b.
            if let model {
                AskField(editor: model, focused: $askFocused) { model.runRewrite(scope: task.scope) }
                    .columnLayoutEvidence("director.ask", text: placeholder)
            }
        case .takes: RewriteTakesCard(model: model)
        }
    }
}

/// The headline: 15 semibold with an optional sub-line, or while running the spinner, the
/// text, the elapsed m:ss and Stop.
@MainActor private struct PanelHeadlineView: View {
    let headline: PanelHeadline
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if headline.runningSince != nil {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    .accessibilityHidden(true)
            }
            Text(headline.text).font(VCType.title3.font(.semibold)).foregroundStyle(DesignValues.color("text.primary"))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .columnLayoutEvidence("director.headline", text: headline.text)
            if let sub = headline.sub {
                Text(sub).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tag = headline.tag {
                // "Beta" in a hairline capsule (design.md §6.3.4), read after the headline.
                Text(tag).font(VCType.small.font(.medium)).foregroundStyle(DesignValues.color("text.secondary"))
                    .padding(.horizontal, 5).frame(height: 16)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(DesignValues.color("line.strong"), lineWidth: 1) }
                    .fixedSize()
                    .columnLayoutEvidence("director.tag", text: tag)
            }
            if let since = headline.runningSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(durationLabel(context.date.timeIntervalSince(since)))
                        .font(VCType.callout.mono()).monospacedDigit().foregroundStyle(DesignValues.color("text.tertiary"))
                        .accessibilityLabel("Elapsed")
                        .accessibilityValue(durationLabel(context.date.timeIntervalSince(since)))
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            if let stop = headline.stop {
                PanelButton(action: stop, kind: .small).help("\(stop.title) (⌘.)")
            }
        }
    }
}

/// "Asked: **Fix mistakes**, fix slips and repeats…" under a 2 pt rule (design.md R1).
@MainActor private struct AskedCard: View {
    let preset: String?
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(DesignValues.color("line.strong")).frame(width: 2)
            Group {
                if let preset { Text("Asked: \(Text(preset).fontWeight(.semibold)), \(text)") } else { Text("Asked: \(text)") }
            }
                .font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .columnLayoutEvidence("director.asked")
    }
}

/// The work log in a hairline box: ✓ done, a spinner while running, ○ waiting; a detail
/// under each. VoiceOver reads "Done: Read clip 1, 118 words" and hears each change.
@MainActor private struct ActivityCard: View {
    let steps: [ActivityStep]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    glyph(step.status).frame(width: 14, height: 14)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).font(VCType.callout.font())
                            .foregroundStyle(DesignValues.color(step.status == .waiting ? "text.tertiary" : step.status == .running ? "text.primary" : "text.secondary"))
                        if !step.detail.isEmpty {
                            Text(step.detail).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let tool = step.tool {
                        Text(tool).font(VCType.label.mono()).foregroundStyle(DesignValues.color("text.tertiary"))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.accessibilityLabel)
                .accessibilityAddTraits(.updatesFrequently)
                .columnLayoutEvidence("director.step.\(step.id)", text: step.accessibilityLabel)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DesignValues.color("line.default"), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps")
    }
    @ViewBuilder private func glyph(_ status: ActivityStep.Status) -> some View {
        switch status {
        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignValues.color("text.secondary"))
        case .failed: Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignValues.color("status.warning"))
        case .running: ProgressView().controlSize(.mini)
        case .waiting: Circle().strokeBorder(DesignValues.color("text.disabled"), lineWidth: 1).frame(width: 8, height: 8)
        }
    }
}

/// R0's radio list. A row with no key shows a secure field and Save Key under it.
@MainActor private struct ChooserCard: View {
    @Bindable var task: DirectorTask
    let rows: [ConnectorChoice]
    let saveKey: PanelAction?
    var keyFieldFocused: FocusState<Bool>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                let chosen = task.choice == row.id
                Button { task.choose(row.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ZStack {
                            Circle().strokeBorder(DesignValues.color(chosen ? "text.primary" : "text.tertiary"), lineWidth: 1)
                            if chosen { Circle().fill(DesignValues.color("text.primary")).padding(3.5) }
                        }
                        .frame(width: 13, height: 13)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).font(VCType.body.font()).foregroundStyle(DesignValues.color("text.primary"))
                            Text(row.status).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(minHeight: 26)
                    .background(chosen ? DesignValues.color("bg.selectedRow") : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.name), \(row.status)")
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                .columnLayoutEvidence("director.choice.\(row.id)", text: row.status)
                if row.needsKey, let save = saveKey {
                    HStack(spacing: 6) {
                        KeyField(label: "Paste your \(row.shortName) API key", text: $task.keyDraft, focused: keyFieldFocused) { save.perform() }
                        PanelButton(action: save, kind: .bordered)
                    }
                    .padding(.leading, 29).padding(.trailing, 8).padding(.bottom, 4)
                    .columnLayoutEvidence("director.key.\(row.id)")
                }
            }
        }
        .padding(.horizontal, -8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI")
    }
}

/// A secure field on the raised input fill (notes.md §3 `raised`, `line2` outline).
@MainActor private struct KeyField: View {
    let label: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void
    var body: some View {
        SecureField(label, text: $text)
            .textFieldStyle(.plain).textContentType(.password)
            .font(VCType.callout.font())
            .focused(focused)
            .onSubmit(submit)
            .padding(.horizontal, 8).frame(height: 26)
            .background(DesignValues.color("bg.input"), in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1) }
            .accessibilityLabel(label)
    }
}

/// The pinned footer (notes.md `.pfoot`): a hairline above, the note leading, then the link
/// and the primary. Where the note would get under 150 pt, it moves above the buttons. A
/// question (`asks`) reads as body copy in `text.primary`, not as a tertiary note.
@MainActor private struct PanelFooterView: View {
    let footer: PanelFooter
    var asks = false
    /// A question's focus on its safe answer, the primary.
    var answerFocus: FocusState<Bool>.Binding?
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if footer.note == nil { Spacer(minLength: 0) }
                else { note.frame(minWidth: 150, idealWidth: 150, maxWidth: .infinity, alignment: .leading) }
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                note
                HStack(spacing: 8) { Spacer(minLength: 0); buttons }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignValues.color("bg.window"))
        .overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
        .columnLayoutEvidence("director.footer")
    }
    @ViewBuilder private var note: some View {
        if let text = footer.note {
            Text(text).font(asks ? VCType.callout.font(.medium) : VCType.small.font()).lineSpacing(2)
                .foregroundStyle(DesignValues.color(asks ? "text.primary" : "text.tertiary"))
                .fixedSize(horizontal: false, vertical: true)
                .columnLayoutEvidence(asks ? "director.question" : "director.note", text: text)
        }
    }
    @ViewBuilder private var buttons: some View {
        if let link = footer.link { PanelButton(action: link, kind: .ghost) }
        if let primary = footer.primary {
            if let answerFocus {
                // The question's safe answer takes the keyboard, with its ring; VoiceOver reads the question with it.
                PanelButton(action: primary, kind: .primary)
                    .focusable().focused(answerFocus)
                    .accessibilityHint(footer.note ?? "")
                    .columnLayoutEvidence("director.answer", text: answerFocus.wrappedValue ? "focused:" + primary.id : primary.id)
            } else { PanelButton(action: primary, kind: .primary) }
        }
    }
}

/// A panel button (notes.md `.btn`): the primary in `tint` (28 high, tint.on label), a
/// borderless ghost link, a bordered secondary, or a small ghost like Stop.
@MainActor struct PanelButton: View {
    enum Kind { case primary, ghost, bordered, small }
    let action: PanelAction
    let kind: Kind
    @State private var appeared = Date()
    var body: some View {
        Button(action.title) {
            let event = NSApp.currentEvent
            let now = Date()
            if action.priced, event?.type == .keyDown {
                guard event?.keyCode != 49,
                      VoiceLabSession.permitsPaidActivation(keyboard: true, command: event?.modifierFlags.contains(.command) == true,
                        repeated: event?.isARepeat == true, appeared: appeared, now: now,
                        eventDate: VoiceLabSession.paidEventDate(timestamp: event?.timestamp, now: now)) else { return }
            }
            action.perform()
        }
            .buttonStyle(PanelButtonStyle(kind: kind, action: action))
            .accessibilityIdentifier("voxclip.director.\(action.id)")
            .onAppear { appeared = Date() }
            .onChange(of: action) { _, _ in appeared = Date() }
    }
}

/// Records each button the panel draws and whether SwiftUI enables it, so a scene runner
/// can assert design.md's "no disabled buttons" headless. It sits inside the button's label,
/// where a `disabled` on the button or any view around it reaches the environment.
@MainActor private struct PanelButtonEvidence: ViewModifier {
    let action: PanelAction
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.columnLayoutEvidence("director.button.\(action.id)", text: (isEnabled ? "" : DirectorPanel.disabledPrefix) + action.title)
    }
}

extension DirectorPanel {
    /// Marks a disabled button's evidence text; a scene with one fails its check.
    static let disabledPrefix = "disabled:"
}

private struct PanelButtonStyle: ButtonStyle {
    let kind: PanelButton.Kind
    let action: PanelAction
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label.lineLimit(1).fixedSize().modifier(PanelButtonEvidence(action: action))
        switch kind {
        case .primary:
            label.font(VCType.body.font(.semibold)).foregroundStyle(DesignValues.color("tint.on"))
                .padding(.horizontal, 12).frame(height: 28)
                .background(DesignValues.color(configuration.isPressed ? "tint.pressed" : "tint.default"), in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
        case .ghost:
            label.font(VCType.body.font(.medium)).foregroundStyle(DesignValues.color(configuration.isPressed ? "text.primary" : "text.secondary"))
                .padding(.horizontal, 10).frame(height: 24).contentShape(Rectangle())
        case .bordered:
            label.font(VCType.callout.font(.medium)).foregroundStyle(DesignValues.color("text.primary"))
                .padding(.horizontal, 10).frame(height: 26)
                .background(DesignValues.color(configuration.isPressed ? "bg.selectedRow" : "bg.muted"), in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("line.edge"), lineWidth: 1) }
                .contentShape(Rectangle())
        case .small:
            label.font(VCType.callout.font()).foregroundStyle(DesignValues.color(configuration.isPressed ? "text.primary" : "text.secondary"))
                .padding(.horizontal, 6).frame(height: 22).contentShape(Rectangle())
        }
    }
}
