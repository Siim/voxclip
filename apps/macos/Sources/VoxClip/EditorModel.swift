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
    /// Each clip's answer to "How should it sound?" this session: true for the whole clip, false for the changed phrases.
    var wholeClipPicks: [String: Bool] = [:]
    var selectedWordIDs: Set<String> = [] {
        didSet {
            guard selectedWordIDs != oldValue else { return }
            rewriteOpenTask?.cancel()
            // Changing the selection ends an open inline correction, as a click elsewhere ends an inline rename.
            if correctionID != nil { endCorrection() }
            updateSelectionEnds(); refreshPendingSendScope()
        }
    }
    var selectedPauseIDs: Set<String> = [] { didSet { if selectedPauseIDs != oldValue { rewriteOpenTask?.cancel(); updateSelectionEnds(); refreshPendingSendScope() } } }
    var previewStop: Double?
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
    var timelineSnapping = true
    /// The selection's first and last word or pause in reading order (a pause follows the
    /// word before it), one id when they are the same. A fold opens while one of them is in
    /// it (`openFoldEnds`), so what is selected always shows.
    private(set) var selectionEnds: [String] = []
    var findVisible = false
    var query = ""
    var textSize = DesignValues.transcriptTextSize
    var error: String?
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
        let replacingPendingSend = sendConfirmation.isPresented
        guard let scope = requested ?? rewriteScopeNow, RewriteEntryPolicy.canRun(editable: capabilities.edit && (capabilities.ai || replacingPendingSend), scope: scope) else { return }
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
            closeRewrite(returnFocus: false)
            openRewriteSession(scope: scope, instruction: instruction)
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
    private func cancelRewriteOpen() { rewriteOpenToken = nil; rewriteOpenTask?.cancel() }
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
    func sendRewriteAgain(_ session: RewriteSession, instruction: String? = nil, feedback: String? = nil) {
        session.stopWordingFit(refresh: false)
        guard session.isOpen, !session.isProposing else { return }
        cancelRewriteOpen()
        let count = session.proposalCount
        guard count > 0, session.hasPaidTakes || session.hasEditedChanges else {
            sendAgain(session, instruction: instruction, feedback: feedback)
            return
        }
        session.confirmDiscardChanges { [weak self, weak session] in
            guard let self, let session else { return }
            sendAgain(session, instruction: instruction, feedback: feedback)
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
            RewriteConnector(connector: app.connector(provider.id), model: app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? ""),
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
    func restartRewrite(_ session: RewriteSession) {
        guard openRewrite === session, session.isOpen else { return }
        guard RewriteEntryPolicy.canRun(editable: capabilities.ai, scope: session.rewriteScope) else {
            closeRewrite(returnFocus: false)
            rewriteNotice = Self.rewriteUnavailableNotice
            announce(Self.rewriteUnavailableNotice)
            return
        }
        let scope = session.rewriteScope, instruction = session.instruction
        closeRewrite(returnFocus: false)
        openRewriteSession(scope: scope, instruction: instruction)
    }
    var rewriteConnectorSignature: [String] {
        let id = app.string("llm.connector")
        return [id, app.string("llm.model.\(id)"), app.string("llm.baseUrl.\(id)"), app.string("llm.cliPath.\(id)")]
    }
    func closeRewrite(returnFocus: Bool = true) {
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
        if !exporting && (!exportJob.isOpen || clipIDs != nil || exportJob.requestedIDs != requestedIDs) {
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
        guard !exporting else { return }
        exportJob.draft.commit(model: self)
        exportJob.isOpen = false
        onFinishExport?()
    }
    var exportIndex = 0
    /// Renders in the export under way: targets × aspects (nil before the first).
    var exportTotal: Int?
    var exportStartedAt: Date?
    var sourceURL: URL { URL(fileURLWithPath: project.media.source.absolutePath) }
    var mediaResolved = false { didSet { document.setMediaResolved(mediaResolved); if !mediaResolved { transcription.close(); sendConfirmation.cancel(); closeRewrite(returnFocus: false) }; followWaveformKey() } }
    /// The video's check (as the project opens or reverts, or after its video changes) has answered, found or not. A
    /// video not resolved before then is only not checked yet, so Locate… and the read-only note wait for the answer
    /// rather than flash while a slow or external volume reads.
    private(set) var mediaChecked = false
    /// The latest check, so one that a newer check replaced doesn't answer for it.
    @ObservationIgnored private var mediaCheck = 0
    /// The video's check answered without finding it: Locate… shows and the editor only reads.
    var mediaMissing: Bool { mediaChecked && !mediaResolved }
    /// The project has a transcript. Unlike `project`, views observe it, so a transcript
    /// that arrives or is undone redraws the transcript column.
    private(set) var transcribed = false
    /// Bumped by every refresh that finds the project changed. Views that derive what they
    /// show from `project`, which they can't observe, read it (the toolbar's Export).
    @ObservationIgnored let exportsFingerprintCache = ExportsFingerprintCache()
    private(set) var projectRevision = 0
    /// The video is there but can't be read (design §5.4.4 f, corrupt file).
    var mediaUnreadable = false { didSet { if mediaUnreadable { transcription.close(); sendConfirmation.cancel(); closeRewrite(returnFocus: false) }; followWaveformKey() } }
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
    var editingAvailable = false
    var waveform: WaveformData?
    var waveformKey: WaveformCache.Key? {
        guard !document.demo, mediaResolved, !mediaUnreadable, project.media.source.audio != nil else { return nil }
        return WaveformCache.Key(contentKey: project.media.source.contentKey, source: sourceURL, cache: app.locations.cache)
    }
    /// The load `followWaveformKey` started for `requestedWaveformKey`, until it ends.
    @ObservationIgnored private(set) var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var requestedWaveformKey: WaveformCache.Key?
    #if DEBUG
    @ObservationIgnored var beforeWaveformLoad: @MainActor () async -> Void = {}
    #endif
    func loadWaveform() async {
        let key = waveformKey
        #if DEBUG
        await beforeWaveformLoad()
        #endif
        let value = if let key { await WaveformCache.shared.load(key) } else { nil as WaveformData? }
        guard !Task.isCancelled, key == waveformKey else { return }
        waveform = value
    }
    /// Loads the waveform when the project's media is there to read, and again when it
    /// changes (impl-plan §3.1): the model owns it, so a hidden timeline never starves the
    /// audiogram stand-in or Rewrite.
    func followWaveformKey() {
        let key = waveformKey
        guard key != requestedWaveformKey else { return }
        requestedWaveformKey = key
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
    @ObservationIgnored var workTask: Task<Void, Never>?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored var findTask: Task<Void, Never>?
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
    /// change a project that is leaving.
    var isLeaving = false { didSet { if isLeaving { app.voiceLabSession.leaveVoiceControls(owner: self); contextDemoSession?.close(); contextDemoSession = nil; motionCueEditing = nil; voiceChange?.cancel(); if voiceChange?.close() == true { voiceChange = nil }; transcription.close(); sendConfirmation.cancel(); closeRewrite(returnFocus: false) } } }
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
    var words: [TimedWord] { project.transcript?.words ?? [] }
    var activeClip: ClipRange? { project.edits.clips.first { $0.id == project.edits.activeClipId } }
    var sortedClips: [ClipRange] {
        project.edits.clips.enumerated().sorted {
            let first = index($0.element.startWordId) ?? 0, second = index($1.element.startWordId) ?? 0
            return first == second ? $0.offset < $1.offset : first < second
        }.map(\.element)
    }
    var selectedIDs: [String] { words.filter { selectedWordIDs.contains($0.id) }.map(\.id) }
    var sourceDuration: Double { project.media.source.durationSeconds }
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
        let span = scopeBounds.flatMap { try? clipTimes(words, startIndex: $0.lowerBound, endIndex: $0.upperBound) }
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
                    if let stop = previewStop, source >= stop { preview.pause(); previewStop = nil }
                case .playing(let playing): isPlaying = playing
                case .failed(let error, let reason):
                    if let reason { await previewFailed(reason) } else { previewError = await app.safeError(error) }
                case .frame: break
                }
            }
        }
        if !document.demo && sourceURL.path != "/" {
            do {
                let url = try await resolveMediaIdentity()
                var changed = project
                let probe = try await AVMediaProbe().probe(url)
                if document.fileURL == nil {
                    changed.media.source.durationSeconds = probe.durationSeconds
                    changed.media.source.video = probe.video; changed.media.source.audio = probe.audio
                    document.replaceProject(changed)
                }
            } catch {
                // The file resolved but its probe failed: it is there and can't be read.
                mediaUnreadable = mediaResolved
                previewError = await app.safeError(error)
            }
        }
        // The check has answered (a project without a video path has none to make).
        mediaChecked = true
        refresh()
        if mediaUsable { await updatePreview(load: true); await transcription.openOnImport() }
    }
    func close() {
        motionCueEditing = nil
        app.voiceLabSession.leaveVoiceControls(owner: self)
        contextDemoSession?.close(); contextDemoSession = nil
        voiceChange?.cancel(); if voiceChange?.close() == true { voiceChange = nil }
        voiceRewriteToastTask?.cancel()
        cancelMediaRelink()
        transcription.close()
        sendConfirmation.cancel()
        closeRewrite(returnFocus: false)
        previewRevision &+= 1
        workTask?.cancel(); exportTask?.cancel(); findTask?.cancel(); eventTask?.cancel(); updateTask?.cancel(); waveformTask?.cancel(); preview.close()
        app.openProjectKeys[project.id] = nil
        cacheLeaseEnded = true
        cacheLease?.release(); cacheLease = nil
    }
    func reloadFromDocument(previousProjectID: String) {
        motionCueEditing = nil
        app.voiceLabSession.leaveVoiceControls(owner: self)
        contextDemoSession?.close(); contextDemoSession = nil
        voiceChange?.cancel(); if voiceChange?.close() == true { voiceChange = nil }
        cancelMediaRelink()
        sendConfirmation.cancel()
        transcription.close()
        closeRewrite(returnFocus: false)
        app.openProjectKeys[previousProjectID] = nil
        // The project stays open while its video is checked again, even if it is missing (architecture §8.2).
        holdCacheEntry()
        workTask?.cancel(); exportTask?.cancel(); findTask?.cancel(); updateTask?.cancel()
        preview.pause(); isPlaying = false; previewStop = nil
        history = nil
        renderedTranscript = nil; renderedEdits = nil; renderedMedia = nil; renderedVoiceLab = nil
        planningSegments = nil; planningWordIndex = [:]; summaryCache.removeAll()
        correctionID = nil; selectedWordIDs = []; selectedPauseIDs = []
        fallbackNote = nil; focusedSuggestion = nil; clipError = nil; error = nil; previewError = nil
        mediaResolved = document.demo; mediaChecked = false
        refresh()
        updateTask = Task { [weak self] in
            guard let self else { return }
            guard sourceURL.path != "/" else { mediaChecked = true; return }
            do {
                _ = try await resolveMediaIdentity()
                await updatePreview(load: true)
            } catch is CancellationError {} catch { previewError = await app.safeError(error) }
        }
    }
    func editState() -> EditState? {
        let project = project
        guard let transcript = project.transcript else { return nil }
        let edits = project.edits
        return EditState(transcript: transcript, pauses: pauses, pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds, cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections, clips: edits.clips, activeClipId: edits.activeClipId)
    }
    func refresh() {
        let project = project
        let words = project.transcript?.words ?? []
        let edits = project.edits
        let transcriptChanged = renderedTranscript != project.transcript
        let editChanged = renderedEdits != edits
        guard transcriptChanged || editChanged || renderedMedia != project.media || renderedVoiceLab != project.voiceLab || renderedContextDemo != project.contextDemo || renderedMotionCues != project.motionCues || renderedMusic != project.music || renderedClipControls != project.clipControls || renderedEdits == nil else { return }
        let clipsChanged = renderedEdits?.clips != edits.clips
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
            pauses = (try? detectPauses(words, thresholdSeconds: edits.pauseThresholdSeconds)) ?? []
            pauseByAfterIndex = Dictionary(uniqueKeysWithValues: pauses.map { ($0.afterIndex, $0) })
            pauseIndex = Dictionary(uniqueKeysWithValues: pauses.map { ($0.id, $0) })
        }
        cutWordIDs = Set(edits.cutWordIds); cutPauseIDs = Set(edits.cutPauseIds)
        let activeClip = edits.clips.first { $0.id == edits.activeClipId }
        if let clip = activeClip, let lower = index(clip.startWordId), let upper = index(clip.endWordId), lower <= upper { scopeBounds = lower...upper }
        else { scopeBounds = nil }
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
                if !transcriptChanged, activeClip == nil, comparable == renderedEdits, var cached = planningSegments {
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
                plan = try buildEditPlan(segments, duration: sourceDuration, sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: edits.pauseKeepSeconds)
            } else { planningSegments = nil; planningWordIndex = [:]; plan = Self.uncutPlan(duration: sourceDuration) }
        } catch {
            plan = nil; voiceLabPlan = nil
            previewError = UserMessages.message(error)
        }
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
    func replace(_ newProject: Project, name: String, restoringSnapshot: Bool = false) {
        // A Versions-browser version is read-only.
        guard capabilities.writable, capabilities.media || name == "Locate media" || onlyCaptionPositionChanged(newProject) else { return }
        // The title follows the document's name, not the edit history (design §2), so
        // undoing an edit made before a Save As or Rename keeps the new title.
        var newProject = newProject
        newProject.title = project.title
        // Undo and Redo never switch tabs (impl-plan §3.3): a restored snapshot keeps the
        // current scope while it still has that clip, else Full Take.
        if restoringSnapshot { newProject.edits.activeClipId = scopeKept(in: newProject) }
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
            undoManager?.registerUndo(withTarget: self) { model in model.replace(previous, name: name, restoringSnapshot: true) }
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
        recordDocumentChange()
        error = nil
        refresh()
        schedulePreviewUpdate(mediaChanged: mediaChanged)
    }
    /// Updates the preview a moment after a project change, after checking a changed video first.
    func schedulePreviewUpdate(mediaChanged: Bool) {
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
            } catch is CancellationError {} catch { previewError = await app.safeError(error) }
        }
    }
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
            if mediaRelinkCandidate != nil {
                transcription.close(); sendConfirmation.cancel(); closeRewrite(returnFocus: false)
            }
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
            catch { if revision == mediaRelinkRevision { previewError = await app.safeError(error) } }
        }
    }
    func prepareMediaRelink(url: URL, probe: MediaProbeResult) async {
        cancelMediaRelink()
        previewError = nil
        let revision = mediaRelinkRevision, base = project
        guard !isLeaving, !cacheLeaseEnded else { return }
        do {
            let next: Project
            do { next = try await app.projectStore.relink(base, to: url, probe: probe) }
            catch VoxClipError.mediaMissing(_) {
                guard probe.durationSeconds.isFinite, abs(probe.durationSeconds - base.media.source.durationSeconds) <= 0.05 else {
                    previewError = "This file's duration differs by more than 0.05 seconds. Choose another file. Edits are saved."
                    return
                }
                guard revision == mediaRelinkRevision, base == project, !isLeaving, !cacheLeaseEnded else { return }
                mediaRelinkCandidate = MediaRelinkCandidate(url: url, probe: probe)
                announce("This file looks different. Use it anyway? \(url.lastPathComponent)")
                return
            }
            guard revision == mediaRelinkRevision, base == project, !isLeaving, !cacheLeaseEnded else { return }
            await applyMediaRelink(next)
        } catch { previewError = await app.safeError(error) }
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
            if revision == mediaRelinkRevision { previewError = await app.safeError(error) }
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
        if case .removeClip(let id) = command { next.motionCues.removeAll { $0.clipID == id }; next.music.removeAll { $0.clipId == id }; next.clipControls.removeAll { $0.clipId == id }; next.captionTranslations.removeAll { $0.clipId == id } }
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
        guard let start = selectedIDs.first, let end = selectedIDs.last else { return }
        if let existing = project.edits.clips.first(where: { $0.startWordId == start && $0.endWordId == end }) {
            let message = clipNumber(existing.id).map { "Clip \($0) already covers these words." } ?? "A clip already covers these words."
            if activeClip?.id == existing.id { announce(message) } else { activate(existing, announcing: message) }
            return
        }
        let title = EditingAlgorithms.clipTitle(words.lazy.filter { self.selectedWordIDs.contains($0.id) }.map { self.text($0) })
        let clip = ClipRange(id: UUID().uuidString.lowercased(), startWordId: start, endWordId: end, title: title)
        guard apply([.addClip(clip), .setActiveClip(clipId: clip.id)], name: "Make clip from selection") else { return }
        announce(clipNumber(clip.id).map { "Clip \($0) made." } ?? "Clip made.")
    }
    func nudge(_ clip: ClipRange, start: Bool, offset: Int) {
        guard let lower = index(clip.startWordId), let upper = index(clip.endWordId) else { return }
        apply(.updateClip(id: clip.id, startIndex: start ? min(upper, max(0, lower + offset)) : lower, endIndex: start ? upper : max(lower, min(words.count - 1, upper + offset))), name: "Nudge clip edge")
    }
    func setClipEdge(start: Bool) {
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
        if let clip = activeClip, let word = words.first(where: { $0.id == clip.startWordId }) { seek(source: word.start) }
    }
    func moveClip(_ direction: Int) {
        guard !sortedClips.isEmpty else { return }
        let position = sortedClips.firstIndex { $0.id == activeClip?.id } ?? (direction > 0 ? -1 : sortedClips.count)
        activate(sortedClips[min(sortedClips.count - 1, max(0, position + direction))])
    }
    func removeClip(_ id: String) {
        rowAction([.removeClip(id: id)] + focusNext(after: id), name: "Remove clip", announcing: clipNumber(id).map { "Clip \($0) removed." } ?? "Clip removed.")
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
    func dismiss(_ id: String) { rowAction([.removeClip(id: id)] + focusNext(after: id), name: "Dismiss suggestion", announcing: "Suggestion dismissed.") }
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
        guard let state = editState(), let segments = try? buildSegments(state, activeClip: clip),
              let plan = try? buildEditPlan(segments, duration: sourceDuration, sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: state.pauseKeepSeconds)
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
        let lower = clip.flatMap { index($0.startWordId) } ?? 0, upper = clip.flatMap { index($0.endWordId) } ?? words.count - 1
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
    func seek(source: Double) {
        guard let renderTimeline else { return }
        let time = renderTimeline.mapTime(source)
        Task { [weak self] in
            guard let self else { return }
            do { try await preview.seek(to: time, exact: true); playhead = time; sourceTime = source }
            catch { previewError = await app.safeError(error) }
        }
    }
    func transport(_ key: String, shift: Bool = false) {
        if [" ", "l", "p"].contains(key.lowercased()) { rewrite?.takePlan?.stopAudition() }
        // Saving an open correction pauses (`apply`), so Space and L toggle from the state before the save.
        let wasPlaying = isPlaying
        endCorrection()
        switch key.lowercased() {
        case " ":
            if shift, let word = words.first(where: { selectedWordIDs.contains($0.id) }) { seek(source: word.start) }
            if wasPlaying { preview.pause() } else { preview.play() }
            isPlaying = preview.isPlaying
        case "j": seek(source: max(0, sourceTime - 3))
        case "k": preview.pause(); isPlaying = false; playbackRate = 1; previewStop = nil
        case "l": playbackRate = wasPlaying ? (playbackRate == 1 ? 1.5 : 2) : 1; preview.play(); nativePreview?.player.rate = playbackRate; isPlaying = preview.isPlaying
        case "p": if let word = words.first(where: { selectedWordIDs.contains($0.id) }), let last = words.last(where: { selectedWordIDs.contains($0.id) }) { previewStop = min(sourceDuration, last.end + 2); seek(source: max(0, word.start - 2)); preview.play(); isPlaying = preview.isPlaying }
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
    func renderRequest(target: ExportTarget? = nil, snapshot: EditorRenderSnapshot? = nil, labelPosition: VoiceLabLabelPosition? = nil) async throws -> RenderRequest {
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
        if target != nil || voiceLab != nil, let state, let segments {
            plan = try buildEditPlan(segments, duration: project.media.source.durationSeconds, sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), pauseKeepSeconds: state.pauseKeepSeconds)
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
        if target == nil, snapshot.project != self.project || isLeaving { throw CancellationError() }
        let request = RenderRequest(sourceURL: URL(fileURLWithPath: project.media.source.absolutePath), plan: plan, captions: layout?.track ?? CaptionTrack(),
            output: output, forPreview: target == nil, captionLayout: layout, voiceLab: voiceLab)
        return try RenderCallerInputs.prepare(request, project: project, clipID: clip?.id, dataRoot: app.locations.root,
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
            previewError = nil
        } catch is CancellationError {} catch {
            guard revision == previewRevision, snapshot.project == project, !isLeaving, !Task.isCancelled else { return }
            preview.close(); isPlaying = false; previewStop = nil
            let message = await app.safeError(error)
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
    /// Asks the chosen connector for clips with `preset` and `instruction`, the popover's when nil. They arrive as
    /// suggestions in one undo step.
    func findClips(preset requestedPreset: ClipPresetID? = nil, instruction requestedInstruction: String? = nil) {
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
        guard capabilities.ai, let shared = app.shared, let transcript = project.transcript, let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) else { return }
        let corrections = project.edits.corrections
        let cuts = Set(project.edits.cutWordIds)
        let selectedModel = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        let selectedSignature = rewriteConnectorSignature
        let selectedPreset = requestedPreset ?? preset
        let instructions = requestedInstruction ?? instruction
        lastFindRequest = (selectedPreset, instructions)
        let snapshot = project
        do {
            guard self.capabilities.ai, self.project == snapshot, self.app.string("llm.connector") == provider.id,
                  self.app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "") == selectedModel,
                  self.rewriteConnectorSignature == selectedSignature,
                  let lease = self.llmRuns.acquire() else { return }
            let runs = self.llmRuns
            let connector = self.app.connector(provider.id)
            self.findTask?.cancel(); self.showAISetup = false
            self.findTask = Task { [self] in
                defer { self.finding = false; runs.release(lease) }
                do {
                    // The route comes first (design §6.2: the consent, then "while it runs"); only the lease is held. A
                    // declined send leaves the sidebar, the last error and the fallback note as they were and announces
                    // nothing, and no "Finding clips…" row shows behind a sheet.
                    guard try await app.authorizeConnectorRequest(provider, connector: connector, action: .findClips,
                        wordCount: transcript.words.filter { $0.kind == .word }.count, rewrite: selectedPreset == .hooks ? DirectorScope(kind: .fullTake, wordCount: transcript.words.filter { $0.kind == .word }.count) : nil, confirmation: sendConfirmation, verb: selectedPreset == .hooks ? "Hook" : nil, isCurrent: { [self] in
                            !isLeaving && project == snapshot && rewriteConnectorSignature == selectedSignature
                        }) else { return }
                    finding = true; clipError = nil; fallbackNote = nil
                    onNeedsSidebar?()
                    announce("Finding clips")
                    let catalog = LLMCatalog(document: try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: shared.root.appendingPathComponent("catalog/llm-providers.json"))))
                    let finder = ClipFinder(runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log), shared: shared)
                    let presets = try await finder.presets()
                    guard let preset = presets.first(where: { $0.id == selectedPreset }) else { throw ClipFinderGateError.needInstructions(message: "Choose a clip preset.") }
                    let result = try await finder.find(ClipFinderRequest(transcript: transcript, corrections: corrections, cutWordIds: cuts, preset: preset, instruction: instructions, snap: app.bool("llm.clips.snapToLines", fallback: true)), connector: connector, model: selectedModel)
                    try Task.checkCancellation()
                    let usedFallback = await finder.lastUsedFallback == true && result.model != selectedModel
                    guard project.transcript == transcript else { return }
                    guard !result.clips.isEmpty else { clipError = Self.noClipsMatched; claudeModeFindEnded(); return }
                    var next = project
                    next.ai.results.append(result)
                    let ranges = result.clips.enumerated().map { position, clip in ClipRange(id: UUID().uuidString.lowercased(), startWordId: clip.startWordId, endWordId: clip.endWordId, title: clip.title, origin: .ai, aiResultId: result.id, aiClipIndex: position) }
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
                    fallbackNote = usedFallback ? "Answered by \(result.model) because \(selectedModel) was busy." : nil
                    announce([added.count == 1 ? "Found 1 clip." : "Found \(added.count) clips.", fallbackNote].compactMap { $0 }.joined(separator: " "))
                    // Claude mode on a newly opened video goes straight on (ClaudeMode.swift).
                    claudeModeFindEnded()
                } catch is CancellationError { claudeModeFindEnded() } catch LLMError.cancelled { claudeModeFindEnded() } catch VoxClipError.cancelled { claudeModeFindEnded() } catch {
                    let message = await app.safeError(error, context: "ai:\(provider.label)")
                    // A connector that is not ready fails in the route, before the run revealed the sidebar.
                    if !message.isEmpty { clipError = message; fallbackNote = nil; onNeedsSidebar?() }
                    claudeModeFindEnded()
                }
            }
        }
    }
}
