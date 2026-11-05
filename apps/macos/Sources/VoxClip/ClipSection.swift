import SwiftUI
import VoxClipCore

/// The Clip section (design.md §6.8), folded under Music in the Captions panel's look: an uppercase heading that names what
/// is changed ("1.25× · Muted"), then Speed (a slider and presets), Shape, Look and Volume, and More ▸ with the fades, Mute
/// source, Flip and Rotate. It shows only while a clip is open, every control acts, and nothing opens a pop-up. Each change is
/// one undo step; a slider commits once when its drag ends, and keyboard or VoiceOver steps commit each step.
@MainActor struct ClipSection: View {
    @Bindable var model: EditorModel
    @State private var expanded: Bool
    @State private var more: Bool
    @State private var drafts = Drafts()

    /// Folded by default; captures and tests open it, with More, from the start.
    init(model: EditorModel, expanded: Bool = false, more: Bool = false) {
        self.model = model
        _expanded = State(initialValue: expanded)
        _more = State(initialValue: more)
    }

    struct Drafts: Equatable {
        var speed: Double?, gain: Double?, fadeIn: Double?, fadeOut: Double?
        var dragging: Set<String> = []
    }

    var body: some View {
        let _ = model.projectRevision
        if let controls = model.currentClipControls {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(DesignValues.color("line.default")).frame(height: 1).padding(.top, VCTokens.spacingLabelGap)
                    .accessibilityHidden(true)
                heading(controls)
                if expanded { rows(controls) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voxclip.clip")
            .columnLayoutEvidence("captions.clip")
        }
    }

    // MARK: Heading

    private func heading(_ controls: ProjectClipControls) -> some View {
        Button { withAnimation(nil) { expanded.toggle() } } label: {
            HStack(spacing: VCTokens.spacingRowGap) {
                Text("Clip").textCase(.uppercase).font(VCType.small.font(.semibold)).tracking(0.55)
                    .foregroundStyle(DesignValues.color("text.tertiary"))
                if let summary = Self.summary(controls) {
                    Text(summary).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
                        .accessibilityIdentifier("voxclip.clip.summary")
                }
                Spacer(minLength: VCTokens.spacingRowGap)
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignValues.color("text.tertiary"))
            }
            .frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clip controls" + (Self.summary(controls).map { ", " + $0 } ?? ""))
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("voxclip.clip.heading")
    }

    /// What differs from the defaults, most visible first: "1.25× · 9:16 · Muted · −3 dB · Muted source".
    static func summary(_ controls: ProjectClipControls) -> String? {
        var parts: [String] = []
        if controls.speed != 1 { parts.append(ProjectClipControls.speedLabel(controls.speed)) }
        if let shape = controls.shape { parts.append(shape.rawValue) }
        if controls.look != .original { parts.append(controls.look.label) }
        if controls.muteSource { parts.append("Source muted") } else if controls.gainDb != 0 { parts.append(MusicSection.gainLabel(controls.gainDb)) }
        if controls.fadeInSeconds > 0 || controls.fadeOutSeconds > 0 { parts.append("Fades") }
        if controls.flipHorizontal { parts.append("Flipped") }
        if controls.rotationDegrees != 0 { parts.append("\(controls.rotationDegrees)°") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Rows

    @ViewBuilder private func rows(_ controls: ProjectClipControls) -> some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            CaptionPropertyRow("Speed", marker: "clip.speed") {
                slider(key: "speed", value: drafts.speed ?? controls.speed, range: ProjectClipControls.speedRange, step: 0.05,
                       label: "Speed", text: ProjectClipControls.speedLabel(drafts.speed ?? controls.speed),
                       draft: { drafts.speed = $0 }) { model.setSpeed($0) }
            }
            chips(ProjectClipControls.speedPresets.map { ($0, ProjectClipControls.speedLabel($0)) }, selected: controls.speed,
                  identifier: "speed", name: "Speed") { model.setSpeed($0) }
            CaptionPropertyRow("Shape", marker: "clip.shape") {
                Text(controls.shape == nil ? "As the project" : "This clip only").font(VCType.small.font())
                    .foregroundStyle(DesignValues.color("text.tertiary"))
            }
            chips(ClipShape.allCases.map { ($0, $0.rawValue) }, selected: controls.shape, identifier: "shape", name: "Shape") { shape in
                // The chosen shape again goes back to the project's frame.
                model.setShape(controls.shape == shape ? nil : shape)
            }
            CaptionPropertyRow("Look", marker: "clip.look") {
                Text(controls.look == .original ? "As filmed" : controls.look.label).font(VCType.small.font())
                    .foregroundStyle(DesignValues.color("text.tertiary"))
            }
            chips(ClipLook.allCases.map { ($0, $0.label) }, selected: controls.look, identifier: "look", name: "Look") { model.setLook($0) }
            CaptionPropertyRow("Volume", marker: "clip.volume") {
                if controls.muteSource {
                    // Muted, the level has nothing to act on: say so, with the way back.
                    HStack(spacing: VCTokens.spacingLabelGap) {
                        Text("Source muted").font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                        Button("Unmute") { model.setMute(false) }.buttonStyle(.link).font(VCType.callout.font())
                            .accessibilityIdentifier("voxclip.clip.unmute")
                    }
                } else {
                    slider(key: "gain", value: drafts.gain ?? controls.gainDb, range: ProjectClipControls.gainRange, step: 0.5,
                           label: "Clip volume", text: MusicSection.gainLabel(drafts.gain ?? controls.gainDb),
                           draft: { drafts.gain = $0 }) { model.setGain($0) }
                }
            }
            Button { more.toggle() } label: {
                HStack(spacing: VCTokens.spacingLabelGap) {
                    Text("More").font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    Image(systemName: more ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignValues.color("text.tertiary"))
                }
                .frame(height: CaptionsPanelMetrics.propertyRowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More clip controls")
            .accessibilityValue(more ? "expanded" : "collapsed")
            .accessibilityIdentifier("voxclip.clip.more")
            if more { moreRows(controls) }
            Text("Speed keeps the voice\u{2019}s pitch; captions, cuts and music follow it.")
                .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voxclip.clip.footer")
        }
        .padding(.bottom, VCTokens.spacingRowGap)
        .disabled(!model.capabilities.edit)
    }

    @ViewBuilder private func moreRows(_ controls: ProjectClipControls) -> some View {
        CaptionPropertyRow("Fade in", marker: "clip.fadeIn") {
            slider(key: "fadeIn", value: drafts.fadeIn ?? controls.fadeInSeconds, range: ProjectClipControls.fadeRange, step: 0.1,
                   label: "Fade in", text: Self.seconds(drafts.fadeIn ?? controls.fadeInSeconds),
                   draft: { drafts.fadeIn = $0 }) { model.setFade(in: $0) }
        }
        CaptionPropertyRow("Fade out", marker: "clip.fadeOut") {
            slider(key: "fadeOut", value: drafts.fadeOut ?? controls.fadeOutSeconds, range: ProjectClipControls.fadeRange, step: 0.1,
                   label: "Fade out", text: Self.seconds(drafts.fadeOut ?? controls.fadeOutSeconds),
                   draft: { drafts.fadeOut = $0 }) { model.setFade(out: $0) }
        }
        CaptionPropertyRow("Mute source", marker: "clip.mute") {
            Toggle("Mute source", isOn: Binding(get: { controls.muteSource }, set: { model.setMute($0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityIdentifier("voxclip.clip.mute")
        }
        CaptionPropertyRow("Flip", marker: "clip.flip") {
            Toggle("Flip", isOn: Binding(get: { controls.flipHorizontal }, set: { model.setFlip($0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityIdentifier("voxclip.clip.flip")
        }
        if model.canRotateClip {
            CaptionPropertyRow("Rotate", marker: "clip.rotate") {
                Button { model.setRotation(controls.rotationDegrees + 90) } label: {
                    HStack(spacing: VCTokens.spacingLabelGap) {
                        Image(systemName: "rotate.right").font(.system(size: 11))
                        Text(controls.rotationDegrees == 0 ? "90°" : "\(controls.rotationDegrees)° \u{2192} \((controls.rotationDegrees + 90) % 360)°")
                            .font(VCType.callout.font()).monospacedDigit()
                    }
                    .foregroundStyle(DesignValues.color("text.primary"))
                    .frame(height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rotate 90 degrees clockwise")
                .accessibilityValue("\(controls.rotationDegrees) degrees")
                .accessibilityIdentifier("voxclip.clip.rotate")
            }
        }
    }

    // MARK: Controls

    /// A mini slider with its value; a drag commits once at its end, a keyboard or VoiceOver step commits straight away.
    private func slider(key: String, value: Double, range: ClosedRange<Double>, step: Double, label: String, text: String,
                        draft: @escaping (Double?) -> Void, commit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: VCTokens.spacingLabelGap) {
            Slider(value: Binding(get: { value }, set: { next in
                if drafts.dragging.contains(key) { draft(next) } else { commit(next) }
            }), in: range) { editing in
                if editing { drafts.dragging.insert(key) } else {
                    drafts.dragging.remove(key)
                    if let pending = pendingDraft(key) { commit(pending) }
                    draft(nil)
                }
            }
            .controlSize(.mini)
            .accessibilityLabel(label)
            .accessibilityValue(text)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(min(range.upperBound, value + step))
                case .decrement: commit(max(range.lowerBound, value - step))
                @unknown default: break
                }
            }
            .accessibilityIdentifier("voxclip.clip.\(key)")
            Text(text).font(VCType.small.font()).monospacedDigit().foregroundStyle(DesignValues.color("text.tertiary"))
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func pendingDraft(_ key: String) -> Double? {
        switch key {
        case "speed": drafts.speed
        case "gain": drafts.gain
        case "fadeIn": drafts.fadeIn
        case "fadeOut": drafts.fadeOut
        default: nil
        }
    }

    /// A row of capsule chips (the clip style card's chip, one size smaller); the chosen one is marked selected.
    private func chips<Value: Hashable>(_ options: [(Value, String)], selected: Value?, identifier: String, name: String,
                                        choose: @escaping (Value) -> Void) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ClipStyleFlowLayout(spacing: VCTokens.spacingChipGap) {
                ForEach(options, id: \.0) { option in
                    let on = option.0 == selected
                    Button { choose(option.0) } label: {
                        Text(option.1).font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(DesignValues.color("text.primary"))
                            .padding(.horizontal, VCTokens.spacingRowGap).frame(minHeight: 22)
                            .background(DesignValues.color(on ? "bg.selectedRow" : "bg.muted"), in: .capsule)
                            .overlay(Capsule().strokeBorder(DesignValues.color(on ? "line.strong" : "line.default")))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name) \(option.1)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("voxclip.clip.\(identifier).\(option.1)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }

    static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
}
