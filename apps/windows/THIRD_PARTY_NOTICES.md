# Windows third-party notices

Dependency selection checked on **2026-10-25**. Application source is MIT; each dependency retains its own licence. This file is an inventory, not a replacement for upstream licence texts. Release packaging must copy the actual licences and all native/transitive notices to the install folder and expose them in About → Licences.

## Direct dependencies

The central, machine-readable pins are in `Directory.Packages.props`. Exact NuGet registration URLs, listing/publication evidence and the newest listed stable version in each required line are recorded in `build/dependencies-2026-10-25.json`.

| Dependency | Pinned version | Licence / primary source |
|---|---|---|
| Microsoft.WindowsAppSDK | 2.5.1 | [Windows App SDK](https://github.com/microsoft/WindowsAppSDK), MIT source; retain redistributable component notices |
| Microsoft.Windows.SDK.BuildTools | 10.0.28000.2705 | [NuGet](https://www.nuget.org/packages/Microsoft.Windows.SDK.BuildTools/10.0.28000.2705), Microsoft Windows SDK licence (build tooling, not application source) |
| CommunityToolkit.Mvvm | 8.4.2 | [CommunityToolkit/dotnet](https://github.com/CommunityToolkit/dotnet), MIT |
| CommunityToolkit.WinUI.Controls.SettingsControls | 8.2.251219 | [CommunityToolkit/Windows](https://github.com/CommunityToolkit/Windows), MIT |
| SkiaSharp, SkiaSharp.HarfBuzz, SkiaSharp.NativeAssets.Win32, SkiaSharp.NativeAssets.macOS | 3.119.4 | [mono/SkiaSharp](https://github.com/mono/SkiaSharp), MIT bindings; native Skia BSD and bundled third-party notices |
| HarfBuzzSharp, HarfBuzzSharp.NativeAssets.Win32, HarfBuzzSharp.NativeAssets.macOS | 14.2.1.301 | [mono/SkiaSharp](https://github.com/mono/SkiaSharp), MIT bindings; native HarfBuzz MIT-style notices |
| FFmpeg.AutoGen | 9.0.1.1 | [Ruslan-B/FFmpeg.AutoGen](https://github.com/Ruslan-B/FFmpeg.AutoGen), MIT bindings only |
| Whisper.net, Whisper.net.Runtime, Whisper.net.Runtime.NoAvx | 1.9.1 | [sandrohanea/whisper.net](https://github.com/sandrohanea/whisper.net), MIT; native whisper.cpp/ggml and component notices retained |
| NAudio.Wasapi | 3.3.0 | [naudio/NAudio](https://github.com/naudio/NAudio), MIT |
| Velopack | 1.2.161 | [velopack/velopack](https://github.com/velopack/velopack), MIT |
| System.CommandLine | 2.0.13 | [dotnet/command-line-api](https://github.com/dotnet/command-line-api), MIT |
| xunit.v3 | 4.0.2 | [xunit/xunit](https://github.com/xunit/xunit), Apache-2.0; development only |
| xunit.runner.visualstudio | 4.0.1 | [xunit/visualstudio.xunit](https://github.com/xunit/visualstudio.xunit), Apache-2.0; development only |
| Microsoft.NET.Test.Sdk | 18.11.0 | [microsoft/vstest](https://github.com/microsoft/vstest), MIT; development only |

NuGet metadata is available at `https://api.nuget.org/v3/registration5-semver1/<lowercase-package-id>/index.json`; flat-container indexes also contain unlisted versions. Select listed, non-prerelease versions published no later than the check date. NAudio.Wasapi 22.0.0 is **unlisted**, so 3.3.0 is the listed stable pin. SkiaSharp is intentionally pinned to the latest stable **3.x** line, not the newer 4.x line, as required by the architecture. The two Microsoft SDK pins are explicitly required by the verified VM configuration.

## FFmpeg dynamic distribution

`build/ffmpeg.json` pairs **FFmpeg.AutoGen 9.0.1.1** with the **FFmpeg 9.0** shared-library ABI, pinned to BtbN release `autobuild-2026-10-24-13-02`, version `n9.0.2-35-g9a9b70bb8c`. It records exact win-x64 and win-arm64 LGPL-shared assets, source commit and SHA-256 hashes. Hashes were compared with the release's `checksums.sha256` and GitHub asset digests. `build/Fetch-Ffmpeg.ps1` verifies a download before selecting the six allowed DLL families. It does not put native DLLs into the application or bypass the runtime licence gate.

- Upstream: https://ffmpeg.org/ and https://github.com/BtbN/FFmpeg-Builds
- Legal checklist: https://ffmpeg.org/legal.html
- Dynamically linked FFmpeg only, under LGPL-2.1-or-later, with the applicable LGPLv3/GPLv3 texts for LGPLv3 portions and third-party notices supplied by the actual build. No `--enable-gpl`, `--enable-nonfree`, x264 or x265.
- Before any decode, win-media must call `FfmpegLoader.ValidateConfiguration` with the real `avcodec_configuration()` value. The skeleton does not load FFmpeg yet. A release must preserve replacement of the DLLs, corresponding source/build instructions and attribution, and verify `zscale`/HDR support against the actual binaries.
- The skeleton downloads no speech models. Future model installs use `shared/catalog/transcription-models.json` and their individual licence/attribution requirements, not this NuGet inventory.

## Shared assets and transitive notices

Styles, bundled fonts, prompts and optional emoji assets remain in repository `shared/`; neither app owns a duplicate. Font licence files travel with the fonts (SIL OFL); bundled emoji artwork retains its own Apache-2.0 notices. The native package licence/notice files are authoritative for their transitive components. No system/proprietary fonts are embedded by this skeleton. A future release must audit the resolved dependency graph and ship complete notice texts, not only this summary.
