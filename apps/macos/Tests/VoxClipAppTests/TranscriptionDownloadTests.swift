#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClip

private actor InlineModelDownloader: ModelDownloader {
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
        progress(ModelDownloadProgress(modelID: id, receivedBytes: 212_000_000, totalBytes: model.totalBytes))
        if let failure { throw failure }
        installed.formUnion([id] + model.requires)
    }
}

@Suite("Headless inline model download", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
@MainActor struct TranscriptionDownloadTests {
    private func turbo() async throws -> ModelDescriptor {
        try await BundledModelCatalog(shared: SharedResources.locate()).model(id: "whisper-large-v3-turbo-q5_0")
    }
    @Test func inlineDownloadAcceptsOnlyItsDisplayedPublishersWithoutADialog() async throws {
        let item = try await turbo()
        let store = InlineModelDownloader(model: item)
        let app = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: store)
        let library = app.modelLibrary
        await store.configure(library.confirmation)
        var asked = 0
        library.confirmation.onRequest = { asked += 1; library.confirmation.respond(false) }
        let installed = await library.install(item, publisherTermsAccepted: true)
        #expect(installed && asked == 0 && library.confirmation.pending == nil)
        #expect(library.installed?.isSuperset(of: [item.id] + item.requires) == true)
        #expect(library.confirmation.approvedModelIDs.isEmpty)
        #expect(InlineTranscription.publisherTerms(item).contains("By downloading you accept the publisher's terms."))
        #expect(InlineTranscription.publisherTerms(item).contains(item.publisher))
    }
    @Test(arguments: [VoxClipError.offline, .rateLimited("huggingface.co"), .modelChecksumMismatch("weights.bin"), .diskFull("Macintosh HD")])
    func inlineDownloadFailuresKeepProgressAndAllowRetry(failure: VoxClipError) async throws {
        let item = try await turbo()
        let store = InlineModelDownloader(model: item, failure: failure)
        let app = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: store)
        await store.configure(app.modelLibrary.confirmation)
        #expect(await app.modelLibrary.install(item, publisherTermsAccepted: true) == false)
        #expect(app.modelLibrary.failedModelID == item.id)
        #expect(app.modelLibrary.lastProgress?.receivedBytes == 212_000_000)
        #expect(app.modelLibrary.error != nil && app.modelLibrary.confirmation.pending == nil)
        if failure.code == .rateLimited { #expect(app.modelLibrary.error == "Hugging Face is busy. Try again in a minute.") }
        if failure.code == .offline { #expect(app.modelLibrary.error == "You're offline.") }
    }
    @Test func settingsDownloadsKeepTheirOwnConfirmation() async throws {
        let item = try await turbo()
        let store = InlineModelDownloader(model: item)
        let app = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: store)
        let library = app.modelLibrary
        await store.configure(library.confirmation)
        var origin: ModelLibrary.DownloadOrigin?
        library.confirmation.onRequest = { origin = library.downloadOrigin; library.confirmation.respond(true) }
        library.download(item)
        await library.task?.value
        #expect(origin == .settings && library.installed?.contains(item.id) == true)
    }
    @Test func cancelFromAnotherEditorDoesNotCancelTheCurrentDownload() async throws {
        let item = try await turbo()
        let store = InlineModelDownloader(model: item)
        let app = AppModel(settingsStore: RegressionSettingsStore(), modelDownloader: store)
        let library = app.modelLibrary
        await store.configure(library.confirmation)
        library.confirmation.onRequest = {
            library.cancelTranscriptionDownload(modelID: "a-different-model")
            #expect(library.task?.isCancelled == false)
            library.confirmation.respond(true)
        }
        #expect(await library.install(item) == true)
    }
    @Test func lowMemoryMacsGetTheLowMemoryDownload() {
        let gib: Int64 = 1 << 30
        #expect(ModelLibrary.localModelID(local: ["a", "b"], installed: [], recommended: "large", lowMemory: "small", ram: 4 * gib, threshold: 8 * gib) == "small")
        #expect(ModelLibrary.localModelID(local: ["a", "b"], installed: [], recommended: "large", lowMemory: "small", ram: 16 * gib, threshold: 8 * gib) == "large")
        #expect(ModelLibrary.localModelID(local: ["a", "b"], installed: ["b"], recommended: "large", lowMemory: "small", ram: 4 * gib, threshold: 8 * gib) == "b")
    }
}
#endif
