import Foundation
import VoxClipCore
import VoxClipMedia

extension RewriteSession {
    func discoverVoices() async {
        guard current, editor.app.voiceLabRewriteEnabled, generation == nil else { return }
        reportGenerationProblem(nil)
        let app = editor.app
        if !app.bool("voiceLab.providerConsent.elevenlabs") {
            guard let window = editor.window,
                  await RewriteApprovalSheet(title: "Use ElevenLabs?", copy: VoiceLabSession.providerCopy, parent: window).confirm(), current else { return }
            app.set("voiceLab.providerConsent.elevenlabs", .bool(true))
        }
        do {
            let language = project.transcript?.language ?? "en"
            let speaker = try await app.speakerModelLibrary.check(language: language)
            guard current else { return }
            let region = ElevenLabsRegion(rawValue: app.string("transcription.elevenlabs.region", fallback: "default")) ?? .default
            let client = ElevenLabsVoiceLab(keys: app.secrets, region: region, logger: app.log, spend: VoiceLabSpendLedger(locations: app.locations))
            configureGeneration(client: client, store: VoiceConsentStore(locations: app.locations), speaker: speaker)
            await generation?.discover(language: language)
        } catch { generationProblem(error) }
    }
    func prepareTakes() async {
        if let reviewing { await reviewing.value }
        guard current, let generation, review != nil, overBudget == nil, !includedVoice.isEmpty, let takeBackend else { return }
        takePlan?.invalidate(); takePlan = nil
        guard let recordID = generation.selectedVoiceID, let modelID = generation.selectedModelID,
              let audio = project.media.source.audio else { return }
        let revision = self.revision, ordinals = includedVoice
        let snapshot = editor.project, region = takeRegion
        do {
            let final = try editor.voiceLabReviewProject(localCommands: localCommands)
            let selected = changes.enumerated().filter { offset, change in
                change.hunk.kind == .voice ? ordinals.contains(offset + 1) : ownProposal?[offset + 1]?.state != .excluded
            }
            takePlanOrdinals = selected.map { $0.offset + 1 }
            guard let envelope else { throw RewriteSessionError.noSourceAudio }
            let sampleRate: Double = Double(audio.sampleRate)
            let sampleCount: Double = project.media.source.durationSeconds * sampleRate
            let frames: Int64 = Int64(EditingPrimitives.jsRound(sampleCount))
            let outputScope = scope, sourceURL = editor.sourceURL
            let plan = try ClipTakePlan(project: final, scope: scope, envelope: envelope, hunks: selected.map { $0.element.hunk },
                makeInput: { phrase in
                    let silence = try VoiceLabWindowPlanner.lendableSilence(project: final, scope: outputScope, window: phrase.window)
                    let source = try await VoiceLabSourceAudio.rewriteSource(source: sourceURL, frames: frames, sampleRate: audio.sampleRate,
                        window: phrase.window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, items: Self.corrected(final))
                    return VoiceLabTakeInput(text: phrase.text, modelID: modelID, recordID: recordID,
                        language: final.transcript?.language ?? "en", seed: UInt32.random(in: 0...UInt32.max),
                        contentKey: final.media.source.contentKey, source: source.excerpt, sourceEnvelope: source.envelope,
                        sourceSampleRate: audio.sampleRate, items: Self.corrected(final), cutWordIDs: Set(final.edits.cutWordIds),
                        window: phrase.window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, providerConsent: true)
                }, readCap: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.currentGenerationCap()
                }, isCurrent: { [weak self, weak generation] in
                    guard let self, let generation else { return false }
                    return current && editor.project == snapshot && self.revision == revision && includedVoice == ordinals &&
                        generation.selectedVoiceID == recordID && generation.selectedModelID == modelID &&
                        region.map { generationIsCurrent(region: $0) } == true
                })
            plan.connect(takeBackend(plan.phrases.count) { [weak plan] request, start in
                guard let plan else { throw CancellationError() }
                try await plan.dispatch(request, start: start)
            })
            takePlan = plan
            await plan.prepare()
        } catch { generation.fail(ClipTakePlan.copy(error)) }
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
