import SwiftUI
import AppKit
import VoxClipCore
import VoxClipMedia

enum CaptionStyleGroup: String, CaseIterable {
    case word = "Word by word", phrase = "Phrase", sentence = "Sentence", other = "Other"
    static func group(for style: CaptionStyle) -> Self {
        if style.tags.contains("one-word") { return .word }
        if style.tags.contains("phrase") { return .phrase }
        if style.tags.contains("sentence") { return .sentence }
        return .other
    }
}

enum CaptionGalleryTarget: Hashable { case tile(String), header(CaptionStyleGroup), end }
private extension VerticalAlignment {
    /// Centres the Captions switch on the heading in both header forms.
    enum CaptionsHeading: AlignmentID { static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] } }
    static let captionsHeading = VerticalAlignment(CaptionsHeading.self)
}

@MainActor struct CaptionsSection: View {
    @Bindable var model: EditorModel
    @ObservedObject private var document: VoxClipDocument
    @State private var fineTune = false
    @State private var width: CGFloat = 360
    @State private var galleryReveal = CaptionGalleryReveal()
    @State private var galleryViewport = CaptionGalleryViewport()
    @State private var galleryTiles: [String: CGRect] = [:]
    @State private var galleryHeaders: [CaptionStyleGroup: CGRect] = [:]
    #if DEBUG
    @State private var galleryID = UUID().uuidString
    #endif
    init(model: EditorModel, fineTune: Bool = false) {
        self.model = model
        self.document = model.document
        _fineTune = State(initialValue: fineTune)
    }
    var body: some View {
        let _ = document.project
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader
            gallery
        }
        .padding(16)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .tint(Color(nsColor: DesignValues.accentFill))
    }
    @ViewBuilder private var fineTuneControls: some View {
        if fineTune {
                    VStack(alignment: .leading, spacing: 12) {
                        CaptionControlRow("Size") {
                            Picker("Size", selection: Binding(get: { if case .number(let scale) = value("font", "sizeScale") { return scale }; return 1 }, set: { scale in mutate { CaptionFineTuning.size(&$0, scale: scale) } })) { Text("S").tag(0.8); Text("M").tag(1.0); Text("L").tag(1.2); Text("XL").tag(1.45) }.pickerStyle(.segmented).labelsHidden()
                        }
                        CaptionControlRow("Case") {
                            Picker("Case", selection: overrideString("text", "transform", fallback: style?.text.transform.rawValue ?? "none")) { Text("As said").tag("none"); Text("ALL CAPS").tag("uppercase") }.pickerStyle(.segmented).labelsHidden().disabled(style?.text.userOverridable == false)
                        }
                        CaptionControlRow("Words on screen") {
                            Picker("Words on screen", selection: Binding(get: { if case .number(let count) = value("layout", "maxWords") { return Int(count) }; return 0 }, set: { count in mutate { CaptionFineTuning.words(&$0, count: count) } })) { Text("1").tag(1); Text("Phrase").tag(0); Text("Line").tag(16) }.pickerStyle(.segmented).labelsHidden()
                        }
                        Toggle("Keep punctuation", isOn: Binding(get: { value("text", "punctuation") == .string("keep") || (value("text", "punctuation") == nil && style?.text.punctuation == .keep) }, set: { setOverride("text", "punctuation", .string($0 ? "keep" : "strip-keep-numeric")) })).disabled(style?.text.userOverridable == false)
                        if style?.accent != nil {
                            HStack {
                                Text("Colour")
                                Spacer()
                                ForEach(palette, id: \.hex) { swatch in
                                    Button { mutate { $0.overrides["accent"] = .string(swatch.hex) } } label: {
                                        Circle().fill(Color(nsColor: DesignValues.parse(swatch.hex))).frame(width: 22, height: 22)
                                            .overlay(Circle().stroke(.primary, lineWidth: model.project.captions.overrides["accent"] == .string(swatch.hex) ? 2 : 0.5))
                                    }.buttonStyle(.plain).accessibilityLabel(swatch.name)
                                }
                            }
                        }
                        CaptionControlRow("Position") {
                            Picker("Position", selection: Binding(get: { storedPosition?.y ?? 0.8 }, set: { y in mutate { CaptionFineTuning.position(&$0, aspect: model.captionPreset, point: y == 0.8 ? nil : CaptionPosition(x: 0.5, y: y)) } })) { Text("Top").tag(0.2); Text("Middle").tag(0.5); Text("Bottom").tag(0.8) }.pickerStyle(.segmented).labelsHidden().disabled(style?.position.userDraggable == false)
                        }
                        Text("Drag captions on the video to move them.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button { mutate { CaptionFineTuning.reset(&$0) } } label: { Text("Reset to Style").underline() }.buttonStyle(.plain).foregroundStyle(DesignValues.accentText).accessibilityLabel("Reset to Style")
                    }
                }
    }
    private var sectionHeader: some View {
        // The switch stays outside ViewThatFits. Turning captions off shortens the summary and can
        // change which form fits; a switch inside the candidates would be replaced and lose focus.
        HStack(alignment: .captionsHeading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { heading; liveChip; styleSummary.fixedSize(horizontal: true, vertical: false); Spacer(minLength: 0) }.columnLayoutEvidence("captions.inline")
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    HStack(spacing: 8) { liveChip; styleSummary; Spacer(minLength: 0) }
                }.columnLayoutEvidence("captions.stacked")
            }
            captionsSwitch
        }
    }
    private var heading: some View {
        Text("Captions").font(.system(size: 13, weight: .semibold)).accessibilityIdentifier("voxclip.captions.heading")
            .alignmentGuide(.captionsHeading) { $0[VerticalAlignment.center] }.columnLayoutEvidence("header.captions.heading")
    }
    private var captionsSwitch: some View {
        Toggle("Captions", isOn: Binding(get: { model.project.captions.styleId != "off" }, set: { model.setCaptionsEnabled($0) }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize().accessibilityIdentifier("voxclip.captions.switch")
            .alignmentGuide(.captionsHeading) { $0[VerticalAlignment.center] }.columnLayoutEvidence("header.captions.switch")
    }
    private var liveChip: some View {
        Group {
            if let style { CaptionTile(input: chipInput(style), pipeline: model.app.captions) }
            else {
                ZStack {
                    DesignValues.color("stage")
                    Text("Off").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                }
            }
        }.frame(width: 64, height: 36).clipShape(.rect(cornerRadius: 6)).accessibilityHidden(true)
    }
    private var styleSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(style?.name ?? "Off").font(.system(size: 13, weight: .semibold))
                if model.captionsEdited { Text("Edited").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")) }
            }.lineLimit(1)
            DisclosureGroup(isExpanded: $fineTune) { EmptyView() } label: {
                HStack(spacing: 3) { Image(systemName: fineTune ? "chevron.down" : "chevron.right"); Text(model.captionSummary) }
                    .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
            }.disclosureGroupStyle(CaptionDisclosureStyle()).accessibilityLabel("Fine tune captions, \(model.captionSummary)").accessibilityValue(fineTune ? "Expanded" : "Collapsed").accessibilityIdentifier("voxclip.captions.disclosure")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("voxclip.captions.summary")
    }
    private func chipInput(_ style: CaptionStyle) -> CaptionTileInput {
        var input = model.captionTileInput(style)
        input.tileSize = PixelSize(width: 128, height: 72)
        return input
    }
    private var gallery: some View {
        ScrollViewReader { reader in
            #if DEBUG
            galleryScroll(reader: reader).columnLayoutEvidence("caption.gallery.\(galleryID)")
                .onReceive(NotificationCenter.default.publisher(for: CaptionGalleryAudit.notification)) { notification in
                    guard notification.object as? String == galleryID else { return }
                    if notification.userInfo?["snapshot"] as? Bool == true {
                        CaptionGalleryAudit.snapshots[galleryID] = .init(paint: galleryTile?.frame, header: galleryLayout.header,
                            visible: galleryViewport.visible, size: galleryViewport.size, pending: galleryReveal.pending,
                            selectedStyle: model.project.captions.styleId, paintStyle: galleryTile?.styleID, interrupted: galleryReveal.interrupted,
                            commands: galleryReveal.commands)
                        return
                    }
                    if let selected = notification.userInfo?["selectStyle"] as? String {
                        styleSelection.wrappedValue = selected
                        return
                    }
                    if notification.userInfo?["beginReveal"] as? Bool == true { galleryReveal.restart(); return }
                    if notification.userInfo?["userScroll"] as? Bool == true { galleryScrollPhaseChanged(.interacting); return }
                    if notification.userInfo?["end"] as? Bool == true {
                        galleryReveal.cancelForUserScroll(); reader.scrollTo(CaptionGalleryTarget.end, anchor: .bottom)
                    } else { galleryReveal.restart(); revealSelection(reader: reader) }
                }
            #else
            galleryScroll(reader: reader)
            #endif
        }
    }
    private func galleryScroll(reader: ScrollViewProxy) -> some View {
        ScrollView { galleryContents }
            .onScrollGeometryChange(for: CaptionGalleryViewport.self) { geometry in
                CaptionGalleryViewport(visible: geometry.visibleRect, size: geometry.containerSize)
            } action: { _, viewport in galleryViewport = viewport }
            .onChange(of: galleryRequest, initial: true) { _, request in galleryReveal.begin(request); revealSelection(reader: reader) }
            .onChange(of: galleryLayout) { _, _ in revealSelection(reader: reader) }
            .onScrollPhaseChange { _, phase in galleryScrollPhaseChanged(phase) }
            .onChange(of: fineTune) { _, expanded in
                if expanded { reader.scrollTo("captions.fineTune", anchor: .top) }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [DesignValues.color("bg.surface").opacity(0), DesignValues.color("bg.surface")], startPoint: .top, endPoint: .bottom).frame(height: 24).allowsHitTesting(false).accessibilityHidden(true)
            }
            .padding(.horizontal, -3)
    }
    private var galleryContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            fineTuneControls.id("captions.fineTune")
            if let error = model.captionError { InlineNotice(text: error).fixedSize(horizontal: false, vertical: true) }
            galleryGrid
            if model.app.styles.isEmpty { Text("Caption styles are unavailable. Reinstall VoxClip.").foregroundStyle(.secondary) }
        }.padding(.horizontal, 3).padding(.bottom, 24)
            .overlay(alignment: .bottom) { Color.clear.frame(height: 24).id(CaptionGalleryTarget.end).allowsHitTesting(false).accessibilityHidden(true) }
            .coordinateSpace(name: CaptionGallerySpace.content)
    }
    private var galleryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 10) {
            ForEach(CaptionStyleGroup.allCases, id: \.self) { group in
                let styles = model.app.styles.filter { CaptionStyleGroup.group(for: $0) == group }.sorted { $0.order < $1.order }
                if !styles.isEmpty {
                    Section { ForEach(styles, id: \.id) { style in styleTile(style).id(CaptionGalleryTarget.tile(style.id)) } } header: {
                        Text(group.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignValues.color("text.secondary")).padding(.top, 2)
                            .onGeometryChange(for: CGRect.self) { geometry in geometry.frame(in: .named(CaptionGallerySpace.content)) } action: { galleryHeaders[group] = $0 }
                            .id(CaptionGalleryTarget.header(group)).columnLayoutEvidence("caption.group.\(group.rawValue)")
                    }
                }
            }
        }.padding(.vertical, 3).accessibilityRepresentation { galleryPicker }
    }
    private var galleryPicker: some View {
        Picker("Caption style", selection: styleSelection) {
            ForEach(model.app.styles.sorted { $0.order < $1.order }, id: \.id) { Text("\($0.name): \($0.description)").tag($0.id) }
        }.pickerStyle(.radioGroup).accessibilityIdentifier("voxclip.captions.gallery")
    }
    private var styleSelection: Binding<String> {
        Binding(get: { model.project.captions.styleId }, set: { model.setStyle($0) })
    }
    private func galleryScrollPhaseChanged(_ phase: ScrollPhase) {
        if phase == .tracking || phase == .interacting { galleryReveal.cancelForUserScroll() }
    }
    private var galleryRequest: CaptionGalleryRequest {
        CaptionGalleryRequest(selection: "\(model.project.id)/\(model.activeClip?.id ?? "full")/\(model.project.captions.styleId)", size: galleryViewport.size, fineTune: fineTune)
    }
    private var galleryLayout: CaptionGalleryLayout {
        CaptionGalleryLayout(tile: galleryTile, header: style.flatMap { galleryHeaders[CaptionStyleGroup.group(for: $0)] }, viewport: galleryViewport)
    }
    private var galleryTile: CaptionGalleryTileGeometry? {
        let identifier = model.project.captions.styleId
        return galleryTiles[identifier].map { CaptionGalleryTileGeometry(styleID: identifier, frame: $0) }
    }
    private func revealSelection(reader: ScrollViewProxy) {
        guard !galleryReveal.interrupted, !fineTune, galleryViewport.size.height > 0, galleryReveal.request != nil else { return }
        galleryReveal.resumeForLayout()
        var target = CaptionGalleryTarget.tile(model.project.captions.styleId)
        if let tile = galleryTile, tile.styleID == model.project.captions.styleId {
            let expectedWidth: CGFloat = (galleryViewport.size.width - 14) / 2 + 6
            var visible = galleryViewport.visible
            if tile.frame.height + 24 <= visible.height { visible.size.height -= 24 }
            let shortViewport = tile.frame.height > visible.height
            let verticallyVisible = shortViewport ? abs(tile.frame.minY - visible.minY) <= 0.5 : visible.insetBy(dx: -0.5, dy: -0.5).contains(tile.frame)
            var complete = abs(tile.frame.width - expectedWidth) <= 0.5 && verticallyVisible
            if let style, let header = galleryLayout.header, header.union(tile.frame).height + 24 <= galleryViewport.size.height {
                target = .header(CaptionStyleGroup.group(for: style))
                complete = complete && visible.insetBy(dx: -0.5, dy: -0.5).contains(header)
            }
            if complete { galleryReveal.complete(); return }
        }
        if galleryReveal.shouldScroll(to: target, anchor: .top) { reader.scrollTo(target, anchor: .top) }
    }
    private var style: CaptionStyle? { model.app.styles.first { $0.id == model.project.captions.styleId } }
    private var storedPosition: CaptionPosition? { model.captionPreset == .source ? model.project.captions.position : model.project.captions.positionByAspect[model.captionPreset.rawValue] }
    private var palette: [(name: String, hex: String)] { [("Yellow", "#FFE14D"), ("Green", "#4BE38A"), ("Cyan", "#5CE1FF"), ("Pink", "#FF6FAE"), ("Paper", "#F3F0E7"), ("White", "#FFFFFF")] }
    private func mutate(_ change: (inout CaptionSettings) -> Void) { var next = model.project; change(&next.captions); model.replace(next, name: "Fine tune captions") }
    private func styleTile(_ style: CaptionStyle) -> some View {
        let id = style.id
        let selected = model.project.captions.styleId == id
        return Button { model.setStyle(id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    CaptionTile(input: model.captionTileInput(style), pipeline: model.app.captions)
                        .aspectRatio(1 / 0.45, contentMode: .fit).clipShape(.rect(cornerRadius: 10))
                    if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 18, height: 18).background(.black.opacity(0.62), in: Circle()).padding(5) }
                }.overlay { if selected { RoundedRectangle(cornerRadius: 12).stroke(DesignValues.accentText, lineWidth: 2).padding(-2).columnLayoutEvidence("caption.ring.\(id)") } }
                Text(style.name + (selected && model.captionsEdited ? " · Edited" : "")).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(DesignValues.color("text.primary")).lineLimit(1).columnLayoutEvidence("caption.name.\(id)")
            }.padding(.top, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(style.name): \(style.description)").accessibilityAddTraits(selected ? .isSelected : [])
            .columnLayoutEvidence("caption.target.\(id)")
            .background {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { geometry in geometry.frame(in: .named(CaptionGallerySpace.content)) }
                    action: { frame in if frame.width > 0, frame.height > 0 { galleryTiles[id] = frame } }
                    .columnLayoutEvidence("caption.tile.\(id)")
                    .padding(.horizontal, -3).allowsHitTesting(false).accessibilityHidden(true)
            }
    }
    private func value(_ group: String, _ key: String) -> JSONValue? { if case .object(let object) = model.project.captions.overrides[group] { return object[key] }; return nil }
    private func setOverride(_ group: String, _ key: String, _ value: JSONValue) {
        var next = model.project; var object: [String: JSONValue] = [:]
        if case .object(let existing) = next.captions.overrides[group] { object = existing }
        object[key] = value; next.captions.overrides[group] = .object(object); model.replace(next, name: "Fine tune captions")
    }
    private func overrideNumber(_ group: String, _ key: String, fallback: Double) -> Binding<Double> { Binding(get: { if case .number(let number) = value(group, key) { return number }; return fallback }, set: { setOverride(group, key, .number($0)) }) }
    private func overrideString(_ group: String, _ key: String, fallback: String) -> Binding<String> { Binding(get: { if case .string(let string) = value(group, key) { return string }; return fallback }, set: { setOverride(group, key, .string($0)) }) }
}

struct CaptionGalleryRequest: Equatable {
    let selection: String
    let size: CGSize
    let fineTune: Bool
}

struct CaptionGalleryReveal: Equatable {
    private(set) var request: CaptionGalleryRequest?
    private(set) var pending = false
    private(set) var interrupted = false
    private(set) var commands = 0
    private var lastTarget: CaptionGalleryTarget?
    private var lastAnchor = UnitPoint.top
    mutating func begin(_ request: CaptionGalleryRequest) {
        guard self.request != request else { return }
        self.request = request; pending = !request.fineTune; interrupted = false; lastTarget = nil
    }
    mutating func complete() { pending = false }
    mutating func resumeForLayout() { if !interrupted { pending = request?.fineTune == false } }
    mutating func restart() { pending = request?.fineTune == false; interrupted = false; lastTarget = nil }
    mutating func cancelForUserScroll() { pending = false; interrupted = true }
    mutating func shouldScroll(to target: CaptionGalleryTarget, anchor: UnitPoint) -> Bool {
        guard pending else { return false }
        if lastTarget == target, abs(lastAnchor.x - anchor.x) < 0.000001, abs(lastAnchor.y - anchor.y) < 0.000001 { return false }
        lastTarget = target; lastAnchor = anchor; commands += 1
        return true
    }
}

private struct CaptionGalleryViewport: Equatable {
    var visible = CGRect.zero
    var size = CGSize.zero
}

private struct CaptionGalleryTileGeometry: Equatable {
    let styleID: String
    let frame: CGRect
}

private struct CaptionGalleryLayout: Equatable {
    let tile: CaptionGalleryTileGeometry?
    let header: CGRect?
    let viewport: CaptionGalleryViewport
}

private enum CaptionGallerySpace: Hashable { case content }

#if DEBUG
@MainActor enum CaptionGalleryAudit {
    static let notification = Notification.Name("com.voxclip.caption-gallery-audit")
    struct Snapshot: Codable {
        let paint: CGRect?; let header: CGRect?; let visible: CGRect; let size: CGSize; let pending: Bool
        let selectedStyle: String; let paintStyle: String?; let interrupted: Bool; let commands: Int
    }
    static var snapshots: [String: Snapshot] = [:]
}
#endif

@MainActor private struct CaptionControlRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { Text(title).fixedSize(); content }.columnLayoutEvidence("fineTune.\(title).inline")
            VStack(alignment: .leading, spacing: 6) { Text(title); content }.columnLayoutEvidence("fineTune.\(title).stacked")
        }
    }
}

private struct CaptionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isExpanded.toggle() } label: { configuration.label }.buttonStyle(.plain)
    }
}

@Observable @MainActor final class CaptionTileState {
    private(set) var image: NSImage?
    private var generation = 0
    func load(_ input: CaptionTileInput, render: @MainActor (CaptionTileInput) async -> NSImage?) async {
        generation += 1
        let request = generation
        guard !Task.isCancelled else { return }
        let result = await render(input)
        guard !Task.isCancelled, request == generation else { return }
        image = result
    }
    func invalidate() { generation += 1 }
}

@MainActor struct CaptionTile: View {
    let input: CaptionTileInput
    let pipeline: CaptionHandoff
    @State private var state = CaptionTileState()
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: DesignValues.parse(input.loading ? "#000000" : input.backdrop ?? "#000000"))
                if let image = state.image { Image(nsImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
            }
        }
        .task(id: input) {
            await state.load(input) { await pipeline.tile($0) }
        }
        .onDisappear { state.invalidate() }
        .accessibilityHidden(true)
    }
}
