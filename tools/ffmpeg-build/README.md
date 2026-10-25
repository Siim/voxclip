# Minimal Windows FFmpeg build

This is the only FFmpeg pin/build tool. It replaces the BtbN resolver rather
than accepting its LGPL label. The previous DLLs contained GPL FFTW through
Chromaprint, despite their `avcodec_license()` string. See architecture
section 6.1, release section 3.3 and [components.md](components.md).

`sources.json` pins FFmpeg **n9.0.2**, deliberately the requested 9.0 point
release, not a moving branch or "latest" release; nv-codec-headers, AMF,
libvpl, the official VideoLAN dav1d **1.5.4** source release, and the
llvm-mingw runtime/build sources are pinned too.
The two host toolchains are llvm-mingw **20261020 UCRT**, clang **23.1.4**.
Every download has an HTTPS URL, SHA-256 and byte size. Compiler/runtime
sources are included even where only a few archive members are linked.
No source checkout, submodule update, Cargo or dependency fetch happens.

AMF's pinned full repository archive also contains 79 unrelated prebuilt
sample/third-party binaries. Only its 57 public header files and root MIT
notice are used. The source pin's `includePaths` records that selection;
the release source packer must extract those paths rather than redistribute
the full AMF container (and its unrelated FFmpeg binaries). The original
download URL/hash remains in the source manifest for verification.

The tracked libvpl patch prevents its pre-MSVC-2005 fallback macros from
redefining MinGW's secure CRT functions before Windows headers are included.
The patch is part of the recipe/source handoff; no downloaded archive
bytes are changed. zimg is excluded: its WTFPL-2 licence is outside the
project allowlist, and architecture section 6.5 permits the existing
swscale HDR conversion and warning instead of the optional zscale graph.

## Run

Supported hosts: Apple-silicon macOS and Linux x86_64 (Ubuntu 22.04 or newer).
Host prerequisites: Python 3.11+, GNU `timeout`/`gtimeout`, curl, make,
CMake, pkg-config, Perl and the host C/C++ compiler. Ninja, NASM and Meson are
fetched from pinned source, not installed into the system. Dependencies are permissive and
FFmpeg is LGPL-2.1-or-later. GPU drivers and Windows system DLLs are supplied
by the operating system/vendor, not bundled.

```sh
python3 -I tools/ffmpeg-build/test_build.py
python3 -I tools/ffmpeg-build/build.py fetch
python3 -I tools/ffmpeg-build/build.py build --rid win-x64 --attempt 1 --jobs 2
python3 -I tools/ffmpeg-build/build.py build --rid win-x64 --attempt 2 --jobs 2
python3 -I tools/ffmpeg-build/build.py build --rid win-arm64 --attempt 1 --jobs 2
python3 -I tools/ffmpeg-build/build.py build --rid win-arm64 --attempt 2 --jobs 2
python3 -I tools/ffmpeg-build/build.py verify
python3 -I tools/ffmpeg-build/build.py write-pin
```

All downloads, temporary objects, ZIPs, logs and reports live under
`~/Library/Caches/voxclip-ffmpeg-build` (`--cache` overrides it). The driver
prints `df -h` before downloads, extraction and build phases; it stops below
15 GiB free or at a 6 GiB cache. At most two compiler jobs run. Each
architecture/attempt's entire build tree is removed in `finally`, including
on failure. `config.log` is never retained in reports or source archives.
No daemon, background polling, VM, upload or publish step is involved.

The ZIPs contain only the six ABI-named FFmpeg DLLs, with sorted paths,
stored bytes, a fixed 1980 ZIP timestamp and fixed permissions. Linker PE
timestamps are zero, debug data is stripped, compiler paths are mapped,
`SOURCE_DATE_EPOCH` is fixed, and configure uses a fixed extra version.
Both architectures must pass two independently extracted clean builds.
Build evidence includes a digest of the exact source lock and executable
recipe inputs; stale reports from a different recipe are rejected.
`verify` compares ZIP hashes and exact per-DLL bytes, saves differing byte
ranges if necessary, and refuses a nonidentical result. This is same-host
reproducibility; cross-host equivalence requires running on Linux as well.

Configure, Meson, Ninja and make run with a fresh, explicit environment:
pinned toolchain and host-tool paths, scratch config/cache/TMPDIR paths, C locale, UTC
and fixed build epoch. Caller `CFLAGS`, `CPPFLAGS`, include/library paths,
package paths, credentials and other variables cannot enter the build. `HOME`
is omitted from the subprocess environment; curl uses `-q` to ignore curlrc.
Toolchain/Ninja/NASM caches are keyed by their pinned SHA-256 and have a
completion marker; a partial or mismatched extraction is rebuilt atomically.

Reports retain the decoded exported `avcodec_configuration()` and
`avcodec_license()` function return strings without executing Windows code,
every DLL's architecture/imports/hash, resolved component list, full link
maps with LLD's verbose archive-extraction trail and the selected member
inventory. The COFF map alone omits archive origins, so the wrapper appends
the real linker's extraction evidence, not an inferred object-to-library
mapping. The source licence gate maps every linked FFmpeg object to its
pinned `.c`, `.S` or `.asm` file, fails on GPL-only headers, asserts that
ARM64 `crc.o` contributes no `.text`, and writes `FFmpeg-NOTICES.txt` from
linked permissive headers and dependency notices. It ships FFmpeg's
`LICENSE.md` and the full pinned MinGW runtime notice, including gdtoa.
The dependency gate resolves every loaded dav1d, libvpl, LLVM compiler-rt,
libc++/libc++abi, libunwind, MinGW CRT and winpthreads member to one source
in its pinned component and architecture. It rejects unknown archives,
ambiguous sources and unexpected direct objects. The only source-free
members are explicitly recorded Windows UCRT import records in
`libmsvcrt.a`; those reference system DLLs and redistribute no UCRT DLL.
Each report counts loaded members and lists those imports separately.
Generated notices contain the exact pinned LLVM component and winpthreads
licence texts as well as the MinGW runtime text.
The binary gate scans **all** DLLs for
unambiguous FFTW/x264/x265/postproc/Chromaprint/Rust supplier markers and fail
closed. The native H.264 decoder's `x264 - core %d` SEI recognition string is
not proof of a linked x264 encoder and is tested as such. Pattern scanning
supports the source/configuration audit; it does not replace it.

FFmpeg x64 and dav1d x64 assembly use the pinned NASM 2.16.03 source build;
dav1d ARM64 assembly uses clang's integrated assembler. ARM64 disables
arm-crc, pmull and eor3 to exclude FFmpeg's GPL-headed `aarch64/crc.S`.
AV1 uses dav1d software decode; native AV1 hardware wrappers are not needed
by the current media contract. Windows performance and device acceptance
remain separate from these cross-build checks.

## Binding compatibility without Windows execution

`abi-check/` reads only FFmpeg.AutoGen's managed constants. Pass the exact
9.0.1.1 assembly already used by win-media as the `BindingsAssembly` MSBuild
property; build into the cache, not a sibling worktree. Running its output
with the manifest path checks all six ABI majors without loading a DLL.
This is in addition to building the read-only media test-project snapshot;
it is not a Windows decoder/encoder runtime test.

## Release handoff

The schema-2 manifest keeps `sourceAssets`, configure and licence metadata,
but intentionally has **no BtbN URL or `btbnCommit`**. `builds` identifies
local ZIP names/digests, not unpublished HTTPS assets. Never turn local
paths into fake download URLs. The recipe is the tracked
`tools/ffmpeg-build/` tree from the release's `BUILD_COMMIT`; the release
source archive must include it, the pinned original source archives,
build tools and runtime sources, the manifest, licence texts and BUILD.txt.
`BUILD_COMMIT` is resolved to the release commit by the release reader, not
to an invented source tarball URL. The release driver stages verified ZIPs,
licences, notices and per-RID reports for the VM; it excludes `config.log`,
`build.log` and raw maps from the corresponding-source archive.

For Windows development, `apps/windows/build/Fetch-Ffmpeg.ps1 -ZipPath <zip>`
accepts a local self-built ZIP only after its size, SHA-256 and ABI DLL set
match `ffmpeg.json`. `-TestTools` fetches the separately pinned former BtbN
LGPL-labelled shared archive for CI's `ffmpeg.exe` fixture pushes. That test-only
archive is never an input to shipping DLLs or release packaging.

## Native regression inputs outside the shipping format subset

The shipping ZIPs enable only the MOV, Matroska and WAV demuxers. The
win-media R5 regression fixtures `start-zero.avi`, `start-zero.flv` and
`channels-switch.aac` need AVI, FLV and raw AAC demuxers; the FLV fixture
also needs FLV video and MP3 audio decode. They are synthetic edge cases,
not a request to expand the supported import formats. Run those cases with
the separately pinned **test-only** DLLs. The test archive is a BtbN build,
not an audited source-clean shipping artifact.

On the Mac, after `write-pin` has populated `ffmpeg.json`, prepare a flat
ARM64 test ZIP from the pinned original archive:

```sh
python3 -I tools/ffmpeg-build/prepare-test-tools.py --rid win-arm64
```

The helper checks the original SHA-256 before reading it, enforces the disk
floor, and prints the flat ZIP's path and SHA-256. Its `bin/` contains the six
ABI DLLs, the `avdevice` DLL needed by `ffmpeg.exe`, `ffmpeg.exe` and
`ffprobe.exe`. The output stays in the build cache and is **test-only**.
From a committed win-media checkout, its owner can run the existing locked
native regression runner after generating its fixtures:

```sh
sh apps/windows/tests/VoxClip.Media.Tests/generate-fixtures.sh
VOXCLIP_FFMPEG_ZIP="$HOME/Library/Caches/voxclip-ffmpeg-build/test-tools/voxclip-ffmpeg-test-only-win-arm64.zip" \
  sh apps/windows/tests/VoxClip.Media.Tests/verify-vm.sh
```

That runner transfers an archive of win-media `HEAD`, stages the flat ZIP in
its owned VM scratch, and runs the full native suite. The R5 cases are
`WindowsPipelineTests.IdentityExportAndPreviewAudioStartSeekFromZero` (AVI
and FLV rows) and `NativePipelineTests.DecoderReconfiguresWhenAudioChannelsChange`
(raw AAC). Check that each row passes rather than skips. `Fetch-Ffmpeg.ps1
-TestTools` is the direct Windows/CI path to the same pinned test-only tools;
it copies `avdevice-63.dll` alongside `ffmpeg.exe` and the six app DLLs.

The remaining codeload GitHub archives in `sources.json` are content-addressed by
SHA-256 and size: a server-side byte change fails closed. To re-pin, obtain
and review the replacement source, record its exact URL/size/SHA-256, then
rebuild both RIDs twice and review the licence/notice diff before updating
`ffmpeg.json`. Prefer upstream uploaded release tarballs where available.
