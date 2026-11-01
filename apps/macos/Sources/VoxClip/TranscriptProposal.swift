import AppKit
import VoxClipCore

/// One change of a Rewrite proposal as the transcript shows it (ux/v2 notes.md §5, design.md
/// §6.3.5): a diff hunk with its ordinal, "Change {i}" in the transcript and the panel alike.
/// It is one or more §8.2 hunks: C2 gives one per change, and editing its words in the
/// popover (`ChangeEditPopover`) may split it into several, which still keep and undo as one.
struct TranscriptChange: Equatable, Identifiable {
    /// The gutter glyph's precedence (notes.md §5): voice waveform > pencil > scissors.
    enum Kind: Int, Comparable {
        case cut, fix, voice
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    /// Pending until reviewed (impl-plan item 7). A kept cut or fix is applied to the project and
    /// is gone from the transcript like a commit (notes.md §5), even when its words are restored
    /// or corrected again later; only ⌘Z of its Keep takes it back to pending. A kept voice
    /// change is included for takes and changes nothing yet, so it still shows. An excluded
    /// change shows its original words.
    enum State: Equatable { case pending, kept, excluded }
    /// One §8.2 hunk of the change: `VoiceLabDiffHunk`'s values.
    struct Part: Equatable {
        var kind: VoiceLabDiffHunkKind
        var sourceWordIDs: [String]
        var newTokens: [String]
        var correctedTexts: [String] = []
        var bridgeWordIDs: [String] = []
        var absorbedItemIDs: [String] = []
        /// An insertion part's place inside its change, when an edit split the change; C2's
        /// insertions are whole changes and use the change's anchor.
        var anchor: Anchor?
        init(kind: VoiceLabDiffHunkKind, sourceWordIDs: [String], newTokens: [String] = [], correctedTexts: [String] = [], bridgeWordIDs: [String] = [], absorbedItemIDs: [String] = [], anchor: Anchor? = nil) {
            self.kind = kind; self.sourceWordIDs = sourceWordIDs; self.newTokens = newTokens
            self.correctedTexts = correctedTexts; self.bridgeWordIDs = bridgeWordIDs; self.absorbedItemIDs = absorbedItemIDs; self.anchor = anchor
        }
        init(_ hunk: VoiceLabDiffHunk) {
            self.init(kind: hunk.kind, sourceWordIDs: hunk.sourceWordIds, newTokens: hunk.newTokens, correctedTexts: hunk.correctedTexts,
                      bridgeWordIDs: hunk.bridgeWordIds, absorbedItemIDs: hunk.absorbedItemIds)
        }
    }
    /// Where an insertion's new words go: after a word, or before the scope's first word.
    enum Anchor: Equatable { case after(String), before(String) }
    let ordinal: Int
    var parts: [Part]
    /// The source words the change covers, in order: its parts' words as C2 gave them. An edit
    /// diffs these words again, so the parts may cover fewer of them.
    let span: [String]
    /// An insertion has no source word; its words stand here.
    var anchor: Anchor?
    var state: State
    var id: Int { ordinal }

    init(ordinal: Int, parts: [Part], anchor: Anchor? = nil, state: State = .pending) {
        self.ordinal = ordinal; self.parts = parts; self.anchor = anchor; self.state = state
        span = parts.flatMap(\.sourceWordIDs)
    }
    var kind: Kind {
        parts.contains { $0.kind == .voice } ? .voice : parts.contains { $0.kind == .textOnly } ? .fix : .cut
    }
    var isFree: Bool { kind != .voice }
}

/// What a change shows, in reading order: a source word it removes (struck), a source word it
/// keeps inside its extent (a bridge, or a word a fix leaves as it is: plain), and a run of
/// new words (the `change.add` tint), display-only text that maps to no word.
enum TranscriptChangeSegment: Equatable {
    case old(String)
    case kept(String)
    case new(String)

    /// A part's segments: removed words first, then the new words that replace them; a voice
    /// part's bridges, which it speaks with their own words, stay where they are between them.
    static func segments(_ part: TranscriptChange.Part, text: (String) -> String) -> [TranscriptChangeSegment] {
        var result: [TranscriptChangeSegment] = []
        var old: [String] = [], new: [String] = []
        func flush() {
            result += old.map(TranscriptChangeSegment.old)
            if !new.isEmpty { result.append(.new(new.joined(separator: " "))) }
            old = []; new = []
        }
        switch part.kind {
        case .cut:
            return part.sourceWordIDs.map(TranscriptChangeSegment.old)
        case .textOnly:
            for (id, corrected) in zip(part.sourceWordIDs, part.correctedTexts) {
                if corrected == text(id) { flush(); result.append(.kept(id)) } else { old.append(id); new.append(corrected) }
            }
            flush()
        case .voice:
            let bridges = Set(part.bridgeWordIDs)
            let tokens = part.newTokens
            var next = 0
            for id in part.sourceWordIDs {
                let own = EditingPrimitives.splitWords(text(id))
                if bridges.contains(id), !own.isEmpty,
                   let found = stride(from: next, through: tokens.count - own.count, by: 1).first(where: { Array(tokens[$0..<($0 + own.count)]) == own }) {
                    new = Array(tokens[next..<found])
                    flush()
                    result.append(.kept(id))
                    next = found + own.count
                } else { old.append(id) }
            }
            new = Array(tokens[min(next, tokens.count)...])
            flush()
        }
        return result
    }
}

/// A Rewrite proposal in the transcript: its changes, in transcript order, the one the keys and
/// the Keep and Undo buttons act on, and the tab it belongs to (design.md §6.3.5). It changes
/// no project until a change is kept. V13 fills it from C2's hunks; V15's change list reads it.
struct TranscriptProposal: Equatable {
    /// Which proposal this is: the undo of a Keep puts change states back only into the
    /// proposal it was made in, never into one a later Rewrite put in its place.
    let id = UUID()
    /// The open clip it belongs to; nil for Full Take. It shows only while that tab is open.
    var clipID: String?
    /// The scope's title, "Rewrite clip 1": Keep All's undo name.
    var title: String
    var changes: [TranscriptChange]
    /// The ordinal of the change the keys and the buttons act on.
    var focused: Int?
    /// Moves when the focus moves by key or rotor, so the transcript scrolls the change into view.
    var revealRevision = 0

    init(clipID: String?, title: String, changes: [TranscriptChange]) {
        self.clipID = clipID; self.title = title; self.changes = changes
        focused = changes.first?.ordinal
    }
    /// C2's hunks (`ScopeRewriteDiff.hunks`), one change each, numbered from 1. An insertion
    /// before the plan's first item stands before `firstItemID`, the scope's first word.
    init(clipID: String?, title: String, hunks: [ScopeRewriteDiff.Hunk], firstItemID: String?) {
        let changes = hunks.enumerated().map { offset, hunk in
            let anchor: TranscriptChange.Anchor? = hunk.hunk.sourceWordIds.isEmpty ? hunk.insertionAfterItemID.map(TranscriptChange.Anchor.after) ?? firstItemID.map(TranscriptChange.Anchor.before) : nil
            return TranscriptChange(ordinal: offset + 1, parts: [TranscriptChange.Part(hunk.hunk)], anchor: anchor)
        }
        self.init(clipID: clipID, title: title, changes: changes)
    }
    subscript(ordinal: Int) -> TranscriptChange? { changes.first { $0.ordinal == ordinal } }
}

/// What the transcript buttons and keys do to the focused change (impl-plan item 7).
enum TranscriptChangeAction: String, Equatable { case keep, undo }

/// How a word or a run of new words belongs to a shown change, carried on its span, so the
/// fragment draws the change bar, the glyph and the treatments from the span alone and a
/// paragraph is written again when any of them changes.
struct TranscriptChangeMark: Equatable {
    enum Role: Equatable {
        /// A source word the change removes: the Show-cuts strike.
        case old
        /// A source word inside the change that stays: plain.
        case kept
        /// The change's new words: `change.add` at 19 %.
        case new
        /// An excluded change's original words, or the word its insertion follows: a dotted underline.
        case slot
        /// The blank the Keep and Undo buttons stand over.
        case spacer
    }
    /// The `vcUnderline` style of an excluded change's place: dotted.
    static let slotUnderline = 4
    let ordinal: Int
    let kind: TranscriptChange.Kind
    let role: Role
    /// The change waits for review: its lines show the change bar.
    let pending: Bool
    let focused: Bool
}

/// The proposal as the open tab shows it: the changes in view and, by word, what each word is
/// to them. `EditorModel.proposalDisplay` makes it; the transcript's content includes it, so
/// a focus move or a Keep writes only the paragraphs it changes.
struct TranscriptProposalDisplay: Equatable {
    struct Shown: Equatable {
        let ordinal: Int
        let kind: TranscriptChange.Kind
        let state: TranscriptChange.State
        /// How many changes the proposal holds: "Proposed change 1 of 5".
        let count: Int
        /// "Proposed change 1 of 5: removed to, to the; inserted your, in the".
        let description: String
        /// The first and last word positions it touches, for the overview ruler and its times.
        let words: ClosedRange<Int>
    }
    struct Run: Equatable {
        let mark: TranscriptChangeMark
        let text: String
    }
    var shown: [Shown] = []
    var marks: [String: TranscriptChangeMark] = [:]
    var before: [String: [Run]] = [:]
    var after: [String: [Run]] = [:]
    var focused: Int?
    /// The buttons the focused change shows; none where the project cannot change.
    var actions: [TranscriptChangeAction] = []
    var pending: Bool { shown.contains { $0.state == .pending } }
    func shown(_ ordinal: Int) -> Shown? { shown.first { $0.ordinal == ordinal } }
}

/// The take as a proposal reads it, taken from the editor once per use: the document's project
/// sits behind a lock, and a proposal reads many words on every render.
private struct TranscriptChangeReader {
    let words: [TimedWord]
    let wordIndex: [String: Int]
    let corrections: [String: String]
    let cutWordIDs: Set<String>
    @MainActor init(_ model: EditorModel) {
        words = model.words; wordIndex = model.wordIndex; corrections = model.project.edits.corrections; cutWordIDs = model.cutWordIDs
    }
    /// A word as it reads, corrected; empty for an id not in the take.
    func text(_ id: String) -> String { wordIndex[id].map { corrections[id] ?? words[$0].text } ?? "" }
    /// A cut or fix part is in the project: its words are cut, or read as corrected.
    func applied(_ part: TranscriptChange.Part) -> Bool {
        switch part.kind {
        case .cut: part.sourceWordIDs.allSatisfy(cutWordIDs.contains)
        case .textOnly: zip(part.sourceWordIDs, part.correctedTexts).allSatisfy { id, corrected in wordIndex[id] != nil && text(id) == corrected }
        case .voice: false
        }
    }
    func isApplied(_ change: TranscriptChange) -> Bool { change.isFree && change.parts.allSatisfy(applied) }
    func isPunctuationOnly(_ change: TranscriptChange) -> Bool {
        func letters(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })) }
        return !change.parts.isEmpty && change.parts.allSatisfy { part in
            part.kind == .textOnly && part.correctedTexts.count == part.sourceWordIDs.count
                && zip(part.sourceWordIDs, part.correctedTexts).allSatisfy { letters(text($0)) == letters($1) }
        }
    }
    /// Where a change's words go: the words it removes, the absorbed items it re-voices over,
    /// and its new-word runs, each after the segment word before it, or before the one after
    /// it, or, for an insertion, at its anchor.
    func layout(_ change: TranscriptChange) -> (old: Set<String>, absorbed: [String], before: [String: [String]], after: [String: [String]], inserted: [String]) {
        var old = Set<String>(), absorbed: [String] = [], before: [String: [String]] = [:], after: [String: [String]] = [:], inserted: [String] = []
        for part in change.parts {
            let segments = TranscriptChangeSegment.segments(part, text: text)
            func id(_ segment: TranscriptChangeSegment) -> String? {
                switch segment { case .old(let id), .kept(let id): id; case .new: nil }
            }
            for (position, segment) in segments.enumerated() {
                switch segment {
                case .old(let id): old.insert(id)
                case .kept: break
                case .new(let text):
                    inserted.append(text)
                    if let previous = segments[..<position].reversed().lazy.compactMap(id).first { after[previous, default: []].append(text) }
                    else if let next = segments[(position + 1)...].lazy.compactMap(id).first { before[next, default: []].append(text) }
                    else if case .after(let anchor) = part.anchor ?? change.anchor { after[anchor, default: []].append(text) }
                    else if case .before(let anchor) = part.anchor ?? change.anchor { before[anchor, default: []].append(text) }
                }
            }
            for id in part.absorbedItemIDs where !part.sourceWordIDs.contains(id) && !absorbed.contains(id) { absorbed.append(id); old.insert(id) }
        }
        return (old, absorbed, before, after, inserted)
    }
}

extension EditorModel {
    /// A free change is applied once all its parts are in the project; it then shows as the
    /// project does (kept cuts fold like any cut), and an undo of its Keep shows it again.
    func isApplied(_ change: TranscriptChange) -> Bool { TranscriptChangeReader(self).isApplied(change) }
    /// A fix that only moves punctuation: never shown as a hunk (notes.md §5). Keep All still
    /// applies it, and the change list (V15) still lists it.
    func isPunctuationOnly(_ change: TranscriptChange) -> Bool { TranscriptChangeReader(self).isPunctuationOnly(change) }

    /// The proposal as the open tab shows it, or nil when it belongs to another tab. Shown are
    /// the changes not kept into the project and not already in it whose words are in the take,
    /// less punctuation-only fixes (notes.md §5: never drawn; Keep All still applies them).
    var proposalDisplay: TranscriptProposalDisplay? {
        guard let proposal, proposal.clipID == project.edits.activeClipId else { return nil }
        let reader = TranscriptChangeReader(self), index = reader.wordIndex
        let visible = proposal.changes.filter { change in
            !(change.isFree && change.state == .kept) && !reader.isPunctuationOnly(change) && !reader.isApplied(change) && change.span.allSatisfy { index[$0] != nil }
                && (change.anchor.map { anchor in
                    switch anchor { case .after(let id), .before(let id): index[id] != nil }
                } ?? true) && !(change.span.isEmpty && change.anchor == nil)
        }
        var display = TranscriptProposalDisplay()
        // The focused change, or, when it is no longer shown, the first pending one shown.
        display.focused = visible.contains { $0.ordinal == proposal.focused } ? proposal.focused : (visible.first { $0.state == .pending } ?? visible.first)?.ordinal
        for change in visible {
            let focused = change.ordinal == display.focused
            func mark(_ role: TranscriptChangeMark.Role) -> TranscriptChangeMark {
                TranscriptChangeMark(ordinal: change.ordinal, kind: change.kind, role: role, pending: change.state == .pending, focused: focused)
            }
            var removed: [String] = [], inserted: [String] = []
            var positions: [Int] = change.span.compactMap { index[$0] }
            if change.state == .excluded {
                for id in change.span { display.marks[id] = mark(.slot) }
                if change.span.isEmpty, let anchor = change.anchor {
                    switch anchor { case .after(let id), .before(let id): display.marks[id] = mark(.slot) }
                }
            } else {
                let layout = reader.layout(change)
                for id in change.span + layout.absorbed {
                    if layout.old.contains(id) { display.marks[id] = mark(.old); removed.append(reader.text(id)) }
                    else if change.parts.contains(where: { $0.sourceWordIDs.contains(id) }) { display.marks[id] = mark(.kept) }
                }
                positions += layout.absorbed.compactMap { index[$0] }
                for (id, runs) in layout.before { display.before[id, default: []] += runs.map { .init(mark: mark(.new), text: $0) } }
                for (id, runs) in layout.after { display.after[id, default: []] += runs.map { .init(mark: mark(.new), text: $0) } }
                inserted = layout.inserted
            }
            if positions.isEmpty, let anchor = change.anchor {
                switch anchor { case .after(let id), .before(let id): positions += index[id].map { [$0] } ?? [] }
            }
            let lower = positions.min() ?? 0, upper = positions.max() ?? lower
            func trimmed(_ text: String) -> String { text.hasSuffix(",") || text.hasSuffix(";") ? String(text.dropLast()) : text }
            var parts: [String] = []
            if !removed.isEmpty { parts.append("removed " + trimmed(removed.joined(separator: " "))) }
            if !inserted.isEmpty { parts.append("inserted " + inserted.map(trimmed).joined(separator: ", ")) }
            let state = change.state == .excluded ? ", left out" : change.state == .kept ? ", kept" : ""
            // The ordinal the change list shares (design.md §6.3.5), of all the proposal's changes.
            let count = proposal.changes.count
            display.shown.append(.init(ordinal: change.ordinal, kind: change.kind, state: change.state, count: count,
                                       description: "Proposed change \(change.ordinal) of \(count): " + parts.joined(separator: "; ") + state, words: lower...upper))
        }
        if let focused = display.focused, capabilities.edit, let change = proposal[focused] {
            switch change.state {
            case .pending: display.actions = [.keep, .undo]
            case .kept: display.actions = [.undo]
            case .excluded: display.actions = [.keep]
            }
        }
        return display
    }

    /// The change's words as it would leave them: its span read through its parts. The edit
    /// popover starts from it.
    func changeText(_ ordinal: Int) -> String {
        guard let change = proposal?[ordinal] else { return "" }
        let reader = TranscriptChangeReader(self), layout = reader.layout(change)
        guard !change.span.isEmpty else { return layout.inserted.joined(separator: " ") }
        var words: [String] = []
        for id in change.span {
            words += layout.before[id] ?? []
            if !layout.old.contains(id) { words.append(reader.text(id)) }
            words += layout.after[id] ?? []
        }
        return words.joined(separator: " ")
    }

    /// The take time each pending change spans, from its first word to its last, for the
    /// overview ruler and the timeline ruler's `change.add` marks.
    var pendingChangeSpans: [ClosedRange<Double>] {
        guard let display = proposalDisplay else { return [] }
        return display.shown.filter { $0.state == .pending }.compactMap { shown in
            guard words.indices.contains(shown.words.lowerBound), words.indices.contains(shown.words.upperBound) else { return nil }
            return words[shown.words.lowerBound].start...max(words[shown.words.lowerBound].start, words[shown.words.upperBound].end)
        }
    }
    /// The clip's tab shows the dirty dot while its proposal has changes not yet reviewed (notes.md §5).
    func hasUnreviewedChanges(clipID: String?) -> Bool {
        guard let proposal, proposal.clipID == clipID else { return false }
        let reader = TranscriptChangeReader(self)
        return proposal.changes.contains { $0.state == .pending && !reader.isPunctuationOnly($0) && !reader.isApplied($0) }
    }

    /// Focuses a change, as ⌥↓, ⌥↑, a click on its new words and the Proposed changes rotor do,
    /// and reads it out.
    func focusChange(_ ordinal: Int, announcing: Bool = true) {
        guard var proposal, proposal[ordinal] != nil else { return }
        proposal.focused = ordinal
        proposal.revealRevision += 1
        self.proposal = proposal
        if announcing, let shown = proposalDisplay?.shown(ordinal) { announce(shown.description) }
    }
    /// ⌥↓ and ⌥↑ (impl-plan §3.2): the next or previous change shown, from the focused one.
    @discardableResult func focusNextChange(_ step: Int) -> Bool {
        guard let display = proposalDisplay, !display.shown.isEmpty else { return false }
        let current = display.shown.firstIndex { $0.ordinal == display.focused }
        let next = current.map { $0 + step } ?? (step > 0 ? 0 : display.shown.count - 1)
        guard display.shown.indices.contains(next) else { return false }
        focusChange(display.shown[next].ordinal)
        return true
    }
    /// The focus after a review: the next pending change shown, wrapping, in `order`, the
    /// changes shown before the review, else the first shown.
    private func advanceFocus(after ordinal: Int, order: [Int]) {
        guard var proposal, let display = proposalDisplay else { return }
        let start = order.firstIndex(of: ordinal) ?? -1
        let rotated = order.count > 0 ? (1...order.count).map { order[(start + $0 + order.count) % order.count] } : []
        if let next = rotated.first(where: { candidate in display.shown(candidate)?.state == .pending }) {
            proposal.focused = next; proposal.revealRevision += 1
        } else if display.shown(ordinal) == nil { proposal.focused = display.shown.first?.ordinal }
        self.proposal = proposal
    }
    /// The cuts and corrections that apply a change's free parts.
    private func commands(_ change: TranscriptChange) -> [EditCommand] {
        let reader = TranscriptChangeReader(self)
        var commands: [EditCommand] = []
        for part in change.parts {
            switch part.kind {
            case .cut:
                let ids = part.sourceWordIDs.filter { !reader.cutWordIDs.contains($0) }
                if !ids.isEmpty { commands.append(.cutSelection(ids: ids)) }
            case .textOnly:
                for (id, text) in zip(part.sourceWordIDs, part.correctedTexts) where reader.text(id) != text { commands.append(.correct(id: id, text: text)) }
            case .voice: break
            }
        }
        return commands
    }
    /// Keep (⌘↩, impl-plan item 7): a cut or fix applies as one undo step, "Keep change {i}",
    /// whose undo also puts the change back as it was, pending or left out; a voice change is
    /// included for takes, with no project change and no undo step. Either is `.kept` from then on.
    @discardableResult func keepChange(_ ordinal: Int) -> Bool {
        guard capabilities.edit, var proposal, let index = proposal.changes.firstIndex(where: { $0.ordinal == ordinal }) else { return false }
        let change = proposal.changes[index], order = proposalDisplay?.shown.map(\.ordinal) ?? []
        guard change.state != .kept else { return false }
        let previous = proposal
        proposal.changes[index].state = .kept
        // A cut's or fix's commands, or a voice change's free parts (an edit split it), apply with it.
        let free = commands(change)
        if !free.isEmpty {
            guard apply(free, name: "Keep change \(ordinal)") else { return false }
            registerProposalUndo(previous)
        }
        self.proposal = proposal
        advanceFocus(after: ordinal, order: order)
        announce("Kept change \(ordinal)")
        return true
    }
    /// Undo (⌘⌫, impl-plan item 7): the change is excluded, `included = false` in the change
    /// list. The project does not change and no undo step is added.
    @discardableResult func excludeChange(_ ordinal: Int) -> Bool {
        guard capabilities.edit, var proposal, let index = proposal.changes.firstIndex(where: { $0.ordinal == ordinal }), proposal.changes[index].state != .excluded else { return false }
        let order = proposalDisplay?.shown.map(\.ordinal) ?? []
        proposal.changes[index].state = .excluded
        self.proposal = proposal
        advanceFocus(after: ordinal, order: order)
        announce("Undid change \(ordinal)")
        return true
    }
    @discardableResult func keepFocusedChange() -> Bool { proposalDisplay?.focused.map { keepChange($0) } ?? false }
    @discardableResult func excludeFocusedChange() -> Bool { proposalDisplay?.focused.map { excludeChange($0) } ?? false }
    /// Keep All (impl-plan item 7): every change still pending. The free ones apply as one
    /// undo step named for the scope ("Rewrite clip 1") and the voice ones are included for
    /// takes; all of them are `.kept`, so a later edit of their words never brings them back.
    @discardableResult func keepAllChanges() -> Bool {
        guard capabilities.edit, var proposal else { return false }
        let reader = TranscriptChangeReader(self)
        let kept = proposal.changes.filter { $0.state == .pending && !reader.isApplied($0) }
        guard !kept.isEmpty else { return false }
        let previous = proposal
        for index in proposal.changes.indices where proposal.changes[index].state == .pending { proposal.changes[index].state = .kept }
        let free = kept.flatMap(commands)
        // Its undo step also takes every change it kept back to pending.
        if !free.isEmpty {
            guard apply(free, name: proposal.title) else { return false }
            registerProposalUndo(previous)
        }
        self.proposal = proposal
        announce(kept.count == 1 ? "Applied 1 change" : "Applied \(kept.count) changes")
        return true
    }

    /// Registers, in the step a Keep's cuts and corrections make, putting the changes' states
    /// and the focus back as they were, so ⌘Z takes what it kept back to pending (or left out)
    /// and ⌘⇧Z keeps them again. It acts only on the proposal it was made in: once a later
    /// Rewrite replaces or clears the proposal, the step undoes the project alone, and the
    /// changes' words as an edit left them stay.
    private func registerProposalUndo(_ previous: TranscriptProposal) {
        let id = previous.id, focused = previous.focused
        let states = Dictionary(previous.changes.map { ($0.ordinal, $0.state) }, uniquingKeysWith: { first, _ in first })
        undoManager?.registerUndo(withTarget: self) { model in
            guard var proposal = model.proposal, proposal.id == id else { return }
            model.registerProposalUndo(proposal)
            for index in proposal.changes.indices {
                if let state = states[proposal.changes[index].ordinal] { proposal.changes[index].state = state }
            }
            proposal.focused = focused
            model.proposal = proposal
        }
    }

    /// The edit popover's save (design.md §6.3.5): the local diff of the change's words and the
    /// new text replaces its parts. Nothing is sent. An empty text turns it into a cut of its
    /// words; a text equal to them leaves nothing to change, so the change is left out.
    @discardableResult func editChange(_ ordinal: Int, text: String) -> Bool {
        guard var proposal, let slot = proposal.changes.firstIndex(where: { $0.ordinal == ordinal }) else { return false }
        var change = proposal.changes[slot]
        let trimmed = EditingPrimitives.jsTrim(text)
        let reader = TranscriptChangeReader(self)
        let source: [TimedWord] = change.span.compactMap { id in
            reader.wordIndex[id].map { position in var word = reader.words[position]; word.text = reader.text(id); return word }
        }
        if source.isEmpty {
            guard !trimmed.isEmpty else { return excludeChange(ordinal) }
            change.parts = [.init(kind: .voice, sourceWordIDs: [], newTokens: EditingPrimitives.splitWords(trimmed))]
        } else if trimmed.isEmpty {
            change.parts = [.init(kind: .cut, sourceWordIDs: source.map(\.id))]
        } else {
            guard let diff = try? VoiceLabWordDiff.diff(source: source, newText: trimmed) else { return false }
            guard !diff.hunks.isEmpty else { return excludeChange(ordinal) }
            // An insertion stands before the word that owns the source token at its index, or after the last word.
            let owners = source.flatMap { word in Array(repeating: word.id, count: max(1, EditingPrimitives.splitWords(word.text).count)) }
            change.parts = diff.hunks.map { hunk in
                var part = TranscriptChange.Part(hunk)
                if hunk.sourceWordIds.isEmpty { part.anchor = owners.indices.contains(hunk.sourceStartIndex) ? .before(owners[hunk.sourceStartIndex]) : source.last.map { .after($0.id) } }
                return part
            }
        }
        change.state = .pending
        proposal.changes[slot] = change
        self.proposal = proposal
        return true
    }
    /// The fit meter line for new words in a voice change's place (voice-lab.md §8.9.1): "about
    /// 2.1 s for a 2.3 s gap: fits". Nil without the take's audio envelope, for an insertion,
    /// for a cut, or where the change cannot be placed.
    func changeFit(_ ordinal: Int, text: String) -> String? {
        let trimmed = EditingPrimitives.jsTrim(text)
        guard let change = proposal?[ordinal], !trimmed.isEmpty, let waveform, let first = change.span.first, let last = change.span.last else { return nil }
        let envelope = AudioEnvelope(sampleRate: Double(project.media.source.audio?.sampleRate ?? 48_000), levels: waveform.fine)
        let scope: VoiceLabOutputScope = project.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full
        let reader = TranscriptChangeReader(self)
        let transcript = reader.words.map { word -> TimedWord in var corrected = word; corrected.text = reader.text(word.id); return corrected }
        do {
            let window = try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: envelope, firstWordId: first, lastWordId: last)
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: window)
            let patch = (window.leftBridgeWordIds.map(reader.text) + [trimmed] + window.rightBridgeWordIds.map(reader.text)).joined(separator: " ")
            let rate = try VoiceLabLengthBudget.rate(transcript: transcript).charactersPerSecond
            let voices = proposal?.changes.filter { $0.kind == .voice && $0.state != .excluded }.count ?? 0
            return try VoiceLabFitMeter.measure(text: patch, window: window, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                                                rate: rate, newWords: trimmed, multipleHunks: voices > 1).copy
        } catch { return nil }
    }
    /// Which change Return edits (design.md §6.3.5): the focused one with no words selected, or
    /// the one whose words the selection lies in; nil leaves Return to Correct Spelling.
    var changeForReturn: Int? {
        guard let display = proposalDisplay, let focused = display.focused, !display.actions.isEmpty else { return nil }
        guard !selectedWordIDs.isEmpty else { return focused }
        let ordinals = Set(selectedWordIDs.map { display.marks[$0]?.ordinal })
        guard ordinals.count == 1, let ordinal = ordinals.first ?? nil else { return nil }
        return ordinal
    }
}
