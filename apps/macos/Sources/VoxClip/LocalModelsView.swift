import SwiftUI
import Observation
import VoxClipCore

@MainActor @Observable final class ModelLibrary {
    var models: [ModelDescriptor] = []
    var installed: Set<String>?
    var progress: ModelDownloadProgress?
    var error: String?
    let confirmation: ModelDownloadConfirmation
    var failedModelID: String?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var downloadID: UUID?
    @ObservationIgnored let store: any ModelDownloader
    unowned let app: AppModel
    init(app: AppModel, store: (any ModelDownloader)? = nil) {
        self.app = app
        let confirmation = ModelDownloadConfirmation()
        self.confirmation = confirmation
        self.store = store ?? ModelStore(catalog: BundledModelCatalog(shared: app.shared ?? SharedResources(root: URL(fileURLWithPath: "/"))), locations: app.locations, confirm: { model, bytes in try await confirmation.request(model, bytes: bytes) })
    }
    func load() async {
        guard let shared = app.shared else { return }
        do { models = try await BundledModelCatalog(shared: shared).models(); installed = Set(try await store.installedModels()) }
        catch {
            struct Catalogue: Decodable { let models: [ModelDescriptor] }
            models = (try? JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: shared.root.appendingPathComponent("catalog/transcription-models.json"))).models) ?? []
            self.error = await app.safeError(error, context: "Installation status is unavailable.")
        }
        struct Listing: Decodable {
            struct Entry: Decodable { let id: String; let listed: Bool?; let platforms: [String] }
            let models: [Entry]
        }
        guard let data = try? Data(contentsOf: shared.root.appendingPathComponent("catalog/transcription-models.json")),
              let listing = try? JSONDecoder().decode(Listing.self, from: data) else { models = []; return }
        let visible = Set(listing.models.filter { $0.listed != false && $0.platforms.contains("macos") }.map(\.id))
        models.removeAll { !visible.contains($0.id) }
    }
    func download(_ model: ModelDescriptor) {
        guard progress == nil, installed?.contains(model.id) != true else { return }
        let requestID = UUID()
        downloadID = requestID
        progress = ModelDownloadProgress(modelID: model.id, receivedBytes: 0, totalBytes: model.totalBytes)
        failedModelID = nil
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if downloadID == requestID { downloadID = nil; progress = nil } }
            do {
                try Task.checkCancellation()
                try await store.install(id: model.id) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.downloadID == requestID else { return }
                        self.progress = update
                    }
                }
                try Task.checkCancellation(); installed = Set(try await store.installedModels()); error = nil
            } catch is CancellationError {} catch VoxClipError.cancelled {} catch { failedModelID = model.id; self.error = await app.safeError(error) }
        }
    }
    func remove(_ model: ModelDescriptor) {
        guard progress == nil else { return }
        task = Task { do { try await store.remove(id: model.id); installed = Set(try await store.installedModels()) } catch { self.error = await app.safeError(error) } }
    }
    func localModel(language: String) async throws -> ModelDescriptor {
        guard let shared = app.shared else { throw VoxClipError.sharedResourcesMissing }
        struct Catalogue: Decodable {
            struct Defaults: Decodable {
                struct Language: Decodable {
                    struct Platform: Decodable { let local: [String]; let recommendedDownload: String }
                    let macos: Platform
                }
                let byLanguage: [String: Language]
            }
            let models: [ModelDescriptor]
            let defaults: Defaults
        }
        let catalogue = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: shared.root.appendingPathComponent("catalog/transcription-models.json")))
        guard let defaults = (catalogue.defaults.byLanguage[language] ?? catalogue.defaults.byLanguage["*"])?.macos else { throw VoxClipError.sharedResourcesMissing }
        let installed = Set((try? await store.installedModels()) ?? [])
        let id = defaults.local.first(where: installed.contains) ?? defaults.recommendedDownload
        guard let model = catalogue.models.first(where: { $0.id == id }) else { throw VoxClipError.sharedResourcesMissing }
        return model
    }
}

@MainActor struct LocalModelsView: View {
    let app: AppModel
    var body: some View { Form { LocalModelRows(app: app) }.formStyle(.grouped) }
}

@MainActor struct LocalModelRows: View {
    let app: AppModel
    private var library: ModelLibrary { app.modelLibrary }
    init(app: AppModel) { self.app = app }
    var body: some View {
        Section {
                if let error = library.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                ForEach(library.models, id: \.id) { model in
                    modelRow(model)
                }
            } header: { Text("Models") } footer: { Text("Models download on first use and never ship inside the app. Each runs entirely on this Mac.") }
        .task { await library.load() }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { library.confirmation.pending != nil }, set: { if !$0 { library.confirmation.respond(false) } }), titleVisibility: .visible) {
            if let model = library.confirmation.pending {
                Button("Download") { library.confirmation.respond(true) }
                Button("Open source page") { NSWorkspace.shared.open(model.sourcePage) }
                Button("Cancel", role: .cancel) { library.confirmation.respond(false) }
            }
        } message: { Text(confirmationMessage) }
    }
    private func modelRow(_ model: ModelDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
                        Text(model.displayName).fontWeight(.medium)
                        Text("\(model.languages.joined(separator: ", ")) · \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)) · \(model.license)").font(.caption).foregroundStyle(.secondary)
                        Text(model.attribution).font(.caption2).textSelection(.enabled)
                        HStack {
                            Link("Source", destination: model.sourcePage).tint(DesignValues.accentText)
                            Spacer()
                            if let progress = library.progress, progress.modelID == model.id {
                                ProgressView(value: Double(progress.receivedBytes), total: Double(max(1, progress.totalBytes))).frame(width: 120)
                                Text(progressText(model, progress: progress)).font(.caption)
                                Button("Cancel") { library.task?.cancel() }
                            } else if library.installed?.contains(model.id) == true {
                                Text("Installed ✓"); Button("Remove") { library.remove(model) }
                            } else { Button(library.failedModelID == model.id ? "Retry" : "Download") { library.download(model) }.disabled(library.progress != nil) }
                        }
                    }.padding(.vertical, 4)
    }
    private func progressText(_ model: ModelDescriptor, progress: ModelDownloadProgress) -> String {
        let percent = Int(Double(progress.receivedBytes) / Double(max(1, progress.totalBytes)) * 100)
        let received = ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        return "Downloading \(model.displayName) · \(percent)% · \(received) of \(total)"
    }
    private var confirmationTitle: String {
        guard let model = library.confirmation.pending else { return "Download model" }
        return "Download \(model.displayName) from \(model.files.first?.url.host ?? "the publisher")?"
    }
    private var confirmationMessage: String {
        guard let model = library.confirmation.pending else { return "" }
        let total = ByteCountFormatter.string(fromByteCount: library.confirmation.totalBytes, countStyle: .file)
        return "This model is published by \(model.publisher), not by VoxClip. It downloads from the publisher (\(total)) and runs on this Mac. Licence: \(model.license). By downloading you accept the publisher's terms.\n\n\(model.attribution)"
    }
}
