# ADR-R47: exports land at social loudness

Date: 2026-11-07. Status: accepted (package v2-loudness, from the agent clipping benchmark).

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
