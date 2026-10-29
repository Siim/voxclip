import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor @Observable final class VoiceLabSession {
    enum Request: Identifiable, Equatable {
        case subscription, verify, create, delete(String)
        var id: String { String(describing: self) }
        var title: String {
            switch self { case .subscription: "Check ElevenLabs account"; case .verify: "Verify statement · < $0.01"; case .create: "Create your voice"; case .delete: "Delete voice" }
        }
    }
    static let betaCopy = "Voice Lab can clone your own voice, change your voice and re-voice a few words. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key and, for lip sync, your fal.ai or sync.so key."
    static let providerCopy = "Voice Lab sends audio of your voice and the words to speak to ElevenLabs with your key. Under ElevenLabs' terms, ElevenLabs may use uploaded content, including your voice, to improve its services unless you opt out in your ElevenLabs account. Generated audio can be traced to your account."
    static let noticeCopy = "Your voice clone is created in your ElevenLabs account and stays there. ElevenLabs' terms let it use uploaded content, including your voice, to improve its services; you can opt out of training in your ElevenLabs account, but the opt-out is not retroactive. You can delete the voice at any time from VoxClip or ElevenLabs. ElevenLabs' Prohibited Use Policy applies, including its rules on political content."
    var confirmation: Request?
    var records: [VoiceConsentRecord] = []
    var subscription: VoiceLabSubscription?
    var message: String?
    var busy = false
    var showEnrollment = false
    var displayName = ""
    var ownVoice = false
    var adult = false
    var ownVideosOnly = false
    var statement: VoiceConsentStatement?
    var verified = false
    var trainingReady = false
    var unsavedRecord: VoiceConsentRecord?
    var recordingTraining = false
    var script = ""
    let recorder = VoiceMicrophoneRecorder()
    private(set) var recordID = UUID().uuidString.lowercased()
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let store: VoiceConsentStore
    @ObservationIgnored private var client: ElevenLabsVoiceLab?
    @ObservationIgnored private var enrollment: VoiceEnrollment?
    @ObservationIgnored private var region: ElevenLabsRegion?
    @ObservationIgnored private var statementWAV: Data?
    @ObservationIgnored private var training: [VoiceTrainingSample] = []
    @ObservationIgnored private var quote: VoiceLabQuote?
    @ObservationIgnored private var acceptedAt = Date()
    init(app: AppModel) { self.app = app; self.store = VoiceConsentStore(locations: app.locations) }
    var enabled: Bool { app.bool("voiceLab.enabled") }
    var canRecord: Bool { enabled && !busy && ownVoice && adult && ownVideosOnly && (try? VoiceConsentText.displayName(displayName)) != nil }
    var canCreate: Bool { enabled && !busy && verified && trainingReady && unsavedRecord == nil }
    var planMessage: String? {
        guard let subscription else { return "Check your ElevenLabs account before creating a voice." }
        if !subscription.canClone { return "Instant voice cloning needs an ElevenLabs Starter plan or higher." }
        if subscription.voiceSlotsUsed >= subscription.voiceLimit { return "Your ElevenLabs account has no free voice slots." }
        return nil
    }
    var speakerMessage: String {
        if app.speakerModelLibrary.installed { return "Own-voice checks run on this Mac. Estonian is not available yet." }
        return "Download the own-voice check model in Settings → Voice Lab before creating a voice. No audio is sent for this check."
    }
    func load() async {
        do { records = try await store.records() } catch { message = "The local voice records could not be read. No audio was sent." }
    }
    func reconcileStartup() async {
        do { try await store.reconcileAbandonedEnrollments() }
        catch { message = "An abandoned voice recording could not be removed. Open Voice Lab and retry cleanup." }
    }
    private func services() throws -> (ElevenLabsVoiceLab, VoiceEnrollment) {
        let selected = ElevenLabsRegion(rawValue: app.string("transcription.elevenlabs.region", fallback: "default")) ?? .default
        if let client, let enrollment, region == selected { return (client, enrollment) }
        let client = ElevenLabsVoiceLab(keys: app.secrets, region: selected, logger: app.log)
        let transcriber = ElevenLabsTranscriber(keys: app.secrets, region: selected, logger: app.log)
        let cache = app.locations.cache.appendingPathComponent("voice-consent", isDirectory: true)
        let enrollment = VoiceEnrollment(store: store, client: client) { wav, language in
            let temporary = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let pcm = try VoiceConsentAudio.pcm16k(wav)
            let file = temporary.appendingPathComponent("statement.wav")
            try VoiceTrainingAudio.wav(pcm, rate: 16_000).write(to: file, options: .atomic)
            let audio = ExtractedAudio(wav16k: file, sampleCount: Int64(pcm.count), durationSeconds: Double(pcm.count) / 16_000)
            let plan = TranscriptionPlan(engine: .elevenlabs, model: "scribe_v2", language: .forced(language), options: .init(diarize: false))
            return try await transcriber.transcribe(.init(plan: plan, audio: audio, contentKey: UUID().uuidString)) { _ in }
        }
        self.client = client; self.enrollment = enrollment; region = selected
        return (client, enrollment)
    }
    func request(_ action: Request) {
        guard VoiceLabGate.canEnroll(enabled: enabled, busy: busy), !recorder.recording else { return }
        confirmation = action
    }
    func approve(_ action: Request) async {
        guard enabled, !busy else { return }
        confirmation = nil; busy = true; message = nil
        defer { busy = false }
        do {
            let (client, enrollment) = try services()
            app.set("voiceLab.providerConsent.elevenlabs", .bool(true))
            switch action {
            case .subscription:
                subscription = try await client.plan()
                if records.contains(where: { $0.status == .verificationRequired }) {
                    try await store.refreshVerification(client.listOwnClones())
                    await load()
                }
            case .verify:
                guard let statement, let statementWAV else { throw VoiceLabError.invalidInput }
                let attestations = VoiceConsentRecord.Attestations(ownVoice: ownVoice, adult: adult, ownVideosOnly: ownVideosOnly, acceptedAt: acceptedAt)
                try await enrollment.verify(recordID: recordID, statement: statement, wav: statementWAV, attestations: attestations, approved: true, enabled: enabled)
                verified = true; recorder.discard(); message = "Statement verified. Record your training read-aloud next."
            case .create:
                guard let quote else { throw VoiceConsentError.speakerUnavailable }
                subscription = try await client.plan()
                let record = try await enrollment.create(quote: quote, approved: true, enabled: enabled, appVersion: AppModel.version)
                training = []; statementWAV = nil; recorder.discard(); showEnrollment = false
                message = record.status == .verificationRequired ? "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back." : "Your voice is ready."
                await load()
            case .delete(let id):
                try await enrollment.delete(recordID: id, approved: true, enabled: enabled)
                await load(); message = "Voice deleted. Existing rendered takes remain playable and labelled."
            }
        } catch {
            if let error = error as? VoiceConsentSaveError {
                unsavedRecord = error.record
                training = []; statementWAV = nil; recorder.discard(); trainingReady = false
                message = "ElevenLabs created voice \(error.record.voiceId), but the local consent record could not be saved. Retry saving; do not create the voice again."
                return
            }
            message = await errorMessage(error)
            if action == .verify {
                verified = false; statementWAV = nil; recorder.discard()
                try? await enrollment?.cancel(recordID: recordID)
                statement = nil
            }
        }
    }
    func beginStatement() async {
        guard canRecord, planMessage == nil else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            guard let shared = app.shared else { throw VoxClipError.sharedResourcesMissing }
            if let enrollment { try await enrollment.cancel(recordID: recordID) }
            try await store.abandonEnrollment(recordID: recordID)
            recordID = UUID().uuidString.lowercased()
            let recentLanguage = app.recent.compactMap { app.recentProjects.items[$0]?.language }.first
            let language = app.shell.document?.project.transcript?.language ?? recentLanguage ?? "en"
            let selected = language == "et" ? "et" : "en"
            let words = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/nonce-words-\(selected).txt"), encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
            var rng = SystemRandomNumberGenerator()
            let data = try VoiceConsentText(shared: shared)
            statement = try data.statement(name: displayName, language: selected, date: Date(), words: words, rng: &rng)
            script = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/scripts-\(selected).txt"), encoding: .utf8)
            acceptedAt = Date(); verified = false; trainingReady = false; statementWAV = nil; training = []; recordingTraining = false
            try await recorder.start(maximumSeconds: 30)
        } catch { message = await errorMessage(error) }
    }
    func stopRecording() async {
        recorder.stop()
        await finishRecording()
    }
    func finishRecording() async {
        guard enabled, !busy, !recorder.recording, !recorder.samples.isEmpty else { return }
        busy = true; defer { busy = false }
        let samples = recorder.samples
        do {
            if recordingTraining {
                training = try await Task.detached(priority: .userInitiated) { try VoiceTrainingAudio.training(samples) }.value
                trainingReady = true; recorder.discard()
                message = "Training recording is ready. " + speakerMessage
            } else {
                guard (5...30).contains(Double(samples.count) / 48_000) else { throw VoiceLabError.invalidAudio }
                let wav = try await Task.detached(priority: .userInitiated) { try VoiceTrainingAudio.wav(samples) }.value
                try await store.saveStatement(wav, recordID: recordID)
                statementWAV = wav
                message = "Recording is ready. Verify statement sends only this recording to ElevenLabs."
            }
        } catch { message = await errorMessage(error); if recordingTraining { trainingReady = false } }
    }
    func beginTraining() async {
        guard enabled, verified, !busy else { return }
        message = nil; trainingReady = false; recordingTraining = true; training = []
        do { try await recorder.start(maximumSeconds: 90) } catch { message = await errorMessage(error) }
    }
    func prepareCreation() async {
        guard canCreate else { return }
        busy = true; defer { busy = false }
        do {
            let (_, enrollment) = try services()
            let check = try await app.speakerModelLibrary.check(language: statement?.language ?? "en")
            try await enrollment.setSpeakerCheck(check)
            quote = try await enrollment.prepare(recordID: recordID, displayName: displayName, samples: training, enabled: enabled)
            confirmation = .create
        } catch { message = await errorMessage(error) }
    }
    var hasStatementRecording: Bool { statementWAV != nil }
    var creationCost: String {
        guard let quote else { return "Check ElevenLabs pricing before creating your voice." }
        return quote.estimate.usd.map { VoiceLabCostPresentation.format($0) } ?? "VoxClip can't tell what this costs. Check ElevenLabs's pricing."
    }
    func cancelEnrollment() async {
        guard !busy else { return }
        if unsavedRecord != nil { showEnrollment = false; return }
        recorder.discard()
        do {
            try await enrollment?.cancel(recordID: recordID)
            try await store.abandonEnrollment(recordID: recordID)
        } catch { message = "The statement recording could not be removed. Retry Cancel to finish cleanup."; return }
        statementWAV = nil; training = []; verified = false; trainingReady = false; statement = nil; quote = nil
        showEnrollment = false
    }
    func retrySavingRecord() async {
        guard let record = unsavedRecord, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await store.save(record)
            unsavedRecord = nil; showEnrollment = false
            await load(); message = "Consent record saved. No provider request was made."
        } catch { message = "The consent record still could not be saved. Free some disk space, then retry saving. Do not create the voice again." }
    }
    private func errorMessage(_ error: any Error) async -> String {
        if let error = error as? VoiceConsentError { return error.localizedDescription }
        if let error = error as? MicrophoneError { return error.localizedDescription }
        if let error = error as? VoiceLabError {
            switch error {
            case .planUnavailable: return "Instant voice cloning needs an ElevenLabs Starter plan or higher."
            case .noVoiceSlots: return "Your ElevenLabs account has no free voice slots."
            case .missingKey: return "Add your ElevenLabs key in Settings to use it."
            case .permissionMissing(let permission): return "Allow the \(permission) permission for this key on elevenlabs.io."
            case .invalidAudio: return "Record 5–30 seconds for consent, or 60–90 seconds for the training read-aloud, with clear speech."
            case .cancelled: return ""
            default: return "ElevenLabs could not complete this action. Your videos and edits are still here. No automatic retry was made."
            }
        }
        return await app.safeError(error)
    }
}

extension AppModel {
    var voiceLabLabelPosition: VoiceLabLabelPosition {
        switch string("voiceLab.labelPosition", fallback: "top-right") {
        case "top-left": .topLeft
        case "bottom-left": .bottomLeft
        case "bottom-right": .bottomRight
        default: .topRight
        }
    }
    var voiceLabSettingsVisible: Bool {
        #if DEBUG
        VoiceLabGate.settingsVisible(enabled: bool("voiceLab.enabled"), internalBuild: true)
        #else
        VoiceLabGate.settingsVisible(enabled: bool("voiceLab.enabled"), internalBuild: false)
        #endif
    }
}
