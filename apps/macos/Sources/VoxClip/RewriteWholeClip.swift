import Foundation
import VoxClipCore
import VoxClipMedia

/// Revoice the whole clip inside Rewrite (ADR-R46): the card's actions and the live steps. The voice is a take plan over the
/// script's parts (`WholeClipScript.hunks`), so each part goes through the same window placement, R40 guard, R43
/// calibration, per-video voice (R45), take checks and journals as a phrase. One timeline (ADR-R46): each take is laid out
/// on the clip **as edited** (`VoiceLabEditedLayout`), as generated; a shorter take speeds the picture up evenly (at most
/// 1.2×) before its pauses grow. Its picture is the clip's own cuts (`cut` at zoom 1, with that speed) through the same
/// duration path, so the fit, the picture, the render and the lip sync all read the same timeline. The Fit step checks the
/// picture match and the lip sync's free preconditions before anything is offered; the lip sync is Rewrite's own over one
/// merged window with the chosen model; Use is Rewrite's own commit, one undo step, with the project's `wholeClipRevoices`
/// record. The voice plan is current while what it is made from is (`wholeClipIdentity`): a save, music, captions or another
/// clip never makes a paid voice stale, and an edit of the clip keeps it, stale, until Undo or Start Over.
extension RewriteSession {
    /// The clip this Rewrite is inside, nil for the full take.
    var wholeClipID: String? {
        switch rewriteScope {
        case .clip(let id): return id
        case .selection(let range): return Self.enclosingClip(range, in: project)
        case .fullTake: return nil
        }
    }

    /// The card shows at the price step whenever the whole clip can be offered: Voice Lab on with voice changes in one
    /// clip, a voice chosen and no paid patch takes. The pick only sets its default; after the patch is picked it is one
    /// compact row ("Revoice the Whole Clip Instead · ≈ $X"), so the whole clip stays findable and redoable. A run keeps
    /// it shown until it ends.
    var offersWholeClip: Bool {
        guard showsVoiceLab, wholeClipID != nil, generation?.selectedVoiceID != nil, !wholeClipVoiceHunks.isEmpty else { return false }
        if let session = wholeClip, session.phase != .choose { return true }
        return !hasPaidTakes
    }

    /// The card, made on first show and again for a new proposal; its price is fetched in the background (free).
    func wholeClipCard() -> PanelCard? {
        guard offersWholeClip, let clip = wholeClipID else { return nil }
        // A new proposal for the clip, in this Rewrite or a later one: the earlier pick and price were for other words.
        if let session = wholeClip, session.phase == .choose, session.proposalID != proposalID {
            wholeClip = nil
        }
        if wholeClip == nil, let pick = editor.wholeClipPicks[clip], pick.proposal != proposalID { editor.wholeClipPicks[clip] = nil }
        if let session = wholeClip {
            // The changes on the card changed (one included or left out, or an edit under a stopped paid voice): the price
            // on its button (Revoice Whole Clip, Start Over) follows them.
            if session.needsRequote {
                Task { [weak self, weak session] in
                    await session?.refreshQuote()
                    self?.refreshWholeClipPanel()
                }
            }
            return .wholeClip
        }
        let session = WholeClipRevoiceSession()
        session.proposalID = proposalID
        session.wholeSelected = editor.wholeClipPicks[clip]?.whole != false
        configureWholeClip(session)
        // A whole clip saved before VoxClip quit or crashed comes back on its card (`RewriteSavedProposal`).
        restoreWholeClip(into: session)
        #if DEBUG
        editor.wholeClipSmoke?(self, session)
        #endif
        wholeClip = session
        Task { [weak self, weak session] in
            await session?.refreshQuote()
            self?.refreshWholeClipPanel()
        }
        return .wholeClip
    }

    func refreshWholeClipPanel() {
        if isOpen, case .proposal = task.state { showProposal() }
    }

    /// The patch was picked for this clip: the card is one row, "Revoice the Whole Clip Instead · ≈ $X".
    var wholeClipCompact: Bool {
        guard let session = wholeClip, session.phase == .choose, let clip = wholeClipID, let pick = editor.wholeClipPicks[clip] else { return false }
        return !pick.whole && pick.proposal == proposalID
    }

    /// "Add fal.ai Key…": the lip sync needs the key, so nothing is priced without it (Settings › Voice Lab takes it, and
    /// the card offers the price once it is saved).
    private func wholeClipAddKeyAction() -> PanelAction {
        PanelAction(id: "wholeClipAddKey", title: "Add fal.ai Key…") { openVoxClipSettings(pane: "voiceLab") }
    }

    /// The card's primary: "Revoice Whole Clip · ≈ $X" (the click approves the voice and the lip sync at that price), or
    /// "Voice Only the Changed Phrases" for the patch. With no fal.ai key the whole clip opens Settings for it.
    func wholeClipPrimary(retry: Bool = false) -> PanelAction? {
        guard let session = wholeClip, session.repeatedWordCheckPart == nil else { return nil }
        guard session.wholeSelected || retry else {
            guard wholeClipReplacement == nil else { return nil }
            return PanelAction(id: "wholeClipPatchPick", title: "Voice Only the Changed Phrases") { [weak self] in self?.patchInstead() }
        }
        if wholeClipReplacement != nil, session.quote == nil { return nil }
        guard session.keyAvailable else { return wholeClipAddKeyAction() }
        guard let usd = session.quote?.wholeUSD else { return nil }
        // Try Again pays only what's left; a kept lip-sync result is re-imported for free ("Try Again · free").
        let remaining = retry ? session.retryUSD ?? usd : usd
        let price = remaining > 0 ? " · " + VoiceLabCostPresentation.format(remaining) : retry ? " · free" : ""
        return PanelAction(id: retry ? "wholeClipRetry" : "wholeClipRevoice", title: (retry ? "Try Again" : "Revoice Whole Clip") + price, priced: remaining > 0) { [weak self] in
            self?.startWholeClip(approved: remaining)
        }
    }

    /// The callout's chip over a large change: "Revoice the Whole Clip · ≈ $X". Nothing is spent until it is clicked.
    func wholeClipChipAction() -> PanelAction? {
        guard let session = wholeClip, session.phase == .choose, session.keyAvailable, let usd = session.quote?.wholeUSD else { return nil }
        return PanelAction(id: "wholeClipChip", title: "Revoice the Whole Clip · " + VoiceLabCostPresentation.format(usd), priced: true) { [weak self] in
            self?.wholeClip?.wholeSelected = true
            self?.startWholeClip(approved: usd)
        }
    }

    /// The compact card's row after the patch was picked: "Revoice the Whole Clip Instead · ≈ $X", its click the approval.
    func wholeClipInsteadAction() -> PanelAction? {
        guard let session = wholeClip, session.phase == .choose else { return nil }
        guard session.keyAvailable else { return wholeClipAddKeyAction() }
        guard let usd = session.quote?.wholeUSD else { return nil }
        return PanelAction(id: "wholeClipInstead", title: "Revoice the Whole Clip Instead · " + VoiceLabCostPresentation.format(usd), priced: true) { [weak self] in
            self?.wholeClip?.wholeSelected = true
            self?.startWholeClip(approved: usd)
        }
    }

    /// "Change fewer words": the voice budget's own re-ask (RewriteNextSteps.swift).
    func changeFewerWordsAction() -> PanelAction? {
        guard let advice = voiceBudget else { return nil }
        return budgetSteps(advice, freeChanges: 0).chips.first { $0.action.id == "changeFewerWords" }?.action
    }

    /// Review's upgrade: "Sharper Lip Sync · sync-3 · ≈ $X", re-running only the lip sync over the paid voice. After a lost
    /// submit answer it is the user's own "I Checked fal.ai" button, which may charge twice.
    func wholeClipUpgradeAction() -> PanelAction? {
        guard let session = wholeClip, session.phase == .review, let usd = session.upgradeUSD, !session.automatic else { return nil }
        let price = session.upgradeKept ? "free" : VoiceLabCostPresentation.format(usd)
        if session.submissionUnconfirmed {
            return PanelAction(id: "wholeClipUpgradeCheckedFal", title: "I Checked fal.ai · Sharper Lip Sync Again · \(price) (fal.ai may charge twice)",
                               priced: true) { [weak self, weak session] in
                session?.upgradeAfterCheckingFal()
                self?.watchWholeClip()
            }
        }
        return PanelAction(id: "wholeClipUpgrade", title: "Sharper Lip Sync · sync-3 · " + price, priced: !session.upgradeKept) { [weak self, weak session] in
            session?.upgrade()
            self?.watchWholeClip()
        }
    }

    /// The stopped card's actions, the first one primary. Every one can succeed (design.md, Stopped):
    /// - Use failed: Try Use Again · free.
    /// - A lost submit answer: the user's own "I Checked fal.ai · Lip Sync Again", which may charge twice.
    /// - The clip changed since its voice was paid: Start Over (priced, the voice paid again); Undo brings Try Again back.
    /// - A shorter wording waiting: Voice the Shorter Wording · ≈ $Y; one to ask for: Shorter Wording · free.
    /// - Otherwise Try Again (priced) only when a retry can succeed: after a stop that would only repeat, such as a part that
    ///   can't be placed, a picture that can't be matched or a lip sync that failed on this Mac, the patch is the way forward.
    ///   After a voice that can't fit, over the same script, or the same stop twice in a row, the patch is the primary and
    ///   the retry comes second (ADR-R46). The patch says when it drops a paid voice.
    func wholeClipStoppedActions() -> [PanelAction] {
        guard let session = wholeClip, session.isStopped else { return [] }
        var actions = wholeClipStopActions(session)
        // A paid voice whose lip sync can't run can still go in, free (lead decision): just before the patch, which drops it.
        if session.canUseVoiceOnly {
            let voiceOnly = PanelAction(id: "wholeClipVoiceOnly", title: "Use the Voice Without Lip Sync · free") { [weak self] in
                self?.useWholeClipVoiceOnly()
            }
            actions.insert(voiceOnly, at: actions.firstIndex { $0.id == "wholeClipPatch" } ?? actions.endIndex)
        }
        if let replacement = wholeClipReplacement {
            actions.removeAll { $0.id == "wholeClipPatch" }
            if !hasUnusedPaidWork { actions.append(undoRevoiceAction(replacement)) }
            if actions.isEmpty { actions.append(task.close) }
        }
        return actions
    }

    private func wholeClipStopActions(_ session: WholeClipRevoiceSession) -> [PanelAction] {
        if let part = session.repeatedWordCheckPart, !session.stoppedForInputs {
            return [
                PanelAction(id: "wholeClipPatch", title: "Voice Only the Changed Phrases") { [weak self] in self?.patchInstead() },
                PanelAction(id: "wholeClipEditWords", title: "Edit the Words") { [weak self] in
                    self?.editWholeClipWords(part: part)
                },
            ]
        }
        // Only a voice still held is one the patch drops: one let go (Start Over) is counted in the spend, not here.
        let paid = session.heldVoiceSpent > 0
        let patch = PanelAction(id: "wholeClipPatch", title: paid ? "Voice Only the Changed Phrases (drops the paid voice)" : "Voice Only the Changed Phrases") { [weak self] in
            self?.patchInstead()
        }
        if session.failure?.atUse == true {
            let again = PanelAction(id: "wholeClipUseAgain", title: "Try Use Again · free") { [weak self] in self?.useWholeClipAgain() }
            return [again, patch]
        }
        if session.submissionUnconfirmed {
            guard let usd = session.checkedFalUSD else { return [patch] }
            // A lip sync already paid over this voice and picture is only put back: the button says free.
            let price = usd > 0 ? VoiceLabCostPresentation.format(usd) + " (fal.ai may charge twice)" : "free"
            let checked = PanelAction(id: "wholeClipCheckedFal", title: "I Checked fal.ai · Lip Sync Again · " + price, priced: usd > 0) { [weak self] in
                self?.wholeClip?.lipsyncAfterCheckingFal()
                self?.watchWholeClip()
            }
            return [checked, patch]
        }
        if session.stoppedForInputs {
            if session.inputsRestored, let retry = wholeClipPrimary(retry: true) { return [retry, patch] }
            guard session.keyAvailable else { return [wholeClipAddKeyAction(), patch] }
            guard let usd = session.quote?.wholeUSD else { return [patch] }
            // The click approves this price: Start Over prices the clip again first, and runs only within it.
            let over = PanelAction(id: "wholeClipStartOver", title: "Start Over · " + VoiceLabCostPresentation.format(usd), priced: true) { [weak self] in
                self?.startWholeClipOver(approved: usd)
            }
            return [over, patch]
        }
        // A voice chosen, Voice Lab ready, an editable project or an Undo lets the Voice step pass; until then a Try Again
        // could only meet the same stop.
        if session.waitsForReadiness { return [patch] }
        let first = session.repeatsFit || session.failure?.again == true
        if let shorter = session.shorterWording {
            let price = shorter.usd.map { " · " + VoiceLabCostPresentation.format($0) } ?? ""
            let voice = PanelAction(id: "wholeClipVoiceShorter", title: "Voice the Shorter Wording" + price, priced: true) { [weak self] in
                self?.wholeClip?.voiceShorterWording()
                self?.watchWholeClip()
            }
            return [voice, patch]
        }
        if session.failure?.rewordable == true {
            guard session.canAskShorterWording else { return [patch] }
            let ask = PanelAction(id: "wholeClipShorter", title: "Shorter Wording · free") { [weak self] in
                self?.wholeClip?.askShorterWording()
                self?.watchWholeClip()
            }
            return first ? [patch, ask] : [ask, patch]
        }
        guard session.failure?.repeats != true, let retry = wholeClipPrimary(retry: true) else { return [patch] }
        // The same stop twice: the patch leads and Try Again comes second (design.md, Stopped).
        return first ? [patch, retry] : [retry, patch]
    }

    func startWholeClip(automatic: Bool = false, budget: Decimal? = nil, approved: Decimal? = nil) {
        guard let session = wholeClip, let clip = wholeClipID, !session.running, !session.submissionUnconfirmed,
              session.repeatedWordCheckPart == nil else { return }
        if let approved {
            let price = session.isStopped ? session.retryUSD : session.quote?.wholeUSD
            guard let price, price <= approved else { return }
        }
        editor.wholeClipPicks[clip] = WholeClipPick(whole: true, proposal: proposalID)
        session.start(automatic: automatic, budget: budget)
        editor.announce("Revoicing the whole clip.")
        watchWholeClip()
    }

    /// Refreshes the panel while the whole clip runs and once it ends.
    func watchWholeClip() {
        refreshWholeClipPanel()
        Task { [weak self, weak session = wholeClip] in
            while session?.running == true { await session?.waitForRun() }
            self?.refreshWholeClipPanel()
        }
    }

    /// Start Over · ≈ $Y, clicked at `approved`: the clip as it is now is priced first. Within that price, the paid voice
    /// that no longer matches is let go (what it cost stays counted) and the clip is revoiced from the start; over it,
    /// nothing is let go or paid, and the stop shows Start Over at the new price for its own click.
    @discardableResult func startWholeClipOver(approved: Decimal) -> Task<Void, Never> {
        Task { [weak self, weak session = wholeClip] in
            guard let session, await session.startOver(approved: approved) else {
                self?.refreshWholeClipPanel()
                return
            }
            self?.startWholeClip()
        }
    }

    /// The patch, as before: the pick is kept for this clip and the card becomes its compact row.
    func patchInstead() {
        guard wholeClipReplacement == nil, let clip = wholeClipID else { return }
        editor.wholeClipPicks[clip] = WholeClipPick(whole: false, proposal: proposalID)
        Task { [weak self] in
            await self?.wholeClip?.discard()
            self?.retireWholeClipVoicePlan()
            self?.wholeClip = nil
            self?.retiredWholeClipVoiceSpend = 0
            self?.refreshWholeClipPanel()
        }
    }

    private func editWholeClipWords(part: Int) {
        let index = part - 1
        let words: [String]
        if let plan = wholeClipPlan, plan.phrases.indices.contains(index),
           let first = editor.wordIndex[plan.phrases[index].window.firstWordId],
           let last = editor.wordIndex[plan.phrases[index].window.lastWordId], first <= last {
            words = editor.words[first...last].map(\.id)
        } else if let parts = wholeClip?.script?.parts, parts.indices.contains(index) {
            words = parts[index].sourceWordIds
        } else { return }
        let wordIDs = Set(words)
        if let change = ownProposal?.changes.first(where: { includedVoice.contains($0.ordinal) && !wordIDs.isDisjoint(with: $0.span) }) {
            editor.focusChange(change.ordinal)
            if editor.openRewriteThreadOwnWords() { return }
        }
        guard let word = words.first(where: { !editor.cutWordIDs.contains($0) }) else { return }
        editor.selectedPauseIDs = []
        editor.selectedWordIDs = [word]
        editor.beginCorrection()
    }

    @discardableResult func useWholeClip() -> Task<Void, Never> {
        Task { [weak self] in
            await self?.wholeClip?.use()
            self?.refreshWholeClipPanel()
        }
    }

    /// Try Use Again · free.
    @discardableResult func useWholeClipAgain() -> Task<Void, Never> {
        Task { [weak self] in
            await self?.wholeClip?.useAgain()
            self?.refreshWholeClipPanel()
        }
    }

    /// Use the Voice Without Lip Sync · free (a user click only).
    @discardableResult func useWholeClipVoiceOnly() -> Task<Void, Never> {
        Task { [weak self] in
            await self?.wholeClip?.useVoiceOnly()
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

    private func wholeClipReviewProject() throws -> Project {
        let final = try editor.voiceLabReviewProject(localCommands: localCommands)
        return wholeClipReplacement?.removing(from: final) ?? final
    }

    private func wholeClipHunks(_ script: WholeClipScript, project: Project) -> [VoiceLabDiffHunk] {
        script.hunks(words: wholeClipWords(project), cutWordIds: Set(project.edits.cutWordIds), cutPauseIds: Set(project.edits.cutPauseIds))
    }

    /// The clip's transcript items, corrected, from the review's project.
    private func wholeClipWords(_ final: Project) -> [TimedWord] {
        let words = Self.corrected(final)
        guard let id = wholeClipID, let clip = final.edits.clips.first(where: { $0.id == id }),
              let lower = words.firstIndex(where: { $0.id == clip.startWordId }),
              let upper = words.firstIndex(where: { $0.id == clip.endWordId }), lower <= upper else { return [] }
        return Array(words[lower...upper])
    }

    /// The voice changes the whole clip says (wholeclip-drops-unfit-changes): the included ones, those the wording fit kept as
    /// recorded because they ran long (`wordingFit.kept`), and those whose slot can't hold them. The whole clip lays the
    /// picture out under its voice, which is what carries a wording too long for its slot. Only the user's own exclusions
    /// stay out.
    var wholeClipVoiceHunks: [VoiceLabDiffHunk] {
        let unfit = reviewedVoiceOrdinals.filter { voiceReview($0)?.timing?.fits == false }
        let said = Set(includedVoice).union(wordingFit.kept).union(unfit)
        return changes.enumerated().filter { $0.element.hunk.kind == .voice && said.contains($0.offset + 1) }.map(\.element.hunk)
    }

    /// The rule's inputs here: the clip's spoken words after its cuts, the words the whole clip re-voices, and the phrases
    /// that can't fit.
    var wholeClipRuleInputs: WholeClipRevoice.RuleInputs {
        let final = (try? wholeClipReviewProject()) ?? project
        let cuts = Set(final.edits.cutWordIds)
        let spoken = wholeClipWords(final).filter { $0.kind == .word && !cuts.contains($0.id) }.count
        let revoiced = wholeClipVoiceHunks.reduce(0) { $0 + $1.newTokens.count }
        let noFit = (takePlan?.phrases.indices.filter { takePlan?.fitsNoDuration(phrase: $0) == true }.count ?? 0) + wordingFit.kept.count
        return .init(spokenWords: spoken, revoicedWords: revoiced, noFitPhrases: noFit)
    }

    func configureWholeClip(_ session: WholeClipRevoiceSession) {
        let editor = self.editor
        session.backend = WholeClipRevoiceSession.Backend(script: { [weak self] in
            guard let self else { throw CancellationError() }
            let final = try wholeClipReviewProject()
            guard let script = WholeClipScript.assemble(words: wholeClipWords(final), cutWordIds: Set(final.edits.cutWordIds),
                                                        voiceHunks: wholeClipVoiceHunks) else { throw ClipTakePlan.Failure.nothingToVoice }
            return script
        }, quote: { [weak self] script, model in
            guard let self else { throw CancellationError() }
            return try wholeClipQuote(script, model: model)
        }, voice: { [weak self] script, progress in
            guard let self else { throw CancellationError() }
            return try await wholeClipVoice(script, progress: progress)
        }, videoSeconds: { [weak self] in
            self?.wholeClipEditedSeconds ?? 0
        }, reword: { [weak self] script, target, voice, video in
            guard let self else { throw CancellationError() }
            return try await wholeClipReword(script, target: target, voiceSeconds: voice, videoSeconds: video)
        }, canReword: { [weak self] in
            // The reword asks the AI this Rewrite was opened with: after an AI change it waits for Rewrite Again.
            self?.connector != nil && self?.editor.app.shared != nil && self?.current == true
        }, estimate: { [weak self] script in
            self?.wholeClipEstimate(script)
        }, unfinishedVoicePrice: { [weak self] in
            guard let plan = self?.wholeClipPlan, plan.stillCurrent else { return nil }
            return plan.unfinishedVoicePrice
        }, unsettledVoiceSpend: { [weak self] in
            guard let self, !wholeClipPlanSettled else { return 0 }
            return wholeClipPlan?.spent.usd ?? 0
        }, retiredVoiceSpend: { [weak self] in
            self?.retiredWholeClipVoiceSpend ?? 0
        }, partlyVoiced: { [weak self] script in
            guard let self, let plan = wholeClipPlan, wholeClipPlanScript == script else { return false }
            return plan.spent.units > 0
        }, voiceReadiness: { [weak self] in
            self?.wholeClipVoiceReadiness() ?? .unavailable
        }, picture: { [weak self] voice in
            guard let self else { throw CancellationError() }
            return try await wholeClipPicture(voice)
        }, lipsync: { [weak self] voice, factor, model, progress in
            guard let self else { throw CancellationError() }
            return try await wholeClipLipsync(voice, factor: factor, model: model, progress: progress)
        }, lipsyncPrice: { [weak self] model in
            guard let self, let catalog = wholeClipCatalog, let seconds = wholeClipLipsyncSeconds else { return nil }
            return try WholeClipRevoice.lipsyncPrice(videoSeconds: LipsyncLimits.uploadSeconds(seconds), lipsync: model, catalog: catalog).usd
        }, match: { _ in nil }, play: { [weak self] original in
            self?.playWholeClip(original: original)
        }, use: { [weak self] voice, synced, match in
            guard let self else { throw CancellationError() }
            return try await useWholeClip(voice: voice, synced: synced, match: match)
        }, undo: { [weak editor] record in
            editor?.removeWholeClip(record)
        }, discard: { [weak self] in
            self?.retireWholeClipVoicePlan()
        }, report: { [weak editor] line in
            guard let log = editor?.app.log else { return }
            Task { await log.write(LogEntry(level: .warn, category: "voice-lab", message: line)) }
        }, hasKey: { [weak editor] in
            // Presence only, without reading the secret (no Keychain prompt); tests replace the store.
            await editor?.app.providerKeyStore.hasKey(for: "fal") ?? false
        }, preflight: { [weak self] in
            try await self?.wholeClipPreflight()
        }, voiceCurrent: { [weak self] voice in
            guard let self, let plan = wholeClipPlan else { return false }
            return plan.stillCurrent && wholeClipPlanScript?.text == voice.key.script
        }, appliedLipsync: { [weak self] in
            self?.wholeClipPlan?.lipsync.applied ?? [:]
        }, restoreLipsync: { [weak self] entries in
            await self?.restoreWholeClipLipsync(entries) ?? false
        }, useVoiceOnly: { [weak self] voice in
            guard let self else { throw CancellationError() }
            try await putInWholeClipVoiceOnly(voice)
        }, persist: { [weak self] in
            self?.persistPaidWork()
        }, voiceKey: { [weak self] script in
            // As `wholeClipVoice` makes it: the voice chosen now, on the wording-fit model.
            guard let recordID = self?.generation?.selectedVoiceID else { return nil }
            return .init(script: script.text, recordId: recordID, model: VoiceLabWordingFit.modelID)
        })
    }

    private var wholeClipCatalog: VoiceLabPriceCatalog? {
        prices ?? editor.app.shared.flatMap { try? VoiceLabPriceCatalog.load(shared: $0) }
    }

    /// The clip as edited (its cuts and tightened pauses applied) with no voice in it: the one timeline the whole clip's
    /// fit, layout, picture and lip sync read (ADR-R46).
    private func wholeClipEditedPlan(_ final: Project) -> VoiceLabOutputPlan? {
        guard let id = wholeClipID else { return nil }
        return try? VoiceLabOutputPlanner.build(final, scope: .clip(id))
    }

    /// The parts' windows as edited, in seconds: each window without the clip's own cuts inside it. Before the voice's
    /// plan exists, the script's span on the clip as edited.
    var wholeClipEditedSeconds: Double? {
        guard let final = try? wholeClipReviewProject(), let edited = wholeClipEditedPlan(final) else { return nil }
        if let phrases = wholeClipPlan?.phrases, !phrases.isEmpty {
            return phrases.reduce(0) { total, phrase in
                let cuts = WholeClipRevoice.editedCuts(edited, startSample: phrase.window.startSample, endSample: phrase.window.endSample)
                return total + WholeClipRevoice.editedSeconds(cuts, startSample: phrase.window.startSample, endSample: phrase.window.endSample,
                                                               sampleRate: edited.sampleRate)
            }
        }
        guard let script = wholeClip?.script ?? (try? wholeClip?.backend?.script()), let first = script.sentences.first,
              let last = script.sentences.last else { return nil }
        return edited.mapTime(last.end) - edited.mapTime(first.start)
    }

    /// The lip-sync window's seconds with Rewrite's one-second handles (voice-lab §9.3): the Fit step's picture as it plays
    /// (sped up, laid out and trimmed), else the clip as edited.
    private var wholeClipLipsyncSeconds: Double? {
        if let output = wholeClip?.picture?.outputSeconds, output > 0 { return output + 2 }
        return wholeClipEditedSeconds.map { $0 + 2 }
    }

    /// The calibrated speaking-rate estimate of a script (check before paying), part by part as the voice says it: the
    /// speaker's measured rate with each part's onset and trims, times the voice's calibration (its measured ÷ estimated
    /// ratio, as the patch's word budgets read it, RewriteWordingFit.swift). Without the speaker's rate, the generated
    /// takes' rate or the provider's floor.
    private func wholeClipEstimate(_ script: WholeClipScript) -> Double? {
        if let rate = try? VoiceLabPhraseTiming.speakingRate(transcript: RewriteReview.timingTranscript(reviewInputs)) {
            let multiplier = VoiceLabWordingFit.multiplier(rateSamples(VoiceLabWordingFit.modelID))
            var total = 0.0
            for part in script.parts {
                guard let seconds = try? VoiceLabPhraseTiming.estimate(text: part.text, rate: rate) else { return nil }
                total += seconds
            }
            return total * multiplier
        }
        let rate = (try? VoiceLabLengthBudget.generatedRate(project: project).charactersPerSecond) ?? VoiceLabLengthBudget.providerRateFloor
        return try? VoiceLabPhraseTiming.estimate(text: script.text, rate: max(rate, VoiceLabLengthBudget.providerRateFloor))
    }

    private func wholeClipQuote(_ script: WholeClipScript, model: WholeClipRevoice.Lipsync) throws -> WholeClipRevoiceSession.Quote {
        guard let catalog = wholeClipCatalog, let id = wholeClipID, let first = script.sentences.first, let last = script.sentences.last else {
            throw VoxClipError.sharedResourcesMissing
        }
        // The lip sync is priced on the clip as edited, the video it gets, with Rewrite's one-second handles and the upload's
        // tail margin (LipsyncLimits.tailMarginSeconds).
        let final = try wholeClipReviewProject()
        let edited = wholeClipEditedPlan(final)
        let seconds = (edited.map { $0.mapTime(last.end) - $0.mapTime(first.start) } ?? (last.end - first.start)) + 2
        if wholeClipReplacement != nil {
            guard let video = final.media.source.video else { throw LipsyncPreparationError.unsupportedVideo }
            try LipsyncWindowPreparation.preflight(video: video, outputSeconds: seconds)
            guard let envelope else { throw ClipTakePlan.Failure.noSelection }
            let hunks = wholeClipHunks(script, project: final)
            _ = try ClipTakePlan.preparePlan(project: final, scope: scope, envelope: envelope, hunks: hunks)
        }
        let price = try WholeClipRevoice.price(characters: script.characters, ttsModel: VoiceLabWordingFit.modelID,
                                               videoSeconds: LipsyncLimits.uploadSeconds(seconds), lipsync: model, catalog: catalog)
        guard let wordCheckUSD = Self.wordCheckUSD(catalog) else { throw VoxClipError.sharedResourcesMissing }
        let wordChecksUSD = wordCheckUSD * Decimal(script.parts.count)
        let patchCharacters = wholeClipVoiceHunks.reduce(0) { $0 + $1.newTokens.joined(separator: " ").unicodeScalars.count }
        let patch = wholeClipReplacement != nil ? nil : takePlan?.estimate?.usd ?? (try? VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: VoiceLabWordingFit.modelID,
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
                     voiceNote: matched ? "matched to this video" : "", wordChecksUSD: wordChecksUSD)
    }

    private func retireWholeClipVoicePlan() {
        if !wholeClipPlanSettled { retiredWholeClipVoiceSpend += wholeClipPlan?.spent.usd ?? 0 }
        wholeClipPlan?.invalidate()
        wholeClipPlan = nil
        wholeClipPlanScript = nil
        wholeClipPlanSettled = false
    }

    /// What the whole clip's paid voice and lip sync are made from (`Project.voiceTakeIdentity` over the clip): its words,
    /// cuts, pauses and corrections, the source and its clean audio. Save metadata, the tab, music, captions, colour,
    /// motion, other clips and VoxClip's own calibration writes are not part of it (voice-lab.md "What counts as an edit").
    func wholeClipIdentity(_ project: Project) -> Project? {
        guard let id = wholeClipID else { return nil }
        return project.voiceTakeIdentity(scope: .clip(id), enclosingClipID: id)
    }

    /// The currency of what a whole-clip voice is made from, captured now: true while the Rewrite can spend on its voice
    /// (`voiceSpendCurrent`, never the AI connector) and the clip's identity is the one it was made over.
    func wholeClipInputsCurrency() -> @MainActor () -> Bool {
        let identity = wholeClipIdentity(editor.project)
        return { [weak self] in
            guard let self else { return false }
            return voiceSpendCurrent && wholeClipIdentity(editor.project) == identity
        }
    }

    /// The stop for a paid plan that no longer matches the clip: "You edited Clip N after its voice was made…", or "You
    /// chose another voice…" when the voice chosen now is not the one its takes were made with.
    private func wholeClipInputsChanged(_ plan: ClipTakePlan) -> WholeClipRevoiceSession.Stop {
        let madeWith = plan.phrases.lazy.flatMap(\.takes).compactMap { plan.measuredInput(take: $0.id)?.recordID }.first
            ?? wholeClip?.voice?.key.recordId
        let switched = madeWith.map { $0 != generation?.selectedVoiceID } ?? false
        return .voiceInputsChanged(clip: wholeClipClipNumber, usd: plan.spent.usd ?? 0, voiceSwitched: switched)
    }

    private var wholeClipClipNumber: Int { wholeClipID.flatMap(editor.clipNumber) ?? 1 }

    /// What stops the whole clip's Voice step before anything is sent, until something outside the card changes; nil when
    /// it can go on (`WholeClipRevoiceSession.Backend.voiceReadiness`). The card's Try Again waits for it.
    func wholeClipVoiceReadiness() -> WholeClipRevoiceSession.Stop? {
        guard isOpen, editor.capabilities.edit else { return .locked }
        // `voiceSpendCurrent` past the two above: the scope's inputs are not the ones this Rewrite was made for.
        guard voiceSpendCurrent else { return .rewriteChanged(clip: wholeClipClipNumber) }
        guard generation?.selectedVoiceID != nil else { return .voiceMissing }
        guard takeBackend != nil, envelope != nil else { return .unavailable }
        return nil
    }

    /// A stale plan never stops as "nothing was sent" over paid takes: with spend it is kept (stale until Undo or Start
    /// Over); with none it goes, and the next click prices the clip as it is.
    private func checkWholeClipPlan(_ plan: ClipTakePlan) throws {
        guard !plan.stillCurrent else { return }
        if plan.spent.units > 0 { throw wholeClipInputsChanged(plan) }
        if wholeClipPlan === plan { retireWholeClipVoicePlan() }
        throw ClipTakePlan.Failure.stale
    }

    /// The lip sync's free checks on the source before any voice is paid (no-voice-only-and-late-checks): a source fal.ai
    /// can be sent (its size and a frame rate of 1 to 60), and the clip as edited with its handles within 3 s to 5 min. The
    /// Voice step checks the fal.ai key first thing.
    private func wholeClipPreflight() async throws {
        typealias Session = WholeClipRevoiceSession
        do {
            guard let video = project.media.source.video else { throw LipsyncPreparationError.unsupportedVideo }
            // A length not known yet (no clip as edited) is checked by the lip sync's own window later.
            if let seconds = wholeClipLipsyncSeconds { try LipsyncWindowPreparation.preflight(video: video, outputSeconds: seconds) }
            else { _ = try LipsyncWindowPreparation.uploadSize(video) }
        } catch {
            throw Session.Unsent(error: Session.LipsyncFailed(error: error, local: true))
        }
    }

    /// The backstop before a restored voice is paid for: the click approved putting it back at its Try Again's price
    /// (`approved`, `restoredRetryVoiceUSD`); a fresh price above it (a part's journal entry went after the card was priced,
    /// or another run holds it) sends nothing and waits for its own click at the new price. The card is priced again from
    /// the fresh plan: its price, and the parts the plan adopts, so a part voiced again also prices a new lip sync and the
    /// line names the parts that come back.
    func holdRestoredVoicePrice(_ plan: ClipTakePlan, approved: Decimal?) throws {
        guard let approved, let fresh = plan.estimate?.usd, fresh <= approved else {
            let fresh = plan.estimate?.usd
            let back = plan.adoptedPhraseCount
            if wholeClipPlan === plan { retireWholeClipVoicePlan() } else { plan.invalidate() }
            if let fresh { wholeClip?.repriceRestoredVoice(fresh, partsBack: back) }
            throw WholeClipRevoiceSession.Stop.noVoice("The price to put your paid voice back changed. Nothing new was sent. Review the new price before retrying.")
        }
    }

    /// The Voice step: a take plan over the script's parts, priced, then made under the click's approval (the session only
    /// asks for a voice it may pay for).
    private func wholeClipVoice(_ script: WholeClipScript, progress: @escaping @MainActor (String) -> Void) async throws -> WholeClipRevoiceSession.Voice {
        typealias Session = WholeClipRevoiceSession
        // The lip sync needs a fal.ai key: without one, no voice is paid for that could never be lip synced.
        guard await editor.app.providerKeyStore.hasKey(for: "fal") else {
            throw Session.Unsent(error: Session.LipsyncFailed(error: LipsyncError.missingKey, local: true))
        }
        await ensureVideoVoice()
        // The patch's own plan was only priced: it lets go of its quotes, so the voice's record has no run in flight.
        if let patch = takePlan, !hasPaidTakes {
            await patch.stop(); patch.invalidate(); takePlan = nil
        }
        // What stops the Voice step says what it is: a project that can't be edited now, an edit of the scope since the
        // Rewrite (a paid voice is kept for Undo), no voice chosen (a paid voice is kept for choosing it again), or a Voice
        // Lab that can't make takes here. Each waits for its cause to change before Try Again is offered.
        if let stop = wholeClipVoiceReadiness() {
            switch stop {
            case .rewriteChanged, .voiceMissing:
                if let kept = wholeClipPlan, kept.spent.units > 0 { throw wholeClipInputsChanged(kept) }
            default: break
            }
            throw stop
        }
        guard let generation, let recordID = generation.selectedVoiceID, let takeBackend, let envelope else { throw Session.Stop.unavailable }
        if let kept = wholeClipPlan, wholeClipPlanScript == script {
            try checkWholeClipPlan(kept)
            // Parts paid while an edit made the plan stale are its own again after the Undo: never voiced twice.
            kept.acceptTakesMadeBeforeEdit()
            try checkWholeClipWordFailures(kept, recordID: recordID)
            if let blocked = kept.phrases.first(where: { $0.blocked != nil }) {
                throw Session.Unsent(error: Session.Stop.noVoice((blocked.blocked ?? "The voice is blocked.") + " Nothing new was sent."))
            }
            if !kept.unfinishedVoiceParts.isEmpty {
                let approvedPrice = kept.unfinishedVoicePrice ?? wholeClip?.quote?.voicePassUSD
                await kept.prepareUnfinishedVoiceParts()
                try Task.checkCancellation()
                guard let approval = kept.approvalID, let approvedPrice, let freshPrice = kept.estimate?.usd else {
                    throw Session.Stop.noVoice(kept.problem.isEmpty ? "The remaining voice parts couldn't be priced. Nothing new was sent." : kept.problem)
                }
                guard freshPrice <= approvedPrice else {
                    throw Session.Stop.noVoice("The price for the remaining parts changed. Nothing new was sent. Review the new price before retrying.")
                }
                progress("retrying \(kept.unfinishedVoiceParts.count) unfinished parts")
                await kept.start(approved: true, quoteID: approval)
                try Task.checkCancellation()
            }
            return try finishWholeClipVoice(kept, script: script, recordID: recordID)
        }
        // The plan: free, and the same every time for the same clip, so a stop here is one Try Again would only repeat.
        // It is current while the clip's identity is the one captured now and the voice is the one it is made with.
        let inputsCurrent = wholeClipInputsCurrency()
        weak var created: ClipTakePlan?
        let model = VoiceLabWordingFit.modelID
        // A voice paid before a relaunch (`WholeClipRevoiceSession.restore`) is put back only with the voice and model it
        // was made with, at no more than the price its Try Again showed: the journal's takes are adopted and only their
        // word checks are paid. Another voice, or a higher price, sends nothing.
        let restored = wholeClip?.restoredVoiceKey.flatMap { $0.script == script.text ? $0 : nil }
        if let restored, restored.recordId != recordID || restored.model != model {
            throw Session.Stop.voiceInputsChanged(clip: wholeClipClipNumber, usd: wholeClip?.restoredVoices[restored] ?? 0, voiceSwitched: true)
        }
        // The price Try Again showed for the voice (`retryUSD`'s voice part): the backstop below holds the fresh plan to it.
        let restoredApproval = restored == nil ? nil : wholeClip?.restoredRetryVoiceUSD
        let plan: ClipTakePlan
        do {
            let final = try wholeClipReviewProject()
            let hunks = wholeClipHunks(script, project: final)
            let phraseInput = try takeInputMaker(final: final, recordID: recordID, modelID: model, envelope: envelope,
                checksGeneratedSpeaker: false, model: { created?.modelID ?? model })
            // One timeline: each part's take is laid out on the clip as edited, as generated (provider pace 1.0, never
            // stretched): a shorter take first speeds the picture up evenly to at most 1.2×, then its sentence-end pauses
            // grow within the project's pause threshold, then the picture's end is trimmed (ADR-R46, "Your own pace").
            guard let edited = wholeClipEditedPlan(final) else { throw VoiceLabProjectError.invalidSegment }
            let bound = final.edits.pauseThresholdSeconds
            let makeInput: @MainActor (ClipTakePlan.Phrase) async throws -> VoiceLabTakeInput = { phrase in
                var input = try await phraseInput(phrase).replacingPace(nil)
                input.editedLayout = VoiceLabEditedLayout(cuts: WholeClipRevoice.editedCuts(edited, startSample: phrase.window.startSample,
                                                                                             endSample: phrase.window.endSample), pauseBoundSeconds: bound,
                                                          maximumPictureSpeed: WholeClipRevoice.maximumPictureSpeed)
                return input
            }
            plan = try ClipTakePlan(project: final, scope: scope, envelope: envelope, hunks: hunks, makeInput: makeInput,
                readCap: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.currentGenerationCap()
                }, isCurrent: { [weak self] in
                    guard let self else { return false }
                    return inputsCurrent() && self.generation?.selectedVoiceID == recordID
                }, acceptedChargesChanged: { [weak app = editor.app] in await app?.refreshMonthlySpend() }, wordCheckFailures: wordCheckFailures)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Session.Unsent(error: error)
        }
        created = plan
        _ = plan.changeModel(model)
        plan.prepareDurationRender = durationRenderPreparer()
        #if DEBUG
        plan.publishOverride = publishOverride
        #endif
        configureLipsync(plan)
        plan.lipsync.automaticallyRefreshOffers = false
        // The parts' measured takes calibrate the speaking-rate estimate as the patch's do.
        plan.onMeasuredTakesChanged = { [weak self, weak plan] in
            guard let self, let plan else { return }
            observeWholeClipMeasuredTakes(plan)
        }
        plan.connect(takeBackend(plan.phrases.count) { [weak plan] request, start in
            guard let plan else { throw CancellationError() }
            try await plan.dispatch(request, start: start)
        })
        retireWholeClipVoicePlan()
        wholeClipPlan = plan
        wholeClipPlanScript = script
        wholeClipPlanSettled = false
        progress("pricing \(plan.phrases.count == 1 ? "one part" : "\(plan.phrases.count) parts")")
        await plan.prepare()
        #if DEBUG
        editor.wholeClipPrepared?(plan)
        #endif
        try Task.checkCancellation()
        try checkWholeClipWordFailures(plan, recordID: recordID)
        if let blocked = plan.phrases.first(where: { $0.blocked != nil }) {
            throw Session.Unsent(error: Session.Stop.noVoice((blocked.blocked ?? "") + " Nothing was sent."))
        }
        guard plan.problem.isEmpty, let approval = plan.approvalID else {
            throw Session.Stop.noVoice(plan.problem.isEmpty ? "The voice couldn't be priced. Nothing was sent." : plan.problem)
        }
        if restored != nil { try holdRestoredVoicePrice(plan, approved: restoredApproval) }
        progress("\(plan.phrases.count == 1 ? "one take" : "\(plan.phrases.count) parts, one take")")
        await plan.start(approved: true, quoteID: approval)
        return try finishWholeClipVoice(plan, script: script, recordID: recordID)
    }

    private func finishWholeClipVoice(_ plan: ClipTakePlan, script: WholeClipScript, recordID: String) throws -> WholeClipRevoiceSession.Voice {
        // Paid parts made while the clip changed are kept, never wrapped as "nothing was sent" (Undo makes them current).
        try checkWholeClipPlan(plan)
        plan.acceptTakesMadeBeforeEdit()
        try checkWholeClipWordFailures(plan, recordID: recordID)
        let edited = (try? wholeClipReviewProject()).flatMap(wholeClipEditedPlan)
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        // The voice as said: each take's speech between its trims, before any pause of the layout.
        var seconds = 0.0
        var overrun: Double?
        for phrase in plan.phrases {
            guard let take = plan.automaticTake(phrase: phrase.id), let audio = take.row.audio, plan.select(take: take.id, phrase: phrase.id) else {
                let row = phrase.takes.last?.row
                let reason = phrase.blocked ?? row.flatMap(TakeFailurePresentation.reason(for:))
                    ?? (plan.problem.isEmpty ? "No verified take was available." : plan.problem)
                let kept = plan.phrases.count - plan.unfinishedVoiceParts.count
                let saved = kept > 0 ? " \(kept) verified \(kept == 1 ? "part is" : "parts are") kept for retry." : ""
                let failure = WholeClipRevoiceSession.Stop.partVoice(part: phrase.id + 1, reason: reason + saved,
                                                                    checks: row?.qa?.failures ?? [])
                if phrase.blocked != nil { throw WholeClipRevoiceSession.Unsent(error: failure) }
                throw failure
            }
            seconds += Double(audio.fit.plan.trimEndFrame - audio.fit.plan.trimStartFrame) / Double(audio.sampleRate)
            // A part whose laid-out take runs past its own window, with no picture to carry it (wholeclip-fit-raw-aggregate):
            // the Fit asks for a shorter wording over it rather than matching the total and failing the picture later.
            if wholeClipPictureChoice(plan, phrase: phrase.id) == nil, let edited,
               let output = plan.videoAvailability(phrase: phrase.id).options?.outputSamples {
                let cuts = WholeClipRevoice.editedCuts(edited, startSample: phrase.window.startSample, endSample: phrase.window.endSample)
                let window = WholeClipRevoice.editedSeconds(cuts, startSample: phrase.window.startSample, endSample: phrase.window.endSample,
                                                            sampleRate: edited.sampleRate)
                let laid = Double(output) / rate
                if window > 0, laid > window { overrun = max(overrun ?? 0, laid / window) }
            }
        }
        wholeClipPlanSettled = true
        return .init(key: .init(script: script.text, recordId: recordID, model: plan.modelID ?? VoiceLabWordingFit.modelID), seconds: seconds,
                     parts: plan.phrases.count, usd: plan.spent.usd ?? 0, overrun: overrun)
    }

    private func checkWholeClipWordFailures(_ plan: ClipTakePlan, recordID: String) throws {
        let unfinished = plan.unfinishedVoiceParts
        if let part = unfinished.first(where: { plan.stoppedForRepeatedWords(phrase: $0) }) {
            throw WholeClipRevoiceSession.Stop.repeatedWordCheck(part: part + 1, kept: plan.phrases.count - unfinished.count,
                                                               recordID: recordID)
        }
    }

    /// The whole clip's measured takes calibrate the speaking-rate estimate as the patch's do (`observeMeasuredTakes`): each
    /// cloned-voice take is one sample of its measured length against the same estimate, so the next check before paying
    /// reads them. The samples are VoxClip's own writes, which no take or voice treats as an edit.
    private func observeWholeClipMeasuredTakes(_ plan: ClipTakePlan) {
        guard wholeClipPlan === plan, !plan.generating, !plan.preparing,
              let rate = try? VoiceLabPhraseTiming.speakingRate(transcript: RewriteReview.timingTranscript(reviewInputs)) else { return }
        try? recordMeasuredTakes(plan, rate: rate)
    }

    /// Each cloned-voice take of `plan` is one speaking-rate sample (R43): its measured length against the estimate of its
    /// words at the speaker's `rate`, with its audio tags' allowance. The one calibration loop for every plan's measured
    /// takes, the patch's (`observeMeasuredTakes`) and the whole clip's, so both read and write the same samples.
    func recordMeasuredTakes(_ plan: ClipTakePlan, rate: Double) throws {
        for phrase in plan.phrases {
            for take in phrase.takes {
                guard take.source == .clonedVoice, let audio = take.row.audio, let input = plan.measuredInput(take: take.id) else { continue }
                let estimate = try VoiceLabPhraseTiming.estimate(text: input.text, rate: rate)
                    + VoiceLabAudioTags.allowance(input.audioTags, text: input.text, modelID: input.modelID)
                recordSpeakingRate(model: input.modelID, recordID: input.recordID, take: take.id,
                    measured: Double(audio.trimmed.count) / Double(audio.sampleRate) * (input.pace ?? 1), baseline: estimate)
            }
        }
    }

    /// The Fit step's measured-wording round: Rewrite's own send with its measured feedback (voice-lab §8.2.2), for the
    /// whole clip as one line (the voice's measured length against the clip as edited), then the reply's changes as the
    /// script. It only ever asks for fewer words: a shorter voice is laid out, never padded (ADR-R46).
    private func wholeClipReword(_ script: WholeClipScript, target: Int, voiceSeconds: Double,
                                 videoSeconds: Double) async throws -> WholeClipScript? {
        guard let connector, let shared = editor.app.shared else { return nil }
        struct Measured: Decodable { let shorterMeasuredFeedbackBlock: String; let shorterMeasuredPhraseLine: String }
        let template = try JSONDecoder().decode(Measured.self, from: Data(contentsOf: shared.root.appendingPathComponent("prompts/voice-rewrite-shorter-measured.json")))
        let final = try wholeClipReviewProject()
        let original = wholeClipWords(final).filter { $0.kind == .word }.map(\.text).joined(separator: " ")
        let values = ["original": original, "proposed": script.text, "measuredSeconds": toFixed1(voiceSeconds), "slotSeconds": toFixed1(videoSeconds)]
        let line = template.shorterMeasuredPhraseLine.replacing(#/\{(original|proposed|measuredSeconds|slotSeconds)\}/#) { values[String($0.1)] ?? "" }
        var block = template.shorterMeasuredFeedbackBlock.replacingOccurrences(of: "{phrases}", with: line)
        block += "\nAim at about \(target) words for the whole clip."
        let prepared = try await prepareSend(connector, feedback: block)
        guard await confirmSend(), current else { return nil }
        guard let (checked, _) = try await reply(prepared, connector: connector, accept: { [weak self] in self?.current == true }) else { return nil }
        let hunks = checked.changes.map(\.hunk).filter { $0.kind == .voice }
        let cuts = Set(final.edits.cutWordIds).union(checked.changes.map(\.hunk).filter { $0.kind == .cut }.flatMap(\.sourceWordIds))
        return WholeClipScript.assemble(words: wholeClipWords(final), cutWordIds: cuts, voiceHunks: hunks)
    }

    /// A part's picture under its laid-out take: the source when the take fills its window exactly, else the clip's own
    /// cuts (sped up evenly when the take is shorter), else a retime within the fit tolerance and the picture's speed cap.
    /// Nil when none can carry it.
    private func wholeClipPictureChoice(_ plan: ClipTakePlan, phrase: Int) -> VoiceLabVideoMode? {
        let availability = plan.videoAvailability(phrase: phrase)
        if availability.allows(.source) { return .source }
        if availability.allows(.cut) { return .cut }
        if availability.allows(.retimed), let factor = availability.options?.retimeFactor,
           factor >= 1 - WholeClipRevoice.fitTolerance - 1e-9, factor <= WholeClipRevoice.maximumPictureSpeed + 1e-9 { return .retimed }
        return nil
    }

    /// Every part's picture is the clip as edited under its laid-out take, through Rewrite's own duration path
    /// (`wholeClipPictureChoice`), and the trim after the voice's last pause. A paid lip sync already applied stays: a part
    /// whose choice is already the one it needs is never chosen again, so nothing paid is taken off. Each match starts
    /// clean otherwise: an earlier attempt's failed preparation is forgotten, so a retry prepares the picture again instead
    /// of meeting the old problem at once (MVP45). A failure throws what actually failed.
    func wholeClipMatchPicture() async throws -> ClipTakePlan {
        typealias Session = WholeClipRevoiceSession
        guard let plan = wholeClipPlan else { throw ClipTakePlan.Failure.stale }
        try checkWholeClipPlan(plan)
        plan.retryVideoPreparation()
        if let left = plan.phrases.first(where: \.leftOut) { throw Session.Stop.pictureUnmatched(part: left.id + 1) }
        for phrase in plan.phrases {
            guard let choice = wholeClipPictureChoice(plan, phrase: phrase.id),
                  phrase.videoChoice == choice || plan.chooseVideo(choice, phrase: phrase.id) else {
                throw Session.Stop.pictureUnmatched(part: phrase.id + 1)
            }
        }
        await plan.prepareVideoChoices()
        try Task.checkCancellation()
        guard wholeClipPlan === plan else { throw ClipTakePlan.Failure.stale }
        try checkWholeClipPlan(plan)
        if let left = plan.phrases.first(where: \.leftOut) { throw Session.Stop.pictureUnmatched(part: left.id + 1) }
        if let error = plan.videoPreparationFailure { throw Session.Unmatched(error: error) }
        return plan
    }

    /// The Fit step's picture check (ADR-R46): the picture matched to every laid-out take, then the lip sync's own free checks
    /// on this Mac (the source can be prepared for upload, a fal.ai key is there, the merged window is one job fal.ai takes,
    /// and it can be priced). Returns the picture's even speed-up and its output length, which the lip sync is priced on.
    private func wholeClipPicture(_ voice: WholeClipRevoiceSession.Voice) async throws -> WholeClipRevoiceSession.Picture {
        typealias Session = WholeClipRevoiceSession
        let plan = try await wholeClipMatchPicture()
        do {
            guard let video = project.media.source.video else { throw LipsyncPreparationError.unsupportedVideo }
            _ = try LipsyncWindowPreparation.uploadSize(video)
        } catch { throw Session.LipsyncFailed(error: error, local: true) }
        // A lip sync already on every part is the offer's answer: the window was checked when it was paid for.
        if !plan.phrases.allSatisfy({ plan.lipsync.applied[$0.id] != nil }) {
            do {
                _ = try await plan.makeWholeClipLipsyncOffer(model: .standard)
            } catch let error as LipsyncError {
                throw Session.LipsyncFailed(error: error, local: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch { throw Session.Unmatched(error: error) }
        }
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        var kept = 0.0, shown = 0.0
        for phrase in plan.phrases {
            guard let row = phrase.selected?.row else { throw Session.Stop.pictureUnmatched(part: phrase.id + 1) }
            let options = VoiceLabVideoDurationOptions(row: row, sourceSampleRate: Int(rate))
            let output = Double(options.outputSamples ?? 0)
            let speed: Double = switch phrase.videoChoice {
            case .cut: options.cutRetimeFactor ?? 1
            case .retimed: options.retimeFactor ?? 1
            default: 1
            }
            kept += output * speed; shown += output
        }
        let speed: Double = shown > 0 ? kept / shown : 1
        return .init(speed: speed, outputSeconds: shown / rate, laidOut: speed >= WholeClipRevoice.maximumPictureSpeed - 1e-3)
    }

    /// The Lip sync step: every part's picture matched to its take, then one lip sync over the merged window. A lip sync of
    /// this model already on the parts is the result, with nothing sent. Another model's (the sync-3 upgrade over lipsync-2)
    /// is set aside while it runs and put back if the new one fails or is cancelled, so the paid one is never lost.
    private func wholeClipLipsync(_ voice: WholeClipRevoiceSession.Voice, factor: Double, model: WholeClipRevoice.Lipsync,
                                  progress: @escaping @MainActor (Double?) -> Void) async throws -> WholeClipRevoiceSession.Synced {
        typealias Session = WholeClipRevoiceSession
        let plan = try await wholeClipMatchPicture()
        let previous = plan.lipsync.applied
        if !previous.isEmpty, plan.phrases.allSatisfy({ previous[$0.id] != nil }), let first = previous[plan.phrases[0].id],
           first.result.provenance.model == model.rawValue {
            return .init(model: model, usd: first.result.provenance.estimate.usd ?? 0, factor: factor,
                         requestID: first.result.provenance.requestID, recovered: false)
        }
        for phrase in previous.keys { plan.lipsync.undo(phrase) }
        func putBack(_ offer: RewriteLipsyncSession.Offer?) {
            guard !previous.isEmpty, previous.keys.allSatisfy({ plan.lipsync.applied[$0] == nil }) else { return }
            _ = plan.lipsync.restore(previous, matching: offer)
        }
        let offer: RewriteLipsyncSession.Offer
        do {
            var prepared = try await plan.makeWholeClipLipsyncOffer(model: model)
            // A kept result (Try Again · free) or one already paid for is put back for free; nothing new is paid.
            if wholeClip?.lipsyncKept == true || wholeClip?.lipsyncMayPay == false { prepared.mayPay = false }
            offer = prepared
            // Only the user's "I Checked fal.ai" click starts past a lost submit answer (it may charge twice).
            if wholeClip?.checkedFal == true { try plan.lipsync.startAfterCheckingFal(offer) } else { try plan.lipsync.startChecked(offer) }
        } catch let error as LipsyncError {
            putBack(nil)
            throw Session.LipsyncFailed(error: error, local: true)
        } catch {
            putBack(nil)
            throw error
        }
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
        // What the job came to is read before the cancel: a result fal.ai finished and billed is kept for a free Try Again
        // (C's set-aside), and its charge is counted, even when Cancel landed meanwhile.
        for phrase in offer.phraseIDs where plan.lipsync.applied[phrase] == nil {
            putBack(offer)
            // The job's own error, with its real case for the log, whether it failed on this Mac before fal.ai, what fal.ai
            // charged for it and whether its result is kept for a free Try Again.
            if case .failed(_, _, let mayBill) = plan.lipsync.states[phrase] {
                let error = plan.lipsync.errors[phrase] ?? LipsyncError.invalidResponse
                let attempt = (error as? LipsyncAttemptFailure)?.attempt
                throw Session.LipsyncFailed(error: error, local: RewriteLipsyncSession.isLocal(error),
                    usd: mayBill ? attempt?.estimate.usd : nil, requestID: attempt?.requestID,
                    freeRetry: plan.lipsync.freeRetries.contains(phrase))
            }
            throw CancellationError()
        }
        let result = offer.phraseIDs.first.flatMap { plan.lipsync.applied[$0]?.result }
        // The record's retime is the picture's even speed-up from the Fit step (1 at the clip's own pace). A re-imported
        // kept result costs what its billed attempt was quoted.
        return .init(model: model, usd: result?.provenance.estimate.usd ?? offer.estimate.usd ?? 0, factor: factor,
                     requestID: result?.provenance.requestID, recovered: result?.recovered ?? false)
    }

    /// Puts the whole clip's kept lip sync back on its parts when a step took it off, for free (nothing is sent): true when
    /// the parts hold it now. Nothing to put back (no lip sync was applied) is true.
    private func restoreWholeClipLipsync(_ entries: [Int: RewriteLipsyncSession.Applied]) async -> Bool {
        guard !entries.isEmpty else { return true }
        guard let plan = wholeClipPlan else { return false }
        if entries.allSatisfy({ plan.lipsync.applied[$0.key]?.result.asset.id == $0.value.result.asset.id }) { return true }
        guard entries.keys.allSatisfy({ plan.lipsync.applied[$0] == nil }) else { return false }
        let model = entries.values.first.flatMap { WholeClipRevoice.Lipsync(rawValue: $0.result.provenance.model) } ?? .standard
        guard let offer = try? await plan.makeWholeClipLipsyncOffer(model: model) else { return false }
        return plan.lipsync.restore(entries, matching: offer)
    }

    /// The anchor the baseline belongs to, named as Settings › Voices names it ("siim"), never the video's own voice.
    var wholeClipAnchorName: String {
        editor.app.voiceLabSession.anchorVoice(language: nil).map { VoiceLabSession.rebuildName($0.voiceName) } ?? "your voice"
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
    /// as one undo step. A lip sync that was paid for and applied must be in it, or nothing goes in.
    private func useWholeClip(voice: WholeClipRevoiceSession.Voice, synced: WholeClipRevoiceSession.Synced,
                              match: WholeClipRevoiceRecord.Match?) async throws -> WholeClipRevoiceRecord {
        guard let plan = wholeClipPlan, let clip = wholeClipID else { throw ClipTakePlan.Failure.stale }
        try checkWholeClipPlan(plan)
        let made = try await plan.acceptance()
        if wholeClip?.syncedEntries.isEmpty == false, made.videoAssets.isEmpty { throw WholeClipRevoiceSession.Stop.lipsyncMissing }
        let usd = NSDecimalNumber(decimal: wholeClip?.spent ?? 0).doubleValue
        let record = WholeClipRevoiceRecord(id: "wholeclip-" + UUID().uuidString.lowercased().prefix(13), clipId: clip,
            segmentIds: made.segments.map(\.id), script: voice.key.script, consentRecordId: made.voice?.consentRecordId ?? voice.key.recordId,
            videoRetime: synced.factor, lipsyncModel: synced.model.rawValue, usd: usd, match: match,
            createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        // Rewrite's own commit: the card shows it used (no R3), and ⌘Z puts the card back on Review (`commitOwnEdit`).
        try commitOwnEdit {
            try editor.applyVoiceLab(made.segments, assets: made.assets, voice: made.voice, scope: rewriteScope,
                                     localCommands: localCommands, videoAssets: made.videoAssets, wholeClip: record, replacing: wholeClipReplacement)
        }
        editor.announce("Whole clip revoiced. Undo takes it back.")
        return record
    }

    /// Use the Voice Without Lip Sync: the paid parts go in as ordinary Voice Lab segments over the picture matched to
    /// them (source, cut or VoxClip's own retime), one undo step, and no whole-clip record, so the project format is
    /// unchanged. Free: the picture match is local, and a lip sync on some parts is taken off (it stays in the plan).
    private func putInWholeClipVoiceOnly(_ voice: WholeClipRevoiceSession.Voice) async throws {
        let plan = try await wholeClipMatchPicture()
        guard wholeClipPlanScript?.text == voice.key.script else { throw wholeClipInputsChanged(plan) }
        for phrase in Array(plan.lipsync.applied.keys) { plan.lipsync.undo(phrase) }
        let made = try await plan.acceptance()
        try commitOwnEdit {
            try editor.applyVoiceLab(made.segments, assets: made.assets, voice: made.voice, scope: rewriteScope,
                                     localCommands: localCommands, videoAssets: made.videoAssets, replacing: wholeClipReplacement)
        }
        editor.announce("Whole-clip voice put in without lip sync. Undo takes it back.")
    }
}

extension EditorModel {
    /// Takes a used whole-clip revoice back out as one undo step: its segments off and its record removed. The clip's pick
    /// is cleared, so its card offers the whole clip again as the default.
    func removeWholeClip(_ record: WholeClipRevoiceRecord) {
        wholeClipPicks[record.clipId] = nil
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
