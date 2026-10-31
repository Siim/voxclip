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
- Voice Lab (beta, off until you turn it on in Settings): rewrite a passage with your AI and re-voice it in your own cloned voice with your ElevenLabs key. Each paid step shows its cost and asks first.
- Create your voice from the open project's audio, or from a 90-second read-aloud. You always record a short consent statement live, and a local speaker check makes sure the training audio sounds like the voice in it.
- The speaker check is calibrated for English only, so your voice works in English projects in this release.
- Every export that contains generated speech is marked AI MODIFIED on screen, and the mark is also embedded in the file's metadata and a provenance sidecar. You can move the label but not turn it off.
- Share text for such an export ends with a line saying it contains AI-modified speech, and VoxClip asks before you share without it.
- On Windows, creating your voice in Voice Lab is not available yet.
- Your keys stay in the Mac Keychain or encrypted for your Windows account. VoxClip sends no telemetry.
- Windows asks you to accept the Microsoft Windows App SDK terms the first time you open it.
- Windows builds use the LGPL FFmpeg libraries; their source is attached to this release.
- Not tested on: TODO list the test machines that were not available (doc/plan.md section 6).
