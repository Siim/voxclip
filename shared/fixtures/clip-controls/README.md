# Clip-controls project wire fixtures

Synthetic metadata only. `clip-controls-project.voxclip` is the context-demo v4 fixture without its demo and motion
fields, plus one `clipControls` entry under `clip-main` (1.25×, 9:16, Muted, −3.5 dB, fades, flipped, a quarter turn).
`clip-controls-wire-cases.json` (`voxclip-clip-controls-wire-cases/1`) applies JSON-pointer replacements and removals to it.

Regenerate with `python3 tools/fixtures/clip-controls/generate_clip_controls.py` (check_drift.py runs it and the schema
generator `tools/schemas/generate_clip_controls_schema.py`). Do not hand-edit. Swift `ClipControlsProjectWireTests` and C#
`ClipControlsProjectWireTests` replay every case; `python3 tools/schemas/test_clip_controls_schema.py` checks the schema
half. `schemaValid: true` on an invalid case marks a rule only the Cores check: the clip exists, one entry per clip, and no
entry is stored at its defaults. The rules are in doc/design.md section 6.9.

`clip-controls-color-grade-cases.json` (`voxclip-clip-color-grade-wire-cases/1`, same generator) holds the schema-v8
`colorGrade` cases (looks spec 2026-11-28, sections 8.1 and 11.5) on the same project: every case first sets
`schemaVersion` to 8. A valid case loads and saves byte for byte at v8 and a v7 reader refuses it as too new; the invalid
cases cover ranges, key sets, curves, split tones and a grade in a v4 or v6 project. `schemaValid: true` marks the one rule
only the Cores check: a curve never decreases.
