import SwiftUI
import VoxClipCore

enum TimelineEditMode: Hashable {
    case effects, trim
}

struct TimelineEditorRoute: Hashable {
    let mode: TimelineEditMode
    let projectID: String
    let clipID: String?
}

extension EditorModel {
    var timelineEditableEffects: [ClipEffect] {
        _ = timelineEffectsRevision
        let scope = scopeSourceRange ?? 0...max(0, sourceDuration)
        return ClipEffects.rendered(in: project, clipID: activeClip?.id)
            .filter { $0.end > scope.lowerBound && $0.start < scope.upperBound }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    static func effectName(_ effect: ClipEffect) -> String {
        rowTitle(.init(id: effect.id, decision: .overlay, action: .effect(effect), reason: ""))
    }

    /// A title over the range or the selected words (issue #41), else from the playhead for 2 s.
    func addTimelineTitle(_ draft: String) throws {
        let bounds = scopeSourceRange ?? 0...max(0, recordingTimelineDuration)
        let range = timelineActionRange
        let start = (range?.lowerBound ?? sourceTime).clamped(to: bounds)
        let end = min(range?.upperBound ?? start + 2, bounds.upperBound, recordingTimelineDuration)
        guard capabilities.edit, end > start else { throw ClipEffectError.invalidEntry("Move the playhead inside the clip to add a title.") }
        let id = ClipEffects.nextID(.title, existing: Set(project.clipEffects.map(\.id)))
        let title = ClipEffect(id: id, clipId: activeClip?.id, kind: .title, start: start, end: end,
                               text: draft.trimmingCharacters(in: .whitespacesAndNewlines), position: .top)
        let next = try ClipEffects.adding([title], to: project)
        replace(next, name: "Add title")
        adjustAskClaudeEffect(fromTimeline: id)
    }

    var timelineCanCut: Bool {
        capabilities.edit && timelineRange == nil && (!selectedWordIDs.isSubset(of: cutWordIDs) || !selectedPauseIDs.isSubset(of: cutPauseIDs))
    }

    var timelineTrimBounds: ClosedRange<Int>? {
        guard let clip = activeClip else { return nil }
        guard clip.parts != nil else { return scopeBounds }
        return clip.playPartIndices(in: words)?[selectedStoryPartIndex]
    }

    var timelineTrimTitle: String { activeClip?.parts == nil ? "Trim clip" : "Trim part \(selectedStoryPartIndex + 1)" }
    var timelineCanTrim: Bool { capabilities.edit && timelineTrimBounds != nil }

    func openTimelineEditor(_ mode: TimelineEditMode, effectID: String? = nil) {
        guard !isLeaving, panelTask?.confirm == nil, mode != .trim || timelineCanTrim else {
            if timelineEditor == nil { timelineEffectID = nil }
            return
        }
        timelineEffectID = effectID
        timelineEditor = TimelineEditorRoute(mode: mode, projectID: project.id, clipID: activeClip?.id)
        let shell = (window?.windowController as? ShellWindowController)?.shell ?? app.shell
        if let onShowPanelJob { onShowPanelJob(.timelineEdit) }
        else if shell.editor === self, !shell.viewerShown { shell.toggleViewer() }
        focusedPane = .panel
        paneFocusRequest += 1
        _ = shell.chromeFocus?.focus(.panel)
    }

    func resetTimelineEditor() {
        timelineEditor = nil
        timelineEffectID = nil
    }

    func finishTimelineEditor(in shell: WorkspaceShell) {
        resetTimelineEditor()
        focusedPane = shell.layout.timelineVisible ? .timeline : .transcript
        paneFocusRequest += 1
        if shell.chromeFocus?.focus(focusedPane) != true, focusedPane == .transcript {
            focusTranscript(in: window)
        }
    }
}

/// Keep the edit actions above the scrollable tracks, including when E1 is off screen.
@MainActor struct TimelineEditBar: View {
    let model: EditorModel
    var compact = false
    var body: some View {
        Group {
            if compact {
                Menu("Edit") {
                    Button("Titles & effects…") { model.openTimelineEditor(.effects) }
                    Button("\(model.timelineTrimTitle)…") { model.openTimelineEditor(.trim) }.disabled(!model.timelineCanTrim)
                    Button("Cut selection") { model.cutSelection() }.disabled(!model.timelineCanCut)
                }.fixedSize().controlSize(.small)
                .accessibilityLabel("Timeline edits")
                .columnLayoutEvidence("timeline.editMenu")
            } else {
                HStack(spacing: 12) {
                    Button { model.openTimelineEditor(.effects) } label: {
                        Label("Titles & effects", systemImage: "textformat")
                    }
                    Button { model.openTimelineEditor(.trim) } label: { Label(model.timelineTrimTitle, systemImage: "timeline.selection") }
                        .disabled(!model.timelineCanTrim)
                        .help("Adjust the first or last word")
                    Divider().frame(height: 14)
                    Button { model.cutSelection() } label: { Label("Cut selection", systemImage: "scissors") }
                        .disabled(!model.timelineCanCut).help("Cut the selected words and pauses (Delete). Undo with ⌘Z.")
                        .columnLayoutEvidence("timeline.cutSelection")
                    if model.selectedWordIDs.isEmpty && model.selectedPauseIDs.isEmpty {
                        Text("Drag across the waveform to select words or a pause.")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    } else {
                        let words = model.selectedWordIDs.count, pauses = model.selectedPauseIDs.count
                        Text([words == 0 ? nil : "\(words) \(words == 1 ? "word" : "words")", pauses == 0 ? nil : "\(pauses) \(pauses == 1 ? "pause" : "pauses")"].compactMap { $0 }.joined(separator: ", "))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless).controlSize(.small).font(.callout)
                .padding(.horizontal, 10).frame(height: TimelineMetrics.editBar)
            }
        }
    }
}

@MainActor struct TimelineEditorPanel: View {
    let model: EditorModel
    let shell: WorkspaceShell
    let route: TimelineEditorRoute
    @FocusState private var panelFocused: Bool
    @State private var newTitle = ""
    @State private var error: String?

    var body: some View {
        let effects = model.timelineEditableEffects
        let selected = effects.first { $0.id == model.timelineEffectID }
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch route.mode {
                    case .trim: TimelineTrimControls(model: model, route: route)
                    case .effects: effectControls(effects, selected: selected)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(selected?.id)
            Divider()
            HStack {
                Spacer()
                Button("Done", action: finish)
                    .accessibilityIdentifier("voxclip.timeline.edit.done")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .font(.callout)
        .modifier(EditorPaneFocus(model: model, pane: .panel, focus: $panelFocused))
        .onExitCommand(perform: finish)
        .task(id: selected?.id) {
            if model.focusedPane == .panel { panelFocused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.timeline.edit.panel")
    }

    @ViewBuilder private func effectControls(_ effects: [ClipEffect], selected: ClipEffect?) -> some View {
        if let selected {
            Button { model.timelineEffectID = nil } label: { Label("All effects", systemImage: "chevron.backward") }
            let title = EditorModel.effectName(selected)
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ProjectEffectControls(model: model, effect: selected, title: title).disabled(!model.capabilities.edit)
        } else {
            Text("Titles & effects").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Add a title at the playhead").font(.subheadline)
            ViewThatFits(in: .horizontal) {
                HStack { titleField.frame(minWidth: 100); addButton }
                VStack(alignment: .leading, spacing: 6) { titleField; addButton }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            Divider()
            if effects.isEmpty { Text("No titles or effects in this view.").foregroundStyle(.secondary) }
            else {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(effects) { effect in
                        Button { model.adjustAskClaudeEffect(fromTimeline: effect.id) } label: {
                            HStack {
                                Text(effect.text.map { "\(EditorModel.effectName(effect)): \($0)" } ?? EditorModel.effectName(effect)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(String(format: "%.2f s", model.timelineTime(source: effect.start, on: model.timelineAxis))).monospacedDigit().fixedSize()
                                Image(systemName: "chevron.forward")
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private var titleField: some View {
        TextField("Title text", text: $newTitle).onSubmit(add).disabled(!model.capabilities.edit)
    }
    private var addButton: some View { Button("Add title", action: add).disabled(!canAdd) }
    private var canAdd: Bool { model.capabilities.edit && !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func add() {
        guard model.timelineEditor == route, canAdd else { return }
        do { try model.addTimelineTitle(newTitle); newTitle = ""; error = nil }
        catch {
            self.error = error.localizedDescription
            Task { await model.app.logFailure(error, context: .editing) }
        }
    }
    private func finish() {
        guard model.timelineEditor == route else { return }
        model.finishTimelineEditor(in: shell)
    }
}

@MainActor private struct TimelineTrimControls: View {
    let model: EditorModel
    let route: TimelineEditorRoute
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.timelineTrimTitle).font(.headline).accessibilityAddTraits(.isHeader)
            Text("Move either edge one transcript word at a time. Times are in the source recording.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let bounds = model.timelineTrimBounds {
                edge("In", index: bounds.lowerBound, time: model.words[bounds.lowerBound].start, canGoBack: bounds.lowerBound > 0, canGoForward: bounds.lowerBound < bounds.upperBound, start: true)
                edge("Out", index: bounds.upperBound, time: model.words[bounds.upperBound].end, canGoBack: bounds.upperBound > bounds.lowerBound, canGoForward: bounds.upperBound + 1 < model.words.count, start: false)
            }
        }
    }
    private func edge(_ label: String, index: Int, time: Double, canGoBack: Bool, canGoForward: Bool, start: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(label) · \(time, specifier: "%.3f") s").monospacedDigit()
                Text(model.text(model.words[index])).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach([-1, 1], id: \.self) { step in
                Button {
                    guard model.timelineEditor == route, model.timelineCanTrim else { return }
                    model.adjustTrim(start: start, offset: step)
                } label: { Image(systemName: step < 0 ? "chevron.left" : "chevron.right") }
                    .accessibilityLabel("Move \(label) one word \(step < 0 ? "earlier" : "later")")
                    .help("One word \(step < 0 ? "earlier" : "later")").disabled(!(step < 0 ? canGoBack : canGoForward) || !model.capabilities.edit)
            }
        }
    }
}
