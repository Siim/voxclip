import SwiftUI
import VoxClipCore

/// Find Clips (design §6.2): the connector and its readiness, a preset, optional
/// instructions and the privacy footnote. Running it closes the popover; progress,
/// results and failures show in the sidebar.
@MainActor struct FindClipsPopover: View {
    @Bindable var model: EditorModel
    @State private var status: ConnectorStatus?

    private var canRun: Bool {
        !model.words.isEmpty && model.findConnector != nil && !model.finding
            && !(model.preset == .custom && model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        let connector = model.findConnector
        VStack(alignment: .leading, spacing: 12) {
            Text("Find clips in this take").font(.headline)
            if let connector {
                HStack(spacing: 6) {
                    Text("Connector").foregroundStyle(DesignValues.color("text.secondary"))
                    Text("\(connector.label) ·")
                    Text("●").foregroundStyle(DesignValues.color(status == .ready ? "status.success" : "status.warning")).accessibilityHidden(true)
                    Text(Self.statusText(status))
                    Spacer(minLength: 8)
                    Button("Change…") { model.showFindClips = false; openVoxClipSettings(pane: "ai") }.buttonStyle(.borderless).foregroundStyle(DesignValues.accentText)
                    if status != nil && status != .ready {
                        Button("Retry") { Task { status = await model.app.connectorStatus(connector) } }
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("clipConnectorStatus")
            } else {
                HStack {
                    Text("Choose a connector in AI settings.")
                    Spacer()
                    Button("Choose…") { model.showFindClips = false; openVoxClipSettings(pane: "ai") }
                }.font(.callout)
            }
            Picker("Preset", selection: $model.preset) {
                Text("Best moments").tag(ClipPresetID.best); Text("Hooks").tag(ClipPresetID.hooks); Text("One per topic").tag(ClipPresetID.topics)
                Text("Quotes").tag(ClipPresetID.quotes); Text("Custom").tag(ClipPresetID.custom)
            }
            TextField(model.preset == .custom ? "Describe the clips you want" : "Anything specific? (optional)", text: $model.instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
                .onSubmit(run)
                .onChange(of: model.instruction) { _, value in if value.count > 500 { model.instruction = String(value.prefix(500)) } }
            Text(Self.footnote(connector, serverHost: connector.flatMap { model.app.localServerHost($0) }))
                .font(.caption).foregroundStyle(DesignValues.color("text.secondary"))
            HStack {
                Spacer()
                Button("Find Clips", action: run).keyboardShortcut(.defaultAction).disabled(!canRun).accessibilityIdentifier("findClipsAction")
            }
        }
        .padding(16)
        .frame(width: 340)
        .task(id: "\(model.app.string("llm.connector")):\(model.app.connectorReadinessRevision)") {
            status = nil
            let id = model.app.string("llm.connector"), revision = model.app.connectorReadinessRevision
            guard let provider = model.findConnector else { return }
            let found = await model.app.connectorStatus(provider)
            guard !Task.isCancelled, revision == model.app.connectorReadinessRevision, id == model.app.string("llm.connector") else { return }
            status = found
        }
    }

    private func run() {
        guard canRun else { return }
        model.showFindClips = false
        model.findClips()
    }

    /// The connector line's status (design §6.2).
    static func statusText(_ status: ConnectorStatus?) -> String {
        switch status {
        case .ready: "Ready"
        case .needsKey: "Key missing"
        case .notRunning: "Not running"
        case .cliMissing: "Not found"
        case .cliSignedOut: "Not signed in"
        case .cliTooOld: "Too old"
        case .noModels: "No model loaded"
        case .unavailable: "Unavailable"
        case nil: "Checking…"
        }
    }

    static func footnote(_ connector: ProviderChoice?, serverHost: String?) -> String {
        if let serverHost { return "Sends transcript text with word numbers to \(serverHost). No audio or video." }
        return connector?.group == "local" ? "Runs on this Mac. Nothing leaves it." : "Sends transcript text with word numbers. No audio or video."
    }
}
