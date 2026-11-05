import AppKit
import Observation
import VoxClipCore
import VoxClipMedia

/// Text Rewrite's entry rule (design.md §6.3.6 and §8, impl-plan V13): an editable project with AI and a scope, from the
/// menu, ⇧⌘R, the selection bar, the transcript's context menu and the clip bar alike. Voice Lab gates only Rewrite's voice
/// parts (phrases in your voice, making your voice, takes), and Insert Words, which waits for Core to place an insertion,
/// is never offered. Text Rewrite ships in Release (lead decision on item 26, V15); its voice parts stay behind the
/// Voice Lab setting and its beta notice (`AppModel.voiceLabRewriteEnabled`).
enum RewriteEntryPolicy {
    static func canRun(editable: Bool, scope: RewriteScope?) -> Bool { editable && scope != nil }
}

struct RewriteConnector {
    let connector: any LLMConnector
    let model: String
    let name: String
    let group: String
    let plan: String
}

@MainActor final class ConnectorConsentWait {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var operation: Task<Void, Never>?
    func confirm(_ consent: @escaping @MainActor () async -> Bool) async -> Bool {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                operation = Task { [weak self] in
                    let approved = await consent()
                    self?.finish(approved)
                }
            }
        } onCancel: {
            Task { @MainActor [self] in
                operation?.cancel(); operation = nil; finish(false)
            }
        }
    }
    private func finish(_ approved: Bool) {
        let pending = continuation
        continuation = nil; operation = nil
        pending?.resume(returning: approved)
    }
}

/// One change of a proposal, in transcript order: C2's hunk for a clip or Full take (`ScopeRewriteDiff.Hunk`), or the
/// passage diff's for a selection, as the AI's reply made it. The reply becomes the transcript's proposal
/// (`EditorModel.proposal`), which the hunks (V14) and the change list (V15) review.
struct RewriteChange: Equatable, Sendable {
    var hunk: VoiceLabDiffHunk
    /// An insertion's place in a clip or Full take: the item it follows, nil before the scope's first item, for a change
    /// with source items, and for a selection's insertions.
    var insertionAfterItemID: String? = nil
    /// It adds something the speaker didn't say (voice-lab.md §8.1).
    var checkThis = false
    /// The `[a-b]` lines a clip or Full take edit comes from, with the AI's reason for each; empty for a selection.
    var lines: [String] = []
    var reasons: [String] = []
}

/// One Rewrite of a scope (design.md §6.3, impl-plan V13, plan M7): a clip, kept or suggested, Full take, or a word
/// selection. It runs as it opens, so the panel shows R1 at once: a clip or Full take goes through C1's `ScopeRewritePlan`
/// and `PatchRewriteService`, and its reply through C2's `ScopeRewriteDiff`; a selection through `VoiceRewriteService`
/// and the passage diff. Both end in `changes` and the task's `ChangeSet`. The session belongs to the tab it opened on.
@MainActor @Observable final class RewriteSession {
    var sendApproved = false
    /// Injectable system URL boundary; clicking recovery never launches a CLI or changes permissions.
    var openSettingsURL: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    var sendFailure: LLMError?
    #if DEBUG
    @ObservationIgnored var beforeFailurePresentation: @MainActor () async -> Void = {}
    #endif
    func waitForSend() async { _ = await sending?.value }
    let editor: EditorModel
    /// What the session rewrites (C1's `RewriteScope`).
    let rewriteScope: RewriteScope
    /// The project the session reads, scoped to its tab. An edit outside the scope moves it on (`follow`) and a run reads
    /// the editor's again; in R3 it keeps the proposal's, so an undo back to it shows the proposal again.
    private(set) var project: Project
    /// The take as the user reads it: corrections applied to words.
    private(set) var transcript: [TimedWord]
    var pricedAnyway: Set<Int> = []
    var shorterFeedback: String?
    let wordingFit = RewriteWordingFitState()
    /// A next step's re-ask in flight, its AI suggestions and the advisory voice budget (RewriteNextSteps.swift).
    let reasking = RewriteReaskState()
    /// The automatic fixes of stuck phrases after an approved price (RewriteAutoFix.swift).
    let autoFix = RewriteAutoFixState()
    var calibratedTakeIDs: Set<UUID> = []
    /// The takes footer's Apply with every phrase kept as recorded: no take could be used, so nothing asks to discard.
    @ObservationIgnored var applyingTextFixesOnly = false
    /// The scope's items in order: the selection's, a clip's from its first to its last word, or the take's.
    private(set) var source: [TimedWord]
    /// Where voice changes are placed (`VoiceLabWindowPlanner`): the clip of a clip, or of a selection inside the tab's
    /// clip; else the take.
    let scope: VoiceLabOutputScope
    let envelope: AudioEnvelope?
    let connector: RewriteConnector?
    let prices: VoiceLabPriceCatalog?
    let synthesisModel: String?
    private(set) var isOpen = true
    private(set) var isProposing = false
    /// What the run asks, as the Ask field had it; empty asks Fix mistakes (`RewriteSuggestions.suggestion(for:)`).
    private(set) var instruction: String
    private(set) var problem = ""
    private(set) var readiness: ConnectorStatus?
    /// The proposal's changes, in transcript order; empty before a reply.
    private(set) var changes: [RewriteChange] = []
    private(set) var review: RewriteReview?
    private(set) var revision = 0
    private(set) var generation: RewriteGenerationSession?
    var takePlan: ClipTakePlan?
    var speechContextOffer: RewriteSpeechContextReview?
    private var requestedSurroundingSentenceOrdinal: Int?
    var surroundingSentenceOrdinal: Int? {
        get {
            guard let ordinal = requestedSurroundingSentenceOrdinal else { return nil }
            guard reviewedVoiceOrdinals.contains(ordinal) else {
                requestedSurroundingSentenceOrdinal = nil
                return nil
            }
            return ordinal
        }
        set { requestedSurroundingSentenceOrdinal = newValue }
    }
    var speechContextReview: RewriteSpeechContextReview?
    var acceptedSpeechContext: RewriteSpeechContextReview?
    var speechContextProblem = ""
    /// The phrases a refused surrounding sentence was for: their next steps show with `speechContextProblem`.
    var speechContextRefusedOrdinals: [Int] = []
    /// Why the last takes plan could not be made or used (`ClipTakePlan.Failure` and the rest): its next steps, and the
    /// footer's blocker, show until the inputs change or a fresh plan is made.
    var takePlanFailure: (any Error)?
    var takeQuotePhrase: Int?
    var focusedTakePhrase = 0
    var takeRowsShown = true
    /// The phrase whose My words field shows: one free-text field at a time (PhraseOwnWords.swift).
    var ownWordsEditing: Int?
    let ownWordsAdvice = OwnWordsAdvice()
    /// Say it myself's recorder, one phrase at a time (MicrophoneTake.swift).
    let phraseMicrophone = PhraseMicrophoneTake()
    @ObservationIgnored var takeStorage: VoiceLabTakeStorage?
    @ObservationIgnored var takeBackend: ((Int, @escaping VoiceLabTakeDispatchBoundary) -> ClipTakePlan.Backend)?
    @ObservationIgnored var takePlanOrdinals: [Int] = []
    @ObservationIgnored var takeRegion: ElevenLabsRegion?
    /// The Director task the Rewrite job shows (impl-plan V12m); the session drives it.
    let task: DirectorTask
    /// The AIs R0 lists, once detected.
    var choices: [ConnectorChoice] = []
    /// The work a panel action started (detection, a run, Try Again); closing the session cancels it.
    @ObservationIgnored var actionTask: Task<Void, Never>?
    func configureGeneration(client: ElevenLabsVoiceLab, store: VoiceConsentStore, speaker: VoiceSpeakerCheck) {
        takePlan?.invalidate(); takePlan = nil
        generation?.invalidate()
        let region = client.region
        takeRegion = region
        let model: EditorModel = editor
        let dataRoot: URL = model.app.locations.root
        let paidRoot: URL = dataRoot.appendingPathComponent("VoiceLab", isDirectory: true)
        let scratchRoot: URL = dataRoot.appendingPathComponent("VoiceLabScratch", isDirectory: true)
        let storage = VoiceLabTakeStorage(projectId: model.project.id,
            paidRoot: paidRoot, scratchRoot: scratchRoot)
        takeStorage = storage
        if phraseMicrophone.transcriber == nil {
            let engine = model.project.transcript?.engine
            let whisper = engine?.id == .whispercpp ? engine?.modelId.flatMap { id in model.app.shared.map { (BundledModelCatalog(shared: $0), id) } } : nil
            phraseMicrophone.transcriber = OnDeviceTakeTranscriber(locations: model.app.locations, whisper: whisper)
        }
        // §8.5 timing recovery's free fallback: an on-device transcriber already installed, never a download.
        let localTiming = VoiceLabLocalTimingSource.onDevice(locations: model.app.locations,
            scratch: scratchRoot.appendingPathComponent("timing", isDirectory: true))
        let run = VoiceLabTakeRun(client: client, store: store, speaker: speaker, storage: storage, dispatchIfCurrent: { [weak self] _, start in
            guard let generation = await self?.generation else { throw VoiceLabError.consentRequired }
            try await generation.dispatchWithCurrentCost(start)
        }, localTiming: localTiming) { [weak self] in
            await self?.generationIsCurrent(region: region) ?? false
        }
        generation = RewriteGenerationSession(run: run) { [weak self] in self?.generationIsCurrent(region: region) ?? false }
        generation?.fixedModelID = VoiceLabWordingFit.modelID
        generation?.onFailure = { [weak self] error in self?.logFailure(error, stage: "generation") }
        generation?.prepareDurationRender = durationRenderPreparer()
        takeBackend = { [weak self] count, dispatch in
            let runs = (0..<count).map { _ in
                VoiceLabTakeRun(client: client, store: store, speaker: speaker, storage: storage, dispatchIfCurrent: dispatch,
                                localTiming: localTiming) { [weak self] in
                    await self?.generationIsCurrent(region: region) ?? false
                }
            }
            return ClipTakePlan.Backend(runs: runs)
        }
        includedVoicesSeen = includedVoice
        generation?.validatePlacement = { [weak self] window in
            guard let self else { throw CancellationError() }
            try self.editor.validateVoiceLabPlacement(window, localCommands: self.localCommands)
        }
        generation?.prepareQuote = { [weak self] in await self?.prepareTakes() }
        generation?.onInputsChanged = { [weak self] in self?.takePlan?.invalidate() }
        generation?.readMonthlyCap = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.currentGenerationCap()
        }
    }
    /// Why finding the voices failed before a generation exists, R2's callout; nil clears it as Make Takes tries again.
    func reportGenerationProblem(_ error: (any Error)?) { problem = error.map { reported($0, stage: "voices") } ?? "" }
    /// Takes need Voice Lab's Rewrite on, its ElevenLabs consent and region, and a session that is current.
    func generationIsCurrent(region: ElevenLabsRegion) -> Bool {
        current && !isProposing && !wordingIsLocked && !isReasking && editor.app.voiceLabRewriteEnabled && editor.app.bool("voiceLab.providerConsent.elevenlabs") &&
            editor.app.string("transcription.elevenlabs.region", fallback: "default") == region.rawValue
    }
    /// Prepares and sends a selection's quotes; tests move its clock past a quote's 300 s window.
    @ObservationIgnored let passageService: VoiceRewriteService?
    /// Prepares and sends a clip's or Full take's quotes.
    @ObservationIgnored let scopeService: PatchRewriteService?
    @ObservationIgnored private let connectorIsCurrent: @MainActor () -> Bool
    @ObservationIgnored private let consent: @MainActor () async -> Bool
    /// The run in flight; `close` and an edit in the scope cancel it.
    @ObservationIgnored private(set) var sending: Task<Bool, Never>?
    /// R3: what an edit in the scope set aside, the transcript's proposal and the panel as it showed it. An undo back to
    /// `project` shows both again, with every review.
    struct SetAside {
        let proposal: TranscriptProposal?
        let shown: DirectorTask.Shown
    }
    @ObservationIgnored private(set) var setAside: SetAside?
    /// The transcript proposal this session made from the reply (`EditorModel.proposal`), which its change list reviews.
    @ObservationIgnored private(set) var proposalID: UUID?
    /// Each change's parts as the reply made them; a change whose parts differ was edited in the popover.
    @ObservationIgnored private(set) var replyParts: [Int: [TranscriptChange.Part]] = [:]
    /// The voice changes left out because they can't be made now (`voiceUnavailable`): Voice Lab's Turn on, or a review
    /// that places them, includes them again (design.md R2).
    @ObservationIgnored var leftOutUnavailable: Set<Int> = []
    @ObservationIgnored var includedVoicesSeen: [Int] = []
    /// What a run replaced, shown again when the run ends with nothing sent or proposed: a declined sheet, a send gone
    /// stale. Nil for a session's first run, which closes instead, as Stop does.
    @ObservationIgnored private var replaced: Replaced?
    /// A task's panel and the session's proposal as a run found them.
    struct Replaced {
        let shown: DirectorTask.Shown
        let changes: [RewriteChange]
        let review: RewriteReview?
        let setAside: SetAside?
        let proposal: TranscriptProposal?
        let proposalID: UUID?
        let replyParts: [Int: [TranscriptChange.Part]]
        let leftOutUnavailable: Set<Int>
    }
    /// Counts R2's observations: the change list follows the transcript's reviews, Voice Lab and the takes
    /// (`showProposal`), and only the latest observation shows it again.
    @ObservationIgnored var proposalObservation = 0
    /// Voice Lab's work a footer started (finding voices, Use Take); closing the session cancels it.
    @ObservationIgnored var takesTask: Task<Void, Never>?
    /// The session applies its own changes (Apply, Use Takes): the edit that follows is not an edit in its scope. Set only
    /// around the synchronous edit (`ownEdit`), so an edit the user makes while takes publish is still followed.
    @ObservationIgnored private var applying = false
    /// The review being built again, off the main actor, after an edit outside the scope moved the session on (`move`).
    /// Make Takes and Use Takes wait for it.
    @ObservationIgnored private(set) var reviewing: Task<Void, Never>?

    init(editor: EditorModel, scope rewriteScope: RewriteScope, instruction: String = "", envelope: AudioEnvelope?, connector: RewriteConnector?,
         prices: VoiceLabPriceCatalog? = nil, synthesisModel: String? = nil,
         consent: @escaping @MainActor () async -> Bool = { false }, connectorIsCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.editor = editor; self.rewriteScope = rewriteScope; project = editor.project
        self.instruction = instruction
        let corrected = Self.corrected(editor.project)
        let items = Self.items(of: rewriteScope, in: corrected, project: editor.project)
        transcript = corrected
        source = items
        scope = Self.outputScope(of: rewriteScope, in: editor.project)
        self.envelope = envelope; self.connector = connector; self.prices = prices; self.synthesisModel = VoiceLabWordingFit.modelID
        self.consent = consent; self.connectorIsCurrent = connectorIsCurrent
        passageService = editor.app.shared.map(VoiceRewriteService.init)
        scopeService = editor.app.shared.map(PatchRewriteService.init)
        let words = Self.scopeWords(rewriteScope, source: items, project: editor.project, editor: editor)
        task = DirectorTask(scope: rewriteScope, words: words, state: connector == nil ? .choosingAI : .running,
                            close: PanelAction(id: "close", title: "Close Rewrite") { [weak editor] in editor?.closeRewrite() })
        if connector == nil { task.show(.choosingAI, headline: PanelHeadline(text: "Who should rewrite \(words.name)?"), cards: [.text("Checking which AIs are set up…")]) }
        refreshContext()
        // As the panel appears, the AI's status for the context line's dot (design.md §6.3.4).
        task.appeared = { [weak self] in await self?.detectConnector() }
    }

    // MARK: The scope's words

    /// The take with corrections applied to words.
    static func corrected(_ project: Project) -> [TimedWord] {
        (project.transcript?.words ?? []).map { word in
            var corrected = word
            if word.kind == .word { corrected.text = project.edits.corrections[word.id] ?? word.text }
            return corrected
        }
    }
    /// The positions a clip spans in the take, nil for an unknown clip.
    private static func clipRange(_ id: String, in project: Project) -> ClosedRange<Int>? {
        let words = project.transcript?.words ?? []
        guard let clip = project.edits.clips.first(where: { $0.id == id }),
              let lower = words.firstIndex(where: { $0.id == clip.startWordId }),
              let upper = words.firstIndex(where: { $0.id == clip.endWordId }), lower <= upper else { return nil }
        return lower...upper
    }
    /// The tab's clip when a selection lies inside it.
    private static func enclosingClip(_ range: ClosedRange<Int>, in project: Project) -> String? {
        guard let id = project.edits.activeClipId, let clip = clipRange(id, in: project),
              clip.contains(range.lowerBound), clip.contains(range.upperBound) else { return nil }
        return id
    }
    static func items(of scope: RewriteScope, in transcript: [TimedWord], project: Project) -> [TimedWord] {
        guard !transcript.isEmpty else { return [] }
        switch scope {
        case .fullTake: return transcript
        case .clip(let id): return clipRange(id, in: project).map { Array(transcript[$0]) } ?? []
        case .selection(let range):
            let lower = max(0, range.lowerBound), upper = min(transcript.count - 1, range.upperBound)
            return lower <= upper ? Array(transcript[lower...upper]) : []
        }
    }
    static func outputScope(of scope: RewriteScope, in project: Project) -> VoiceLabOutputScope {
        switch scope {
        case .fullTake: return .full
        case .clip(let id): return .clip(id)
        case .selection(let range): return enclosingClip(range, in: project).map(VoiceLabOutputScope.clip) ?? .full
        }
    }
    /// The scope in its copy's words (design.md §6.3 "Scope words"): a selection counts its words; a clip and Full take
    /// count their kept words, which are what the AI reads.
    static func scopeWords(_ scope: RewriteScope, source: [TimedWord], project: Project, editor: EditorModel) -> DirectorScope {
        switch scope {
        case .selection(let range):
            return DirectorScope(kind: .selection(inClip: enclosingClip(range, in: project) != nil), wordCount: source.filter { $0.kind == .word }.count)
        case .clip(let id):
            let cut = Set(project.edits.cutWordIds)
            return DirectorScope(kind: .clip(number: editor.clipNumber(id) ?? 1), wordCount: source.filter { $0.kind == .word && !cut.contains($0.id) }.count)
        case .fullTake:
            let cut = Set(project.edits.cutWordIds)
            return DirectorScope(kind: .fullTake, wordCount: source.filter { $0.kind == .word && !cut.contains($0.id) }.count)
        }
    }
    /// R1's "{m:ss}" for the scope: a clip's and Full take's edited length, a selection's span.
    var span: Double {
        switch rewriteScope {
        case .selection: return (source.last?.end ?? 0) - (source.first?.start ?? 0)
        case .clip(let id): return editor.editedDuration(project.edits.clips.first { $0.id == id })
        case .fullTake: return editor.editedDuration(nil)
        }
    }
    /// Reads the scope again from the editor's project, as a new run does.
    private func reread() {
        project = editor.project.scoped(to: project.edits.activeClipId)
        derive()
    }
    private func derive() {
        transcript = Self.corrected(project)
        source = Self.items(of: rewriteScope, in: transcript, project: project)
        task.rescope(Self.scopeWords(rewriteScope, source: source, project: project, editor: editor))
    }

    // MARK: Running

    /// The scope's inputs still match, apart from save metadata and the active tab (impl-plan §3.3).
    var current: Bool { isOpen && editor.capabilities.edit && inside(editor.project) == inside(project) && connectorIsCurrent() }
    /// "Rewrite", or "Rewrite…" when the send asks first (design §6.3.1): an API key, or a CLI signed in with one.
    var proposalButton: String { sendAsksFirst ? "Rewrite…" : "Rewrite" }
    /// The note beside the button that sends (design.md R1's footer); empty while no AI is chosen (R0).
    var sendLine: String {
        guard let connector else { return "" }
        let words = task.words.words
        switch connector.group {
        case "apiKey": return "Sends \(words) to \(connector.name) with your key."
        case "cli":
            switch editor.app.cliSignIn(connector.connector.id) {
            case .plan: return "Sends \(words) to \(connector.name) with your sign-in. Counts toward your \(connector.plan)."
            case .apiKey: return "Sends \(words) to \(connector.name), billed to the API key it is signed in with."
            case nil: return "Sends \(words) to \(connector.name) with your sign-in."
            }
        default:
            if connector.connector.id.rawValue == "apple-foundation" { return "Runs on this Mac. Nothing leaves it." }
            let id = connector.connector.id.rawValue
            let fallback = editor.app.providers.first(where: { $0.id == id })?.baseUrl ?? ""
            return Self.localSendLine(words: words, baseURL: editor.app.string("llm.baseUrl.\(id)", fallback: fallback))
        }
    }
    /// A local server's send line: on this Mac, or "Sends {the scope's words} to {host}." (design.md R1's footer).
    static func localSendLine(words: String, baseURL: String) -> String {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return "Sends \(words) to the configured server." }
        if host == "localhost" || host == "::1" || host == "[::1]" || host.split(separator: ".").count == 4 && host.hasPrefix("127.") {
            return "Runs on this Mac. Nothing leaves it."
        }
        return "Sends \(words) to \(host)."
    }
    /// The AI's status now, for the context line's dot, which keeps an answer's "answered in {t} s".
    func detectConnector() async {
        guard current, let connector else { return }
        let result: ConnectorStatus?
        if let provider = editor.app.providers.first(where: { $0.id == connector.connector.id.rawValue }) {
            result = await editor.app.connectorStatus(provider, using: connector.connector)
        } else { result = await connector.connector.status() }
        guard !Task.isCancelled, current else { return }
        readiness = result
        if case .answered(let seconds) = task.context?.state { refreshContext(answered: seconds) } else { refreshContext() }
    }

    /// Starts the run as the session opens: R1 at once, or R0's detection when no AI is chosen.
    func start() {
        guard isOpen else { return }
        actionTask?.cancel()
        if connector == nil {
            actionTask = Task { [weak self] in await self?.showChooser() }
        } else if let work = begin() {
            actionTask = Task { _ = await work.value }
        }
    }
    /// Runs Rewrite on the scope again, asking `instruction` when given (the Ask field's text): Rewrite Again, Try Again
    /// and a new Rewrite of the same scope. False when nothing was proposed.
    @discardableResult func run(instruction next: String? = nil, feedback: String? = nil) async -> Bool {
        guard isOpen else { return false }
        if let next { instruction = next }
        shorterFeedback = feedback
        guard connectorIsCurrent() else {
            editor.restartRewrite(self)
            return false
        }
        guard connector != nil else { await showChooser(); return false }
        guard let work = begin() else { return false }
        return await work.value
    }
    /// The run's first part, before any wait, so the panel never draws a state before R1: the project's AI lease, the scope
    /// read again, R1 with nothing sent, then the send in `sending`. Nil while another AI request holds the project.
    private func begin() -> Task<Bool, Never>? {
        guard isOpen, !isProposing, let connector else { return nil }
        stopWordingFit(refresh: false)
        guard let lease = editor.llmRuns.acquire() else {
            let busy = editor.finding ? "Find Clips is still running. Choose Try Again when it finishes."
                                      : "Another AI request on this project is still running. Choose Try Again when it finishes."
            if case .error(let error) = task.state { fail(error, problem: busy) } else { fail(.message(busy)) }
            return nil
        }
        let runs = editor.llmRuns
        replaced = hasRun ? Replaced(shown: task.shown, changes: changes, review: review, setAside: setAside, proposal: ownProposal,
                                     proposalID: proposalID, replyParts: replyParts, leftOutUnavailable: leftOutUnavailable) : nil
        hasRun = true
        invalidate()
        reread()
        changes = []; review = nil; setAside = nil; problem = ""
        clearProposal()
        isProposing = true
        let expected = revision
        beginRun()
        let started = ContinuousClock.now
        let work = Task { [self] () -> Bool in
            let proposed = await send(connector, expected: expected, started: started)
            runs.release(lease)
            isProposing = false
            // Declining consent restores the previous view; stale successful replies show R3 instead.
            if isOpen, task.state == .running { restoreReplaced() }
            if proposed { await beginAutomaticWordingFit() }
            return proposed
        }
        sending = work
        return work
    }
    /// What a run sends: a selection's passage request, or a clip's or Full take's plan, each with its quote.
    enum PreparedSend {
        case passage(VoiceRewriteRequest, VoiceRewriteQuote, VoiceRewriteService)
        case scope(ScopeRewritePlan, PatchRewriteQuote, PatchRewriteService)
    }
    /// The run after R1 shows: the request and its quote, made fresh for every send (a quote binds the connector, the model
    /// and the prompt, and the services refuse one older than 300 s); the route (`consent`: the one-time privacy consent,
    /// then the cost sheet on a key); the send; and the reply as changes. Nothing is sent or announced until the route
    /// passes.
    private func send(_ connector: RewriteConnector, expected: Int, started: ContinuousClock.Instant) async -> Bool {
        do {
            let prepared = try await prepareSend(connector)
            guard !Task.isCancelled, current, revision == expected else { return false }
            guard await ConnectorConsentWait().confirm(consent) else { return false }
            guard !Task.isCancelled, current, revision == expected else { return false }
            sendRun()
            guard let (checked, nextActions) = try await reply(prepared, connector: connector, accept: { [self] in
                guard acceptReply(expected: expected) else { return false }
                advanceRun(to: 3)
                return true
            }) else { return false }
            guard acceptReply(expected: expected) else { return false }
            receive(checked)
            reasking.suggestions = nextActions
            let elapsed = started.duration(to: .now).components
            finishRun(seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            return true
        } catch VoiceLabWordDiffError.tokenLimit {
            // A reply too long to review shows its problem (R1x).
            guard isOpen, revision == expected else { return false }
            fail(.message(VoiceLabPatchBudget.disabledCopy))
            return false
        } catch {
            guard isOpen, revision == expected else { return false }
            await fail(error is CancellationError ? LLMError.cancelled : error, expected: expected)
            return false
        }
    }
    /// The reply to `prepared` as changes with their review, and its AI-suggested next steps; nil when `accept`, asked as
    /// the reply arrives and before it is checked, refuses it.
    func reply(_ prepared: PreparedSend, connector: RewriteConnector,
               accept: @MainActor () -> Bool) async throws -> (Checked, [RewriteNextAction])? {
        switch prepared {
        case .passage(let input, let quote, let service):
            let result = try await service.propose(input, connector: connector.connector, model: connector.model,
                authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
            guard accept() else { return nil }
            let source = source, text = result.proposedText, audioTags = result.audioTags
            return (try await check { try VoiceLabWordDiff.diff(source: source, newText: text, audioTags: audioTags).hunks.map { RewriteChange(hunk: $0) } },
                    result.nextActions)
        case .scope(let plan, let quote, let service):
            let result = try await service.propose(plan.request, connector: connector.connector, model: connector.model,
                authorization: PatchRewriteAuthorization(quote: quote, approved: true))
            guard accept() else { return nil }
            return (try await check {
                try ScopeRewriteDiff.hunks(plan: plan, proposal: result).map {
                    RewriteChange(hunk: $0.hunk, insertionAfterItemID: $0.insertionAfterItemID, checkThis: $0.checkThis, lines: $0.lines, reasons: $0.reasons)
                }
            }, result.nextActions)
        }
    }
    private func acceptReply(expected: Int) -> Bool {
        guard isOpen, revision == expected else { return false }
        guard !Task.isCancelled, current else {
            clearProposal()
            showChanged(reason: connectorIsCurrent() ? .scope : .ai)
            return false
        }
        return true
    }
    /// The request a run sends, made off the main actor: placing a selection and planning a clip or Full take read the
    /// whole take (impl-plan §3.1). The quote is the service's.
    func prepareSend(_ connector: RewriteConnector, feedback: String? = nil) async throws -> PreparedSend {
        let project = project, rewriteScope = rewriteScope, envelope = envelope
        let language = project.transcript?.language ?? "en"
        let asked = RewriteSuggestions.suggestion(for: instruction).instruction
        let feedback = feedback ?? shorterFeedback
        switch rewriteScope {
        case .selection:
            guard let service = passageService else { throw VoxClipError.sharedResourcesMissing }
            let source = source, transcript = transcript, scope = scope
            let range = try await offMain {
                try Self.passageRange(project: project, scope: scope, envelope: envelope, source: source, transcript: transcript)
            }
            let input = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: source.filter { $0.kind == .word }, instruction: asked,
                language: language, targetSeconds: range.targetSeconds, minChars: range.minChars, maxChars: range.maxChars, feedback: feedback)
            return .passage(input, try await service.prepare(input, connector: connector.connector.id, model: connector.model), service)
        case .clip, .fullTake:
            guard let service = scopeService else { throw VoxClipError.sharedResourcesMissing }
            let plan = try await offMain {
                try ScopeRewritePlan.make(project: project, scope: rewriteScope, instruction: asked, language: language, envelope: envelope, feedback: feedback)
            }
            return .scope(plan, try await service.prepare(plan.request, connector: connector.connector.id, model: connector.model), service)
        }
    }
    /// A selection's length range (voice-lab.md §8.9.1): its words placed as one window, or, as C1 does for a line, the
    /// span of its items when there is no envelope or the window is refused. Text Rewrite never needs the placement, which
    /// only voice changes do (`RewriteReview`); a refusal saying the scope does not render as it stands stays the run's.
    nonisolated static func passageRange(project: Project, scope: VoiceLabOutputScope, envelope: AudioEnvelope?, source: [TimedWord],
                                         transcript: [TimedWord]) throws -> VoiceLabLengthRange {
        let rate = try VoiceLabLengthBudget.rate(transcript: transcript).charactersPerSecond
        if let envelope, let first = source.first(where: { $0.kind == .word }), let last = source.last(where: { $0.kind == .word }) {
            do {
                let window = try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: envelope, firstWordId: first.id, lastWordId: last.id)
                let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: window)
                return try VoiceLabLengthBudget.passage(window: window, transcript: transcript, incomingSilence: silence.incoming,
                                                        outgoingSilence: silence.outgoing, rate: rate)
            } catch let refusal as VoiceLabGeometryError {
                if case .invalidInput(let segmentId) = refusal, segmentId != nil { throw refusal }
            } catch {}
        }
        return try VoiceLabLengthBudget.fullTake(transcript: source, rate: rate)
    }
    /// Runs Core's pure work off the main actor: a long take's plan or review never holds up R1 or an edit (§3.1).
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        #if DEBUG
        let probe = editor.rewriteWorkProbe
        #else
        let probe: (@Sendable (Bool) -> Void)? = nil
        #endif
        return try await Task.detached(priority: .userInitiated) {
            probe?(pthread_main_np() != 0)
            return try work()
        }.value
    }
    /// A reply's changes with their review, or why the review was refused.
    typealias Checked = (changes: [RewriteChange], review: Result<RewriteReview, any Error>)
    /// R1's "Check that each change fits", off the main actor: the reply's diff, then the review of its voice changes.
    private func check(_ diff: @escaping @Sendable () throws -> [RewriteChange]) async throws -> Checked {
        let inputs = reviewInputs
        return try await offMain {
            let found = try diff()
            return (found, Result { try RewriteReview.build(found.map(\.hunk), inputs) })
        }
    }
    /// What the review reads now.
    var reviewInputs: RewriteReview.Inputs {
        RewriteReview.Inputs(transcript: transcript, project: project, scope: scope, envelope: envelope, prices: prices, synthesisModel: synthesisModel)
    }
    private func receive(_ checked: Checked) {
        stopWordingFit(refresh: false)
        wordingFit.round = 0; wordingFit.completed = false; wordingFit.stopped = false
        wordingFit.initialEstimates = [:]; wordingFit.frozen = []; wordingFit.kept = []; wordingFit.problem = ""
        wordingFit.measured = nil
        pricedAnyway = []
        takePlanFailure = nil
        reasking.reset()
        autoFix.reset()
        changes = checked.changes
        switch checked.review {
        case .success(let built): review = built
        case .failure(let error): review = nil; problem = reported(error, stage: "review")
        }
    }
    /// The reply's changes and their review, on the main actor: how the DEBUG scenes and tests show a proposal.
    func receive(_ found: [RewriteChange]) {
        let inputs = reviewInputs
        receive((found, Result { try RewriteReview.build(found.map(\.hunk), inputs) }))
    }
    /// A selection's reply as the AI wrote it: its diff against the selected words.
    func receivePassage(_ text: String) throws {
        receive(try VoiceLabWordDiff.diff(source: source, newText: text).hunks.map { RewriteChange(hunk: $0) })
    }
    /// The consent route a send takes (the one-time privacy consent, then the cost row on a key).
    func confirmSend() async -> Bool { await ConnectorConsentWait().confirm(consent) }
    func applyWordingFit(_ updates: [VoiceLabFitUpdate]) throws {
        guard var proposal = ownProposal else { throw CancellationError() }
        var next = changes
        for update in updates {
            guard next.indices.contains(update.ordinal - 1), next[update.ordinal - 1].hunk.kind == .voice,
                  let index = proposal.changes.firstIndex(where: { $0.ordinal == update.ordinal }) else { throw CancellationError() }
            if update.keepOriginal {
                proposal.changes[index].state = .excluded
                wordingFit.kept.insert(update.ordinal)
            } else {
                let old = next[update.ordinal - 1].hunk
                let tags = VoiceLabAudioTags.reanchored(old.audioTags, from: old.newTokens.joined(separator: " "), to: update.text)
                next[update.ordinal - 1].hunk = VoiceLabWordingFit.reword(old, text: update.text, tags: tags)
                let parts = [TranscriptChange.Part(next[update.ordinal - 1].hunk)]
                proposal.changes[index].parts = parts
                replyParts[update.ordinal] = parts
            }
        }
        let built = try RewriteReview.build(next.map(\.hunk), reviewInputs)
        changes = next; review = built
        editor.proposal = proposal
        showProposal()
    }
    func recordSpeakingRate(model: String, take: UUID, measured: Double, baseline: Double) {
        guard !calibratedTakeIDs.contains(take) else { return }
        var next = editor.project
        let previous = next.voiceLab.speakingRateSamples?[model] ?? []
        if previous.contains(where: { $0.id == take.uuidString }) {
            calibratedTakeIDs.insert(take)
            return
        }
        let samples = VoiceLabWordingFit.recording(previous, id: take.uuidString, measured: measured, estimated: baseline)
        guard samples != previous else { return }
        calibratedTakeIDs.insert(take)
        if next.voiceLab.speakingRateSamples == nil { next.voiceLab.speakingRateSamples = [:] }
        next.voiceLab.speakingRateSamples?[model] = samples
        editor.document.replaceProject(next)
        if !editor.document.demo { editor.document.updateChangeCount(.changeDone) }
        project.voiceLab.speakingRateSamples = next.voiceLab.speakingRateSamples
        review = try? RewriteReview.build(changes.map(\.hunk), reviewInputs)
    }
    private func invalidate() {
        stopWordingFit(refresh: false)
        stopReask(refresh: false)
        autoFix.reset()
        takePlanFailure = nil
        speechContextOffer = nil; speechContextReview = nil; acceptedSpeechContext = nil; speechContextProblem = ""
        surroundingSentenceOrdinal = nil
        takePlan?.invalidate(); takePlan = nil
        generation?.invalidate(); generation = nil
        revision += 1; sending?.cancel()
        reviewing?.cancel(); reviewing = nil
    }
    /// A run has started on this session: a later run replaces what it showed.
    @ObservationIgnored private var hasRun = false
    /// The transcript's proposal when it is this session's.
    var ownProposal: TranscriptProposal? { editor.proposal.flatMap { $0.id == proposalID ? $0 : nil } }
    /// Takes the session's proposal out of the transcript.
    private func clearProposal() {
        if ownProposal != nil { editor.proposal = nil }
    }
    /// Shows what the run replaced again, with the transcript's proposal and its reviews, or closes a first run.
    /// A failed run has a proposal to go back to (R1x's "Back to the changes").
    var canRestoreReplaced: Bool { if case .proposal? = replaced?.shown.state { true } else { false } }
    func restoreReplaced() {
        guard let replaced else { editor.closeRewrite(returnFocus: false); return }
        self.replaced = nil
        changes = replaced.changes; review = replaced.review; setAside = replaced.setAside
        proposalID = replaced.proposalID; replyParts = replaced.replyParts; leftOutUnavailable = replaced.leftOutUnavailable
        if let proposal = replaced.proposal { editor.proposal = proposal }
        task.show(replaced.shown)
        if case .proposal = task.state { showProposal() }
    }
    /// Makes the reply's changes the transcript's proposal (design.md §6.3.5), numbered from 1 in transcript order. A
    /// voice change that can't be made is left out as R2 shows it (`showProposal`).
    func showReplyInTranscript() {
        let cut = editor.cutWordIDs
        let first = source.first { $0.kind == .word && !cut.contains($0.id) }?.id
        // A selection's insertion stands before the word that owns its source token, as an edit popover's rediff places it.
        let owners = source.flatMap { word in Array(repeating: word.id, count: max(1, EditingPrimitives.splitWords(word.text).count)) }
        let made = changes.enumerated().map { offset, change in transcriptChange(change, ordinal: offset + 1, first: first, owners: owners) }
        replyParts = Dictionary(made.map { ($0.ordinal, $0.parts) }, uniquingKeysWith: { first, _ in first })
        leftOutUnavailable = []
        guard !made.isEmpty else { proposalID = nil; return }
        let proposal = TranscriptProposal(clipID: project.edits.activeClipId, title: task.words.title, changes: made)
        proposalID = proposal.id
        editor.proposal = proposal
    }
    /// The transcript change for `change` at `ordinal`; an insertion stands where its reply placed it.
    func transcriptChange(_ change: RewriteChange, ordinal: Int, first: String? = nil, owners: [String]? = nil) -> TranscriptChange {
        let hunk = change.hunk
        var anchor: TranscriptChange.Anchor?
        if hunk.sourceWordIds.isEmpty {
            switch rewriteScope {
            case .selection:
                let owners = owners ?? source.flatMap { word in Array(repeating: word.id, count: max(1, EditingPrimitives.splitWords(word.text).count)) }
                anchor = owners.indices.contains(hunk.sourceStartIndex) ? .before(owners[hunk.sourceStartIndex]) : source.last.map { .after($0.id) }
            case .clip, .fullTake:
                let cut = editor.cutWordIDs
                let first = first ?? source.first { $0.kind == .word && !cut.contains($0.id) }?.id
                anchor = change.insertionAfterItemID.map(TranscriptChange.Anchor.after) ?? first.map(TranscriptChange.Anchor.before)
            }
        }
        return TranscriptChange(ordinal: ordinal, parts: [TranscriptChange.Part(hunk)], anchor: anchor)
    }
    /// Replaces the changes at `replacements` (by ordinal) with a re-ask's reply, leaves out `kept`, and removes `absorbed`
    /// (merged into a replacement), keeping every other change, its review and its parts as they are; changes after an
    /// absorbed one move up a number. Throws, changing nothing, when the review cannot be built again.
    func applyReask(replacing replacements: [Int: RewriteChange], keepingOriginal kept: Set<Int>, absorbing absorbed: Set<Int> = []) throws {
        guard var proposal = ownProposal else { throw CancellationError() }
        var next = changes
        for (ordinal, change) in replacements {
            guard next.indices.contains(ordinal - 1), let index = proposal.changes.firstIndex(where: { $0.ordinal == ordinal }) else { throw CancellationError() }
            next[ordinal - 1] = change
            var made = transcriptChange(change, ordinal: ordinal)
            made.state = proposal.changes[index].state == .kept && change.hunk.kind == .voice ? .kept : .pending
            proposal.changes[index] = made
            replyParts[ordinal] = made.parts
        }
        for ordinal in kept {
            guard let index = proposal.changes.firstIndex(where: { $0.ordinal == ordinal }) else { continue }
            proposal.changes[index].state = .excluded
        }
        // A merge: the absorbed changes go, and every later change moves up to stay numbered from 1 in transcript order.
        var renumber: [Int: Int] = [:]
        if !absorbed.isEmpty {
            var kept: [RewriteChange] = [], made: [TranscriptChange] = []
            for (offset, change) in next.enumerated() where !absorbed.contains(offset + 1) {
                let old = offset + 1, new = kept.count + 1
                renumber[old] = new
                kept.append(change)
                guard let shown = proposal.changes.first(where: { $0.ordinal == old }) else { throw CancellationError() }
                var moved = TranscriptChange(ordinal: new, parts: shown.parts, anchor: shown.anchor, state: shown.state)
                moved.reviewable = shown.reviewable
                made.append(moved)
            }
            next = kept
            proposal.changes = made
            proposal.focused = proposal.focused.flatMap { renumber[$0] } ?? made.first?.ordinal
        }
        let built = try RewriteReview.build(next.map(\.hunk), reviewInputs)
        if !absorbed.isEmpty {
            func moved(_ ordinals: Set<Int>) -> Set<Int> { Set(ordinals.compactMap { renumber[$0] }) }
            replyParts = Dictionary(replyParts.compactMap { key, value in renumber[key].map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
            pricedAnyway = moved(pricedAnyway); leftOutUnavailable = moved(leftOutUnavailable)
            wordingFit.kept = moved(wordingFit.kept); wordingFit.frozen = moved(wordingFit.frozen)
            wordingFit.initialEstimates = Dictionary(wordingFit.initialEstimates.compactMap { key, value in renumber[key].map { ($0, value) } },
                                                     uniquingKeysWith: { first, _ in first })
            speechContextRefusedOrdinals = speechContextRefusedOrdinals.compactMap { renumber[$0] }
            surroundingSentenceOrdinal = nil
            takePlan?.invalidate(); takePlan = nil; takePlanOrdinals = []
            generation?.inputsChanged()
        }
        changes = next; review = built; problem = ""
        takePlanFailure = nil
        let touched = Set(replacements.keys.compactMap { absorbed.isEmpty ? $0 : renumber[$0] }).union(kept.compactMap { absorbed.isEmpty ? $0 : renumber[$0] })
        pricedAnyway.subtract(touched)
        wordingFit.kept.subtract(touched)
        for ordinal in touched { wordingFit.initialEstimates[ordinal] = nil }
        if surroundingSentenceOrdinal.map(touched.contains) == true { surroundingSentenceOrdinal = nil }
        editor.proposal = proposal
    }

    // MARK: The proposal

    /// The transcript's changes still pending that need no voice: cuts and text fixes the project does not hold yet.
    private var pendingFree: [TranscriptChange] {
        guard case .proposal = task.state else { return [] }
        let readings = editor.changeReadings
        return readings.filter { $0.change.isFree && $0.change.state == .pending && !$0.applied }.map(\.change)
    }
    /// R2's apply action (design.md R2's footers): "Apply {c} Changes" when only cuts and fixes are included, "Apply {k}
    /// Free Changes" beside voice changes the footer can't make; nil when the footer offers none.
    var applyTitle: String? {
        guard case .proposal = task.state, let primary = task.footer.primary, primary.id == "apply" else { return nil }
        return primary.title
    }
    static func applyTitle(free: Int, voice: Bool) -> String? {
        guard free > 0 else { return nil }
        return free == 1 ? (voice ? "Apply 1 Free Change" : "Apply 1 Change") : (voice ? "Apply \(free) Free Changes" : "Apply \(free) Changes")
    }
    /// The changes a new run discards: the proposal's, or in R3 those of the proposal set aside.
    var proposalCount: Int {
        switch task.state {
        case .proposal(let set): return set.items.count
        case .changed: return setAside?.proposal?.changes.count ?? 0
        default: return 0
        }
    }
    /// A change was edited in the popover (design.md §6.3.1: a new run asks first then).
    var hasEditedChanges: Bool {
        let proposal = task.state == .changed ? setAside?.proposal : ownProposal
        return proposal?.changes.contains { change in replyParts[change.ordinal].map { $0 != change.parts } ?? false } ?? false
    }
    func updateAudioTags(_ tags: [VoiceLabAudioTag], ordinal: Int) {
        guard changes.indices.contains(ordinal - 1) else { return }
        let original = changes[ordinal - 1].hunk.newTokens.joined(separator: " ")
        let displayed = editor.changeReadings.first { $0.change.ordinal == ordinal }?.text ?? original
        updateAudioTags([ordinal - 1: VoiceLabAudioTags.reanchored(tags, from: displayed, to: original)])
    }
    /// An expression on a phrase with no paid takes: the tags go into the phrase's changes, mapped through the plan's
    /// hunks. False when the phrase maps to none of them (a widened sentence) or nothing changed.
    @discardableResult func updateAudioTagsWithoutPlan(_ tags: [VoiceLabAudioTag], phrase: ClipTakePlan.Phrase) -> Bool {
        var remaining = tags
        var retained: [Bool] = []
        for annotation in phrase.audioTags {
            if let index = remaining.firstIndex(of: annotation) {
                retained.append(true)
                remaining.remove(at: index)
            } else { retained.append(false) }
        }
        var annotationIndex = 0
        var updates: [Int: [VoiceLabAudioTag]] = [:]
        for index in phrase.indices where takePlanOrdinals.indices.contains(index) {
            let change = takePlanOrdinals[index] - 1
            guard changes.indices.contains(change), changes[change].hunk.kind == .voice else { continue }
            updates[change] = changes[change].hunk.audioTags.filter { _ in
                defer { annotationIndex += 1 }
                return retained.indices.contains(annotationIndex) && retained[annotationIndex]
            }
        }
        if let last = updates.keys.max() {
            updates[last, default: []] += remaining.map {
                VoiceLabAudioTag(beforeToken: changes[last].hunk.newTokens.count, tag: $0.tag)
            }
        }
        return updateAudioTags(updates)
    }
    @discardableResult private func updateAudioTags(_ updates: [Int: [VoiceLabAudioTag]]) -> Bool {
        guard current, !isProposing, !updates.isEmpty,
              updates.keys.allSatisfy({ changes.indices.contains($0) && changes[$0].hunk.kind == .voice }) else { return false }
        let changed = updates.filter { index, tags in
            VoiceLabAudioTags.validated(tags, text: changes[index].hunk.newTokens.joined(separator: " ")) != changes[index].hunk.audioTags
        }
        guard !changed.isEmpty else { return false }
        stopWordingFit(refresh: false)
        if confirmPaidProposalChange(perform: { [weak self] in self?.updateAudioTags(changed) }) { return true }
        let requote = generation != nil
        takePlan?.invalidate(); takePlan = nil
        speechContextOffer = nil; speechContextReview = nil; acceptedSpeechContext = nil
        surroundingSentenceOrdinal = nil; takeQuotePhrase = nil
        revision += 1
        for (index, tags) in changed {
            changes[index].hunk.audioTags = VoiceLabAudioTags.validated(tags, text: changes[index].hunk.newTokens.joined(separator: " "))
        }
        do { review = try RewriteReview.build(changes.map(\.hunk), reviewInputs); problem = "" }
        catch { review = nil; problem = reported(error, stage: "review") }
        generation?.inputsChanged(prepareNewQuote: false)
        showProposal()
        if requote { makeTakes() }
        return true
    }
    var hasPaidTakes: Bool { takePlan?.generating == true || (takePlan?.spent.units ?? 0) > 0 || generation?.rows.isEmpty == false }
    var currentSynthesisModel: String? {
        takePlan.flatMap { $0.isRetired ? nil : $0.modelID } ?? generation?.selectedModelID ?? synthesisModel
    }
    func confirmDiscardChanges(perform: @escaping @MainActor () -> Void) {
        let count = proposalCount
        let question = count == 1 ? "Discard this change?" : "Discard these \(count) changes?"
        task.ask(PanelConfirm(question: question,
            cancel: PanelAction(id: "keepWorking", title: "Keep Working") { [weak self] in self?.task.dismissConfirm() },
            confirm: PanelAction(id: "discardChanges", title: "Discard Changes") { [weak self] in
                guard let self, isOpen, task.confirm?.confirm.id == "discardChanges" else { return }
                task.dismissConfirm()
                perform()
            }))
        if editor.app.shell.editor === editor, !editor.app.shell.viewerShown { editor.app.shell.toggleViewer() }
        editor.announce(question)
    }
    func confirmPaidProposalChange(perform: @escaping @MainActor () -> Void) -> Bool {
        guard hasPaidTakes, !applyingTextFixesOnly else { return false }
        confirmDiscardChanges { [weak self] in
            guard let self, current else { return }
            if takesBusy, let plan = takePlan {
                takesTask = Task { [weak self] in
                    await plan.stop()
                    guard let self, current, takePlan === plan else { return }
                    discardPaidPlan(perform: perform)
                }
            } else { discardPaidPlan(perform: perform) }
        }
        return true
    }
    private func discardPaidPlan(perform: @MainActor () -> Void) {
        takePlan?.invalidate(); takePlan = nil
        generation?.invalidate()
        speechContextOffer = nil; speechContextReview = nil; acceptedSpeechContext = nil
        surroundingSentenceOrdinal = nil; takeQuotePhrase = nil
        perform()
        showProposal()
    }
    /// The proposal has phrases in your voice and Voice Lab is on: R2's Beta tag shows (design.md §6.3.4).
    var showsVoiceLab: Bool { review?.voiceHunks.isEmpty == false && editor.app.voiceLabRewriteEnabled }
    /// Applies every change still pending (Keep All) as one undo step named for the scope ("Rewrite clip 1", design.md
    /// R2), announces "Applied {c} changes", closes Rewrite and moves focus to the first changed word. Voice changes that
    /// wait are left out first: nothing voices them once Rewrite closes.
    @discardableResult func applyFreeChanges() -> Bool {
        guard current, !isProposing, var proposal = ownProposal else { return false }
        let free = pendingFree
        guard !free.isEmpty else { return false }
        let first = free.compactMap(\.span.first).min { (editor.index($0) ?? 0) < (editor.index($1) ?? 0) }
        for index in proposal.changes.indices where !proposal.changes[index].isFree && proposal.changes[index].state == .pending {
            proposal.changes[index].state = .excluded
        }
        editor.proposal = proposal
        guard editor.keepAllChanges() else { return false }
        editor.closeRewrite(returnFocus: false)
        if let first { editor.select(first) }
        focusTranscript(in: editor.window)
        return true
    }
    /// Uses the selected take with the free changes still pending, one undo step (Use Takes), and closes Rewrite. It waits
    /// for a review being built again: when that moved a window, the takes no longer fit and are not used.
    @discardableResult func acceptTakes() async -> Bool {
        if let reviewing { await reviewing.value }
        if let takePlan {
            do {
                guard current else { return false }
                let output = try await takePlan.acceptance()
                guard current, takePlan.stillCurrent, self.takePlan === takePlan else { return false }
                let cuts = pendingFree.filter { $0.kind == .cut }.count
                let fixes = pendingFree.filter { $0.kind == .fix }.count
                let used = takePlan.phrases.filter { $0.selected?.row.selectable == true }
                let first = (pendingFree.compactMap(\.span.first) + output.segments.compactMap(\.replace.firstWordId))
                    .min { (editor.index($0) ?? 0) < (editor.index($1) ?? 0) }
                try ownEdit { try editor.applyVoiceLab(output.segments, assets: output.assets, voice: output.voice,
                    scope: rewriteScope, localCommands: localCommands, videoAssets: output.videoAssets) }
                editor.finishVoiceRewrite(phrases: used, segments: output.segments, voice: output.voice,
                    spent: takePlan.spent, scope: task.words, cuts: cuts, fixes: fixes)
                editor.closeRewrite()
                if let first { editor.select(first) }
                return true
            } catch { problem = ClipTakePlan.copy(error); takePlanFailure = error; return false }
        }
        return false
    }
    /// The session's own edit: `follow` does not take it for an edit in the scope.
    private func ownEdit<T>(_ edit: () throws -> T) rethrows -> T {
        applying = true
        defer { applying = false }
        return try edit()
    }
    /// The free changes still pending as edit commands: cuts of words not cut yet, and corrections.
    var localCommands: [EditCommand] { pendingFree.flatMap(editor.commands) }
    func close() {
        guard isOpen else { return }
        isOpen = false; phraseMicrophone.cancel(); invalidate(); actionTask?.cancel(); takesTask?.cancel()
        clearProposal()
    }

    // MARK: R3

    /// Follows a project change the editor made (design.md R3, impl-plan §3.3). An edit outside the scope moves the
    /// session on. One inside it sets an open proposal aside and shows R3, and stops a run; before a run it moves the
    /// session on, as the next run reads the scope again. In R3, an undo back to the proposal's revision shows it again
    /// with every inclusion and take. Another transcript or video, or a clip that is gone, closes the session.
    func follow(_ next: Project, name: String = "") {
        guard isOpen, !applying else { return }
        if wordingFit.running || wordingFit.awaitingApproval { stopWordingFit(refresh: false) }
        if isReasking { stopReask(refresh: false) }
        let next = next.scoped(to: project.edits.activeClipId)
        let before = inside(project), after = inside(next)
        if after.transcript != before.transcript || after.media.source != before.media.source || !Self.scopeExists(rewriteScope, in: next) {
            editor.closeRewrite(returnFocus: false)
            return
        }
        let unchanged = after == before
        if task.state == .changed {
            guard unchanged else { return }
            move(to: next)
            if let setAside {
                self.setAside = nil
                if let proposal = setAside.proposal { editor.proposal = proposal }
                task.show(setAside.shown)
                // The editor reads the edit after this (`EditorModel.refresh`); the list follows it, and the
                // transcript's reviews, from there.
                Task { @MainActor [weak self] in
                    guard let self, isOpen, case .proposal = task.state else { return }
                    showProposal()
                }
            }
            return
        }
        guard !unchanged, !reviews(next, name: name) else { move(to: next); return }
        switch task.state {
        case .proposal:
            setAside = SetAside(proposal: ownProposal, shown: task.shown)
            clearProposal()
            showChanged()
        case .running:
            invalidate()
            setAside = nil
            showChanged()
        default:
            move(to: next)
        }
    }
    /// Moves the session on to `next`, past an edit outside the scope, which never waits for Core (impl-plan §3.1). A
    /// voice change's window can read the kept words and pauses beside the scope, so the review is built again off the
    /// main actor (`reviewing`); when a window or patch text moved, takes made for the old ones no longer fit
    /// (`inputsChanged`). A review that failed so leaves the proposal's phrases out with its problem (`voiceUnavailable`),
    /// and the next such edit tries again. Cuts and fixes read nothing outside the scope.
    private func move(to next: Project) {
        guard next != project else { return }
        let requote = takePlan != nil
        takePlanFailure = nil
        speechContextOffer = nil; speechContextReview = nil; acceptedSpeechContext = nil; speechContextProblem = ""
        surroundingSentenceOrdinal = nil
        takePlan?.invalidate(); takePlan = nil
        project = next; derive()
        let previous = review
        guard previous.map({ !$0.voiceHunks.isEmpty }) ?? changes.contains(where: { $0.hunk.kind == .voice }) else { return }
        reviewing?.cancel()
        let hunks = changes.map(\.hunk), inputs = reviewInputs, version = revision
        reviewing = Task { [self] in
            guard let built = try? await offMain({ Result { try RewriteReview.build(hunks, inputs) } }),
                  !Task.isCancelled, isOpen, revision == version else { return }
            reviewing = nil
            switch built {
            case .success(let fresh):
                review = fresh; problem = ""
                if requote || previous.map({ !fresh.makesTheSameTakes(as: $0) }) ?? true { generation?.inputsChanged() }
            case .failure(let error):
                review = nil; problem = reported(error, stage: "review")
                generation?.inputsChanged()
            }
        }
    }
    /// An edit that only keeps changes of the session's proposal, or takes a Keep back (V14's "Keep change {i}" and Keep
    /// All, named for the proposal, and their undo and redo): every word inside the scope it changes is one of those
    /// changes'. It reviews the proposal and is not an edit to the scope (design.md R3).
    private func reviews(_ next: Project, name: String) -> Bool {
        guard case .proposal = task.state, let proposal = ownProposal else { return false }
        let named = name == proposal.title ? proposal.changes : proposal.changes.filter { name == "Keep change \($0.ordinal)" }
        guard !named.isEmpty else { return false }
        let words = Set(named.flatMap { $0.parts.flatMap(\.sourceWordIDs) })
        var before = inside(project), after = inside(next)
        let cuts = Set(before.edits.cutWordIds).symmetricDifference(after.edits.cutWordIds)
        let corrections = Set(before.edits.corrections.keys).union(after.edits.corrections.keys).filter { before.edits.corrections[$0] != after.edits.corrections[$0] }
        guard cuts.union(corrections).isSubset(of: words) else { return false }
        before.edits.cutWordIds = []; after.edits.cutWordIds = []
        before.edits.corrections = [:]; after.edits.corrections = [:]
        return before == after
    }
    private static func scopeExists(_ scope: RewriteScope, in project: Project) -> Bool {
        if case .clip(let id) = scope { return project.edits.clips.contains { $0.id == id } }
        return true
    }
    /// Uses the same scoped inputs as opening, keeping the session's original enclosing clip across tab changes.
    private func inside(_ project: Project) -> Project {
        let clipID: String? = if case .clip(let id) = scope { id } else { nil }
        return project.rewriteInputs(scope: rewriteScope, enclosingClipID: clipID)
    }
    enum ChangedReason { case scope, ai }
    /// R3: "Clip 1 changed", why nothing was applied, Close, and Rewrite Again with the send line.
    func showChanged(reason: ChangedReason = .scope) {
        let words = task.words
        let headline = reason == .ai ? "AI changed" : words.changed
        let change = reason == .ai ? "You changed the AI" : "You edited \(words.name)"
        var body = "\(change), so these changes may no longer fit. Nothing was applied, and no takes were paid for."
        if hasPaidTakes { body += " Your takes are kept until you close this." }
        // Rewrite Again discards the set-aside proposal and its takes, so it asks first as ⇧⌘R does.
        let again = PanelAction(id: "rewriteAgain", title: sendAsksFirst ? "Rewrite Again…" : "Rewrite Again") { [weak self] in
            guard let self else { return }
            editor.sendRewriteAgain(self)
        }
        let steps = NextSteps(id: "stale", ask: NextStepAsk(id: "stale", placeholder: NextSteps.askPlaceholder) { [weak self] text in
            self?.askInstead(text)
        })
        task.show(.changed, headline: PanelHeadline(text: headline), cards: [.text(body), .nextSteps(steps)],
                  footer: PanelFooter(note: sendLine, link: PanelAction(id: "closeChanged", title: "Close") { [weak editor] in editor?.closeRewrite() }, primary: again))
        editor.announce(headline + ".")
    }

    /// A failure the panel reports: its copy (`refusal`), and one release log line with its type and case, never its text.
    func reported(_ error: any Error, stage: String) -> String {
        let copy = Self.refusal(error)
        if !copy.isEmpty { logFailure(error, stage: stage) }
        return copy
    }
    /// "rewrite failure stage=takes type=ClipTakePlan.Failure case=tooManyPhrases" through the app logger.
    func logFailure(_ error: any Error, stage: String) {
        guard !(error is CancellationError) else { return }
        let entry = LogEntry(level: .warn, category: "rewrite", message: "rewrite failure stage=\(stage) " + Self.failureKind(error))
        let log = editor.app.log
        Task { await log.write(entry) }
    }
    /// An error's type and case, with no associated text: "type=VoiceLabError case=permissionMissing",
    /// "type=ClipTakePlan.Failure case=placement.geometry.windowTooShort", or an NSError's domain and code.
    nonisolated static func failureKind(_ error: any Error) -> String {
        // The module and any "(unknown context at $…)" of a private type are dropped.
        let type = String(reflecting: Swift.type(of: error)).split(separator: ".").dropFirst()
            .filter { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }.joined(separator: ".")
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else {
            let ns = error as NSError
            let domain = ns.domain.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
            return "type=\(type.isEmpty ? "unknown" : type) domain=\(domain) code=\(ns.code)"
        }
        return "type=\(type) case=\(caseName(error, depth: 0))"
    }
    private nonisolated static func caseName(_ value: Any, depth: Int) -> String {
        let mirror = Mirror(reflecting: value)
        guard let child = mirror.children.first else {
            let name = String(describing: value)
            return name.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil ? name : "unnamed"
        }
        let label = child.label ?? "unnamed"
        guard depth < 3 else { return label }
        // A case's payload is its value, or a tuple when the case has several; the first enum in it names the inner case.
        let payload = Mirror(reflecting: child.value)
        let first: Any? = payload.displayStyle == .tuple ? payload.children.first?.value : child.value
        guard let inner = first, Mirror(reflecting: inner).displayStyle == .enum else { return label }
        return label + "." + caseName(inner, depth: depth + 1)
    }

    nonisolated static func refusal(_ error: any Error) -> String {
        if let error = error as? VoiceConsentError { return error.localizedDescription }
        if let error = error as? VoiceLabSourceAudioError, let reason = error.errorDescription { return reason + " Your edits are saved." }
        if let geometry = error as? VoiceLabGeometryError, let isStart = geometry.takeEdgeIsStart {
            return "This change is too close to the \(isStart ? "start" : "end") of the take to blend in. Re-record this sentence instead."
        }
        switch error {
        case RewriteSessionError.noSourceAudio: return "Find the original video before rewriting speech. Your edits are saved."
        case VoiceLabProjectError.invalidFadeHandles, VoiceLabProjectError.overlappingFades:
            return "This change can't blend beside the proposed cuts. Keep more of the surrounding speech or re-record this sentence. Your edits are saved."
        case VoiceLabProjectError.invalidScope:
            return "This change extends outside the selected scope. Choose a wider scope and try again. Your edits are saved."
        case VoiceLabGeometryError.insertionUnsupported: return "Inserting words isn't available yet. Your edits are saved."
        case VoiceLabGeometryError.roomToneUnavailable: return "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in. Clean audio is not available in this build. Re-record this sentence instead."
        case is VoiceLabGeometryError: return "This change can't be placed in this take. Your edits are saved."
        case is VoiceLabLengthBudgetError: return "There isn't enough timed speech to estimate this change. Your edits are saved."
        case VoiceLabWordDiffError.tokenLimit: return VoiceLabPatchBudget.disabledCopy
        case VoiceLabWordDiffError.invalidInput:
            return "The AI's words couldn't be matched to the transcript. Ask again or edit the words. Your edits are saved."
        case is ClipTakePlan.Failure: return ClipTakePlan.copy(error)
        case is RewriteSpeechContextReview.Failure, is VoiceLabSpeechContextPlan.Failure: return RewriteSpeechContextReview.copy(error)
        case let error as VoiceLabError: return voiceLabCopy(error)
        case let error as VoiceLabAudioMathError:
            switch error {
            case .noVoicedAudio: return "This take has no speech to match to the recording's level. Try another take or record it yourself."
            case .insufficientContext: return "This change is too close to the edge of the recording to blend in. Re-record this sentence instead."
            case .invalidInput: return "VoxClip couldn't measure this take's audio. Try another take. Your edits are saved."
            }
        case let error as MicrophoneTakeError:
            switch error {
            case .noSpeech: return "We didn't hear any words in your take. Record it again."
            case .transcriptionUnavailable: return "This Mac can't check your take's words in this language yet. Use a voiced take instead."
            }
        default:
            let message = UserMessages.message(error)
            guard message == UserMessages.generic else { return message }
            if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty { return described + " Your edits are saved." }
            return "Voice Lab couldn't finish this step. Get a fresh price or ask again. Your edits are saved."
        }
    }
    /// Every `VoiceLabError` the Rewrite can meet, with what to do next (the access cases keep their shared copy).
    nonisolated static func voiceLabCopy(_ error: VoiceLabError) -> String {
        if let message = error.accessMessage { return message }
        switch error {
        case .invalidInput:
            return "ElevenLabs can't take this request as it stands. Get a fresh price; if it fails again, shorten or leave out the longest phrase. Your edits are saved."
        case .consentRequired: return "This price expired or no longer matches the changes. Get a fresh price. Nothing was sent."
        case .speakerMismatch: return "This take doesn't sound like your voice. Try another take or record it yourself."
        case .planUnavailable: return "Your ElevenLabs plan can't make voice takes. Check your plan on elevenlabs.io."
        case .noVoiceSlots: return "Your ElevenLabs account has no free voice slots. Free one on elevenlabs.io, then try again."
        case .missingKey: return "Add your ElevenLabs key in Settings to make takes."
        case .permissionMissing(let permission): return "Allow the \(permission) permission for this ElevenLabs key on elevenlabs.io, then get a fresh price."
        case .unauthorized: return "ElevenLabs rejected the key (401). Your edits are saved."
        case .quotaExceeded: return "Your ElevenLabs credits are used up. Add credit, then get a fresh price."
        case .rateLimited: return "ElevenLabs is busy. Wait a minute, then get a fresh price."
        case .unsupportedModel, .unsupportedEndpoint, .unsupportedFormat:
            return "ElevenLabs doesn't offer this speech model for your voice and language. Choose another model."
        case .malformedResponse, .invalidAudio, .invalidAlignment, .responseTooLarge:
            return "ElevenLabs sent a reply VoxClip couldn't use. Try another take. Your edits are saved."
        case .providerFailure(let status): return "ElevenLabs had a server error (\(status)). Try again in a minute."
        case .network: return "Couldn't reach ElevenLabs. Check your internet connection, then try again."
        case .cancelled: return ""
        case .subscriptionRequired, .featureUnavailable, .voiceAccessDenied, .modelAccessDenied: return error.accessMessage ?? ""
        }
    }
    static func proposalError(_ error: LLMError, provider: String, model: String) -> String {
        error.userMessage(label: provider, model: model, feature: .voiceRewrite) ?? ""
    }
}

enum RewriteSessionError: Error, Equatable {
    /// Placing a voice change needs the video's audio envelope.
    case noSourceAudio
}
