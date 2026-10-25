#!/bin/sh
set -eu
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || { echo 'Install a system ffmpeg CLI, then rerun this script.' >&2; exit 1; }
command -v ffprobe >/dev/null || { echo 'Install a system ffprobe CLI, then rerun this script.' >&2; exit 1; }
if [ -n "${VOXCLIP_HEVC_FIXTURE:-}" ]; then
  [ -f "$VOXCLIP_HEVC_FIXTURE" ] || { echo 'VOXCLIP_HEVC_FIXTURE must name the prepared Main 10 MP4.' >&2; exit 1; }
  command -v "${VOXCLIP_FIXTURE_PYTHON:-python3}" >/dev/null || { echo 'Python is required to validate the HEVC fixture.' >&2; exit 1; }
fi
mkdir -p Fixtures/generated
cd Fixtures/generated
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'smptebars=size=640x360:rate=30:duration=4' \
  -f lavfi -i 'aevalsrc=0.35*sin(2*PI*(997*t+81*t*t)):s=48000:d=4' \
  -f lavfi -i 'sine=frequency=2011:sample_rate=48000:duration=4' \
  -map 0:v -map 1:a -map 2:a -c:v mpeg4 -q:v 3 -c:a pcm_s16le -metadata:s:a:1 title=second-track bars-two-audio.mkv
ffmpeg -hide_banner -loglevel error -y -i bars-two-audio.mkv -map 0 -c:v copy -ar 44100 -c:a pcm_f32le native-rate-44100.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'smptebars=size=3840x2160:rate=24:duration=0.25' \
  -c:v mpeg4 -q:v 8 bars-4k.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=size=160x90:rate=10:duration=60' \
  -f lavfi -i 'aevalsrc=0.35*sin(2*PI*(997*t+81*t*t)):s=48000:d=60' \
  -c:v mpeg4 -g 10 -c:a pcm_f32le coarse-clock.mkv
ffmpeg -hide_banner -loglevel error -i coarse-clock.mkv -map 0 -c copy -f matroska pipe:1 > coarse-clock-nocues.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=size=160x90:rate=30:duration=4.1' \
  -f lavfi -i 'sine=sample_rate=48000:duration=4.01' -c:v mpeg4 -c:a aac unequal-duration.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=size=160x90:rate=30:duration=1' \
  -f lavfi -i 'aevalsrc=0.75|0.25:s=48000:d=1' -c:v mpeg4 -c:a pcm_f32le stereo-average.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=size=160x90:rate=30:duration=1' \
  -f lavfi -i 'aevalsrc=0.4*sin(2*PI*(300*t+400*t*t))|0.3*sin(2*PI*(500*t+200*t*t)):s=48000:d=1' \
  -c:v mpeg4 -c:a pcm_f32le stereo-varying.mkv
ffmpeg -hide_banner -loglevel error -y -i stereo-varying.mkv -map 0 -c:v copy -ar 44100 -c:a pcm_f32le stereo-varying-44100.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=size=160x90:rate=10:duration=0.6' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.6' -c:v mpeg4 -c:a pcm_s16le start-zero.avi
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=size=160x90:rate=10:duration=0.6' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=0.6' -c:v flv1 -c:a mp3 start-zero.flv
for size in 160x90 64x64; do
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=size=$size:rate=10:duration=0.5" -c:v mpeg4 -q:v 3 -f m4v "size-$size.m4v"
done
cat size-160x90.m4v size-64x64.m4v > resolution-switch.m4v
ffmpeg -hide_banner -loglevel error -y -fflags +genpts -r 10 -f m4v -i resolution-switch.m4v -c:v copy resolution-switch.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'aevalsrc=0.3*sin(2*PI*440*t)|0.2*sin(2*PI*550*t):s=48000:d=0.5' -c:a aac -f adts stereo-part.aac
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=660:sample_rate=48000:duration=0.5' -c:a aac -f adts mono-part.aac
cat stereo-part.aac mono-part.aac > channels-switch.aac
rm -f size-160x90.m4v size-64x64.m4v resolution-switch.m4v stereo-part.aac mono-part.aac
for range in limited full; do
  if [ "$range" = limited ]; then black=64; expected=tv; else black=0; expected=pc; fi
  ffmpeg -hide_banner -loglevel error -y -f lavfi \
    -i "nullsrc=s=64x64:r=30:d=0.1,format=yuv420p10le,geq=lum=$black:cb=512:cr=512,setparams=range=$range:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc" \
    -c:v ffv1 -color_range "$expected" "hdr-$range.mkv"
  actual=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_range -of default=nw=1:nk=1 "hdr-$range.mkv")
  [ "$actual" = "$expected" ] || { echo "HDR $range fixture has color_range=$actual, expected $expected" >&2; exit 1; }
done
if [ -n "${VOXCLIP_HEVC_FIXTURE:-}" ]; then
  cp "$VOXCLIP_HEVC_FIXTURE" hevc10-two-audio.mp4
else
  encoded=false
  for encoder in ${VOXCLIP_HEVC_ENCODER:-hevc_videotoolbox hevc_nvenc hevc_qsv hevc_vaapi hevc_vulkan}; do
    case "$encoder" in
      hevc_videotoolbox|hevc_nvenc|hevc_qsv) extra='-pix_fmt p010le' ;;
      hevc_vaapi) extra="-vaapi_device ${VOXCLIP_VAAPI_DEVICE:-/dev/dri/renderD128} -vf format=p010le,hwupload" ;;
      hevc_vulkan) extra='-init_hw_device vulkan=vk -filter_hw_device vk -vf format=p010le,hwupload' ;;
      *) echo "Unsupported encoder: $encoder (never use libx265)." >&2; exit 1 ;;
    esac
    # extra contains the encoder-specific FFmpeg argument words.
    # shellcheck disable=SC2086
    if ffmpeg -hide_banner -loglevel error -y -i bars-two-audio.mkv -map 0:v -map 0:a \
      $extra -c:v "$encoder" -profile:v main10 -b:v 1000k -tag:v hvc1 -c:a aac -b:a 160k \
      -color_primaries bt709 -color_trc bt709 -colorspace bt709 -movflags +faststart hevc10-two-audio.mp4; then encoded=true; break; fi
  done
  if [ "$encoded" != true ]; then
    rm -f hevc10-two-audio.mp4
    echo 'HEVC Main10 hardware encoder required. On macOS use hevc_videotoolbox; on Linux enable VAAPI/QSV/NVENC/Vulkan and rerun with VOXCLIP_HEVC_ENCODER=hevc_vaapi (or the matching encoder).' >&2
    exit 1
  fi
fi
ffprobe -v error -show_streams -show_format -of json hevc10-two-audio.mp4 > hevc10-probe.json
"${VOXCLIP_FIXTURE_PYTHON:-python3}" - hevc10-probe.json <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    probe = json.load(source)
streams = probe["streams"]
video = [stream for stream in streams if stream.get("codec_type") == "video"]
audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
assert len(video) == 1 and len(audio) == 2, "HEVC fixture needs one video and two audio tracks"
v = video[0]
assert (v.get("codec_name"), v.get("profile"), v.get("pix_fmt"), v.get("width"), v.get("height")) == (
    "hevc", "Main 10", "yuv420p10le", 640, 360
), "HEVC fixture needs 640x360 Main 10 yuv420p10le"
assert all((track.get("codec_name"), track.get("sample_rate"), track.get("channels")) == (
    "aac", "48000", 1
) for track in audio), "HEVC fixture needs two AAC 48 kHz mono tracks"
assert abs(float(probe["format"]["duration"]) - 4.0) < 0.04, "HEVC fixture must last four seconds"
PY
rm hevc10-probe.json
