import SwiftUI
import VoxClipCore

/// The look controls (looks spec 2026-11-28, section 3; approved mockup frames 1–7): one view type at two densities.
/// - `.header`, `.body` or `.full` in the Picture panel: the Claude line, the Look row with Compare, Amount, category chips,
///   the tile grid, and the Fine-tune fold with its Fix, Light, Color and Effects groups. The panel pins the header while its
///   body is at least 300 pt tall.
/// - `.compact` in the Clip section: the Look row with Compare, Amount, one row of Suggested tiles and the link into Picture.
/// Every control stays visible and is disabled with its reason (spec section 10); nothing opens a pop-up.
@MainActor struct ClipLookControls: View {
    enum Part { case full, header, body, compact }
    let model: EditorModel
    var part: Part = .full

    init(model: EditorModel, part: Part = .full) { self.model = model; self.part = part }

    var body: some View {
        let _ = model.projectRevision
        if let panel = model.lookPanel {
            content(panel)
                .id(panel.controls.clipId)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(part == .compact ? "voxclip.clip.look" : "voxclip.picture.look")
        } else if part == .compact, model.currentClipControls != nil, model.project.media.source.video == nil {
            // An audio-only recording keeps the Look block, disabled with its reason.
            CaptionPropertyRow("Look", marker: "clip.look") {
                Text("This recording has no picture to color.").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    .accessibilityIdentifier("voxclip.clip.look.reason")
            }
        }
    }

    @ViewBuilder private func content(_ panel: ClipLookPanel) -> some View {
        let editReason = model.lookEditReason
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            if part == .header || part == .full { header(panel, editReason: editReason) }
            if part == .compact { compact(panel, editReason: editReason) }
            if part == .body || part == .full { ClipLookBody(model: model, panel: panel, editReason: editReason) }
        }
        .task(id: panel.controls.clipId) { model.measureLookFix(clipID: panel.controls.clipId) }
    }

    @ViewBuilder private func header(_ panel: ClipLookPanel, editReason: String?) -> some View {
        if let line = panel.claudeLine { ClipLookClaudeLine(model: model, text: line.text, useIt: line.useIt, editReason: editReason) }
        ClipLookRow(model: model, panel: panel)
        ClipLookAmountRow(model: model, panel: panel, editReason: editReason)
        if let editReason { ClipLookReason(text: editReason, identifier: "voxclip.picture.reason") }
    }

    @ViewBuilder private func compact(_ panel: ClipLookPanel, editReason: String?) -> some View {
        ClipLookRow(model: model, panel: panel)
        ClipLookAmountRow(model: model, panel: panel, editReason: editReason)
        ClipLookTileGrid(model: model, panel: panel, looks: panel.suggestedLooks, oneRow: 6, editReason: editReason)
        Button {
            model.looks.scrollTarget = panel.match?.look.id
            model.app.shell.showPicture(for: model)
        } label: {
            Text("All looks and Fine-tune in Picture \u{203A}").font(VCType.callout.font())
        }
        .buttonStyle(.link)
        .help("Show every look and the Fine-tune sliders in the Picture panel")
        .accessibilityLabel("Show all looks and Fine-tune in Picture")
        .accessibilityIdentifier("voxclip.clip.look.picture")
        if let editReason { ClipLookReason(text: editReason, identifier: "voxclip.clip.look.reason") }
    }
}

/// A disabled control's reason, inline (text.tertiary, small).
@MainActor struct ClipLookReason: View {
    let text: String
    var identifier: String?
    var body: some View {
        Text(text).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier ?? "voxclip.picture.reason")
    }
}

/// "✦ Claude chose Warm Print · 70% · {reason}", or after a hand change "✦ Claude's pick: Warm Print · 70% · Use it".
@MainActor private struct ClipLookClaudeLine: View {
    let model: EditorModel
    let text: String
    let useIt: Bool
    let editReason: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingLabelGap) {
            Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignValues.color("ai.tint"))
                .accessibilityHidden(true)
            Text(text).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voxclip.picture.claude")
            if useIt {
                Button("Use it") { model.useClaudesLook() }
                    .buttonStyle(.link).font(VCType.small.font())
                    .disabled(editReason != nil)
                    .help(editReason ?? "Use the look Claude chose for this clip")
                    .accessibilityIdentifier("voxclip.picture.claude.use")
            }
        }
        .padding(.horizontal, VCTokens.spacingRowGap).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignValues.color("bg.muted"), in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }
}

/// The Look row: the look's name and amount, and Compare at its right.
@MainActor struct ClipLookRow: View {
    let model: EditorModel
    let panel: ClipLookPanel
    var body: some View {
        CaptionPropertyRow("Look", marker: "picture.look") {
            Text(panel.lookValue).font(VCType.callout.font(.semibold)).foregroundStyle(DesignValues.color("text.primary"))
                .lineLimit(1).truncationMode(.tail)
                .accessibilityLabel("Look \(panel.lookValue)")
                .accessibilityIdentifier("voxclip.picture.look.value")
                .columnLayoutEvidence("picture.look.value", text: panel.lookValue)
            Spacer(minLength: VCTokens.spacingLabelGap)
            ClipLookCompareButton(model: model, panel: panel, iconOnly: false)
        }
    }
}

/// Compare (looks spec section 3.4): held, the viewer shows As filmed; release returns. Space held on the focused button
/// does the same. VoiceOver gets a toggle.
@MainActor struct ClipLookCompareButton: View {
    let model: EditorModel
    let panel: ClipLookPanel
    let iconOnly: Bool
    var body: some View {
        let comparing = model.looks.comparing
        let reason = panel.compareReason ?? (model.lookPreviewsAvailable ? nil : "Previews need the source video. Looks still apply when it's back.")
        HStack(spacing: 3) {
            Image(systemName: "square.split.2x1").font(.system(size: 10, weight: .semibold))
            if !iconOnly { Text("Compare").font(VCType.small.font()) }
        }
        .foregroundStyle(DesignValues.color(reason == nil ? "text.primary" : "text.disabled"))
        .padding(.horizontal, iconOnly ? 4 : 7).frame(minWidth: 22, minHeight: 20)
        .background(DesignValues.color(comparing ? "bg.selectedRow" : "bg.muted"), in: .rect(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DesignValues.color("line.default")))
        .contentShape(.rect)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 400, perform: {}, onPressingChanged: { pressing in
            guard reason == nil else { return }
            model.setLookCompare(pressing)
        })
        .focusable(reason == nil)
        .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
            guard reason == nil else { return .ignored }
            model.setLookCompare(press.phase == .down)
            return .handled
        }
        .help(reason ?? "Hold to compare with as filmed (\\)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compare with as filmed")
        .accessibilityValue(comparing ? "Showing as filmed" : "Showing \(panel.lookName)")
        .accessibilityHint(reason ?? "")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { if reason == nil { model.setLookCompare(!comparing) } }
        .accessibilityIdentifier("voxclip.picture.compare")
        .columnLayoutEvidence(iconOnly ? "panel.compare" : "picture.compare")
        .onDisappear { if model.looks.comparing { model.setLookCompare(false) } }
    }
}

/// Amount (looks spec section 3.3): 0–100%, disabled with its reason while there is no look to blend. A drag previews on
/// the paused viewer and commits once on release; ←/→ step 1 and Shift 10; a double-click or Delete returns to 100;
/// clicking the value types one; VoiceOver steps 5.
@MainActor struct ClipLookAmountRow: View {
    let model: EditorModel
    let panel: ClipLookPanel
    let editReason: String?
    @State private var draft: Int?
    @State private var dragging = false
    @FocusState private var focused: Bool

    var body: some View {
        let reason = editReason ?? panel.amountReason
        let value = draft ?? panel.amount
        VStack(alignment: .leading, spacing: 2) {
            CaptionPropertyRow("Amount", marker: "picture.amount") {
                ClipLookTrack(value: value, range: 0...100, tick: nil, dragging: $dragging, draft: $draft,
                              preview: { preview($0) }, commit: { commit($0) }, reset: { commit(100) })
                    .disabled(reason != nil)
                    .focused($focused)
                    .accessibilityLabel("Look amount")
                    .accessibilityValue("\(value) percent")
                    .accessibilityHint(reason ?? "Blends the look over the clip; the fix stays")
                    .accessibilityAdjustableAction { direction in
                        commit(value + (direction == .increment ? 5 : -5))
                    }
                    .accessibilityIdentifier("voxclip.picture.amount")
                ClipLookValueText(text: "\(value)%", width: 40, enabled: reason == nil, label: "Look amount") { typed in
                    Int(typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
                } commit: { commit($0) }
            }
            .help(reason ?? "Blends the look over the clip; the fix stays")
            if let amountReason = panel.amountReason, editReason == nil {
                ClipLookReason(text: amountReason, identifier: "voxclip.picture.amount.reason").padding(.leading, CaptionsPanelMetrics.keyWidth)
            }
        }
        .onChange(of: model.looks.amountFocusRequest) { focused = true }
    }

    private func preview(_ amount: Int) {
        var controls = panel.controls
        var grade = controls.colorGrade ?? ClipColorGrade()
        grade.amount = amount
        controls.colorGrade = grade
        model.previewLookDraft(controls)
    }

    private func commit(_ amount: Int) {
        model.previewLookDraft(nil)
        model.setLookAmount(amount)
    }
}

/// A mini slider whose drag previews and commits once on release, with an optional accent tick for the look's own value.
/// Keyboard steps commit at once: ←/→ 1, Shift 10; Delete or a double-click resets.
@MainActor struct ClipLookTrack: View {
    let value: Int
    let range: ClosedRange<Int>
    let tick: Int?
    @Binding var dragging: Bool
    @Binding var draft: Int?
    let preview: (Int) -> Void
    let commit: (Int) -> Void
    let reset: () -> Void

    var body: some View {
        Slider(value: Binding(get: { Double(value) }, set: { next in
            let point = Int(next.rounded())
            if dragging { if draft != point { draft = point; preview(point) } } else { commit(point) }
        }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1) { editing in
            dragging = editing
            if !editing {
                if let draft { commit(draft) }
                draft = nil
            }
        }
        .controlSize(.mini)
        .overlay { if let tick { tickMark(tick) } }
        .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        .onKeyPress(keys: [.leftArrow, .rightArrow, .delete, .deleteForward]) { press in
            switch press.key {
            case .delete, .deleteForward: reset()
            default:
                let step = press.modifiers.contains(.shift) ? 10 : 1
                let next = min(range.upperBound, max(range.lowerBound, value + (press.key == .leftArrow ? -step : step)))
                if next != value { commit(next) }
            }
            return .handled
        }
    }

    private func tickMark(_ tick: Int) -> some View {
        GeometryReader { geometry in
            let inset: CGFloat = 6
            let span = CGFloat(range.upperBound - range.lowerBound)
            let x = inset + (geometry.size.width - inset * 2) * CGFloat(tick - range.lowerBound) / max(1, span)
            Rectangle().fill(Color.accentColor).frame(width: 2, height: 8)
                .position(x: x, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A slider's value text; a click turns it into a field: type "+20" or "−15", then Return. Escape keeps the value.
@MainActor struct ClipLookValueText: View {
    let text: String
    let width: CGFloat
    let enabled: Bool
    let label: String
    let parse: (String) -> Int?
    let commit: (Int) -> Void
    @State private var editing = false
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    init(text: String, width: CGFloat, enabled: Bool, label: String, parse: @escaping (String) -> Int?, commit: @escaping (Int) -> Void) {
        self.text = text; self.width = width; self.enabled = enabled; self.label = label; self.parse = parse; self.commit = commit
    }

    var body: some View {
        Group {
            if editing {
                TextField(label, text: $typed)
                    .textFieldStyle(.roundedBorder).controlSize(.mini).font(VCType.small.font()).monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .focused($fieldFocused)
                    .onSubmit { if let value = parse(typed) { commit(value) }; editing = false }
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { if !fieldFocused { editing = false } }
                    .onAppear { typed = text; fieldFocused = true }
                    .accessibilityLabel("\(label) value")
            } else {
                Button { editing = true } label: {
                    Text(text).font(VCType.small.font()).monospacedDigit()
                        .foregroundStyle(DesignValues.color(enabled ? "text.secondary" : "text.disabled"))
                        .frame(maxWidth: .infinity, alignment: .trailing).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(enabled ? "Type a value" : "")
                .accessibilityLabel("Type the \(label.lowercased()) value")
            }
        }
        .frame(width: width, alignment: .trailing)
    }
}

/// The panel's body under the header: notes, category chips, the tiles and Fine-tune.
@MainActor private struct ClipLookBody: View {
    let model: EditorModel
    let panel: ClipLookPanel
    let editReason: String?

    var body: some View {
        let looks = panel.looks(in: model.looks.category)
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            if case .sample(let note?) = model.looks.tileSource {
                Text(note).font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voxclip.picture.sample")
            }
            ClipLookCategories(model: model, panel: panel)
            ClipLookTileGrid(model: model, panel: panel, looks: looks, oneRow: nil, editReason: editReason)
            ClipLookFineTune(model: model, panel: panel, editReason: editReason)
            ClipLookTimedLooks(model: model, clipID: panel.controls.clipId, lookName: panel.lookName)
        }
    }
}

/// The category chips (one keyboard stop): ←/→ move, Space or Return choose. The choice is view state, not an undo step.
@MainActor private struct ClipLookCategories: View {
    let model: EditorModel
    let panel: ClipLookPanel
    @State private var focusedIndex = 0
    @FocusState private var focused: Bool

    var body: some View {
        let categories = panel.categories
        let chosen = model.looks.category
        ClipStyleFlowLayout(spacing: VCTokens.spacingChipGap) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                chip(category.label, on: category.id == chosen, ring: focused && index == focusedIndex)
                    .onTapGesture { model.looks.category = category.id }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(category.label)
                    .accessibilityAddTraits(category.id == chosen ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { model.looks.category = category.id }
                    .accessibilityIdentifier("voxclip.picture.category.\(category.id)")
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space, .return]) { press in
            switch press.key {
            case .leftArrow: focusedIndex = max(0, focusedIndex - 1)
            case .rightArrow: focusedIndex = min(categories.count - 1, focusedIndex + 1)
            default: model.looks.category = categories[min(focusedIndex, categories.count - 1)].id
            }
            return .handled
        }
        .onAppear { focusedIndex = categories.firstIndex { $0.id == chosen } ?? 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Look categories")
        .columnLayoutEvidence("picture.categories")
    }

    private func chip(_ label: String, on: Bool, ring: Bool) -> some View {
        Text(label).font(.system(size: 11))
            .foregroundStyle(DesignValues.color("text.primary"))
            .padding(.horizontal, VCTokens.spacingRowGap).frame(minHeight: 22)
            .background(DesignValues.color(on ? "bg.selectedRow" : "bg.muted"), in: .capsule)
            .overlay(Capsule().strokeBorder(ring ? Color.accentColor : DesignValues.color(on ? "line.strong" : "line.default"), lineWidth: ring ? 2 : 1))
            .contentShape(.capsule)
    }
}

/// The tiles (one keyboard stop): square, at least 56 pt, 6 apart, as many columns as fit, or one row of at most `oneRow`.
/// A click applies; hover for 120 ms or keyboard focus previews on the paused viewer; ←/→/↑/↓ move, Home and End jump,
/// Return or Space apply, Escape ends the preview.
@MainActor struct ClipLookTileGrid: View {
    static let minimum: CGFloat = 56
    static let gap: CGFloat = 6
    let model: EditorModel
    let panel: ClipLookPanel
    let looks: [ClipLookPreset]
    let oneRow: Int?
    let editReason: String?
    @State private var width: CGFloat = 0
    @State private var focusedIndex: Int?
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// Columns that fit `width`: 4 at 296, 6 at 376, 8 at 532.
    static func columns(width: CGFloat) -> Int { max(1, Int((width + gap) / (minimum + gap))) }

    var body: some View {
        let columns = Self.columns(width: width)
        let shown = oneRow.map { Array(looks.prefix(min($0, columns))) } ?? looks
        let side = max(Self.minimum, ((width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        let pixels = min(144, Int((side * 2 / 16).rounded(.up)) * 16)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: Self.gap, alignment: .top), count: columns),
                  alignment: .leading, spacing: Self.gap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, look in
                ClipLookTile(look: look, panel: panel, image: model.looks.tiles[look.id], side: side,
                             hovered: model.looks.hovered == look.id, focused: focused && focusedIndex == index,
                             playing: model.isPlaying, editReason: editReason)
                    .onTapGesture { apply(look) }
                    .onHover { inside in hover(inside ? look.id : nil) }
                    .accessibilityAction { apply(look) }
                    .id(look.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onHover { inside in if !inside { hover(nil) } }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { if !focused { focusedIndex = nil; model.previewLook(nil) } }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end, .return, .space, .escape]) { press in
            key(press.key, count: shown.count, columns: columns, shown: shown)
        }
        .task(id: "\(panel.controls.clipId):\(pixels):\(model.projectRevision):\(model.isPlaying)") {
            guard !model.isPlaying, pixels > 0, width > 0 else { return }
            // The still follows the paused playhead once it has rested (spec section 7.1).
            try? await Task.sleep(for: .milliseconds(model.looks.tiles.isEmpty ? 0 : 500))
            guard !Task.isCancelled else { return }
            model.refreshLookTiles(pixels: pixels, first: shown.map(\.id))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Looks, \(panel.categoryLabel(model.looks.category))")
        .accessibilityValue("\(shown.count) looks")
        .accessibilityIdentifier(oneRow == nil ? "voxclip.picture.tiles" : "voxclip.clip.look.tiles")
        .columnLayoutEvidence(oneRow == nil ? "picture.tiles" : "clip.look.tiles")
    }

    private func apply(_ look: ClipLookPreset) {
        guard editReason == nil else { return }
        model.previewLook(nil)
        model.chooseLook(look.id)
    }

    /// Hover previews after 120 ms; leaving ends it.
    private func hover(_ id: String?) {
        hoverTask?.cancel()
        guard let id else { model.previewLook(nil); return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            model.previewLook(id)
        }
    }

    private func key(_ key: KeyEquivalent, count: Int, columns: Int, shown: [ClipLookPreset]) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        let current = focusedIndex ?? shown.firstIndex { panel.state(of: $0) != .none } ?? 0
        var next = current
        switch key {
        case .leftArrow: next = current - 1
        case .rightArrow: next = current + 1
        case .upArrow: next = current - columns
        case .downArrow: next = current + columns
        case .home: next = 0
        case .end: next = count - 1
        case .escape: model.previewLook(nil); return .handled
        default:
            apply(shown[min(current, count - 1)])
            return .handled
        }
        focusedIndex = min(count - 1, max(0, next))
        if let index = focusedIndex { model.previewLook(shown[index].id) }
        return .handled
    }
}

/// One look's tile: its picture (decorative), its label below on one line, and its state rings.
@MainActor private struct ClipLookTile: View {
    let look: ClipLookPreset
    let panel: ClipLookPanel
    let image: CGImage?
    let side: CGFloat
    let hovered: Bool
    let focused: Bool
    let playing: Bool
    let editReason: String?

    var body: some View {
        let state = panel.state(of: look)
        VStack(spacing: 3) {
            picture(state)
            Text(look.label).font(.system(size: 11, weight: state == .none ? .regular : .semibold))
                .foregroundStyle(DesignValues.color(state == .none ? "text.secondary" : "text.primary"))
                .lineLimit(1).truncationMode(.tail)
                .frame(width: side)
        }
        .contentShape(.rect)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(panel.tileLabel(look))
        .accessibilityValue(panel.tileValue(look))
        .accessibilityHint(editReason ?? look.line)
        .accessibilityAddTraits(state == .none ? .isButton : [.isButton, .isSelected])
        .accessibilityIdentifier("voxclip.picture.tile.\(look.id)")
    }

    private var help: String {
        if let editReason { return "\(look.label): \(look.line). \(editReason)" }
        return playing ? "\(look.label): \(look.line). Pause to preview on the viewer" : "\(look.label): \(look.line)"
    }

    private func picture(_ state: ClipLookPanel.TileState) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image { Image(decorative: image, scale: 2).resizable().interpolation(.high) }
                else { DesignValues.color("bg.muted") }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("line.default"), lineWidth: 1))
            .overlay(ring(state))
            if panel.isClaudes(look) {
                Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(DesignValues.color("ai.tint"))
                    .padding(3).background(.black.opacity(0.35), in: .circle).padding(3)
            }
            if state != .none {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white, Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(4)
            }
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder private func ring(_ state: ClipLookPanel.TileState) -> some View {
        switch state {
        case .applied: RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
        case .edited: RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        case .none:
            if hovered || focused { RoundedRectangle(cornerRadius: 6).strokeBorder(DesignValues.color("text.secondary"), lineWidth: focused ? 2 : 1.5) }
        }
    }
}

/// Fine-tune ▸ (looks spec section 3.5): the fold, remembered per app, opening by itself for a custom or edited look, with
/// Back to {look} at its right; then Fix, Light, Color and Effects, the toning row and Clear all color.
@MainActor private struct ClipLookFineTune: View {
    static let key = "ui.pictureFineTuneOpen"
    let model: EditorModel
    let panel: ClipLookPanel
    let editReason: String?
    @State private var override: Bool?

    var body: some View {
        let open = override ?? (model.app.bool(Self.key) || panel.opensFineTune)
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            HStack(spacing: VCTokens.spacingLabelGap) {
                Button {
                    override = !open
                    model.app.set(Self.key, .bool(!open))
                } label: {
                    HStack(spacing: VCTokens.spacingLabelGap) {
                        Text("Fine-tune").font(VCType.callout.font(.medium)).foregroundStyle(DesignValues.color("text.primary"))
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DesignValues.color("text.tertiary"))
                    }
                    .frame(height: CaptionsPanelMetrics.propertyRowHeight).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fine-tune")
                .accessibilityValue(open ? "expanded" : "collapsed")
                .accessibilityIdentifier("voxclip.picture.finetune")
                Spacer(minLength: 0)
                if let label = panel.backToLabel {
                    let reason = editReason ?? panel.backToReason
                    Button(label) { model.backToLook() }
                        .buttonStyle(.link).font(VCType.callout.font())
                        .disabled(reason != nil)
                        .help(reason ?? "Every value but the fix back to the look's; Amount stays")
                        .accessibilityHint(reason ?? "")
                        .accessibilityIdentifier("voxclip.picture.backto")
                }
            }
            if open { groups }
        }
    }

    @ViewBuilder private var groups: some View {
        ForEach(ClipLookGroup.allCases, id: \.self) { group in
            ClipLookGroupView(model: model, panel: panel, group: group, editReason: editReason)
        }
        let clearReason = editReason ?? panel.clearReason
        HStack(spacing: VCTokens.spacingLabelGap) {
            Button("Clear all color") { model.clearColor() }
                .buttonStyle(.link).font(VCType.callout.font())
                .disabled(clearReason != nil)
                .help(clearReason ?? "The look, the fine-tuning and the fix, all removed")
                .accessibilityHint(clearReason ?? "Removes the fix too")
                .accessibilityIdentifier("voxclip.picture.clear")
            Spacer(minLength: 0)
            Text(panel.clearReason ?? "removes the Fix too").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
        }
        .padding(.top, 4)
    }
}

/// One Fine-tune group: its heading with Reset (and Auto for the Fix), then its sliders.
@MainActor private struct ClipLookGroupView: View {
    let model: EditorModel
    let panel: ClipLookPanel
    let group: ClipLookGroup
    let editReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            if group == .fix, editReason == nil, let reason = model.autoReason(panel) {
                ClipLookReason(text: reason, identifier: "voxclip.picture.auto.reason")
            }
            ForEach(group.sliders, id: \.self) { slider in
                ClipLookSliderRow(model: model, panel: panel, slider: slider, editReason: editReason)
            }
            if group == .effects, panel.hasToning { toning }
        }
        .padding(.top, 4)
    }

    private var heading: some View {
        HStack(spacing: VCTokens.spacingLabelGap) {
            HStack(spacing: 4) {
                Text(group.title).textCase(.uppercase).font(VCType.small.font(.semibold)).tracking(0.55)
                    .foregroundStyle(DesignValues.color("text.tertiary"))
                if let note = group.note {
                    Text("\u{00B7} \(note)").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary")).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(group.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if group == .fix {
                let reason = editReason ?? model.autoReason(panel)
                Button("Auto") { model.fixLightAndColor() }
                    .buttonStyle(.link).font(VCType.small.font())
                    .disabled(reason != nil)
                    .help(reason ?? "Set exposure, temperature and tint from the clip's frames, measured on this Mac")
                    .accessibilityLabel("Auto fix light and color")
                    .accessibilityHint(reason ?? "")
                    .accessibilityIdentifier("voxclip.picture.auto")
            }
            let reason = editReason ?? panel.resetReason(group)
            Button("Reset") { model.resetLookGroup(group) }
                .buttonStyle(.link).font(VCType.small.font())
                .disabled(reason != nil)
                .help(reason ?? (group == .fix ? "The fix back to 0" : "\(group.title) back to the look's values"))
                .accessibilityLabel(group.resetName.capitalizedFirst)
                .accessibilityHint(reason ?? "")
                .accessibilityIdentifier("voxclip.picture.reset.\(group.rawValue)")
        }
        .frame(height: 22)
    }

    private var toning: some View {
        HStack(spacing: VCTokens.spacingLabelGap) {
            Text(panel.toningText).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary")).lineLimit(2)
                .accessibilityIdentifier("voxclip.picture.toning")
            Spacer(minLength: 0)
            Button("Remove") { model.removeLookToning() }
                .buttonStyle(.link).font(VCType.small.font())
                .disabled(editReason != nil)
                .help(editReason ?? "Remove the look's curve and split tone")
                .accessibilityLabel("Remove toning")
                .accessibilityIdentifier("voxclip.picture.toning.remove")
        }
        .frame(minHeight: 22)
    }
}

/// A Fine-tune slider row: label, the mini slider with the look's tick, and the signed value, which a click types.
@MainActor private struct ClipLookSliderRow: View {
    let model: EditorModel
    let panel: ClipLookPanel
    let slider: ClipLookSlider
    let editReason: String?
    @State private var draft: Int?
    @State private var dragging = false

    var body: some View {
        let reason = editReason ?? panel.reason(slider)
        let value = draft ?? slider.value(panel.controls)
        let tick = panel.tick(slider)
        VStack(alignment: .leading, spacing: 0) {
            CaptionPropertyRow(slider.label, marker: "picture.\(slider.rawValue)") {
                ClipLookTrack(value: value, range: slider.range, tick: panel.origin == nil || slider.group == .fix ? nil : tick,
                              dragging: $dragging, draft: $draft, preview: { preview($0) }, commit: { commit($0) }, reset: { commit(tick) })
                    .disabled(reason != nil)
                    .accessibilityLabel(slider.label)
                    .accessibilityValue(slider.spoken(value))
                    .accessibilityHint(reason ?? panel.origin.map { "\($0.label)'s value: \(slider.spoken(tick))" } ?? "")
                    .accessibilityAdjustableAction { direction in commit(value + (direction == .increment ? 1 : -1)) }
                    .accessibilityIdentifier("voxclip.picture.\(slider.rawValue)")
                ClipLookValueText(text: slider.text(value), width: slider == .exposure ? 64 : 40, enabled: reason == nil, label: slider.label,
                                  parse: { slider.parse($0) }, commit: { commit($0) })
            }
            .help(reason ?? "")
            if let muted = panel.reason(slider), editReason == nil {
                ClipLookReason(text: muted, identifier: "voxclip.picture.\(slider.rawValue).reason").padding(.leading, CaptionsPanelMetrics.keyWidth)
            }
        }
    }

    private func preview(_ point: Int) {
        var controls = panel.controls
        slider.set(point, in: &controls)
        model.previewLookDraft(controls)
    }

    private func commit(_ point: Int) {
        model.previewLookDraft(nil)
        model.setLookSlider(slider, value: point)
    }
}

/// "A timed B&W from Ask Claude replaces this look at 0:12–0:15 · ▶ · Remove" for each timed look over the clip.
@MainActor private struct ClipLookTimedLooks: View {
    let model: EditorModel
    let clipID: String
    let lookName: String

    var body: some View {
        let timed = model.project.clipEffects.filter { $0.kind == .colourLook && $0.clipId == clipID }
        ForEach(timed, id: \.id) { effect in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("A timed \(effect.look?.label ?? "look") from Ask Claude replaces this look at "
                     + "\(model.makeItClipTime(effect.start, clipID: clipID))\u{2013}\(model.makeItClipTime(effect.end, clipID: clipID))")
                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.seek(source: effect.start); if !model.isPlaying { model.transport(" ") } } label: {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                .buttonStyle(.link).accessibilityLabel("Play the timed look")
                Button("Remove") { model.removeTimedLook(effect.id) }
                    .buttonStyle(.link).font(VCType.small.font())
                    .disabled(model.lookEditReason != nil)
                    .accessibilityLabel("Remove the timed look")
            }
            .padding(VCTokens.spacingLabelGap)
            .background(DesignValues.color("status.infoBackground"), in: .rect(cornerRadius: 6))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voxclip.picture.timed")
        }
    }
}

extension EditorModel {
    /// The timed look's Remove, as one step.
    @discardableResult func removeTimedLook(_ id: String) -> Bool {
        guard capabilities.edit, let next = try? ClipEffects.removing([id], from: project) else { return false }
        replace(next, name: "Remove timed look")
        announce("Timed look removed")
        return true
    }
}
