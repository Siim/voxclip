# ADR-R47: exports land at social loudness

Date: 2026-11-07. Status: accepted (package v2-loudness, from the agent clipping benchmark); amended 2026-11-08 (package v2-loudness-limiter): the static gain gains a true-peak limiter. The Amended section below supersedes Decision 1's "static gain only" and the true-peak cap.

## Context

doc/agent-clipping-benchmark.md measured a VoxClip export of a talking-head clip at **−20.7 LUFS** integrated. The clips the agents made for the user, which the user posted, were about −16 LUFS, and feeds normalise near −14. A quiet export sounds weak beside the posts around it, and a feed that only turns loud clips down never brings it up.

## Decision

1. **The rule** (`SocialLoudness`, Mac and Windows Core, shared vectors `shared/fixtures/loudness/social-loudness-cases.json` from `tools/fixtures/loudness/generate_social_loudness.py`):
   - Target **−14 LUFS** integrated: ITU-R BS.1770-4 K-weighting, 400 ms blocks every 100 ms, the −70 LUFS absolute gate and the gate 10 LU below it (EBU R128). Channel weights are 1.
   - **True peak at or below −1.0 dBTP**, measured as BS.1770-4 Annex 2 (the 48-tap 4× filter, never below the sample peak), the measurement Voice Lab already uses for its −1 dBTP limit.
   - **Static gain only.** The gain is target minus measured, kept within **−20…+12 dB**, then lowered until the true peak sits at −1 dBTP. There is no compressor or limiter, so the voice never pumps.
   - A mix whose gated loudness is undefined (digital silence, everything below −70 LUFS, or shorter than one 400 ms block) gets **0 dB**.
   - When the true-peak ceiling stops the gain short, the clip lands quieter than −14 and the report says `capped: true`. When the ±limit stops it, `gainDb` is +12 or −20 and `outputLufs` shows where it landed.
2. **Measure the mix that is exported, apply the gain to the exported audio only.** The measurement is taken after Voice Lab, clip controls (speed, gain, fades, mute), the music bed, effects and bleeps: exactly the PCM the AAC encoder receives, cut to the export's sample count and padded with silence to it.
   - **Mac** (`AVExporter`, `ExportLoudnessPass`): a measuring pre-pass reads the export's own composition, mixed tracks, audio mix and time range through a second `AVAssetReaderAudioMixOutput` at 48 kHz Float32 stereo, then the audio pump multiplies every buffer by the gain before the AAC writer. The alternative, measuring the written MP4 and rewriting its audio track, would decode AAC, encode the audio a second time (one more lossy generation) and remux the whole file, and it cannot be faster: the pre-pass is an audio-only decode, offline and far faster than real time, with no second encode.
   - **Windows** (`Exporter.MeasureLoudness`): the existing native path, not FFmpeg filters. A second `RenderedAudioReader` over the same snapshot, Voice Lab session and staged music bed is read in the encoder's frame size, and `EncodeAudio` multiplies each frame by the gain. Both platforms run the same meter, so they land on the same gain: the shared vectors agree within 1e-6 dB (the bound is 0.2 dB).
3. **On by default for every export.** `ExportJob.loudness` defaults to `social`; the CLI takes `--loudness social|off` (default `social`) on both platforms.
   - The export JSON reports `loudness: { measuredLufs, gainDb, outputLufs, truePeakDbtp, capped }`. `measuredLufs` is before the gain; `outputLufs` and `truePeakDbtp` are the exported PCM's, after it. A silent mix reports `measuredLufs` and `outputLufs` as null and `gainDb` 0. `loudness` is null with `--loudness off` or a video with no audio track.
   - The app logs the same numbers per export (`export: loudness measured=… gain=… output=… truePeak=… capped=…`), numbers only.
   - No new app UI in this package, and preview plays the mix as composed: the export is louder than the preview by `gainDb`.
4. **Sidecars.** The SRT is unchanged. The CLI's `--audio-out` WAV (the edited voice at 1× without music, a test hook) is staged first and multiplied by the export's gain in place before anything is published, so it carries the same gain. `writeEditedAudio` on its own stays at the recorded level.

## Verification

- The vectors: a 1 kHz sine at −23 dBFS in both channels reads −22.99 LUFS (EBU Tech 3341 case 1), and the same tone in one channel reads 3 LU lower. Speech-like bursts reach −14.00, quiet bursts stop at +12 dB, a click caps the gain at −1 dBTP, a +12 dBFS float mix stops at −20 dB, the relative gate leaves a quiet tail out, and silence, sub-gate noise and a 375 ms clip get 0 dB. FFmpeg's `ebur128` reads the same integrated loudness on every signal case to its 0.1 LU display, except the +12 LUFS mix, which is above the top of its histogram.
- Mac Media: a speech-like source at −23.9 LUFS exports at **−14.00 LUFS** decoded from the AAC, true peak −2.6 dBTP. `off` leaves it within 0.01 LU of the source. A clip with a click is capped (`capped: true`) and decodes at −1.01 dBTP.

## Consequences

- Talking-head exports move from about −21 to −14 LUFS, at the cost of one audio-only decode per export (measured in doc/publishing.md §6).
- **Static gain cannot always reach −14.** A clip with a peak far above its loudness (a peak-to-loudness ratio over 13 dB, typical of clean speech with plosives or a clap) is capped and lands quieter. That is the price of never limiting. A limiter would need its own ADR.
- **The ceiling is the PCM's.** AAC can ring a little past it on a click (about 0.2 dB in the tests), and FFmpeg's 192 kHz true peak can read up to about 0.6 dB above the Annex 2 filter on full-band noise. Speech and music sit well below either margin in practice.
- **Preview is not normalised**, so A/B between preview and export differs by the gain. A later package may apply the same gain to preview.
- Tests that compare exported sample values with the edited WAV pin `loudness: .off` (Mac `VoiceLabCompositionTests`).

## Amended 2026-11-08: a true-peak limiter, the 9 dB reduction cap, landing on target

### Why static gain alone failed on real speech

The lead's live benchmark (2026-11-08, a 29-minute DJI talking-head recording, three Claude-mode clips) exported at −20.1, −19.8 and −20.0 LUFS, every one `capped: true`: measured −21.5, −20.2 and −20.9 LUFS, gains of only +1.6, +0.4 and +0.7 dB. Plosives and clicks sit 18–20 dB over the speech's loudness, so they reach −1 dBTP long before the speech reaches −14. Fewer than 1.5% of the frames are near the ceiling; the static rule let them set the level of the other 98.5%.

### Decision

Both platforms, one definition (`SocialLoudness`, `SocialLimiter` in Mac and Windows Core; vectors `shared/fixtures/loudness/social-loudness-cases.json` /2 and `social-limiter-cases.json` /1 from `tools/fixtures/loudness/generate_social_loudness.py`; the full specification is doc/publishing.md §6.1):

1. **Gain.** G = −14 − L for the exported mix's integrated loudness L, within −20…+12 dB. A silent mix (gated loudness undefined) gets 0 dB and no limiting.
2. **Limiter after the gain**, ceiling −1.0 dBTP: Annex 2 4× true-peak detection, each overshoot held over the 12 inputs its detection reads, a 5 ms raised-cosine lookahead attack, an 80 ms exponential release ending below 0.01 dB, one reduction for both channels. No makeup gain, no knee, nothing below the ceiling compressed: far from an overshoot every sample is exactly `Float(x × G)`. When the true peak after G is under the ceiling the limiter does not run at all.
3. **Reduction cap.** The limiter's largest reduction is exactly TP + G − (−1) (the envelope never exceeds the largest overshoot it detects), so no search is needed: G is lowered to −1 + 9 − TP when it would exceed it, and the report says `capped: true`. That is now the only reason for `capped`. The clip lands quieter rather than squashed.
4. **Landing on target.** Limiting removes energy, and the 80 ms release ducks the syllable after each plosive, so one offline pre-pass (gain and limiter simulated, no encode) measures the output and G is corrected once by −14 minus what it measured. When the limiter took more than 0.5 LU, the corrected gain is simulated too and a secant step through the two lands it: at most two simulations. Every corrected gain stays within +12 dB and the cap.
5. **Report.** `loudness: { measuredLufs, gainDb, outputLufs, truePeakDbtp, capped, limiterMaxReductionDb, limitedPercent }`; `outputLufs` and `truePeakDbtp` are metered on the PCM the encoder receives; `limitedPercent` is the share of frames under any reduction, release included. The app log line adds `maxReduction=` and `limited=`. `--loudness off` is unchanged; `--audio-out` runs the same gain and limiter over its own samples (without music, the export's PCM, sample for sample).
6. **Where.** Mac: `AVExporter.socialLoudness` reads the mix once to measure and once or twice more to simulate; the audio pump runs `ExportLoudnessStage` and flushes the limiter's 251-frame lookahead after the last frame. Windows: `Exporter.PlanLoudness` does the same through second `RenderedAudioReader`s; `ExportLoudnessStage` wraps the export's reader so `EncodeAudio` reads as many frames as before, in order, and never sees the latency.

### Verification (2026-11-08)

- Vectors: Mac and Windows replay both files within 1e-6 dB and output samples within 2e-6 (Windows Media's encoder-frame-size stage equals Core's output bit for bit). Each rule, removed alone, turns at least one replay red.
- Mac Media: speech bursts with 150 Hz plosives at −4.4 dBFS (−23.1 LUFS, −5.7 dBTP) export at −14.00 LUFS, PCM −1.00 dBTP, 6.0 dB of reduction; decoded AAC −14.00 LUFS and −0.97 dBTP; FFmpeg `ebur128=peak=true` −14.0 LUFS, −1.0 dBFS. Clicks 26 dB over quiet speech stop at the cap (9.00 dB, −20.9 LUFS).
- The benchmark's three clips (release CLI, `--aspect 9:16 --style off`, FFmpeg `ebur128=peak=true`):

| Clip | Before | After: measured | gain | output (FFmpeg) | true peak PCM / FFmpeg | max reduction | limited (any / ≥ 1 dB / ≥ 3 dB / over the ceiling) |
|---|---|---|---|---|---|---|---|
| 1 (21.6 s) | −20.0 LUFS, capped | −21.54 | +8.54 dB | −14.04 (−14.1) | −1.00 / −0.9 | 6.94 dB | 45.7% / 10.8% / 1.1% / 0.7% |
| 2 (29.7 s) | −19.8 LUFS, capped | −20.16 | +8.70 dB | −14.06 (−14.1) | −1.00 / −0.9 | 8.35 dB | 65.3% / 22.4% / 7.7% / 1.5% |
| 3 (31.2 s) | −20.1 LUFS, capped | −20.89 | +8.96 dB | −14.05 (−14.1) | −1.00 / −0.9 | 8.23 dB | 62.6% / 19.9% / 5.7% / 1.3% |

### Consequences

- Talking-head exports reach −14 LUFS instead of about −20. The cost is the limiter's own work in the audio path and one or two more audio-only offline passes when it lands the gain: on the Mac +0.40 s on a 34 s range, +1.7 s on 3 minutes and +0.57 s on the 29.7 s benchmark clip, against +0.04 s, +0.53 s and +0.17 s for the static gain (doc/publishing.md §6.2).
- **`limitedPercent` reads high on speech.** With an 80 ms release, a 6 dB reduction takes about half a second to fall under 0.01 dB, so on the benchmark 46–65% of frames are under some reduction while only 0.7–1.5% are over the ceiling and 1–8% are reduced by 3 dB or more. A shorter release or a higher floor would lower the share at the cost of transparency; this amendment keeps the brief's 80 ms.
- **The ceiling is the PCM's.** AAC rings a few hundredths of a dB past it on a limited transient (−0.97 dBTP decoded in the test; FFmpeg's 4× reading −0.9 on the benchmark). The tests allow the decoded peak 0.1 dB over −1 dBTP. Holding the decoded file at −1.0 would need encoder headroom (a lower PCM ceiling), which this amendment does not take.
- Reductions of 7–8 dB on the benchmark's loudest plosives sit near the 9 dB cap; a listening pass on the posted clips is the check that they stay transparent.

