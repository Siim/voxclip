import Foundation
import VoxClipCore
import VoxClipMedia

/// Revoice the whole clip inside Rewrite (ADR-R46): the card's actions and the live steps. The voice is a take plan over the
/// script's parts (`WholeClipScript.hunks`), so each part goes through the same window placement, R40 guard, R43
/// calibration, per-video voice (R45), take checks and journals as a phrase; the picture is matched per part through the
/// same duration path; the lip sync is Rewrite's own over one merged window with the chosen model; Use is Rewrite's own
/// commit, one undo step, with the project's `wholeClipRevoices` record.
extension RewriteSession {
    /// The clip this Rewrite is inside, nil for the full take.
    var wholeClipID: String? {
        switch rewriteScope {
        case .clip(let id): return id
        case .selection(let range): return Self.enclosingClip(range, in: project)
        case .fullTake: return nil
        }
    }

    /// The Choose card shows once per clip at the price step: Voice Lab on with included voice changes in one clip, a voice
    /// chosen, nothing paid yet, and no pick for this clip. A pick of the whole clip keeps it shown until the run ends.
    var offersWholeClip: Bool {
        guard showsVoiceLab, let clip = wholeClipID, generation?.selectedVoiceID != nil, !includedVoice.isEmpty else { return false }
        if let session = wholeClip, session.phase != .choose { return true }
        return !hasPaidTakes && editor.wholeClipPicks[clip] == nil
    }

    /// The card, made on first show; its price is fetched in the background (free).
    func wholeClipCard() -> PanelCard? {
        guard offersWholeClip else { return nil }
        if wholeClip == nil {
            let session = WholeClipRevoiceSession()
            configureWholeClip(session)
            #if DEBUG
            editor.wholeClipSmoke?(self, session)
            #endif
            wholeClip = session
            Task { [weak self, weak session] in
                await session?.refreshQuote()
                self?.refreshWholeClipPanel()
            }
        }
        return .wholeClip
    }

    func refreshWholeClipPanel() {
        if isOpen, case .proposal = task.state { showProposal() }
    }

    /// The card's primary: "Revoice Whole Clip · ≈ $X" (the click approves the voice and the lip sync at that price), or
    /// "Voice Only the Changed Phrases" for the patch. With no fal.ai key the whole clip opens Settings for it.
    func wholeClipPrimary(retry: Bool = false) -> PanelAction? {
        guard let session = wholeClip else { return nil }
        guard session.wholeSelected || retry else {
            return PanelAction(id: "wholeClipPatchPick", title: "Voice Only the Changed Phrases") { [weak self] in self?.patchInstead() }
        }
        guard let usd = session.quote?.wholeUSD else { return nil }
        let remaining = max(0, usd - session.spent)
        let price = remaining > 0 ? " · " + VoiceLabCostPresentation.format(remaining) : ""
        return PanelAction(id: retry ? "wholeClipRetry" : "wholeClipRevoice", title: (retry ? "Try Again" : "Revoice Whole Clip") + price, priced: true) { [weak self] in
            self?.startWholeClip()
        }
    }

    /// The callout's chip over a large change: "Revoice the Whole Clip · ≈ $X". Nothing is spent until it is clicked.
    func wholeClipChipAction() -> PanelAction? {
        guard let session = wholeClip, session.phase == .choose, let usd = session.quote?.wholeUSD else { return nil }
        return PanelAction(id: "wholeClipChip", title: "Revoice the Whole Clip · " + VoiceLabCostPresentation.format(usd), priced: true) { [weak self] in
            self?.wholeClip?.wholeSelected = true
            self?.startWholeClip()
        }
    }

    /// "Change fewer words": the voice budget's own re-ask (RewriteNextSteps.swift).
    func changeFewerWordsAction() -> PanelAction? {
        guard let advice = voiceBudget else { return nil }
        return budgetSteps(advice, freeChanges: 0).chips.first { $0.action.id == "changeFewerWords" }?.action
    }

    /// Review's upgrade: "Sharper Lip Sync · sync-3 · ≈ $X", re-running only the lip sync over the paid voice.
    func wholeClipUpgradeAction() -> PanelAction? {
        guard let session = wholeClip, session.phase == .review, let usd = session.upgradeUSD, !session.automatic else { return nil }
        return PanelAction(id: "wholeClipUpgrade", title: "Sharper Lip Sync · sync-3 · " + VoiceLabCostPresentation.format(usd), priced: true) { [weak session] in
            session?.upgrade()
        }
    }

    /// The stopped card's actions, the first one primary. Try Again (priced) only when a retry can succeed: after a stop that
    /// would only repeat, such as a part that can't be placed, the patch is the way forward and nothing is priced for work
    /// that can't happen.
    func wholeClipStoppedActions() -> [PanelAction] {
        guard let session = wholeClip, session.isStopped else { return [] }
        let patch = PanelAction(id: "wholeClipPatch", title: "Voice Only the Changed Phrases") { [weak self] in self?.patchInstead() }
        guard session.failure?.repeats != true, let retry = wholeClipPrimary(retry: true) else { return [patch] }
        return [retry, patch]
    }

    func startWholeClip(automatic: Bool = false) {
        guard let session = wholeClip, let clip = wholeClipID, !session.running else { return }
        editor.wholeClipPicks[clip] = true
        session.start(automatic: automatic)
        editor.announce("Revoicing the whole clip.")
        refreshWholeClipPanel()
        Task { [weak self, weak session] in
            while session?.running == true { await session?.waitForRun() }
            self?.refreshWholeClipPanel()
        }
    }

    /// The patch, as before: the pick is kept for this clip and the card goes.
    func patchInstead() {
        guard let clip = wholeClipID else { return }
        editor.wholeClipPicks[clip] = false
        Task { [weak self] in
            await self?.wholeClip?.discard()
            self?.wholeClipPlan?.invalidate(); self?.wholeClipPlan = nil
            self?.wholeClip = nil
            self?.refreshWholeClipPanel()
        }
    }

    @discardableResult func useWholeClip() -> Task<Void, Never> {
        Task { [weak self] in
            await self?.wholeClip?.use()
            self?.refreshWholeClipPanel()
        }
    }

    /// Undo on Review: the original audio and video stay; the card offers the choice again.
    func discardWholeClip() {
        Task { [weak self] in
            await self?.wholeClip?.discard()
            self?.refreshWholeClipPanel()
        }
    }

    // MARK: The live steps

    /// The clip's transcript items, corrected, from the review's project.
    private func wholeClipWords(_ final: Project) -> [TimedWord] {
        let words = Self.corrected(final)
        guard let id = wholeClipID, let clip = final.edits.clips.first(where: { $0.id == id }),
              let lower = words.firstIndex(where: { $0.id == clip.startWordId }),
              let upper = words.firstIndex(where: { $0.id == clip.endWordId }), lower <= upper else { return [] }
        return Array(words[lower...upper])
    }

    private var includedVoiceHunks: [VoiceLabDiffHunk] {
        changes.enumerated().filter { $0.element.hunk.kind == .voice && includedVoice.contains($0.offset + 1) }.map(\.element.hunk)
    }

    /// The rule's inputs here: the clip's spoken words after its cuts, the voice budget's count, and the phrases that can't fit.
    var wholeClipRuleInputs: WholeClipRevoice.RuleInputs {
        let final = (try? editor.voiceLabReviewProject(localCommands: localCommands)) ?? project
        let cuts = Set(final.edits.cutWordIds)
        let spoken = wholeClipWords(final).filter { $0.kind == .word && !cuts.contains($0.id) }.count
        let revoiced = includedVoiceHunks.reduce(0) { $0 + $1.newTokens.count }
        let noFit = (takePlan?.phrases.indices.filter { takePlan?.fitsNoDuration(phrase: $0) == true }.count ?? 0) + wordingFit.kept.count
        return .init(spokenWords: spoken, revoicedWords: revoiced, noFitPhrases: noFit)
    }

    func configureWholeClip(_ session: WholeClipRevoiceSession) {
        let editor = self.editor
        session.backend = WholeClipRevoiceSession.Backend(script: { [weak self] in
            guard let self else { throw CancellationError() }
            let final = try editor.voiceLabReviewProject(localCommands: localCommands)
            guard let script = WholeClipScript.assemble(words: wholeClipWords(final), cutWordIds: Set(final.edits.cutWordIds),
                                                        voiceHunks: includedVoiceHunks) else { throw ClipTakePlan.Failure.nothingToVoice }
            return script
        }, quote: { [weak self] script, model in
            guard let self else { throw CancellationError() }
            return try wholeClipQuote(script, model: model)
        }, voice: { [weak self] script, progress in
            guard let self else { throw CancellationError() }
            return try await wholeClipVoice(script, progress: progress)
        }, videoSeconds: { [weak self] in
            self?.wholeClipPlan?.phrases.reduce(0) { $0 + $1.originalLength } ?? 0
        }, reword: { [weak self] script, shorter, target, voice, video in
            guard let self else { throw CancellationError() }
            return try await wholeClipReword(script, shorter: shorter, target: target, voiceSeconds: voice, videoSeconds: video)
        }, lipsync: { [weak self] voice, factor, model, progress in
            guard let self else { throw CancellationError() }
            return try await wholeClipLipsync(voice, factor: factor, model: model, progress: progress)
        }, lipsyncPrice: { [weak self] model in
            guard let self, let catalog = wholeClipCatalog, let seconds = wholeClipLipsyncSeconds else { return nil }
            return try WholeClipRevoice.lipsyncPrice(videoSeconds: seconds, lipsync: model, catalog: catalog).usd
        }, match: { [weak self] voice in
            await self?.wholeClipMatch(voice)
        }, play: { [weak self] original in
            self?.playWholeClip(original: original)
        }, use: { [weak self] voice, synced, match in
            guard let self else { throw CancellationError() }
            return try await useWholeClip(voice: voice, synced: synced, match: match)
        }, undo: { [weak editor] record in
            editor?.removeWholeClip(record)
        }, discard: { [weak self] in
            self?.wholeClipPlan?.invalidate(); self?.wholeClipPlan = nil
        }, report: { [weak editor] line in
            guard let log = editor?.app.log else { return }
            Task { await log.write(LogEntry(level: .warn, category: "voice-lab", message: line)) }
        })
    }

    private var wholeClipCatalog: VoiceLabPriceCatalog? {
        prices ?? editor.app.shared.flatMap { try? VoiceLabPriceCatalog.load(shared: $0) }
    }

    /// The lip-sync window's seconds: the parts' span with Rewrite's one-second handles (voice-lab §9.3).
    private var wholeClipLipsyncSeconds: Double? {
        if let phrases = wholeClipPlan?.phrases, let first = phrases.first, let last = phrases.last {
            return last.window.end - first.window.start + 2
        }
        guard let script = wholeClip?.script, let first = script.sentences.first, let last = script.sentences.last else { return nil }
        return last.end - first.start + 2
    }

    private func wholeClipQuote(_ script: WholeClipScript, model: WholeClipRevoice.Lipsync) throws -> WholeClipRevoiceSession.Quote {
        guard let catalog = wholeClipCatalog, let id = wholeClipID, let first = script.sentences.first, let last = script.sentences.last else {
            throw VoxClipError.sharedResourcesMissing
        }
        let seconds = last.end - first.start + 2
        let price = try WholeClipRevoice.price(characters: script.characters, ttsModel: VoiceLabWordingFit.modelID,
                                               videoSeconds: seconds, lipsync: model, catalog: catalog)
        let patchCharacters = includedVoiceHunks.reduce(0) { $0 + $1.newTokens.joined(separator: " ").unicodeScalars.count }
        let patch = takePlan?.estimate?.usd ?? (try? VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: VoiceLabWordingFit.modelID,
                                                                             units: Double(max(1, patchCharacters)), catalog: catalog))?.usd
        let inputs = wholeClipRuleInputs
        let voiceLab = editor.app.voiceLabSession
        let selected = generation?.voices.first { $0.id == generation?.selectedVoiceID }
        let anchor = voiceLab.anchorVoice(language: project.transcript?.language)
        let matched = selected != nil && selected?.id == preferredVoiceForVideo && selected?.id != anchor?.id
        return .init(clipNumber: editor.clipNumber(id) ?? 1, clipSeconds: editor.makeItRenderedSeconds(id), spokenWords: inputs.spokenWords,
                     reason: WholeClipRevoice.reason(inputs), patchUSD: patch, phrases: includedVoice.count,
                     voiceUSD: price.voice.usd, lipsyncUSD: price.lipsync.usd,
                     voiceName: selected.map { VoiceLabSession.rebuildName($0.voiceName) } ?? "your voice",
                     voiceNote: matched ? "matched to this video" : "")
    }

    /// The Voice step: a take plan over the script's parts, priced, then made under the click's approval.
    private func wholeClipVoice(_ script: WholeClipScript, progress: @escaping @MainActor (String) -> Void) async throws -> WholeClipRevoiceSession.Voice {
        await ensureVideoVoice()
        // The patch's own plan was only priced: it lets go of its quotes, so the voice's record has no run in flight.
        if let patch = takePlan, !hasPaidTakes {
            await patch.stop(); patch.invalidate(); takePlan = nil
        }
        guard current, let generation, let recordID = generation.selectedVoiceID, let takeBackend, let envelope else {
            throw WholeClipRevoiceSession.Unsent(error: WholeClipRevoiceSession.Stop.noVoice("Make your voice in Rewrite first. Nothing was sent."))
        }
        // The plan: free, and the same every time for the same clip, so a stop here is one Try Again would only repeat.
        let snapshot = editor.project
        weak var created: ClipTakePlan?
        let model = VoiceLabWordingFit.modelID
        let plan: ClipTakePlan
        do {
            let final = try editor.voiceLabReviewProject(localCommands: localCommands)
            let hunks = script.hunks(words: wholeClipWords(final), cutWordIds: Set(final.edits.cutWordIds), cutPauseIds: Set(final.edits.cutPauseIds))
            let makeInput = try takeInputMaker(final: final, recordID: recordID, modelID: model, envelope: envelope, model: { created?.modelID ?? model })
            plan = try ClipTakePlan(project: final, scope: scope, envelope: envelope, hunks: hunks, makeInput: makeInput,
                readCap: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.currentGenerationCap()
                }, isCurrent: { [weak self] in
                    guard let self else { return false }
                    var now = editor.project
                    now.voiceLab.speakingRateSamples = snapshot.voiceLab.speakingRateSamples
                    return current && now == snapshot && self.generation?.selectedVoiceID == recordID
                }, acceptedChargesChanged: { [weak app = editor.app] in await app?.refreshMonthlySpend() })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WholeClipRevoiceSession.Unsent(error: error)
        }
        created = plan
        _ = plan.changeModel(model)
        plan.prepareDurationRender = durationRenderPreparer()
        #if DEBUG
        plan.publishOverride = publishOverride
        #endif
        configureLipsync(plan)
        plan.connect(takeBackend(plan.phrases.count) { [weak plan] request, start in
            guard let plan else { throw CancellationError() }
            try await plan.dispatch(request, start: start)
        })
        wholeClipPlan?.invalidate()
        wholeClipPlan = plan
        progress("pricing \(plan.phrases.count == 1 ? "one part" : "\(plan.phrases.count) parts")")
        await plan.prepare()
        #if DEBUG
        editor.wholeClipPrepared?(plan)
        #endif
        try Task.checkCancellation()
        if let blocked = plan.phrases.first(where: { $0.blocked != nil }) {
            throw WholeClipRevoiceSession.Unsent(error: WholeClipRevoiceSession.Stop.noVoice((blocked.blocked ?? "") + " Nothing was sent."))
        }
        guard plan.problem.isEmpty, let approval = plan.approvalID else {
            throw WholeClipRevoiceSession.Stop.noVoice(plan.problem.isEmpty ? "The voice couldn't be priced. Nothing was sent." : plan.problem)
        }
        progress("\(plan.phrases.count == 1 ? "one take" : "\(plan.phrases.count) parts, one take")")
        await plan.start(approved: true, quoteID: approval)
        try Task.checkCancellation()
        var seconds = 0.0
        for phrase in plan.phrases {
            guard let take = plan.automaticTake(phrase: phrase.id), let length = take.length, plan.select(take: take.id, phrase: phrase.id) else {
                throw WholeClipRevoiceSession.Stop.noVoice("Part \(phrase.id + 1)'s take didn't pass its checks. " + (plan.problem.isEmpty ? "" : plan.problem))
            }
            seconds += length
        }
        return .init(key: .init(script: script.text, recordId: recordID, model: plan.modelID ?? model), seconds: seconds,
                     parts: plan.phrases.count, usd: plan.spent.usd ?? 0)
    }

    /// The Fit step's measured-wording round: Rewrite's own send with its measured feedback (voice-lab §8.2.2), for the
    /// whole clip as one line (the voice's measured length against the video's), then the reply's changes as the script.
    private func wholeClipReword(_ script: WholeClipScript, shorter: Bool, target: Int, voiceSeconds: Double,
                                 videoSeconds: Double) async throws -> WholeClipScript? {
        guard let connector, let shared = editor.app.shared else { return nil }
        struct Measured: Decodable { let shorterMeasuredFeedbackBlock: String; let shorterMeasuredPhraseLine: String }
        let template = try JSONDecoder().decode(Measured.self, from: Data(contentsOf: shared.root.appendingPathComponent("prompts/voice-rewrite-shorter-measured.json")))
        let final = try editor.voiceLabReviewProject(localCommands: localCommands)
        let original = wholeClipWords(final).filter { $0.kind == .word }.map(\.text).joined(separator: " ")
        let values = ["original": original, "proposed": script.text, "measuredSeconds": toFixed1(voiceSeconds), "slotSeconds": toFixed1(videoSeconds)]
        let line = template.shorterMeasuredPhraseLine.replacing(#/\{(original|proposed|measuredSeconds|slotSeconds)\}/#) { values[String($0.1)] ?? "" }
        var block = template.shorterMeasuredFeedbackBlock.replacingOccurrences(of: "{phrases}", with: line)
        block += "\nAim at about \(target) words for the whole clip."
        if !shorter { block = block.replacingOccurrences(of: "Say it in fewer words", with: "Say it in more words") }
        let prepared = try await prepareSend(connector, feedback: block)
        guard await confirmSend(), current else { return nil }
        guard let (checked, _) = try await reply(prepared, connector: connector, accept: { [weak self] in self?.current == true }) else { return nil }
        let hunks = checked.changes.map(\.hunk).filter { $0.kind == .voice }
        let cuts = Set(final.edits.cutWordIds).union(checked.changes.map(\.hunk).filter { $0.kind == .cut }.flatMap(\.sourceWordIds))
        return WholeClipScript.assemble(words: wholeClipWords(final), cutWordIds: cuts, voiceHunks: hunks)
    }

    /// Every part's picture matched to its take through Rewrite's own duration path (Match video), before the lip sync.
    func wholeClipMatchPicture() async throws -> ClipTakePlan {
        guard let plan = wholeClipPlan else { throw ClipTakePlan.Failure.stale }
        for phrase in plan.phrases where plan.lipsync.applied[phrase.id] != nil { plan.lipsync.undo(phrase.id) }
        for phrase in plan.phrases where phrase.videoChoice != .retimed {
            guard plan.chooseVideo(.retimed, phrase: phrase.id) else {
                throw WholeClipRevoiceSession.Stop.noVoice("Part \(phrase.id + 1)'s picture can't be matched to its voice.")
            }
        }
        await plan.prepareVideoChoices()
        try Task.checkCancellation()
        guard plan.problem.isEmpty else { throw WholeClipRevoiceSession.Stop.noVoice(plan.problem) }
        return plan
    }

    /// The Lip sync step: every part's picture matched to its take, then one lip sync over the merged window.
    private func wholeClipLipsync(_ voice: WholeClipRevoiceSession.Voice, factor: Double, model: WholeClipRevoice.Lipsync,
                                  progress: @escaping @MainActor (Double?) -> Void) async throws -> WholeClipRevoiceSession.Synced {
        let plan = try await wholeClipMatchPicture()
        await plan.lipsync.refresh()
        guard plan.lipsync.keyAvailable else { throw LipsyncError.missingKey }
        let (_, all) = try await plan.makeLipsyncOffers(model: model)
        guard let offer = all else { throw ClipTakePlan.Failure.stale }
        plan.lipsync.start(offer)
        let watcher = Task { [weak plan] in
            while let plan, plan.lipsync.running, !Task.isCancelled {
                if case .running(_, let value) = plan.lipsync.states[offer.phraseIDs.first ?? 0] { progress(value) }
                await plan.lipsync.waitForRun()
            }
        }
        await withTaskCancellationHandler {
            await plan.lipsync.waitForRun()
        } onCancel: {
            Task { @MainActor in for phrase in offer.phraseIDs { plan.lipsync.cancel(phrase) } }
        }
        watcher.cancel()
        try Task.checkCancellation()
        for phrase in offer.phraseIDs where plan.lipsync.applied[phrase] == nil {
            if case .failed(let reason, _, _) = plan.lipsync.states[phrase] { throw WholeClipRevoiceSession.Stop.noVoice("Couldn't lip sync: " + reason) }
            throw CancellationError()
        }
        return .init(model: model, usd: offer.estimate.usd ?? 0, factor: factor)
    }

    /// The anchor the baseline belongs to, named as Settings › Voices names it ("siim"), never the video's own voice.
    var wholeClipAnchorName: String {
        editor.app.voiceLabSession.anchorVoice(language: nil).map { VoiceLabSession.rebuildName($0.voiceName) } ?? "your voice"
    }

    private func wholeClipMatch(_ voice: WholeClipRevoiceSession.Voice) async -> WholeClipRevoiceRecord.Match? {
        guard let plan = wholeClipPlan else { return nil }
        let language = project.transcript?.language ?? "en"
        guard let check = try? await editor.app.speakerModelLibrary.check(language: language) else { return nil }
        var scores: [Double] = []
        for phrase in plan.phrases {
            guard let take = phrase.selected, let audio = take.row.audio, let input = plan.measuredInput(take: take.id),
                  let score = await VoicePerVideoMatch.score(take: audio, input: input, check: check) else { continue }
            scores.append(score)
        }
        guard !scores.isEmpty else { return nil }
        let baseline = editor.app.voiceLabSession.perVideoBook.anchorBaseline?.score
        return .init(take: scores.reduce(0, +) / Double(scores.count), anchorBaseline: baseline, realSpeech: nil)
    }

    /// ▶ Play the result, or A/B: the recording as it is, from the clip's first revoiced word.
    private func playWholeClip(original: Bool) {
        guard let plan = wholeClipPlan, let first = plan.phrases.first else { return }
        Task { [weak self, weak plan] in
            guard let self, let plan else { return }
            do {
                if original {
                    await editor.reloadPreview()
                    try await editor.preview.seek(to: max(0, first.window.start - 0.2), exact: true)
                } else {
                    let request = try await plan.lipsyncPreview()
                    try await editor.preview.load(request)
                    let start = plan.lipsync.applied[first.id].map { Double($0.window.outputStartSample) / request.timeline.sampleRate } ?? 0
                    try await editor.preview.seek(to: start, exact: true)
                }
                editor.preview.play()
            } catch { plan.lipsync.previewFailed() }
        }
    }

    /// Use Whole Clip: Rewrite's own commit of every part with its matched, lip-synced picture, and the project's record,
    /// as one undo step.
    private func useWholeClip(voice: WholeClipRevoiceSession.Voice, synced: WholeClipRevoiceSession.Synced,
                              match: WholeClipRevoiceRecord.Match?) async throws -> WholeClipRevoiceRecord {
        guard let plan = wholeClipPlan, let clip = wholeClipID else { throw ClipTakePlan.Failure.stale }
        let made = try await plan.acceptance()
        let usd = NSDecimalNumber(decimal: wholeClip?.spent ?? 0).doubleValue
        let record = WholeClipRevoiceRecord(id: "wholeclip-" + UUID().uuidString.lowercased().prefix(13), clipId: clip,
            segmentIds: made.segments.map(\.id), script: voice.key.script, consentRecordId: made.voice?.consentRecordId ?? voice.key.recordId,
            videoRetime: synced.factor, lipsyncModel: synced.model.rawValue, usd: usd, match: match,
            createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        try editor.applyVoiceLab(made.segments, assets: made.assets, voice: made.voice, scope: rewriteScope,
                                 localCommands: localCommands, videoAssets: made.videoAssets, wholeClip: record)
        editor.announce("Whole clip revoiced. Undo takes it back.")
        return record
    }
}

extension EditorModel {
    /// Takes a used whole-clip revoice back out as one undo step: its segments off and its record removed.
    func removeWholeClip(_ record: WholeClipRevoiceRecord) {
        let next = removingWholeClip(record, from: project)
        guard next != project else { return }
        replace(next, name: "Undo Whole Clip")
    }

    /// `project` without `record`: its segments off (their paid audio stays playable for Redo) and the record gone.
    func removingWholeClip(_ record: WholeClipRevoiceRecord, from project: Project) -> Project {
        var next = project
        next.voiceLab.wholeClipRevoices?.removeAll { $0.id == record.id }
        if next.voiceLab.wholeClipRevoices?.isEmpty == true { next.voiceLab.wholeClipRevoices = nil }
        let output = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        for id in record.segmentIds { next = (try? VoiceLabEditCommand.setEnabled(segmentID: id, enabled: false).applying(to: next, outputScope: output)) ?? next }
        return next
    }
}
