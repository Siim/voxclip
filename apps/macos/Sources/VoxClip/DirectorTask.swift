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
    var priced = false
    let perform: @MainActor () -> Void
}
extension PanelAction: Equatable {
    static func == (lhs: PanelAction, rhs: PanelAction) -> Bool { lhs.id == rhs.id && lhs.title == rhs.title && lhs.priced == rhs.priced }
}

/// The headline, with its optional sub-line and tag. While the task runs it carries the spinner, the
/// elapsed time since `runningSince` and Stop.
struct PanelHeadline: Equatable {
    var text: String
    var sub: String? = nil
    /// A tag after the headline: "Beta" while R2 shows phrases in your voice with Voice Lab on (design.md §6.3.4).
    var tag: String? = nil
    var runningSince: Date? = nil
    var stop: PanelAction? = nil
}

/// The pinned footer: at most one note, at most one secondary link and at most one primary.
struct PanelFooter: Equatable {
    var note: String? = nil
    var link: PanelAction? = nil
    var primary: PanelAction? = nil
}

/// A question the task asks in place of its footer before it drops the user's work (impl-plan §13.1: inline, not an
/// alert): "Discard these 6 changes?" with the safe answer as the primary ("Keep Working"), which Return and Esc choose,
/// and the other as the link ("Discard Changes").
struct PanelConfirm: Equatable {
    let question: String
    let cancel: PanelAction
    let confirm: PanelAction
}

/// One step of a task's work log: Rewrite's own steps (R1), or one tool call in Phase 1.
struct ActivityStep: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case waiting, running, done, failed }
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
        case .failed: "Failed: \(spoken)"
        }
    }
}

/// A change a proposal makes, in transcript order; `ordinal` is the "Change {i} of {c}" the
/// panel and the transcript share (design.md §6.3.5). The proposal's producer keeps it as the
/// transcript's proposal reads it, so its review follows the transcript's Keep and Undo.
struct ProposalItem: Identifiable, Equatable, Sendable {
    var audioTags: [VoiceLabAudioTag] = []
    var tagsOmitted = false
    var timing: VoiceLabPhraseTiming? = nil
    var pricedAnyway = false
    enum Kind: String, Sendable { case cut, fix, voice }
    /// Reviewed per change (impl-plan item 7): pending until kept or left out. A kept cut or fix is in the project; a kept
    /// voice change is included for takes. A change left out is the change list's unchecked row.
    enum State: Sendable { case pending, kept, excluded }
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
    var state = State.pending
    /// What its row reads: the words it would leave, or for a cut the words it removes.
    var quote = ""
    /// A line under the quote: why a voice change can't be made, or a warning.
    var note: String? = nil
    /// The note is a warning ("Check this: …", "Needs Voice Lab (beta)"): `status.warning` with its glyph.
    var warns = false
    /// It can be kept or left out. A voice change that can't be made has no review and stays left out (design.md R2).
    var reviewable = true
    /// "Change 1 of 6: removed to, to the; inserted your, in the", with ", left out" or ", kept" after a review.
    var spoken = ""
    var id: Int { ordinal }
}

/// A proposal: what a task would change, before anything changes the project (design.md §6.5).
struct ChangeSet: Equatable, Sendable {
    var items: [ProposalItem]
    /// The change the transcript focuses, which the list shows selected.
    var focused: Int? = nil
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

/// A next-step chip of a stuck state (design.md R2 "Next steps"): a built-in action, or one the AI suggested (✦).
struct NextStepChip: Identifiable, Equatable {
    let action: PanelAction
    var suggested = false
    var id: String { action.id }
}

/// The "Tell the AI what to do instead…" field under a stuck state's chips; `submit` re-asks with its text.
struct NextStepAsk: Equatable {
    let id: String
    let placeholder: String
    let submit: @MainActor (String) -> Void
    static func == (lhs: NextStepAsk, rhs: NextStepAsk) -> Bool { lhs.id == rhs.id && lhs.placeholder == rhs.placeholder }
}

/// A stuck state's next steps (design.md R2 "Next steps"): an optional line saying what happened, a row of chips that
/// each act now, and the free-text field. Nothing in it is disabled; a step that cannot act is not shown.
struct NextSteps: Equatable {
    /// The stuck state: "budget", "fit", "take", "context", "failure", "stale", "reask".
    let id: String
    var line: String? = nil
    var chips: [NextStepChip] = []
    var ask: NextStepAsk? = nil
    static let askPlaceholder = "Tell the AI what to do instead…"
}

/// One block of a task's panel body.
enum PanelCard: Identifiable, Equatable {
    /// What was asked, under a rule: "Asked: **Fix mistakes**, fix slips…" or "Asked: “{instruction}”".
    case asked(preset: String?, text: String)
    /// A work log, one row per step.
    case activity([ActivityStep])
    /// Body copy.
    case text(String)
    case secondaryText(String)
    /// A radio list of AIs (R0). The choice is `DirectorTask.choice`; `saveKey` saves
    /// `DirectorTask.keyDraft` for the row that has no key.
    case chooser([ConnectorChoice], saveKey: PanelAction?)
    /// A secure field for an API key, typed into `DirectorTask.keyDraft`; `label` is its placeholder and name.
    case keyField(provider: String, label: String)
    /// A proposal's change list (R2), one row per change; `DirectorTask.review` keeps, undoes and focuses a change.
    case changes(ChangeSet)
    /// A warning callout: "These changes re-voice 72 words; …" (R2 over the voice budget).
    case callout(String)
    /// The Ask field with `placeholder`, where Ask for Something Else puts the keyboard. The clip bar holds it from V3b.
    case ask(placeholder: String)
    /// Voice Lab's takes for the proposal's voice change, until the Takes job (V18).
    case takes
    case wordingFit
    /// A stuck state's chips and free-text field (design.md R2 "Next steps").
    case nextSteps(NextSteps)

    var id: String {
        switch self {
        case .asked: "asked"
        case .activity: "activity"
        case .text(let text): "text:\(text)"
        case .secondaryText(let text): "secondaryText:\(text)"
        case .chooser: "chooser"
        case .keyField(let provider, _): "key:\(provider)"
        case .changes: "changes"
        case .callout(let text): "callout:\(text)"
        case .ask: "ask"
        case .takes: "takes"
        case .wordingFit: "wordingFit"
        case .nextSteps(let steps): "nextSteps:\(steps.id)"
        }
    }
}

/// Why a task could not finish (R1x). Each case has its own fix in the panel.
enum PanelError: Equatable, Sendable {
    /// The AI's error message, which ends "Your edits are saved." (`LLMError.userMessage`).
    case message(String)
    /// An installed CLI that is not signed in; `command` signs it in ("claude", "codex login").
    case signedOut(cli: String, command: String)
    case cliNetworkUnreachable(cli: String, detail: String)
    /// An API-key connector with no key.
    case noKey(provider: String, name: String)
    /// A local server that does not answer: "Ollama", "LM Studio".
    case notRunning(server: String, url: String)
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
        /// R1. A task with an AI starts here, as its run starts as it opens.
        case running
        /// R2: the proposal, or "No changes needed" with no items. Its set follows each change's review.
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
    /// The question the panel asks in place of the footer, nil when it asks none. A new step drops it.
    private(set) var confirm: PanelConfirm?
    /// Closes the task ("Close Rewrite", Esc).
    let close: PanelAction
    /// The harness line's borderless action: R2's "Ask again" (notes.md §7).
    private(set) var contextAction: PanelAction?
    /// Keeps, undoes, focuses or edits a change of a `.changes` card, by ordinal (impl-plan item 7).
    @ObservationIgnored var review: (@MainActor (Int, ChangeReview) -> Void)?
    @ObservationIgnored var phraseTimingAction: (@MainActor (Int, PhraseTimingAction) -> Void)?
    @ObservationIgnored var audioTagsChanged: (@MainActor (Int, [VoiceLabAudioTag]) -> Void)?
    var wordingLocked = false
    /// The producer's work as the task's panel appears: Rewrite detects its AI for the context line's dot.
    @ObservationIgnored var appeared: (@MainActor () async -> Void)?
    /// The row picked in a chooser card.
    private(set) var choice: String?
    /// Told when the user picks another row, so the producer can retitle the primary.
    @ObservationIgnored var chose: (@MainActor (String) -> Void)?
    /// A key typed into a key field. In memory only, never logged or saved here, and cleared once saved.
    var keyDraft = ""
    /// What is typed into a next-steps field (`NextStepAsk`), cleared as it is sent.
    var nextStepDraft = ""
    /// Bumped to ask the panel to focus its first field (a key field).
    private(set) var focusRequest = 0
    /// The keyboard is in the task's panel; its views report it as their focus changes. Moving it out drops a handover.
    @ObservationIgnored var keyboardInPanel = false { didSet { if !keyboardInPanel { keyboardHandover = false } } }
    /// The view the panel draws next takes the keyboard after a change of state while the keyboard was in the panel, so a
    /// panel drawn again (another job or tab and back) gets back the keyboard it had; otherwise focus stays where the user
    /// moved it while the AI worked. A task starts with focus where it was (design.md §10).
    @ObservationIgnored private var keyboardHandover = false

    /// A task that starts in `.running` is on its first turn; one that chooses its AI first gets turn 1 as it runs.
    init(scope: RewriteScope, words: DirectorScope, state: State, close: PanelAction) {
        self.scope = scope; self.words = words; self.state = state; self.close = close
        turn = state == .running ? 1 : 0
        headline = PanelHeadline(text: words.title)
    }
    /// The scope's words as a new run reads them.
    func rescope(_ words: DirectorScope) { if words != self.words { self.words = words } }

    /// The right column's job that shows the task. Voice steps and takes move it to the
    /// Voice and Takes jobs (V16–V18).
    var job: PanelJob { cards.contains(.takes) ? .voice : .rewrite }
    @ObservationIgnored var primaryAppearedAt: Date?

    /// Shows `state` with its panel content. Entering `.running` starts a new turn. A proposal shown again after a review
    /// is the same step: the keyboard stays where it is.
    func show(_ state: State, headline: PanelHeadline, cards: [PanelCard] = [], footer: PanelFooter = PanelFooter(), contextAction: PanelAction? = nil) {
        if self.footer.primary != footer.primary { primaryAppearedAt = Date() }
        if state == .running, self.state != .running { turn += 1 }
        if !Self.sameStep(state, self.state) { keyboardHandover = keyboardHandover || keyboardInPanel; confirm = nil }
        self.state = state; self.headline = headline; self.cards = cards; self.footer = footer; self.contextAction = contextAction
    }
    /// Asks `confirm` in place of the footer until it is answered or the task moves to another step.
    func ask(_ confirm: PanelConfirm) { self.confirm = confirm }
    func dismissConfirm() { confirm = nil }
    private static func sameStep(_ lhs: State, _ rhs: State) -> Bool {
        if case .proposal = lhs, case .proposal = rhs { return true }
        return lhs == rhs
    }
    /// What the panel shows: a state with its content.
    struct Shown {
        let state: State
        let headline: PanelHeadline
        let cards: [PanelCard]
        let footer: PanelFooter
        let contextAction: PanelAction?
        let context: DirectorContext?
    }
    var shown: Shown { Shown(state: state, headline: headline, cards: cards, footer: footer, contextAction: contextAction, context: context) }
    /// Shows `shown` again: what a run replaced, when the run ends with nothing sent.
    func show(_ shown: Shown) {
        show(shown.state, headline: shown.headline, cards: shown.cards, footer: shown.footer, contextAction: shown.contextAction)
        context = shown.context
    }
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
    /// The change list on the panel, if it shows one.
    var changes: ChangeSet? {
        for case .changes(let set) in cards { return set }
        return nil
    }
    /// The next steps the panel shows, in card order.
    var nextSteps: [NextSteps] { cards.compactMap { if case .nextSteps(let steps) = $0 { steps } else { nil } } }

    /// Return in the panel, outside a text field (design.md §10, "Rewrite without a pointer"): with a change list, Return
    /// edits the focused change and ⌘Return runs the primary, so walking the list never applies, makes takes or pays;
    /// elsewhere either runs the primary. While the panel asks a question, either answers it with its safe choice. False
    /// when nothing acts.
    func pressReturn(command: Bool, now: Date = Date(), eventDate: Date? = nil) -> Bool {
        // A question waits for its answer first; Return chooses the safe one, as an alert's default button would.
        if let confirm {
            confirm.cancel.perform()
            return true
        }
        if let changes, !command {
            guard let focused = changes.focused, let review else { return false }
            review(focused, .edit)
            return true
        }
        if cards.contains(.takes), !command { return false }
        guard let primary = footer.primary else { return false }
        if primary.priced, !VoiceLabSession.permitsPaidActivation(keyboard: true, command: command, repeated: false,
            appeared: primaryAppearedAt, now: now, eventDate: eventDate) { return true }
        primary.perform()
        return true
    }
    /// Space on the change list: leaves the focused change out, or keeps one left out, as its row's checkbox would
    /// (design.md R2). A kept cut or fix is in the project; ⌘Z takes it back. False when nothing acts.
    func pressSpace() -> Bool {
        // A question's safe answer has the keyboard (`DirectorPanel`): Space chooses it, and leaves the list alone.
        if let confirm {
            confirm.cancel.perform()
            return true
        }
        guard let changes, let review, let item = changes.items.first(where: { $0.ordinal == changes.focused }), item.reviewable else { return false }
        switch item.state {
        case .pending: review(item.ordinal, .undo)
        case .excluded: review(item.ordinal, .keep)
        case .kept:
            guard item.kind == .voice else { return false }
            review(item.ordinal, .undo)
        }
        return true
    }
}

/// What a change list row asks of its change.
enum ChangeReview: Sendable { case focus, keep, undo, edit }
