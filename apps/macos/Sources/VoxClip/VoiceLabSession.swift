import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

@MainActor @Observable final class VoiceLabSession {
    enum Request: Identifiable, Equatable {
        case subscription, verify, create, delete(String), removeLocal(String), stopLooking(UUID)
        var id: String { String(describing: self) }
        var title: String {
            switch self { case .subscription: "Check ElevenLabs account"; case .verify: "Verify statement"; case .create: "Create your voice"; case .delete: "Delete voice"; case .removeLocal: "Remove from VoxClip only"; case .stopLooking: "I've checked my ElevenLabs account — stop looking" }
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
    static let chooseTrainingCopy = "Statement verified. Choose your training audio next."
    static let readAloudNextCopy = "Statement verified. Record your training read-aloud next."
    /// The Rewrite panel's voice row in a project whose language has no calibrated speaker check (§6.5.2).
    static let languageUnavailableCopy = "Your voice can't be used in this project's language yet. It works in English projects."
    static let noticeCopy = "Your voice clone is created in your ElevenLabs account and stays there. ElevenLabs' terms let it use uploaded content, including your voice, to improve its services; you can opt out of training in your ElevenLabs account, but the opt-out is not retroactive. You can delete the voice at any time from VoxClip or ElevenLabs. ElevenLabs' Prohibited Use Policy applies, including its rules on political content."
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
    /// §6.5: where the training samples come from. The live consent statement is recorded and verified either way.
    enum TrainingSource: String, Hashable { case project, readAloud }
    /// §6.5.2: the editor's project as the sheet found it.
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
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let store: VoiceConsentStore
    @ObservationIgnored private var client: ElevenLabsVoiceLab?
    @ObservationIgnored private var enrollment: VoiceEnrollment?
    @ObservationIgnored private let reconciler: VoiceOperationReconciler
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var region: ElevenLabsRegion?
    @ObservationIgnored private var statementWAV: Data?
    @ObservationIgnored private var training: [VoiceTrainingSample] = []
    @ObservationIgnored private var quote: VoiceLabQuote?
    @ObservationIgnored private var verificationQuote: VoiceLabQuote?
    @ObservationIgnored private var acceptedAt = Date()
    init(app: AppModel) {
        self.app = app; self.store = VoiceConsentStore(locations: app.locations)
        let secrets = app.secrets; let logger = app.log
        reconciler = VoiceOperationReconciler(store: store, regionIsCurrent: { region in
            await MainActor.run { app.string("transcription.elevenlabs.region", fallback: "default") == region.rawValue }
        }) { ElevenLabsVoiceLab(keys: secrets, region: $0, logger: logger) }
    }
    #if DEBUG
    init(app: AppModel, store: VoiceConsentStore, reconciler: VoiceOperationReconciler? = nil) {
        self.app = app; self.store = store
        let secrets = app.secrets; let logger = app.log
        self.reconciler = reconciler ?? VoiceOperationReconciler(store: store) { ElevenLabsVoiceLab(keys: secrets, region: $0, logger: logger) }
    }
    func stageVerificationForTests(statement: VoiceConsentStatement, wav: Data, client: ElevenLabsVoiceLab) {
        self.statement = statement; statementWAV = wav
        self.client = client; region = client.region
        enrollment = VoiceEnrollment(store: store, client: client, reconciler: reconciler)
    }
    #endif
    func refreshEnabledState() async {
        guard enabled else { records = []; deleting = []; operations = []; return }
        await load()
        if subscription == nil { request(.subscription) }
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
    var canCreate: Bool { enabled && speakerReady && !busy && verified && trainingAvailable && unsavedRecord == nil && pendingCreations.isEmpty }
    private var trainingAvailable: Bool { trainingSource == .project ? projectAudioUsable && !projectMismatch : trainingReady }
    /// The sheet offers the two-choice picker: a project with a transcript is open.
    var offersProjectAudio: Bool { projectAudio != .noProject && projectAudio != .untranscribed }
    var projectAudioUsable: Bool {
        if case .found(let selection) = projectAudio { selection.status == .ok } else { false }
    }
    var projectChoiceEnabled: Bool { (projectAudioUsable || projectAudio == .finding) && !projectMismatch }
    /// After verification: a choice only when the project option can be taken.
    var verifiedCopy: String { projectChoiceEnabled ? Self.chooseTrainingCopy : Self.readAloudNextCopy }
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
    @discardableResult
    func request(_ action: Request) -> Task<Void, Never>? {
        if (action == .verify || action == .create) && !speakerReady { message = VoiceConsentError.speakerUnavailable.localizedDescription; return nil }
        guard VoiceLabGate.canEnroll(enabled: enabled, busy: busy), !recorder.recording else { return nil }
        if action == .verify {
            guard let statementWAV, let statement else { return nil }
            busy = true
            return Task {
                defer { busy = false }
                do {
                    let (client, _) = try services()
                    verificationQuote = try await client.prepareConsentVerification(wav: statementWAV, language: statement.language, requestID: UUID())
                    if enabled { confirmation = action }
                } catch { message = await errorMessage(error) }
            }
        }
        confirmation = action
        return nil
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
            if action == .verify || action == .create {
                guard speakerReady else { throw VoiceConsentError.speakerUnavailable }
                let check = try await app.speakerModelLibrary.check(language: enrollmentLanguage)
                guard check.available else { throw VoiceConsentError.speakerUnavailable }
                let (_, enrollment) = try services()
                try await enrollment.setSpeakerCheck(check)
            }
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
                try await enrollment.verify(recordID: recordID, statement: statement, wav: statementWAV, attestations: attestations, approved: true, enabled: enabled, verificationQuote: verificationQuote)
                verified = true; recorder.discard()
                message = verifiedCopy
            case .create:
                guard let quote else { throw VoiceConsentError.speakerUnavailable }
                subscription = try await client.plan()
                let record = try await enrollment.create(quote: quote, approved: true, enabled: enabled, appVersion: AppModel.version)
                finishCreation()
                message = record.status == .verificationRequired ? "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back." : "Your voice is ready."
                await load()
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
            if action == .create {
                let savedStatement = try? await store.statement(recordID: recordID)
                trainingReady = !training.isEmpty && savedStatement != nil
                quote = nil; keptSeconds = nil
                await load(recover: false)
            }
            if case .delete = action { await load(recover: false) }
            if action == .verify {
                verified = false; statementWAV = nil; recorder.discard()
                try? await enrollment?.cancel(recordID: recordID)
                statement = nil
            }
        }
    }
    func beginStatement() async {
        guard speakerReady else { message = VoiceConsentError.speakerUnavailable.localizedDescription; return }
        guard canRecord, planMessage == nil else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            guard try await app.speakerModelLibrary.check(language: enrollmentLanguage).available else { throw VoiceConsentError.speakerUnavailable }
            guard let shared = app.shared else { throw VoxClipError.sharedResourcesMissing }
            if let enrollment { try await enrollment.cancel(recordID: recordID) }
            try await store.abandonEnrollment(recordID: recordID)
            recordID = UUID().uuidString.lowercased()
            let selected = enrollmentLanguage
            let words = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/nonce-words-\(selected).txt"), encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
            var rng = SystemRandomNumberGenerator()
            let data = try VoiceConsentText(shared: shared)
            statement = try data.statement(name: displayName, language: selected, date: Date(), words: words, rng: &rng)
            script = try String(contentsOf: shared.root.appendingPathComponent("voice-lab/scripts-\(selected).txt"), encoding: .utf8)
            acceptedAt = Date(); verified = false; trainingReady = false; statementWAV = nil; training = []; recordingTraining = false; keptSeconds = nil
            try await recorder.start(maximumSeconds: 30)
        } catch { message = await errorMessage(error) }
    }
    func stopRecording() async {
        recorder.stop()
        await finishRecording()
    }
    func finishRecording() async {
        if let failure = recorder.failure {
            message = failure.localizedDescription; recorder.discard(); trainingReady = false
            if !recordingTraining { statementWAV = nil; try? await store.abandonEnrollment(recordID: recordID) }
            return
        }
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
        guard enabled, verified, !busy, trainingSource == .readAloud else { return }
        message = nil; trainingReady = false; recordingTraining = true; training = []
        do { try await recorder.start(maximumSeconds: 90) } catch { message = await errorMessage(error) }
    }
    func prepareCreation() async {
        guard canCreate else { return }
        busy = true; defer { busy = false }
        message = nil; keptSeconds = nil
        do {
            let (_, enrollment) = try services()
            let check = try await app.speakerModelLibrary.check(language: statement?.language ?? "en")
            try await enrollment.setSpeakerCheck(check)
            var samples = training
            if trainingSource == .project {
                guard case .found(let selection) = projectAudio, let source = trainingProject?.source, let rate = projectRate else { throw VoiceLabError.invalidInput }
                // Span WAVs stay in memory: the enrollment keeps the prepared request until it is sent or cancelled.
                do { samples = try await VoiceTrainingAudio.projectSamples(source: source, sampleRate: rate, spans: selection.selected) }
                catch is CancellationError { return }
                // The line under the training choice now says so; the message stays empty to avoid repeating it.
                catch { projectAudio = .unreadable; trainingSource = .readAloud; return }
            }
            let prepared = try await enrollment.prepare(recordID: recordID, displayName: displayName, samples: samples, enabled: enabled)
            quote = prepared
            keptSeconds = await enrollment.trainingSeconds(quote: prepared)
            confirmation = .create
        } catch { await creationFailed(error) }
    }
    /// §6.5.2: project spans that fail the speaker match block with the project copy and offer a read-aloud.
    func creationFailed(_ error: any Error) async {
        if trainingSource == .project, error as? VoiceConsentError == .speakerMismatch {
            projectMismatch = true; message = Self.projectMismatchCopy
        } else { message = await errorMessage(error) }
    }
    /// Record a Read-Aloud: switches to §6.5 (b) and keeps the verified statement. The project option stays off: its
    /// spans would fail the same match again.
    func useReadAloud() {
        guard !busy, !recorder.recording else { return }
        trainingSource = .readAloud; message = nil
    }
    func chooseTrainingSource(_ source: TrainingSource) {
        guard !busy, !recorder.recording, source == .readAloud || projectChoiceEnabled else { return }
        trainingSource = source; message = nil
    }
    /// Opens the sheet with the editor's project as the §6.5 (a) default.
    func openEnrollment() {
        openEnrollment(project: app.shell.editor.map { Self.trainingProject(editor: $0, name: app.shell.projectTitle) })
    }
    /// The editor's project; its media is offered only when the editor reads it, never for a demo.
    static func trainingProject(editor: EditorModel, name: String) -> TrainingProject {
        let readable = editor.mediaResolved && !editor.mediaUnreadable && !editor.document.demo
        return TrainingProject(project: editor.project, name: name, source: readable ? editor.sourceURL : nil)
    }
    /// §6.5.2: a project with a transcript makes its audio the default and starts the on-device analysis at once.
    func openEnrollment(project: TrainingProject?) {
        guard !showEnrollment else { return }
        showEnrollment = true
        analysis?.cancel(); analysis = nil; analysisID = UUID()
        trainingProject = project; projectRate = nil; projectMismatch = false; keptSeconds = nil
        projectName = project?.name ?? ""
        guard let project else { projectAudio = .noProject; trainingSource = .readAloud; return }
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
        if message == Self.chooseTrainingCopy { message = Self.readAloudNextCopy }
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
        guard let quote else { return "Check ElevenLabs pricing before creating your voice." }
        switch VoiceLabCostPresentation.kind(quote.estimate, isLipSync: false, providerName: "ElevenLabs") {
        case .inline(let amount): return amount.isEmpty ? "This action is free." : amount
        case .confirm(let copy): return copy
        }
    }
    var verificationCost: String {
        guard let verificationQuote else { return "VoxClip can't tell what this costs. Check ElevenLabs's pricing." }
        switch VoiceLabCostPresentation.kind(verificationQuote.estimate, isLipSync: false, providerName: "ElevenLabs") {
        case .inline(let amount): return amount.isEmpty ? "This action is free." : amount
        case .confirm(let copy): return copy
        }
    }
    func finishCreation() {
        recordID = UUID().uuidString.lowercased()
        statement = nil; statementWAV = nil; training = []; quote = nil
        verified = false; trainingReady = false; recordingTraining = false
        recorder.discard(); showEnrollment = false
        closeProjectAudio()
    }
    func cancelEnrollment() async {
        guard !busy else { return }
        recorder.discard()
        do {
            try await store.withdrawCreation(recordID: recordID, remoteVoiceID: unsavedRecord?.voiceId, region: region ?? .default)
            try await enrollment?.cancel(recordID: recordID)
            try await store.abandonEnrollment(recordID: recordID)
        } catch { message = "The statement recording could not be removed. Retry Remove This Voice to finish cleanup."; return }
        unsavedRecord = nil
        statementWAV = nil; training = []; verified = false; trainingReady = false; statement = nil; quote = nil
        showEnrollment = false
        closeProjectAudio()
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
            unsavedRecord = nil; finishCreation()
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
    var voiceLabRewriteEnabled: Bool {
        VoiceLabGate.rewriteEnabled(enabled: bool("voiceLab.enabled"), noticeAccepted: bool("voiceLab.betaNoticeAccepted"), internalBuild: RewriteEntryPolicy.buildEnabled)
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
        #if DEBUG
        VoiceLabGate.settingsVisible(enabled: bool("voiceLab.enabled"), internalBuild: true)
        #else
        VoiceLabGate.settingsVisible(enabled: bool("voiceLab.enabled"), internalBuild: false)
        #endif
    }
}
