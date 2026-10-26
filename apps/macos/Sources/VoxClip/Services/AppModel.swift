import SwiftUI
import Observation
import OSLog
import VoxClipCore
import VoxClipMedia

struct ProviderChoice: Decodable, Identifiable, Sendable {
    struct Auth: Decodable, Sendable { let keyAccount: String?; let keyHint: String? }
    struct Model: Decodable, Identifiable, Sendable { let id: String; let name: String; let tier: String? }
    struct CLI: Decodable, Sendable { let executable: String; let signInHint: String; let installHint: String }
    let id: String
    let label: String
    let group: String
    let privacy: String
    let enabled: Bool?
    let platforms: [String]
    let auth: Auth?
    let cli: CLI?
    let defaultModel: String?
    let baseUrl: String?
    let models: [Model]
}

struct ProviderCatalogue: Decodable { let connectors: [ProviderChoice] }
protocol ProviderKeyStore: Sendable {
    func hasKey(for provider: String) async -> Bool
    func save(_ value: String, for provider: String) async throws
}
extension SecretStore: ProviderKeyStore {}
extension ProviderChoice {
    var cliConsentCopy: String? {
        if id == "claude-code" { return "VoxClip will run your installed Claude Code with your own sign-in. The transcript is sent to Anthropic and counts toward your Claude plan's usage." }
        if id == "codex" { return "VoxClip will run your installed Codex with your own sign-in. The transcript is sent to OpenAI and counts toward your ChatGPT plan's usage." }
        return nil
    }
}

@MainActor @Observable public final class AppModel {
    static let sharedModel = AppModel()
    nonisolated static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    public var startupError: VoxClipError?
    var notice: String?
    var settingErrors: [String: String] = [:]
    var settings = SettingsDocument()
    var providers: [ProviderChoice] = []
    var styles: [CaptionStyle] = []
    var recent: [URL] = []
    func noteRecent(_ url: URL) {
        if !Self.isTestSession { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        recent.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recent.insert(url, at: 0)
        recent = Array(recent.prefix(20))
    }
    func moveRecent(from oldURL: URL, to newURL: URL) {
        recent.removeAll { $0.standardizedFileURL == oldURL.standardizedFileURL || $0.standardizedFileURL == newURL.standardizedFileURL }
        recent.insert(newURL, at: 0)
        if !Self.isTestSession {
            NSDocumentController.shared.clearRecentDocuments(nil)
            for url in recent.reversed() { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        }
    }
    var update: UpdateRelease?
    var showTour = false
    let fileRouter = FileOpenRouter()
    @ObservationIgnored weak var activeHome: EditorModel?
    @ObservationIgnored weak var activeEditor: EditorModel?
    private(set) var settingsLoaded = false
    private(set) var loadingSettings = true
    private(set) var pauseBreathRevision = 0
    private(set) var connectorReadinessRevision = 0
    var providerStatus: [String: String] = [:]
    var openProjectKeys: [String: String] = [:]
    let log: RedactingLogger
    let secrets: SecretStore
    let settingsStore: any SettingsStore
    let projectStore: JSONProjectStore
    let updates: any UpdateChecking
    let shared: SharedResources?
    let locations = DataLocations()
    private var settingsTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var pendingSettings: [String: JSONValue] = [:]
    var modelLibrary: ModelLibrary {
        if let library { return library }
        let value = ModelLibrary(app: self, store: modelDownloader)
        library = value
        return value
    }
    @ObservationIgnored private var library: ModelLibrary?
    @ObservationIgnored private let modelDownloader: (any ModelDownloader)?
    @ObservationIgnored var connectorOverride: ((String) -> any LLMConnector)?
    @ObservationIgnored var providerKeyStoreOverride: (any ProviderKeyStore)?
    var providerKeyStore: any ProviderKeyStore { providerKeyStoreOverride ?? secrets }
    @ObservationIgnored lazy var captions = CaptionHandoff(shared: shared)

    public init(settingsStore: (any SettingsStore)? = nil, updates: any UpdateChecking = UpdateChecker(), modelDownloader: (any ModelDownloader)? = nil) {
        let directory = DataLocations().logs
        let logger = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path, directory: directory) { entry in
            let logger = os.Logger(subsystem: "com.voxconvo.voxclip", category: entry.category)
            switch entry.level {
            case .debug: logger.debug("\(entry.message, privacy: .private)")
            case .info: logger.info("\(entry.message, privacy: .private)")
            case .warn: logger.warning("\(entry.message, privacy: .private)")
            case .error: logger.error("\(entry.message, privacy: .private)")
            }
        }
        log = logger
        secrets = SecretStore(log: logger)
        self.settingsStore = settingsStore ?? JSONSettingsStore(locations: locations, logger: logger)
        projectStore = JSONProjectStore(logger: logger)
        self.updates = updates
        self.modelDownloader = modelDownloader
        do { shared = try SharedResources.locate() }
        catch { shared = nil; startupError = .sharedResourcesMissing }
        DesignValues.registerFonts()
        loadCatalogue()
    }

    func launch() {
        guard startupTask == nil else { return }
        startupTask = Task { await loadStartup() }
    }
    func start() async {
        launch()
        await startupTask?.value
    }
    private func loadStartup() async {
        recent = Self.isTestSession ? [] : NSDocumentController.shared.recentDocumentURLs
        do {
            var loaded = try await settingsStore.load()
            loaded.values.merge(pendingSettings) { _, new in new }
            settings = loaded
            refreshConnectorReadiness()
            settingsLoaded = true
            loadingSettings = false
            if !pendingSettings.isEmpty { scheduleSettingsSave() }
            pendingSettings.removeAll()
        } catch {
            loadingSettings = false
            notice = await safeError(error, context: "Settings could not be loaded.")
            return
        }
        restoreCachedUpdate()
        #if DEBUG
        if Self.isTestSession { return }
        #endif
        guard bool("update.autoCheck", fallback: true) else { return }
        let last = string("update.lastCheckAt")
        if let date = ISO8601DateFormatter().date(from: last), Date().timeIntervalSince(date) < 86_400 { return }
        updateTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await self?.checkUpdates(manual: false)
        }
    }
    static var isTestSession: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-demoCapture") || CommandLine.arguments.contains("-uiSelfTest") || CommandLine.arguments.contains("-uiPerformanceTest") || CommandLine.arguments.contains("-sceneAudit") || CommandLine.arguments.contains("-saveBoundaryAudit") || CommandLine.arguments.contains("-settingsAudit")
        #else
        false
        #endif
    }

    func string(_ key: String, fallback: String = "") -> String {
        if case .string(let value) = settings.values[key] { return value }
        return fallback
    }
    @discardableResult func selectOnboardingConnector(_ id: String, consent: Bool) -> Bool {
        guard let provider = providers.first(where: { $0.id == id }), provider.cliConsentCopy == nil || consent else { return false }
        set("llm.connector", .string(id))
        if provider.cliConsentCopy != nil, consent { set("llm.cloudConsent.\(id)", .bool(true)) }
        return true
    }
    func bool(_ key: String, fallback: Bool = false) -> Bool {
        if case .bool(let value) = settings.values[key] { return value }
        return fallback
    }
    func number(_ key: String, fallback: Double) -> Double {
        if case .number(let value) = settings.values[key] { return value }
        return fallback
    }
    @discardableResult func set(_ key: String, _ value: JSONValue) -> Bool {
        do { try SettingsDocument(values: [key: value]).validate() }
        catch {
            settingErrors[key] = "Enter a valid value. The previous setting is unchanged."
            return false
        }
        settingErrors[key] = nil
        guard settings.values[key] != value else { return true }
        if key == "editing.pauseBreath", settingsLoaded, settings.values[key] != value { pauseBreathRevision += 1 }
        if key == "llm.connector" || key.hasPrefix("llm.baseUrl.") || key.hasPrefix("llm.cliPath.") { refreshConnectorReadiness() }
        settings.values[key] = value
        guard settingsLoaded else { if loadingSettings { pendingSettings[key] = value }; return true }
        scheduleSettingsSave()
        return true
    }
    func refreshConnectorReadiness() { connectorReadinessRevision &+= 1 }
    func saveProviderKey(_ value: String, for provider: String) async throws {
        try await providerKeyStore.save(value, for: provider)
        refreshConnectorReadiness()
    }
    private func scheduleSettingsSave() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                try await settingsStore.save(settings)
            } catch is CancellationError {} catch {
                guard let self else { return }
                notice = await safeError(error, context: "Settings could not be saved.")
            }
        }
    }
    func flushSettings() async {
        await startupTask?.value
        let pending = settingsTask
        settingsTask?.cancel()
        await pending?.value
        guard settingsLoaded else { return }
        do { try await settingsStore.save(settings); try await settingsStore.flush() }
        catch { notice = await safeError(error, context: "Settings could not be saved.") }
    }
    private func restoreCachedUpdate() {
        guard let url = URL(string: string("update.htmlURL")) else { return }
        update = UpdateChecker.available(version: string("update.latestVersion"), htmlURL: url, downloadURL: nil, currentVersion: Self.version)
    }
    var appearance: ColorScheme? {
        switch string("general.appearance", fallback: "system") { case "dark": .dark; case "light": .light; default: nil }
    }
    func safeError(_ error: any Error, context: String = "") async -> String {
        let provider = providers.first { context == "ai:\($0.label)" || context == "ai-test:\($0.label)" }
        let message = UserMessages.message(error, context: context, model: provider.map { string("llm.model.\($0.id)", fallback: $0.defaultModel ?? "the selected model") } ?? "the selected model", installHint: provider?.cli?.installHint, signInHint: provider?.cli?.signInHint, connectorID: provider?.id)
        guard !message.isEmpty else { return "" }
        let category = context.hasPrefix("ai") ? "llm" : context == "export" ? "export" : "settings"
        await log.write(LogEntry(level: .error, category: category, message: "code=\((error as? VoxClipError)?.code.rawValue ?? (error is LLMError ? "llmFailure" : "operationFailed"))"))
        return await log.redact(message)
    }
    func checkUpdates(manual: Bool) async {
        do {
            update = try await updates.check(currentVersion: Self.version)
            set("update.lastCheckAt", .string(Date().ISO8601Format()))
            if let update {
                set("update.latestVersion", .string(update.version)); set("update.htmlURL", .string(update.htmlURL.absoluteString))
                notice = "VoxClip \(update.version) is available."
            } else {
                set("update.latestVersion", .null); set("update.htmlURL", .null)
                if manual { notice = "VoxClip \(Self.version) is the latest version." }
            }
            await log.write(LogEntry(level: .info, category: "update", message: update == nil ? "check=current" : "check=available"))
        } catch {
            await log.write(LogEntry(level: .warn, category: "update", message: "check=failed"))
            if manual {
                let offline = (error as? VoxClipError) == .offline || (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains($0.code) } == true
                notice = offline ? "Couldn't check for updates. You're offline." : "Couldn't check for updates. Try again later."
            }
        }
    }
    func loadCatalogue() {
        guard let shared else { return }
        do {
            let data = try Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))
            providers = try JSONDecoder().decode(ProviderCatalogue.self, from: data).connectors.filter { $0.platforms.contains("macos") && $0.enabled != false }
            styles = try CaptionStyleLibrary(shared: shared).styles
        } catch { startupError = .sharedResourcesMissing }
    }
    func connector(_ id: String) -> any LLMConnector {
        if let connectorOverride { return connectorOverride(id) }
        guard let selected = ConnectorID(rawValue: id), let shared, let catalog = try? LLMCatalog(shared: shared) else {
            return StubLLMConnector(id: ConnectorID(rawValue: id) ?? .ollama)
        }
        if selected == .appleFoundation { return FoundationModelsConnector(log: log) }
        let provider = providers.first { $0.id == id }
        let base = string("llm.baseUrl.\(id)", fallback: provider?.baseUrl ?? "")
        let path = string("llm.cliPath.\(id)")
        return StubLLMConnector(id: selected, keys: secrets, catalog: catalog, log: log,
            baseURL: base.isEmpty ? nil : URL(string: base), cliPath: path.isEmpty ? nil : path)
    }
    func revealLogs() { try? FileManager.default.createDirectory(at: locations.logs, withIntermediateDirectories: true); NSWorkspace.shared.open(locations.logs) }
    func diagnostics() async -> String {
        let file = locations.logs.appendingPathComponent("voxclip.log")
        let lines = (try? String(contentsOf: file, encoding: .utf8).split(separator: "\n").suffix(200).joined(separator: "\n")) ?? "No log entries."
        return await log.redact("VoxClip \(Self.version) (\(Self.build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · arm64\n\(lines)")
    }
}
