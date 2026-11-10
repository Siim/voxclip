import Foundation
import Observation
import VoxClipCore

/// One change's talk with Claude (design.md §6.3 "Talk back to Claude", ADR-R50): every version of its new words, the
/// version in the text, the turns, and Claude's next steps from its last reply. It lives on the proposal
/// (`TranscriptProposal.threads`), so it is gone once the change is kept or undone, or the proposal is closed. A
/// change with no thread yet has one version, its words as they read now.
struct RewriteThread: Equatable {
    struct Version: Equatable {
        var text: String
        /// Claude's note when a reply made it; nil for the Rewrite's own first version and for your own words.
        var note: String?
        /// Your own words ("✎ My own words"), typed and applied here with no request: "‹ 3 of 3 › · your words".
        var yours = false
    }
    struct Turn: Equatable {
        /// `yours` is your own words put in place, "You · your own words: “…”": a turn of the thread, not a message to Claude.
        enum Speaker: Equatable { case you, claude, yours }
        let speaker: Speaker
        let text: String
    }
    var versions: [Version]
    /// The version in the text now, an index into `versions`.
    var current = 0
    var turns: [Turn] = []
    /// Claude's own next steps for this text, from its last reply: the thread's ✦ bubbles.
    var nextSteps: [String] = []

    init(text: String) { versions = [Version(text: text, note: nil)] }
    /// What the user said about the change, in order: every message the next request carries.
    var messages: [String] { turns.filter { $0.speaker == .you }.map(\.text) }
    /// The thread with `text`, the change's words as they read now, as its current version. A local edit made them
    /// differ (the wording fit, an edit of the change); they become a version of their own, so the next request and
    /// the arrows read what the text shows.
    func following(_ text: String) -> RewriteThread {
        guard RewriteFollowupPrompt.key(versions[current].text) != RewriteFollowupPrompt.key(text) else { return self }
        var next = self
        if let found = versions.firstIndex(where: { RewriteFollowupPrompt.key($0.text) == RewriteFollowupPrompt.key(text) }) { next.current = found }
        else { next.versions.append(Version(text: text, note: nil)); next.current = next.versions.count - 1 }
        return next
    }
}

/// What the AI answers a thread with: the live connector after its inline consent, or a test's or the smoke's stand-in.
struct RewriteThreadBackend {
    let send: @MainActor (RewriteFollowupRequest) async throws -> RewriteFollowupReply
}

/// The thread's input and request (design.md §6.3): one per editor, for the focused change. The words typed, the
/// request in flight, an error and a fold belong to one change of one proposal (`Key`).
@MainActor @Observable final class RewriteThreadState {
    struct Key: Equatable, Hashable { let proposal: UUID; let ordinal: Int }
    var text = ""
    /// The change `text` and `error` belong to; a focus move to another change starts with an empty input.
    var key: Key?
    /// The change whose request is in flight.
    private(set) var sending: Key?
    var error: String?
    /// The message that failed, which Try Again sends again.
    var failed: (message: String, kind: RewriteFollowupRequest.Kind)?
    /// The change whose thread Esc folded; focusing that change again opens it.
    var folded: Key?
    /// The thread view's measured height, which the transcript keeps free under the change's paragraph. The text view
    /// measures it and renders again itself, so it is not observed.
    @ObservationIgnored var height: Double = 0
    /// The prompt's bubbles and limits, read once.
    @ObservationIgnored var prompt: RewriteFollowupPrompt?
    /// Moves when Return, F2 or a click on the change's new words asks the input to take the keys.
    var focusRequest = 0
    /// The change whose input takes your own words ("✎ My own words", ⌥E): ↵ puts them in place as a version, and nothing
    /// is sent. Nil is Claude mode.
    var ownWords: Key?
    /// What the input held for Claude when your own words took it, given back when they leave.
    @ObservationIgnored var draft = ""
    /// A version, Claude's or your own words, that waits for the paid takes' discard before it goes into the text. Only
    /// one waits: a later version replaces it. It waits while the Rewrite panel's question with `token` stands.
    struct Waiting: Equatable {
        let key: Key
        let token: UUID
        /// The paid takes it replaces; 0 while the first ones are still being made.
        let takes: Int
    }
    var waiting: Waiting?
    /// The inline connector confirmation, as Ask Claude's (consent action `rewrite`).
    let confirmation = ConnectorConfirmation()
    @ObservationIgnored var task: Task<Void, Never>?
    func begin(_ key: Key, task: Task<Void, Never>) { sending = key; self.task = task }
    func end(_ key: Key) { if sending == key { sending = nil; task = nil } }
    /// Moves the input to `key`, keeping what it holds when the key is the same.
    func follow(_ key: Key) {
        guard self.key != key else { return }
        self.key = key; text = ""; error = nil; failed = nil; ownWords = nil; draft = ""
    }
}

/// The focused change's thread as the transcript shows it (`RewriteThreadView`).
struct RewriteThreadDisplay: Equatable {
    let key: RewriteThreadState.Key
    let ordinal: Int
    /// The last two turns; older ones fold into the versions.
    let turns: [RewriteThread.Turn]
    /// 1-based: "‹ 2 of 2 ›".
    let version: Int
    let versions: Int
    /// The change's parts to voice at Keep; 0 is "text only, free".
    let voicePhrases: Int
    /// ✦ bubbles from Claude's last reply, at most two.
    let steps: [String]
    let keep: String
    let steady: [String]
    /// "Free on your Claude plan" or "Billed to your Anthropic key".
    let costLine: String
    let sending: Bool
    let error: String?
    /// The failed message Try Again sends; false for an error with nothing to send again.
    var retry = false
    /// The version in the text is your own words.
    var yours = false
    /// The input takes your own words, not a message to Claude.
    var ownWords = false
    /// A version waits for the paid takes' discard: "Waiting: this replaces 2 paid takes. Confirm in the Rewrite panel to use it."
    var waiting: String? = nil
    static let ownWordsBubble = "\u{270E} My own words"
    static let ownWordsPlaceholder = "Your exact words \u{00B7} \u{21B5} applies \u{00B7} Esc cancels"
    static let ownWordsCostLine = "Free \u{00B7} nothing is sent"
    var versionLine: String { "\(version) of \(versions)" }
    /// "· your words" after the arrows when the version in the text is yours.
    var yoursLine: String? { yours ? "\u{00B7} your words" : nil }
    /// Beside the input: the AI's cost line, or "Free · nothing is sent" for your own words.
    var inputCostLine: String { ownWords ? Self.ownWordsCostLine : costLine }
    /// "· 3 phrases to voice at Keep" or "· text only, free".
    var phrasesLine: String {
        voicePhrases == 0 ? "\u{00B7} text only, free" : "\u{00B7} \(voicePhrases) phrase\(voicePhrases == 1 ? "" : "s") to voice at Keep"
    }
    var label: String { "Talk to Claude about change \(ordinal)" }
    /// The waiting line for a version that replaces `takes` paid takes (0: the takes still being made).
    static func waitingLine(takes: Int) -> String {
        let what = takes == 0 ? "your paid takes" : takes == 1 ? "1 paid take" : "\(takes) paid takes"
        return "Waiting: this replaces \(what). Confirm in the Rewrite panel to use it."
    }
}

extension EditorModel {
    /// "Free on your Claude plan", "Free on your ChatGPT plan", "Billed to your Anthropic key" or "Free on this Mac": the
    /// cost line Ask Claude's field and the Rewrite thread's input show for `provider` (design.md §6.8).
    static func costLine(_ provider: ProviderChoice?) -> String {
        guard let provider else { return "" }
        if provider.cliName != nil { return provider.id == "claude-code" ? "Free on your Claude plan" : "Free on your ChatGPT plan" }
        if provider.group == "apiKey" { return "Billed to your \(provider.label) key" }
        return "Free on this Mac"
    }

    /// The prompt's bubbles and limits, read once; nil without the shared resources.
    var rewriteFollowupPrompt: RewriteFollowupPrompt? {
        if let prompt = rewriteThread.prompt { return prompt }
        let loaded = app.shared.flatMap { try? RewriteFollowupPrompt.load(shared: $0) }
        rewriteThread.prompt = loaded
        return loaded
    }

    /// The change a thread would show for: the focused one, pending, with Keep and Undo, in the open Rewrite's own
    /// proposal, while its wording is not being fitted. The cheap checks come first: a proposal with no Rewrite of its
    /// own costs nothing here.
    private func rewriteThreadTarget(_ shown: TranscriptProposalDisplay?) -> (key: RewriteThreadState.Key, change: TranscriptChange, session: RewriteSession)? {
        // Editing, not `ai`: the thread's own request holds the project's AI lease, and the thread stays while it runs.
        guard capabilities.edit, let proposal, let session = openRewrite, session.ownProposal?.id == proposal.id, !session.wordingIsLocked,
              let display = shown, let focused = display.focused, !display.actions.isEmpty,
              let change = proposal[focused], change.state == .pending, change.reviewable else { return nil }
        return (RewriteThreadState.Key(proposal: proposal.id, ordinal: focused), change, session)
    }
    private var rewriteThreadTarget: (key: RewriteThreadState.Key, change: TranscriptChange, session: RewriteSession)? {
        guard openRewrite?.ownProposal != nil else { return nil }
        return rewriteThreadTarget(proposalDisplay)
    }

    /// Where the transcript shows a thread and how much room it keeps under the change's paragraph.
    struct RewriteThreadSlot: Equatable {
        let ordinal: Int
        let height: Double
    }
    /// The thread's slot for the proposal as `display` shows it, nil where no thread shows (folded included).
    func rewriteThreadSlot(_ display: TranscriptProposalDisplay?) -> RewriteThreadSlot? {
        guard openRewrite?.ownProposal != nil, let target = rewriteThreadTarget(display), rewriteThread.folded != target.key else { return nil }
        return RewriteThreadSlot(ordinal: target.key.ordinal, height: rewriteThread.height)
    }

    /// The change's thread as it stands: its stored one following the words in the text, or a new one.
    func rewriteThread(_ ordinal: Int) -> RewriteThread? {
        guard let proposal, proposal[ordinal] != nil else { return nil }
        let text = changeText(ordinal)
        return proposal.threads[ordinal]?.following(text) ?? RewriteThread(text: text)
    }

    /// The focused change's thread, or nil where none shows: no Rewrite of its own, not pending, folded with Esc.
    var rewriteThreadDisplay: RewriteThreadDisplay? {
        guard let target = rewriteThreadTarget, rewriteThread.folded != target.key, let thread = rewriteThread(target.key.ordinal) else { return nil }
        let state = rewriteThread, prompt = rewriteFollowupPrompt
        let mine = state.key == target.key
        return RewriteThreadDisplay(key: target.key, ordinal: target.key.ordinal, turns: Array(thread.turns.suffix(2)), version: thread.current + 1,
                                    versions: thread.versions.count, voicePhrases: target.change.parts.filter { $0.kind == .voice }.count,
                                    steps: Array(thread.nextSteps.prefix(prompt?.maxNextSteps ?? 2)), keep: prompt?.keepBubble ?? "",
                                    steady: prompt?.steadyBubbles ?? [], costLine: Self.costLine(target.session.provider),
                                    sending: state.sending == target.key, error: mine ? state.error : nil, retry: mine && state.failed != nil,
                                    yours: thread.versions[thread.current].yours, ownWords: state.ownWords == target.key,
                                    waiting: rewriteThreadWaiting(target.key, session: target.session).map { RewriteThreadDisplay.waitingLine(takes: $0.takes) })
    }

    /// The version waiting for change `key`: only while the Rewrite panel still asks its question. Keep Working, or
    /// anything else that takes the question away, ends the wait with nothing changed.
    private func rewriteThreadWaiting(_ key: RewriteThreadState.Key, session: RewriteSession) -> RewriteThreadState.Waiting? {
        guard let waiting = rewriteThread.waiting, waiting.key == key, session.task.confirm?.owner == waiting.token else { return nil }
        return waiting
    }

    /// Where a thread version went: into the text now, waiting for the paid takes' discard, or nowhere.
    enum RewriteThreadPlacement { case placed, waiting, failed }

    /// Puts a thread version, Claude's or your own words, in change `key`'s place: the local edit, then the Rewrite's own
    /// words for the change (`acceptThreadWords`), then `land` records it in the thread. With paid takes it waits for the
    /// discard instead (design.md §6.3 "Talk back to Claude", "Paid takes"): the thread says so, and the Rewrite panel
    /// asks. Discard Changes puts it in and records it, as any version; Keep Working changes nothing. A later version
    /// replaces a waiting one, so only one waits.
    func placeRewriteThreadVersion(_ key: RewriteThreadState.Key, text: String,
                                   land: @escaping @MainActor () -> Void) -> RewriteThreadPlacement {
        guard let session = openRewrite, session.changeNeedsDiscard else {
            guard editChange(key.ordinal, text: text) else { return .failed }
            try? openRewrite?.acceptThreadWords(key.ordinal, text: text)
            land()
            return .placed
        }
        let token = UUID(), state = rewriteThread
        state.waiting = .init(key: key, token: token, takes: session.paidTakeCount)
        state.error = nil; state.failed = nil
        _ = session.confirmPaidProposalChange(owner: token) { [weak self] in
            guard let self, state.waiting?.token == token else { return }
            state.waiting = nil
            guard proposal?.id == key.proposal, proposal?[key.ordinal]?.state == .pending, editChange(key.ordinal, text: text) else {
                if state.key == key { state.error = "The new words couldn't be put in the text. Your edits are saved." }
                return
            }
            try? openRewrite?.acceptThreadWords(key.ordinal, text: text)
            land()
        }
        announce(RewriteThreadDisplay.waitingLine(takes: session.paidTakeCount))
        return .waiting
    }

    /// The change's recorded words: its span as the take reads it, corrected spelling included.
    func recordedText(_ ordinal: Int) -> String {
        guard let change = proposal?[ordinal] else { return "" }
        let index = wordIndex, corrections = project.edits.corrections
        return change.span.compactMap { id in index[id].map { corrections[id] ?? words[$0].text } }.joined(separator: " ")
    }

    // MARK: Sending

    /// Sends `message` about the focused change (↵, a bubble, Try Again). "3 more versions" asks for alternatives. The
    /// input keeps its text until the reply is in; an error shows in place and keeps it; nothing is voiced or paid.
    func sendRewriteThread(_ message: String, kind: RewriteFollowupRequest.Kind = .reply, fromInput: Bool = false) {
        let words = AIText.trim(message)
        guard !words.isEmpty, let target = rewriteThreadTarget, rewriteThread.sending == nil, let thread = rewriteThread(target.key.ordinal) else { return }
        let key = target.key, session = target.session
        let request = RewriteFollowupRequest(kind: kind, scope: Self.followupScope(session.rewriteScope), language: project.transcript?.language ?? "en",
                                             source: session.source.filter { $0.kind == .word }.map(\.text).joined(separator: " "),
                                             ordinal: key.ordinal, recorded: recordedText(key.ordinal), versions: thread.versions.map(\.text),
                                             messages: thread.messages + [words])
        let state = rewriteThread
        state.follow(key)
        // A bubble or Try Again talks to Claude: the input leaves your own words first, with nothing put in place.
        if state.ownWords != nil { leaveRewriteThreadOwnWords(focus: false) }
        state.error = nil; state.failed = nil
        let backend = rewriteThreadBackend ?? liveRewriteThreadBackend
        announce(kind == .versions ? "Asking Claude for 3 more versions" : "Asking Claude")
        state.begin(key, task: Task { [self] in
            defer { state.end(key) }
            do {
                let reply = try await backend.send(request)
                try Task.checkCancellation()
                receiveRewriteThread(reply, message: words, kind: kind, key: key, fromInput: fromInput)
            } catch is CancellationError {} catch LLMError.cancelled {} catch {
                guard proposal?.id == key.proposal else { return }
                let line = await openRewrite?.panelError(error).line ?? (error as? LLMError)?.userMessage(label: "Claude", feature: .voiceRewrite) ?? ""
                guard state.key == key else { return }
                state.error = line.isEmpty ? "Claude couldn't answer. Try Again. Your edits are saved." : line
                state.failed = (words, kind)
                announce(state.error ?? "")
            }
        })
    }

    /// Try Again after an error: the failed message, sent again.
    func retryRewriteThread() {
        guard let failed = rewriteThread.failed else { return }
        sendRewriteThread(failed.message, kind: failed.kind, fromInput: AIText.trim(rewriteThread.text) == failed.message)
    }

    /// A bubble: "✓ That's it, keep it" is exactly Keep; "✎ My own words" switches the input to your own words and back;
    /// "3 more versions" asks for alternatives; any other bubble, ✦ or steady, sends its words as your message.
    func pressRewriteThreadBubble(_ title: String) {
        guard let display = rewriteThreadDisplay else { return }
        if title == display.keep { keepChange(display.ordinal); return }
        if title == RewriteThreadDisplay.ownWordsBubble { toggleRewriteThreadOwnWords(); return }
        let more = rewriteFollowupPrompt?.steadyBubbles.last
        sendRewriteThread(title, kind: title == more ? .versions : .reply)
    }

    /// Stop while Claude works: the request is cancelled, nothing changes and the input keeps its text.
    func stopRewriteThread() {
        rewriteThread.task?.cancel()
        rewriteThread.confirmation.cancel()
        if let key = rewriteThread.sending { rewriteThread.end(key) }
        announce("Stopped. Nothing changed.")
    }

    /// Claude's reply: a new version (or three for "3 more versions"), put in the change's place through the local edit,
    /// so its diff, kinds, fit and cost are worked out again here. Words that match the version in the text add none,
    /// and Claude's line says so.
    func receiveRewriteThread(_ reply: RewriteFollowupReply, message: String, kind: RewriteFollowupRequest.Kind, key: RewriteThreadState.Key,
                              fromInput: Bool) {
        guard proposal?.id == key.proposal, proposal?[key.ordinal]?.state == .pending, var thread = rewriteThread(key.ordinal) else { return }
        let count = thread.versions.count
        var note = reply.note
        var target: Int?
        for text in reply.texts {
            if let found = thread.versions.firstIndex(where: { RewriteFollowupPrompt.key($0.text) == RewriteFollowupPrompt.key(text) }) {
                if kind == .reply { target = found }
                continue
            }
            thread.versions.append(.init(text: text, note: reply.note))
            if target == nil || target.map({ $0 < count }) == true { target = thread.versions.count - 1 }
        }
        if kind == .reply, target == thread.current {
            note = "Kept the words as they are." + (note.isEmpty ? "" : " " + note)
        } else if note.isEmpty {
            note = kind == .versions ? "\(thread.versions.count - count) more versions." : "Changed the words."
        }
        thread.turns += [.init(speaker: .you, text: message), .init(speaker: .claude, text: note)]
        thread.nextSteps = reply.nextSteps
        let record: @MainActor (Int) -> Void = { [weak self] current in
            guard let self, var proposal, proposal.id == key.proposal, proposal[key.ordinal]?.state == .pending else { return }
            var thread = thread
            thread.current = current
            proposal.threads[key.ordinal] = thread
            self.proposal = proposal
            if fromInput, rewriteThread.key == key { rewriteThread.text = "" }
            announce("Claude: \(note) Version \(current + 1) of \(thread.versions.count).")
        }
        guard let target, target != thread.current else { record(thread.current); return }
        // Claude's words, not a hand edit: the Rewrite reviews and voices them at Keep. With paid takes they wait for the
        // discard, and the reply's versions and turns come into the thread only once they are in the text.
        if placeRewriteThreadVersion(key, text: thread.versions[target].text, land: { record(target) }) == .failed {
            rewriteThread.error = "The new words couldn't be put in the text. Your edits are saved."
        }
    }

    // MARK: Versions and folding

    /// ‹ and ›, ⌥← and ⌥→: the change's text becomes the previous or next version through the local edit. Nothing is sent,
    /// and no undo step is added.
    @discardableResult func switchRewriteThreadVersion(by step: Int) -> Bool {
        guard let target = rewriteThreadTarget, var thread = rewriteThread(target.key.ordinal) else { return false }
        let next = thread.current + step, key = target.key
        guard thread.versions.indices.contains(next) else { return false }
        thread.current = next
        return placeRewriteThreadVersion(key, text: thread.versions[next].text) { [weak self] in
            // Words equal to the recorded ones leave nothing to change: the edit left the change out, and its thread goes with it.
            guard let self, var proposal, proposal.id == key.proposal, proposal[key.ordinal]?.state == .pending else { return }
            proposal.threads[key.ordinal] = thread
            self.proposal = proposal
            announce("Version \(next + 1) of \(thread.versions.count)")
        } != .failed
    }

    /// Esc: the thread folds; the version stays in the text, and focusing the change again opens it.
    func foldRewriteThread() {
        guard let display = rewriteThreadDisplay else { return }
        rewriteThread.folded = display.key
        announce("Folded the talk about change \(display.ordinal)")
    }

    /// Return, F2, a click on the change's new words and VoiceOver's Edit change: the thread opens and its input takes the keys.
    @discardableResult func openRewriteThreadInput() -> Bool {
        if let folded = rewriteThread.folded, folded.ordinal == proposal?.focused { rewriteThread.folded = nil }
        guard let display = rewriteThreadDisplay else { return false }
        rewriteThread.follow(display.key)
        rewriteThread.focusRequest += 1
        return true
    }

    // MARK: Your own words

    /// "✎ My own words" and ⌥E: the bubble switches the input to your own words, and again back to Claude.
    func toggleRewriteThreadOwnWords() {
        if let own = rewriteThread.ownWords, own == rewriteThreadDisplay?.key { leaveRewriteThreadOwnWords(); return }
        openRewriteThreadOwnWords()
    }

    /// The input takes the change's words as the text shows them, the cursor at their end, for you to type over. What it
    /// held for Claude comes back when your own words leave. False where no thread shows or Claude is working.
    @discardableResult func openRewriteThreadOwnWords() -> Bool {
        if let folded = rewriteThread.folded, folded.ordinal == proposal?.focused { rewriteThread.folded = nil }
        guard let display = rewriteThreadDisplay, !display.sending else { return false }
        let state = rewriteThread
        state.follow(display.key)
        if state.ownWords != display.key {
            state.draft = state.text
            state.text = changeText(display.ordinal)
            state.ownWords = display.key
        }
        state.focusRequest += 1
        announce("Your own words for change \(display.ordinal). Return puts them in place, Escape cancels. Nothing is sent.")
        return true
    }

    /// Esc, or the bubble again: back to Claude with nothing changed; the input holds what it held for Claude.
    func leaveRewriteThreadOwnWords(focus: Bool = true) {
        let state = rewriteThread
        guard state.ownWords != nil else { return }
        state.ownWords = nil
        state.text = state.draft
        state.draft = ""
        guard focus else { return }
        state.focusRequest += 1
        announce("Back to talking to Claude. Nothing changed.")
    }

    /// ↵ with your own words: they go into the change's place as a new version, "your words", through the local edit
    /// Claude's versions take, and nothing is sent. They are this Rewrite's words for the change (`acceptThreadWords`), so
    /// Keep prices and voices them as any change, the voice made from your text. An empty text makes the change a cut; the
    /// recorded words leave nothing to change, so it is left out; the words already in the text change nothing; a
    /// version's words show that version.
    @discardableResult func applyRewriteThreadOwnWords(_ typed: String) -> Bool {
        guard let target = rewriteThreadTarget, rewriteThread.ownWords == target.key, rewriteThread.sending == nil,
              var thread = rewriteThread(target.key.ordinal) else { return false }
        let key = target.key, text = EditingPrimitives.jsTrim(typed), state = rewriteThread
        guard text != EditingPrimitives.jsTrim(thread.versions[thread.current].text) else {
            leaveRewriteThreadOwnWords(focus: false)
            announce("Nothing changed: those are the words in the text.")
            return true
        }
        // With paid takes your words wait for the discard, and the input keeps them, still your own words, until then.
        let placed = placeRewriteThreadVersion(key, text: text) { [weak self] in
            guard let self else { return }
            if state.ownWords == key { leaveRewriteThreadOwnWords(focus: false) }
            // The recorded words (or none for added words): the edit left the change out, and its thread went with it.
            guard var proposal, proposal.id == key.proposal, proposal[key.ordinal]?.state == .pending else { return }
            let shown = changeText(key.ordinal)
            if let found = thread.versions.firstIndex(where: { $0.text == shown }) { thread.current = found } else {
                thread.versions.append(.init(text: shown, note: nil, yours: true))
                thread.current = thread.versions.count - 1
            }
            thread.turns.append(.init(speaker: .yours, text: text))
            // Claude's next steps were for its own words.
            thread.nextSteps = []
            proposal.threads[key.ordinal] = thread
            self.proposal = proposal
            if state.key == key { state.error = nil }
            announce((text.isEmpty ? "Change \(key.ordinal) cuts its words now." : "Your words are in change \(key.ordinal).")
                     + " Version \(thread.current + 1) of \(thread.versions.count). Nothing was sent.")
        }
        guard placed != .failed else {
            state.error = "Your words couldn't be put in the text. Your edits are saved."
            state.failed = nil
            return false
        }
        return true
    }

    nonisolated static func followupScope(_ scope: RewriteScope) -> String {
        switch scope {
        case .selection: "passage"
        case .clip: "clip"
        case .fullTake: "fullTake"
        }
    }

    /// The live send: the open Rewrite's AI, after the inline confirmation where its provider needs one (consent action
    /// `rewrite`, as Ask Claude's), under the project's one AI lease.
    var liveRewriteThreadBackend: RewriteThreadBackend {
        RewriteThreadBackend { [weak self] request in
            guard let self, let session = openRewrite, let connector = session.connector, let shared = app.shared else { throw LLMError.noConnector }
            guard let lease = llmRuns.acquire() else {
                throw LLMError.unavailable(reason: "Another AI request on this project is still running. Try Again when it finishes.")
            }
            defer { llmRuns.release(lease) }
            if let provider = session.provider {
                let proposalID = proposal?.id
                guard try await app.authorizeConnectorRequest(provider, connector: connector.connector, action: .rewrite,
                        wordCount: session.task.words.wordCount, rewrite: session.task.words, confirmation: rewriteThread.confirmation, verb: "Rewrite",
                        isCurrent: { [weak self] in self?.openRewrite === session && self?.proposal?.id == proposalID }) else { throw CancellationError() }
            }
            let catalog = try LLMCatalog(shared: shared)
            let service = RewriteFollowupService(runner: LLMRunner(keys: app.secrets, catalog: catalog, log: app.log),
                                                 prompt: try RewriteFollowupPrompt.load(shared: shared), catalog: catalog)
            return try await service.send(request, connector: connector.connector, model: connector.model)
        }
    }
}
