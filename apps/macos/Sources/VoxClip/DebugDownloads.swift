#if DEBUG
import SwiftUI
import VoxClipCore

actor RegressionModelDownloader: ModelDownloader {
    let model: ModelDescriptor
    let failure: VoxClipError?
    let hold: Bool
    private var confirmation: ModelDownloadConfirmation?
    private var installed = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(model: ModelDescriptor, failure: VoxClipError? = nil, hold: Bool = false) { self.model = model; self.failure = failure; self.hold = hold }
    func configure(_ confirmation: ModelDownloadConfirmation) { self.confirmation = confirmation }
    func installedModels() -> [String] { installed ? [model.id] : [] }
    func verify(id: String) -> Bool { installed && id == model.id }
    func remove(id: String) { installed = false }
    func install(id: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        guard let confirmation, try await confirmation.request(model, bytes: model.totalBytes + 123) else { throw VoxClipError.cancelled }
        if let failure { throw failure }
        if hold { await withCheckedContinuation { waiting = $0; observer?.resume(); observer = nil } }
        try Task.checkCancellation()
        installed = true
    }
    func waitUntilHeld() async { if waiting == nil { await withCheckedContinuation { observer = $0 } } }
    func release() { waiting?.resume(); waiting = nil }
}

actor RegressionAppleSpeech: Transcriber {
    nonisolated let engine = TranscriptEngine.appleSpeech
    private var installed: Set<String> = []
    private(set) var prepared: [String] = []
    let hold: Bool
    let failure: VoxClipError?
    private var waiting: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(hold: Bool = false, failure: VoxClipError? = nil) { self.hold = hold; self.failure = failure }
    nonisolated func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .runGrouped, verbatim: false, autoLanguage: false, onDevice: true) }
    func supports(_ language: LanguageChoice, model: String?) -> Bool { language != .forced("et") }
    func readiness(for plan: TranscriptionPlan) -> Readiness {
        guard case .forced(let code) = plan.language, code != "et" else { return .unsupportedLanguage("et") }
        return installed.contains(code) ? .ready : .needsSystemAssets(locale: code + "-US")
    }
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard case .forced(let code) = plan.language else { return }
        prepared.append(code); progress(0.5)
        if hold { await withCheckedContinuation { waiting = $0; observer?.resume(); observer = nil } }
        try Task.checkCancellation()
        if let failure { throw failure }
        installed.insert(code); progress(1)
    }
    func waitUntilHeld() async { if waiting == nil { await withCheckedContinuation { observer = $0 } } }
    func release() { waiting?.resume(); waiting = nil }
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) throws -> RawTranscript { throw VoxClipError.cancelled }
}

@MainActor enum DebugDownloads {
    static func run(app: AppModel, directory: URL, captures: Bool = true) async throws -> [DebugUISuite.Result] {
        let descriptor = try await app.modelLibrary.localModel(language: "et")
        var results: [DebugUISuite.Result] = []
        for scenario in ["success", "cancel", "failure"] {
            let store = RegressionModelDownloader(model: descriptor, failure: scenario == "failure" ? .offline : nil)
            let owner = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: store)
            let library = owner.modelLibrary
            await store.configure(library.confirmation)
            var confirmed = false
            library.confirmation.onRequest = { confirmed = library.confirmation.totalBytes == descriptor.totalBytes + 123; library.confirmation.respond(scenario != "cancel") }
            library.download(descriptor)
            await library.task?.value
            let passed: Bool
            switch scenario {
            case "success": passed = library.installed?.contains(descriptor.id) == true && library.error == nil && library.failedModelID == nil
            case "cancel": passed = library.error == nil && library.failedModelID == nil && library.progress == nil
            default: passed = library.failedModelID == descriptor.id && library.error?.isEmpty == false
            }
            results.append(.init(name: "model confirmation uses store bytes: \(scenario)", passed: confirmed && passed))
            library.confirmation.onRequest = nil
        }
        let store = RegressionModelDownloader(model: descriptor, hold: true)
        let owner = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: store)
        let library = owner.modelLibrary
        await store.configure(library.confirmation)
        library.confirmation.onRequest = { library.confirmation.respond(true) }
        library.download(descriptor)
        await store.waitUntilHeld()
        if captures { try await DebugUISuite.snapshot(LocalModelsView(app: owner), name: "models-downloading", size: NSSize(width: 720, height: 480), appearance: .aqua, directory: directory) }
        let survived = owner.modelLibrary === library && library.task?.isCancelled == false && library.progress != nil
        await store.release(); await library.task?.value
        results.append(.init(name: "closing Local Models preserves the AppModel download task", passed: survived && library.installed?.contains(descriptor.id) == true))
        library.confirmation.onRequest = nil
        let speech = RegressionAppleSpeech()
        let speechOwner = AppModel(settingsStore: RegressionSettingsStore())
        let assets = speechOwner.appleSpeechAssets
        assets.engine = speech
        await assets.check("auto"); let chooses = assets.state == .chooseLanguage
        await assets.check("et"); let unsupported = assets.state == .unsupported
        await assets.check("en")
        let english = Locale.current.localizedString(forLanguageCode: "en") ?? "en"
        let offered = assets.state == .needsDownload && assets.statusText == "Apple's \(english) speech model isn't on this Mac yet."
        assets.download()
        let downloading = assets.state == .downloading && assets.statusText == "Downloading Apple's \(english) speech model…"
        await assets.task?.value
        let prepared = await speech.prepared
        results.append(.init(name: "Settings downloads Apple's speech model through the engine's asset flow", passed: chooses && unsupported && offered && downloading
            && assets.state == .installed && prepared == ["en"] && assets.error == nil && speechOwner.appleSpeechAssets === assets))
        for scenario in ["cancel", "failure", "language-change"] {
            let speech = RegressionAppleSpeech(hold: true, failure: scenario == "failure" ? .offline : nil)
            let owner = AppModel(settingsStore: RegressionSettingsStore())
            let assets = owner.appleSpeechAssets
            assets.engine = speech
            await assets.check("en")
            assets.download()
            let download = assets.task
            await speech.waitUntilHeld()
            if scenario == "cancel" { download?.cancel() }
            if scenario == "language-change" { await assets.check("fr") }
            await speech.release()
            await download?.value
            let passed = assets.task == nil && assets.state == .needsDownload && (scenario == "failure" ? assets.error?.isEmpty == false : assets.error == nil)
                && assets.language == (scenario == "language-change" ? "fr" : "en")
            results.append(.init(name: "Apple speech assets \(scenario) preserve retry, silent cancellation and current language", passed: passed))
        }
        return results
    }
}
#endif
