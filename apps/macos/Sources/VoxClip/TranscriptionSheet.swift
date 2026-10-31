import SwiftUI
import VoxClipCore
import VoxClipMedia

@MainActor struct TranscriptionSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var engine = "local"
    @State private var language = "auto"
    @State private var remember = true
    @State private var speakers = "off"
    @State private var keyterms = ""
    @State private var consent = TranscriptionConsentGate()
    @State private var error: String?
    @State private var prompt: TranscriptionPrompt?
    @State private var installing: TranscriptionModelInstall?
    @State private var running = false
    @State private var progress: TranscriptionProgress?
    @State private var hasCloudKey = false
    private let scribeSession: URLSession?
    #if DEBUG
    var inlineConsentForAudit = false
    #endif
    init(model: EditorModel, scribeSession: URLSession? = nil) {
        self.model = model
        self.scribeSession = scribeSession
        let selected = model.app.string("transcription.engineMode", fallback: "local")
        _engine = State(initialValue: selected == "ask" ? "local" : selected)
        _language = State(initialValue: model.project.transcript?.language ?? model.app.string("transcription.language", fallback: "auto"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe \(model.project.title ?? "video")").font(.title2)
            // A first-use download keeps the engine and language it was started for until it ends (transcription §11.3).
            Form {
                Picker("Language", selection: $language) { Text("Auto").tag("auto"); ForEach(Locale.LanguageCode.isoLanguageCodes, id: \.identifier) { code in Text(Locale.current.localizedString(forLanguageCode: code.identifier) ?? code.identifier).tag(code.identifier) } }
                Toggle("Remember for new imports", isOn: $remember)
                Picker("Engine", selection: $engine) {
                    Text("On this Mac · downloads a model on first use").tag("local")
                    Text("Apple on-device · supported languages only").tag("apple")
                    if hasCloudKey { Text("ElevenLabs Scribe · sends the audio track").tag("elevenlabs") }
                }
                if engine == "elevenlabs" {
                    DisclosureGroup("Advanced") {
                        Picker("Speakers", selection: $speakers) { Text("Off").tag("off"); Text("Auto").tag("auto"); ForEach(1...32, id: \.self) { Text("\($0)").tag(String($0)) } }
                        TextField("Keyterms, comma-separated", text: $keyterms)
                    }
                    Text("Sends the audio track to ElevenLabs, which keeps it under its terms. Estimated cost is shown by the engine when available.").font(.caption)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(running || installing != nil)
            if running { ProgressView(model.progress ?? "Reading video…", value: progress?.fraction) }
            if let prompt { promptRow(prompt) }
            if let error { InlineNotice(text: error) }
            HStack { Button("Models and keys…") { openVoxClipSettings(pane: "transcription") }; Spacer(); Button(running ? "Cancel" : "Not now") { model.workTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction); Button(error == nil && prompt == nil ? "Transcribe" : "Retry") { consent.request(engine: engine, app: model.app) { transcribe() } }.keyboardShortcut(.defaultAction).disabled(running || installing != nil).accessibilityIdentifier("transcription.start").auditButtonAction("transcription.start") }
            #if DEBUG
            if inlineConsentForAudit && consent.pending { consentSheet }
            #endif
        }.padding(24).frame(width: 560)
        .sheet(isPresented: Binding(get: { presentsConsentSheet }, set: { if !$0 { consent.cancel() } })) { consentSheet }
        .onDisappear {
            consent.cancel()
            // A publisher confirmation the sheet asked for closes with it, so its download doesn't wait on a hidden dialog.
            if model.app.modelLibrary.downloadOrigin == .transcription { model.app.modelLibrary.confirmation.respond(false) }
        }
        .onChange(of: [engine, language]) { if installing == nil { prompt = nil } }
        .modifier(ModelDownloadConfirmationDialog(library: model.app.modelLibrary, origin: .transcription))
        // A first-use download continues the local transcription it was started for when it finishes (transcription
        // §11.3); closing the sheet cancels only that continuation, and the app-owned download goes on.
        .task(id: installing?.model.id) {
            guard let request = installing else { return }
            let library = model.app.modelLibrary
            let installed = await library.install(request.model)
            guard !Task.isCancelled, installing?.model.id == request.model.id else { return }
            installing = nil
            if installed { prompt = nil }
            if request.continues(installed: installed, engine: engine, language: language) { transcribe() }
            else if !installed, library.failedModelID == request.model.id, let failure = library.error { error = failure }
        }
        .task {
            engine = model.app.string("transcription.engineMode", fallback: "local"); if engine == "ask" { engine = "local" }
            language = model.project.transcript?.language ?? model.app.string("transcription.language", fallback: "auto")
            hasCloudKey = await model.app.secrets.hasKey(for: "elevenlabs")
            if engine == "elevenlabs" && !hasCloudKey { engine = "local" }
        }
    }
    /// The callout for an engine that can't start yet, with [Download] and [Use ElevenLabs instead] for a missing
    /// model (design §13), and the download's progress and Cancel in place of those buttons while it runs.
    private func promptRow(_ prompt: TranscriptionPrompt) -> some View {
        let library = model.app.modelLibrary
        return VStack(alignment: .leading, spacing: 4) {
            InlineNotice(text: prompt.message)
            if let download = prompt.download {
                HStack {
                    if let progress = library.progress, progress.modelID == download.id {
                        ProgressView(value: Double(progress.receivedBytes), total: Double(max(1, progress.totalBytes))).frame(width: 120)
                        Text(ModelLibrary.progressText(download, progress: progress)).font(.caption)
                        Spacer()
                        Button("Cancel") { library.task?.cancel() }
                    } else {
                        Button("Download") { error = nil; installing = TranscriptionModelInstall(model: download, engine: engine, language: language) }.disabled(running || library.progress != nil)
                        if prompt.offersCloud { Button("Use ElevenLabs instead") { useElevenLabs() }.disabled(running) }
                    }
                }.padding(.horizontal, 12)
            }
        }
    }
    private func useElevenLabs() {
        engine = "elevenlabs"
        consent.request(engine: engine, app: model.app) { transcribe() }
    }
    private var presentsConsentSheet: Bool {
        #if DEBUG
        if inlineConsentForAudit { return false }
        #endif
        return consent.pending
    }
    private var consentSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe with ElevenLabs?").font(.title2)
            Text("ElevenLabs Scribe uploads this take's audio track with your key. ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. No video is sent.")
            HStack {
                Spacer()
                Button("Cancel") { consent.cancel() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("transcription.consent.cancel").auditButtonAction("transcription.consent.cancel")
                Button("Continue") { consent.approve(app: model.app) }.keyboardShortcut(.defaultAction).accessibilityIdentifier("transcription.consent.continue").auditButtonAction("transcription.consent.continue")
            }
        }.padding(24).frame(width: 480)
    }
    private func transcribe() {
        model.findTask?.cancel()
        running = true; error = nil; prompt = nil
        model.workTask = Task {
            defer { running = false; model.progress = nil; model.progressFraction = nil; model.progressStage = nil }
            do {
                let terms = keyterms.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard terms.count <= 100, !terms.contains(where: { $0.count > 50 }) else { error = "Use at most 100 keyterms, each up to 50 characters."; return }
                let adapter: any Transcriber
                switch engine {
                case "apple": adapter = AppleSpeechTranscriber()
                case "elevenlabs":
                    if let scribeSession {
                        guard let shared = model.app.shared else { throw VoxClipError.sharedResourcesMissing }
                        adapter = await ElevenLabsTranscriber(keys: model.app.secrets, settings: model.app.settings, session: scribeSession, catalog: BundledModelCatalog(shared: shared), logger: model.app.log)
                    } else {
                        adapter = await ElevenLabsTranscriber(keys: model.app.secrets, settings: model.app.settings, logger: model.app.log)
                    }
                default: adapter = WhisperCppTranscriber(logger: model.app.log)
                }
                let local = engine == "local" ? try await model.app.modelLibrary.localModel(language: language) : nil
                let plan = TranscriptionPlan(engine: adapter.engine, model: local?.id, language: language == "auto" ? .auto : .forced(language), options: TranscriptionOptions(diarize: speakers != "off", numSpeakers: Int(speakers), keyterms: terms))
                model.progress = "Reading video…"; model.progressStage = .readingVideo
                let readiness = await adapter.readiness(for: plan)
                if case .needsSystemAssets = readiness { await model.app.appleSpeechAssets.check(language) }
                if let next = TranscriptionPrompt(readiness, engine: engine, language: language, local: local, hasCloudKey: hasCloudKey) { prompt = next; return }
                if remember { model.app.set("transcription.language", .string(language)) }
                model.progress = "Extracting audio…"; model.progressStage = .extractingAudio
                let audio = try await CacheStore(locations: model.app.locations).extractAudio(sourceURL: model.sourceURL, contentKey: model.project.media.source.contentKey, durationSeconds: model.sourceDuration, using: AVAudioExtractor()) { _ in }
                let service = TranscriptionService()
                let watch = Task {
                    var announced = -1
                    var previousStage: TranscriptionStage?
                    for await value in await service.progress() {
                        guard !Task.isCancelled else { return }
                        progress = value
                        model.progressFraction = value.fraction
                        model.progressStage = value.stage == .aligning ? .aligning : .transcribing
                        let percent = Int((value.fraction ?? 0) * 100)
                        switch value.stage {
                        case .preparing: model.progress = "Preparing the speech model…"
                        case .uploading: model.progress = "Transcribing with ElevenLabs · \(percent)%"
                        case .transcribing:
                            let label = engine == "elevenlabs" ? "Transcribing with ElevenLabs" : "Transcribing on this Mac"
                            model.progress = value.fraction.map { "\(label) · \(Int($0 * 100))%" } ?? "\(label)…"
                        case .aligning: model.progress = "Aligning words…"
                        }
                        if value.stage != previousStage || percent / 10 != announced {
                            previousStage = value.stage; announced = percent / 10
                            model.announce(model.progress ?? "")
                            await model.app.log.write(LogEntry(level: .info, category: "transcribe", message: "stage=\(value.stage.rawValue) percent=\(percent)"))
                        }
                    }
                }
                defer { watch.cancel() }
                let result = try await service.transcribeResult(TranscriptionRequest(plan: plan, audio: audio.audio, contentKey: model.project.media.source.contentKey), using: adapter, envelope: audio.envelope)
                try Task.checkCancellation()
                model.replaceTranscript(result.transcript)
                if result.fromCache { model.error = "Using the earlier ElevenLabs transcript of this file (no charge)." }
                dismiss()
            } catch is CancellationError {} catch VoxClipError.cancelled {} catch { self.error = await model.app.safeError(error) }
        }
    }
}

/// A first-use model download started from the transcription sheet, with the engine and language it was started for.
struct TranscriptionModelInstall: Equatable {
    let model: ModelDescriptor
    let engine: String
    let language: String
    /// Whether the finished download goes on to transcribe by itself: only once the model is installed, and only for the
    /// local engine and language the user chose Download for. Any other engine waits for Transcribe, so an ElevenLabs
    /// upload always follows a click and its first-upload consent (transcription §11.3).
    func continues(installed: Bool, engine: String, language: String) -> Bool {
        installed && self.engine == "local" && engine == self.engine && language == self.language
    }
}

/// What the transcription sheet shows when its engine can't start yet (transcription §11.3, design §13).
struct TranscriptionPrompt: Equatable {
    let message: String
    /// The local model [Download] installs before the transcription continues.
    var download: ModelDescriptor?
    /// [Use ElevenLabs instead], offered beside Download when an ElevenLabs key exists.
    var offersCloud = false

    /// nil when the engine is ready.
    init?(_ readiness: Readiness, engine: String, language: String, local: ModelDescriptor?, hasCloudKey: Bool) {
        let name = Locale.current.localizedString(forLanguageCode: language) ?? language
        switch readiness {
        case .ready: return nil
        case .needsKey(let provider): message = "Add your \(provider == "elevenlabs" ? "ElevenLabs" : provider) key in Settings to use it."
        case .needsModels(_, let bytes):
            message = "Download the \(local?.displayName ?? "transcription") model (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) to transcribe on this Mac."
            download = local; offersCloud = local != nil && hasCloudKey
        case .needsSystemAssets: message = "Download Apple's \(name) speech model in Settings → Transcription first. Choose Models and keys… to open it."
        // Auto can't pick a model for Apple Speech, so the user chooses the language from the sheet's Language menu.
        case .unsupportedLanguage where language == "auto": message = "Which language is spoken?"
        case .unsupportedLanguage:
            let label = engine == "apple" ? "Apple Speech" : engine == "elevenlabs" ? "ElevenLabs Scribe" : "Whisper"
            message = "\(label) can't transcribe \(name)."
        case .unavailable: message = "Transcription is not available in this build (mac-speech). Your video and edits are still here."
        }
    }
}

extension EditorModel {
    func replaceTranscript(_ transcript: Transcript) {
        findTask?.cancel()
        fallbackNote = nil; focusedSuggestion = nil
        var next = project
        next.replaceTranscript(transcript)
        replace(next, name: "Transcribe video")
    }
}
