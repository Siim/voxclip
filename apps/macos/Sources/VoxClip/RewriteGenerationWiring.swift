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
        guard !wordingIsLocked else { return }
        if let reviewing { await reviewing.value }
        if let ordinal = surroundingSentenceOrdinal, acceptedSpeechContext == nil {
            reviewTimingSpeechContext(ordinal: ordinal)
            return
        }
        guard voiceSpendCurrent, let generation, review != nil, !isReasking, !includedVoice.isEmpty, let takeBackend else { return }
        guard !hasPaidTakes else {
            // Stale paid takes say what changed and ask Keep Working or Discard Takes, the one way to a fresh price that
            // keeps nothing paid from going unasked.
            if let plan = takePlan, !plan.isRetired, !plan.stillCurrent, case .proposal = task.state {
                let copy = ClipTakePlan.copy(staleStop(plan))
                generation.fail(copy)
                askToDiscardTakes(copy)
            } else {
                generation.fail("Your paid takes are kept. Leave this review and confirm discarding them before making a fresh takes plan.")
            }
            return
        }
        // This video's own voice first, when matching is on (voice-lab §6.13): the price is for the voice takes use.
        await ensureVideoVoice()
        guard voiceSpendCurrent, !hasPaidTakes else { return }
        takePlan?.invalidate(); takePlan = nil
        takeQuotePhrase = nil; takeRowsShown = true; takePlanFailure = nil
        guard let recordID = generation.selectedVoiceID, let modelID = generation.selectedModelID,
              project.media.source.audio != nil else { return }
        let ordinals = includedVoice, commands = localCommands
        let reviewAtPlan = review
        weak var created: ClipTakePlan?
        // What the takes are made from (`Project.voiceTakeIdentity`): a save, the tab, music, captions, colour, motion and
        // VoxClip's own rate samples leave it as it is, so they never make paid takes stale.
        let basis = TakePlanBasis(identity: voiceIdentity(editor.project), revision: revision, ordinals: ordinals,
            commands: commands, changes: changes, proposalChanges: ownProposal?.changes, recordID: recordID,
            modelID: { created?.modelID ?? modelID }, region: takeRegion)
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
            let makeInput = try takeInputMaker(final: final, recordID: recordID, modelID: modelID, envelope: envelope,
                                               model: { created?.modelID ?? modelID })
            let plan = try ClipTakePlan(project: final, scope: scope, envelope: envelope, hunks: hunks,
                makeInput: makeInput, readCap: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.currentGenerationCap()
                }, isCurrent: { [weak self, weak generation] in
                    guard let self, let generation else { return false }
                    return staleCause(basis, generation: generation) == nil
                }, acceptedChargesChanged: { [weak app = editor.app] in
                    await app?.refreshMonthlySpend()
                })
            created = plan
            plan.onFailure = { [weak self] error in self?.logFailure(error, stage: "takes") }
            plan.describeStale = { [weak self, weak plan] in
                guard let self, let plan, takePlan === plan, takePlanBasis?.plan === plan else { return nil }
                return staleStop(plan)
            }
            #if DEBUG
            plan.publishOverride = publishOverride
            #endif
            plan.onUnusable = { [weak self] phrases in self?.noteUnusable(phrases) }
            // The guard's verdict on a phrase holds for this Rewrite: a later plan never prices it again.
            applyRememberedBlocks(to: plan)
            plan.onBlocked = { [weak self, weak plan] phrase, reason in
                guard let self, let plan else { return }
                rememberBlocked(phrase: phrase, reason: reason, plan: plan)
            }
            _ = plan.changeModel(VoiceLabWordingFit.modelID)
            plan.onMeasuredTakesChanged = { [weak self, weak plan] in
                guard let self, let plan else { return }
                self.observeMeasuredTakes(plan)
            }
            plan.prepareDurationRender = durationRenderPreparer()
            plan.microphoneStorage = takeStorage
            phraseMicrophone.cancel(); ownWordsEditing = nil
            configureLipsync(plan)
            takePlanReview = reviewAtPlan
            basis.plan = plan; takePlanBasis = basis
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
            // The next-steps card shows it with its chips (RewriteNextSteps.swift); the footer names the blocker.
            takePlanFailure = error
            logFailure(error, stage: "plan")
            // One phrase that can't be joined to the recording keeps its words, and the others are priced (MVP48).
            if keepUnplaceable(error) { return }
            generation.fail("")
            showProposal()
            // A collision goes to the AI once as one sentence, with no click (RewriteAutoFix.swift).
            if planRefusal?.earlier != nil { resolveCollision() }
        }
    }
    /// What every phrase's take input is made from, for a plan over `final` (a Rewrite's phrases, or a whole clip's parts,
    /// RewriteWholeClip.swift): the speaker's rate, pauses and levels are measured once per plan, the source's own levels
    /// decoded once, by the first phrase. `model` reads the plan's model at the time each input is made.
    func takeInputMaker(final: Project, recordID: String, modelID: String, envelope: AudioEnvelope,
                        model: @escaping @MainActor () -> String) throws -> @MainActor (ClipTakePlan.Phrase) async throws -> VoiceLabTakeInput {
        guard let audio = project.media.source.audio else { throw RewriteSessionError.noSourceAudio }
        let sampleRate: Double = Double(audio.sampleRate)
        let sampleCount: Double = project.media.source.durationSeconds * sampleRate
        let frames: Int64 = Int64(EditingPrimitives.jsRound(sampleCount))
        let outputScope = scope, sourceURL = editor.sourceURL
        let timingInputs = RewriteReview.Inputs(transcript: Self.corrected(final), project: final,
            scope: scope, envelope: envelope, prices: nil, synthesisModel: modelID)
        // What every phrase's input shares is measured once per plan; the source's own levels are decoded once, by the
        // first phrase, so a long take's price doesn't decode the whole movie once per phrase.
        let timingItems = RewriteReview.timingTranscript(timingInputs)
        let correctedItems = Self.corrected(final)
        let speakingRate = try VoiceLabPhraseTiming.speakingRate(transcript: timingItems)
        let pauseProfile = VoiceLabPauseProfile.measure(items: timingItems, envelope: envelope, start: 0, end: .greatestFiniteMagnitude)
        let sourceLevels = RewriteSourceLevels()
        // The plan's own model once the user changes it with paid takes kept (`ClipTakePlan.changeModel`).
        return { [weak self] phrase in
            let modelID = model()
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: final, scope: outputScope, window: phrase.window)
            let timing = try VoiceLabPaceMatching.measure(text: phrase.text, rate: speakingRate, window: phrase.window,
                incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                sourceSampleRate: audio.sampleRate, supportsPace: modelID != "eleven_v4", hardJoinSmoothing: true,
                audioTags: phrase.audioTags, modelID: modelID,
                sourceItems: timingItems, sourceEnvelope: envelope,
                rateMultiplier: VoiceLabWordingFit.multiplier(self?.rateSamples(modelID) ?? []))
            let levels = try await sourceLevels.levels(source: sourceURL, frames: frames, sampleRate: audio.sampleRate)
            let source = try await VoiceLabSourceAudio.rewriteSource(source: sourceURL, frames: frames, sampleRate: audio.sampleRate,
                window: phrase.window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, items: correctedItems,
                envelope: levels)
            var input = VoiceLabTakeInput(text: phrase.text, modelID: modelID, recordID: recordID,
                language: final.transcript?.language ?? "en", seed: UInt32.random(in: 0...UInt32.max),
                contentKey: final.media.source.contentKey, source: source.excerpt, sourceEnvelope: source.envelope,
                sourceSampleRate: audio.sampleRate, items: correctedItems, cutWordIDs: Set(final.edits.cutWordIds),
                window: phrase.window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                providerConsent: true, pace: timing.pace, audioTags: phrase.audioTags)
            input.pauseProfile = pauseProfile
            return input
        }
    }

    /// Why `basis`'s takes plan is stale, or nil while it is current: the plan's currency (`prepareTakes`'s isCurrent) and
    /// what a stale stop names (`staleStop`). An edit of the scope's words or of the reviewed changes, an edit beside the
    /// scope that moved the takes' windows, a change left out, another voice or model, Voice Lab's settings, a wording
    /// still being fitted or asked again, or a project that can't be edited. A save, the tab, music, captions, colour,
    /// motion, the AI connector and VoxClip's own rate samples are none of these (voice-lab.md "What counts as an edit").
    func staleCause(_ basis: TakePlanBasis, generation: RewriteGenerationSession?) -> ClipTakePlan.StaleStop.Cause? {
        guard isOpen, editor.capabilities.edit else { return .locked }
        guard let generation else { return .settings }
        if !voiceSpendCurrent || voiceIdentity(editor.project) != basis.identity || revision != basis.revision
            || localCommands != basis.commands || changes != basis.changes { return .words(staleWords) }
        if takeWindowsMoved { return .beside(staleBeside) }
        if includedVoice != basis.ordinals { return .inclusion }
        if ownProposal?.changes != basis.proposalChanges { return .words(staleWords) }
        if generation.selectedVoiceID != basis.recordID { return .voice }
        if generation.selectedModelID != basis.modelID() { return .model }
        if isProposing || wordingIsLocked || isReasking { return .busy }
        guard let region = basis.region, generationIsCurrent(region: region) else { return .settings }
        return nil
    }
    /// The takes plan's stale stop: what changed since it was made, with its paid takes and the way back when they were
    /// paid for (`ClipTakePlan.StaleStop`).
    func staleStop(_ plan: ClipTakePlan) -> ClipTakePlan.StaleStop {
        let cause = takePlanBasis.flatMap { $0.plan === plan ? staleCause($0, generation: generation) : nil } ?? .words(staleWords)
        guard plan === takePlan, hasPaidPatchWork else { return .init(cause: cause) }
        let kept = paidTakesKept
        return .init(cause: cause, kept: kept.kept, pronoun: kept.pronoun)
    }
    /// What a stale stop names as edited: "The words or cuts in clip 1", "The words or cuts in the full take", "These
    /// words or their cuts".
    private var staleWords: String {
        if case .selection = rewriteScope { return task.words.wordCount == 1 ? "This word or its cut" : "These words or their cuts" }
        return "The words or cuts in " + task.words.name
    }
    /// What a stale stop names beside the scope: "The words beside clip 1", "The words beside these words".
    var staleBeside: String {
        if case .selection = rewriteScope { return task.words.wordCount == 1 ? "The words beside this word" : "The words beside these words" }
        return "The words beside " + task.words.name
    }

    func currentGenerationCap() async throws -> VoiceLabMonthlyCap? {
        let total = await VoiceLabSpendLedger(locations: editor.app.locations).total(provider: "elevenlabs", at: Date())
        guard let limit = Decimal(string: editor.app.string("voiceLab.monthlyCapUsd.elevenlabs"), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        guard let total else { throw VoiceLabError.consentRequired }
        return VoiceLabMonthlyCap(limit: limit, spent: total.usd)
    }
    private func generationProblem(_ error: any Error) {
        if let generation { generation.fail(reported(error, stage: "voices")) } else { reportGenerationProblem(error) }
    }
}

/// What a Rewrite's takes plan was made from (`RewriteSession.prepareTakes`): its voice identity, the session's revision,
/// inclusions, pending free changes and reviewed changes, the voice, the model and the region. The plan is current while
/// they are as they were (`RewriteSession.staleCause`).
@MainActor final class TakePlanBasis {
    let identity: Project
    let revision: Int
    let ordinals: [Int]
    let commands: [EditCommand]
    let changes: [RewriteChange]
    let proposalChanges: [TranscriptChange]?
    let recordID: String
    /// The plan's model: the one its inputs were made with, or the one the user changed it to with paid takes kept.
    let modelID: @MainActor () -> String
    let region: ElevenLabsRegion?
    /// The plan made from it.
    weak var plan: ClipTakePlan?
    init(identity: Project, revision: Int, ordinals: [Int], commands: [EditCommand], changes: [RewriteChange],
         proposalChanges: [TranscriptChange]?, recordID: String, modelID: @escaping @MainActor () -> String, region: ElevenLabsRegion?) {
        self.identity = identity; self.revision = revision; self.ordinals = ordinals; self.commands = commands
        self.changes = changes; self.proposalChanges = proposalChanges; self.recordID = recordID; self.modelID = modelID
        self.region = region
    }
}

/// A take plan's source levels (`VoiceLabSourceAudio.rewriteEnvelope`), decoded by the first phrase that needs them and
/// shared by the rest.
@MainActor final class RewriteSourceLevels {
    private var decoded: Task<AudioEnvelope, any Error>?
    func levels(source: URL, frames: Int64, sampleRate: Int) async throws -> AudioEnvelope {
        if let decoded { return try await decoded.value }
        let task = Task { try await VoiceLabSourceAudio.rewriteEnvelope(source: source, frames: frames, sampleRate: sampleRate) }
        decoded = task
        do { return try await task.value } catch { decoded = nil; throw error }
    }
}
