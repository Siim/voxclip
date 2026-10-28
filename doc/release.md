# VoxClip release and signing

Status: normative for 0.1.0. Date: 2026-10-25.

Releases are built and signed **locally**: macOS on the maintainer's Mac, Windows on the existing UTM Windows VM driven from the Mac over SSH. CI never signs. Every release is a **draft** GitHub Release on `github.com/Siim/voxclip` until a human publishes it. The clip.voxconvo.com page on GitHub Pages links directly to the latest stable release's assets (publishing.md section 4). The voxconvo.com/download page is dropped (user decision, 2026-10-27). Both platforms launch together; there is no Mac-only 0.1.0 (ADR-R33).

**No secret ever enters this repository, a command line, a log or the VM disk.** Secrets are named here by variable and file location only.

Provenance: Superscribe's `apps/macos/bundle.sh`, `apps/windows/build-windows.sh`, `build-installer.ps1` and their documented gotchas (planning research `ss-mac.md`, `ss-win.md`), adapted and with their known weaknesses fixed.

---

## 1. Constants

| Thing | Value |
|---|---|
| Product | VoxClip |
| Version | `0.1.0` (semver). macOS: `CFBundleShortVersionString` in `apps/macos/Sources/VoxClip/Info.plist`. Windows: `<Version>` in `apps/windows/Directory.Build.props`. Nowhere else |
| Build number (macOS) | `CFBundleVersion`, a positive integer that increases with every release (0.1.0 = `1`) |
| Tag | `v<version>`, annotated, on the release commit |
| Bundle ID | `com.voxconvo.voxclip` |
| CLI signing identifier | `com.voxconvo.voxclip.cli`; its designated requirement must differ from the app's |
| Apple signing identity | `Developer ID Application: Haugas Development OU (5ZJ9N8WURW)` |
| Apple team | `5ZJ9N8WURW` |
| Notary keychain profile | `superscribe-notarize-2` (per Apple ID and team, not per app, so it is shared with Superscribe) |
| Windows signing | Azure Artifact Signing (formerly Trusted Signing) through `signtool.exe` + `Azure.CodeSigning.Dlib.dll` on the VM |
| Windows signing credentials | an env file **outside this repo** whose path is in the Mac env var `VOXCLIP_SIGNING_ENV` (section 3.2) |
| Velopack pack id | `VoxClip`; channels `win-x64`, `win-arm64` |
| GitHub repo | `Siim/voxclip` |

The macOS CLI reads the linked Info.plist through `AppVersion.current`, including
`--version`, `version --json`, and every success/error JSON envelope. Missing or
empty or whitespace-only bundle metadata reports `unknown`, as the Windows CLI
does for null, empty or whitespace-only informational versions (after dropping
assembly build metadata). Project writers receive an explicit version at
import/save boundaries; Domain does no bundle I/O. On both platforms a missing,
blank or invalid runtime writer version becomes `0.0.0`, not the CLI's `unknown`.
Valid writer versions match `X.Y.Z(-beta.N)?`, with non-negative ASCII integers
and no leading zeroes except the number zero itself, exactly as `version.py`.
LLM, speech and Voice Lab clients use bundle metadata on macOS and assembly
informational metadata on Windows, never a second release constant.

`bash tools/release/check-version.sh` checks both version files and rejects the
current Info.plist version as a complete token anywhere in production source
text, **including comments**, under `apps/macos/Sources` and `apps/windows/src`.
It scans Swift, C#, XAML, C/C++/Objective-C, F#, VB and resource-script files.
Tokens match the same `X.Y.Z(-beta.N)?` grammar above, are not preceded by
`[0-9A-Za-z.]`, and are not followed by `[0-9A-Za-z]`, a dot then a digit, or
`-beta`. Only a whole matched token equal to the current version fails. Thus for
`0.1.0`, `VoxClip/0.1.0` and `since 0.1.0` fail, but `0.1.0-beta.2`, `10.1.0`,
`0.1.0.1`, `10.0.1.0` and `0.1.01` do not. Raw, verbatim and multiline strings
are covered without interpreting their language syntax. This is a tripwire for
whole version strings, not a proof: concatenations such as `"0.1." + "0"` are
out of scope. Production comments should describe behavior, not release history.

The scanner excludes test/tests and fixture/fixtures directories, build output
(`.build`, `bin`, `obj`, `.git`), generated-name files (`.g.`, `.g.i.`,
`.generated.`, `.designer.`), and the explicit generator outputs listed in
`version.py`: `apps/macos/Sources/VoxClip/Design/Tokens.swift` and
`apps/windows/src/VoxClip.App/Themes/Tokens.xaml`. A `Generated` header or a
directory called `Generated` is not an exemption. A deliberate exception needs
a same-line comment `version-check: allow <reason>` (after `//`, `/*`, `<!--` or
the VB comment apostrophe) that ends the line, after every occurrence of the
version; the reason holds no quote character, so marker text inside a string
literal never counts. The checker prints every allowed matching line with its
path, line number and reason. No blank reason is accepted. Info.plist and
Directory.Build.props remain the only release version sources; test inputs may
keep literal versions.
CI's “Versions agree” step also runs `tools/release/test_version.py`, which plants
literals in an isolated `/tmp` copy and checks that they fail without changing
the working version files. It also checks the shared project-writer edge cases
against the release grammar, alongside both platforms' save-and-reload tests.
The CLI E2E comparator in `tools/parity` also requires matching, nonempty version
fields on success and failure reports, including the platform-specific WebM case.

### 1.1 Release assets (constant names)

| Asset | Platform | Notes |
|---|---|---|
| `VoxClip-macOS.dmg` | macOS arm64 | Signed, notarized, stapled. Download page target |
| `VoxClip-macOS.zip` | macOS arm64 | `ditto` zip of the stapled app (for scripted installs) |
| `SHA256SUMS-macOS.txt` | macOS | `shasum -a 256` format for the two files above |
| `VoxClip-win-x64-Setup.exe` | Windows x64 | Velopack installer (`{packId}-{channel}-Setup.exe`). Download page target |
| `VoxClip-win-arm64-Setup.exe` | Windows ARM64 | Velopack installer. Download page target |
| `releases.win-x64.json`, `releases.win-arm64.json` | Windows | Velopack feeds read by `GithubSource` |
| `VoxClip-<version>-win-x64-full.nupkg`, `VoxClip-<version>-win-arm64-full.nupkg` | Windows | Velopack full packages (exact names are whatever `vpk pack` writes into `assets.<channel>.json`) |
| `VoxClip-<version>-win-*-delta.nupkg` | Windows | Only when a previous release existed |
| `VoxClip-win-ffmpeg-source.tar.xz` | Windows | Corresponding source for the self-built minimal LGPL FFmpeg DLLs: component-labelled source/runtime archives and build tools pinned by URL and SHA-256, `tools/ffmpeg-build/` from the release `BUILD_COMMIT`, the schema-2 manifest and `BUILD.txt` with each RID's configure line and runtime inventory (architecture section 6.1). Incomplete provenance or failed clean-build reproducibility blocks release. Constant name; attached to every release that ships Windows |
| `SHA256SUMS-windows.txt` | Windows | `<sha256>  <file>` lines for every Windows asset above |

The download-page targets never carry a version in their names, so `https://github.com/Siim/voxclip/releases/latest/download/<asset>` always resolves to the newest **published** release. Drafts and pre-releases are never "latest". Velopack's package files carry versions by design; Velopack finds them through the feed files.

Not uploaded: `RELEASES-*` (legacy Squirrel feeds), `assets.*.json` (local build metadata), Portable zips (disabled with `--noPortable`).

---

## 2. macOS release

### 2.1 Prerequisites (on the release Mac)

- Xcode with the newest macOS SDK, licence accepted (`sudo xcodebuild -license accept`). Check `xcrun --sdk macosx --show-sdk-version`.
- The Developer ID identity in the login keychain: `security find-identity -v -p codesigning | grep "Developer ID Application: Haugas Development OU (5ZJ9N8WURW)"`.
- The notary profile works: `xcrun notarytool history --keychain-profile superscribe-notarize-2` (an authenticated call; `security find-generic-password` failing to find it proves nothing).
- `create-dmg` (`brew install create-dmg`), `gh` signed in with release rights on `Siim/voxclip`. Preflight runs `gh auth status --hostname github.com --active`, checking only the active github.com account; on failure, run `gh auth login -h github.com`.

### 2.2 Files the script expects (apps/macos)

`VoxClip.entitlements` (exactly these two keys, nothing else; no sandbox):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
```

`Sources/VoxClip/Info.plist` (embedded into both executables with `-sectcreate`, and copied into the bundle):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>VoxClip</string>
  <key>CFBundleName</key><string>VoxClip</string>
  <key>CFBundleExecutable</key><string>VoxClip</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.voxconvo.voxclip</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>NSHumanReadableCopyright</key><string>(c) Haugas Development OU. MIT License.</string>
  <key>NSCameraUsageDescription</key><string>VoxClip uses the camera when you record a new video.</string>
  <key>NSMicrophoneUsageDescription</key><string>VoxClip uses the microphone when you record a new video.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>VoxClip transcribes your videos on this Mac with Apple's on-device speech recognition. Audio stays on this Mac.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>VoxClip Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>com.voxconvo.voxclip.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.movie</string><string>public.mpeg-4</string><string>com.apple.quicktime-movie</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.voxconvo.voxclip.project</string>
      <key>UTTypeDescription</key><string>VoxClip Project</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>voxclip</string></array>
        <key>public.mime-type</key><string>application/vnd.voxconvo.voxclip+json</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
```

Also: `dmg-background.png` (600×400) in `apps/macos`. From the repository root: `shared/brand/macos/AppIcon.icns`, the single `THIRD_PARTY_NOTICES.md` (fonts, Unicode data, whisper.cpp, swift-argument-parser, models' attribution, and the Windows components) and `LICENSE`. The `NSSpeechRecognitionUsageDescription` string above is the only copy; the transcription spec refers to it.

### 2.3 `bundle.sh` (lives at `apps/macos/bundle.sh`)

The script and `scripts/release-common.sh` are the implementation; this spec describes their contract, not a second executable template. Bash 3.2 is supported. Tracing is disabled; never enable `set -x` around signing or release commands.

Both Swift build invocations use two jobs to bound compiler resource use on the release Mac.

| Command | Result |
|---|---|
| `./bundle.sh` | Debug build, ad-hoc signed `dist/VoxClip.app`; anyone can run it |
| `./bundle.sh --sign-only` | Release build signed with Developer ID and hardened runtime; no notarization. The app's designated requirement matches production releases, preserving camera/mic and Keychain grants |
| `./bundle.sh --release --no-upload` | Signed, notarized, stapled app, zip, DMG and checksums in `dist/`; submits to Apple, but does not upload to GitHub |
| `./bundle.sh --upload-only` | Verify existing `dist/` artifacts, then attach them to draft `v<version>`, creating it if missing; no build or notarization |
| `./bundle.sh --upload-only --dry-run` | Perform local and read-only remote validation; print draft creation/upload commands without executing them |
| `./bundle.sh --release` or `-r` | Build, sign, notarize, staple and package, then create/update the draft |
| `./bundle.sh --release --no-upload --allow-dirty` | Untagged/dirty local test release; Apple submissions still happen, GitHub uploads are permanently forbidden for these artifacts |
| `./bundle.sh --universal` | Reserved and rejected; v1 ships arm64 only |

Usage errors exit **2**: unknown options, conflicting modes, `--no-upload` without `--release`, `--dry-run` without `--upload-only`, or `--allow-dirty` in any combination except `--release --no-upload`. Operational failures exit 1, including nonzero signing, stapler and Gatekeeper statuses, normalized by `set -Eeo pipefail` and `trap 'exit 1' ERR`. `--help` exits 0.

After argument validation, every mode takes the per-checkout `.build/bundle.lock` with `/usr/bin/shlock` before reading or changing `dist/`. A second invocation fails without disturbing the active build or its artifacts. The EXIT trap removes the lock and temporary work directory; `shlock` recovers stale locks from dead processes.

Production releases and uploads require a clean tree (excluding ignored `dist/` outputs), an annotated `v<version>` at HEAD and matching platform versions from `tools/release/check-version.sh`. Capture `BUILD_COMMIT` during the initial tree check, before `swift build`; after assembling the app and before signing, and again immediately before writing metadata, require a clean tree and HEAD still equal to that captured commit. `--allow-dirty` skips clean-tree/tag/recheck gates only; it does not bypass the resource, licence or signing gates. `dist/release-metadata.plist` records `Version`, `BuildNumber`, the captured `GitCommit` (never a later reread of HEAD) and `TestBuild`. Uploads, including dry runs, require `TestBuild=false`, `GitCommit` equal to HEAD and matching version/build fields; test artifacts cannot be uploaded in a later invocation.

The pipeline, step by step:

1. **SDK pin check.** Read the selected SDK version from `SDKSettings`, pass `-platform_version macos <min> <sdk>` to Swift's linker, and verify both `LC_BUILD_VERSION sdk` and `minos` on both executables with Xcode's real `otool`. The package and plist minimum macOS versions must agree. A stale SDK stamp makes macOS draw pre-Liquid-Glass controls.
2. **Licence gate.** Fail closed if any shipped Mach-O cannot be inspected, or contains espeak/espeak-ng, x264, x265 or FFmpeg C symbols or linked libraries. Write `nm -a` and `otool -L` output to temporary files in the work directory and grep those files (excluding the otool filename header), never a multi-megabyte producer pipeline that can mask a match through SIGPIPE under `pipefail`.
3. **Resources.** Copy only Git-tracked runtime files in `shared/{caption-styles,catalog,data,design,fonts,prompts,schemas}`, excluding nested `fixtures/`; untracked/ignored files, ingest data, brand sources and tools never ship. Copy and byte-compare with the same NUL-delimited tracked manifests, not a scan of untracked files. List ignored files with `git ls-files -z`, rejecting listing errors and ignored files in shipped shared directories even with `--allow-dirty`, printing offending paths first. Ignore `.DS_Store` basenames everywhere in this gate, including non-ASCII, quoted or newline-containing paths, because untracked files never ship. Copy root `THIRD_PARTY_NOTICES.md`, `LICENSE` and the icon from `shared/brand`; compile the token-owned `apps/macos/Resources/Assets.xcassets` (the `AccentColor` generated from the `accent.default` token) and the App-owned `apps/macos/Resources/Transport.xcassets` (custom three-second SF Symbols) together into `Contents/Resources/Assets.car` with `actool --accent-color`, failing unless its partial Info.plist names the same `NSAccentColorName` as the app's Info.plist, because actool only warns about a missing colour; strip dSYMs and thin embedded code to arm64.
4. **Nested-first signing with `--timestamp`.** Sign embedded Mach-O files and framework wrappers, then `voxclip-cli`, then the main executable and bundle. The CLI has no entitlements and is signed with `--identifier com.voxconvo.voxclip.cli`; verify that identifier and require its designated requirement to differ from the app's `com.voxconvo.voxclip` requirement. Signed local app rebuilds retain the production app requirement. Require the same Team ID, hardened runtime and secure timestamp on every Developer ID Mach-O; no `disable-library-validation` or other runtime exceptions.
5. **Entitlements and notices.** The signed bundle must carry exactly camera + audio-input. Every embedded framework and dylib (including `Contents/Frameworks/*.dylib`) must match the same known-notice table and its exact copyright marker in the bundled notices file; unknown names fail closed. The current known names are `whisper.framework` and `libwhisper.dylib` (ggml authors).
6. **Notarize the zip.** Check the screen lock state before the release build and again before every notarization submission (section 5). The current `--upload-only` flow never notarizes; any future upload path that submits must use the same gate. Require a successful `notarytool` command, JSON `status=Accepted` and a valid submission ID; otherwise print stderr/JSON and fetch the submission log when an ID is available. Map `No Keychain password item found for profile` to the same locked-screen diagnostic, not advice to recreate credentials. Retain diagnostics in `dist/notarization/`; never retry submissions automatically. Staple/validate the app and re-zip it so the zip carries the ticket; assess with `spctl --assess --type execute`.
7. **DMG.** Require installed `create-dmg` before any notarization (`brew install create-dmg`). Use the branded 600×400 background and Applications link; if the installed tool fails, fall back to `hdiutil` with the same app, link and hidden background but no custom Finder positioning. Sign the DMG with `--timestamp`, notarize it separately, staple/validate it and assess with `spctl --assess --type open --context context:primary-signature`.
8. **Checksums and metadata.** Write `SHA256SUMS-macOS.txt` for the DMG and final zip, plus the local release metadata above. Uploads verify the checksums, signatures, staples and both Gatekeeper assessments before any remote mutation. `dist/` is ignored by Git; it and notarization diagnostics are never committed or uploaded as extra assets.
9. **Draft upload.** Require authenticated `gh` and identical annotated tag objects locally and on GitHub. Query `isDraft`, `tagName` and `isPrerelease`; refuse published releases, tag mismatches and prerelease flags inconsistent with the version. Only a failed query explicitly reporting `release not found` takes the create path. On HTTP, rate-limit or GraphQL errors, print stderr and stop with `Cannot query release <tag>; not creating a draft`. Create a missing draft with `--verify-tag`, title `VoxClip <version>` and the nonempty exact `## <version>` section from root `CHANGELOG.md`; numbered beta versions add `--prerelease` in real and dry-run commands. Re-query after creation before uploading. A full release checks GitHub prerequisites before building/notarizing, then rechecks immediately before upload. Never publish automatically or replace published assets.

---

## 3. Windows release (UTM VM over SSH)

The Windows VM (ARM64 Windows 11 under UTM on the release Mac) has signtool and the Artifact Signing dlib, but no git and no GitHub CLI. The Mac drives it: it archives the tagged tree, copies it over, runs one PowerShell script on the VM that builds, signs, packs and verifies both architectures, then copies the results back and uploads them with `gh`.

### 3.1 VM prerequisites (one-time)

- OpenSSH Server enabled, key-based login from the release Mac (`ssh <user>@<vm-host>` without a password prompt).
- .NET 10 SDK (`dotnet --list-sdks` shows 10.0.1xx). Windows 11 SDK (for `signtool.exe`, 10.0.26100 or newer). Long paths enabled (`HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1`).
- `Azure.CodeSigning.Dlib.dll` from the `Microsoft.Trusted.Signing.Client` NuGet package, extracted (e.g. `C:\trusted-signing-client\bin\x64\`). **The dlib and signtool must be the same architecture**: on the ARM64 VM use the x64 signtool with the x64 dlib (both run under emulation), as the existing Superscribe setup does.
- `tar.exe` (built into Windows 11) and Windows PowerShell 5.1 (`powershell.exe`). Scripts run under 5.1 must be **ASCII only** (an em dash broke Superscribe's script).
- `vpk` comes from the repo's local tool manifest `apps/windows/.config/dotnet-tools.json` (pinned version), restored with `dotnet tool restore`; nothing global.
- Velopack's `--signTemplate` calls `apps/windows/build/Sign-Artifacts.ps1` (section 3.5).

### 3.2 Credentials (never on a command line, never on the VM disk, never in the repo)

- A signing env file with more than one hard link is refused before locking or staging. All local staging and secret-name checks finish before acquiring the VM lock or deleting older VM runs. Dirty/skeleton archives send a NUL-delimited `git ls-files -z --cached --others --exclude-standard -- <staged paths>` list through isolated Python: it rejects `*.env`, `.env*`, `azure-signing*`, `*.pfx`, `*.p12`, `*.cer`, `*.key`, `*.pem` and `signing/` components case-insensitively, then drops deleted paths. `tar --null -T <validated list> --no-recursion` applies matching case-insensitive exclusions as an independently tested second layer and prevents recursive inclusion of unlisted contents.
- The env file lives **outside this repo** on the release Mac. Its path is in the Mac env var `VOXCLIP_SIGNING_ENV` (for example the existing Superscribe signing env file). Isolated Python walks every ancestor of its resolved path and compares device/inode identity with the checkout, rejecting internal files through symlinks, case variants on case-insensitive filesystems and other aliases before staging or SSH.
- Every Python invocation in the Mac driver runs with `-I`, including `release-assets.py`, dry-run pin checks, version checks, containment and VM configuration, so modules planted in the launch directory cannot execute even with empty/relative `PYTHONPATH` entries. After capturing the signing-file path, the driver unsets `VOXCLIP_SIGNING_ENV` so children do not inherit it.
- Each canonical tenant/client/secret value wins when its unquoted value is non-empty; otherwise its KVT/KVI/KVS alias supplies the value. The effective value must be non-blank. A whitespace-only canonical value therefore fails before the lock even with a valid alias, and the VM repeats this validation with `.Trim()`.
- Recognised names (values are never printed): `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` (aliases accepted for the existing file: `AZURE_SIGNING_KVT`, `AZURE_SIGNING_KVI`, `AZURE_SIGNING_KVS`), plus the non-secret `AZURE_SIGNING_ENDPOINT`, `AZURE_SIGNING_ACCOUNT` and `AZURE_SIGNING_PROFILE`. Each non-secret name absent from the file falls back to the driver's own Mac process environment; a present file value always wins, including an empty or invalid value. Only the endpoint has a default when absent from both: `https://neu.codesigning.azure.net`. Account `<account>` and profile `<profile>` must match `^[A-Za-z0-9][A-Za-z0-9-]{1,63}$`; endpoint must be exactly `https://<region>.codesigning.azure.net` with region matching `^[a-z]{2,8}$`. Mac validation occurs before locking and reports only the invalid variable name, and the VM repeats it. All three travel explicitly in the same stdin payload as credentials, never SSH argv; the VM requires the endpoint. Tenant/client/secret require non-blank effective values through their documented aliases; they never fall back to the Mac environment. Other legacy signing names remain ignored.
- The driver uses isolated Python to read bytes, strip a leading UTF-8 BOM and normalize CR/CRLF line endings before matching exact allowed names; unrelated lines are skipped without decoding, and grep environment options have no effect. Allowed lines must be valid UTF-8, with each value one single-quoted, double-quoted or unquoted shell word on one line and no trailing payload. Malformed allowed assignments report only the variable name; unexpected failures use one fixed message without traceback text, bytes or offsets. The complete validated output is UTF-8-encoded in memory, including validation-only preflight, before a single binary write, so a parsing or encoding failure never streams a partial set. It **streams the validated assignments over the SSH session's stdin** to `vm-release.ps1`, which reads stdin once at start into a script-scoped hashtable and never writes the values anywhere. The builds, local FFmpeg staging and the delta download run **without** credentials. Only then are `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` (what the dlib's `DefaultAzureCredential` reads) set as process environment variables, for the signing and packing steps alone (signtool, `vpk pack` with its sign template, the sign wrapper); they are removed before verification and the smoke install (section 3.4). The SSH command line carries only the version, paths and tool locations.
- `metadata.json` for the dlib is written by the VM script from the non-secret values, as single-line ASCII without a BOM (a UTF-16 or BOM file breaks the dlib):
  `{"Endpoint":"https://neu.codesigning.azure.net","CodeSigningAccountName":"<account>","CertificateProfileName":"<profile>"}`

### 3.3 Mac-side driver (`apps/windows/build/release-windows.sh`)

`write-pin` is a maintainer pin-update operation, not part of releasing an existing pin. Release builds verify `buildInputsSha256`, both clean-build results and the committed ZIP hashes; they never rewrite `ffmpeg.json` to accept different output. The shipping recipe excludes zimg and uses architecture section 6.5's existing swscale HDR fallback, without assuming a licence exception.

Env vars: `VOXCLIP_WIN_HOST` (required, `user@host`), `VOXCLIP_SIGNING_ENV` (required), `VOXCLIP_FFMPEG_CACHE` (optional local build cache), `VOXCLIP_WIN_BUILD_DIR` (default `C:\voxclip-build`), `VOXCLIP_VM_SIGNTOOL` (optional override), `VOXCLIP_VM_DLIB` (default `C:\trusted-signing-client\bin\x64\Azure.CodeSigning.Dlib.dll`). Flags include `--no-upload`, `--upload-only`, `--dry-run` and non-uploadable `--skeleton-test`.

Before release, run the pinned `tools/ffmpeg-build/` recipe for both RIDs twice and verify the committed pin (architecture section 6.1). The Windows release driver consumes those cached outputs; it does not rebuild or rewrite the pin. `recipeCommit: "BUILD_COMMIT"` resolves to this release's full commit. The shipping path has no `btbnCommit`, `ffmpeg-builds` or BtbN download URL requirement.

The release driver validates the committed schema-2 pin and the two cached clean-build reports before taking the VM lock. The archive name, byte size and SHA-256 for each local ZIP must match `builds`; both reports must match `buildInputsSha256`, the exact configure/licence evidence and the reproducibility hashes. It checks that each ZIP holds exactly the six ABI-named DLLs for the RID and that their PE machine types and per-DLL hashes match the reports. The former BtbN `testTools` ZIP is never a shipping input. There are no shipping ZIP URLs.

Source staging reads `tools/ffmpeg-build/` from the tagged release commit, compares its source lock and recipe digest with the manifest, and rechecks every cached source/build-tool archive's pinned size and SHA-256 before copying it. The `sourceAssets.includePaths` selection is repacked after rejecting traversal, unsafe links, duplicate entries and missing selected files. The full AMF download is not redistributed; its original URL, size and hash remain in `SOURCE-ASSETS.json` alongside the selected archive's hash. Other pinned original source archives, including llvm-mingw, MinGW-w64 and LLVM, and pinned build-tool archives are included. The archive also has the exact committed recipe, schema-2 manifest, `BUILD.txt` with both configure lines, DLL/import inventory and final shipping ZIP hashes, LGPL text, FFmpeg licence, generated per-RID notices and per-RID audit summaries with resolved components, runtime objects and licence coverage. It excludes build logs, config logs, raw maps and private evidence. The staged source archive is verified again when copied into the final upload set, so a later change to the build cache or working recipe cannot change corresponding source.

The driver transfers only the staged ZIPs, licence/notice/BUILD files, audit summaries and their hash receipt to the VM; it keeps the corresponding-source archive on the Mac. The VM checks the receipt against its release commit and `buildInputsSha256`, verifies every transferred file and passes the ZIP as `-ZipPath` to `Fetch-Ffmpeg.ps1`. `--dry-run` prints the plan without staging, VM access or signing. `--skeleton-test` remains permanently non-uploadable. `--upload-only` uses the previously verified production output and repeats checksum and optional Setup signature checks before draft upload.

### 3.4 VM-side script (`apps/windows/build/vm-release.ps1`, ASCII only)

The driver invokes the committed script with a per-run `config.json` beneath the configured build root's `runs/` directory. The owner-token lock and heartbeat belong to the Mac driver; the VM script never takes over another run.

1. **Start without signing credentials in the environment.** Reject inherited Azure tenant/client/secret values. Record the process identity for bounded cancellation, select the configured .NET SDK, disable build servers and telemetry, and create the run's private metadata directory with restricted ACLs.
2. **Read credentials from SSH stdin into memory.** Parse only the names and aliases in section 3.2, validate them again, and clear the raw input. Keep secrets in a hashtable until signing; write only the non-secret account/profile/endpoint metadata as ASCII. Never log a credential value.
3. **Prepare the exact source and tools.** Extract this run's `source.tar.gz` into its fresh `source/` directory, require .NET 10, validate the selected signtool/dlib PE architectures, and extract release notes for the configured version from `CHANGELOG.md`. The explicitly non-uploadable skeleton resume may reuse its own original publish, never a production release.
4. **Build without signing credentials in the environment.** For `win-x64`, then `win-arm64`, publish the CLI followed by the App into the same RID-specific `out/<rid>/app` directory. Both are self-contained Release builds with `-m:1`, node reuse disabled and shared compilation disabled; the App also receives the matching `Platform`. Verify shared resources and root notices. Verify the schema-2 FFmpeg stage receipt, ZIP size/hash, six ABI DLLs and exact runtime configure/licence strings before staging the DLLs and licence/notice/BUILD files. Collect build failures, shut down build servers and stop before signing if any failed.
5. **Prepare packaging.** Use the `vpk` tool version pinned by `Directory.Packages.props`, installing it into the build root's versioned tools directory if absent. Fetch the optional previous published package for each channel; a first release may have no delta base.
6. **Sign and pack.** Set the three Azure credential environment variables only inside the signing `try/finally`. `Sign-Artifacts.ps1` signs the payload; `Pack-Velopack.ps1` creates each RID's installer, full package, optional delta and feed with the production ICO and `--noPortable`. Its signing template uses the pinned Velopack `{{file}}` placeholder and the same wrapper for package tooling, including `Update.exe`. It verifies the final installer publisher as `Haugas Development OU`. The `finally` clears credentials and the signing runtime override before any install or CLI smoke test.
7. **Verify after clearing credentials.** Check every payload PE, the installer and every PE extracted from the full package. `Test-Install.ps1` silently installs each architecture into its own temporary directory, verifies installed signatures and required app/CLI/licence files, checks the installed CLI's version and RID, then uninstalls. Installation, CLI execution and cleanup are bounded. Preserve existing user data, retain cleanup markers on failure, and report both the original failure and any cleanup failure. The x64 installer runs under emulation on the ARM64 VM.
8. **Collect verified output.** Copy only the installer, packages listed by Velopack and the channel feed into `out/upload`. Write ASCII, LF-terminated `SHA256SUMS-windows.txt` and a verification receipt identifying the source commit, version, tool versions and whether it was a test build. The Mac adds and checks the corresponding-source archive before draft upload (section 3.3).
9. **Clean up on every exit.** Clear credential variables and the in-memory hashtable, restore process tool paths, and remove this run's private metadata, source archive and process marker. The Mac driver handles owned remote process cleanup, evidence copy-back and lock release; it never deletes a foreign run or lock.

### 3.5 Signing wrapper (`apps/windows/build/Sign-Artifacts.ps1`)

Parameters: `-SignTool`, `-Dlib`, `-Metadata`, `-Paths`, plus `-VerifyOnly` and optional `-ReportPath`. The wrapper inventories PE files recursively and preserves publisher signatures that already meet the release checks. It signs the remaining files in batches of at most 50 with SHA-256 and Microsoft's RFC 3161 timestamp service. Only transient timestamp-service failures retry, at most three attempts, and each attempt filters out files already successfully signed.

Every invocation ends with the shared Authenticode and timestamp verification; `-VerifyOnly` performs those checks without reading signing credentials. Failed native exit codes, missing or invalid signatures and missing valid timestamps fail the release. Signer output is redacted before logging. The wrapper restores the prior signing runtime path on every exit. See [the implementation guide](../apps/windows/build/README-release.md) for prerequisite selection, evidence files and offline regression commands.

### 3.6 What the Windows flow guarantees

- The VM builds exactly the tagged commit (clean `git archive`, the old tree deleted first), so files deleted locally never survive on the VM.
- Every PE file in the install folder, the packages and the installer carries a valid Authenticode signature, most of them ours (Smart App Control checks every loaded module).
- Failures are detected by exit codes, not by grepping logs.
- Credentials exist only in the memory of one SSH session on the VM: in a script variable during the build phase, and in that one PowerShell process's environment only during the signing phase. No build tool, MSBuild node, compiler server, binlog, installer or smoke-test process ever sees them.
- The install folder carries VoxClip's `LICENSE`, the full `THIRD_PARTY_NOTICES.md` and the FFmpeg licence and build notes, and every release carries the FFmpeg corresponding source. For both Windows RIDs, the full package and installed notices must match the tagged release root byte-for-byte. Installed `Update.exe` and the root execution stub must match their respective signed full-package entries.
- Results are hash-checked after the copy back, and optionally signature-checked on the Mac with `osslsigncode`. When installed, it verifies each Setup file with a bounded 120-second check before upload, including `--upload-only`; a verification failure stops the release. When absent, the driver explicitly reports that this optional check is skipped. The `.release/latest` pointer advances only after the final Mac hash check and this signature-verification step pass for a clean production build; failures leave any previous verified pointer unchanged. Before signing, the VM honors `VOXCLIP_VM_SIGNTOOL`; otherwise it selects the numerically newest Windows Kits `10.0.26100.0` or newer x64 signtool, then the pinned AzureTrustedSignTool `1.3.13` user-profile tool-store bundle. That bundled x64 tool with the x64 dlib is accepted without a Windows SDK. The selected signtool and dlib must have matching PE machine types; invalid headers or a mismatch fail with a prerequisite error before signing credentials enter the environment. `signing-tool.json` and the verification receipt record the tool path, version, dlib path and both machine types.
- After the first copy-back hash check, the driver stops and reaps the ownership heartbeat, cleans up the remote process and metadata, and releases only its own VM lock. Cleanup and Release each retry transport exits 124/255 at most three times with 20/40-second backoff. If release remains unsuccessful, a CRITICAL diagnostic retains the lock for human inspection without another exit-cleanup retry; the hash-verified Mac corresponding-source, manifest and upload steps still finish. The driver then exits 75 with a summary identifying the retained VM lock. Mac-only work never depends on a running heartbeat or continued VM availability.
- Exit cleanup ignores further INT, TERM and HUP signals while its bounded steps run. It stops and reaps the heartbeat before terminating the active step, so a repeated interrupt or heartbeat signal cannot prevent the owner-checked release. On failure it first attempts to copy only `out/evidence` back to the Mac with a 60-second timeout, never `private`; copy failure does not skip remote cleanup. Installer aggregate errors carry the original error and every cleanup error in the outer message, including on Windows PowerShell 5.1. Before Setup starts, `out/evidence/<rid>/install-root.json` records the temporary install root; only successful cleanup removes the marker. After taskkill, remote cleanup handles every marker in this run: bounded 180-second uninstall, process cleanup, root removal, then marker deletion, within a 600-second remote-call limit; unmarked roots and other runs are untouched. A failed app kill never skips uninstall. Cleanup waits 60 seconds for root-matched processes, force-stops any remaining processes on timeout, waits another 10 seconds, then removes the root with at most five attempts two seconds apart, checking existence each time. The CLI version check is bounded to 60 seconds. Failed cleanup retains its marker and the VM lock for inspection.
- After ambiguous acquisition, exit cleanup retries owner-checked Release on transport exits 124/255 at most three times with 20/40-second backoff. Successful release and a first-attempt 74 are silent; an exhausted transport retry budget produces a WARNING identifying the run, owner and lock. A later 74 after an ambiguous reply follows the lost-reply rule below.
- A Release exit 74 after an earlier 124/255 means an earlier release reply was lost: Describe reports current state and the driver prints that this invocation no longer owns the lock, without a retained-lock failure or exit 75. A first-attempt 74 during normal release keeps the CRITICAL human-inspection path.
- Every invocation, including resume, uses a fresh random lock owner separate from its run-directory ID. Acquisition timeouts and SSH transport failures retry owner checks within the lock deadline, including after later contention, to recover only that invocation's acquisition. Early-exit cleanup attempts an owner-checked release after successful or uncertain acquisition, including interruptions, but not after definite contention alone. A foreign/missing lock (exit 74) is left untouched and silent; diagnostics identify the run, invocation owner and lock path, never credential values.

### 3.7 Windows runtime redistribution gate (open)

ADR-030 records the narrow dependency-policy allowance for the official pinned Windows runtimes. Internal development and maintainer previews may continue under their development and test rights. The public-release agreement and payload notice conditions below remain open.

The win-x64 and win-arm64 self-contained publish inventories match 148 and 144 files respectively to Windows App SDK, Windows ML and WebView2 packages; no supported self-contained property has been found to prune the selected AI/ML files. The exact `Microsoft.WindowsAppSDK` 2.5.1 and `Microsoft.Windows.AI.MachineLearning` 2.1.74 package licences are in the root `THIRD_PARTY_NOTICES.md`. Both Section 3(a)(i) texts permit redistribution of files binplaced by the Windows App SDK, including self-contained deployments. Both Section 3(b)(ii) texts also require distributors and external end users to agree to terms that protect the Microsoft code and Microsoft at least as much as the package agreement. The complete notices in the installed folder provide the terms but do not record agreement. Section 3(b)(iii) places an indemnity duty on the application distributor, with an exception for claims based solely on unmodified distributable code. Both package notice files include Intel MKL simplified terms with a reverse-engineering restriction; the publish inventory has no file named `mkl`, which does not establish that MKL code is absent. Preserve the Section 4(b) exception for reverse engineering required by third-party open-source component terms and the explicit LGPL debugging exception in the SDK and ML notices. Any downstream agreement must apply only to Microsoft runtime components; VoxClip source stays MIT and the dynamically linked FFmpeg libraries retain their LGPL rights.

Pinned `vpk` 1.2.161 has `--instLicense`, but its Windows packer passes that input only to the optional `--msi` WiX licence dialog. `Pack-Velopack.ps1` ships Velopack Setup.exe, not MSI. Its Setup source accepts `--silent` ("hides all dialogs and answers 'yes' to all prompts") and has no licence agreement option or dialog. The MSI checkbox is part of the full UI sequence; quiet MSI installs skip that sequence. Adding `--instLicense` to the present Setup command would therefore create no agreement gate. The source is Velopack commit `92d6a1c91716729d449034df5c50307dcce39493`, recorded in the pinned `vpk` NuGet package; see `WindowsPackCommand.cs`, `WindowsPackCommandRunner.cs`, `MsiBuilder.cs`, `MsiTemplate.hbs`, `src/bins/src/setup.rs` and `LicenseAgreementDlg.wxs` in that commit.

ADR-R23 selects the runtime agreement path while retaining Setup.exe. Installation, including silent Setup, leaves acceptance unset. On first normal app launch a WinUI dialog shows the two exact bundled Microsoft runtime terms and requires **Accept and continue**; Quit, Escape and closing it stop before normal features. The bundled CLI supports `--runtime-terms` and `--accept-runtime-terms <SHA-256>`; other work fails with `runtimeTermsRequired` exit 7 until the current terms are accepted. Direct extraction has the same gate. An atomic per-user hash-only receipt persists across updates with unchanged terms and becomes invalid when the terms change. Redistributors must preserve this requirement or provide an equivalent agreement limited to those Microsoft components. The receipt does not modify VoxClip's MIT source licence or FFmpeg's LGPL rights.

For release integration, verify both published executables carry the complete root notices, run the CLI terms command against the staged payload, and check that a fresh isolated `VOXCLIP_DATA_DIR` fails `voxclip-cli probe missing-media.mp4 --json` with `runtimeTermsRequired` and exit 7 before input access. Parse the first line of the JSON `output` from `voxclip-cli --runtime-terms --json` as the 64-character SHA-256, run `voxclip-cli --accept-runtime-terms <SHA-256> --json` in that same data root, then require `mediaMissing` and exit 3 from the probe. Removing or corrupting `windows-runtime-agreement.txt` must restore the exit-7 gate. Existing app `--self-check` smoke runs must first complete the dialog or use a receipt accepted through the bundled CLI in the same isolated data root; `version` alone does not test the gate. Exercise the WinUI accept, Quit and unchanged-update paths on the final package, including silent Setup and direct extraction. The public Windows release remains blocked until final package agreement behavior and payload/runtime notice audits are verified; the implementation and offline tests alone do not close that condition.

The separate Velopack Setup, Update/Squirrel and execution-stub notice audit is recorded in `doc/dependency-notices-audit.md`. The root notices now include exact pinned Rust, native and data texts in addition to Velopack's MIT licence. Before either RID is packed, the release script hashes all six architecture-specific `vpk` 1.2.161 vendor inputs against the pinned NuGet archive. For each RID it requires one `Full` package named for the current version and RID, compares that package's notices and the installed notices with the tagged release root, and compares installed Update/stub bytes with that same package's entries. Velopack edits resources and Setup's bundle and signs these files, so these comparisons establish input and package/install propagation, not a final binary link inventory. The earlier local signed installer predates these notices and checks; a new Windows release run is needed to verify its resulting assets.

The installed CLI smoke test sets `VOXCLIP_DATA_DIR` to a fresh directory under its temporary install root. It requires the bundled notices beside both executables, reads `--runtime-terms --json`, checks its SHA-256 first line, requires `runtimeTermsRequired`/7 before acceptance, then accepts that hash only in the isolated directory. A missing-media probe must return `mediaMissing`/3 after acceptance and `runtimeTermsRequired`/7 again after the receipt is removed and after it is separately corrupted. Silent installation is never counted as acceptance. Any real App `--self-check` must first accept in that same isolated data root; this CLI smoke test does not establish the interactive dialog behavior.

---

## 4. Version bump and release procedure

1. Pick the version `X.Y.Z` or `X.Y.Z-beta.N` (numeric components only; no other suffixes or build metadata). macOS rejects any other version format. Numbered beta drafts are created with `gh release create --prerelease` (also printed in dry runs), never "latest"; an existing draft's `isPrerelease` must agree with the version. Use the full chosen version, including `-beta.N`, everywhere `X.Y.Z` appears below.
2. Run `tools/release/set-version.sh X.Y.Z`. It sets `CFBundleShortVersionString` to `X.Y.Z`, increments `CFBundleVersion` by 1 in `apps/macos/Sources/VoxClip/Info.plist`, and sets `<Version>` in `apps/windows/Directory.Build.props`. `tools/release/check-version.sh` (also run in CI) fails if the two disagree.
3. Add a `## X.Y.Z - YYYY-MM-DD` section at the top of `CHANGELOG.md` (user-facing changes, one line each).
3a. **Subscription connector check** (ADR-R20). Confirm that `enabled` for `claude-code` and `codex` in `shared/catalog/llm-providers.json` matches the lead's current decision (0.1.0: both enabled, decided 2026-10-25). If a vendor has objected since (ai.md section 14 item 8), set that connector to `false` for this release. The switch is bundled data, so this is the only point where it can withdraw a connector.
3b. **Notices.** Every component added since the last release has its section in `THIRD_PARTY_NOTICES.md` with the exact licence text from the pinned package (not a placeholder).
4. Commit `Release X.Y.Z`, create the annotated tag `git tag -a vX.Y.Z -m "VoxClip X.Y.Z"`, push the commit and the tag. CI must be green on that commit.
5. macOS: unlock the Mac, then `cd apps/macos && ./bundle.sh --release` (creates or updates draft `vX.Y.Z` and uploads `VoxClip-macOS.dmg`, `VoxClip-macOS.zip`, `SHA256SUMS-macOS.txt`). The script refuses a locked screen before building and before each notarization (section 5). To separate packaging from upload, use `--release --no-upload`, inspect with `--upload-only --dry-run`, then use `--upload-only`. A missing release is created only on `release not found`; transient query errors stop without creating a draft. Never publish automatically.
6. Windows: start the VM, then `VOXCLIP_WIN_HOST=… VOXCLIP_SIGNING_ENV=… apps/windows/build/release-windows.sh` (uploads both Setup.exe files, the feeds, the packages and `SHA256SUMS-windows.txt` to the same draft).
7. Smoke-test from the draft: `gh release download vX.Y.Z --pattern 'VoxClip-*' -D "$(mktemp -d)/vc-rc"` (outside the checkout, so no release artifact can be committed); on a second macOS account open the DMG (quarantined download) and launch; on a clean Windows VM snapshot run both installers. For stable releases only, check that an installed previous version updates (Windows) and that "Check for Updates…" sees the new version once published (macOS). Beta smoke tests cover the downloaded DMG and installers; neither update check offers betas (architecture.md sections 13.1 and 13.2).
8. Publish stable releases with `gh release edit vX.Y.Z --draft=false --latest`. Publish betas with `gh release edit vX.Y.Z-beta.N --draft=false`, keeping the draft's prerelease flag; never pass `--latest` for a beta.
9. **Stable releases only:** after the approved Pages publication succeeds, inspect the download links on `https://clip.voxconvo.com`: Mac, Windows x64, Windows Arm and FFmpeg corresponding source must link to the correct new tag and actual assets on GitHub Releases; verify each target returns the expected file. Check the version, sizes, any listed SHA-256, and video/caption playback. There are no voxconvo.com/download redirects. Betas keep the last stable app release on the page.

---

### 4.1 Launch page go-live — user's approval required

The page address is **clip.voxconvo.com**, served by GitHub Pages from this public repository (ADR-R32, user decision 2026-10-27). Pages is disabled until the user approves going live. The implementation task does not change DNS, repo settings, upload assets or publish releases.

Prepare approved captures and completed `doc/media/CREDITS.md`. Commit the approved byte size and SHA-256 for every MP4 and VTT in `site/media.json` with the user's capture approval. Stage those exact bytes in the media release named there. Until all pins are approved, leave their size and SHA-256 entries null: fetching skips the media release entirely and the builder uses placeholders. Approved fetching requires the API size/digest and downloaded bytes to match the committed pins. Use a tag containing the Pages workflow, and mark this media release **not latest**, preserving the latest stable `vX.Y.Z` app release for downloads. Videos never enter Git. Production fetching requires the Mac, Windows x64 and Windows Arm installers and matching FFmpeg corresponding source. Both platforms must pass acceptance before publishing 0.1.0 (ADR-R33).

Each of these go-live actions needs the user's approval:

1. **Approval required:** verify `voxconvo.com` for the **Siim account** in GitHub account settings → Pages → verified domains. Add GitHub's supplied `_github-pages-challenge-…` TXT record at GoDaddy and complete verification.
2. **Approval required:** enable Pages with **GitHub Actions** as the source and set this repository's custom domain to `clip.voxconvo.com`. In Settings → Environments → `github-pages` → Deployment branches and tags, keep `main` and add tag rules `v*` and `media-v*`.
3. **Approval required:** only after account verification and repository custom-domain assignment, add the GoDaddy CNAME `clip` → `siim.github.io`.
4. **Approval required:** wait for the certificate, then turn on **Enforce HTTPS**.
5. **Approval required:** publish the release, or dispatch **Launch page** from `main`.

Never point DNS at GitHub before steps 1–2 are complete. Keep the verification TXT record permanently. If Pages is disabled again, remove the CNAME so it no longer points at GitHub. Until the environment tag rules exist, a release run only builds: its tag-ref deploy is rejected by `github-pages`. A `workflow_dispatch` from `main` publishes the same page: every run, whatever its trigger, builds `site/` and `site/media.json` from `main`.

The workflow tests the page offline, fetches public release assets, verifies their byte sizes and SHA-256, builds, uploads with `actions/upload-pages-artifact` and deploys with `actions/deploy-pages`. It never changes Pages settings. Confirm its deployment and run step 9 above before announcing the URL.

---

## 5. Known gotchas

| Symptom | Cause and fix |
|---|---|
| `notarytool submit` → `HTTP status code: 403. A required agreement is missing or has expired.` | Not a credential problem. Apple revised the Program License Agreement. The Account Holder must accept it at developer.apple.com → Agreements, Tax, and Banking. It cannot be scripted. `set -e` stops the script before stapling or uploading, so published assets are untouched; re-run after accepting |
| `No Keychain password item found for profile: superscribe-notarize-2` while the profile worked earlier | The script checks screen lock before the release build and before every notarization using the command below. Both a locked-screen result and this notarytool error stop with `The Mac screen is locked (doc/release.md §5); unlock it and re-run. Do not re-create the notary profile.` An unreadable lock state also stops before submission. notarytool keeps the profile in the data-protection keychain, which is unreadable while the screen is locked even though `security show-keychain-info` reports the login keychain unlocked. Check with `ioreg -n Root -d1 -a \| plutil -extract IOConsoleUsers xml1 -o - - \| grep -A1 CGSSessionScreenIsLocked`; unlock the Mac and re-run. Do not re-create the profile |
| Notary profile still missing after unlocking | First unlock the screen and retry; do not recreate the profile for the locked-screen error above. The profile can genuinely be lost when its keychain is replaced (the original `superscribe-notarize` died on 22 Sep 2026). Test with `xcrun notarytool history --keychain-profile superscribe-notarize-2`. Re-create interactively with `xcrun notarytool store-credentials superscribe-notarize-2 --apple-id <the Apple ID from the maintainer's private notes> --team-id 5ZJ9N8WURW`; it prompts for an app-specific password, so the password never reaches shell history. Never write the Apple ID or password into this repo |
| App draws old-style controls, no Liquid Glass | The binary carries the wrong SDK stamp (seen when Xcode ran without an accepted licence). `bundle.sh` pins and verifies it; accept the Xcode licence and rebuild |
| `.build/release/VoxClip` is stale | Since Xcode 27 the products moved under `.build/out/Products/…`. Always use `swift build --show-bin-path` |
| Login-password prompt for the Keychain during local runs | An ad-hoc-signed build reading an item created by the signed app. Use `./bundle.sh --sign-only` for local testing; the CLI never touches the Keychain |
| `codesign --verify` fails with "unsealed contents present in the bundle root" | Something was copied to the `.app` root (for example a SwiftPM resource bundle). Only `Contents/` may hold files |
| `Developer ID Application` identity missing or expired | The certificate lasts 5 years. Check `security find-identity -v -p codesigning`; renew in the Apple Developer portal (Account Holder) |
| Signing fails with `AADSTS7000222` / `invalid_client` | The Entra app registration's client secret expired (secrets have a fixed lifetime). Create a new secret under Entra ID → App registrations → the signing app → Certificates & secrets, put it in the env file outside the repo, delete the old one. Also confirm the service principal still has the "Artifact Signing Certificate Profile Signer" role and that the Artifact Signing identity validation is current |
| Signing fails with 403 from the signing endpoint | Wrong account/profile in `AZURE_SIGNING_ACCOUNT` / `AZURE_SIGNING_PROFILE`, wrong region endpoint, or the role assignment is missing |
| signtool says it cannot load the dlib | signtool and the dlib have different architectures, or `metadata.json` has a BOM / is UTF-16. Use the x64 signtool with the x64 dlib, and the ASCII writer |
| "Windows protected your PC" (SmartScreen) on early downloads | Reputation builds per publisher identity and per file as downloads accumulate; a signature does not grant it instantly. Expected for the first releases; tell users "More info → Run anyway". Keep the publisher identity stable. Smart App Control can still block new low-reputation apps; signing every PE (section 3.6) is required for it to allow the app at all |
| Script dies on non-ASCII characters on the VM | Windows PowerShell 5.1 reads scripts as ANSI. Keep `.ps1` files ASCII (CI can check with `grep -nP '[^\x00-\x7F]'`) |
| Timestamp or token errors on the VM | VM clock drift after the Mac slept. Resync: `w32tm /resync` |
| Velopack update not found by users | The asset `releases.win-<arch>.json` is missing from the release, or the build was packed with a different `--channel`. Channels are permanent; never rename them |
| Launch page serves an old version | A release-published run uses a tag ref: the default `github-pages` environment allows only `main`, so missing `v*` / `media-v*` tag rules reject deployment after the build. Follow the approval-required environment setup in §4.1, or dispatch **Launch page** from `main` to publish the same page. Also check whether the app release is draft/pre-release, Pages is disabled, or latest-release metadata is wrong. Check the dispatch/release run and its joint-platform asset checks, then request a manual dispatch after approval. The media release must be marked not latest so `/releases/latest` continues to select the stable app release |
| `azure-signing.env` missing in a git worktree | Not applicable to VoxClip: the env file is never in the repo; `VOXCLIP_SIGNING_ENV` names its absolute path |
