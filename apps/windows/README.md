# VoxClip for Windows

Native WinUI 3 app and `voxclip-cli` on .NET 10, unpackaged and self-contained, for win-x64 and win-arm64. Import, transcription, word editing, clips, Find Clips, captions, export, the share helpers and Velopack updates are integrated. The native redesign and Voice Lab beta work are tracked separately; see CONTRACTS.md for implemented behavior and outstanding native checks.

Read [`CONTRACTS.md`](CONTRACTS.md) before implementation. The architecture and shared schemas live two directories above; do not copy shared data into source projects. The six projects follow architecture §2.3. `VoxClip.Core` has **no NuGet dependencies**. Media depends on Core; App and CLI depend on both. The application version comes only from `Directory.Build.props`.

## Prerequisites

- .NET 10 SDK; `global.json` accepts the latest installed .NET 10 feature band (verified with macOS 10.0.102 and Windows 10.0.402).
- WinUI builds require Windows and the pinned SDK/App SDK packages; no Visual Studio template or global tool installation is required.
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

The platform-specific executables are under `src/VoxClip.App/bin/ARM64/Release/net10.0-windows10.0.26100.0/win-arm64/` and the corresponding `x64/.../win-x64/` directory. Launch `VoxClip.exe` from the matching directory. Mica requires a supporting desktop/OS; the shell still has a normal system background. On first launch the Windows component terms dialog comes first (doc/design.md §9); after that the window opens on Home. `AppInstance` keeps a single running instance: launching again activates the open window, and Ctrl+N opens another main window. Velopack executes before WinUI initialization.

The full `VoxClip.slnx` includes the App. For full-solution builds select `-p:Platform=ARM64 -r win-arm64` or `-p:Platform=x64 -r win-x64`. On a 4 GB VM, use `-m:1` and never run the two architecture builds concurrently.

## Windows: development test copy

Debug builds are development builds: Voice Lab reads as on until you set the switch, and Rewrite skips the beta notice (doc/spec/voice-lab.md section 5). A Release-config build behaves like a shipped one. To make a Release-config test copy a development build, add `-p:VoxClipDevelopmentBuild=true`:

```powershell
dotnet publish src/VoxClip.App/VoxClip.App.csproj -c Release -r win-arm64 --self-contained -m:1 -p:VoxClipDevelopmentBuild=true
```

Use `-r win-x64` for x64. Only `-p:` sets the property; an environment variable of that name is ignored. Never pass it to a release build. `build/` and CI never do, and `VoiceLabReleaseBoundaryTests` checks this.

An explicit value in `settings.json` always wins. Earlier Windows builds wrote every default on the first settings change, so an older test copy's settings may already store `"voiceLab.enabled": false`. Turn Voice Lab on once in Settings, or delete the `voiceLab.enabled` and `voiceLab.betaNoticeAccepted` lines.

## Native media dependencies

NuGet pins are centralized in `Directory.Packages.props`; see the root [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) for pinned sources and licences. Whisper.net CPU runtimes include **both win-x64 and win-arm64**; NoAvx is the x64 fallback. macOS native SkiaSharp/HarfBuzz assets let renderer tests run without Windows.

The FFmpeg DLLs are **not** fetched by restore or loaded at startup. After building the pinned shipping ZIP locally, stage and verify it on Windows:

```powershell
powershell -NoProfile -File build/Fetch-Ffmpeg.ps1 -RuntimeIdentifier win-arm64 -ZipPath 'C:\path\to\pinned-win-arm64.zip'
```

`build/ffmpeg.json` pins the self-built FFmpeg n9.0.2 LGPL shared ABI matching FFmpeg.AutoGen 9.0.1.1. Obtain the locally built ZIP from `tools/ffmpeg-build/` and pass it to `build/Fetch-Ffmpeg.ps1 -ZipPath <path>`; the script verifies its SHA-256, size and six ABI-named DLLs before staging them in `build/.cache/ffmpeg/<rid>/native`. `-TestTools` fetches a separately pinned, test-only FFmpeg distribution with `ffmpeg.exe`; never package that directory. On first media use the App and CLI load the six DLLs from their own directory and refuse a GPL build. Never substitute a GPL build or x264/x265 for the shipping DLLs.

## Data, resources and CLI behavior

- `SharedResources.ResolveRoot`: `VOXCLIP_SHARED_DIR`, then installed `shared/`, then walk up to repository `shared/`; absence is `sharedResourcesMissing`.
- `DataLocations.Resolve`: `VOXCLIP_DATA_DIR` or `%LOCALAPPDATA%/VoxConvo/VoxClip`, with separate `Models`, `Cache`, `Autosave`, `Secrets`, `Logs` and `settings.json`. The resolver creates nothing and touches no existing data. The App keeps API keys in `Secrets`, encrypted with DPAPI for the current Windows user; the CLI reads keys only from environment variables (architecture §9).
- `FixtureLoader` requires `shared/fixtures`, so point its environment override to repository assets, not the installed runtime-only asset subset.
- The CLI implements the complete architecture §9 tree, including `probe`, `transcribe`, `models list/install/verify/remove`, `plan`, all `render-caption` forms, `find-clips`, `llm-test`, `encoders`, `version`, and the primary export form, plus `--runtime-terms` and `--accept-runtime-terms <SHA-256>` for the Windows component terms. Use `--help` on any command. Output and exit codes follow architecture §9.3: invalid usage is 2, missing input is 3, cancellation is 6.
- Redaction, version comparison, output sizing/bitrate rules, source-generated project/style/settings serialization and resource/path resolution are implemented, not placeholders. Source word timings and unknown project `extensions` / settings keys survive round trips.

## Verification

Current test counts, native VM results and owed checks are recorded in [`CONTRACTS.md`](CONTRACTS.md) and [doc/plan.md](../../doc/plan.md) section 0; the release gates are in doc/plan.md section 6 and doc/release.md section 3. Check the UI in the VM's interactive desktop. SSH runs in **noninteractive Session 0** and shows no window, so an App process that stays alive there is not UI verification.
