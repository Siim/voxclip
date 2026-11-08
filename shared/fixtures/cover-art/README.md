# MP4 cover-art vectors

Synthetic media only (ADR-R48, doc/publishing.md §7). Each `.mp4` here is a few KB that
`tools/fixtures/cover-art/generate_cover_art.py` lays out byte by byte: a 64 × 64 black H.264 picture (three frames at
10 fps) and 16 frames of silent 48 kHz AAC, with `moov` before or after `mdat`. The sample bytes are constants in the
script (encoded once with OpenH264 and ffmpeg's AAC encoder), so no encoder runs and the files are the same everywhere.
`cover.jpg` (16 × 16) and `cover.png` (24 × 24, stored deflate) are the images the writers embed.

`cover-art-cases.json` (`voxclip-cover-art-cases/1`, `shared/schemas/cover-art-cases.schema.json`) lists 17 cases:

- **Written** (10): the output's size and SHA-256, the growth of `moov`, every track's `stco`/`co64` before and after, and
  the boxes on the way to the cover (`path offset size`). The script builds each expected file from scratch with the cover
  in place rather than editing the input, so it checks the writers independently. `decodes: false` marks the one case
  whose offsets are synthetic (`stco-overflow`: entries just under 2^32 that the growth pushes over, so its `stco` becomes
  a `co64`).
  - `moov-first` (with a `free` box between `moov` and `mdat`) and `moov-first-png`, `co64`, `mdat-largesize` (`size == 1`),
    `mdat-to-end` (`size == 0`): every entry moves by the growth.
  - `moov-last`, `udta-without-meta` (a location in `udta`, no `meta`), `moov-to-end` (`moov` is size 0; the writer writes
    its size out): no offset changes.
  - `existing-covr`: a title, a PNG cover and an encoder tag in `ilst`, and a location in `udta`. The cover is replaced in
    place and the rest is kept byte for byte. The new cover is smaller, so the growth is negative.
- **Refused** (7), the file untouched: `fragmented-mvex`, `fragmented-moof`, `truncated` (the file is cut inside `mdat`),
  `truncated-header` (stray bytes after `mdat`), `truncated-child` (a `trak` larger than its `moov`), `bad-largesize` (a
  64-bit size smaller than its header) and `no-moov`.

Regenerate with `python3 tools/fixtures/cover-art/generate_cover_art.py`; `tools/fixtures/voice-lab/check_drift.py` runs it
and checks every file here byte for byte. Do not hand-edit. Swift `MP4CoverArtTests` (Core) and `MP4CoverEmbedTests`
(Media, which streams the file and decodes every sample with AVFoundation) and C# `Mp4CoverArtReplayTests` replay every
case.
