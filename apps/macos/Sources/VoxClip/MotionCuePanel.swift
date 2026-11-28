import SwiftUI
import VoxClipCore

/// The existing right-panel job host owns the title/context row. Controls scroll; actions stay pinned.
@MainActor struct MotionCuePanel: View {
    let model: EditorModel
    @Bindable var editing: MotionCueEditing
    let shell: WorkspaceShell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var keyboardWithin: Bool

    var body: some View {
        panelContents
            .modifier(EditorPaneFocus(model: model, pane: .panel))
            .focused($keyboardWithin)
            .onExitCommand { model.closeMotionCueJob(in: shell) }
            .onAppear { keyboardWithin = true }
            .onDisappear(perform: discardDraft)
            .columnLayoutEvidence("motion.keyboard", text: keyboardWithin ? "focused" : "idle")
    }

    private func discardDraft() {
        if model.motionCueEditing === editing { model.motionCueEditing = nil }
    }

    private var panelContents: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pan and zoom").font(VCType.title3.font(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    cueControls
                    keyframeControls
                    note(Self.guidance).columnLayoutEvidence("motion.note", text: Self.guidance)
                    if reduceMotion {
                        note(Self.reduceMotionNote).columnLayoutEvidence("motion.reduceMotion", text: Self.reduceMotionNote)
                    }
                    note("Original audio and source word timings stay unchanged.")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .font(VCType.callout.font())
        .foregroundStyle(DesignValues.color("text.primary"))
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Motion editor")
        .accessibilityIdentifier("voxclip.motion.panel")
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    /// The how-to shows under Reduce Motion too; the extra line says why the preview then shows no zoom.
    static let guidance = "Raise Zoom, then Horizontal and Vertical choose what stays in view. Apply, then play the cue to see it."
    static let reduceMotionNote = "Reduce Motion is on, so the preview shows no pan or zoom. Export includes it."

    private var cueControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Cue", selection: Binding(get: { editing.draft.original?.id ?? "" }, set: {
                editing.chooseCue($0, model: model)
            })) {
                Text("New motion cue").tag("")
                ForEach(model.clipMotionCues) { cue in
                    Text("\(timecode(cue.sourceStart))–\(timecode(cue.sourceEnd)) source").tag(cue.id)
                }
            }
            .frame(height: 24)
            .accessibilityIdentifier("voxclip.motion.cue")
            sourceField("Source start (s)", value: $editing.draft.sourceStart, id: "start")
            sourceField("Source end (s)", value: $editing.draft.sourceEnd, id: "end")
            note("Source seconds, inside the open clip. Cut video is skipped.")
        }
    }

    private var keyframeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Keyframe", selection: Binding(get: { editing.selectedFrame }, set: {
                editing.selectFrame($0, model: model)
            })) {
                ForEach(editing.draft.keyframes.indices, id: \.self) { index in
                    Text(editing.keyframeLabel(index)).tag(index)
                }
            }
            .frame(height: 24)
            .accessibilityHint("Shows this keyframe's moment in the paused viewer.")
            .accessibilityIdentifier("voxclip.motion.keyframe")
            if editing.draft.keyframes.indices.contains(editing.selectedFrame) {
                frameControls
            }
            HStack(spacing: 8) {
                Button("Add keyframe", action: editing.addKeyframe)
                    .disabled(editing.draft.keyframes.count >= MotionCue.maximumKeyframes
                        || editing.selectedFrame >= editing.draft.keyframes.count - 1)
                    .accessibilityHint("Adds a keyframe halfway to the next keyframe. Maximum eight.")
                Button("Remove keyframe", action: editing.removeKeyframe)
                    .disabled(editing.selectedFrame == 0 || editing.selectedFrame >= editing.draft.keyframes.count - 1
                        || editing.draft.keyframes.count <= 2)
            }
            .frame(height: 24)
        }
    }

    private var frameControls: some View {
        VStack(spacing: 4) {
            frameRow(.progress, range: 0...1, step: 0.001)
                .disabled(editing.selectedFrame == 0 || editing.selectedFrame == editing.draft.keyframes.count - 1)
            frameRow(.scale, range: 1...MotionCue.maximumScale, step: 0.01)
            frameRow(.anchorX, range: 0...1, step: 0.01)
            frameRow(.anchorY, range: 0...1, step: 0.01)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = editing.footerMessage(model: model) {
                note(message).accessibilityIdentifier("voxclip.motion.status")
                    .columnLayoutEvidence("motion.status", text: message)
            }
            HStack(spacing: 4) {
                PanelButton(action: PanelAction(id: "motion.delete", title: "Delete cue") {
                    editing.deleteCue(model: model)
                }, kind: .ghost)
                .disabled(editing.draft.original == nil || model.motionCueUnavailableReason != nil)
                .accessibilityIdentifier("voxclip.motion.delete")
                Spacer(minLength: 0)
                PanelButton(action: PanelAction(id: "motion.cancel", title: "Cancel") {
                    model.closeMotionCueJob(in: shell)
                }, kind: .ghost)
                .accessibilityIdentifier("voxclip.motion.cancel")
                PanelButton(action: PanelAction(id: "motion.apply", title: editing.draft.original == nil ? "Add cue" : "Apply") {
                    editing.apply(model: model)
                }, kind: .primary)
                .disabled(model.motionCueValidation(editing.draft) != nil || !editing.hasUnappliedChanges)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("voxclip.motion.apply")
                .columnLayoutEvidence("motion.apply")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
        .columnLayoutEvidence("motion.footer")
    }

    private func sourceField(_ title: String, value: Binding<Double>, id: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(DesignValues.color("text.secondary"))
            Spacer(minLength: 0)
            TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder).frame(width: 88)
                .accessibilityLabel(title).accessibilityIdentifier("voxclip.motion.\(id)")
        }.frame(height: 24)
    }

    private func frameRow(_ field: MotionCueEditing.FrameField, range: ClosedRange<Double>, step: Double) -> some View {
        let title = field.title
        return HStack(spacing: 8) {
            Text(title).foregroundStyle(DesignValues.color("text.secondary")).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { editing.frameValue(field) }, set: { editing.setFrameValue(field, to: $0) }),
                   in: range, step: step) { Text(title) }
                .labelsHidden().accessibilityValue("\(Int(editing.frameValue(field) * 100)) percent")
                .accessibilityHint(field.hint)
            Text("\(editing.frameValue(field) * 100, specifier: "%.0f")%")
                .frame(width: 36, alignment: .trailing)
        }.frame(height: 24)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            .fixedSize(horizontal: false, vertical: true)
    }
}
