import SwiftUI
import VoxClipCore
import VoxClipMedia

/// fal.ai's key and spending rows show while lip sync through fal.ai is wired into Rewrite (user, 2026-11-03).
/// sync.so's rows return with its client when lip sync ships (M3+). Stored keys and caps remain intact.
enum LipSyncAvailability {
    static let shipped = false
    static var settingsProviders: [(id: String, label: String)] {
        [("elevenlabs", "ElevenLabs"), ("fal", "fal.ai")] + (shipped ? [("syncso", "sync.so")] : [])
    }
}

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
                        app.speakerModelLibrary.cancelDownload()
                        if !app.voiceLabSettingsVisible { app.settingsPane = "general" }
                    }
                })).disabled(session.busy || session.recorder.recording)
                Text("Voice Lab is optional. Import, cut, captions, clips and export work without it.").font(.caption)
            }
            if confirmBeta {
                Section("Turn on Voice Lab") { VoiceFirstUseCard(session: session) }
                    .task { await session.prepareVoiceJob() }
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
            .onExitCommand { confirmBeta = false }
            .sheet(item: Binding(get: { session.confirmation }, set: { session.confirmation = $0 })) { VoiceLabRequestSheet(session: session, action: $0, shared: app.shared) }
            .task(id: session.enabled) { await session.refreshEnabledState() }
    }
    private var keySection: some View {
        Section("Your API keys") {
            ForEach(LipSyncAvailability.settingsProviders, id: \.id) { provider in
                VoiceLabKeyRow(provider: provider.id, label: provider.label, app: app)
            }
            Text("Create a key just for VoxClip on elevenlabs.io → Developers → API keys. Allow only the permissions listed for the features you use, and set a monthly credit limit. Never enable voice-library publishing, sharing or workspace permissions for this key.").font(.caption)
            Text("My voice: create_instant_voice_clone, voices_read, voices_write, speech_to_text. Account check: user_read. Never allow create_professional_voice_clone, share_voice_externally, publish_voice_to_voice_library, workspace_*, dubbing_*, convai_*, service_account_write or create_user_api_key.").font(.caption).textSelection(.enabled)
            Button(session.busy ? "Checking…" : "Check ElevenLabs account") { session.request(.subscription) }.disabled(session.busy)
        }
    }
    private var voicesSection: some View {
        let records = session.visibleRecords + (session.unsavedRecord.map { [$0] } ?? [])
        let operations = session.operations.filter { !$0.finished }
        let contexts = Self.accessibilityContexts(records: records, operations: operations, shared: app.shared)
        return Section("My voices") {
            if session.subscription?.isNonCommercial == true { Text("Free ElevenLabs plans allow non-commercial use only.").foregroundStyle(.secondary) }
            if let message = session.planMessage { Text(message).font(.caption) }
            if session.visibleRecords.isEmpty { Text("No voice yet").foregroundStyle(.secondary) }
            ForEach(session.visibleRecords) { record in
                let context = contexts["record-\(record.id)", default: ""]
                VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
                    Text(record.voiceName).fontWeight(.medium)
                    Text("Created \(Self.createdDate(record.createdAt, shared: app.shared)) · \(record.voiceId)").font(.caption).textSelection(.enabled)
                    if record.status == .verificationRequired { Text("ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back.").font(.caption) }
                    if record.status == .active {
                        VoiceReferenceRows(session: session, record: record, context: context)
                        VoiceRebuildRows(session: session, state: session.rebuilds[record.id], record: record, context: context)
                    }
                    if session.deleting.contains(record.id) { Text(session.busy ? "Deleting…" : "Couldn't finish deleting").font(.caption) }
                    Button(session.deleting.contains(record.id) ? "Retry deletion…" : "Delete voice", role: .destructive) { session.request(.delete(record.id)) }.disabled(session.busy)
                        .accessibilityLabel(Self.actionAccessibilityLabel(session.deleting.contains(record.id) ? "Retry deletion" : "Delete voice", context: context))
                    Button("Remove from VoxClip only", role: .destructive) { session.request(.removeLocal(record.id)) }.disabled(session.busy)
                        .accessibilityLabel(Self.actionAccessibilityLabel("Remove from VoxClip only", context: context))
                }
            }
            if let record = session.unsavedRecord {
                let context = contexts["record-\(record.id)", default: ""]
                Button("Retry saving consent record") { Task { await session.retrySavingRecord() } }.disabled(session.busy)
                    .accessibilityLabel(Self.actionAccessibilityLabel("Retry saving consent record", context: context))
                Button("Remove This Voice", role: .destructive) { Task { await session.cancelEnrollment() } }.disabled(session.busy)
                    .accessibilityLabel(Self.actionAccessibilityLabel("Remove unfinished voice", context: context))
            }
            VoiceRecoveryRows(session: session, shared: app.shared)
            if session.records.contains(where: { $0.status == .active && $0.projectConsent != nil }) { VideoVoiceRows(session: session) }
            Text("Make your voice from Rewrite when a phrase needs it.").font(.caption)
            Text(session.speakerMessage).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var exportSection: some View {
        Section("Exports and spending") {
            ForEach(LipSyncAvailability.settingsProviders, id: \.id) { provider in
                VoiceLabCapField(provider: provider.id, label: provider.label, app: app)
            }
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
    static func accessibilityContexts(records: [VoiceConsentRecord], operations: [VoiceOperation], shared: SharedResources?) -> [String: String] {
        let recordRows = records.map { record in
            (key: "record-\(record.id)", name: record.voiceName, date: record.createdAt, voiceID: Optional(record.voiceId), ordinal: 0)
        }
        let operationRows = operations.enumerated().map { ordinal, operation in
            (key: "operation-\(operation.id)", name: operation.expectedVoiceName ?? "", date: ISO8601DateFormatter().string(from: operation.startedAt), voiceID: operation.remoteVoiceID, ordinal: ordinal + 1)
        }
        let rows = recordRows + operationRows
        let bases = rows.map { row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name.isEmpty ? "Unnamed voice" : name), created \(createdDate(row.date, shared: shared))"
        }
        var contexts: [String: String] = [:]
        for (index, row) in rows.enumerated() {
            let base = bases[index]
            var context = base
            if bases.filter({ $0 == base }).count > 1 || row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let voiceID = row.voiceID, !voiceID.isEmpty, voiceID != "pending" {
                    let suffix = voiceID.suffix(6)
                    let collision = rows.enumerated().contains { otherIndex, other in
                        guard otherIndex != index, bases[otherIndex] == base,
                              let otherID = other.voiceID, otherID != "pending" else { return false }
                        return otherID.suffix(6) == suffix
                    }
                    context += collision ? ", voice ID \(voiceID)" : ", voice ID ending \(suffix)"
                } else { context += ", attempt \(row.ordinal)" }
            }
            contexts[row.key] = context
        }
        return contexts
    }
    static func actionAccessibilityLabel(_ action: String, context: String) -> String {
        "\(action) \(context)"
    }
    static func requestAccessibilityLabel(_ action: VoiceLabSession.Request, contexts: [String: String]) -> String {
        let key: String
        switch action {
        case .delete(let id), .removeLocal(let id): key = "record-\(id)"
        case .stopLooking(let id): key = "operation-\(id)"
        default: return action.title
        }
        guard let context = contexts[key] else { return action.title }
        return actionAccessibilityLabel(action.title, context: context)
    }
}

/// A voice's learned references (ADR-R41): how many of the owner's videos taught the guard, and the two inline actions.
@MainActor struct VoiceReferenceRows: View {
    @Bindable var session: VoiceLabSession
    let record: VoiceConsentRecord
    let context: String
    var body: some View {
        let learned = VoiceSpeakerReferences.learnedCount(record.speaker)
        let learning = session.isLearning
        Text(VoiceLabSession.learnedLine(record)).font(.caption).accessibilityIdentifier("voice-references-\(record.id)")
        if let line = session.learningLine[record.id] { Text(line).font(.caption).foregroundStyle(.secondary) }
        HStack {
            Button(learning ? "Learning…" : "Learn from my videos") { session.learnFromVideos(recordID: record.id) }
                .disabled(learning || session.busy)
                .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel("Learn from my videos", context: context))
            if learned > 0 || record.speaker.references != nil {
                Button("Forget learned references") { Task { await session.forgetLearned(recordID: record.id) } }
                    .disabled(session.busy)
                    .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel("Forget learned references", context: context))
            }
        }
        Text("Checks speech in your projects on this Mac against your consent recording. Free; nothing is sent.").font(.caption).foregroundStyle(.secondary)
    }
}

/// A matching voice for each video (voice-lab §6.13, ADR-R45): the remembered answer, which video has its own voice,
/// a removal still owed, and how close takes sound to the speech beside them.
@MainActor struct VideoVoiceRows: View {
    @Bindable var session: VoiceLabSession
    var body: some View {
        let anchor = session.anchorVoice(language: nil).map { VoiceLabSession.rebuildName($0.voiceName) } ?? "your voice"
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            Picker("Each video", selection: Binding(get: { session.videoVoiceMode }, set: { session.setVideoVoiceMode($0) })) {
                Text("Make a matching voice").tag(VoicePerVideo.Mode.match)
                Text("Use \(anchor)").tag(VoicePerVideo.Mode.anchor)
                Text("Ask in Rewrite").tag(VoicePerVideo.Mode.ask)
            }
            .accessibilityIdentifier("voice-per-video-mode")
            Text(Self.modeLine(session.videoVoiceMode, anchor: anchor)).font(.caption).foregroundStyle(.secondary)
            ForEach(session.perVideoBook.videos, id: \.recordId) { video in
                let name = session.records.first { $0.id == video.recordId }?.voiceName ?? video.title
                Text("\(name) · \(VoiceRebuild.amount(Int(video.videoSeconds * 1_000))) of \(video.title)\(video.removesBackgroundNoise ? ", background noise removed" : "")")
                    .font(.caption).accessibilityIdentifier("voice-per-video-\(video.recordId)")
            }
            if let note = session.perVideoNote {
                HStack {
                    Text(note).font(.caption).accessibilityIdentifier("voice-per-video-note")
                    if session.perVideoBook.removals.contains(where: { $0.lastError != nil }) {
                        Button("Retry now") { Task { await session.removePreviousVideoVoices() } }.disabled(session.busy)
                    }
                }
            }
            if !session.perVideoBook.measurements.isEmpty {
                Text("How close takes sound to your speech beside them (1.00 is the same voice):").font(.caption)
                ForEach(session.perVideoBook.measurements, id: \.contentKey) { measurement in
                    Text(VoiceLabSession.matchLine(measurement, anchor: anchor)).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice-per-video-match-\(measurement.contentKey.prefix(8))")
                }
            }
        }
    }
    static func modeLine(_ mode: VoicePerVideo.Mode, anchor: String) -> String {
        switch mode {
        case .match: "Each video gets a voice made from its own speech, so takes sound like that recording. The previous video's voice is removed; \(anchor) stays."
        case .anchor: "Every video uses \(anchor)."
        case .ask: "Rewrite asks once, on the next video that needs your voice."
        }
    }
}

/// "Rebuild from my videos" (voice-lab §6.12, ADR-R44): what it will use before any click, the three attestations
/// inline, Rebuild · price, then Use the new voice for Rewrite and Remove the old voice, all in the voice's own row.
@MainActor struct VoiceRebuildRows: View {
    @Bindable var session: VoiceLabSession
    /// Nil until the first Rebuild from my videos click; the row is then the idle one.
    let state: VoiceRebuildState?
    let record: VoiceConsentRecord
    let context: String
    var body: some View {
        if let state { VoiceRebuildStateRows(session: session, state: state, record: record, context: context) }
        else {
            Button("Rebuild from my videos") { session.findRebuild(recordID: record.id) }
                .disabled(session.busy || session.isLearning)
                .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel("Rebuild from my videos", context: context))
            Text(VoiceLabSession.rebuildIntro).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor private struct VoiceRebuildStateRows: View {
    @Bindable var session: VoiceLabSession
    @Bindable var state: VoiceRebuildState
    let record: VoiceConsentRecord
    let context: String
    var body: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            switch state.phase {
            case .idle, .failed, .finding:
                Button(state.phase == .finding ? "Finding your speech…" : "Rebuild from my videos") { session.findRebuild(recordID: record.id) }
                    .disabled(state.phase == .finding || session.busy || session.isLearning)
                    .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel("Rebuild from my videos", context: context))
                if state.phase == .idle { Text(VoiceLabSession.rebuildIntro).font(.caption).foregroundStyle(.secondary) }
            case .found, .preparing, .ready, .creating:
                found
            case .created:
                created
            }
            if !state.line.isEmpty { Text(state.line).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("voice-rebuild-line-\(record.id)") }
        }
    }
    private var found: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            Text("Rebuild with \(state.summary)").font(.caption).fontWeight(.medium).accessibilityIdentifier("voice-rebuild-summary-\(record.id)")
            HStack {
                ForEach(Array((state.found?.samples ?? []).prefix(3).enumerated()), id: \.offset) { index, sample in
                    Button("▶ \(Int(sample.seconds)) s") { session.playRebuildPiece(state, index: index) }
                        .accessibilityLabel("Play piece \(index + 1), \(Int(sample.seconds)) seconds")
                }
            }
            let locked = state.phase == .creating || session.busy
            Toggle(VoiceConsentRecord.ProjectConsent.text, isOn: $state.ownVoice).disabled(locked)
            Toggle("I am 18 or older.", isOn: $state.adult).disabled(locked)
            Toggle("I will use it only on videos of myself.", isOn: $state.ownVideosOnly).disabled(locked)
            if state.phase == .ready || state.phase == .creating {
                Button(state.phase == .creating ? "Rebuilding…" : session.rebuildTitle(state)) { Task { await session.approveRebuild(state) } }
                    .disabled(state.phase != .ready || session.busy)
                    .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel(session.rebuildTitle(state), context: context))
            }
        }
    }
    private var created: some View {
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            HStack {
                if !state.usedForRewrite {
                    Button("Use the new voice for Rewrite") { session.useRebuiltVoice(state) }.disabled(session.busy)
                }
                if !state.removed && !state.confirmingRemoval {
                    Button("Remove the old voice", role: .destructive) { state.confirmingRemoval = true }.disabled(session.busy)
                        .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel("Remove the old voice", context: context))
                }
            }
            if state.confirmingRemoval {
                Text("Deletes \(record.voiceName), made \(VoiceLabSettings.createdDate(record.createdAt, shared: session.app.shared)), from your ElevenLabs account and VoxClip. Free. Existing takes stay playable and labelled.").font(.caption)
                HStack {
                    Button("Keep it") { state.confirmingRemoval = false }
                    Button("Remove old voice", role: .destructive) { Task { await session.removeOldVoice(state) } }.disabled(session.busy)
                }
            }
        }
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

/// Shared management and inline-job recovery. A retry reconciles existing work; it never creates another voice.
@MainActor struct VoiceRecoveryRows: View {
    @Bindable var session: VoiceLabSession
    let shared: SharedResources?
    var inline = false
    @State private var stopLooking: UUID?
    var body: some View {
        let operations = session.operations.filter { !$0.finished }
        let contexts = VoiceLabSettings.accessibilityContexts(records: session.visibleRecords, operations: operations, shared: shared)
        return Group {
            ForEach(operations) { operation in
                let context = contexts["operation-\(operation.id)", default: ""]
                VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
                    Text(operation.kind == .create ? "Voice creation" : "Voice removal").fontWeight(.medium)
                    Text(operation.displayState).font(.caption)
                    if operation.needsCreatorRecoveryReview, operation.recoveryNeedsReview == true {
                        Button(VoiceLabSession.Request.stopLooking(operation.id).title) {
                            if inline { stopLooking = operation.id } else { session.request(.stopLooking(operation.id)) }
                        }
                            .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel(VoiceLabSession.Request.stopLooking(operation.id).title, context: context)).disabled(session.busy)
                    }
                    if inline, stopLooking == operation.id {
                        Text("The remote state stays unknown. This stops recovery without deleting a voice from ElevenLabs.")
                        HStack {
                            Button("Cancel") { stopLooking = nil }
                            Button("Stop Looking", role: .destructive) { Task { await session.approve(.stopLooking(operation.id)); stopLooking = nil } }
                        }
                    }
                    Button("Retry") { Task { await session.load(force: true) } }.disabled(session.busy)
                        .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel("Retry", context: context))
                    if operation.kind == .create {
                        Button("Remove This Voice", role: .destructive) { Task { await session.withdrawOperation(operation) } }.disabled(session.busy)
                            .accessibilityLabel(VoiceLabSettings.actionAccessibilityLabel("Remove unfinished voice", context: context))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(context)
            }
        }
    }
}

@MainActor private struct VoiceLabRequestSheet: View {
    @Bindable var session: VoiceLabSession
    let action: VoiceLabSession.Request
    let shared: SharedResources?
    var body: some View {
        let records = session.visibleRecords + (session.unsavedRecord.map { [$0] } ?? [])
        let contexts = VoiceLabSettings.accessibilityContexts(records: records, operations: session.operations.filter { !$0.finished }, shared: shared)
        return VStack(alignment: .leading, spacing: 16) {
            Text(action.title).font(.title2)
            Text(VoiceLabSession.providerCopy)
            switch action {
            case .subscription: Text("Reads your subscription, plan, available voice slots and pending voice verification status. No audio, video or transcript is sent. This check is free.")
            case .delete: Text("Deletes this voice from ElevenLabs, removes the local statement recording, and marks the local consent record deleted. Existing rendered takes stay playable and labelled. This action is free.")
            case .removeLocal: Text("Removes the local consent statement and records that the remote state is unknown. The voice may stay in your ElevenLabs account. This action is free.")
            case .stopLooking: Text("Stops recovery without deleting any voice from ElevenLabs. Records that the remote state is unknown; the voice may stay in your ElevenLabs account. This action is free.")
            }
            HStack {
                Spacer()
                if action.defaultIsCancel {
                    Button("Cancel", role: .cancel) { session.confirmation = nil }.keyboardShortcut(.defaultAction)
                    Button(action.title, role: .destructive) { Task { await session.approve(action) } }
                        .accessibilityLabel(VoiceLabSettings.requestAccessibilityLabel(action, contexts: contexts))
                } else {
                    Button("Cancel", role: .cancel) { session.confirmation = nil }.keyboardShortcut(.cancelAction)
                    Button(action == .subscription ? "Continue" : action.title) { Task { await session.approve(action) } }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 500).onExitCommand { session.confirmation = nil }
    }
}
