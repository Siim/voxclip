import Foundation

/// A clip or Full take Fix with AI proposal as review hunks (voice-lab.md §8.1 item 1 and §8.2). Pure; it sends nothing and
/// changes no project. Shared vectors: `shared/fixtures/voice-lab/scope-rewrite-diff-cases.json`.
public enum ScopeRewriteDiff {
    /// One review hunk of a scope proposal: a tracked change and its checklist row.
    public struct Hunk: Sendable, Equatable {
        /// The §8.2 hunk. Its source token indices address the word tokens of all the plan's lines in line order (each word
        /// item's `splitWords` tokens) and order the hunks. Its source item IDs are its stable key in the transcript.
        public let hunk: VoiceLabDiffHunk
        /// An insertion has no source item, so this is its key: the ID of the plan item it follows, nil when it comes before
        /// the plan's first item. It lies between that item and the plan's next one, at `hunk.anchorSeconds`. Its
        /// `sourceStartIndex` cannot say which side of an event or an echoed label between two word tokens it is on. Nil for
        /// a hunk with source items.
        public let insertionAfterItemID: String?
        /// The `[a-b]` labels of the edits the hunk comes from, in line order: one, or more after a merge across lines.
        public let lines: [String]
        /// Each of those edits' reasons, in the same order.
        public let reasons: [String]
        /// One of the hunk's own new tokens is a token the §8.1 `checkThis` rule flags in its edit; a merged hunk carries it
        /// when one of its parts does. A cut has no new token, so it never carries it.
        public let checkThis: Bool
    }

    /// At most this many equal word items, or at most `mergeSeconds` of source time, let two voice hunks merge (§8.2 step 6).
    static let mergeWords = 2
    static let mergeSeconds = 0.35

    /// One hunk before the merge across stretches.
    private struct Part {
        var hunk: VoiceLabDiffHunk
        var lines: [String]
        var reasons: [String]
        var checkThis: Bool
        /// The first voice hunk of its stretch: only such a hunk may merge with an earlier stretch's.
        var firstVoice: Bool
        /// Its stretch holds no word item, so it is an insertion that is never merged.
        var wordless: Bool
        /// For an insertion in a stretch with words, the scope item position §8.2 step 6 gives it: the item of the next
        /// word token in its stretch, or of the stretch's last one.
        var insertItem: Int?
        /// For an insertion, the plan item it follows.
        var after: String?
    }

    /// One word token of the scope: its item's position among the plan's items, and that item's times.
    private struct Token {
        let item: Int
        let start: Double
        let end: Double
    }

    /// The items of one line between two echoed entries, or an echoed entry and a re-voiced run, or either and the line's
    /// edge, and the edit's tokens between them.
    private struct Stretch {
        var items: [TimedWord] = []
        var newTokens: [String] = []
        /// Each new token's position among the edit's `splitWords` tokens.
        var editIndices: [Int] = []
        /// The echoed entries right before and after it, when it is bounded by one.
        var before: TimedWord?
        var after: TimedWord?
    }

    /// The hunks of `proposal`'s edits over `plan`'s lines, in transcript order.
    ///
    /// - Echoed labels. The model reads a line's events as their labels and unlabeled speech as "…", and may return them.
    ///   The edit is paired with the line as the model read it: `VoiceLabWordDiff` over the line's entries' texts, every
    ///   entry a word. A non-word entry is echoed when each of its tokens pairs with an `equal` and no inserted token falls
    ///   between them. Echoed tokens are dropped, never spoken, and each echoed entry splits the line into stretches.
    /// - Re-voiced runs. Items an enabled replacement already re-voices are not in the plan, but no window may span them
    ///   (§8.4 step 6), so a run of them also splits its line (`Line.revoicedBefore`). Each new token joins the stretch of
    ///   the source token the pairing walked last, the first stretch before any.
    /// - Each stretch, the line's items between two such splits (corrections applied, as `Line.items` holds them) and the
    ///   edit's tokens between them, is diffed alone with `VoiceLabWordDiff`. A label left out or changed is not echoed: its
    ///   entry stays in its stretch, where a voice hunk across it absorbs it, and a changed label's tokens are new words.
    /// - §8.2 step 6 then runs across stretches in transcript order: each stretch's first voice hunk may merge with the last
    ///   voice hunk before it. Counts, times and barriers read the plan's items, so a cut item never stops a merge, as within
    ///   one line, but a re-voiced run between the two hunks does, like an event. An insertion's time is the anchor its
    ///   stretch gives it.
    /// - An insertion into a stretch with no word item anchors at the start of the stretch's first item, else at the start of
    ///   the echoed entry after it, else at the end of the one before it, and is never merged.
    /// - An edit for a line the plan does not have, or a second edit for one line, is `VoiceLabWordDiffError.invalidInput`; a
    ///   line over the `VoiceLabWordDiff` token limit is its `tokenLimit`.
    public static func hunks(plan: ScopeRewritePlan, proposal: PatchRewriteProposal) throws -> [Hunk] {
        let labels = Set(plan.lines.map { Array($0.line.unicodeScalars) })
        var edits: [[Unicode.Scalar]: PatchRewriteEdit] = [:]
        for edit in proposal.edits {
            let label = Array(edit.line.unicodeScalars)
            guard labels.contains(label), edits.updateValue(edit, forKey: label) == nil else { throw VoiceLabWordDiffError.invalidInput }
        }
        let sources = PatchRewriteValidator.Sources(plan.request.entries.map(\.text) + [plan.request.instruction])
        var ids: [String] = []
        var kinds: [WordKind] = []
        // Per plan item: a re-voiced run lies between it and the item before it.
        var revoiced: [Bool] = []
        var tokens: [Token] = []
        // Each word token's new surface where its stretch keeps it (an `equal`), else its own: the text a bridge speaks.
        var surfaces: [String] = []
        var parts: [Part] = []
        for line in plan.lines {
            guard line.items.count == line.entries.count, line.revoicedBefore.count == line.items.count else {
                throw VoiceLabWordDiffError.invalidInput
            }
            let firstItem = ids.count
            let firstToken = tokens.count
            for (offset, item) in line.items.enumerated() {
                ids.append(item.id)
                kinds.append(item.kind)
                revoiced.append(line.revoicedBefore[offset])
                guard item.kind == .word else { continue }
                for surface in EditingPrimitives.splitWords(item.text) {
                    tokens.append(Token(item: firstItem + offset, start: item.start, end: item.end))
                    surfaces.append(surface)
                }
            }
            guard let edit = edits[Array(line.line.unicodeScalars)] else { continue }

            // The line as the model read it, every entry a word, so the LCS pairs the labels it echoed.
            let read = zip(line.items, line.entries).map { (pair: (TimedWord, ClipWord)) -> TimedWord in
                TimedWord(id: pair.0.id, text: pair.1.text, start: pair.0.start, end: pair.0.end)
            }
            let pairing = try VoiceLabWordDiff.diff(source: read, newText: edit.text).ops
            var echoedIDs: Set<String> = []
            for item in line.items where item.kind != .word {
                let at = pairing.indices.filter { pairing[$0].sourceWordId == item.id }
                if let first = at.first, let last = at.last, last - first + 1 == at.count,
                   at.allSatisfy({ pairing[$0].kind == .equal }) {
                    echoedIDs.insert(item.id)
                }
            }
            // Stretches end at each echoed entry, which is dropped, and before each item a re-voiced run precedes. Each
            // item's stretch; an echoed entry's is the stretch after it.
            var stretches = [Stretch()]
            var stretchOf: [String: Int] = [:]
            var position: [String: Int] = [:]
            for (offset, item) in line.items.enumerated() {
                position[item.id] = firstItem + offset
                if offset > 0 && line.revoicedBefore[offset] { stretches.append(Stretch()) }
                if echoedIDs.contains(item.id) {
                    stretches[stretches.count - 1].after = item
                    stretches.append(Stretch(before: item))
                } else {
                    stretches[stretches.count - 1].items.append(item)
                }
                stretchOf[item.id] = stretches.count - 1
            }
            // Each new token joins the stretch of the source token the pairing walked last, the first stretch before any.
            var current = 0
            var newIndex = 0
            for op in pairing {
                if let id = op.sourceWordId, let stretch = stretchOf[id] { current = stretch }
                guard let token = op.newToken else { continue }
                let echoedToken: Bool = op.sourceWordId.map { (id: String) -> Bool in echoedIDs.contains(id) } ?? false
                if !echoedToken {
                    stretches[current].newTokens.append(token)
                    stretches[current].editIndices.append(newIndex)
                }
                newIndex += 1
            }
            let flags = sources.flaggedTokens(edit.text)

            var offset = firstToken
            for stretch in stretches {
                let count = stretch.items.reduce(0) { (total: Int, item: TimedWord) -> Int in
                    total + (item.kind == .word ? EditingPrimitives.splitWords(item.text).count : 0)
                }
                let startToken = offset
                offset += count
                if stretch.items.isEmpty && stretch.newTokens.isEmpty { continue }
                let diff = try VoiceLabWordDiff.diff(source: stretch.items, newText: stretch.newTokens.joined(separator: " "))
                var walked = 0
                for op in diff.ops {
                    if op.kind == .equal, let token = op.newToken { surfaces[startToken + walked] = token }
                    if op.kind != .insert { walked += 1 }
                }
                var firstVoice = true
                for found in diff.hunks {
                    var anchor = found.anchorSeconds
                    var insertItem: Int?
                    var after: String?
                    if found.sourceStartIndex == found.sourceEndIndex {
                        // The plan item before the insertion, as a position among the plan's items (-1 before the first).
                        let previous: Int
                        if count == 0 {
                            // No word to anchor on: the stretch's first item, else the echoed entry after it, else the one
                            // before it. An empty stretch only takes new tokens beside an echoed entry.
                            if let item = stretch.items.first, let place = position[item.id] {
                                anchor = item.start
                                previous = place - 1
                            } else if let next = stretch.after, let place = position[next.id] {
                                anchor = next.start
                                previous = place - 1
                            } else if let echo = stretch.before, let place = position[echo.id] {
                                anchor = echo.end
                                previous = place
                            } else {
                                throw VoiceLabWordDiffError.invalidInput
                            }
                        } else {
                            // Before the item of the next word token in its stretch, or after the stretch's last word.
                            let item = tokens[startToken + min(found.sourceStartIndex, count - 1)].item
                            insertItem = item
                            previous = found.sourceStartIndex < count ? item - 1 : item
                        }
                        after = previous >= 0 ? ids[previous] : nil
                    }
                    let begin = newStart(diff.ops, before: found.sourceStartIndex)
                    let flagged = found.newTokens.indices.contains { (index: Int) -> Bool in
                        let at = begin + index
                        guard at < stretch.editIndices.count else { return false }
                        let token = stretch.editIndices[at]
                        return token < flags.count ? flags[token] : edit.checkThis
                    }
                    let hunk = VoiceLabDiffHunk(kind: found.kind, sourceWordIds: found.sourceWordIds, newTokens: found.newTokens,
                                                correctedTexts: found.correctedTexts, absorbedItemIds: found.absorbedItemIds,
                                                bridgeWordIds: found.bridgeWordIds, sourceStartIndex: startToken + found.sourceStartIndex,
                                                sourceEndIndex: startToken + found.sourceEndIndex, anchorSeconds: anchor)
                    parts.append(Part(hunk: hunk, lines: [line.line], reasons: [edit.reason], checkThis: flagged,
                                      firstVoice: found.kind == .voice && firstVoice, wordless: count == 0, insertItem: insertItem,
                                      after: after))
                    if found.kind == .voice { firstVoice = false }
                }
            }
        }

        func startTime(_ part: Part) -> Double {
            part.hunk.sourceStartIndex < part.hunk.sourceEndIndex ? tokens[part.hunk.sourceStartIndex].start : part.hunk.anchorSeconds ?? 0
        }
        func endTime(_ part: Part) -> Double {
            part.hunk.sourceStartIndex < part.hunk.sourceEndIndex ? tokens[part.hunk.sourceEndIndex - 1].end : part.hunk.anchorSeconds ?? 0
        }
        func firstPosition(_ part: Part) -> Int {
            part.hunk.sourceStartIndex < part.hunk.sourceEndIndex ? tokens[part.hunk.sourceStartIndex].item : part.insertItem ?? 0
        }
        func lastPosition(_ part: Part) -> Int {
            part.hunk.sourceStartIndex < part.hunk.sourceEndIndex ? tokens[part.hunk.sourceEndIndex - 1].item : part.insertItem ?? 0
        }
        var merged: [Part] = []
        for part in parts {
            if part.firstVoice, !part.wordless, let earlierIndex = merged.lastIndex(where: { $0.hunk.kind == .voice }),
               !merged[earlierIndex].wordless, merged[earlierIndex].hunk.sourceEndIndex <= part.hunk.sourceStartIndex,
               !merged[(earlierIndex + 1)...].contains(where: { $0.hunk.kind == .cut }) {
                let earlier = merged[earlierIndex]
                let between = earlier.hunk.sourceEndIndex..<part.hunk.sourceStartIndex
                let bridges = unique(between.map { ids[tokens[$0].item] })
                let gap = startTime(part) - endTime(earlier)
                let left = lastPosition(earlier), right = firstPosition(part)
                // An event or unlabeled speech between them, or a re-voiced run, which lies before an item that has the flag:
                // no window may span it (§8.4 step 6).
                let event = right > left + 1 && (left + 1..<right).contains { (index: Int) -> Bool in kinds[index] != .word }
                let run = right > left && (left + 1...right).contains { (index: Int) -> Bool in revoiced[index] }
                if !event && !run && (bridges.count <= mergeWords || gap <= mergeSeconds) {
                    let pieces = Array(merged[earlierIndex...]) + [part]
                    var lines: [String] = []
                    var reasons: [String] = []
                    for piece in pieces {
                        for (label, reason) in zip(piece.lines, piece.reasons) where !lines.contains(label) {
                            lines.append(label)
                            reasons.append(reason)
                        }
                    }
                    let start = earlier.hunk.sourceStartIndex, end = part.hunk.sourceEndIndex
                    let hunk = VoiceLabDiffHunk(kind: .voice, sourceWordIds: unique(earlier.hunk.sourceWordIds + bridges + part.hunk.sourceWordIds),
                                                newTokens: earlier.hunk.newTokens + between.map { surfaces[$0] } + part.hunk.newTokens,
                                                correctedTexts: [], absorbedItemIds: earlier.hunk.absorbedItemIds + part.hunk.absorbedItemIds,
                                                bridgeWordIds: unique(earlier.hunk.bridgeWordIds + bridges + part.hunk.bridgeWordIds),
                                                sourceStartIndex: start, sourceEndIndex: end,
                                                anchorSeconds: start == end ? earlier.hunk.anchorSeconds : nil)
                    merged.removeSubrange(earlierIndex...)
                    merged.append(Part(hunk: hunk, lines: lines, reasons: reasons, checkThis: pieces.contains { $0.checkThis },
                                       firstVoice: false, wordless: false, insertItem: part.insertItem,
                                       after: start == end ? earlier.after : nil))
                    continue
                }
            }
            merged.append(part)
        }
        return merged.map { (part: Part) -> Hunk in
            Hunk(hunk: part.hunk, insertionAfterItemID: part.after, lines: part.lines, reasons: part.reasons, checkThis: part.checkThis)
        }
    }

    /// How many new tokens come before a hunk that starts at source token `source`: those of the `equal`s before it and of
    /// the insertions at an earlier source position. An insertion at its own position belongs to the hunk (§8.2 step 4).
    private static func newStart(_ ops: [VoiceLabDiffOp], before source: Int) -> Int {
        var count = 0
        var position = 0
        for op in ops {
            guard position < source else { break }
            if op.kind != .delete { count += 1 }
            if op.kind != .insert { position += 1 }
        }
        return count
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
