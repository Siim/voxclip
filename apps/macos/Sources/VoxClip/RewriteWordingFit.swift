import Foundation
import Observation
import VoxClipCore

@MainActor @Observable final class RewriteWordingFitState {
    var running = false
    var awaitingApproval = false
    var round = 0
    var completed = false
    var stopped = false
    var phrases: [VoiceLabFitPhrase] = []
    var initialEstimates: [Int: Double] = [:]
    var frozen: Set<Int> = []
    var kept: Set<Int> = []
    var problem = ""
    var estimate: CostEstimate?
    @ObservationIgnored var token = UUID()
    @ObservationIgnored var work: Task<Void, Never>?
    @ObservationIgnored var lease: UUID?
    @ObservationIgnored var measuredTakes: Set<UUID> = []
    @ObservationIgnored var measuredWork: Task<Void, Never>?
    @ObservationIgnored var measuredLease: UUID?
    var measured: MeasuredWordingSuggestion?
}

struct MeasuredWordingSuggestion {
    let phrase: Int
    let take: UUID
    let number: Int
    let measuredSeconds: Double
    let slotSeconds: Double
    let tooLong: Bool
    var text: String?
    var keepOriginal = false
    var preparing = true
    var awaitingApproval = false
    var problem = ""
}

extension RewriteSession {
    var wordingIsLocked: Bool { wordingFit.running || wordingFit.awaitingApproval }

    func fitPhrases(ordinals: [Int], measured: [Int: Double] = [:]) throws -> [VoiceLabFitPhrase] {
        let spoken = RewriteReview.timingTranscript(reviewInputs)
        let words = spoken.filter { $0.kind == .word }
        let characters = words.reduce(0) { $0 + VoiceLabTextLength.length($1.text) }
        let rate = try VoiceLabPhraseTiming.speakingRate(transcript: spoken)
        guard characters > 0 else { throw VoiceLabLengthBudgetError.rateUnavailable }
        let wordsPerSecond = rate * Double(words.count) / Double(characters)
        let samples = project.voiceLab.speakingRateSamples?[VoiceLabWordingFit.modelID] ?? []
        let multiplier = VoiceLabWordingFit.multiplier(samples)
        let readings = Dictionary(uniqueKeysWithValues: editor.changeReadings.map { ($0.change.ordinal, $0) })
        return try ordinals.map { ordinal in
            guard let reading = readings[ordinal], let review = voiceReview(ordinal), let timing = review.timing,
                  let window = review.window, let patch = review.patchText else { throw RewriteSessionError.noSourceAudio }
            let allowance = VoiceLabAudioTags.allowance(review.hunk.audioTags, text: patch, modelID: VoiceLabWordingFit.modelID)
            let baseline = try VoiceLabPhraseTiming.estimate(text: patch, rate: rate)
            let speech = Double(VoiceLabTextLength.length(patch)) / (rate * VoiceLabPhraseTiming.providerSpeechRateMultiplier)
            let overhead = max(0, baseline - speech) * multiplier + allowance
            let length = measured[ordinal] ?? timing.estimateSeconds
            let adjustment = measured[ordinal].map { $0 / timing.estimateSeconds } ?? 1
            let lower = timing.minimumSeconds ?? timing.slotSeconds
            let upper = max(lower, timing.maximumSeconds ?? timing.slotSeconds)
            let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: wordsPerSecond,
                multiplier: multiplier * adjustment, minimumSeconds: lower, maximumSeconds: upper,
                overheadSeconds: overhead * adjustment,
                bridgeWords: window.leftBridgeWordIds.count + window.rightBridgeWordIds.count)
            return VoiceLabFitPhrase(ordinal: ordinal, original: reading.removed.joined(separator: " "), proposed: reading.text,
                estimateSeconds: timing.estimateSeconds, slotSeconds: timing.slotSeconds,
                direction: length > (timing.maximumSeconds ?? timing.slotSeconds) ? "shorter" : "longer",
                target: target, measuredSeconds: measured[ordinal], calibrated: samples.count >= 2)
        }
    }

    func beginAutomaticWordingFit() async {
        guard current, showsVoiceLab, !blockedVoiceOrdinals.isEmpty, !hasPaidTakes,
              let connector, let shared = editor.app.shared else { return }
        stopWordingFit(refresh: false)
        wordingFit.round = 0; wordingFit.completed = false; wordingFit.stopped = false
        wordingFit.kept = []; wordingFit.frozen = []; wordingFit.initialEstimates = [:]; wordingFit.problem = ""
        let token = wordingFit.token
        do {
            wordingFit.phrases = try fitPhrases(ordinals: blockedVoiceOrdinals)
            for phrase in wordingFit.phrases { wordingFit.initialEstimates[phrase.ordinal] = phrase.estimateSeconds }
            let service = VoiceLabWordingFitService(shared: shared)
            let quote = try await service.prepare(wordingFit.phrases, connector: connector.connector.id, model: connector.model,
                language: project.transcript?.language ?? "en")
            guard current, token == wordingFit.token, !Task.isCancelled else { return }
            wordingFit.estimate = quote.estimate
            if sendAsksFirst {
                wordingFit.awaitingApproval = true
                showProposal()
            } else { await fitWording(approved: true) }
        } catch {
            guard current, token == wordingFit.token else { return }
            wordingFit.problem = Self.refusal(error)
            showProposal()
        }
    }

    func fitWording(approved: Bool) async {
        guard approved, current, !wordingFit.running, let connector, let shared = editor.app.shared,
              let lease = editor.llmRuns.acquire() else { return }
        wordingFit.awaitingApproval = false; wordingFit.running = true; wordingFit.stopped = false
        wordingFit.lease = lease
        let token = wordingFit.token, revision = revision
        let service = VoiceLabWordingFitService(shared: shared)
        let work = Task { [weak self] in
            guard let self else { return }
            defer {
                editor.llmRuns.release(lease)
                if wordingFit.token == token {
                    wordingFit.running = false; wordingFit.completed = true; wordingFit.lease = nil
                    if current { showProposal() }
                }
            }
            do {
                while wordingFit.round < VoiceLabWordingFit.maximumRounds {
                    try Task.checkCancellation()
                    guard current, self.revision == revision, wordingFit.token == token else { return }
                    let blocked = Set(blockedVoiceOrdinals)
                    let candidates = changes.indices.filter { changes[$0].hunk.kind == .voice }.map { $0 + 1 }
                    wordingFit.frozen.formUnion(Set(candidates).subtracting(blocked))
                    let ordinals = VoiceLabWordingFit.nextOrdinals(roundsCompleted: wordingFit.round, candidates: candidates,
                        fitting: wordingFit.frozen, kept: wordingFit.kept, stopped: wordingFit.stopped)
                    if ordinals.isEmpty { break }
                    wordingFit.phrases = try fitPhrases(ordinals: ordinals)
                    wordingFit.round += 1
                    showProposal()
                    let language = project.transcript?.language ?? "en"
                    let quote = try await service.prepare(wordingFit.phrases, connector: connector.connector.id, model: connector.model, language: language)
                    guard current, wordingFit.token == token, !Task.isCancelled else { return }
                    let updates = try await service.propose(wordingFit.phrases, connector: connector.connector,
                        model: connector.model, language: language, quote: quote, approved: true)
                    guard current, self.revision == revision, wordingFit.token == token, !Task.isCancelled else { return }
                    try applyWordingFit(updates)
                }
            } catch {
                guard current, wordingFit.token == token, !Task.isCancelled else { return }
                wordingFit.problem = Self.refusal(error)
            }
        }
        wordingFit.work = work
        await work.value
    }

    func stopWordingFit(refresh: Bool = true) {
        let active = wordingFit.running || wordingFit.awaitingApproval
        wordingFit.token = UUID(); wordingFit.work?.cancel(); wordingFit.work = nil
        wordingFit.measuredWork?.cancel(); wordingFit.measuredWork = nil
        if let lease = wordingFit.measuredLease { editor.llmRuns.release(lease) }
        wordingFit.measuredLease = nil
        if wordingFit.measured?.preparing == true { wordingFit.measured = nil }
        if let lease = wordingFit.lease { editor.llmRuns.release(lease) }
        wordingFit.lease = nil; wordingFit.running = false; wordingFit.awaitingApproval = false
        if active { wordingFit.stopped = true }
        if refresh, isOpen, case .proposal = task.state { showProposal() }
    }

    var wordingFitCostLine: String {
        guard let estimate = wordingFit.estimate else { return "price unavailable" }
        if let usd = estimate.usd { return VoiceLabCostPresentation.format(usd * 3) }
        return "price unavailable · billed to your key"
    }

    func observeMeasuredTakes(_ plan: ClipTakePlan) {
        guard current, takePlan === plan, !plan.generating, !plan.preparing, !plan.publishing else { return }
        if let suggestion = wordingFit.measured,
           !plan.phrases.indices.contains(suggestion.phrase) || plan.phrases[suggestion.phrase].selectedID != suggestion.take {
            wordingFit.token = UUID()
            wordingFit.measuredWork?.cancel(); wordingFit.measuredWork = nil
            if let lease = wordingFit.measuredLease { editor.llmRuns.release(lease) }
            wordingFit.measuredLease = nil; wordingFit.measured = nil
        }
        do {
            let rate = try VoiceLabPhraseTiming.speakingRate(transcript: RewriteReview.timingTranscript(reviewInputs))
            for phrase in plan.phrases {
                for take in phrase.takes {
                    guard let audio = take.row.audio, let input = plan.measuredInput(take: take.id) else { continue }
                    let estimate = try VoiceLabPhraseTiming.estimate(text: input.text, rate: rate)
                        + VoiceLabAudioTags.allowance(input.audioTags, text: input.text, modelID: input.modelID)
                    recordSpeakingRate(model: input.modelID, take: take.id,
                        measured: Double(audio.trimmed.count) / Double(audio.sampleRate) * (input.pace ?? 1), baseline: estimate)
                }
            }
            guard connector != nil, wordingFit.measuredWork == nil, wordingFit.measured == nil,
                  let phrase = plan.phrases.first(where: { phrase in
                      guard let take = phrase.selected, !wordingFit.measuredTakes.contains(take.id),
                            plan.measuredInput(take: take.id)?.modelID == VoiceLabWordingFit.modelID else { return false }
                      let availability = plan.videoAvailability(phrase: phrase.id)
                      return !availability.allows(.source) && !availability.allows(.cut)
                  }), let take = phrase.selected, let measured = take.length else { return }
            wordingFit.measuredTakes.insert(take.id)
            wordingFit.measured = MeasuredWordingSuggestion(phrase: phrase.id, take: take.id, number: take.number,
                measuredSeconds: measured, slotSeconds: phrase.originalLength, tooLong: measured > phrase.originalLength)
            let token = wordingFit.token
            wordingFit.measuredWork = Task { [weak self, weak plan] in
                guard let self, let plan else { return }
                await rewordMeasuredTake(plan, approved: !sendAsksFirst)
                if wordingFit.token == token { wordingFit.measuredWork = nil }
            }
        } catch { wordingFit.problem = Self.refusal(error) }
    }

    func rewordMeasuredTake(_ plan: ClipTakePlan, approved: Bool) async {
        guard current, takePlan === plan, let suggestion = wordingFit.measured,
              plan.phrases.indices.contains(suggestion.phrase),
              plan.phrases[suggestion.phrase].selectedID == suggestion.take,
              let connector, let shared = editor.app.shared else { return }
        let token = wordingFit.token
        let phrase = plan.phrases[suggestion.phrase]
        do {
            let ordinals = takePhraseOrdinals(phrase)
            guard let ordinal = ordinals.first else { return }
            let rate = try VoiceLabPhraseTiming.speakingRate(transcript: RewriteReview.timingTranscript(reviewInputs))
            let calibrated = VoiceLabWordingFit.multiplier(project.voiceLab.speakingRateSamples?[VoiceLabWordingFit.modelID] ?? [])
            let base = try VoiceLabPhraseTiming.estimate(text: phrase.text, rate: rate)
            let seconds = base * calibrated + VoiceLabAudioTags.allowance(phrase.audioTags, text: phrase.text, modelID: VoiceLabWordingFit.modelID)
            let spoken = RewriteReview.timingTranscript(reviewInputs).filter { $0.kind == .word }
            let characters = spoken.reduce(0) { $0 + VoiceLabTextLength.length($1.text) }
            let wordsPerSecond = rate * Double(spoken.count) / Double(max(1, characters))
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: phrase.window)
            let timing = try VoiceLabPaceMatching.measure(text: phrase.text, rate: rate, window: phrase.window,
                incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                sourceSampleRate: project.media.source.audio?.sampleRate ?? 48_000, supportsPace: false,
                hardJoinSmoothing: true, audioTags: phrase.audioTags, modelID: VoiceLabWordingFit.modelID,
                sourceItems: spoken, sourceEnvelope: envelope, rateMultiplier: calibrated)
            let ratio = suggestion.measuredSeconds / base
            let speech = Double(VoiceLabTextLength.length(phrase.text)) / (rate * VoiceLabPhraseTiming.providerSpeechRateMultiplier)
            let lower = timing.minimumSeconds ?? timing.slotSeconds
            let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: wordsPerSecond, multiplier: ratio,
                minimumSeconds: lower, maximumSeconds: max(lower, timing.maximumSeconds ?? timing.slotSeconds),
                overheadSeconds: max(0, base - speech) * ratio)
            let readings = editor.changeReadings.filter { ordinals.contains($0.change.ordinal) }
            let request = VoiceLabFitPhrase(ordinal: ordinal, original: readings.flatMap(\.removed).joined(separator: " "),
                proposed: phrase.text, estimateSeconds: seconds, slotSeconds: phrase.originalLength,
                direction: suggestion.tooLong ? "shorter" : "longer", target: target,
                measuredSeconds: suggestion.measuredSeconds, calibrated: true)
            let service = VoiceLabWordingFitService(shared: shared), language = project.transcript?.language ?? "en"
            let quote = try await service.prepare([request], connector: connector.connector.id, model: connector.model, language: language)
            guard current, wordingFit.token == token, !Task.isCancelled else { return }
            wordingFit.estimate = quote.estimate
            if !approved {
                wordingFit.measured?.awaitingApproval = true
                wordingFit.measured?.preparing = false
                showProposal()
                return
            }
            wordingFit.measured?.awaitingApproval = false; wordingFit.measured?.preparing = true
            guard let lease = editor.llmRuns.acquire() else { throw LLMError.unavailable(reason: "Another AI request on this project is still running.") }
            wordingFit.measuredLease = lease
            defer {
                editor.llmRuns.release(lease)
                if wordingFit.token == token { wordingFit.measuredLease = nil }
            }
            let updates = try await service.propose([request], connector: connector.connector, model: connector.model,
                language: language, quote: quote, approved: true)
            guard current, wordingFit.token == token, !Task.isCancelled, takePlan === plan,
                  plan.phrases[suggestion.phrase].selectedID == suggestion.take, let update = updates.first else { return }
            wordingFit.measured?.keepOriginal = update.keepOriginal
            if !update.keepOriginal {
                wordingFit.measured?.text = update.text
                takeQuotePhrase = suggestion.phrase
                await plan.prepareRewording(update.text, phrase: suggestion.phrase)
            }
            wordingFit.measured?.preparing = false
            showProposal()
        } catch {
            guard current, wordingFit.token == token, !Task.isCancelled else { return }
            wordingFit.measured?.preparing = false
            wordingFit.measured?.problem = Self.refusal(error)
            showProposal()
        }
    }

    func keepMeasuredTake() {
        guard let suggestion = wordingFit.measured, let plan = takePlan, !takesBusy else { return }
        wordingFit.token = UUID()
        wordingFit.measuredWork?.cancel(); wordingFit.measuredWork = nil
        if let lease = wordingFit.measuredLease { editor.llmRuns.release(lease) }
        wordingFit.measuredLease = nil
        plan.keepSelectedWording(phrase: suggestion.phrase)
        wordingFit.measured = nil
        observeMeasuredTakes(plan)
        showProposal()
    }

    func approveMeasuredFit(_ plan: ClipTakePlan) {
        guard wordingFit.measured?.awaitingApproval == true, wordingFit.measuredWork == nil else { return }
        wordingFit.measured?.awaitingApproval = false
        let token = wordingFit.token
        wordingFit.measuredWork = Task { [weak self, weak plan] in
            guard let self, let plan else { return }
            await rewordMeasuredTake(plan, approved: true)
            if wordingFit.token == token { wordingFit.measuredWork = nil }
        }
    }
}
