import SwiftUI
import VoxClipCore

/// ✦ Ask Claude in the right panel (design.md §6.8, mockup "Clip controls and Ask Claude" B and C): one inline field with
/// example chips that only fill it, then the change list "Done for “…” · 2 changes · Undo all" with ▶ · Adjust · Undo on
/// each row. No pop-ups: the send confirmation, the paid click and every Adjust editor are inline.
@MainActor struct AskClaudePanel: View {
    let model: EditorModel
    @Bindable var state: AskClaudeState
    @FocusState private var fieldFocused: Bool

    init(model: EditorModel) {
        self.model = model
        let state: AskClaudeState = model.askClaude
        _state = Bindable(state)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: VCTokens.spacingGroupGap) {
                    if state.selection != nil { composer }
                    if let run = state.run { changes(run) }
                }
                .padding(.horizontal, VCTokens.spacingPanePaddingMacos).padding(.vertical, VCTokens.spacingGroupGap)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .font(VCType.callout.font())
        .foregroundStyle(DesignValues.color("text.primary"))
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask Claude")
        .accessibilityIdentifier("voxclip.askClaude.panel")
        .onExitCommand { model.closeAskClaude() }
        .onAppear { if state.selection != nil { fieldFocused = true } }
        .onChange(of: state.selection) { _, selection in if selection != nil { fieldFocused = true } }
    }

    // MARK: The field

    private var composer: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            Text("\u{2726} Ask Claude about \(state.label)").font(VCType.title3.font(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("voxclip.askClaude.title")
            TextField("blur the invoice on screen and bleep the amount", text: $state.text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .vcFieldChrome(multiline: true)
                .focused($fieldFocused)
                .disabled(state.asking)
                .onSubmit { model.sendAskClaude() }
                .accessibilityLabel("What should Claude do?")
                .accessibilityIdentifier("voxclip.askClaude.field")
            // The chips only fill the field; while Claude works they step aside rather than show disabled.
            if !state.asking {
                ExpressionFlow(spacing: VCTokens.spacingChipGap) {
                    ForEach(AskClaudeState.chips, id: \.label) { chip in
                        Button(chip.label) { state.text = chip.text; fieldFocused = true }
                            .buttonStyle(.plain)
                            .font(VCType.small.font())
                            .padding(.horizontal, VCTokens.spacingRowGap).frame(height: 22)
                            .background(DesignValues.color("bg.selectedRow"), in: Capsule())
                            .accessibilityHint("Fills the field. Nothing is sent until you press Return.")
                            .accessibilityIdentifier("voxclip.askClaude.chip.\(chip.label)")
                    }
                }
            }
            ConnectorConfirmationView(confirmation: state.confirmation, model: model)
            if let progress = state.progress {
                HStack(spacing: VCTokens.spacingLabelGap) {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(DesignValues.color("text.secondary"))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("voxclip.askClaude.progress")
            }
            if let error = state.error {
                Text(error).foregroundStyle(DesignValues.color("status.dangerForeground")).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voxclip.askClaude.error")
            }
        }
    }

    // MARK: The change list

    private func changes(_ run: AskClaudeRun) -> some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            HStack(spacing: VCTokens.spacingLabelGap) {
                let count = run.appliedCount
                Text("Done for \(run.label) \u{00B7} \(count == 1 ? "1 change" : "\(count) changes")")
                    .font(VCType.callout.font(.semibold))
                    .accessibilityIdentifier("voxclip.askClaude.done")
                Spacer(minLength: 0)
                if count > 0 {
                    Button("Undo all") { model.undoAllAskClaude() }.buttonStyle(.link)
                        .accessibilityIdentifier("voxclip.askClaude.undoAll")
                }
            }
            if !run.summary.isEmpty { note(run.summary) }
            ForEach(run.rows) { row in rowView(row) }
            ForEach(run.repairs, id: \.self) { note($0) }
        }
        .padding(VCTokens.spacingCardPadding)
        .background(DesignValues.color("bg.elevated"), in: RoundedRectangle(cornerRadius: 8))
    }

    private func rowView(_ row: AskClaudeRow) -> some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            HStack(alignment: .firstTextBaseline, spacing: VCTokens.spacingRowGap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).strikethrough(row.status == .undone)
                        .foregroundStyle(DesignValues.color(row.status == .undone ? "text.tertiary" : "text.primary"))
                    Text(row.detail).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary")).lineLimit(2)
                }
                Spacer(minLength: 0)
                rowActions(row)
            }
            if let choice = row.choice, row.status == .applied {
                HStack(spacing: VCTokens.spacingLabelGap) {
                    Text("Claude chose \(choice)").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                    if canAdjust(row) {
                        Button("Change") { state.adjusting = row.id }.buttonStyle(.link).font(VCType.small.font())
                            .accessibilityLabel("Change Claude's choice")
                    }
                }
                .accessibilityIdentifier("voxclip.askClaude.choice.\(row.id)")
            }
            switch row.status {
            case .paid(let price):
                PanelButton(action: PanelAction(id: "askClaude.paid.\(row.id)", title: price, priced: true) { model.runPaidAskClaudeRow(row.id) }, kind: .bordered)
                note("Nothing is spent until you approve the exact price in the next step.")
            case .later(let reason): note(reason)
            case .undone: note("Undone. Use Edit \u{203A} Redo to bring it back.")
            case .applied: if state.adjusting == row.id { adjuster(row) }
            }
        }
        .padding(.vertical, VCTokens.spacingRowPaddingY)
        .overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.askClaude.row.\(row.id)")
    }

    @ViewBuilder private func rowActions(_ row: AskClaudeRow) -> some View {
        if row.status == .applied {
            HStack(spacing: 4) {
                if EditorModel.sourceRange(row.operation, words: model.words) != nil {
                    Button { model.playAskClaudeRow(row.id) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Play this change")
                        .accessibilityLabel("Play \(row.title)").accessibilityIdentifier("voxclip.askClaude.play.\(row.id)")
                }
                if canAdjust(row) {
                    Button("Adjust") { state.adjusting = state.adjusting == row.id ? nil : row.id }.buttonStyle(.borderless)
                        .accessibilityLabel("Adjust \(row.title)").accessibilityIdentifier("voxclip.askClaude.adjust.\(row.id)")
                }
                Button("Undo") { model.undoAskClaudeRow(row.id) }.buttonStyle(.borderless)
                    .accessibilityLabel("Undo \(row.title)").accessibilityIdentifier("voxclip.askClaude.undo.\(row.id)")
            }
            .font(VCType.small.font())
        }
    }

    private func canAdjust(_ row: AskClaudeRow) -> Bool {
        if case .effect = row.operation.action { return model.askClaudeEffect(row.id) != nil }
        if case .motion = row.operation.action { return true }
        return false
    }

    // MARK: Adjust

    @ViewBuilder private func adjuster(_ row: AskClaudeRow) -> some View {
        if case .motion(let cue) = row.operation.action {
            Button("Edit the zoom in Motion") { model.openMotionCueJob(id: cue.id, in: model.app.shell) }.buttonStyle(.link)
        } else if let effect = model.askClaudeEffect(row.id) {
            VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
                nudgeRow("Start", effect.start) { value in model.adjustAskClaudeEffect(row.id) { $0.start = value } }
                if effect.kind != .sound {
                    nudgeRow("End", effect.end) { value in model.adjustAskClaudeEffect(row.id) { $0.end = value } }
                }
                if effect.kind.usesText, effect.kind != .sticker {
                    AskClaudeTextEditor(text: effect.text ?? "") { text in model.adjustAskClaudeEffect(row.id) { $0.text = text } }
                }
                if effect.kind.usesPosition {
                    Picker("Position", selection: Binding(get: { effect.position ?? .top }, set: { value in model.adjustAskClaudeEffect(row.id) { $0.position = value } })) {
                        ForEach(Self.positions(effect.kind), id: \.self) { Text(Self.positionName($0)).tag($0) }
                    }
                    .frame(height: 24).accessibilityIdentifier("voxclip.askClaude.position")
                }
                if effect.kind == .sticker {
                    Stepper("Size \(Int(((effect.scale ?? 1) * 100).rounded()))%", value: Binding(get: { effect.scale ?? 1 }, set: { value in
                        model.adjustAskClaudeEffect(row.id) { $0.scale = min(ClipEffect.scaleRange.upperBound, max(ClipEffect.scaleRange.lowerBound, value)) }
                    }), in: ClipEffect.scaleRange, step: 0.25)
                }
                if effect.kind.usesRect {
                    rectNudges(row.id)
                    note("Drag the box on the viewer to move it.")
                }
                if effect.kind.isTracked {
                    Picker("Follow", selection: Binding(get: { effect.tracking ?? ClipEffect.Tracking.none }, set: { value in model.retrackAskClaudeEffect(row.id, tracking: value) })) {
                        Text("Hold still").tag(ClipEffect.Tracking.none)
                        Text("A face").tag(ClipEffect.Tracking.face)
                        Text("The moving subject").tag(ClipEffect.Tracking.saliency)
                    }
                    .frame(height: 24).accessibilityIdentifier("voxclip.askClaude.tracking")
                }
                if effect.kind == .sound, let id = effect.sound?.id {
                    Picker("Sound", selection: Binding(get: { id }, set: { value in model.adjustAskClaudeEffect(row.id) { effect in
                        let seconds = AskClaudeValidator.soundSeconds[value] ?? 0.45
                        effect.sound = .init(source: .bundled, id: value, durationSeconds: seconds, title: value.capitalized, license: "cc0")
                        effect.end = effect.start + seconds
                    } })) {
                        ForEach(ClipEffect.bundledSoundIDs, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .frame(height: 24)
                }
            }
            .padding(VCTokens.spacingCardPadding)
            .background(DesignValues.color("bg.window"), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Adjust \(row.title)")
            .accessibilityIdentifier("voxclip.askClaude.adjuster")
        }
    }

    private func nudgeRow(_ title: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: VCTokens.spacingRowGap) {
            Text(title).foregroundStyle(DesignValues.color("text.secondary")).frame(width: 44, alignment: .leading)
            Text(String(format: "%.2f s", value)).font(DesignValues.mono(11)).frame(width: 64, alignment: .leading)
            Button { set(value - 0.1) } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
                .accessibilityLabel("\(title) earlier by a tenth of a second")
            Button { set(value + 0.1) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                .accessibilityLabel("\(title) later by a tenth of a second")
        }
        .frame(height: 24)
    }

    private func rectNudges(_ id: String) -> some View {
        HStack(spacing: VCTokens.spacingLabelGap) {
            Text("Box").foregroundStyle(DesignValues.color("text.secondary")).frame(width: 44, alignment: .leading)
            ForEach([("arrow.left", "left", -0.02, 0.0), ("arrow.right", "right", 0.02, 0.0), ("arrow.up", "up", 0.0, -0.02), ("arrow.down", "down", 0.0, 0.02)], id: \.1) { item in
                Button { model.adjustAskClaudeEffect(id) { effect in
                    guard var rect = effect.rect else { return }
                    rect.x += item.2; rect.y += item.3; effect.rect = rect
                } } label: { Image(systemName: item.0) }.buttonStyle(.borderless).accessibilityLabel("Move the box \(item.1)")
            }
            Button { model.adjustAskClaudeEffect(id) { effect in effect.rect = effect.rect.map { Self.scaled($0, 0.9) } } } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless).accessibilityLabel("Make the box smaller")
            Button { model.adjustAskClaudeEffect(id) { effect in effect.rect = effect.rect.map { Self.scaled($0, 1.1) } } } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless).accessibilityLabel("Make the box bigger")
        }
        .frame(height: 24)
    }

    static func scaled(_ rect: ClipEffect.Rect, _ factor: Double) -> ClipEffect.Rect {
        let width = rect.width * factor, height = rect.height * factor
        return ClipEffect.Rect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height).clamped
    }

    static func positions(_ kind: ClipEffect.Kind) -> [ClipEffect.Position] {
        switch kind {
        case .title: [.top, .center, .bottom]
        case .lowerThird: [.bottomLeft, .bottomRight]
        case .progress: [.top, .bottom]
        default: [.topLeft, .topRight, .center, .bottomLeft, .bottomRight]
        }
    }

    static func positionName(_ position: ClipEffect.Position) -> String {
        switch position {
        case .top: "Top"; case .center: "Centre"; case .bottom: "Bottom"; case .topLeft: "Top left"; case .topRight: "Top right"
        case .bottomLeft: "Bottom left"; case .bottomRight: "Bottom right"
        }
    }

    // MARK: Footer

    /// Every footer names the next step: ↵ to ask, or ask again / Done once the answer is in.
    private var footer: some View {
        HStack(spacing: VCTokens.spacingRowGap) {
            if state.selection != nil, state.asking {
                Text("Claude is working \u{00B7} Stop keeps the project as it is").font(VCType.small.font())
                    .foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
                Spacer(minLength: 0)
                PanelButton(action: PanelAction(id: "askClaude.stop", title: "Stop") { model.stopAskClaude() }, kind: .ghost)
            } else if state.selection != nil {
                Text("\u{21B5} Ask Claude \u{00B7} \(model.askClaudeCostLine)").font(VCType.small.font())
                    .foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
                    .accessibilityIdentifier("voxclip.askClaude.cost")
                Spacer(minLength: 0)
                PanelButton(action: PanelAction(id: "askClaude.cancel", title: "Cancel") { model.closeAskClaude() }, kind: .ghost)
                // Shown once there is something to send: never a button that cannot act.
                if !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PanelButton(action: PanelAction(id: "askClaude.send", title: "Ask Claude") { model.sendAskClaude() }, kind: .primary)
                        .accessibilityIdentifier("voxclip.askClaude.send")
                }
            } else if let run = state.run {
                Text("Play a change to check it, then Done").font(VCType.small.font())
                    .foregroundStyle(DesignValues.color("text.secondary")).lineLimit(1)
                Spacer(minLength: 0)
                PanelButton(action: PanelAction(id: "askClaude.again", title: "Ask again") { model.openAskClaude(run.selection) }, kind: .ghost)
                PanelButton(action: PanelAction(id: "askClaude.done", title: "Done") { model.closeAskClaude() }, kind: .primary)
                    .accessibilityIdentifier("voxclip.askClaude.close")
            }
        }
        .padding(.horizontal, VCTokens.spacingPanePaddingMacos).padding(.vertical, VCTokens.spacingFooterPaddingY)
        .overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary")).fixedSize(horizontal: false, vertical: true)
    }
}

/// The overlay text editor: commits on Return, as one undo step.
@MainActor private struct AskClaudeTextEditor: View {
    @State var text: String
    let commit: (String) -> Void
    var body: some View {
        TextField("Text", text: $text)
            .textFieldStyle(.roundedBorder)
            .onSubmit { let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); if !trimmed.isEmpty { commit(String(trimmed.unicodeScalars.prefix(ClipEffect.maximumTitleScalars))) } }
            .accessibilityLabel("Overlay text")
            .accessibilityIdentifier("voxclip.askClaude.text")
    }
}

/// While a blur, pixelate, arrow or circle is being adjusted, its box draws on the viewer and drags to move (one undo step
/// on release). The box maps through the same crop as the export.
@MainActor struct AskClaudeRectOverlay: View {
    let model: EditorModel
    let stage: CGSize
    @State private var offset: CGSize = .zero

    var body: some View {
        if let (id, effect) = model.askClaudeAdjustingRect, let rect = effect.rect(at: model.sourceTime) ?? effect.rect,
           let frame = Self.frame(rect, project: model.project, stage: stage) {
            Rectangle()
                .strokeBorder(DesignValues.color("accent.text"), style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                .background(Color.white.opacity(0.001))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX + offset.width, y: frame.midY + offset.height)
                .gesture(DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { value in
                        offset = .zero
                        let scale = Self.pictureScale(project: model.project, stage: stage)
                        model.adjustAskClaudeEffect(id, name: "Move \(EditorModel.rowTitle(ClipAutopilotOperation(id: id, decision: .blur, action: .effect(effect), reason: "")))") { effect in
                            guard var moved = effect.rect else { return }
                            moved.x += value.translation.width / scale.width
                            moved.y += value.translation.height / scale.height
                            effect.rect = moved.clamped
                        }
                    })
                .accessibilityLabel("Effect box; drag to move it")
                .accessibilityIdentifier("voxclip.askClaude.viewerBox")
        }
    }

    /// Stage points per unit of picture space: the export crop of the oriented source, scaled to the stage.
    static func pictureScale(project: Project, stage: CGSize) -> CGSize {
        let source = project.media.source.video.map(OutputSizing.orientedSize) ?? PixelSize(width: 1920, height: 1080)
        let ratio = ViewerSection.ratio(project)
        let sourceWidth = Double(source.width), sourceHeight = Double(source.height)
        let cropWidth = sourceWidth / sourceHeight > ratio ? sourceHeight * ratio : sourceWidth
        let cropHeight = sourceWidth / sourceHeight > ratio ? sourceHeight : sourceWidth / ratio
        return CGSize(width: stage.width * sourceWidth / cropWidth, height: stage.height * sourceHeight / cropHeight)
    }

    /// The rect on the stage, top-left origin; nil when it falls outside the shown crop.
    static func frame(_ rect: ClipEffect.Rect, project: Project, stage: CGSize) -> CGRect? {
        guard stage.width > 0, stage.height > 0 else { return nil }
        let scale = pictureScale(project: project, stage: stage)
        // The crop is centred, so picture 0.5 sits at the stage's centre.
        let x = stage.width / 2 + (rect.x - 0.5) * scale.width, y = stage.height / 2 + (rect.y - 0.5) * scale.height
        let frame = CGRect(x: x, y: y, width: rect.width * scale.width, height: rect.height * scale.height)
        return frame.intersects(CGRect(origin: .zero, size: stage)) ? frame : nil
    }
}
