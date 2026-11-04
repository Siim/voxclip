import AppKit
import SwiftUI
import VoxClipCore

/// v5 f20–f21/f25: buffer content on the transcript's text column; no card, ring, fill or corner radius.
@MainActor struct InlineTranscriptionView: View {
    @Bindable var transcription: InlineTranscription
    @FocusState private var cancelFocused: Bool
    @FocusState private var keyFocused: Bool
    private var model: EditorModel { transcription.model }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if transcription.phase == .folded { folded }
            else if transcription.isRunning { running }
            else if transcription.phase == .choosing { choices }
            if let note = transcription.cancelledNote, transcription.phase != .running {
                bufferLine("info.circle", text: note).padding(.top, 8)
            }
        }
        .font(.system(size: 12)).foregroundStyle(DesignValues.color("text.primary"))
        .padding(.top, transcription.again ? 20 : 24).padding(.bottom, 18).padding(.trailing, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain).accessibilityLabel(transcription.title)
        .accessibilityIdentifier("voxclip.inline.transcription")
        .onAppear { if transcription.again { cancelFocused = true } }
        .onChange(of: downloadDecile) { _, value in
            if let value { model.announce("Downloading speech model · \(value * 10)%") }
        }
        .onChange(of: transcription.again) { _, again in if again { cancelFocused = true } }
        .onChange(of: [transcription.engine, transcription.language, transcription.modelID, transcription.keyterms]) { transcription.choicesChanged() }
        .onExitCommand { if transcription.isDownloading { transcription.cancelDownload() } else if transcription.isRunning { transcription.cancel() } else { transcription.notNow() } }
        .onKeyPress(keys: [.space]) { press in
            guard !keyFocused, press.modifiers.isEmpty else { return .ignored }
            let editor: EditorModel = model
            editor.transport(" ")
            return .handled
        }
        .onKeyPress(keys: [.return], phases: [.down, .repeat]) { press in
            guard !keyFocused, press.modifiers.contains(.command) else { return .ignored }
            transcription.pressReturn(timestamp: NSApp.currentEvent?.timestamp ?? 0, now: ProcessInfo.processInfo.systemUptime,
                repeatKey: press.phase == .repeat, command: true)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "."), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if transcription.isDownloading { transcription.cancelDownload() } else if transcription.isRunning { transcription.cancel() }
            return .handled
        }
    }
    private var choices: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            if transcription.again {
                bufferLine("exclamationmark.triangle", text: transcription.warning)
                    .padding(.top, VCTokens.spacingGroupGap)
                detail("Clips and cuts belong to the old words, so they can't carry over. Your exports stay.").padding(.top, VCTokens.spacing2)
            } else { detail("This video isn't transcribed yet. It plays while you \(transcription.isDownloading ? "wait" : "choose").").padding(.top, VCTokens.spacing2) }
            languageRow.padding(.top, VCTokens.spacingSectionGap)
            engineRows.padding(.top, VCTokens.spacingLabelGap)
            if transcription.isDownloading { downloadRow.padding(.top, VCTokens.spacingGroupGap) }
            Divider().overlay(DesignValues.color("line.default")).padding(.leading, 80).padding(.top, VCTokens.spacing5).padding(.bottom, VCTokens.spacingGroupGap)
            if !(transcription.again && !transcription.againConfirmed && !transcription.needsDownload && !transcription.paid) {
                bufferLine(transcription.error != nil ? "exclamationmark.triangle" : transcription.paid ? "arrow.up" : transcription.isDownloading ? "clock" : "arrow.down", text: transcription.sendLine)
                detail(transcription.sendDetail).padding(.top, VCTokens.spacing2)
                if let kept = transcription.keptDownloadCopy { detail(kept).padding(.top, VCTokens.spacing2) }
                if transcription.needsDownload && !transcription.paid, let item = transcription.selectedModel {
                    Link("Source page", destination: item.sourcePage).font(.system(size: 11)).padding(.leading, 80).padding(.top, VCTokens.spacing2)
                }
            }
            if !transcription.isDownloading || transcription.paid { actions.padding(.top, VCTokens.spacingGroupGap) }

        }
    }
    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 17) {
            Image(systemName: transcription.again ? "arrow.clockwise" : "captions.bubble")
                .font(.system(size: 13)).frame(width: 14)
                .foregroundStyle(DesignValues.color("text.tertiary")).accessibilityHidden(true)
            Text(transcription.title).font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Text("\(durationLabel(model.sourceDuration)) · \(URL(fileURLWithPath: model.project.media.source.absolutePath).lastPathComponent)")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).lineLimit(1).truncationMode(.middle)
        }.padding(.leading, 49)
    }
    private var languageRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { languagePicker; Spacer(minLength: 0); remember }
            VStack(alignment: .leading, spacing: 6) { languagePicker; remember.padding(.leading, 88) }
        }.padding(.leading, 80)
    }
    private var languagePicker: some View {
        HStack(spacing: 0) {
            Text("Language").foregroundStyle(DesignValues.color("text.tertiary")).frame(width: 88, alignment: .leading)
            Picker("Language", selection: $transcription.language) {
                Text("Auto").tag("auto")
                ForEach(languageCodes, id: \.self) { code in
                    Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                }
            }.labelsHidden().fixedSize().accessibilityLabel("Language")
        }.frame(minHeight: 26)
    }
    private var languageCodes: [String] {
        let recent: [String] = if case .array(let values) = model.app.settings.values["transcription.recentLanguages"] { values.compactMap { if case .string(let value) = $0 { value } else { nil } } } else { [] }
        let all = Locale.LanguageCode.isoLanguageCodes.map(\.identifier).sorted { (Locale.current.localizedString(forLanguageCode: $0) ?? $0) < (Locale.current.localizedString(forLanguageCode: $1) ?? $1) }
        return recent + all.filter { !recent.contains($0) }
    }
    private var remember: some View {
        Toggle("Remember for new imports", isOn: $transcription.remember)
            .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).fixedSize()
    }
    private var engineRows: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Engine").foregroundStyle(DesignValues.color("text.tertiary")).frame(width: 88, height: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Picker("Engine", selection: $transcription.engine) {
                    engineLabel("Apple Speech", fact: "On this Mac · free").tag("apple")
                    engineLabel("On this Mac", fact: localFact).tag("local")
                    engineLabel("ElevenLabs Scribe", fact: "\(transcription.hasKey ? "Your key · " : "Needs your key · ")\(transcription.price)").tag("elevenlabs")
                }.pickerStyle(.radioGroup).labelsHidden().controlSize(.small).accessibilityLabel("Engine").help(transcription.paid ? transcription.sendLine : "Transcribes on this Mac. Nothing leaves this Mac.")
                if transcription.engine == "local" {
                    Picker("Whisper model", selection: $transcription.modelID) {
                        Text(transcription.selectedModel?.displayName ?? "Recommended Whisper model").tag("")
                        ForEach(model.app.modelLibrary.models.filter { $0.engine == .whispercpp }, id: \.id) { Text($0.displayName).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 240).padding(.leading, 23).accessibilityLabel("Whisper model")
                }
                if transcription.paid { cloudOptions.padding(.leading, 23) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.leading, 80)
    }
    private var localFact: String {
        guard let item = transcription.selectedModel else { return "Free · local model" }
        return model.app.modelLibrary.installed?.contains(item.id) == true ? "Installed · free" : "Free · \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)) download"
    }
    private func engineLabel(_ title: String, fact: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 0)
            Text(fact).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
        }.frame(minHeight: 26)
    }
    private var cloudOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !transcription.hasKey {
                HStack {
                    SecureField("Paste your ElevenLabs API key", text: $transcription.key).textFieldStyle(.roundedBorder)
                        .focused($keyFocused).onSubmit { Task { await transcription.saveKey() } }
                    Button(transcription.savingKey ? "Saving…" : "Save Key") { Task { await transcription.saveKey() } }
                        .disabled(transcription.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcription.savingKey)
                        .accessibilityIdentifier("transcription.saveKey")
                }
                Link("Make a restricted key ›", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                Text("Saved in the macOS Keychain. Saving makes no request.").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            DisclosureGroup("Speakers and key terms") {
                Picker("Speakers", selection: $transcription.speakers) {
                    Text("Off").tag("off"); Text("Auto").tag("auto")
                    ForEach(1...32, id: \.self) { Text("\($0)").tag(String($0)) }
                }
                TextField("Keyterms, comma-separated", text: $transcription.keyterms).textFieldStyle(.roundedBorder)
                if !transcription.terms.isEmpty { Text("Key terms add \(Int(transcription.keytermsSurcharge * 100))% to the estimate.").font(.system(size: 11)) }
            }
        }.padding(.vertical, 4)
    }
    private var downloadRow: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            HStack {
                if let progress = transcription.downloadProgress {
                    let percent = Int(Double(progress.receivedBytes) / Double(max(1, progress.totalBytes)) * 100)
                    Text("Downloading · \(percent)%")
                    Spacer()
                    Button("Cancel") { transcription.cancelDownload() }.buttonStyle(.plain)
                    ProgressView(value: Double(progress.receivedBytes), total: Double(max(1, progress.totalBytes))).frame(width: 100)
                } else { Text("Downloading Apple's \(transcription.languageName) speech model…"); Button("Cancel") { transcription.cancelDownload() } }
            }
            if let item = transcription.installing, let progress = transcription.downloadProgress {
                Text(ModelLibrary.progressText(item, progress: progress) + (transcription.downloadRemaining.map { " · " + $0 } ?? "")).font(.system(size: 11))
                Text("From \(item.files.first?.url.host ?? "the publisher") · published by \(item.publisher), not by VoxClip · \(item.license)")
                    .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
            }
        }.padding(.leading, 191).accessibilityLabel("Downloading speech model").accessibilityValue(downloadValue)
    }
    private var downloadDecile: Int? {
        guard let progress = transcription.downloadProgress else { return nil }
        return Int(Double(progress.receivedBytes) / Double(max(1, progress.totalBytes)) * 10)
    }
    private var downloadValue: String {
        guard let progress = transcription.downloadProgress else { return "In progress" }
        return "\(Int(Double(progress.receivedBytes) / Double(max(1, progress.totalBytes)) * 100)) percent, \(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))"
    }
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { buttons; Spacer(minLength: 0); actionNote }
            VStack(alignment: .leading, spacing: 8) { HStack(spacing: 12) { buttons }; actionNote }
        }.padding(.leading, 80)
    }
    @ViewBuilder private var buttons: some View {
        if transcription.canStart || transcription.paid {
            InlinePrimaryButton(title: transcription.primaryTitle, accented: !(transcription.again && !transcription.againConfirmed),
                help: transcription.paid && !transcription.hasKey ? "Save your ElevenLabs API key to enable transcription." : transcription.again && !transcription.againConfirmed ? transcription.warning : transcription.sendLine,
                action: { transcription.activate() }, keyAction: { event in
                    transcription.pressReturn(timestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime,
                        repeatKey: event.isARepeat, command: event.modifierFlags.contains(.command), focusedPrimary: true)
                }, spaceAction: {
                    if transcription.again && !transcription.paid { transcription.activate() }
                    else { model.transport(" ") }
                })
                .disabled(!transcription.canStart)
                .accessibilityIdentifier("transcription.start").auditButtonAction("transcription.start")
        }
        Button(transcription.cancelTitle) { transcription.notNow() }.buttonStyle(.plain).focused($cancelFocused)
            .accessibilityIdentifier("transcription.notNow").auditButtonAction("transcription.notNow")
    }
    private var actionNote: some View {
        Text(transcription.paid ? !transcription.hasKey ? "Paste your ElevenLabs key above, then choose Save Key." : "\(durationLabel(model.sourceDuration)) at \(transcription.rate.map { InlineTranscription.money($0) } ?? "an unknown rate") an hour" : "Free. Nothing leaves this Mac.")
            .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
    }
    private var folded: some View {
        HStack(spacing: VCTokens.spacingRowGap) {
            Text("This video isn't transcribed yet.")
            Button("Transcribe…") { Task { await transcription.open() } }.buttonStyle(.plain)
        }.padding(.leading, 80)
    }
    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            bufferLine("waveform", text: model.progress ?? "Reading video…", spinning: true)
            detail("\(transcription.languageName) · \(durationLabel(model.sourceDuration)). The video plays while you wait.")
            ProgressView(value: transcription.overallFraction).padding(.leading, 80)
            ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, text in
                bufferLine(index < transcription.runStage ? "checkmark" : "circle", text: text,
                    spinning: index == transcription.runStage)
            }
            if transcription.paid {
                bufferLine("arrow.up", text: "\(transcription.price) to your ElevenLabs key.")
                detail(transcription.cancelCopy)
                if let fraction = transcription.progress?.fraction, transcription.progress?.stage == .uploading {
                    let total = model.sourceDuration * 32_000
                    detail("\(ByteCountFormatter.string(fromByteCount: Int64(total * fraction), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)) · with your key · no video frames")
                }
            }
            HStack { Button("Cancel") { transcription.cancel() }.buttonStyle(.plain).help(transcription.cancelCopy); Spacer(); Text("Esc or ⌘.").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")) }.padding(.leading, 80)
            ForEach(0..<6) { index in
                Rectangle().fill(DesignValues.color("bg.muted")).frame(maxWidth: index.isMultiple(of: 2) ? 440 : 340).frame(height: 12).padding(.leading, 80).padding(.top, 6).accessibilityHidden(true)
            }
        }
    }
    private var stepTitles: [String] {
        transcription.paid ? ["Read the video", "Extract the audio", "Upload to ElevenLabs", "ElevenLabs writes the words", "Align the words on this Mac"] : ["Read the video", "Extract the audio", "Transcribe on this Mac", "Align the words"]
    }
    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary")).padding(.leading, 80)
    }
    private func bufferLine(_ glyph: String, text: String, spinning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 17) {
            Group { if spinning { ProgressView().controlSize(.mini) } else { Image(systemName: glyph).font(.system(size: 13)) } }
                .frame(width: 14).foregroundStyle(DesignValues.color("text.tertiary")).accessibilityHidden(true)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.leading, 49)
    }
}
