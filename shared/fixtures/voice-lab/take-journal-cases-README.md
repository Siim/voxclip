# Paid-take journal vectors

`take-journal-cases.json` pins the paid-take journal (voice-lab §3 "Paid takes are
kept"): the entry each platform writes to `VoiceLab/<projectId>/takes/<assetId>.json`
when a paid ElevenLabs take arrives, and which entry a later run over the same
request adopts for free. It is synthetic and holds no recorded audio or provider
replies.

`assets` describes tiny mono PCM16 files at 24 kHz: `frames` copies of the 16-bit
value `fill`. Each platform writes them with its own paid-asset writer, whose
canonical 44-byte WAV must hash to `sha256`. `entries` is then written through the
journal; the "missing" entry has no asset, and the "wrong frames" entry claims
more frames than its file holds.

Each `parse` case decodes and validates one entry against `projectId`. A valid
entry must encode back to the same keys and values (numbers compared by value;
`providerRequestID`, `alignment` and `estimateUSD` are left out when absent).
Each `match` case looks up the newest entry over `key` (record, clone, model,
language, words as sent, words before and after, and pace rounded to 0.01) whose
asset is intact, leaving out the asset files in `claimed`; `expected` is its
`assetFile`, or null.

`tools/fixtures/voice-lab/generate_take_journal.py` writes the file; CI runs it and
fails on any drift, so change the generator, not the JSON. An asset's `sha256` is the
SHA-256 of its canonical WAV (`RIFF`, 36 + data size, a 16-byte PCM `fmt ` chunk, then
`data`); `caseCount` is the number of `cases`, which both replays assert.
