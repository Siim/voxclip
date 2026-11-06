# Voice rebuild vectors

`voice-rebuild-cases.json` (schema `voxclip-voice-rebuild/1`) pins "Rebuild from my videos" (doc/spec/voice-lab.md section 6.12, ADR-R44) and the per-video floor of section 6.13 (ADR-R45): which owner-verified stretches a rebuilt voice is made from, in send order, what was left out, and the line shown before any click. `tools/fixtures/voice-lab/generate_voice_rebuild.py` writes it; `--check` fails on drift, and `tools/fixtures/voice-lab/check_drift.py` compares it byte for byte (EXACT list).

Both Cores replay it: the Mac in `VoiceRebuildReplayTests`, Windows in `VoiceRebuildTests.ReplaysEveryRebuildVector`.

## Arithmetic

Pure binary64 in a fixed order, as in `voice-references-README.md`: a vector is normalized by the square root of its sum of squares (each term in binary64, summed in order), each element rounded to binary32; a cosine is the binary64 sum, in order, of the products of the two normalized vectors, clamped to [-1, 1]. Candidate embeddings are synthetic four-element vectors normalized that way, stored as little-endian binary32 in base64. Scores and SNRs are inputs; no speech or speaker model is involved.

## Kinds

- `pick`: `VoiceRebuild.pick(candidates, threshold, keptMs, minimumSnrDb)`. `expected.pieces` lists `[video, startMs]` in send order (after the kept consent clip); `rejected` counts `notTheOwner` (below τ, one hop), `noisy` (below the floor), `length` (not 5–30 s) and `full` (24 files or 120 s, the kept clip counted); then `totalMs`, `videoCount`, `fileCount`, `enough` (30 s) and `summary` ("1 min 8 s from 1 video and your consent clip").
- `amount`: whole seconds as minutes and seconds ("2 min", "1 min 8 s", "27 s").
