import Foundation

/// What a Rewrite acts on (design.md §6.3): a kept or suggested clip, named by its `ClipRange` ID; Full take; or a word
/// selection, as inclusive transcript item positions. A clip or Full take is "Fix with AI" over the scope
/// (`ScopeRewritePlan` and `PatchRewriteService`, voice-lab.md §8.1 item 1). A selection is a passage for
/// `VoiceRewriteService` (item 2), so `ScopeRewritePlan.make` refuses it.
public enum RewriteScope: Sendable, Hashable {
    case clip(String)
    case fullTake
    case selection(ClosedRange<Int>)
}

public enum ScopeRewritePlanError: Error, Sendable, Equatable {
    /// More than 3,000 entries (voice-lab.md §8.1). `count` is the number of entries, the scope's kept items, for the R1x
    /// copy "This {video | clip} has {n}."
    case tooManyEntries(count: Int)
    /// At most 3,000 entries, but more than 20,000 UTF-8 bytes of entry text joined with single spaces (§8.1). `bytes` is
    /// that size. Its R1x copy names no count, because the entry count is within its limit.
    case tooMuchText(bytes: Int)
    /// Every item in the scope is cut or already re-voiced.
    case empty
    /// No transcript, an unknown clip, a selection, a take, envelope or scope the window planner cannot read (a scope
    /// `VoiceLabOutputPlanner` does not render included), or no speech rate.
    case invalidInput
}

/// The Fix with AI request for a clip or Full take, before any quote (voice-lab.md §8.1 item 1). Building it is free, pure
/// and sends nothing. Shared vectors: `shared/fixtures/voice-lab/scope-rewrite-plan-cases.json`.
public struct ScopeRewritePlan: Sendable {
    /// Where a line's character range comes from.
    public enum RangeSource: String, Sendable {
        /// The length budget of the line's words placed as one replace hunk (§8.9.1).
        case window
        /// The window was refused, or there is no source envelope: the advisory budget of the line's own word span.
        case lineSpan
        /// The line holds only events or unlabeled speech, so there is nothing to re-voice: its labels' length, at least 1.
        case noSpeech
    }

    /// One `formatTranscript` line of the entries and its character range.
    public struct Line: Sendable, Equatable {
        /// The line's `[a-b]` label, as the request's range names it.
        public let line: String
        /// The line's items as the transcript holds them, corrections applied, in source order: the items `ScopeRewriteDiff`
        /// diffs an edit of the line against. Cut and re-voiced items between them are not listed.
        public let items: [TimedWord]
        /// The line's request entries, one per item: the text the model read.
        public let entries: [ClipWord]
        /// `minChars...maxChars`, at most 5,000 on both bounds.
        public let range: ClosedRange<Int>
        public let rangeSource: RangeSource
        /// The transcript item IDs of the line's entries, in source order.
        public var itemIDs: [String] { items.map(\.id) }
    }

    public static let maxEntries = 3_000
    public static let maxBytes = 20_000
    /// ai.md §11.2, in UTF-16 code units.
    static let maxWordTextLength = 100
    /// The request's range limit (voice-lab.md §8.1).
    static let maxChars = 5_000

    public let scope: RewriteScope
    public let lines: [Line]
    public let request: PatchRewriteRequest
    /// The scope's kept items in source order (§8.1 item 1).
    public var entries: [ClipWord] { request.entries }

    /// Plans a clip or Full take.
    ///
    /// - The take, the `envelope` when there is one and the scope's render scope are read first, as
    ///   `VoiceLabWindowPlanner.place` reads them. One it cannot read, including a scope `VoiceLabOutputPlanner` does not
    ///   render, is `.invalidInput` for the whole plan.
    /// - Entries are the scope's kept items, in source order, in the ai.md §11.2 item format: the absolute position, the
    ///   display text with corrections applied (an event's label, "…" for unlabeled speech), cut to 100 UTF-16 units without
    ///   splitting a surrogate pair. Unlike §11.2, which sends every item, cut items are left out, and so are the items an
    ///   enabled replacement of the scope already re-voices (§8.4): their cuts and corrections are dormant and no window
    ///   may overlap them, so no edit to them could apply. A clip keeps only the items from its first to its last word.
    /// - Lines are `formatTranscript` of the entries (ai.md §11.3).
    /// - A line's range is the §8.9.1 budget of its words as one replace hunk: `VoiceLabWindowPlanner.place` from the line's
    ///   first to its last word item in the scope's render scope, `lendableSilence` for the take-edge pads, and the bridge
    ///   words' length as `f`, at the §8.9.1 rate: `candidates`, the stored candidates for the voice, model and language key,
    ///   or the take's transcript with corrections applied when there are none. A refused window, or a nil `envelope`,
    ///   falls back to `VoiceLabLengthBudget.fullTake` of the line's items, except a refusal saying the scope does not
    ///   render as it stands (`invalidInput` naming a replacement), which is the plan's. The model returns the whole line,
    ///   echoing its event labels, and Core counts every letter of it, so both bounds add the `VoiceLabTextLength` of the
    ///   line's non-word entries; a line with no word item gets that length, at least 1, on both. Both bounds are capped at
    ///   5,000.
    /// - The instruction and language pass through; `PatchRewriteService` checks them with the rest of the request.
    public static func make(project: Project, scope: RewriteScope, instruction: String, language: String,
                            envelope: AudioEnvelope?, candidates: [VoiceLabRateCandidate] = [],
                            id: UUID = UUID()) throws -> ScopeRewritePlan {
        guard let items = project.transcript?.words else { throw ScopeRewritePlanError.invalidInput }
        let edits = project.edits
        let outputScope: VoiceLabOutputScope
        let positions: Range<Int>
        switch scope {
        case .fullTake:
            outputScope = .full
            positions = items.indices
        case .clip(let clipID):
            guard let clip = edits.clips.first(where: { $0.id == clipID }), let bounds = clipIndices(clip, words: items) else {
                throw ScopeRewritePlanError.invalidInput
            }
            outputScope = .clip(clipID)
            positions = bounds.lowerBound..<bounds.upperBound + 1
        case .selection:
            throw ScopeRewritePlanError.invalidInput
        }
        // The take, the envelope and the render scope, read once: a failure there is the plan's, never one line's.
        let replaced: [Bool]
        do { replaced = try VoiceLabWindowPlanner.replacedItems(project: project, scope: outputScope, envelope: envelope) }
        catch { throw ScopeRewritePlanError.invalidInput }

        // The take as the user reads it: corrections applied to words. The rate and the bridge lengths read it too.
        let corrected = items.map { item -> TimedWord in
            var value = item
            if item.kind == .word { value.text = edits.corrections[item.id] ?? item.text }
            return value
        }
        let cut = Set(edits.cutWordIds)
        let kept = positions.filter { !cut.contains(items[$0].id) && !replaced[$0] }
        let entries = kept.map { position -> ClipWord in
            let item = corrected[position]
            let text = item.kind == .unlabeledSpeech ? "…" : item.text
            return ClipWord(index: position, text: AIText.prefix(text, utf16: maxWordTextLength), start: item.start, end: item.end)
        }
        guard !entries.isEmpty else { throw ScopeRewritePlanError.empty }
        guard entries.count <= maxEntries else { throw ScopeRewritePlanError.tooManyEntries(count: entries.count) }
        let bytes = entries.map(\.text).joined(separator: " ").utf8.count
        guard bytes <= maxBytes else { throw ScopeRewritePlanError.tooMuchText(bytes: bytes) }
        let formatted: FormattedTranscript
        do { formatted = try formatTranscript(entries) } catch { throw ScopeRewritePlanError.invalidInput }

        var speechRate: Double?
        func rate() throws -> Double {
            if let speechRate { return speechRate }
            do {
                let value = try VoiceLabLengthBudget.rate(transcript: corrected, pauseThresholdSeconds: edits.pauseThresholdSeconds,
                                                          candidates: candidates)
                speechRate = value.charactersPerSecond
                return value.charactersPerSecond
            } catch { throw ScopeRewritePlanError.invalidInput }
        }
        var lines: [Line] = []
        for line in formatted.lines {
            let lineItems = kept[line.firstPos...line.lastPos].map { corrected[$0] }
            let lineEntries = Array(entries[line.firstPos...line.lastPos])
            let label = "[\(line.firstIndex)-\(line.lastIndex)]"
            // The labels the model echoes when it returns the line: an event's counts, and "…" has no letters.
            let echoed = (line.firstPos...line.lastPos).filter { corrected[kept[$0]].kind != .word }
                .reduce(0) { $0 + VoiceLabTextLength.length(entries[$1].text) }
            guard let first = lineItems.first(where: { $0.kind == .word }), let last = lineItems.last(where: { $0.kind == .word }) else {
                let chars = min(max(1, echoed), maxChars)
                lines.append(Line(line: label, items: lineItems, entries: lineEntries, range: chars...chars, rangeSource: .noSpeech))
                continue
            }
            let speech = try rate()
            let budget: VoiceLabLengthRange
            let source: RangeSource
            if let placed = try windowBudget(project: project, scope: outputScope, envelope: envelope, first: first.id,
                                             last: last.id, transcript: corrected, rate: speech) {
                budget = placed
                source = .window
            } else {
                do { budget = try VoiceLabLengthBudget.fullTake(transcript: lineItems, rate: speech) }
                catch { throw ScopeRewritePlanError.invalidInput }
                source = .lineSpan
            }
            let lower = min(budget.minChars + echoed, maxChars), upper = min(budget.maxChars + echoed, maxChars)
            lines.append(Line(line: label, items: lineItems, entries: lineEntries, range: lower...upper, rangeSource: source))
        }
        let ranges = lines.map { PatchRewriteLineRange(line: $0.line, minChars: $0.range.lowerBound, maxChars: $0.range.upperBound) }
        return ScopeRewritePlan(scope: scope, lines: lines,
                                request: PatchRewriteRequest(id: id, entries: entries, ranges: ranges, instruction: instruction, language: language))
    }

    /// §8.9.1 for one line placed as a replace hunk. Nil, so the caller falls back, without an envelope or when the window or
    /// its budget is refused. A refusal that names a replacement as `invalidInput` says the scope does not render as it
    /// stands (§8.4 step 6), which no line can mend, so it throws.
    private static func windowBudget(project: Project, scope: VoiceLabOutputScope, envelope: AudioEnvelope?, first: String,
                                     last: String, transcript: [TimedWord], rate: Double) throws -> VoiceLabLengthRange? {
        guard let envelope else { return nil }
        do {
            let window = try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: envelope, firstWordId: first,
                                                         lastWordId: last)
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: window)
            return try VoiceLabLengthBudget.passage(window: window, transcript: transcript, incomingSilence: silence.incoming,
                                                    outgoingSilence: silence.outgoing, rate: rate)
        } catch let refusal as VoiceLabGeometryError {
            if case .invalidInput(let segmentId) = refusal, segmentId != nil { throw ScopeRewritePlanError.invalidInput }
            return nil
        } catch {
            return nil
        }
    }
}
