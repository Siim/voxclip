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
`python3 tools/fixtures/clip-frames/generate_face_facing.py` (check_drift.py runs it). Swift `FaceFacingVectorTests`
replays every case; the Windows replay is owed.
