import SwiftUI
import AVFoundation
import VoxClipCore
import VoxClipMedia

@MainActor struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView { let view = PlayerLayerView(); view.playerLayer.player = player; return view }
    func updateNSView(_ view: PlayerLayerView, context: Context) { view.playerLayer.player = player }
}

@MainActor final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true; layer?.addSublayer(playerLayer); playerLayer.videoGravity = .resizeAspectFill }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}

func viewerStageSize(ratio: Double, innerWidth: CGFloat, columnHeight: CGFloat, rewriting: Bool) -> CGSize {
    let aspect = max(0.01, ratio)
    let width = max(1, innerWidth)
    let cap: CGFloat = rewriting && columnHeight < 760 ? 124 : aspect <= 1 ? 320 : .greatestFiniteMagnitude
    let height = min(width / aspect, cap)
    return CGSize(width: min(width, height * aspect), height: height)
}

@MainActor struct ViewerSection: View {
    @Bindable var model: EditorModel
    var columnHeight: CGFloat = 800
    @State private var innerWidth: CGFloat = 328
    var ratio: Double {
        switch model.project.export.aspect {
        case .source:
            let size = model.project.media.source.video.map(OutputSizing.orientedSize) ?? PixelSize(width: 16, height: 9)
            return Double(size.width) / Double(max(1, size.height))
        case .landscape: return 16 / 9
        case .portrait: return 9 / 16
        case .square: return 1
        }
    }
    var body: some View {
        let size = viewerStageSize(ratio: ratio, innerWidth: innerWidth, columnHeight: columnHeight, rewriting: model.rewrite != nil)
        VStack(spacing: 10) {
            ZStack {
                Rectangle().fill(DesignValues.color("stage"))
                if !model.document.demo, model.mediaResolved, !model.mediaUnreadable, model.project.media.source.video != nil, let native = model.nativePreview {
                    PlayerSurface(player: native.player)
                } else { ViewerStandIn(model: model) }
                if !model.document.demo, model.previewError == nil, let style = model.app.styles.first(where: { $0.id == model.project.captions.styleId }), style.position.userDraggable {
                    CaptionPositionOverlay(model: model, style: style)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: 10))
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stageLabel)
            viewerRow
            HStack(spacing: 8) {
                Text("Frame").font(.system(size: 13)).foregroundStyle(DesignValues.color("text.secondary"))
                Picker("Frame", selection: Binding(get: { model.project.export.aspect }, set: { model.setAspect($0) })) {
                    ForEach([AspectRatio.portrait, .square, .landscape, .source], id: \.self) { aspect in
                        Text(aspect == .source ? "Original" : aspect.rawValue)
                            .fontWeight(model.project.export.aspect == aspect ? .semibold : .regular).tag(aspect)
                    }
                }.labelsHidden().pickerStyle(.segmented).frame(height: 24)
            }
        }
        .padding(VCTokens.spacingPanePaddingMacos)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { innerWidth = max(1, $0 - 32) }
        .tint(DesignValues.accentText)
        .focusable()
        .onKeyPress(characters: CharacterSet(charactersIn: " jklpico[]")) { key in model.transport(key.characters, shift: key.modifiers.contains(.shift)); return .handled }
    }
    private var stageLabel: String {
        let scope = model.activeClip.flatMap { model.clipNumber($0.id) }.map { "clip \($0)" } ?? "full take"
        let ai = model.voiceLabPlan?.pieces.contains { $0.kind == .synth } == true ? ", contains AI-modified speech" : ""
        return "Video preview, \(scope)\(ai)\(model.mediaStatus.spokenState.map { ", " + $0 } ?? "")"
    }
    private var viewerRow: some View {
        HStack(spacing: 4) {
            if model.voiceLabPlan?.pieces.contains(where: { $0.kind == .synth }) == true {
                Text("AI modified").font(.system(size: 11)).padding(.horizontal, 4).padding(.vertical, 2)
                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(DesignValues.accentText, lineWidth: 1) }
            }
            HStack(spacing: 0) {
                Text(timecode(model.playhead))
                Text(" / \(timecode(model.duration))").foregroundStyle(DesignValues.color("text.secondary"))
                if model.playbackRate != 1 { Text(" · \(model.playbackRate.formatted())×").foregroundStyle(DesignValues.color("text.secondary")) }
            }
            .font(DesignValues.mono(12)).monospacedDigit().fixedSize()
            .accessibilityElement(children: .ignore).accessibilityLabel("Playback time")
            .accessibilityIdentifier("voxclip.viewer.time")
            .accessibilityValue("\(timecode(floor(model.playhead))) of \(timecode(model.duration))")
            Spacer(minLength: 4)
            Button { model.transport("j") } label: { transportSymbol("gobackward.3", fallback: "gobackward").frame(width: 28, height: 28) }
                .help("Back 3 Seconds (J)").accessibilityLabel("Back 3 seconds")
            Button { model.transport(" ") } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 34, height: 34) }
                .background(DesignValues.color("bg.sunken"), in: Circle()).help("Play/Pause (Space)").accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Button { model.seek(source: min(model.sourceDuration, model.sourceTime + 3)) } label: { transportSymbol("goforward.3", fallback: "goforward").frame(width: 28, height: 28) }
                .help("Forward 3 Seconds").accessibilityLabel("Forward 3 seconds")
        }.buttonStyle(.plain).foregroundStyle(DesignValues.color("text.primary")).frame(height: 34)
    }
    @ViewBuilder private func transportSymbol(_ name: String, fallback: String) -> some View {
        if NSImage(named: name) != nil { Image(name).renderingMode(.template) }
        else { Image(systemName: fallback).overlay { Text("3").font(.system(size: 7, weight: .semibold)).offset(y: 1) } }
    }
}

@MainActor private struct ViewerStandIn: View {
    let model: EditorModel
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(backdrop)
                if model.mediaStatus == .missing || model.mediaStatus == .unreadable {
                    VStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(MediaChipTokens.warningGlyph)
                        Text(model.mediaStatus == .missing ? "Video not found" : "Video can’t be read").font(.system(size: 13, weight: .semibold))
                        Text(model.sourceURL.lastPathComponent).font(DesignValues.mono(11)).opacity(0.66).lineLimit(1)
                    }.foregroundStyle(DesignValues.color("overlay.foreground"))
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.36)
                } else if model.mediaStatus == .demo || model.mediaStatus == .audioOnly {
                    Canvas { context, size in
                        let span = model.project.export.aspect == .portrait ? 5.0 : 6.0
                        let scale = size.width / span
                        for word in model.words where word.end >= model.sourceTime - span / 2 && word.start <= model.sourceTime + span / 2 && !model.cutWordIDs.contains(word.id) {
                            let current = word.start <= model.sourceTime && word.end > model.sourceTime
                            let left = size.width / 2 + (word.start - model.sourceTime) * scale
                            let width = max(2, (word.end - word.start) * scale - 2)
                            let height: CGFloat = current ? 12 : 6
                            let rect = CGRect(x: left, y: size.height * 0.42 - height / 2, width: width, height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.white.opacity(current ? 1 : word.end < model.sourceTime ? 0.62 : 0.26)))
                        }
                        let caret = CGRect(x: size.width / 2, y: size.height * 0.42 - 15, width: 1, height: 30)
                        context.fill(Path(caret), with: .color(.white.opacity(0.55)))
                    }
                }
                if let label = chip { MediaChip(text: label).padding(6) }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private var chip: String? {
        switch model.mediaStatus {
        case .demo: "Demo · no video"
        case .audioOnly: "Audio only"
        case .transcribing(_, let stage): stage.chipText
        default: nil
        }
    }
    private var backdrop: Color {
        guard let style = model.app.cardStyle(for: model.project),
              let hex = CaptionCardLook.backdrop(style, previewBackground: model.app.previewBackgrounds[style.id]) else { return DesignValues.color("stage") }
        return Color(nsColor: DesignValues.parse(hex))
    }
}

@MainActor private struct CaptionPositionOverlay: View {
    let model: EditorModel
    let style: CaptionStyle
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
        let resolved = (try? style.resolved(overrides: model.project.captions.overrides, frame: size)) ?? style
        return CaptionPosition(x: resolved.position.x, y: resolved.position.y)
    }
    var body: some View {
        GeometryReader { geometry in
            if dragged != nil {
                Canvas { context, size in
                    let unsafe = DesignValues.color("stage").opacity(0.3), guide = DesignValues.color("overlay.foreground").opacity(0.6)
                    switch aspectClass {
                    case "portrait":
                        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.12)), with: .color(unsafe))
                        context.fill(Path(CGRect(x: 0, y: size.height * 0.78, width: size.width, height: size.height * 0.22)), with: .color(unsafe))
                        context.fill(Path(CGRect(x: size.width * 0.88, y: 0, width: size.width * 0.12, height: size.height)), with: .color(unsafe))
                    case "square", "landscape":
                        let bottom = aspectClass == "square" ? 0.12 : 0.10
                        context.fill(Path(CGRect(x: 0, y: size.height * (1 - bottom), width: size.width, height: size.height * bottom)), with: .color(unsafe))
                    default: break
                    }
                    for fraction in [1.0 / 3, 0.5, 2.0 / 3] {
                        var line = Path(); line.move(to: CGPoint(x: size.width * fraction, y: 0)); line.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                        line.move(to: CGPoint(x: 0, y: size.height * fraction)); line.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                        context.stroke(line, with: .color(guide), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            RoundedRectangle(cornerRadius: 4).stroke(DesignValues.color("overlay.foreground").opacity(hovering || dragged != nil ? 0.8 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: max(80, geometry.size.width * 0.75), height: max(32, geometry.size.height * 0.12))
                .contentShape(Rectangle())
                .position(x: (dragged?.x ?? CGFloat(position.x)) * geometry.size.width, y: (dragged?.y ?? CGFloat(position.y)) * geometry.size.height)
                .onHover { hovering = $0 }
                .gesture(DragGesture(coordinateSpace: .named("caption-stage")).updating($dragged) { value, state, _ in
                    state = normalized(value.location, size: geometry.size)
                }.onEnded { value in move(normalized(value.location, size: geometry.size)) })
                .accessibilityLabel("Caption position. Drag to move captions.")
                .accessibilityAdjustableAction { direction in move(CGPoint(x: position.x, y: min(1, max(0, position.y + (direction == .increment ? 0.05 : -0.05))))) }
        }.coordinateSpace(name: "caption-stage")
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

@MainActor struct TimelineStrip: View {
    @Bindable var model: EditorModel
    /// With the viewer collapsed the strip leads with Play and the edited time (§5.3).
    var compactTransport = false
    @State private var hoveredSource: Double?
    var body: some View {
        HStack(spacing: 12) {
            if compactTransport {
                Button { model.transport(" ") } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).background(DesignValues.color("bg.sunken"), in: Circle())
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                (Text(timecode(model.playhead)) + Text(" / \(timecode(model.duration))").foregroundStyle(DesignValues.color("text.secondary")))
                    .font(DesignValues.mono(12)).monospacedDigit().fixedSize()
            }
            GeometryReader { geometry in
                TimelineTrack(projection: model.timeline, edited: model.editedTimeline).equatable()
                    .overlay { TimelinePlayhead(model: model) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let ratio = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                        let source = model.editedTimeline ? model.renderTimeline?.sourceTime(ratio * model.duration) ?? 0 : ratio * model.sourceDuration
                        if NSEvent.modifierFlags.contains(.shift), let word = model.word(at: source, nearest: true) { model.seek(source: word.start) } else { model.seek(source: source) }
                    })
                    .onTapGesture(count: 2) { location in
                        let ratio = min(1, max(0, location.x / max(1, geometry.size.width)))
                        let source = model.editedTimeline ? model.renderTimeline?.sourceTime(ratio * model.duration) ?? 0 : ratio * model.sourceDuration
                        let wordIDs = model.word(at: source).map { model.cutWordIDs.contains($0.id) ? [$0.id] : [] } ?? []
                        let pauseIDs = model.pause(at: source).map { model.cutPauseIDs.contains($0.id) ? [$0.id] : [] } ?? []
                        if !wordIDs.isEmpty || !pauseIDs.isEmpty { model.apply(.restoreSelection(ids: wordIDs + pauseIDs), name: "Restore cut") }
                    }
                    .onContinuousHover { phase in
                        if case .active(let point) = phase {
                            let time = min(1, max(0, point.x / max(1, geometry.size.width))) * (model.editedTimeline ? model.duration : model.sourceDuration)
                            hoveredSource = model.editedTimeline ? model.renderTimeline?.sourceTime(time) ?? time : time
                        } else { hoveredSource = nil }
                    }
                    .help(hoveredSource.map { source in (model.word(at: source).map { model.text($0) + " · " } ?? "") + timecode(source) } ?? "Drag to scrub. Shift-drag snaps to word starts. Double-click a cut to restore it.")
            }
            VStack(alignment: .trailing, spacing: 3) {
                Picker("Timeline time", selection: $model.editedTimeline) { Text("Source").tag(false); Text("Edited").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 130).controlSize(.mini)
            }.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .background(DesignValues.color("bg.surface"))
        .focusable()
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { key in model.step(key.key == .leftArrow ? -1 : 1, sentence: key.modifiers.contains(.shift)); return .handled }
        .onKeyPress(.home) { if let word = model.words.first { model.select(word.id) }; return .handled }
        .onKeyPress(.end) { if let word = model.words.last { model.select(word.id) }; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: " jklpico[]")) { key in model.transport(key.characters); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead")
        .accessibilityValue(compactTransport ? "\(timecode(model.playhead)) of \(timecode(model.duration)) after cuts" : "\(model.summary.cutWordCount + model.summary.cutPauseCount) cuts")
        .accessibilityAdjustableAction { direction in model.step(direction == .increment ? 1 : -1) }
    }
}
