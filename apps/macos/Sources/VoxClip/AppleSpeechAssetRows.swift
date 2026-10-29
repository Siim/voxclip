import SwiftUI
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor @Observable final class AppleSpeechAssetLibrary {
    enum State: Equatable { case chooseLanguage, checking, installed, needsDownload, downloading, unsupported, unavailable }
    private(set) var language = ""
    private(set) var state = State.checking
    private(set) var fraction: Double?
    private(set) var error: String?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var engine: any Transcriber
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var pendingLanguage: String?
    unowned let app: AppModel
    init(app: AppModel) {
        self.app = app
        engine = AppleSpeechTranscriber(locations: app.locations)
    }

    var statusText: String {
        let name = Locale.current.localizedString(forLanguageCode: language) ?? language
        switch state {
        case .chooseLanguage: return "Choose a language above to get Apple's speech model for it."
        case .checking: return "Checking Apple's \(name) speech model…"
        case .installed: return "Apple's \(name) speech model"
        case .needsDownload: return "Apple's \(name) speech model isn't on this Mac yet."
        case .downloading: return "Downloading Apple's \(name) speech model…"
        case .unsupported: return "Apple Speech can't transcribe \(name)."
        case .unavailable: return "Apple on-device speech isn't available on this Mac."
        }
    }

    func check(_ code: String) async {
        guard state != .downloading else { pendingLanguage = code; return }
        revision &+= 1
        let current = revision
        language = code; error = nil; fraction = nil
        guard code != "auto", !code.isEmpty else { state = .chooseLanguage; return }
        state = .checking
        let readiness = await engine.readiness(for: TranscriptionPlan(engine: .appleSpeech, language: .forced(code)))
        guard current == revision else { return }
        switch readiness {
        case .ready: state = .installed
        case .needsSystemAssets: state = .needsDownload
        case .unsupportedLanguage: state = .unsupported
        default: state = .unavailable
        }
    }

    func download() {
        guard state == .needsDownload else { return }
        revision &+= 1
        let current = revision, code = language
        state = .downloading; fraction = nil; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            let failure: String?
            do {
                try await engine.prepare(for: TranscriptionPlan(engine: .appleSpeech, language: .forced(code))) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.revision == current else { return }
                        self.fraction = value
                    }
                }
                failure = nil
            } catch is CancellationError { failure = nil } catch VoxClipError.cancelled { failure = nil } catch { failure = await app.safeError(error) }
            guard revision == current else { return }
            task = nil
            state = .needsDownload
            let nextLanguage = pendingLanguage ?? code
            pendingLanguage = nil
            if let failure, nextLanguage == code { self.error = failure } else { await check(nextLanguage) }
        }
    }
}

@MainActor struct AppleSpeechAssetRows: View {
    let app: AppModel
    private var assets: AppleSpeechAssetLibrary { app.appleSpeechAssets }
    var body: some View {
        let language = app.string("transcription.language", fallback: "auto")
        Section {
            HStack {
                Text(assets.statusText)
                Spacer()
                switch assets.state {
                case .needsDownload: Button(assets.error == nil ? "Download" : "Retry") { assets.download() }
                case .downloading:
                    ProgressView(value: assets.fraction).frame(width: 120)
                    Button("Cancel") { assets.task?.cancel() }
                case .installed: Text("Installed ✓")
                default: EmptyView()
                }
            }
            if let error = assets.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("Apple on-device speech") } footer: { Text("macOS downloads Apple's speech models from Apple and keeps them. Transcription with them stays on this Mac.") }
        .task { await assets.check(assets.language.isEmpty ? language : assets.language) }
        .onChange(of: language) { _, code in Task { await assets.check(code) } }
    }
}
