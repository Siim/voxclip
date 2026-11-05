# ADR-R40: the use-time guard hears each patch's own speech, judged per phrase

Date: 2026-11-05. Status: accepted lead decision (package v2-rewrite-unstick).

## Context

The user's own car video (road noise, long pauses) failed the use-time guard (voice-lab §6.9) on every phrase of a Rewrite, and the footer then offered Get Price and Make Takes again, which failed the same way. The guard embedded 10 s of raw source centred on the phrase: silence and road noise as well as speech. §6.9 asked for "the project's speech nearest the patch" and a cache "per (project `contentKey`, `recordId`)". The code cached on the audio as well, so each phrase was judged on its own window.

A local measurement on the user's project (wespeaker-resnet34, τ = 0.45, four phrases of Clip 4, read only) gave raw-window cosines of 0.364, 0.351, 0.426 and 0.421, and speech-only cosines of 0.412, 0.437, 0.457 and 0.451. Hearing only the words lifts every phrase by 0.03 to 0.09. Two of the four still fall below τ.

## Decision

1. **What is embedded.** The guard's input is the transcript words' own audio nearest the patch, from the original source: word spans only (`kind == word`), each at most its 2 s nearest the patch, joined in source order, up to 10 s. Selection widens outward word by word from the patch. Where the transcript labels speakers, only the patch speaker's words count: first that speaker's turn around the patch, then the same speaker's other turns by distance. Another speaker's words are never taken. A transcript with no timed words falls back to the patch's own 10 s of source. The embedding then runs the same VAD, features and window/hop as the enrollment statement's embedding, so the two are comparable. τ is unchanged and there is no override.
2. **The cache stays per phrase.** A guard result is cached per (`contentKey`, the guard's speech, `recordId`, the record's embedding and model, τ). The same phrase is not embedded twice, for Try another or a later part of a run, but a pass on one phrase does not cover another.
3. **A refusal settles the phrase for the Rewrite.** "Not the voice owner", or too little of the patch speaker's speech to check, ends that window as `blocked` before anything is sent. The run's other windows go on, and no plan of the same Rewrite prices that phrase again (design.md R2 "Not your voice here").

## Why per phrase rather than per project

A per-project cache, as §6.9 first said, would let one passing phrase authorize every phrase of the video. Scribe labels speakers only when diarization runs; the user's project has no labels. In an unlabelled interview, one pass on the creator's own sentence would then let the creator's clone voice a guest's words. Per-phrase judgement on the patch speaker's own speech keeps that phrase blocked, which is the guard's purpose: Voice Lab is only for your own videos and your own words. The cost is that a quiet phrase in a noisy recording can be blocked while its neighbours pass. Step 3 makes that a settled, one-time stop with Say it myself and Keep as recorded, not a loop.

## How a multi-speaker video stays protected

- **Labelled transcript.** A guest's phrase reads only the guest's words, so it is judged on the guest's voice and blocked.
- **Unlabelled transcript.** Each phrase is judged on the words nearest it. A guest's phrase is mostly the guest's speech and is blocked. Mixed turns can still dilute the result, as the raw window did before.
- **Never a pass for someone else.** No pass on one phrase is reused for another, and τ is never lowered.

## Consequences

- Rewrite source decoding also holds the guard's word spans, a few spans per phrase.
- The Windows twin still reads the raw 10 s span, which the shared region vectors pin (`rewrite-source-regions.json`). It owes the same selection, the `blocked` run end and the settled footer.
- What still blocks the creator's own speech here is the channel difference between the statement's microphone and the car recording. Fixing that belongs to calibration (a field own-voice check is already owed before release, voice-lab §6.6), not to the guard.
