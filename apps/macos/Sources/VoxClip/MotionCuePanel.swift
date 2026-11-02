import AppKit
import SwiftUI
import VoxClipCore

struct MotionCuePanel: View {
    let model: EditorModel
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: MotionCueDraft
    @State private var selectedCueID: String
    @State private var selectedFrame = 0
    @State private var status: String?

    init(model: EditorModel, cueID: String? = nil, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        let initial: MotionCueDraft
        if let existing = model.motionCueDraft(id: cueID) { initial = existing }
        else {
            let empty = MotionCue(id: "", clipID: "", sourceStart: 0, sourceEnd: 0)
            initial = MotionCueDraft(cue: empty)
        }
        _draft = State(initialValue: initial)
        _selectedCueID = State(initialValue: initial.original?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Motion").font(.headline)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            if let reason = model.motionCueUnavailableReason {
                Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                editor
            }
        }
        .padding(16)
        .frame(width: 360)
        .accessibilityIdentifier("voxclip.motion.panel")
        .onChange(of: model.activeClip?.id) { _, _ in selectCue("") }
        .onChange(of: model.project.motionCues) { _, _ in
            selectCue(model.clipMotionCues.contains(where: { $0.id == selectedCueID }) ? selectedCueID : "")
        }
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Cue", selection: $selectedCueID) {
                Text("New motion cue").tag("")
                ForEach(model.clipMotionCues) { cue in
                    Text("\(cue.sourceStart, specifier: "%.2f")–\(cue.sourceEnd, specifier: "%.2f") s source").tag(cue.id)
                }
            }
            .onChange(of: selectedCueID) { _, value in selectCue(value) }
            .accessibilityIdentifier("voxclip.motion.cue")
            HStack {
                TextField("Source start (s)", value: $draft.sourceStart, format: .number.precision(.fractionLength(2)))
                    .accessibilityIdentifier("voxclip.motion.start")
                TextField("Source end (s)", value: $draft.sourceEnd, format: .number.precision(.fractionLength(2)))
                    .accessibilityIdentifier("voxclip.motion.end")
            }
            .textFieldStyle(.roundedBorder)
            Text("Source seconds, inside the open clip. Cut video is skipped.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Keyframe", selection: $selectedFrame) {
                ForEach(draft.keyframes.indices, id: \.self) { index in
                    Text("\(index + 1) · \(draft.keyframes[index].progress * 100, specifier: "%.0f")%").tag(index)
                }
            }
            .accessibilityIdentifier("voxclip.motion.keyframe")
            if draft.keyframes.indices.contains(selectedFrame) {
                frameControls
            }
            HStack {
                Button("Add keyframe", action: addKeyframe)
                    .disabled(draft.keyframes.count >= MotionCue.maximumKeyframes || selectedFrame >= draft.keyframes.count - 1)
                    .accessibilityHint("Adds a keyframe halfway to the next keyframe. Maximum eight.")
                Button("Remove keyframe", action: removeKeyframe)
                    .disabled(selectedFrame == 0 || selectedFrame >= draft.keyframes.count - 1 || draft.keyframes.count <= 2)
            }
            Text(reduceMotion ? "Reduce Motion: preview stays still. Export includes your authored motion." : "Smooth pan and zoom. Apply to update preview and export.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Original audio and source word timings stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = status ?? model.motionCueValidation(draft) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voxclip.motion.status")
            }
            HStack {
                Button("Delete cue", role: .destructive) {
                    if let original = draft.original, model.deleteMotionCue(original) {
                        selectCue("")
                        status = "Motion cue deleted. Undo restores it."
                    } else {
                        status = "This cue changed or is no longer editable. Choose it again before deleting."
                    }
                }
                .disabled(draft.original == nil)
                .accessibilityIdentifier("voxclip.motion.delete")
                Spacer()
                Button(draft.original == nil ? "Add cue" : "Apply") {
                    guard model.applyMotionCue(draft) else {
                        status = model.motionCueValidation(draft) ?? "No changes to apply."
                        return
                    }
                    let id = draft.id
                    selectCue(id)
                    status = "Motion cue saved. Undo restores the previous state."
                }
                .disabled(model.motionCueValidation(draft) != nil || draft.original == draft.cue)
                .accessibilityIdentifier("voxclip.motion.apply")
            }
        }
    }

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let frame = draft.keyframes[selectedFrame]
            Text("Position in cue: \(frame.progress * 100, specifier: "%.1f")%")
            Slider(value: frameBinding(.progress), in: 0...1, step: 0.001) { Text("Position in cue") }
                .disabled(selectedFrame == 0 || selectedFrame == draft.keyframes.count - 1)
            Text("Zoom: \(frame.scale * 100, specifier: "%.0f")%")
            Slider(value: frameBinding(.scale), in: 1...MotionCue.maximumScale, step: 0.01) { Text("Zoom") }
                .accessibilityValue("\(Int(frame.scale * 100)) percent")
            Text("Horizontal framing: \(frame.anchorX * 100, specifier: "%.0f")%")
            Slider(value: frameBinding(.anchorX), in: 0...1, step: 0.01) { Text("Horizontal framing") }
                .accessibilityHint("Zero keeps the left edge; one hundred percent keeps the right edge. Visible when zoomed in.")
            Text("Vertical framing: \(frame.anchorY * 100, specifier: "%.0f")%")
            Slider(value: frameBinding(.anchorY), in: 0...1, step: 0.01) { Text("Vertical framing") }
                .accessibilityHint("Zero keeps the top edge; one hundred percent keeps the bottom edge. Visible when zoomed in.")
        }
    }

    private enum FrameField: Equatable { case progress, scale, anchorX, anchorY }

    private func frameBinding(_ field: FrameField) -> Binding<Double> {
        Binding {
            guard draft.keyframes.indices.contains(selectedFrame) else { return 0 }
            let frame = draft.keyframes[selectedFrame]
            switch field {
            case .progress: return frame.progress
            case .scale: return frame.scale
            case .anchorX: return frame.anchorX
            case .anchorY: return frame.anchorY
            }
        } set: { value in
            guard draft.keyframes.indices.contains(selectedFrame) else { return }
            let frame = draft.keyframes[selectedFrame]
            var progress = frame.progress
            if field == .progress, selectedFrame > 0, selectedFrame < draft.keyframes.count - 1 {
                progress = min(draft.keyframes[selectedFrame + 1].progress - 0.0001, max(draft.keyframes[selectedFrame - 1].progress + 0.0001, value))
            }
            draft.keyframes[selectedFrame] = MotionKeyframe(progress: progress,
                scale: field == .scale ? value : frame.scale,
                anchorX: field == .anchorX ? value : frame.anchorX,
                anchorY: field == .anchorY ? value : frame.anchorY)
            status = nil
        }
    }

    private func selectCue(_ id: String) {
        guard let next = model.motionCueDraft(id: id.isEmpty ? nil : id) else { return }
        selectedCueID = next.original?.id ?? ""
        draft = next
        selectedFrame = min(1, next.keyframes.count - 1)
        status = nil
    }

    private func addKeyframe() {
        guard draft.keyframes.count < MotionCue.maximumKeyframes, selectedFrame < draft.keyframes.count - 1 else { return }
        let first = draft.keyframes[selectedFrame]
        let last = draft.keyframes[selectedFrame + 1]
        guard last.progress - first.progress >= 0.0004 else { return }
        let progress = (first.progress + last.progress) / 2
        let transform = draft.cue.transform(atSourceTime: draft.sourceStart + progress * (draft.sourceEnd - draft.sourceStart))
        draft.keyframes.insert(MotionKeyframe(progress: progress, scale: transform.scale, anchorX: transform.anchorX, anchorY: transform.anchorY), at: selectedFrame + 1)
        selectedFrame += 1
        status = nil
    }

    private func removeKeyframe() {
        guard selectedFrame > 0, selectedFrame < draft.keyframes.count - 1, draft.keyframes.count > 2 else { return }
        draft.keyframes.remove(at: selectedFrame)
        selectedFrame -= 1
        status = nil
    }
}

@MainActor final class MotionCuePopover {
    let popover = NSPopover()

    init(model: EditorModel, cueID: String?) {
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: MotionCuePanel(model: model, cueID: cueID) { [weak popover] in popover?.performClose(nil) })
    }

    func show(relativeTo view: NSView) {
        popover.show(relativeTo: NSRect(x: view.bounds.midX, y: 0, width: 1, height: view.bounds.height), of: view, preferredEdge: .minY)
    }

    func close() { popover.performClose(nil) }
}
