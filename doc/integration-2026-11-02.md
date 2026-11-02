# Feature integration validation — 2 November 2026

The Mac integration is in the dirty `v2-rewrite` worktree based on `10d9c0a01de86790cc657f842cc28ea20e5ad9ea`. Portable Windows compatibility is in the dirty `v2-explorer` worktree based on `22be8ab836578256abb8dd480e0cf22c71ed4f02`. Staging and unrelated user edits are preserved. No commit, push, merge, CI dispatch or provider operation forms part of this validation.

## Integrated behavior

- Project-audio enrollment uses the exact own-voice checkbox statement and truthful `/2` evidence. Recorded-statement `/1` records retain their shape. Quote, consent, provider verification, account and dispatch guards remain enforced.
- Raw or VAD-retained generated speech shorter than the calibrated three-second minimum reports insufficient generated speech with absent measurements. Structural duration checks refuse clearly undersized work before payment. Explicit complete-sentence review binds a new exact text/window and requires fresh quote approval.
- Rewrite requires an explicit duration choice per passage. Changed-duration acceptance prepares the actual staged composition, keeps natural audio unstretched, and applies the bounded source-video zoom-cover route.
- Scoped voice changing uses pinned credentials, real upload overlap, one approved batch, immutable paid outputs, measured canonical mixing, explicit audition and one project transaction. Conversion leaves unmeasured ASR/speaker metrics and its unused TTS ranking score absent. Swift and C# retain mandatory measured loudness/peak checks and the TTS/legacy ranking requirements.
- Context demonstrations use source-bound schema-v4 documents, full-narration coordinates, silent video tracks, retained private snapshots and one preview/export compositor. Motion cues use source time and clip scope, with Reduce Motion affecting preview only. Clip removal and Undo preserve the associated project invariants.
- Desktop, webpage and code-project controls connect to the reviewed implementations. Fake-backed lifecycle tests cover cancellation, stale results and capture-before-actions ordering. These tests do not constitute native permission or real recording acceptance.
- Make Takes pins creator/key/region. Definitive clone refusals retain actionable errors and permit only a freshly quoted, explicitly approved retry; ambiguous transport outcomes retain recovery protection.

## Validation results

All totals below are reported by the test runners. Existing opt-in and platform prerequisite skips remain visible in the logs.

| Check | Result | Evidence tag |
|---|---|---|
| Mac Core, default parallel | 1,018 tests / 90 suites, zero failures; 38.506 seconds execution | `core-final-parallel-1` |
| Mac App | 738 tests / 58 suites, zero failures; 149.384 seconds execution | `integrated-app-tests-final-1` |
| Mac Media, excluding the separately run caption suites | 480 tests / 52 suites, zero failures | `integrated-media-tests-2` |
| Mac caption fixture/gallery suites | 7 tests / 2 suites; 302 golden samples and 38 tiles matched | `caption-parity-final-1` |
| Windows Release Core | 2,593 cases, 29 prerequisite/informative skips, zero failures | `windows-core-final-tests-1` |
| Windows portable Release Media/CLI | 872 cases, 5 prerequisite skips, zero failures; FFmpeg/Windows traits excluded | `windows-media-final-tests-1` |
| Windows portable Release UI | 1,041 cases, 5 prerequisite skips, zero failures | `windows-ui-final-tests-1` |
| Windows Release builds/typecheck | Zero warnings and zero errors | `windows-media-final-build-1`, `windows-core-final-build-1`, `windows-ui-final-build-1` |
| Strict Windows Release boundary | All four actual portable/typecheck assemblies passed existing exact allowlists | `windows-release-boundary-final-1` |
| Shared schema, fixture generation, version and whitespace | Both worktrees pass; shared contracts are byte-identical; 11 valid / 71 rejected v4 corpus cases | `shared-contract-final-1` |

The retained local evidence directory is `/tmp/voxclip-feature-integration-20261102/`. Each run has its exact command, full log and result receipt. Earlier failed logs and process samples remain preserved. No fixture expectation, calibrated acceptance threshold or test deadline was relaxed to obtain these results.

## Integration repairs established by validation

Synthetic repros established that an `AVAssetTrack` outlived its backing asset before demo-track insertion. The composition boundary now retains both until insertion completes. Native synthetic preview, scoped audio preservation, missing-frame refusal, MP4 export and preview-update regressions pass.

AVFoundation accepted the same valid H.264 MP4 bytes under `.mp4` and `.partial.mp4`, and refused them under `.partial`. Lip-sync import now validates a private `.partial.mp4` stage before the existing no-clobber publication. Container, metadata, SHA, path and cancellation validation remain intact.

Conversion finishing now uses canonical lowercase IDs for derived assets and leaves its unused TTS ranking score absent. Positive full/passage/touching-chunk finishing and canonical audition tests pass; malformed evidence and bad measured levels remain refused. Saving deleted consent revokes an already prepared dispatch in both Cores.

The aspect-fill path again clamps the original image before translation and Lanczos scaling. Existing preview/export color-edge assertions pass unchanged. The default-parallel Core repair replaces expensive per-sample key-path predicates with equivalent direct finite checks; speaker preprocessing, calibration, VAD, windows and thresholds remain unchanged.

## Artifact and remaining acceptance

The separate optimized PROFILE bundle is ready at `apps/macos/dist/validated-20261102-r2/VoxClip.app`, version 0.1.0 (build 1), arm64. Licence gates and deep strict ad-hoc signature verification pass. The bundled CLI reports `VoxClip 0.1.0 (macos-arm64)`. Project, consent and context-demo schemas are byte-identical to their source files.

Executable SHA-256: `56b76fadeaf30b4a30a8bc880134568dc8e766a6844499a5e607af10d9c963b0`. Executable UUID: `6C721047-D47A-3412-B0FA-192C38AE6B0D`. `isolated-app-receipt.json` and `packaged-source-manifest.json` in the local evidence directory bind the artifact to the current source/resources. Build and verification tags are `integrated-profile-bundle-2` and `integrated-bundle-verification-2`.

The release bundler deliberately copies only Git-tracked shared resources. The first isolated artifact omitted the new untracked context-demo schema and failed the additional artifact check. Its output and failed verification log remain retained. The corrected local packaging changes only the output destination and an explicit copy of this approved schema before the normal signing steps. Release bundling policy and the Git index remain unchanged.

The existing `apps/macos/dist/VoxClip.app` executable and plist hashes are unchanged, and the user's running instance was not replaced or restarted. Save work and quit that instance before opening the new copy with the same bundle ID.

Validation used Swift 6.4 with macOS SDK 27 and portable .NET 10. The deployment target remains macOS 26; SDK 26 compilation has not been verified in this run. SDK 27 emits retained warnings about inherited Sendable conformance in three HTTP test fixtures. The Mac PROFILE compile retains advisories for the ScreenCaptureKit callback's async alternative, a Binding setter's Sendable conversion, two debug AX casts and an existing deprecated Text concatenation. The .NET Release builds report zero warnings.

No paid generation, provider upload, Keychain access, model download, real screen recording, native Accessibility inspection, permission change or audible playback ran. Real-voice quality, Screen Recording/Accessibility onboarding, selected-window/browser interaction, listening, keyboard/VoiceOver and native Windows x64/ARM64 execution remain acceptance gates. The guarded private AX window-ID SPI remains a distribution gate. Lip-sync provider/import services are tested locally, but its editor acceptance and render route remain unavailable.

The ElevenLabs Starter-plan requirement is a provider account gate. It is reported truthfully and is not bypassed by these changes.
