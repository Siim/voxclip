import Foundation
import VoxClipCore
import VoxClipMedia

extension RewriteSession {
    func discoverVoices() async {
        guard current, editor.app.voiceLabRewriteEnabled, generation == nil else { return }
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
        guard current, let generation, let review, review.budget.copy == nil else { return }
        guard review.voiceHunks.count == 1, let hunk = review.voiceHunks.first, let window = hunk.window,
              let text = hunk.patchText else {
            generation.fail("Rewrite one passage at a time. Keep one changed passage, then generate takes.")
            return
        }
        guard let recordID = generation.selectedVoiceID, let modelID = generation.selectedModelID,
              let audio = project.media.source.audio else { return }
        guard let reservation = generation.reservePreparation() else { return }
        let revision = self.revision
        do {
            let sampleRate: Double = Double(audio.sampleRate)
            let sampleCount: Double = project.media.source.durationSeconds * sampleRate
            let frames: Int64 = Int64(EditingPrimitives.jsRound(sampleCount))
            let source = try await VoiceLabSourceAudio.rewriteSource(source: editor.sourceURL, frames: frames, sampleRate: audio.sampleRate)
            guard current, self.revision == revision, generation.preparationIsCurrent(reservation), generation.selectedVoiceID == recordID,
                  generation.selectedModelID == modelID, !Task.isCancelled else { return }
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: window)
            let input = VoiceLabTakeInput(text: text, modelID: modelID, recordID: recordID,
                language: project.transcript?.language ?? "en", seed: UInt32.random(in: 0...UInt32.max),
                contentKey: project.media.source.contentKey, source: source, sourceSampleRate: audio.sampleRate,
                items: transcript, cutWordIDs: editor.cutWordIDs, window: window,
                incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                providerConsent: editor.app.bool("voiceLab.providerConsent.elevenlabs"))
            let total = await VoiceLabSpendLedger(locations: editor.app.locations).total(provider: "elevenlabs", at: Date())
            guard generation.preparationIsCurrent(reservation) else { return }
            let limit = Decimal(string: editor.app.string("voiceLab.monthlyCapUsd.elevenlabs"), locale: Locale(identifier: "en_US_POSIX"))
            let cap = limit.map { VoiceLabMonthlyCap(limit: $0, spent: total?.usd ?? 0) }
            await generation.prepare(input, cap: cap, reservation: reservation)
        } catch { if generation.preparationIsCurrent(reservation) { generationProblem(error) } }
    }
    private func generationProblem(_ error: any Error) {
        if let generation { generation.fail(Self.refusal(error)) } else { reportGenerationProblem(error) }
    }
}
