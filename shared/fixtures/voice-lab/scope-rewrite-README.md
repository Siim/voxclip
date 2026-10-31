# Scope rewrite plan vectors

`scope-rewrite-plan-cases.json` pins `ScopeRewritePlan.make`: the Fix with AI request for a clip or Full take
(voice-lab.md §8.1 item 1), before any quote. `tools/fixtures/voice-lab/generate_scope_rewrite.py` writes it (Python 3,
standard library only, byte-identical on every run); change the generator, never the JSON. All inputs are synthetic and
offline. The Swift suite `ScopeRewritePlanTests` replays every case. The C# suite does not yet; the C# twin (plan W1)
replays the same file.

## Rules the generator encodes

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
  stop ends a line. `itemIds` lists the line's entries; cut items between them are not listed.
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

## Case shape

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
  - `{entries, utf8Bytes, lines}`: every entry and every line with `line`, `itemIds`, `minChars`, `maxChars` and
    `rangeSource`. A line's `note` (the seams, target and bridge length, or the refusal) is informative; the suites do
    not read it.
  - `{summary}` for the three large passing cases: the entry count, the byte count, the first and last entry, and each
    line's label, item count, first and last item ID, range and source.
  - `{error}`: `tooManyEntries` (with `count`), `tooMuchText` (with `bytes`), `empty` or `invalidInput`.

## Coverage

A kept clip with a cut repeat inside a line and corrections; Full take with an event-only line and a line refused
because a cut filler touches it; a clip at the take start (`none` incoming seam, so the edge pad shortens the target)
and at the take end (`none` outgoing seam); a suggested clip whose head cuts the event before it; no envelope; an
all-cut clip, an unknown clip, a selection and an envelope on the wrong rate; event labels at the start and the end of a
line; an enabled replacement inside a clip line, the same one disabled, one beside other lines, a clip boundary crossing
one (with and without an envelope), a cut after acceptance that leaves the scope unrenderable, and a scope that is all
re-voiced; a stored-candidate rate and a malformed candidate; 100-unit text cuts with a surrogate pair at the boundary;
the 5,000 cap; and the entry and byte limits on both sides, with both over at once.
