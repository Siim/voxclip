import SwiftUI
import VoxClipCore

@MainActor public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    public init() {}
    public var body: some View {
        TabView(selection: Binding(get: { app.settingsPane }, set: { app.settingsPane = $0 })) {
            GeneralSettings(app: app).tabItem { Label("General", systemImage: "gear") }.tag("general")
            TranscriptionSettings(app: app).tabItem { Label("Transcription", systemImage: "waveform") }.tag("transcription")
            ProviderSettings(app: app).tabItem { Label("AI", systemImage: "key") }.tag("ai")
            ExportSettings(app: app).tabItem { Label("Export", systemImage: "square.and.arrow.up") }.tag("export")
            AboutSettings(app: app).tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(minWidth: 600, minHeight: 480)
        .preferredColorScheme(app.appearance)
    }
}

extension AppModel {
    func stringBinding(_ key: String, fallback: String = "") -> Binding<String> { Binding(get: { self.string(key, fallback: fallback) }, set: { self.set(key, .string($0)) }) }
    func boolBinding(_ key: String, fallback: Bool = false) -> Binding<Bool> { Binding(get: { self.bool(key, fallback: fallback) }, set: { self.set(key, .bool($0)) }) }
    func numberBinding(_ key: String, fallback: Double) -> Binding<Double> { Binding(get: { self.number(key, fallback: fallback) }, set: { self.set(key, .number($0)) }) }
}

@MainActor struct GeneralSettings: View {
    @Bindable var app: AppModel
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: app.stringBinding("general.appearance", fallback: "system")) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                LabeledContent("Transcript text size") { Slider(value: app.numberBinding("general.transcriptTextSize", fallback: DesignValues.transcriptTextSize), in: DesignValues.transcriptZoom, step: 1); Text("\(Int(app.number("general.transcriptTextSize", fallback: DesignValues.transcriptTextSize)))").monospacedDigit() }
                Picker("Pause breath", selection: app.stringBinding("editing.pauseBreath", fallback: "natural")) { Text("Tight · 0.05 s").tag("tight"); Text("Natural · 0.15 s").tag("natural"); Text("Relaxed · 0.30 s").tag("relaxed") }
                Toggle("Show low-confidence words", isOn: app.boolBinding("general.showLowConfidence"))
                Toggle(isOn: app.boolBinding("general.showPlaceholderWords", fallback: true)) {
                    Text("Show transcript words on placeholders")
                    Text("When off, placeholders show the project title instead of its first words.")
                }
                Picker("Default caption style", selection: app.stringBinding("captions.defaultStyleId", fallback: "vox-highlight")) { Text("Off").tag("off"); ForEach(app.styles, id: \.id) { Text($0.name).tag($0.id) } }
            }
            Section {
                Toggle("Check for updates automatically", isOn: app.boolBinding("update.autoCheck", fallback: true))
                Picker("Cache size limit", selection: app.numberBinding("cache.limitGB", fallback: 5)) { ForEach([2.0, 5, 10, 20], id: \.self) { Text("\(Int($0)) GB").tag($0) } }
                Button("Clear cache") {
                    Task {
                        do { try await CacheStore(locations: app.locations).evict(limitBytes: 0, protectedKeys: Set(app.openProjectKeys.values), keepingEnvelopes: true); app.notice = "Unused cache cleared. Your video, models and edits are still here." }
                        catch { app.notice = await app.safeError(error) }
                    }
                }
            } footer: { Text("No telemetry. No account required. Settings never contain keys.") }
            if let notice = app.notice { Section { Text(notice).font(.caption).foregroundStyle(.secondary) } }
        }.formStyle(.grouped)
    }
}

@MainActor struct TranscriptionSettings: View {
    @Bindable var app: AppModel
    var body: some View {
        Form {
            Section {
                EnginePicker(app: app)
                LanguagePicker(app: app)
                ProviderKeyRow(provider: "elevenlabs", label: "ElevenLabs Scribe", app: app)
            } footer: { Text("Sends the audio track to ElevenLabs, which keeps it under its terms. You confirm before the first upload.") }
            Section("Advanced") {
                Picker("Region", selection: app.stringBinding("transcription.elevenlabs.region", fallback: "default")) { Text("Default").tag("default"); Text("EU residency").tag("eu"); Text("US").tag("us"); Text("India").tag("in"); Text("Singapore").tag("sg") }
            }
            LocalModelRows(app: app)
            Section {
                Text("Models download on first use and never ship inside the app. Each runs entirely on this Mac.")
                Text(app.locations.models.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.caption).textSelection(.enabled)
                Button("Reveal in Finder") { NSWorkspace.shared.open(app.locations.models) }
            }
        }.formStyle(.grouped)
    }
}

@MainActor struct EnginePicker: View {
    @Bindable var app: AppModel
    var body: some View {
        Picker("Engine", selection: app.stringBinding("transcription.engineMode", fallback: "local")) {
            Text("On this Mac").tag("local"); Text("ElevenLabs Scribe").tag("elevenlabs"); Text("Apple on-device").tag("apple"); Text("Ask each time").tag("ask")
        }
    }
}

@MainActor struct LanguagePicker: View {
    @Bindable var app: AppModel
    var body: some View {
        Picker("Language", selection: app.stringBinding("transcription.language", fallback: "auto")) {
            Text("Auto").tag("auto")
            ForEach(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).sorted { (Locale.current.localizedString(forLanguageCode: $0) ?? $0) < (Locale.current.localizedString(forLanguageCode: $1) ?? $1) }, id: \.self) { code in
                Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
            }
        }
    }
}

@MainActor struct ConnectorPicker: View {
    @Bindable var app: AppModel
    var body: some View {
        Picker("AI", selection: app.stringBinding("llm.connector")) {
            Text("Choose a connector").tag("")
            ForEach(["apiKey", "local", "cli"], id: \.self) { group in
                Section(group == "apiKey" ? "Your API key" : group == "local" ? "On this computer" : "Installed CLI (your own sign-in)") {
                    ForEach(app.providers.filter { $0.group == group }) { Text($0.label).tag($0.id) }
                }
            }
        }
    }
}

@MainActor struct ProviderSettings: View {
    @Bindable var app: AppModel
    @State private var refreshed: [LLMModel] = []
    @State private var refreshing = false
    @State private var result: String?
    var body: some View {
        Form {
            Section("Providers & Keys") {
                ConnectorPicker(app: app)
                if let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) {
                    ProviderModelPicker(provider: provider, refreshed: refreshed, app: app).id(provider.id)
                    Button(refreshing ? "Refreshing…" : "Refresh models") {
                        refreshing = true
                        Task { defer { refreshing = false }; do { refreshed = try await app.connector(provider.id).models(refresh: true) } catch { result = await app.safeError(error) } }
                    }.disabled(refreshing)
                    if provider.group == "local" {
                        if provider.id != "apple-foundation" { SettingTextField("Server URL", key: "llm.baseUrl.\(provider.id)", fallback: provider.baseUrl ?? "", app: app) }
                        Text(app.providerStatus[provider.id] ?? "Status unavailable in this build").font(.caption).foregroundStyle(.secondary)
                        Button("Test") { Task { result = await testProvider(provider, app: app) } }
                        Text(localPrivacy(provider)).font(.caption).foregroundStyle(.secondary)
                    } else if provider.group == "cli" { CLIConnectorRow(provider: provider, app: app) }
                    else { ProviderKeyRow(provider: provider.id, label: provider.label, app: app) }
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                }
                Toggle("Snap clip edges to sentence boundaries", isOn: app.boolBinding("llm.clips.snapToLines", fallback: true))
            }
            Section("Your API keys") {
                ForEach(app.providers.filter { $0.group == "apiKey" }) { provider in ProviderKeyRow(provider: provider.id, label: provider.label, app: app) }
            }
            Section("Installed CLI (your own sign-in)") {
                ForEach(app.providers.filter { $0.group == "cli" }) { CLIConnectorRow(provider: $0, app: app) }
            }
        }.formStyle(.grouped)
    }
    private func localPrivacy(_ provider: ProviderChoice) -> String {
        let base = app.string("llm.baseUrl.\(provider.id)", fallback: provider.baseUrl ?? "")
        if let url = URL(string: base), let host = url.host, !["localhost", "127.0.0.1", "::1"].contains(host) { return "Transcripts are sent to \(host)." }
        return "Runs on this Mac. Nothing leaves it."
    }
}

@MainActor struct ProviderModelPicker: View {
    let provider: ProviderChoice
    let refreshed: [LLMModel]
    let app: AppModel
    @State private var custom = false
    private var models: [ProviderChoice.Model] { provider.models + refreshed.filter { candidate in !provider.models.contains { $0.id == candidate.id } }.map { ProviderChoice.Model(id: $0.id, name: $0.name, tier: $0.tier) } }
    private var modelID: String { app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "") }
    private var isCustom: Bool { custom || (!modelID.isEmpty && !models.contains { $0.id == modelID }) }
    var body: some View {
        Picker("Model", selection: Binding(get: { isCustom ? "__custom" : modelID }, set: { choice in
            custom = choice == "__custom"
            if !custom { app.set("llm.model.\(provider.id)", .string(choice)) }
        })) {
            ForEach(models) { model in Text(model.name + (model.tier.map { " (\($0))" } ?? "")).tag(model.id) }
            Text("Custom…").tag("__custom")
        }
        if isCustom { SettingTextField("Custom model ID", key: "llm.model.\(provider.id)", fallback: provider.defaultModel ?? "", app: app) }
    }
}

@MainActor struct ProviderKeyRow: View {
    let provider: String
    let label: String
    let app: AppModel
    @State private var value = ""
    @State private var saved = false
    @State private var testing = false
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).fontWeight(.medium)
            HStack {
                SecureField(saved ? "Saved in the Keychain; paste to replace" : "API key", text: $value).textContentType(.password).accessibilityLabel("\(label) API key")
                Button("Save key") {
                    Task { do { try await app.saveProviderKey(value, for: provider); value = ""; saved = true; result = "Saved in the Keychain." } catch { result = await app.safeError(error) } }
                }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(testing ? "Testing…" : "Test") {
                    testing = true
                    Task {
                        defer { testing = false }
                        if !value.isEmpty {
                            do { try await app.saveProviderKey(value, for: provider); value = ""; saved = true } catch { result = await app.safeError(error); return }
                        }
                        if provider == "elevenlabs" { result = await testSpeechKey(app: app) }
                        else if let choice = app.providers.first(where: { $0.id == provider }) { result = await testProvider(choice, app: app) }
                    }
                }.disabled(testing || !saved && value.isEmpty)
                if saved { Button("Forget key") { Task { do { try await app.saveProviderKey("", for: provider); saved = false; result = nil } catch { result = await app.safeError(error) } } } }
            }
            Text(provider == "elevenlabs" ? "The key stays in the macOS Keychain and is used only for transcription." : "The key stays in the macOS Keychain and is used only for AI features.").font(.caption).foregroundStyle(.secondary)
            Text(provider == "elevenlabs" ? "Sends the audio track to ElevenLabs." : "Sends transcript text only. No audio or video.").font(.caption).foregroundStyle(.secondary)
            if let result { Text(result).font(.caption).foregroundStyle(result.hasPrefix("Works") ? DesignValues.color("status.success") : DesignValues.color("status.warning")) }
        }
        .task(id: "\(provider):\(app.connectorReadinessRevision)") { saved = await app.providerKeyStore.hasKey(for: provider) }
    }
}

@MainActor struct CLIConnectorRow: View {
    let provider: ProviderChoice
    let app: AppModel
    @State private var status = "Detection not run"
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provider.label).fontWeight(.medium)
            Text(status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Detect") { Task { await detect() } }
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { app.set("llm.cliPath.\(provider.id)", .string(url.path)); Task { await detect() } }
                }
                Button("Test") { Task { await detect(); result = await testProvider(provider, app: app) } }
                Button("Sign-in help") { result = provider.cli?.signInHint }
            }
            Text("VoxClip runs your installed \(provider.id == "claude-code" ? "Claude Code" : "Codex") with your own sign-in. Sends transcript text only. No audio or video.").font(.caption).foregroundStyle(.secondary)
            if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
        }.task { await detect() }
    }
    private func detect() async {
        guard let shared = app.shared, let cli = provider.cli else { return }
        do {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))) as? [String: Any]
            let connectors = root?["connectors"] as? [[String: Any]]
            let record = connectors?.first { $0["id"] as? String == provider.id }
            let paths = ((record?["cli"] as? [String: Any])?["searchPaths"] as? [String: [String]])?["macos"] ?? []
            let chosen = app.string("llm.cliPath.\(provider.id)")
            let candidates = chosen.isEmpty ? paths : [chosen]
            guard let path = candidates.map({ NSString(string: $0).expandingTildeInPath }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { status = "Not found"; return }
            status = "Found \(cli.executable) at \(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) · Sign-in status unavailable"
            let connectorStatus = await app.connectorStatus(provider)
            if connectorStatus == .ready { status += " · Ready" }
        } catch { status = await app.safeError(error) }
    }
}

@MainActor func testProvider(_ provider: ProviderChoice, app: AppModel) async -> String {
    guard let shared = app.shared else { return "Failed: VoxClip is missing some of its files. Reinstall VoxClip." }
    do {
        let data = try Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))
        let catalog = LLMCatalog(document: try JSONDecoder().decode(JSONValue.self, from: data))
        struct Test: Decodable { let system: String; let instruction: String; let schemaName: String; let schema: JSONValue; let maxOutputTokens: Int }
        struct Catalogue: Decodable { let testRequest: Test }
        let test = try JSONDecoder().decode(Catalogue.self, from: data).testRequest
        let start = ContinuousClock.now
        let answer = try await LLMRunner(keys: app.secrets, catalog: catalog, log: app.log).run(LLMRequest(feature: .test, system: test.system, instruction: test.instruction, schemaName: test.schemaName, schema: test.schema, maxOutputTokens: test.maxOutputTokens, effort: .low, timeout: .seconds(provider.group == "cli" ? 120 : 30), tag: "connection-test"), on: app.connector(provider.id), model: app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? ""))
        guard case .object(let object) = answer.object, object["ok"] == .bool(true), case .string(let echo) = object["echo"], echo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "voxclip" else { return "The model answered, but not as expected. It may not follow instructions well." }
        if answer.usedFallback { return "Works · answered by \(answer.model)" }
        let seconds = Double(start.duration(to: .now).components.attoseconds) / 1e18 + Double(start.duration(to: .now).components.seconds)
        return "Works · \(answer.model) · \(String(format: "%.1f", seconds)) s"
    } catch { return "Failed: " + (await app.safeError(error, context: "ai-test:\(provider.label)")) }
}

@MainActor func testSpeechKey(app: AppModel) async -> String {
    do {
        guard let key = try await app.secrets.key(for: "elevenlabs") else { return "Add your ElevenLabs key in Settings to use it." }
        let hosts = ["default": "api.elevenlabs.io", "us": "api.us.elevenlabs.io", "eu": "api.eu.residency.elevenlabs.io", "in": "api.in.residency.elevenlabs.io", "sg": "api.sg.residency.elevenlabs.io"]
        let host = hosts[app.string("transcription.elevenlabs.region", fallback: "default")] ?? "api.elevenlabs.io"
        var request = URLRequest(url: URL(string: "https://\(host)/v1/user/subscription")!, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await KeyedNetwork.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return "Works." }
        if [401, 403].contains(status), String(decoding: data.prefix(10_000), as: UTF8.self).contains("user_read") { return "The key works. It can't read account details (user_read), and that is fine for transcription." }
        return "ElevenLabs rejected the key (\(status)). Your video is still here."
    } catch { return "Failed: " + (await app.safeError(error)) }
}

@MainActor struct ExportSettings: View {
    @Bindable var app: AppModel
    var body: some View {
        Form {
            Section("Defaults for new projects") {
                Picker("Aspect", selection: app.stringBinding("export.defaultAspect", fallback: "source")) { ForEach(AspectRatio.allCases, id: \.self) { Text($0 == .source ? "Source" : $0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented)
                Picker("Quality", selection: app.stringBinding("export.quality", fallback: "standard")) { Text("Standard").tag("standard"); Text("High").tag("high") }.pickerStyle(.segmented)
                Toggle("Also save .srt", isOn: app.boolBinding("export.srt"))
                SettingTextField("File name pattern", key: "export.fileNamePattern", fallback: "{project}-{clip}-{aspect}", app: app)
                SettingTextField("Default folder", key: "export.folder", fallback: app.locations.defaultExport.path, app: app)
                Button("Choose folder…") { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; if panel.runModal() == .OK, let url = panel.url { app.set("export.folder", .string(url.path)) } }
                Toggle("Open folder after export", isOn: app.boolBinding("export.openFolderAfter", fallback: false))
            }
        }.formStyle(.grouped)
    }
}

@MainActor struct AboutSettings: View {
    @Bindable var app: AppModel
    @State private var showLicences = false
    @State private var showPrivacy = false
    var body: some View {
        Form {
            Section {
                Text("VoxClip").font(.title.bold())
                Text("\(AppModel.version) (\(AppModel.build)) · MIT License")
                Text("A fast way to cut, because we already know where every word sits.").foregroundStyle(.secondary)
                Button("Check for updates") { Task { await app.checkUpdates(manual: true) } }
                if let notice = app.notice { Text(notice).font(.caption) }
                Link(destination: URL(string: "https://github.com/Siim/voxclip")!) { Text("GitHub").underline() }.buttonStyle(.plain).foregroundStyle(DesignValues.accentText)
                Button("Licences…") { showLicences = true }
                Button("What leaves this device") { showPrivacy = true }
                Button("Reset onboarding") { app.showTour = true; app.set("onboarding.completed", .bool(false)) }
                Button("Reveal logs") { app.revealLogs() }
            }
            Section { Text("VoxClip can run Claude Code or Codex if you have installed them and signed in. Their use is governed by your own agreements with Anthropic and OpenAI.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
            .sheet(isPresented: $showLicences) { LicencesView(app: app) }
            .sheet(isPresented: $showPrivacy) { TextSheet(title: "What leaves this device", text: privacyCopy) }
    }
}

@MainActor struct LicencesView: View {
    let app: AppModel
    @State private var text = "Licences could not be loaded. Reinstall VoxClip."
    var body: some View {
        TextSheet(title: "Licences", text: text).task {
            let candidates = [Bundle.main.resourceURL?.appendingPathComponent("THIRD_PARTY_NOTICES.md"), app.shared?.root.deletingLastPathComponent().appendingPathComponent("THIRD_PARTY_NOTICES.md")]
            for case let url? in candidates { if let content = try? String(contentsOf: url, encoding: .utf8) { text = content; break } }
            await app.modelLibrary.load()
            struct Catalogue: Decodable {
                struct Model: Decodable {
                    let id: String
                    let displayName: String
                    let license: String
                    let attribution: String
                    let citation: String?
                }
                let models: [Model]
            }
            if let shared = app.shared,
               let data = try? Data(contentsOf: shared.root.appendingPathComponent("catalog/transcription-models.json")),
               let catalogue = try? JSONDecoder().decode(Catalogue.self, from: data),
               let installed = app.modelLibrary.installed {
                let entries = catalogue.models.filter { installed.contains($0.id) }.map { model in
                    "\(model.displayName) · \(model.license)\n\(model.attribution)" + (model.citation.map { "\n\($0)" } ?? "")
                }
                if !entries.isEmpty { text += "\n\nInstalled transcription models\n\n" + entries.joined(separator: "\n\n") }
            }
        }
    }
}

@MainActor struct TextSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) { Text(title).font(.title2); ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }; HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) } }.padding(24).frame(width: 640, height: 480)
    }
}
