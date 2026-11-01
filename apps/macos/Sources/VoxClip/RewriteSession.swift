import AppKit
import Observation
import VoxClipCore
import VoxClipMedia

/// Text Rewrite's entry rule (design.md §6.3.6 and §8, impl-plan V13): an editable project with AI and a scope, from the
/// menu, ⇧⌘R, the selection bar, the transcript's context menu and the clip bar alike. Voice Lab gates only Rewrite's voice
/// parts (phrases in your voice, making your voice, takes), and Insert Words, which waits for Core to place an insertion,
/// is never offered. `buildEnabled` keeps text Rewrite in DEBUG builds until V15 turns it on for Release with the
/// release-boundary allowlists (lead decision on item 26).
enum RewriteEntryPolicy {
    static var buildEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    static func canRun(editable: Bool, scope: RewriteScope?, internalBuild: Bool = buildEnabled) -> Bool {
        internalBuild && editable && scope != nil
    }
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

@MainActor final class RewriteApprovalSheet {
    private let alert = NSAlert()
    private let parent: NSWindow
    /// `confirm` is the default button's title; Cancel is the other button.
    init(title: String, copy: String, confirm: String = "Continue", parent: NSWindow) {
        self.parent = parent
        alert.messageText = title; alert.informativeText = copy
        alert.addButton(withTitle: confirm); alert.addButton(withTitle: "Cancel")
    }
    func confirm() async -> Bool {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            let response = await alert.beginSheetModal(for: parent)
            return !Task.isCancelled && response == .alertFirstButtonReturn
        } onCancel: {
            Task { @MainActor [self] in
                if alert.window.sheetParent === parent { parent.endSheet(alert.window, returnCode: .abort) }
            }
        }
    }
}

/// One change of a proposal, in transcript order: C2's hunk for a clip or Full take (`ScopeRewriteDiff.Hunk`), or the
/// passage diff's for a selection. The transcript's hunks (V14) and the change list (V15) read it.
struct RewriteChange: Equatable, Sendable {
    let hunk: VoiceLabDiffHunk
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
    let editor: EditorModel
    /// What the session rewrites (C1's `RewriteScope`).
    let rewriteScope: RewriteScope
    /// The project the session reads, scoped to its tab. An edit outside the scope moves it on (`follow`) and a run reads
    /// the editor's again; in R3 it keeps the proposal's, so an undo back to it shows the proposal again.
    private(set) var project: Project
    /// The take as the user reads it: corrections applied to words.
    private(set) var transcript: [TimedWord]
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
    /// The Director task the Rewrite job shows (impl-plan V12m); the session drives it.
    let task: DirectorTask
    /// The AIs R0 lists, once detected.
    var choices: [ConnectorChoice] = []
    /// The work a panel action started (detection, a run, Try Again); closing the session cancels it.
    @ObservationIgnored var actionTask: Task<Void, Never>?
    func configureGeneration(client: ElevenLabsVoiceLab, store: VoiceConsentStore, speaker: VoiceSpeakerCheck) {
        generation?.invalidate()
        let region = client.region
        let storage = VoiceLabTakeStorage(projectId: editor.project.id,
            paidRoot: editor.app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true),
            scratchRoot: editor.app.locations.root.appendingPathComponent("VoiceLabScratch", isDirectory: true))
        let run = VoiceLabTakeRun(client: client, store: store, speaker: speaker, storage: storage, dispatchIfCurrent: { [weak self] _, start in
            guard let generation = await self?.generation else { throw VoiceLabError.consentRequired }
            try await generation.dispatchWithCurrentCost(start)
        }) { [weak self] in
            await self?.generationIsCurrent(region: region) ?? false
        }
        generation = RewriteGenerationSession(run: run) { [weak self] in self?.generationIsCurrent(region: region) ?? false }
        generation?.prepareQuote = { [weak self] in await self?.prepareTakes() }
        generation?.readMonthlyCap = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.currentGenerationCap()
        }
    }
    func reportGenerationProblem(_ error: any Error) { problem = Self.refusal(error) }
    /// Takes need Voice Lab's Rewrite on, its ElevenLabs consent and region, and a session that is current.
    func generationIsCurrent(region: ElevenLabsRegion) -> Bool {
        current && !isProposing && editor.app.voiceLabRewriteEnabled && editor.app.bool("voiceLab.providerConsent.elevenlabs") &&
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
    /// R3: the proposal an edit in the scope set aside, with its headline. An undo back to `project` shows it again.
    @ObservationIgnored private var setAside: (changes: ChangeSet, headline: PanelHeadline)?
    /// The session applies its own changes (Apply, Use Takes): the edit that follows is not an edit in its scope. Set only
    /// around the synchronous edit (`ownEdit`), so an edit the user makes while takes publish is still followed.
    @ObservationIgnored private var applying = false

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
        self.envelope = envelope; self.connector = connector; self.prices = prices; self.synthesisModel = synthesisModel
        self.consent = consent; self.connectorIsCurrent = connectorIsCurrent
        passageService = editor.app.shared.map(VoiceRewriteService.init)
        scopeService = editor.app.shared.map(PatchRewriteService.init)
        let words = Self.scopeWords(rewriteScope, source: items, project: editor.project, editor: editor)
        task = DirectorTask(scope: rewriteScope, words: words, state: connector == nil ? .choosingAI : .ready,
                            close: PanelAction(id: "close", title: "Close Rewrite") { [weak editor] in editor?.closeRewrite() })
        if connector == nil { task.show(.choosingAI, headline: PanelHeadline(text: "Who should rewrite \(words.name)?"), cards: [.text("Checking which AIs are set up…")]) }
        refreshContext()
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

    /// The session still matches the editor's project. The editor's tab is not part of it:
    /// a session belongs to its tab and keeps working while another tab shows (impl-plan §3.3).
    var current: Bool { isOpen && editor.capabilities.edit && editor.project.scoped(to: project.edits.activeClipId) == project && connectorIsCurrent() }
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
    func detectConnector() async {
        guard current, let connector else { return }
        let result: ConnectorStatus?
        if let provider = editor.app.providers.first(where: { $0.id == connector.connector.id.rawValue }) {
            result = await editor.app.connectorStatus(provider, using: connector.connector)
        } else { result = await connector.connector.status() }
        guard !Task.isCancelled, current else { return }
        readiness = result
        refreshContext()
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
    @discardableResult func run(instruction next: String? = nil) async -> Bool {
        guard isOpen else { return false }
        if let next { instruction = next }
        guard connector != nil else { await showChooser(); return false }
        guard let work = begin() else { return false }
        return await work.value
    }
    /// The run's first part, before any wait, so the panel never draws a state before R1: the project's AI lease, the scope
    /// read again, R1 with nothing sent, then the send in `sending`. Nil while another AI request holds the project.
    private func begin() -> Task<Bool, Never>? {
        guard isOpen, !isProposing, let connector else { return nil }
        guard let lease = editor.llmRuns.acquire() else {
            problem = editor.finding ? "Find Clips is still running. Choose Rewrite when it finishes."
                                     : "Another AI request on this project is still running. Choose Rewrite when it finishes."
            showReady()
            return nil
        }
        let runs = editor.llmRuns
        invalidate()
        reread()
        changes = []; review = nil; setAside = nil; problem = ""
        isProposing = true
        let expected = revision
        beginRun()
        let started = ContinuousClock.now
        let work = Task { [self] () -> Bool in
            let proposed = await send(connector, expected: expected, started: started)
            runs.release(lease)
            isProposing = false
            // A declined sheet or a send gone stale changes nothing: back to the field, silently.
            if isOpen, task.state == .running { showReady() }
            return proposed
        }
        sending = work
        return work
    }
    /// What a run sends: a selection's passage request, or a clip's or Full take's plan, each with its quote.
    private enum PreparedSend {
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
            let found: [RewriteChange]
            switch prepared {
            case .passage(let input, let quote, let service):
                let result = try await service.propose(input, connector: connector.connector, model: connector.model,
                    authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
                guard !Task.isCancelled, current, revision == expected else { return false }
                advanceRun(to: 3)
                found = try VoiceLabWordDiff.diff(source: source, newText: result.proposedText).hunks.map { RewriteChange(hunk: $0) }
            case .scope(let plan, let quote, let service):
                let result = try await service.propose(plan.request, connector: connector.connector, model: connector.model,
                    authorization: PatchRewriteAuthorization(quote: quote, approved: true))
                guard !Task.isCancelled, current, revision == expected else { return false }
                advanceRun(to: 3)
                found = try ScopeRewriteDiff.hunks(plan: plan, proposal: result).map {
                    RewriteChange(hunk: $0.hunk, insertionAfterItemID: $0.insertionAfterItemID, checkThis: $0.checkThis, lines: $0.lines, reasons: $0.reasons)
                }
            }
            receive(found)
            let elapsed = started.duration(to: .now).components
            finishRun(seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            return true
        } catch is CancellationError { return false } catch VoiceLabWordDiffError.tokenLimit {
            // A reply too long to review shows its problem at the field, unannounced.
            guard current, revision == expected else { return false }
            problem = VoiceLabPatchBudget.disabledCopy
            return false
        } catch {
            if current && revision == expected { await fail(error) }
            return false
        }
    }
    private func prepareSend(_ connector: RewriteConnector) async throws -> PreparedSend {
        let language = project.transcript?.language ?? "en"
        let asked = RewriteSuggestions.suggestion(for: instruction).instruction
        switch rewriteScope {
        case .selection:
            guard let service = passageService else { throw VoxClipError.sharedResourcesMissing }
            guard let envelope, let first = source.first(where: { $0.kind == .word }), let last = source.last(where: { $0.kind == .word }) else {
                throw RewriteSessionError.noSourceAudio
            }
            let window = try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: envelope, firstWordId: first.id, lastWordId: last.id)
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: window)
            let rate = try VoiceLabLengthBudget.rate(transcript: transcript).charactersPerSecond
            let range = try VoiceLabLengthBudget.passage(window: window, transcript: transcript, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing, rate: rate)
            let input = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: source.filter { $0.kind == .word }, instruction: asked,
                language: language, targetSeconds: range.targetSeconds, minChars: range.minChars, maxChars: range.maxChars)
            return .passage(input, try await service.prepare(input, connector: connector.connector.id, model: connector.model), service)
        case .clip, .fullTake:
            guard let service = scopeService else { throw VoxClipError.sharedResourcesMissing }
            let plan = try ScopeRewritePlan.make(project: project, scope: rewriteScope, instruction: asked, language: language, envelope: envelope)
            return .scope(plan, try await service.prepare(plan.request, connector: connector.connector.id, model: connector.model), service)
        }
    }
    /// The reply's changes: the review of their voice changes, and the proposal (`finishRun`). Also how the DEBUG scenes show
    /// a proposal.
    func receive(_ found: [RewriteChange]) {
        changes = found
        refreshReview()
    }
    /// A selection's reply as the AI wrote it: its diff against the selected words.
    func receivePassage(_ text: String) throws {
        receive(try VoiceLabWordDiff.diff(source: source, newText: text).hunks.map { RewriteChange(hunk: $0) })
    }
    private func invalidate() {
        generation?.invalidate(); generation = nil
        revision += 1; sending?.cancel()
    }
    private func refreshReview() {
        do { review = try RewriteReview.build(self) }
        catch { review = nil; problem = Self.refusal(error) }
    }

    // MARK: The proposal

    /// The included changes that need no voice: cuts and text fixes.
    private var freeChanges: [RewriteChange] {
        guard case .proposal(let set) = task.state else { return [] }
        let included = Set(set.items.filter(\.included).map(\.ordinal))
        return changes.enumerated().filter { included.contains($0.offset + 1) && $0.element.hunk.kind != .voice }.map(\.element)
    }
    /// The interim proposal's apply button (design.md R2's footers until V15): "Apply {c} Changes" when every included
    /// change is free, "Apply {k} Free Changes" beside voice changes; nil with nothing free to apply.
    var applyTitle: String? {
        let free = freeChanges.count
        guard free > 0 else { return nil }
        let all = changes.count == free
        return free == 1 ? (all ? "Apply 1 Change" : "Apply 1 Free Change") : (all ? "Apply \(free) Changes" : "Apply \(free) Free Changes")
    }
    /// Applies the included cuts and fixes as one undo step named for the scope ("Rewrite clip 1", design.md R2), announces
    /// "Applied {c} changes", closes Rewrite and moves focus to the first changed word.
    @discardableResult func applyFreeChanges() -> Bool {
        guard current, !isProposing else { return false }
        let free = freeChanges
        let commands = localCommands(free)
        guard !commands.isEmpty else { return false }
        let first = free.compactMap(\.hunk.sourceWordIds.first).min { (editor.index($0) ?? 0) < (editor.index($1) ?? 0) }
        guard ownEdit({ editor.apply(commands, name: task.words.title) }) else { return false }
        editor.closeRewrite(returnFocus: false)
        editor.announce(free.count == 1 ? "Applied 1 change" : "Applied \(free.count) changes")
        if let first { editor.select(first) }
        focusTranscript(in: editor.window)
        return true
    }
    /// Uses the selected take with the free changes, one undo step (Use Takes), and closes Rewrite.
    @discardableResult func acceptTakes() async -> Bool {
        guard current, let generation else { return false }
        let accepted = await generation.accept(into: editor, localCommands: localCommands) { [self] edit in try ownEdit(edit) }
        if accepted { editor.closeRewrite() }
        return accepted
    }
    /// The session's own edit: `follow` does not take it for an edit in the scope.
    private func ownEdit<T>(_ edit: () throws -> T) rethrows -> T {
        applying = true
        defer { applying = false }
        return try edit()
    }
    /// The free changes as edit commands: cuts of words not cut yet, and corrections.
    var localCommands: [EditCommand] { localCommands(freeChanges) }
    private func localCommands(_ free: [RewriteChange]) -> [EditCommand] {
        var commands: [EditCommand] = []
        for change in free {
            let hunk = change.hunk
            if hunk.kind == .cut {
                let ids = hunk.sourceWordIds.filter { !editor.cutWordIDs.contains($0) }
                if !ids.isEmpty { commands.append(.cutSelection(ids: ids)) }
            } else if hunk.kind == .textOnly {
                for (id, text) in zip(hunk.sourceWordIds, hunk.correctedTexts) { commands.append(.correct(id: id, text: text)) }
            }
        }
        return commands
    }
    func close() {
        guard isOpen else { return }
        isOpen = false; invalidate(); actionTask?.cancel()
    }

    // MARK: R3

    /// Follows a project change the editor made (design.md R3, impl-plan §3.3). An edit outside the scope moves the
    /// session on. One inside it sets an open proposal aside and shows R3, and stops a run; before a run it moves the
    /// session on, as the next run reads the scope again. In R3, an undo back to the proposal's revision shows it again
    /// with every inclusion and take. Another transcript or video, or a clip that is gone, closes the session.
    func follow(_ next: Project) {
        guard isOpen, !applying else { return }
        let next = next.scoped(to: project.edits.activeClipId)
        if next.transcript != project.transcript || next.media.source != project.media.source || !Self.scopeExists(rewriteScope, in: next) {
            editor.closeRewrite(returnFocus: false)
            return
        }
        let unchanged = inside(next) == inside(project)
        if task.state == .changed {
            guard unchanged else { return }
            project = next; derive()
            if let setAside {
                self.setAside = nil
                task.show(.proposal(setAside.changes), headline: setAside.headline)
            }
            return
        }
        guard !unchanged else {
            project = next; derive()
            if !changes.isEmpty { refreshReview() }
            return
        }
        switch task.state {
        case .proposal(let set):
            setAside = (set, task.headline)
            showChanged()
        case .running:
            invalidate()
            setAside = nil
            showChanged()
        default:
            project = next; derive()
        }
    }
    private static func scopeExists(_ scope: RewriteScope, in project: Project) -> Bool {
        if case .clip(let id) = scope { return project.edits.clips.contains { $0.id == id } }
        return true
    }
    /// The parts of `project` the scope reads: the transcript, the video, the pause and Voice Lab settings, and the cuts,
    /// corrections and pauses of the scope's words and its clip's, with that clip's bounds. The clip's title, and whether it
    /// is kept or suggested, lie outside it, as do other clips, Find Clips results, captions, export and share settings.
    /// Full take reads every word.
    private func inside(_ project: Project) -> Project {
        let positions = editor.wordIndex
        var clipID: String?
        var words: ClosedRange<Int>
        switch rewriteScope {
        case .fullTake: words = 0...max(0, (project.transcript?.words.count ?? 1) - 1)
        case .clip(let id):
            clipID = id
            words = Self.clipRange(id, in: self.project) ?? 0...0
        case .selection(let range):
            words = range
            if case .clip(let id) = scope, let clip = Self.clipRange(id, in: self.project) {
                clipID = id
                words = min(range.lowerBound, clip.lowerBound)...max(range.upperBound, clip.upperBound)
            }
        }
        var project = project
        project.modifiedAt = .distantPast
        project.title = nil
        project.edits.activeClipId = nil
        project.edits.clips = project.edits.clips.filter { $0.id == clipID }.map { ClipRange(id: $0.id, startWordId: $0.startWordId, endWordId: $0.endWordId) }
        project.edits.cutWordIds = project.edits.cutWordIds.filter { positions[$0].map(words.contains) ?? true }
        project.edits.cutPauseIds = project.edits.cutPauseIds.filter { id in
            editor.pauseIndex[id].map { $0.afterIndex >= words.lowerBound && $0.afterIndex < words.upperBound } ?? true
        }
        project.edits.corrections = project.edits.corrections.filter { positions[$0.key].map(words.contains) ?? true }
        project.captions = CaptionSettings()
        project.export = ProjectExport()
        project.share = ProjectShare()
        project.ai = ProjectAI()
        return project
    }
    /// R3: "Clip 1 changed", why nothing was applied, Close, and Rewrite Again with the send line.
    func showChanged() {
        let words = task.words
        var body = "You edited \(words.name), so these changes may no longer fit. Nothing was applied, and no takes were paid for."
        if generation?.rows.isEmpty == false { body += " Your takes are kept until you close this." }
        let again = PanelAction(id: "rewriteAgain", title: sendAsksFirst ? "Rewrite Again…" : "Rewrite Again") { [weak self] in
            guard let self else { return }
            actionTask?.cancel()
            actionTask = Task { await self.run() }
        }
        task.show(.changed, headline: PanelHeadline(text: words.changed), cards: [.text(body)],
                  footer: PanelFooter(note: sendLine, link: PanelAction(id: "closeChanged", title: "Close") { [weak editor] in editor?.closeRewrite() }, primary: again))
        editor.announce(words.changed + ".")
    }

    static func refusal(_ error: any Error) -> String {
        if let error = error as? VoiceConsentError { return error.localizedDescription }
        if let error = error as? VoiceLabSourceAudioError, let reason = error.errorDescription { return reason + " Your edits are saved." }
        if let error = error as? VoiceLabError, error == .unauthorized { return "ElevenLabs rejected the key (401). Your edits are saved." }
        if let message = (error as? VoiceLabError)?.accessMessage { return message }
        if let geometry = error as? VoiceLabGeometryError, let isStart = geometry.takeEdgeIsStart {
            return "This change is too close to the \(isStart ? "start" : "end") of the take to blend in. Re-record this sentence instead."
        }
        switch error {
        case RewriteSessionError.noSourceAudio: return "Find the original video before rewriting speech. Your edits are saved."
        case VoiceLabGeometryError.insertionUnsupported: return "Inserting words isn't available yet. Your edits are saved."
        case VoiceLabGeometryError.roomToneUnavailable: return "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in. Clean audio is not available in this build. Re-record this sentence instead."
        case is VoiceLabGeometryError: return "This change can't be placed in this take. Your edits are saved."
        case is VoiceLabLengthBudgetError: return "There isn't enough timed speech to estimate this change. Your edits are saved."
        case VoiceLabWordDiffError.tokenLimit: return VoiceLabPatchBudget.disabledCopy
        default: return UserMessages.message(error)
        }
    }
    static func proposalError(_ error: LLMError, provider: String, model: String) -> String {
        error.userMessage(label: provider, model: model, feature: .voiceRewrite) ?? ""
    }
}

enum RewriteSessionError: Error, Equatable {
    /// A selection's voice placement needs the video's audio envelope.
    case noSourceAudio
}
