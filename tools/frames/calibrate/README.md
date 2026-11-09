# Windows faces calibrated against the Mac (W7)

On Windows, VoxClip measures faces with YuNet and Face Mesh V2 (`OnnxFrameFaces`). The Mac uses Apple Vision. The shared
decisions read both platforms' numbers with the same lines: eyes closed below 0.20, a good capture from 0.4, an open look
from 0.25, the opening's 0.15 margin, and facing within 0.35 rad. The Windows numbers are mapped onto Vision's scale by the
constants in the `calibration` block of `shared/catalog/frame-models.json`, and this tool fits those constants. It then checks
them on held-out people and writes the result back. ADR-R48 (Windows calibration) has the outcome.

## What is here

| File | What it is |
|---|---|
| `manifest.json` | The frames. US federal public-domain NASA video from images.nasa.gov only: nasa_id, the exact asset URL, each segment's seconds and fps, and every decoded frame's SHA-256 (raw RGB24 rows at 1,280 px on the long side, frame k at start + k / fps). 37 subjects (one person each), split by subject into `fit` (24) and `validation` (13). |
| `calibrate.py` | `measure`: fetch, decode, hash and run both pipelines, one subject at a time. `fit`: fit on the fit split and report the acceptance numbers. `write`: write the catalogue's calibration block. `pin`: record the hashes of new segments. |
| `windows-runner/` | The Windows half: a .NET 10 console app on the shipped C# steps (YuNet input, `YuNetDecoder`, `RotatedCrop`, Face Mesh V2, `FaceCropStats`, `FaceMeshFields.Measure`). It writes the raw numbers before the catalogue's maps, and stops if any frame differs from `OnnxFrameFaces.Faces` itself. |
| `apps/macos/Tests/VoxClipMediaTests/Frames/CalibrationVisionHarness.swift` | The Mac half: the production `AppleFrameVision` on the same bytes. It runs only when `VOXCLIP_CALIBRATION_FRAMES` names a job and is skipped everywhere else. |
| `test_calibrate.py` | Shows that the fit is deterministic and recovers known maps, using a fixed synthetic paired set (numbers only). |

The repository never holds frames, faces or video. NASA's guidelines give identifiable people publicity rights and say some
NASA media embeds third-party material. The frames are decoded into the work folder (`VOXCLIP_CALIBRATION_WORK`, default
`/tmp/voxclip-w7`) one subject at a time, fed to both pipelines and deleted. Only the paired numbers stay in
`<work>/paired/*.jsonl`. A frame whose bytes differ from its pin is refused, which happens when NASA re-encodes an asset or
ffmpeg's output changes; re-pin and re-run in that case.

The manifest's segments were chosen by scanning candidate videos with the face detector. Each one is a single continuous shot
of its subject, and each was checked by eye. Rejected: JPL, ESA and partner productions; still photos, b-roll and title cards;
anything showing a child; school hosts' feeds inside downlinks; and wide shots of several people.

## Rerun (when macOS, Vision's request set or the catalogue changes)

Needs ffmpeg/ffprobe (6.1.1 pinned the hashes), Python 3 with numpy and scipy (no other packages), Xcode, and the .NET 10 SDK.
Run on the Mac, not while the frames would contend with other work: about 25 minutes for 5,620 frames, and 15 GB free disk.

```sh
cd apps/macos && VOXCLIP_NO_KEYCHAIN=1 swift build --build-tests
cd ../../tools/frames/calibrate/windows-runner && dotnet build -c Release -m:1 -nodeReuse:false -p:UseSharedCompilation=false
cd ../../../..
python3 -I tools/frames/calibrate/calibrate.py measure     # resumable: subjects with numbers are skipped (--again to redo)
python3 -I tools/frames/calibrate/calibrate.py fit         # prints every number, pooled and per held-out subject
python3 -I tools/frames/calibrate/calibrate.py write       # enabled: true and status: calibrated only if every line passes
python3 -I tools/fixtures/clip-frames/generate_face_fields.py
python3 -I tools/models/face_golden_reference.py shared/fixtures/frame-faces/*.png   # re-pin OnnxFrameFacesTests' Goldens
python3 -I -m unittest discover -s tools/frames/calibrate -p "test_*.py"
```

Then update the C# constants in `FrameModelCatalogTests` and the goldens in `OnnxFrameFacesTests`, and run both
`check_drift.py` scripts, `tools/schemas/validate.py` and the Windows Core and Media suites. Delete the work folder at the end.

## The fit (the study's order, fit split only)

1. **(a)** The eye-ratio map: least squares of Vision's mean eye ratio on the mesh's mean ratio.
2. **(b)** The yaw and pitch maps: least squares onto Vision revision 3's angles.
3. **(c)** `pitch0` on a 0.01 rad grid, with the quality weights `w0`, `w1`, `w2` by non-negative least squares at each grid
   point. The least residual wins.
4. **(d)** The gates. A gate is fitted only when at least 30 fit faces lie past its fixed value; otherwise the study's fixed
   gate stays.
5. **(e)** The quantile remap: the Windows score's p10, p25, p50, p75 and p90 onto Vision's.

These stay as in the study: the eyes-open span (0.12 to 0.26), the facing span (0.6) and the sharpness range (30 to 400).
`SHARPNESS_GRID` can try a range, but a fitted range lowered the held-out agreement on 2026-11-09. Frames where the two face
boxes overlap less than 0.3 are two different faces, and they stay out of the fit.

## Acceptance (validation split, through the shared decisions)

The decisions are `tools/fixtures/clip-frames/generate_frame_decisions.py`, the reference that both Cores replay byte for
byte. Every acceptance line runs on every validation frame. Facing is judged against each platform's own per-video median
pitch, as the app does.

| Line | Needs |
|---|---|
| Eyes open or closed | ≥ 0.98 |
| Facing the camera | ≥ 0.95 |
| Quality on the same side of 0.25 | ≥ 0.95 |
| Quality on the same side of 0.40 | ≥ 0.85 |
| The opening frame | ≥ 0.95 |
| Cover regret p90 | ≤ 0.06 |

The opening frame line counts `OpeningFrame.choose` on every 10 fps frame that has 0.6 s either side: the scan is the 13
frames around it, and the silence runs back 0.6 s. For cover regret, `CoverFrame.pick` runs on consecutive 24-frame windows,
and the regret is how much worse Windows' pick scores than the Mac's under Vision's own scoring.

The report also gives two diagnostics: the validation split without faces under 100 px, and without different-face frames.
