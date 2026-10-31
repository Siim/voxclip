# Speaker parity, English calibration and Estonian et-v1

`vectors.json` holds eight PCM16 mono, six-second LibriSpeech test-clean renders: four original 16 kHz excerpts and 48 kHz / 44.1 kHz versions of `1089-134686-0000` and `1188-133604-0000`. High-rate IDs append the rate. FFmpeg 8.0 resampled the committed 16 kHz excerpts to produce those four high-rate WAVs. Each includes its input rate, SHA-256, Silero voiced ranges (half-open 16 kHz sample indices), 256-dimensional L2-normalized embedding and every pairwise cosine score. Expected embeddings and scores now come from the production Swift resampler/embedding/cosine path, not Python ONNX. Absolute tolerances remain 0.0002, with no relative tolerance. Windows should consume the same WAV bytes and the versioned resampler/voiced-window/feature contract, not infer identity from filenames.

Source and attribution: LibriSpeech (c) 2014 Vassil Panayotov, CC BY 4.0, `https://www.openslr.org/resources/12/test-clean.tar.gz` (SHA-256 `39fde525e59672dc6d1551919b1478f724438a95aa55f874b576be21967e6c23`). Excerpts were decoded from FLAC to WAV and truncated to the first six seconds. This is a modification; no endorsement is implied. The full licence is in root `THIRD_PARTY_NOTICES.md`.

| Utterance IDs | Book / chapter |
|---|---|
| `1089-134686-0000`, `1089-134686-0002` | Portrait of the Artist as a Young Man, Ch3 Pt1 |
| `1188-133604-0000`, `1188-133604-0001` | Lectures on Landscape, Lecture III: Color |

`calibration-en.json` records 438 distinct six-second source utterances from 146 speakers, each rendered at 48 kHz and 44.1 kHz (876 renders). Dev-clean and test-clean supply 80 calibration speakers / 240 independent source utterances. Dev-other and test-other supply 66 additional, speaker-disjoint validation speakers / 198 source utterances. Speakers never cross corpus splits. Pairs and sample-rate versions are correlated, **not independent trials**. No pair compares rate versions of the same source utterance. No consent or provider account is represented by these corpus clips.

| Corpus | Input rate | Speakers | Source clips | False accepts / impostor pairs | FAR | Same-speaker passes / pairs |
|---|---:|---:|---:|---:|---:|---:|
| dev-clean | 48,000 Hz | 40 | 120 | 5 / 7,020 | 0.071225% | 120 / 120 (100%) |
| dev-clean | 44,100 Hz | 40 | 120 | 5 / 7,020 | 0.071225% | 120 / 120 (100%) |
| test-clean | 48,000 Hz | 40 | 120 | 8 / 7,020 | 0.113960% | 120 / 120 (100%) |
| test-clean | 44,100 Hz | 40 | 120 | 8 / 7,020 | 0.113960% | 120 / 120 (100%) |
| dev-other | 48,000 Hz | 33 | 99 | 0 / 4,752 | 0% | 99 / 99 (100%) |
| dev-other | 44,100 Hz | 33 | 99 | 0 / 4,752 | 0% | 99 / 99 (100%) |
| test-other | 48,000 Hz | 33 | 99 | 2 / 4,752 | 0.042088% | 98 / 99 (98.989899%) |
| test-other | 44,100 Hz | 33 | 99 | 2 / 4,752 | 0.042088% | 98 / 99 (98.989899%) |

Across all conditions there are 47,088 impostor and 876 same-speaker pairs. The 2026-10-29 end-to-end production rerun publishes **tau = 0.45**: the 99.9th percentile of pooled clean impostors at both rates (0.44653703263815736, linear interpolation at `(n-1)*0.999`) plus `max(0.002, measured cross-runtime drift)`, rounded up to 0.01 with decimal ceiling. This replaces the earlier maximum-impostor rule. All scores use the production Swift pipeline, so there is no separate Python runtime drift to measure (recorded as 0); the fixed margin still applies. Freeze before disjoint validation, without lowering to pass a harder condition. Every corpus/rate meets the predeclared FAR ≤ 0.5% and same-speaker pass ≥ 95% gates. Pooled results are 30/47,088 false accepts (0.063710%) and 874/876 same-speaker passes (99.771689%). Only English with installed, hash-verified assets becomes available; Estonian remains unavailable.

The report includes the 0.001-grid clean and overall score curves plus the exact candidate, margin rule, all condition counts/results, selection policy, CLI/model/VAD/input hashes and decoder version. `calibration-pairs.json` stores all 47,964 complete within-condition pairs as `[leftID, rightID, sameSpeaker, productionScore, corpusRate]`; rate-suffixed IDs identify the rendered inputs. Every pair uses distinct source utterances. These are read-speech calibration/validation data, not held-out field accuracy, anti-spoof guarantees or microphone acceptance.

All corpora are LibriSpeech (c) 2014 Vassil Panayotov, CC BY 4.0, from OpenSLR 12. Only the eight parity WAVs are committed; corpus audio remains outside the repository. Additional source archives:

| Archive URL | SHA-256 |
|---|---|
| `https://www.openslr.org/resources/12/dev-clean.tar.gz` | `76f87d090650617fca0cac8f88b9416e0ebf80350acb97b343a85fa903728ab3` |
| `https://www.openslr.org/resources/12/dev-other.tar.gz` | `12661c48e8c3fe1de2c1caa4c3e135193bfb1811584f11f569dd12645aa84365` |
| `https://www.openslr.org/resources/12/test-other.tar.gz` | `d09c181bba5cf717b3dee7d4d592af11a3ee3a09e08ae025c5506f6ebe961c29` |

`features.json` is a separate deterministic numerical vector generated by the independent NumPy feature implementation from `Float(sin(Double(index) * 0.071) * 0.2)` for 48,000 samples. It contains the first and last 80-bin CMN rows; Swift checks them without a model or download.

See `tools/voice-lab/README.md` for regeneration. The real model is 26,530,309 bytes: it is not a small fixture and is not committed. Real-model tests explicitly skip when the local cache is absent; they never download. Estonian et-v1 failed its gates (below), so a passing Estonian calibration and the user's own-voice check on this Mac microphone are owed. A production language without calibrated evidence remains unavailable.

## Estonian et-v1 (Riigikogu): failed, Estonian stays unavailable

`policy-et-v1.md` was committed before any Estonian audio was decoded or scored. The frozen candidate from the calibration groups alone was committed (`status: frozen-before-validation`) before any validation excerpt was rendered or scored. The branch history shows that order: policy, frozen candidate, validation.

`calibration-et.json` records 480 distinct six-second excerpts from 160 speakers, each rendered at 48 kHz and 44.1 kHz (960 renders). The renders were made like the English ones: FFmpeg 8.0 with `-t 6 -ac 1 -ar 48000|44100 -c:a pcm_s16le`, here from the 16 kHz excerpts. The speakers are four hash-split, speaker-disjoint groups of 40:
- `rk-cal-a` and `rk-cal-b` fit τ (80 speakers, 240 excerpts).
- `rk-val-a` and `rk-val-b` are speaker-disjoint validation only (80 speakers, 240 excerpts).

Each speaker's three excerpts come from three different pool sessions on different days, so every same-speaker pair is cross-session. Pairs and rate renders are correlated, **not independent trials**.

Selection, from transcripts alone:
- The 30-session pool gave 191 qualifying speakers (48 / 48 / 48 / 47 by group) and 716 candidate excerpts.
- 34 candidates had under 3 s of Silero speech at 48 kHz or 44.1 kHz and were dropped. Where a speaker had a fourth-session candidate, it took the dropped one's place.
- 13 speakers had fewer than three passing candidates and were skipped. Each group then used its first 40 complete speakers in key order.

| Group | Role | Input rate | Speakers | Source clips | False accepts / impostor pairs | FAR | Same-speaker passes / pairs |
|---|---|---:|---:|---:|---:|---:|---:|
| rk-cal-a | calibration | 48,000 Hz | 40 | 120 | 7 / 7,020 | 0.099715% | 107 / 120 (89.166667%) |
| rk-cal-a | calibration | 44,100 Hz | 40 | 120 | 7 / 7,020 | 0.099715% | 107 / 120 (89.166667%) |
| rk-cal-b | calibration | 48,000 Hz | 40 | 120 | 5 / 7,020 | 0.071225% | 115 / 120 (95.833333%) |
| rk-cal-b | calibration | 44,100 Hz | 40 | 120 | 5 / 7,020 | 0.071225% | 115 / 120 (95.833333%) |
| rk-val-a | speaker-disjoint validation | 48,000 Hz | 40 | 120 | 20 / 7,020 | 0.284900% | 107 / 120 (89.166667%) |
| rk-val-a | speaker-disjoint validation | 44,100 Hz | 40 | 120 | 20 / 7,020 | 0.284900% | 107 / 120 (89.166667%) |
| rk-val-b | speaker-disjoint validation | 48,000 Hz | 40 | 120 | 4 / 7,020 | 0.056980% | 114 / 120 (95%) |
| rk-val-b | speaker-disjoint validation | 44,100 Hz | 40 | 120 | 4 / 7,020 | 0.056980% | 114 / 120 (95%) |

The τ rule is the English one, unchanged:
- The 99.9th percentile of the 28,080 pooled `rk-cal-a` / `rk-cal-b` impostor scores at both rates is 0.4820615720086565 (linear interpolation at `(n-1)*0.999`).
- Adding `max(0.002, drift = 0)` and rounding up to 0.01 with decimal ceiling froze the candidate at **0.49**.

Results at 0.49:
- Every cell meets FAR ≤ 0.5%. The worst is `rk-val-a` at 0.284900%.
- The same-speaker gate (≥ 95%) fails in `rk-cal-a` and `rk-val-a`: 89.166667% at both rates.
- The pooled calibration point also fails: 24/28,080 false accepts and 444/480 same-speaker passes (92.5%).
- Pooled over all 8 cells: 72/56,160 false accepts (0.128205%) and 886/960 same-speaker passes (92.291667%).

`threshold` is therefore `null`. The outcome is **failed**, and Estonian stays unavailable. τ was not refitted, lowered or replaced after validation. No speakers or pairs were curated, and the catalogue and apps are unchanged. A later et-v2 that adds Mozilla Common Voice et (consumer microphones), if the product owner provides it, supersedes et-v1 whatever its outcome.

`calibration-pairs-et.json` stores all 57,120 within-condition pairs as `[leftID, rightID, sameSpeaker, productionScore, groupRate]`. Every pair uses two different excerpts, and all scores come from the production DEBUG `voxclip-cli speaker-diagnostic`. The report also records:
- the model, VAD and CLI hashes, the decoder and the preprocessing ID;
- the 0.001-grid curves and the selection and rejection logs;
- each render's ID, `session@start-end` source key, `rkNNN` speaker key (numbered in SHA-256 order of the normalised name), render SHA-256 and excerpt SHA-256;
- the source records: the Hugging Face revision; for each of the 30 pool FLACs its LFS SHA-256, size, STREAMINFO MD5 and length; and for all 1,001 `.trs` files their SHA-256 and Git blob SHA-1.

No audio, transcripts, sentences, speaker names, name map, name hashes or embeddings are committed. The session keys can be traced to public speaker names through the public stenograms; that is inherent to a reproducible public corpus.

Attribution: Derived from Riigikogu plenary recordings and stenograms (© Riigikogu, CC BY-SA) via TalTechNLP/riigikogu-audio-stenograms-2018-2025 (CC BY-SA 3.0), revision `52e34438a43b26b785ad2f76806633bf9942b2fb`. No audio or text redistributed.
