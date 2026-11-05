# Clip-controls project wire fixtures

Synthetic metadata only. `clip-controls-project.voxclip` is the context-demo v4 fixture without its demo and motion
fields, plus one `clipControls` entry under `clip-main` (1.25×, 9:16, Muted, −3.5 dB, fades, flipped, a quarter turn).
`clip-controls-wire-cases.json` (`voxclip-clip-controls-wire-cases/1`) applies JSON-pointer replacements and removals to it.

Regenerate with `python3 tools/fixtures/clip-controls/generate_clip_controls.py` (check_drift.py runs it and the schema
generator `tools/schemas/generate_clip_controls_schema.py`). Do not hand-edit. Swift `ClipControlsProjectWireTests` and C#
`ClipControlsProjectWireTests` replay every case; `python3 tools/schemas/test_clip_controls_schema.py` checks the schema
half. `schemaValid: true` on an invalid case marks a rule only the Cores check: the clip exists, one entry per clip, and no
entry is stored at its defaults. The rules are in doc/design.md section 6.8.
