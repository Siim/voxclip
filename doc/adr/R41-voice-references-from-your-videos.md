# ADR-R41: let a video teach your voice — owner-verified references, one hop from the consent statement

Date: 2026-11-05. Status: accepted user decision (package v2-voice-references).

## Context

ADR-R40 made the use-time guard (voice-lab §6.9) hear only the words near each patch. On the creator's own car video (Clip 4, wespeaker-resnet34, τ = 0.45) two phrases still fell below τ against the consent record's embedding: 0.412 and 0.437, while the other two passed at 0.457 and 0.451. The statement was recorded on another microphone. The guard had a single example of the owner.

A local measurement on the user's files (read only, `VoiceGuardSpeechMeasureTests`) took the guard speech of passing phrases of the same video as references. Phrase 1 (w450–w451) scores 0.800, 0.803 and 0.831, and phrase 2 (w453–w454) 0.834, 0.835 and 0.866, against references from three passing stretches (w475–w477 at 0.456, w478 at 0.452, w493 at 0.457 against the statement). The Rewrite's phrase windows are not stored; phrases 1 and 2 reproduce the reported cosines exactly, and 3 and 4 are the nearest windows (within 0.001).

The user approved the design on 2026-11-05: "let a video teach your voice".

## Decision

1. **References.** The consent record gains additive `speaker.references`: the guard embedding of the owner's speech from a project, its `contentKey`, `addedAt`, its cosine against the record's own embedding and the model id.
2. **One hop.** A reference is learned only from speech that passes against the record's own embedding at τ. It is never checked against, or learned through, another reference. At use, each reference's cosine against the record's embedding is recomputed from the stored vectors and must still be ≥ τ, and its model must be the record's.
3. **The rule.** A phrase passes when cos(statement, x) ≥ τ, or cos(reference, x) ≥ τ for a usable reference. τ never changes; there is no override.
4. **Bound.** One per project (the best-scoring kept), at most 16 per voice. Over the bound, the reference most similar to another goes first, so the set covers different rooms and microphones. Another speaker model drops them all.
5. **Learning without clicks.** Get Price runs the guard first, free and local, for every phrase. Passing phrases teach this project's reference, the rest are checked against the references, and what still fails is settled as blocked before any quote. Get Price never prices, and never asks approval for, a phrase that will be blocked. ✦ Make it postable and ✦ Claude does it all use the same step.
6. **Learn from my videos.** Settings › Voices, and automatically after a project is transcribed, reads the user's projects on this Mac (recent projects and the export folder; not Desktop or Documents, which would raise macOS privacy prompts), picks up to six 6–10 s stretches of each one's transcribed speech, verifies them one hop, and stores the best per project. Media labelled AI modified never teaches.
7. **Visible and reversible.** Settings › Voices says "Learned from n of your videos" and offers Forget learned references inline. Deleting or withdrawing the voice removes the references with the record; the tombstone keeps its hashes as before (§6.10).

## Why one hop

A chain (statement → reference A → reference B → …) would let the accepted voice drift one τ-step at a time, until it reached someone else. With one hop every accepted phrase is within τ of a stored embedding that is itself within τ of the consent recording. The widest accepted angle is bounded by two τ-steps of the calibrated model, never more.

## How a guest stays blocked

- ADR-R40's speaker-turn rules still apply: each phrase is judged on its own speaker's words, and a labelled guest's phrase reads only the guest.
- A reference is the owner's speech. A guest's phrase must itself be within τ of the statement or of one of those owner references. Calibration puts 99.9% of impostor pairs below τ, so references widen the owner's accepted channels, not the set of speakers.
- References from the same room raise impostor scores slightly (shared channel). The S6 corpus pairs were mostly within one recording condition per speaker, so τ already reflects same-channel impostors. The field own-voice check owed before release (§6.6) should also report guest-versus-reference scores.
- Smoke S-guard-guest: in a video that teaches a reference, a guest's phrase stays blocked before any price.

## Consequences

- `VoiceConsentStore.validateUse` compares records without their references, so learning in one project never invalidates a run approved in another; the guard reads the references when it judges a phrase, and its caches key on them.
- Windows owes the twin: the record field and its validation, the rule, the pre-price screen, the learner and Settings rows (see apps/macos/CONTRACTS.md).
- Clone quality is a separate problem (part b of the user's follow-up). On the user's recovered project, the clone's takes score 0.47–0.54 against the creator's speech right beside them (0.54 pooled), while that original speech scores 0.81–0.90 against `reference.wav`. The takes are within 2 dB of the original's loudness but darker (pooled slope −9.4 vs −7.9 dB/octave; 2–6 kHz 4.5 dB lower relative to 0.1–1 kHz). Rebuilding the voice from verified speech across videos and a gentle tilt match at render are owed (CONTRACTS, "Owed").
