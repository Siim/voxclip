import Foundation
import VoxClipCore

/// Closing with paid work (design.md R2, "Closing Rewrite"): Close Rewrite, Esc, the panel's X, a tab's close, Rewrite on
/// another scope or with another AI, closing or replacing the project and Quit never drop unused or running paid takes, a
/// whole-clip voice or a lip sync unasked. They ask inline, in place of the Rewrite job's footer and never in an alert:
/// "Close Rewrite and discard 3 paid takes (≈ $0.12)?" with Keep Working, the primary that Return and Esc choose, and
/// Discard and Close (Discard and Rewrite, Discard and Quit). Claude mode never answers it: the Make-it driver stops with
/// "needs you" on any question it may not press (`MakeItRewriteDriver.step`).
extension RewriteSession {
    /// What the close is for, which names the question and its Discard button.
    enum CloseReason: Equatable {
        /// Close Rewrite, Esc, the panel's X, a tab's close, a change of the video or its transcript under the session.
        case close
        /// Rewrite on another scope, or again with another AI: a new Rewrite replaces this one.
        case newRewrite
        /// Close Project, opening or importing another project in its place.
        case closeProject
        /// Quit VoxClip.
        case quit
    }

    /// Unused or running paid work, which closing asks about and Claude mode never closes over: `hasPaidWork`, less a used
    /// whole clip's lip sync, which its plan still lists as applied after Use put it in the project.
    var hasUnusedPaidWork: Bool {
        guard hasPaidWork else { return false }
        guard !hasPaidPatchWork, wholeClip?.phase == .used else { return true }
        return wholeClipPlan?.lipsync.running == true
    }

    /// Closing asks first (`EditorModel.closeRewrite`): the session is open and holds unused or running paid work. A
    /// session already closed asks nothing, whatever its whole clip still holds in memory.
    var asksBeforeClosing: Bool { isOpen && hasUnusedPaidWork }

    /// Lets go of the whole clip's unused paid work once the user chose to discard it (Rewrite Again's Discard): its run
    /// stops, its plan goes with its takes and lip sync, and the next proposal offers the choice again. A used whole clip
    /// is in the project and stays.
    func discardWholeClipWork() {
        guard let whole = wholeClip, whole.phase != .used else { return }
        whole.cancel()
        wholeClipPlan?.invalidate(); wholeClipPlan = nil
        wholeClipPlanScript = nil; wholeClipPlanSettled = false
        retiredWholeClipVoiceSpend = 0
        wholeClip = nil
    }

    /// Paid work another voice would make stale, so the video's voice is not switched under it (`ensureVideoVoice`): the
    /// patch's paid takes and lip syncs, a whole-clip voice being made, and a whole clip's paid voice or lip sync that is not
    /// used or let go. A whole clip running with nothing paid yet is not: its own run chooses the video's voice first.
    var holdsPaidVoice: Bool {
        guard hasUnusedPaidWork else { return false }
        if hasPaidPatchWork || wholeClipPlan?.generating == true || wholeClipPlan?.lipsync.hasPaidWork == true { return true }
        return (wholeClip?.spent ?? 0) > 0
    }

    /// The question can be shown: the session's own tab can come forward (Full Take, or a clip still in the project). A
    /// session whose clip was removed shows on no tab, so the project's close and Quit, which nothing else could answer,
    /// don't wait on it.
    var canAskAboutPaidWork: Bool {
        guard let id = project.edits.activeClipId else { return true }
        return editor.project.edits.clips.contains { $0.id == id }
    }

    /// What Discard lets go of, USD, as the question names it: the patch's paid takes and its lip syncs, and the whole
    /// clip's paid voice and lip sync (its ledger and fal.ai's charges for failed attempts). A used whole clip is in the
    /// project, so it counts nothing.
    var paidWorkUSD: Decimal {
        var usd = Decimal(0)
        if hasPaidPatchWork, let plan = takePlan, !plan.isRetired {
            usd += plan.spent.usd ?? 0
            for applied in plan.lipsync.applied.values where !applied.result.recovered {
                usd += applied.result.provenance.estimate.usd ?? 0
            }
        }
        if let whole = wholeClip, whole.phase != .used { usd += whole.spent }
        return usd
    }

    /// The paid work closing would drop, for the question: "3 paid takes (≈ $0.12)", "the paid whole-clip voice and lip
    /// sync (≈ $1.61)", "1 paid take and a lip sync still running (≈ $0.04)", "the takes being made".
    var paidWorkSummary: String {
        var parts: [String] = []
        if hasPaidPatchWork {
            let takes = paidTakeCount
            if takes == 1 { parts.append("1 paid take") }
            else if takes > 1 { parts.append("\(takes) paid takes") }
            else if takePlan?.generating == true { parts.append("the takes being made") }
            let synced = takePlan?.lipsync.applied.count ?? 0
            if synced == 1 { parts.append("1 lip sync") } else if synced > 1 { parts.append("\(synced) lip syncs") }
            if takePlan?.lipsync.running == true { parts.append("a lip sync still running") }
        }
        if let whole = wholeClip, whole.phase != .used, whole.running || whole.spent > 0 || wholeClipPlan?.lipsync.hasPaidWork == true {
            if whole.running { parts.append(whole.spent > 0 ? "the paid whole-clip voice, still being made" : "the whole-clip voice being made") }
            else if whole.synced != nil || wholeClipPlan?.lipsync.applied.isEmpty == false { parts.append("the paid whole-clip voice and lip sync") }
            else { parts.append("the paid whole-clip voice") }
        }
        if parts.isEmpty { parts.append("the paid work") }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        let usd = paidWorkUSD
        return list + (usd > 0 ? " (" + VoiceLabCostPresentation.format(usd) + ")" : "")
    }

    /// The question for `reason`: "Close Rewrite and discard 3 paid takes (≈ $0.12)?".
    func discardPaidWorkQuestion(_ reason: CloseReason) -> String {
        let summary = paidWorkSummary
        switch reason {
        case .close: return "Close Rewrite and discard \(summary)?"
        case .newRewrite: return "Start a new Rewrite and discard \(summary)?"
        case .closeProject: return "Close the project and discard \(summary)?"
        case .quit: return "Quit VoxClip and discard \(summary)?"
        }
    }

    /// Asks before the paid work goes, inline in the Rewrite job's footer (impl-plan §13.1): `discardPaidWorkQuestion` with
    /// Keep Working, the default for Return and Esc, which changes nothing, and Discard and Close (Rewrite, Quit), which
    /// runs `perform`. The job comes forward to ask, on its own tab when another one shows, and VoiceOver hears the question.
    func confirmDiscardPaidWork(_ reason: CloseReason, perform: @escaping @MainActor () -> Void) {
        let question = discardPaidWorkQuestion(reason)
        let title = switch reason {
        case .close, .closeProject: "Discard and Close"
        case .newRewrite: "Discard and Rewrite"
        case .quit: "Discard and Quit"
        }
        task.ask(PanelConfirm(question: question,
            cancel: PanelAction(id: "keepWorking", title: "Keep Working") { [weak self] in self?.task.dismissConfirm() },
            confirm: PanelAction(id: "discardPaidWork", title: title) { [weak self] in
                guard let self, isOpen, task.confirm?.confirm.id == "discardPaidWork" else { return }
                task.dismissConfirm()
                perform()
            }))
        bringQuestionForward()
        editor.announce(question)
    }

    /// The question shows where the user can answer it: the viewer comes back, and a session whose tab is not the one
    /// showing (its tab was closed, or another is active) gets its tab again. On the next turn, so a close asked from inside
    /// a tab change or a refresh never re-enters it.
    private func bringQuestionForward() {
        let editor = self.editor
        if editor.app.shell.editor === editor, !editor.app.shell.viewerShown { editor.app.shell.toggleViewer() }
        Task { @MainActor [weak self, weak editor] in
            guard let self, let editor, isOpen, task.confirm?.confirm.id == "discardPaidWork", editor.openRewrite === self else { return }
            if editor.rewrite !== self { _ = editor.setScope(project.edits.activeClipId) }
            editor.onShowPanelJob?(task.job)
        }
    }
}
