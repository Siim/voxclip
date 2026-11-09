# Clip frames project wire fixtures

Synthetic metadata only (ADR-R48, "Claude sees the picture" part 2). `clip-frames-project.voxclip` is the clip-controls
fixture with an opening lead-in on its clip (`edits.clips[].leadInSeconds`, 0.25 s) and a face-follow crop
(`clipControls[].reframe`) and a cover (`clipControls[].coverSeconds`) on its controls. `clip-frames-wire-cases.json`
(`voxclip-clip-frames-wire-cases/1`) applies JSON-pointer replacements and removals to it.

Regenerate with `python3 tools/fixtures/clip-frames/generate_clip_frames.py` (check_drift.py runs it after the schema
generators `tools/schemas/generate_clip_controls_schema.py` and `generate_clip_frames_schema.py`). Do not hand-edit. Swift
`ClipFramesProjectWireTests` and C# `ClipFramesProjectWireTests` replay every case: a valid case loads, validates and saves
byte-identically. `python3 tools/schemas/test_clip_frames_schema.py` checks the schema half. `schemaValid: true` on an invalid
case marks a rule only the Cores check.

`face-facing-cases.json` (`voxclip-face-facing-cases/1`, ADR-R48 and ai.md §19.2) holds the facing rule's vectors: the
recording's typical pitch (the median pitch of the faces in the whole video's frame pass) and whether a face with a given
yaw and pitch faces the camera (|yaw| ≤ 0.35 rad and pitch within 0.35 rad of that baseline). Regenerate with
`python3 tools/fixtures/clip-frames/generate_face_facing.py` (check_drift.py runs it). Swift and C# `FaceFacingVectorTests`
replay every case.

`decision-cases.json` (`voxclip-frame-decision-cases/1`, ADR-R48 and ai.md §19) holds the pure frame decisions on fabricated
observations: eye states, clear looks, the opening frame (the relative rule against the baseline), the cover and its C1–C3
candidates, the 9:16 and 1:1 face-follow crop, screens, blur spans and their B1… candidates, the frame sheet's summary
text, the sampling times, the Mac's two-decimal rule (the shortest decimal rounded half to even, not printf's), and an
`analysis-v2.json` sample. Inputs and answers are in the Mac's JSON shape. Regenerate with
`python3 tools/fixtures/clip-frames/generate_frame_decisions.py` (check_drift.py runs it, exact); `tools/schemas/validate.py`
checks it against `shared/schemas/frame-decision-cases.schema.json`. Swift and C# `FrameDecisionVectorTests` replay every
case, comparing numbers within 1e-12.

`frame-face-fields-cases.json` (`voxclip-frame-face-fields-cases/1`, ADR-R48 Windows, package W2) holds the Windows-only pure steps
between the two face models and a `FrameFace`, on synthetic inputs: YuNet's input size and output decoding (sparse output
tensors, the score, NMS and the largest face), the roll-aligned crop (roll, both affines, mapped points, bilinear
resampling), the crop's Laplacian variance, mean grey and clipped share, the 478 mesh landmarks to `FrameFace` fields (open,
closed, half-closed and one closed eye, turned, tipped, level, a skewed midline, an unmeasured eye, no pose, a gated face) and
the capture quality with its gates and quantile remap. It echoes `shared/catalog/frame-models.json`'s calibration block, the
constants' one home. Regenerate with `python3 tools/fixtures/clip-frames/generate_face_fields.py` after changing that block
(check_drift.py runs it, exact: atan2, exp and ln are fixed series there, never libm). C# `FrameFaceFieldsVectorTests` replays
every case within 1e-9 relative; there is no Mac twin, because the Mac reads Vision.

`frame-quad-cases.json` (`voxclip-frame-quad-cases/1`, ADR-R48 Windows, package W4) holds the Windows stand-in for Vision's
rectangle request: drawn grey frames (run-length encoded `value*count` tokens, with their SHA-256) and the quads drawn in them.
The frames are the Mac's drawn phone screen (`FrameAnalyzerTests.phoneScreen()`, words as bars) upright and turned 2.86°, a
laptop in slight perspective, a face-like frame with no rectangle, clutter, and pairs that pass and fail each of Vision's
settings (size, aspect, skew, confidence, at most 6). `quads` lists what the finder must find (corners and box within
`tolerance`, normalized), what it must not, and how many it may return; `scans` sends line boxes and quads through
`FrameScreens.detect` (from a frame's found quads, or listed quad boxes compared exactly). Regenerate with
`python3 tools/fixtures/clip-frames/generate_frame_quads.py` (check_drift.py runs it, exact: integers and Fractions only);
`tools/schemas/validate.py` checks it against `shared/schemas/frame-quad-cases.schema.json`. C# `FrameQuadVectorTests`
replays every case; there is no Mac twin, because the Mac reads Vision.

`analyze-frames-cli-cases.json` (`voxclip-analyze-frames-cli-cases/1`, ADR-R48, Windows package W5) pins `voxclip-cli
analyze-frames --json` across the twins. Each report case is a fabricated clip analysis (its words and word range, the source's
video facts, the sentence frames and opening scan in the Mac's JSON shape, the sheet's image sizes and byte counts, and the
whole-video pass's fields when it ran) and the exact bytes the command prints for it: sorted keys, unescaped slashes, Swift's
number text (`1` for 1.0, `1.234e-05` below 1e-4) and one final LF. `numbers` pins that number text on its own. The decisions
come from `generate_frame_decisions.py`, imported as it is; every face's centre has x = 0.5, so the cover's centring is exact
whether a Core calls hypot or sqrt. Regenerate with `python3 tools/fixtures/clip-frames/generate_analyze_frames.py`
(check_drift.py runs it, exact); `tools/schemas/validate.py` checks it against `shared/schemas/analyze-frames-cli-cases.schema.json`.
Swift `CLIAnalyzeFramesVectorTests` (through `FrameAnalyzerCLI.report` and `CLIExecution.printed`) and C# `AnalyzeFramesVectorTests`
(through `CliAnalyzeFrames.Report` and `FrameJson.MacText`) replay every case byte for byte.
