# Clip-effects project wire fixtures

The wire fixtures are synthetic metadata only. `effects-project.voxclip` is the context-demo v4
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

`clip-plan-effect-cases.json` is a hand-authored set of synthetic word anchors and proposed entries for the
shared `clip-plan-effect.schema.json`. Both Core suites replay the same vectors and check source spans,
framing keyframes, overlay templates, deferred asset requests, and refusal of invalid operations. Update expectations
by hand only when the documented placement contract changes; the values describe intended behaviour.

## Offline asset responses

`openverse-sound.json` and `fal-illustration.json` capture the response shapes used by the two asset clients.
They contain synthetic, non-identifying data: the sound download is replayed from `shared/data/sfx/pop.wav`,
and the inline PNG stands in for one generated image. Neither fixture requires credentials or network access.
