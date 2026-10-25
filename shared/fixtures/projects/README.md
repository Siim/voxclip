# Example projects

These are two hand-written `.voxclip` project files that validate against [`shared/schemas/project.schema.json`](../../schemas/project.schema.json). The rules they follow are in [`doc/spec/editing.md`](../../../doc/spec/editing.md) section 10. The media paths, sizes and hashes are fictional, so the media will never resolve. Use the files to test loading, validation, round-tripping and planning.

| File | Shows |
|---|---|
| `interview-take.voxclip` | macOS; ElevenLabs Scribe v2 (engine `elevenlabs`, verbatim, native timing) on an English take at 48 kHz; two filler cuts, a cut pause and a correction; no clips; export choices (9:16, standard, no SRT, default folder); an edited share caption for the full edit |
| `clip-from-long-take.voxclip` | Windows; whisper.cpp (engine `whispercpp`) with the TalTech Estonian model `taltech-et-verbatim-2604-q8_0` (catalogue sha256, non-verbatim, DTW timing) at 44.1 kHz stereo; an `unlabeledSpeech` item; a tight 0.05 s pause breath; an AI clip (active, selected) and a manual clip (not selected); a cached clip-finding result from the Claude Code connector; caption overrides and per-aspect position; export choices with an explicit folder; an edited share caption for the AI clip |

The expected plans for the full take and for every clip are in `shared/fixtures/editing/projects/<name>.json` (kind `project-plan`), produced by the fixture generator.

Both test suites SHOULD also load each file, save it, reload it, and check that the two models are equal. This catches number formatting that does not round-trip and dropped fields.

Validate them with `python3 tools/schemas/validate.py` (CI runs it). After any change to these files, run `npm --prefix tools/fixtures/editing run generate` so `shared/fixtures/editing/projects/*.json` stays in step.
