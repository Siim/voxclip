# VoxClip Windows skeleton

Native WinUI 3 shell and fixed .NET contracts for parallel implementation. This is a **compiling skeleton**, not a functional editor: media, editing, model downloads, speech, captions and LLM service stubs fail with `VoxClipException(NotImplemented, "<track-id>")`. Safe startup/status placeholders return empty collections or unavailable states. The app does not load FFmpeg, download models, use credentials or perform paid/network operations at launch.

Read [`CONTRACTS.md`](CONTRACTS.md) before implementation. The architecture and shared schemas live two directories above; do not copy shared data into source projects. The six projects follow architecture §2.3. `VoxClip.Core` has **no NuGet dependencies**. Media depends on Core; App and CLI depend on both. The application version comes only from `Directory.Build.props`.

## Prerequisites

- .NET 10 SDK; `global.json` accepts the latest installed .NET 10 feature band (verified with macOS 10.0.102 and Windows 10.0.402).
- WinUI builds require Windows and the pinned SDK/App SDK packages; no Visual Studio template or global tool installation is required for this scaffold.
- An intact repository `shared/` tree, or `VOXCLIP_SHARED_DIR` pointing to it. The project Content links copy runtime assets to `shared/` in App/CLI output, excluding fixtures. Tests resolve fixtures directly from the repository.

## macOS: Core, Media, CLI and tests

Run in `apps/windows`:

```sh
dotnet build VoxClip.CrossPlatform.slnf -c Release
dotnet test --project tests/VoxClip.Core.Tests -c Release --no-build
dotnet test --project tests/VoxClip.Media.Tests -c Release --no-build \
  --filter 'Category!=RequiresFFmpeg&Category!=RequiresWindows'
dotnet run --project src/VoxClip.Cli -c Release --no-build -- version --json
```

`VoxClip.CrossPlatform.slnf` filters the main solution to five projects, excluding the Windows-only App. Do **not** build the full WinUI solution on macOS. Current xunit.v3 4.0.2 uses Microsoft.Testing.Platform v2; `global.json` opts into that runner. On .NET 10 use `dotnet test --project <project>` or `dotnet test --solution <solution>`, not the older positional project syntax. `--filter` is supported directly by the runner (no extra `--` separator). All fixtures are checked by reference, never copied into tests.

## Windows: unpackaged self-contained app

In PowerShell, in `apps/windows`, run **sequentially**:

```powershell
dotnet build src/VoxClip.App -c Release -r win-arm64 -p:Platform=ARM64 -m:1
dotnet build src/VoxClip.App -c Release -r win-x64 -p:Platform=x64 -m:1
dotnet build VoxClip.CrossPlatform.slnf -c Release -m:1
dotnet test --project tests/VoxClip.Core.Tests -c Release --no-build
dotnet test --project tests/VoxClip.Media.Tests -c Release --no-build
```

The platform-specific executables are under `src/VoxClip.App/bin/ARM64/Release/net10.0-windows10.0.26100.0/win-arm64/` and the corresponding `x64/.../win-x64/` directory. Launch `VoxClip.exe` from the matching directory. Mica requires a supporting desktop/OS; the shell still has a normal system background. Home contains recent-project placeholders, Open/Import navigation and Settings. Editor regions are intentionally empty, and the future AI inspector tab is disabled. A session-local mutex prevents duplicate running instances. Velopack executes before WinUI initialization.

The full `VoxClip.slnx` includes the App. For full-solution builds select `-p:Platform=ARM64 -r win-arm64` or `-p:Platform=x64 -r win-x64`. On a 4 GB VM, use `-m:1` and never run the two architecture builds concurrently.

## Native media dependencies

NuGet pins are centralized in `Directory.Packages.props`; see the root [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) for pinned sources and licences. Whisper.net CPU runtimes include **both win-x64 and win-arm64**; NoAvx is the x64 fallback. macOS native SkiaSharp/HarfBuzz assets let renderer tests run without Windows.

The FFmpeg DLLs are **not** fetched by restore or loaded at startup. After building the pinned shipping ZIP locally, stage and verify it on Windows:

```powershell
powershell -NoProfile -File build/Fetch-Ffmpeg.ps1 -RuntimeIdentifier win-arm64 -ZipPath 'C:\path\to\pinned-win-arm64.zip'
```

`build/ffmpeg.json` pins the self-built FFmpeg n9.0.2 LGPL shared ABI matching FFmpeg.AutoGen 9.0.1.1. Obtain the locally built ZIP from `tools/ffmpeg-build/` and pass it to `build/Fetch-Ffmpeg.ps1 -ZipPath <path>`; the script verifies its SHA-256, size and six ABI-named DLLs before staging them in `build/.cache/ffmpeg/<rid>/native`. `-TestTools` fetches a separately pinned, test-only FFmpeg distribution with `ffmpeg.exe`; never package that directory. Loader initialization, packaging and media fixture conformance remain win-media work. Never substitute a GPL build or x264/x265 for the shipping DLLs.

## Data, resources and CLI behavior

- `SharedResources.ResolveRoot`: `VOXCLIP_SHARED_DIR`, then installed `shared/`, then walk up to repository `shared/`; absence is `sharedResourcesMissing`.
- `DataLocations.Resolve`: `VOXCLIP_DATA_DIR` or `%LOCALAPPDATA%/VoxConvo/VoxClip`, with separate `Models`, `Cache`, `Autosave`, `Secrets`, `Logs` and `settings.json`. The resolver creates nothing and touches no existing data. Windows DPAPI persistence is not implemented.
- `FixtureLoader` requires `shared/fixtures`, so point its environment override to repository assets, not the installed runtime-only asset subset.
- CLI declares the complete architecture §9 tree, including `probe`, `transcribe`, `models list/install/verify/remove`, `plan`, all `render-caption` forms, `find-clips`, `llm-test`, `encoders`, `version`, and the primary export form. Use `--help` on any command. `version` succeeds; valid unfinished actions return `notImplemented`/exit 1. Invalid usage is 2, missing input is 3, cancellation is 6. Implementers preserve the remaining documented exit codes 4/5/7.
- Redaction, version comparison, output sizing/bitrate rules, source-generated project/style/settings serialization and resource/path resolution are implemented, not placeholders. Source word timings and unknown project `extensions` / settings keys survive round trips.

## Verification baseline

On 2026-10-25: macOS Release builds of all five non-UI projects passed with zero warnings/errors. Core tests: 17 passed, 5 explicitly skipped track placeholders; Media: 4 passed, 2 explicitly skipped platform/media placeholders (filtered macOS run: 4 passed). Shared project fixtures and all 19 caption styles decode with generated metadata; an ICU-backed NFC regression test protects architecture §2.3. Skia/HarfBuzz native loading works on macOS ARM64. Windows build results and any limitations are recorded with the handoff; real video/audio/export/caption golden conformance is deliberately **not** claimed by this skeleton.

Windows SDK 10.0.402 on the ARM64 Windows 11 VM builds the self-contained App for **win-arm64 and win-x64**, sequentially, with zero warnings/errors. The five-project solution filter also builds there; Core and Media tests have the same pass/skip counts as macOS, including native Skia/HarfBuzz loading on Windows ARM64. CLI smoke verification covers 24 JSON/exit-code cases and 11 help entrypoints. The FFmpeg fetch script passes the Windows PowerShell parser check; downloading/loading native FFmpeg and real media conformance remain untested stubs.

An SSH launch probe kept the App process alive, but SSH runs in **noninteractive Session 0** and exposed no visible window handle. This is not visual/UI-interaction verification; launch `VoxClip.exe` in the VM's interactive desktop for that check. No scheduled task, global tooling or files outside `C:\voxclip-build\skeleton` were created for this probe.
