import SwiftUI
import VoxClipCore
import VoxClipMedia
import CryptoKit

@MainActor struct CaptionsInspector: View {
    @Bindable var model: EditorModel
    @State private var fineTune = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Style").font(.headline)
                if let error = model.captionError { InlineNotice(text: error) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    styleTile(nil)
                    ForEach(model.app.styles, id: \.id) { style in styleTile(style) }
                }.accessibilityElement(children: .contain).accessibilityLabel("Caption style, radio group")
                if model.app.styles.isEmpty { Text("Caption styles are unavailable. Reinstall VoxClip.").foregroundStyle(.secondary) }
                DisclosureGroup("Fine tune", isExpanded: $fineTune) {
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
                }
            }.padding(16)
        }
    }
    private var style: CaptionStyle? { model.app.styles.first { $0.id == model.project.captions.styleId } }
    private var storedPosition: CaptionPosition? { model.captionPreset == .source ? model.project.captions.position : model.project.captions.positionByAspect[model.captionPreset.rawValue] }
    private var palette: [(name: String, hex: String)] { [("Yellow", "#FFE14D"), ("Green", "#4BE38A"), ("Cyan", "#5CE1FF"), ("Pink", "#FF6FAE"), ("Paper", "#F3F0E7"), ("White", "#FFFFFF")] }
    private func mutate(_ change: (inout CaptionSettings) -> Void) { var next = model.project; change(&next.captions); model.replace(next, name: "Fine tune captions") }
    private func styleTile(_ style: CaptionStyle?) -> some View {
        let id = style?.id ?? "off"
        return Button { model.setStyle(id) } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    CaptionTile(input: style.map { model.captionTileInput($0) }, pipeline: model.app.captions)
                        .frame(maxWidth: .infinity).frame(height: 80)
                        .background(DesignValues.color("bg.elevated"), in: .rect(cornerRadius: 12))
                    if model.project.captions.styleId == id { Image(systemName: "checkmark.circle.fill").padding(6).foregroundStyle(DesignValues.accentText) }
                }.overlay(RoundedRectangle(cornerRadius: 12).stroke(model.project.captions.styleId == id ? DesignValues.accentText : Color.clear, lineWidth: 2))
                Text(style?.name ?? "Off").font(.caption).foregroundStyle(DesignValues.color("text.primary")).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(style?.name ?? "Off"): \(style?.description ?? "Just the video")").accessibilityAddTraits(model.project.captions.styleId == id ? .isSelected : [])
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

@MainActor private struct CaptionTile: View {
    let input: CaptionTileInput?
    let pipeline: CaptionHandoff
    @State private var image: NSImage?
    @State private var unavailable = false
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if input == nil { VStack(spacing: 4) { Text("Off").font(.headline); Text("Just the video").font(.caption2).foregroundStyle(DesignValues.color("text.muted")) } }
            else if unavailable { Text("Preview unavailable").font(.caption2).foregroundStyle(DesignValues.color("text.muted")).multilineTextAlignment(.center).padding(8) }
            else { ProgressView().controlSize(.small) }
        }
        .task(id: input) {
            guard let input else { return }
            image = await pipeline.tile(input)
            unavailable = image == nil
        }
    }
}
