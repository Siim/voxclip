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
    /// No AI is chosen, or the chosen CLI is missing or signed out: Settings › AI.
    case setUp(String)
    /// The chosen AI bills each send to a key: Find Clips asks inline first.
    case approveSend(String)
    /// Find Clips failed or found nothing: Find Clips again.
    case findAgain(String)

    var reason: String {
        switch self { case .setUp(let text), .approveSend(let text), .findAgain(let text): text }
    }
    var action: String {
        switch self {
        case .setUp: "Set Up Claude Code…"
        case .approveSend: "Find Clips"
        case .findAgain: "Find Clips Again"
        }
    }
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
    /// The run's queue, from the start to the last clip.
    @ObservationIgnored var task: Task<Void, Never>?
    /// Going on once Find Clips' task has ended.
    @ObservationIgnored var afterFind: Task<Void, Never>?

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
        if mode == .claude { claudeModeContinue() } else if case .blocked = claudeMode.phase { claudeMode.phase = .idle }
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
        if claudeModeOn { claudeMode.phase = .waiting }
    }

    /// Claude mode takes the transcript on: Find Clips after any transcription, not only a free one.
    var claudeModeWaitsForTranscript: Bool { claudeMode.armed && claudeModeOn }

    /// The transcript arrived; `started` says whether Find Clips started by itself.
    func claudeModeTranscribed(started: Bool) {
        guard claudeMode.armed, claudeModeOn else { return }
        if started || finding { claudeMode.phase = .waiting; return }
        claudeModeContinue()
    }

    /// Find Clips ended (found, nothing, failed or cancelled). It is called from inside the find task, which still holds
    /// `finding` and the project's AI lease, so Claude goes on once that task has ended.
    func claudeModeFindEnded() {
        guard claudeMode.armed, claudeModeOn else { return }
        let find = findTask
        claudeMode.afterFind = Task { [weak self] in
            await find?.value
            self?.claudeModeContinue()
        }
    }

    /// Goes as far as it can: starts the run when there are suggestions, starts Find Clips when it is free, else says
    /// what blocks it.
    func claudeModeContinue() {
        guard claudeMode.armed, claudeModeOn, capabilities.edit, transcribed || project.transcript != nil else { return }
        if finding { claudeMode.phase = .waiting; return }
        if !suggestedClips.isEmpty { startClaudeMode(); return }
        if project.ai.results.isEmpty, findClipsIfFree() { claudeMode.phase = .waiting; return }
        claudeMode.phase = .blocked(claudeModeBlocker)
    }

    /// Why Claude can't find the clips by itself, with the fix.
    var claudeModeBlocker: ClaudeModeBlocker {
        if let error = clipError, !project.ai.results.isEmpty || error == Self.noClipsMatched {
            return .findAgain(error == Self.noClipsMatched ? "Claude found no clip worth posting in this video." : error)
        }
        guard let connector = ConnectorID(rawValue: app.string("llm.connector")), app.providers.contains(where: { $0.id == connector.rawValue }) else {
            return .setUp("Claude isn't set up yet. Choose Claude Code in Settings › AI, then Claude starts on its own.")
        }
        switch app.llmSendKind(connector) {
        case nil:
            return .setUp("\(findConnector?.label ?? "Claude Code") isn't installed or signed in. Set it up in Settings › AI.")
        case .inline(let amount)? where !amount.isEmpty:
            return .approveSend("\(findConnector?.label ?? "This AI") bills each send to your key, so Claude waits for your OK to find clips.")
        default:
            if let error = clipError { return .findAgain(error) }
            return .approveSend("Claude waits for your OK to read the transcript and find clips.")
        }
    }

    /// The blocked card's one action.
    func fixClaudeModeBlocker() {
        guard case .blocked(let blocker) = claudeMode.phase else { return }
        switch blocker {
        case .setUp: openVoxClipSettings(pane: "ai")
        case .approveSend, .findAgain:
            claudeMode.phase = .waiting
            clipError = nil
            findClips()
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
        makeTopPostable(settings.count, budget: budget)
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
    }

    /// Stop: the clip in progress ends at its next safe point; finished clips stay.
    func stopClaudeMode() {
        guard claudeMode.running else { return }
        stopMakeIt()
    }

    /// Continue at the cap: approves exactly the amount shown.
    func continueClaudeMode() { claudeMode.budget?.approveNeeded() }

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
        if finding {
            steps.append(ClaudeStep(id: "found", state: .now, text: "Finding the best moments…"))
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
        let music = runs.flatMap(\.rows).filter { $0.id == "music" && $0.undoable && !$0.undone }
        var parts = [claudeModeSpent]
        parts.append(voiced == 0 ? "your own words" : "\(voiced) \(voiced == 1 ? "phrase" : "phrases") in your voice")
        if music.contains(where: { $0.text.hasSuffix("(generated)") }) { parts.append("generated music") }
        else if !music.isEmpty { parts.append("music from the free library") }
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
                text = "✦ Claude does it all · \(Self.makeItDollars(budget.spent)) / $\(settings.capUSD)"
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
