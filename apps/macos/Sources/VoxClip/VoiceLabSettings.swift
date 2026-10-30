import SwiftUI
import VoxClipCore

@MainActor struct VoiceLabSettings: View {
    @Bindable var app: AppModel
    @Bindable var session: VoiceLabSession
    @State private var confirmBeta = false
    var body: some View {
        Form {
            Section {
                Toggle("Show Voice Lab (beta)", isOn: Binding(get: { session.enabled }, set: { enabled in
                    if enabled {
                        if app.bool("voiceLab.betaNoticeAccepted") { app.set("voiceLab.enabled", .bool(true)) }
                        else { confirmBeta = true }
                    } else {
                        app.set("voiceLab.enabled", .bool(false))
                        app.speakerModelLibrary.task?.cancel(); app.speakerModelLibrary.confirmation.respond(false)
                        if !app.voiceLabSettingsVisible { app.settingsPane = "general" }
                    }
                })).disabled(session.busy || session.recorder.recording)
                Text("Voice Lab is optional. Import, cut, captions, clips and export work without it.").font(.caption)
            }
            if session.enabled {
                keySection
                SpeakerModelRows(app: app)
                voicesSection
                exportSection
                Section("Storage") {
                    Text("Consent statements stay on this Mac until you delete the voice. Training audio is discarded after upload. Local consent records keep an audit trail; they never go into project files.").font(.caption)
                    Text(app.locations.root.appendingPathComponent("VoiceLab").path).font(.caption).textSelection(.enabled)
                    Button("Reveal in Finder") { NSWorkspace.shared.open(app.locations.root.appendingPathComponent("VoiceLab")) }
                }
            }
            if let message = session.message { Section { Text(message).textSelection(.enabled).accessibilityIdentifier("voice-lab-message") } }
        }.formStyle(.grouped)
            .alert("Turn on Voice Lab?", isPresented: $confirmBeta) {
                Button("Turn on") { app.set("voiceLab.betaNoticeAccepted", .bool(true)); app.set("voiceLab.enabled", .bool(true)) }
                Button("Cancel", role: .cancel) {}
            } message: { Text(VoiceLabSession.betaCopy) }
            .sheet(isPresented: $session.showEnrollment) { CreateVoiceSheet(session: session) }
            .sheet(item: Binding(get: { session.showEnrollment ? nil : session.confirmation }, set: { session.confirmation = $0 })) { VoiceLabRequestSheet(session: session, action: $0) }
            .task(id: session.enabled) { await session.refreshEnabledState() }
    }
    private var keySection: some View {
        Section("Your API keys") {
            VoiceLabKeyRow(provider: "elevenlabs", label: "ElevenLabs", app: app)
            VoiceLabKeyRow(provider: "fal", label: "fal.ai", app: app)
            VoiceLabKeyRow(provider: "syncso", label: "sync.so", app: app)
            Text("Create a key just for VoxClip on elevenlabs.io → Developers → API keys. Allow only the permissions listed for the features you use, and set a monthly credit limit. Never enable voice-library publishing, sharing or workspace permissions for this key.").font(.caption)
            Text("My voice: create_instant_voice_clone, voices_read, voices_write, speech_to_text. Account check: user_read. Never allow create_professional_voice_clone, share_voice_externally, publish_voice_to_voice_library, workspace_*, dubbing_*, convai_*, service_account_write or create_user_api_key.").font(.caption).textSelection(.enabled)
            Button(session.busy ? "Checking…" : "Check ElevenLabs account") { session.request(.subscription) }.disabled(session.busy)
        }
    }
    private var voicesSection: some View {
        Section("My voices") {
            if session.subscription?.isNonCommercial == true { Text("Free ElevenLabs plans allow non-commercial use only.").foregroundStyle(.secondary) }
            if let message = session.planMessage { Text(message).font(.caption) }
            if session.visibleRecords.isEmpty { Text("No voice yet").foregroundStyle(.secondary) }
            ForEach(session.visibleRecords) { record in
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.voiceName).fontWeight(.medium)
                    Text("Created \(Self.createdDate(record.createdAt, shared: app.shared)) · \(record.voiceId)").font(.caption).textSelection(.enabled)
                    if record.status == .verificationRequired { Text("ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back.").font(.caption) }
                    if session.deleting.contains(record.id) { Text(session.busy ? "Deleting…" : "Couldn't finish deleting").font(.caption) }
                    Button(session.deleting.contains(record.id) ? "Retry deletion…" : "Delete voice", role: .destructive) { session.request(.delete(record.id)) }.disabled(session.busy)
                    Button("Remove from VoxClip only", role: .destructive) { session.request(.removeLocal(record.id)) }.disabled(session.busy)
                }
            }
            if session.unsavedRecord != nil {
                Button("Retry saving consent record") { Task { await session.retrySavingRecord() } }.disabled(session.busy)
                Button("Remove This Voice", role: .destructive) { Task { await session.cancelEnrollment() } }.disabled(session.busy)
            }
            ForEach(session.operations.filter { !$0.finished }) { operation in
                VStack(alignment: .leading, spacing: 5) {
                    Text(operation.kind == .create ? "Voice creation" : "Voice removal").fontWeight(.medium)
                    Text(operation.displayState).font(.caption)
                    if operation.needsCreatorRecoveryReview, operation.recoveryNeedsReview == true {
                        Button(VoiceLabSession.Request.stopLooking(operation.id).title) { session.request(.stopLooking(operation.id)) }.disabled(session.busy)
                    }
                    Button("Retry") { Task { await session.load(force: true) } }.disabled(session.busy)
                    if operation.kind == .create {
                        Button("Remove This Voice", role: .destructive) { Task { await session.withdrawOperation(operation) } }.disabled(session.busy)
                    }
                }
            }
            Button("Create Your Voice…") { session.showEnrollment = true }.disabled(session.busy || session.planMessage != nil || session.unsavedRecord != nil || !session.pendingCreations.isEmpty)
            Text(session.speakerMessage).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var exportSection: some View {
        Section("Exports and spending") {
            VoiceLabCapField(provider: "elevenlabs", label: "ElevenLabs", app: app)
            VoiceLabCapField(provider: "fal", label: "fal.ai", app: app)
            VoiceLabCapField(provider: "syncso", label: "sync.so", app: app)
            Picker("Label position", selection: app.stringBinding("voiceLab.labelPosition", fallback: "top-right")) {
                Text("Top right").tag("top-right"); Text("Top left").tag("top-left")
                Text("Bottom right").tag("bottom-right"); Text("Bottom left").tag("bottom-left")
            }
            Text("AI MODIFIED is required for synthetic exports. You can change its position, not turn it off.").font(.caption)
            Toggle("Add Content Credentials (C2PA) to exports", isOn: app.boolBinding("voiceLab.c2pa", fallback: true))
            Text("Applies to Clean-audio-only exports when the C2PA component is available. Exports that need disclosure always carry a machine-readable mark.").font(.caption)
        }
    }
    static func createdDate(_ value: String, shared: SharedResources?) -> String {
        guard let date = ISO8601DateFormatter().date(from: value), let shared,
              let text = try? VoiceConsentText(shared: shared).displayDate(date) else { return "Date unavailable" }
        return text
    }
}

@MainActor private struct VoiceLabCapField: View {
    let provider: String
    let label: String
    let app: AppModel
    @State private var amount = ""
    var body: some View {
        VStack(alignment: .leading) {
            TextField("Warn me above $___ a month · \(label)", text: $amount).onSubmit { commit() }.onAppear { amount = app.string("voiceLab.monthlyCapUsd.\(provider)") }
            Button("Save cap") { commit() }
            if let error = app.settingErrors["voiceLab.monthlyCapUsd.\(provider)"] { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private func commit() {
        let text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        app.set("voiceLab.monthlyCapUsd.\(provider)", text.isEmpty ? .null : .string(text))
    }
}

@MainActor private struct VoiceLabKeyRow: View {
    let provider: String
    let label: String
    let app: AppModel
    @State private var value = ""
    @State private var saved = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).fontWeight(.medium)
            SecureField(saved ? "Saved in Keychain; paste to replace" : "API key", text: $value).accessibilityLabel("\(label) API key")
            HStack {
                Button("Save key") {
                    Task { do { try await app.saveProviderKey(value, for: provider); value = ""; saved = true; message = "Saved in the Keychain." } catch { message = await app.safeError(error) } }
                }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved {
                    Button("Forget key") {
                        Task { do { try await app.saveProviderKey("", for: provider); value = ""; saved = false; message = nil } catch { message = await app.safeError(error) } }
                    }
                }
            }
            Text("The key stays in the macOS Keychain. No request is made when you save it.").font(.caption)
            if let message { Text(message).font(.caption) }
        }.task { saved = await app.providerKeyStore.hasKey(for: provider) }
    }
}

@MainActor private struct VoiceLabRequestSheet: View {
    @Bindable var session: VoiceLabSession
    let action: VoiceLabSession.Request
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title).font(.title2)
            Text(VoiceLabSession.providerCopy)
            switch action {
            case .subscription: Text("Reads your subscription, plan, available voice slots and pending voice verification status. No audio, video or transcript is sent. This check is free.")
            case .verify: Text("Sends only the statement recording to ElevenLabs Scribe v2. No video is sent. \(session.verificationCost)")
            case .create: Text("Checks your plan, then sends the consent recording and training audio to create your own voice. No video is sent. \(session.creationCost)")
            case .delete: Text("Deletes this voice from ElevenLabs, removes the local statement recording, and marks the local consent record deleted. Existing rendered takes stay playable and labelled. This action is free.")
            case .removeLocal: Text("Removes the local consent statement and records that the remote state is unknown. The voice may stay in your ElevenLabs account. This action is free.")
            case .stopLooking: Text("Stops recovery without deleting any voice from ElevenLabs. Records that the remote state is unknown; the voice may stay in your ElevenLabs account. This action is free.")
            }
            HStack {
                Spacer()
                if action.defaultIsCancel {
                    Button("Cancel", role: .cancel) { session.confirmation = nil }.keyboardShortcut(.defaultAction)
                    Button(action.title, role: .destructive) { Task { await session.approve(action) } }
                } else {
                    Button("Cancel", role: .cancel) { session.confirmation = nil }.keyboardShortcut(.cancelAction)
                    Button(action == .subscription ? "Continue" : action.title) { Task { await session.approve(action) } }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 500).onExitCommand { session.confirmation = nil }
    }
}

@MainActor private struct CreateVoiceSheet: View {
    @Bindable var session: VoiceLabSession
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Your Voice").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(VoiceLabSession.noticeCopy)
                    HStack { Link("ElevenLabs terms", destination: URL(string: "https://elevenlabs.io/terms-of-use")!); Link("Prohibited Use Policy", destination: URL(string: "https://elevenlabs.io/use-policy")!) }
                    attestations
                    if let statement = session.statement {
                        Text(session.verified ? "Training read-aloud · about 90 seconds" : "Read this aloud").font(.headline)
                        Text(session.verified ? session.script : statement.text).textSelection(.enabled).accessibilityIdentifier("voice-consent-teleprompter")
                        if statement.language == "et" { Text("Estonian draft — pending the user's review.").font(.caption) }
                    }
                    recordingControls
                    if let message = session.message { Text(message).textSelection(.enabled) }
                    Text(session.speakerMessage).font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                if session.unsavedRecord == nil {
                    Button("Cancel", role: .cancel) { Task { await session.cancelEnrollment() } }.keyboardShortcut(.cancelAction).disabled(session.busy)
                } else {
                    Button("Remove This Voice", role: .destructive) { Task { await session.cancelEnrollment() } }.disabled(session.busy)
                }
                if session.unsavedRecord != nil {
                    Button("Retry saving consent record") { Task { await session.retrySavingRecord() } }.disabled(session.busy)
                } else {
                    Button("Create voice…") { Task { await session.prepareCreation() } }.disabled(!session.canCreate || session.recorder.recording)
                }
            }
        }.padding(24).frame(width: 600, height: 680).interactiveDismissDisabled()
            .sheet(item: $session.confirmation) { VoiceLabRequestSheet(session: session, action: $0) }
            .onChange(of: session.recorder.recording) { wasRecording, recording in
                if wasRecording && !recording { Task { await session.finishRecording() } }
            }
    }
    private var attestations: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Display name", text: $session.displayName)
            Text("1–60 Unicode scalars; no control characters.").font(.caption)
            Toggle("This is my own voice.", isOn: $session.ownVoice)
            Toggle("I am 18 or older.", isOn: $session.adult)
            Toggle("I will use it only on videos of myself.", isOn: $session.ownVideosOnly)
        }.disabled(session.statement != nil || session.busy || session.recorder.recording)
    }
    @ViewBuilder private var recordingControls: some View {
        if session.recorder.recording {
            ProgressView(value: session.recorder.level).accessibilityLabel("Microphone level")
            Text(String(format: "%.1f seconds", session.recorder.seconds)).monospacedDigit()
            Button("Stop recording") { Task { await session.stopRecording() } }
        } else if session.verified {
            Button(session.trainingReady ? "Record training again" : "Record training read-aloud") { Task { await session.beginTraining() } }.disabled(session.busy)
        } else {
            HStack {
                Button(session.statement == nil ? "Record statement" : "Record statement again") { Task { await session.beginStatement() } }.disabled(!session.canRecord)
                Button("Verify statement · < $0.01") { session.request(.verify) }.disabled(!session.hasStatementRecording || session.busy)
            }
        }
        if session.busy { ProgressView("Working…") }
    }
}
