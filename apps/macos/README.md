# VoxClip for macOS

SwiftPM package for the native macOS app and the headless `voxclip-cli`. Requires Apple silicon, macOS 26+, and Xcode with Swift 6.2+ and the macOS 26 SDK or newer. All targets use Swift 6 language mode.

## Build, run and test

From the repository root:

```sh
cd apps/macos
swift package resolve
swift build
swift build --product VoxClip
swift run VoxClip
swift test
swift run voxclip-cli --help
swift run voxclip-cli export --help
swift run voxclip-cli models --help
swift run voxclip-cli version
```

The first resolve downloads the pinned argument parser and official whisper xcframework; no transcription model is downloaded. Package.resolved is part of this package. No Xcode project or SwiftPM resource bundle is needed.

The app is one main window (ADR-R29): a sidebar with Home, the open project's Full take, kept clips and suggestions; the transcript page with its selection bar; the viewer with Captions; and the timeline. Each project stays a `.voxclip` `NSDocument` attached to that window (architecture §2.6). Import, transcription, word editing, clips, Find Clips, captions, export and the share helpers are integrated; doc/design.md describes the interface. Voice Lab generation is planned for 0.1.0 behind an explicit beta opt-in; its implementation is owned by the Voice Lab track.

The CLI implements the architecture §9 command tree: `export` (also the primary `--open ... --export ...` form), `probe`, `transcribe`, `models list/install/verify/remove`, `plan`, `render-caption`, `find-clips`, `llm-test`, `encoders` and `version`. --json writes exactly one final object on stdout; diagnostics go to stderr. Exit codes follow architecture §9.3; bad argument values exit 2.

## Shared resources and isolated data

SharedResources resolves VOXCLIP_SHARED_DIR, then Contents/Resources/shared, then a repository walk from the executable. It never uses Bundle.module and never copies shared assets here. Tests independently walk from #filePath and support the same environment override.

```sh
VOXCLIP_SHARED_DIR="$PWD/../../shared" swift test
VOXCLIP_DATA_DIR=/tmp/voxclip-dev swift run voxclip-cli models list --json
```

Without VOXCLIP_DATA_DIR, locations follow architecture §2.5 (Application Support/VoxClip, Library/Logs/VoxClip, Movies/VoxClip). Location resolution alone creates no files. CLI keys come only from the documented API-key environment variables (architecture §9), never the Keychain. Never put a key in a command argument or project.

## Parallel implementation

Read [CONTRACTS.md](CONTRACTS.md) for the complete public type/protocol index, ownership, dated changes and the latest native gate results. Work only in your track's folders. The shared value contracts are frozen; propose changes in CONTRACTS.md before modifying them. `swift test` runs the Core and Media suites, which check the shared fixtures. The App target has no test target: its UI checks are DEBUG self-tests and audits started with launch arguments (for example `-uiSelfTest <folder>`), run with the console unlocked and idle.

Release packaging is supplied by `bundle.sh`; see the release section below. No sandbox, signing credential or extra entitlement is introduced here.

## Release packaging

The local-only signing/notarization workflow follows [doc/release.md](../../doc/release.md), using the same Developer ID and notary keychain profile as Superscribe. Xcode with the macOS 26+ SDK and an arm64 Mac are required. The default build needs no signing account. Release signing uses `Developer ID Application: Haugas Development OU (5ZJ9N8WURW)`, team `5ZJ9N8WURW`, and keychain profile `superscribe-notarize-2`; forks can override `SIGNING_IDENTITY`, `TEAM_ID`, `NOTARIZE_PROFILE` and `GITHUB_REPO`. Never put credentials in this package or pass a password on a command line.

```sh
./bundle.sh                         # debug, ad-hoc signed app
./bundle.sh profile                 # optimized with the DEBUG self-tests, ad-hoc; for performance gates
./bundle.sh --sign-only             # release, Developer ID + hardened runtime
./bundle.sh --release --no-upload   # notarized app, zip, DMG and checksums
./bundle.sh --upload-only --dry-run # verify artifacts/tag; print create/upload commands
./bundle.sh --upload-only           # attach to draft v<version>, creating it if needed
./bundle.sh --release               # full pipeline, then create/update the draft
```

The default debug build and the profile build are development builds: Voice Lab reads as on until you set the switch, and Rewrite skips the beta notice (doc/spec/voice-lab.md section 5). Release builds keep the shipped off default.

All modes take the per-checkout `.build/bundle.lock` with macOS `shlock` before accessing `dist/`; a concurrent invocation fails without changing the active build's artifacts. The EXIT trap removes the lock and temporary work directory. Operational failures, including signing, stapler and Gatekeeper failures, exit 1; usage errors remain exit 2. GitHub preflight checks only the active github.com account with `gh auth status --hostname github.com --active`; authenticate it with `gh auth login -h github.com` if needed. Ignored files are listed as NUL-delimited Git paths, so `.DS_Store` basenames are exempt even under non-ASCII, quoted or newline-containing directories.

`--universal` is reserved and fails explicitly; v1 ships arm64 only. Invalid options or combinations exit 2. Production releases and uploads require a clean tree, an annotated `v<version>` at HEAD and `tools/release/check-version.sh`. The build captures HEAD before compiling and rechecks the clean tree and unchanged commit before signing and before writing `dist/release-metadata.plist`; its `GitCommit` always identifies that captured build commit. For an untagged development notarization use `./bundle.sh --release --no-upload --allow-dirty`. This override is recorded as `TestBuild=true` in the metadata; those artifacts cannot be uploaded by a later `--upload-only` invocation. Ignored files under the seven shipped shared directories are printed and rejected even with `--allow-dirty`, except `.DS_Store` basenames (untracked files never ship).

Versions must be `X.Y.Z` or `X.Y.Z-beta.N`. Uploads require an authenticated `gh`, the same annotated tag object locally and on GitHub, HEAD at the tagged commit, and an unpublished release whose `tagName` and `isPrerelease` match the version. Only an explicit `release not found` response creates a draft with `--verify-tag`, titled `VoxClip <version>`, using the nonempty exact `## <version>` section from root `CHANGELOG.md`; numbered betas also use `--prerelease`. Other query failures print stderr and stop without creating a draft. It never publishes a release or overwrites published assets. A full release checks GitHub authentication, tag and draft prerequisites before building or notarizing, then rechecks before upload. `--dry-run` is only valid with `--upload-only`; it performs local and read-only remote validation and prints any create/upload commands without executing them.

Outputs are `dist/VoxClip.app`, `dist/VoxClip-macOS.zip`, `dist/VoxClip-macOS.dmg` and `dist/SHA256SUMS-macOS.txt`. The screen must be unlocked before the release build and before every notarization submission. A locked-screen preflight or notarytool's `No Keychain password item found for profile` error instructs you to unlock the Mac and re-run, never to recreate the profile (doc/release.md §5). Upload-only does not notarize. The app and DMG are submitted separately; status must be `Accepted`, both tickets are stapled and validated, and Gatekeeper assessments must pass. The zip is rebuilt after the app is stapled. Submission IDs/status and failure logs are retained under `dist/notarization/` (never uploaded). A missing/expired Apple agreement stops immediately; only the Account Holder can accept it, and the script does not retry submissions.

The bundle contains both executable products, the unchanged source Info.plist, the brand icon copied directly from `shared/brand/macos/AppIcon.icns`, `PkgInfo`, root `LICENSE` and `THIRD_PARTY_NOTICES.md`, `Assets.car`, and exactly runtime `shared/{caption-styles,catalog,data,design,fonts,prompts,schemas}`. actool compiles `Resources/Assets.xcassets` into `Assets.car`; its `AccentColor` is generated from the `accent.default` token by `tools/design`, and the build fails unless actool reports the colour that Info.plist's `NSAccentColorName` names. A bare `swift run` has no asset catalog, so DEBUG builds tint their SwiftUI roots instead (see `DesignValues.debugTint`). Only Git-tracked runtime files ship; nested fixtures, untracked/ignored files and brand source assets never ship. Each runtime directory is checked byte for byte against its tracked manifest. Every embedded framework and dylib must have its known copyright notice in the bundled notices file for release packaging; unknown names fail closed. Embedded frameworks/dylibs are thinned to arm64 and signed before the CLI, app executable and bundle; the CLI has no entitlements, uses signing identifier `com.voxconvo.voxclip.cli`, and must have a different designated requirement from the app. Both executables must carry the selected SDK/minimum version stamp, and every shipped Mach-O is checked for forbidden espeak/x264/x265/FFmpeg C symbols and libraries using temporary `nm`/`otool` output files to avoid SIGPIPE masking matches under `pipefail`. The app's signed entitlements must equal the existing camera/audio-input plist.

Install `create-dmg` before releasing (`brew install create-dmg`); its absence is a hard preflight failure. It supplies the branded 600×400 Finder layout and Applications link. Only if an installed `create-dmg` run fails does `hdiutil` create an image containing the same app, link and hidden background, without custom Finder positioning. The background and its SVG source live at `apps/macos/dmg-background.png` and `apps/macos/dmg-background.svg`. Regenerate the background with `scripts/render-dmg-background.sh` (ImageMagick, using the repository's OFL DM Sans fonts). Run packaging safety tests with `python3 scripts/test_release.py` and shell checks from `apps/macos` with `shellcheck -x bundle.sh scripts/*.sh`.

The safety tests mock signing, notarization and GitHub commands; they never submit or upload artifacts. They run copied `bundle.sh` scripts to check concurrent lock rejection, exit-code normalization and preflight ordering before Swift builds. The large-output licence regression forces grep to stop at its first match and asserts that both scans read temporary files, so restoring a producer pipeline cannot silently pass on BSD grep.

## Licences

VoxClip is MIT. Dependencies and full applicable licence texts are in the root [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md); the About settings pane identifies both native dependencies. The whisper b5454 archive checksum is e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b. See CONTRACTS.md for the release selection and verification command.
