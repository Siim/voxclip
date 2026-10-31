# Scope rewrite vectors

Two files pin a clip or Full take Rewrite (voice-lab.md §8.1 item 1): the plan, before any quote, and the diff of the
proposal into review hunks. Only the Swift suites replay them until the C# twins land (plan W1).

## Plan

`scope-rewrite-plan-cases.json` pins `ScopeRewritePlan.make`: the Fix with AI request for a clip or Full take
(voice-lab.md §8.1 item 1), before any quote. `tools/fixtures/voice-lab/generate_scope_rewrite.py` writes it (Python 3,
standard library only, byte-identical on every run); change the generator, never the JSON. All inputs are synthetic and
offline. The Swift suite `ScopeRewritePlanTests` replays every case. The C# suite does not yet; the C# twin (plan W1)
replays the same file.

### Rules the generator encodes

- **Scope.** `fullTake` covers every transcript item. `clip` names a `ClipRange` in `edits.clips`, kept (`origin`
  `manual`, or `ai` and selected) or suggested (`ai`, not selected); both are planned alike, from the clip's first to its
  last word. An unknown clip is `invalidInput`. A `selection` is a passage for `VoiceRewriteService` (§8.1 item 2), so it
  is `invalidInput` here.
- **Take and scope.** The take, the envelope (when there is one) and the scope's render scope are read first, as
  `VoiceLabWindowPlanner.place` reads them. A take, envelope or scope it cannot read is `invalidInput` for the whole plan,
  never a silent fallback: an envelope on another sample rate, or a scope `VoiceLabOutputPlanner` does not render, such as
  a clip whose `clipTimes` boundary crosses an enabled replacement (voice-lab.md §10.2).
- **Entries.** The scope's kept items in source order, each `{index, text, start, end}` in the ai.md §11.2 item format:
  `index` is the absolute transcript position; `text` is a word's display text with its correction applied, an event's
  stored label, or `…` for unlabeled speech, cut to 100 UTF-16 units without splitting a surrogate pair. Unlike ai.md
  §11.2, which sends every item (the clip finder needs them), cut items are left out: an item whose ID is in `cutWordIds`
  is never an entry, whatever its kind. This is the voice-lab.md §8.1 rule; D0 confirmed it in the spec, and
  `tools/voice-lab/test_rewrite_spec.py` keeps the two sections apart. An item wholly inside an enabled replacement of
  the scope (§8.4 replaced items) is left out too: its cuts and corrections are dormant and no window may overlap it, so
  no edit to it could apply, and the model never sees words the video no longer has. A disabled replacement changes
  nothing.
- **Limits.** No entry is `empty`. More than 3,000 entries is `tooManyEntries` with `count`, the entry count, for the R1x
  copy. Otherwise more than 20,000 UTF-8 bytes of entry text joined with single spaces is `tooMuchText` with `bytes`, that
  size; its R1x copy names no count. The limits count kept items: cutting one of 3,001 items passes, and a clip counts
  only its own.
- **Lines.** `formatTranscript` (ai.md §11.3) of the entries. Corrections apply first, so a correction that adds a full
  stop ends a line. `itemIds` lists the line's entries; cut items between them are not listed. `revoicedBefore` lists
  the line's items that a run of re-voiced items precedes, back to the entry before (Swift `Line.revoicedBefore`, one
  flag per item). No window may span such a run (§8.4 step 6), so the diff never merges across it; cut items set no
  flag.
- **Ranges** (§8.9.1), in this order:
  - The model returns a line's whole text, echoing its event labels, and Core counts every letter of it. So both bounds
    add the `VoiceLabTextLength` of the line's non-word entries (an event's label; `…` has none), and keeping a label
    never pushes an edit out of range.
  - A line with no word item (only events or unlabeled speech) has nothing to re-voice: that length, at least 1, on both
    bounds, `noSpeech`.
  - With an envelope, the line's words are placed as one replace hunk: `VoiceLabWindowPlanner.place` from the line's first
    to its last word item, in the scope's render scope (Full take, or the clip with its `clipTimes` head and tail) beside
    its enabled replacements, then `lendableSilence` for the take-edge pads and the bridge words' `VoiceLabTextLength` as
    `f`. `window`.
  - The speech rate is the §8.9.1 rate: the case's `rateCandidates`, the stored candidates for the voice, model and
    language key, or else `VoiceLabLengthBudget.rate` of the whole take with corrections applied and the take's pause
    threshold. A malformed candidate span is `invalidInput`.
  - A refused window, or no envelope (`envelope: null`), takes `VoiceLabLengthBudget.fullTake` of the line's items:
    first word start to last word end, `e = f = 0`. `lineSpan`. A line whose words lie on both sides of a replacement
    is one of these: its window overlaps it. A refusal that says the scope does not render as it stands (`invalidInput`
    naming a replacement, §8.4 step 6) is `invalidInput` for the whole plan instead.
  - Both bounds are capped at 5,000, the request's limit.
- **Request.** `instruction` and `language` pass through; `PatchRewriteService` checks them with the rest. The suite
  also runs `PatchRewriteService.estimate` on every plan, so each plan is a request the service accepts.

### Case shape

- `input`: `sampleRate`, `durationSeconds`, the take's items (`words`, or the `wordsRepeat` recipe), `edits`
  (`cutWordIds`, `cutPauseIds`, `corrections`, `pauseThresholdSeconds`, `pauseKeepSeconds` and `clips` with `origin`
  and `selected`), `envelope` (`sampleRate` and 10 ms levels as `[level, count]` runs, or `null`), `scope` (`kind`
  `fullTake`, `clip` with `clipId`, or `selection` with `first` and `last`), `instruction` and `language`. The suite
  builds the take on `passage-render-v3.voxclip` with its replacements removed, as the window vectors do.
- Optional `segments`: the replacements already accepted, each `{id, enabled, start, end, firstWordId, lastWordId,
  inSeam, outSeam}` with each seam's `kind` and `fadeSamples`. The generator places each one with generate_window.py's
  `place` and checks that it renders; the suite builds it on the fixture's replacement with that range and those seams,
  which is all `place` reads.
- Optional `rateCandidates`: `{text, firstCharStart, lastCharEnd}` for the rate key, passed as `candidates`.
- `wordsRepeat` follows the word-diff `sourceRepeat` recipe: item `i` has ID `idPrefix + i`, text `token`, kind `word`,
  start `i * timingStep` and end `start + timingStep / 2`.
- `expected` is one of:
  - `{entries, utf8Bytes, lines}`: every entry and every line with `line`, `itemIds`, `revoicedBefore`, `minChars`,
    `maxChars` and `rangeSource`. A line's `note` (the seams, target and bridge length, or the refusal) is informative; the suites do
    not read it.
  - `{summary}` for the three large passing cases: the entry count, the byte count, the first and last entry, and each
    line's label, item count, first and last item ID, range and source.
  - `{error}`: `tooManyEntries` (with `count`), `tooMuchText` (with `bytes`), `empty` or `invalidInput`.

### Coverage

A kept clip with a cut repeat inside a line and corrections; Full take with an event-only line and a line refused
because a cut filler touches it; a clip at the take start (`none` incoming seam, so the edge pad shortens the target)
and at the take end (`none` outgoing seam); a suggested clip whose head cuts the event before it; no envelope; an
all-cut clip, an unknown clip, a selection and an envelope on the wrong rate; event labels at the start and the end of a
line; an enabled replacement inside a clip line and one beside other lines, with the items their runs precede, the
same one disabled, a clip boundary crossing one (with and without an envelope), a cut after acceptance that leaves the
scope unrenderable, and a scope that is all re-voiced; a stored-candidate rate and a malformed candidate; 100-unit text cuts with a surrogate pair at the boundary;
the 5,000 cap; and the entry and byte limits on both sides, with both over at once.

## Diff

`scope-rewrite-diff-cases.json` pins `ScopeRewriteDiff.hunks(plan:proposal:)`: the Fix with AI edits of a clip or Full take
as review hunks (voice-lab.md §8.1 item 1 and §8.2). `tools/fixtures/voice-lab/generate_scope_rewrite_diff.py` writes it
(Python 3, standard library only, byte-identical on every run); change the generator, never the JSON. It loads only the
definitions of `generate_scope_rewrite.py` for the plan, of `generate_word_diff.py` for the §8.2 diff, and of
`generate_patch_rewrite.py` for the edit validation and the `checkThis` rule, and reads `patch-rewrite-cases.json`. The
Swift suite `ScopeRewriteDiffTests` replays every case. The C# suite does not yet.

### Rules the generator encodes

- **Edits.** Each kept edit is one line's whole new text. An edit for a line the plan does not have, or a second edit for
  one line, is `invalidInput`: the proposal is not this plan's. A line without an edit is unchanged.
- **Echoed labels.** The model reads a line's events as their labels and unlabeled speech as `…` (ai.md §11.2), and may
  return them. The edit's tokens are paired with the line as the model read it: the §8.2 diff (steps 1 to 3) over the
  line's entry texts, every entry tokenised as a word. A non-word entry is *echoed* when each of its tokens pairs with an
  `equal` and no inserted token falls between them. Echoed tokens are dropped, so they are never spoken, and each echoed
  entry splits the line into *stretches*: the items and new tokens between two echoed entries, or between one and the
  line's edge. A label the model left out or changed is not echoed. Its entry stays in its stretch, where a voice hunk
  across it absorbs it (§8.2 step 6); a changed label's tokens are new words.
- **Re-voiced runs.** The plan leaves out items an enabled replacement already re-voices, but no window may span them
  (§8.4 step 6), so a run of them splits its line into stretches too (`revoicedBefore`). The model never saw the run, so
  each new token joins the stretch of the source token the pairing walked last, or the first stretch before any: a
  change on both sides of the run becomes two changes beside it (`revoiced-run-splits-a-change`), and a word added
  where it lies joins the stretch before it (`revoiced-run-insertion`).
- **Per stretch.** `VoiceLabWordDiff` runs on each stretch alone, so every DP stays within one line. Its source is the
  stretch's items as the transcript holds them, corrections applied (`ScopeRewritePlan.Line.items`), not the entry text,
  which is cut to 100 UTF-16 units: a longer item echoed as sent shows as a change the user can leave out. An empty edit
  (`isDeletion`) cuts the line's words; its events and unlabeled speech stay (§8.2 step 5).
- **Across stretches.** §8.2 step 6 runs once more over the scope in transcript order: the first voice hunk of each
  stretch may merge with the last voice hunk before it (within a stretch, `VoiceLabWordDiff` has decided). The rule is
  unchanged: only equal words between them (no cut hunk), at most 2 equal word items or at most 0.35 s from the earlier
  hunk's last source word end to the later hunk's first source word start (binary64, inclusive), and never across an event
  or unlabeled speech among the plan's items, or a re-voiced run between them. An echoed entry is such an item, so the
  stretches it splits never merge, and neither do those a re-voiced run splits: the merged window would overlap the
  replacement and be refused, where each part places beside it. The counts, times and barriers read the plan's items: a
  cut item is not among them and never stops a merge, as within one line's diff. An insertion's time and barrier position
  are its stretch's: the next word token's start in its stretch, or the stretch's last word end, and that word's item. The
  equal words between become bridges with their new surfaces, and a text-only hunk among them is absorbed. Two insertions
  merged with nothing between keep the earlier one's anchor and item.
- **Insertions with no word.** In a stretch without a word item, an insertion anchors at the start of the stretch's first
  item, else at the start of the echoed entry after it, else at the end of the one before it. It is never merged.
- **Indices.** A hunk's `sourceStartIndex` and `sourceEndIndex` address the word tokens of all the plan's lines in line
  order (each word item's `splitWords` tokens), not one line's. They order the hunks, but an insertion's index cannot say
  on which side of an event or an echoed label between two tokens it lies.
- **Insertion place.** An insertion has no source item, so `insertionAfterItemId` names the plan item it follows, `null`
  before the plan's first item: it lies between that item and the plan's next one, at `anchorSeconds`. An insertion
  before word token `p` follows the plan item before that token's item; one at a stretch's end follows the stretch's last
  word; one in a stretch without words follows the item before its anchor item, or the echoed entry it comes after.
  Every hunk with source items has `null`.
- **Carried per hunk.** `lines` and `reasons`: the labels and reasons of the edits the hunk comes from, in line order;
  after a merge, every part's, including an absorbed text-only hunk's. `checkThis`: one of the hunk's own new tokens is a
  token the §8.1 rule flags in its edit, the edit's whole text giving each token's sentence start; a merged hunk carries it
  when one part does. The edit's flag is true exactly when one of its tokens is. A cut has no new token and never carries
  it, and neither does anything for an echoed label the rule flags: it is dropped (`flagged-label-echo`).
- **Budget.** The §8.2 patch budget over the hunks after every merge, as M7 applies it to a scope proposal: the new
  tokens of every voice hunk, bridges included, against the word items of the whole transcript (cut and re-voiced items
  included), `reRecordInstead` when `count × 100 > 15 × wordItems` or `count > 60`.

### Case shape

- `cases`: `input` is a plan vector's input (`envelope` is always `null`: ranges only set `inRange`, which the diff does
  not read), plus `reply`, the model's raw reply, which the suite sends through `PatchRewriteService` with a canned
  connector, or `proposal`, edits `{line, text, reason, checkThis}` taken as they are for the two refusals. Optional
  `segments` are the replacements already accepted, as in the plan vectors; the generator places each one, and each
  voice hunk beside them, with the window reference. `expected` is `{edits, hunks, budget}`, where `edits` gives each
  validated edit's `line`, `inRange`, `checkThis` and `isDeletion`, or `{error: "invalidInput"}`.
- Each hunk: `kind`, `sourceWordIds`, `newTokens`, `correctedTexts`, `absorbedItemIds`, `bridgeWordIds`,
  `sourceStartIndex`, `sourceEndIndex`, `anchorSeconds` (`null` unless the hunk has no source word),
  `insertionAfterItemId`, `lines`, `reasons` and `checkThis`.
- `budget`: `voiceTokenCount`, `wordItems` and `flag`, as `VoiceLabPatchBudget.evaluate(hunks:transcript:)` returns them
  for the case's hunks and the whole transcript.
- `patchRewriteCases`: one result per `patch-rewrite-cases.json` case, in its order. The plan's lines are the
  `formatTranscript` lines of the case's entries, each entry a word item with ID `i` + index and no re-voiced run. A
  reply that validates maps to `{hunks, budget}`, the transcript being the entries; one that fails keeps its `{error}`.
- `merge` holds the step 6 limits.

### Coverage

Merges across a line boundary with no word, one bridge or three bridges at exactly 0.35 s, and none over three words and
1 s; a text-only fix absorbed by a merge across lines; a cut hunk and an event as barriers across lines; an insertion at
a line's end merging with the next line's first change, one at a line's start merging back, two insertions merging into
one, and an event between an insertion and a change at the start and at the end of a line; an echoed label
splitting a line, a dropped label absorbed, a dropped label changing nothing, an echoed `…`, a changed label spoken as
words, and a capitalised echo that flags the edit but no hunk; insertions after, before and instead of an event-only
line's label; whole-line deletions with and without an event, and a text of only the label; surface-only fixes on a
two-word correction, a partial change to it and an unchanged echo; `checkThis` on the voice hunk that adds the digit run,
on a text-only capital, and not for a year from the instruction; a cut item between merged lines, a clip scope with a cut
repeat, echoed labels and a new capital, and Full take's event-only line; a re-voiced run between two lines and inside a
line, each stopping a merge whose window the replacement would refuse, a change across a re-voiced run and a word added
where one lies; the two refusals; and every Fix with AI reply.
