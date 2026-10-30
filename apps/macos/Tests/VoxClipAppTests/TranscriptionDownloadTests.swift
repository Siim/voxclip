#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

/// Installs the requested model and the models it requires once the confirmation is accepted; no network.
private actor SheetModelDownloader: ModelDownloader {
    let model: ModelDescriptor
    let failure: VoxClipError?
    private var confirmation: ModelDownloadConfirmation?
    private var installed: Set<String> = []
    init(model: ModelDescriptor, failure: VoxClipError? = nil) { self.model = model; self.failure = failure }
    func configure(_ confirmation: ModelDownloadConfirmation) { self.confirmation = confirmation }
    func installedModels() -> [String] { installed.sorted() }
    func verify(id: String) -> Bool { installed.contains(id) }
    func remove(id: String) { installed.remove(id) }
    func install(id: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        guard let confirmation, try await confirmation.request(model, bytes: model.totalBytes) else { throw VoxClipError.cancelled }
        if let failure { throw failure }
        installed.formUnion([id] + model.requires)
    }
}

@Suite("Headless first-use model download", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; nothing is downloaded."))
@MainActor struct TranscriptionDownloadTests {
    private func turbo() async throws -> ModelDescriptor {
        try await BundledModelCatalog(shared: SharedResources.locate()).model(id: "whisper-large-v3-turbo-q5_0")
    }

    @Test func missingLocalModelOffersDownloadAndElevenLabsWhenKeyed() async throws {
        let model = try await turbo()
        let app = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: SheetModelDownloader(model: model))
        // A new user's default: engine "On this Mac", language Auto, nothing installed.
        let local = try await app.modelLibrary.localModel(language: "auto")
        #expect(local == model)
        let bytes: Int64 = model.totalBytes + 885_098
        let readiness = Readiness.needsModels(ids: [model.id, "silero-vad-v6.2.0"], bytes: bytes)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let keyed = try #require(TranscriptionPrompt(readiness, engine: "local", language: "auto", local: local, hasCloudKey: true))
        #expect(keyed.message == "Download the \(model.displayName) model (\(size)) to transcribe on this Mac.")
        #expect(keyed.download == model && keyed.offersCloud)
        let unkeyed = try #require(TranscriptionPrompt(readiness, engine: "local", language: "auto", local: local, hasCloudKey: false))
        #expect(unkeyed.download == model && !unkeyed.offersCloud)
        #expect(TranscriptionPrompt(.ready, engine: "local", language: "auto", local: local, hasCloudKey: true) == nil)
    }

    @Test func appleSpeechWithAutoAsksWhichLanguageIsSpoken() throws {
        let auto = try #require(TranscriptionPrompt(.unsupportedLanguage("Choose a supported Apple Speech locale"), engine: "apple", language: "auto", local: nil, hasCloudKey: true))
        #expect(auto.message == "Which language is spoken?")
        #expect(auto.download == nil && !auto.offersCloud)
        let estonian = try #require(TranscriptionPrompt(.unsupportedLanguage("et"), engine: "apple", language: "et", local: nil, hasCloudKey: false))
        #expect(estonian.message == "Apple Speech can't transcribe \(Locale.current.localizedString(forLanguageCode: "et") ?? "et").")
    }

    @Test(arguments: ["success", "decline", "failure"])
    func sheetDownloadConfirmsInTheSheetAndReportsWhetherToContinue(scenario: String) async throws {
        let model = try await turbo()
        let store = SheetModelDownloader(model: model, failure: scenario == "failure" ? .offline : nil)
        let app = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: store)
        let library = app.modelLibrary
        await store.configure(library.confirmation)
        var origin: ModelLibrary.DownloadOrigin?
        library.confirmation.onRequest = {
            origin = library.downloadOrigin
            library.confirmation.respond(scenario != "decline")
        }
        defer { library.confirmation.onRequest = nil }
        let installed = await library.install(model)
        #expect(origin == .transcription)
        #expect(library.progress == nil)
        switch scenario {
        case "success":
            #expect(installed && library.error == nil && library.failedModelID == nil)
            #expect(library.installed?.isSuperset(of: [model.id] + model.requires) == true)
        case "decline":
            #expect(!installed && library.error == nil && library.failedModelID == nil)
        default:
            #expect(!installed && library.failedModelID == model.id && library.error?.isEmpty == false)
        }
    }

    @Test func settingsDownloadsKeepTheirOwnConfirmation() async throws {
        let model = try await turbo()
        let store = SheetModelDownloader(model: model)
        let app = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: store)
        let library = app.modelLibrary
        await store.configure(library.confirmation)
        var origin: ModelLibrary.DownloadOrigin?
        library.confirmation.onRequest = { origin = library.downloadOrigin; library.confirmation.respond(true) }
        defer { library.confirmation.onRequest = nil }
        library.download(model)
        await library.task?.value
        #expect(origin == .settings)
        #expect(library.installed?.contains(model.id) == true)
    }

    @Test func lowMemoryMacsGetTheLowMemoryDownload() {
        let gib: Int64 = 1 << 30
        #expect(ModelLibrary.localModelID(local: ["a", "b"], installed: [], recommended: "large", lowMemory: "small", ram: 4 * gib, threshold: 8 * gib) == "small")
        #expect(ModelLibrary.localModelID(local: ["a", "b"], installed: [], recommended: "large", lowMemory: "small", ram: 16 * gib, threshold: 8 * gib) == "large")
        #expect(ModelLibrary.localModelID(local: ["a", "b"], installed: [], recommended: "large", lowMemory: nil, ram: 4 * gib, threshold: 8 * gib) == "large")
        #expect(ModelLibrary.localModelID(local: ["a", "b"], installed: ["b"], recommended: "large", lowMemory: "small", ram: 4 * gib, threshold: 8 * gib) == "b")
    }
}
#endif
