# Agents vs VoxClip: how agents made the clips, and how fast VoxClip is

Status: research note, 2026-11-07. It compares the user's agent-made clips (no VoxClip) with VoxClip on the same kind of footage, and lists what VoxClip still needs to be the app people want to install.

## Summary

- **VoxClip is already much faster at the mechanical work.** On a 29-minute 1080p recording, local transcription took 53 s. A captioned 34 s clip, with fillers cut and pauses tightened, rendered in under 7 s in either shape. A 4K 10-bit HEVC source is no slower. None of this needs any setup, and no cut can clip a word, because cuts follow word timings.
- **The AI decisions take most of the time.** Finding clips in the 29-minute transcript took 77 s with Opus 5.5 at extra high effort, and Make it postable takes 74 s (median) per plan. About 80% of VoxClip's time from a video to a postable clip is spent waiting for Claude.
- **Total time.** A 29-minute file takes about **4–5 minutes** to reach three postable clips in Claude mode. The agent took about **12 minutes** to its first CapCut projects, after finding and fixing its own tools, and then hours of rounds with the user.
- **The agents did more.** They looked at the picture, worked across several recordings, added B-roll and screenshots, made editable CapCut projects, normalised loudness and checked their own exports. VoxClip's Claude never sees a frame. These are the gaps that matter for "wow" (see the last section).

## How the agents made the clips

### Session 1: Osmo Pocket clips (Codex, GPT-6 astra at ultra effort, 2026-09-10/11)

Prompt (13:05): "check out some of the most interesting latest videos from my Osmo pocket four … make some interesting edits and clips."

| Time | Step |
|---|---|
| 13:05 | Lists the camera (`/Volumes/Pocket4/DCIM`), checks for ffmpeg, ffprobe and Python, and opens CapCut through computer use. |
| 13:05:41 | Starts three sub-agents. **review_footage** makes contact sheets (frame grids rendered with ffmpeg and PIL) and *looks at them*. **transcribe_recent** runs local openai-whisper (torch on MPS). **capcut_builder** writes CapCut draft JSON directly. |
| 13:06–13:08 | Fixes its tools: finds a Whisper install, works around an OpenMP/numba crash (`NUMBA_THREADING_LAYER=workqueue`), and copies media off the card. |
| 13:10–13:14 | Reads the transcripts, picks segments, and writes edit specs (word-timed cuts, filler removal). |
| 13:14:42 | `prepare_edits.py` renders the selected segments with the Mac's hardware encoder. |
| 13:17:34 | Installs the first CapCut projects. **About 12 minutes from prompt to first clips.** |
| …to 00:44 next day | About 15 clips over many rounds of feedback: portrait vs landscape, keep the demo unblurred, use Roboto Black, a better opening frame ("eyes half closed"), a washed-out night look, music choice, blurs, ratings, tweet text, and posting order. |

### Session 2: the October clips workspace (`~/Desktop/clips`, Oct 15–27)

The agent turned its method into reusable tools: `transcribe_elevenlabs.py`, `edl.py`, `render_clip.py`, `prep_recording.py`, `make_music.py`, `audit_cuts.py` and `capcut/build_capcut_draft.py`. Its `START HERE.md` describes the result:

- **Selection.** It keeps only the strongest one or two arguments from a 9-minute recording and drops tangents it names explicitly.
- **Captions.** Word-by-word Roboto Black with a black outline; the spoken word highlights yellow; each card pops in.
- **Hook line** at the top: yellow on a dark box.
- **Music.** An ElevenLabs Music bed per clip, about 14 LU under the voice, with fades.
- **Tight jump cuts**, with framing that switches between wide and 12% closer at each new thought, not on every cut.
- **Inserts timed to words.** Game footage on "flight simulator game", a 1997 → 2026 poster, Play Store screenshots as cards, all on their own "Inserts" track.
- **QA on every export.** It checked that picture and sound stay within 0.3 ms, re-transcribed each export and compared it word for word with the edit, and confirmed about −16 LUFS, H.264 1080p30.
- **Delivery.** Editable CapCut projects with exported MP4s and SRTs, suggested post text, and a posting order.

### What cost the agents time

- Building and repairing tools on every run: the Whisper environment, OpenMP, CapCut's sandbox ("File not accessible" until the media was moved inside `~/Movies`), and 20–30 KB of scripts written from scratch.
- Computer use in CapCut (clicks and screenshots) to open, check and export.
- Long reasoning at ultra or extra high effort for every decision, including mechanical ones.

## VoxClip, measured (2026-11-07)

Setup: MacBook (Apple silicon), release `voxclip-cli` at a2d5fe94, an isolated data directory, and the installed whisper.cpp large-v3-turbo model.

The 29-minute test file was the 1080p60 0030 recording (5:48) joined five times without re-encoding. Clip finding used the user's Claude Code connector with Opus 5.5. Nothing paid was called. The test files were deleted afterwards.

| Step | 29 min 1080p60 | 52 s 4K HEVC 10-bit | From the app log (real use) |
|---|---|---|---|
| Probe | 0.04 s | — | — |
| Transcription, local Whisper (free) | **53 s**, 2,864 words, audio extraction included (33× real time) | **2.8 s** | — |
| Transcription, ElevenLabs Scribe v2 | ≈ 35 s, extrapolated | — | 6–8 s for 5.8 min (≈ 50× real time) |
| Find clips (Opus 5.5, extra high) | **77 s**, 5 clips | — | median 16 s, p90 36 s on 1–6 min transcripts |
| Make it postable plan (Opus 5.5, extra high, ~8k output tokens) | not run | — | median 74 s, max 124 s |
| Rewrite in your voice (LLM) | — | — | 16–27 s median, then TTS takes |
| Export: captioned clip, fillers cut, pauses tightened | **6.8 s** (16:9) and **6.5 s** (9:16) for a 34 s clip | **4.9 s** for a 46 s 9:16 clip | 7–50 s |
| Loudness of the export | −20.7 LUFS integrated | — | the agent delivered about −16 LUFS |

Clip finding on the 29-minute file returned the same arguments the agent had picked by hand in October ("Everybody can clone the software, but not the deals", "Software is solved, so now you can do business", "Quantity isn't quality").

Every AI step runs at extra high effort (`clip-finder.json`, `ai-tighten.json`, `caption-pick.json`, `ask-claude.json`, `ClipAutopilotService.effort`). Each call also pays the Claude Code CLI's start-up time: the connection test alone has a median of 4.6 s.

## Claude mode live, after the speed package (2026-11-08)

Release `voxclip-cli autopilot --count 3 --timings` at `0f952b0b` (eyes part 1, loudness and speed merged) on the same 29-minute file, Claude Code with Opus 5.5 at extra high effort, local Whisper, an isolated data directory. The Mac was also building another package (load average 9–15).

| Stage | Seconds | Note |
|---|---|---|
| Probe and audio | 2.2 | |
| Transcribe, local Whisper | 51.4 | 2,864 words |
| Find Clips, compact sentence lines | **32.4** | was 77 s with per-word lines |
| Plans, three at once | 53.9 / 57.5 / 60.8 | applied as each is ready |
| First clip applied | **140.0** | target 120 |
| First clip exported (9:16) | 145.5 | 5.3 s export |
| All three exported | **158.7** | |

- **Transcription is now the largest stage.** Apple's on-device `SpeechTranscriber` (`--engine apple`) took **18.2 s** for the same file (96× real time) and found 2,855 words. Within one 5:48 repetition it matched Whisper on 94–96% of words. It writes "um" and "uh", which Whisper drops, and it missed some names ("Opus", "Twilio") but got "telcos" where Whisper wrote "delco's". Its word starts are about 300 ms earlier (median), because Apple's word ranges take in the silence before a word (transcription.md §5.5 already handles both conventions). With Apple transcription the first clip would land at about 105 s.
- **Loudness did not reach −14 on real speech.** The three exports measured −20.1, −19.8 and −20.0 LUFS (FFmpeg `ebur128`). Clip 1's report: measured −20.9 LUFS, gain +0.74 dB, `capped: true`. Plosives and clicks reach the −1 dBTP ceiling first, so static gain alone barely moves talking-head audio. track/v2-loudness-limiter adds a transparent true-peak limiter.

## Side by side

| | Agent (Codex/Opus, no app) | VoxClip today |
|---|---|---|
| Time to first clips | ~12 min, plus tool repair | ~4–5 min for 3 postable clips; ~1.5 min to suggestions |
| Mechanical steps | minutes; scripts written per run | seconds; native, cached by content key |
| Word-accurate cuts | checked afterwards by re-transcribing | guaranteed by construction |
| Looks at the picture | yes: contact sheets, face position, what to blur | **no**: text only, and `faceX` is not measured |
| Several recordings, camera ingest | yes: browses the card and picks across files | one video per project |
| B-roll, screenshots, dual-video stacks | yes | context demos only |
| Captions, hook, music, zooms, looks, speed | yes | yes: 26 caption styles, title, music, zooms, looks, speed |
| Fixing what you said, in your voice | no | **yes**: Rewrite and whole-clip revoice with lip sync |
| Loudness normalisation | −16 LUFS | none (−20.7 LUFS measured) |
| Self-check of exports | lip sync, every word, loudness | by construction; nothing shown to the user |
| Editable hand-off | CapCut projects | MP4 and SRT |
| Score, post text, when to post | yes, all three | score and post text |
| Cost control and undo | none | priced buttons, spend cap, undo per decision |

## What "wow" still needs, in order

1. **Give Claude eyes.**
   - Send a small contact sheet (one frame per sentence, about 320 px) with the plan request, so Claude can choose the opening frame, avoid closed eyes and spot what to blur.
   - Add on-device face detection (Vision) for reframing and zooms.
   - This is the agent's largest quality advantage, and it costs one image input per clip.
2. **Halve the wait.**
   - Find clips at high effort over a compact sentence-level transcript; the timings per word aren't needed to pick moments.
   - Start planning the best clip as soon as it's found, rather than after the whole list.
   - Plan clips in parallel, or merge finding and planning into one call in Claude mode.
   - Keep the connector process warm.
   - Show each clip as soon as it's ready.
   - Target: a 29-minute file to its first postable clip in under 2 minutes.
3. **Normalise loudness** at export, to −14 to −16 LUFS. Cheap, and clips sound right in the feed.
4. **Import from the camera or a folder.**
   - Transcribe every recording in parallel and find the best moments across them.
   - Claude mode ends with "N clips ready" for the whole card, as in the agent's first prompt.
5. **Inserts and layouts.** B-roll or screenshots from other files timed to words, and dual-video stacks for portrait.
6. **Show the self-check.** Re-transcribe the export, check sync and loudness locally (seconds), and show "verified" in the review.
7. **Editable hand-off.** FCPXML, or a CapCut draft, for people who finish in another editor.
8. **Posting help.** Suggest when and in what order to post, beside the score and post text.

Items 2 and 3 are engineering on existing paths. Item 1 changes what Claude can decide and needs an evaluation set. Items 4 and 5 extend the project model beyond one source.
