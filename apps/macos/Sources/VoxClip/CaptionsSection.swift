import SwiftUI
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

@MainActor struct CaptionsSection: View {
    @Bindable var model: EditorModel
    @State private var fineTune = false
    @State private var width: CGFloat = 360
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup(isExpanded: $fineTune) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Size", selection: Binding(get: { if case .number(let scale) = value("font", "sizeScale") { return scale }; return 1 }, set: { scale in mutate { CaptionFineTuning.size(&$0, scale: scale) } })) { Text("S").tag(0.8); Text("M").tag(1.0); Text("L").tag(1.2); Text("XL").tag(1.45) }.pickerStyle(.segmented)
                        Picker("Case", selection: overrideString("text", "transform", fallback: style?.text.transform.rawValue ?? "none")) { Text("As said").tag("none"); Text("ALL CAPS").tag("uppercase") }.pickerStyle(.segmented).disabled(style?.text.userOverridable == false)
                        Picker("Words on screen", selection: Binding(get: { if case .number(let count) = value("layout", "maxWords") { return Int(count) }; return 0 }, set: { count in mutate { CaptionFineTuning.words(&$0, count: count) } })) { Text("1").tag(1); Text("Phrase").tag(0); Text("Line").tag(16) }.pickerStyle(.segmented)
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
                        Picker("Position", selection: Binding(get: { storedPosition?.y ?? 0.8 }, set: { y in mutate { CaptionFineTuning.position(&$0, aspect: model.captionPreset, point: y == 0.8 ? nil : CaptionPosition(x: 0.5, y: y)) } })) { Text("Top").tag(0.2); Text("Middle").tag(0.5); Text("Bottom").tag(0.8) }.pickerStyle(.segmented).disabled(style?.position.userDraggable == false)
                        Text("Drag captions on the video to move them.").font(.caption).foregroundStyle(.secondary)
                        Button { mutate { CaptionFineTuning.reset(&$0) } } label: { Text("Reset to style").underline() }.buttonStyle(.plain).foregroundStyle(DesignValues.accentText)
                    }.padding(.top, 12)
                } label: { sectionHeader }
                .disclosureGroupStyle(CaptionDisclosureStyle())
            if let error = model.captionError { InlineNotice(text: error) }
            gallery
        }
        .padding(16)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .tint(Color(nsColor: DesignValues.accentFill))
    }
    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if width < 340 {
                HStack { heading; Spacer(); captionsSwitch }
                HStack(spacing: 8) { liveChip; styleSummary; Spacer(minLength: 0) }
            } else {
                HStack(spacing: 8) { heading; liveChip; styleSummary; Spacer(minLength: 0); captionsSwitch }
            }
        }
    }
    private var heading: some View { Text("Captions").font(.system(size: 13, weight: .semibold)) }
    private var captionsSwitch: some View {
        Toggle("Captions", isOn: Binding(get: { model.project.captions.styleId != "off" }, set: { model.setCaptionsEnabled($0) }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
    }
    private var liveChip: some View {
        Group {
            if let style { CaptionTile(input: model.captionTileInput(style), pipeline: model.app.captions) }
            else { DesignValues.color("stage") }
        }.frame(width: 64, height: 36).clipShape(.rect(cornerRadius: 6)).accessibilityHidden(true)
    }
    private var styleSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(style?.name ?? "Off").font(.system(size: 13, weight: .semibold))
                if model.captionsEdited { Text("Edited").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")) }
            }.lineLimit(1)
            Button { fineTune.toggle() } label: {
                HStack(spacing: 3) { Image(systemName: fineTune ? "chevron.down" : "chevron.right"); Text(model.captionSummary) }
                    .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
            }.buttonStyle(.plain).accessibilityLabel("Fine tune captions, \(model.captionSummary)").accessibilityValue(fineTune ? "Expanded" : "Collapsed")
        }
    }
    private var gallery: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 10) {
                    ForEach(CaptionStyleGroup.allCases, id: \.self) { group in
                        let styles = model.app.styles.filter { CaptionStyleGroup.group(for: $0) == group }.sorted { $0.order < $1.order }
                        if !styles.isEmpty {
                            Section { ForEach(styles, id: \.id) { style in styleTile(style).id(style.id) } } header: {
                                Text(group.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignValues.color("text.secondary")).padding(.top, 2)
                            }
                        }
                    }
                }.padding(.vertical, 3)
                if model.app.styles.isEmpty { Text("Caption styles are unavailable. Reinstall VoxClip.").foregroundStyle(.secondary) }
            }
            .scrollClipDisabled()
            .accessibilityRepresentation {
                Picker("Caption style", selection: Binding(get: { model.project.captions.styleId }, set: { model.setStyle($0) })) {
                    ForEach(model.app.styles.sorted { $0.order < $1.order }, id: \.id) { Text("\($0.name): \($0.description)").tag($0.id) }
                }.pickerStyle(.radioGroup)
            }
            .onChange(of: model.activeClip?.id) { _, _ in reader.scrollTo(model.project.captions.styleId, anchor: .top) }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [DesignValues.color("bg.surface").opacity(0), DesignValues.color("bg.surface")], startPoint: .top, endPoint: .bottom).frame(height: 24).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
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
                }.overlay { if selected { RoundedRectangle(cornerRadius: 12).stroke(DesignValues.accentText, lineWidth: 2).padding(-2) } }
                Text(style.name + (selected && model.captionsEdited ? " · Edited" : "")).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(DesignValues.color("text.primary")).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(style.name): \(style.description)").accessibilityAddTraits(selected ? .isSelected : [])
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

private struct CaptionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) { configuration.label; if configuration.isExpanded { configuration.content } }
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
