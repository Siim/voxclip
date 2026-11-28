import SwiftUI
import Observation
import AVFoundation
import VoxClipCore
import VoxClipMedia

struct EditorRenderSnapshot {
    let project: Project
    let state: EditState?
    let plan: EditPlan?
    var reduceMotion: Bool = false
}

@MainActor @Observable public final class EditorModel {
    let document: VoxClipDocument
    let app: AppModel
    var showFindClips = false
    var findClipsAnchor = FindClipsAnchor.clipBar
    /// The sidebar's "Choose how VoxClip finds clips…" callout (no connector chosen).
    var showAISetup = false
    /// Each clip's answer to "How should it sound?" this session, with the Rewrite proposal it was given for: a new proposal
    /// for the clip, in the same Rewrite or a later one, starts from the default again (the whole clip).
    var wholeClipPicks: [String: WholeClipPick] = [:]
    #if DEBUG
    /// The Rewrite smoke's stand-in for fal.ai in a whole-clip revoice (DebugRewriteSmokeWholeClip.swift).
    @ObservationIgnored var wholeClipSmoke: (@MainActor (RewriteSession, WholeClipRevoiceSession) -> Void)?
    /// Told when a whole-clip voice plan is priced, so the smoke's scripted voice knows its windows.
    @ObservationIgnored var wholeClipPrepared: (@MainActor (ClipTakePlan) -> Void)?
    /// The Rewrite smoke's lip sync: the real run over a stood-in fal.ai (`LipsyncSmokeFalHTTP`), for every take plan.
    @ObservationIgnored var lipsyncSmoke: (@MainActor (RenderRequest, LipsyncRenderWindow, String, WholeClipRevoice.Lipsync, Bool, String?,
                                                       @escaping @MainActor @Sendable (LipsyncQuote) -> Void,
                                                       @escaping @Sendable (Double?) async -> Void) async throws -> ImportedLipsyncResult)?
    #endif
    var selectedWordIDs: Set<String> = [] {
        didSet {
            guard selectedWordIDs != oldValue else { return }
            // Any other selection replaces the timeline's exact range (issue #41).
            if !settingTimelineRange { timelineRange = nil }
            if !selectedWordIDs.isEmpty { selectTimelineItems([]) }
            rewriteOpenTask?.cancel()
            // Changing the selection ends an open inline correction, as a click elsewhere ends an inline rename.
            if correctionID != nil { endCorrection() }
            updateSelectionEnds(); refreshPendingSendScope()
        }
    }
    var selectedPauseIDs: Set<String> = [] {
        didSet {
            guard selectedPauseIDs != oldValue else { return }
            if !settingTimelineRange { timelineRange = nil }
            if !selectedPauseIDs.isEmpty { selectTimelineItems([]) }
            rewriteOpenTask?.cancel(); updateSelectionEnds(); refreshPendingSendScope()
        }
    }
    /// Where Play range, P or an Ask Claude row's ▶ stops, on the output (Edited) clock: the take time after a story
    /// part can play before an earlier one, so Out is where its end plays (`mapEndTime`). Space and every seek end it.
    var previewStop: Double? { didSet { previewStopArmed = false } }
    /// Whether playback has reported a time before `previewStop`: only then does reaching it stop, so a time
    /// queued from before the seek can't end the range at once.
    @ObservationIgnored var previewStopArmed = false
    var storyPartPlaybackEnd: Double?
    var selectedStoryPartID: String?
    var draggedStoryPartID: String?
    var storyPartError: String?
    var playhead: Double = 0
    var sourceTime: Double = 0
    var isPlaying = false
    var playbackRate: Float = 1
    /// Show cuts (ux/v2 notes.md §5 and §6), one switch for the transcript and the timeline. On,
    /// the transcript shows every removed word struck and every cut pause's length where a fold
    /// stands, and the timeline shows take time with the cuts as gaps (Source); off, each run of
    /// removals is one fold and the timeline shows the scope's output with every cut closed
    /// (Edited). Off by default. A view setting: no undo step and no document change (impl-plan §3.3).
    var showsCuts = false
    var showsSurroundingContext = false
    var focusesClip: Bool { scopeBounds != nil && !showsSurroundingContext }
    /// Show Pauses: the lengths of uncut pauses in the open clip. An opt-in, off by default.
    var showPauses = false
    /// The A1 track header's speaker (impl-plan V9, item 9): the preview plays without sound.
    /// A view setting: no undo step and no document change.
    var previewMuted = false { didSet { nativePreview?.player.isMuted = previewMuted } }
    /// The pages of the preview's caption layout, for the timeline's CC lane (impl-plan V9):
    /// empty until the first preview load; CC also reads them as empty while captions are off.
    var captionPages: [CaptionPage] = []
    var timelineZoomStep = 0
    var timelineEditor: TimelineEditorRoute?
    var timelineEffectsOpen: Bool {
        get { timelineEditor?.mode == .effects }
        set {
            if newValue { openTimelineEditor(.effects, effectID: timelineEffectID) }
            else if timelineEffectsOpen { resetTimelineEditor() }
        }
    }
    var timelineEffectID: String?
    private(set) var timelineEffectsRevision = 0
    var timelineSnapping = true
    var timelineItemSelection: Set<TimelineItemID> = []
    var timelineItemRefusal: String?
    /// The last frame or word-boundary step of the playhead (, / . on the timeline): where it
    /// started and where it asked to go, so a key repeat steps on before the seek lands.
    @ObservationIgnored var timelineStep: (axis: TimelineAxis, from: Double, to: Double)?
    /// The exact range a drag with Snapping off (or ⌥) leaves on the timeline, or I and O set
    /// there (issue #41), or nil. The words wholly inside it are selected underneath; any other
    /// word, pause or item selection replaces it. A selection, so no undo step.
    var timelineRange: TimelineRange? {
        didSet {
            guard timelineRange != oldValue else { return }
            // ✦ Ask Claude asks about a range of at least 0.1 s (design.md §6.8).
            askClaude.timeRange = timelineRangeSource.flatMap { $0.upperBound - $0.lowerBound >= 0.1 ? $0 : nil }
        }
    }
    @ObservationIgnored var settingTimelineRange = false
    /// The selection's first and last word or pause in reading order (a pause follows the
    /// word before it), one id when they are the same. A fold opens while one of them is in
    /// it (`openFoldEnds`), so what is selected always shows.
    private(set) var selectionEnds: [String] = []
    var findVisible = false
    var query = ""
    var textSize = DesignValues.transcriptTextSize
    var error: String?
    var projectSaveNotice: String?
    var previewError: String?
    var captionError: String?
    var progress: String?
    /// Transcription's completed fraction while `progress` shows a percentage.
    var progressFraction: Double?
    /// Transcription's stage while it runs, for the media chips (design §5.4.8).
    var progressStage: MediaTranscriptionStage?
    /// The running transcription as a media status (design §5.4.4 d), or nil.
    var transcriptionStatus: MediaStatus? {
        guard progress != nil, let progressStage else { return nil }
        return .transcribing(fraction: progressStage == .transcribing ? progressFraction : nil, stage: progressStage)
    }
    let sendConfirmation = ConnectorConfirmation()
    /// The clip style card and Claude's caption pick (design.md §6.6; EditorModel+ClipStyle.swift).
    let clipStyleState = ClipStyleState()
    /// ✦ Ask Claude's field, run and Adjust state (design.md §6.8).
    let askClaude = AskClaudeState()
    /// The Rewrite thread's input, request and fold for the focused change (design.md §6.3 "Talk back to Claude").
    let rewriteThread = RewriteThreadState()
    /// What answers the thread; nil asks the open Rewrite's AI (`liveRewriteThreadBackend`). Tests and the smoke stand it in.
    @ObservationIgnored var rewriteThreadBackend: RewriteThreadBackend?
    var connectorSendVerb = "Rewrite"
    @ObservationIgnored lazy var transcription = InlineTranscription(model: self)
    var contextDemoSession: ContextDemoSession?
    var motionCueEditing: MotionCueEditing?
    /// The Music section's suggestions, search and audition (EditorModel+Music.swift).
    let musicPanel = MusicPanel()
    /// ✦ Make it postable's runs, queue and scores (MakeItPostable.swift).
    let makeIt = MakeItController()
    /// "✦ Claude does it all" on a newly opened video: the automatic run, its card and Export all (ClaudeMode.swift).
    let claudeMode = ClaudeModeState()
    /// The next plan's note to Claude (a question's other answer), sent once.
    @ObservationIgnored var makeItNote: String?
    /// The window shows the Make it postable job, a panel job, or a clip's inline rename.
    @ObservationIgnored var onShowMakeIt: (() -> Void)?
    @ObservationIgnored var onShowPanelJob: ((PanelJob) -> Void)?
    @ObservationIgnored var onRenameClip: ((String) -> Void)?
    #if DEBUG
    /// The smoke and tests give Make it postable's Rewrite session their scripted voice and speaker check, and watch each
    /// step its driver takes.
    @ObservationIgnored var makeItGeneration: ((RewriteSession) async -> Void)?
    @ObservationIgnored var makeItStepObserver: ((String) async -> Void)?
    /// S-claude-does-it-all renders the smoke's synthetic (demo) recording through the real exporter; the Claude mode
    /// captures draw Export all as a real video shows it.
    @ObservationIgnored var smokeExportsDemo = false
    /// Tests read the copied post text here instead of the user's pasteboard.
    @ObservationIgnored var pasteboardOverride: ((String) -> Void)?
    #endif
    /// One undo step over several project changes (Make it postable's run): `replace` registers nothing while a group
    /// owns the edits, and the group registers one step back to where it began.
    @ObservationIgnored var undoGroup: EditorUndoGroup?
    var voiceChange: VoiceChangeSession?
    var correctionID: String?
    var correctionText = ""
    /// The open Rewrite session, on whichever tab it belongs to. The right column reads
    /// `rewrite`, which holds it only while the session's tab is active (EditorModel+Tabs).
    /// Opening one tells the shell, which pins the session's preview tab (V2).
    var openRewrite: RewriteSession? {
        didSet {
            // Its scope keeps its edges while it is open, and a close may leave paid work saved beside the project.
            cutEdgeOfferMemo = nil; cutEdgeChoiceMemo = nil; savedPaidRewriteScopesMemo = nil
            if let session = openRewrite, session.isOpen { onRewriteSessionOpen?(session.project.edits.activeClipId) }
        }
    }
    /// A Rewrite proposal shown in the transcript as tracked changes (`TranscriptProposal`).
    var proposal: TranscriptProposal?
    var focusedPane = EditorPane.transcript
    var paneFocusRequest = 0
    var scopeScrollRevision = 0
    /// The Outline target for the existing scope-scroll revision, cleared on a scope change.
    var outlineScrollWordID: String?
    var lastStyleId: String?
    /// Voice Lab's one-time beta sheet (voice-lab.md §5); R2's Turn On Voice Lab… opens it.

    @ObservationIgnored var rewriteOpenTask: Task<Void, Never>?
    #if DEBUG
    /// Tests learn where Rewrite's Core work (a plan, a placement, a review) ran: true on the main thread.
    @ObservationIgnored var rewriteWorkProbe: (@Sendable (Bool) -> Void)?
    #endif
    /// The Ask field's text (design.md §6.3.1): what the next Rewrite asks; empty asks Fix mistakes. The clip bar's field
    /// (V3b) and the Rewrite job's Ask field bind it. In memory only.
    var rewriteInstruction = ""
    /// Rewrite's scope now (design.md §6.3): the word selection, else the tab's clip, kept or suggested, else Full take.
    /// Nil with no transcript.
    var rewriteScopeNow: RewriteScope? {
        guard !words.isEmpty else { return nil }
        let selected = selectedIDs
        if let first = selected.first, let last = selected.last, let lower = index(first), let upper = index(last) {
            return .selection(min(lower, upper)...max(lower, upper))
        }
        if let clip = activeClip { return .clip(clip.id) }
        return .fullTake
    }
    /// Edit › Rewrite {scope} (design.md §8): "Rewrite Selection", "Rewrite Clip {n}" (a suggested clip too) or
    /// "Rewrite Full Take", with "…" when the chosen AI asks before each send.
    var rewriteMenuTitle: String {
        let title: String
        switch rewriteScopeNow {
        case .selection: title = "Rewrite Selection"
        case .clip(let id): title = "Rewrite Clip \(clipNumber(id) ?? 1)"
        case .fullTake, nil: title = "Rewrite Full Take"
        }
        return title + (rewriteAsksFirst ? "…" : "")
    }
    /// The chosen AI asks before each send (C8): an API key, or a CLI signed in with one. A CLI whose sign-in is not known
    /// yet does not; its send neither starts nor asks until detection knows it (ai.md §4.8).
    var rewriteAsksFirst: Bool {
        let id = app.string("llm.connector")
        guard let connector = ConnectorID(rawValue: id), app.providers.contains(where: { $0.id == id }) else { return false }
        if (connector == .claudeCode || connector == .codex) && app.cliSignIn(connector) == nil { return false }
        if case .confirm = app.llmSendKind(connector) { return true }
        return false
    }
    /// Runs Rewrite on `scope` (the scope now when nil) with `instruction` (the Ask field's text when nil): the menu,
    /// ⇧⌘R, the selection bar, the transcript's context menu and the clip bar (design.md §6.3.6 "Start"). The panel opens
    /// in R1, or in R0 when no AI is chosen. The open session on this tab sends again when it has the same scope;
    /// another scope replaces it. Text Rewrite needs no Voice Lab.
    func runRewrite(scope requested: RewriteScope? = nil, instruction: String? = nil, verb: String = "Rewrite") {
        if let reason = storyRewriteReason(for: requested ?? rewriteScopeNow) { announce(reason); return }
        let replacingPendingSend = sendConfirmation.isPresented
        guard !transcription.isRunning, let scope = requested ?? rewriteScopeNow,
              RewriteEntryPolicy.canRun(editable: capabilities.edit && (capabilities.ai || replacingPendingSend), scope: scope) else { return }
        // A Rewrite of another scope replaces the open one: its unused or running paid work asks first, inline in that
        // Rewrite ("Start a new Rewrite and discard 3 paid takes (≈ $0.12)?"); the same scope sends again and asks there.
        if let open = openRewrite, open.asksBeforeClosing, replacingPendingSend || open.rewriteScope != scope {
            askBeforeReplacing(open, scope: scope, instruction: instruction, verb: verb)
            return
        }
        let previous = sendConfirmation.isPresented ? openRewrite : nil
        let previousFind = sendConfirmation.isPresented ? findTask : nil
        if sendConfirmation.isPresented { sendConfirmation.cancel(); findTask?.cancel(); closeRewrite(returnFocus: false) }
        connectorSendVerb = verb
        // An empty field asks the default tone (the clip style's Tone, else Fix mistakes; design.md §6.3.1).
        let typed = instruction ?? rewriteInstruction
        let instruction = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (defaultRewriteItem?.instruction ?? typed) : typed
        if let session = rewrite, session.isOpen, session.rewriteScope == scope {
            sendRewriteAgain(session, instruction: instruction)
            return
        }
        rewriteOpenTask?.cancel()
        // The open session on another scope stays until the new one opens: closing it first re-rendered the transcript
        // without its proposal, which could move the selection and cancel this open, leaving no session and no message.
        rewriteNotice = nil
        let inputClipID: String? = if case .clip(let id) = RewriteSession.outputScope(of: scope, in: project) { id } else { nil }
        let snapshot = project.rewriteInputs(scope: scope, enclosingClipID: inputClipID)
        let selection = selectedWordIDs
        let pauses = selectedPauseIDs
        let signature = rewriteConnectorSignature
        let token = UUID()
        rewriteOpenToken = token
        rewriteOpenTask = Task { [weak self] in
            guard let self else { return }
            await previousFind?.value
            await previous?.waitForSend()
            if waveform == nil { await loadWaveform() }
            // A newer Rewrite or an explicit close replaced this one; it says nothing.
            guard rewriteOpenToken == token else { return }
            rewriteOpenToken = nil
            let refusal: String? = if !capabilities.ai { Self.rewriteUnavailableNotice }
                else if selectedWordIDs != selection || selectedPauseIDs != pauses { Self.rewriteSelectionNotice }
                else if project.rewriteInputs(scope: scope, enclosingClipID: inputClipID) != snapshot { Self.rewriteProjectNotice }
                else if rewriteConnectorSignature != signature { Self.rewriteConnectorNotice }
                else if Task.isCancelled { Self.rewriteStoppedNotice }
                else { nil }
            if let refusal {
                rewriteNotice = refusal
                announce(refusal)
                return
            }
            // Paid work that arrived while this one got ready asks first, as the press would have.
            if let open = openRewrite, open.asksBeforeClosing {
                askBeforeReplacing(open, scope: scope, instruction: instruction, verb: verb)
                return
            }
            // Nothing asks now: a session with no paid work, or one on no tab (its clip gone), which says what went with it.
            closeRewrite(returnFocus: false)
            openRewriteSession(scope: scope, instruction: instruction)
        }
    }
    /// A new Rewrite would replace `open`, which holds unused or running paid work: it asks first, inline in `open`, and
    /// Discard and Rewrite discards it and runs this press again on the tab it was made on (the question can bring the open
    /// session's own tab forward to ask).
    private func askBeforeReplacing(_ open: RewriteSession, scope: RewriteScope, instruction: String?, verb: String) {
        let tab = project.edits.activeClipId
        open.confirmDiscardPaidWork(.newRewrite) { [weak self] in
            guard let self else { return }
            discardRewrite(returnFocus: false)
            _ = setScope(tab)
            runRewrite(scope: scope, instruction: instruction, verb: verb)
        }
    }
    /// Why the last Rewrite press did not start, shown in the status bar until the next press (design.md §6.3.6 Start).
    var rewriteNotice: String?
    @ObservationIgnored private var rewriteOpenToken: UUID?
    static let rewriteSelectionNotice = "Rewrite didn't start because the selection changed. Nothing was sent. Press Rewrite again."
    static let rewriteProjectNotice = "Rewrite didn't start because the project changed. Nothing was sent. Press Rewrite again."
    static let rewriteConnectorNotice = "Rewrite didn't start because the AI choice changed. Nothing was sent. Press Rewrite again."
    static let rewriteUnavailableNotice = "Rewrite isn't available right now. Nothing was sent."
    static let rewriteStoppedNotice = "Rewrite didn't start. Nothing was sent. Press Rewrite again."
    /// Ends a Rewrite still getting ready without a notice: a close, or a send of the open session, replaced it.
    func cancelRewriteOpen() { rewriteOpenToken = nil; rewriteOpenTask?.cancel() }
    /// Scope changes reword the single row and bind its approval to the newly displayed words, also headlessly.
    func refreshPendingSendScope() {
        guard sendConfirmation.isPresented, openRewrite != nil else { return }
        guard rewriteScopeNow != nil else { sendConfirmation.cancel(); closeRewrite(returnFocus: false); return }
        runRewrite(verb: connectorSendVerb)
    }
    /// Sends `session` again, asking `instruction` when given: ⇧⌘R and the menu on its scope, the clip bar, R2's Ask
    /// again and R3's Rewrite Again. A proposal with takes or a change edited in its popover, R2's or the one R3 set aside,
    /// asks first (design.md §6.3.1 "Proposal open"), inline in the Rewrite job (impl-plan §13.1): "Discard these {c}
    /// changes?" in place of its footer, with Keep Working, the primary that Return and Esc choose, and Discard Changes,
    /// which sends. The job comes to the panel to ask, and VoiceOver hears the question.
    /// Paid work a resend would drop (the patch's takes, a whole clip's voice or lip sync) asks too, even with no change in
    /// the proposal. After the AI changed, the send goes to a new Rewrite with that AI (`restartRewrite`), once confirmed.
    func sendRewriteAgain(_ session: RewriteSession, instruction: String? = nil, feedback: String? = nil) {
        session.stopWordingFit(refresh: false)
        guard session.isOpen, !session.isProposing else { return }
        cancelRewriteOpen()
        // The AI changed under paid work that is still current: Rewrite Again is a new Rewrite with the new AI, and the
        // paid work it drops asks first.
        if session.asksBeforeClosing, !session.current, session.voiceSpendCurrent {
            session.confirmDiscardPaidWork(.newRewrite) { [weak self, weak session] in
                guard let self, let session else { return }
                restartRewrite(session, paidWorkConfirmed: true)
            }
            return
        }
        let count = session.proposalCount
        guard session.hasUnusedPaidWork || count > 0 && session.hasEditedChanges else {
            sendAgain(session, instruction: instruction, feedback: feedback)
            return
        }
        // Discard sends again: the run lets go of the patch's takes, and the whole clip's paid voice goes with them.
        let paid = session.hasUnusedPaidWork
        let send: @MainActor () -> Void = { [weak self, weak session] in
            guard let self, let session else { return }
            if paid { session.discardWholeClipWork() }
            sendAgain(session, instruction: instruction, feedback: feedback)
        }
        if count > 0 && (session.hasEditedChanges || session.hasPaidPatchWork || session.restoredTakesPending) {
            session.confirmDiscardChanges(perform: send)
        } else {
            session.confirmDiscardPaidWork(.newRewrite, perform: send)
        }
    }
    /// A next step's re-ask (an AI chip, Change fewer words or the free-text field) in `session`: only its phrases can
    /// change, so nothing else is discarded; paid takes still ask first, inline (RewriteNextSteps.swift).
    func sendRewriteAgain(_ session: RewriteSession, reask request: RewriteReask) {
        session.stopWordingFit(refresh: false)
        guard session.isOpen, !session.isProposing else { return }
        cancelRewriteOpen()
        session.reask(request)
    }
    private func sendAgain(_ session: RewriteSession, instruction: String?, feedback: String? = nil) {
        guard session.isOpen, !session.isProposing else { return }
        cancelRewriteOpen()
        rewriteOpenTask = Task {
            guard !Task.isCancelled, session.isOpen else { return }
            session.actionTask?.cancel()
            session.actionTask = Task { _ = await session.run(instruction: instruction, feedback: feedback) }
        }
    }
    /// Opens a Rewrite session on `scope` with the AI chosen now, which runs at once; with none, its panel asks which (R0).
    private func openRewriteSession(scope: RewriteScope, instruction: String) {
        let signature = rewriteConnectorSignature
        let provider = app.providers.first { $0.id == app.string("llm.connector") }
        let connector: RewriteConnector? = provider.map { (provider: ProviderChoice) -> RewriteConnector in
            RewriteConnector(connector: app.connector(provider.id), model: app.effectiveModel(for: provider),
                name: provider.shortName, group: provider.group, plan: provider.id == "codex" ? "ChatGPT plan" : "Claude plan")
        }
        let envelope = waveform.map { AudioEnvelope(sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), levels: $0.fine) }
        let session = RewriteSession(editor: self, scope: scope, instruction: instruction, envelope: envelope, connector: connector,
            consent: { [weak self] in
                guard let self, let provider else { return false }
                return await self.rewriteConsent(provider: provider)
            }, connectorIsCurrent: { [weak self] in self?.rewriteConnectorSignature == signature })
        openRewrite = session
        session.start()
        if app.shell.editor === self, !app.shell.viewerShown { app.shell.toggleViewer() }
        transcriptRevision += 1
    }
    /// R0's Use {name}: writes `llm.connector`, as the AI menu and Settings do, and opens the
    /// session again on the same scope with its instruction, now with that AI, which runs.
    func useRewriteConnector(_ id: String) {
        guard let session = openRewrite else { return }
        app.set("llm.connector", .string(id))
        restartRewrite(session)
    }
    /// Opens `session` again with the AI chosen now (R0's Use, a run after the AI changed). Its unused or running paid work
    /// asks first, unless the user just confirmed it (`paidWorkConfirmed`).
    func restartRewrite(_ session: RewriteSession, paidWorkConfirmed: Bool = false) {
        guard openRewrite === session, session.isOpen else { return }
        let runs = RewriteEntryPolicy.canRun(editable: capabilities.ai, scope: session.rewriteScope)
        if session.asksBeforeClosing, !paidWorkConfirmed {
            session.confirmDiscardPaidWork(runs ? .newRewrite : .close) { [weak self, weak session] in
                guard let self, let session else { return }
                restartRewrite(session, paidWorkConfirmed: true)
            }
            return
        }
        guard runs else {
            discardRewrite(returnFocus: false)
            rewriteNotice = Self.rewriteUnavailableNotice
            announce(Self.rewriteUnavailableNotice)
            return
        }
        let scope = session.rewriteScope, instruction = session.instruction
        discardRewrite(returnFocus: false)
        openRewriteSession(scope: scope, instruction: instruction)
    }
    var rewriteConnectorSignature: [String] {
        let id = app.string("llm.connector")
        return [id, app.string("llm.model.\(id)"), app.string("llm.baseUrl.\(id)"), app.string("llm.cliPath.\(id)")]
    }
    /// Closes the open Rewrite: Close Rewrite, Esc, the panel's X, a tab's close, Done, a change of the video or transcript
    /// under it, and every other close. With unused or running paid work it asks first instead, inline in the Rewrite
    /// ("Close Rewrite and discard 3 paid takes (≈ $0.12)?", Keep Working the default) and returns false; Discard and Close
    /// closes it then. Another question already up in it (a price, a provider to allow) stays, and the close waits for the
    /// creator. A session whose clip went away without Remove or Dismiss (an Undo, a run's own edit) shows on no tab to ask
    /// on, so it closes, and the status bar says what went with it. True when it closed (or nothing was open).
    @discardableResult func closeRewrite(returnFocus: Bool = true, onDiscard: (@MainActor () -> Void)? = nil) -> Bool {
        if let session = openRewrite, session.asksBeforeClosing, !closesUnasked {
            // A Rewrite still getting ready is replaced by this close, as before.
            cancelRewriteOpen()
            session.confirmDiscardPaidWork(.close) { [weak self, weak session] in
                guard let self, let session, openRewrite === session else { return }
                discardRewrite(returnFocus: returnFocus)
                onDiscard?()
            }
            return false
        }
        if let session = openRewrite, session.isOpen, session.hasUnusedPaidWork, !session.canAskAboutPaidWork {
            let line = "Rewrite closed with its clip, discarding \(session.paidWorkSummary)."
            rewriteNotice = line
            announce(line)
            let log = app.log
            Task { await log.write(LogEntry(level: .info, category: "voice-lab", message: "rewrite closed with its removed clip; its paid work was discarded")) }
        }
        discardRewrite(returnFocus: returnFocus)
        return true
    }
    /// Runs `body` with every close of the open Rewrite going ahead unasked: a close its caller already decided over paid
    /// work no phrase can use (Make it postable's settled Rewrite, `MakeItRewriteDriver.finishAsRecorded`).
    func closingUnasked(_ body: () -> Void) {
        let outer = closesUnasked
        closesUnasked = true
        defer { closesUnasked = outer }
        body()
    }
    @ObservationIgnored private var closesUnasked = false
    /// The AI choice changed (Settings, the AI picker: `AppModel`'s `llm.*` settings). An open Rewrite closes, as it did,
    /// unless it holds unused or running paid work: then it stays as it is, its takes and whole clip still usable, because
    /// the AI never makes paid work stale (design.md R3), and the status bar says so (`rewriteConnectorKeptNotice`). It is
    /// never asked about: a Settings change is no close. A reply still on its way from the old AI is set aside when it
    /// lands (R3 "AI changed"), and Rewrite Again asks before it starts over with the new AI (`sendRewriteAgain`).
    func rewriteConnectorChanged() {
        if let session = openRewrite, session.asksBeforeClosing {
            rewriteNotice = Self.rewriteConnectorKeptNotice(session.paidWorkKept.kept)
            return
        }
        closeRewrite(returnFocus: false)
    }
    /// "The AI changed. Your 3 paid takes (≈ $0.12) are kept; Rewrite Again uses the new AI and asks first."
    static func rewriteConnectorKeptNotice(_ kept: String) -> String {
        "The AI changed. " + kept + "; Rewrite Again uses the new AI and asks first."
    }
    /// Closes the open Rewrite with whatever it holds, asking nothing: a close the user already confirmed (the question's
    /// Discard, a leave they confirmed), the editor closing, and the DEBUG scenes that discard on purpose.
    func discardRewrite(returnFocus: Bool = true) {
        cancelRewriteOpen(); openRewrite?.close(); openRewrite = nil
        transcriptRevision += 1
        if returnFocus { _ = focusTranscript(in: window) }
    }
    /// The session's own `current` (its connector, its project apart from the tab, open)
    /// decides, so an edit outside its scope or another tab leaves the consent valid (impl-plan §3.3).
    func rewriteConsent(provider: ProviderChoice) async -> Bool {
        guard let session = openRewrite, session.current, let connector = session.connector?.connector else { return false }
        let expected = session.revision
        do {
            return try await app.authorizeConnectorRequest(provider, connector: connector, action: .rewrite,
                wordCount: session.task.words.wordCount, rewrite: session.task.words, confirmation: sendConfirmation, verb: connectorSendVerb) { [self] in
                    openRewrite === session && session.current
                }
        } catch is CancellationError { return false } catch {
            // R1x: the error's fix shows in the panel, named for the session's AI; the send returns false and changes nothing.
            await session.fail(error, expected: expected)
            return false
        }
    }
    /// Voice Lab's beta sheet's Turn on.
    func enableVoiceLab() {
        app.set("voiceLab.betaNoticeAccepted", .bool(true))
        app.set("voiceLab.enabled", .bool(true))

    }
    var preset = ClipPresetID.best
    var instruction = ""
    /// The last Find Clips run's preset and instructions (Hook's or the popover's), which the Explorer's Retry sends again.
    @ObservationIgnored private(set) var lastFindRequest: (preset: ClipPresetID, instruction: String)?
    var clipError: String?
    /// "Answered by {fallback} because {model} was busy." after a Find Clips run that
    /// used the fallback model (ai.md §4.3), shown under the Suggested header.
    var fallbackNote: String?
    /// The suggestion that has keyboard focus after Find Clips, without being selected
    /// (design §6.2): Return keeps it and ⌫ dismisses it.
    var focusedSuggestion: String? {
        didSet { if focusedSuggestion != nil { onNeedsSuggestions?() } }
    }
    /// A Find Clips run (Hook's or the popover's) is under way; `findingSince` is when it started, for the status bar's
    /// elapsed time (impl-plan V11a).
    var finding = false {
        didSet {
            if finding != oldValue { findingSince = finding ? Date() : nil }
            if finding { onNeedsSuggestions?() }
        }
    }
    private(set) var findingSince: Date?
    var exportProgress: ExportProgress?
    var exports: [ExportResult] = []
    /// Each exported target's share disclosure line (voice-lab.md §11.3), keyed like `ExportLedger.targetID`.
    var exportDisclosureLines: [String: String] = [:]
    var exportError: String?
    var exportClipIDs: [String] = []
    var activeExportKey: String?
    var failedExports: [String: URL] = [:]
    /// Export all (Claude mode) goes on past a file that fails; each failure is named here, "Clip 2 · 9:16: …".
    var exportFileFailures: [String] = []
    var exporting = false
    var exportJob = ExportJobState()
    @ObservationIgnored var onPresentExport: (() -> Void)?
    @ObservationIgnored var onFinishExport: (() -> Void)?
    func presentExport(clipIDs: [String]? = nil, folder: URL? = nil) {
        guard capabilities.writable, mediaExportable else { return }
        // An idle entry follows the active tab; only a render in flight keeps its
        // captured target regardless of where the user has navigated.
        let requestedIDs = clipIDs ?? activeClip.map { [$0.id] } ?? []
        if !exporting && !exportJob.voxConvo.running && (!exportJob.isOpen || clipIDs != nil || exportJob.requestedIDs != requestedIDs) {
            exportJob.draft.commit(model: self)
            exportJob = ExportJobState()
            exports = []; exportDisclosureLines = [:]; exportError = nil
            exportClipIDs = requestedIDs
            exportJob.requestedIDs = exportClipIDs
            exportJob.scope = exportClipIDs.isEmpty ? .fullVideo : .thisClip
            exportJob.folderOverride = folder
            exportJob.fileNamePattern = app.string("export.fileNamePattern", fallback: "{project}-{clip}-{aspect}")
        }
        exportJob.isOpen = true
        onPresentExport?()
    }
    func finishExportJob() {
        guard !exporting, !exportJob.voxConvo.running else { return }
        exportJob.draft.commit(model: self)
        exportJob.isOpen = false
        onFinishExport?()
    }
    var exportIndex = 0
    /// Renders in the export under way: targets × aspects (nil before the first).
    var exportTotal: Int?
    var exportStartedAt: Date?
    var sourceURL: URL { URL(fileURLWithPath: project.media.source.absolutePath) }
    var mediaResolved = false { didSet { document.setMediaResolved(mediaResolved); if !mediaResolved { suspendWorkWithoutVideo() }; followWaveformKey() } }
    /// The video's check (as the project opens or reverts, or after its video changes) has answered, found or not. A
    /// video not resolved before then is only not checked yet, so Locate… and the read-only note wait for the answer
    /// rather than flash while a slow or external volume reads.
    private(set) var mediaChecked = false
    /// The latest check, so one that a newer check replaced doesn't answer for it.
    @ObservationIgnored private var mediaCheck = 0
    /// The video's check answered without finding it: Locate… shows and the editor only reads.
    var mediaMissing: Bool { mediaChecked && !mediaResolved }
    func markRecordingMediaReady() { mediaResolved = true; mediaChecked = true }
    /// The project has a transcript. Unlike `project`, views observe it, so a transcript
    /// that arrives or is undone redraws the transcript column.
    private(set) var transcribed = false
    /// Bumped by every refresh that finds the project changed. Views that derive what they
    /// show from `project`, which they can't observe, read it (the toolbar's Export).
    @ObservationIgnored let exportsFingerprintCache = ExportsFingerprintCache()
    private(set) var projectRevision = 0
    /// The video is there but can't be read (design §5.4.4 f, corrupt file).
    var mediaUnreadable = false { didSet { if mediaUnreadable { suspendWorkWithoutVideo() }; followWaveformKey() } }

    private func suspendWorkWithoutVideo() {
        transcription.close()
        sendConfirmation.cancel()
        if let session = openRewrite {
            let paid = session.hasUnusedPaidWork
            if paid { session.persistPaidWork() }
            let notice = "Rewrite closed because the video is unavailable." + (paid ? " \(session.paidWorkKept.kept)." : "")
            rewriteNotice = notice
            announce(notice)
        }
        discardRewrite(returnFocus: false)
    }
    var canMoveCaptions: Bool {
        !document.demo && capabilities.captionPosition && !mediaUnreadable && (previewError == nil || !mediaResolved)
    }
    /// The open project's media state for its stand-ins and Export (design §5.4.4).
    var mediaStatus: MediaStatus {
        if let transcriptionStatus { return transcriptionStatus }
        if document.demo { return .demo }
        if !mediaResolved { return .missing }
        if mediaUnreadable { return .unreadable }
        return project.media.source.video == nil ? .audioOnly : .none
    }
    var plan: EditPlan?
    var voiceLabPlan: VoiceLabOutputPlan?
    var voiceRewriteFeedback: VoiceRewriteFeedback?
    var voiceRewriteToastVisible = false
    @ObservationIgnored var voiceRewriteToastTask: Task<Void, Never>?
    var renderTimeline: RenderTimeline? {
        if let voiceLabPlan { return .voiceLab(voiceLabPlan) }
        return plan.map(RenderTimeline.legacy)
    }
    var pauses: [Pause] = []
    var fillerIDs: Set<String> = []
    var summary = EditSummary()
    var transcriptRevision = 0
    var transcriptLayoutRevision = 0
    var wordIndex: [String: Int] = [:]
    var pauseByAfterIndex: [Int: Pause] = [:]
    var pauseIndex: [String: Pause] = [:]
    var cutWordIDs: Set<String> = []
    var cutPauseIDs: Set<String> = []
    var scopeBounds: ClosedRange<Int>?
    private(set) var scopePartBounds: [ClosedRange<Int>]?
    private(set) var storyTimeline: StoryTimelineLayout?
    var editingAvailable = false
    var waveform: WaveformData?
    var waveformKey: WaveformCache.ProjectKey? {
        guard !document.demo, mediaResolved, !mediaUnreadable else { return nil }
        let cache = app.locations.cache
        if project.media.spokenSources?.isEmpty == false {
            let clock = ProjectClock.build(project)
            let recordings = RenderCallerInputs.recordingFiles(project: project, primary: sourceURL, projectURL: document.fileURL)
            return .clock(sampleRate: clock.sampleRate, totalSamples: clock.totalSamples, regions: recordings.map { recording in
                .init(start: recording.region.offsetSamples, end: recording.region.endSample,
                      key: .init(contentKey: recording.key, source: recording.url, cache: cache))
            })
        }
        guard project.media.source.audio != nil else { return nil }
        return .single(.init(contentKey: project.media.source.contentKey, source: sourceURL, cache: cache))
    }
    /// The load `followWaveformKey` started for `requestedWaveformKey`, until it ends.
    @ObservationIgnored private(set) var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var requestedWaveformKey: WaveformCache.ProjectKey?
    #if DEBUG
    @ObservationIgnored var beforeWaveformLoad: @MainActor () async -> Void = {}
    #endif
    func loadWaveform() async {
        let key = waveformKey
        // The key leaves out a recording whose file isn't there or isn't the one recorded: it has no levels to load.
        var unreadable: Set<String> = []
        if case .clock(_, _, let regions) = key {
            unreadable = Set(ProjectClock.build(project).regions.map(\.key)).subtracting(regions.map(\.key.contentKey))
        }
        #if DEBUG
        await beforeWaveformLoad()
        #endif
        let value = if let key { await WaveformCache.shared.load(key) } else { nil as WaveformData? }
        // Each recording's own levels too, in its local seconds, for the cut edge seat (editing §5.10); the clock load
        // has just read them, so these come from the cache. A recording whose load ends without levels can't be read.
        var recordings: [String: WaveformData] = [:]
        switch key {
        case .single(let single): if let value { recordings[single.contentKey] = value } else { unreadable.insert(single.contentKey) }
        case .clock(_, _, let regions):
            for region in regions {
                if let loaded = await WaveformCache.shared.load(region.key) { recordings[region.key.contentKey] = loaded }
                else { unreadable.insert(region.key.contentKey) }
            }
        case nil: break
        }
        guard !Task.isCancelled, key == waveformKey else { return }
        waveform = value
        recordingWaveforms = recordings
        unreadableWaveformKeys = unreadable
    }
    /// The loaded waveform of each recording by its key (the project's content key, a spoken recording's source key):
    /// what `CutEdges` seats a cut on. Empty until a load finishes.
    var recordingWaveforms: [String: WaveformData] = [:]
    /// The recordings, by the same keys, that the last load read no levels for, because the file can't be read or isn't
    /// the one recorded: their cut edges say Reconnect rather than "Waveform still loading". Empty while a load for a new
    /// waveform key runs.
    private(set) var unreadableWaveformKeys: Set<String> = []
    /// The inline offer as last counted, for the edits, waveforms and Rewrite it was counted over (EditorModel+CutEdges).
    @ObservationIgnored var cutEdgeOfferMemo: CutEdgeOfferMemo?
    /// The selected cut's edges as last read, for the selection, edits and waveforms they were read over.
    @ObservationIgnored var cutEdgeChoiceMemo: CutEdgeChoiceMemo?
    /// The Rewrite scopes with paid takes saved beside the project, read once per project change (EditorModel+CutEdges).
    @ObservationIgnored var savedPaidRewriteScopesMemo: [String]?
    /// "Moved N cut edges into the quiet", shown in the edit bar while the edits are the ones Fix cut edges made.
    var cutEdgeResult: (edits: ProjectEdits, text: String)?
    /// Loads the waveform when the project's media is there to read, and again when it
    /// changes (impl-plan §3.1): the model owns it, so a hidden timeline never starves the
    /// audiogram stand-in or Rewrite.
    func followWaveformKey() {
        let key = waveformKey
        guard key != requestedWaveformKey else { return }
        requestedWaveformKey = key
        unreadableWaveformKeys = []
        waveformTask?.cancel()
        waveformTask = Task { [weak self] in await self?.loadWaveform() }
    }
    @ObservationIgnored private var renderedTranscript: Transcript?
    @ObservationIgnored private var renderedEdits: ProjectEdits?
    @ObservationIgnored private var renderedMedia: ProjectMedia?
    @ObservationIgnored private var renderedVoiceLab: ProjectVoiceLab?
    @ObservationIgnored private var renderedContextDemo: ContextDemoDocument?
    @ObservationIgnored private var renderedMotionCues: [MotionCue] = []
    @ObservationIgnored private var renderedMusic: [ProjectMusic] = []
    @ObservationIgnored private var renderedClipControls: [ProjectClipControls] = []
    @ObservationIgnored private var renderedClipEffects: [ClipEffect] = []
    @ObservationIgnored private(set) var fillerCandidateIDs: Set<String> = []
    @ObservationIgnored private var planningSegments: [EditSegment]?
    @ObservationIgnored private var planningWordIndex: [String: Int] = [:]
    @ObservationIgnored private var summaryCache: [(edits: ProjectEdits, summary: EditSummary)] = []
    /// Edited lengths and card words by scope ("full" or a clip id), cleared by refresh().
    @ObservationIgnored private var scopeDurations: [String: Double] = [:]
    @ObservationIgnored private var scopeCards: [String: CaptionCardText] = [:]
    @ObservationIgnored weak var undoManager: UndoManager? { didSet { undoManager?.levelsOfUndo = 500 } }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var history: EditHistory?
    @ObservationIgnored let preview: any PreviewEngine
    @ObservationIgnored let nativePreview: PreviewPlayerController?
    @ObservationIgnored let exporter: any Exporter
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var previewRevision: UInt64 = 0
    var stagedTimelineDucking: (revision: Int, contour: TimelineDuckingContour)?
    @ObservationIgnored var workTask: Task<Void, Never>?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored var findTask: Task<Void, Never>?
    @ObservationIgnored var cardPlanConnector: CardPlanConnector?
    @ObservationIgnored var onCardProjectChange: ((Project) -> Void)?
    @ObservationIgnored private var initialised = false
    /// This editor's lease on its project's cache entry, from `start` to `close` (architecture §8.2). Every editor holds
    /// its own, so a Versions window showing the same project never releases or moves the main window's lease.
    @ObservationIgnored private var cacheLease: CacheKeyLease?
    @ObservationIgnored private var cacheLeaseEnded = false
    /// The content key this editor holds in the cache, if any.
    var cacheLeaseKey: String? { cacheLease?.key }
    /// Leases the project's current content key at once and marks its entry used, releasing a different key held
    /// before. Opening, a relink or its undo, and a reload of the document call it; after `close` it does nothing.
    func holdCacheEntry() {
        let key = project.media.source.contentKey
        guard !cacheLeaseEnded, cacheLease?.key != key else { return }
        cacheLease?.release()
        cacheLease = app.leaseOpenProject(contentKey: key)
    }
    /// Set by the shell's leave boundary: edits freeze, and late results cannot
    /// change a project that is leaving. Its Rewrite is discarded without asking: the boundary asked about its paid work
    /// before setting this (`WorkspaceShell.leave`).
    var isLeaving = false { didSet { if isLeaving { app.voiceLabSession.leaveVoiceControls(owner: self); contextDemoSession?.close(); contextDemoSession = nil; motionCueEditing = nil; voiceChange?.cancel(); if voiceChange?.close() == true { voiceChange = nil }; transcription.close(); sendConfirmation.cancel(); discardRewrite(returnFocus: false) } } }
    /// Called when a refresh finds a different active clip, for example after Undo.
    @ObservationIgnored var onActiveClipChange: ((String?) -> Void)?
    /// Called when a refresh finds the clips changed: made, kept, dismissed, removed, or back after Undo. The tabs follow it.
    @ObservationIgnored var onClipsChange: (() -> Void)?
    /// Work on a preview belongs to a pinned tab, regardless of the Rewrite entry point.
    @ObservationIgnored var onRewriteSessionOpen: ((String?) -> Void)?
    /// A new editor puts keyboard focus in its transcript once it shows.
    @ObservationIgnored var wantsTranscriptFocus = true
    /// Shows the sidebar for the Find Clips setup callout and a run's progress (design §6.2).
    @ObservationIgnored var onNeedsSidebar: (() -> Void)?
    /// Progress and keyboard focus must have visible rows even after a disclosure collapsed.
    @ObservationIgnored var onNeedsSuggestions: (() -> Void)?
    #if DEBUG
    @ObservationIgnored var editTimestampForTests: Date?
    /// The last VoiceOver announcement, for harness checks.
    @ObservationIgnored var lastAnnouncement: String?
    /// Every VoiceOver announcement, for "announced once" checks.
    @ObservationIgnored var announcements: [String] = []
    /// Undo steps registered, for harness checks of one-step commands.
    @ObservationIgnored var undoSteps = 0
    #endif
    /// The active clip the last refresh drew. Unlike `project`, views observe it, so a tab
    /// switch redraws what follows the scope, such as the Rewrite panel.
    private(set) var renderedActiveClipID: String?

    init(document: VoxClipDocument, app: AppModel, preview: (any PreviewEngine)? = nil, exporter: (any Exporter)? = nil) {
        document.beginVoiceLabActivity(paidRoot: app.locations.root.appendingPathComponent("VoiceLab"))
        self.document = document
        self.app = app
        self.exporter = exporter ?? ExportQueue(exporter: AVExporter(cleanupRegistry: app.locations.root.appendingPathComponent("Scratch", isDirectory: true)))
        mediaResolved = document.demo
        if let preview { self.preview = preview; nativePreview = preview as? PreviewPlayerController }
        else {
            let native = PreviewPlayerController()
            self.preview = native; nativePreview = native
        }
        textSize = app.number("general.transcriptTextSize", fallback: DesignValues.transcriptTextSize)
        refresh()
    }

    var project: Project { document.project }
    private(set) var recordingClock: ProjectClock?
    var recordingTranscriptChoice: RecordingTranscriptChoice?
    var recordingOpenLineID: String?
    var recordingSelectedVersionKey: String?
    var partPickKey: String?
    var pendingRecording: PendingSpokenRecording?
    var recordingImportTask: Task<Void, Never>?
    var recordingImportError: String?
    @ObservationIgnored var recordingTranscriptRecipient: ((Transcript) -> Void)?
    @ObservationIgnored var recordingMatchesClock: ProjectClock?
    @ObservationIgnored var recordingMatches: TakeMatch.Result?
    var recordingFeedback: RecordingFeedback?
    @ObservationIgnored var recordingAuditionTask: Task<Void, Never>?
    @ObservationIgnored var recordingAuditionEnd: Double?
    var words: [TimedWord] { recordingClock?.words ?? project.transcript?.words ?? [] }
    var activeClip: ClipRange? { project.edits.clips.first { $0.id == project.edits.activeClipId } }
    var sortedClips: [ClipRange] {
        project.edits.clips.enumerated().sorted {
            let first = index($0.element.startWordId) ?? 0, second = index($1.element.startWordId) ?? 0
            return first == second ? $0.offset < $1.offset : first < second
        }.map(\.element)
    }
    var selectedIDs: [String] { words.filter { selectedWordIDs.contains($0.id) }.map(\.id) }
    var sourceDuration: Double { project.media.source.durationSeconds }
    /// The source sample grid the Core compares words and replace ranges on (voice-lab §10.1): a word touching a stored
    /// edge off the grid, by under a sample, is still covered.
    var sourceGrid: VoiceLabSampleGrid { VoiceLabSampleGrid(rate: Double(project.media.source.audio?.sampleRate ?? 48_000)) }
    var duration: Double { renderTimeline?.duration ?? sourceDuration }
    /// Cuts in the scope (design §3.5): the maximal runs of consecutive cut words, plus
    /// the cut pauses between the scope's words.
    var cutCount: Int { let cuts = scopeCuts; return cuts.runs + cuts.pauses }
    /// The scope's cut words, the runs they form and its cut pauses.
    private var scopeCuts: (words: Int, runs: Int, pauses: Int) {
        guard !words.isEmpty else { return (0, 0, 0) }
        let range = scopeBounds ?? 0...(words.count - 1)
        var cut = 0, runs = 0, previous = false
        for index in range {
            let isCut = cutWordIDs.contains(words[index].id)
            if isCut { cut += 1 }
            if isCut && !previous { runs += 1 }
            previous = isCut
        }
        let cutPauses = pauses.filter { cutPauseIDs.contains($0.id) && range.lowerBound <= $0.afterIndex && $0.afterIndex < range.upperBound }.count
        return (cut, runs, cutPauses)
    }
    /// The edit summary's detail (design §3.5), which VoiceOver reads after the status bar's summary (`statusSummary`):
    /// "{source} source · {w} words cut in {r} places · {p} pauses cut".
    var summaryDetail: String {
        let cuts = scopeCuts
        let span = scopeBounds.flatMap { try? clipTimes(words, startIndex: $0.lowerBound, endIndex: $0.upperBound, leadIn: scopeLeadIn) }
        let source = span.map { $0.end - $0.start } ?? sourceDuration
        let cutWords = cuts.words == 1 ? "1 word" : "\(cuts.words) words", places = cuts.runs == 1 ? "1 place" : "\(cuts.runs) places"
        let cutPauses = cuts.pauses == 1 ? "1 pause" : "\(cuts.pauses) pauses"
        return "\(durationLabel(source)) source · \(cutWords) cut in \(places) · \(cutPauses) cut"
    }
    /// "Export Video…" for the full take, "Export Clip…" for a clip (design §3.5).
    var exportTitle: String { activeClip == nil ? "Export Video…" : "Export Clip…" }
    /// The video is there to export: not a demo, found and readable (design §5.4.4).
    var mediaExportable: Bool { !exportBlockedAsDemo && mediaUsable }
    /// Demo projects have no video to export; the smoke's S-claude-does-it-all exports its synthetic recording anyway.
    var exportBlockedAsDemo: Bool {
        #if DEBUG
        document.demo && !smokeExportsDemo
        #else
        document.demo
        #endif
    }
    /// The project's video is there, readable and confirmed: no relink waits for Use It. Until then the editor only
    /// reads (editing.md §10.3, v5 f24c and f24, lead decision 7): the edit verbs, Rewrite and Export can't act, while
    /// the transcript, selection, Explorer, timeline and caption position work.
    var mediaUsable: Bool { mediaResolved && !mediaUnreadable && mediaRelinkCandidate == nil }
    /// Why the editor only reads while its video is missing or a relink waits for Use It: the status bar's alert (v5
    /// f24c, f24). Nil otherwise, and in demo projects and Versions windows, where Locate… does not apply.
    var mediaReadOnlyNote: String? {
        guard !document.demo, !document.isVersion else { return nil }
        if mediaRelinkCandidate != nil { return "Read-only until you confirm the video" }
        return mediaMissing ? "Read-only until you locate the video" : nil
    }
    /// Why Export can't run for the scope, as its tooltip and accessible description
    /// (design §3.5 and §5.4.4); nil when it can or while an export runs.
    var exportUnavailable: String? {
        if document.demo { return "Demo projects have no video to export." }
        if mediaRelinkCandidate != nil { return "Confirm the video to export." }
        if !mediaExportable { return "Locate the video to export." }
        if let clip = activeClip, isSuggestion(clip.id) { return "Keep this clip to export it." }
        return canExport || exporting ? nil : "Keep at least one word before exporting."
    }
    var canExport: Bool { capabilities.export && !exportBlockedAsDemo && (voiceLabPlan.map { $0.outputSamples > 0 } ?? (words.isEmpty ? sourceDuration > 0 : editingAvailable && summary.canExport)) }
    var playingWordID: String? {
        let transcript = words
        var lower = 0, upper = transcript.count
        while lower < upper { let middle = (lower + upper) / 2; if transcript[middle].start <= sourceTime { lower = middle + 1 } else { upper = middle } }
        return lower > 0 && sourceTime < transcript[lower - 1].end ? transcript[lower - 1].id : nil
    }
    func index(_ id: String) -> Int? { wordIndex[id] }
    func text(_ word: TimedWord) -> String { project.edits.corrections[word.id] ?? word.text }
    func scopeContains(_ id: String) -> Bool {
        guard let scopeBounds else { return true }
        return wordIndex[id].map(scopeBounds.contains) ?? false
    }
    func start() async {
        guard !initialised else { return }
        initialised = true
        await document.reportWarnings(to: app.log)
        app.openProjectKeys[project.id] = project.media.source.contentKey
        holdCacheEntry()
        eventTask = Task { [weak self, preview] in
            for await event in preview.events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .time(let edited, let source):
                    playhead = edited; sourceTime = source
                    if let stop = recordingAuditionEnd, edited >= stop { stopRecordingAudition() }
                    if let stop = previewStop {
                        if edited < stop { previewStopArmed = true } else if previewStopArmed { preview.pause(); previewStop = nil }
                    }
                    if let stop = storyPartPlaybackEnd, edited >= stop { preview.pause(); storyPartPlaybackEnd = nil }
                case .playing(let playing): isPlaying = playing
                case .failed(let error, let reason):
                    if let reason { await previewFailed(reason) } else { previewError = await app.safeError(error, context: .preview) }
                case .frame: break
                }
            }
        }
        if !document.demo && sourceURL.path != "/" {
            do {
                let url = try await resolveMediaIdentity()
                var changed = project
                document.importClock?.begin(.probe)
                defer { document.importClock?.end(.probe) }
                let probe = try await AVMediaProbe().probe(url)
                if document.fileURL == nil {
                    changed.media.source.durationSeconds = probe.durationSeconds
                    changed.media.source.video = probe.video; changed.media.source.audio = probe.audio
                    document.replaceProject(changed)
                }
            } catch {
                // The file resolved but its probe failed: it is there and can't be read.
                mediaUnreadable = mediaResolved
                previewError = await app.safeError(error, context: .preview)
            }
        }
        // The check has answered (a project without a video path has none to make).
        mediaChecked = true
        refresh()
        if mediaUsable { await updatePreview(load: true); await transcription.openOnImport() }
    }
    func close() {
        stopRecordingAudition(restore: false)
        cancelRecordingImport()
        resetTimelineEditor()
        motionCueEditing = nil
        musicPanel.reset()
        app.voiceLabSession.leaveVoiceControls(owner: self)
        contextDemoSession?.close(); contextDemoSession = nil
        voiceChange?.cancel(); if voiceChange?.close() == true { voiceChange = nil }
        voiceRewriteToastTask?.cancel()
        cancelMediaRelink()
        transcription.close()
        sendConfirmation.cancel()
        discardRewrite(returnFocus: false)
        previewRevision &+= 1
        claudeMode.armed = false
        claudeMode.cancelFindContinuation()
        workTask?.cancel(); exportTask?.cancel(); findTask?.cancel(); eventTask?.cancel(); updateTask?.cancel(); waveformTask?.cancel(); preview.close()
        app.openProjectKeys[project.id] = nil
        cacheLeaseEnded = true
        cacheLease?.release(); cacheLease = nil
    }
    func reloadFromDocument(previousProjectID: String) {
        resetTimelineEditor()
        motionCueEditing = nil
        musicPanel.reset()
        app.voiceLabSession.leaveVoiceControls(owner: self)
        contextDemoSession?.close(); contextDemoSession = nil
        voiceChange?.cancel(); if voiceChange?.close() == true { voiceChange = nil }
        cancelMediaRelink()
        sendConfirmation.cancel()
        transcription.close()
        // The document was read again (a revert, a change on disk): the session's project is gone with it. A Rewrite with
        // unused paid work asked first (`VoxClipDocument.revert`), so this discards only what the creator let go.
        discardRewrite(returnFocus: false)
        app.openProjectKeys[previousProjectID] = nil
        // The project stays open while its video is checked again, even if it is missing (architecture §8.2).
        holdCacheEntry()
        claudeMode.cancelFindContinuation()
        workTask?.cancel(); exportTask?.cancel(); findTask?.cancel(); updateTask?.cancel()
        preview.pause(); isPlaying = false; previewStop = nil
        history = nil
        renderedTranscript = nil; renderedEdits = nil; renderedMedia = nil; renderedVoiceLab = nil
        planningSegments = nil; planningWordIndex = [:]; summaryCache.removeAll()
        correctionID = nil; selectedWordIDs = []; selectedPauseIDs = []; timelineRange = nil
        fallbackNote = nil; focusedSuggestion = nil; clipError = nil; error = nil; previewError = nil
        mediaResolved = document.demo; mediaChecked = false
        refresh()
        updateTask = Task { [weak self] in
            guard let self else { return }
            guard sourceURL.path != "/" else { mediaChecked = true; return }
            do {
                _ = try await resolveMediaIdentity()
                await updatePreview(load: true)
            } catch is CancellationError {} catch { previewError = await app.safeError(error, context: .preview) }
        }
    }
    func editState() -> EditState? {
        let project = project
        if hasSeveralRecordings { return try? EditState(project: project) }
        guard let transcript = project.transcript else { return nil }
        let edits = project.edits
        return EditState(transcript: transcript, pauses: pauses, pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds, cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections, clips: edits.clips, activeClipId: edits.activeClipId, cutEdges: edits.cutEdges)
    }
    func refresh() {
        let project = project
        cutEdgeOfferMemo = nil; cutEdgeChoiceMemo = nil; savedPaidRewriteScopesMemo = nil
        if let route = timelineEditor, route.projectID != project.id || route.clipID != project.edits.activeClipId {
            resetTimelineEditor()
        }
        defer {
            if let effectID = timelineEffectID, !timelineEditableEffects.contains(where: { $0.id == effectID }) {
                timelineEffectID = nil
            }
        }
        if renderedClipEffects != project.clipEffects {
            renderedClipEffects = project.clipEffects
            timelineEffectsRevision += 1
        }
        let edits = project.edits
        let clockChanged = renderedMedia?.source != project.media.source
            || renderedMedia?.spokenSources != project.media.spokenSources
            || (project.media.spokenSources?.isEmpty == false && renderedMedia?.additionalSources != project.media.additionalSources)
        let transcriptChanged = renderedTranscript != project.transcript || clockChanged
        let editChanged = renderedEdits != edits
        guard transcriptChanged || editChanged || renderedMedia != project.media || renderedVoiceLab != project.voiceLab || renderedContextDemo != project.contextDemo || renderedMotionCues != project.motionCues || renderedMusic != project.music || renderedClipControls != project.clipControls || renderedEdits == nil else { return }
        if transcriptChanged { recordingClock = ProjectClock.build(project) }
        let words = self.words
        let clipsChanged = renderedEdits?.clips != edits.clips
        if renderedEdits?.activeClipId != edits.activeClipId {
            recordingTranscriptChoice = nil
            partPickKey = nil
            selectedStoryPartID = nil
            draggedStoryPartID = nil
            storyPartError = nil
            storyPartPlaybackEnd = nil
        }
        if transcribed != (project.transcript != nil) { transcribed = project.transcript != nil }
        projectRevision += 1
        scopeDurations.removeAll(keepingCapacity: true)
        scopeCards.removeAll(keepingCapacity: true)
        if transcriptChanged || renderedEdits?.clips != edits.clips || renderedVoiceLab != project.voiceLab {
            transcriptLayoutRevision += 1
        }
        if transcriptChanged || renderedEdits?.corrections != edits.corrections {
            transcriptLayoutRevision += 1
            fillerCandidateIDs = Set(words.filter { word in
                word.kind == .unlabeledSpeech || word.kind == .word && (try? isFillerText(edits.corrections[word.id] ?? word.text)) == true
            }.map(\.id))
        }
        if transcriptChanged {
            captionPages = []
            summaryCache.removeAll(keepingCapacity: true)
            wordIndex = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element.id, $0.offset) })
        }
        if transcriptChanged || renderedEdits?.pauseThresholdSeconds != edits.pauseThresholdSeconds {
            let detected = (try? detectPauses(words, thresholdSeconds: edits.pauseThresholdSeconds)) ?? []
            pauses = hasSeveralRecordings ? detected.filter {
                recordingClock?.region(of: words[$0.afterIndex].id) == recordingClock?.region(of: words[$0.afterIndex + 1].id)
            } : detected
            pauseByAfterIndex = Dictionary(uniqueKeysWithValues: pauses.map { ($0.afterIndex, $0) })
            pauseIndex = Dictionary(uniqueKeysWithValues: pauses.map { ($0.id, $0) })
        }
        cutWordIDs = Set(edits.cutWordIds); cutPauseIDs = Set(edits.cutPauseIds)
        let activeClip = edits.clips.first { $0.id == edits.activeClipId }
        if let clip = activeClip, let lower = index(clip.startWordId), let upper = index(clip.endWordId), lower <= upper { scopeBounds = lower...upper }
        else { scopeBounds = nil }
        scopePartBounds = activeClip?.playPartIndices(in: words)
        fillerIDs = fillerCandidateIDs.subtracting(cutWordIDs).filter { id in
            guard let scopeBounds else { return true }
            return wordIndex[id].map(scopeBounds.contains) ?? false
        }
        let state = editState()
        if history == nil, let state { history = EditHistory(state: state) }
        let coreSummary = summaryCache.first { $0.edits == edits }?.summary ?? state?.summary
        editingAvailable = coreSummary != nil
        summary = coreSummary ?? EditSummary()
        if let coreSummary, !summaryCache.contains(where: { $0.edits == edits }) {
            summaryCache.append((edits, coreSummary))
            if summaryCache.count > 16 { summaryCache.removeFirst() }
        }
        do {
            voiceLabPlan = try VoiceLabRenderPreflight.prepare(project: project,
                scope: activeClip.map { .clip($0.id) } ?? .full,
                paidRoot: app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true), labelPosition: app.voiceLabLabelPosition)?.prepared.outputPlan
            if let state {
                var comparable = edits
                comparable.cutWordIds = renderedEdits?.cutWordIds ?? []
                let segments: [EditSegment]
                // The cache only flips cut flags, so it holds only while no cut edge is stored: an edge sits on the
                // segment beside its kept/cut boundary, which a flip can move (editing §5.10).
                if !transcriptChanged, activeClip == nil, edits.cutEdges.isEmpty, comparable == renderedEdits, var cached = planningSegments {
                    let changed = state.cutWordIds.symmetricDifference(renderedEdits.map { Set($0.cutWordIds) } ?? [])
                    for id in changed {
                        if let position = planningWordIndex[id] { cached[position].cut = state.cutWordIds.contains(id) }
                    }
                    segments = cached
                } else {
                    segments = try buildSegments(state, activeClip: activeClip)
                    planningWordIndex = Dictionary(uniqueKeysWithValues: segments.enumerated().filter { $0.element.kind == .word }.map { ($0.element.id, $0.offset) })
                }
                planningSegments = segments
                let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
                if state.projectClock != nil {
                    plan = try EditPlan.build(transcript: state.transcript, editState: state, activeClip: activeClip, duration: sourceDuration, sampleRate: rate)
                } else if let clip = activeClip, clip.parts != nil {
                    plan = try buildStoryPlan(state, clip: clip, duration: sourceDuration, sampleRate: rate)
                } else {
                    plan = try buildEditPlan(segments, duration: sourceDuration, sampleRate: rate, pauseKeepSeconds: edits.pauseKeepSeconds)
                }
            } else { planningSegments = nil; planningWordIndex = [:]; plan = Self.uncutPlan(duration: sourceDuration) }
        } catch {
            plan = nil; voiceLabPlan = nil
            previewError = UserMessages.message(error)
            Task { await app.logFailure(error, context: .preview) }
        }
        storyTimeline = StoryTimelineLayout(model: self)
        renderedTranscript = project.transcript; renderedEdits = edits; renderedMedia = project.media
        renderedVoiceLab = project.voiceLab
        renderedContextDemo = project.contextDemo; renderedMotionCues = project.motionCues; renderedMusic = project.music; renderedClipControls = project.clipControls
        transcriptRevision += 1
        followWaveformKey()
        if edits.activeClipId != renderedActiveClipID {
            motionCueEditing = nil
            showsSurroundingContext = false
            captionPages = []
            renderedActiveClipID = edits.activeClipId
            onActiveClipChange?(edits.activeClipId)
        }
        // An open Motion draft follows outside changes to its saved cue (Undo, timeline edits, Ask Claude).
        motionCueEditing?.follow(self)
        if clipsChanged { onClipsChange?() }
    }
    func word(at source: Double, nearest: Bool = false) -> TimedWord? {
        let words = words
        var lower = 0, upper = words.count
        while lower < upper { let middle = (lower + upper) / 2; if words[middle].start <= source { lower = middle + 1 } else { upper = middle } }
        if nearest {
            if lower == 0 { return words.first }
            if lower == words.count { return words.last }
            return source - words[lower - 1].start <= words[lower].start - source ? words[lower - 1] : words[lower]
        }
        return lower > 0 && source <= words[lower - 1].end ? words[lower - 1] : nil
    }
    func pause(at source: Double) -> Pause? {
        var lower = 0, upper = pauses.count
        while lower < upper { let middle = (lower + upper) / 2; if pauses[middle].start <= source { lower = middle + 1 } else { upper = middle } }
        return lower > 0 && source <= pauses[lower - 1].end ? pauses[lower - 1] : nil
    }
    static func uncutPlan(duration: Double) -> EditPlan {
        let total = Int64(max(0, duration) * 48_000)
        return EditPlan(sampleRate: 48_000, totalSamples: total, cuts: [], kept: total > 0 ? [MediaInterval(startSample: 0, endSample: total)] : [])
    }
    func replace(_ newProject: Project, name: String, restoringSnapshot: Bool = false, restoresRecordingScope: Bool = false) {
        // A Versions-browser version is read-only.
        guard capabilities.writable, capabilities.media || name == "Locate media" || onlyCaptionPositionChanged(newProject) else { return }
        // The title follows the document's name, not the edit history (design §2), so
        // undoing an edit made before a Save As or Rename keeps the new title.
        var newProject = newProject
        newProject.title = project.title
        // Undo and Redo never switch tabs (impl-plan §3.3): a restored snapshot keeps the
        // current scope while it still has that clip, else Full Take.
        if restoringSnapshot, !restoresRecordingScope { newProject.edits.activeClipId = scopeKept(in: newProject) }
        // A new cut's edges move into the quiet in this same step (editing §5.10); Undo and Redo restore snapshots as
        // they were.
        if !restoringSnapshot { newProject = committingCutEdges(from: project, to: newProject) }
        guard newProject != project else { return }
        preview.pause(); isPlaying = false
        let previous = project
        let mediaChanged = previous.media.source != newProject.media.source
        if restoringSnapshot, let group = undoGroup {
            // ⌘Z or ⌘⇧Z while a group is open: what it changed so far is in the restored snapshot's redo; the run stops.
            group.interrupted = true; group.base = nil
        }
        if !restoringSnapshot, let group = undoGroup, group.ownsEdits {
            if group.base == nil { group.base = previous }
        } else {
            if !restoringSnapshot, let group = undoGroup { flush(group) }
            undoManager?.registerUndo(withTarget: self) { model in
                model.replace(previous, name: name, restoringSnapshot: true, restoresRecordingScope: restoresRecordingScope)
            }
            undoManager?.setActionName(name)
            #if DEBUG
            undoSteps += 1
            #endif
        }
        var changed = newProject
        if !restoringSnapshot {
        #if DEBUG
        changed.modifiedAt = editTimestampForTests ?? Date()
        #else
        changed.modifiedAt = Date()
        #endif
        }
        document.replaceProject(changed)
        // The open Rewrite session follows: an edit outside its scope moves it on, one inside shows R3 (design.md R3).
        openRewrite?.follow(changed, name: name)
        // A relink, or its undo or redo, may change the content key: the lease moves with the project.
        if mediaChanged { holdCacheEntry() }
        if let onCardProjectChange { onCardProjectChange(changed) } else { recordDocumentChange() }
        error = nil
        refresh()
        schedulePreviewUpdate(mediaChanged: mediaChanged)
    }
    /// Updates the preview a moment after a project change, after checking a changed video first.
    func schedulePreviewUpdate(mediaChanged: Bool) {
        stopRecordingAudition(restore: false)
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                if mediaChanged, !document.demo {
                    mediaResolved = false; mediaChecked = false
                    _ = try await resolveMediaIdentity()
                }
                try await Task.sleep(for: .milliseconds(150))
                await updatePreview(load: mediaChanged)
            } catch is CancellationError {} catch { previewError = await app.safeError(error, context: .preview) }
        }
    }
    func cancelPendingPreviewUpdate() { updateTask?.cancel() }
    #if DEBUG
    func waitForPendingPreviewForAudit() async { await updateTask?.value }
    func markMediaCheckedForAudit() { mediaChecked = true }
    #endif
    private func recordDocumentChange() {
        document.updateChangeCount(undoManager?.isUndoing == true ? .changeUndone : undoManager?.isRedoing == true ? .changeRedone : .changeDone)
    }
    private func onlyCaptionPositionChanged(_ candidate: Project) -> Bool {
        var positionEdit = project
        positionEdit.captions.position = candidate.captions.position
        positionEdit.captions.positionByAspect = candidate.captions.positionByAspect
        positionEdit.modifiedAt = candidate.modifiedAt
        positionEdit.title = candidate.title
        return positionEdit == candidate
    }
    func resolveMediaIdentity() async throws -> URL {
        mediaCheck &+= 1
        let check = mediaCheck
        // Found, missing, unreadable or cancelled, the check has answered unless a newer one replaced it.
        defer { if check == mediaCheck { mediaChecked = true } }
        let reference = project.media.source
        let resolved = try await app.projectStore.resolveSource(for: project, projectURL: document.fileURL ?? sourceURL.deletingLastPathComponent().appendingPathComponent("Untitled.voxclip"))
        try Task.checkCancellation()
        // Only a change to the media itself makes this check stale. A Save As or Move that
        // lands meanwhile rewrites the relative path, and the check still holds.
        let current = project.media.source
        guard current.contentKey == reference.contentKey, current.sizeBytes == reference.sizeBytes,
              current.absolutePath == reference.absolutePath else { throw CancellationError() }
        if reference.absolutePath != resolved.path, !document.isVersion {
            var changed = project
            changed.media.source.absolutePath = resolved.path
            document.replaceProject(changed)
            document.markEdited()
        }
        mediaResolved = true
        app.openProjectKeys[project.id] = reference.contentKey
        holdCacheEntry()
        return resolved
    }
    /// The relink flow for missing media (editing §10.3): choose the file, confirm a
    /// different-looking one, and attach it as one "Locate media" step.
    struct MediaRelinkCandidate {
        let url: URL
        let probe: MediaProbeResult
    }
    /// A different-looking file waiting for the banner's Use It. The editor only reads meanwhile (`mediaUsable`), so an
    /// open Rewrite closes as it does when the video goes missing.
    var mediaRelinkCandidate: MediaRelinkCandidate? {
        didSet {
            if mediaRelinkCandidate != nil { suspendWorkWithoutVideo() }
        }
    }
    private var mediaRelinkRevision = 0
    func cancelMediaRelink() { mediaRelinkRevision += 1; mediaRelinkCandidate = nil }
    func locateMedia() {
        cancelMediaRelink()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let revision = mediaRelinkRevision
        Task {
            do {
                let probe = try await AVMediaProbe().probe(url)
                guard revision == mediaRelinkRevision else { return }
                await prepareMediaRelink(url: url, probe: probe)
            }
            catch { if revision == mediaRelinkRevision { previewError = await app.safeError(error, context: .relink) } }
        }
    }
    func prepareMediaRelink(url: URL, probe: MediaProbeResult) async {
        cancelMediaRelink()
        previewError = nil
        let revision = mediaRelinkRevision, base = project
        guard !isLeaving, !cacheLeaseEnded else { return }
        let resume: @MainActor () -> Void = { [weak self] in
            guard let self, revision == mediaRelinkRevision, project == base else { return }
            Task { await self.prepareMediaRelink(url: url, probe: probe) }
        }
        do {
            let next: Project
            do { next = try await app.projectStore.relink(base, to: url, probe: probe) }
            catch VoxClipError.mediaMissing(_) {
                guard probe.durationSeconds.isFinite, abs(probe.durationSeconds - base.media.source.durationSeconds) <= 0.05 else {
                    previewError = "This file's duration differs by more than 0.05 seconds. Choose another file. Edits are saved."
                    return
                }
                guard revision == mediaRelinkRevision, base == project, !isLeaving, !cacheLeaseEnded else { return }
                guard closeRewrite(returnFocus: false, onDiscard: resume) else { return }
                mediaRelinkCandidate = MediaRelinkCandidate(url: url, probe: probe)
                announce("This file looks different. Use it anyway? \(url.lastPathComponent)")
                return
            }
            guard revision == mediaRelinkRevision, base == project, !isLeaving, !cacheLeaseEnded else { return }
            guard closeRewrite(returnFocus: false, onDiscard: resume) else { return }
            await applyMediaRelink(next)
        } catch { previewError = await app.safeError(error, context: .relink) }
    }
    /// Only the banner's explicit Use It action confirms different media.
    func confirmMediaRelink() async {
        guard let candidate = mediaRelinkCandidate else { return }
        let revision = mediaRelinkRevision
        guard !isLeaving, !cacheLeaseEnded else {
            previewError = "This project is closing. Reopen it before locating the video. Edits are saved."
            return
        }
        do {
            let next = try await app.projectStore.relink(project, to: candidate.url, probe: candidate.probe, confirmedDifferent: true)
            // Cancel or Choose Another deliberately retires this candidate. Otherwise
            // a refusal stays in the banner, with an explanation beside its actions.
            guard revision == mediaRelinkRevision else { return }
            guard !isLeaving, !cacheLeaseEnded else {
                previewError = "This project is closing. Reopen it before locating the video. Edits are saved."
                return
            }
            // Hashing may suspend while another edit or tab switch lands. Only the
            // media reference changes; keep the current title, edits and scope.
            var current = project
            current.media.source = next.media.source
            mediaRelinkCandidate = nil
            await applyMediaRelink(current)
        } catch {
            if revision == mediaRelinkRevision { previewError = await app.safeError(error, context: .relink) }
        }
    }
    private func applyMediaRelink(_ next: Project) async {
        mediaResolved = true; mediaUnreadable = false; previewError = nil
        replace(next, name: "Locate media")
        await updatePreview(load: true)
    }
    func apply(_ command: EditCommand, name: String, base: Project? = nil, announcing message: String? = nil) {
        guard capabilities.edit else { return }
        guard let state = editState() else { return }
        preview.pause(); isPlaying = false
        var next = base ?? project
        if history?.state != state { history = EditHistory(state: state) }
        history?.apply(command, aiResults: next.ai.results)
        guard let changed = history?.state else { return }
        guard changed != state || next != project else { return }
        next.edits = changed.projectEdits
        if case .removeClip(let id) = command {
            next.motionCues.removeAll { $0.clipID == id }; next.music.removeAll { $0.clipId == id }
            next.clipEffects.removeAll { $0.clipId == id }; next.clipControls.removeAll { $0.clipId == id }
            next.captionTranslations.removeAll { $0.clipId == id }
        }
        let clipIDs = Set(changed.clips.map(\.id))
        next.share.captions = next.share.captions.filter { $0.key == "full" || clipIDs.contains($0.key) }
        // Only the scope changed: a tab switch, not an edit (impl-plan item 16).
        if onlyScopeDiffers(next) {
            if setScope(next.edits.activeClipId) { announce(message ?? scopeName(next.edits.activeClipId)) }
            return
        }
        replace(next, name: name)
        if case .addAIClips = command, changed == state { clipError = "These clips are already in the list." }
        announce(message ?? announcement(command, before: state, after: changed, fallback: name))
    }
    /// Applies several commands as one undo step. Returns false when nothing changed.
    @discardableResult func apply(_ commands: [EditCommand], name: String) -> Bool {
        guard capabilities.edit, let state = editState() else { return false }
        preview.pause(); isPlaying = false
        if history?.state != state { history = EditHistory(state: state) }
        var next = project
        for command in commands { history?.apply(command, aiResults: next.ai.results) }
        guard let changed = history?.state, changed != state else { return false }
        next.edits = changed.projectEdits
        let removedClips = Set(commands.compactMap { command -> String? in
            if case .removeClip(let id) = command { return id }
            return nil
        })
        next.motionCues.removeAll { removedClips.contains($0.clipID) }
        next.music.removeAll { $0.clipId.map(removedClips.contains) ?? false }
        next.clipControls.removeAll { removedClips.contains($0.clipId) }
        next.captionTranslations.removeAll { $0.clipId.map(removedClips.contains) ?? false }
        let clipIDs = Set(changed.clips.map(\.id))
        next.share.captions = next.share.captions.filter { $0.key == "full" || clipIDs.contains($0.key) }
        if onlyScopeDiffers(next) { return setScope(next.edits.activeClipId) }
        replace(next, name: name)
        return true
    }
    func announcement(_ command: EditCommand, before: EditState, after: EditState, fallback: String) -> String {
        if case .restoreCuts = command { return "Restored all cuts, corrections kept" }
        let added = after.cutWordIds.subtracting(before.cutWordIds)
        let restored = before.cutWordIds.subtracting(after.cutWordIds)
        let ids = added.isEmpty ? restored : added
        let verb = added.isEmpty ? "Restored" : "Cut"
        if ids.count == 1, let id = ids.first, let position = index(id) { return "\(verb) '\(text(words[position]))'" }
        if !ids.isEmpty { return "\(verb) \(ids.count) words" }
        let pauses = after.cutPauseIds.symmetricDifference(before.cutPauseIds).count
        if pauses > 0 { return "\(after.cutPauseIds.count > before.cutPauseIds.count ? "Cut" : "Restored") \(pauses) \(pauses == 1 ? "pause" : "pauses")" }
        return fallback
    }
    func cutSelection(restore: Bool = false) {
        // An exact range cuts nothing yet: the words under it are only its highlight (issue #41).
        if timelineRange != nil { announce(Self.timelineCutRangeReason); return }
        let selected = selectedIDs + selectedPauseIDs.sorted()
        let ids = restore ? selected : selected.filter { (id: String) -> Bool in
            !cutWordIDs.contains(id) && !cutPauseIDs.contains(id)
        }
        guard !ids.isEmpty else { return }
        apply(restore ? .restoreSelection(ids: ids) : .cutSelection(ids: ids), name: restore ? "Restore selection" : "Cut selection")
    }
    func toggleSelectionCut() {
        let ids = selectedIDs + selectedPauseIDs.sorted()
        let restore: Bool = !ids.isEmpty && ids.allSatisfy { (id: String) -> Bool in cutWordIDs.contains(id) || cutPauseIDs.contains(id) }
        cutSelection(restore: restore)
    }
    /// Make Clip (⌥⌘K, design §3.4): one undo step adds the clip and selects its row. A
    /// selection an existing clip already covers selects that clip instead.
    func makeClip() {
        // From an exact range the clip's edges snap to the words it covers (issue #41).
        let range = timelineRange.flatMap { _ in timelineRangeClipWords }
        guard let start = range?.start ?? selectedIDs.first, let end = range?.end ?? selectedIDs.last else { return }
        if let existing = project.edits.clips.first(where: { $0.startWordId == start && $0.endWordId == end }) {
            let message = clipNumber(existing.id).map { "Clip \($0) already covers these words." } ?? "A clip already covers these words."
            if activeClip?.id == existing.id { announce(message) } else { activate(existing, announcing: message) }
            return
        }
        guard let lower = index(start), let upper = index(end), lower <= upper else { return }
        let named = range == nil ? words.filter { self.selectedWordIDs.contains($0.id) } : words[lower...upper].filter { !self.cutWordIDs.contains($0.id) }
        let title = EditingAlgorithms.clipTitle(named.lazy.map { self.text($0) })
        let clip = ClipRange(id: UUID().uuidString.lowercased(), startWordId: start, endWordId: end, title: title)
        guard apply([.addClip(clip), .setActiveClip(clipId: clip.id)], name: range == nil ? "Make clip from selection" : "Make clip") else { return }
        announce(clipNumber(clip.id).map { "Clip \($0) made." } ?? "Clip made.")
    }
    func nudge(_ clip: ClipRange, start: Bool, offset: Int) {
        guard let lower = index(clip.startWordId), let upper = index(clip.endWordId) else { return }
        apply(.updateClip(id: clip.id, startIndex: start ? min(upper, max(0, lower + offset)) : lower, endIndex: start ? upper : max(lower, min(words.count - 1, upper + offset))), name: "Nudge clip edge")
    }
    func setClipEdge(start: Bool) {
        if activeClip?.parts != nil {
            if let id = selectedIDs.first, let caret = index(id) { trimStoryPart(start: start, at: caret) }
            return
        }
        guard let clip = activeClip, let id = selectedIDs.first, let caret = index(id), let lower = index(clip.startWordId), let upper = index(clip.endWordId) else { return }
        guard start ? caret <= upper : caret >= lower else { return }
        apply(.updateClip(id: clip.id, startIndex: start ? caret : lower, endIndex: start ? upper : caret), name: "Set clip edge")
    }
    func trimIndex(start: Bool, source: Double) -> Int? {
        guard !words.isEmpty else { return nil }
        var lower = 0
        var upper = words.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let boundary = start ? words[middle].start : words[middle].end
            if boundary < source { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return 0 }
        if lower == words.count { return words.count - 1 }
        let previous = start ? words[lower - 1].start : words[lower - 1].end
        let next = start ? words[lower].start : words[lower].end
        return source - previous <= next - source ? lower - 1 : lower
    }
    func trimClip(_ clip: ClipRange, start: Bool, index: Int) {
        guard let lower = self.index(clip.startWordId), let upper = self.index(clip.endWordId) else { return }
        let nextStart = start ? index.clamped(to: 0...upper) : lower
        let nextEnd = start ? upper : index.clamped(to: lower...(words.count - 1))
        guard nextStart != lower || nextEnd != upper else { return }
        apply(.updateClip(id: clip.id, startIndex: nextStart, endIndex: nextEnd), name: "Trim clip")
    }
    func adjustTrim(start: Bool, offset: Int) {
        if let parts = activeClip?.parts {
            let part = parts[selectedStoryPartIndex]
            guard let current = index(start ? part.startWordId : part.endWordId) else { return }
            trimStoryPart(start: start, at: current + offset)
            return
        }
        guard let clip = activeClip, let current = index(start ? clip.startWordId : clip.endWordId) else { return }
        trimClip(clip, start: start, index: current + offset)
    }
    /// Scopes the editor to `clip`, or to Full Take: a tab, an Explorer row, [ and ], and
    /// Escape in the transcript. A scope change is no undo step (`setScope`); VoiceOver hears
    /// `message`, else the new scope's name. The playhead moves to the clip's first word and
    /// the transcript scrolls to it.
    func activate(_ clip: ClipRange?, announcing message: String? = nil) {
        let previous = project.edits.activeClipId
        setScope(clip?.id)
        if project.edits.activeClipId != previous { timelineRange = nil }
        if let message { announce(message) }
        else if project.edits.activeClipId != previous { announce(scopeName(project.edits.activeClipId)) }
        if project.edits.activeClipId == clip?.id {
            outlineScrollWordID = nil
            seekToActiveClip()
            if previous != clip?.id { scopeScrollRevision += 1 }
        }
    }
    /// Moves the playhead to the active clip's first word.
    private func seekToActiveClip() {
        guard let clip = activeClip else { return }
        if clip.parts != nil, let timeline = renderTimeline, timeline.duration > 0 {
            seek(source: timeline.sourceTime(0))
        } else if let start = clip.playParts.first?.startWordId, let first = index(start) {
            seek(source: words[first].start)
        }
    }
    func moveClip(_ direction: Int) {
        guard !sortedClips.isEmpty else { return }
        let position = sortedClips.firstIndex { $0.id == activeClip?.id } ?? (direction > 0 ? -1 : sortedClips.count)
        activate(sortedClips[min(sortedClips.count - 1, max(0, position + direction))])
    }
    func removeClip(_ id: String) {
        guard !asksBeforeRemoving(id, suggestion: false, then: { [weak self] in self?.removeClip(id) }) else { return }
        rowAction([.removeClip(id: id)] + focusNext(after: id), name: "Remove clip", announcing: clipNumber(id).map { "Clip \($0) removed." } ?? "Clip removed.")
    }
    /// Remove or Dismiss on the open Rewrite's own clip (its tab, or the clip it rewrites) while it holds unused or running
    /// paid work: asks first, inline in that Rewrite on its tab ("Remove this clip and discard 3 paid takes (≈ $0.12)?",
    /// Keep Working the default), and true. Discard and Remove (Dismiss) discards the Rewrite and runs `then`, the removal
    /// again. Without the question the clip's Rewrite would close with it, on no tab where it could still ask.
    private func asksBeforeRemoving(_ id: String, suggestion: Bool, then: @escaping @MainActor () -> Void) -> Bool {
        guard capabilities.edit, let session = openRewrite, session.asksBeforeClosing,
              session.project.edits.activeClipId == id || session.rewriteScope == .clip(id) else { return false }
        session.confirmDiscardPaidWork(.removeClip(suggestion: suggestion)) { [weak self, weak session] in
            guard let self, let session, openRewrite === session else { return }
            discardRewrite(returnFocus: false)
            then()
        }
        return true
    }

    // Clips in the sidebar (design §3.4 and §6.2): kept clips number 1…n in transcript
    // order and suggestions continue after them.
    var keptClips: [ClipRange] { sortedClips.filter { $0.origin == .manual || $0.selected } }
    /// Suggestions ranked by score, best first (design.md §6.7): the planner's once Make it postable scored the clip,
    /// else Find Clips' own. Equal scores keep transcript order.
    var suggestedClips: [ClipRange] {
        let found = sortedClips.filter { $0.origin == .ai && !$0.selected }
        return found.enumerated().sorted { first, second in
            let a = suggestionScore(first.element) ?? 0, b = suggestionScore(second.element) ?? 0
            return a == b ? first.offset < second.offset : a > b
        }.map(\.element)
    }
    /// A suggestion's score, 1–10: the planner's, else Find Clips'; nil without either.
    func suggestionScore(_ clip: ClipRange) -> Int? {
        if let planned = makeIt.scores[clip.id]?.score { return planned }
        guard let resultID = clip.aiResultId, let index = clip.aiClipIndex,
              let result = project.ai.results.first(where: { $0.id == resultID }), result.clips.indices.contains(index) else { return nil }
        return result.clips[index].score
    }
    func clipNumber(_ id: String) -> Int? {
        let kept = keptClips
        if let position = kept.firstIndex(where: { $0.id == id }) { return position + 1 }
        return suggestedClips.firstIndex { $0.id == id }.map { kept.count + $0 + 1 }
    }
    func isSuggestion(_ id: String) -> Bool { suggestedClips.contains { $0.id == id } }
    /// The row after a clip in sidebar order: the next kept clip or suggestion, else Full
    /// take (nil).
    func clipAfter(_ id: String) -> String? {
        let rows = keptClips + suggestedClips
        guard let position = rows.firstIndex(where: { $0.id == id }), position + 1 < rows.count else { return nil }
        return rows[position + 1].id
    }
    /// Keep, Dismiss and Remove on the selected row move the selection to the next row in
    /// the same undo step (design §3.4).
    private func focusNext(after id: String) -> [EditCommand] {
        project.edits.activeClipId == id ? [.setActiveClip(clipId: clipAfter(id))] : []
    }
    /// A row action as one undo step; the playhead follows when the selection moved.
    private func rowAction(_ commands: [EditCommand], name: String, announcing message: String) {
        let active = project.edits.activeClipId
        guard apply(commands, name: name) else { return }
        announce(message)
        if project.edits.activeClipId != active { seekToActiveClip() }
    }
    func keep(_ id: String) {
        rowAction([.setClipSelected(id: id, selected: true)] + focusNext(after: id), name: "Keep clip", announcing: keptAnnouncement(id))
    }
    /// A suggestion row's Rewrite or Export (design §3.4): keeps the suggestion as one "Keep clip" undo step, with no
    /// prompt, and leaves the selection on it so the action that follows opens on that clip. False when it is not a
    /// suggestion or the project cannot be edited.
    @discardableResult func keepForRowAction(_ id: String) -> Bool {
        guard isSuggestion(id), capabilities.edit else { return false }
        let message = keptAnnouncement(id)
        guard apply([.setClipSelected(id: id, selected: true)], name: "Keep clip") else { return false }
        announce(message)
        return true
    }
    /// "Clip 3 kept.": the number the clip takes once kept.
    private func keptAnnouncement(_ id: String) -> String {
        let number = sortedClips.filter { $0.origin == .manual || $0.selected || $0.id == id }.firstIndex { $0.id == id }.map { $0 + 1 }
        return number.map { "Clip \($0) kept." } ?? "Clip kept."
    }
    /// Keeps every suggestion as one undo step.
    func keepAll() {
        let ids = suggestedClips.map(\.id)
        guard !ids.isEmpty, apply(ids.map { .setClipSelected(id: $0, selected: true) }, name: "Keep all suggestions") else { return }
        announce(ids.count == 1 ? "Clip \(keptClips.count) kept." : "\(ids.count) clips kept.")
    }
    func dismiss(_ id: String) {
        guard !asksBeforeRemoving(id, suggestion: true, then: { [weak self] in self?.dismiss(id) }) else { return }
        rowAction([.removeClip(id: id)] + focusNext(after: id), name: "Dismiss suggestion", announcing: "Suggestion dismissed.")
    }
    /// Return on the focused suggestion keeps it, ⌫ dismisses it, and focus moves to the
    /// next suggestion (design §6.2). False when no suggestion has focus.
    @discardableResult func actOnFocusedSuggestion(keep: Bool) -> Bool {
        guard let id = focusedSuggestion, isSuggestion(id) else { focusedSuggestion = nil; return false }
        let rows = suggestedClips.map(\.id)
        let next: String? = rows.firstIndex(of: id).flatMap { (index: Int) -> String? in
            let following: Int = index + 1
            return following < rows.count ? rows[following] : nil
        }
        if keep { self.keep(id) } else { dismiss(id) }
        focusedSuggestion = isSuggestion(id) ? id : next
        return true
    }
    func renameClip(_ id: String, to title: String) {
        apply(.renameClip(id: id, title: EditingAlgorithms.clipTitle([title])), name: "Rename clip")
    }
    /// The edited length of a clip, or of the full take for nil (design §3.4 meta line).
    func editedDuration(_ clip: ClipRange?) -> Double {
        let key = clip?.id ?? "full"
        if let cached = scopeDurations[key] { return cached }
        guard let state = editState(),
              let plan = try? EditPlan.build(transcript: state.transcript, editState: state, activeClip: clip, duration: sourceDuration,
                                             sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000))
        else { return clip == nil ? sourceDuration : 0 }
        scopeDurations[key] = plan.duration
        return plan.duration
    }
    /// The caption card's words for a scope (design §5.4.2), from VoxClipCore.
    func cardText(_ scope: CaptionCardScope, wordsVisible: Bool) -> CaptionCardText {
        _ = transcriptRevision
        guard let style = app.cardStyle(for: project), let resources = app.captionResources else { return .none }
        let key: String
        switch scope { case .fullTake: key = "full"; case .clip(let id): key = id }
        let cacheKey = "\(key)|\(wordsVisible)|\(style.id)"
        if let cached = scopeCards[cacheKey] { return cached }
        let text = CaptionCardText.make(project: project, scope: scope, style: style, wordsVisible: wordsVisible, resources: resources)
        scopeCards[cacheKey] = text
        return text
    }
    /// The source time of a scope's first kept word, where its thumbnail frame is taken.
    func firstKeptTime(_ clip: ClipRange?) -> Double? {
        let cut = Set(project.edits.cutWordIds)
        let opening = clip?.playParts.first
        let lower = opening.flatMap { index($0.startWordId) } ?? 0, upper = opening.flatMap { index($0.endWordId) } ?? words.count - 1
        guard lower <= upper, upper < words.count else { return nil }
        return words[lower...upper].first { $0.kind == .word && !cut.contains($0.id) }?.start
    }
    func beginCorrection() {
        guard capabilities.edit, let id = selectedIDs.first, let word = words.first(where: { $0.id == id }) else { return }
        correctionID = id; correctionText = text(word)
    }
    func saveCorrection(advance: Bool = false) {
        guard let id = correctionID else { return }
        let text = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !correctionText.unicodeScalars.contains(where: { [0x0A, 0x0D, 0x2028, 0x2029].contains($0.value) }),
              text.unicodeScalars.count <= EditingLimits.maxCorrectionScalars else { return }
        apply(.correct(id: id, text: text), name: "Correct spelling")
        correctionID = nil
        if advance, let position = index(id), position + 1 < words.count { selectedWordIDs = [words[position + 1].id]; beginCorrection() }
    }
    /// Ends the inline correction (design §4.2) the way an inline rename ends: focus leaving the field, a selection
    /// change and Play keep the typed text when it can be saved; Esc, or text that can't be saved, keeps the word.
    func endCorrection(keep: Bool = true) {
        guard correctionID != nil else { return }
        if keep { saveCorrection() }
        correctionID = nil
    }
    /// Finds the selection's first and last word or pause in reading order, from the
    /// selection `didSet`s.
    private func updateSelectionEnds() {
        var lower: (position: Int, id: String)?, upper: (position: Int, id: String)?
        func consider(_ id: String, at position: Int?) {
            guard let position else { return }
            if lower.map({ position < $0.position }) ?? true { lower = (position, id) }
            if upper.map({ position > $0.position }) ?? true { upper = (position, id) }
        }
        for id in selectedWordIDs { consider(id, at: wordIndex[id].map { 2 * $0 }) }
        for id in selectedPauseIDs { consider(id, at: pauseIndex[id].map { 2 * $0.afterIndex + 1 }) }
        let ends = [lower?.id, upper?.id].compactMap { $0 }
        let unique = ends.count == 2 && ends[0] == ends[1] ? [ends[0]] : ends
        if unique != selectionEnds { selectionEnds = unique }
    }
    /// Selects a word, or with `extend` the words from the selection's first to it and the
    /// cut pauses between them, as a drag over their folds selects them.
    func select(_ id: String, extend: Bool = false) {
        if extend, let anchor = selectedIDs.first, let lower = index(anchor), let upper = index(id) {
            let span = min(lower, upper)...max(lower, upper)
            selectedPauseIDs = Set(span.dropLast().compactMap { pauseByAfterIndex[$0]?.id }.filter(cutPauseIDs.contains))
            selectedWordIDs = Set(words[span].map(\.id))
        } else { selectedPauseIDs = []; selectedWordIDs = [id] }
        if !isPlaying, let word = words.first(where: { $0.id == id }) { seek(source: word.start) }
    }
    func step(_ offset: Int, extend: Bool = false, sentence: Bool = false) {
        guard !words.isEmpty else { return }
        var position = index(selectedIDs.last ?? "") ?? 0
        repeat { position = min(words.count - 1, max(0, position + offset)) }
        while sentence && position > 0 && position < words.count - 1 && !words[max(0, position - 1)].text.hasSuffix(".")
        select(words[position].id, extend: extend)
    }
    /// Seeks the preview. A seek ends any stop (`previewStop`); `stop` (take time) sets a new one once the seek has
    /// landed, so a time from before the seek can't end it at once.
    func seek(source: Double, stop: Double? = nil) {
        guard let renderTimeline else { return }
        previewStop = nil
        let time = renderTimeline.mapTime(source), end = stop.map(renderTimeline.mapEndTime)
        Task { [weak self] in
            guard let self else { return }
            do { try await preview.seek(to: time, exact: true); playhead = time; sourceTime = source; if let end { previewStop = end } }
            catch { previewError = await app.safeError(error, context: .preview) }
        }
    }
    func transport(_ key: String, shift: Bool = false) {
        if recordingAuditionTask != nil { stopRecordingAudition(); return }
        storyPartPlaybackEnd = nil
        if [" ", "l", "p"].contains(key.lowercased()) { rewrite?.takePlan?.stopAudition() }
        // Saving an open correction pauses (`apply`), so Space and L toggle from the state before the save.
        let wasPlaying = isPlaying
        endCorrection()
        switch key.lowercased() {
        case " ":
            // Space is plain playback: it ends a Play range or P stop, as on Windows.
            previewStop = nil
            if shift, let word = words.first(where: { selectedWordIDs.contains($0.id) }) { seek(source: word.start) }
            if wasPlaying { preview.pause() } else { preview.play() }
            isPlaying = preview.isPlaying
        case "j": seek(source: max(0, sourceTime - 3))
        case "k": preview.pause(); isPlaying = false; playbackRate = 1; previewStop = nil
        case "l": playbackRate = wasPlaying ? (playbackRate == 1 ? 1.5 : 2) : 1; preview.play(); nativePreview?.player.rate = playbackRate; isPlaying = preview.isPlaying
        case "p": if let word = words.first(where: { selectedWordIDs.contains($0.id) }), let last = words.last(where: { selectedWordIDs.contains($0.id) }) { seek(source: max(0, word.start - 2), stop: min(sourceDuration, last.end + 2)); preview.play(); isPlaying = preview.isPlaying }
        case "c", "\r": beginCorrection()
        case "i": setClipEdge(start: true)
        case "o": setClipEdge(start: false)
        case "[": moveClip(-1)
        case "]": moveClip(1)
        case "\u{1b}": activate(nil)
        default: break
        }
    }
    func findNext(backward: Bool = false) {
        let matches = words.filter { text($0).localizedCaseInsensitiveContains(query) }
        guard !query.isEmpty, !matches.isEmpty else { return }
        let current = matches.firstIndex { selectedWordIDs.contains($0.id) } ?? (backward ? 0 : -1)
        select(matches[(current + (backward ? -1 : 1) + matches.count) % matches.count].id)
    }
    func cutMatches() { let ids = words.filter { text($0).localizedCaseInsensitiveContains(query) }.map(\.id); apply(.cutSelection(ids: ids), name: "Cut all matches") }
    /// The captions the open clip renders with (its own pick, else the project's, design.md §6.6); the full take's are the
    /// project's. The Captions panel, the viewer and the CC lane show and edit these.
    var activeCaptions: CaptionSettings { project.captionSettings(forClip: activeClip?.id) }

    /// With a clip open, the style becomes that clip's own pick, kept whatever the project default or Claude does later.
    /// With none, it is the project default every clip without a pick follows, and it fixes the clip style's captions so
    /// Claude's picks never override it (design.md §6.6).
    func setStyle(_ id: String) {
        let current = activeCaptions
        if id == "off", current.styleId != "off" { lastStyleId = current.styleId }
        else if id != "off" { lastStyleId = id }
        var next = project
        if let clip = activeClip, let style = project.clipStyle ?? cardClipStyle {
            next.clipStyle = style.choosingCaptionStyle(id, forClip: clip.id, current: current)
        } else {
            next.captions.styleId = id; next.clipStyle = next.clipStyle?.fixingCaptions(.init(raw: id))
        }
        replace(next, name: "Change caption style")
    }

    /// A fine-tune of the open clip's captions: its pick's overrides while one applies, else the project's captions. The
    /// position always stays the project's.
    func mutateCaptions(name: String = "Fine tune captions", _ change: (inout CaptionSettings) -> Void) {
        var next = project
        if let clip = activeClip, var style = project.clipStyle, var pick = style.captionPick(forClip: clip.id) {
            var settings = activeCaptions
            change(&settings)
            pick.styleId = settings.styleId
            pick.overrides = settings.overrides
            style.captionPicks[clip.id] = pick
            next.clipStyle = style
            next.captions.position = settings.position
            next.captions.positionByAspect = settings.positionByAspect
        } else {
            change(&next.captions)
        }
        replace(next, name: name)
    }
    func setCaptionsEnabled(_ enabled: Bool) {
        guard enabled else { setStyle("off"); return }
        let previous = lastStyleId ?? app.string("captions.defaultStyleId")
        setStyle(app.styles.contains { $0.id == previous } ? previous : app.styles.first?.id ?? "off")
    }
    var captionsEdited: Bool {
        !activeCaptions.overrides.isEmpty || project.captions.positionByAspect[captionPreset.rawValue] != nil || project.captions.position != nil
    }
    var captionSummary: String {
        let captions = activeCaptions
        guard let library = app.styles.first(where: { $0.id == captions.styleId }) else { return "Off" }
        let resolved = (try? library.resolved(overrides: captions.overrides, frame: outputSpec().size)) ?? library
        var parts: [String] = []
        if let accent = resolved.accent {
            let names = ["#FFE14D": "Yellow", "#4BE38A": "Green", "#5CE1FF": "Cyan", "#FF6FAE": "Pink", "#F3F0E7": "Paper", "#FFFFFF": "White"]
            parts.append(names[accent.uppercased()] ?? "Colour")
        }
        parts.append(resolved.text.transform == .uppercase ? "ALL CAPS" : "As said")
        let count = resolved.layout.maxWords
        parts.append(count >= 16 ? "Line" : count == 1 ? "1 word" : "\(count) words")
        return parts.joined(separator: " · ")
    }
    func setAspect(_ aspect: AspectRatio) { var next = project; next.export.aspect = aspect; replace(next, name: "Change aspect") }
    var captionPreset: AspectRatio {
        let size = outputSpec().size
        if 16 * size.width == 9 * size.height { return .portrait }
        if 9 * size.width == 16 * size.height { return .landscape }
        if size.width == size.height { return .square }
        return .source
    }
    func zoom(_ amount: Double) { textSize = (amount == 0 ? DesignValues.transcriptTextSize : textSize + amount).clamped(to: DesignValues.transcriptZoom); app.set("general.transcriptTextSize", .number(textSize)); transcriptRevision += 1 }
    func copySelection() { copyText(words.filter { selectedWordIDs.contains($0.id) }.map { text($0) }.joined(separator: " ")) }
    func announce(_ message: String) {
        #if DEBUG
        lastAnnouncement = message
        announcements.append(message)
        #endif
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func renderSnapshot() -> EditorRenderSnapshot {
        EditorRenderSnapshot(project: project, state: editState(), plan: plan, reduceMotion: EditorAccessibilityPolicy.system.reduceMotion)
    }
    func renderRequest(target: ExportTarget? = nil, snapshot: EditorRenderSnapshot? = nil, labelPosition: VoiceLabLabelPosition? = nil,
                       previewBaseline: Project? = nil) async throws -> RenderRequest {
        let snapshot = snapshot ?? renderSnapshot()
        let project = snapshot.project
        let state = snapshot.state
        let clip: ClipRange?
        switch target {
        case nil: clip = state?.activeClip
        case .fullEdit: clip = nil
        case .clip(let id):
            guard let selected = project.edits.clips.first(where: { $0.id == id }) else {
                throw VoxClipError.exportFailed("Clip no longer exists")
            }
            clip = selected
        }
        let voiceLab = try VoiceLabRenderPreflight.prepare(project: project,
            scope: clip.map { .clip($0.id) } ?? .full,
            paidRoot: app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true), labelPosition: labelPosition ?? app.voiceLabLabelPosition)
        if clip != nil && state == nil { throw VoxClipError.exportFailed("Clip transcript is unavailable") }
        let segments = try state.map { try buildSegments($0, activeClip: clip) }
        var plan = snapshot.plan
        if target != nil || voiceLab != nil, let state {
            plan = try EditPlan.build(transcript: state.transcript, editState: state, activeClip: clip, duration: project.media.source.durationSeconds,
                                      sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000))
        }
        if state == nil, project.contextDemo != nil, case .legacy(let canonical) = try RenderCallerInputs.timeline(project: project) {
            plan = canonical
        }
        guard let plan else { throw VoxClipError.exportFailed("Could not build the edit plan") }
        guard (voiceLab?.prepared.outputPlan.outputSamples ?? plan.outputSamples) > 0 else { throw VoxClipError.everythingCut }
        let output = ExportFingerprint.output(project, clipID: clip?.id)
        // Bleeped and muted words read as × marks in the captions (ai.md §18.5), on the Voice Lab path too.
        let effects = ClipEffects.rendered(in: project, clipID: clip?.id)
        let captionSegments = segments.map { ClipEffects.maskingBleeps($0, effects: effects) }
        // Each clip renders in its own caption look (design.md §6.6): preview, export and the SRT lay out with it.
        let layout = try await buildCaptions(segments: captionSegments, plan: plan, output: output, forPreview: target == nil,
                                            project: project.resolvingCaptions(forClip: clip?.id), voiceLab: voiceLab.map { ClipEffects.maskingBleeps($0.prepared.outputPlan, effects: effects) },
                                            translations: (project, clip?.id, effects))
        try Task.checkCancellation()
        if target == nil, (previewBaseline ?? snapshot.project) != self.project || isLeaving { throw CancellationError() }
        let request = RenderRequest(sourceURL: URL(fileURLWithPath: project.media.source.absolutePath), plan: plan, captions: layout?.track ?? CaptionTrack(),
            output: output, forPreview: target == nil, captionLayout: layout, voiceLab: voiceLab)
        return try RenderCallerInputs.prepare(request, project: project, clipID: clip?.id, dataRoot: app.locations.root.resolvingSymlinksInPath(),
            shared: app.shared, resolveFootageURL: { JSONProjectStore.footageURL($0, beside: request.sourceURL) },
            projectURL: document.fileURL,
            reduceMotion: snapshot.reduceMotion, isCancelled: { Task.isCancelled })
    }
    func buildCaptions(segments: [EditSegment]?, plan: EditPlan, output: OutputSpec, forPreview: Bool,
                       project: Project, voiceLab: VoiceLabOutputPlan?,
                       translations: (project: Project, clipID: String?, effects: [ClipEffect])? = nil) async throws -> CaptionLayoutResult? {
        guard let segments else { return nil }
        let style = app.styles.first { $0.id == project.captions.styleId }
        do {
            let layout = try await app.captions.layout(AppCaptionLayoutInput(segments: segments, settings: project.captions, plan: plan, output: output, language: project.transcript?.language, style: style, voiceLab: voiceLab, translations: translations))
            captionError = app.captions.rejectedOverrides ? "These caption settings could not be applied." : nil
            return layout
        } catch is CancellationError { throw CancellationError() }
        catch {
            captionError = "Captions are not available in this build. Your video and edits are still here."
            if !forPreview || voiceLab != nil { throw error }
            return nil
        }
    }
    func outputSpec() -> OutputSpec {
        ExportFingerprint.output(project, clipID: renderedActiveClipID)
    }
    /// Whether the stage shows the native player rather than a stand-in (design.md §5.4.4): a resolved, readable video in a
    /// project that isn't the demo.
    var stageShowsPlayer: Bool {
        !document.demo && mediaResolved && !mediaUnreadable && project.media.source.video != nil && nativePreview != nil
    }
    /// The preview failure the stage shows over its player, with Reload Preview (design.md §5.4.4 g), so a preview that
    /// can't draw is never a silent black box. The transcript's notice steps aside while the stage carries it.
    var stagePreviewError: String? {
        guard stageShowsPlayer, let previewError, !previewError.isEmpty else { return nil }
        return previewError
    }
    /// The stage's player layer held a ready item without showing a frame and was re-attached once (design.md §5.4.4 g):
    /// logged so a black stage with no compositor reason is told apart from failed frames.
    func previewDisplayStalled() async {
        await app.log.write(LogEntry(level: .error, category: "preview", message: "display stalled, layer reattached"))
    }
    /// The preview's compositor failed a frame or left an overlay out (design.md §5.4.4 g): logged by its fixed tag,
    /// never user text, and shown on the stage. The item reports once, so this runs once per load.
    func previewFailed(_ reason: PreviewFailureReason) async {
        await app.log.write(LogEntry(level: .error, category: "preview", message: "compositor reason=\(reason.rawValue)"))
        let message = Self.previewFailureMessage(reason)
        previewError = message
        announce(message)
    }
    /// The stage's line for a compositor failure (design.md §13 "Preview failed").
    static func previewFailureMessage(_ reason: PreviewFailureReason) -> String {
        switch reason {
        case .captionLayout, .captionRaster, .resources: "Captions couldn't be drawn, so the preview plays without them."
        case .title: "The title couldn't be drawn, so the preview plays without it."
        case .disclosure: "The AI voice label couldn't be drawn, so the preview stopped."
        case .sourceFrame, .lipsyncFrame, .demoFrame, .frameBuffer: "The preview couldn't draw the video."
        }
    }
    /// Reload Preview on the stage: builds the preview again; a load that works clears the message.
    func reloadPreview() async { await updatePreview(load: true) }
    func updatePreview(load: Bool) async {
        guard mediaResolved else { return }
        previewRevision &+= 1
        let revision = previewRevision
        let snapshot = renderSnapshot()
        do {
            let request = try await renderRequest(snapshot: snapshot)
            guard revision == previewRevision, snapshot.project == project, !isLeaving, !Task.isCancelled else { return }
            captionPages = request.captionLayout?.pages.map(\.page) ?? []
            if load { try await preview.load(request) } else { try await preview.update(request) }
            guard revision == previewRevision, snapshot.project == project, !isLeaving, !Task.isCancelled else { return }
            stagedTimelineDucking = nativePreview?.musicDuckingGainsDb.map { gains in
                (projectRevision, TimelineDuckingContour(gains: gains, timing: request.speedTiming))
            }
            previewError = nil
        } catch is CancellationError {} catch {
            guard revision == previewRevision, snapshot.project == project, !isLeaving, !Task.isCancelled else { return }
            preview.close(); isPlaying = false; previewStop = nil
            stagedTimelineDucking = nil
            let message = await app.safeError(error, context: .preview)
            guard revision == previewRevision, snapshot.project == project, !isLeaving, !Task.isCancelled else { return }
            previewError = message
        }
    }
}

@MainActor func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

extension EditorModel {
    /// Where the Find Clips popover opens: the clip bar, at Hook (the menus, ⇧⌘K, ⋯ and Hook
    /// with no AI chosen; impl-plan item 17), or the sidebar's action.
    enum FindClipsAnchor { case clipBar, sidebar }
    static let noClipsMatched = "No clips matched. Try another style or describe what you want."
    /// The chosen clip-finding connector, nil when none is set up.
    var findConnector: ProviderChoice? { app.providers.first { $0.id == app.string("llm.connector") } }
    func requestFindClips(from anchor: FindClipsAnchor) {
        guard capabilities.ai, !words.isEmpty else { return }
        showAISetup = false
        findClipsAnchor = anchor
        showFindClips = true
    }
    /// Hook (impl-plan item 17): one click finds hook clips in the take with the Hooks preset, through the same route,
    /// lease and Suggested results as Find Clips; the popover's own preset and instructions stay as they were. With no AI
    /// chosen it opens the Find Clips popover at the clip bar on Hooks instead, which says how to choose one.
    func runHook() {
        guard capabilities.ai, !words.isEmpty else { return }
        guard findConnector != nil else {
            preset = .hooks
            requestFindClips(from: .clipBar)
            return
        }
        showFindClips = false
        findClips(preset: .hooks, instruction: "")
    }
    /// Retry after a failed run: the same search again, a failed Hook with Hooks, not the popover's style.
    func retryFindClips() {
        findClips(preset: lastFindRequest?.preset, instruction: lastFindRequest?.instruction)
    }

    struct ClaudeDraft {
        let transcript: Transcript
        let request: InlineTranscription.ApprovedRun
        let work: Task<Void, Never>
    }

    private func canSearchClaudeDraft(_ provider: ProviderChoice) -> Bool {
        guard let connector = ConnectorID(rawValue: provider.id), case .inline(let amount) = app.llmSendKind(connector), amount.isEmpty else { return false }
        return (provider.privacy != "thirdPartyCloud" && app.localServerHost(provider) == nil) || app.bool("llm.cloudConsent.\(provider.id)")
    }

    func findClipsOnDraft(_ transcript: Transcript, request: InlineTranscription.ApprovedRun) -> Task<Void, Never>? {
        guard claudeModeWaitsForTranscript, let workTask, let provider = findConnector, canSearchClaudeDraft(provider),
              findTask == nil, !sendConfirmation.isPresented else { return nil }
        findClips(draft: ClaudeDraft(transcript: transcript, request: request, work: workTask))
        return findTask
    }

    /// Asks the chosen connector for clips with `preset` and `instruction`, the popover's when nil. They arrive as
    /// suggestions in one undo step.
    func findClips(preset requestedPreset: ClipPresetID? = nil, instruction requestedInstruction: String? = nil, draft: ClaudeDraft? = nil) {
        if sendConfirmation.isPresented {
            let pending = findTask, session = openRewrite
            sendConfirmation.cancel(); pending?.cancel(); closeRewrite(returnFocus: false)
            findTask = Task { [weak self] in
                await pending?.value; await session?.waitForSend()
                guard !Task.isCancelled else { return }
                self?.findClips(preset: requestedPreset, instruction: requestedInstruction)
            }
            return
        }
        let canStart = draft == nil ? capabilities.ai : capabilities.writable && capabilities.media && !llmRuns.isBusy
        guard canStart, let shared = app.shared, let transcript = draft?.transcript ?? project.transcript, let provider = findConnector else { return }
        let corrections = project.edits.corrections
        let cuts = Set(project.edits.cutWordIds)
        let selectedModel = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        let selectedSignature = rewriteConnectorSignature
        let selectedPreset = requestedPreset ?? preset
        let instructions = requestedInstruction ?? instruction
        let comparisonClock = selectedPreset == .bestTakes ? recordingClock : nil
        let comparison = comparisonClock.flatMap(RecordingProposalContext.init(clock:))
        lastFindRequest = (selectedPreset, instructions)
        let snapshot = project
        do {
            guard self.project == snapshot, self.app.string("llm.connector") == provider.id,
                  self.app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "") == selectedModel,
                  self.rewriteConnectorSignature == selectedSignature,
                  let lease = self.llmRuns.acquire() else { return }
            let runs = self.llmRuns
            let connector: any LLMConnector = cardPlanConnector.map { $0 as any LLMConnector } ?? app.connector(provider.id)
            if claudeMode.findNeedsAction || claudeMode.afterFind != nil {
                claudeMode.cancelFindContinuation()
                if claudeMode.armed, claudeModeOn { claudeMode.phase = .waiting }
            }
            claudeMode.findNeedsAction = false
            self.findTask?.cancel(); self.showAISetup = false
            if draft != nil { claudeMode.clock?.begin(.find) }
            self.findTask = Task { [self] in
                var outcome = ClaudeModeFindOutcome.cancelled
                defer {
                    finding = false
                    runs.release(lease)
                    claudeModeFindEnded(outcome)
                }
                do {
                    // The route comes first (design §6.2: the consent, then "while it runs"); only the lease is held. A
                    // declined send leaves the sidebar, the last error and the fallback note as they were and announces
                    // nothing, and no "Finding clips…" row shows behind a sheet.
                    let authorized = if let cardPlanConnector { cardPlanConnector.isCurrent } else { try await app.authorizeConnectorRequest(provider, connector: connector, action: .findClips,
                        wordCount: transcript.words.filter { $0.kind == .word }.count, rewrite: selectedPreset == .hooks ? DirectorScope(kind: .fullTake, wordCount: transcript.words.filter { $0.kind == .word }.count) : nil, confirmation: sendConfirmation, verb: selectedPreset == .hooks ? "Hook" : nil, isCurrent: { [self] in
                            let current = project == snapshot || (draft?.request.confirmedTranscript != nil && project.transcript == draft?.request.confirmedTranscript)
                            return !isLeaving && current && rewriteConnectorSignature == selectedSignature && (draft == nil || canSearchClaudeDraft(provider))
                        }) }
                    guard authorized else {
                            if let draft { await draft.work.value }
                            if !Task.isCancelled, project == snapshot, rewriteConnectorSignature == selectedSignature { outcome = .needsApproval }
                            else if draft != nil, !Task.isCancelled, capabilities.edit { outcome = .needsApproval }
                            return
                        }
                    finding = true; clipError = nil; fallbackNote = nil
                    onNeedsSidebar?()
                    announce("Finding clips")
                    let catalog = LLMCatalog(document: try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))))
                    let finder = ClipFinder(runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log), shared: shared)
                    let presets = try await finder.presets()
                    guard let preset = presets.first(where: { $0.id == selectedPreset }) else { throw ClipFinderGateError.needInstructions(message: "Choose a clip preset.") }
                    var result = try await finder.find(ClipFinderRequest(transcript: comparisonClock?.transcript ?? transcript, corrections: corrections, cutWordIds: cuts, preset: preset, instruction: instructions, recordings: comparison), connector: connector, model: selectedModel)
                    if let draft {
                        claudeMode.clock?.end(.find)
                        await draft.work.value
                        try Task.checkCancellation()
                        guard claudeModeWaitsForTranscript, let confirmed = draft.request.confirmedTranscript, project.transcript == confirmed,
                              project.edits.corrections == corrections, Set(project.edits.cutWordIds) == cuts,
                              rewriteConnectorSignature == selectedSignature else { return }
                        result = try Self.confirmDraftRanges(result, from: transcript, with: confirmed, preset: preset)
                        if result.clips.isEmpty {
                            guard canSearchClaudeDraft(provider) else { outcome = .needsApproval; return }
                            claudeMode.clock?.begin(.find)
                            result = try await finder.find(ClipFinderRequest(transcript: confirmed, corrections: corrections, cutWordIds: cuts, preset: preset, instruction: instructions), connector: connector, model: selectedModel)
                            guard project.transcript == confirmed, rewriteConnectorSignature == selectedSignature else { return }
                        }
                    }
                    try Task.checkCancellation()
                    let usedFallback = await finder.lastUsedFallback == true && result.model != selectedModel
                    let publishable = draft?.request.confirmedTranscript ?? transcript
                    guard !Task.isCancelled, project.transcript == publishable,
                          comparisonClock == nil || recordingClock == comparisonClock else { return }
                    outcome = .finished
                    guard !result.clips.isEmpty else { clipError = Self.noClipsMatched; return }
                    var next = project
                    let ranges = result.clips.enumerated().map { position, clip in
                        let parts = clip.parts?.enumerated().map { index, part in
                            ClipPart(id: "part-\(index + 1)", startWordId: part.startWordId, endWordId: part.endWordId, takeReason: part.takeReason)
                        }
                        return ClipRange(id: UUID().uuidString.lowercased(), startWordId: clip.startWordId, endWordId: clip.endWordId,
                                         title: clip.title, origin: .ai, aiResultId: result.id, aiClipIndex: position, parts: parts,
                                         kind: selectedPreset == .bestTakes && (parts?.count ?? 0) > 1 ? .story : nil)
                    }
                    if selectedPreset == .bestTakes {
                        for index in result.clips.indices {
                            result.clips[index].parts = result.clips[index].parts?.map {
                                ClipWordRange(startWordId: $0.startWordId, endWordId: $0.endWordId)
                            }
                        }
                    }
                    next.ai.results.append(result)
                    // One undo step: the result arrives as suggestions, not kept clips.
                    guard capabilities.edit, let state = editState() else { return }
                    if history?.state != state { history = EditHistory(state: state) }
                    let before = Set(state.clips.map(\.id))
                    history?.apply(.addAIClips(resultId: result.id, clips: ranges), aiResults: next.ai.results)
                    let added = (history?.state.clips ?? []).filter { !before.contains($0.id) }
                    for clip in added { history?.apply(.setClipSelected(id: clip.id, selected: false), aiResults: next.ai.results) }
                    guard let changed = history?.state, changed != state else { clipError = "These clips are already in the list."; return }
                    next.edits = changed.projectEdits
                    replace(next, name: "Find clips")
                    // The first new suggestion in transcript order is focused, not selected
                    // (design §6.2): the scope, playhead, Export and status summary stay.
                    focusedSuggestion = added.min { (index($0.startWordId) ?? .max) < (index($1.startWordId) ?? .max) }?.id
                    let codexFallback = provider.id == "codex" ? app.codexFallbackMessage(for: selectedModel) : nil
                    fallbackNote = usedFallback ? codexFallback ?? "Answered by \(result.model) because \(selectedModel) was busy." : nil
                    announce([added.count == 1 ? "Found 1 clip." : "Found \(added.count) clips.", fallbackNote].compactMap { $0 }.joined(separator: " "))
                } catch is CancellationError {} catch LLMError.cancelled {} catch VoxClipError.cancelled {} catch {
                    if let draft {
                        claudeMode.clock?.end(.find)
                        await draft.work.value
                        guard project.transcript == draft.request.confirmedTranscript, draft.request.confirmedTranscript != nil else { return }
                    }
                    guard !Task.isCancelled else { return }
                    let message = await app.safeError(error, context: .llm, messageContext: "ai:\(provider.label)")
                    guard !Task.isCancelled else { return }
                    // A connector that is not ready fails in the route, before the run revealed the sidebar.
                    if !message.isEmpty { clipError = message; fallbackNote = nil; onNeedsSidebar?() }
                    outcome = .failed(error, connectorSignature: selectedSignature)
                }
            }
        }
    }

    private nonisolated static func confirmDraftRanges(_ result: ProjectAIResult, from draft: Transcript, with confirmed: Transcript,
                                                       preset: ClipPreset) throws -> ProjectAIResult {
        var updated = result
        updated.language = confirmed.language
        if let firstLanguage = draft.language, let finalLanguage = confirmed.language,
           SpeechText.primaryLanguage(firstLanguage) != SpeechText.primaryLanguage(finalLanguage) {
            updated.clips = []
            return updated
        }
        let draftByID = Dictionary(draft.words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spoken = confirmed.words.indices.filter { confirmed.words[$0].kind == .word }
        func boundary(_ time: Double, at edge: KeyPath<TimedWord, Double>) -> Int? {
            guard let nearest = spoken.min(by: { abs(confirmed.words[$0][keyPath: edge] - time) < abs(confirmed.words[$1][keyPath: edge] - time) }),
                  abs(confirmed.words[nearest][keyPath: edge] - time) <= 1 else { return nil }
            return nearest
        }
        let candidates: [ClipCandidate] = result.clips.compactMap { clip in
            let parts = (clip.parts ?? [.init(startWordId: clip.startWordId, endWordId: clip.endWordId)]).compactMap { part -> ClipCandidatePart? in
                guard let first = draftByID[part.startWordId], let last = draftByID[part.endWordId],
                      let start = boundary(first.start, at: \.start), let end = boundary(last.end, at: \.end), start <= end else { return nil }
                return .init(startWord: Double(start), endWord: Double(end))
            }
            guard let first = parts.first else { return nil }
            let title = confirmed.words[Int(first.startWord)...Int(first.endWord)].lazy.filter { $0.kind == .word }.prefix(6).map(\.text).joined(separator: " ")
            return ClipCandidate(title: title, reason: "Suggested moment", score: Double(clip.score), parts: parts, notInTake: clip.notInTake)
        }
        let validated = try finalizeClips(candidates, words: confirmed.words, preset: preset, lines: [], options: FinalizeClipsOptions(snap: false))
        updated.clips = validated.map { ProjectAIClip(title: $0.title, reason: $0.reason, score: $0.score,
                                                       startWordId: confirmed.words[$0.startWord].id, endWordId: confirmed.words[$0.endWord].id,
                                                       parts: $0.parts?.map { .init(startWordId: confirmed.words[$0.lowerBound].id, endWordId: confirmed.words[$0.upperBound].id) }, notInTake: $0.notInTake) }
        return updated
    }
}

/// A clip's answer to "How should it sound?": `whole` for the whole clip, false for the changed phrases, and the Rewrite
/// proposal (`RewriteSession.proposalID`) it answered.
struct WholeClipPick: Equatable {
    var whole: Bool
    var proposal: UUID?
}
