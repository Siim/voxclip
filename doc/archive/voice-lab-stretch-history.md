# Voice Lab time-stretch fit (history)

Status: historical. ADR-R30 superseded this design on 2026-10-26. This note records how Voice Lab used to fit a re-voiced take to its window by time-stretching it, what was tried, and why it was rejected. It does not describe the current design. The current policy is in [voice-lab.md §8.9](../spec/voice-lab.md#89-duration-fit): voiced speech is never time-stretched.

## 1. The superseded design

The ratio was `r = duration(trimmed TTS) / duration(W)`, and `STRETCH_OK = [0.92, 1.08]` was the "pitch-preserving stretch range (±8%)". Step 1 of voice-lab.md §8.9 read:

> **Within range.** If `r ∈ STRETCH_OK`, apply a pitch-preserving time-stretch to exactly `duration(W)`. The output timeline is unchanged, and the video stays source video.
>
> - macOS: `AVAudioUnitTimePitch` (`rate = r`) in `AVAudioEngine` offline manual rendering.
> - Windows: FFmpeg's `atempo` filter (libavfilter, LGPL), `atempo = r`.

Step 2 borrowed pause time at the seams or padded room tone, and ended "Recompute `r`. If it now falls in `STRETCH_OK`, go to step 1." Other sections followed from this:

- §8.6 ranked candidates by `0.6 × (1 − min(1, |r − 1| / 0.25)) + 0.3 × matchRatio + 0.1 × flatness`.
- §8.8 multiplied synthetic word times by the stretch factor.
- §11.9 listed stretch among the ordinary processing steps allowed alongside SynthID watermarks.
- §15 test 4 expected `r = 1.05` to stretch to the exact length, and `r = 1.15` next to a 0.6 s pause to borrow the pause and then stretch.

## 2. Windows `atempo`

This paragraph was removed from §8.9:

> The audited Windows runtime now includes `atempo`; its reproducible build and native graph evidence are recorded in `tools/ffmpeg-build/README.md`. The graph's first output PTS of zero does not establish a proportional body origin or exact output duration. Finite-window count differences and marker shifts must be handled and verified in the production composition path with the declared trim and seam handles. Nonunity App and CLI rendering remains refused until that path passes; the runtime prerequisite alone does not enable duration fitting.

These sentences were removed from the Windows refusal in §10.5:

> Windows admits unity and its immediately adjacent binary64 values as duration-arithmetic roundoff. Other values, including `1 + 1e-9`, require fit and return a typed `VoiceLabTempoException` before paid snapshot or output creation. The audited runtime contains `atempo`; the refusal reflects unverified body and seam placement rather than a missing runtime prerequisite. Direct bounded atempo rendering remains diagnostic only.

The audited Windows FFmpeg runtime still contains `atempo` (architecture §6.1). It stays a diagnostic path. Its source header calls it "an implementation of WSOLA algorithm", the same family as the rejected overlap-add experiment in section 4.

## 3. Mac `AVAudioUnitTimePitch`

This paragraph was removed from the Mac refusal in §10.5:

> Nonunity pitch-preserving fit is a typed `pitchPreservingFitUnverified` capability refusal before paid snapshot, scratch or output creation. Only numerical roundoff within four binary64 ULPs of unity takes the unity path. The direct offline `AVAudioUnitTimePitch` diagnostic still uses the inverse of stored stretch and bounded CAF rendering for measured experiments; its full frame count does not prove that body and declared seam handles survived. A first-channel, level-gated waveform heuristic previously accepted right-only and quiet copies of full-take and extra-preroll signals that it refused at normal mono level. It is not a production acceptance check. Subsequent native diagnostics reproduced an undetected middle pulse and measured tail timing drift, but did not reproduce an absent tail packet; a failed detector must not be described as proven content loss. Three tested neutral prime/drain policies failed the full provisional criteria despite returning enough frames for the nominal crop. Those diagnostic limits do not define shipping tolerances or establish a universal processor defect. The diagnostic results are retained outside the source tree for a later measured prime, drain and crop policy; that policy is not yet established.

The refusal itself remains in §10.5. ADR-R30 makes it permanent until a later ADR adopts a micro-stretch.

## 4. What the user heard

The user compared two stretchers by ear on real camera speech: a 15 s excerpt at rates 1.08 and 0.92, the edges of `STRETCH_OK`.

- **Finite fit**, a WSOLA-style overlap-add (`FiniteVoiceFit.swift` in commit `8ec929e`, never merged to main): a 960-frame window, 240-frame hop and ±240-frame search at 48 kHz. The user heard a robotic quality in expanded audio, and audible artifacts and less purity in compressed audio, compared with the original.
- **Apple `AVAudioUnitTimePitch`** at its default overlap of 8. The user judged the original best and both processed versions metallic.

Not tested: TimePitch with overlap 32, and the `AVAudioTimePitchAlgorithm.timeDomain` variant, which the macOS SDK header `AVAudioProcessingSettings.h` describes as "Modest quality, less expensive. Suitable for voice". Stretching by ±3% was not tested either. The verdict shows only that ±8% on real recorded speech fails with these two algorithms.

## 5. Why the other stretchers are not candidates

| Stretcher | Licence | Family and evidence | Status after ADR-R30 |
|---|---|---|---|
| FFmpeg `atempo` | LGPL-2.1+, already in the audited Windows runtime | WSOLA, by its source header. No Mac counterpart | Not a fit candidate; diagnostic only |
| SoundTouch | LGPL-2.1, or a commercial licence on request | Its README says it "uses WSOLA-like time-stretching routines", tuned for pop and rock, and warns of an "echoing" artifact when slowing down. It would be the first LGPL library on the Mac | Not a fit candidate |
| Apple `AVAudioUnitTimePitch` | Apple system framework | Rejected as metallic (section 4). Mac only | Not a fit candidate |
| Rubber Band R3 | GPL, or a paid commercial licence | A phase vocoder, widely regarded as one of the best. GPL cannot ship in the MIT apps | Excluded unless a commercial licence is bought |
| Signalsmith Stretch | MIT | A hybrid spectral (phase-vocoder) design. Its README says it "sounds best for more modest changes (between 0.75x and 1.5x)". No speech benchmark exists | Optional later micro-stretch of at most ±3%, behind the blinded listening check |
| Sonic | Apache-2.0 | Written for speech; uses the pitch period (AMDF) and is focused on speed-ups above 2x. ExoPlayer uses it for variable-speed playback. No data for 3–8% slow-downs on cloned voices | Optional later micro-stretch of at most ±3%, behind the blinded listening check |
| Bungee (open-source edition) | MPL-2.0 | A phase vocoder. The vendor's own comparison shows a much higher noise floor than Bungee Pro | Lower priority than Signalsmith and Sonic |
| Duration-controllable neural TTS, for example IndexTTS2 | Unverified model licence | The paper claims token-level duration control, for Chinese and English only, so not Estonian | Future option only |

The phase-vocoder designs (Signalsmith, Bungee, Rubber Band) belong to the family the user heard as metallic.

## 6. Sources

- FFmpeg `atempo` source: https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/af_atempo.c
- SoundTouch: https://www.surina.net/soundtouch/ and https://www.surina.net/soundtouch/README.html
- Rubber Band: https://breakfastquay.com/rubberband/
- Signalsmith Stretch: https://github.com/Signalsmith-Audio/signalsmith-stretch, with informal comparisons at https://www.practicesession.app/blog/signalsmith-stretch-deep-dive/, https://forum.hise.audio/topic/7303/timestretching-pitchshifting/38 and https://github.com/kvoltmer/Audionaut/pull/78
- Sonic: https://github.com/waywardgeek/sonic and https://medium.com/google-exoplayer/variable-speed-playback-with-exoplayer-e6e6a71e0343
- Bungee: https://github.com/bungee-audio-stretch/bungee and https://bungee.parabolaresearch.com/compare-audio-stretch-tempo-pitch-change
- Speech tempo just-noticeable difference of about 5%: Quené (2007), https://www.sciencedirect.com/science/article/abs/pii/S0095447006000441
- IndexTTS2: https://arxiv.org/pdf/2506.21619
