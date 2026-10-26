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
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.addSublayer(playerLayer); playerLayer.videoGravity = .resizeAspect }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}

@MainActor struct PreviewColumn: View {
    @Bindable var model: EditorModel
    var compact = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointerInside = false
    @State private var showTransport = true
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
        VStack(spacing: compact ? 6 : 12) {
            HStack {
                Label(model.activeClip == nil ? "Full Video" : "Clip: \(model.activeClip?.title ?? "Untitled clip")", systemImage: model.activeClip == nil ? "play.rectangle" : "film")
                    .font((compact ? Font.caption : Font.callout).weight(.medium)).lineLimit(1)
                    .accessibilityLabel(model.activeClip == nil ? "Previewing full video" : "Previewing selected clip")
                Spacer()
                if model.activeClip != nil { Button("Full Video") { model.activate(nil) } }
            }
            ZStack(alignment: .bottom) {
                Rectangle().fill(DesignValues.color("stage"))
                if model.document.demo {
                    #if DEBUG
                    DemoFrame(model: model)
                    #endif
                } else if let native = model.nativePreview { PlayerSurface(player: native.player) }
                if model.sourceDuration == 0 && !model.document.demo {
                    Label("Your video will appear here.", systemImage: "play.rectangle").foregroundStyle(DesignValues.color("overlay.foreground").opacity(0.7))
                }
                if !model.document.demo, model.previewError == nil, let style = model.app.styles.first(where: { $0.id == model.project.captions.styleId }), style.position.userDraggable {
                    CaptionPositionOverlay(model: model, style: style)
                }
                if showTransport || reduceMotion || !model.isPlaying {
                    transport.padding(.bottom, 16)
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .onHover { pointerInside = $0; if $0 { showTransport = true } }
            .task(id: model.isPlaying && !pointerInside && !reduceMotion) {
                guard model.isPlaying && !pointerInside && !reduceMotion else { showTransport = true; return }
                do { try await Task.sleep(for: .seconds(2)); showTransport = false } catch {}
            }
            Picker("Preview aspect", selection: Binding(get: { model.project.export.aspect }, set: { model.setAspect($0) })) {
                ForEach(AspectRatio.allCases, id: \.self) { aspect in Text(aspect == .source ? "Source" : aspect.rawValue).tag(aspect) }
            }.labelsHidden().pickerStyle(.segmented).controlSize(compact ? .mini : .small)
            if let error = model.previewError, !error.isEmpty {
                InlineNotice(text: error)
                if !model.mediaResolved, !model.document.demo { Button("Locate…") { locateMedia() } }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 8 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .onKeyPress(characters: CharacterSet(charactersIn: " jklpico[]")) { key in model.transport(key.characters, shift: key.modifiers.contains(.shift)); return .handled }
        .accessibilityLabel("Video preview")
    }
    @ViewBuilder private var transport: some View {
        if reduceTransparency {
            transportContent.background(DesignValues.color("overlay.transportOpaque"), in: Capsule()).overlay(Capsule().stroke(DesignValues.color("line.strong"), lineWidth: 1))
        } else {
            GlassEffectContainer { transportContent.glassEffect(.regular.interactive(), in: .capsule) }.environment(\.colorScheme, .dark)
        }
    }
    private var transportContent: some View {
        HStack(spacing: 12) {
            Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.transport(" ") }.labelStyle(.iconOnly).buttonStyle(.plain)
            Text("\(timecode(model.playhead)) / \(timecode(model.duration))").font(DesignValues.mono(13)).monospacedDigit()
            if model.playbackRate != 1 { Text("\(model.playbackRate.formatted())×").font(.caption) }
        }.foregroundStyle(DesignValues.color("overlay.foreground")).padding(.horizontal, 16).frame(height: 36)
    }
    private func locateMedia() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let probe = try await VoxClipMedia.AVMediaProbe().probe(url)
                    let next: Project
                    do {
                        next = try await model.app.projectStore.relink(model.project, to: url, probe: probe)
                    } catch VoxClipError.mediaMissing(_) {
                        guard probe.durationSeconds.isFinite, abs(probe.durationSeconds - model.sourceDuration) <= 0.05 else {
                            model.previewError = "This file's duration differs by more than 0.05 seconds. Choose another file. Edits are saved."
                            return
                        }
                        let alert = NSAlert(); alert.messageText = "This file looks different. Use it anyway?"; alert.addButton(withTitle: "Use it"); alert.addButton(withTitle: "Choose another")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        next = try await model.app.projectStore.relink(model.project, to: url, probe: probe, confirmedDifferent: true)
                    }
                    model.mediaResolved = true
                    model.replace(next, name: "Locate media")
                    await model.updatePreview(load: true)
                } catch { model.previewError = await model.app.safeError(error) }
            }
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
    @State private var hoveredSource: Double?
    var body: some View {
        HStack(spacing: 12) {
            Text(timecode(model.playhead)).font(DesignValues.mono(11)).frame(width: 60)
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
                Text("\(timecode(model.duration)) after cuts · \(timecode(model.sourceDuration)) source").font(DesignValues.mono(10)).foregroundStyle(.secondary)
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
        .accessibilityValue("\(timecode(model.playhead)) of \(timecode(model.duration)) after cuts, \(model.summary.cutWordCount + model.summary.cutPauseCount) cuts")
        .accessibilityAdjustableAction { direction in model.step(direction == .increment ? 1 : -1) }
    }
}
