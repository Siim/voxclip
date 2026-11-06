# Voice reference vectors

`voice-references-cases.json` (schema `voxclip-voice-references/1`) pins "Let a video teach your voice" (doc/spec/voice-lab.md section 6.9, ADR-R41): which learned references the use-time guard may use, how a phrase's speech matches the owner through them, and how learning one changes the speaker block. `tools/fixtures/voice-lab/generate_voice_references.py` writes it; `--check` fails on drift, and `tools/fixtures/voice-lab/check_drift.py` compares it byte for byte (EXACT list).

Both Cores replay it: the Mac in `VoiceSpeakerReferencesReplayTests`, Windows in `VoiceSpeakerReferencesTests.ReplaysEveryVoiceReferenceVector`.

## Arithmetic

Pure binary64 in a fixed order, so scores match to the bit on every platform:

- a vector is normalized by the square root of its sum of squares (each term in binary64, summed in order), each element rounded to binary32;
- a cosine is the binary64 sum, in order, of the products of the two normalized vectors, clamped to [-1, 1].

Embeddings are synthetic four-element integer vectors normalized that way and stored as the consent record stores them: little-endian binary32, base64. No speech or speaker model is involved.

## Kinds

- `usable`: the content keys of the references the guard may use (same model, stored score at least τ, and passing against the record's own embedding when re-checked), and `learnedCount`.
- `match`: the guard's verdict on `candidate`: `statement` (the record's own embedding, tried first), `reference` with its content key, or null.
- `learning`: the speaker block after learning `embedding` from `contentKey` at `at`: either a `refusal` (`notTheOwner`, `otherModel`, `notBetter`), or the references' content keys and statement scores in order, with the new reference's score. Over the bound of 16, the most redundant reference goes: the one closest to another, then the lower score, then the older.
