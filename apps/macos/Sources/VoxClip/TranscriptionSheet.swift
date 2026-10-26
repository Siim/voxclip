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
    @State private var showCloudConsent = false
    @State private var error: String?
    @State private var running = false
    @State private var progress: TranscriptionProgress?
    @State private var hasCloudKey = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe \(model.project.title ?? "video")").font(.title2)
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
            }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(running)
            if running { ProgressView(model.progress ?? "Reading video…", value: progress?.fraction) }
            if let error { InlineNotice(text: error) }
            HStack { Button("Models and keys…") { openVoxClipSettings() }; Spacer(); Button(running ? "Cancel" : "Not now") { model.workTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction); Button(error == nil ? "Transcribe" : "Retry") { if engine == "elevenlabs" && !model.app.bool("transcription.cloudConsent.elevenlabs") { showCloudConsent = true } else { transcribe() } }.keyboardShortcut(.defaultAction).disabled(running) }
        }.padding(24).frame(width: 560)
        .sheet(isPresented: $showCloudConsent) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Transcribe with ElevenLabs?").font(.title2)
                Text("ElevenLabs Scribe uploads this take's audio track with your key. ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. No video is sent.")
                HStack { Spacer(); Button("Cancel") { showCloudConsent = false }.keyboardShortcut(.cancelAction); Button("Continue") { model.app.set("transcription.cloudConsent.elevenlabs", .bool(true)); showCloudConsent = false; transcribe() }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 480)
        }
        .task {
            engine = model.app.string("transcription.engineMode", fallback: "local"); if engine == "ask" { engine = "local" }
            language = model.project.transcript?.language ?? model.app.string("transcription.language", fallback: "auto")
            hasCloudKey = await model.app.secrets.hasKey(for: "elevenlabs")
            if engine == "elevenlabs" && !hasCloudKey { engine = "local" }
        }
    }
    private func transcribe() {
        model.findTask?.cancel()
        running = true; error = nil
        model.workTask = Task {
            defer { running = false; model.progress = nil }
            do {
                let terms = keyterms.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard terms.count <= 100, !terms.contains(where: { $0.count > 50 }) else { error = "Use at most 100 keyterms, each up to 50 characters."; return }
                let adapter: any Transcriber
                switch engine { case "apple": adapter = AppleSpeechTranscriber(); case "elevenlabs": adapter = await ElevenLabsTranscriber(keys: model.app.secrets, settings: model.app.settings, logger: model.app.log); default: adapter = WhisperCppTranscriber(logger: model.app.log) }
                let local = engine == "local" ? try await model.app.modelLibrary.localModel(language: language) : nil
                let plan = TranscriptionPlan(engine: adapter.engine, model: local?.id, language: language == "auto" ? .auto : .forced(language), options: TranscriptionOptions(diarize: speakers != "off", numSpeakers: Int(speakers), keyterms: terms))
                model.progress = "Reading video…"
                switch await adapter.readiness(for: plan) {
                case .ready: break
                case .needsKey(let provider): error = "Add your \(provider == "elevenlabs" ? "ElevenLabs" : provider) key in Settings to use it."; return
                case .needsModels(_, let bytes): error = "Download the \(local?.displayName ?? "transcription") model (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) to transcribe on this Mac."; return
                case .needsSystemAssets: error = "Apple speech assets need to download before transcription. Use Settings to prepare the selected language."; return
                case .unsupportedLanguage:
                    let label = engine == "apple" ? "Apple Speech" : engine == "elevenlabs" ? "ElevenLabs Scribe" : "Whisper"
                    error = "\(label) can't transcribe \(Locale.current.localizedString(forLanguageCode: language) ?? language)."; return
                case .unavailable: error = "Transcription is not available in this build (mac-speech). Your video and edits are still here."; return
                }
                if remember { model.app.set("transcription.language", .string(language)) }
                model.progress = "Extracting audio…"
                let audio = try await AVAudioExtractor().extract(AudioExtractionRequest(sourceURL: model.sourceURL, contentKey: model.project.media.source.contentKey, durationSeconds: model.sourceDuration, cacheDirectory: model.app.locations.cache)) { _ in }
                let service = TranscriptionService()
                let watch = Task {
                    var announced = -1
                    var previousStage: TranscriptionStage?
                    for await value in await service.progress() {
                        guard !Task.isCancelled else { return }
                        progress = value
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

extension EditorModel {
    func replaceTranscript(_ transcript: Transcript) {
        findTask?.cancel()
        clipAnswer = nil
        var next = project
        next.replaceTranscript(transcript)
        replace(next, name: "Transcribe video")
    }
}
