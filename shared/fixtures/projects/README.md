# Example projects

These are two hand-written `.voxclip` project files that validate against [`shared/schemas/project.schema.json`](../../schemas/project.schema.json). The rules they follow are in [`doc/spec/editing.md`](../../../doc/spec/editing.md) section 10. The media paths, sizes and hashes are fictional, so the media will never resolve. Use the files to test loading, validation, round-tripping and planning.

| File | Shows |
|---|---|
| `interview-take.voxclip` | macOS; ElevenLabs Scribe v2 (engine `elevenlabs`, verbatim, native timing) on an English take at 48 kHz; two filler cuts, a cut pause and a correction; no clips; export choices (9:16, standard, no SRT, default folder); an edited share caption for the full edit |
| `clip-from-long-take.voxclip` | Windows; whisper.cpp (engine `whispercpp`) with the TalTech Estonian model `taltech-et-verbatim-2604-q8_0` (catalogue sha256, non-verbatim, DTW timing) at 44.1 kHz stereo; an `unlabeledSpeech` item; a tight 0.05 s pause breath; an AI clip (active, selected) and a manual clip (not selected); a cached clip-finding result from the Claude Code connector; caption overrides and per-aspect position; export choices with an explicit folder; an edited share caption for the AI clip |

The expected plans for the full take and for every clip are in `shared/fixtures/editing/projects/<name>.json` (kind `project-plan`), produced by the fixture generator.

Both test suites SHOULD also load each file, save it, reload it, and check that the two models are equal. This catches number formatting that does not round-trip and dropped fields.

Validate them with `python3 tools/schemas/validate.py` (CI runs it). After any change to these files, run `npm --prefix tools/fixtures/editing run generate` so `shared/fixtures/editing/projects/*.json` stays in step.

## Legacy text normalization

`tools/fixtures/projects/generate_normalization.py` writes `normalization/legacy-nfc.voxclip` and `normalization/legacy-nfc.expected.json`. The input has non-NFC LV+T word text and a correction, inert jamo boundary text, and a composed Kirat Rai letter. Both project loaders normalize word text and corrections in memory before text validation, silently; their serializers write exactly the same model as the expected file. Ids and source times stay fixed. Run the generator twice to check reproducibility.

## Timestamp cases

`timestamps.json` pins the persisted timestamp rule of editing.md section 10.1. `tools/fixtures/projects/generate_timestamps.py` writes it with the Python standard library only, and two runs give identical bytes. Regenerate with `python3 tools/fixtures/projects/generate_timestamps.py` and review the diff as a behaviour change. Both Core suites replay every case: Mac `TimestampWireRule` (`Tests/VoxClipCoreTests/Editing/TimestampTests.swift`) and Windows `TimestampWireRuleTests`.

- `texts`: loading `input` and saving it writes `canonical`. Each of 14 base seconds takes 23 fractions, from none to nine digits and including exact half milliseconds. The bases are the Unix epoch and the second before it, macOS's 2001 reference date and the second before it, a working day, a year end, leap-day and century rollovers, the 1582 Gregorian reform, and the first and last seconds of years 0001–9999.
- `rejected`: the timestamp parsers (`UTCTimestamp`, `UtcTimestamp`), the project decoders and project validation refuse `input`, for the stated `reason`. Inputs that round past `9999-12-31T23:59:59.999Z` are refused too, because they have no canonical text. Cache metadata readers are not bound by this list: they also accept RFC 3339 offsets (architecture §8.2). They still refuse an instant that rounds past `9999-12-31T23:59:59.999Z`, and that entry becomes a cache miss.
- `instants`: `ticks` is a decimal string of 100 ns ticks since 0001-01-01T00:00:00Z (the .NET `DateTime.Ticks` unit; a JSON number cannot hold every such value exactly). Writing that instant gives `canonical`, or fails when `canonical` is null. The macOS suite holds each instant as `Date(timeIntervalSinceReferenceDate: Double(seconds) + Double(remainder) / 10_000_000)`, with seconds and remainder counted from 2001-01-01. The generator keeps only instants for which that binary64 value rounds like the exact ticks. The 34 it leaves out are exact half milliseconds that a `Date` cannot hold; the seven- and nine-digit `texts` cover them instead.
- `property`: 10,000 instants from SplitMix64 seeded with `seed`, each from two draws. The first draw modulo 315,537,897,599,999 gives whole milliseconds since 0001 below the last millisecond. The second draw modulo 9,000 gives ticks within that millisecond, and values from 4,500 up add 1,000. No instant therefore lies within 50 µs of a half millisecond, which a `Date` near year 9999 cannot resolve. `sha256` is the digest of every canonical text followed by LF, and `first` and `last` help locate a mismatch.

The two example projects, like the Voice Lab examples, store whole seconds written before the three-digit rule. A save writes the same instants with `.000`. The suites list these as the only non-canonical example projects, and every other example must already be canonical.
