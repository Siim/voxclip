# ADR-R49: The export self-check — words, sync, loudness and captions, measured on the Mac

Date: 2026-11-08. Status: the engine is accepted (package v2-export-check: Core, Media and the CLI), and its Windows twin
(track/v2-win-export-check, §8). The review rows that show it (the lead's mockup, frame E: "✓ Every word as edited" and
three more per clip) wait for the user's approval on both platforms.

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
     alignment is `SpokenNumbers.align`, the one the take QA's transcript ratio reads too. No second normaliser or
     alignment was written.
   - **Numbers (2026-11-08).** A number matches however it is written (voice-lab §8.11): "three hundred dollar" heard as
     "$300" is three matched words, each mapped to the heard "$300" for its output time. A number heard as a numeral is
     never a cut-off. A numeral facing only another language's words (no spelled-number table) is unverified: no item,
     left out of `matched` and `total`, and counted in the result's `unverified`. The lead's first real run on the user's
     29.7 s clip had failed here (44 of 47, "three" reported cut off as "300", "hundred" and "dollar" as mismatches) on an
     export that was right.
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
8. **Windows (2026-11-08).** The same rules, the same JSON and the same exit codes.
   - **Core.** `ExportCheck`, `ExportCheckExpectation` and `CaptionSafeZones` (on the caption resolver's aspect class)
     replay both fixture files with their exact keys and counts. The words align on the C# `SpokenNumbers` and the take
     QA's homophone rule.
   - **Media.** `ExportChecker` reads both tracks' ranges, the frame rate and the frame through FFmpeg. It reads the audio
     for its known length with the Windows decoder under a bounded token, because `AudioDecoder.Read` pads with silence
     and never returns 0. The decode feeds the ADR-R47 meter and, with an engine, a 16 kHz mono PCM16 copy through the
     streaming form of the consent resampler (`SincResampler`). Caption boxes come from the render's caption track and
     title boxes from `EffectTitleLayout`.
   - **Local only.** Windows has no Apple speech. The engine is Whisper with the project's model when it is installed
     and verified, otherwise any installed, verified Whisper model, in the transcript's language and then auto. Without
     one, `words` and phrase sync are skipped. A provider is never called.
   - **CLI.** `check` and the autopilot's checks prepare the clip's render through the export command's own path
     (`PrepareExportAsync`).
   - **Not in the cross-platform E2E.** The ten E2E reports are export runs that `compare_e2e.py` compares, and the Mac
     E2E has no check case. The Windows command's check on a real file is a native test (`NativeCliCheckTests`).

## Measured

| What | Result |
| --- | --- |
| A 29.3 s 9:16 clip, a cold `voxclip-cli check` with the installed large-v3-turbo (2026-11-08) | **2.3 s** wall; the model hears it in 1.2–1.4 s |
| 6 s of speech, checked in-process | 0.76 s warm; 5.5 s for the first check, which loads the model |
| A failing run (a quiet source, a cut between "here" and "there", Highlight captions) | `there` cut off (heard "in"); −15.6 LUFS (the +12 dB boost limit stopped the gain short); 78 cards 0.043 into the bottom band |
| A passing run (the same speech 10 dB louder, "continually" cut, Bounce captions) | 77/78 words, sync ok, −14.01 LUFS and −0.87 dBTP, captions clear |

The engine's rules are in shared/fixtures/export-check/check-cases.json (schema `voxclip-export-check-cases/1`) and its
numbers in number-check-cases.json (`voxclip-export-check-number-cases/1`), which
tools/fixtures/export-check/generate_check_cases.py writes. The Mac Core and the Windows Core replay both.

## Consequences

- **Defaults that failed the check: resolved (2026-11-08, track/v2-safe-zones).**
  - The check found that Highlight at its default position reached 0.043 of the height into the 9:16 bottom band, and
    so did Bold, Bold+ (0.030), Minimal, Typewriter, Clean subtitle and Lower third. Measured on each style's deepest page,
    Editorial and Pill reached in too. The hook title's top sat at 0.102–0.106 of the height, inside the top band.
    Clean subtitle and Lower third also reached 0.020 into the 1:1 band, and six deepest pages reached up to 0.016 into
    the 16:9 one.
  - The lead moved the defaults clear of the bands with one rule in every shape, so the check agrees with every default.
    A style whose deepest page reached into a shape's bottom band has that shape's `aspects` y, ending the page at or
    above the band's start minus 1%. That is nine styles in 9:16, Clean subtitle and Lower third in 1:1, and those two
    with Minimal, Pill, Sing-along and Typewriter in 16:9. A 9:16 title's box starts at 13% and a bottom one ends by 77%.
    design.md §5.1 has the values.
  - `ExportCheckPlacementTests` is now a gate with no known issues: every bundled style at its default position, and
    its deepest page, clear every band in every shape, and each moved override is the lowest clear position.
- **What a cold `check` costs.** It loads the model each time. The autopilot loads it once for all its clips.
- **Reported but not warned.** A mismatched word next to a cut, heard as a longer word, is a mismatch but not a
  cut-off. For example, "speaking" was heard as "continuing" after "continually" was cut.
- **Owed.**
  - The review rows, once the user approves the mockup.
  - Windows on the VM: the FFmpeg reader and the whole `check` command on a real file (`NativeExportCheckerTests`,
    `NativeCliCheckTests`), and the check with the real local Whisper on x64 and arm64.
