# Estonian speaker calibration et-v1: predeclared policy

This policy was committed on 2026-10-31, before any Estonian audio was decoded, rendered or scored. It applies the English rule in `doc/spec/voice-lab.md` §6.6 unchanged; only the corpus differs. `tools/voice-lab/riigikogu.py` implements selection and verified streaming, and `tools/voice-lab/speaker.py calibrate --language et` implements scoring. The git history is the evidence for the order: this policy first, then the frozen τ from the calibration groups alone, then validation.

## Source

- Corpus: [TalTechNLP/riigikogu-audio-stenograms-2018-2025](https://huggingface.co/datasets/TalTechNLP/riigikogu-audio-stenograms-2018-2025), revision `52e34438a43b26b785ad2f76806633bf9942b2fb`. Licence CC BY-SA 3.0, ungated. It holds 1,001 plenary sessions (December 2017 to May 2025) as 16 kHz mono 16-bit FLAC (Git LFS) and Transcriber `.trs` stenograms with forced-alignment times.
- This is the research plan's fallback: Riigikogu only, because Mozilla Common Voice et has not been provided. A single parliament hall and microphone chain is weaker evidence for home microphones than the two-corpus design.
- All 1,001 `.trs` files are read, because the pool is chosen from all of them. They are ordinary Git blobs, not LFS, so each is verified against its pinned Git blob SHA-1 and size, and its SHA-256 is recorded. Each pool FLAC is streamed once over HTTPS and checked against its LFS SHA-256 and size. Its decoded PCM is checked against the FLAC STREAMINFO MD5 and length. Only the six-second excerpts are kept, and whole sessions are never stored.

## Names

- Labels are converted to NFC and their whitespace is collapsed. The name is the trailing run of capitalised tokens. Lowercase role words (`Riigikohtu liikme kandidaat`, `Eesti Panga president`) end the run by themselves. Leading capitalised role words inside the run are then dropped: `Aseesimees`, `Esimees`, `Professor`, `Õiguskantsler` and the other words listed in `ROLE_WORDS`, plus any word ending in `minister` or `kandidaat`.
- A label that leaves fewer than two name tokens, or starts with `Unknown`, is not one named person and is dropped. On this revision 8 of 545 labels are dropped: unknown speakers, the choir, a faction, the Board and a single-word label. The `.trs` gender attribute is wrong and is never used.
- Two spellings are one person when their given names are identical and their surnames differ by one edit or by adding or dropping a hyphenated part. The canonical spelling is the one in the most sessions, then the first in code-point order. On this revision this merges 2 spellings: one married-name variant and one typo. Relatives who share a surname but have different given names stay separate speakers, and they are kept as legitimate hard impostors.
- Names, the name map and name hashes stay in the local work directory and are deleted after the run. Committed evidence uses `rkNNN` keys only.

## Turns, excerpts and pool

- A qualifying turn is a single-speaker `<Turn>` whose aligned `endTime − startTime` is at least 10.000 s. Times are exact milliseconds.
- The excerpt is `[turnStart + 2 s, turnStart + 8 s]`: 96,000 samples cut sample-exactly from the decoded 16 kHz PCM. This keeps it clear of the dataset card's ±1 s alignment error. Its source key is `session@start-end` in seconds.
- The pool is chosen from transcripts alone, greedily. Add the session that most increases the sum over speakers of `min(qualifying pool sessions, 3)`. Allow at most one session per calendar date, so same-speaker pairs are cross-day. Ties go to the earlier session ID. Stop at 30 sessions or when no session adds anything.
- On this revision the pool is 30 sessions totalling 12.9 GB of FLAC:
  - 2018: `201801101400`, `201803061000`, `201803071400`, `201805091400`, `201806051000`, `201806061400`, `201809181000`, `201809261400`, `201810171400`, `201810231000`, `201811211400`, `201811261100`
  - 2019–2021: `201902141000`, `201906031500`, `201909251400`, `202001291400`, `202103091000`, `202103101400`, `202103231000`
  - 2022–2025: `202206011400`, `202206081400`, `202210191400`, `202310181400`, `202401181000`, `202402131000`, `202405291400`, `202406121400`, `202409111400`, `202501221400`, `202502191400`

## Speakers and groups

- A speaker qualifies with qualifying turns in at least 3 pool sessions. On this revision 191 speakers qualify (from 414 people).
- Qualifying speakers are sorted by the SHA-256 of their UTF-8 canonical name and numbered `rk001`… in that order. They are dealt in turn to `rk-cal-a`, `rk-val-a`, `rk-cal-b` and `rk-val-b`, which gives 48, 48, 48 and 47 speakers. Groups are speaker-disjoint. `rk-cal-*` fit τ, and `rk-val-*` are speaker-disjoint validation only.
- A speaker's candidates are the first qualifying turn in each of their first four pool sessions by date. 143 speakers have four candidates and 48 have three, giving 716 candidates in all.

## Audio rule and replacement (stated before scoring)

- Each excerpt is rendered exactly as the English renders were: FFmpeg 8.0 `-i excerpt.wav -t 6 -ac 1 -ar 48000|44100 -c:a pcm_s16le`. The renders are mono PCM16 at 48 kHz and 44.1 kHz.
- A candidate passes when the production DEBUG `voxclip-cli speaker-diagnostic` finds at least 3 s of Silero speech, and so produces an embedding, at **both** rates. This is the existing English rule.
- A speaker keeps the first three passing candidates in date order. A failing candidate is therefore replaced by the speaker's fourth-session candidate when there is one. A speaker without three passing candidates is skipped, and the next speaker of the same group in key order takes the place.
- Each group uses its first 40 complete speakers in key order. Unused reserve speakers are not scored for anything else.

## Predeclared minimums

- Each cell is one group at one rate. With *n* speakers and three utterances each, a cell has `9n(n−1)/2` impostor pairs and `3n` same-speaker pairs.
- **Target:** 40 speakers per group, giving 7,020 impostor and 120 same-speaker pairs per cell.
- **Minimum:** 17 complete speakers per group, giving 1,224 / 51 pairs per cell. 16 speakers would give only 48 same-speaker pairs. If any group has fewer than 17 complete speakers, et-v1 fails.

## τ rule, freeze and gates

- Pairs are scored by the production Swift resampler, Silero VAD, ONNX Runtime 1.19.2 CPU embedding and cosine: the same CLI hook and preprocessing `sinc32-blackman94-silero-6.2.0-kaldi80-v2` as English. Python never computes scores. Every pair is within one cell and uses two different utterances.
- **Fit:** only `rk-cal-a` and `rk-cal-b` are rendered and scored.
  1. Pool their impostor scores at both rates (the target is 28,080).
  2. Take P99.9 by linear interpolation at index `(n − 1) × 0.999`.
  3. Add `max(0.002, drift)`. Drift is 0 because scoring is production Swift.
  4. Apply a decimal ceiling to the next 0.01.
  5. Freeze the result. `calibration-et.json` is committed with `status: frozen-before-validation` before any validation excerpt is rendered or scored.
- **Validate:** `rk-val-a` and `rk-val-b` are scored against the frozen τ. τ is never refitted, lowered or replaced after validation scores are seen.
- **Gates:** all 8 cells (4 groups × 48 kHz and 44.1 kHz) need:
  - FAR ≤ 0.5%;
  - same-speaker pass ≥ 95%;
  - at least 200 impostor and 50 same-speaker pairs;
  - at least 17 speakers.

  The pooled calibration point must also pass, as for English. Pooled figures never replace per-cell gates.
- **No manual curation.** Nobody listens to pairs, and no speakers or pairs are removed after scoring, in calibration or in validation.
- **Failure:** if any gate fails, the report's `threshold` is `null` and Estonian stays unavailable. The evidence is committed either way, and a failed run is a valid outcome.
- **Supersession:** a later **et-v2** that adds Mozilla Common Voice et (consumer microphones), if the product owner provides it, supersedes et-v1 whatever et-v1's outcome.
- Adopting a passing τ into `shared/catalog` and the apps is a separate change.

## Committed and never committed

- **Committed:** `calibration-et.json` and `calibration-pairs-et.json`. They contain:
  - model, VAD and CLI hashes, the decoder version and the preprocessing ID;
  - the HF revision, per-FLAC LFS SHA-256 and per-`.trs` SHA-256 / Git blob SHA-1;
  - the policy, pool, render IDs, `session@start-end` source keys, `rkNNN` keys, render and excerpt SHA-256s;
  - conditions, margin, curves, limitations and every within-condition pair score.
- **Never committed:** audio, transcripts or sentences, speaker names, the name map or name hashes, and embeddings.
- **Traceability:** session keys can be traced to public names through the public stenograms. This is inherent to a reproducible public corpus.
