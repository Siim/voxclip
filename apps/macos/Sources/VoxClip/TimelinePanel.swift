import AppKit
import SwiftUI
import VoxClipCore

// The v2 timeline panel (ux/v2 notes.md §6, impl-plan V7a): a 28 pt toolbar over the AppKit
// lanes (TimelineCanvas.swift). It fills the shell's bottom panel, which ⌘J hides.

/// The bottom panel: its toolbar and the lanes. F6 stops here (EditorPaneFocus); ← → and
/// Home / End work from the panel as from the lanes.
@MainActor struct TimelinePanel: View {
    let model: EditorModel
    let shell: WorkspaceShell
    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(model: model, shell: shell)
            TimelineCanvas(model: model)
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
            return TimelineCanvasView.handleKey(code, shift: press.modifiers.contains(.shift), model: model) ? .handled : .ignored
        }
    }
}

/// The toolbar (notes.md §6): the TIMELINE tab, play and the timecode readout; Hide (⌘J)
/// at the end. Edited / Source, ⏮ ⏭, the src TC and the selection length arrive with V7b;
/// zoom, track height and Maximize with V9; EXPORTS with V11b.
@MainActor struct TimelineToolbar: View {
    let model: EditorModel
    let shell: WorkspaceShell
    var body: some View {
        HStack(spacing: 6) {
            Text("Timeline".uppercased())
                .font(VCType.small.font(.semibold)).tracking(0.55)
                .foregroundStyle(DesignValues.color("text.primary"))
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignValues.color("text.primary")).frame(height: 1).padding(.horizontal, 6) }
                .accessibilityLabel("Timeline").accessibilityAddTraits(.isHeader)
            Spacer().frame(width: 14)
            TimelineToolbarButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", name: (model.isPlaying ? EditorIconAction.pause : .play).name,
                                  help: "Play/Pause (Space)", primary: true) { model.transport(" ") }
                .accessibilityIdentifier("voxclip.timeline.play")
            Spacer().frame(width: 2)
            TimelineReadout(model: model)
            Spacer(minLength: 0)
            TimelineToolbarButton(symbol: "chevron.down.square", name: EditorIconAction.hideTimeline.name, help: "Hide Timeline (⌘J)") { shell.toggleTimeline() }
                .disabled(!shell.layout.rightVisible)
                .accessibilityIdentifier("voxclip.timeline.hide")
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: TimelineMetrics.toolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback time")
            .accessibilityValue("\(timecode(floor(time))) of \(timecode(model.timelineLength(on: axis)))")
            .accessibilityIdentifier("voxclip.timeline.time")
    }
}

/// The lanes in SwiftUI.
@MainActor struct TimelineCanvas: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> TimelineCanvasView { TimelineCanvasView(model: model) }
    func updateNSView(_ view: TimelineCanvasView, context: Context) {}
    static func dismantleNSView(_ view: TimelineCanvasView, coordinator: ()) { view.tearDown() }
}
