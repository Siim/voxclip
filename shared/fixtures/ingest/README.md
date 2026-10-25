# Camera-file compatibility input

`media/pocket4-like-2tracks.mov` is the small synthetic M1 camera-file fixture
from `doc/spec/ingest.md` sections 3.1, 18.2 and 18.9. It is not a camera recording.

- Six seconds, 1280×720, 30 fps, HEVC Main 10 (`hvc1`, 10-bit 4:2:0), 1 Mbps target.
- BT.709 colour tags, moving colour test pattern and a frame barcode.
- Two AAC-LC tracks, each 48 kHz stereo at 96 kbps: first `DJI Mic`, a 1 kHz
  sine on both channels; second `Built-in microphones`, a 300 Hz sine.
- Below 2,000,000 bytes. The committed bytes are canonical because hardware
  encoders are not byte-reproducible.

Regenerate on macOS from the repository root, one encode at a time:

```sh
swift tools/fixtures/media/generate.swift --pocket4 shared/fixtures/ingest/media/pocket4-like-2tracks.mov
swift tools/fixtures/media/generate.swift --verify-pocket4 shared/fixtures/ingest/media/pocket4-like-2tracks.mov
```

The generator uses AVAssetWriter and VideoToolbox HEVC Main 10, transfers the
CoreGraphics BGRA test pattern into P010 input buffers, and supplies independent
AAC inputs for the two audio tracks. This is an AVFoundation equivalent of the
developer-only FFmpeg command in section 18.2; it does not use x265. Verification
needs development `ffprobe` (or `VOXCLIP_FFPROBE`) to inspect the Main 10 profile,
then AVFoundation decodes all 180 frame barcodes and correlates both channels
of each track against its expected tone. No GUI or real camera is needed.

App tests should open, preview and export this file, and verify that audio
extracted at 16 kHz contains the first track's 1 kHz tone, not the second
track's 300 Hz tone. This fixture alone does not claim those app tests passed.

The other media, FLV, RTMP, LAN and live-clipping fixtures listed in section
18.2 are later ingest-track work and are deliberately not generated here.
