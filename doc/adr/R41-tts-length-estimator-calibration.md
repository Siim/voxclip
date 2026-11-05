# ADR-R41: the text-to-voice length estimator is calibrated on real takes and learns per voice

Date: 2026-11-05. Status: accepted lead decision (package v2-tts-estimator).

## Context

A Rewrite plans each changed phrase against its slot in the real video before anything is paid for. The plan's length comes from `VoiceLabPhraseTiming.estimate`: letters ÷ (the speaker's letters per voiced second × a provider multiplier of 1.8), plus the trim lead and tail, plus 0.22 s per sentence mark and 0.12 s per clause mark. The 1.8 came from three takes of one casual clip (voice-lab §8.2.2, `phrase-timing-cases.json`).

The user's projects showed that it fails. The DJI project's Eleven v4 takes measured 2.59, 1.75, 2.17, 2.38 and 1.69 times their estimate (median 2.17). Each new project therefore planned its first round at about half the real length. That brought overlong takes, `segment_end_beyond_duration` in the log, wording-fit rounds and money spent, and the rewrite and fit aimed at word budgets that were too large.

## Measurement

`tools/voice-lab/measure_tts_takes.py` measured the user's paid takes locally and read only, on 5 November 2026:
- **Text:** each take's words came from on-device whisper (large-v3-turbo q5_0).
- **Length:** the voiced span, from the first to the last voiced 10 ms frame, widened by the trim lead and tail, as a Rewrite measures a take without alignment.
- **Speaker rate:** letters per voiced second of the project transcript (11.38 and 11.69 for the two projects).
- **Model:** takes are labelled Eleven v4 from 2026-11-03 11:00, when the app moved Rewrite takes to v4, and "pre-v4" before.

No audio, text or per-take figure was kept or committed.

There were 152 takes. 144 were kept: 78 Eleven v4 and 66 pre-v4. 8 were dropped as whisper misses, cut-off takes or impossible rates.

| Eleven v4 takes (n = 78) | median | IQR |
|---|---|---|
| measured ÷ old estimate | 1.46 | 1.37–1.66 |
| measured ÷ old estimate, punctuation pauses left out | 1.78 | 1.63–2.15 |
| provider ÷ speaker letters/s, takes with no internal marks (n = 45) | 0.98 | 0.82–1.00 |
| measured ÷ new estimate | 0.96 | 0.90–1.07 (p80 ÷ p50 = 1.15) |

What the takes do:
- **Speaking rate.** A cloned take speaks at about the speaker's own letter rate, not 1.8 times it.
- **Onset.** Each take carries a fixed onset and decay of about 0.4 s beyond the trim allowance. A least-squares fit gives 0.42 s on v4 and 0.50 s on all takes.
- **Sentence pauses.** A sentence mark followed by more speech adds about 0.5 s (fit 0.50 s on v4). The pause after a sentence measured from word timings has a median of 0.37 s.
- **Commas.** A clause mark adds about 0.1 s (fit 0.03 s on v4, 0.10 s on all takes).
- **Final punctuation.** A final mark adds nothing: the trim cuts after the last word.
- **Syllables.** Counting syllables instead of letters did not help. With the same onset and pauses it scored MAE 0.43 s on v4, against 0.35 s for letters.

Scored on the same takes (leave-one-out fits agreed within 0.03 s MAE):

| | MAE | MAPE | within ±15% | median bias |
|---|---|---|---|---|
| v4, old prior (1.8, 0.22/0.12) | 0.89 s | 33% | 5% | −31% |
| v4, new prior | 0.35 s | 14% | 63% | +4% |
| pre-v4, old prior | 0.99 s | 36% | 11% | −37% |
| pre-v4, new prior | 0.46 s | 22% | 47% | −5% |
| all 144, old prior | 0.93 s | 35% | 8% | −33% |
| all 144, new prior | 0.40 s | 18% | 56% | +2% |

The DJI project's in-app ratios (median 2.17) were measured against the input text, whose punctuation added pauses whisper's text does not have. With punctuation left out of the old estimate, the harness gives a median of 1.78 on v4 takes. Both figures say the old prior is far too fast.

## Decision

1. **Prior.** `estimate = letters ÷ (speaker letters/s × 1.2) + TTS_TRIM_LEAD + TTS_TRIM_TAIL + 0.4 s + 0.5 s per internal sentence group + 0.1 s per internal clause group`.
   - A punctuation group counts only when more speech follows it.
   - A hyphen between two letters or digits ("A-10") is not a pause.
   - The constants are rounded. `VoiceLabPhraseTiming.priorVersion` is 2.
2. **Project samples keep their place, under a new key.** `voiceLab.speakingRateSamples["<model>@prior2"]` holds measured ÷ estimated ratios against this prior, at most ten per model.
   - Ratios under the bare model ID describe the 1.8 prior and are no longer read.
   - The project format and schema are unchanged. The Windows twin keeps reading and writing the bare key with its own 1.8 prior until it moves.
3. **Each voice learns across projects.** `VoiceLab/calibration/<recordId>.json` (`voxclip-voice-rate-calibration/1`) keeps, per model, the last 30 ratios within 0.25–4.
   - **Robust median.** The multiplier is the median after trimming ratios more than three scaled MADs from the median, once there are five or more.
   - **Updates.** Every take a Rewrite measures updates the project and the voice.
   - **New projects.** A new project's samples start with the voice's median, weighted as three samples, so a project's own takes outweigh the voice from its fourth take on.
4. **Seed once.** On the first launch of this build, outside harness sessions, a background task measures up to 30 of the newest takes on device, if exactly one active voice exists, and seeds that voice's calibration.
   - It reads only takes written after the voice was created, takes the words from the existing on-device word check, and takes the speaker rate from the voice's reference recording.
   - It writes counts to the log only, and records the result as seeded.
   - Takes carry no model ID, so the seed is filed under the Rewrite model, Eleven v4.
5. **Confidence.**
   - The calibration's spread is p80 ÷ p50 of its robust ratios, kept within 1.05–1.6, once there are five samples. Before that it is the prior's 1.15.
   - `VoiceLabWordingFit.wordTarget` aims the upper word bound at the p80 (the slot ÷ spread), so four takes in five fit the first time. It aims the lower bound at the median.
   - The displayed "≈ x s" stays the median.

## Consequences

- **First estimates.** A new project's first estimates are about 1.5 to 2 times the old ones. Phrases that used to look like they fit now ask for shorter wording before money is spent.
- **Other voices.** The prior is fitted on one speaker's voice. The three 3 November takes of another speaker and an older model (`phrase-timing-cases.json`) come out 18–62% under it. Two measured takes of that voice bring the third within 3%, which is why calibration is per voice.
- **One-word takes.** The 0.4 s onset makes them about 0.7–0.8 s. A one-word swap in a 0.4 s word with hard seams no longer reads as fitting, which matches what such takes do.
- **Vectors.**
  - `shared/fixtures/voice-lab/tts-estimator-cases.json` (new schema `voxclip-tts-estimator/1`) carries synthetic texts. Its "observed" lengths are bin medians of the measured v4 takes, never a single take.
  - `phrase-timing-cases.json` stays the 1.8 prior's vectors for the Windows twin until it moves. The Mac replays only its recorded measurements.
- **Windows owes:**
  - the prior and the pause rule;
  - the `@prior2` project key;
  - the calibration store, its seed and the p80 budget, replaying `tts-estimator-cases.json`.
