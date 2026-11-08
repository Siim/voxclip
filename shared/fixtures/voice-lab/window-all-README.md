# Voice Lab several-window vectors

`window-all-cases.json` uses schema `voxclip-voice-lab-window-all-cases/1`, with exactly
`schema`, `caseCount` and `cases` at the root. It contains 32 synthetic review cases.
Regenerate with `python3 -I tools/fixtures/voice-lab/generate_window_all.py`. The standalone
standard-library generator loads only definitions from `generate_window.py`, never its
case generation or output. Both files regenerate byte for byte; neither allows float tolerance.
The legacy `window-cases.json` keeps the pre-C3 606-case shape. The clip-edge rule (voice-lab §8.4 step 1, 2026-11-08) changed
42 of its expectations (40 refusals at a clip's own edge now place, 2 refusals report a later rule) and one multi-segment
take, whose earlier replacement now places; its own vectors are in
[window-clip-edge-README.md](window-clip-edge-README.md). This file did not change.

Inputs use the legacy literal take/envelope format plus `hunks`. Results contain `status`,
original-input `indices`, the resulting `hunk`, and either the complete `window` or a typed
`reason`. Cases pin source ordering, transitive touches, seam-widening overlaps, fade-only
collisions, corrected bridges, whole-review budgets (including exactly 15% and 60 tokens),
clip scopes and existing segments. Cut hunks temporarily join project cut IDs for both
single-window placement and placement beside earlier reservations; the caller's project is unchanged.
The two `all-review-cut-*` cases put a deletion inside the seam-search range, with and
without a later voice hunk, so the deleted word never becomes a re-voiced bridge.

`all-event-prevents-merge` and `all-unlabeled-prevents-merge` place two individually valid
windows across a 1 ms intervening item. Their windows do not touch, but their outer fade
halves cannot share that source run: reservation placement triggers a merge, which the
non-word barrier refuses. Allowing that kind through the merge guard changes both the
Python and Swift result. The `all-cut-word-refuses-seam-before-merge` and
`all-cut-hunk-refuses-seam-before-merge` cases instead pin the earlier `seamFadeCrossesCut`
refusal; they do not claim to test the merge guard. `all-real-review-like-id-overlap` pins
an existing segment's original ID in the geometry error, not the reservation alias guard.

This file is replayed by both Cores: Swift `VoiceLabWindowTests.placeAllVectors` and C#
`VoiceLabWindowAllTests.SharedPlaceAllVector`. Both validate/prepare accepted unions against
the temporary review cuts. The separate C# class pins this file's exact keys, schema and
32-case count without changing the legacy replay. Outcomes, group/index identity, bridge
token surfaces, seconds, samples, seam kinds and odd fade halves compare exactly; C# checks
double bits, not a tolerance. Use binary64 operations, inclusive comparisons and jsRound;
no epsilon or take-edge seconds reconstructed from samples. No provider assets or live calls.
