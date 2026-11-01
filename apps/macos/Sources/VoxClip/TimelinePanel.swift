import AppKit
import SwiftUI
import Observation
import VoxClipCore

// The v2 timeline panel (ux/v2 notes.md §6, impl-plan V7a, V7b and V9): a 28 pt toolbar over the
// AppKit lanes (TimelineCanvas.swift). It fills the shell's bottom panel, which ⌘J hides.

/// The bottom panel: its toolbar and the lanes. F6 stops here (EditorPaneFocus); ← → and
/// Home / End work from the panel as from the lanes.
@MainActor struct TimelinePanel: View {
    let model: EditorModel
    let shell: WorkspaceShell
    @State private var zoom = TimelineZoom()
    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(model: model, shell: shell, zoom: zoom)
            TimelineCanvas(model: model, shell: shell, zoom: zoom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignValues.color("bg.window"))
        .modifier(EditorPaneFocus(model: model, pane: .timeline))
        .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end], phases: .down) { press in
            let code: UInt16 = switch press.key {
            case .leftArrow: 123
            case .rightArrow: 124
            case .home: 115
            default: 119
            }
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            let handled = zoom.canvas?.interaction.key(code, shift: press.modifiers.contains(.shift))
                ?? TimelineCanvasView.handleKey(code, shift: press.modifiers.contains(.shift), model: model)
            return handled ? .handled : .ignored
        }
    }
}

/// The toolbar (notes.md §6, f1): the TIMELINE tab, Edited / Source, the transport ⏮ ▶ ⏭,
/// the timecode readout, the src TC and the selection's length; Hide (⌘J) at the end.
/// Zoom, track height, snapping and Maximize follow notes.md §6; EXPORTS waits for V11b. When the
/// panel is too narrow the src TC goes first, then the selection's length (impl-plan §3.5).
@MainActor struct TimelineToolbar: View {
    let model: EditorModel
    let shell: WorkspaceShell
    var zoom = TimelineZoom()
    var body: some View {
        GeometryReader { geometry in
        HStack(spacing: 6) {
            Text("Timeline".uppercased())
                .font(VCType.small.font(.semibold)).tracking(0.55)
                .foregroundStyle(DesignValues.color("text.primary"))
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignValues.color("text.primary")).frame(height: 1).padding(.horizontal, 6) }
                .accessibilityLabel("Timeline").accessibilityAddTraits(.isHeader)
            Spacer().frame(width: 10)
            TimelineAxisPicker(model: model)
            Spacer().frame(width: 14)
            TimelineToolbarButton(symbol: "backward.end.fill", name: "Go to start", help: "Go to Start (Home)") { model.seekTimelineBoundary(end: false) }
                .accessibilityIdentifier("voxclip.timeline.start")
            TimelineToolbarButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", name: (model.isPlaying ? EditorIconAction.pause : .play).name,
                                  help: "Play/Pause (Space)", primary: true) { model.transport(" ") }
                .accessibilityIdentifier("voxclip.timeline.play")
            TimelineToolbarButton(symbol: "forward.end.fill", name: "Go to end", help: "Go to End (End)") { model.seekTimelineBoundary(end: true) }
                .accessibilityIdentifier("voxclip.timeline.end")
            Spacer().frame(width: 8)
            TimelineReadout(model: model)
            if geometry.size.width >= 920 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Spacer().frame(width: 10)
                    TimelineSourceReadout(model: model)
                    Spacer().frame(width: 18)
                    TimelineSelectionLength(model: model)
                }
                HStack(spacing: 6) {
                    Spacer().frame(width: 10)
                    TimelineSelectionLength(model: model)
                }
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if geometry.size.width >= 720 {
                Button { model.timelineSnapping.toggle() } label: {
                    TimelineSnapGlyph().stroke(DesignValues.color(model.timelineSnapping ? "text.primary" : "text.tertiary"), lineWidth: 1)
                        .frame(width: 12, height: 12).frame(width: 24, height: 22)
                        .background(model.timelineSnapping ? DesignValues.color("bg.selectedRow") : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                    .buttonStyle(.plain).help("Snap to words").accessibilityLabel("Snapping")
                    .accessibilityValue(model.timelineSnapping ? "On" : "Off")
                    .accessibilityIdentifier("voxclip.timeline.snapping")
                    .columnLayoutEvidence("timeline.snapping")
            }
            if geometry.size.width >= 840 {
                Menu {
                    ForEach(TrackHeight.allCases, id: \.self) { height in
                        Button { shell.layout.trackHeight = height } label: {
                            if shell.layout.trackHeight == height { Label(height.label, systemImage: "checkmark") } else { Text(height.label) }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 12)).frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Track Height (S / M / L)")
                .accessibilityLabel("Track height").accessibilityValue(shell.layout.trackHeight.label)
                .columnLayoutEvidence("timeline.trackHeight")
            }
            TimelineZoomControl(zoom: zoom, slider: geometry.size.width >= 800)
            TimelineToolbarButton(symbol: shell.layout.timelineMaximized ? "chevron.down" : "chevron.up", name: shell.layout.timelineMaximized ? "Restore Timeline" : "Maximize Timeline", help: shell.layout.timelineMaximized ? "Restore Timeline" : "Maximize Timeline") { shell.layout.timelineMaximized.toggle() }
                .accessibilityIdentifier("voxclip.timeline.maximize")
                .columnLayoutEvidence("timeline.maximize")
            TimelineToolbarButton(symbol: "chevron.down.square", name: EditorIconAction.hideTimeline.name, help: "Hide Timeline (⌘J)") { shell.toggleTimeline() }
                .disabled(!shell.layout.rightVisible)
                .accessibilityIdentifier("voxclip.timeline.hide")
                .columnLayoutEvidence("timeline.hide")
        }
        .padding(.leading, 10).padding(.trailing, 6)
        }
        .frame(height: TimelineMetrics.toolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
    }
}

/// Edited / Source (notes.md §6): one state with Show cuts, so it flips the transcript too.
/// A 22 pt control on `timeline.lane` with a `line.default` outline; the on segment is
/// `bg.selectedRow` with `text.primary`, the other `text.tertiary`, 11 pt. VoiceOver reads it
/// as the two-option picker "Timeline time" (design §5.2).
@MainActor struct TimelineAxisPicker: View {
    let model: EditorModel
    var body: some View {
        let source = model.showsCuts
        HStack(spacing: 0) {
            segment("Edited", on: !source) { model.showsCuts = false }
            segment("Source", on: source) { model.showsCuts = true }
        }
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignValues.color("timeline.lane")))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("line.default"), lineWidth: 1))
        .fixedSize()
        .accessibilityRepresentation {
            Picker("Timeline time", selection: Binding(get: { model.showsCuts }, set: { model.showsCuts = $0 })) {
                Text("Edited").tag(false)
                Text("Source").tag(true)
            }
            .pickerStyle(.segmented)
        }
        .accessibilityIdentifier("voxclip.timeline.axis")
    }

    /// An 18 pt segment, 8 pt in, inside a 22 pt target.
    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(VCType.small.font())
                .foregroundStyle(DesignValues.color(on ? "text.primary" : "text.tertiary"))
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(on ? DesignValues.color("bg.selectedRow") : .clear, in: RoundedRectangle(cornerRadius: 4))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A 24 × 22 icon button in the toolbar, t3 (t1 for play), named for VoiceOver.
@MainActor private struct TimelineToolbarButton: View {
    let symbol: String
    let name: String
    let help: String
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(DesignValues.color(primary ? "text.primary" : "text.tertiary"))
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(name)
    }
}

/// The SF Mono 13 Medium readout (notes.md §2): the playhead on the timeline's axis as
/// HH:MM:SS:FF, its leading zero groups dimmed. Only this view follows the playhead.
@MainActor struct TimelineReadout: View {
    let model: EditorModel
    var body: some View {
        let axis = model.timelineAxis
        let time = model.timelinePlayhead(on: axis)
        let parts = SMPTETimecode.format(seconds: time)
        // Two fixed-pitch runs side by side read as one timecode.
        HStack(spacing: 0) {
            Text(parts.dimPrefix).foregroundStyle(DesignValues.color("text.disabled"))
            Text(parts.value).foregroundStyle(DesignValues.color("text.primary"))
        }
            .font(VCType.body.mono(.medium)).tracking(0.13).fixedSize()
            .columnLayoutEvidence("timeline.readout", text: parts.dimPrefix + parts.value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback time")
            .accessibilityValue("\(timecode(floor(time))) of \(timecode(model.timelineLength(on: axis)))")
            .accessibilityIdentifier("voxclip.timeline.time")
    }
}

/// The take time under the playhead on Edited, beside the readout (notes.md §2, §6): "src"
/// and SF Mono 11 `HH:MM:SS:FF` in `text.tertiary`, leading zero groups `text.disabled`;
/// "src AI voice" while the playhead is in an AI patch. Source view shows take time in the
/// readout, so it has none. It follows the playhead, as the readout does.
@MainActor struct TimelineSourceReadout: View {
    let model: EditorModel
    var body: some View {
        if model.timelineAxis == .edited {
            let ai = model.playheadInAIVoice
            let time = model.sourceTime
            HStack(spacing: 4) {
                Text("src").font(VCType.small.font())
                if ai {
                    Text("AI voice").font(VCType.small.font())
                } else {
                    let parts = SMPTETimecode.format(seconds: time)
                    HStack(spacing: 0) {
                        Text(parts.dimPrefix).foregroundStyle(DesignValues.color("text.disabled"))
                        Text(parts.value)
                    }
                    .font(VCType.small.mono())
                }
            }
            .foregroundStyle(DesignValues.color("text.tertiary"))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Source time")
            .accessibilityValue(ai ? "AI voice" : timecode(floor(time)))
            .accessibilityIdentifier("voxclip.timeline.sourceTime")
            .columnLayoutEvidence("timeline.sourceReadout")
        }
    }
}

/// "4.4 s selected" (notes.md §2, f1): an 8 pt `tint.default` square, the length on the
/// timeline's axis in SF Mono 11 `text.primary` and "selected" in 11 `text.tertiary`. Only
/// while words are selected.
@MainActor struct TimelineSelectionLength: View {
    let model: EditorModel
    var body: some View {
        if let selection = model.timelineSelection(on: model.timelineAxis) {
            let length = selection.upperBound - selection.lowerBound
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(DesignValues.color("tint.default")).frame(width: 8, height: 8)
                HStack(spacing: 3) {
                    Text(SecondsText.format(length)).font(VCType.small.mono()).foregroundStyle(DesignValues.color("text.primary"))
                    Text("selected").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: "%.1f seconds selected", locale: Locale(identifier: "en_US_POSIX"), length))
            .accessibilityIdentifier("voxclip.timeline.selectionLength")
            .columnLayoutEvidence("timeline.selectionLength")
        }
    }
}

/// The lanes in SwiftUI.
@MainActor struct TimelineCanvas: NSViewRepresentable {
    let model: EditorModel
    var shell: WorkspaceShell? = nil
    var zoom: TimelineZoom? = nil
    func makeNSView(context: Context) -> TimelineCanvasView {
        let view = TimelineCanvasView(model: model, shell: shell)
        zoom?.attach(view)
        return view
    }
    func updateNSView(_ view: TimelineCanvasView, context: Context) {}
    static func dismantleNSView(_ view: TimelineCanvasView, coordinator: ()) { view.tearDown() }
}


/// Window-local zoom state shared by the native canvas and the toolbar. No undo or save.
@MainActor @Observable final class TimelineZoom {
    var value = 0.0
    weak var canvas: TimelineCanvasView?
    func attach(_ canvas: TimelineCanvasView) {
        self.canvas = canvas
        value = canvas.zoomValue
        canvas.onZoom = { [weak self] value in if self?.value != value { self?.value = value } }
    }
    func step(_ direction: Double) { canvas?.zoom(by: pow(1.4, direction)) }
    func set(_ value: Double) { canvas?.setZoom(value) }
}

@MainActor private struct TimelineZoomControl: View {
    let zoom: TimelineZoom
    let slider: Bool
    var body: some View {
        HStack(spacing: 2) {
            TimelineToolbarButton(symbol: "minus", name: "Zoom timeline out", help: "Zoom Timeline Out (⌘−)") { zoom.step(-1) }
                .columnLayoutEvidence("timeline.zoom.out")
            if slider {
                Slider(value: Binding(get: { zoom.value }, set: { zoom.set($0) }), in: 0...1)
                    .controlSize(.mini).frame(width: 64)
                    .accessibilityLabel("Timeline zoom")
                    .accessibilityIdentifier("voxclip.timeline.zoom")
                    .columnLayoutEvidence("timeline.zoom.slider")
            }
            TimelineToolbarButton(symbol: "plus", name: "Zoom timeline in", help: "Zoom Timeline In (⌘=)") { zoom.step(1) }
                .columnLayoutEvidence("timeline.zoom.in")
        }
    }
}


/// The U-shaped magnet in the approved toolbar; no dependency on a newer SF Symbol.
private struct TimelineSnapGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: 1))
        path.addLine(to: CGPoint(x: 2, y: 7))
        path.addCurve(to: CGPoint(x: 10, y: 7), control1: CGPoint(x: 2, y: 12), control2: CGPoint(x: 10, y: 12))
        path.addLine(to: CGPoint(x: 10, y: 1))
        path.addLine(to: CGPoint(x: 7, y: 1))
        path.addLine(to: CGPoint(x: 7, y: 7))
        path.addQuadCurve(to: CGPoint(x: 5, y: 7), control: CGPoint(x: 6, y: 9))
        path.addLine(to: CGPoint(x: 5, y: 1))
        path.closeSubpath()
        path.move(to: CGPoint(x: 2, y: 4)); path.addLine(to: CGPoint(x: 5, y: 4))
        path.move(to: CGPoint(x: 7, y: 4)); path.addLine(to: CGPoint(x: 10, y: 4))
        return path
    }
}
