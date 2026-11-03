import Foundation
import VoxClipCore
import VoxClipMedia

extension RewriteSession {
    func refreshCreatedVoice(_ record: VoiceConsentRecord) {
        let app = editor.app
        guard current else { return }
        guard app.voiceLabRewriteEnabled else { return }
        guard app.bool("voiceLab.providerConsent.elevenlabs") else { return }
        takesTask = Task { [weak self] in
            guard let self, current else { return }
            if let generation { await generation.discover(language: project.transcript?.language ?? "en") }
            else { await discoverVoices() }
            guard current, !Task.isCancelled, let generation else { return }
            if generation.voices.contains(where: { $0.id == record.id }) { generation.chooseVoice(record.id) }
            else {
                generation.chooseVoice(nil)
                generation.fail("This voice isn't ready to use. Finish ElevenLabs verification, then refresh Voices. Nothing was sent for takes.")
            }
            showProposal()
        }
    }
    func discoverVoices() async {
        guard current, editor.app.voiceLabRewriteEnabled, generation == nil else { return }
        reportGenerationProblem(nil)
        let app = editor.app
        if !app.bool("voiceLab.providerConsent.elevenlabs") {
            task.ask(PanelConfirm(question: VoiceLabSession.providerCopy,
                cancel: PanelAction(id: "cancelVoiceProvider", title: "Cancel") { [weak self] in self?.task.dismissConfirm() },
                confirm: PanelAction(id: "allowVoiceProvider", title: "Allow ElevenLabs") { [weak self] in
                    guard let self, current, task.confirm?.confirm.id == "allowVoiceProvider" else { return }
                    task.dismissConfirm()
                    app.set("voiceLab.providerConsent.elevenlabs", .bool(true))
                    makeTakes()
                }))
            return
        }
        do {
            let language = project.transcript?.language ?? "en"
            let speaker = try await app.speakerModelLibrary.check(language: language)
            guard current else { return }
            let region = ElevenLabsRegion(rawValue: app.string("transcription.elevenlabs.region", fallback: "default")) ?? .default
            let client = ElevenLabsVoiceLab(keys: VoiceChangePinnedKeys(source: app.secrets), region: region, logger: app.log, spend: VoiceLabSpendLedger(locations: app.locations))
            configureGeneration(client: client, store: VoiceConsentStore(locations: app.locations), speaker: speaker)
            await generation?.discover(language: language)
        } catch { generationProblem(error) }
    }
    func prepareTakes() async {
        if let reviewing { await reviewing.value }
        if let ordinal = surroundingSentenceOrdinal, acceptedSpeechContext == nil {
            reviewTimingSpeechContext(ordinal: ordinal)
            return
        }
        guard current, let generation, review != nil, overBudget == nil, !includedVoice.isEmpty, let takeBackend else { return }
        guard !hasPaidTakes else {
            generation.fail("Your paid takes are kept. Leave this review and confirm discarding them before making a fresh takes plan.")
            return
        }
        takePlan?.invalidate(); takePlan = nil
        takeQuotePhrase = nil; takeRowsShown = true
        guard let recordID = generation.selectedVoiceID, let modelID = generation.selectedModelID,
              let audio = project.media.source.audio else { return }
        let revision = self.revision, ordinals = includedVoice
        let snapshot = editor.project, region = takeRegion
        let commands = localCommands, reviewedChanges = changes, proposalChanges = ownProposal?.changes
        do {
            let final = try editor.voiceLabReviewProject(localCommands: commands)
            let selected = changes.enumerated().filter { offset, change in
                change.hunk.kind == .voice ? ordinals.contains(offset + 1) : ownProposal?[offset + 1]?.state != .excluded
            }
            takePlanOrdinals = selected.map { $0.offset + 1 }
            guard let envelope else { throw RewriteSessionError.noSourceAudio }
            let contextReview = acceptedSpeechContext
            let contextRequest = try contextReview.map { try currentSpeechContextRequest($0) }
            let hunks: [VoiceLabDiffHunk]
            if let contextReview, let contextRequest {
                hunks = try contextReview.replacingHunks(current: contextRequest, envelope: envelope)
            } else { hunks = selected.map { $0.element.hunk } }
            let sampleRate: Double = Double(audio.sampleRate)
            let sampleCount: Double = project.media.source.durationSeconds * sampleRate
            let frames: Int64 = Int64(EditingPrimitives.jsRound(sampleCount))
            let outputScope = scope, sourceURL = editor.sourceURL
            let timingInputs = RewriteReview.Inputs(transcript: Self.corrected(final), project: final,
                scope: scope, envelope: envelope, prices: nil, synthesisModel: modelID)
            let speakingRate = try VoiceLabPhraseTiming.speakingRate(transcript: RewriteReview.timingTranscript(timingInputs))
            // The plan's own model once the user changes it with paid takes kept (`ClipTakePlan.changeModel`).
            weak var created: ClipTakePlan?
            let plan = try ClipTakePlan(project: final, scope: scope, envelope: envelope, hunks: hunks,
                makeInput: { phrase in
                    let modelID = created?.modelID ?? modelID
                    let silence = try VoiceLabWindowPlanner.lendableSilence(project: final, scope: outputScope, window: phrase.window)
                    let timing = try VoiceLabPaceMatching.measure(text: phrase.text, rate: speakingRate, window: phrase.window,
                        incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                        sourceSampleRate: audio.sampleRate, supportsPace: modelID != "eleven_v4", hardJoinSmoothing: true,
                        audioTags: phrase.audioTags, modelID: modelID,
                        sourceItems: RewriteReview.timingTranscript(timingInputs), sourceEnvelope: envelope)
                    let source = try await VoiceLabSourceAudio.rewriteSource(source: sourceURL, frames: frames, sampleRate: audio.sampleRate,
                        window: phrase.window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, items: Self.corrected(final))
                    var input = VoiceLabTakeInput(text: phrase.text, modelID: modelID, recordID: recordID,
                        language: final.transcript?.language ?? "en", seed: UInt32.random(in: 0...UInt32.max),
                        contentKey: final.media.source.contentKey, source: source.excerpt, sourceEnvelope: source.envelope,
                        sourceSampleRate: audio.sampleRate, items: Self.corrected(final), cutWordIDs: Set(final.edits.cutWordIds),
                        window: phrase.window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                        providerConsent: true, pace: timing.pace, audioTags: phrase.audioTags)
                    input.pauseProfile = VoiceLabPauseProfile.measure(items: RewriteReview.timingTranscript(timingInputs),
                        envelope: envelope, start: 0, end: .greatestFiniteMagnitude)
                    return input
                }, readCap: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.currentGenerationCap()
                }, isCurrent: { [weak self, weak generation] in
                    guard let self, let generation else { return false }
                    return current && editor.project == snapshot && self.revision == revision && includedVoice == ordinals &&
                        localCommands == commands && changes == reviewedChanges && ownProposal?.changes == proposalChanges &&
                        generation.selectedVoiceID == recordID && generation.selectedModelID == (created?.modelID ?? modelID) &&
                        region.map { generationIsCurrent(region: $0) } == true
                }, acceptedChargesChanged: { [weak app = editor.app] in
                    await app?.refreshMonthlySpend()
                })
            created = plan
            plan.prepareDurationRender = durationRenderPreparer()
            configureLipsync(plan)
            if let contextReview, let contextRequest {
                try contextReview.validatePreparedPhrases(plan.phrases, current: contextRequest, envelope: envelope)
                bindSpeechContext(contextReview, to: plan)
            }
            plan.connect(takeBackend(plan.phrases.count) { [weak plan] request, start in
                guard let plan else { throw CancellationError() }
                try await plan.dispatch(request, start: start)
            })
            takePlan = plan
            if let contextReview {
                takeQuotePhrase = contextReview.targetPhraseID
                await plan.prepareSpeechContext(phrase: contextReview.targetPhraseID)
            } else { await plan.prepare() }
        } catch {
            generation.fail(ClipTakePlan.copy(error))
        }
    }
    func currentGenerationCap() async throws -> VoiceLabMonthlyCap? {
        let total = await VoiceLabSpendLedger(locations: editor.app.locations).total(provider: "elevenlabs", at: Date())
        guard let limit = Decimal(string: editor.app.string("voiceLab.monthlyCapUsd.elevenlabs"), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        guard let total else { throw VoiceLabError.consentRequired }
        return VoiceLabMonthlyCap(limit: limit, spent: total.usd)
    }
    private func generationProblem(_ error: any Error) {
        if let generation { generation.fail(Self.refusal(error)) } else { reportGenerationProblem(error) }
    }
}
