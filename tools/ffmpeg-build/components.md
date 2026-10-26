# Windows FFmpeg component audit

Audited against the read-only `win-media` implementation and its
`apps/windows/tests/VoxClip.Media.Tests/HANDOFF.md`, section "FFmpeg components
for the self-built LGPL pin". Paths below are relative to `apps/windows/` in
that track. The contract is architecture section 6 (including 6.6), editing
section 1 and ingest sections 5–6. This is a guaranteed input subset, not a
promise to decode every codec that a supported container can hold.

## Explicit components

| Category | Components | Reason and code location |
| --- | --- | --- |
| Decoders | `h264`, `hevc` | MP4/MOV/M4V, camera Main10 and M2 live preview; `src/VoxClip.Media/Ffmpeg/Native.cs:49`, `DecodeSession.cs:41`; ingest section 6 |
| Decoders | `vp8`, `vp9` | WebM/MKV input; generic codec-id lookup in `Ffmpeg/Native.cs:49` |
| Decoders | `libdav1d` | BSD-2 AV1 software decoder for WebM/MKV; generic codec-id lookup in `Ffmpeg/Native.cs:49`; the media handoff does not require native AV1 hardware wrappers |
| Decoders | `aac`, `opus`, `vorbis` | Supported container audio and live AAC; `Ffmpeg/AudioDecoder.cs`, `Pipeline/AudioExtraction.cs` |
| Decoders | `mpeg4`, `ffv1` | Native test fixtures; the handed-off media test contract requires these, not their encoders |
| Decoders | `pcm_u8`, `pcm_s8`, `pcm_s16le`, `pcm_s16be`, `pcm_s24le`, `pcm_s24be`, `pcm_s32le`, `pcm_s32be`, `pcm_f32le`, `pcm_f32be`, `pcm_f64le`, `pcm_f64be` | MOV/WAV LPCM, managed float-WAV re-read and M2 recording; `Ffmpeg/AudioDecoder.cs`, `Pipeline/AudioExtraction.cs`; ingest ING-2 |
| Encoders | `h264_nvenc`, `h264_qsv`, `h264_amf`, `h264_mf` | Encoder ladder; `Pipeline/EncoderProbe.cs:23`, `Ffmpeg/EncoderSession.cs:18`. MF is one encoder used with `hw_encoding=1`, then `0`. QSV is x64-only because Intel's dispatcher targets x86 |
| Encoders | `aac` | MP4 export audio; `Pipeline/Exporter.cs` |
| Encoders | `pcm_s16le` | M2 MOV recording with video passthrough and decoded 16-bit PCM, not AAC passthrough; ingest ING-2 |
| Parsers | `h264`, `hevc`, `vp8`, `vp9`, `av1`, `aac`, `opus`, `vorbis`, `mpeg4video` | Packet parsing for the enabled decoders/containers; `Ffmpeg/Native.cs:29`, `:49` |
| Bitstream filters | `aac_adtstoasc`, `h264_mp4toannexb`, `hevc_mp4toannexb`, `extract_extradata`, `av1_frame_split`, `vp9_superframe_split` | Container/decoder framing and codec extradata, including M2 AVC/HEVC video passthrough; `Pipeline/Exporter.cs:199`; ingest section 6 |
| Demuxers | `mov`, `matroska`, `wav` | MP4/MOV/M4V; MKV/WebM; managed WAV re-read; `Ffmpeg/Native.cs:29` and handed-off native tests |
| Muxers | `mp4`, `mov` | Seekable faststart MP4 export (`Pipeline/Exporter.cs:199`, `:222`), and M2 MOV video/LPCM recording (ingest ING-2) |
| Filters | `atempo`, `buffer`, `buffersink`, `abuffer`, `abuffersink` | `atempo` supplies pitch-preserving duration fit for nonunity Voice Lab replacement audio. The four sources/sinks are unconditional registrations in the ABI-required avfilter library. No optional HDR graph is enabled: `Ffmpeg/ToneMapper.cs:12` checks for zscale and `VideoDecoder.cs` falls back to direct swscale with the architecture section 6.5 warning |
| Hwaccels | `h264_d3d11va`, `h264_d3d11va2`, `hevc_d3d11va`, `hevc_d3d11va2`, `vp9_d3d11va`, `vp9_d3d11va2` | Device creation and frame download; `Ffmpeg/DecodeSession.cs:41`, `VideoDecoder.cs:73`. The app uses the `AV_PIX_FMT_D3D11` v2 variants. FFmpeg 9.0.2's Makefile gates each shared implementation object on the legacy flag, so both registrations are required to link without changing upstream FFmpeg |
| Protocols | `file` | The only allowed input and output transport; `Ffmpeg/Native.cs:28`; `Pipeline/Exporter.cs` |

The resolved allowlist also includes `h263` decode (selected by `mpeg4`),
the `ac3` parser and `vp9_superframe` bitstream filter (selected by the MOV
muxer). These framing helpers do not promise AC-3 audio decode. The final
counts are 23 decoders, 6 encoders (5 on ARM64), 10 parsers, 7 bitstream
filters, 3 demuxers, 2 muxers, 5 filters, 6 hwaccels and 1 protocol.
FFmpeg always registers `buffer`, `buffersink`, `abuffer` and `abuffersink`
when avfilter is built; they have no CONFIG component macros and cannot
be disabled separately. The recipe enables only `atempo` and checks all five
symbols in the generated filter registration table. `atempo` uses FFmpeg's
internal transform implementation; the linked objects and their notices are
selected by the per-RID link-map audit rather than assumed here.
The build checks the exact resolved component set against this allowlist;
any further addition or silently disabled requested feature is a failure.

`swscale` is also called directly by `Ffmpeg/VideoDecoder.cs:85`,
`Pipeline/FrameComposer.cs` and `Pipeline/Exporter.cs:114` for BGRA/NV12
conversion. `swresample` is called by `Ffmpeg/AudioDecoder.cs:76`,
`Audio/EditedAudioReader.cs:34` and `Pipeline/AudioExtraction.cs:48` for
float samples, downmix matrices and rate conversion. These are libraries,
not additional filters. The six shared libraries are `avcodec`, `avformat`,
`avutil`, `avfilter`, `swscale`, `swresample`; their majors must match
FFmpeg.AutoGen 9.0.1.1 (`Ffmpeg/FfmpegLoader.cs:11`).

## Deliberate exclusions

- No network, RTMP, FLV, HLS, DASH, concat, HTTP, TLS or socket protocols.
  VoxClip owns the RTMP receiver and passes compressed video to the MOV
  writer (ingest ING-1/ING-2); FFmpeg is not the server. Remote imports and
  unsupported playlists fail instead of opening secondary resources.
- No DXVA2 hwaccels: the current code creates D3D11VA contexts only and
  falls back to software. No QSV, CUDA or AMF decode paths: these names are
  encoder choices, not a request for every vendor decoder. AV1 software
  decode uses dav1d without the unused native AV1 hardware wrapper.
- No zimg or optional zscale/tonemap graph: the examined zimg 3.0.6 is
  WTFPL-2, outside the project licence allowlist. The existing swscale HDR
  fallback remains available and may produce flatter colours; architecture
  section 6.5 requires the user-visible warning. No licence exception is assumed.
- No software H.264/HEVC external encoder, libx264, libx265, GPL FFTW,
  Chromaprint, librsvg, rav1e, Cargo, libass or font renderer. Missing vendor
  encoders fall through to Windows' MF software H.264 encoder.
- No SRT or WAV muxer, subtitle decoder, subtitle burn-in filter or lavfi
  generator. Managed code writes SRT/WAV and Skia composes captions.
  System FFmpeg fixture-generation encoders are not app dependencies.
- No arbitrary audio/video codec promise (for example AC-3, DTS, ProRes,
  MJPEG, MP3 or FLAC). Such tracks return unsupported/decode errors until
  separately audited and added. Compressed Matroska headers needing zlib
  are not enabled. PCM coverage is the explicit list above.
- Voice Lab Clean audio (M2) will require the FLAC encoder and matching
  decode/container path; that addition needs a new audited pin before M2 ships.

The recipe must enable platform `mediafoundation`, `d3d11va`, `ffnvcodec`,
`nvenc`, `amf`, and x64 `libvpl`, plus `libdav1d`. Header
libraries are not redistributable vendor GPU drivers. Their availability
does not establish runtime hardware support on either architecture.
