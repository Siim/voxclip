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
  yaw is coarse (multiples of π/4), so "facing the camera" is coarse too. An evaluation set is owed before the rows ship.
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
