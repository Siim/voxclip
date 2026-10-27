# win-media handoff

## 2026-10-26: Voice Lab composition R5 real caption collision correction

R4's `full-preview-collision-1280x720.ppm` was made with a real caption track
whose page `Start`, `End`, `Block` and `Visual` were then replaced in the test.
It proved the overlay responds to supplied bounds, **not** that a normally
laid-out caption collides with the chip. Preserve those R4 captures as prior
evidence with that limitation. The R5 test source is commit
`d8db903e5c67f784ee9d698c9b904216c053704e`.

R5 stores caption position `(0.12, 0.08)` in an isolated synthetic v3 project,
reruns `VoiceLabRenderContract.Prepare` for full scope, captures the exact
project/request pair, and builds the `vox-bold` track from the prepared output
words with `CaptionEngine`. It changes no `CaptionPage` geometry or timing.
The test checks that a produced page intersects the preferred top-left chip
region during the disclosure interval, that the visible `WHOLE` glyphs render
at 0.3 s, and that the chip moves to the opposite top corner without covering
those glyphs. It checks caption-off preview and decoded MP4 at the same 0.3 s,
then uses `PreviewEngine` and `Exporter` with the caption-on request and reads
the resulting decoded export frame. The ARM64 and x64 frames visibly show a
legible `WHOLE` caption at top left and `AI MODIFIED` at top right. The source
is still the seven-second 1280×720 synthetic fixture, not app UI or a real
provider workflow.

The exact committed source ran on the Windows ARM64 VM using the existing
audited `win-arm64-1` and `win-x64-1` FFmpeg ZIPs/reports. ARM64 Release build
had zero warnings/errors; x64 self-contained publish succeeded. Each RID had
2/2 separate loaded-six-DLL identity tests and 2/2 affected production route
cases, with zero skips and failures. x64 ran under ARM64 emulation, not on a
physical x64 host. The local portable class run had 27 passes and 13 expected
Windows skips. R5 did not rerun the broader shipping, tempo diagnostic or
converter suites; no production, pin or dependency code changed. The R4
nonunity fit refusal and app/CLI active-synth guards remain.

R5 frames, loaded-module reports, logs and test scripts are in
`/tmp/voxclip-win-media-r5-d8db903/`. Inspect
`evidence-arm/full-preview-collision-1280x720.png` and
`evidence-arm/full-decoded-export-collision-1280x720.png`, or the matching
`evidence-x64/` files; the PPM originals are retained. The caption-off frames
at the same time are named `full-preview-1280x720` and
`full-decoded-export-1280x720` in each RID folder.
After evidence retrieval, the R5-owned VM source/runtime/build scratch and
lock were removed (`RELEASED=True`, `OWNED_SCRATCH_REMOVED=True`); final VM
free space was 8,629,608,448 bytes.

## 2026-10-26: Voice Lab composition R4 final exact-unity source acceptance

The **native-tested source head** is
`258776691f363d77a98d4cde9fcd35d37b840ce2` on `track/win-media`.
Only Windows Media source/tests plus the authorized
synthetic fixture and its generator documentation changed in this round. The
new `voice-lab-7s-720p.mkv` is 856,604 bytes; its committed SHA-256 is in
`shared/fixtures/voice-lab/media-render-README.md`. The frozen Voice Lab
README, contract and rewrite prompt remain byte-identical at SHA-256
`c86de4a9e0e75e480c3abf1a01514e7aa52f854448c14155d8e95947ac4dd69c`,
`a5729f04af4b56f2c45a9b8e83f5526cd92cc13e4f2b8382209581847a250a5c`, and
`01e4f9ed85ef6d84c20a924224a69cec2191de3588141fe60a36c8d8f3e55021`.

The committed archive used `git archive --format=tar HEAD apps/windows shared
THIRD_PARTY_NOTICES.md`. On the exclusive Windows ARM64 VM it ran
`powershell -NoProfile -ExecutionPolicy Bypass -File
C:\voxclip-build\win-media\source-win-media-r4-97b9aa02537\run-arm.ps1`
with the audited `win-arm64-1` ZIP/report, then the corresponding
`run-x64.ps1` with the audited
`win-x64-1` ZIP/report and a self-contained x64 test executable under ARM64
emulation. The retrieved script copies are
`/tmp/voxclip-win-media-r4-arm.ps1` and
`/tmp/voxclip-win-media-r4-x64.ps1`. They use `dotnet build
VoxClip.CrossPlatform.slnf -c Release -m:1`, `dotnet publish
tests\VoxClip.Media.Tests\VoxClip.Media.Tests.csproj -c Release -r
win-x64 --self-contained true -m:1`, and the test executable's `-class
VoxClip.Media.Tests.VoiceLabAudioMixerTests` filter. Both ZIPs, pin,
build-input digest and each extracted six-DLL set
were checked before tests. Each test process checked its **loaded** six DLL
paths, sizes and hashes, architecture, LGPL licence and FFmpeg configuration
against the RID report. ARM64 Release solution build passed with 0 warnings
and 0 errors; x64 self-contained test publish passed. Identity was 2/2 and
the focused `VoiceLabAudioMixerTests` class was 40/40 per RID, with 0 failures
and 0 skips under `VOXCLIP_REQUIRE_NATIVE=1`. The 27 portable mixer tests
passed locally. No unchanged eight-vector tempo diagnostic or broad strict
suite was rerun.

Those native tests covered the existing passage and new production full-take
two-chunk and touching-segment routes through the real edited-WAV writer and
marked MP4 exporter. The full take had two distinct chunk tones; touching
segments used different private paid-asset snapshots and verified both sides
of the centered seam. Source spans remained source audio. Native source-only
clip exclusion and a disabled segment used the legacy edit plan and published
unmarked output without opening a paid snapshot. Exact 1 and the adjacent
binary doubles below and above 1 wrote real 336,000-frame WAVs; stored
`1 + 1e-9` returned typed unverified-fit refusal before paid snapshot/output,
with original paid bytes intact. The empty edited-WAV timeline now returns
`EverythingCut` before capacity or partial creation, matching the existing
CLI/exporter ordering. Native all-output staging used real production WAV,
MP4 and sidecar, plus captions-off SRT; injected publication failure and
cancellation restored prior MP4/SRT/WAV/sidecar bytes and removed owned
partials. A Windows volume-GUID path and owned junction were grouped with
the scratch drive path by the real resolver; only available capacity was
overridden to prove the early low-space refusal. No second physical volume
was claimed.

The actual `PreviewEngine` loaded private synth assets, started WASAPI,
advanced on the device clock, paused, sought, resumed, replaced its graph and
disposed without a new dangling `voxclip-voice-*` snapshot. This passed in
the VM's available audio endpoint from SSH; it does not certify audible
quality or device-unplug behavior. At 1280×720 the same production compositor
rendered caption-off preview, a caption-track with test-replaced collision
bounds (moving the interval-wide chip to the opposite top corner), and decoded MP4 export.
Native test assertions counted the label's dark field and separated bright
glyph columns, not just changed frame bytes. The actual ARM64 frames are at
`/tmp/voxclip-win-media-r4-97b9aa02537/evidence-arm/full-preview-1280x720.ppm`,
`full-preview-collision-1280x720.ppm`, and
`full-decoded-export-1280x720.ppm` in that directory; the x64 counterparts
are in `evidence-x64/`. These are compositor frames, not app UI.

Independent inspection of all six final synthetic MP4/WAV pairs is recorded
in `/tmp/voxclip-win-media-r4-97b9aa02537/aac-wav-independent.json`.
Each WAV had exactly 336,000 stereo float frames. Each MP4 had 330 AAC
packets; its first packet PTS was −1024 with a measured 1024-sample skip.
FFmpeg decoded 336,896 frames after that skip, leaving 896 measured tail
frames beyond the WAV's logical output. Zero-lag WAV/AAC correlations at
source, chunk and touching-segment probes were 0.9999139–0.9999995. This
padding is observed for these six files, not a universal AAC constant.
Independent top-level ISO BMFF parsing found exactly one Adobe XMP UUID in
each MP4, with the required DigitalSourceType, and matched every final MP4
SHA-256 to its sidecar. The loaded-module and XMP review is in
`/tmp/voxclip-win-media-r4-97b9aa02537/native-identity-xmp-independent.json`.
The per-RID native logs, output files and frames are retained under that
owned `/tmp` evidence directory.

No nonunity pitch-preserving fit was accepted: atempo's body/seam placement
remains opaque as described in the R3 evidence and
`/tmp/clipper-planning/reviews/voice-fit-timing-r1.md`. App and CLI active
synth guards remain, and this synthetic route does not certify consent UI,
live generation/providers, changed-duration video, lip sync, installed-app
behavior or physical x64 performance. The final VM lock and owned source/
build/runtime scratch were removed only after evidence retrieval:
`RELEASED=True`, `OWNED_SCRATCH_REMOVED=True`, free `8,645,165,056` bytes.

## 2026-10-26: Voice Lab composition R3 native evidence and limits

The frozen `shared/fixtures/voice-lab/README.md` is restored byte-for-byte
(SHA-256 `c86de4a9e0e75e480c3abf1a01514e7aa52f854448c14155d8e95947ac4dd69c`).
The synthetic source generator and its committed hash live in the new
[`media-render-README.md`](../../../../shared/fixtures/voice-lab/media-render-README.md).
The source fixture SHA-256 remains
`6be0c2e01c675805f2cb61b0e0a31ec1980be433a23daf8897ebb18443cbcf39`;
the frozen Core contract SHA-256 remains
`a5729f04af4b56f2c45a9b8e83f5526cd92cc13e4f2b8382209581847a250a5c`.

Native source commit `ec350c6` ran from an owned archived scratch directory on
the exclusive Windows ARM64 VM, first as native ARM64 and then as self-contained
x64 under emulation. Both audited runtime ZIPs matched the committed pin and
build-input digest `fd879b5d763b4bbb4fc3af17da076a6d2e96e5a20661cbeae468adb067a0827f`.
All six extracted DLLs matched each RID report by size and SHA-256. The test
processes each checked their own **loaded** DLL paths, sizes, hashes, process
architecture, FFmpeg configuration and LGPL licence: separate identity,
atempo diagnostic and production passage processes on each RID. The local
copies of those six process reports match the exact audited reports. Release
ARM64 build and x64 self-contained test publish passed with zero errors or
warnings. Per RID, identity 2/2, diagnostic 8/8 and production passage 1/1
passed with `VOXCLIP_REQUIRE_NATIVE=1`, zero skips.

The eight graph diagnostics per RID retained actual first PTS (all zero),
frame counts, minimum versus excess handle lengths, both marker positions
and measured pitch (428–434 Hz for the 440 Hz source). The assumed linear
body-origin marker error ranged from −341 to −1 frames. These measurements
**do not accept** nonunity fit. The typed refusal still precedes paid copies
and output creation. The read-only timing review at
`/tmp/clipper-planning/reviews/voice-fit-timing-r1.md` confirms that atempo's
correlation shifts fragment positions and that PTS/count alone cannot prove
body or seam placement. Its DSP prime/drain/crop proposal is unverified.

The production passage test exercised real preview load/seek/frame, exact
336,000-frame 48 kHz WAV, 210 video frames, marked MP4, final-file sidecar
hash and cancellation with previous MP4/sidecar bytes preserved. Independent
ISO BMFF parsing found one top-level Adobe XMP UUID box with
`compositeWithTrainedAlgorithmicMedia` on each RID; independent SHA-256 matches
each sidecar. Separate AAC decoding yielded 336,896 stereo frames per RID:
the first packet declares 1,024 priming samples to skip, leaving 896 tail
padding frames after the 336,000 logical frames. At 1.0, 2.8 and 4.0 seconds,
the decoded MP4 and WAV have zero-lag correlation above .9999 and the intended
source/synthetic/source tone regions. This is passage evidence, not full-take
or touching-seam production acceptance.

Evidence is in `/tmp/voxclip-win-media-r3-9b15fa4a5503/`: per-RID test logs,
eight tempo JSON files, three loaded-module reports, preview PPM, WAV, MP4
and sidecar. The 160×90 preview frame is genuinely rendered at 2.8 seconds,
but its 2.16-pixel disclosure font is not legible by visual inspection at
that resolution. The current production test checks changed frame bytes,
not readable label pixels; a larger-output visual assertion remains. The
test does not call WASAPI `PlayAsync`/Pause/Seek/dispose, and no native
full-take/touching production, all-output publication rollback, or actual
Windows volume-GUID alias test ran in this slot. No physical x64 performance
claim is made.

After releasing the VM, a narrow Media fix replaced the `1e-8` unity bypass
with one binary-double ULP on either side of 1. Decimal duration arithmetic
in the frozen passage fixture stores `0.9999999999999999`; it remains a unity
recipe, while a genuine `1 + 1e-9` stored ratio requires fit and cannot use
the wave path. The focused local `VoiceLabAudioMixerTests` run passed 26,
skipped the Windows-only native passage case once, failed zero. This final
source change was **not rerun natively**; the earlier native passage and
diagnostics apply to `ec350c6`. App and CLI active-synth guards remain.

The VM never went below 6 GiB free or over 2 GiB owned scratch. After logs
and artifacts were retrieved, only token `win-media-r3-9b15fa4a5503`'s
scratch and matching lock were removed. Final VM check:
`RELEASED=True`, `OWNED_SCRATCH_REMOVED=True`, free `8,656,207,872` bytes.

## 2026-10-26: Voice Lab composition R2 corrections and native gate

R2 moves the physical source-size check from Core `CaptureSnapshot` to Media
preparation. Core still freezes the plan, captions, and geometry, and now
rejects non-finite caption duration and page times. Media checks the source
before paid snapshots or output creation. A capacity preflight groups the
selected paid snapshot bytes, every fitted stereo float stage, and the peak
WAV or marked MP4/XMP/sidecar/SRT/rollback bytes by actual volume. The CLI
checks its combined WAV and video transaction before its first partial. Long
paid copies, tempo stage creation, XMP copying, and sidecar creation recheck
remaining available space. The query boundary has low-space, same-volume,
overflow, source-size, alias-grouping and distinct-volume regression cases.
Windows resolves drive and mounted-folder aliases to one volume GUID before
budgeting; separate volumes are queried independently. No development-machine
free-space reserve is built into the product check. The Windows volume API
resolution itself still needs a native run.

WAV and CLI atomic writers now delete only partials they created and pass the
caller cancellation token through publication. The CLI's combined transaction
also tracks which partials it owns. The MP4 XMP stage is deleted by the exporter
only after the disclosure writer returns an owned stage; the writer itself
removes a stage it created if its copy fails. Creation-race tests retain another
writer's partial and preserve the existing destination.

The audited `9ad75f` atempo runtime has a working filter, but the independent
R2 native report found nonproportional marker placement and count residuals
in both directions. A zero first output PTS does not establish the body or seam
origin. Nonunity composition therefore returns a typed timing refusal before
copying paid assets or opening outputs. The bounded production graph remains
available to `VoiceLabNativeTempoTests` as a diagnostic: eight rate/channel/
ratio/handle vectors record actual first PTS, frame count, and two marker
positions to `VOXCLIP_VOICE_EVIDENCE_DIR`. A committed 964 KiB seven-second
48 kHz PCM/MPEG-4 test source drives `NativePassageUsesProductionWaveComposerAndMarkedExporter`
through real preview frames, the edited WAV writer and the marked MP4 exporter.
The latter checks source/synthetic frequency regions, exact logical WAV and
export frame counts, preview disclosure with captions off, independently
extracted top-level MP4 XMP and the final MP4 sidecar hash. These Windows
native cases are prepared but **not yet acceptance evidence**; run with
`VOXCLIP_REQUIRE_NATIVE=1` so missing prerequisites fail, on each audited RID
after an explicit exclusive VM handoff. The App and CLI active-synth guards
remain in place.

Local Mac Release cross-platform build passed with zero warnings/errors.
Focused Media `VoiceLabAudioMixerTests`: 25 passed, one Windows-only skip,
zero failed. `CliOutputParityTests`: 44 passed, four native prerequisite skips,
zero failed. `VoiceLabDisclosureTests`: six passed. `OutputSafetyTests`:
14 passed. The new production passage test exercises preview load/seek/frame,
but not WASAPI `PlayAsync`; it checks logical MP4 audio sample count but does
not decode AAC to compare sample timing or priming. No native full-take or
touching-seam production route is prepared. The passage cancellation assertion
has not run on Windows. These, plus WAV/all-output transaction failure and
cancel checks, remain required before route acceptance.

After the parent grants the exclusive VM slot, use an archived checkout of this
HEAD under `C:\voxclip-build\win-media\` and the matching audited DLL/report
for each RID. Recheck free C: >= 6 GiB, owned scratch <= 2 GiB, all six DLL
hashes/sizes and loaded-module identities before a composition run. Set
`VOXCLIP_DATA_DIR` to an isolated owned folder,
`VOXCLIP_LIVE_TESTS=0`, `VOXCLIP_TEST_DOWNLOAD=0`,
`VOXCLIP_REQUIRE_NATIVE=1`, `VOXCLIP_FFMPEG_DIR` to that RID's six-DLL
directory, `VOXCLIP_SHIPPING_REPORT` to its matching report, and
`VOXCLIP_VOICE_EVIDENCE_DIR` to an owned report folder. Build the
cross-platform solution in Release with `-m:1`. Then run one test process at a
time, ARM64 native before self-contained x64 under emulation:

```powershell
# From the archived checkout's apps\windows directory, after the above gates.
$dotnet = 'C:\Program Files\dotnet\dotnet.exe'
$arm = 'tests\VoxClip.Media.Tests\bin\Release\net10.0\VoxClip.Media.Tests.dll'
& $dotnet $arm -class VoxClip.Media.Tests.ShippingRuntimeIdentityTests
& $dotnet $arm -class VoxClip.Media.Tests.VoiceLabNativeTempoTests -showLiveOutput
& $dotnet $arm -method VoxClip.Media.Tests.VoiceLabAudioMixerTests.NativePassageUsesProductionWaveComposerAndMarkedExporter -showLiveOutput

# With the independently verified x64 DLL/report, and the existing Release
# self-contained x64 test publish in .runs\x64-tests:
$x64 = 'tests\VoxClip.Media.Tests\.runs\x64-tests\VoxClip.Media.Tests.exe'
& $x64 -class VoxClip.Media.Tests.ShippingRuntimeIdentityTests
& $x64 -class VoxClip.Media.Tests.VoiceLabNativeTempoTests -showLiveOutput
& $x64 -method VoxClip.Media.Tests.VoiceLabAudioMixerTests.NativePassageUsesProductionWaveComposerAndMarkedExporter -showLiveOutput
```

Keep the 26-case atempo graph/PTS reports from the runtime owner alongside
these production-path results. Inspect the marker JSON and retained preview
PPM, WAV, MP4 and sidecar; a test failure is evidence, not a reason to relax
sample boundaries, substitute ordinary resampling or remove the typed fit
refusal. Confirm no optional prerequisite skip under the required-native flag.
The source fixture is 964 KiB at `shared/fixtures/voice-lab/voice-lab-7s.mkv`;
its exact generator command and hash are in `shared/fixtures/voice-lab/media-render-README.md`.

## 2026-10-26: Voice Lab mixed composition source handoff

The frozen Core v3 render plan now drives one Windows timeline for video frames,
caption times, disclosure and sample-exact audio. `VoiceLabRenderInput` takes a
verified detached project and checks the media source, grid, caption words and
output geometry again before native work. `VoiceLabRenderSession` prepares only
selected private paid snapshots before a preview is published or an export/WAV
partial is created; readers and callbacks stop before it releases them. The
bounded mixer uses two active WAV readers, two active fitted readers, one
room-tone run and one on-demand seam buffer, independent of segment count.
Full-take multi-chunk, passage, and conversion fixture cases include 48 kHz
source/24 kHz assets, trim and marker boundaries, source clip/cut fades and
scope inclusion/exclusion. A declared nonunity fit uses one FFmpeg `atempo`
stage for the body and both handles; absent filter capability refuses before
paid preparation or output. No raw rate-change fit is accepted.

The reviewed disclosure helper merge `4deca8f7b461fb5060d386aac0b5a4278a7ef0f7`
is integrated. The compositor draws a reused label after captions, with
interval-wide collision placement. After muxer trailer, the writer copies to
a distinct owned XMP stage, hashes the completed marked MP4, and returns the
sidecar bytes. `OutputSafety` publishes MP4/SRT/sidecar as one set; the CLI's
prepared transaction also includes an optional WAV. Existing files are
restored after publication failure or cancellation. The helper freezes
intervals/provenance before caller mutation and rejects chip geometry that
cannot contain both margins.

The exact audited atempo recipe source `9ad75f33539a12ab4855d02e6a75d7891e80266c`
is merged for testing, with build-input digest
`fd879b5d763b4bbb4fc3af17da076a6d2e96e5a20661cbeae468adb067a0827f`.
Both RID reports and ZIPs are under
`~/Library/Caches/voxclip-ffmpeg-atempo-20261026/reports/{win-x64-1,win-arm64-1}`.
This source integration does not accept the native graph or runtime behavior.

Local Mac Release verification with isolated `VOXCLIP_DATA_DIR`, live and
download switches off: cross-platform solution build passed with zero warnings
and errors; full Core passed 1,375 with 27 expected skips and zero failures;
full Media passed 441 with 62 expected skips and zero failures. The focused
Voice Lab/CLI selection passed 69 with four native prerequisite skips. These
portable runs exercise pure mixing, request freezing, disclosure staging and
transaction rollback. They do not run Windows WASAPI, the shipping FFmpeg
graph, preview/export video, or native output decoding.

**Next exclusive Windows slot:** verify all six loaded DLL identities for the
selected RID against its exact audited report and ZIP before native tests.
Use one test process, at most two compile jobs, isolated data/live flags off,
6 GiB VM free space and at most 2 GiB owned scratch. Exercise `atempo`
capability plus passage/touching-seam body and handle pitch/EOF, preview
replacement/cancellation, exact WAV and decoded MP4 sample/frame timing
(including AAC priming), source-frame/caption/disclosure order, independently
extracted XMP, sidecar final hash, and existing-output rollback. Test both
native ARM64 and emulated x64 separately. The App owner must wire and verify
its guarded route afterward. The CLI active-synth guard also stays active;
there is no provider, real-voice, physical-hardware, push or release claim.

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
VOXCLIP_FFMPEG_ZIP="$HOME/Library/Caches/voxclip-ffmpeg-atempo-20261026/reports/win-arm64-1/voxclip-ffmpeg-n9.0.2-win-arm64.zip" \
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

Evidence and the audio device have their own gates. `NativeTest.Require`
covers native prerequisites: Windows, the FFmpeg DLLs and their demuxers and
filters, generated fixtures and committed sources; `VOXCLIP_REQUIRE_NATIVE=1`
makes their absence a failure. `NativeTest.RequireEvidence` covers what only a
VM or release run produces: `VOXCLIP_SHIPPING_REPORT` with
`VOXCLIP_MODULE_EVIDENCE`, and the `VOXCLIP_APP_EVIDENCE_DIR` and
`VOXCLIP_DYNAMIC_APP_EVIDENCE_DIR` App export folders. Without them those tests
skip and name the missing input, even under `VOXCLIP_REQUIRE_NATIVE=1`.
`VOXCLIP_REQUIRE_VM_EVIDENCE=1` turns that skip into a failure.
`verify-windows.ps1 -ShippingAcceptance` sets it, and `verify-vm.sh` passes it
whenever `VOXCLIP_SHIPPING_RID` is set. Set it yourself for any other run that
supplies evidence, such as a manual App-evidence run.
`NativeTest.RequireAudioOutput` needs a default audio render endpoint for
`NativePreviewPlaysPausesSeeksAndReleasesSynthLease`, the only Media test that
opens a real WASAPI device. `VOXCLIP_REQUIRE_AUDIO_OUTPUT=1` turns its skip into
a failure. `verify-windows.ps1` sets it for both of its VM runs: the full run,
whose `tests` step runs the whole Media suite, and the shipping-acceptance run,
whose `shipping-preview-audio` step runs that one test against the shipping
DLLs. `verify-vm.sh` passes it to every run it starts. Hosted runners have no
audio device, so hosted CI never sets `VOXCLIP_REQUIRE_AUDIO_OUTPUT` and the
test skips there, naming the flag. Hosted CI requires native inputs but never
sets `VOXCLIP_REQUIRE_VM_EVIDENCE`, and it loads the test-only FFmpeg tools.
The Voice Lab tempo graph, mixer and native
route tests therefore assert behaviour on whichever FFmpeg is loaded, and add
the loaded-module comparison whenever the shipping report is supplied. A hosted
pass of those tests says nothing about shipping identity.
`LoadedModulesMatchShippingReport` and
`PcmFloatWavDecodesAndSeeksWithShippingDlls` pass only after that comparison.

Logs, E2E JSON/CSV reports, `loaded-modules.json` and
`loaded-cli-modules.json` are copied into the
ignored `.runs/<owner>/` directory before the owned VM scratch is removed.
`VOXCLIP_VM_SCRATCH` names that scratch's one track directory under
`C:\voxclip-build` (default `win-media`); `verify-windows.ps1 -ScratchRoot`
refuses to run outside it.
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
