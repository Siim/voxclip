# Synthetic native composition source

`voice-lab-7s.mkv` is a 964 KiB, seven-second source for the Windows native
composition tests. It contains generated `testsrc2` video at 160×90/30 fps
and a generated 48 kHz mono PCM sweep (instantaneous frequency 300 + 60t Hz).
It contains no paid voice, speech, or personal media. It was generated with
FFmpeg 8.0 using this command from the repository root:

```sh
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -f lavfi -i 'testsrc2=size=160x90:rate=30:duration=7' \
  -f lavfi -i 'aevalsrc=0.28*sin(2*PI*(300*t+30*t*t)):s=48000:d=7' \
  -map 0:v -map 1:a -c:v mpeg4 -q:v 7 -g 30 -c:a pcm_s16le \
  shared/fixtures/voice-lab/voice-lab-7s.mkv
```

Committed SHA-256: `6be0c2e01c675805f2cb61b0e0a31ec1980be433a23daf8897ebb18443cbcf39`.
The test copies no fixture into an app directory.

`voice-lab-7s-720p.mkv` uses the same generated audio at 48 kHz and a flat,
high-contrast 1280×720/30 fps video field. It lets the native compositor and
decoded export show the disclosure at a realistic output size without a
resizing-only test. FFmpeg 8.0 generated the 837 KiB file from the repository
root with:

```sh
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -f lavfi -i 'color=c=0x30435C:s=1280x720:r=30:d=7,drawbox=x=320:y=180:w=640:h=360:color=0x546D84:t=3' \
  -f lavfi -i 'aevalsrc=0.28*sin(2*PI*(300*t+30*t*t)):s=48000:d=7' \
  -map 0:v -map 1:a -c:v mpeg4 -q:v 25 -g 30 -c:a pcm_s16le \
  shared/fixtures/voice-lab/voice-lab-7s-720p.mkv
```

Committed SHA-256: `ced32d5a0ed80dd4f50e506381873aa458dc2eae069b6248575838221ceb56e1`.
