# win-media handoff

## 2026-10-26: round 7 native acceptance of `997134ef`

The optimized converter source and tests were archived from commit
`997134efcfbc44e4ef6a37ed9b56b007029e4055`. On Windows ARM64, the x64
run used the self-contained x64 test/CLI executables under emulation; the
ARM64 run used native `dotnet.exe` and app-adjacent CLI DLLs. Both Release
builds had zero warnings and errors. Each RID passed 22 converter/oracle
cases, 49 selected strict shipping cases and two cleanup cases, with zero
skips or failures. The isolated timing case also passed on each RID.

The `win-x64-1` and `win-arm64-1` report ZIPs matched schema-2
`buildInputsSha256=049f309525d2e22ab186539890732cbcb526d3c4f3b65c78ccc5b01839ba2ed7`,
the committed manifest, archive hashes/sizes and all six audited DLL
hashes/sizes before transfer and again on the VM. The saved module reports
identify all six loaded DLL paths, sizes and SHA-256 values in both the test
process and app-adjacent CLI process. The test and CLI architectures match
each RID. The six CLI DLLs came only from the audited runtime archive.

Both 72-row bar CSVs passed the production software Media Foundation rule:
preencoder RGB maximum error was 3 on x64 and 2 on ARM64, paired decoded
Y/U/V maximum error was 1 on each, and decoded RGB was within 2 of the
finite BT.709 inverse. All rows retained High/yuv420p, limited-range BT.709
metadata. The ten canonical E2E reports and CSV for each RID are saved under
`apps/windows/tests/VoxClip.Media.Tests/.runs/round7-x64/` and
`round7-arm64/`, alongside logs, `audit.json`, `timing-summary.json` and
test/CLI loaded-module reports.

The isolated Release conversion diagnostic used eight warmups and 12 samples
for each 1080p and 4K format/path, with zero managed allocation per
accelerated frame. Its successful per-format output is retained in each
`timing-only/conversion-probe.out.log`. The before/after medians below are
R5 versus R7 on the same Windows ARM64 VM; x64 is emulated and ARM64 native.

| 4K input | x64 R5 → R7 ms/frame | ARM64 R5 → R7 ms/frame |
| --- | ---: | ---: |
| NV12 | 12.82 → 12.22 | 8.11 → 7.81 |
| YUV420P | 19.96 → 15.35 | 12.71 → 7.83 |
| P010 | 23.91 → 20.57 | 15.45 → 8.74 |
| YUV420P10 | 30.47 → 21.14 | 13.30 → 9.00 |

The strict E2E suite took 64.930 → 58.743 s under x64 emulation and
29.668 → 25.626 s native ARM64. Per-case CLI elapsed totals were 52.26 →
47.90 s and 23.02 → 20.55 s respectively. Timing output records actual
`Avx2.IsSupported=true`/`AdvSimd.Arm64.IsSupported=false` for x64 and the
opposite flags for ARM64. These are VM diagnostics; physical x64/iGPU and
Snapdragon performance acceptance remains open. Native swscale is faster on
some formats but does not meet the strict colour rule.

The first x64 attempt stopped before tests because the archived workspace
omitted the root `THIRD_PARTY_NOTICES.md` used by the CLI project. The runner
now includes that tracked file. Successful timing output was initially
captured by xUnit but not printed; the runner now uses `-showLiveOutput` for
the timing class. For the two timing-only runs, that runner-only change was
copied into owned VM scratch after archiving the exact candidate source.
No conversion, fixture, gate or tolerance code changed. Each run released
its own lock and removed its source/build/native scratch. The final disk and
lock check is recorded in the round-7 evidence.

## 2026-10-26: exact BT.709 conversion performance candidate

The vertical chroma loop now selects direct 8-bit planar, P010, or planar
10-bit reads once per row. It retains the previous integer interpolation,
P010 right shift, planar 10-bit clamp, SIMD pixel conversion and scalar
fallback. The timing diagnostic writes to xUnit output so successful runs
show their measurements. One regression compares out-of-range planar 10-bit
chroma with the equivalent clamped input. No colour tolerance, fixture,
shipping DLL or metadata rule changed.

Local Release timing on the same M3 Max Arm64 host and .NET 10 SDK, before
and after the converter edit: eight warmups, 12 samples, medians in ms/frame.
The optimized values are the range of two consecutive runs. Every measured
path allocated 0 managed B/frame.

| Input | 1080p before | 1080p after | 4K before | 4K after |
| --- | ---: | ---: | ---: | ---: |
| NV12 | 5.56 | 5.55–5.62 | 8.26 | 8.30–8.57 |
| YUV420P | 3.06 | 2.02–2.04 | 12.17 | 8.01–8.21 |
| P010 | 4.07 | 2.11–2.20 | 15.57 | 8.38–8.55 |
| YUV420P10 | 3.47 | 2.11–2.12 | 13.93 | 8.36–8.82 |

The planar improvements support the per-sample format and clamp decisions
in the old hot loop as the local bottleneck. NV12, which already had direct
reads, is effectively unchanged. These Mac timings are diagnostic, not
Windows performance acceptance. The timing run used AdvSimd; this Mac has
no x64 .NET host. Native x64 correctness, the strict Windows end-to-end
timing, and physical x64 acceptance remain for the parent-managed VM slot.

Verification from this worktree: Release Media test build passed with zero
warnings/errors; 22 converter cases passed, including scalar equality and
the independent double oracle; the filtered Media suite reported 405 passed,
5 explicit prerequisite/opt-in skips, 0 failed (410 total). No VM lock or
transfer was used. The earlier round-5 shipping and DLL-identity evidence is
unchanged and was not rerun in this local round.

## 2026-10-25: round 4 continuation

## Shipping FFmpeg runtime acceptance

From the committed `track/win-media` checkout, run each available RID separately:

```sh
VOXCLIP_VM_HOST=siim@192.168.64.3 \
VOXCLIP_SHIPPING_RID=win-arm64 \
VOXCLIP_FFMPEG_ZIP="$HOME/Library/Caches/voxclip-ffmpeg-build/reports/win-arm64-1/voxclip-ffmpeg-n9.0.2-win-arm64.zip" \
sh apps/windows/tests/VoxClip.Media.Tests/verify-vm.sh
```

Use `win-x64` and its matching report ZIP only when the VM has an x64 .NET 10
host/runtime. The script checks the ZIP, input digest and six DLL hashes against
the committed manifest and audited report before transfer. The VM checks them
again before loading. It builds from `git archive HEAD`, with offline NuGet
sources and one build job, then runs the ten canonical CLI cases, the software
MF colour test, loaded-module identity, and supported-format native pipeline
selections in separate test processes. The AVI, FLV and raw AAC success cases
are excluded because their demuxers are outside the shipping build. Caption
goldens and the full Core/Media suites are outside this selection. The CLI
gets only app-adjacent DLLs; its test subprocess removes the test-only loader
override. The native test-process evidence records the six paths, sizes and
SHA-256 values, license string, configuration and process architecture. The
first CLI case separately records the six modules loaded by the shipping CLI
from its own app directory and verifies their hashes.

Logs, E2E JSON/CSV reports, `loaded-modules.json` and
`loaded-cli-modules.json` are copied into the
ignored `.runs/<owner>/` directory before the owned VM scratch is removed.
The runner releases only its own lock. A pre-existing lock with a missing
owner marker is reported after 90 seconds and left untouched.

## Native prerequisites and reproducibility

Work only in the `track/win-media` checkout and `C:\voxclip-build\win-media` on Windows. Source transfers use `git archive HEAD apps/windows shared`; ignored generated fixtures are transferred separately. Never transfer environment or credential files. `FfmpegLoader.LibraryMajors`, derived from FFmpeg.AutoGen, determines DLL basenames and ABI majors. Do not use a different ABI with these struct layouts. `build/ffmpeg.json` remains owned by win-ffmpeg-pin.

The round-4 native run used the lead-supplied `win-arm64-1/voxclip-ffmpeg-n9.0.2-win-arm64.zip` after checking its SHA-256 against the brief before each transfer. The lead explicitly allowed this archive for native testing despite the newly discovered GPL-only aarch64 `crc.S`. This is test evidence, not shipping licence approval. The archive must be re-pinned by win-ffmpeg-pin; no new hash, pin or binary is committed here.

Generate synthetic fixtures with system tooling, never shipping FFmpeg libraries:

```sh
sh apps/windows/tests/VoxClip.Media.Tests/generate-fixtures.sh
cd apps/windows
dotnet build VoxClip.CrossPlatform.slnf -c Release
dotnet test --project tests/VoxClip.Core.Tests -c Release
dotnet test --project tests/VoxClip.Media.Tests -c Release
```

Generation needs `ffmpeg`, `ffprobe`, and a hardware HEVC Main10 encoder. macOS uses VideoToolbox; Linux may set `VOXCLIP_HEVC_ENCODER` to NVENC/QSV/VAAPI/Vulkan and optionally `VOXCLIP_VAAPI_DEVICE`. There is no GPL encoder fallback. HDR generation explicitly sets and checks `pc`/`tv`; the regenerated full-range fixture reports `color_range=pc`, `color_transfer=smpte2084`, `color_primaries=bt2020`. The native test additionally checks decoded range and black luma (0 versus 64).

Only tests read `VOXCLIP_FFMPEG_DIR`; shipping code loads app-adjacent libraries. Missing fixtures or ABI-compatible native libraries are explicit xUnit skips on the Mac. `VOXCLIP_REQUIRE_NATIVE=1` makes those prerequisites fail on Windows. Licence-gate failures never skip. Windows H.264/WASAPI cases explicitly skip elsewhere. Tests run one collection at a time to avoid overloading the 4 GB VM. Missing optional zscale is not a prerequisite failure: tests exercise the documented HDR fallback instead.

## VM verification and lock protocol

Set the SSH target privately in `VOXCLIP_VM_HOST`; no maintainer host is stored here. Verify the selected native ZIP against the lead's current pin first, then supply its absolute Mac path as `VOXCLIP_FFMPEG_ZIP`. The runner transfers and expands it inside its owned VM source scratch, selects `native\bin`, and removes it with the workspace. Native verification:

```sh
timeout 8 ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$VOXCLIP_VM_HOST" exit
VOXCLIP_FFMPEG_ZIP=/absolute/path/to/verified-test-build.zip sh apps/windows/tests/VoxClip.Media.Tests/verify-vm.sh
```

The script atomically creates `C:\voxclip-build\vm.lock`, writes its unique owner token, and waits synchronously for at most 30 minutes if another track owns it. It never takes over or removes another token, even after a reboot. A lock older than the boot is reported to the lead, not cleared. Every SSH/SCP/build/test command has a timeout. Do not start background probe loops.

One fresh `source-<owner>` directory is used per run. The outer script owns lock release, kills only the run's recorded process tree on failure, retrieves bounded test logs, removes its source/build/generated-media/native-library scratch, and then releases its matching marker. The PowerShell runner checks ownership before work, limits MSBuild to one node and disables reusable build/compiler servers. It builds Core/Media/CLI/tests, runs the full Media and Core suites, then runs CLI probe/encoder/video-only export smoke checks. Nonzero suite results are collected rather than suppressing the remaining suites and smoke checks. Optional ffprobe/ffmpeg diagnostics use only the selected native directory. `-WithoutEncoders` explicitly omits Windows-only H.264/WASAPI cases; it is not full hardware acceptance. Neither that switch nor `-ManagedOnly` was used for round-4 native verification.

Without `VOXCLIP_FFMPEG_ZIP`, the existing `-FfmpegDirectory` option still selects an already staged directory under `C:\voxclip-build\win-media`. `-ManagedOnly` runs non-native verification without loading FFmpeg and does **not** certify native media behavior.

## FFmpeg component demand for the pinned LGPL build

This is the code's component demand, not a claim that every FFmpeg format is supported. Pin exact sources/hashes in the pin track; do not add autodetected dependencies.

- Shared libraries: `avcodec`, `avformat`, `avutil`, `avfilter`, `swscale`, `swresample`; accepted ABI majors come only from `FfmpegLoader.LibraryMajors`.
- Demuxers: `mov` for MP4/MOV/M4V, `matroska` for MKV/WebM, `wav` for native re-read tests. Common decoders: `h264`, `hevc` including Main10, `vp8`, `vp9`, `libdav1d` for software AV1, `aac`, `opus`, `vorbis`, and supported PCM variants. Generic codec-id selection is in `Ffmpeg/Native.cs`.
- Synthetic fixtures additionally need `mpeg4`, `ffv1`, `pcm_s16le`, and `pcm_f32le` decoders. AAC priming/edit-list tests use MOV/AAC; float WAV re-read uses `pcm_f32le`. Fixture generation is separate system tooling.
- Encoders: `h264_nvenc`, `h264_qsv` on x64 only, `h264_amf`, `h264_mf` with hardware enabled then disabled, plus native `aac`. Required external sources are nv-codec-headers (MIT), AMF headers (MIT), libvpl (MIT, x64 QSV), and dav1d (BSD-2-Clause). They must come from the pin track's verified source closure with llvm-mingw and FFmpeg n9.0.x. No x264/x265/FFTW or nonfree build.
- Hardware decode: `--enable-d3d11va` and `h264_d3d11va2`, `hevc_d3d11va2`, `vp9_d3d11va2`; `DecodeSession.SelectHardware` selects `AV_PIX_FMT_D3D11`. The `*_d3d11va`/`AV_PIX_FMT_D3D11VA_VLD` variants are not used. Software AV1 uses dav1d: the native `av1` wrapper and `av1_d3d11va2` are not required. If native AV1 hardware selection is added later, both must be audited together.
- Output: MP4 muxer, seekable `file` protocol, faststart/trailer support. `file` is the only protocol whitelist entry. HLS/DASH/concat and network protocols are not required. `swscale` handles BGRA/NV12 conversion and scaling; `swresample` handles float resampling and explicit channel matrices.
- HDR: the shipping build may omit zscale and its external dependency. `Ffmpeg/ToneMapper.cs` checks for zscale and describes the optional `buffer,buffersink,zscale,format,tonemap,scale` graph; `VideoDecoder.cs` otherwise uses swscale, and the CLI prints the architecture 6.5 notice. libzimg's WTFPL-2.0 is outside the project's licence allowlist, so it is **not** an approved shipping dependency or a native-test requirement. A future exception needs a lead licence decision, pinned sources and notices/About changes before enabling it.
- WAV and SRT are managed writers. No FFmpeg SRT muxer, subtitles/ASS filter, libass, font renderer, CLI programs or lavfi sources are application dependencies. ffprobe is optional verification tooling.

## Merge adapters and W contracts

Main `b327e33` was merged normally in `a9524af` (parents `c809947`, `b327e33`); both sides of `apps/windows/CONTRACTS.md` were preserved. The continuation did not re-merge, edit `doc/`, touch another worktree, or push. This track owns no W item.

W2 and W3 are real integrations now: `FfmpegAudioExtractor` streams through `AudioEnvelopeBuilder.Append` and uses `Finish().Rms` for both outputs. CLI editing calls `EditingEngine.FromProject` and `ApplyToProject`; audio uses `EditPlan.JoinGain`. Both old adapters and their obsolete TODOs are deleted. The remaining adapters target W5/W6/W7 only:

| Adapter | W item and intended call |
| --- | --- |
| `ServicesMergeAdapter.Models` / `ModelStorage` | W5: `ModelCatalog(sharedRoot)` / `ModelStore(catalog, locations, http)`. |
| `ServicesMergeAdapter.Transcription` / `TranscribeAsync` | W5: `ElevenLabsTranscriber(keys,http)`, `WhisperNetTranscriber(models)`, `TranscriptionService(engines,locations)`, and `ITranscriptionService.TranscribeAsync(request, extracted.Envelope, progress, ct)`. |
| `ServicesMergeAdapter.GlyphShaper` / `Rasterizer` | W6: `HarfBuzzGlyphShaper(sharedRoot)` / `SkiaCaptionRasterizer(sharedRoot)`. |
| `ServicesMergeAdapter.LlmModels` / `Connector` / `Runner` | W7: `LlmCatalog.Load(sharedRoot)`, `LlmConnector(id,keys,processes,catalog,http)`, existing injected `LlmRunner(keys,catalog,redactor)`. |
| `AiMergeAdapter.CreateClipFinderAsync` | W7: `ClipFinder(runner, connectorFor, sharedRoot)`. |

`ProjectStore.ReplaceTranscript`, `EditingImport.Pipeline`, `EditingFormat.ToFixed1` and `EditingLimits` are available from the editing merge. The CLI no longer replaces a saved project's transcript: `.voxclip` plus `--transcript` is a usage error. Only dry-run prompt payload, typed feature gates and the W5/W6/W7 services remain sibling integration TODOs. Missing sibling APIs fail closed. `CONTRACTS.md` now describes the actual code rather than the pre-merge baseline.

## Decisions 1–8 audit

1. **Cue-less Matroska seeks:** `cb68145` enables the indexed video stream only around `av_seek_frame`, restores `AVDISCARD_ALL` in `finally`, and uses the audio stream when the video has no index entries. `generate-fixtures.sh` creates `coarse-clock-nocues.mkv` with `-f matroska pipe:1`. Both cued and cue-less fresh-decoder late/backward seeks passed on the VM, including the strict `< fileLength / 20` I/O bound after the first seek, packet bound and half-tick sample alignment.
2. **Rollback never loses a file:** `8937785` attempts all restores, retains only failed-restore backups and reports their exact file names. `FailedSrtRestoreKeepsItsBackupAndStillRestoresTheMp4` passed on Mac with fault injection and on Windows with a held SRT handle: WAV publication fails, MP4 is restored, the SRT backup remains and no other backup or partial remains.
3. **CLI parity:** `d64f2d5` / `3e98eed` cover every remapped exit code and `(0, 60]` fps limits. `65f5882` checks unusable/colliding outputs and unknown clips before expensive work. `669d3e5` independently tests the exact project/transcript usage error, including an absent input. `635ec12` writes WAV at the plan rate and length; both 48 kHz and 44.1 kHz native cases passed. Native acceptance exposed additional path bugs fixed in `9452f17`: Windows device roots are special files, and symlink targets are canonicalized through their parents. Error-copy tests respect canonical paths and home-directory redaction.
4. **Real W2/W3 adapters:** `0e80d68` / `054ec96` use the real streaming envelope and editing APIs and delete the old adapters. `21063e4` verifies every old/new fade gain bit at 44.1/48 kHz, including short ranges, and every native stereo PCM output sample through `EditedAudioReader`. Those tests passed. `6e6dca4` reconciles the contracts ledger and leaves W5/W6/W7 pending.
5. **PlaybackFaulted:** `8e95911` adds the exact no-op interface default, keeping consumers that omit the event compilable. The recovery/liveness tests passed. `6e6dca4` records win-ui's remaining action: subscribe, dispatch to the UI thread, display the recoverable fault inline and unsubscribe on disposal.
6. **Test isolation:** `6e6529a` uses `Directory.CreateTempSubdirectory("voxclip-media-tests-")`; generated fixtures resolve from the test project, not the shared-directory override. Shared-checkout status before and after all Mac tests is identical: only the pre-existing `.agents/`, `.claude/` and `skills-lock.json` untracked entries. No new shared-checkout files were created.
7. **Scope and cost:** `d64790d` drives the real CLI `ExportAsync` through publication without edit flags. The stored `w3`–`w7` clip produces kept samples `[50400,174000)` and a `Clip("stored")` target, versus `[0,336000)` for a full media export. The positive media case supplies a transcript and reuses exactly one injected input probe through preparation/publication; unknown-clip cases also stop after one probe, before transcript loading/transcription. Both positive cases passed on both hosts.
8. **Native acceptance:** `736a0e8` stages the checked test archive inside the owned VM scratch and runs every native/Windows case without exclusions. The first native run exposed a real initial-AAC-seek silent frame; `4c65e2e` retains preroll before presentation zero. `00c0a2b` tests fresh/repeated zero-seek alignment and bounded AAC waveform error; lossless join tests remain bit-exact. Final Media result is 181/181 passing with zero skips. The 9.5 cases remain blocked by absent canonical fixtures, listed below. Three inherited Windows Core failures also keep the aggregate runner nonzero.

## Round-4 verification

Final source and tests verified at `00c0a2b`; this handoff is the only subsequent change. All Mac commands ran from `apps/windows` with `VOXCLIP_SHARED_DIR=<repo>/shared`. Core also used `VOXCLIP_SCHEMA_PYTHON=<python>` with `jsonschema` and `referencing` installed.

| Host / command | Result |
| --- | --- |
| Mac: `dotnet build VoxClip.CrossPlatform.slnf -c Release` | Passed, 0 warnings / 0 errors. |
| Mac: `dotnet test --project tests/VoxClip.Core.Tests -c Release --no-build` | 345 total: 339 passed, 6 skipped, 0 failed. |
| Mac: Media with `--filter-not-trait Category=RequiresFFmpeg --filter-not-trait Category=RequiresWindows` | 144 total: 144 passed, 0 skipped / failed. |
| Windows ARM64: clean archived-source Release build | Passed, 0 warnings / 0 errors, 25.17 s. |
| Windows ARM64: full Media, no trait filters | 181 total: 181 passed, 0 skipped / failed, 12.89 s; all 37 native/platform cases included (8 Windows cases). |
| Windows ARM64: Core | 345 total: 337 passed, 5 skipped, 3 failed. |
| Windows ARM64: CLI probe, encoder enumeration and video-only MP4 export | All exited 0. Software Media Foundation selected; video-only result reports 48,000 Hz / 0 audio samples. |

The Windows results include the real failed-SRT-restore handle test, every publication failure position, cancellation rollback, cued/cue-less seek bounds, native 44.1 kHz WAV output, bit-identical stereo PCM joins, AAC priming and seek-to-zero, HDR fallback, HEVC Main10, corrupt-input CLI mapping, H.264/AAC exports and video-only 48 kHz metadata. No missing decoder, demuxer or parser surfaced in those exercised cases. The absent 9.5 VP9/Opus fixture is not certified by that statement.

The inherited Windows Core failures are all in unchanged win-editing code/tests:
- `SettingsStoreTests.ReplacementsAreAlwaysWholeJsonAndFlushWritesOnlyTheLatestSnapshot`: sharing violation opening `settings.json`, test line 119.
- `SettingsStoreTests.InvalidUtf8SettingsArePreservedAndRecoveredAsDefaults`: expected LF but the Windows serialized JSON contains CRLF, test line 56.
- `SettingsStoreTests.EveryWriterOutputPassesTheRealDraft202012Schemas`: the VM's `python` resolves to the Microsoft Store alias, not a working interpreter, test line 247.

They were not hidden, excluded or fixed in this media track. The full runner exits nonzero because of them even though all Media tests and CLI smoke checks pass.

## Architecture 9.5 CLI cases

**Blocked, not passed:** neither this worktree nor the configured shared checkout contains `shared/fixtures/media/`, its canonical `index.json`, the six media files or their transcript companions. No substitutes were generated and no 9.5 media assertion is claimed. Restoring that fixture set and merging the W6 caption implementation are lead integration prerequisites.

| Case id | Status / missing canonical input |
| --- | --- |
| `e2e-1-chirp-cut-fillers` | Blocked: `fillers-chirp.mp4` and transcript. |
| `e2e-2-tone-joins` | Blocked: `joins-tone.mov` and transcript. |
| `e2e-3-captions-vox-bold` | Blocked: `fillers-chirp.mp4` and transcript; W6 is also still a placeholder. |
| `e2e-3-captions-vox-highlight` | Blocked: `fillers-chirp.mp4` and transcript; W6 is also still a placeholder. |
| `e2e-4-style-off` | Blocked: `fillers-chirp.mp4` and transcript. |
| `e2e-5-everything-cut` | Blocked: `fillers-chirp.mp4` and `fillers-only.transcript.json`. |
| `e2e-6-big-source` | Blocked: `big-2400x1350.mp4`. |
| `e2e-7-counter-9x16` | Blocked: `counter-1080p.mp4`. |
| `e2e-8-bars` | Blocked: `bars-1080p.mp4`. |
| `e2e-9-tiny-webm` | Blocked: `tiny.webm`; VP9/Opus acceptance is pending. |

All three bounded native runs released only their own lock and deleted their archived source/build/media/native-library scratch. A bounded SSH read confirmed the final `source-win-media-1792935901-62318` directory was absent and the lock was free. Final Windows logs are in ignored `.runs/win-media-1792935901-62318/`; final Mac logs and native run transcripts are in ignored `.runs/round4/`. No native DLL, ZIP or generated fixture is tracked. Long HEVC/WASAPI audible gaplessness, 50-join drift, physical device unplug, hardware encoder bitrate and x64-iGPU performance remain physical-hardware acceptance work.
