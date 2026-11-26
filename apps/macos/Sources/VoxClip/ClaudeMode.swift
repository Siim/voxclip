import AppKit
import Foundation
import Observation
import VoxClipCore

// "✦ Claude does it all" (doc/design.md §6.6, §6.7): one remembered choice, Settings `clips.mode`. In Claude mode a newly
// opened video runs the whole loop with no clicks: transcription and Find Clips (which already run on drop), then Make
// top N postable within the per-video cap, then one card with Export all. "I'll pick" leaves the clips to the creator.
// The run is not stored in the project: a reopened project never starts it again (its video is no longer new).

/// What Claude mode needs from the creator before it can go on, with the one action that fixes it.
enum ClaudeModeBlocker: Equatable {
    /// No AI is chosen, or the chosen CLI's status check found it missing, signed out or too old: Settings › AI.
    case setUp(String)
    case aiSettings(String)
    /// The chosen AI bills each send to a key: Find Clips asks inline first.
    case approveSend(String)
    /// Find Clips failed or found nothing: Find Clips again.
    case findAgain(String)

    var reason: String {
        switch self { case .setUp(let text), .aiSettings(let text), .approveSend(let text), .findAgain(let text): text }
    }
    var action: String {
        switch self {
        case .setUp: "Set Up Claude Code…"
        case .aiSettings: "AI Settings…"
        case .approveSend: "Find Clips"
        case .findAgain: "Find Clips Again"
        }
    }
}

enum ClaudeModeFindOutcome {
    case finished
    case failed(any Error, connectorSignature: [String])
    case needsApproval
    case cancelled
}

/// The editor's Claude mode state for its video.
@MainActor @Observable final class ClaudeModeState {
    enum Phase: Equatable {
        /// Nothing for this video (not new, "I'll pick", or not chosen yet).
        case idle
        /// Waiting for the transcript or Find Clips.
        case waiting
        case blocked(ClaudeModeBlocker)
        case running
        case done
        case stopped
    }
    /// The video was newly opened in this window and Claude has not started on it yet.
    var armed = false
    var phase = Phase.idle
    /// The clips the run makes, best first.
    var clipIDs: [String] = []
    /// How many moments Find Clips offered.
    var found = 0
    var budget: MakeItBudget?
    /// The run's stage times from the video's open (transcribe, find, then each clip's plan and apply), logged when it ends.
    @ObservationIgnored var clock: ClaudeModeClock?
    /// The run's queue, from the start to the last clip.
    @ObservationIgnored var task: Task<Void, Never>?
    /// Going on once Find Clips' task has ended.
    @ObservationIgnored var afterFind: Task<Void, Never>?
    @ObservationIgnored var findNeedsAction = false
    @ObservationIgnored var findRetries = 0
    @ObservationIgnored var waitForFindRetry: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func cancelFindContinuation() {
        afterFind?.cancel()
        afterFind = nil
        findRetries = 0
    }
    /// The chosen CLI's short name while its free status check runs ("Checking Claude Code…"). A CLI no check has
    /// looked at yet is not missing: the card waits for the check before it says anything is wrong.
    var checking: String?
    /// The status check in flight, and what the last one found for the connector and path it checked.
    @ObservationIgnored var detection: Task<Void, Never>?
    @ObservationIgnored var checked: (key: String, status: ConnectorStatus?)?
    /// A blocked card watches what decides its AI's readiness, and looks again when any of it changes.
    @ObservationIgnored var watchesReadiness = false

    var running: Bool { phase == .running }
}

extension EditorModel {
    // MARK: The remembered choice

    var clipsAutopilot: ClipsAutopilotSettings { app.settings.clipsAutopilot }
    var claudeModeOn: Bool { clipsAutopilot.mode == .claude }

    /// Card A ("Who makes the clips?") asks once, inline, until the creator chooses: on a newly opened video, or once a
    /// project has clips. A read-only project never shows it.
    var showsClipsModeCard: Bool {
        guard capabilities.edit, clipsAutopilot.mode == nil else { return false }
        return claudeMode.armed || claudeMode.phase != .idle || !project.edits.clips.isEmpty
    }

    /// The choice, remembered in Settings for every new video. Choosing Claude on a video that is still new starts it.
    func chooseClipsMode(_ mode: ClipsMode) {
        guard app.set(ClipsMode.key, .string(mode.rawValue)) else { return }
        clipStyleState.reopened = false
        announce(mode == .claude ? "Claude does it all, for every new video." : "You pick the clips. Claude suggests them.")
        if mode == .claude {
            if claudeMode.armed, project.transcript?.engine.id == .appleSpeech {
                claudeMode.armed = false
                claudeMode.phase = .idle
                return
            }
            if claudeModeWaitsForTranscript, !transcribed, transcription.engine == "apple", transcription.phase != .hidden {
                let previous = workTask
                transcription.close()
                claudeMode.phase = .waiting
                _ = claudeModeChecksConnector()
                Task { [weak self] in
                    await previous?.value
                    guard let self, claudeModeWaitsForTranscript, !isLeaving, transcription.phase == .hidden else { return }
                    await transcription.open(automatic: true)
                }
                return
            }
            claudeModeContinue()
        } else if claudeMode.afterFind != nil {
            claudeMode.cancelFindContinuation()
            claudeMode.phase = .idle
        } else if case .blocked = claudeMode.phase, !claudeMode.findNeedsAction {
            claudeMode.phase = .idle
        }
    }

    func setClaudeClipCount(_ count: Int) { _ = app.set(ClipsMode.countKey, .number(Double(count))) }
    func setClaudeSpendCap(_ usd: Int) { _ = app.set(ClipsMode.capKey, .number(Double(usd))) }

    /// "Top 3 clips · up to $2.00 per video for voice and music · Opus, extra high".
    var claudeModeMeta: String {
        let settings = clipsAutopilot
        let spend = settings.capUSD == 0 ? "no paid voice or music" : "up to \(Self.makeItDollars(Decimal(settings.capUSD))) per video for voice and music"
        return "Top \(settings.count) \(settings.count == 1 ? "clip" : "clips") · \(spend) · Opus, extra high"
    }

    /// "✦ Claude does it all · up to $2.00", or without an amount at $0.
    var claudeModeButtonTitle: String {
        let cap = clipsAutopilot.capUSD
        return cap == 0 ? "✦ Claude does it all" : "✦ Claude does it all · up to \(Self.makeItDollars(Decimal(cap)))"
    }

    // MARK: The automatic run

    /// A newly opened video (the transcription starts on its own): Claude mode may run on it.
    func armClaudeMode() {
        guard claudeMode.phase == .idle, !document.isVersion else { return }
        claudeMode.armed = true
        claudeMode.clock = document.importClock ?? ClaudeModeClock()
        claudeMode.clock?.end(.ingest)
        document.importClock = nil
        claudeMode.clock?.begin(.transcribe)
        guard claudeModeOn else { return }
        claudeMode.phase = .waiting
        // The check is free and sends nothing, so it runs beside the transcription.
        _ = claudeModeChecksConnector()
    }

    /// Claude mode takes the transcript on: Find Clips after any transcription, not only a free one.
    var claudeModeWaitsForTranscript: Bool { claudeMode.armed && claudeModeOn }

    /// The transcript arrived; `started` says whether Find Clips started by itself.
    func claudeModeTranscribed(started: Bool) {
        guard claudeMode.armed, claudeModeOn else { return }
        claudeMode.clock?.end(.transcribe)
        if started || finding { claudeMode.clock?.begin(.find); claudeMode.phase = .waiting; return }
        claudeModeContinue()
    }

    /// Claude goes on only after the find task has ended and released the project's AI lease.
    func claudeModeFindEnded(_ outcome: ClaudeModeFindOutcome = .finished) {
        guard claudeMode.armed, claudeModeOn else { return }
        claudeMode.clock?.end(.find)
        let find = findTask
        claudeMode.afterFind = Task { [weak self] in
            await find?.value
            guard let self, !Task.isCancelled else { return }
            if claudeModeOn, case .failed(let error, let signature) = outcome,
               await claudeModeRetryFind(error, connectorSignature: signature) { return }
            guard !Task.isCancelled else { return }
            claudeMode.afterFind = nil
            guard claudeMode.armed, claudeModeOn, capabilities.edit else { return }
            switch outcome {
            case .finished where !suggestedClips.isEmpty:
                claudeModeContinue()
            case .finished:
                let reason = clipError == Self.noClipsMatched ? nil : clipError
                blockClaudeModeFind(.findAgain(reason ?? "Claude found no clip worth posting in this video."))
            case .failed(let error, _):
                let reason = clipError ?? "Could not find clips right now. Try again later. Your edits are saved."
                switch error as? LLMError {
                case .modelNotFound?, .cliSignedOut?: blockClaudeModeFind(.aiSettings(reason))
                default: blockClaudeModeFind(.findAgain(reason))
                }
            case .needsApproval:
                blockClaudeModeFind(.approveSend("Claude waits for your OK to read the transcript and find clips. Your edits are saved."))
            case .cancelled:
                claudeMode.findNeedsAction = true
                claudeMode.phase = .idle
            }
        }
    }

    private static let findRetryDelays: [Duration] = [.seconds(2), .seconds(8), .seconds(30)]

    private func claudeModeRetryFind(_ error: any Error, connectorSignature: [String]) async -> Bool {
        switch (error as? LLMError, error as? VoxClipError) {
        case (.network?, _), (.timeout?, _), (.cliNetworkUnreachable?, _), (_, .offline?): break
        default: return false
        }
        guard canFindClipsIfFree, connectorSignature == rewriteConnectorSignature,
              claudeMode.findRetries < Self.findRetryDelays.count else { return false }
        let delay = Self.findRetryDelays[claudeMode.findRetries]
        claudeMode.findRetries += 1
        do { try await claudeMode.waitForFindRetry(delay) } catch { return false }
        guard !Task.isCancelled, claudeMode.armed, claudeModeOn, connectorSignature == rewriteConnectorSignature else { return false }
        claudeMode.afterFind = nil
        guard findClipsIfFree(retrying: true) else { return false }
        claudeMode.clock?.begin(.find)
        return true
    }

    private func blockClaudeModeFind(_ blocker: ClaudeModeBlocker) {
        claudeMode.findNeedsAction = true
        claudeMode.phase = .blocked(blocker)
    }

    /// Goes as far as it can: starts the run when there are suggestions, starts Find Clips when it is free, else says
    /// what blocks it.
    func claudeModeContinue() {
        guard claudeMode.armed, claudeModeOn, capabilities.edit, transcribed || project.transcript != nil else { return }
        if finding || claudeMode.afterFind != nil { claudeMode.phase = .waiting; return }
        if !suggestedClips.isEmpty { startClaudeMode(); return }
        guard !claudeMode.findNeedsAction else { return }
        if claudeModeChecksConnector() { claudeMode.phase = .waiting; return }
        if project.ai.results.isEmpty, findClipsIfFree() { claudeMode.clock?.begin(.find); claudeMode.phase = .waiting; return }
        claudeMode.phase = .blocked(claudeModeBlocker)
        watchClaudeModeReadiness()
    }

    /// "claude-code:/usr/local/bin/claude": the connector and the CLI path a status check covers.
    private func claudeModeCheckKey(_ connector: ConnectorID) -> String {
        connector.rawValue + ":" + app.string("llm.cliPath.\(connector.rawValue)")
    }

    /// The chosen CLI's sign-in is not known yet: runs its status check (the one Rewrite runs; free, it sends nothing) and
    /// goes on when it ends. Returns whether Claude waits for it. "Not checked yet" never reads as "isn't installed".
    private func claudeModeChecksConnector() -> Bool {
        if claudeMode.detection != nil { return true }
        guard let connector = ConnectorID(rawValue: app.string("llm.connector")), connector == .claudeCode || connector == .codex,
              let provider = app.providers.first(where: { $0.id == connector.rawValue }), app.cliSignIn(connector) == nil else { return false }
        let key = claudeModeCheckKey(connector)
        if claudeMode.checked?.key == key { return false }
        claudeMode.checking = provider.shortName
        let app = self.app
        claudeMode.detection = Task { [weak self] in
            let status = await app.connectorStatus(provider)
            guard let self, !Task.isCancelled else { return }
            claudeMode.detection = nil
            claudeMode.checking = nil
            claudeMode.checked = (key, status)
            claudeModeContinue()
        }
        return true
    }

    /// A blocked card looks again, and goes on by itself once clear, when its AI's readiness may have changed: a status
    /// check found a sign-in, a connector send succeeded, Settings closed, or the chosen AI or its path changed.
    private func watchClaudeModeReadiness() {
        guard !claudeMode.watchesReadiness else { return }
        claudeMode.watchesReadiness = true
        let app = self.app
        withObservationTracking {
            _ = app.knownCLIAuthMethods
            _ = app.detectedConnectorStatus
            _ = app.connectorReadinessRevision
            _ = app.connectorSendRevision
            _ = app.settingsClosedRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.claudeMode.watchesReadiness = false
                self?.claudeModeRecheck()
            }
        }
    }

    /// Re-evaluates a card blocked on set-up or a send's OK, with a fresh status check. A failed Find Clips waits for its
    /// own Find Clips Again.
    func claudeModeRecheck() {
        guard claudeMode.armed, claudeModeOn, !claudeMode.findNeedsAction, case .blocked(let blocker) = claudeMode.phase else { return }
        if case .findAgain = blocker { return }
        claudeMode.checked = nil
        claudeModeContinue()
    }

    /// Why Claude can't find the clips by itself, with the fix.
    var claudeModeBlocker: ClaudeModeBlocker {
        if let error = clipError, !project.ai.results.isEmpty || error == Self.noClipsMatched {
            return .findAgain(error == Self.noClipsMatched ? "Claude found no clip worth posting in this video." : error)
        }
        guard let connector = ConnectorID(rawValue: app.string("llm.connector")), app.providers.contains(where: { $0.id == connector.rawValue }) else {
            return .setUp("Claude isn't set up yet. Choose Claude Code in Settings › AI, then Claude starts on its own.")
        }
        let name = app.providers.first { $0.id == connector.rawValue }?.shortName ?? "Claude Code"
        switch app.llmSendKind(connector) {
        case nil:
            let checked = claudeMode.checked.flatMap { $0.key == claudeModeCheckKey(connector) ? $0.status : nil }
            return .setUp(Self.claudeModeSetUpReason(name: name, status: checked))
        case .confirm?:
            // An API key, or a CLI signed in with one: each send asks first, inline.
            return .approveSend("\(name) bills each send to your key, so Claude waits for your OK to find clips.")
        default:
            if let error = clipError { return .findAgain(error) }
            return .approveSend("Claude waits for your OK to read the transcript and find clips.")
        }
    }

    /// The set-up card's reason for what the CLI's status check found. Only a check that ran can say it is missing.
    nonisolated static func claudeModeSetUpReason(name: String, status: ConnectorStatus?) -> String {
        switch status {
        case .cliMissing?: return "\(name) isn't installed on this Mac. Install it, then check it in Settings › AI."
        case .cliSignedOut?: return "\(name) isn't signed in. Sign in once in Terminal, then check it in Settings › AI."
        case .cliTooOld(let version, _)?:
            let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
            let named = version.isEmpty || version == "unknown" ? name : "\(name) \(version)"
            return "Your \(named) is too old for VoxClip. Update it, then check it in Settings › AI."
        default: return "VoxClip couldn't check \(name). Check it in Settings › AI."
        }
    }

    /// The blocked card's one action.
    func fixClaudeModeBlocker() {
        guard case .blocked(let blocker) = claudeMode.phase else { return }
        switch blocker {
        case .setUp: openVoxClipSettings(pane: "ai")
        case .aiSettings:
            app.settingsPane = "ai"
            openVoxClipSettings()
        case .approveSend, .findAgain:
            claudeMode.phase = .waiting
            clipError = nil
            claudeMode.clock?.begin(.find)
            retryFindClips()
        }
    }

    /// Make top N postable with the per-video cap as its budget: the cap is the approval for paid voice and music.
    private func startClaudeMode() {
        guard claudeMode.armed, makeIt.active == nil, capabilities.ai, capabilities.edit else { return }
        let settings = clipsAutopilot
        let budget = MakeItBudget(cap: Decimal(settings.capUSD))
        claudeMode.armed = false
        claudeMode.found = suggestedClips.count
        claudeMode.budget = budget
        let clock = claudeMode.clock ?? ClaudeModeClock()
        claudeMode.clock = clock
        makeTopPostable(settings.count, budget: budget, clock: clock)
        claudeMode.clipIDs = makeIt.series
        guard !claudeMode.clipIDs.isEmpty else { claudeMode.phase = .blocked(.findAgain("Claude couldn't start on these clips.")); return }
        claudeMode.phase = .running
        announce("Claude is making \(claudeMode.clipIDs.count) clips.")
        claudeMode.task = Task { [weak self] in
            await self?.makeIt.waitForQueue()
            self?.claudeModeFinished()
        }
    }

    private func claudeModeFinished() {
        let runs = claudeModeRuns
        claudeMode.phase = runs.contains { $0.phase == .stopped } ? .stopped : .done
        let ready = claudeModeReady.count
        announce(claudeMode.phase == .done ? "\(ready) \(ready == 1 ? "clip" : "clips") ready. Next: Export all." : "Stopped. What was done is kept.")
        // Numbers only (ai.md §16.12): each stage's wall time, never a title, word or path.
        if let clock = claudeMode.clock {
            let log = app.log
            Task { await log.write(LogEntry(level: .info, category: "claude-mode", message: clock.logLine())) }
        }
    }

    /// Stop: the clip in progress ends at its next safe point; finished clips stay.
    func stopClaudeMode() {
        guard claudeMode.running else { return }
        stopMakeIt()
    }

    /// Continue at the cap: approves exactly the amount shown. The one action behind both entry points, the sidebar card
    /// and the Make it panel's footer (`capContinueAction`).
    func continueClaudeMode() { claudeMode.budget?.approveNeeded() }

    /// The priced primary while a step waits at the video's cap, "Continue · $0.40"; nil while nothing waits. `id` names
    /// the entry point for evidence; the action is always `continueClaudeMode()`.
    func capContinueAction(id: String) -> PanelAction? {
        guard let needed = claudeMode.budget?.needed else { return nil }
        return PanelAction(id: id, title: "Continue · " + Self.makeItDollars(needed), priced: true) { [weak self] in self?.continueClaudeMode() }
    }

    /// "Continue approves exactly $0.40 more for voice or music on this video."
    nonisolated static func capContinueNote(_ needed: Decimal) -> String {
        "Continue approves exactly \(makeItDollars(needed)) more for voice or music on this video."
    }

    var claudeModeRuns: [MakeItRun] { claudeMode.clipIDs.compactMap { makeIt.run(for: $0) } }
    var claudeModeReady: [MakeItRun] { claudeModeRuns.filter { $0.phase == .ready } }

    // MARK: The card's lines

    enum ClaudeClipState: Equatable { case ready, making, waiting, stopped, failed }

    /// The clip row's pill while Claude mode makes it: Ready, Making… or Waiting.
    func claudeClipState(_ clipID: String) -> ClaudeClipState? {
        guard claudeMode.clipIDs.contains(clipID), let run = makeIt.run(for: clipID) else { return nil }
        switch run.phase {
        case .ready: return .ready
        case .stopped: return .stopped
        case .failed: return .failed
        case .applying: return .making
        case .planning: return run.lines.last == "Waiting for Claude…" && makeIt.shownClipID != clipID ? .waiting : .making
        }
    }

    struct ClaudeStep: Identifiable, Equatable {
        enum State: Equatable { case done, now, todo, note }
        let id: String
        var state: State
        var text: String
        var detail = ""
    }

    /// Card C's steps: the transcript, Find Clips, then each clip.
    var claudeModeSteps: [ClaudeStep] {
        var steps: [ClaudeStep] = []
        if let transcript = project.transcript {
            let seconds = transcript.words.last?.end ?? 0
            steps.append(ClaudeStep(id: "transcribed", state: .done, text: "Transcribed \(durationLabel(seconds))"))
        } else {
            steps.append(ClaudeStep(id: "transcribed", state: .now, text: transcription.isRunning ? "Transcribing…" : "Waiting for the transcript"))
        }
        if let name = claudeMode.checking { steps.append(ClaudeStep(id: "checking", state: .now, text: "Checking \(name)…")) }
        if finding {
            steps.append(ClaudeStep(id: "found", state: .now, text: "Finding clips…"))
        } else if claudeMode.found > 0 {
            steps.append(ClaudeStep(id: "found", state: .done, text: "Found the best moments", detail: "\(claudeMode.found) · top \(claudeMode.clipIDs.count) kept"))
        }
        for (index, run) in claudeModeRuns.enumerated() {
            let number = index + 1
            let title = project.edits.clips.first { $0.id == run.clipID }?.title.map { " “\($0)”" } ?? ""
            switch run.phase {
            case .ready: steps.append(ClaudeStep(id: run.clipID, state: .done, text: "Clip \(number)\(title) ready", detail: durationLabel(run.seconds)))
            case .stopped: steps.append(ClaudeStep(id: run.clipID, state: .note, text: "Clip \(number) stopped · what was done is kept"))
            case .failed(let message): steps.append(ClaudeStep(id: run.clipID, state: .note, text: "Clip \(number): \(message)"))
            case .planning where claudeClipState(run.clipID) == .waiting:
                steps.append(ClaudeStep(id: run.clipID, state: .todo, text: "Clip \(number) waits"))
            case .planning, .applying:
                steps.append(ClaudeStep(id: run.clipID, state: .now, text: "Clip \(number): " + Self.claudeLine(run.lines.last ?? "Reading the clip…"),
                                        detail: run.spent > 0 ? Self.makeItDollars(run.spent) : ""))
            }
        }
        return steps
    }

    /// A run's progress line, as the card says it: "Voicing 2 fixes…" reads "rewording 2 phrases in your voice…".
    static func claudeLine(_ line: String) -> String {
        if line.hasPrefix("Voicing "), let count = Int(line.dropFirst(8).prefix { $0.isNumber }) {
            return "rewording \(count) \(count == 1 ? "phrase" : "phrases") in your voice…"
        }
        guard let first = line.first else { return line }
        return first.lowercased() + line.dropFirst()
    }

    /// "Spent $0.42 of $2.00".
    var claudeModeSpent: String {
        guard let budget = claudeMode.budget else { return "" }
        return "Spent \(Self.makeItDollars(budget.spent)) of \(Self.makeItDollars(budget.approved))"
    }

    /// Card C's footer: what was spent and the next step.
    var claudeModeFooter: String {
        if claudeMode.budget?.needed != nil { return claudeModeSpent + " · Next: Continue, or Stop to keep what's done." }
        return claudeModeSpent + " · Next: wait, or Stop to keep what's done."
    }

    /// Card D's summary: "Spent $0.61 of $2.00 · 4 phrases in your voice · music from the free library".
    var claudeModeSummary: String {
        let runs = claudeModeRuns
        let voiced = runs.flatMap(\.rows).filter { $0.id.hasPrefix("rewrite-") && $0.undoable && !$0.undone }.count
        let music = runs.compactMap { run -> MusicSource? in
            guard case .music(let added)? = run.inverses["music"], MusicProject.entry(for: run.clipID, in: project) == added else { return nil }
            return added.source
        }
        var parts = [claudeModeSpent]
        parts.append(voiced == 0 ? "your own words" : "\(voiced) \(voiced == 1 ? "phrase" : "phrases") in your voice")
        if music.contains(.generated) { parts.append("generated music") }
        if music.contains(.library) { parts.append("music from the free library") }
        if music.contains(.file) { parts.append("music from your folder") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The shapes Export all renders: the clip style's.
    var claudeModeShapes: [AspectRatio] { makeItStyle.shapes }

    /// "Export all 3 · 16:9 + 9:16".
    var claudeExportAllTitle: String {
        let count = claudeModeReady.count
        return "Export all \(count) · " + claudeModeShapes.map(\.rawValue).joined(separator: " + ")
    }

    var canClaudeExportAll: Bool { !claudeModeReady.isEmpty && canExport && mediaExportable && !exporting }

    /// Card D's next step.
    var claudeModeNextStep: String {
        if exporting { return "Next: wait for the export." }
        if !exports.isEmpty, claudeModeExported { return "Next: post them. The first post text is copied; each is beside its video." }
        return "Next: Export. Each post text is copied beside its video."
    }

    /// The last export was this Export all.
    var claudeModeExported: Bool {
        let ids = Set(claudeModeReady.map(\.clipID))
        return !ids.isEmpty && !exporting && Set(exportClipIDs) == ids
    }

    /// The export under way is this Export all.
    var claudeModeExportRunning: Bool { exporting && Set(exportClipIDs) == Set(claudeModeReady.map(\.clipID)) }

    // MARK: Export all

    /// Every ready clip in its style's shapes, into the export folder. Each post text is written beside its videos as
    /// `<name>.txt`, and the first one is copied. A file that fails is named; the rest still render.
    func claudeExportAll() {
        let runs = claudeModeReady
        guard canClaudeExportAll, let first = runs.first else { return }
        let folder = ExportSelection.folder(project.export.folder ?? app.string("export.folder", fallback: "~/Movies/VoxClip"))
        var texts: [String: String] = [:]
        for run in runs { texts[run.clipID] = makeItPostCopy(run) }
        copyMakeItPostText(first)
        beginExport(targets: runs.map { .clip($0.clipID) }, folder: folder, aspects: claudeModeShapes, postTexts: texts, keepGoing: true)
    }

    /// Review: the Make it postable panel, on the first ready clip (its series list reaches the others).
    func reviewClaudeMode() {
        guard let first = claudeModeReady.first ?? claudeModeRuns.first else { return }
        makeIt.shownClipID = first.clipID
        _ = setScope(first.clipID)
        onShowMakeIt?()
    }

    // MARK: Status bar

    /// "✦ Claude does it all · top 3 · ≤$2" (or "· $0.42 / $2" while it runs); "Choose how clips are made" until chosen;
    /// nil in "I'll pick" mode, where the clip style item reads "Style: …".
    var statusClaudeMode: StatusItem? {
        let settings = clipsAutopilot
        switch settings.mode {
        case .claude?:
            var text = settings.summary
            if claudeMode.running, let budget = claudeMode.budget {
                // Each clip is ready on its own (design.md §6.7): "2 of 3 ready" counts them as they come.
                text = "✦ Claude does it all · \(claudeModeReady.count) of \(claudeMode.clipIDs.count) ready · \(Self.makeItDollars(budget.spent)) / $\(settings.capUSD)"
            } else if claudeMode.armed, finding {
                text = "✦ Claude does it all · Finding clips…"
            }
            return StatusItem(kind: .clipStyle, parts: [StatusText(string: text)], dim: false,
                              spoken: text.replacingOccurrences(of: "✦ ", with: "").replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "≤", with: "up to "),
                              help: capabilities.edit ? "Change how clips are made." : nil)
        case nil:
            guard showsClipsModeCard else { return nil }
            let text = "Choose how clips are made"
            return StatusItem(kind: .clipStyle, parts: [StatusText(string: text)], dim: true, spoken: text, help: "Who makes the clips: Claude, or you.")
        case .pick?: return nil
        }
    }
}
