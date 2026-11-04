import SwiftUI
import Observation
import VoxClipCore

/// f23/f10: compact rows in the right panel. The body scrolls; actions remain in the footer.
@MainActor struct DirectorVoiceSteps: View {
    @Bindable var session: VoiceLabSession
    var model: EditorModel?
    var prepareOnAppear = true
    var changeVoice: (@MainActor () -> Void)? = nil
    @FocusState private var fieldFocused: Bool
    private var flow: VoiceEnrollmentFlow { session.flow }
    var body: some View { Group { currentVoiceStep } }
    @ViewBuilder private var currentVoiceStep: some View {
        if let model, let changing = model.voiceChange {
            VoiceChangePanel(session: changing, back: { model.closeVoiceChange() })
                .modifier(EditorPaneFocus(model: model, pane: .panel))
        } else { enrollment }
    }
    private var enrollment: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: VCTokens.spacing5) {
                    HStack {
                        Button { session.returnToRewrite() } label: { Label("Back to Rewrite", systemImage: "chevron.left") }
                            .buttonStyle(.plain)
                        Spacer()
                        Text(stepLabel).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
                    }
                    Text(headline).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("voxclip.voice.headline")
                        .columnLayoutEvidence("voice.headline", text: headline)
                    if flow.state == .firstUse { VoiceFirstUseCard(session: session, showsPrimary: false) }
                    else { enrollmentBody }
                    if flow.state != .finished { voiceChangeEntry }
                    VoiceRecoveryRows(session: session, shared: session.app.shared, inline: true)
                    if !flow.recoveryIDs.isEmpty {
                        Text("A saved voice-creation request is ready to resume. Review its audio and consent before choosing Create My Voice.")
                        ForEach(flow.recoveryIDs, id: \.self) { id in
                            Button("Resume Creation") { Task { await session.recoverVoice(id) } }.disabled(session.busy)
                        }
                    }
                    if let message = session.message {
                        Text(message).font(.system(size: 12)).textSelection(.enabled)
                            .foregroundStyle(DesignValues.color("status.warning"))
                            .accessibilityIdentifier("voxclip.voice.message")
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            footer.font(.system(size: 13, weight: .medium)).padding(16).frame(maxWidth: .infinity, alignment: .trailing)
                .columnLayoutEvidence("voice.footer")
                .overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
        }
        .font(.system(size: 12))
        .foregroundStyle(DesignValues.color("text.primary"))
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain).accessibilityLabel("Your voice, " + stepLabel)
        .accessibilityIdentifier("voxclip.voice.job")
        .modifier(EditorPaneFocus(model: model, pane: .panel))
        .onExitCommand { session.cancelVoiceAction() }
        .onKeyPress(keys: [.space], phases: [.down, .repeat]) { press in
            guard !fieldFocused, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return .ignored }
            if press.phase == .down { model?.transport(" ") }
            return .handled
        }
        .onKeyPress(keys: [.return], phases: [.down, .repeat]) { press in
            guard (!fieldFocused && !(NSApp.keyWindow?.firstResponder is NSTextView)) || press.modifiers.contains(.command) else { return .ignored }
            guard press.phase == .down else { return .handled }
            session.voicePrimary(command: press.modifiers.contains(.command))
            return .handled
        }
        .task { if prepareOnAppear { await session.prepareVoiceJob() } }
        .onDisappear { session.leaveVoiceControls(owner: model) }
        .onChange(of: session.app.speakerModelLibrary.installed) { _, installed in
            if installed { session.continueAfterDownload() }
        }
    }
    private var stepLabel: String { [.ready, .creating, .finished].contains(flow.state) ? "Beta · Step 2 of 2" : "Beta · Step 1 of 2" }
    private var headline: String {
        switch flow.state {
        case .firstUse: session.voiceNeedHeadline
        case .agree: "Find your clear speech and agree"
        case .statement: session.trainingSource == .project ? "Check your clip audio" : (session.recordingTraining ? "Read this aloud, about 90 s" : (session.recorder.recording ? "Read this aloud, in one take" : "Read the statement aloud"))
        case .checking: session.usesProjectConsent ? "Preparing your clip audio…" : "Checking it's you…"
        case .ready: "Ready to create your voice"
        case .creating: "Creating your voice…"
        case .finished: session.unsavedRecord != nil ? "Voice created · saving needs attention" : (flow.finishedRecord?.status == .verificationRequired ? "Voice created · needs verification" : "Your voice is ready.")
        }
    }
    @ViewBuilder private var enrollmentBody: some View {
        if [.agree, .statement, .checking, .ready].contains(flow.state) {
            Text(session.projectAudioLine).foregroundStyle(DesignValues.color("text.secondary"))
        }
        if session.projectAudio == .finding { ProgressView("Finding your clear speech…") }
        if session.offersProjectAudio, [.agree, .statement].contains(flow.state), !session.recorder.recording {
            Picker("Training audio", selection: Binding(get: { session.trainingSource }, set: { session.chooseTrainingSource($0) })) {
                Text(VoiceLabSession.projectChoice).tag(VoiceLabSession.TrainingSource.project).disabled(!session.projectChoiceEnabled)
                Text(VoiceLabSession.readAloudChoice).tag(VoiceLabSession.TrainingSource.readAloud)
            }.pickerStyle(.radioGroup).disabled(session.busy)
        }
        if flow.state == .agree {
            Text("AGREE").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignValues.color("text.tertiary"))
            TextField("Display name", text: $session.displayName).focused($fieldFocused)
            Toggle(VoiceLabSession.projectConsentCopy, isOn: $session.ownVoice).accessibilityIdentifier("voxclip.voice.own-consent")
            Toggle("I am 18 or older.", isOn: $session.adult)
            Toggle("I will use it only on videos of myself.", isOn: $session.ownVideosOnly)
            if session.trainingSource == .project {
                Text(VoiceLabSession.projectConsentExplanation).font(.system(size: 11))
                    .foregroundStyle(DesignValues.color("text.secondary"))
                    .accessibilityIdentifier("voxclip.voice.clip-consent")
            }
            Text(VoiceLabSession.noticeCopy).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
            Link("Terms", destination: URL(string: "https://elevenlabs.io/terms-of-use")!)
            Link("Use policy", destination: URL(string: "https://elevenlabs.io/use-policy")!)
        } else if flow.state == .statement, session.trainingSource == .project {
            Text("Your checkbox consent is confirmed. Retry the clip-audio check or choose a read-aloud.")
                .font(.system(size: 12))
            Button("Change consent or audio") { session.changeVoiceAgreement() }.disabled(session.busy)
            Button("Record a Read-Aloud") { session.useReadAloud() }.disabled(session.busy)
        } else if flow.state == .statement {
            Text("You agreed: my own voice · 18 or older · only my videos").font(.system(size: 11))
            Button("Change") { session.changeVoiceAgreement() }.disabled(session.busy || session.recorder.recording)
            Text(session.recordingTraining ? session.script : session.statement?.text ?? "Prepare a new statement, then read it before recording.")
                .font(.system(size: 13)).textSelection(.enabled).padding(12)
                .background(DesignValues.color("bg.editor"), in: .rect(cornerRadius: 6))
                .accessibilityIdentifier("voxclip.voice.statement")
            Text("Using a screen reader? Wear headphones so it isn't recorded.").font(.system(size: 11))
            if session.recorder.recording {
                ProgressView(value: session.recorder.level).accessibilityLabel("Microphone level")
                Text("Recording \(Int(session.recorder.seconds) / 60):\(String(format: "%02d", Int(session.recorder.seconds) % 60))")
                    .font(DesignValues.mono(11))
            }
            Text(session.recordingTraining ? "Read for 60 to 90 s. Nothing leaves this Mac until you choose Create My Voice." : "Stop after the last word (5 to 30 s). Nothing leaves this Mac until you choose Create My Voice.")
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
            if session.recorder.failure != nil {
                Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
            }
            if session.hasStatementRecording && !session.recorder.recording {
                Button("Play Statement", systemImage: "play.fill") { session.playStatement() }
                if session.projectMismatch || !session.projectChoiceEnabled {
                    Button("Record a Read-Aloud") { session.useReadAloud() }.disabled(session.busy)
                }
                Button("Retry Own-Voice Check") { Task { await session.prepareCreation() } }.disabled(session.busy)
            }
        } else if flow.state == .checking {
            ProgressView(session.usesProjectConsent ? "Checking the selected speech on this Mac…" : "Comparing your statement with the training audio on this Mac…")
            Text("Nothing is sent. A mismatch stops here.").font(.system(size: 11))
        } else if flow.state == .ready || flow.state == .creating {
            creationRows
        } else if flow.state == .finished {
            Label(session.unsavedRecord == nil ? "Voice created in your ElevenLabs account" : "Voice created · saving needs attention", systemImage: "person.wave.2")
            if flow.finishedRecord?.status == .verificationRequired {
                Link("Open ElevenLabs", destination: URL(string: "https://elevenlabs.io/app/voices")!)
                Text("Check verification status with ElevenLabs when you've finished there. This sends a request with your key.").font(.system(size: 11))
                Button("Check Again") { Task { await session.approve(.subscription) } }.disabled(session.busy)
            }
            if session.unsavedRecord != nil {
                Button("Retry Saving") { Task { await session.retrySavingRecord() } }.disabled(session.busy)
                Text("Remove This Voice deletes the unfinished voice from ElevenLabs and its local recording.").font(.system(size: 11))
                Button("Remove This Voice", role: .destructive) { Task { await session.cancelEnrollment() } }.disabled(session.busy)
            }
            Text("AI voice stays labelled AI MODIFIED in exports.").font(.system(size: 11))
            voiceChangeEntry
        }
    }
    @ViewBuilder private var voiceChangeEntry: some View {
        if session.unsavedRecord == nil,
           flow.finishedRecord?.status == .active || session.records.contains(where: { $0.status == .active }) {
            if let changeVoice {
                Button("Change Voice in This Video", action: changeVoice)
                    .disabled(session.busy).accessibilityIdentifier("voxclip.voice.changeInVideo")
            } else if let model {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Change this video's voice").font(.system(size: 12, weight: .medium))
                    Button("Change Selected Passage Voice") {
                        if let scope = model.voiceChangeSelection { Task { await model.openVoiceChange(scope: scope) } }
                    }.disabled(session.busy || model.voiceChangeSelection == nil)
                        .accessibilityIdentifier("voxclip.voice.changePassage")
                    Button("Change Full Take Voice") { Task { await model.openVoiceChange(scope: .fullTake) } }
                        .disabled(session.busy || model.project.edits.activeClipId != nil)
                        .accessibilityIdentifier("voxclip.voice.changeFullTake")
                    Text("Choose words for a passage, or open Full Take for the entire source. Nothing is sent until you approve an exact quote.")
                        .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
                }
            }
        }
    }
    @ViewBuilder private var creationRows: some View {
        Text("ONE CLICK DOES THIS").font(.system(size: 11, weight: .semibold))
        Label("Check your ElevenLabs plan", systemImage: flow.state == .creating ? "circle.dotted" : "circle")
        if session.usesProjectConsent {
            Label("Checkbox consent confirmed", systemImage: "checkmark")
            Label("Use the selected clip speech", systemImage: "waveform")
        } else {
            Label(flow.plan?.verificationPassed == true ? "Statement already checked" : "Check the statement matches what you read", systemImage: flow.plan?.verificationPassed == true ? "checkmark" : "circle")
        }
        Label("Create your own voice", systemImage: "person.wave.2")
        if flow.state == .creating { ProgressView(session.usesProjectConsent ? "Checking your plan and creating your voice…" : "Checking your plan, statement and creating your voice…") }
        else {
            if session.usesProjectConsent {
                Text("\(Int(flow.plan?.trainingSeconds ?? 0)) s of clip speech · consent saved")
                    .font(DesignValues.mono(11))
            } else {
                HStack(spacing: 4) {
                    Text("Statement recorded ·").font(.system(size: 11))
                    Text("\(Int(flow.statementSeconds)) s").font(DesignValues.mono(11))
                }
                Button("Play Statement", systemImage: "play.fill") { session.playStatement() }
            }
            Button("Change consent or audio") { session.changeVoiceAgreement() }
            Text(flow.plan?.verificationPassed == true ? session.recoveryCopy : session.creationCopy)
                .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
            Text(VoiceLabSession.providerCopy).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.tertiary"))
        }
    }
    @ViewBuilder private var footer: some View {
        if flow.state == .firstUse { VoiceFirstUseAction(session: session) }
        else if session.busy {
            HStack {
                ProgressView("Working…")
                if flow.state == .creating { Button("Stop") { session.cancelVoiceAction() } }
            }
        } else if flow.state == .ready {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.usesProjectConsent ? "Sends the selected clip audio to ElevenLabs with your consent. No video." : (flow.plan?.verificationPassed == true ? session.recoveryCopy : "Sends your statement and training audio to ElevenLabs. No video."))
                    .font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
                if let warning = flow.capWarning { Text(warning).font(.system(size: 11)).foregroundStyle(DesignValues.color("status.warning")) }
                Button(session.creationTitle) {
                    let event = NSApp.currentEvent
                    let keyboard = event?.type == .keyDown
                    if keyboard && event?.charactersIgnoringModifiers == " " { model?.transport(" "); return }
                    session.startVoiceCreation(keyboard: keyboard, command: event?.modifierFlags.contains(.command) == true, repeated: keyboard && event?.isARepeat == true)
                }.disabled(!session.canCreate).accessibilityIdentifier("voxclip.voice.create").columnLayoutEvidence("voice.create", text: session.creationTitle)
            }
        } else if flow.state == .finished {
            Button("Back to Rewrite") { session.returnToRewrite() }.disabled(session.unsavedRecord != nil)
        } else if flow.state == .agree {
            Button(session.agreementActionTitle) { Task { await session.continueVoiceEnrollment() } }
                .disabled(!session.canContinueEnrollment).accessibilityIdentifier("voxclip.voice.use-audio")
                .columnLayoutEvidence("voice.use-audio", text: session.agreementActionTitle)
        } else if session.recorder.recording {
            Button("Stop") { Task { await session.stopRecording() } }
        } else if flow.state == .statement, session.projectMismatch, session.trainingSource == .project {
            Button("Record a Read-Aloud") { session.useReadAloud() }
        } else if flow.state == .statement, session.trainingSource == .project {
            Button("Retry Clip Audio Check") { Task { await session.continueVoiceEnrollment() } }.disabled(!session.canContinueEnrollment)
        } else if flow.state == .statement {
            Button(session.recordingTraining ? "Record Read-Aloud" : (session.statement == nil ? "Prepare Statement" : "Record")) {
                Task { if session.recordingTraining { await session.beginTraining() } else { await session.beginStatement() } }
            }.disabled(!session.canRecord)
        }
    }
}

/// Reused in Settings: turning on and downloading have one visible approval, with the licence beside it.
@MainActor struct VoiceFirstUseCard: View {
    @Bindable var session: VoiceLabSession
    private var library: SpeakerModelLibrary { session.app.speakerModelLibrary }
    var showsPrimary = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(VoiceLabSession.betaCopy)
            if !session.flow.keyChecked { ProgressView("Checking for your ElevenLabs key…") }
            else if !session.flow.keyReady {
                Text("FIRST, YOUR ELEVENLABS KEY").font(.system(size: 11, weight: .semibold))
                Text("Your voice is made and spoken by ElevenLabs, with your own key. Create a key just for VoxClip with a monthly credit limit.")
                SecureField("ElevenLabs API key", text: Binding(get: { session.flow.keyDraft }, set: { session.flow.keyDraft = $0 }))
                Link("Make a restricted key ›", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                Text("Saved in the macOS Keychain and used only by VoxClip for Voice Lab. Never passed to Claude Code, Codex or any other AI app. Saving makes no request.").font(.system(size: 11))
            } else {
                Text("ONE CLICK DOES THIS").font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: VCTokens.spacingGroupGap) {
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
                } else {
                    if let model = library.model { Link("Source page", destination: model.sourcePage) }
                }
                if let message = library.message { Text(message).foregroundStyle(DesignValues.color("status.warning")) }
            }
            if showsPrimary { VoiceFirstUseAction(session: session) }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kept beside the licence in Settings, pinned below the scroll body in the Voice job.
@MainActor private struct VoiceFirstUseAction: View {
    @Bindable var session: VoiceLabSession
    private var library: SpeakerModelLibrary { session.app.speakerModelLibrary }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.flow.keyReady, !library.installed, library.progress == nil, library.model != nil {
                Text(library.downloadLicence).font(.system(size: 11)).foregroundStyle(DesignValues.color("text.secondary"))
            }
            if !session.flow.keyChecked { ProgressView("Checking key…") }
            else if !session.flow.keyReady {
                Button("Save Key") { Task { await session.saveVoiceKey() } }
                    .disabled(session.flow.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.busy)
            } else if library.progress != nil { Button("Cancel") { library.cancelDownload() } }
            else {
                Button(library.message == nil ? (session.enabled ? (library.installed ? "Continue" : "Download and Continue") : "Turn On Voice Lab") : "Retry Download") { session.turnOnVoiceJob() }
                    .disabled(session.busy || library.model == nil)
            }
        }
    }
}
