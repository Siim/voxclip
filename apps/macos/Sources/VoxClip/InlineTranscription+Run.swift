import Foundation
import VoxClipCore
import VoxClipMedia

extension InlineTranscription {
    func performRun(plan: TranscriptionPlan, cost: Double?, request: Int) async {
        // From extraction through replacement, eviction leaves this source's cache entry alone (architecture §8.2).
        let lease = await model.app.cacheKeys.lease(model.project.media.source.contentKey)
        defer { lease.release() }
        let before = model.project
        var fromCache = false
        var succeeded = false
        do {
            model.progress = "Reading video…"; model.progressStage = .readingVideo
            let transcript: Transcript
            #if DEBUG
            if let runOverride { transcript = try await runOverride(plan) }
            else { (transcript, fromCache) = try await transcribe(plan: plan) }
            #else
            (transcript, fromCache) = try await transcribe(plan: plan)
            #endif
            try Task.checkCancellation()
            guard request == revision else { return }
            guard before == model.project, model.capabilities.writable else {
                throw VoxClipError.transcriptionFailed("The project changed while transcribing. Your current edits are kept. Try again when you are ready.")
            }
            model.replaceTranscript(transcript)
            completedAt = Date()
            completion = "Transcribed \(cost == nil ? "on this Mac" : "with ElevenLabs") · \(transcript.words.count) words"
            model.announce(completion ?? "Transcribed")
            if fromCache && cost != nil { completion = "Using the earlier ElevenLabs transcript of this file (no charge)." }
            succeeded = true
        } catch is CancellationError { cancelledNote = cancellationNote(cost: cost) }
        catch VoxClipError.cancelled { cancelledNote = cancellationNote(cost: cost) }
        catch {
            self.error = await model.app.safeError(error)
            if let failure = error as? VoxClipError, (failure.code == .keyRejected || failure.code == .keyPermissionMissing) { hasKey = false }
            model.announce(self.error ?? "Transcription failed")
        }
        if let cost, !fromCache, uploadStarted {
            let total = await model.app.transcriptionSpend.record(cost, uncertain: !succeeded)
            spendToday = total.amount; spendUncertain = total.uncertain
        }
        guard request == revision else { return }
        pendingCost = nil; model.progress = nil; model.progressFraction = nil; model.progressStage = nil
        phase = succeeded ? .hidden : cancelledNote != nil ? (again ? .hidden : .folded) : .choosing
        keyGuard.reset()
    }
    func cancellationNote(cost: Double?) -> String {
        if cost != nil && uploadStarted {
            return "Cancelled. ElevenLabs may still bill audio it already received. Up to \(Self.money(cost ?? 0)) for this request. Your video is still here."
        }
        return cost != nil ? "Cancelled. Nothing has been sent and nothing is billed. Your video is still here." : "Cancelled. Your video is still here."
    }
    private func transcribe(plan: TranscriptionPlan) async throws -> (Transcript, Bool) {
        let engine = await adapter()
        model.progress = "Extracting audio…"; model.progressStage = .extractingAudio; runStage = 1
        let audio = try await CacheStore(locations: model.app.locations).extractAudio(sourceURL: model.sourceURL, contentKey: model.project.media.source.contentKey, durationSeconds: model.sourceDuration, using: AVAudioExtractor()) { _ in }
        try Task.checkCancellation()
        runStage = 2
        let service = TranscriptionService()
        let watch = Task { [weak self] in
            guard let self else { return }
            var announced = -1
            var previousStage: TranscriptionStage?
            for await value in await service.progress() {
                guard !Task.isCancelled else { return }
                updateProgress(value)
                let percent = Int((overallFraction ?? 0) * 100)
                if value.stage != previousStage || percent / 10 != announced {
                    previousStage = value.stage; announced = percent / 10
                    model.announce(model.progress ?? "")
                    await model.app.log.write(LogEntry(level: .info, category: "transcribe", message: "stage=\(value.stage.rawValue) percent=\(percent)"))
                }
            }
        }
        defer { watch.cancel() }
        let result = try await service.transcribeResult(TranscriptionRequest(plan: plan, audio: audio.audio, contentKey: model.project.media.source.contentKey), using: engine, envelope: audio.envelope)
        return (result.transcript, result.fromCache)
    }
    func updateProgress(_ value: TranscriptionProgress) {
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
    }
}

extension EditorModel {
    func replaceTranscript(_ transcript: Transcript) {
        findTask?.cancel(); sendConfirmation.cancel(); closeRewrite(returnFocus: false)
        fallbackNote = nil; focusedSuggestion = nil; proposal = nil
        selectedWordIDs = []; selectedPauseIDs = []; correctionID = nil; correctionText = ""
        var next = project
        next.replaceTranscript(transcript)
        replace(next, name: "Transcribe video")
    }
}
