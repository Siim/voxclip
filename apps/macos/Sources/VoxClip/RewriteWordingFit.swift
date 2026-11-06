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
    /// The measured take failed its checks, so the phrase has no take selected (an automatic fix, RewriteAutoFix.swift).
    var unselected = false
    var text: String?
    var keepOriginal = false
    var preparing = true
    var awaitingApproval = false
    var problem = ""
    /// The phrase's selection the suggestion was made for: the measured take, or none when it failed its checks.
    var selection: UUID? { unselected ? nil : take }
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
        let samples = rateSamples(VoiceLabWordingFit.modelID)
        let multiplier = VoiceLabWordingFit.multiplier(samples)
        let spread = rateSpread(VoiceLabWordingFit.modelID)
        let readings = Dictionary(uniqueKeysWithValues: editor.changeReadings.map { ($0.change.ordinal, $0) })
        let built: [VoiceLabFitPhrase] = try ordinals.compactMap { ordinal in
            guard let reading = readings[ordinal], let review = voiceReview(ordinal), let timing = review.timing,
                  let window = review.window, let patch = review.patchText else { throw RewriteSessionError.noSourceAudio }
            // New words with nothing removed (a sentence the rewrite adds) have no slot to fit: they lengthen the video,
            // so they are priced as written rather than reworded (MVP25: one such phrase refused the whole fit request).
            guard !reading.removed.isEmpty, !reading.text.isEmpty, timing.slotSeconds.isFinite, timing.slotSeconds > 0 else { return nil }
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
                bridgeWords: window.leftBridgeWordIds.count + window.rightBridgeWordIds.count, spread: spread)
            return VoiceLabFitPhrase(ordinal: ordinal, original: reading.removed.joined(separator: " "), proposed: reading.text,
                estimateSeconds: timing.estimateSeconds, slotSeconds: timing.slotSeconds,
                direction: length > (timing.maximumSeconds ?? timing.slotSeconds) ? "shorter" : "longer",
                target: target, measuredSeconds: measured[ordinal], calibrated: samples.count >= 2)
        }
        // A phrase the fit request can't take is priced as written, and its reason is logged (never its text).
        let log = editor.app.log
        let fittable = built.filter { phrase in
            guard let reason = VoiceLabWordingFitService.refusal(phrase) else { return true }
            Task { await log.write(LogEntry(level: .warn, category: "rewrite", message: "wording fit skipped phrase check=\(reason)")) }
            return false
        }
        // One request takes 60 phrases; the rest are priced as written.
        let limit = VoiceLabWordingFitService.maximumPhrases
        if fittable.count > limit {
            Task { await log.write(LogEntry(level: .warn, category: "rewrite", message: "wording fit capped phrases=\(fittable.count) limit=\(limit)")) }
        }
        return Array(fittable.prefix(limit))
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
            guard !wordingFit.phrases.isEmpty else {
                // Nothing here can be reworded to a slot: the long ones keep the speaker's words, and Rewrite goes on.
                wordingFit.completed = true
                keepLongChangesAsRecorded()
                showProposal()
                return
            }
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
            wordingFitFailed(error)
        }
    }

    /// A fit that could not start ends as one that ran out of rounds does (design.md R2): its problem shows on the fit
    /// card, and the changes still too long keep the speaker's words, so Get Price goes on for the rest. Nothing offers
    /// the same request again (the log's 2026-11-05 `wordingFit invalidInput` left the held changes with no way on but
    /// Keep All).
    func wordingFitFailed(_ error: any Error) {
        wordingFit.problem = reported(error, stage: "wordingFit")
        wordingFit.completed = true
        keepLongChangesAsRecorded()
        showProposal()
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
                    keepLongChangesAsRecorded()
                    if let plan = takePlan { applyPendingExpressions(plan) }
                    if current { showProposal() }
                }
            }
            do {
                while wordingFit.round < Self.automaticFitRounds {
                    try Task.checkCancellation()
                    guard current, self.revision == revision, wordingFit.token == token else { return }
                    let blocked = Set(blockedVoiceOrdinals)
                    let candidates = changes.indices.filter { changes[$0].hunk.kind == .voice }.map { $0 + 1 }
                    wordingFit.frozen.formUnion(Set(candidates).subtracting(blocked))
                    let ordinals = VoiceLabWordingFit.nextOrdinals(roundsCompleted: wordingFit.round, candidates: candidates,
                        fitting: wordingFit.frozen, kept: wordingFit.kept, stopped: wordingFit.stopped)
                    if ordinals.isEmpty { break }
                    wordingFit.phrases = try fitPhrases(ordinals: ordinals)
                    if wordingFit.phrases.isEmpty { break }
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
                wordingFit.problem = reported(error, stage: "wordingFit")
            }
        }
        wordingFit.work = work
        await work.value
    }

    /// The free fit rounds a reply's over-budget changes get before takes (ai.md §12.9): one. A change still longer than
    /// its slot after it keeps the speaker's words.
    static let automaticFitRounds = 1

    /// The automatic wording fit ended and a change is still longer than its time in the video (ai.md §12.9): it keeps
    /// the speaker's own words, as a change the fit itself left as recorded does, and Rewrite goes on with the rest
    /// (Get Price for what is left, or Done). Nothing is priced that can't fit: the video keeps running under the take.
    /// A change too short keeps its surrounding-sentence route; after Stop, the footer's Keep my words settles them.
    func keepLongChangesAsRecorded(evenAfterStop: Bool = false) {
        guard current, evenAfterStop || !wordingFit.stopped, !hasPaidTakes, !autoFix.stopped || evenAfterStop else { return }
        let long = blockedVoiceOrdinals.filter { voiceReview($0)?.timing?.tooLong == true }
        guard !long.isEmpty else { return }
        do { try applyWordingFit(long.map { VoiceLabFitUpdate(ordinal: $0, keepOriginal: true, text: "") }) }
        catch { return }
        autoFix.notes.append("\(Self.changeNames(long)) \(long.count == 1 ? "keeps" : "keep") your original words: "
            + "still longer than \(long.count == 1 ? "its" : "their") time in the video after a fit.")
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
        autoChooseVideo(plan)
        applyPendingExpressions(plan)
        if let suggestion = wordingFit.measured,
           !plan.phrases.indices.contains(suggestion.phrase) || plan.phrases[suggestion.phrase].selectedID != suggestion.selection {
            wordingFit.token = UUID()
            wordingFit.measuredWork?.cancel(); wordingFit.measuredWork = nil
            if let lease = wordingFit.measuredLease { editor.llmRuns.release(lease) }
            wordingFit.measuredLease = nil; wordingFit.measured = nil
        }
        do {
            let rate = try VoiceLabPhraseTiming.speakingRate(transcript: RewriteReview.timingTranscript(reviewInputs))
            for phrase in plan.phrases {
                for take in phrase.takes {
                    guard take.source == .clonedVoice, let audio = take.row.audio, let input = plan.measuredInput(take: take.id) else { continue }
                    let estimate = try VoiceLabPhraseTiming.estimate(text: input.text, rate: rate)
                        + VoiceLabAudioTags.allowance(input.audioTags, text: input.text, modelID: input.modelID)
                    recordSpeakingRate(model: input.modelID, recordID: input.recordID, take: take.id,
                        measured: Double(audio.trimmed.count) / Double(audio.sampleRate) * (input.pace ?? 1), baseline: estimate)
                }
            }
            // Once an approved price armed the automatic fixes, they make this round (RewriteAutoFix.swift).
            guard autoFix.plan !== plan else { advanceAutoFix(); return }
            guard connector != nil, wordingFit.measuredWork == nil, wordingFit.measured == nil,
                  let phrase = plan.phrases.first(where: { phrase in
                      guard phrase.wording == .suggested, let take = phrase.selected, !wordingFit.measuredTakes.contains(take.id),
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
        } catch { wordingFit.problem = reported(error, stage: "wordingFit") }
    }

    func rewordMeasuredTake(_ plan: ClipTakePlan, approved: Bool, automatic: Bool = false) async {
        guard current, takePlan === plan, let suggestion = wordingFit.measured,
              plan.phrases.indices.contains(suggestion.phrase),
              plan.phrases[suggestion.phrase].selectedID == suggestion.selection,
              let connector, let shared = editor.app.shared else { return }
        let token = wordingFit.token
        let phrase = plan.phrases[suggestion.phrase]
        do {
            let ordinals = takePhraseOrdinals(phrase)
            guard let ordinal = ordinals.first else { return }
            let rate = try VoiceLabPhraseTiming.speakingRate(transcript: RewriteReview.timingTranscript(reviewInputs))
            let calibrated = VoiceLabWordingFit.multiplier(rateSamples(VoiceLabWordingFit.modelID))
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
                overheadSeconds: max(0, base - speech) * ratio, spread: rateSpread(VoiceLabWordingFit.modelID))
            let readings = editor.changeReadings.filter { ordinals.contains($0.change.ordinal) }
            // The loop's memory (voice-lab §8.2.2): every wording this phrase had, with its measured result. The whole
            // phrase is reworded, so the words joining it to the recording are named as required.
            var tried = triedWordings(phrase, plan: plan)
            let bridge = plan.bridge(phrase: suggestion.phrase)
            func request(_ tried: [VoiceLabFitTried]) -> VoiceLabFitPhrase {
                // An added sentence removed nothing; the request still names that, rather than sending no original words.
                VoiceLabFitPhrase(ordinal: ordinal, original: { let removed = readings.flatMap(\.removed).joined(separator: " "); return removed.isEmpty ? "(none: new words)" : removed }(),
                    proposed: phrase.text, estimateSeconds: seconds, slotSeconds: phrase.originalLength,
                    direction: suggestion.tooLong ? "shorter" : "longer", target: target,
                    measuredSeconds: suggestion.measuredSeconds, calibrated: true, tried: tried.isEmpty ? nil : tried, bridge: bridge)
            }
            let service = VoiceLabWordingFitService(shared: shared), language = project.transcript?.language ?? "en"
            let quote = try await service.prepare([request(tried)], connector: connector.connector.id, model: connector.model, language: language)
            guard current, wordingFit.token == token, !Task.isCancelled else { return }
            wordingFit.estimate = quote.estimate
            if automatic, !autoFixChargeSend(quote.estimate, phrase: suggestion.phrase) {
                wordingFit.measured = nil
                return
            }
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
            func stillAsked() -> Bool {
                current && wordingFit.token == token && !Task.isCancelled && takePlan === plan
                    && plan.phrases[suggestion.phrase].selectedID == suggestion.selection
            }
            var updates = try await service.propose([request(tried)], connector: connector.connector, model: connector.model,
                language: language, quote: quote, approved: true)
            guard stillAsked(), var update = updates.first else { return }
            // A reply that dropped the bridge words can't be priced or placed, so it never counts as a round: an automatic
            // round asks once more, free of speech cost, naming them and listing the dropped wording (voice-lab §8.2.2).
            if !update.keepOriginal, let bridge, !bridge.keeps(update.text) {
                let dropped = VoiceLabFitTried(text: update.text, result: "missingBridge")
                guard automatic else {
                    wordingFit.measured?.preparing = false
                    wordingFit.measured?.problem = Self.droppedBridgeProblem(aiName, bridge: bridge, phrase: suggestion.phrase)
                    showProposal()
                    return
                }
                autoFix.refused[suggestion.phrase, default: []].append(dropped)
                tried = triedWordings(phrase, plan: plan)
                autoFix.lines[suggestion.phrase] = "Fixing phrase \(suggestion.phrase + 1): asking \(aiName) again to keep “\(bridge.display)”…"
                let again = try await service.prepare([request(tried)], connector: connector.connector.id, model: connector.model, language: language)
                guard stillAsked() else { return }
                guard autoFixChargeSend(again.estimate, phrase: suggestion.phrase) else {
                    wordingFit.measured = nil
                    return
                }
                updates = try await service.propose([request(tried)], connector: connector.connector, model: connector.model,
                    language: language, quote: again, approved: true)
                guard stillAsked(), let retried = updates.first else { return }
                update = retried
                if !update.keepOriginal, !bridge.keeps(update.text) {
                    // Still without them: this round ends, and the phrase card's "Round k of 3 · tried: …" says why.
                    autoFix.refused[suggestion.phrase, default: []].append(VoiceLabFitTried(text: update.text, result: "missingBridge"))
                    wordingFit.measured?.preparing = false
                    wordingFit.measured?.problem = Self.droppedBridgeProblem(aiName, bridge: bridge, phrase: suggestion.phrase)
                    showProposal()
                    return
                }
            }
            wordingFit.measured?.keepOriginal = update.keepOriginal
            if !update.keepOriginal {
                // An automatic round never prices a repeat, or a wording that doesn't move toward the slot; the next
                // round hears why. A suggestion the user reviews is theirs to judge by ear.
                if automatic, let refusal = try automaticRefusal(update.text, suggestion: suggestion, phrase: phrase, plan: plan,
                                                                 tried: tried, rate: rate) {
                    autoFix.refused[suggestion.phrase, default: []].append(VoiceLabFitTried(text: update.text, result: refusal))
                    wordingFit.measured?.preparing = false
                    wordingFit.measured?.problem = refusal == "repeat" ? "\(aiName) repeated a wording already tried, so it wasn't used."
                        : "\(aiName)'s wording wasn't \(suggestion.tooLong ? "shorter" : "longer"), so it wasn't used."
                    showProposal()
                    return
                }
                wordingFit.measured?.text = update.text
                takeQuotePhrase = suggestion.phrase
                guard await plan.prepareRewording(update.text, phrase: suggestion.phrase) else {
                    wordingFit.measured?.text = nil
                    wordingFit.measured?.preparing = false
                    wordingFit.measured?.problem = "The new wording couldn't be priced."
                    showProposal()
                    return
                }
            }
            wordingFit.measured?.preparing = false
            showProposal()
        } catch {
            guard current, wordingFit.token == token, !Task.isCancelled else { return }
            wordingFit.measured?.preparing = false
            wordingFit.measured?.problem = reported(error, stage: "wordingFit")
            showProposal()
        }
    }

    /// Why a reworded phrase is not voiced when the AI dropped its bridge words (voice-lab §8.2.2).
    static func droppedBridgeProblem(_ aiName: String, bridge: VoiceLabFitBridge, phrase: Int) -> String {
        "\(aiName) left out “\(bridge.display)”, the words that join phrase \(phrase + 1) to your recording, so its wording wasn't used."
    }

    /// Why an automatic round's wording is not voiced (voice-lab §8.2.2): a variant already tried, or one that does not
    /// move toward the slot from the measured take's wording. Nil when it may be priced.
    private func automaticRefusal(_ text: String, suggestion: MeasuredWordingSuggestion, phrase: ClipTakePlan.Phrase, plan: ClipTakePlan,
                                  tried: [VoiceLabFitTried], rate: Double) throws -> String? {
        let measuredText = plan.measuredInput(take: suggestion.take)?.text ?? phrase.text
        let key = VoiceLabFitTried.key(text)
        if key == VoiceLabFitTried.key(measuredText) || tried.contains(where: { VoiceLabFitTried.key($0.text) == key }) { return "repeat" }
        let before = try VoiceLabPhraseTiming.estimate(text: measuredText, rate: rate)
        let after = try VoiceLabPhraseTiming.estimate(text: text, rate: rate)
        if suggestion.tooLong, after >= before { return "notShorter" }
        if !suggestion.tooLong, after <= before { return "notLonger" }
        return nil
    }

    /// The measured card's keep button. A take that no video duration carries can't be kept: keeping it ends in the
    /// recorded audio (`settleTakesThatFitNoDuration`), so the button names that instead of the take.
    func measuredKeepTitle(_ suggestion: MeasuredWordingSuggestion, plan: ClipTakePlan) -> String {
        if suggestion.awaitingApproval { return "Skip" }
        return plan.fitsNoDuration(phrase: suggestion.phrase) ? "Keep Original Audio" : "Keep Take \(suggestion.number)"
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

    /// A selected passing take gets a video duration chosen (design.md R2): the only valid one, or the first of keep
    /// source, cut and match. The phrase card reads it as one line, with Change when another is valid, so Use is the
    /// one action left. A cut or matched video is prepared whenever the selection needs it, also after another phrase's
    /// choice cleared the one prepared before. A phrase whose take no duration can carry keeps its recorded audio first
    /// (`settleTakesThatFitNoDuration`).
    func autoChooseVideo(_ plan: ClipTakePlan) {
        guard !plan.preparingVideo else { return }
        settleTakesThatFitNoDuration(plan)
        for phrase in plan.phrases where phrase.videoChoice == nil && !plan.lipsync.blocksMutation(phrase.id) {
            guard let first = plan.validVideoChoices(phrase: phrase.id).first else { continue }
            plan.chooseVideo(first, phrase: phrase.id)
        }
        if plan.needsVideoPreparation { Task { [weak plan] in await plan?.prepareVideoChoices(); await plan?.lipsync.refresh() } }
    }
}
