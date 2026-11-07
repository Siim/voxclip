# ADR-R46: revoice the whole clip in one voice, fitted and lip synced, when patching would sound stitched

Date: 2026-11-07. Status: accepted (package v2-revoice-whole; the user's request and decisions below, approved mockup "revoice whole clip").

## Context

The user rewrites clips in their cloned voice. When many phrases change, patching each changed phrase into the real recording sounds stitched: each take differs from the real voice and from the other takes at every join. ADR-R45's per-video voice narrows the gap but can't close it at the joins. The user asked for an option that generates the whole clip's voice with AI and lip-syncs the video, so there are no seams.

The user decided (2026-11-07):

1. **Lip-sync model: both, Claude picks.** The default is `fal-ai/sync-lipsync/v2:lipsync-2` (about $3 a minute). Review offers sync-3 (`fal-ai/sync-lipsync/v3`, about $8 a minute) as a priced upgrade that re-runs only the lip sync over the paid voice. The Choose card prices the default.
2. **Claude mode switches automatically within the spend cap.** In ✦ Claude does it all, VoxClip revoices the whole clip instead of patching when the rule below says the patch would sound stitched and the whole clip's price fits what is left of the run's cap. Over the cap Claude patches as before and offers "Revoice the Whole Clip · ≈ $X" inline; nothing is spent until it is clicked. Outside Claude mode the Rewrite panel asks once per clip, at the price step, and keeps the pick per clip.

## Decision

1. **The switch rule** (`WholeClipRevoice.reason`, shared constants, integer arithmetic so each edge is exact). Revoice the whole clip when either:
   - (a) the included voice changes re-voice at least **40%** of the clip's spoken words (`wordSharePercent`). The re-voiced count is the voice budget's: every new word of the included voice changes (`VoiceLabPatchBudget`). The spoken words are the clip's `word` items after its cuts. `revoiced × 100 ≥ spoken × 40`.
   - (b) at least **2** phrases can't fit their slot (`noFitPhrases`): after takes, the phrases `ClipTakePlan.fitsNoDuration` would keep as recorded; before takes, the phrases the free wording fit kept as recorded because their wording is too long for the video (ADR-R42).
   A whole clip escapes the slot limit because the picture is fitted to the voice.
2. **Claude mode's choice** (`WholeClipRevoice.autoChoice`): no reason → patch; no price in the tables → patch, never offered; price within the run's remaining cap → revoice; otherwise patch and offer. The over-cap offer's click approves exactly the offered price.
3. **The pipeline reuses Rewrite's own paths.**
   - **Script** (free): the clip's words in transcript order with every cut, correction and included rewrite applied (`WholeClipScript.assemble`).
   - **Voice:** the script split at sentence boundaries into parts of at most 12 s of source and 1,000 characters (`WholeClipScript.parts`), handed to a `ClipTakePlan` as voice changes (`WholeClipScript.hunks`). Each part goes through window placement, the R40 guard (before any price), R43 calibration, the R45 per-video voice with the anchor fallback, the take checks and the take journals. Placement joins touching windows, so a clip's parts are voiced as one window: one take per contiguous stretch.
   - **Fit** (free): the voice's length against the windows' source length. Clip speed scales voice and picture alike, so the ratio is the rendered one. Within **±8%** (`fitTolerance`) the picture is matched through Rewrite's Match video (`retimed`). Outside it, Rewrite's measured-wording round (`voice-rewrite-shorter-measured.json`, the whole clip as one line with its measured and video seconds) asks for about `words ÷ factor` words, at most **2** rounds (`maximumRewordRounds`), each voiced again. After that the panel says so inline and offers Try Again and Voice Only the Changed Phrases.
   - **Lip sync:** one job over the merged window through `RewriteLipsyncSession`, `LipsyncRun`, the import, validation, conform, receipts and journals, with the chosen model (`LipsyncRun.execute(model:)`, `FalLipsyncProvider.prepareApprovedUpload(model:)`). The recipe records the model the job ran (`addingLipsync(model:)`).
4. **Never paid twice** (`WholeClipRevoiceLedger`). A voice is keyed by its script, voice record and model, and a lip sync by its voice, retime and model. Try Again after a cancelled or failed lip sync pays only the lip sync. The sync-3 upgrade pays only sync-3. A new wording is a new voice.
5. **Cancel and failure keep the clip.** Nothing enters the project before Use Whole Clip. Use is one undo step: Rewrite's own commit of the parts' segments, with their matched and lip-synced recipes, plus the project's record.
6. **The project's record** (`voiceLab.wholeClipRevoices`, schema v3 and v4, omitted when empty): `id`, `clipId`, `segmentIds`, `script`, `consentRecordId`, `videoRetime` (within ±8%), `lipsyncModel` (one of the two), `usd`, `match` (`take`, `anchorBaseline`, `realSpeech`) and `createdAt`. Every key is written; `usd` and `match` may be null. Validation requires the clip and every segment (each a text-to-speech segment in at most one record). An edit that removes the clip or one of its segments, or replaces the transcript, drops the record in the same step (`WholeClipRevoice.pruneDangling`, C# `PruneDangling`: removing a clip, the reference clean on save and Windows load, deleting a segment); the segments stay as voiced patches. A file that arrives with a dangling record is still refused.
7. **Disclosure.** A segment named by a record adds the disclosure kind `revoice`. The burned-in chip reads "Voice and lip movement generated with AI" and the post text "Voice and lip movement generated with AI." The rest of the label plan is unchanged, so a revoiced clip, being over 30% AI, is labelled throughout. Consent is the existing voice consent, plus the lip-sync approval.
8. **The stage** shows its AI voice tag over the whole revoiced clip, the pauses between parts included (`WholeClipRevoice.isRevoiced`).

## Consequences

- A heavily rewritten clip can sound like one take, at a lip-sync price: about $1.55 for 31 s with lipsync-2, about $4.13 with sync-3.
- **The whole clip's lip-sync seconds are quoted** from the script's span plus Rewrite's one-second handles. The job is priced again from its real window, which can differ by the seam widening.
- **Parts as written.** A clip whose script is one stretch of speech is voiced as one take: placement joins the parts. The mockup's "3 parts, one take" applies only when parts stay apart. The step reads "one take" otherwise.
- **A whole-recording clip** has no speech beside it to level the voice against (voice-lab §8.7 item 2), and the Voice step stops with that reason. The same holds for any patch over a whole recording.
- **Windows owes** the twin: the record's wire, validation and schema replay, the `revoice` disclosure kind, the rule and autoChoice, the card and run, and Claude mode's switch. Until then Windows refuses to open a project holding a record, as it refuses any `voiceLab` key it doesn't know (`ProjectValidation`, apps/windows). A project with no whole-clip revoice is unchanged on disk, since the key is omitted.
