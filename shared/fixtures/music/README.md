# Background-music project wire fixtures

Synthetic metadata only: no audio, no downloaded music, no provider replies. `music-project.voxclip` is the context-demo
v4 fixture without its demo and motion fields, plus a CC BY library track under `clip-main` and a generated track under the
full video. `music-wire-cases.json` (`voxclip-music-wire-cases/1`) applies JSON-pointer replacements and removals to it.

Regenerate with `python3 tools/fixtures/music/generate_music.py` (check_drift.py runs it and the schema generator
`tools/schemas/generate_music_schema.py`). Do not hand-edit. Swift `MusicProjectWireTests` and C# `MusicProjectWireTests`
replay every case; `python3 tools/schemas/test_music_schema.py` checks the schema half. `schemaValid: true` on an invalid
case marks a rule only the Cores check: the asset folder is the project id, the clip exists, one track per clip, unique ids
and an offset inside the track. The rules are in doc/spec/music.md section 2.

`music-mix-cases.json` (`voxclip-music-mix-cases/1`) holds the music bed's levels and timing (doc/spec/music.md section 4):
10 ms levels, speech activity, ducking and its interpolation, bed gain, fades, trims and crossfaded loops, and two whole
beds. `python3 tools/fixtures/music/generate_music_mix.py` writes it from a port of Mac Core `MusicMix.swift` (check_drift.py
runs it). Floats are rounded to 9 decimals. C# `MusicMixVectorTests` (Core) and `MusicBedTests` (Media) replay every case;
a Swift replay is owed.
