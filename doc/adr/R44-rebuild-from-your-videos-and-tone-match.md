# ADR-R44: rebuild your voice from your videos, and match the take's tone at render

Date: 2026-11-06. Status: accepted (package v2-voice-rebuild; the design owed by ADR-R41 "Consequences").

## Context

ADR-R41 measured that the clone's takes on the user's recovered project score 0.47–0.54 against the creator's speech beside them, while that speech scores 0.81–0.90 against `reference.wav`. They also sound darker: pooled slope −9.4 against −7.9 dB/octave, with 2–6 kHz 4.5 dB lower relative to 0.1–1 kHz. Loudness was already within 2 dB. Two remedies were owed: rebuild the voice from verified speech across videos, and a gentle tilt match at render.

A read-only measurement on the user's files (`VoiceRebuildMeasureTests`, local only, 2026-11-06) found:

- The voice "siim (VoxClip)" has 8 training samples, 118.57 s in all. Its `reference.wav` is 27.72 s and scores 1.000 against the record.
- The one readable project with media, DJI_20261014184458_0030_D_1080p (348 s, 48 kHz), has **no** span at `TRAIN_MIN_SNR`. All 16 of its transcribed stretches are below the floor (4.5–15.4 dB, median 7.44), and 2 more are too short. Their lowest-part scores against the record are 0.330–0.491, and only five reach τ.
- The recovered DJI_0075 project's media is no longer on the Desktop.

So today's rebuild on this Mac would show the "too little" line. It needs cleaner videos, which is the design's intent: never train a clone on noise.

## Decision

1. **Rebuild from my videos** (voice-lab §6.12), in Settings › Voices on an attested voice. It finds the owner's clearest speech in their projects for free, on this Mac. Each span must pass **one hop** against the record's own embedding, by its lowest part score, never through a learned reference. It must also meet the §6.5.1 SNR floor and be 5–30 s long.
2. **Pick for coverage.** The cleanest span of each video comes first, then the most dissimilar remaining span, up to 24 files and 120 s (ElevenLabs recommends 1–2 minutes).
3. **The statement stays the same.** The voice's own `reference.wav` is sent first, so the new record's embedding is the old one, and ADR-R41's one-hop bound is unchanged. Learned references are carried over, each re-checked one hop against the new record.
4. **The existing attested creation**, with its three checkbox attestations inline, the free plan check, one priced click (**Rebuild · {price}**) and the journal. There is no new consent route or provider call.
5. **Switch and remove are separate, explicit steps.** **Use the new voice for Rewrite** writes `voiceLab.rewriteVoice`, which Rewrite's voice choice starts with. **Remove the old voice** confirms inline and then runs the existing deletion. Nothing is removed automatically.
6. **Tone match** (§8.7 item 2b). A generated take gets a static spectral tilt towards the original speech beside it. It is measured with one-third-octave bands over the same neighbourhood as the level, clamped to ±2 dB/octave, stepped by 0.1 and pivoted at 1 kHz. The filter is three first-order shelves run from the asset's first frame, and the tilt is applied before the gain is measured. It is stored as optional `audio.tiltDbPerOctave`. The user's own recorded take is never tilted. Shared vectors (`tilt-cases.json`) pin the arithmetic.

## Why these limits

- **One hop and the SNR floor.** A rebuilt clone is trained on what passes. Training on a guest's or a noisy stretch would make the voice worse and could move it away from the owner. The floor is §6.5.1's own (20 dB), not a new one. The measurement shows it is strict for car vlogs, and a relaxed floor with ElevenLabs' `remove_background_noise` was considered but not adopted. Training on noise is what produced the dark, low-scoring clone.
- **±2 dB/octave.** The measured difference was 1.5 dB/octave. A gentle, static first-order tilt corrects the tone without the artefacts of an equaliser that follows the signal, and it can't change the words or the voice's identity. A take already like its neighbours gets no tilt.

## Consequences

- An older project renders unchanged (no `tiltDbPerOctave`). The export fingerprint covers the field, so a changed tilt invalidates an export as any audio change does.
- Windows reads, validates and saves the tilt but renders without it, and has no rebuild row. It owes the renderer twin (and a replay of `tilt-cases.json`), take processing's measurement and the Settings rows (apps/macos/CONTRACTS.md).
- The real before/after comparison needs a rebuild on the user's account, which only the user can start.
