import SwiftUI
import VoxClipCore
import VoxClipMedia
import CryptoKit

@MainActor struct InspectorView: View {
    @Bindable var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Captions").font(.headline); Spacer(); Button("Close", systemImage: "xmark") { model.showInspector = false }.labelStyle(.iconOnly) }
                .padding(16)
            Divider()
            CaptionsInspector(model: model)
        }.controlSize(.small).foregroundStyle(DesignValues.color("text.primary"))
    }
}

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
                        Button("Reset to style") { mutate { CaptionFineTuning.reset(&$0) } }.buttonStyle(.link)
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
                    if model.project.captions.styleId == id { Image(systemName: "checkmark.circle.fill").padding(6).foregroundStyle(DesignValues.color("accent.default")) }
                }.overlay(RoundedRectangle(cornerRadius: 12).stroke(model.project.captions.styleId == id ? DesignValues.color("accent.default") : Color.clear, lineWidth: 2))
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

@MainActor struct ClipsInspector: View {
    @Bindable var model: EditorModel
    @State private var renaming: String?
    @State private var title = ""
    @State private var connectorStatus: ConnectorStatus?
    @State private var finderExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clips").font(.title2.weight(.semibold))
                            Text(model.words.isEmpty ? "Transcribe this video to select words and find clips." : model.sortedClips.isEmpty ? "Select words in Transcript to make a clip, or find moments with AI." : "\(model.sortedClips.count) clip\(model.sortedClips.count == 1 ? "" : "s") in this project")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.words.isEmpty {
                            Button("Transcribe…") { model.showTranscribe = true }
                        } else if model.selectedIDs.isEmpty || selectionAlreadyClipped {
                            Button("Select Words in Transcript") { model.location = .transcript }
                        } else {
                            Button("Make Clip from Selection") { model.makeClip() }
                        }
                    }
                    Divider()
                    if model.sortedClips.isEmpty {
                        Text("No clips yet. Results will appear here for preview and export.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.sortedClips, id: \.id) { clip in clipRow(clip) }
                    }
                    Divider()
                    HStack {
                        Text("Find Clips").font(.headline)
                        Spacer()
                        if !model.sortedClips.isEmpty {
                            Button(finderExpanded ? "Hide Setup" : "Find Clips…") { finderExpanded.toggle() }
                        }
                    }
                    if model.sortedClips.isEmpty || finderExpanded || model.finding || model.clipError != nil {
                        ConnectorPicker(app: model.app)
                        let connector = model.app.providers.first { $0.id == model.app.string("llm.connector") }
                        if let connector { Text(connector.group == "local" ? "Runs on this Mac. Nothing leaves it." : "Sends transcript text with word numbers. No audio or video.").font(.caption).foregroundStyle(.secondary) }
                        if let connector {
                            Label(statusMessage(connectorStatus, connector: connector), systemImage: connectorStatus == .ready ? "checkmark.circle" : "info.circle")
                                .font(.caption).foregroundStyle(connectorStatus == .ready ? DesignValues.color("status.success") : .secondary)
                                .accessibilityIdentifier("clipConnectorStatus")
                            if connectorStatus != .ready {
                                HStack {
                                    Button("Check Again") { model.app.refreshConnectorReadiness() }
                                        .accessibilityIdentifier("checkConnectorAgain")
                                    SettingsLink { Text("Configure \(connector.label)…") }
                                }
                            }
                        }
                        Picker("Clip preset", selection: $model.preset) {
                            Text("Best moments").tag(ClipPresetID.best); Text("Hooks").tag(ClipPresetID.hooks); Text("One per topic").tag(ClipPresetID.topics); Text("Quotes").tag(ClipPresetID.quotes); Text("Custom").tag(ClipPresetID.custom)
                        }
                        TextField(model.preset == .custom ? "Describe the clips you want" : "Anything specific? (optional)", text: $model.instruction, axis: .vertical).lineLimit(2...4).onSubmit { model.findClips() }.onChange(of: model.instruction) { _, value in if value.count > 500 { model.instruction = String(value.prefix(500)) } }
                        if model.finding { HStack { ProgressView().controlSize(.small); Text("Finding clips…"); Button("Cancel") { model.findTask?.cancel() } } }
                        else { HStack { Spacer(); Button("Find Clips") { model.findClips() }.buttonStyle(.borderedProminent).accessibilityIdentifier("findClipsAction").disabled(model.words.isEmpty || connector == nil || model.preset == .custom && model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
                        if connector == nil {
                            Text("Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.").font(.callout).foregroundStyle(.secondary)
                            SettingsLink { Text("Open AI settings") }
                        } else if connector?.group == "apiKey", let connector { ProviderKeyRow(provider: connector.id, label: connector.label, app: model.app) }
                        if let error = model.clipError { InlineNotice(text: error); Button("Retry") { model.findClips() } }
                        if let answer = model.clipAnswer { Text(answer).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Use AI to suggest moments. Manual clips remain available without a connector.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }
            Divider()
            HStack {
                if model.activeClip != nil { Button("Preview Full Video") { model.activate(nil) }.buttonStyle(.plain) }
                Spacer()
                let selected = model.sortedClips.filter(\.selected)
                Button(selected.isEmpty ? "Choose clips to export" : "Export \(selected.count) \(selected.count == 1 ? "clip" : "clips")") { model.presentExport(clipIDs: selected.map(\.id)) }.disabled(selected.isEmpty || !model.canExport)
            }.padding(12)
        }
        .alert("Rename clip", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { if let id = renaming { model.apply(.renameClip(id: id, title: EditorModel.clipTitle(title)), name: "Rename clip") }; renaming = nil }
        }
        .task(id: "\(model.app.string("llm.connector")):\(model.app.connectorReadinessRevision)") {
            connectorStatus = nil
            let id = model.app.string("llm.connector")
            let revision = model.app.connectorReadinessRevision
            guard !id.isEmpty else { return }
            if AppModel.isTestSession && model.app.connectorOverride == nil { return }
            let status = await model.app.connector(id).status()
            guard !Task.isCancelled, revision == model.app.connectorReadinessRevision, id == model.app.string("llm.connector") else { return }
            connectorStatus = status
        }
        .onChange(of: model.sortedClips.count) { _, count in if count > 0 { finderExpanded = false } }
    }
    private var selectionAlreadyClipped: Bool {
        guard let start = model.selectedIDs.first, let end = model.selectedIDs.last else { return false }
        return model.sortedClips.contains { $0.startWordId == start && $0.endWordId == end }
    }
    private func clipRow(_ clip: ClipRange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(get: { model.project.edits.clips.first { $0.id == clip.id }?.selected ?? false }, set: { model.apply(.setClipSelected(id: clip.id, selected: $0), name: "Choose clip") })) { Text(clip.title ?? "Untitled clip").fontWeight(.semibold) }
                Spacer()
                if let lower = model.index(clip.startWordId), let upper = model.index(clip.endWordId), let times = try? clipTimes(model.words, startIndex: lower, endIndex: upper) { Text(durationLabel(times.end - times.start) + (suggestion(clip).map { " · \($0.score)/10" } ?? "")).font(DesignValues.mono(10)) }
            }
            if let suggestion = suggestion(clip) { Text(suggestion.reason).font(.caption2).foregroundStyle(DesignValues.color("text.muted")) }
            if let lower = model.index(clip.startWordId), let upper = model.index(clip.endWordId), lower <= upper { Text(model.words[lower...upper].map { model.text($0) }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(model.activeClip?.id == clip.id ? nil : 2) }
            HStack(spacing: 5) {
                Button(model.activeClip?.id == clip.id ? "Stop preview" : "Preview") { model.activate(model.activeClip?.id == clip.id ? nil : clip) }
                Text("start").foregroundStyle(.secondary)
                Button("Earlier start", systemImage: "chevron.left") { model.nudge(clip, start: true, offset: -1) }.labelStyle(.iconOnly)
                Button("Later start", systemImage: "chevron.right") { model.nudge(clip, start: true, offset: 1) }.labelStyle(.iconOnly)
                Text("end").foregroundStyle(.secondary)
                Button("Earlier end", systemImage: "chevron.left") { model.nudge(clip, start: false, offset: -1) }.labelStyle(.iconOnly)
                Button("Later end", systemImage: "chevron.right") { model.nudge(clip, start: false, offset: 1) }.labelStyle(.iconOnly)
                Menu { clipActions(clip) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).accessibilityLabel("More actions")
            }.font(.caption).buttonStyle(.borderless)
            Divider()
        }
        .contextMenu { clipActions(clip) }
        .focusable()
        .onKeyPress(.return) { model.activate(clip); return .handled }
        .onKeyPress(.escape) { model.activate(nil); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "[]io")) { model.transport($0.characters); return .handled }
    }
    private func statusMessage(_ status: ConnectorStatus?, connector: ProviderChoice) -> String {
        switch status {
        case .ready: "Ready to find clips."
        case .needsKey: "Add your \(connector.label) key in AI Settings."
        case .noModels: "Load a model in \(connector.label), then try again."
        case .cliMissing: "Install \(connector.label) or choose its executable in AI Settings."
        case .cliSignedOut: "Sign in to \(connector.label) before finding clips."
        case .notRunning(let url): "Start \(connector.label) at \(url)."
        case .cliTooOld: "Update \(connector.label) before finding clips."
        case .unavailable(let reason): reason.isEmpty ? "Connector unavailable. Check AI Settings." : reason
        case nil: "Check connector readiness in AI Settings."
        }
    }
    @ViewBuilder private func clipActions(_ clip: ClipRange) -> some View {
        Button("Export this clip") { model.presentExport(clipIDs: [clip.id]) }
        Button("Copy text") { if let lower = model.index(clip.startWordId), let upper = model.index(clip.endWordId), lower <= upper { copyText(model.words[lower...upper].map { model.text($0) }.joined(separator: " ")) } }
        Button("Rename…") { renaming = clip.id; title = clip.title ?? "" }
        Button("Remove") { model.removeClip(clip.id) }
    }
    private func suggestion(_ clip: ClipRange) -> ProjectAIClip? {
        guard let result = model.project.ai.results.first(where: { $0.id == clip.aiResultId }), let position = clip.aiClipIndex, result.clips.indices.contains(position) else { return nil }
        return result.clips[position]
    }
}

extension EditorModel {
    func findClips() {
        guard let shared = app.shared, let transcript = project.transcript, let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) else { return }
        let corrections = project.edits.corrections
        let cuts = Set(project.edits.cutWordIds)
        let selectedModel = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        let selectedPreset = preset
        let instructions = instruction
        let run = {
            self.findTask?.cancel(); self.finding = true; self.clipError = nil; self.clipAnswer = nil
            self.findTask = Task { [self] in
                defer { self.finding = false }
                do {
                    let catalog = LLMCatalog(document: try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))))
                    let finder = ClipFinder(runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log), shared: shared)
                    let presets = try await finder.presets()
                    guard let preset = presets.first(where: { $0.id == selectedPreset }) else { throw ClipFinderGateError.needInstructions(message: "Choose a clip preset.") }
                    let result = try await finder.find(ClipFinderRequest(transcript: transcript, corrections: corrections, cutWordIds: cuts, preset: preset, instruction: instructions, snap: app.bool("llm.clips.snapToLines", fallback: true)), connector: app.connector(provider.id), model: selectedModel)
                    try Task.checkCancellation()
                    guard project.transcript == transcript else { return }
                    guard !result.clips.isEmpty else { clipError = "No clips matched. Try another style or describe what you want."; return }
                    var next = project
                    next.ai.results.append(result)
                    let ranges = result.clips.enumerated().map { position, clip in ClipRange(id: UUID().uuidString.lowercased(), startWordId: clip.startWordId, endWordId: clip.endWordId, title: clip.title, origin: .ai, aiResultId: result.id, aiClipIndex: position) }
                    apply(.addAIClips(resultId: result.id, clips: ranges), name: "Find clips", base: next)
                    let fallback = await finder.lastUsedFallback == true && result.model != selectedModel
                    clipAnswer = fallback ? "Answered by \(result.model) because \(selectedModel) was busy." : "Answered by \(result.model)"
                } catch is CancellationError {} catch LLMError.cancelled {} catch VoxClipError.cancelled {} catch {
                    let message = await app.safeError(error, context: "ai:\(provider.label)")
                    if !message.isEmpty { clipError = message }
                }
            }
        }
        if provider.privacy == "thirdPartyCloud" && !app.bool("llm.cloudConsent.\(provider.id)") {
            let alert = NSAlert(); alert.messageText = "Find clips"
            if let copy = provider.cliConsentCopy { alert.informativeText = copy }
            else { alert.informativeText = "Find clips sends this project's transcript (\(words.count) words, no audio or video) to \(provider.label) using your API key." }
            alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            app.set("llm.cloudConsent.\(provider.id)", .bool(true))
        }
        run()
    }
}
