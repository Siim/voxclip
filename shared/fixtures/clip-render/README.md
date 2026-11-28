# Clip-render vectors

Synthetic numbers only. `clip-render-cases.json` (`voxclip-clip-render-cases/1`) records the Mac renderer's decisions for clip
controls (doc/design.md section 6.9) and Ask Claude's effects (doc/spec/ai.md section 18.5) that a second renderer must
reproduce: the look pixels on the 4 × 2 synthetic frame (`macGoldens` are the Mac's Core Image goldens, `recipe` is the
`ClipLookRecipe` arithmetic on the 8-bit swatches), where flips and quarter turns move the top-left corner, effect boxes
through `mapRect`, clip frames and bitrates, rendered lengths at a speed, the bleep, silence, sound and title bounds at
1.25×, SRT cues on the rendered clock, and × masking.

Regenerate with `python3 tools/fixtures/clip-render/generate_clip_render.py` (check_drift.py runs it). Do not hand-edit.
C# `ClipRenderVectorTests` (Core) and `ClipRenderMediaTests` (Media) replay every category, and so does the Mac's
`ClipRenderVectorReplayTests` (Media). Every case passes on both as generated; a case that fails is fixed in the generator.

`clip-grade-cases.json` (`voxclip-clip-grade-cases/1`) holds the colour grade of the looks spec (2026-11-28, sections 5, 6
and 11.1): the Fix (stage P), the base look and adjustments, the tone, vibrance, curve, split-tone and fade steps (stage T),
Amount mixed over the Fix's output, and the vignette and grain finish (stage F) with the context demo's grain hole. It also
holds Auto (`ClipColorFix.measure`) and the light facts on synthetic frames, the 24 looks of `shared/looks/clip-looks.json`
on every swatch at 100% and 70%, and the spec's skin table. Inputs are stored bytes; outputs are bytes, plus floats where a
case lists them. A sibling file, so the strict category lists in `clip-render-cases.json` and its replays stay unchanged.
Regenerate with `python3 tools/fixtures/clip-render/generate_clip_grade.py` (check_drift.py runs it and compares floats with
its tolerance, since the Fix's pow and Auto's log2 can differ in the last bit between platforms). Do not hand-edit. Swift
`ClipGradeRecipeTests` and C# `ClipGradeVectorTests` (both Core) replay every category: bytes and integers exactly, floats
within 1e-9 and curve coefficients within 1e-12.

`clip-grade-mac-goldens.json` (`voxclip-clip-grade-mac-goldens/1`) holds the Mac's Core Image bytes for every grade case
(`controls`, `chains`, `adjustments`, `looksOnSwatches` and `skinCheck`, keyed by category and case, each input by name)
and every `finish` case, rendered through `ClipPicture.grade` and `finish` with the clip grade's kernels. The Mac's
`ClipGradeRenderTests` (Media) holds its renders within 1 of these and within 2 of the recipe's bytes; Windows
`ClipPicture.Grade` and `Finish` replay them within 1. They are recorded, not generated: after a deliberate change to the
kernels or the cases, run that suite with `VOXCLIP_RECORD_CLIP_GRADE_GOLDENS=1` and review the diff. Do not hand-edit.
