# ADR-R48: Claude sees the picture — faces and screens measured on the Mac, small frames to the AI

Date: 2026-11-07. Status: accepted (package v2-eyes-1, part 1 of 2, and v2-eyes-2, part 2; the user approved the mockup
and the sending of small frames on 2026-11-07).

## Context

The agents that made the user's favourite clips looked at the footage (doc/agent-clipping-benchmark.md). They chose
opening frames and avoided "eyes half closed" and "looks drunk" frames. They placed the face in 9:16, blurred private
screens and picked covers. VoxClip's Claude was text-only, and the reframe's `faceX` was never measured.

The approved mockup adds four Make it postable rows: "Opens on a clear look at you", "9:16 follows your face", "Blurred
the phone screen at …" and "Cover frame chosen". A send line says what goes to the AI: "Claude read the clip's words and
24 small frames (one per sentence, 320 px) on your Claude plan. Faces were measured on this Mac." The user agreed that
small frames may be sent to the chosen AI. The cover is saved as `cover.jpg` next to the export and as the MP4's poster.

## Decision

1. **Computed locally, with Apple Vision and AVFoundation** (ai.md §19.1). For each sentence of a clip (at most 24) and
   for an opening scan (10 fps over ±0.6 s at its start), VoxClip decodes a 1,280 px frame and measures: the largest
   face's rect, capture quality, each eye's aspect ratio (closed below a mean of 0.20), head yaw and pitch; text boxes
   (positions only, the words are dropped); and screen-like rectangles holding dense text. Results are cached per source
   content key, pass and millisecond in the source's cache entry, so a cached frame is never decoded or looked at
   again, and clearing the cache drops them.
2. **Decisions are pure and local** (ai.md §19.2): the opening shift (0 or into the silence before the first word,
   never across a word), the face-follow crop for 9:16 and 1:1 (median, dead zone, slow pans), the cover score (eyes
   open, quality, centred, not mid-blink) and blur spans (screens merged over time). Claude gets them as facts and
   makes the editorial calls; VoxClip never lets a reply move a cut across a word.
3. **What is sent** (ai.md §19.3–§19.4): with a Make it postable request, the frame sheet — one 320 px JPEG per
   sentence, labelled with its time — and a compact text summary of the measurements per frame. No video, audio, file
   name, path or recognised text. 24 frames of the user's 4K clip are 314 KB, about 1,850 image tokens (Anthropic's
   estimate) and 900 summary tokens.
4. **Text fallback.** Every connector declares `images` in the shared catalogue. Anthropic, OpenAI, xAI, Gemini, Claude
   Code and Codex take images through their native inputs. Apple Intelligence, Ollama and LM Studio do not; they get the
   summary only, which the caller always puts in the instruction. Claude Code sends images only when its `--help` lists
   `--input-format` and `--verbose`, else text. A request without images is unchanged byte for byte.
5. **Claude Code's image input** is one stream-json user message (`--input-format stream-json`), which the CLI accepts
   only with `--output-format stream-json` and `--verbose`; the output's last `result` event is read as the `json`
   output was. Its tool, permission and session flags are unchanged. Codex uses `--image` with files from the private
   io folder.

## Consequences

- **Measured** (debug build, the user's 52 s 4K 10-bit HEVC DJI file, read locally, nothing kept): 24 sentence frames
  with the sheet in 0.82 s cold, the opening scan in 0.37 s, 7 ms from the cache; within the 2 s and 0.5 s targets.
  Decoding within 0.25 s of a sentence's time instead of one frame took the sentence pass from 2.4 s to 0.8 s.
- **Thresholds come from one person's footage**: eyes 0.20 (open 0.22–0.65, half-closed 0.17–0.19), quality 0.4. Vision's
  yaw was coarse (multiples of π/4) and pitch absent, so "facing the camera" was coarse too; resolved by the face pose
  section below (continuous yaw and pitch, 2026-11-08).
- **Faces can't be synthesised reliably for Vision**, so face handling is tested through the `FrameObserving` seam with
  stubs; real Vision is tested on a drawn phone screen and the repository's counter fixture.
- **Part 2 owes** the planner request with the sheet and summary, the four review rows, the send line, the cover export
  (`cover.jpg` and MP4 artwork) and Claude mode's use; **Windows owes** the twin (ai.md §19.5).

## Part 2 (track/v2-eyes-2)

- **Off the critical path.** One frame per sentence of the whole video is looked at as soon as the transcript exists,
  beside Find Clips; each clip's plan takes its ≤ 24 frames from that pass and starts its opening scan beside the request.
  Measured: 202 frames of a 1080p recording in 2.07 s, a clip's frames from the pass in 1–3 ms, an opening scan 0.08–0.54 s.
- **The request and reply** (ai.md §19.6): the summary always, the 320 px images only to a connector that takes them,
  screens `B1…` and covers `C1…C3` named; the reply's `frames` choices; unknown ids fall back. API-key images are priced
  before the send and the run's cap covers them (`shared/catalog/llm-image-prices.json`).
- **Stored in the project:** the opening as the clip's `leadInSeconds` (never across a word), the face as
  `clipControls.reframe` (mode `face`, a static centre the 9:16 and 1:1 crops follow), the cover as
  `clipControls.coverSeconds`; blurs are clip effects. The cover is exported as `<name>-cover.jpg` and MP4 `covr` art
  (not `cover.jpg`: several clips share a folder).
- **Thresholds, evaluated** on three of the user's recordings: the eye line 0.20 holds. Quality 0.4 does not hold as an
  absolute line on dim 1080p footage (0.30–0.44 throughout): two openings moved 0.4–0.5 s between equally clear frames.
  A relative rule (move only for shut eyes, a turned face or a clearly worse frame) is the next step.
- **Windows** keeps the fields losslessly, honours the lead-in and the crop centre, and owes the rest (ai.md §19.5).

## The cover's write (track/v2-cover-box, 2026-11-08)

- **VoxClip writes the MP4's cover art itself, on every macOS.** `AVAssetWriter` embeds an iTunes `covr` item on macOS
  27 and never on macOS 26 (13 variants on the hosted 26.7.2 runner, CI 42472116651), so no AVFoundation setting fixes
  26. Core `MP4CoverArt` (pure, byte-level) puts the JPEG in `moov/udta/meta/ilst/covr`, as AtomicParsley does: it
  replaces an existing `covr`, keeps every other box byte for byte, moves every `stco`/`co64` entry by the growth when
  `moov` comes first (an `stco` that would overflow becomes a `co64`), and refuses fragmented or truncated files
  untouched. The exporter streams it over its `.partial` before the rename and no longer adds the AVFoundation item.
- **The cover is extra.** A failed embed keeps the export and the JPEG beside it and logs one line.
- **One behaviour, two platforms.** The C# Core has the same writer, replaying shared/fixtures/cover-art; Windows wires
  it into its exporter with its cover export (doc/publishing.md §7).

## Face pose (track/v2-face-pose, 2026-11-08)

- **The request set.** Landmarks run without a face-rectangles request use Vision's internal revision-2 detector ("creating
  VNFaceBBoxAligner from VNFaceDetectorRevision2"): yaw is 0 or ±π/4 and pitch is nil, so `facesCamera` meant "yaw rounded
  to 0" and looking down never counted. `VNDetectFaceRectanglesRequest` revision 3 now runs in the same `perform` as the
  text and rectangle requests, and its largest face is the input of the landmarks and capture-quality requests. Yaw and
  pitch are continuous and the revision-2 line is gone. No committed or drawn face (the Noto emoji faces, a CoreGraphics
  face) is detected by Vision, so the pose was checked on the user's recordings; a unit test pins the revision.
- **Evaluation** (release CLI, before = 47fe62d2, after = this package; three of the user's recordings, read locally,
  numbers only): R1, 1080p, 348 s, seated in a car at dusk; R2, 4K, 53 s, handheld walking selfie from below; R3, 1080p,
  two 28–30 s exported segments of one evening car recording. 885 frames (whole-video passes at one frame per word, the
  clips' sentence frames and opening scans).

  | | R1 | R2 | R3 (two segments) |
  |---|---|---|---|
  | yaw p5 / p50 / p95 (rad) | −0.09 / +0.09 / +0.24 | −0.02 / +0.21 / +0.43 | −0.45…−0.54 / −0.05…−0.04 / +0.09 |
  | pitch p5 / p50 / p95 | −0.03 / +0.06 / +0.14 | −0.34 / +0.07 / +0.28 | −0.13…−0.19 / +0.15…+0.17 / +0.22…+0.23 |
  | median pitch of the pass | +0.07 | +0.18 (13 frames; +0.07 at one per word) | +0.15 / +0.17 |
  | frames no longer facing / now facing | 8 / 0 of 617 | 23 / 1 of 109 | 1 / 0 of 159 |
  | capture quality shift, mean (max) | +0.012 (0.062) | −0.019 (0.267) | +0.018 (0.067) |
  | eye ratio shift, mean (max) | −0.008 (0.040) | −0.001 (0.229) | −0.006 (0.041) |

- **The facing rule.** |yaw| ≤ 0.35 rad, and pitch within 0.35 rad of the recording's median pitch (the whole video's pass,
  or the clip's own frames without one). Yaw stays at 0.35: the R1 frames at 0.28–0.33 look into the lens with the head
  slightly turned, and most frames past 0.35 (R2's handheld turns, R3's glances away to the side) have the
  eyes off the lens (two R2 frames look into it from a three-quarter turn). The pitch limit is on the difference: R3's frames 0.21–0.30 below the baseline are clear looks into
  the lens (0.25 or 0.30 would reject them), and every frame past 0.35 is the head tipped back with the eyes up (R1, R3)
  or a chin-up shot from a camera held low (R2). An absolute 0.35 would have rejected camera height on studio footage
  (rev-3 pitch +0.1 to +0.2 there, 7.5 % of frames past 0.35); on these recordings the two rules differ on 0–6 frames each.
- **Decisions on 19 clips.** Two openings move: R1's clip started on the head tipped back, eyes up at the car roof, and
  now starts 0.5 s earlier on a more level face with the eyes toward the lens (heavy-lidded, quality 0.31); R2's started
  on a head turned 0.37 rad with the eyes down, and now starts 0.5 s earlier on a less turned face looking at the lens.
  Both are better. Of seven covers that change, R2's moves from a turned, downcast frame to one looking at the lens; the
  other six swap between frames of the same look (eyes on the lens, level head), on capture-quality differences of
  0.01–0.03.
- **Thresholds re-checked.** The eye line 0.20 holds: the eye ratio moves −0.008 on average, and the 23 R1 frames that
  cross the line all sit within 0.02 of it (19 now closed, 4 now open). They are heavy-lidded frames in a dim car, where
  half-closed counts as closed. The opening's quality margin (0.15) and floor (0.25) hold: quality moves at most ±0.02 on
  average per recording and 0.07 at the 95th percentile, no opening moved on quality, and the dim R1 frames stay at
  0.29–0.41 (5th–95th). One R2 frame moved 0.27 (a wide-eyed glance up, judged turned away either way).
- **Cache.** `analysis-v2.json` replaces `analysis-v1.json`; old files are ignored and go with the cache's own eviction.
- **Windows** calibrates against this Mac (post-fix): the face request set and the macOS build are in
  apps/windows/CONTRACTS.md.
- **Windows** has the pure decisions in C# Core `Domain/Frames` (W1, track/v2-win-frames-core), replaying
  shared/fixtures/clip-frames/decision-cases.json and face-facing-cases.json with the Mac; the analyzer and wiring (W3–W7) are owed.
- **Windows** has the face models' catalogue (`shared/catalog/frame-models.json`: YuNet + Face Mesh V2, hash-pinned, off until the
  calibration and the licence decision) and the pure maths from their outputs to these fields (W2, track/v2-win-frames-w2):
  eye ratios mapped to Vision's scale, yaw and pitch mapped to revision 3's (pitch negative with the head tipped back), and a
  gated capture quality, with provisional constants in the catalogue until W7.
- **Windows** sees text and screens with `Windows.Media.Ocr` line boxes plus a pure quad finder on Vision's rectangle settings, into
  `FrameScreens.detect`, and skips both on opening-scan frames (W4, track/v2-win-frames-w4); the PP-OCRv4 fallback waits for W7's screen evaluation.
- **Windows** analyzes frames as the Mac does, behind a face seam (W5, track/v2-win-frames-w5): FFmpeg lanes at 1,280 px with the Mac's
  tolerances, the per-millisecond cache, 320 px sheet JPEGs, the whole-video pass and `voxclip-cli analyze-frames` with the Mac's bytes; with
  no face models installed nothing is measured (exit 7), never an invented "no face". W3, W6 and W7 are owed.
- **Windows** bundles both face models in the app, pinned and hash-checked with their LICENSE and NOTICE (the user's decision, 2026-11-09, accepting YuNet's WIDER FACE training-data risk), and measures faces with them (W3, track/v2-win-frames-w3); they stay off until W7's calibration passes.

## Windows calibration (W7, track/v2-win-frames-w7, 2026-11-09)

- **Set.** 37 people from US federal public-domain NASA video (images.nasa.gov; no JPL, ESA or partner productions):
  studio and live interviews, crew profiles, space-station downlinks (two of them wide shots with faces about 55 px wide),
  messages and science interviews. That is 5,620 frames at 10 fps and 1,280 px, of which Vision calls 583 eyes closed.
  16.5 % of the faces are under 100 px wide, 3.5 % are dim (crop luma under 70) and four subjects wear glasses. The set has
  no handheld or phone footage that could be verified as such. The frames are split by person: 24 fit, 13 held out.
  `tools/frames/calibrate/manifest.json` pins each frame's SHA-256. No frame is kept.
- **Reference.** This Mac's production `AppleFrameVision` (macOS 27.0.1, 26A434, the post-fix request set:
  `VNDetectFaceRectanglesRequest` revision 3, then landmarks and capture quality on its largest face). The Windows side is
  the shipped C# path, checked frame by frame against `OnnxFrameFaces`.
- **Fit** (the study's order, fit split only): eye ratio 0.7446·mesh + 0.069; yaw 1.1694·mesh − 0.0004; pitch
  −0.9019·mesh + 0.0263; pitch0 0.11; w0 0.2739, w1 0.1218, w2 0.2468; a five-point quantile map. The gates stay the study's,
  because only one fit face falls past any of them.
- **Fails.** On the held-out people:

  | Line | Needs | Got |
  |---|---|---|
  | eyes | ≥ 0.98 | 0.960 |
  | facing | ≥ 0.95 | 0.980 (passes) |
  | quality at 0.25 | ≥ 0.95 | 0.817 |
  | quality at 0.40 | ≥ 0.85 | 0.823 |
  | opening | ≥ 0.95 | 0.794 |
  | cover regret p90 | ≤ 0.06 | 0.074 |

  The catalogue stays `enabled: false`, and the calibration stays `provisional` so that it can't be switched on. It still
  holds the constants and every number, pooled and per person.
- **Why.**
  - **The eye line can't reach 0.98 with a linear map on this set.** The best threshold scores 0.949 on the fit split and
    0.965 held out. The misses sit on small, soft faces, where Vision itself is unsteady: it calls eyes closed in 76 % of a
    wide-shot astronaut's frames. On faces from 100 px the eyes agree 0.978.
  - **Vision's quality is set per person and per shot,** as Risk 2 of the study said. Small in-station faces score 0.18–0.37
    and studio faces 0.45–0.77. The formula's eyes, facing and sharpness terms don't carry that offset (pooled Pearson 0.58 on
    the fit split, 0.11 held out). Fitting the sharpness range raised the fit split's agreement but lowered the held-out
    people's, so it stays the study's.
  - **On one held-out person, YuNet's largest box is not the speaker.** In a Demo-2 interview, a face in a graphic beside the
    speaker is taken in 150 of 220 frames, and Vision doesn't see it. Without such frames, quality agrees 0.891 at 0.25 and
    0.897 at 0.40, and the opening 0.878.
- **What would change it:** a size-aware eye state on Windows, for example eyes unknown under about 100 px; a quality term for
  face size and person; and a check that the measured face is the speaker. Each is a code change to the Windows face path,
  which is outside this package. Rerun with `tools/frames/calibrate` (its README) after any of them, or when macOS or the
  request set changes.

## Windows calibration, second pass (W8, track/v2-win-frames-w8, 2026-11-09)

The W7 set, split and reference, rerun after three Windows-side changes. The shared decisions are unchanged.

- **The speaker's face, not the largest (`SpeakerFace`).** The face path reads YuNet's boxes in this order: outside the frame's
  screens (the screen scan's text-dense rectangles and clusters) first, then confident detections (YuNet score ≥ `speakerScore`),
  then the larger. A weak box counts as a face only once the mesh confirms it. `speakerScore` 0.85 is the fit split's lowest
  speaker score (0.864) rounded down to 0.05. No other fit box reaches it; the non-speakers in the whole set score 0.60–0.79.
  The analyzer now scans screens before faces and passes them on; the calibration has no OCR, so only the score rule acts here.
  - W7's "face in a graphic" is the first segment of the Demo-2 subject (s25, 97–112 s): the interview's title card. YuNet's
    largest box is the dark helmet face behind its text (score 0.77). Vision, and now Windows, take the portrait photo beside it.
    That segment is a still card, which the manifest's own rules exclude; it stays, because the split is W7's.
  - Raw quads can't serve as the screen rule: 14 % of fit speakers sit inside a larger quad (a window, a door, a poster).
  - Face counts now agree with the Mac on 5,610 of 5,620 frames.
- **Small faces report their eyes unknown.** Below `eyesFromWidth`, at 1,280 px, the face has null eye ratios, as the Mac reports a
  face without eye landmarks. The capture quality still uses the measured eyes. Fit: the top of the highest 20 px band of fit faces,
  with at least 30 faces, whose eye agreement is below the fit split's overall 0.948. That is 40–60 px (439 faces, 0.781) and
  60–80 px (61 faces, 0.918), so 80 px. The fit split has one face from 80 to 100 px, so it can't place the cut there; held out,
  that band agrees 0.885.
  - **Vision is unreliable there too.** On fit faces under 60 px, Vision calls the eyes closed in 40.5 % of frames; on faces of
    100 px or more, it does so in 4–11 %. The Mac should probably treat faces under about 80 px as unknown as well; this package
    doesn't change the Mac.
  - **How the acceptance counts an unknown.** The eyes line counts the frames where both platforms state open or closed. A frame
    where Windows says unknown and Vision gives a value is left out of it and reported as `eyesUnknown`. `eyesStrict` counts such
    a frame as the decisions read it: not an open look, so it agrees with Vision's "closed" and disagrees with Vision's "open".
    The opening and cover lines run on every frame, so they carry what an unknown costs.
- **Quality per recording: tried, not applied.** Per-recording offsets (the recording's median moved toward a fixed level by a
  strength 0–1), a per-recording quantile remap and a recording-relative sharpness term were tried. Each lowered the agreement on
  the fit split as well as held out, so the fit chose strength 0 and the app applies none. The reason: Windows' per-recording level
  tracks Vision's (correlation 0.54 fit, 0.70 held out), so pinning it removes information. The misses that remain are recordings
  whose whole level sits on a line on both platforms (s17 and s19, in-station mid shots: Vision medians 0.31 and 0.22).
- **Result on the 13 held-out people** (needs → W7 → speaker → speaker and small faces):

  | Line | Needs | W7 | Speaker | Shipped (both) |
  |---|---|---|---|---|
  | eyes | ≥ 0.98 | 0.960 | 0.960 | 0.968 (260 unknown) |
  | facing | ≥ 0.95 | 0.980 | 0.980 | 0.980 |
  | quality at 0.25 | ≥ 0.95 | 0.817 | 0.900 | 0.900 |
  | quality at 0.40 | ≥ 0.85 | 0.823 | 0.906 | 0.906 |
  | opening | ≥ 0.95 | 0.794 | 0.890 | 0.887 |
  | cover regret p90 | ≤ 0.06 | 0.074 | 0.074 | 0.455 |

  Quality at 0.40 now passes, as does facing. Eyes, quality at 0.25, the opening and the cover still fail, so the catalogue stays
  `enabled: false` and `provisional`.
- **Why the rest fails.**
  - **Cover:** with eyes unknown under 80 px, a wide shot has no open-eyed Windows frame, so `CoverFrame.pick` has nothing to
    choose, and the line counts the Mac's whole score as regret. That is a real loss (no cover from frames on such footage), not an
    artefact. Without the small-face rule, p90 is 0.074.
  - **Eyes:** 0.968 even with small faces out, and 0.978 on faces from 100 px. Away from the line (Vision's ratio more than 0.02
    from 0.20), eyes agree 0.983. Half of the misses are within 0.02 of the line. There, Vision's state flips between consecutive
    frames (100 ms apart) in 25–33 % of pairs, and its ratio moves a median 0.009 (p90 0.03) between frames even with the eyes
    clearly open. The mesh-to-Vision offset also varies by person (±0.05).
  - **Quality at 0.25 and the opening:** the in-station mid shots (s15, s17, s19), whose whole level sits near 0.25 on both
    platforms. From 100 px, held out, quality at 0.25 agrees 0.965, at 0.40 0.913, and the opening 0.936.
- **Constants** in the calibration block: `speakerScore` 0.85 and `eyesFromWidth` 80. The W7 maps and weights are refitted
  unchanged. `evaluation` adds `steps` (the table above, fit and held out), `eyeBands`, `speaker`, `recordingOffset` and the eyes
  counts. Setting `eyesFromWidth` to 0 turns the small-face rule off.
