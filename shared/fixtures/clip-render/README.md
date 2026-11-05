# Clip-render vectors

Synthetic numbers only. `clip-render-cases.json` (`voxclip-clip-render-cases/1`) records the Mac renderer's decisions for clip
controls (doc/design.md section 6.9) and Ask Claude's effects (doc/spec/ai.md section 18.5) that a second renderer must
reproduce: the look pixels on the 4 × 2 synthetic frame (`macGoldens` are the Mac's Core Image goldens, `recipe` is the
`ClipLookRecipe` arithmetic on the 8-bit swatches), where flips and quarter turns move the top-left corner, effect boxes
through `mapRect`, clip frames and bitrates, rendered lengths at a speed, the bleep, silence, sound and title bounds at
1.25×, SRT cues on the rendered clock, and × masking.

Regenerate with `python3 tools/fixtures/clip-render/generate_clip_render.py` (check_drift.py runs it). Do not hand-edit.
C# `ClipRenderVectorTests` (Core) and `ClipRenderMediaTests` (Media) replay every category. The Mac's own tests hold the
same numbers; a Swift replay of this file is owed.
