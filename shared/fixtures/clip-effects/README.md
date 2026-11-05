# Clip-effects project wire fixtures

Synthetic metadata only: no audio, no video, no provider replies. `effects-project.voxclip` is the context-demo v4
fixture without its demo and motion fields, plus one effect of every kind (bleep, mute, blur, pixelate, title, lower
third, sticker, arrow, circle, progress bar, freeze and a bundled sound). `effects-wire-cases.json`
(`voxclip-clip-effects-wire-cases/1`) applies JSON-pointer replacements and removals to it.

Regenerate with `python3 tools/fixtures/clip-effects/generate_clip_effects.py` (check_drift.py runs it and the schema
generator `tools/schemas/generate_clip_effects_schema.py`). Do not hand-edit. Swift `ClipEffectsWireTests` and C#
`ClipEffectsWireTests` replay every case; `python3 tools/schemas/test_clip_effects_schema.py` checks the schema half.
`schemaValid: true` on an invalid case marks a rule only the Cores check: the clip and words exist, unique ids, a rect
inside the frame, increasing track times, no samples while untracked, a freeze of at most 5 s, a sound spanning its own
length, a sticker of at most 16 scalars, a progress bar at the top or bottom, and the project's own sound folder. The
rules are in doc/spec/ai.md section 18.2.
