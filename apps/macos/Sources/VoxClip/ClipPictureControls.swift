import SwiftUI
import VoxClipCore

@MainActor struct ClipPictureControls: View {
    let model: EditorModel

    init(model: EditorModel) { self.model = model }

    var body: some View {
        let _ = model.projectRevision
        if model.project.media.source.video != nil, let controls = model.currentClipControls {
            ClipPictureGradeControls(model: model, controls: controls)
                .id(controls.clipId)
                .disabled(!model.capabilities.edit)
        }
    }

    static func label(for controls: ProjectClipControls) -> String {
        ClipColorPreset.matching(controls)?.label ?? "Custom"
    }
}

@MainActor private struct ClipPictureGradeControls: View {
    let model: EditorModel
    let controls: ProjectClipControls
    @State private var fineTuneOverride: Bool?

    var body: some View {
        let preset = ClipColorPreset.matching(controls)
        let expanded = fineTuneOverride ?? (preset == nil)
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            CaptionPropertyRow("Look", marker: "clip.look") {
                if preset == nil {
                    Text("Custom").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                        .accessibilityIdentifier("voxclip.clip.color.custom")
                }
            }
            if controls.colorAdjustments != nil {
                Text("Choosing a look replaces fine-tuning.")
                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ClipSection.chips(ClipColorPreset.allCases.map { ($0, $0.label) }, selected: preset,
                              identifier: "look", name: "Look") { model.setColorPreset($0, clipID: controls.clipId) }
            disclosure(expanded: expanded)
            if expanded {
                ClipColorSliders(controls: controls) { control, value in
                    model.setColorAdjustment(control, value: value, clipID: controls.clipId)
                }
            }
        }
    }

    private func disclosure(expanded: Bool) -> some View {
        HStack(spacing: VCTokens.spacingLabelGap) {
            Button { fineTuneOverride = !expanded } label: {
                HStack(spacing: VCTokens.spacingLabelGap) {
                    Text("Fine-tune").font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignValues.color("text.tertiary"))
                }
                .frame(height: CaptionsPanelMetrics.propertyRowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fine-tune color")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .accessibilityIdentifier("voxclip.clip.color.adjust")
            Spacer(minLength: 0)
            if expanded {
                Button("Reset") { model.resetColorAdjustments(clipID: controls.clipId) }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .disabled(controls.colorAdjustments == nil)
                    .accessibilityLabel("Reset color adjustments")
                    .accessibilityIdentifier("voxclip.clip.color.reset")
            }
        }
    }
}

@MainActor private struct ClipColorSliders: View {
    let controls: ProjectClipControls
    let commit: (ClipColorAdjustments.Control, Int) -> Void

    var body: some View {
        let adjustments = controls.colorAdjustments ?? .neutral
        ForEach(ClipColorAdjustments.Control.allCases, id: \.self) { control in
            if control != .saturation || controls.look != .bw {
                CaptionPropertyRow(control.label, marker: "clip.color.\(control.rawValue)") {
                    ClipColorSlider(control: control, point: adjustments[control]) { commit(control, $0) }
                }
            }
        }
    }
}

@MainActor private struct ClipColorSlider: View {
    let control: ClipColorAdjustments.Control
    let point: Int
    let commit: (Int) -> Void
    @State private var isDragging = false
    @State private var draft: Int?

    var body: some View {
        let bounds = ClipColorAdjustments.range
        let value = draft ?? point
        let label = value == 0 ? "0" : value > 0 ? "+\(value)" : "−\(-value)"
        HStack(spacing: VCTokens.spacingLabelGap) {
            Slider(value: Binding(get: { Double(value) }, set: { next in
                let updated = Int(next.rounded())
                if isDragging { draft = updated } else { commit(updated) }
            }), in: Double(bounds.lowerBound)...Double(bounds.upperBound), step: 1) { editing in
                isDragging = editing
                if !editing {
                    if let draft { commit(draft) }
                    draft = nil
                }
            }
            .controlSize(.mini)
            .accessibilityLabel(control.label)
            .accessibilityValue(label)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(min(bounds.upperBound, point + 1))
                case .decrement: commit(max(bounds.lowerBound, point - 1))
                @unknown default: break
                }
            }
            .accessibilityIdentifier("voxclip.clip.color.\(control.rawValue)")
            Text(label).font(VCType.small.font()).monospacedDigit().foregroundStyle(DesignValues.color("text.tertiary"))
                .frame(width: 36, alignment: .trailing).accessibilityHidden(true)
        }
    }
}
