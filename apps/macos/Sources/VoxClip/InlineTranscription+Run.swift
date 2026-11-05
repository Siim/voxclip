import Foundation
import VoxClipCore
import VoxClipMedia

extension InlineTranscription {
    @MainActor final class ApprovedRun {
        let revision: Int
        let project: Project
        let plan: TranscriptionPlan
        let cost: Double?
        let approvedAt = Date()
        let evidence = TranscriptionEvidence()
        var cancelled = false
        var watch: Task<Void, Never>?
        var spendRecorded = false

        init(revision: Int, project: Project, plan: TranscriptionPlan, cost: Double?) {
            self.revision = revision; self.project = project; self.plan = plan; self.cost = cost
        }
    }

    func isCurrent(_ request: ApprovedRun) -> Bool { request.revision == revision && activeRun === request }

    func validate(_ request: ApprovedRun) throws {
        try Task.checkCancellation()
        guard isCurrent(request), !request.cancelled else { throw CancellationError() }
        guard request.project == model.project, mediaReady else {
            throw VoxClipError.transcriptionFailed("The project changed while transcribing. Your current edits are kept. Try again when you are ready.")
        }
    }

    func performRun(_ request: ApprovedRun) async {
        // From extraction through replacement, eviction leaves this source's cache entry alone (architecture §8.2).
        let contentKey = request.project.media.source.contentKey
        let lease: CacheKeyLease
        #if DEBUG
        if let leaseOverride { lease = await leaseOverride(contentKey) }
        else { lease = await model.app.cacheKeys.lease(contentKey) }
        #else
        lease = await model.app.cacheKeys.lease(contentKey)
        #endif
        defer { lease.release() }
        var succeeded = false
        do {
            try validate(request)
            model.progress = "Reading video…"; model.progressStage = .readingVideo
            let result: TranscriptionResult
            #if DEBUG
            if let requestRunOverride { result = try await requestRunOverride(request) }
            else if let runOverride { result = TranscriptionResult(transcript: try await runOverride(request.plan)) }
            else { result = try await transcribe(request) }
            #else
            result = try await transcribe(request)
            #endif
            if result.fromCache { request.evidence.recordCacheHit() }
            try validate(request)
            let transcript = result.transcript
            model.replaceTranscript(transcript)
            // On drop: a free transcription goes straight on to Find Clips when the AI is free too (design.md §6.6).
            if startedOnImport, request.cost == nil { startedOnImport = false; model.findClipsIfFree() }
            completedAt = Date()
            completion = "Transcribed \(request.cost == nil ? "on this Mac" : "with ElevenLabs") · \(transcript.words.count) words"
            if result.fromCache && request.cost != nil { completion = "Using the earlier ElevenLabs transcript of this file (no charge)." }
            model.announce(completion ?? "Transcribed")
            succeeded = true
        } catch is CancellationError {
            if isCurrent(request) { cancelledNote = cancellationNote(request) }
        } catch VoxClipError.cancelled {
            if isCurrent(request) { cancelledNote = cancellationNote(request) }
        } catch {
            if isCurrent(request) {
                let message: String
                #if DEBUG
                if let runErrorOverride { message = await runErrorOverride(error) }
                else { message = await model.app.safeError(error) }
                #else
                message = await model.app.safeError(error)
                #endif
                if isCurrent(request), request.cancelled || Task.isCancelled {
                    cancelledNote = cancellationNote(request)
                } else if isCurrent(request) {
                    self.error = message
                    if let failure = error as? VoxClipError, (failure.code == .keyRejected || failure.code == .keyPermissionMissing) { hasKey = false }
                    model.announce(message)
                }
            }
        }
        request.watch?.cancel(); await request.watch?.value; request.watch = nil
        let evidence = request.evidence.snapshot
        if let cost = request.cost, !evidence.fromCache, evidence.uploadStarted, !request.spendRecorded {
            request.spendRecorded = true
            let total = await model.app.transcriptionSpend.record(cost, uncertain: !succeeded, at: request.approvedAt)
            if isCurrent(request) { spendToday = total.amount; spendUncertain = total.uncertain }
        }
        guard isCurrent(request) else { return }
        pendingCost = nil; model.progress = nil; model.progressFraction = nil; model.progressStage = nil
        phase = succeeded ? .hidden : cancelledNote != nil ? (again ? .hidden : .folded) : .choosing
        keyGuard.reset(); activeRun = nil
    }
    func cancellationNote(_ request: ApprovedRun) -> String {
        let evidence = request.evidence.snapshot
        if let cost = request.cost, evidence.uploadStarted, !evidence.fromCache {
            return "Cancelled. ElevenLabs may still bill audio it already received. Up to \(Self.money(cost)) for this request. Your video is still here."
        }
        return request.cost != nil ? "Cancelled. Nothing has been sent and nothing is billed. Your video is still here." : "Cancelled. Your video is still here."
    }
    private func transcribe(_ request: ApprovedRun) async throws -> TranscriptionResult {
        let engine = await adapter(for: request.plan)
        try validate(request)
        model.progress = "Extracting audio…"; model.progressStage = .extractingAudio; runStage = 1
        let source = request.project.media.source
        let audio = try await CacheStore(locations: model.app.locations).extractAudio(sourceURL: URL(fileURLWithPath: source.absolutePath), contentKey: source.contentKey, durationSeconds: source.durationSeconds, using: AVAudioExtractor()) { _ in }
        try validate(request)
        runStage = 2
        let service = TranscriptionService(locations: model.app.locations)
        let stream = await service.progress()
        try validate(request)
        let watch = watchProgress(stream, request: request)
        request.watch = watch
        do {
            let result = try await service.transcribeResult(TranscriptionRequest(plan: request.plan, audio: audio.audio, contentKey: source.contentKey), using: engine, envelope: audio.envelope,
                evidence: request.evidence, validate: { try await self.validate(request) })
            watch.cancel(); await watch.value; request.watch = nil
            return result
        } catch {
            watch.cancel(); await watch.value; request.watch = nil
            throw error
        }
    }
    func watchProgress(_ stream: AsyncStream<TranscriptionProgress>, request: ApprovedRun) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            var announced = -1
            var previousStage: TranscriptionStage?
            for await value in stream {
                guard !Task.isCancelled else { return }
                guard updateProgress(value, request: request) else { continue }
                let percent = Int((overallFraction ?? 0) * 100)
                if value.stage != previousStage || percent / 10 != announced {
                    previousStage = value.stage; announced = percent / 10
                    model.announce(model.progress ?? "")
                    await model.app.log.write(LogEntry(level: .info, category: "transcribe", message: "stage=\(value.stage.rawValue) percent=\(percent)"))
                }
            }
        }
    }
    @discardableResult func updateProgress(_ value: TranscriptionProgress, request: ApprovedRun) -> Bool {
        let paid = request.plan.engine == .elevenlabs
        if paid, value.stage == .uploading { request.evidence.recordUploadStarted() }
        guard isCurrent(request), !request.cancelled else { return false }
        let evidence = request.evidence.snapshot
        uploadStarted = evidence.uploadStarted && !evidence.fromCache
        progress = value
        let percent = Int((overallFraction ?? 0) * 100)
        model.progressFraction = overallFraction
        model.progressStage = value.stage == .aligning ? .aligning : .transcribing
        switch value.stage {
        case .preparing: model.progress = "Preparing the speech model…"
        case .uploading:
            uploadStarted = true; runStage = 2
            model.progress = "Transcribing with ElevenLabs · \(percent)%"
        case .transcribing:
            runStage = paid ? 3 : 2
            // A provider may go straight from its cached response to alignment; the cache flag prevents charging it.
            let label = paid ? "Transcribing with ElevenLabs" : "Transcribing on this Mac"
            model.progress = overallFraction.map { "\(label) · \(Int($0 * 100))%" } ?? "\(label)…"
        case .aligning: runStage = paid ? 4 : 3; model.progress = "Aligning words…"
        }
        return true
    }
}

extension EditorModel {
    /// Find Clips with no click, after a free transcription on drop, when the chosen AI costs nothing extra: a CLI on its
    /// plan, a local server or Apple on-device. An API key's send still asks first, inline, when Find Clips is pressed.
    func findClipsIfFree() {
        guard capabilities.ai, project.ai.results.isEmpty, suggestedClips.isEmpty, !finding,
              let connector = ConnectorID(rawValue: app.string("llm.connector")),
              app.providers.contains(where: { $0.id == connector.rawValue }),
              case .inline(let amount) = app.llmSendKind(connector), amount.isEmpty else { return }
        findClips()
    }
    func replaceTranscript(_ transcript: Transcript) {
        findTask?.cancel(); sendConfirmation.cancel(); closeRewrite(returnFocus: false)
        fallbackNote = nil; focusedSuggestion = nil; proposal = nil
        selectedWordIDs = []; selectedPauseIDs = []; correctionID = nil; correctionText = ""
        var next = project
        next.replaceTranscript(transcript)
        replace(next, name: "Transcribe video")
    }
}
