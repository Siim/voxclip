# ADR-R42: a rewrite writes within each slot; what can't fit keeps the speaker's words

Date: 2026-11-05. Status: accepted lead decision (package v2-rewrite-fit).

## Context

MVP32, Suggested clip 7, tone ✦ Viral YouTuber (the user: "still stuck??"). The rewrite padded five of six lines with connectors ("or, put differently", "then again, on the other hand", "and then, in addition to that") to about twice their slots. The fit rounds did not get them under. A take's render recipe was refused at Use, so a Review card offered only Use 1 Take, which repeated the failure. The footer then read "Changes 3, 5 and 6 need a shorter wording before takes. Fix the problem above to go on." beside Keep All alone.

Causes, from the prompts and code at cecb343f:
- `voice-rewrite.json` v3 asked for "{minChars} to {maxChars}" letters and "Keep each change about as long, when spoken, as the words it replaces; prefer the same number of syllables". The tones said "close to the length of the words it replaces". Nothing said why the length is fixed, nor that shorter is fine, so a tone that cuts words was pushed back up to the minimum.
- `voice-rewrite-fit.json` v1 allowed "longer or shorter wording as requested" with a word target that had a minimum, and the estimator (`providerSpeechRateMultiplier` 1.8) under-predicts Eleven v4 takes about 2.2× on this project. Lines the fit judged to fit ran long as takes.
- The automatic fit does not run once takes are paid (`beginAutomaticWordingFit` guards `!hasPaidTakes`). The recalibrated estimate (`speakingRateSamples`) then held back changes 3, 5 and 6, and no control resolved them.
- `acceptTakes` set `takePlanFailure` and logged nothing. `takePlanBlocker` returned "Fix the problem above to go on." with no primary.

## Decision

1. **Say why, and give a budget.** The rewrite, fit and Fix with AI prompts, and every tone, say that the words replace speech in a running video, so a change never takes longer than what it replaces, shorter is fine, and nothing pads. A selection's request lists each span's seconds and word budget. The budget comes from `VoiceLabWordingFit.wordTarget` at the project's measured `multiplier`, never above the span's own words (ai.md §12.9).
2. **Repair once, then keep the speaker's words.** An over-budget line gets one free fit round. If it is still long, it is kept as recorded, never priced as written: no take of it could fit without retiming the video. After paid takes the estimate holds nothing back.
3. **No dead end.** Every footer that waits on nothing has a primary that moves forward, or Done. A take that can't go into the video keeps its phrase as recorded with one line of why, and Use goes on with the rest. Make it postable and ✦ Claude does it all reach a finished state the same way with no click.
4. **Insertions are not proposed.** A change that only adds words where the speaker said nothing can't be placed in the recording, and the video has no time for it. The prompts forbid it, rather than the app adding placement for it. A reply that still has one leaves it out and says why.

## Consequences

- `pricedAnyway` is now reached only by the row's Price it anyway and the refused-context route, no longer by the end of the fit.
- Windows renders the new prompt text through its unchanged templates but owes the slots, the one-round fit with keep-as-recorded, the no-hold-back after paid takes, the Use settle and the footer forwards.
- The estimator's 2.2× error is recalibrated by track/v2-tts-estimator; the budgets follow it through the same functions.
