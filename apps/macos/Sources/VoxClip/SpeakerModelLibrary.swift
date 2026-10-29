import Foundation
import Observation
import SwiftUI
import VoxClipCore
import VoxClipMedia

@MainActor @Observable final class SpeakerModelLibrary {
    var model: SpeakerModel?
    var installed = false
    var progress: ModelDownloadProgress?
    var message: String?
    let confirmation = ModelDownloadConfirmation()
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var store: ModelStore?
    @ObservationIgnored private var embedder: ONNXSpeakerEmbedder?
    @ObservationIgnored private var downloadID: UUID?
    @ObservationIgnored var task: Task<Void, Never>?
    init(app: AppModel) { self.app = app }
    func load() async {
        guard let shared = app.shared else { return }
        do {
            let catalog = try SpeakerModelCatalog(shared: shared)
            model = catalog.entry
            if store == nil {
                let confirmation = confirmation
                store = ModelStore(catalog: catalog, locations: app.locations, namespace: .voiceLab, confirm: { model, bytes in try await confirmation.request(model, bytes: bytes) })
            }
            installed = try await store?.verify(id: catalog.entry.id) == true
        } catch { installed = false; message = "The own-voice check model is unavailable. No audio was sent." }
    }
    func download() {
        guard let model, let store, progress == nil, app.bool("voiceLab.enabled") else { return }
        progress = .init(modelID: model.id, receivedBytes: 0, totalBytes: model.totalBytes)
        let requestID = UUID(); downloadID = requestID
        message = nil
        task = Task {
            defer { if downloadID == requestID { downloadID = nil; progress = nil; task = nil } }
            do {
                try await store.install(id: model.id) { [weak library = self] update in
                    Task { @MainActor in
                        guard let library, library.downloadID == requestID else { return }
                        library.progress = update
                    }
                }
                try Task.checkCancellation()
                await load()
            } catch is CancellationError {} catch VoxClipError.cancelled {} catch { message = "The model could not be installed. Your videos and edits are still here. Retry when ready." }
        }
    }
    func remove() {
        guard let model, let store, progress == nil else { return }
        task = Task {
            do { try await store.remove(id: model.id); embedder = nil; installed = false }
            catch { message = "The model could not be removed." }
            task = nil
        }
    }
    func check(language: String = "en") async throws -> VoiceSpeakerCheck {
        guard let shared = app.shared else { return VoiceSpeakerCheck() }
        let model = try SpeakerModelCatalog(shared: shared).entry
        guard model.calibratedThreshold(language: language) != nil else { return VoiceSpeakerCheck() }
        let directory = model.directory(app.locations)
        do {
            _ = try await Task.detached(priority: .utility) { try model.verifiedFiles(at: directory) }.value
            if embedder == nil { embedder = try await Task.detached(priority: .utility) { try ONNXSpeakerEmbedder(model: model, directory: directory) }.value }
            installed = true
            return try await embedder?.speakerCheck(language: language) ?? VoiceSpeakerCheck()
        } catch { embedder = nil; installed = false; return VoiceSpeakerCheck() }
    }
    func useGuard(store: VoiceConsentStore, recordID: String) async throws -> VoiceUseGuard {
        let record = try await store.load(recordID)
        return VoiceUseGuard(store: store, check: try await check(language: record.statement.language))
    }
}

@MainActor struct SpeakerModelRows: View {
    let app: AppModel
    private var library: SpeakerModelLibrary { app.speakerModelLibrary }
    var body: some View {
        Section("Own-voice check · on this Mac") {
            if let model = library.model {
                Text(model.displayName).fontWeight(.medium)
                Text("\(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)) · \(model.license)").font(.caption)
                Text(model.attribution).font(.caption2).textSelection(.enabled)
                Text("Runs on this Mac using CPU only. No audio leaves this Mac for the speaker check.").font(.caption)
                Text(model.calibratedThreshold() == nil ? "The speaker check is not ready yet. Creating a voice is unavailable." : "English speaker checks are available. Estonian is not available yet. Check your own voice with this Mac's microphone before relying on the check.").font(.caption)
                if let progress = library.progress {
                    ProgressView(value: Double(progress.receivedBytes), total: Double(max(1, progress.totalBytes)))
                    Text(progress.verifying ? "Verifying download…" : "Downloading \(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))").font(.caption)
                    Button("Cancel") { library.task?.cancel(); library.confirmation.respond(false) }
                } else if library.installed {
                    Text("Installed ✓")
                    Button("Remove") { library.remove() }.disabled(app.voiceLabSession.busy || app.voiceLabSession.recorder.recording)
                } else {
                    Button("Download") { library.download() }.disabled(app.voiceLabSession.busy || !app.bool("voiceLab.enabled"))
                }
            }
            if let message = library.message { Text(message).font(.caption) }
        }
        .task { await library.load() }
        .confirmationDialog(downloadTitle, isPresented: Binding(get: { library.confirmation.pending != nil }, set: { if !$0 { library.confirmation.respond(false) } }), titleVisibility: .visible) {
            if let model = library.confirmation.pending {
                Button("Download") { library.confirmation.respond(true) }
                Button("Open source page") { NSWorkspace.shared.open(model.sourcePage) }
                Button("Cancel", role: .cancel) { library.confirmation.respond(false) }
            }
        } message: { Text(downloadMessage) }
    }
    private var downloadTitle: String {
        guard let model = library.confirmation.pending else { return "Download model" }
        return "Download \(model.displayName) from \(model.files.first?.url.host ?? "the publisher")?"
    }
    private var downloadMessage: String {
        guard let model = library.confirmation.pending else { return "" }
        let bytes = ByteCountFormatter.string(fromByteCount: library.confirmation.totalBytes, countStyle: .file)
        return "This model is published by \(model.publisher), not by VoxClip. It downloads from the publisher (\(bytes)) and runs on this Mac. Licence: \(model.license). By downloading you accept the publisher's terms.\n\n\(model.attribution)"
    }
}
