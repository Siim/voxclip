import Foundation
import AppKit
import AVFoundation
import Observation
import VoxClipCore
import VoxClipMedia

/// The enrollment job, separate from the Rewrite proposal it returns to. No document mutation or paid work on opening.
@MainActor @Observable final class VoiceEnrollmentFlow {
    enum State: String, CaseIterable { case firstUse = "V0", agree = "V1", statement = "V2", checking = "V3", ready = "V4", creating = "V5", finished = "V6" }
    var state = State.firstUse
    var keyReady = false
    var keyChecked = false
    var keyDraft = ""
    var turn = 0
    var plan: VoiceEnrollmentPlan?
    var priceAppearedAt: Date?
    var recoveryIDs: [String] = []
    var statementSeconds: Double = 0
    var capWarning: String?
    var finishedRecord: VoiceConsentRecord?
    @ObservationIgnored weak var owner: EditorModel?
    @ObservationIgnored weak var originTask: DirectorTask?
    var originTurn = 0
}

@MainActor @Observable final class VoiceLabSession {
    enum Request: Identifiable, Equatable {
        case subscription, delete(String), removeLocal(String), stopLooking(UUID)
        var id: String { String(describing: self) }
        var title: String {
            switch self { case .subscription: "Check ElevenLabs account"; case .delete: "Delete voice"; case .removeLocal: "Remove from VoxClip only"; case .stopLooking: "I've checked my ElevenLabs account — stop looking" }
        }
        var defaultIsCancel: Bool { switch self { case .delete, .removeLocal, .stopLooking: true; default: false } }
    }
    static let betaCopy = "Voice Lab can clone your own voice, change your voice and re-voice a few words. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key and, for lip sync, your fal.ai or sync.so key."
    static let providerCopy = "Voice Lab sends audio of your voice and the words to speak to ElevenLabs with your key. Under ElevenLabs' terms, ElevenLabs may use uploaded content, including your voice, to improve its services unless you opt out in your ElevenLabs account. Generated audio can be traced to your account."
    static let projectChoice = "Use this project's audio (recommended)"
    static let readAloudChoice = "Record a read-aloud (about 90 s)"
    static let projectMismatchCopy = "Some of this project's audio doesn't sound like the voice in your consent statement. Record a read-aloud instead."
    static let projectUnreadableCopy = "VoxClip can't read this project's audio. Record a read-aloud instead."
    static let projectGeneratedCopy = "This project's media is labelled AI modified, so it can't train your voice. Record a read-aloud instead."
    /// The Rewrite panel's voice row in a project whose language has no calibrated speaker check (§6.5.2).
    static let languageUnavailableCopy = "Your voice can't be used in this project's language yet. It works in English projects."
    static let noticeCopy = "Your voice clone is created in your ElevenLabs account and stays there. ElevenLabs' terms let it use uploaded content, including your voice, to improve its services; you can opt out of training in your ElevenLabs account, but the opt-out is not retroactive. You can delete the voice at any time from VoxClip or ElevenLabs. ElevenLabs' Prohibited Use Policy applies, including its rules on political content."
    static let recoveryCreationCopy = "Sends your saved statement and training audio to ElevenLabs to finish creation. The statement check is not repeated. No video is sent."
    var confirmation: Request?
    var records: [VoiceConsentRecord] = []
    var deleting: Set<String> = []
    var operations: [VoiceOperation] = []
    var pendingCreations: [VoiceOperation] { operations.filter(\.blocksCreation) }
    var visibleRecords: [VoiceConsentRecord] {
        records.filter { record in
            let creating = operations.contains { $0.recordID == record.id && $0.kind == .create && !$0.finished }
            return record.voiceId != "pending" && !creating && (record.status != .deleted || deleting.contains(record.id))
        }
    }
    var subscription: VoiceLabSubscription?
    var message: String?
    var busy = false
    var showEnrollment = false
    let flow = VoiceEnrollmentFlow()
    var displayName = ""
    var ownVoice = false
    var adult = false
    var ownVideosOnly = false
    var statement: VoiceConsentStatement?
    var trainingReady = false
    var unsavedRecord: VoiceConsentRecord?
    var recordingTraining = false
    var script = ""
    /// §6.5: where the training samples come from. The live consent statement is recorded and verified either way.
    enum TrainingSource: String, Hashable { case project, readAloud }
    /// §6.5.2: the editor's project when the job opened.
    enum ProjectAudio: Equatable {
        /// `generated`: the media carries the AI-modified XMP label, so it may hold generated speech (§6.5.2).
        case noProject, untranscribed, finding, unreadable, generated
        case found(VoiceTrainingSpanSelection)
    }
    /// The project the sheet was opened with; `source` is nil when its media is not available.
    struct TrainingProject {
        let project: Project
        let name: String
        let source: URL?
    }
    var trainingSource = TrainingSource.readAloud
    var projectAudio = ProjectAudio.noProject
    var projectName = ""
    /// The project's spans failed the §6.6 speaker match; only a read-aloud can continue until the sheet closes.
    var projectMismatch = false
    @ObservationIgnored private(set) var analysis: Task<Void, Never>?
    @ObservationIgnored private var analysisID = UUID()
    @ObservationIgnored private var trainingProject: TrainingProject?
    @ObservationIgnored private var projectRate: Int?
    @ObservationIgnored private var keptSeconds: Double?
    let recorder = VoiceMicrophoneRecorder()
    private(set) var recordID = UUID().uuidString.lowercased()
    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private let store: VoiceConsentStore
    @ObservationIgnored private var client: ElevenLabsVoiceLab?
    @ObservationIgnored private var enrollment: VoiceEnrollment?
    @ObservationIgnored private let reconciler: VoiceOperationReconciler
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var region: ElevenLabsRegion?
    @ObservationIgnored private var statementPlayer: AVAudioPlayer?
    @ObservationIgnored private var paidAction: Task<Void, Never>?
    @ObservationIgnored private var statementWAV: Data?
    @ObservationIgnored private var training: [VoiceTrainingSample] = []
    @ObservationIgnored private var acceptedAt = Date()
    @ObservationIgnored private var recordingTurn = UUID()
    @ObservationIgnored private(set) var recordingCompletion: Task<Void, Never>?
    init(app: AppModel) {
        self.app = app; self.store = VoiceConsentStore(locations: app.locations)
        let secrets = app.secrets; let logger = app.log
        reconciler = VoiceOperationReconciler(store: store, regionIsCurrent: { region in
            await MainActor.run { app.string("transcription.elevenlabs.region", fallback: "default") == region.rawValue }
        }) { ElevenLabsVoiceLab(keys: secrets, region: $0, logger: logger) }
        observeRecordingCompletion()
    }
    #if DEBUG
    init(app: AppModel, store: VoiceConsentStore, reconciler: VoiceOperationReconciler? = nil) {
        self.app = app; self.store = store
        let secrets = app.secrets; let logger = app.log
        self.reconciler = reconciler ?? VoiceOperationReconciler(store: store) { ElevenLabsVoiceLab(keys: secrets, region: $0, logger: logger) }
        observeRecordingCompletion()
    }
    @ObservationIgnored private var speakerCheckForTests: VoiceSpeakerCheck?
    func stageEnrollmentForTests(statement: VoiceConsentStatement, wav: Data, client: ElevenLabsVoiceLab, speaker: VoiceSpeakerCheck? = nil) {
        self.statement = statement; statementWAV = wav
        self.client = client; region = client.region
        speakerCheckForTests = speaker
        enrollment = VoiceEnrollment(store: store, client: client, speaker: speaker ?? .unavailable, reconciler: reconciler)
    }
    func stageTrainingForTests(_ samples: [VoiceTrainingSample]) {
        training = samples; trainingReady = true; trainingSource = .readAloud
    }
    #endif
    private func currentSpeakerCheck() async throws -> VoiceSpeakerCheck {
        #if DEBUG
        if let speakerCheckForTests { return speakerCheckForTests }
        #endif
        return try await app.speakerModelLibrary.check(language: enrollmentLanguage)
    }
    var voiceNeedHeadline: String {
        let count = flow.owner?.openRewrite?.changes.filter { $0.hunk.kind == .voice }.count ?? 0
        return count == 0 ? "Your voice" : count == 1 ? "1 phrase needs your voice" : "\(count) phrases need your voice"
    }
    func prepareVoiceJob() async {
        await app.speakerModelLibrary.load()
        flow.keyReady = await app.providerKeyStore.hasKey(for: "elevenlabs")
        flow.keyChecked = true
        flow.recoveryIDs = (try? await store.recoverableEnrollments()) ?? []
        if enabled && speakerReady && flow.keyReady && flow.state == .firstUse { continueAfterDownload() }
    }
    func saveVoiceKey() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await app.providerKeyStore.save(flow.keyDraft, for: "elevenlabs")
            flow.keyDraft = ""; flow.keyReady = true; message = nil
        } catch { message = "Couldn't save the key. " + (await app.safeError(error)) }
    }
    func turnOnVoiceJob() {
        guard flow.keyReady, !busy else { return }
        app.set("voiceLab.betaNoticeAccepted", .bool(true)); app.set("voiceLab.enabled", .bool(true))
        if app.speakerModelLibrary.installed { continueAfterDownload() }
        else { app.speakerModelLibrary.download(approved: true) }
    }
    func continueAfterDownload() {
        guard enabled, app.speakerModelLibrary.installed, flow.keyReady else { return }
        if flow.state == .firstUse { flow.state = .agree }
        if let project = trainingProject, projectAudio == .noProject { startProjectAnalysis(project) }
        flow.owner?.announce("Own-voice check installed. Finding your clear speech.")
    }
    func returnToRewrite() {
        leaveVoiceControls()
        guard !busy else { return }
        let created = flow.state == .finished && unsavedRecord == nil ? flow.finishedRecord : nil
        if flow.state == .finished, unsavedRecord == nil { finishCreation() }
        // Preserve local enrollment when switching jobs. Closing the proposal never approves a send.
        if let owner = flow.owner {
            owner.app.shell.choosePanelJob(.rewrite, for: owner)
            if let created { owner.openRewrite?.refreshCreatedVoice(created) }
        }
    }
    private func observeRecordingCompletion() {
        recorder.onStopped = { [weak self] in
            guard let self else { return }
            recordingCompletion = Task { [weak self] in await self?.finishRecording() }
        }
    }
    func leaveVoiceControls(owner: EditorModel? = nil) {
        if let owner, flow.owner !== owner { return }
        recordingTurn = UUID()
        recordingCompletion?.cancel()
        let wasRecording = recorder.recording || !recorder.samples.isEmpty
        recorder.discard()
        statementPlayer?.stop()
        if wasRecording { message = "Recording discarded when you left Voice. Record it again to continue." }
    }
    func cancelVoiceAction() {
        if app.speakerModelLibrary.progress != nil { app.speakerModelLibrary.cancelDownload(); return }
        if busy { paidAction?.cancel(); return }
        if recorder.recording { recorder.discard(); return }
        returnToRewrite()
    }
    func voicePrimary(command: Bool) {
        guard !busy else { return }
        if flow.state == .ready {
            startVoiceCreation(keyboard: true, command: command)
        } else if flow.state == .firstUse {
            if flow.keyReady { turnOnVoiceJob() } else { Task { await saveVoiceKey() } }
        } else if flow.state == .agree { Task { await prepareVoiceStatement() } }
        else if flow.state == .finished, unsavedRecord == nil { returnToRewrite() }
        else if flow.state == .statement, projectMismatch, trainingSource == .project { useReadAloud() }
        else if flow.state == .statement {
            Task { if recorder.recording { await stopRecording() } else if recordingTraining { await beginTraining() } else { await beginStatement() } }
        }
    }
    func changeVoiceAgreement() {
        guard !busy, !recorder.recording else { return }
        statement = nil; statementWAV = nil; flow.state = .agree
    }
    func prepareVoiceStatement() async {
        guard canRecord, let shared = app.shared else { return }
        do {
            let selected = enrollmentLanguage
            let words = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/nonce-words-\(selected).txt"), encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
            var rng = SystemRandomNumberGenerator()
            statement = try VoiceConsentText(shared: shared).statement(name: displayName, language: selected, date: Date(), words: words, rng: &rng)
            script = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/scripts-\(selected).txt"), encoding: .utf8)
            acceptedAt = Date(); flow.state = .statement; message = nil
        } catch { message = await errorMessage(error) }
    }
    func refreshEnabledState() async {
        guard enabled else { records = []; deleting = []; operations = []; return }
        await load()
    }
    var enabled: Bool { app.bool("voiceLab.enabled") }
    var enrollmentLanguage: String {
        if let statement { return statement.language }
        let project = trainingProject?.project ?? app.shell.document?.project
        let candidate = project?.transcript?.language ?? app.recent.compactMap { app.recentProjects.items[$0]?.language }.first
        return Self.statementLanguage(candidate) { [app] in app.speakerModelLibrary.model?.calibratedThreshold(language: $0) != nil }
    }
    /// §6.2: the candidate transcript language's primary subtag (`en-GB` is `en`), but only when the speaker check is
    /// calibrated for it; otherwise English. Training spans may be in any language.
    static func statementLanguage(_ candidate: String?, calibrated: (String) -> Bool) -> String {
        guard let primary = candidate?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased(), !primary.isEmpty, calibrated(primary) else { return "en" }
        return primary
    }
    /// A voice is bound to its statement language, and Rewrite lists only voices in the project's language
    /// (`VoiceLabTakeRun.discover`). Without a calibrated check for that language, no voice made here can be listed there.
    func voicesUnavailable(projectLanguage: String?) -> Bool {
        guard let model = app.speakerModelLibrary.model, model.calibratedThreshold() != nil else { return false }
        let language = projectLanguage ?? "en"
        return Self.statementLanguage(language) { model.calibratedThreshold(language: $0) != nil } != language
    }
    var speakerReady: Bool {
        VoiceLabGate.canCheckOwnVoice(speakerAvailable: app.speakerModelLibrary.installed,
            calibratedThreshold: app.speakerModelLibrary.model?.calibratedThreshold(language: enrollmentLanguage), language: enrollmentLanguage)
    }
    var canRecord: Bool { enabled && speakerReady && !busy && ownVoice && adult && ownVideosOnly && (try? VoiceConsentText.displayName(displayName)) != nil }
    var canCreate: Bool { enabled && speakerReady && !busy && flow.state == .ready && flow.plan?.recordID == recordID && unsavedRecord == nil && pendingCreations.isEmpty }
    var trainingAvailable: Bool { trainingSource == .project ? projectAudioUsable && !projectMismatch : trainingReady }
    /// The job offers the two-choice picker: a project with a transcript is open.
    var offersProjectAudio: Bool { projectAudio != .noProject && projectAudio != .untranscribed }
    var projectAudioUsable: Bool {
        if case .found(let selection) = projectAudio { selection.status == .ok } else { false }
    }
    var projectChoiceEnabled: Bool { (projectAudioUsable || projectAudio == .finding) && !projectMismatch }
    /// The §6.5.2 line under the training choice. After a speaker mismatch it says why the project option stays off.
    var projectAudioLine: String {
        if projectMismatch, trainingSource == .readAloud { return Self.projectMismatchCopy }
        switch projectAudio {
        case .noProject: return "Open a project to use its audio instead."
        case .untranscribed: return "Transcribe this project to use its audio instead."
        case .finding: return "Finding clear speech in \(projectName)…"
        case .unreadable: return Self.projectUnreadableCopy
        case .generated: return Self.projectGeneratedCopy
        case .found(let selection):
            let seconds = selection.availableMs / 1_000
            if selection.status == .ok { return "\(seconds) s of clear speech found in \(projectName)" }
            return seconds == 0 ? "This project has no clear speech to use. Record a read-aloud instead."
                : "This project has only \(seconds) s of clear speech. Record a read-aloud instead."
        }
    }
    var planMessage: String? {
        guard let subscription else { return "Check your ElevenLabs account before creating a voice." }
        if !subscription.canClone { return "Instant voice cloning needs an ElevenLabs Starter plan or higher." }
        if subscription.voiceSlotsUsed >= subscription.voiceLimit { return "Your ElevenLabs account has no free voice slots." }
        return nil
    }
    var speakerMessage: String {
        if !speakerReady { return VoiceConsentError.speakerUnavailable.localizedDescription }
        if app.speakerModelLibrary.model?.calibratedThreshold() == nil { return VoiceConsentError.speakerUnavailable.localizedDescription }
        if app.speakerModelLibrary.installed { return "Own-voice checks run on this Mac. Estonian is not available yet." }
        return "Download the own-voice check model in Settings → Voice Lab before creating a voice. No audio is sent for this check."
    }
    func load(recover: Bool = true, force: Bool = false) async {
        do {
            if recover {
                try await store.reconcileAbandonedEnrollments()
                let abandoned = await store.takeAbandonedEnrollmentCount()
                if abandoned > 0 { await Log(logger: app.log).write(.warn, category: "voice-lab", message: "Abandoned invalid or expired enrollment journals: \(abandoned)") }
                do { try await reconciler.reconcile(force: force) }
                catch VoiceConsentError.recoveryCreatorMismatch { message = VoiceConsentError.recoveryCreatorMismatch.localizedDescription }
                catch { message = "Couldn't finish a voice operation. Retry below. No create request was repeated." }
            }
            operations = try await store.operations()
            deleting = Set(operations.filter { !$0.finished && ($0.kind == .delete || $0.state == .withdrawing) }.map(\.recordID))
            records = try await store.records()
            if !Task.isCancelled { scheduleRecovery() }
        } catch { message = "The local voice records could not be read. No audio was sent." }
    }
    private func scheduleRecovery() {
        recoveryTask?.cancel()
        guard let next = operations.filter({ !$0.finished }).compactMap(\.nextAttemptAt).min() else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            await self?.load()
        }
    }
    func reconcileStartup() async {
        guard !Task.isCancelled else { return }
        do {
            if !enabled, try await store.records().isEmpty, try await store.operations().isEmpty { return }
            await load()
        } catch { message = "The local voice records could not be read. No audio was sent." }
    }
    func stopRecovery() { recoveryTask?.cancel(); recoveryTask = nil }
    private func services() throws -> (ElevenLabsVoiceLab, VoiceEnrollment) {
        let selected = ElevenLabsRegion(rawValue: app.string("transcription.elevenlabs.region", fallback: "default")) ?? .default
        if let client, let enrollment, region == selected { return (client, enrollment) }
        let client = ElevenLabsVoiceLab(keys: app.secrets, region: selected, logger: app.log, spend: VoiceLabSpendLedger(locations: app.locations))
        let enrollment = VoiceEnrollment(store: store, client: client, reconciler: reconciler)
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
            if case .stopLooking(let id) = action {
                try await store.stopLookingForCreation(id)
                await load(recover: false)
                message = "Stopped looking. The remote state is unknown; the voice may stay in your ElevenLabs account."
                return
            }
            let (client, enrollment) = try services()
            app.set("voiceLab.providerConsent.elevenlabs", .bool(true))
            switch action {
            case .subscription:
                subscription = try await client.plan()
                if records.contains(where: { $0.status == .verificationRequired }) {
                    try await store.refreshVerification(client.listOwnClones())
                    await load()
                    if let id = flow.finishedRecord?.id, let updated = records.first(where: { $0.id == id }) { flow.finishedRecord = updated }
                }
            case .delete(let id):
                try await enrollment.delete(recordID: id, approved: true, enabled: enabled)
                await load(); message = "Voice deleted. Existing rendered takes remain playable and labelled."
            case .removeLocal(let id):
                try await store.removeFromVoxClipOnly(id)
                await load(); message = "Voice removed from VoxClip only. The remote state is unknown; it may stay in your ElevenLabs account."
            case .stopLooking: return
            }
        } catch {
            if let error = error as? VoiceConsentSaveError {
                unsavedRecord = error.record
                training = []; statementWAV = nil; recorder.discard(); trainingReady = false
                message = "ElevenLabs created voice \(error.record.voiceId), but the local consent record could not be saved. Retry saving or Remove This Voice. Do not create the voice again."
                await load(recover: false)
                return
            }
            message = await errorMessage(error)
            if case .delete = action { await load(recover: false) }
        }
    }
    func beginStatement() async {
        guard speakerReady else { message = VoiceConsentError.speakerUnavailable.localizedDescription; return }
        guard canRecord else { return }
        if statement == nil { await prepareVoiceStatement(); return }
        busy = true; message = nil
        let turn = recordingTurn
        defer { busy = false }
        do {
            guard try await currentSpeakerCheck().available else { throw VoiceConsentError.speakerUnavailable }
            if let enrollment { try await enrollment.cancel(recordID: recordID) }
            try await store.abandonEnrollment(recordID: recordID)
            recordID = UUID().uuidString.lowercased()
            guard statement != nil, recordingTurn == turn, !Task.isCancelled else { return }
            acceptedAt = Date(); trainingReady = false; statementWAV = nil; training = []; recordingTraining = false; keptSeconds = nil; flow.plan = nil; flow.priceAppearedAt = nil
            statementPlayer?.stop(); flow.owner?.transport("k")
            try await recorder.start(maximumSeconds: 30)
        } catch { message = await errorMessage(error) }
    }
    func stopRecording() async {
        recorder.stop()
        await recordingCompletion?.value
    }
    func finishRecording() async {
        if let failure = recorder.failure {
            message = failure.localizedDescription; recorder.discard(); trainingReady = false
            if !recordingTraining { statementWAV = nil; try? await store.abandonEnrollment(recordID: recordID) }
            return
        }
        guard enabled, !busy, !recorder.recording, !recorder.samples.isEmpty else { return }
        busy = true
        defer { busy = false }
        let turn = recordingTurn
        let id = recordID
        let samples = recorder.samples
        do {
            if recordingTraining {
                let prepared = try await Task.detached(priority: .userInitiated) { try VoiceTrainingAudio.training(samples) }.value
                guard recordingTurn == turn, !Task.isCancelled else { return }
                training = prepared
                trainingReady = true; recorder.discard()
                message = "Training recording is ready. " + speakerMessage
            } else {
                guard (5...30).contains(Double(samples.count) / 48_000) else { throw VoiceLabError.invalidAudio }
                let wav = try await Task.detached(priority: .userInitiated) { try VoiceTrainingAudio.wav(samples) }.value
                guard recordingTurn == turn, !Task.isCancelled else { return }
                try await store.saveStatement(wav, recordID: id)
                guard recordingTurn == turn, !Task.isCancelled else {
                    try? await store.abandonEnrollment(recordID: id)
                    return
                }
                statementWAV = wav; flow.statementSeconds = Double(samples.count) / 48_000
                recorder.discard()
                message = "Statement recorded. Nothing was sent."
            }
        } catch { message = await errorMessage(error); if recordingTraining { trainingReady = false } }
        busy = false
        if recordingTurn == turn, !Task.isCancelled, statementWAV != nil { await prepareCreation() }
    }
    func beginTraining() async {
        guard enabled, statementWAV != nil, !busy, trainingSource == .readAloud else { return }
        message = nil; trainingReady = false; recordingTraining = true; training = []
        do { statementPlayer?.stop(); flow.owner?.transport("k"); try await recorder.start(maximumSeconds: 90) } catch { message = await errorMessage(error) }
    }
    func prepareCreation() async {
        guard enabled, !busy else { return }
        guard speakerReady else { message = VoiceConsentError.speakerUnavailable.localizedDescription; return }
        guard !recorder.recording, let statement, let statementWAV,
              ownVoice, adult, ownVideosOnly, unsavedRecord == nil, pendingCreations.isEmpty else { return }
        busy = true; flow.state = .checking; flow.plan = nil; flow.priceAppearedAt = nil
        defer { busy = false }
        message = nil; keptSeconds = nil
        do {
            if projectAudio == .finding { await analysis?.value }
            if trainingSource == .readAloud && !trainingReady {
                recordingTraining = true; flow.state = .statement
                message = "Statement recorded and kept. Record a read-aloud instead. Nothing was sent."
                return
            }
            let (_, enrollment) = try services()
            let check = try await currentSpeakerCheck()
            try await enrollment.setSpeakerCheck(check)
            var samples = training
            if trainingSource == .project {
                guard case .found(let selection) = projectAudio, let source = trainingProject?.source, let rate = projectRate else { throw VoiceLabError.invalidInput }
                do { samples = try await VoiceTrainingAudio.projectSamples(source: source, sampleRate: rate, spans: selection.selected) }
                catch is CancellationError { throw CancellationError() }
                catch { projectAudio = .unreadable; trainingSource = .readAloud; recordingTraining = true; flow.state = .statement; return }
            }
            let attestations = VoiceConsentRecord.Attestations(ownVoice: ownVoice, adult: adult, ownVideosOnly: ownVideosOnly, acceptedAt: acceptedAt)
            let plan = try await enrollment.preparePlan(recordID: recordID, statement: statement, wav: statementWAV,
                attestations: attestations, displayName: displayName, samples: samples, enabled: enabled)
            guard enabled, showEnrollment || flow.owner == nil else { try await enrollment.cancel(recordID: recordID); return }
            await prepareCapWarning(plan)
            flow.plan = plan; keptSeconds = plan.trainingSeconds
            flow.state = .ready; flow.priceAppearedAt = Date()
            flow.owner?.announce("Ready to create your voice. " + creationCost)
        } catch is CancellationError { flow.state = .statement }
        catch { flow.state = .statement; await creationFailed(error) }
    }
    /// One explicit paid click, bound to the plan prepared locally. Recovery never repeats the statement check.
    func createVoice(now: Date = Date(), keyboard: Bool = false, command: Bool = false, repeated: Bool = false, eventDate: Date? = nil) async {
        guard canCreate, let plan = flow.plan,
              Self.permitsPaidActivation(keyboard: keyboard, command: command, repeated: repeated, appeared: flow.priceAppearedAt, now: now, eventDate: eventDate) else { return }
        busy = true; flow.state = .creating; message = nil; statementPlayer?.stop()
        defer { busy = false }
        app.set("voiceLab.providerConsent.elevenlabs", .bool(true))
        do {
            let (_, enrollment) = try services()
            let record = try await enrollment.execute(plan, approved: true, enabled: enabled, appVersion: AppModel.version)
            flow.plan = nil; flow.recoveryIDs = []; flow.finishedRecord = record; flow.state = .finished
            statementWAV = nil; training = []; recorder.discard(); trainingReady = false
            message = record.status == .verificationRequired ? "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back." : "Your voice is ready."
            flow.owner?.announce(message!)
            await load()
        } catch {
            flow.plan = nil
            if let error = error as? VoiceConsentSaveError {
                unsavedRecord = error.record; flow.finishedRecord = error.record; flow.state = .finished
                message = "ElevenLabs created your voice, but the local consent record could not be saved. Retry saving or Remove This Voice. Do not create it again."
                await load(recover: false)
            } else {
                message = (error is CancellationError || error as? VoiceLabError == .cancelled) ? "Voice creation stopped. Check recovery before trying again." : await errorMessage(error)
                flow.state = .statement
                if error as? VoiceConsentError == .statementMismatch {
                    self.statement = nil; statementWAV = nil; training = []; trainingReady = false; recordingTraining = false
                    try? await enrollment?.cancel(recordID: recordID)
                    // The next recording gets a fresh nonce; no request is repeated.
                }
                flow.recoveryIDs = (try? await store.recoverableEnrollments()) ?? []
                await load(recover: false)
            }
        }
    }
    func startVoiceCreation(keyboard: Bool = false, command: Bool = false, repeated: Bool = false) {
        guard paidAction == nil else { return }
        let activatedAt = Date()
        let eventDate = keyboard ? Self.paidEventDate(timestamp: NSApp.currentEvent?.timestamp, now: activatedAt) : nil
        paidAction = Task { [weak self] in
            guard let self else { return }
            await createVoice(now: activatedAt, keyboard: keyboard, command: command, repeated: repeated, eventDate: eventDate)
            paidAction = nil
        }
    }
    func playStatement() {
        guard !recorder.recording, !busy, let statementWAV else { return }
        do { flow.owner?.transport("k"); statementPlayer = try AVAudioPlayer(data: statementWAV); statementPlayer?.play() }
        catch { message = "This recording couldn't be played. Record it again." }
    }
    private func prepareCapWarning(_ plan: VoiceEnrollmentPlan) async {
        flow.capWarning = nil
        guard let limit = Decimal(string: app.string("voiceLab.monthlyCapUsd.elevenlabs"), locale: Locale(identifier: "en_US_POSIX")) else { return }
        guard let total = await VoiceLabSpendLedger(locations: app.locations).total(provider: "elevenlabs", at: Date()) else {
            flow.capWarning = "Monthly spend couldn't be read. Check your ElevenLabs account before creating your voice."; return
        }
        if VoiceLabMonthlyCap(limit: limit, spent: total.usd).isCrossed(by: plan.quote.estimate) {
            flow.capWarning = VoiceLabCostPresentation.capWarning(cap: limit, providerName: "ElevenLabs")
        }
    }
    static func paidEventDate(timestamp: TimeInterval?, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Date {
        guard let timestamp, timestamp.isFinite, timestamp <= uptime else { return .distantPast }
        return now.addingTimeInterval(timestamp - uptime)
    }
    static func permitsPaidActivation(keyboard: Bool, command: Bool, repeated: Bool, appeared: Date?, now: Date, eventDate: Date? = nil) -> Bool {
        guard !repeated else { return false }
        if keyboard && !command {
            let eventDate = eventDate ?? now
            guard let appeared, eventDate <= now, eventDate.timeIntervalSince(appeared) >= 0.5 else { return false }
        }
        return true
    }
    func recoverVoice(_ id: String) async {
        guard enabled, !busy, speakerReady else { return }
        busy = true; defer { busy = false }
        do {
            let (_, enrollment) = try services()
            let check = try await currentSpeakerCheck()
            try await enrollment.setSpeakerCheck(check)
            let plan = try await enrollment.recoverPlan(recordID: id, enabled: enabled)
            await prepareCapWarning(plan)
            recordID = id; flow.plan = plan; keptSeconds = plan.trainingSeconds
            let wav = try await store.statement(recordID: id)
            let format = try ElevenLabsVoiceLab.validateWAV(wav, maxBytes: 16 * 1_024 * 1_024)
            statementWAV = wav; flow.statementSeconds = Double(format.frames) / Double(format.rate)
            await load(recover: false)
            flow.state = .ready; flow.priceAppearedAt = Date(); message = "Statement already checked. Only creation remains. Nothing was sent."
        } catch { message = await errorMessage(error) }
    }
    /// §6.5.2: project spans that fail the speaker match block with the project copy and offer a read-aloud.
    func creationFailed(_ error: any Error) async {
        if trainingSource == .project, error as? VoiceConsentError == .speakerMismatch {
            projectMismatch = true; message = Self.projectMismatchCopy
        } else { message = await errorMessage(error) }
    }
    /// Record a Read-Aloud: switches to §6.5 (b) and keeps the local statement. The project option stays off: its
    /// spans would fail the same match again.
    func useReadAloud() {
        guard !busy, !recorder.recording else { return }
        trainingSource = .readAloud; message = nil; flow.plan = nil; recordingTraining = true; flow.state = .statement
    }
    func chooseTrainingSource(_ source: TrainingSource) {
        guard !busy, !recorder.recording, source == .readAloud || projectChoiceEnabled else { return }
        trainingSource = source; message = nil; flow.plan = nil
        recordingTraining = source == .readAloud && statementWAV != nil
        if flow.state == .ready { flow.state = .statement }
    }
    /// Opens the job with the editor's project as the §6.5 (a) default.
    func openEnrollment() {
        guard let editor = app.shell.editor else { return }
        editor.openVoiceJob()
    }
    /// The editor's project; its media is offered only when the editor reads it, never for a demo.
    static func trainingProject(editor: EditorModel, name: String) -> TrainingProject {
        let readable = editor.mediaResolved && !editor.mediaUnreadable && !editor.document.demo
        return TrainingProject(project: editor.project, name: name, source: readable ? editor.sourceURL : nil)
    }
    /// §6.5.2: a project with a transcript makes its audio the default and starts the on-device analysis at once.
    func openEnrollment(project: TrainingProject?, startAnalysis: Bool = true) {
        guard !showEnrollment else { return }
        showEnrollment = true
        analysis?.cancel(); analysis = nil; analysisID = UUID()
        trainingProject = project; projectRate = nil; projectMismatch = false; keptSeconds = nil
        projectName = project?.name ?? ""
        guard let project else { projectAudio = .noProject; trainingSource = .readAloud; return }
        if startAnalysis { startProjectAnalysis(project) } else { projectAudio = .noProject }
    }
    private func startProjectAnalysis(_ project: TrainingProject) {
        guard project.project.transcript != nil else { projectAudio = .untranscribed; trainingSource = .readAloud; return }
        guard let source = project.source else { projectAudio = .unreadable; trainingSource = .readAloud; return }
        projectAudio = .finding; trainingSource = .project
        let inputs = VoiceTrainingSpans.inputs(project: project.project), id = analysisID
        analysis = Task.detached(priority: .userInitiated) { [weak self] in
            var rate: Int?, outcome = ProjectAudio.unreadable
            // VoxClip never trains on generated audio: a re-imported export labelled AI modified has no Voice Lab
            // segments left to exclude, so none of its speech is used.
            if VoiceLabDisclosureWriter.isLabelled(source) { outcome = .generated }
            else if let levels = try? await VoiceTrainingAudio.levels(source: source),
                    let selection = try? VoiceTrainingSpans.select(items: inputs.items, excluded: inputs.excluded, frameDb: levels.frameDb, duration: levels.duration) {
                rate = levels.sampleRate; outcome = .found(selection)
            }
            guard !Task.isCancelled else { return }
            await self?.finishAnalysis(outcome, rate: rate, id: id)
        }
    }
    private func finishAnalysis(_ outcome: ProjectAudio, rate: Int?, id: UUID) {
        guard id == analysisID, showEnrollment, projectAudio == .finding else { return }
        projectRate = rate; projectAudio = outcome
        guard !projectAudioUsable else { return }
        if trainingSource == .project { trainingSource = .readAloud }
    }
    private func closeProjectAudio() {
        analysis?.cancel(); analysis = nil; analysisID = UUID()
        trainingProject = nil; projectRate = nil; projectAudio = .noProject; projectName = ""
        trainingSource = .readAloud; projectMismatch = false; keptSeconds = nil
    }
    var hasStatementRecording: Bool { statementWAV != nil }
    var creationCopy: String {
        Self.creationCopy(projectName: trainingSource == .project ? projectName : nil, keptSeconds: keptSeconds, cost: creationCost)
    }
    /// The §6.5.2 create confirmation; project audio names the whole seconds of its spans that passed the speaker match.
    static func creationCopy(projectName: String?, keptSeconds: Double?, cost: String) -> String {
        if let projectName, let keptSeconds {
            return "Checks your plan, then sends the consent recording and \(Int(keptSeconds)) s of speech from \(projectName) to create your own voice. No video is sent. \(cost)"
        }
        return "Checks your plan, then sends the consent recording and training audio to create your own voice. No video is sent. \(cost)"
    }
    var creationCost: String {
        guard let plan = flow.plan else { return "Preparing price…" }
        guard let usd = plan.quote.estimate.usd else { return "Cost unknown — check ElevenLabs pricing" }
        return usd == 0 ? "$0" : VoiceLabCostPresentation.format(usd)
    }
    var creationTitle: String { "Create My Voice · " + creationCost }
    func finishCreation() {
        guard !busy, unsavedRecord == nil else { return }
        resetEnrollmentDraft()
    }
    private func resetEnrollmentDraft() {
        leaveVoiceControls()
        recordID = UUID().uuidString.lowercased()
        statement = nil; statementWAV = nil; training = []; flow.plan = nil; flow.recoveryIDs = []; flow.finishedRecord = nil
        trainingReady = false; recordingTraining = false
        statementPlayer?.stop(); recorder.discard(); showEnrollment = false
        flow.state = .firstUse; flow.priceAppearedAt = nil; flow.capWarning = nil; flow.statementSeconds = 0
        flow.keyDraft = ""; flow.keyChecked = false; flow.keyReady = false; flow.turn += 1
        ownVoice = false; adult = false; ownVideosOnly = false; displayName = ""; script = ""
        trainingSource = .readAloud; projectMismatch = false; message = nil
        closeProjectAudio()
    }
    func cancelEnrollment() async {
        guard !busy else { return }
        recorder.discard()
        do {
            try await enrollment?.cancel(recordID: recordID)
            try await store.withdrawCreation(recordID: recordID, remoteVoiceID: unsavedRecord?.voiceId, region: region ?? .default)
            try await store.abandonEnrollment(recordID: recordID)
        } catch { message = "The statement recording could not be removed. Retry Remove This Voice to finish cleanup."; return }
        unsavedRecord = nil
        resetEnrollmentDraft()
        await load(force: true)
    }
    func withdrawOperation(_ operation: VoiceOperation) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await store.withdrawCreation(recordID: operation.recordID)
            if unsavedRecord?.id == operation.recordID { unsavedRecord = nil }
            await load(force: true)
        } catch { message = "Couldn't finish — Retry"; await load(recover: false) }
    }
    func retrySavingRecord() async {
        guard unsavedRecord != nil, !busy else { return }
        busy = true; defer { busy = false }
        await load(force: true)
        if let record = unsavedRecord, !operations.contains(where: { $0.recordID == record.id && !$0.finished }) {
            unsavedRecord = nil; flow.state = .finished
            flow.finishedRecord = records.first { $0.id == record.id }
            let saved = records.contains { $0.id == record.id && $0.status != .deleted }
            message = saved ? "Consent record saved. No create request was repeated." : "Voice removed. No create request was repeated."
        } else { message = "The consent record still could not be saved. Retry saving or Remove This Voice. Do not create it again." }
    }
    private func errorMessage(_ error: any Error) async -> String {
        if let error = error as? VoiceConsentError { return error.localizedDescription }
        if let error = error as? MicrophoneError { return error.localizedDescription }
        if let error = error as? VoiceLabError {
            if let message = error.accessMessage { return message }
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
    /// A development build: Voice Lab reads an unset switch and beta notice as on, and Rewrite's voice parts need no beta
    /// notice (voice-lab §5). Release builds are never internal; tools/voice-lab/check_release_boundary.py checks it.
    static var internalBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    var voiceLabRewriteEnabled: Bool {
        VoiceLabGate.rewriteEnabled(enabled: bool("voiceLab.enabled"), noticeAccepted: bool("voiceLab.betaNoticeAccepted"), internalBuild: Self.internalBuild)
    }
    var voiceLabLabelPosition: VoiceLabLabelPosition {
        switch string("voiceLab.labelPosition", fallback: "top-right") {
        case "top-left": .topLeft
        case "bottom-left": .bottomLeft
        case "bottom-right": .bottomRight
        default: .topRight
        }
    }
    var voiceLabSettingsVisible: Bool {
        VoiceLabGate.settingsVisible(enabled: bool("voiceLab.enabled"), internalBuild: Self.internalBuild)
    }
}
