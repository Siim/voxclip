# ADR-R49: The export self-check — words, sync, loudness and captions, measured on the Mac

Date: 2026-11-08. Status: the engine is accepted (package v2-export-check: Core, Media and the CLI). The review rows that
show it (the lead's mockup, frame E: "✓ Every word as edited" and three more per clip) wait for the user's approval.

## Context

The agents that made the user's favourite clips checked every export before they handed it over
(doc/agent-clipping-benchmark.md, item 6). They checked that picture and sound were in sync, transcribed the export again
and compared it word for word with the edit, and measured its loudness. VoxClip's exports are right by construction, but
nothing shows it, and a Claude Code or Codex harness driving `voxclip-cli autopilot` can't tell a good export from a bad one.

## Decision

1. **Four checks, each with a status.** `ExportCheck` (Core) returns one result each for `words`, `sync`, `loudness` and
   `captions`: `ok`, `warning`, or `skipped` with the reason. Each finding carries an output time (seconds from the
   export's first frame). The checks report only what they measure. Sync never claims the lips match.
2. **Words.**
   - **What is expected.** `ExportCheckExpectation` takes the expected words from the render's own timeline. On the
     Voice Lab path these are the output plan's words: each Rewrite's or revoiced phrase's new words at their placed
     times, with the kept source words mapped around them. Otherwise they are the clip's kept source words through the
     edit plan, corrections applied. All times are divided by the clip's speed. A bleeped or muted word isn't heard, so
     it isn't expected. A kept filler is optional, because Whisper drops "um" and "uh".
   - **Matching.** Words are aligned on `VoiceLabTakeQuality.tokens`. A heard word that sounds like an expected word
     (`soundsAlike`) is written as that word: "Claude" heard as "cloud" matches, "deals" heard as "details" does not. The
     alignment is `VoiceLabTakeQuality.alignment`, the longest common subsequence the take QA's transcript ratio now reads
     too. No second normaliser or alignment was written.
   - **Mismatches and cut-offs.** Each unmatched word is reported with what was heard in its place. A **cut-off** is a
     word next to a cut, or at a clip edge, that is missing or heard as one shorter, different word. Cut-offs are reported
     separately from mismatches. The edge test is inclusive, because a recognizer's words touch and a cut between them
     falls on that boundary.
   - **Status.** The check warns on any cut-off, on any wrong word inside a revoiced or rewritten phrase, or when fewer
     than 90% of the words match (the take QA's threshold). A lone mismatched source word is reported but stays `ok`: the
     recording is right by construction, and that miss is the recognizer's.
3. **Sync.**
   - **Tracks.** The audio and video tracks must start and end within one frame of each other. The ranges are read from
     the file.
   - **Phrases.** For each revoiced or rewritten phrase, the median of its matched words' heard-minus-placed start offsets
     must lie within **0.30 s**. A phrase with no heard words warns, because its placement can't be measured.
   - **Tolerance evidence.** Whisper large-v3-turbo's word starts were measured on the four shared LibriSpeech fixtures
     (shared/fixtures/voice-lab/speaker). Each fixture was placed after 0.37, 1.13 and 2.71 s of silence, and two pairs
     were set back to back with gaps of 0.25 s and 0.9 s. Against each fixture transcribed alone, shifted by its known
     placement, the 243 matched words had a median error of 0.000 s, p95 0.045 s, p99 0.205 s and a maximum of 0.240 s.
     Every phrase's median was within 0.010 s. A one- or two-word phrase's median is a single word's error, so the
     tolerance covers the largest single-word error with margin.
   - **What sync doesn't measure.** The placed times are ElevenLabs' alignment, which was not measured here.
4. **Loudness.** The export's audio is decoded and measured by the shared ADR-R47 meter (`SocialLoudnessMeter`, the code
   that set the gain). The target is −14 LUFS within ±1 LU, and a true peak of at most −1 dBTP plus a **0.2 dB** meter
   tolerance. AAC rings past the PCM's ceiling on a limited transient: ADR-R47's test decoded −0.97 dBTP, FFmpeg read −0.9
   on its benchmark, and this check's first real run decoded −0.895. An export with loudness off is `skipped` ("Loudness
   is off for this export"), and so is one without an audio track. Nothing above the gate warns as silent.
5. **Captions.**
   - **What is checked.** Every caption card's box and every title's box must lie outside the frame's safe-zone bands.
     The bands are `CaptionSafeZones`: 9:16 top 12% and bottom 22%, 1:1 bottom 12%, 16:9 bottom 10%. They are the bands
     the stage drew; design.md §5.1 now writes all three, and the stage's guides read the same definition.
   - **Where the boxes come from.** A card's box is the layout's own geometry: the page's visual rect after the clamp,
     with its boxes and emoji. A title's box comes from the compositor's `titleLayout`. No pixels are read.
   - **One finding per run.** A run of cards at one depth in a band is one finding, with a count.
   - **What is left out.** 9:16's right-hand button column stays a stage guide only, because captions sit centred across
     the frame.
6. **Local only.** `ExportChecker` (Media) transcribes with the project's engine when it is Whisper or Apple speech and
   ready. Otherwise it uses Whisper with an installed model for the transcript's language. With neither, `words` and
   phrase sync are skipped ("No local transcription model"). It never calls ElevenLabs, and nothing leaves the Mac.
   - **Threading.** The audio decodes run on a dedicated queue behind a continuation. The engine's model work runs with
     a dedicated queue as the task's executor. Neither runs on the cooperative pool (`FrameAnalyzer.look`).
7. **CLI.**
   - **`check`.** `voxclip-cli check --project <path> --clip <n|id> <export.mp4> [--json]` rebuilds the clip's render
     through the export's own preparation (`CLIWorkflow.prepare`) and checks the file. It exits 0 when every check is ok
     or skipped and **8** when any warns.
   - **`autopilot`.** Each exported clip is checked as soon as it is written. The checks run one after another (one local
     engine) beside the other clips' plans and exports, so the first clip is never delayed. Each clip's JSON gets a
     `check` object, `--timings` gains a `check` stage per clip, and `--no-check` turns it off. The autopilot's exit
     status doesn't change: a harness reads `check.passed`.

## Measured

| What | Result |
| --- | --- |
| A 29.3 s 9:16 clip, a cold `voxclip-cli check` with the installed large-v3-turbo (2026-11-08) | **2.3 s** wall; the model hears it in 1.2–1.4 s |
| 6 s of speech, checked in-process | 0.76 s warm; 5.5 s for the first check, which loads the model |
| A failing run (a quiet source, a cut between "here" and "there", Highlight captions) | `there` cut off (heard "in"); −15.6 LUFS (the +12 dB boost limit stopped the gain short); 78 cards 0.043 into the bottom band |
| A passing run (the same speech 10 dB louder, "continually" cut, Bounce captions) | 77/78 words, sync ok, −14.01 LUFS and −0.87 dBTP, captions clear |

The engine's rules are in shared/fixtures/export-check/check-cases.json (schema `voxclip-export-check-cases/1`), which
tools/fixtures/export-check/generate_check_cases.py writes. The Mac Core replays it; the Windows twin owes the replay.

## Consequences

- **Defaults that fail in 9:16 (reported to the lead, not moved).**
  - The default caption style, Highlight, at its default position reaches 0.043 of the height into the 9:16 bottom band.
    So do Bold, Bold+ (0.030), Minimal, Typewriter, Clean subtitle and Lower third.
  - The hook title's top sits at 0.102 of the height for one line and 0.106 for three lines, inside the top 12% band.
  - Both defaults clear the bands on 1:1 and 16:9. `ExportCheckPlacementTests` records the two 9:16 defaults as known
    issues, which fail once the defaults move.
  - Until they move, a 9:16 export with Highlight or a hook title warns on `captions`, and `check` exits 8 for it.
- **What a cold `check` costs.** It loads the model each time. The autopilot loads it once for all its clips.
- **Reported but not warned.** A mismatched word next to a cut, heard as a longer word, is a mismatch but not a
  cut-off. For example, "speaking" was heard as "continuing" after "continually" was cut.
- **Owed.**
  - The review rows, once the user approves the mockup.
  - The Windows twin: the engine, its replay of the vectors, and the CLI.
