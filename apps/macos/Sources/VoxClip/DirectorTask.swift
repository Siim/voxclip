import Foundation
import Observation
import VoxClipCore

// The Director task model (design.md §6.3.4 and §6.5, impl-plan V12m): the one model behind
// the right column's task jobs. Rewrite is a one-turn task on it, and Phase 1's Director
// thread feeds its session events into the same types. A task's body is a list of cards, not
// a fixed list of steps: the v4 thread draft's thinking line, plan, work log, approval rows
// and changes summary arrive as new `PanelCard` kinds, not as a new view model.

/// What a task acts on, in the words its copy uses (design.md §6.3 "Scope words").
struct DirectorScope: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case clip(number: Int)
        case fullTake
        /// A word selection; `inClip` when it lies inside a clip ("this clip", else "this video").
        case selection(inClip: Bool)
    }
    let kind: Kind
    /// The words the task reads: a selection's selected words, a clip's kept words.
    let wordCount: Int

    private var count: String { wordCount == 1 ? "1 word" : "\(wordCount) words" }
    /// The panel's title and the undo name: "Rewrite clip 1", "Rewrite full take", "Rewrite 7 words".
    var title: String {
        switch kind {
        case .clip(let number): "Rewrite clip \(number)"
        case .fullTake: "Rewrite full take"
        case .selection: "Rewrite \(count)"
        }
    }
    /// "clip {n}" in a sentence: "clip 1", "the full take", "these words".
    var name: String {
        switch kind {
        case .clip(let number): "clip \(number)"
        case .fullTake: "the full take"
        case .selection: wordCount == 1 ? "this word" : "these words"
        }
    }
    /// "the {w} words of clip {n}": "the 118 words of clip 1", "the 900 words of this video", "these 7 words".
    var words: String {
        switch kind {
        case .clip(let number): "the \(count) of clip \(number)"
        case .fullTake: "the \(count) of this video"
        case .selection: wordCount == 1 ? "this word" : "these \(count)"
        }
    }
    /// The noun of "this {video | clip}".
    var noun: String {
        switch kind {
        case .clip: "clip"
        case .fullTake: "video"
        case .selection(let inClip): inClip ? "clip" : "video"
        }
    }
    /// The scope as a sentence's subject: "Clip 1", "Full take", "These words" (design.md R1x "{Full take | Clip {n}}").
    var subject: String {
        switch kind {
        case .clip(let number): "Clip \(number)"
        case .fullTake: "Full take"
        case .selection: wordCount == 1 ? "This word" : "These words"
        }
    }
    /// R1x's headline for a scope over Rewrite's limits: "Clip 1 is too long to rewrite at once".
    var tooLong: String { subject + (isPlural ? " are" : " is") + " too long to rewrite at once" }
    /// R3's headline: "Clip 1 changed".
    var changed: String { subject + " changed" }
    private var isPlural: Bool { if case .selection = kind { wordCount != 1 } else { false } }
}

/// The context line (design.md §6.3.4): the AI's short name, its model and the send's state.
/// It is read-only; the AI picker lives above the transcript.
struct DirectorContext: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// A CLI on a plan, a local server or Apple on-device.
        case noExtraCost
        /// An API key, or a CLI signed in with one: the send asks first.
        case billedToKey
        /// After a reply.
        case answered(seconds: Double)
    }
    /// The status dot: ready, asks before each send, or unavailable (design.md §6.3.1).
    enum Readiness: Equatable, Sendable { case ready, asksFirst, unavailable }
    let name: String
    let model: String
    let state: State?
    let readiness: Readiness

    var stateText: String? {
        switch state {
        case .noExtraCost: "no extra cost"
        case .billedToKey: "billed to your key"
        case .answered(let seconds): "answered in \(SecondsText.format(seconds))"
        case nil: nil
        }
    }
    /// "Claude Code · Opus 5.5 · no extra cost".
    var text: String { ([name] + [model, stateText].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · ") }
}

/// A button a task offers. A task shows only actions that can act (design.md §6.3.4: no
/// disabled buttons), so an action has no enabled state.
struct PanelAction: Identifiable {
    /// Stable across copy changes: "use", "checkAgain", "tryAgain", "stop".
    let id: String
    let title: String
    let perform: @MainActor () -> Void
}
extension PanelAction: Equatable {
    static func == (lhs: PanelAction, rhs: PanelAction) -> Bool { lhs.id == rhs.id && lhs.title == rhs.title }
}

/// The headline, with its optional sub-line. While the task runs it carries the spinner, the
/// elapsed time since `runningSince` and Stop.
struct PanelHeadline: Equatable {
    var text: String
    var sub: String? = nil
    var runningSince: Date? = nil
    var stop: PanelAction? = nil
}

/// The pinned footer: at most one note, at most one secondary link and at most one primary.
struct PanelFooter: Equatable {
    var note: String? = nil
    var link: PanelAction? = nil
    var primary: PanelAction? = nil
}

/// One step of a task's work log: Rewrite's own steps (R1), or one tool call in Phase 1.
struct ActivityStep: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case waiting, running, done }
    let id: String
    var title: String
    var detail: String
    var status: Status
    /// What VoiceOver reads after the status: "Read clip 1, 118 words".
    var spoken: String
    /// Phase 1's tool id, set in SF Mono beside the step; nil for Rewrite's steps.
    var tool: String? = nil

    /// "Done: Read clip 1, 118 words", "In progress: Waiting for Claude Code" (design.md §10).
    var accessibilityLabel: String {
        switch status {
        case .done: "Done: \(spoken)"
        case .running: "In progress: \(spoken)"
        case .waiting: "Next: \(spoken)"
        }
    }
}

/// A change a proposal makes, in transcript order; `ordinal` is the "Change {i} of {c}" the
/// panel and the transcript share (design.md §6.3.5).
struct ProposalItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case cut, fix, voice }
    let ordinal: Int
    let kind: Kind
    /// The transcript words it replaces or removes, in order.
    let sourceWordIDs: [String]
    /// Its new words; empty for a cut.
    let newWords: [String]
    /// The words it replaces or removes as the transcript reads them (corrections applied), in order.
    var oldWords: [String] = []
    /// It adds something the speaker didn't say: a number, a link or a name found nowhere in the scope or the instruction
    /// (voice-lab.md §8.1 `checkThis`).
    var checkThis = false
    var included = true
    var id: Int { ordinal }

    /// "Proposed change 1 of 6: removed to, to the; inserted your, in the" (design.md §10), or "Change 1 of 6: …" in
    /// the panel's list.
    func spokenDescription(of count: Int, prefix: String = "Proposed change") -> String {
        let parts = [oldWords.isEmpty ? nil : "removed " + oldWords.joined(separator: " "),
                     newWords.isEmpty ? nil : "inserted " + newWords.joined(separator: " ")].compactMap { $0 }
        return "\(prefix) \(ordinal) of \(count): " + parts.joined(separator: "; ")
    }
}

/// A proposal: what a task would change, before anything changes the project (design.md §6.5).
struct ChangeSet: Equatable, Sendable {
    var items: [ProposalItem]
    var voiceCount: Int { items.filter { $0.kind == .voice }.count }
    /// R2's headline: "6 changes", "1 change", or "No changes needed".
    var headline: String { items.isEmpty ? "No changes needed" : items.count == 1 ? "1 change" : "\(items.count) changes" }
    /// R2's sub-line: "2 cuts · 1 fix · 3 phrases in your voice", zero parts left out; nil with no changes.
    var subline: String? {
        func part(_ kind: ProposalItem.Kind, _ one: String, _ many: String) -> String? {
            let count = items.filter { $0.kind == kind }.count
            return count == 0 ? nil : count == 1 ? "1 \(one)" : "\(count) \(many)"
        }
        let parts = [part(.cut, "cut", "cuts"), part(.fix, "fix", "fixes"), part(.voice, "phrase in your voice", "phrases in your voice")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// "6 changes proposed. 3 need your voice." (design.md §10).
    var announcement: String {
        let changes = items.count == 1 ? "1 change proposed." : "\(items.count) changes proposed."
        switch voiceCount {
        case 0: return changes
        case 1: return changes + " 1 needs your voice."
        default: return changes + " \(voiceCount) need your voice."
        }
    }
}

/// An AI the chooser card offers (R0), with its status now.
struct ConnectorChoice: Identifiable, Equatable, Sendable {
    /// The connector id `llm.connector` stores.
    let id: String
    /// The row's name: "Claude Code (installed CLI)", "Apple on-device", "Anthropic".
    let name: String
    /// The name the primary uses: "Use Claude Code".
    let shortName: String
    /// "Signed in · Claude plan · no extra cost", "Not running. Start Ollama, then choose Check Again."
    let status: String
    /// It can send now: the chooser picks the first such row.
    let isReady: Bool
    /// It has no API key yet: a secure field and Save Key show under the row.
    let needsKey: Bool
}

/// One block of a task's panel body.
enum PanelCard: Identifiable, Equatable {
    /// What was asked, under a rule: "Asked: **Fix mistakes**, fix slips…" or "Asked: “{instruction}”".
    case asked(preset: String?, text: String)
    /// A work log, one row per step.
    case activity([ActivityStep])
    /// Body copy.
    case text(String)
    /// A radio list of AIs (R0). The choice is `DirectorTask.choice`; `saveKey` saves
    /// `DirectorTask.keyDraft` for the row that has no key.
    case chooser([ConnectorChoice], saveKey: PanelAction?)
    /// A secure field for an API key, typed into `DirectorTask.keyDraft`; `label` is its placeholder and name.
    case keyField(provider: String, label: String)

    var id: String {
        switch self {
        case .asked: "asked"
        case .activity: "activity"
        case .text(let text): "text:\(text)"
        case .chooser: "chooser"
        case .keyField(let provider, _): "key:\(provider)"
        }
    }
}

/// Why a task could not finish (R1x). Each case has its own fix in the panel.
enum PanelError: Equatable, Sendable {
    /// The AI's error message, which ends "Your edits are saved." (`LLMError.userMessage`).
    case message(String)
    /// An installed CLI that is not signed in; `command` signs it in ("claude", "codex login").
    case signedOut(cli: String, command: String)
    /// An API-key connector with no key.
    case noKey(provider: String, name: String)
    /// A local server that does not answer: "Ollama", "LM Studio".
    case notRunning(server: String)
    /// The model declined.
    case refused
    /// More than 3,000 entries (voice-lab.md §8.1); `count` is the scope's kept items.
    case tooManyEntries(count: Int)
    /// At most 3,000 entries, but more than 20,000 bytes of text.
    case tooMuchText

    /// A Rewrite plan's refusal of a clip or Full take, nil when it is not a size limit.
    init?(_ error: ScopeRewritePlanError) {
        switch error {
        case .tooManyEntries(let count): self = .tooManyEntries(count: count)
        case .tooMuchText: self = .tooMuchText
        case .empty, .invalidInput: return nil
        }
    }
}

/// One task in the right column: its scope, its state and what the panel shows for it.
@MainActor @Observable final class DirectorTask {
    enum State: Equatable {
        /// R0: no AI is chosen.
        case choosingAI
        /// Nothing runs: the task waits for a new instruction (Ask for Something Else, a declined sheet). The passage panel
        /// shows its field until the clip bar's Ask field (V3b) holds it; V15 deletes the state with the passage panel.
        case ready
        /// R1.
        case running
        /// R2: the proposal, shown by the passage panel until V15.
        case proposal(ChangeSet)
        /// R1x.
        case error(PanelError)
        /// R3: an edit inside the scope while a proposal was open or a run went on (design.md §6.3.6). Undoing back to the
        /// proposal's revision shows it again.
        case changed
    }

    let scope: RewriteScope
    /// The scope's words; a new run reads them again (`rescope`), as edits in the scope change its count.
    private(set) var words: DirectorScope
    private(set) var state: State
    /// Counts the runs started: a new turn brings the task's job back to the panel
    /// (`WorkspaceShell.panelJob(for:)`), though the user switched to Captions before it.
    private(set) var turn = 0
    private(set) var context: DirectorContext?
    private(set) var headline: PanelHeadline
    private(set) var cards: [PanelCard] = []
    private(set) var footer = PanelFooter()
    /// Closes the task ("Close Rewrite", Esc).
    let close: PanelAction
    /// The row picked in a chooser card.
    private(set) var choice: String?
    /// Told when the user picks another row, so the producer can retitle the primary.
    @ObservationIgnored var chose: (@MainActor (String) -> Void)?
    /// A key typed into a key field. In memory only, never logged or saved here, and cleared once saved.
    var keyDraft = ""
    /// Bumped to ask the panel to focus its first field (a key field).
    private(set) var focusRequest = 0
    /// The keyboard is in the task's panel; its views report it as their focus changes. Moving it out drops a handover.
    @ObservationIgnored var keyboardInPanel = false { didSet { if !keyboardInPanel { keyboardHandover = false } } }
    /// The view the panel draws next takes the keyboard: after a change of state while the keyboard was in the panel, or
    /// once asked (`handOverKeyboard`). Until V15 the passage panel and the task's panel take turns, and the one that goes
    /// takes the focused view with it; otherwise focus stays where the user moved it while the AI worked. A task starts
    /// with focus where it was (design.md §10), unless `takesKeyboard`.
    @ObservationIgnored private var keyboardHandover: Bool

    /// A task that starts `.running` starts its first turn.
    init(scope: RewriteScope, words: DirectorScope, state: State, takesKeyboard: Bool = false, close: PanelAction) {
        self.scope = scope; self.words = words; self.state = state; self.close = close
        keyboardHandover = takesKeyboard
        turn = state == .running ? 1 : 0
        headline = PanelHeadline(text: words.title)
    }
    /// The scope's words as a new run reads them.
    func rescope(_ words: DirectorScope) { if words != self.words { self.words = words } }

    /// The right column's job that shows the task. Voice steps and takes move it to the
    /// Voice and Takes jobs (V16–V18).
    var job: PanelJob { .rewrite }

    /// Shows `state` with its panel content. Entering `.running` starts a new turn.
    func show(_ state: State, headline: PanelHeadline, cards: [PanelCard] = [], footer: PanelFooter = PanelFooter()) {
        if state == .running, self.state != .running { turn += 1 }
        if state != self.state { keyboardHandover = keyboardHandover || keyboardInPanel }
        self.state = state; self.headline = headline; self.cards = cards; self.footer = footer
    }
    /// Asks the view the panel draws next to take the keyboard (Ask for Something Else focuses the field).
    func handOverKeyboard() { keyboardHandover = true }
    /// True once for the view that should take the keyboard as it appears.
    func takeKeyboardHandover() -> Bool {
        defer { keyboardHandover = false }
        return keyboardHandover
    }
    /// Replaces the work log's steps while a run goes on.
    func update(_ steps: [ActivityStep]) {
        cards = cards.map { if case .activity = $0 { .activity(steps) } else { $0 } }
    }
    func setContext(_ context: DirectorContext?) { self.context = context }
    /// Picks a chooser row.
    func choose(_ id: String) {
        guard choice != id else { return }
        choice = id
        chose?(id)
    }
    func requestFocus() { focusRequest += 1 }

    /// The work log on the panel, if it shows one.
    var steps: [ActivityStep] {
        for case .activity(let steps) in cards { return steps }
        return []
    }
}
