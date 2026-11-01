import SwiftUI
import AppKit
import VoxClipCore
import VoxClipMedia

// The Captions job of the right column's one panel (ux/v2 notes.md §7, f1 and f2, impl-plan
// V5). The panel header above it names the job and the open tab, so the body starts with the
// STYLE row and its On switch. Under it a 3-column gallery of 40 pt tiles that all show the
// same phrase, "and one cool", so only the style changes: every style in the library's
// order, with no group headers; two rows show at 1280 × 800 and the rest scroll. Then 24 pt
// property rows at 12 pt (Words per caption, Case, Position), and the rest of the fine-tuning
// behind a Fine tune disclosure.

/// The Captions panel's geometry, in points (notes.md §4 and §7: `.pin`, `.tiles`, `.tile`,
/// `.tn`, `.hr`, `.prop`). At 1280 × 800 the 265 pt body is the 30 pt STYLE row, the gallery's
/// two rows (128) and the property rows (107).
enum CaptionsPanelMetrics {
    /// Panel padding across (notes.md §4: 12 / 16).
    static let inset: CGFloat = 16
    /// The STYLE row is 20 high with its centre 20 under the panel header, as in f1.
    static let styleRowTop: CGFloat = 10
    static let styleRowHeight: CGFloat = 20
    static let columns = 3
    static let columnGap: CGFloat = 8
    static let rowGap: CGFloat = 6
    static let tileHeight: CGFloat = 40
    static let tileRadius: CGFloat = 6
    /// The name sits 4 under its tile, one 11 pt line.
    static let nameGap: CGFloat = 4
    static let nameHeight: CGFloat = 14
    /// Room outside a tile, inside the gallery's scroll view, for the selected tile's outer
    /// 1 pt ring and the keyboard focus ring 1–3 pt out.
    static let ringReserve: CGFloat = 3
    /// The first tile sits 6 under the gallery's top edge, 36 under the panel header (f1: 37).
    static let galleryTopInset: CGFloat = 6
    static let galleryBottomInset: CGFloat = 6
    static let propertyRowHeight: CGFloat = 24
    /// The property rows' key column (`.prop .k`).
    static let keyWidth: CGFloat = 120
    /// The hairline above the property rows, 4 under the gallery.
    static let hairlineBlock: CGFloat = 5
    static let propertiesBottomInset: CGFloat = 6

    /// The STYLE row, from the top of the panel body.
    static var top: CGFloat { styleRowTop + styleRowHeight }
    /// A tile and its name.
    static var row: CGFloat { tileHeight + nameGap + nameHeight }
    /// The gallery's height that shows its first row whole.
    static var oneRow: CGFloat { galleryTopInset + row }
    /// The gallery's height that shows two rows whole (f1).
    static var twoRows: CGFloat { galleryTopInset + row * 2 + rowGap }
    /// The property rows with Fine tune closed: the hairline, Words per caption, Case,
    /// Position and the Fine tune row.
    static var properties: CGFloat { hairlineBlock + propertyRowHeight * 4 + propertiesBottomInset }
    /// What the property rows keep before the gallery takes more than one row: the hairline
    /// and two rows.
    static var propertiesFloor: CGFloat { hairlineBlock + propertyRowHeight * 2 }

    /// A tile's width in a panel `width` wide: three columns 8 apart inside the 16 pt padding
    /// (118.67 at 404, 84 at 300, 170.67 at 560).
    static func tileWidth(panelWidth width: CGFloat) -> CGFloat {
        max(0, (width - inset * 2 - columnGap * CGFloat(columns - 1)) / CGFloat(columns))
    }
    /// A tile's width from the width the gallery's scroll view gives its tiles: the scroll view
    /// reaches `ringReserve` past the padding on each side, and a legacy scroller, when one
    /// shows, takes its width from the tiles (`(width − 22) / 3`).
    static func tileWidth(galleryWidth width: CGFloat) -> CGFloat {
        tileWidth(panelWidth: width + (inset - ringReserve) * 2)
    }
    /// The width the gallery's scroll view gives its tiles in a panel `width` wide, without a
    /// legacy scroller.
    static func galleryWidth(panelWidth width: CGFloat) -> CGFloat {
        max(0, width - (inset - ringReserve) * 2)
    }
    /// The gallery's and the property rows' heights in `available`, what the body leaves under
    /// the STYLE row and any caption error; `properties` is the property rows' full height. The
    /// gallery keeps two rows (one while Fine tune is open, which needs the room) before the
    /// property rows take their full height, and the property rows keep their hairline and two
    /// rows before the gallery takes more than its first row. Each scrolls in what it gets.
    static func split(available: CGFloat, properties: CGFloat, fineTune: Bool) -> (gallery: CGFloat, properties: CGFloat) {
        let available = max(0, available)
        let galleryKeeps = fineTune ? oneRow : twoRows
        var bottom = min(properties, max(min(properties, propertiesFloor), available - galleryKeeps))
        var gallery = available - bottom
        if gallery < oneRow {
            gallery = min(available, oneRow)
            bottom = available - gallery
        }
        return (gallery, max(0, bottom))
    }
}

/// Lays the Captions panel out in its body: the fixed top (the STYLE row and any caption
/// error), then the gallery and the property rows as `CaptionsPanelMetrics.split` shares the
/// rest between them.
private struct CaptionsPanelLayout: Layout {
    let properties: CGFloat
    let fineTune: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let top = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        return CGSize(width: width, height: proposal.height ?? top + CaptionsPanelMetrics.twoRows + properties)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let top = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let split = CaptionsPanelMetrics.split(available: bounds.height - top, properties: properties, fineTune: fineTune)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: top))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: split.gallery))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top + split.gallery), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: split.properties))
    }
}

/// Arrow keys in the gallery (impl-plan V5), as in a radio group: left and right step through
/// the gallery's order, up and down by a row of three. Each move chooses the style.
enum CaptionGalleryNavigation {
    /// The index an arrow `key` moves to from `index` among `count` styles; nil at an edge or
    /// for another key. With nothing selected (captions off) any arrow picks the first style.
    static func target(from index: Int?, count: Int, key: KeyEquivalent, columns: Int = CaptionsPanelMetrics.columns) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return [.leftArrow, .rightArrow, .upArrow, .downArrow].contains(key) ? 0 : nil }
        let next: Int
        switch key {
        case .leftArrow: next = index - 1
        case .rightArrow: next = index + 1
        case .upArrow: next = index - columns
        case .downArrow: next = index + columns
        default: return nil
        }
        return (0..<count).contains(next) ? next : nil
    }
}

enum CaptionGalleryTarget: Hashable { case tile(String), end }
private struct CaptionGalleryTargetModifier: ViewModifier {
    let target: CaptionGalleryTarget
    func body(content: Content) -> some View {
        content.id(target)
            .background {
                #if DEBUG
                ColumnLayoutProbe(name: "caption.scrollTarget.\(target)", scrollTarget: target)
                #endif
            }
    }
}

extension EditorModel {
    /// A gallery tile's card (notes.md §7): "and one cool" in `style`, in a tile `width` points
    /// wide. Only the selected style takes the project's caption overrides (captions §15.3),
    /// so its colour and case show there. The phrase never follows the transcript, the
    /// playhead or the frame: a tile changes only with its style and its width. Tiles are
    /// flat stage black (`.tile`), so a style's preview background is not drawn; a near-black
    /// plate still gets the card's lighter backdrop, or it would not show.
    func captionTileInput(_ style: CaptionStyle, width: CGFloat) -> CaptionCardInput {
        let overrides = style.id == project.captions.styleId ? project.captions.overrides : [:]
        let fit = CardFit.galleryTile(width: width)
        let resolved = (try? style.resolved(overrides: overrides, frame: PixelSize(width: fit.width, height: fit.height))) ?? style
        return CaptionCardInput(text: .gallerySample(resolved), style: style, previewBackground: nil, overrides: overrides, language: "en", fit: fit)
    }
}

@MainActor struct CaptionsSection: View {
    private typealias Metrics = CaptionsPanelMetrics
    @Bindable var model: EditorModel
    @ObservedObject private var document: VoxClipDocument
    @State private var fineTune = false
    /// The width the gallery's scroll view gives its content, measured; the tiles take theirs
    /// from it, so a legacy scroller narrows the tiles rather than widening the scroll view
    /// past the column.
    @State private var galleryWidth: CGFloat
    /// The property rows' full height, read from their scroll view.
    @State private var propertiesHeight = CaptionsPanelMetrics.properties
    @State private var galleryReveal = CaptionGalleryReveal()
    @State private var galleryViewportSize = CGSize.zero
    @State private var galleryScrollState = CaptionGalleryScrollState()
    @State private var galleryTiles: [String: CGRect] = [:]
    @FocusState private var galleryFocused: Bool
    /// The keyboard focus ring shows on the selected tile only when focus came from the keyboard.
    @State private var keyboardRing = false
    #if DEBUG
    @State private var galleryID = UUID().uuidString
    #endif
    /// `width` is the panel's, for the tiles' first layout before the gallery measures its own.
    init(model: EditorModel, fineTune: Bool = false, width: CGFloat = 360) {
        self.model = model
        self.document = model.document
        _fineTune = State(initialValue: fineTune)
        _galleryWidth = State(initialValue: CaptionsPanelMetrics.galleryWidth(panelWidth: width))
    }
    /// The gallery's order: the library's `order`, ties by id (captions §15.1), with no groups.
    static func galleryOrder(_ styles: [CaptionStyle]) -> [CaptionStyle] {
        styles.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }
    var body: some View {
        let _ = document.project
        CaptionsPanelLayout(properties: propertiesHeight, fineTune: fineTune) {
            top
            gallery.padding(.horizontal, Metrics.inset)
            properties
        }
        .tint(Color(nsColor: DesignValues.accentFill))
    }

    // MARK: STYLE row

    private var top: some View {
        VStack(alignment: .leading, spacing: 0) {
            styleRow
                .padding(.top, Metrics.styleRowTop)
                .padding(.horizontal, Metrics.inset)
            if let error = model.captionError {
                // The notice's own 12 pt padding sets its text on the panel's 16 pt edge.
                InlineNotice(text: error).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.inset - 12)
                    .columnLayoutEvidence("caption.error")
            }
        }
    }
    /// notes.md §7: "STYLE" (11 semibold, uppercase, +0.05 em, text.tertiary) and, at the
    /// trailing edge, the switch with its state ("On", 12, text.secondary).
    private var styleRow: some View {
        HStack(spacing: 8) {
            Text("Style").textCase(.uppercase).font(VCType.small.font(.semibold)).tracking(0.55)
                .foregroundStyle(DesignValues.color("text.tertiary"))
                .accessibilityLabel("Style")
                .accessibilityIdentifier("voxclip.captions.heading")
                .columnLayoutEvidence("header.captions.heading", text: "STYLE")
            Spacer(minLength: 8)
            captionsSwitch
        }
        .frame(height: Metrics.styleRowHeight)
        .columnLayoutEvidence("captions.style")
    }
    private var captionsSwitch: some View {
        let enabled = model.project.captions.styleId != "off"
        let state = enabled ? "On" : "Off"
        return Toggle(isOn: Binding(get: { enabled }, set: { model.setCaptionsEnabled($0) })) {
            Text(state).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
        }
        .toggleStyle(.switch).controlSize(.mini).fixedSize()
        .accessibilityLabel("Captions")
        .accessibilityIdentifier("voxclip.captions.switch")
        .columnLayoutEvidence("header.captions.switch", text: state)
    }

    // MARK: Gallery

    private var gallery: some View {
        ScrollViewReader { reader in
            #if DEBUG
            galleryScroll(reader: reader).columnLayoutEvidence("caption.gallery.\(galleryID)")
                .onReceive(NotificationCenter.default.publisher(for: CaptionGalleryAudit.notification)) { notification in
                    guard notification.object as? String == galleryID else { return }
                    if notification.userInfo?["snapshot"] as? Bool == true {
                        CaptionGalleryAudit.snapshots[galleryID] = .init(paint: galleryTile?.frame,
                            visible: galleryViewport.visible, size: galleryViewport.size, pending: galleryReveal.pending,
                            selectedStyle: model.project.captions.styleId, paintStyle: galleryTile?.styleID, interrupted: galleryReveal.interrupted,
                            commands: galleryReveal.commands, consumed: galleryReveal.request == galleryRequest,
                            requestStyle: galleryReveal.request.map { String($0.selection.split(separator: "/").last ?? "") },
                            requestHeight: galleryReveal.request?.size.height, fineTune: fineTune, contentSize: galleryViewport.contentSize,
                            focused: galleryFocused)
                        return
                    }
                    if let selected = notification.userInfo?["selectStyle"] as? String {
                        model.setStyle(selected)
                        return
                    }
                    if let selected = notification.userInfo?["clickStyle"] as? String { selectTile(selected); return }
                    if let expanded = notification.userInfo?["fineTune"] as? Bool { fineTune = expanded; return }
                    if let focused = notification.userInfo?["focus"] as? Bool { galleryFocused = focused; return }
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
                CaptionGalleryViewport(visible: geometry.visibleRect, size: geometry.containerSize, contentSize: geometry.contentSize)
            } action: { _, viewport in
                if galleryScrollState.record(viewport) { galleryViewportSize = viewport.size }
                if !galleryReveal.interrupted { revealSelection(reader: reader) }
            }
            .onChange(of: galleryRequest, initial: true) { _, request in galleryReveal.begin(request); revealSelection(reader: reader) }
            .onChange(of: galleryLayout) { _, _ in revealSelection(reader: reader) }
            .onScrollPhaseChange { _, phase in galleryScrollPhaseChanged(phase) }
            .padding(.horizontal, -Metrics.ringReserve)
    }
    private var galleryContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            galleryGrid
            if model.app.styles.isEmpty {
                Text("Caption styles are unavailable. Reinstall VoxClip.").font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
        }
        .padding(.horizontal, Metrics.ringReserve)
        .padding(.top, Metrics.galleryTopInset - Metrics.ringReserve)
        .padding(.bottom, Metrics.galleryBottomInset)
        .overlay(alignment: .bottom) {
            Color.clear.frame(height: Metrics.galleryBottomInset).id(CaptionGalleryTarget.end).allowsHitTesting(false).accessibilityHidden(true)
        }
        .coordinateSpace(name: CaptionGallerySpace.content)
        // Flexible to nothing, so the scroll view never widens to fit the tiles: it gives this
        // its own width (less a legacy scroller), which the tiles then take.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(width - galleryWidth) > 0.25 { galleryWidth = width }
        }
    }
    /// Rows of three tiles. Each tile's button reaches `ringReserve` above it, so a tile
    /// scrolled to the top keeps its ring; the rows are 6 apart between a name and the next tile.
    private var galleryGrid: some View {
        let styles = Self.galleryOrder(model.app.styles)
        let tileWidth = Metrics.tileWidth(galleryWidth: galleryWidth)
        return VStack(alignment: .leading, spacing: Metrics.rowGap - Metrics.ringReserve) {
            ForEach(Array(stride(from: 0, to: styles.count, by: Metrics.columns)), id: \.self) { index in
                HStack(alignment: .top, spacing: Metrics.columnGap) {
                    ForEach(styles[index..<min(index + Metrics.columns, styles.count)], id: \.id) { style in
                        styleTile(style, width: tileWidth).modifier(CaptionGalleryTargetModifier(target: .tile(style.id)))
                    }
                }
            }
        }
        .focusable()
        .focused($galleryFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            moveSelection(press.key) ? .handled : .ignored
        }
        .onChange(of: galleryFocused) { _, focused in
            if focused {
                model.focusedPane = .panel
                keyboardRing = keyboardRing || NSApp.currentEvent?.type == .keyDown
            } else { keyboardRing = false }
        }
        .accessibilityRepresentation { galleryPicker }
    }
    private var galleryPicker: some View {
        Picker("Caption style", selection: styleSelection) {
            ForEach(Self.galleryOrder(model.app.styles), id: \.id) { Text("\($0.name): \($0.description)").tag($0.id) }
        }.pickerStyle(.radioGroup).accessibilityIdentifier("voxclip.captions.gallery")
    }
    private var styleSelection: Binding<String> {
        Binding(get: { model.project.captions.styleId }, set: { model.setStyle($0) })
    }
    /// An arrow key from the focused gallery: chooses the neighbouring style, which the gallery
    /// then reveals. At an edge the key is still the gallery's, so it does not beep.
    func moveSelection(_ key: KeyEquivalent) -> Bool {
        let styles = Self.galleryOrder(model.app.styles)
        guard !styles.isEmpty else { return false }
        let current = styles.firstIndex { $0.id == model.project.captions.styleId }
        keyboardRing = true
        if let next = CaptionGalleryNavigation.target(from: current, count: styles.count, key: key) { model.setStyle(styles[next].id) }
        return true
    }
    /// notes.md `.tile` and `.tn`: a 40 pt tile on the stage, radius 6, with a 1 pt
    /// `line.default` edge, its name 4 under it (11, text.tertiary). The selected tile's edge
    /// and name are text.primary, with a 1 pt text.primary ring outside it (`.tile.on`).
    private func styleTile(_ style: CaptionStyle, width: CGFloat) -> some View {
        let id = style.id
        let selected = model.project.captions.styleId == id
        return Button { selectTile(id) } label: {
            VStack(alignment: .leading, spacing: Metrics.nameGap) {
                CaptionTile(input: model.captionTileInput(style, width: width), pipeline: model.app.captions)
                    .frame(width: width, height: Metrics.tileHeight)
                    .clipShape(.rect(cornerRadius: Metrics.tileRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.tileRadius)
                            .strokeBorder(DesignValues.color(selected ? "text.primary" : "line.default"), lineWidth: 1)
                    }
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: Metrics.tileRadius + 1).strokeBorder(DesignValues.color("text.primary"), lineWidth: 1)
                                .columnLayoutEvidence("caption.ring.\(id)").padding(-1)
                        }
                    }
                    .overlay {
                        if selected && galleryFocused && keyboardRing {
                            RoundedRectangle(cornerRadius: Metrics.tileRadius + 3).strokeBorder(DesignValues.color("focus.ring"), lineWidth: 2)
                                .columnLayoutEvidence("caption.focus.\(id)").padding(-3)
                        }
                    }
                    .columnLayoutEvidence("caption.image.\(id)")
                Text(style.name).font(VCType.small.font())
                    .foregroundStyle(DesignValues.color(selected ? "text.primary" : "text.tertiary"))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: width, height: Metrics.nameHeight, alignment: .leading)
                    .columnLayoutEvidence("caption.name.\(id)", text: style.name)
            }
            .padding(.top, Metrics.ringReserve)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(style.name)
        .accessibilityLabel("\(style.name): \(style.description)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .columnLayoutEvidence("caption.target.\(id)")
        .background {
            Color.clear
                .onGeometryChange(for: CGRect.self) { geometry in geometry.frame(in: .named(CaptionGallerySpace.content)) }
                action: { frame in if frame.width > 0, frame.height > 0 { galleryTiles[id] = frame } }
                .columnLayoutEvidence("caption.tile.\(id)")
                .padding(.horizontal, -Metrics.ringReserve).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private func selectTile(_ identifier: String) {
        let selection = "\(model.project.id)/\(model.activeClip?.id ?? "full")/\(identifier)"
        galleryReveal.selectVisibleTile(selection)
        keyboardRing = false
        model.setStyle(identifier)
    }
    private func galleryScrollPhaseChanged(_ phase: ScrollPhase) {
        if phase == .tracking || phase == .interacting { galleryReveal.cancelForUserScroll() }
    }
    private var galleryRequest: CaptionGalleryRequest {
        CaptionGalleryRequest(selection: "\(model.project.id)/\(model.activeClip?.id ?? "full")/\(model.project.captions.styleId)", size: galleryViewportSize, fineTune: fineTune)
    }
    private var galleryViewport: CaptionGalleryViewport { galleryScrollState.viewport }
    private var galleryLayout: CaptionGalleryLayout {
        CaptionGalleryLayout(tile: galleryTile, size: galleryViewportSize)
    }
    private var galleryTile: CaptionGalleryTileGeometry? {
        let identifier = model.project.captions.styleId
        return galleryTiles[identifier].map { CaptionGalleryTileGeometry(styleID: identifier, frame: $0) }
    }
    private func revealSelection(reader: ScrollViewProxy) {
        guard !galleryReveal.interrupted, galleryViewport.size.height > 0, galleryReveal.request == galleryRequest else { return }
        var reveal = galleryReveal
        reveal.resumeForLayout()
        guard reveal.pending else { return }
        defer { if reveal != galleryReveal { galleryReveal = reveal } }
        let target = CaptionGalleryTarget.tile(model.project.captions.styleId)
        if let tile = galleryTile, tile.styleID == model.project.captions.styleId {
            // The measured frame reaches the ring reserve on both sides; its width shows the
            // tile has been laid out at the gallery's current width.
            let expectedWidth = Metrics.tileWidth(galleryWidth: galleryWidth) + Metrics.ringReserve * 2
            let visible = galleryViewport.visible
            let shortViewport = tile.frame.height > visible.height
            let verticallyVisible = shortViewport ? abs(tile.frame.minY - visible.minY) <= 0.5 : visible.insetBy(dx: -0.5, dy: -0.5).contains(tile.frame)
            if abs(tile.frame.width - expectedWidth) <= 0.5 && verticallyVisible { reveal.complete(); return }
        }
        let geometry = [galleryViewport.visible.minY, galleryViewport.size.width, galleryViewport.size.height,
                        galleryTile?.frame.minY ?? -1, galleryTile?.frame.width ?? -1,
                        galleryTile?.frame.height ?? -1, galleryViewport.contentSize.height]
        if reveal.shouldScroll(to: target, geometry: geometry) {
            reader.scrollTo(target, anchor: .top)
        }
    }

    // MARK: Property rows and Fine tune

    /// notes.md `.hr` and `.prop`: a hairline 4 under the gallery, then 24 pt rows with a
    /// 120 pt key (12, text.tertiary) and a value menu (12, text.primary, a text.tertiary
    /// up-down chevron), then the Fine tune row. They scroll when the body is short.
    private var properties: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(DesignValues.color("line.default")).frame(height: 1)
                        .padding(.top, Metrics.hairlineBlock - 1).accessibilityHidden(true)
                    CaptionPropertyRow("Words per caption", marker: "words") { wordsMenu }
                    CaptionPropertyRow("Case", marker: "case") { caseMenu }
                    CaptionPropertyRow("Position", marker: "position") { positionMenu }
                    fineTuneDisclosure.id("captions.fineTune")
                    if fineTune { fineTuneControls }
                }
                .padding(.horizontal, Metrics.inset)
                .padding(.bottom, Metrics.propertiesBottomInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                if abs(height - propertiesHeight) > 0.5 { propertiesHeight = height }
            }
            .onChange(of: fineTune) { _, expanded in
                if expanded { reader.scrollTo("captions.fineTune", anchor: .top) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.captions.properties")
        .columnLayoutEvidence("captions.properties")
    }
    private var wordsMenu: some View {
        let words = wordsChoice
        return CaptionValueMenu(title: "Words per caption", options: words.options.map { CaptionMenuOption(value: $0, label: Self.wordsLabel($0)) },
                                selection: Binding(get: { words.selected }, set: { count in mutate { CaptionFineTuning.words(&$0, count: count == words.standard ? 0 : count) } }),
                                empty: "Off")
            .disabled(style == nil)
    }
    private var caseMenu: some View {
        CaptionValueMenu(title: "Case", options: [CaptionMenuOption(value: "none", label: "As said"), CaptionMenuOption(value: "uppercase", label: "ALL CAPS")],
                         selection: overrideString("text", "transform", fallback: style?.text.transform.rawValue ?? "none"), empty: "Off")
            .disabled(style == nil || style?.text.userOverridable == false)
    }
    private var positionMenu: some View {
        CaptionValueMenu(title: "Position", options: [CaptionMenuOption(value: 0.2, label: "Top"), CaptionMenuOption(value: 0.5, label: "Middle"), CaptionMenuOption(value: 0.8, label: "Bottom")],
                         selection: Binding(get: { storedPosition?.y ?? 0.8 }, set: { y in mutate { CaptionFineTuning.position(&$0, aspect: model.captionPreset, point: y == 0.8 ? nil : CaptionPosition(x: 0.5, y: y)) } }),
                         empty: style == nil ? "Off" : "Custom")
            .disabled(style == nil || style?.position.userDraggable == false)
    }
    /// "Up to 5" (notes.md §7): the style's own words on screen, one word, a line, and an
    /// override the project already holds. Choosing the style's own drops the override.
    private var wordsChoice: (standard: Int, selected: Int, options: [Int]) {
        guard let style else { return (0, 0, []) }
        let standard = ((try? style.resolved(overrides: [:], frame: model.outputSpec().size)) ?? style).layout.maxWords
        var selected = standard
        if case .number(let count) = value("layout", "maxWords") { selected = Int(count) }
        return (standard, selected, Set([1, standard, 16, selected].filter { $0 > 0 }).sorted())
    }
    static func wordsLabel(_ count: Int) -> String { count >= 16 ? "Line" : count == 1 ? "1 word" : "Up to \(count)" }
    /// The rest of the fine-tuning, in the same rows: size, colour (styles with an active-word
    /// colour), punctuation, the drag hint and Reset to Style.
    private var fineTuneControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionPropertyRow("Size", marker: "size") {
                CaptionValueMenu(title: "Size", options: [CaptionMenuOption(value: 0.8, label: "Small"), CaptionMenuOption(value: 1.0, label: "Medium"),
                                                          CaptionMenuOption(value: 1.2, label: "Large"), CaptionMenuOption(value: 1.45, label: "Extra large")],
                                 selection: Binding(get: { if case .number(let scale) = value("font", "sizeScale") { return scale }; return 1 },
                                                    set: { scale in mutate { CaptionFineTuning.size(&$0, scale: scale) } }), empty: "Custom")
            }
            if style?.accent != nil {
                CaptionPropertyRow("Colour", marker: "colour") {
                    HStack(spacing: 0) {
                        ForEach(palette, id: \.hex) { swatch in
                            let chosen = model.project.captions.overrides["accent"] == .string(swatch.hex)
                            Button { mutate { $0.overrides["accent"] = .string(swatch.hex) } } label: {
                                Circle().fill(Color(nsColor: DesignValues.parse(swatch.hex))).frame(width: 14, height: 14)
                                    .overlay { if chosen { Circle().strokeBorder(DesignValues.color("text.primary"), lineWidth: 1.5).padding(-3) } }
                                    .frame(width: 22, height: 22).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(swatch.name)
                            .accessibilityLabel(swatch.name).accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                    // The row's key is hidden from VoiceOver, so the swatches carry its name.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Colour")
                }
            }
            CaptionPropertyRow("Keep punctuation", marker: "punctuation") {
                Toggle("Keep punctuation", isOn: Binding(get: { value("text", "punctuation") == .string("keep") || (value("text", "punctuation") == nil && style?.text.punctuation == .keep) },
                                                         set: { setOverride("text", "punctuation", .string($0 ? "keep" : "strip-keep-numeric")) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
                    .disabled(style == nil || style?.text.userOverridable == false)
            }
            Text("Drag captions on the video to move them.").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
            Button { mutate { CaptionFineTuning.reset(&$0) } } label: {
                Text("Reset to Style").font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    .frame(height: Metrics.propertyRowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Reset to Style")
        }
        .columnLayoutEvidence("captions.fineTune")
    }
    /// The Fine tune row: closed by default; "Edited" at its end while the style has overrides
    /// or a stored position.
    private var fineTuneDisclosure: some View {
        DisclosureGroup(isExpanded: $fineTune) { EmptyView() } label: {
            HStack(spacing: 5) {
                Text("Fine tune").font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                Image(systemName: fineTune ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignValues.color("text.tertiary"))
                Spacer(minLength: 8)
                if model.captionsEdited { Text("Edited").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary")) }
            }
            .frame(height: Metrics.propertyRowHeight).contentShape(Rectangle())
        }
        .disclosureGroupStyle(CaptionDisclosureStyle())
        .accessibilityLabel("Fine tune captions, \(model.captionSummary)")
        .accessibilityValue(fineTune ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("voxclip.captions.disclosure")
        .columnLayoutEvidence("captions.property.fineTune", text: "Fine tune")
    }
    private var style: CaptionStyle? { model.app.styles.first { $0.id == model.project.captions.styleId } }
    private var storedPosition: CaptionPosition? { model.captionPreset == .source ? model.project.captions.position : model.project.captions.positionByAspect[model.captionPreset.rawValue] }
    private var palette: [(name: String, hex: String)] { [("Yellow", "#FFE14D"), ("Green", "#4BE38A"), ("Cyan", "#5CE1FF"), ("Pink", "#FF6FAE"), ("Paper", "#F3F0E7"), ("White", "#FFFFFF")] }
    private func mutate(_ change: (inout CaptionSettings) -> Void) { var next = model.project; change(&next.captions); model.replace(next, name: "Fine tune captions") }
    private func value(_ group: String, _ key: String) -> JSONValue? { if case .object(let object) = model.project.captions.overrides[group] { return object[key] }; return nil }
    private func setOverride(_ group: String, _ key: String, _ value: JSONValue) {
        var next = model.project; var object: [String: JSONValue] = [:]
        if case .object(let existing) = next.captions.overrides[group] { object = existing }
        object[key] = value; next.captions.overrides[group] = .object(object); model.replace(next, name: "Fine tune captions")
    }
    private func overrideString(_ group: String, _ key: String, fallback: String) -> Binding<String> { Binding(get: { if case .string(let string) = value(group, key) { return string }; return fallback }, set: { setOverride(group, key, .string($0)) }) }
}

/// A property row (notes.md `.prop`): 24 high, the key in a 120 pt column (12,
/// text.tertiary), then the value. VoiceOver reads the value's own control, which carries
/// the key as its name; a value of several controls (Colour's swatches) is a group named so.
@MainActor private struct CaptionPropertyRow<Value: View>: View {
    let title: String
    let marker: String
    let value: Value
    init(_ title: String, marker: String, @ViewBuilder value: () -> Value) {
        self.title = title; self.marker = marker; self.value = value()
    }
    var body: some View {
        HStack(spacing: 0) {
            Text(title).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.tertiary")).lineLimit(1)
                .frame(width: CaptionsPanelMetrics.keyWidth, alignment: .leading).accessibilityHidden(true)
            value
            Spacer(minLength: 0)
        }
        .frame(height: CaptionsPanelMetrics.propertyRowHeight)
        .columnLayoutEvidence("captions.property.\(marker)", text: title)
    }
}

struct CaptionMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// A property row's value (notes.md `.prop .v`): the value (12, text.primary) and an up-down
/// chevron (text.tertiary), which opens the choices with the current one checked.
@MainActor private struct CaptionValueMenu<Value: Hashable>: View {
    let title: String
    let options: [CaptionMenuOption<Value>]
    @Binding var selection: Value
    /// What the row shows when the value is none of the choices.
    let empty: String
    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(current).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.primary"))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignValues.color("text.tertiary"))
            }
            .frame(height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(current)
        .columnLayoutEvidence("captions.value.\(title)", text: current)
    }
    private var current: String { options.first { $0.value == selection }?.label ?? empty }
}

struct CaptionGalleryRequest: Equatable {
    let selection: String
    let size: CGSize
    let fineTune: Bool
    var scope: String { selection.split(separator: "/").dropLast().joined(separator: "/") }
}

struct CaptionGalleryReveal: Equatable {
    private(set) var request: CaptionGalleryRequest?
    private(set) var pending = false
    private(set) var interrupted = false
    private(set) var commands = 0
    private var lastTarget: CaptionGalleryTarget?
    private var lastGeometry: [CGFloat] = []
    private var visibleTileSelection: String?
    /// A new style or scope reveals the selected tile, and so does opening or closing Fine
    /// tune, which resizes the gallery: Fine tune scrolls on its own, below the gallery, and
    /// the selected tile is the one that previews its edits. Only a click on a tile in view
    /// and the user's own scrolling leave the gallery where it is.
    mutating func begin(_ request: CaptionGalleryRequest) {
        guard self.request != request else { return }
        let previous = self.request
        self.request = request
        let scopeChanged = previous.map { $0.scope != request.scope } ?? false
        if visibleTileSelection == request.selection, !scopeChanged {
            visibleTileSelection = nil
            cancelForUserScroll()
            return
        }
        visibleTileSelection = nil
        let fineTuneToggled = previous.map { $0.fineTune != request.fineTune } ?? false
        if previous?.selection != request.selection || scopeChanged || fineTuneToggled {
            pending = true; interrupted = false; lastTarget = nil
        }
    }
    mutating func selectVisibleTile(_ selection: String) {
        visibleTileSelection = selection
        cancelForUserScroll()
    }
    mutating func complete() { pending = false }
    mutating func resumeForLayout() { if !interrupted { pending = request != nil } }
    mutating func restart() { pending = request != nil; interrupted = false; lastTarget = nil }
    mutating func cancelForUserScroll() { pending = false; interrupted = true }
    mutating func shouldScroll(to target: CaptionGalleryTarget, geometry: [CGFloat] = []) -> Bool {
        guard pending else { return false }
        if lastTarget == target {
            guard geometry != lastGeometry else { return false }
        }
        lastTarget = target; lastGeometry = geometry; commands += 1
        return true
    }
}

struct CaptionGalleryViewport: Equatable {
    var visible = CGRect.zero
    var size = CGSize.zero
    var contentSize = CGSize.zero
}

@MainActor final class CaptionGalleryScrollState {
    private(set) var viewport = CaptionGalleryViewport()
    func record(_ viewport: CaptionGalleryViewport) -> Bool {
        let sizeChanged = self.viewport.size != viewport.size
        self.viewport = viewport
        return sizeChanged
    }
}

private struct CaptionGalleryTileGeometry: Equatable {
    let styleID: String
    let frame: CGRect
}

private struct CaptionGalleryLayout: Equatable {
    let tile: CaptionGalleryTileGeometry?
    let size: CGSize
}

private enum CaptionGallerySpace: Hashable { case content }

#if DEBUG
@MainActor enum CaptionGalleryAudit {
    static let notification = Notification.Name("com.voxclip.caption-gallery-audit")
    struct Snapshot: Codable, Equatable {
        let paint: CGRect?; let visible: CGRect; let size: CGSize; let pending: Bool
        let selectedStyle: String; let paintStyle: String?; let interrupted: Bool; let commands: Int
        /// Whether the reveal has taken the gallery's current request (selection, viewport, Fine Tune).
        let consumed: Bool; let requestStyle: String?; let requestHeight: CGFloat?; let fineTune: Bool; let contentSize: CGSize
        /// The gallery holds keyboard focus.
        let focused: Bool
    }
    static var snapshots: [String: Snapshot] = [:]
}
#endif

private struct CaptionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isExpanded.toggle() } label: { configuration.label }.buttonStyle(.plain)
    }
}

/// The image of a gallery tile. A run that finishes after a newer one started never replaces
/// the newer one's image.
@Observable @MainActor final class CaptionTileState {
    private(set) var image: CGImage?
    private var generation = 0
    func load(_ input: CaptionCardInput, render: @MainActor (CaptionCardInput) async -> CGImage?) async {
        generation += 1
        let request = generation
        guard !Task.isCancelled else { return }
        let result = await render(input)
        guard !Task.isCancelled, request == generation else { return }
        image = result
    }
    func invalidate() { generation += 1 }
}

/// A gallery tile's picture: the card on the stage. While a new width draws, the last
/// picture fills the tile.
@MainActor struct CaptionTile: View {
    let input: CaptionCardInput
    let pipeline: CaptionHandoff
    @State private var state = CaptionTileState()
    var body: some View {
        ZStack {
            DesignValues.color("stage")
            if let image = state.image {
                Image(decorative: image, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            }
        }
        .task(id: input) {
            await state.load(input) { await pipeline.card($0) }
        }
        .onDisappear { state.invalidate() }
        .accessibilityHidden(true)
    }
}
