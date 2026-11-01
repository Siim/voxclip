import Foundation
import Observation
import VoxClipCore
import VoxClipMedia

/// The transcript buffer owns the choice, download and run. A paid engine never inherits an automatic continuation.
@MainActor @Observable final class InlineTranscription {
    enum Phase: Equatable { case hidden, choosing, running, folded }
    var phase = Phase.hidden
    var engine = "apple"
    var language = "en"
    var modelID = ""
    var remember = true
    var speakers = "off"
    var keyterms = ""
    var key = ""
    var hasKey = false
    var savingKey = false
    var error: String?
    var readiness: Readiness?
    var selectedModel: ModelDescriptor?
    var again = false
    var againConfirmed = false
    var installing: ModelDescriptor?
    var systemDownloading = false
    var lastDownload: ModelDownloadProgress?
    var downloadFailed = false
    var downloadCancelled = false
    var uploadStarted = false
    var progress: TranscriptionProgress?
    var downloadBegan: Date?
    var runStage = 0
    var cancelledNote: String?
    var keyGuard = PaidSendKeyGuard()
    var rate: Double?
    var keytermsSurcharge = 0.0
    var spendToday = 0.0
    var spendUncertain = false
    var pendingCost: Double?
    var completion: String?
    var completedAt: Date?
    @ObservationIgnored var revision = 0
    @ObservationIgnored private var downloadRevision = 0
    @ObservationIgnored var choiceTask: Task<Void, Never>?
    @ObservationIgnored var installTask: Task<Void, Never>?
    @ObservationIgnored private var begun = false
    @ObservationIgnored unowned let model: EditorModel
    @ObservationIgnored var scribeSession: URLSession?
    #if DEBUG
    @ObservationIgnored var readinessOverride: ((TranscriptionPlan) async -> Readiness)?
    @ObservationIgnored var runOverride: ((TranscriptionPlan) async throws -> Transcript)?
    #endif

    init(model: EditorModel) { self.model = model }
    var paid: Bool { engine == "elevenlabs" }
    var isVisible: Bool { phase != .hidden || cancelledNote != nil }
    var isRunning: Bool { phase == .running }
    var isDownloading: Bool { installing != nil || systemDownloading }
    var terms: [String] { keyterms.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var estimate: Double? {
        guard let rate else { return nil }
        let editor: EditorModel = model
        let duration: Double = editor.sourceDuration
        let secondsPerHour: Double = 3_600
        let hours: Double = duration / secondsPerHour
        let multiplier: Double = terms.isEmpty ? 1 : 1 + keytermsSurcharge
        return hours * rate * multiplier
    }
    static func money(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "unavailable" }
        if value > 0 && value < 0.01 { return "< $0.01" }
        let scale = value > 0 ? pow(10, 1 - floor(log10(value))) : 1
        return String(format: "$%.2f", (value * scale).rounded() / scale)
    }
    var price: String { estimate.map { $0 < 0.01 ? Self.money($0) : "≈ " + Self.money($0) } ?? "Price unavailable" }
    var title: String { again ? "Transcribe this video again" : "Transcribe this video" }
    var warning: String { AppDelegate.retranscriptionWarning(for: model.project) }
    var cancelTitle: String { again ? "Cancel" : "Not now" }
    var needsDownload: Bool { if case .needsModels = readiness { return true }; if case .needsSystemAssets = readiness { return true }; return false }
    var canStart: Bool {
        guard phase == .choosing, readiness != nil, !savingKey else { return false }
        if paid { return hasKey && estimate != nil }
        return readiness == .ready || needsDownload
    }
    var primaryTitle: String {
        if again && !againConfirmed { return "Transcribe Again" + (paid ? " · " + price : "") }
        if paid { return (error == nil ? "Upload and Transcribe" : "Retry") + " · " + price }
        if downloadFailed || downloadCancelled || error != nil { return "Retry" }
        return needsDownload ? "Download and Transcribe" : "Transcribe"
    }
    var cancelCopy: String {
        uploadStarted ? "If you cancel now, ElevenLabs may still bill audio it already received." : "Nothing has been sent yet. Cancel now and nothing is billed."
    }
    var sendLine: String {
        if let error { return error }
        if paid { return "Uploads this video's audio to ElevenLabs with your key." }
        if isDownloading { return "Transcription starts by itself when the download finishes: on this Mac, in \(languageName)." }
        if needsDownload { return "Downloads \(selectedModel?.displayName ?? "Apple's \(languageName) speech model") once, then transcribes on this Mac." }
        return "Transcribes on this Mac. Nothing leaves this Mac."
    }
    var languageName: String { language == "auto" ? "the detected language" : Locale.current.localizedString(forLanguageCode: language) ?? language }
    var sendDetail: String {
        if paid {
            let duration = "\(durationLabel(model.sourceDuration)) of sound, no video frames."
            return duration + (model.app.bool("transcription.cloudConsent.elevenlabs") ? "" : " ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. Asked once.")
        }
        if isDownloading { return "Change the language or engine now and that is what runs." }
        if needsDownload, let selectedModel { return Self.publisherTerms(selectedModel) }
        if case .unsupportedLanguage = readiness { return "Choose another language or engine." }
        return "Free. Nothing leaves this Mac."
    }
    static func publisherTerms(_ item: ModelDescriptor) -> String {
        "This model is published by \(item.publisher), not by VoxClip. It downloads from the publisher (\(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))) and runs on this Mac. Licence: \(item.license). By downloading you accept the publisher's terms."
    }
    var keptDownloadCopy: String? {
        guard !paid, downloadFailed || downloadCancelled, let lastDownload, selectedModel?.id == lastDownload.modelID else { return nil }
        let received = ByteCountFormatter.string(fromByteCount: lastDownload.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: lastDownload.totalBytes, countStyle: .file)
        return "\(received) of \(total) kept. Retry continues from there."
    }
    var downloadProgress: ModelDownloadProgress? {
        guard let installing, model.app.modelLibrary.progress?.modelID == installing.id else { return nil }
        return model.app.modelLibrary.progress
    }
    var overallFraction: Double? {
        guard let progress, let fraction = progress.fraction else { return nil }
        switch progress.stage {
        case .preparing: return nil
        case .uploading: return 0.1 + 0.4 * fraction
        case .transcribing: return paid ? 0.5 + 0.45 * fraction : 0.1 + 0.85 * fraction
        case .aligning: return 0.95 + 0.05 * fraction
        }
    }
    var downloadRemaining: String? {
        guard let progress = downloadProgress, progress.receivedBytes > 0, let began = downloadBegan else { return nil }
        let elapsed = Date().timeIntervalSince(began)
        guard elapsed > 2 else { return nil }
        let seconds = Double(max(0, progress.totalBytes - progress.receivedBytes)) * elapsed / Double(progress.receivedBytes)
        return seconds > 60 ? "about \(Int(ceil(seconds / 60))) min left" : "less than a minute left"
    }
    var billingText: String? {
        if let pendingCost { return "ElevenLabs \(Self.money(spendToday)) today · \(pendingCost < 0.01 ? Self.money(pendingCost) : "≈ " + Self.money(pendingCost)) pending" }
        guard spendToday > 0 else { return nil }
        return "ElevenLabs \(spendUncertain ? "up to " : "")\(Self.money(spendToday)) today"
    }

    /// Automatic import is allowed only for a ready free engine, with a known language (or local detection).
    func openOnImport() async {
        guard !begun, !model.transcribed, model.mediaResolved, !model.document.demo else { return }
        begun = true
        await open(automatic: true)
    }
    func open(automatic: Bool = false, again: Bool = false) async {
        guard !isRunning else { return }
        revision += 1
        self.again = again; againConfirmed = false; cancelledNote = nil; completion = nil
        error = nil; downloadFailed = false; downloadCancelled = false
        readiness = nil; keyGuard.reset()
        language = model.project.transcript?.language ?? model.app.string("transcription.language", fallback: "auto")
        let preferred = model.app.string("transcription.engineMode", fallback: "local")
        // Settings' “On this Mac” routes English to Apple's installed engine; a Whisper choice in this block stays explicit.
        engine = preferred == "elevenlabs" ? "elevenlabs" : preferred == "apple" || (preferred == "local" && language == "en") ? "apple" : "local"
        modelID = ""
        phase = .choosing
        await loadPriceAndKey()
        await refreshChoice()
        if automatic && preferred != "ask" && !again && !paid && readiness == .ready && (language != "auto" || engine == "local") {
            startApprovedRun()
        }
    }
    private func loadPriceAndKey() async {
        hasKey = await model.app.providerKeyStore.hasKey(for: "elevenlabs")
        struct Catalog: Decodable {
            struct Engine: Decodable { struct Pricing: Decodable { let perAudioHour: Double; let keytermsSurchargeFraction: Double }; let id: String; let pricing: Pricing? }
            let engines: [Engine]
        }
        if let url = model.app.shared?.root.appendingPathComponent("catalog/transcription-models.json"),
           let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
           let pricing = catalog.engines.first(where: { $0.id == "elevenlabs" })?.pricing,
           pricing.perAudioHour.isFinite, pricing.perAudioHour >= 0 {
            rate = pricing.perAudioHour; keytermsSurcharge = pricing.keytermsSurchargeFraction
        }
        let total = await model.app.transcriptionSpend.total()
        spendToday = total.amount; spendUncertain = total.uncertain
    }
    func choicesChanged() {
        guard !isRunning else { return }
        error = nil; cancelledNote = nil; readiness = nil; keyGuard.reset()
        choiceTask?.cancel()
        choiceTask = Task { [weak self, model] in await self?.refreshChoice(); _ = model }
    }
    func refreshChoice() async {
        let selection = [engine, language, modelID]
        do {
            if modelID.isEmpty { selectedModel = try await model.app.modelLibrary.localModel(language: language) }
            else { selectedModel = model.app.modelLibrary.models.first { $0.id == modelID } }
            let adapter = await adapter()
            let plan = makePlan()
            let status: Readiness
            #if DEBUG
            if let readinessOverride { status = await readinessOverride(plan) } else { status = await adapter.readiness(for: plan) }
            #else
            status = await adapter.readiness(for: plan)
            #endif
            guard !Task.isCancelled, selection == [engine, language, modelID], phase == .choosing else { return }
            readiness = status
            if case .needsKey = status { hasKey = false }
            if case .unsupportedLanguage = status { error = language == "auto" ? "Which language is spoken?" : "\(engine == "apple" ? "Apple Speech" : "Whisper") can't transcribe \(languageName)." }
            if case .unavailable = status { error = "Transcription is not available in this build. Your video and edits are still here." }
            keyGuard.reset()
        } catch { self.error = await model.app.safeError(error) }
    }
    func makePlan() -> TranscriptionPlan {
        TranscriptionPlan(engine: paid ? .elevenlabs : engine == "apple" ? .appleSpeech : .whispercpp,
            model: paid ? "scribe_v2" : engine == "local" ? selectedModel?.id : nil, language: language == "auto" ? .auto : .forced(language),
            options: TranscriptionOptions(diarize: speakers != "off", numSpeakers: Int(speakers), keyterms: terms))
    }
    func adapter() async -> any Transcriber {
        switch engine {
        case "apple": return AppleSpeechTranscriber(locations: model.app.locations)
        case "elevenlabs":
            if let scribeSession, let shared = model.app.shared {
                return await ElevenLabsTranscriber(keys: model.app.secrets, settings: model.app.settings, session: scribeSession, catalog: BundledModelCatalog(shared: shared), logger: model.app.log)
            }
            return await ElevenLabsTranscriber(keys: model.app.secrets, settings: model.app.settings, logger: model.app.log)
        default: return WhisperCppTranscriber(logger: model.app.log)
        }
    }
    func saveKey() async {
        guard !savingKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savingKey = true
        defer { savingKey = false }
        do {
            try await model.app.saveProviderKey(key, for: "elevenlabs")
            key = ""; hasKey = true; error = nil
            await refreshChoice(); keyGuard.reset()
        } catch { self.error = "Couldn't save the key. Try saving it again." }
    }
    func pressReturn(timestamp: TimeInterval, now: TimeInterval, repeatKey: Bool, command: Bool, focusedPrimary: Bool = false) {
        // f25 is destructive: neither a default Return nor ⌘Return is its confirmation.
        guard !repeatKey else { return }
        if again {
            guard focusedPrimary, !command else { return }
        }
        guard !paid || keyGuard.accepts(timestamp: timestamp, now: now, isRepeat: repeatKey, command: command) else { return }
        activate()
    }
    /// The click is approval. Saving a key, consent already on disk and download completion never reach a paid send.
    func activate() {
        guard canStart else { return }
        guard terms.count <= 100, !terms.contains(where: { $0.count > 50 }) else { error = "Use at most 100 keyterms, each up to 50 characters."; return }
        if again && !againConfirmed {
            againConfirmed = true
        }
        if paid {
            model.app.set("transcription.cloudConsent.elevenlabs", .bool(true))
            startApprovedRun(paidApproval: true)
        } else if needsDownload { download() }
        else if readiness == .ready { startApprovedRun() }
    }
    func download() {
        guard !isDownloading else { return }
        error = nil; downloadFailed = false; downloadCancelled = false
        downloadRevision += 1
        downloadBegan = Date()
        let request = downloadRevision
        if engine == "apple" {
            systemDownloading = true
            installTask = Task { [weak self, model] in
                guard let self else { return }
                await model.app.appleSpeechAssets.check(language)
                model.app.appleSpeechAssets.download()
                await model.app.appleSpeechAssets.task?.value
                guard request == downloadRevision, !Task.isCancelled else { return }
                await finishedDownload(installed: model.app.appleSpeechAssets.state == .installed, failure: model.app.appleSpeechAssets.error)
            }
            return
        }
        guard let item = selectedModel else { return }
        installing = item
        installTask = Task { [weak self, model] in
            guard let self else { return }
            let installed = await model.app.modelLibrary.install(item, publisherTermsAccepted: true)
            guard request == downloadRevision, !Task.isCancelled else { return }
            await finishedDownload(installed: installed, failure: model.app.modelLibrary.error)
        }
    }
    func finishedDownload(installed: Bool, failure: String?) async {
        lastDownload = model.app.modelLibrary.lastProgress ?? lastDownload
        installing = nil; systemDownloading = false; installTask = nil
        guard phase == .choosing else { return }
        if !installed {
            downloadFailed = true
            let message = failure ?? "Download cancelled."
            // A background local download must not reword an ElevenLabs upload as a paid Retry.
            if !paid { error = message }
            model.announce(message)
            return
        }
        await refreshChoice()
        // Use the current choice, even if language/model changed while downloading. Paid always waits for its own click.
        if !paid, readiness == .ready, !again || againConfirmed {
            model.announce("Download finished. Transcribing on this Mac.")
            startApprovedRun()
        }
    }
    func cancelDownload() {
        downloadRevision += 1
        lastDownload = downloadProgress ?? model.app.modelLibrary.lastProgress ?? lastDownload
        installTask?.cancel(); installTask = nil
        if let installing { model.app.modelLibrary.cancelTranscriptionDownload(modelID: installing.id) }
        if systemDownloading { model.app.appleSpeechAssets.task?.cancel() }
        installing = nil; systemDownloading = false
        downloadCancelled = true; error = "Download cancelled."
    }
    func notNow() {
        if isRunning { cancel(); return }
        if isDownloading { cancelDownload() }
        revision += 1; choiceTask?.cancel(); phase = again ? .hidden : .folded
        key = ""; model.wantsTranscriptFocus = true
        _ = focusTranscript(in: model.window)
    }
    func cancel() {
        guard isRunning else { notNow(); return }
        model.workTask?.cancel()
    }
    func close() {
        revision += 1; choiceTask?.cancel(); installTask?.cancel(); model.workTask?.cancel()
        if let installing { model.app.modelLibrary.cancelTranscriptionDownload(modelID: installing.id) }
        if systemDownloading { model.app.appleSpeechAssets.task?.cancel() }
        installing = nil; systemDownloading = false; phase = .hidden; key = ""
        pendingCost = nil; model.progress = nil; model.progressFraction = nil; model.progressStage = nil
    }
    func startApprovedRun(paidApproval: Bool = false) {
        guard phase == .choosing, !isRunning, !paid || paidApproval else { return }
        let plan = makePlan(), cost = paid ? estimate : nil
        if remember { model.app.set("transcription.language", .string(language)) }
        model.findTask?.cancel(); model.sendConfirmation.cancel()
        model.rewriteOpenTask?.cancel()
        // Stop new AI work while retaining the review until replacement actually succeeds.
        model.openRewrite?.sending?.cancel()
        model.openRewrite?.actionTask?.cancel()
        model.openRewrite?.takesTask?.cancel()
        phase = .running; error = nil; progress = nil; uploadStarted = false; runStage = 0; pendingCost = cost
        revision += 1
        let request = revision
        model.workTask = Task { [weak self, model] in
            guard let self else { return }
            await performRun(plan: plan, cost: cost, request: request)
            _ = model // Hold the owner until its canceled run has unwound.
        }
    }
}
