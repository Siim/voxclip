# Clip-effects project wire fixtures

The wire fixtures are synthetic metadata only. `effects-project.voxclip` is the context-demo v4
fixture without its demo and motion fields, plus one toolbox effect of each kind (bleep, mute, blur, pixelate, title, lower
third, sticker, arrow, circle, progress bar, freeze, a bundled sound, timed colour and speed, and illustration).
`effects-wire-cases.json`
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

`motion-template-cases.json` contains hand-authored harness effects at words 9–10 of `projects/clip-from-long-take.voxclip`
(source seconds 5.9–6.24). The Mac and Windows harnesses replay those anchors; both frame compositors render each
placed template. `motion-template-invalid-cases.json` holds payloads neither platform may accept.
Update these by hand only when the documented template contract changes.

`footage-cases.json` is hand-authored using the same convention. Both Core suites check companion source keys,
source-time bounds (including a still near the end), and the `bRoll`, `screenshot`, and `videoStack` vocabulary.
`footage-project-cases.json` layers companion media onto the same base project to verify persistence and rejection
of invalid, duplicate, or overlapping placements. Update these vectors by hand only when the contract changes.

## Offline asset responses

`openverse-sound.json` and `fal-illustration.json` capture the response shapes used by the two asset clients.
They contain synthetic, non-identifying data: the sound download is replayed from `shared/data/sfx/pop.wav`,
and the inline PNG stands in for one generated image. Neither fixture requires credentials or network access.
