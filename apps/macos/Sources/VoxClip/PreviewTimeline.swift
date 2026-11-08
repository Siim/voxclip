import SwiftUI
import AVFoundation
import VoxClipCore
import VoxClipMedia

@MainActor struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    /// The layer held a ready item without showing a frame and was re-attached (design.md §5.4.4 g).
    var onDisplayStall: (() -> Void)?
    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(); view.playerLayer.player = player; view.onDisplayStall = onDisplayStall; return view
    }
    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.onDisplayStall = onDisplayStall
    }
}

/// The display side of a black stage: the player's item is ready but its layer has shown no frame for `limit` ticks
/// in a window. Answers true once per item, when the layer should be re-attached and the stall logged.
struct PlayerDisplayWatch {
    static let limit = 4
    private(set) var stalledTicks = 0
    /// Held weakly: a later item at a freed item's address still gets its own chance.
    private(set) weak var handled: AnyObject?
    /// The item being counted: a new item starts its own count.
    private weak var counting: AnyObject?
    mutating func tick(item: AnyObject?, itemReady: Bool, layerReady: Bool, inWindow: Bool) -> Bool {
        guard inWindow, let item, itemReady, !layerReady else { stalledTicks = 0; return false }
        if counting !== item { counting = item; stalledTicks = 0 }
        stalledTicks += 1
        guard stalledTicks >= Self.limit, handled !== item else { return false }
        handled = item; stalledTicks = 0
        return true
    }
}

@MainActor final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var onDisplayStall: (() -> Void)?
    private var watch = PlayerDisplayWatch()
    private var watchTask: Task<Void, Never>?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true; layer?.addSublayer(playerLayer); playerLayer.videoGravity = .resizeAspectFill }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); playerLayer.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchTask?.cancel(); watchTask = nil
        guard window != nil else { return }
        // Once a second while on screen: a ready item whose layer shows nothing is re-attached once and reported.
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.checkDisplay()
            }
        }
    }
    func checkDisplay() {
        let item = playerLayer.player?.currentItem
        guard watch.tick(item: item, itemReady: item?.status == .readyToPlay,
                         layerReady: playerLayer.isReadyForDisplay, inWindow: window != nil && !isHiddenOrHasHiddenAncestor && bounds.width > 1 && bounds.height > 1)
        else { return }
        let player = playerLayer.player
        playerLayer.player = nil; playerLayer.player = player
        onDisplayStall?()
    }
}

/// The one tag on the stage (impl-plan V4): "AI voice" while the frame plays AI-voiced
/// speech (f4), "AI modified" while the scope holds some, else the stand-in's media chip.
enum ViewerTag: Equatable {
    case aiVoice, aiModified, media(String)
    var text: String {
        switch self {
        case .aiVoice: "AI voice"
        case .aiModified: "AI modified"
        case .media(let text): text
        }
    }
}

/// The viewer (ux/v2 notes.md §1, impl-plan V4): a fixed box the column's width wide and
/// 16:9 of it high (404 × 227 at 1280), on the stage colour, with the frame fitted inside
/// it, so a portrait or square frame is pillarboxed (f5). Only captions, titles and one tag
/// are drawn on the stage. While the timeline panel is hidden, a hover transport along the
/// box's bottom edge carries play, the timecode and Edited / Source (notes.md §1).
@MainActor struct ViewerSection: View {
    /// The viewer's own keyboard stops: the box, which takes the transport keys, and the
    /// hover transport's controls.
    enum Focus: Hashable { case box, play, axis }
    @Bindable var model: EditorModel
    let columnWidth: CGFloat
    /// The box's height: 16:9 of the width unless a short column gives less (`PanelHost`).
    let boxHeight: CGFloat?
    let timelineVisible: Bool
    @State private var hovering: Bool
    /// A caption is being dragged on the stage; the transport steps aside meanwhile.
    @State private var captionDragging = false
    /// The pane's own focus (`EditorPaneFocus`, the nearest focusable ancestor)…
    @Environment(\.isFocused) private var focused
    /// …and focus inside the viewer, which that ancestor does not see.
    @FocusState private var focus: Focus?
    #if DEBUG
    /// Harnesses put keyboard focus inside the viewer when it appears.
    private var initialFocus: Focus?
    func focusing(_ focus: Focus) -> ViewerSection { var copy = self; copy.initialFocus = focus; return copy }
    #endif
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: EditorModel, columnWidth: CGFloat, boxHeight: CGFloat? = nil, timelineVisible: Bool = true, hovering: Bool = false) {
        self.model = model
        self.columnWidth = columnWidth
        self.boxHeight = boxHeight
        self.timelineVisible = timelineVisible
        _hovering = State(initialValue: hovering)
    }

    /// 16:9 of the column's width, to the nearest point: 227 at 404.
    static func boxHeight(forWidth width: CGFloat) -> CGFloat { (max(0, width) * 9 / 16).rounded() }
    /// The frame at `ratio` (width ÷ height), as large as fits in `box`, in whole points: a
    /// frame within half a point of the box fills it (16:9 in 404 × 227), and 9:16 is 128 wide.
    static func stageSize(ratio: Double, in box: CGSize) -> CGSize {
        let aspect = CGFloat(max(0.01, ratio))
        guard box.width > 0, box.height > 0 else { return .zero }
        if box.width / box.height > aspect { return CGSize(width: min(box.width, (box.height * aspect).rounded()), height: box.height) }
        return CGSize(width: box.width, height: min(box.height, (box.width / aspect).rounded()))
    }
    /// The frame's width ÷ height for `aspect`; Original is the oriented source. The open clip's own shape or quarter turn
    /// (design.md §6.9) wins, as the render does.
    static func ratio(_ project: Project) -> Double {
        let controls = ClipControlsProject.controls(for: project.edits.activeClipId, in: project)
        if let shape = controls?.shape { return Double(shape.size.width) / Double(shape.size.height) }
        switch project.export.aspect {
        case .source:
            let oriented = project.media.source.video.map(OutputSizing.orientedSize) ?? PixelSize(width: 16, height: 9)
            let size = controls?.isQuarterTurn == true ? PixelSize(width: oriented.height, height: oriented.width) : oriented
            return Double(size.width) / Double(max(1, size.height))
        case .landscape: return 16 / 9
        case .portrait: return 9 / 16
        case .square: return 1
        }
    }
    /// The tag for what shows: the AI tags on any stage, the media chip only on the stand-in.
    static func tag(for model: EditorModel, standIn: Bool) -> ViewerTag? {
        let time = model.sourceTime
        if model.project.voiceLab.segments.contains(where: { $0.enabled && $0.replace.start <= time && time < $0.replace.end }) { return .aiVoice }
        // A whole-clip revoice (ADR-R46): every frame of the clip plays the AI voice, the pauses between its parts too.
        if let clip = model.activeClip?.id, WholeClipRevoice.isRevoiced(clipId: clip, in: model.project) { return .aiVoice }
        if model.containsAISpeech(clipID: model.activeClip?.id) { return .aiModified }
        return standIn ? ViewerStandIn.chip(model.mediaStatus).map(ViewerTag.media) : nil
    }
    /// The hover transport shows with the timeline hidden while the pointer is over the
    /// viewer, keyboard focus is on the viewer pane or inside it (the box, Play or Edited /
    /// Source), or VoiceOver runs, so it is never only a hover target. It steps aside while
    /// a caption is dragged, so the caption and the guides show.
    static func showsTransport(timelineVisible: Bool, hovering: Bool, focused: Bool, focusInside: Bool = false, voiceOver: Bool, captionDragging: Bool = false) -> Bool {
        !timelineVisible && !captionDragging && (hovering || focused || focusInside || voiceOver)
    }

    var body: some View {
        // The frame, the scope and the AI segments come from the project, which only projectRevision makes observable.
        let _ = model.projectRevision
        let box = CGSize(width: max(1, columnWidth), height: max(1, boxHeight ?? Self.boxHeight(forWidth: columnWidth)))
        let stage = Self.stageSize(ratio: Self.ratio(model.project), in: box)
        let label = Self.stageLabel(for: model)
        let transport = Self.showsTransport(timelineVisible: timelineVisible, hovering: hovering, focused: focused, focusInside: focus != nil,
            voiceOver: voiceOver, captionDragging: captionDragging)
        ZStack(alignment: .bottom) {
            stageView
                .frame(width: stage.width, height: stage.height)
                .columnLayoutEvidence("viewer.stage", text: label)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
                .accessibilityIdentifier("voxclip.viewer.stage")
                .frame(width: box.width, height: box.height)
            if transport {
                ViewerHoverTransport(model: model, focus: $focus).transition(.opacity)
            }
        }
        .frame(width: box.width, height: box.height)
        .background(DesignValues.color("stage"))
        .clipped()
        .columnLayoutEvidence("viewer.box")
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Double(VCTokens.motionDurationBase) / 1000), value: transport)
        .focusable()
        .focused($focus, equals: .box)
        .onKeyPress(characters: CharacterSet(charactersIn: " jklpico[]")) { key in model.transport(key.characters, shift: key.modifiers.contains(.shift)); return .handled }
        #if DEBUG
        .onAppear { if let initialFocus { focus = initialFocus } }
        #endif
    }
    private var standIn: Bool { !model.stageShowsPlayer }
    private var stageView: some View {
        ZStack {
            Rectangle().fill(DesignValues.color("stage"))
            if !standIn, let native = model.nativePreview {
                PlayerSurface(player: native.player, onDisplayStall: { Task { await model.previewDisplayStalled() } })
            } else { ViewerStandIn(model: model) }
            if model.canMoveCaptions, let style = model.app.styles.first(where: { $0.id == model.activeCaptions.styleId }), style.position.userDraggable {
                CaptionPositionOverlay(model: model, style: style, dragging: $captionDragging)
            }
            if model.askClaude.adjusting != nil {
                GeometryReader { geometry in AskClaudeRectOverlay(model: model, stage: geometry.size) }
            }
            if let message = model.stagePreviewError {
                PreviewFailureNotice(message: message) { Task { await model.reloadPreview() } }
            }
        }
        .overlay(alignment: .topLeading) {
            if let tag = Self.tag(for: model, standIn: standIn) {
                MediaChip(text: tag.text, icon: tag == .aiVoice ? "waveform" : nil, tint: tag == .aiVoice ? DesignValues.color("ai.tint") : nil)
                    .columnLayoutEvidence("viewer.tag")
                    .accessibilityIdentifier("voxclip.viewer.tag")
                    // The media chip repeats the stage label's spoken state.
                    .accessibilityHidden(!(tag == .aiVoice || tag == .aiModified))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }
    /// The stage's accessible label, as before V4: the scope, AI speech, then the media state.
    static func stageLabel(for model: EditorModel) -> String {
        let scope = model.activeClip.flatMap { model.clipNumber($0.id) }.map { "clip \($0)" } ?? "full take"
        let ai = model.containsAISpeech(clipID: model.activeClip?.id) ? ", contains AI-modified speech" : ""
        return "Video preview, \(scope)\(ai)\(model.mediaStatus.spokenState.map { ", " + $0 } ?? "")"
    }
}

/// The viewer's transport while the timeline panel is hidden (notes.md §1: "play and
/// timecode are never lost"): play, the timeline's own readout (`TimelineReadout`,
/// `HH:MM:SS:FF` on its axis) and Edited / Source (Show cuts, which flips the transcript
/// too), in a bar along the box's bottom edge, over the video like the stage's chips.
/// Only Play and Edited / Source take the pointer: a press anywhere else on the bar reaches
/// the stage under it, so a caption placed low can still be dragged.
@MainActor struct ViewerHoverTransport: View {
    @Bindable var model: EditorModel
    let focus: FocusState<ViewerSection.Focus?>.Binding
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let opaque = reduceTransparency || contrast == .increased
        // A narrow column drops the speed beside the readout; VoiceOver still reads it.
        ViewThatFits(in: .horizontal) {
            row(rate: true)
            row(rate: false)
        }
        .padding(.leading, 4).padding(.trailing, 6)
        .frame(height: 32)
        .foregroundStyle(DesignValues.color("overlay.foreground"))
        .background {
            RoundedRectangle(cornerRadius: 6).fill(DesignValues.color(opaque ? "overlay.transportOpaque" : "overlay.scrim")).allowsHitTesting(false)
        }
        .overlay {
            if opaque { RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("line.strong"), lineWidth: 1).allowsHitTesting(false) }
        }
        .environment(\.colorScheme, .dark)
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transport")
        .accessibilityIdentifier("voxclip.viewer.transport")
        .columnLayoutEvidence("viewer.transport")
    }
    private func row(rate: Bool) -> some View {
        HStack(spacing: 6) {
            Button { model.transport(" ") } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play/Pause (Space)")
            .accessibilityLabel((model.isPlaying ? EditorIconAction.pause : .play).name)
            .accessibilityIdentifier("voxclip.viewer.play")
            .focused(focus, equals: .play)
            .columnLayoutEvidence("viewer.play")
            playbackTime(rate: rate).allowsHitTesting(false)
            Spacer(minLength: 4)
            Picker("Timeline time", selection: $model.showsCuts) {
                Text("Edited").tag(false); Text("Source").tag(true)
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
            .accessibilityLabel("Timeline time")
            .accessibilityIdentifier("voxclip.viewer.axis")
            .focused(focus, equals: .axis)
            .columnLayoutEvidence("viewer.axis")
        }
    }
    /// The timeline readout's compact current / length, and the speed when it is not 1×. One accessible element,
    /// `voxclip.viewer.time`: the time on the timeline's axis over that axis' length, then the speed.
    private func playbackTime(rate showsRate: Bool) -> some View {
        let axis = model.timelineAxis
        let current = model.timelinePlayhead(on: axis), total = model.timelineLength(on: axis)
        return HStack(spacing: 6) {
            TimelineReadout(model: model, includesLength: true)
            if showsRate && model.playbackRate != 1 {
                Text("\(model.playbackRate.formatted())×").font(VCType.callout.mono()).monospacedDigit()
                    .foregroundStyle(DesignValues.color("overlay.foreground").opacity(0.66))
            }
        }
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback time")
        .accessibilityIdentifier("voxclip.viewer.time")
        .accessibilityValue("\(timecode(floor(current))) of \(timecode(total))\(model.playbackRate != 1 ? ", \(model.playbackRate.formatted()) times speed" : "")")
    }
}

/// The stage's preview-failed state (design.md §5.4.4 g): the §5.4.6 message cluster on a media plate over the player,
/// centred at 36% of the stage, with the stage's one control, Reload Preview. VoiceOver reads the line inside the stage;
/// the editor announces it once when it appears (no live region of its own).
@MainActor struct PreviewFailureNotice: View {
    let message: String
    let reload: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let opaque = reduceTransparency || contrast == .increased
        GeometryReader { geometry in
            cluster(opaque: opaque)
                .frame(maxWidth: max(0, geometry.size.width - 24))
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.36)
        }
    }

    private func cluster(opaque: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MediaChipTokens.warningGlyph)
                    .accessibilityHidden(true)
                Text(message).font(.system(size: 13, weight: .semibold)).lineSpacing(2)
                    .foregroundStyle(DesignValues.color("overlay.foreground"))
                    .multilineTextAlignment(.leading).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voxclip.viewer.previewError")
            }
            Button("Reload Preview", action: reload)
                .controlSize(.small)
                .accessibilityIdentifier("voxclip.viewer.reloadPreview")
                .columnLayoutEvidence("viewer.reloadPreview")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(opaque ? MediaChipTokens.backgroundOpaque : MediaChipTokens.background, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(contrast == .increased ? MediaChipTokens.foreground
                : opaque ? MediaChipTokens.strokeOpaque : MediaChipTokens.stroke, lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .columnLayoutEvidence("viewer.previewError", text: message)
    }
}

@MainActor private struct ViewerStandIn: View {
    let model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(backdrop)
                if model.mediaStatus == .missing || model.mediaStatus == .unreadable {
                    VStack(spacing: 5) {
                        Image(systemName: model.mediaStatus == .missing ? "video.slash" : "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(MediaChipTokens.warningGlyph)
                        Text(model.mediaStatus == .missing ? "Video not found" : "Can't read this video").font(.system(size: 13, weight: .semibold))
                        Text(model.sourceURL.lastPathComponent).font(DesignValues.mono(11)).opacity(0.66).lineLimit(1)
                    }.foregroundStyle(DesignValues.color("overlay.foreground"))
                        .position(x: geometry.size.width / 2, y: geometry.size.height * (model.project.export.aspect == .portrait ? 0.38 : 0.36))
                } else if model.mediaStatus == .audioOnly, let waveform = model.waveform, !waveform.fine.isEmpty {
                    audiogram(waveform)
                } else if model.mediaStatus == .demo || model.mediaStatus == .audioOnly {
                    Canvas { context, size in
                        let span = model.project.export.aspect == .portrait ? 5.0 : 6.0
                        let centre = reduceMotion ? floor(model.sourceTime / span) * span + span / 2 : model.sourceTime
                        let scale = size.width / span
                        for word in model.words where word.end >= centre - span / 2 && word.start <= centre + span / 2 && !model.cutWordIDs.contains(word.id) {
                            let current = word.start <= model.sourceTime && word.end > model.sourceTime
                            let left = size.width / 2 + (word.start - centre) * scale
                            let width = max(2, (word.end - word.start) * scale - 2)
                            let height: CGFloat = current ? 12 : 6
                            let rect = CGRect(x: left, y: size.height * 0.42 - height / 2, width: width, height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.white.opacity(current ? 1 : word.end < model.sourceTime ? 0.62 : 0.26)))
                        }
                        let caret = CGRect(x: size.width / 2, y: size.height * 0.42 - 15, width: 1, height: 30)
                        context.fill(Path(caret), with: .color(.white.opacity(0.55)))
                    }
                }
                if showsCaptions { StandInCaptions(model: model) }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func audiogram(_ waveform: WaveformData) -> some View {
        Canvas { context, size in
            let portrait = model.project.export.aspect == .portrait
            let span = portrait ? 9.0 : 14.0
            let centre = reduceMotion ? floor(model.sourceTime / span) * span + span / 2 : model.sourceTime
            let baseline = size.height * 0.4
            let maximum = size.height * (portrait ? 0.075 : 0.12)
            for offset in stride(from: CGFloat.zero, to: size.width, by: 3.5) {
                let source = centre + (offset / max(1, size.width) - 0.5) * span
                let finePosition: Double = source / 0.01
                let index: Int = Int(finePosition)
                guard source >= 0, waveform.fine.indices.contains(index) else { continue }
                let amplitude: CGFloat = CGFloat(waveform.fine[index])
                let scaledAmplitude: CGFloat = amplitude * maximum * 2
                let height: CGFloat = max(1, min(maximum, scaledAmplitude))
                let bar = CGRect(x: offset, y: baseline - height, width: 2, height: height * 2)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(.white.opacity(source <= model.sourceTime ? 0.72 : 0.26)))
            }
            let line = CGRect(x: size.width / 2, y: baseline - maximum, width: 1, height: maximum * 2)
            context.fill(Path(line), with: .color(.white.opacity(0.55)))
            context.fill(Path(ellipseIn: CGRect(x: size.width / 2 - 2.5, y: baseline - maximum - 2.5, width: 5, height: 5)), with: .color(.white.opacity(0.55)))
        }
    }
    /// The stand-in's status chip (design §5.4.8), which the viewer shows as its one tag.
    static func chip(_ status: MediaStatus) -> String? {
        switch status {
        case .demo: "Demo · no video"
        case .audioOnly: "Audio only"
        case .transcribing(_, let stage): stage.chipText
        default: nil
        }
    }
    private var backdrop: Color {
        switch model.mediaStatus {
        case .loading, .missing, .unreadable, .transcribing: return DesignValues.color("stage")
        default: break
        }
        guard let style = model.app.cardStyle(for: model.project) else { return DesignValues.color("stage") }
        let scope: CaptionCardScope = model.activeClip.map { .clip($0.id) } ?? .fullTake
        let card = model.cardText(scope, wordsVisible: model.app.bool("general.showPlaceholderWords", fallback: true))
        let standIn = MediaStandIn.resolve(status: model.mediaStatus, hasFrame: false, card: card, styleId: style.id)
        guard case .card = standIn,
              let hex = CaptionCardLook.backdrop(style, previewBackground: model.app.previewBackgrounds[style.id]) else { return DesignValues.color("stage") }
        return Color(nsColor: DesignValues.parse(hex))
    }
    private var showsCaptions: Bool {
        if case .transcribing = model.mediaStatus { return false }
        return true
    }
}

@MainActor private struct StandInCaptions: View {
    let model: EditorModel
    @State private var layout: CaptionLayoutResult?
    var body: some View {
        ZStack {
            Color.clear
            if let layout { StandInCaptionImage(layout: layout, time: model.playhead, pipeline: model.app.captions) }
        }
            .task(id: model.projectRevision) {
                layout = nil
                let request = try? await model.renderRequest()
                guard !Task.isCancelled else { return }
                layout = request?.captionLayout
            }
    }
}

@MainActor private struct StandInCaptionImage: View {
    struct Input: Equatable { let layout: CaptionLayoutResult; let time: Double }
    let layout: CaptionLayoutResult
    let time: Double
    let pipeline: CaptionHandoff
    @State private var image: NSImage?
    var body: some View {
        GeometryReader { geometry in
            if let image { Image(nsImage: image).resizable().frame(width: geometry.size.width, height: geometry.size.height) }
        }
        .task(id: Input(layout: layout, time: time)) {
            let rendered = await pipeline.stage(layout, time: time)
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}

@MainActor private struct CaptionPositionOverlay: View {
    let model: EditorModel
    let style: CaptionStyle
    /// Whether a drag is under way, for the viewer's hover transport.
    @Binding var dragging: Bool
    @GestureState private var dragged: CGPoint?
    @State private var hovering = false
    private var aspectClass: String {
        let size = model.outputSpec().size
        return CaptionStyleResolver.aspect(width: size.width, height: size.height)
    }
    private var position: CaptionPosition {
        let size = model.outputSpec().size
        let preset = CaptionStyleResolver.preset(width: size.width, height: size.height)
        if let preset, let stored = model.project.captions.positionByAspect[preset] { return stored }
        if let stored = model.project.captions.position { return stored }
        let resolved = (try? style.resolved(overrides: model.activeCaptions.overrides, frame: size)) ?? style
        return CaptionPosition(x: resolved.position.x, y: resolved.position.y)
    }
    var body: some View {
        GeometryReader { geometry in
            if dragged != nil {
                Canvas { context, size in
                    let unsafe = DesignValues.color("stage").opacity(0.3), guide = DesignValues.color("overlay.foreground").opacity(0.6)
                    // The bands the export check measures (CaptionSafeZones), and 9:16's button column.
                    for band in CaptionSafeZones.bands(aspectClass: aspectClass) {
                        let depth = size.height * band.fraction
                        let top = band.edge == .top ? 0 : size.height - depth
                        context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: depth)), with: .color(unsafe))
                    }
                    if aspectClass == "portrait" {
                        let side = size.width * CaptionSafeZones.portraitSideFraction
                        context.fill(Path(CGRect(x: size.width - side, y: 0, width: side, height: size.height)), with: .color(unsafe))
                    }
                    for fraction in [1.0 / 3, 0.5, 2.0 / 3] {
                        var line = Path(); line.move(to: CGPoint(x: size.width * fraction, y: 0)); line.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                        line.move(to: CGPoint(x: 0, y: size.height * fraction)); line.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                        context.stroke(line, with: .color(guide), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true).columnLayoutEvidence("caption.guides")
            }
            RoundedRectangle(cornerRadius: 4).stroke(DesignValues.color("overlay.foreground").opacity(hovering || dragged != nil ? 0.8 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: max(80, geometry.size.width * 0.75), height: max(32, geometry.size.height * 0.12))
                .contentShape(Rectangle())
                .columnLayoutEvidence("caption.handle")
                .position(x: (dragged?.x ?? CGFloat(position.x)) * geometry.size.width, y: (dragged?.y ?? CGFloat(position.y)) * geometry.size.height)
                .onHover { hovering = $0 }
                .gesture(DragGesture(coordinateSpace: .named("caption-stage")).updating($dragged) { value, state, _ in
                    state = normalized(value.location, size: geometry.size)
                }.onEnded { value in move(normalized(value.location, size: geometry.size)) })
                .accessibilityLabel("Caption position. Drag to move captions.")
                .accessibilityIdentifier("voxclip.caption.position")
                .accessibilityAdjustableAction { direction in move(CGPoint(x: position.x, y: min(1, max(0, position.y + (direction == .increment ? 0.05 : -0.05))))) }
        }.coordinateSpace(name: "caption-stage")
            .onChange(of: dragged != nil) { _, active in dragging = active }
            .onDisappear { dragging = false }
    }
    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        func snap(_ value: Double) -> Double {
            let clamped = min(1, max(0, value))
            return [1.0 / 3, 0.5, 2.0 / 3].first { abs($0 - clamped) < 0.025 } ?? clamped
        }
        return CGPoint(x: snap(point.x / max(1, size.width)), y: snap(point.y / max(1, size.height)))
    }
    private func move(_ point: CGPoint) {
        var project = model.project
        CaptionFineTuning.position(&project.captions, aspect: model.captionPreset, point: CaptionPosition(x: point.x, y: point.y))
        model.replace(project, name: "Move captions")
    }
}
