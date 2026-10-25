# Dependency notice provenance (2026-10-25)

The root `THIRD_PARTY_NOTICES.md` is the notice payload copied into both apps. This audit records how its Windows dependency sections were selected. The FFmpeg source/runtime notices in the root file are the accepted final R4 texts and were not re-generated here.

## Resolved Windows package graph

Offline NuGet restore of `VoxClip.App` for win-x64 and win-arm64 resolved the same 38 package identities for both RIDs. `VoxClip.Cli` adds `System.CommandLine` 2.0.13. `project.assets.json` supplied the managed/runtime/native/build classification; `Directory.Packages.props` supplied direct pins. The app is self-contained, with .NET runtime and host packs 10.0.2 for both RIDs. Their MIT licence and notice files are byte-identical across RIDs. The SDK and package targets may add binplaced assets beyond the NuGet runtime list; the Windows release owner must compare the final installed files with this inventory.

| Payload group | Resolved versions | Notice evidence |
|---|---|---|
| Windows App SDK | `Microsoft.WindowsAppSDK` 2.5.1; Base 2.0.4, Foundation 2.3.12, InteractiveExperiences 2.1.9, WinUI 2.3.9, DWrite 2.1.0, Widgets 2.0.5, AI 2.5.5, ML 2.1.94, Search 2.5.5, Runtime 2.5.1 | Exact cached `license.txt`, `NOTICE.txt`, and WinUI `NOTICE.txt`. These are Microsoft redistributable terms, distinct from the source repository's MIT licence. |
| Windows AI and browser loader | `Microsoft.Windows.AI.MachineLearning` 2.1.74; `Microsoft.Web.WebView2` 1.0.3719.77 | Exact cached licences and notices. NuGet runtime/native assets include DirectML, ONNX Runtime, ML projections and `WebView2Loader.dll`. The installed WebView2 browser runtime is separate. |
| CommunityToolkit | Mvvm 8.4.2, Common 8.2.1; WinUI SettingsControls, Triggers, Helpers and Extensions 8.2.251219 | Exact cached MIT files; Mvvm/Common share the same notice text, all four WinUI packages share the same MIT file. |
| Skia and HarfBuzz | SkiaSharp family 3.119.4; HarfBuzzSharp family 14.2.1.301 | Exact cached MIT and 139,775-byte native third-party notice files; the Win32 packages' notice files are byte-identical. macOS native asset packages resolve for development but do not contribute Windows binaries. |
| Speech | Whisper.net, Runtime and Runtime.NoAvx 1.9.1; Microsoft.Extensions.AI.Abstractions 10.2.0 | Cached Whisper.net licence and public exact source commit `98278acc38ae23590cdfa9859f78f089abae52a7`, whose `whisper.cpp` submodule points to `f24588a272ae8e23280d9c220536437164e6ed28`. The latter's MIT text matches the already included ggml notice. Extensions' MIT text came from its NuGet commit `7c82ecb60925d76e53b65e290a33bef46f285cae`. Runtime.Metal is not a Windows binary. |
| Audio, updates and CLI | NAudio.Wasapi/Core 3.3.0, System.Numerics.Tensors 9.0.0, Velopack 1.2.161, System.CommandLine 2.0.13 | Tensors' cached MIT and notices; exact public source MIT texts at NuGet commits `4f8889e2bd34c3978a25652c6c172fa1502ccba3`, `92d6a1c91716729d449034df5c50307dcce39493`, and `4099f83977f4d29604a9aeb971fb0a7bc1d5f699`. |
| Self-contained .NET | runtime/host packs 10.0.2 | Exact cached `LICENSE.TXT` and `THIRD-PARTY-NOTICES.TXT`; both RIDs have byte-identical texts. |

`Microsoft.Windows.SDK.BuildTools` 10.0.28000.2705 and its MSIX build-tools dependency are build-only. Windows OS libraries and the separately installed WebView2 browser runtime are not copied into the app. Test-only packages and FFmpeg test tools are excluded.

## Release decisions and final-file audit

The Windows App SDK 2.5.1 `license.txt` grants redistribution only under Section 3 conditions; the package is not simply MIT-licensed. Its `NOTICE.txt` and the Windows AI MachineLearning 2.1.74 `ThirdPartyNotices.txt` each contain Intel MKL simplified terms, including a restriction on reverse engineering. ADR-030 permits the unmodified official runtime binaries in this pinned package graph as a narrow exception to AGENTS.md rule 4, with their exact terms and notices. It preserves the package terms' open-source and LGPL exceptions and does not change VoxClip's MIT licence. The downstream agreement requirement and final installer payload notice audit remain open under release section 3.7; the policy decision alone does not authorize public redistribution.

The pinned Velopack NuGet library is covered by its source MIT text. `vpk` creates `Update.exe` and installer binaries later in the Windows release flow; this audit did not inspect a final package. The Windows release owner must audit those outputs and any third-party payload before publishing. Both apps' About/Settings consumers must display the bundled root notices. Final package verification must check that this file is present and matches the release commit; build-only SDK tools must not be described as runtime components. No WinUI or packaging files were changed in this audit.
