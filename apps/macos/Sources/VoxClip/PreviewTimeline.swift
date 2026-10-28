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
    @State private var innerWidth: CGFloat = 1
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
                if model.canMoveCaptions, let style = model.app.styles.first(where: { $0.id == model.project.captions.styleId }), style.position.userDraggable {
                    CaptionPositionOverlay(model: model, style: style)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: 10))
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(stageLabel)
            viewerRow
            HStack(spacing: 8) {
                Text("Frame").font(.system(size: 13)).foregroundStyle(DesignValues.color("text.secondary")).fixedSize()
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
        .onGeometryChange(for: CGFloat.self) { (geometry: GeometryProxy) -> CGFloat in geometry.size.width } action: { (width: CGFloat) in
            let padded: CGFloat = width - 32
            innerWidth = max(1, padded)
        }
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
                .help("Back 3 Seconds (J)").accessibilityLabel(EditorIconAction.back.name)
            Button { model.transport(" ") } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 34, height: 34) }
                .background(DesignValues.color("bg.sunken"), in: Circle()).help("Play/Pause (Space)").accessibilityLabel((model.isPlaying ? EditorIconAction.pause : .play).name)
            Button { model.seek(source: min(model.sourceDuration, model.sourceTime + 3)) } label: { transportSymbol("goforward.3", fallback: "goforward").frame(width: 28, height: 28) }
                .help("Forward 3 Seconds").accessibilityLabel(EditorIconAction.forward.name)
        }.buttonStyle(.plain).foregroundStyle(DesignValues.color("text.primary")).frame(height: 34)
    }
    @ViewBuilder private func transportSymbol(_ name: String, fallback: String) -> some View {
        if NSImage(named: name) != nil { Image(name).renderingMode(.template) }
        else { Image(systemName: fallback).overlay { Text("3").font(.system(size: 7, weight: .semibold)).offset(y: 1) } }
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
                if let label = chip { MediaChip(text: label).padding(6) }
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
    private var chip: String? {
        switch model.mediaStatus {
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
                .accessibilityIdentifier("voxclip.caption.position")
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
    var compactTransport = false
    @State private var hoveredSource: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 12) {
            if compactTransport { compactControls }
            Picker("Timeline time", selection: $model.editedTimeline) {
                Text("Edited").tag(true); Text("Source").tag(false)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 130, height: 24).controlSize(.small)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    track(width: geometry.size.width)
                    if let clip = model.activeClip {
                        TimelineTrimHandle(model: model, clip: clip, start: true, width: geometry.size.width)
                        TimelineTrimHandle(model: model, clip: clip, start: false, width: geometry.size.width)
                    }
                }
                .coordinateSpace(name: "voxclip.timeline")
            }
        }
        .frame(height: 72)
        .padding(.horizontal, 16)
        .background(DesignValues.color("bg.surface"))
        .task(id: model.waveformKey) { await model.loadWaveform() }
    }
    private var compactControls: some View {
        HStack(spacing: 8) {
            Button { model.transport(" ") } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).background(DesignValues.color("bg.sunken"), in: Circle())
            .accessibilityLabel((model.isPlaying ? EditorIconAction.pause : .play).name)
            (Text(timecode(model.playhead)) + Text(" / \(timecode(model.duration))").foregroundStyle(DesignValues.color("text.secondary")))
                .font(DesignValues.mono(12)).monospacedDigit().fixedSize()
                .accessibilityIdentifier("voxclip.compact.time")
        }
    }
    private func track(width: CGFloat) -> some View {
        let projection = model.displayTimeline
        let current = model.editedTimeline ? model.playhead : model.sourceTime
        return scrubTrack(projection: projection, current: current, width: width)
            .focusable()
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { key in
                let direction: Int = key.key == .leftArrow ? -1 : 1
                model.step(direction, sentence: key.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.home) { seekBoundary(end: false); return .handled }
            .onKeyPress(.end) { seekBoundary(end: true); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: " jklpico[]")) { key in model.transport(key.characters); return .handled }
            .accessibilityRepresentation { slider(projection: projection, current: current) }
            .animation(reduceMotion ? nil : .easeInOut(duration: EditorAccessibilityPolicy(reduceMotion: reduceMotion, reduceTransparency: false, increaseContrast: false).timelineZoomDuration), value: projection.zoom)
    }
    private func slider(projection: TimelineProjection, current: Double) -> some View {
        let range = projection.visible(edited: model.editedTimeline)
        let value = Binding(get: { current.clamped(to: range) }, set: { model.seek(source: sourceTime($0)) })
        return Slider(value: value, in: range) { Text("Playhead") }
            .accessibilityIdentifier("voxclip.timeline.playhead")
            .accessibilityValue(model.timelineAccessibilityValue)
            .accessibilityAdjustableAction { model.step($0 == .increment ? 1 : -1) }
    }
    private func seekBoundary(end: Bool) {
        let source: Double
        if let bounds = model.scopeBounds { source = end ? model.words[bounds.upperBound].end : model.words[bounds.lowerBound].start }
        else { source = end ? model.sourceDuration : 0 }
        model.seek(source: source)
    }
    private var hoverHelp: String {
        guard let source = hoveredSource else { return "Drag to scrub. Shift-drag snaps to word starts. Double-click a cut to restore it." }
        let word = model.word(at: source).map { model.text($0) + " · " } ?? ""
        return word + timecode(source)
    }
    private func scrubTrack(projection: TimelineProjection, current: Double, width: CGFloat) -> some View {
        return TimelineTrack(projection: projection, edited: model.editedTimeline).equatable()
            .overlay { TimelinePlayhead(fraction: projection.fraction(current, edited: model.editedTimeline)) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let time = projection.time(value.location.x / max(1, width), edited: model.editedTimeline)
                let source = sourceTime(time)
                if NSEvent.modifierFlags.contains(.shift), let word = model.word(at: source, nearest: true) { model.seek(source: word.start) }
                else { model.seek(source: source) }
            })
            .onTapGesture(count: 2) { location in
                let time = projection.time(location.x / max(1, width), edited: model.editedTimeline)
                let source = sourceTime(time)
                let wordIDs = model.word(at: source).map { model.cutWordIDs.contains($0.id) ? [$0.id] : [] } ?? []
                let pauseIDs = model.pause(at: source).map { model.cutPauseIDs.contains($0.id) ? [$0.id] : [] } ?? []
                if !wordIDs.isEmpty || !pauseIDs.isEmpty { model.apply(.restoreSelection(ids: wordIDs + pauseIDs), name: "Restore cut") }
            }
            .onContinuousHover { phase in
                if case .active(let point) = phase { hoveredSource = sourceTime(projection.time(point.x / max(1, width), edited: model.editedTimeline)) }
                else { hoveredSource = nil }
            }
            .help(hoverHelp)
    }
    private func sourceTime(_ time: Double) -> Double {
        model.timelineSourceTime(time)
    }
}

@MainActor private struct TimelineTrimHandle: View {
    let model: EditorModel
    let clip: ClipRange
    let start: Bool
    let width: CGFloat
    @State private var candidate: Int?
    private var index: Int { candidate ?? model.index(start ? clip.startWordId : clip.endWordId) ?? 0 }
    private var source: Double {
        guard model.words.indices.contains(index) else { return 0 }
        return start ? model.words[index].start : model.words[index].end
    }
    var body: some View {
        let time = model.editedTimeline ? model.renderTimeline?.mapTime(source) ?? source : source
        let fraction = model.timeline.fraction(time, edited: model.editedTimeline)
        Capsule().fill(DesignValues.accentText).frame(width: 7, height: 36)
            .frame(width: 24, height: 44).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("voxclip.timeline"))
                .onChanged { value in candidate = snappedIndex(value.location.x) }
                .onEnded { value in
                    if let index = snappedIndex(value.location.x) { model.trimClip(clip, start: start, index: index) }
                    candidate = nil
                })
            .onKeyPress(.escape) { candidate = nil; return .handled }
            .focusable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Clip \(model.clipNumber(clip.id) ?? 1) \(start ? "start" : "end")")
            .accessibilityValue(timecode(source))
            .accessibilityAdjustableAction { model.adjustTrim(start: start, offset: $0 == .increment ? 1 : -1) }
            .position(x: fraction * width, y: 43)
    }
    private func snappedIndex(_ point: CGFloat) -> Int? {
        let safeWidth: CGFloat = max(1, width)
        let fraction: Double = Double(point / safeWidth)
        return model.timelineTrimIndex(clip, start: start, fraction: fraction)
    }
}
