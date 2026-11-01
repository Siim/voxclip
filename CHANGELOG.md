# Changelog

User-facing changes, newest first, one line each. The release scripts read the section whose heading starts with `## <version>` (doc/release.md section 4); replace "Unreleased" with the release date (`YYYY-MM-DD`) in the release commit.

## 0.1.0 - Unreleased

- First release of VoxClip for Mac (Apple silicon, macOS 26 or later) and Windows (x64 and Arm64, Windows 10 2004 or later).
- Import a video and transcribe it with word timestamps: ElevenLabs Scribe with your own key, local Whisper models, or Apple Speech on Mac. If a local model is missing, VoxClip offers to download it.
- Cut by editing words. Remove filler words and tighten long pauses in a click, correct a word's text, and restore anything you cut.
- Find clips with the AI you choose: your own API key, a local model (Ollama or LM Studio), your signed-in Claude Code or Codex, or Apple's on-device model on Mac.
- Burn captions in 19 styles and export MP4 at the source size, 16:9, 9:16 or 1:1, with an optional SRT file.
- Share after export: show the file, copy a caption, or open X or LinkedIn with your text.
- Save and reopen projects. A command-line tool, voxclip-cli, is included.
- Rewrite a clip, the full take or a few words with the AI you choose, from the bar above the transcript. The changes show in the transcript, and you can edit or leave out each one before anything is applied. Cuts and text fixes work without Voice Lab.
- Rewrite starts at once when it costs you nothing extra: Claude Code or Codex signed in on your plan, a local model, or Apple's on-device model. With an API key, VoxClip asks before every send.
- Find Clips and the Test button in AI settings follow the same rule on Mac: they start at once when they cost you nothing extra, and ask before every send on an API key or on Claude Code or Codex signed in with one. The privacy notice still appears once for each AI, before its first send.
- Voice Lab (beta, off until you turn it on): say the new words in your own cloned voice with your ElevenLabs key. Each paid step shows its cost and asks first.
- Make your voice from the clip you are rewriting, or from a 90-second read-aloud. You always record a short consent statement live. A speaker check on your computer runs before anything is sent, then one click checks your statement and creates the voice. Nothing is created if a check fails.
- The speaker check is calibrated for English only, so your voice works in English projects in this release.
- Every export that contains generated speech is marked AI MODIFIED on screen, and the mark is also embedded in the file's metadata and a provenance sidecar. You can move the label but not turn it off.
- Share text for such an export ends with a line saying it contains AI-modified speech, and VoxClip asks before you share without it.
- On Windows, creating your voice in Voice Lab is not available yet.
- Your keys stay in the Mac Keychain or encrypted for your Windows account. VoxClip sends no telemetry.
- Windows asks you to accept the Microsoft Windows App SDK terms the first time you open it.
- Windows builds use the LGPL FFmpeg libraries; their source is attached to this release.
- The dark theme uses the calmer greys of the new editor design on Mac and Windows. On Mac, Increase Contrast brightens the quietest greys.
- The Mac editor uses the new code-editor frame: a flat Explorer, a tab row that is the title bar, Export beside the viewer, the timeline as a bottom panel and a status bar, with no toolbar. The Explorer, viewer and timeline each have a show and hide button, and the sizes you drag are kept.
- On a narrow Mac window the Explorer folds away first, below 1,128 points, and in full screen or Split View the viewer column folds away below 904; each opens over the editor when you ask for it, and Escape closes it. F6 also visits the tab row and the status bar, and a Versions window shows the same editor frame.
- The Mac timeline is the new bottom panel: an overview of the whole take with every clip, a ruler with timecodes and the clip's In and Out, and a playhead that stays smooth on hour-long takes. It shows the clip as edited by default, and View › Hide Timeline (⌘J) hides it.
- The Mac timeline's audio track shows the waveform, with a thin seam at each cut. Edited and Source switch it between the clip as it plays and the whole take with its cuts, and its toolbar adds go to start and end, the source timecode and the length of the selection.
- Each clip you open on Mac gets a tab beside Full Take, and a suggestion opens as an italic preview tab that the next one replaces. Switching tabs is not an undo step and does not mark the project edited, Undo stays on the tab you are on, and a Rewrite stays open on its own tab until you close that tab. ⌃Tab and ⌃⇧Tab move between tabs, and ⌘W closes a clip's tab.
- On Mac the viewer is a fixed 16:9 picture the width of its column, shorter only in the smallest windows so the panel under it stays usable, with portrait and square frames shown between dark bars, and only captions and one tag (AI voice, AI modified, or the media status) drawn on it. Under it, one panel names its job and the open tab, with a switcher for the jobs you can use now (Captions, and Rewrite while one is open); play and the time are in the timeline, and when you hide the timeline they appear along the viewer's bottom edge as you point at it or move keyboard focus to it, without blocking a caption you drag. The frame choice moved to View › Frame, and Playback › Back 3 Seconds works from the menu wherever you are.
- The Mac transcript reads like a code editor: 15-point text in paragraphs of at most 150 words, each paragraph's start time in a gutter, the open clip on a lighter band with a bar beside it and the rest of the take dimmed, and an overview ruler at the right edge that shows where the clip, your selection and AI-voiced words sit in the take.
- Cutting, restoring and correcting words in the Mac transcript, and Cut Fillers across the take, stay quick in hour-long takes, also with Show Cut Words off.
- When no AI is chosen, Rewrite on Mac asks in its panel which one to use, listing the AIs this Mac has and what each costs. While it runs the panel shows each step with Stop, and when it fails it says how to fix it: sign in, start the local model, paste a key or try again.
- On Mac, Edit › Rewrite and ⇧⌘R work on your selection, the clip you have open or the full take, as the menu names, and start at once. If you edit those words while the proposed changes are open, Rewrite says so and offers Rewrite Again, and undoing your edit brings the changes back. The field offers four common requests and your last three.
- Not tested on: TODO list the test machines that were not available (doc/plan.md section 6).
