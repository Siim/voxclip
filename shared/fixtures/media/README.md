# Synthetic CLI media

These fixtures implement `doc/architecture.md` section 9.5. The committed files
are canonical: hardware encoders are not byte-reproducible. Regenerate only for
an intentional content change, review decoded frames, and commit the media and
the updated `index.json` together. No provider, model, or recorded speech is used.
Every committed file must remain below 2,000,000 bytes.

## Test-only Windows Main 10 input

The Windows native suite also needs `hevc10-two-audio.mp4`, a four-second
640×360 HEVC Main 10 MP4 with two AAC 48 kHz mono tracks. It is generated
outside `shared/fixtures/media/` and is never committed or packaged. The first
track contains the same chirp as the native `bars-two-audio.mkv` fixture; the
second contains a 2011 Hz tone. On macOS, run:

```sh
swift tools/fixtures/media/generate.swift --win-hevc /tmp/hevc10-two-audio.mp4
swift tools/fixtures/media/generate.swift --verify-win-hevc /tmp/hevc10-two-audio.mp4
VOXCLIP_HEVC_FIXTURE=/tmp/hevc10-two-audio.mp4 sh apps/windows/tests/VoxClip.Media.Tests/generate-fixtures.sh
```

CI generates this small input with AVFoundation on `macos-26`. The Swift verifier
uses AVFoundation and CoreMedia to check the `hvc1` Main 10 4:2:0 ten-bit stream,
640×360 dimensions, 120 decoded frames, four-second duration, and both AAC
48 kHz mono tracks and their audio content. It needs no `ffprobe` on macOS.
Windows setup checks the downloaded file with the pinned test-only `ffprobe.exe`
and uses test-only `ffmpeg.exe` for the other ignored native fixtures. It does
not need a Windows HEVC encoder.

## Regenerate on macOS

The Swift script uses AVAssetWriter and VideoToolbox H.264 High, CoreGraphics
BGRA frames, and BT.709 colour properties. Audio is 48 kHz mono: signed 16-bit
LPCM for `joins-tone.mov`, AAC-LC at 128 kbps for the other audio-bearing MP4s.
The bars clip has no audio. Encodes run sequentially.

With development `ffmpeg` and `ffprobe` on `PATH`, run from the repository root:

```sh
export VOXCLIP_FFMPEG="$(command -v ffmpeg)"
export VOXCLIP_FFPROBE="$(command -v ffprobe)"
swift tools/fixtures/media/generate.swift --out shared/fixtures/media
"$VOXCLIP_FFMPEG" -hide_banner -loglevel error -y -threads 1 -i shared/fixtures/media/counter-1080p.mp4 -t 1 -vf scale=320:180:flags=neighbor -c:v libvpx-vp9 -threads 1 -b:v 100k -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a libopus -b:a 48k -ar 48000 -ac 1 shared/fixtures/media/tiny.webm
swift tools/fixtures/media/generate.swift --index shared/fixtures/media
swift tools/fixtures/media/generate.swift --verify shared/fixtures/media
python3 tools/schemas/validate.py
```

`tiny.webm` was made with **ffmpeg version 6.1.1**, built with clang 14.0.6,
using the exact command above. FFmpeg is a development-only tool, never shipped.
Nearest-neighbour scaling preserves the frame barcode's sample points. Rebuild
it after regenerating the counter; `--out` deliberately does not encode WebM.
`--index` then records the six regenerated files' actual byte sizes and SHA-256s.

## Verify

`--verify` checks all six index entries against the normative dimensions, frame
rates, durations, video/audio codecs, audio formats, byte sizes, and SHA-256s.
It decodes every video frame, verifies its timestamp and 12-bit barcode, checks
both 4-pixel counter marker columns, and samples all eight bars within ±3 RGB
code values. Tone/chirp correlation must exceed 0.98 at three positions, with
amplitude within 8%. H.264 High and AAC-LC are checked explicitly. Every video
must carry BT.709 primaries, transfer, and matrix tags.

AVFoundation handles MP4/MOV; only WebM verification needs FFmpeg and ffprobe.
Set `VOXCLIP_FFMPEG` and `VOXCLIP_FFPROBE` to override the script's development
tool locations. Any failed check exits nonzero and identifies the failing file.

The three transcript companions are complete schema-compatible `Transcript`
objects with native timing and the synthetic ElevenLabs engine specified in
section 9.5. Their raw keys hash their filenames. Verification compares every
field and checks 119/60/60 items and 59/17/60 fillers; kept caption words in
`fillers-chirp` have gaps of at least 0.25 seconds.

## On-demand performance inputs

```sh
swift tools/fixtures/media/generate.swift --long-hevc /tmp/voxclip-long.mov
swift tools/fixtures/media/generate.swift --motion-60s /tmp/voxclip-motion.mp4
```

The first writes 600 seconds of 1080p HEVC, moving seeded noise, barcode, chirp,
and a transcript with 200 alternating filler cuts. The second writes 60 seconds
of 1080p H.264 High moving noise for encoder bitrate tests. The 12-bit barcode
wraps modulo 4096 in the long input. These large inputs and the long transcript
are never committed; remove them after testing.
