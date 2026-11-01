import SwiftUI
import Observation
import VoxClipCore

/// f23/f10: compact rows in the right panel. The body scrolls; actions remain in the footer.
@MainActor struct DirectorVoiceSteps: View {
    @Bindable var session: VoiceLabSession
    var model: EditorModel?
    @FocusState private var fieldFocused: Bool
    @State private var holds = false
    private var flow: VoiceEnrollmentFlow { session.flow }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Button { session.returnToRewrite() } label: { Label("Back to Rewrite", systemImage: "chevron.left") }
                            .buttonStyle(.plain)
                        Spacer()
                        Text("Beta · Step 1 of 2").font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
                    }
                    Text(headline).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("voxclip.voice.headline")
                    if flow.state == .firstUse { VoiceFirstUseCard(session: session) }
                    else { enrollmentBody }
                    if let message = session.message {
                        Text(message).font(.system(size: 12)).textSelection(.enabled)
                            .foregroundStyle(DesignValues.color("status.warning"))
                            .accessibilityIdentifier("voxclip.voice.message")
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            footer.padding(16).frame(maxWidth: .infinity, alignment: .trailing)
                .overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
        }
        .font(.system(size: 12))
        .foregroundStyle(DesignValues.color("text.primary"))
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain).accessibilityLabel("Your voice, Step 1 of 2")
        .accessibilityIdentifier("voxclip.voice.job")
        .modifier(EditorPaneFocus(model: model, pane: .panel, holds: $holds))
        .onExitCommand { session.cancelVoiceAction() }
        .onKeyPress(keys: [.space], phases: [.down, .repeat]) { press in
            guard !fieldFocused, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return .ignored }
            if press.phase == .down { model?.transport(" ") }
            return .handled
        }
        .onKeyPress(keys: [.return], phases: [.down, .repeat]) { press in
            guard !fieldFocused || press.modifiers.contains(.command) else { return .ignored }
            guard press.phase == .down else { return .handled }
            session.voicePrimary(command: press.modifiers.contains(.command))
            return .handled
        }
        .task { await session.prepareVoiceJob() }
        .onChange(of: session.recorder.recording) { was, recording in
            if was && !recording { Task { await session.finishRecording() } }
        }
        .onChange(of: session.app.speakerModelLibrary.installed) { _, installed in
            if installed { session.continueAfterDownload() }
        }
    }
    private var headline: String {
        switch flow.state {
        case .firstUse: session.voiceNeedHeadline
        case .agree: "Find your clear speech and agree"
        case .statement: session.recorder.recording ? "Read this aloud, in one take" : "Read the statement aloud"
        case .checking: "Checking it's you…"
        case .ready: "Statement recorded"
        case .creating: "Creating your voice…"
        case .finished: "Your voice is ready."
        }
    }
    @ViewBuilder private var enrollmentBody: some View {
        Text(session.projectAudioLine).foregroundStyle(DesignValues.color("text.secondary"))
        if session.projectAudio == .finding { ProgressView("Finding your clear speech…") }
        if flow.state == .agree {
            Text("AGREE").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignValues.color("text.tertiary"))
            TextField("Display name", text: $session.displayName).focused($fieldFocused)
            Toggle("This is my own voice.", isOn: $session.ownVoice)
            Toggle("I am 18 or older.", isOn: $session.adult)
            Toggle("I will use it only on videos of myself.", isOn: $session.ownVideosOnly)
            Text(VoiceLabSession.noticeCopy).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
            Link("Terms", destination: URL(string: "https://elevenlabs.io/terms-of-use")!)
            Link("Use policy", destination: URL(string: "https://elevenlabs.io/use-policy")!)
        } else if flow.state == .statement {
            Text("You agreed: my own voice · 18 or older · only my videos").font(.system(size: 11))
            Button("Change") { session.changeVoiceAgreement() }.disabled(session.busy || session.recorder.recording)
            Text(session.recordingTraining ? session.script : session.statement?.text ?? "Preparing your statement…")
                .font(.system(size: 13)).textSelection(.enabled).padding(12)
                .background(DesignValues.color("bg.editor"), in: .rect(cornerRadius: 6))
                .accessibilityIdentifier("voxclip.voice.statement")
            Text("Using a screen reader? Wear headphones so it isn't recorded.").font(.system(size: 11))
            if session.recorder.recording {
                ProgressView(value: session.recorder.level).accessibilityLabel("Microphone level")
                Text("Recording \(Int(session.recorder.seconds) / 60):\(String(format: "%02d", Int(session.recorder.seconds) % 60))")
                    .font(DesignValues.mono(11))
            }
            Text("Stop after the last word (5 to 30 s). Nothing leaves this Mac until you choose Create My Voice.")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
            if session.recorder.failure != nil {
                Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
            }
        } else {
            Text("Statement recorded and kept on this Mac. Nothing was sent.")
        }
    }
    @ViewBuilder private var footer: some View {
        if flow.state == .firstUse { EmptyView() } // first use owns its licence and adjacent action
        else if session.busy { ProgressView("Working…") }
        else if flow.state == .agree {
            Button("Read the Statement") { Task { await session.prepareVoiceStatement() } }.disabled(!session.canRecord)
        } else if session.recorder.recording {
            Button("Stop") { Task { await session.stopRecording() } }
        } else if flow.state == .statement {
            Button(session.recordingTraining ? "Record Read-Aloud" : "Record") {
                Task { if session.recordingTraining { await session.beginTraining() } else { await session.beginStatement() } }
            }.disabled(!session.canRecord)
        }
    }
}

/// Reused in Settings: turning on and downloading have one visible approval, with the licence beside it.
@MainActor struct VoiceFirstUseCard: View {
    @Bindable var session: VoiceLabSession
    private var library: SpeakerModelLibrary { session.app.speakerModelLibrary }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice Lab can create a copy of your own voice and re-voice words you rewrite. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key.")
            if !session.flow.keyChecked { ProgressView("Checking for your ElevenLabs key…") }
            else if !session.flow.keyReady {
                Text("FIRST, YOUR ELEVENLABS KEY").font(.system(size: 11, weight: .semibold))
                Text("Your voice is made and spoken by ElevenLabs, with your own key. Create a key just for VoxClip with a monthly credit limit.")
                SecureField("ElevenLabs API key", text: Binding(get: { session.flow.keyDraft }, set: { session.flow.keyDraft = $0 }))
                Link("Make a restricted key ›", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                Text("Saved in the macOS Keychain and used only by VoxClip for Voice Lab. Never passed to Claude Code, Codex or any other AI app. Saving makes no request.").font(.system(size: 11))
                Button("Save Key") { Task { await session.saveVoiceKey() } }.disabled(session.flow.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.busy)
            } else {
                Text("ONE CLICK DOES THIS").font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 10) {
                    Label(session.enabled ? "Voice Lab is on" : "Turn on Voice Lab", systemImage: session.enabled ? "checkmark" : "circle")
                    Text("Turn it off any time in Settings.").font(.system(size: 11))
                    Label(library.installed ? "Own-voice check installed" : "Download the own-voice check", systemImage: library.installed ? "checkmark" : "circle")
                    if let model = library.model {
                        Text("\(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)) · \(model.license) · published by \(model.publisher) on \(model.files.first?.url.host ?? "the publisher"), not by VoxClip").font(.system(size: 11))
                    }
                    Label("Find your clear speech in this video", systemImage: "circle")
                    Text("On this Mac. Nothing is sent.").font(.system(size: 11))
                }.accessibilityElement(children: .contain).accessibilityLabel("One click does this, 3 steps")
                Text("Then you agree and read a short statement aloud. Nothing is sent until Create My Voice. The free changes work without Voice Lab.").font(.system(size: 11))
                if let progress = library.progress {
                    ProgressView(value: Double(progress.receivedBytes), total: Double(max(1, progress.totalBytes)))
                    Text(progress.verifying ? "Verifying download…" : "Downloading \(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                    Button("Cancel") { library.cancelDownload() }
                } else {
                    if !library.installed { Text(library.downloadLicence).font(.system(size: 11)) }
                    if let model = library.model { Link("Source page", destination: model.sourcePage) }
                    Button(library.message == nil ? (session.enabled ? "Download and Continue" : "Turn On Voice Lab") : "Retry Download") { session.turnOnVoiceJob() }
                        .disabled(session.busy || library.model == nil)
                }
                if let message = library.message { Text(message).foregroundStyle(DesignValues.color("status.warning")) }
            }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
