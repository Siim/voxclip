import SwiftUI
import VoxClipCore

/// "How should clips be made?" (design.md §6.6): shown once above the clip list, inline, never a sheet. A chip
/// chooses and collapses the card to the status bar's "Style: …" item, which reopens it here.
@MainActor struct ClipStyleCard: View {
    let editor: EditorModel

    var body: some View {
        if let catalog = editor.clipStyles, let style = editor.cardClipStyle {
            card(catalog: catalog, style: style)
                .padding(VCTokens.spacingCardPadding)
                .background(DesignValues.color("bg.surface"), in: .rect(cornerRadius: VCTokens.radiusPane))
                .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusPane).strokeBorder(DesignValues.color("line.default")))
                .padding(.vertical, VCTokens.spacingLabelGap)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("How should clips be made?")
                .accessibilityIdentifier("voxclip.clipStyle.card")
        }
    }

    private func card(catalog: ClipStyleCatalog, style: ClipStyle) -> some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingGroupGap) {
            header
            modeControl
            if !editor.claudeModeOn {
                ClipStyleFlowLayout(spacing: VCTokens.spacingLabelGap) {
                    ForEach(catalog.presets) { preset in
                        chip(preset, selected: style.preset == preset.id)
                    }
                }
            }
            // One vertical stack of rows: Claude mode's own (Clips, Spend), then the style's.
            VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
                if editor.claudeModeOn { claudeRows(style, catalog: catalog) }
                if !editor.claudeModeOn { pickRows(style, catalog: catalog) }
                shapeRow(style, shapes: catalog.shapes)
                if !editor.claudeModeOn { rewordingRow(style, catalog: catalog) }
            }
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
            Text("How should clips be made?").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignValues.color("text.primary")).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: VCTokens.spacingRowGap)
            Button("Done") { editor.collapseClipStyleCard() }.buttonStyle(.borderless).font(.system(size: 12))
                .accessibilityIdentifier("voxclip.clipStyle.done")
        }
    }

    /// The card's footer names the next step.
    private var footer: some View {
        Text(editor.claudeModeOn
             ? "Free on your Claude plan; the cap covers ElevenLabs voice and generated music. Claude never spends past it. Next: Done, then drop a video."
             : "Claude suggests clips; ✦ Make it postable on a clip uses this style. Next: Done.")
            .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize(horizontal: false, vertical: true)
    }

    private func rewordingRow(_ style: ClipStyle, catalog: ClipStyleCatalog) -> some View {
        optionRow("Rewording", value: catalog.rewording.first { $0.id == style.rewording.rawValue }?.label ?? style.rewording.rawValue,
                  options: catalog.rewording.map { ($0.id, $0.label) }, selected: style.rewording.rawValue) { id in
            editor.updateClipStyle { $0.rewording = ClipRewording(rawValue: id) ?? $0.rewording }
        }
    }

    /// "I'll pick" rows above Shape: Captions, Music and Length.
    @ViewBuilder private func pickRows(_ style: ClipStyle, catalog: ClipStyleCatalog) -> some View {
        captionsRow(style)
        optionRow("Music", value: catalog.music.first { $0.id == style.music.rawValue }?.label ?? style.music.rawValue,
                  help: catalog.music.first { $0.id == style.music.rawValue }?.detail, options: catalog.music.map { ($0.id, [$0.label, $0.detail].compactMap { $0 }.joined(separator: " · ")) }, selected: style.music.rawValue) { id in
            editor.updateClipStyle { $0.music = ClipMusicPreference(rawValue: id) ?? $0.music }
        }
        optionRow("Length", value: "Up to \(style.maxLengthSec) s", options: catalog.lengthChoicesSec.map { ("\($0)", "Up to \($0) s") }, selected: "\(style.maxLengthSec)") { id in
            editor.updateClipStyle { $0.maxLengthSec = Int(id) ?? $0.maxLengthSec }
        }
    }

    /// Claude mode's rows: Clips, Spend, Rewording and Style (the presets as one menu); Shape follows for both modes.
    @ViewBuilder private func claudeRows(_ style: ClipStyle, catalog: ClipStyleCatalog) -> some View {
        let settings = editor.clipsAutopilot
        optionRow("Clips", value: "Top \(settings.count) per video", options: ClipsMode.counts.map { ("\($0)", "Top \($0) per video") },
                  selected: "\(settings.count)") { id in editor.setClaudeClipCount(Int(id) ?? settings.count) }
        optionRow("Spend", value: Self.spendLabel(settings.capUSD), options: ClipsMode.capsUSD.map { ("\($0)", Self.spendLabel($0)) },
                  selected: "\(settings.capUSD)") { id in editor.setClaudeSpendCap(Int(id) ?? settings.capUSD) }
        rewordingRow(style, catalog: catalog)
        let preset = catalog.preset(style.preset)
        optionRow("Style", value: Self.presetTitle(preset), options: catalog.presets.map { ($0.id.rawValue, Self.presetTitle($0)) },
                  selected: style.preset.rawValue) { id in
            if let chosen = ClipStylePresetID(rawValue: id) { editor.chooseClipPreset(chosen, collapse: false) }
        }
    }

    /// "✦ Claude does it all | I'll pick": the remembered mode, on top of the card.
    private var modeControl: some View {
        let mode = editor.clipsAutopilot.mode
        return HStack(alignment: .center, spacing: VCTokens.spacing1) {
            segment("✦ Claude does it all", on: mode == .claude, ai: true) { editor.chooseClipsMode(.claude) }
                .accessibilityIdentifier("voxclip.clipStyle.mode.claude")
            segment("I'll pick", on: mode == .pick, ai: false) { editor.chooseClipsMode(.pick) }
                .accessibilityIdentifier("voxclip.clipStyle.mode.pick")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(VCTokens.spacing1)
        .background(DesignValues.color("bg.muted"), in: .rect(cornerRadius: VCTokens.radiusControl + 1))
        .overlay(RoundedRectangle(cornerRadius: VCTokens.radiusControl + 1).strokeBorder(DesignValues.color("line.default")))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Who makes the clips")
    }

    private func segment(_ title: String, on: Bool, ai: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            Text(title).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(DesignValues.color(on ? (ai ? "ai.tint" : "text.primary") : "text.secondary"))
                .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, VCTokens.spacing2 + 1)
                .background(on ? DesignValues.color("bg.selectedRow") : Color.clear, in: .rect(cornerRadius: VCTokens.radiusControl - 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .modifier(PanelButtonEvidence(id: "clipStyle.mode.\(ai ? "claude" : "pick")", title: title))
    }

    static func spendLabel(_ usd: Int) -> String { usd == 0 ? "No paid voice or music ($0)" : "Up to \(EditorModel.makeItDollars(Decimal(usd))) per video" }

    static func presetTitle(_ preset: ClipStyleCatalog.Preset) -> String {
        preset.id == .auto ? "✦ \(preset.label)" + (preset.detail.map { " · \($0)" } ?? "") : preset.label
    }

    private func chip(_ preset: ClipStyleCatalog.Preset, selected: Bool) -> some View {
        let title = preset.id == .auto ? "✦ \(preset.label)" : preset.label
        return Button { editor.chooseClipPreset(preset.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                if let detail = preset.detail, preset.id == .auto {
                    Text(detail).font(.system(size: 10)).foregroundStyle(DesignValues.color("text.secondary"))
                }
            }
            .padding(.horizontal, VCTokens.spacingFieldPaddingX).padding(.vertical, VCTokens.spacing2)
            .frame(minHeight: 24)
            .background(DesignValues.color(selected ? "bg.selectedRow" : "bg.muted"), in: .capsule)
            .overlay(Capsule().strokeBorder(DesignValues.color(selected ? "line.strong" : "line.default")))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel([preset.label, preset.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("voxclip.clipStyle.preset.\(preset.id.rawValue)")
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).frame(width: 68, alignment: .leading)
    }

    private func captionsRow(_ style: ClipStyle) -> some View {
        let library = editor.app.styles
        let value: String
        switch style.captions {
        case .auto: value = "Auto · Claude"
        case .off: value = "Off"
        case .style(let id): value = library.first { $0.id == id }.map { "\($0.name) · \($0.fontName)" } ?? id
        }
        return HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingLabelGap) {
            label("Captions")
            Menu {
                Button { editor.setClipCaptions(.auto) } label: { check(style.captions == .auto, "Auto · Claude picks per clip") }
                Button { editor.setClipCaptions(.off) } label: { check(style.captions == .off, "Off") }
                Divider()
                ForEach(CaptionsSection.galleryOrder(library), id: \.id) { caption in
                    Button { editor.setClipCaptions(.style(caption.id)) } label: { check(style.captions == .style(caption.id), "\(caption.name) · \(caption.fontName)") }
                }
            } label: { valueText(value) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Captions, \(value)")
            .accessibilityIdentifier("voxclip.clipStyle.captions")
        }
    }

    private func optionRow(_ title: String, value: String, help: String? = nil, options: [(id: String, label: String)], selected: String, choose: @escaping (String) -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingLabelGap) {
            label(title)
            Menu {
                ForEach(options, id: \.id) { option in
                    Button { choose(option.id) } label: { check(option.id == selected, option.label) }
                }
            } label: { valueText(value) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .help(help ?? "")
            .accessibilityLabel([title, value, help].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("voxclip.clipStyle.\(title.lowercased())")
        }
    }

    private func shapeRow(_ style: ClipStyle, shapes: [AspectRatio]) -> some View {
        let value = style.shapes.map(\.rawValue).joined(separator: " and ")
        return HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingLabelGap) {
            label("Shape")
            Menu {
                ForEach(shapes, id: \.self) { shape in
                    let on = style.shapes.contains(shape)
                    // The last shape cannot be turned off: a style always makes at least one.
                    Button { editor.updateClipStyle { next in next.shapes = on ? next.shapes.filter { $0 != shape } : shapes.filter { next.shapes.contains($0) || $0 == shape } } } label: { check(on, shape.rawValue) }
                        .disabled(on && style.shapes.count == 1)
                }
            } label: { valueText(value) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Shape, \(value)")
            .accessibilityIdentifier("voxclip.clipStyle.shape")
        }
    }

    private func valueText(_ text: String) -> some View {
        HStack(spacing: VCTokens.spacing1) {
            Text(text).font(.system(size: 12)).foregroundStyle(DesignValues.color("text.primary")).lineLimit(3).multilineTextAlignment(.leading)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(DesignValues.color("text.tertiary"))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func check(_ on: Bool, _ text: String) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
}

/// Under the Captions STYLE row while the clip style's captions are Auto: what Claude picked for this clip and why,
/// and Pick styles when clips have no pick yet. It runs through the same inline send confirmation as Find Clips.
@MainActor struct ClipStyleCaptionRow: View {
    @Bindable var model: EditorModel

    var body: some View {
        Group {
            if let style = model.project.clipStyle, case .auto = style.captions {
                VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
                    if let pick = model.activeCaptionPick, let name = model.app.styles.first(where: { $0.id == pick.styleId })?.name {
                        (Text("✦ Claude picked ").foregroundStyle(DesignValues.color("text.secondary")) + Text(name).fontWeight(.semibold)
                         + Text(pick.reason.isEmpty ? "" : " · \(pick.reason)").foregroundStyle(DesignValues.color("text.secondary")))
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("voxclip.captions.claudePick")
                    }
                    if model.clipStyleState.picking {
                        HStack(spacing: VCTokens.spacingRowGap) {
                            ProgressView().controlSize(.small)
                            Text("Picking caption styles…").font(.system(size: 12))
                            Spacer(minLength: VCTokens.spacingRowGap)
                            Button("Cancel") { model.clipStyleState.task?.cancel() }.buttonStyle(.borderless).font(.system(size: 12))
                        }
                    } else if model.canPickCaptionStyles, model.unpickedClipCount > 0, !model.clipStyleState.confirmation.isPresented {
                        let count = model.unpickedClipCount
                        Button { model.pickCaptionStyles() } label: {
                            Label(count == 1 ? "Pick a style for 1 clip" : "Pick styles for \(count) clips", systemImage: "sparkles").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("voxclip.captions.pickStyles")
                    }
                    ConnectorConfirmationView(confirmation: model.clipStyleState.confirmation, model: model)
                    if let error = model.clipStyleState.error { InlineNotice(text: error).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.top, VCTokens.spacingLabelGap)
            }
        }
        .onChange(of: model.activeClip?.id, initial: true) { _, _ in model.applyCaptionPick() }
    }
}

/// Lays its children out in rows, wrapping to the width it is offered.
struct ClipStyleFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.isEmpty ? size.width : rowWidth + spacing + size.width
            if !current.isEmpty, next > width {
                rows.append((current, rowWidth, rowHeight))
                current = [index]; rowWidth = size.width; rowHeight = size.height
            } else {
                current.append(index); rowWidth = next; rowHeight = max(rowHeight, size.height)
            }
        }
        if !current.isEmpty { rows.append((current, rowWidth, rowHeight)) }
        return rows
    }
}
