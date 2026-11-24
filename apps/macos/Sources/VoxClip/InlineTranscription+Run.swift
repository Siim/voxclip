import Foundation
import VoxClipCore
import VoxClipMedia

extension InlineTranscription {
    @MainActor final class ApprovedRun {
        let revision: Int
        let project: Project
        let plan: TranscriptionPlan
        let cost: Double?
        let alignmentRetry: TranscriptionAlignmentRetry?
        var confirmedTranscript: Transcript?
        var suspendedRewrite: (session: RewriteSession, proposal: TranscriptProposal?)?
        let approvedAt = Date()
        let evidence = TranscriptionEvidence()
        var cancelled = false
        var watch: Task<Void, Never>?
        var spendRecorded = false

        init(revision: Int, project: Project, plan: TranscriptionPlan, cost: Double?, alignmentRetry: TranscriptionAlignmentRetry? = nil) {
            self.revision = revision; self.project = project; self.plan = plan; self.cost = cost
            self.alignmentRetry = alignmentRetry
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
        var draftFind: Task<Void, Never>?
        defer { if !succeeded { draftFind?.cancel() } }
        do {
            try validate(request)
            let result: TranscriptionResult
            if let retry = request.alignmentRetry {
                model.progress = "Aligning words…"; model.progressStage = .aligning
                model.announce("Aligning words…")
                result = TranscriptionResult(transcript: try await retry.finish(), fromCache: true)
            } else {
                model.progress = "Reading video…"; model.progressStage = .readingVideo
                let clock = model.claudeModeWaitsForTranscript ? model.claudeMode.clock : nil
                let audio = try await loadRunAudio(request, clock: clock)
                let engine = await adapter(for: request.plan)
                if confirmsClaudeTranscript, request.plan.engine != .appleSpeech {
                    if let draft = try await appleDraft(request, audio: audio, confirmation: engine, clock: clock) {
                        draftFind = model.findClipsOnDraft(draft, request: request)
                    }
                }
                clock?.begin(.confirm)
                defer { clock?.end(.confirm) }
                result = try await recognize(request.plan, using: engine, request: request, audio: audio)
            }
            if result.fromCache { request.evidence.recordCacheHit() }
            try validate(request)
            let transcript = result.transcript
            request.confirmedTranscript = transcript
            let foundOnDraft = draftFind != nil && draftFind == model.findTask
            model.replaceTranscript(transcript, preserveFind: foundOnDraft)
            // A video of the owner teaches their voice's guard, on this Mac and free (ADR-R41).
            model.app.voiceLabSession.learnFromTranscribed(model.project, media: model.sourceURL)
            // On drop: a free transcription goes straight on to Find Clips when the AI is free too (design.md §6.7); in
            // Claude mode a newly opened video goes on after any transcription, then Claude makes its clips (§6.6).
            if (startedOnImport && request.cost == nil) || model.claudeModeWaitsForTranscript {
                startedOnImport = false
                if foundOnDraft { model.claudeMode.clock?.end(.transcribe) }
                else { model.claudeModeTranscribed(started: model.findClipsIfFree()) }
            }
            completedAt = Date()
            completion = "Transcribed \(request.cost == nil ? "on this Mac" : "with ElevenLabs") · \(transcript.words.count) words"
            if result.fromCache && request.plan.engine == .elevenlabs { completion = "Using the earlier ElevenLabs transcript of this file (no charge)." }
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
                else { message = await model.app.safeError(error, context: .transcribe) }
                #else
                message = await model.app.safeError(error, context: .transcribe)
                #endif
                if isCurrent(request), request.cancelled || Task.isCancelled {
                    cancelledNote = cancellationNote(request)
                } else if isCurrent(request) {
                    if let retry = request.alignmentRetry ?? request.evidence.snapshot.alignmentRetry,
                       request.project == model.project, mediaReady {
                        pendingAlignment = (request.project, retry)
                        self.error = "Couldn't finish aligning the words. ElevenLabs' words are saved. Your media and edits are safe."
                    } else { self.error = message }
                    if let failure = error as? VoxClipError, (failure.code == .keyRejected || failure.code == .keyPermissionMissing) { hasKey = false }
                    model.announce(self.error ?? message)
                }
            }
        }
        request.watch?.cancel(); await request.watch?.value; request.watch = nil
        let evidence = request.evidence.snapshot
        if let cost = request.cost, !evidence.fromCache, evidence.uploadStarted, !request.spendRecorded {
            request.spendRecorded = true
            let total = await model.app.transcriptionSpend.record(cost, uncertain: !succeeded && evidence.alignmentRetry == nil, at: request.approvedAt)
            if isCurrent(request) { spendToday = total.amount; spendUncertain = total.uncertain }
        }
        guard isCurrent(request) else { return }
        pendingCost = nil; model.progress = nil; model.progressFraction = nil; model.progressStage = nil
        if succeeded { pendingAlignment = nil; phase = .hidden }
        else if cancelledNote != nil && request.alignmentRetry == nil { phase = again ? .hidden : .folded }
        else { phase = .choosing }
        settleRewrite(request, restore: !succeeded)
        keyGuard.reset(); activeRun = nil
    }

    func settleRewrite(_ request: ApprovedRun, restore: Bool) {
        guard let suspended = request.suspendedRewrite else { return }
        request.suspendedRewrite = nil
        if restore, suspended.session.isOpen, model.openRewrite == nil {
            model.proposal = suspended.proposal
            model.openRewrite = suspended.session
        } else {
            suspended.session.close()
        }
    }
    func cancellationNote(_ request: ApprovedRun) -> String {
        if request.alignmentRetry != nil { return "Cancelled. Your saved words, media and edits are safe." }
        let evidence = request.evidence.snapshot
        if let cost = request.cost, evidence.uploadStarted, !evidence.fromCache {
            return "Cancelled. ElevenLabs may still bill audio it already received. Up to \(Self.money(cost)) for this request. Your video is still here."
        }
        return request.cost != nil ? "Cancelled. Nothing has been sent and nothing is billed. Your video is still here." : "Cancelled. Your video is still here."
    }
    private func loadRunAudio(_ request: ApprovedRun, clock: ClaudeModeClock?) async throws -> AudioExtractionResult? {
        #if DEBUG
        if !runOverrideUsesAudio, requestRunOverride != nil || runOverride != nil { return nil }
        #endif
        try validate(request)
        model.progress = "Extracting audio…"; model.progressStage = .extractingAudio; runStage = 1
        let source = request.project.media.source
        clock?.begin(.audio)
        defer { clock?.end(.audio) }
        let audio = try await CacheStore(locations: model.app.locations).extractAudio(sourceURL: URL(fileURLWithPath: source.absolutePath), contentKey: source.contentKey, durationSeconds: source.durationSeconds, using: AVAudioExtractor()) { _ in }
        try validate(request)
        return audio
    }

    private func appleDraft(_ request: ApprovedRun, audio: AudioExtractionResult?, confirmation: any Transcriber,
                            clock: ClaudeModeClock?) async throws -> Transcript? {
        var language = request.plan.language
        if language == .auto, let audio, let whisper = confirmation as? WhisperCppTranscriber {
            let probe = TranscriptionRequest(plan: request.plan, audio: audio.audio, contentKey: request.project.media.source.contentKey)
            if let detected = try? await whisper.detectLanguage(probe), detected.probability >= 0.5 {
                language = .forced(detected.language)
            }
        }
        try validate(request)
        guard case .forced = language else { appleDraftAvailability = .unavailable; return nil }
        clock?.begin(.draft)
        defer { clock?.end(.draft) }
        let plan = TranscriptionPlan(engine: .appleSpeech, language: language)
        let engine = await adapter(for: plan)
        guard await status(for: plan, using: engine) == .ready else { appleDraftAvailability = .unavailable; return nil }
        try validate(request)
        do {
            let draft = try await recognize(plan, using: engine, request: request, audio: audio)
            try validate(request)
            appleDraftAvailability = .ready
            return draft.transcript
        } catch {
            try validate(request)
            appleDraftAvailability = .unavailable
            return nil
        }
    }

    private func recognize(_ plan: TranscriptionPlan, using engine: any Transcriber, request: ApprovedRun,
                           audio: AudioExtractionResult?) async throws -> TranscriptionResult {
        try validate(request)
        let draft = plan.engine == .appleSpeech && request.plan.engine != .appleSpeech
        #if DEBUG
        if let requestRunOverride, !draft { return try await requestRunOverride(request) }
        if let runOverride { return TranscriptionResult(transcript: try await runOverride(plan)) }
        #endif
        guard let audio else { throw VoxClipError.transcriptionFailed("Audio is unavailable") }
        let service = TranscriptionService(locations: model.app.locations)
        let transcription = TranscriptionRequest(plan: plan, audio: audio.audio, contentKey: request.project.media.source.contentKey)
        if draft {
            return try await service.transcribeResult(transcription, using: engine, envelope: audio.envelope,
                                                      validate: { try await self.validate(request) })
        }
        runStage = 2
        let stream = await service.progress()
        try validate(request)
        let watch = watchProgress(stream, request: request)
        request.watch = watch
        do {
            let result = try await service.transcribeResult(transcription, using: engine, envelope: audio.envelope,
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
    /// Returns whether Find Clips started.
    var canFindClipsIfFree: Bool {
        guard capabilities.ai, project.ai.results.isEmpty, suggestedClips.isEmpty, !finding,
              let connector = ConnectorID(rawValue: app.string("llm.connector")),
              app.providers.contains(where: { $0.id == connector.rawValue }),
              case .inline(let amount) = app.llmSendKind(connector), amount.isEmpty else { return false }
        return true
    }
    @discardableResult func findClipsIfFree(retrying: Bool = false) -> Bool {
        guard canFindClipsIfFree else { return false }
        let previous = findTask
        if retrying { retryFindClips() } else { findClips() }
        return findTask != previous
    }
    func replaceTranscript(_ transcript: Transcript, preserveFind: Bool = false) {
        let source = project.media.source, previous = project.transcript
        guard closeRewrite(returnFocus: false, onDiscard: { [weak self] in
            guard let self, project.media.source == source, project.transcript == previous else { return }
            replaceTranscript(transcript, preserveFind: preserveFind)
        }) else { return }
        claudeMode.cancelFindContinuation()
        if !preserveFind { findTask?.cancel(); sendConfirmation.cancel() }
        fallbackNote = nil; focusedSuggestion = nil; proposal = nil
        selectedWordIDs = []; selectedPauseIDs = []; correctionID = nil; correctionText = ""
        var next = project
        next.replaceTranscript(transcript)
        replace(next, name: "Transcribe video")
        // The whole video's frames are looked at now, while Find Clips runs (ADR-R48); nothing waits for them.
        startFramePass()
    }
}
