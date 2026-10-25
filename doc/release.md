# VoxClip release and signing

Status: normative for 0.1.0. Date: 2026-10-25.

Releases are built and signed **locally**: macOS on the maintainer's Mac, Windows on the existing UTM Windows VM driven from the Mac over SSH. CI never signs. Every release is a **draft** GitHub Release on `github.com/Siim/voxclip` until a human publishes it. The voxconvo.com download page links to the latest published release's assets through constant asset names (publishing.md section 4).

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
3. **Resources.** Copy only Git-tracked runtime files in `shared/{caption-styles,catalog,design,fonts,prompts,schemas}`, excluding nested `fixtures/`; untracked/ignored files, ingest data, brand sources and tools never ship. Copy and byte-compare with the same NUL-delimited tracked manifests, not a scan of untracked files. List ignored files with `git ls-files -z`, rejecting listing errors and ignored files in shipped shared directories even with `--allow-dirty`, printing offending paths first. Ignore `.DS_Store` basenames everywhere in this gate, including non-ASCII, quoted or newline-containing paths, because untracked files never ship. Copy root `THIRD_PARTY_NOTICES.md`, `LICENSE` and the icon from `shared/brand`; strip dSYMs and thin embedded code to arm64.
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
- Velopack's `--signTemplate` calls `apps/windows/build/sign-if-needed.ps1` (section 3.5).

### 3.2 Credentials (never on a command line, never on the VM disk, never in the repo)

- The env file lives **outside this repo** on the release Mac. Its path is in the Mac env var `VOXCLIP_SIGNING_ENV` (for example the existing Superscribe signing env file). The driver refuses a path inside the repo.
- Recognised names (values are never printed): `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` (aliases accepted for the existing file: `AZURE_SIGNING_KVT`, `AZURE_SIGNING_KVI`, `AZURE_SIGNING_KVS`), plus the non-secret `AZURE_SIGNING_ENDPOINT` (default `https://neu.codesigning.azure.net`), `AZURE_SIGNING_ACCOUNT` and `AZURE_SIGNING_PROFILE` (the Haugas Development OU Artifact Signing account and certificate profile; required).
- The driver filters exactly these lines from the file and **streams them over the SSH session's stdin** to `vm-release.ps1`, which reads stdin once at start into a script-scoped hashtable and never writes the values anywhere. The builds, the FFmpeg download and the delta download run **without** credentials. Only then are `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` (what the dlib's `DefaultAzureCredential` reads) set as process environment variables, for the signing and packing steps alone (signtool, `vpk pack` with its sign template, the sign wrapper); they are removed before verification and the smoke install (section 3.4). The SSH command line carries only the version, paths and tool locations.
- `metadata.json` for the dlib is written by the VM script from the non-secret values, as single-line ASCII without a BOM (a UTF-16 or BOM file breaks the dlib):
  `{"Endpoint":"https://neu.codesigning.azure.net","CodeSigningAccountName":"<account>","CertificateProfileName":"<profile>"}`

### 3.3 Mac-side driver (`apps/windows/build/release-windows.sh`)

`write-pin` is a maintainer pin-update operation, not part of releasing an existing pin. Release builds verify `buildInputsSha256`, both clean-build results and the committed ZIP hashes; they never rewrite `ffmpeg.json` to accept different output. The shipping recipe excludes zimg and uses architecture section 6.5's existing swscale HDR fallback, without assuming a licence exception.

Env vars: `VOXCLIP_WIN_HOST` (required, `user@host`), `VOXCLIP_SIGNING_ENV` (required), `VOXCLIP_WIN_BUILD_DIR` (default `C:\voxclip-build`), `VOXCLIP_VM_SIGNTOOL` (default `C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe`), `VOXCLIP_VM_DLIB` (default `C:\trusted-signing-client\bin\x64\Azure.CodeSigning.Dlib.dll`). Flags: `--no-upload`, `--upload-only`.

The FFmpeg phase runs on the Mac **before transfer to the signing VM**. Use the pinned `tools/ffmpeg-build/` recipe, never BtbN downloads. Rebuild both RIDs from the source pins, check the resulting ZIPs against `ffmpeg.json` and run the two-clean-build comparison (architecture section 6.1). Pass the verified local ZIPs, the LGPL-2.1 text, build/runtime reports and dependency notices to the Windows packaging step; it must not redownload FFmpeg. `recipeCommit: "BUILD_COMMIT"` is resolved to this release's full commit. The source archive contains that exact recipe tree and the pinned original archives, including static-runtime and build-tool sources. Readers must accept schema 2 and remove their `btbnCommit`, `ffmpeg-builds` and BtbN-URL assumptions; a missing unpublished URL is not an error or permission to publish a new asset.

```bash
#!/usr/bin/env bash
# Release VoxClip for Windows from the Mac: build, sign, pack and verify on the VM, then upload.
# Never use `set -x` here: the signing stream must not be echoed.
set -euo pipefail
cd "$(dirname "$0")/../../.."                                     # repo root
REPO_ROOT="$(pwd)"
HOST="${VOXCLIP_WIN_HOST:?Set VOXCLIP_WIN_HOST=user@vm}"
SIGNING_ENV="${VOXCLIP_SIGNING_ENV:?Set VOXCLIP_SIGNING_ENV to the signing env file outside this repo}"
BUILD_DIR="${VOXCLIP_WIN_BUILD_DIR:-C:\\voxclip-build}"
SIGNTOOL="${VOXCLIP_VM_SIGNTOOL:-C:\\Program Files (x86)\\Windows Kits\\10\\bin\\10.0.26100.0\\x64\\signtool.exe}"
DLIB="${VOXCLIP_VM_DLIB:-C:\\trusted-signing-client\\bin\\x64\\Azure.CodeSigning.Dlib.dll}"
GITHUB_REPO="${GITHUB_REPO:-Siim/voxclip}"
DIST="apps/windows/dist"
NO_UPLOAD=false; UPLOAD_ONLY=false
for a in "$@"; do case "$a" in --no-upload) NO_UPLOAD=true ;; --upload-only) UPLOAD_ONLY=true ;; *) echo "Unknown $a" >&2; exit 2 ;; esac; done

VERSION=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' apps/windows/Directory.Build.props | head -1)
TAG="v$VERSION"
tools/release/check-version.sh >/dev/null
[ -z "$(git status --porcelain)" ] || { echo "Working tree is dirty." >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}" 2>/dev/null)" ] || { echo "HEAD is not tagged $TAG." >&2; exit 1; }
BUILD_COMMIT="$(git rev-parse "$TAG^{commit}")"
FFMPEG_CACHE="$HOME/Library/Caches/voxclip-ffmpeg-build"

upload() {
  (cd "$DIST" && shasum -a 256 -c SHA256SUMS-windows.txt)
  gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1 \
    || gh release create "$TAG" --repo "$GITHUB_REPO" --draft --verify-tag --title "VoxClip $VERSION" --notes "Windows build"
  [ "$(gh release view "$TAG" --repo "$GITHUB_REPO" --json isDraft --jq .isDraft)" = "true" ] \
    || { echo "$TAG is already published; refusing to replace assets." >&2; exit 1; }
  gh release upload "$TAG" "$DIST"/* --repo "$GITHUB_REPO" --clobber
  echo "Attached Windows assets to draft $TAG."
}
if [ "$UPLOAD_ONLY" = true ]; then upload; exit 0; fi

# Credentials file: outside the repo, has the required names (values never printed).
SIGNING_REAL="$(cd "$(dirname "$SIGNING_ENV")" && pwd)/$(basename "$SIGNING_ENV")"
case "$SIGNING_REAL" in "$REPO_ROOT"/*) echo "VOXCLIP_SIGNING_ENV must point outside the repo." >&2; exit 1 ;; esac
NAMES='AZURE_TENANT_ID|AZURE_CLIENT_ID|AZURE_CLIENT_SECRET|AZURE_SIGNING_KVT|AZURE_SIGNING_KVI|AZURE_SIGNING_KVS|AZURE_SIGNING_ENDPOINT|AZURE_SIGNING_ACCOUNT|AZURE_SIGNING_PROFILE'
grep -Eq '^(AZURE_CLIENT_SECRET|AZURE_SIGNING_KVS)=.+' "$SIGNING_ENV" || { echo "No client secret in the signing env file." >&2; exit 1; }
grep -Eq '^AZURE_SIGNING_ACCOUNT=.+' "$SIGNING_ENV" && grep -Eq '^AZURE_SIGNING_PROFILE=.+' "$SIGNING_ENV" \
  || { echo "AZURE_SIGNING_ACCOUNT and AZURE_SIGNING_PROFILE must be set in the signing env file." >&2; exit 1; }

ssh -o ConnectTimeout=5 "$HOST" "echo connected" >/dev/null

# 0. Rebuild both RIDs twice from clean source; verify reproducibility and the committed pin.
# The recipe enforces at most two concurrent compiler jobs and 15 GiB free.
python3 -I tools/ffmpeg-build/build.py fetch --cache "$FFMPEG_CACHE"
for rid in win-x64 win-arm64; do
  for attempt in 1 2; do
    python3 -I tools/ffmpeg-build/build.py build --rid "$rid" --attempt "$attempt" --jobs 2 --cache "$FFMPEG_CACHE"
  done
done
python3 -I tools/ffmpeg-build/build.py verify --cache "$FFMPEG_CACHE"

# 1. Ship a clean archive of the TAG (not the working tree) and replace the VM source tree entirely.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git archive --format=tar --prefix=src/ -o "$TMP/src.tar" "$TAG" apps/windows shared LICENSE THIRD_PARTY_NOTICES.md CHANGELOG.md
ssh "$HOST" "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '$BUILD_DIR' | Out-Null\""
scp -q "$TMP/src.tar" "$HOST:${BUILD_DIR//\\//}/src.tar"
ssh "$HOST" "powershell -NoProfile -Command \"Remove-Item -Recurse -Force '$BUILD_DIR\\src','$BUILD_DIR\\out' -ErrorAction SilentlyContinue; tar -xf '$BUILD_DIR\\src.tar' -C '$BUILD_DIR'; if (\$LASTEXITCODE) { exit 1 }\""
# The VM consumes only the verified local ZIPs and their licence/build reports.
ssh "$HOST" "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '$BUILD_DIR\\ffmpeg' | Out-Null\""
for rid in win-x64 win-arm64; do
  scp -q "$FFMPEG_CACHE/reports/$rid-1/voxclip-ffmpeg-n9.0.2-$rid.zip" "$HOST:${BUILD_DIR//\\//}/ffmpeg/"
  scp -q "$FFMPEG_CACHE/reports/$rid-1/report.json" "$HOST:${BUILD_DIR//\\//}/ffmpeg/$rid-report.json"
  scp -q "$FFMPEG_CACHE/reports/$rid-1/FFmpeg-NOTICES.txt" "$HOST:${BUILD_DIR//\\//}/ffmpeg/$rid-NOTICES.txt"
done
for notice in FFmpeg-LICENSE.txt FFmpeg-LICENSE.md; do
  scp -q "$FFMPEG_CACHE/reports/win-x64-1/$notice" "$HOST:${BUILD_DIR//\\//}/ffmpeg/$notice"
done

# 2. Build, sign, pack, verify on the VM. Credentials go over stdin only.
grep -E "^($NAMES)=" "$SIGNING_ENV" | tr -d '\r' | ssh "$HOST" \
  "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$BUILD_DIR\\src\\apps\\windows\\build\\vm-release.ps1\" -Version $VERSION -BuildDir \"$BUILD_DIR\" -SignTool \"$SIGNTOOL\" -Dlib \"$DLIB\""

# 3. Copy the upload set back (individual files, no zip: Windows zips drop directory execute bits).
rm -rf "$DIST"; mkdir -p "$DIST"
scp -q "$HOST:${BUILD_DIR//\\//}/out/upload/*" "$DIST/"
(cd "$DIST" && shasum -a 256 -c SHA256SUMS-windows.txt)

# 4. LGPL corresponding source for the shipped FFmpeg DLLs (architecture.md section 6.1), built on the Mac
#    from the verified source/runtime/build-tool archives, plus the recipe at BUILD_COMMIT.
#    Both local DLL ZIPs have already passed the ABI, source, GPL-marker and reproducibility gates.
SRC="$TMP/ffmpeg-source"; mkdir -p "$SRC"
python3 - "$SRC" "$FFMPEG_CACHE" "$BUILD_COMMIT" <<'PY'
import hashlib, json, sys, pathlib, shutil, tarfile, io
out = pathlib.Path(sys.argv[1]); pin = json.load(open("apps/windows/build/ffmpeg.json"))
cache = pathlib.Path(sys.argv[2]); pin["recipeCommit"] = sys.argv[3]
for a in pin["sourceAssets"] + pin["buildTools"]:
    data = (cache / "downloads" / a["name"]).read_bytes()
    if hashlib.sha256(data).hexdigest() != a["sha256"]: sys.exit(f"sha256 mismatch: {a['name']}")
    if a.get("includePaths"):
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            selected = [member for member in archive.getmembers() if any(
                "/".join(pathlib.PurePosixPath(member.name).parts[1:]) == prefix or
                "/".join(pathlib.PurePosixPath(member.name).parts[1:]).startswith(prefix + "/")
                for prefix in a["includePaths"])]
            archive.extractall(out / (a["component"] + "-selected-source"), members=selected, filter="data")
    else:
        (out / a["name"]).write_bytes(data)
shutil.copytree("tools/ffmpeg-build", out / "tools/ffmpeg-build", ignore=shutil.ignore_patterns("__pycache__"))
shutil.copyfile("THIRD_PARTY_NOTICES.md", out / "THIRD_PARTY_NOTICES.md")
(out / "ffmpeg.json").write_text(json.dumps(pin, indent=2) + "\n", encoding="utf-8")
(out / "BUILD.txt").write_text("FFmpeg %s, recipe %s\nlicense: %s\n" %
    (pin["sourceCommit"], pin["recipeCommit"], pin["license"]) + "".join(
    "configure %s: %s\nruntimeObjects %s: %s\n" %
    (rid, pin["configure"][rid], rid, json.dumps(json.load(open(cache / "reports" / (rid + "-1") / "report.json"))["runtimeObjects"], sort_keys=True))
    for rid in ("win-x64", "win-arm64")), encoding="utf-8")
for name in ("FFmpeg-LICENSE.txt", "FFmpeg-LICENSE.md"):
    shutil.copyfile(cache / "reports" / "win-x64-1" / name, out / name)
for rid in ("win-x64", "win-arm64"):
    shutil.copyfile(cache / "reports" / (rid + "-1") / "FFmpeg-NOTICES.txt",
                    out / (rid + "-NOTICES.txt"))
PY
tar -C "$TMP" -cJf "$DIST/VoxClip-win-ffmpeg-source.tar.xz" ffmpeg-source
(cd "$DIST" && shasum -a 256 VoxClip-win-ffmpeg-source.tar.xz >> SHA256SUMS-windows.txt)
if command -v osslsigncode >/dev/null; then
  for f in "$DIST"/*-Setup.exe; do osslsigncode verify -in "$f" >/dev/null || { echo "Signature check failed: $f" >&2; exit 1; }; done
fi
[ "$NO_UPLOAD" = true ] && { echo "Built and verified in $DIST. Upload with --upload-only."; exit 0; }
upload
```

### 3.4 VM-side script (`apps/windows/build/vm-release.ps1`, ASCII only)

Normative steps (the script is written at scaffold time; this is its contract):

1. `$ErrorActionPreference = 'Stop'`; `Set-StrictMode -Version Latest`. Every native command is followed by `if ($LASTEXITCODE -ne 0) { throw "<step> failed" }` (no grepping output for "error").
2. **Credentials from stdin into memory only:** `$raw = [Console]::In.ReadToEnd()`. Parse `NAME=VALUE` lines (strip one pair of surrounding quotes), map aliases (`KVT → AZURE_TENANT_ID`, `KVI → AZURE_CLIENT_ID`, `KVS → AZURE_CLIENT_SECRET`), require tenant, client id, secret, account and profile, and keep them in a script-scoped hashtable `$Creds`. **Set no environment variable yet.** Clear `$raw`. Never `Write-Host` a value; log only "Signing credentials: present".
3. Write `$BuildDir\signing\metadata.json` (non-secret values only) with `[IO.File]::WriteAllText(path, json, [Text.Encoding]::ASCII)`.
4. `cd $BuildDir\src\apps\windows`; `dotnet tool restore`; `dotnet --version` must start with `10.`. Set `$env:MSBUILDDISABLENODEREUSE = '1'` and `$env:DOTNET_CLI_USE_MSBUILD_SERVER = '0'`. The script never passes `-bl` or `-v:diag`.
5. **Build phase, no credentials in the environment.** For `rid` in `win-x64` (`Platform=x64`), `win-arm64` (`Platform=ARM64`):
   1. `dotnet publish src\VoxClip.Cli\VoxClip.Cli.csproj -c Release -r <rid> --self-contained -nodeReuse:false -p:UseSharedCompilation=false -o ..\..\..\out\<rid>\app`
   2. `dotnet publish src\VoxClip.App\VoxClip.App.csproj -c Release -r <rid> -p:Platform=<platform> --self-contained -nodeReuse:false -p:UseSharedCompilation=false -o ..\..\..\out\<rid>\app` (the App last; both share one folder and one runtime).
   3. **FFmpeg and notices:** read schema-2 `build\ffmpeg.json`; require the Mac-staged `<rid>` ZIP in `$BUILD_DIR\ffmpeg\` with its pinned local `name`; `Get-FileHash -Algorithm SHA256` must equal the recorded hash (otherwise delete and fail). No download fallback. Extract and require exactly the six ABI-named DLLs in `libraryMajors`, then copy them from `bin\` into the app folder. Stage the pinned `FFmpeg-LICENSE.txt`, `FFmpeg-LICENSE.md` and `<rid>-NOTICES.txt` from `$BUILD_DIR\ffmpeg\` into `licenses\` (the last as `FFmpeg-NOTICES.txt`); write `licenses\FFmpeg-BUILD.txt` with `sourceCommit`, the resolved recipe `BUILD_COMMIT`, the RID's exact configure/licence strings and runtime inventory from `<rid>-report.json`. Copy repository `LICENSE` and `THIRD_PARTY_NOTICES.md` into `out\<rid>\app\`.
   4. **Delta base (optional):** `dotnet vpk download github --repoUrl https://github.com/Siim/voxclip --channel <rid> -o ..\..\..\out\<rid>\releases` (no token; failure on the first release is ignored).

   Then `dotnet build-server shutdown`, so no MSBuild node or compiler server outlives this phase.
6. **Signing phase.** Set `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` from `$Creds` with `[Environment]::SetEnvironmentVariable(name, value, 'Process')`, inside `try { … } finally { … }`. For each `rid`:
   1. **Sign every PE we ship:** `Get-ChildItem out\<rid>\app -Recurse -Include *.exe,*.dll` → files whose `Get-AuthenticodeSignature` status is not `Valid` → `sign-if-needed.ps1` (section 3.5) in batches of 50. Files already validly signed by their publisher (Microsoft runtime and Windows App SDK files, SkiaSharp) keep their signature; everything else (our assemblies and executables, FFmpeg, Whisper.net natives, NAudio, Velopack) is signed by us.
   2. **Pack:** `dotnet vpk pack --packId VoxClip --packVersion <version> --packTitle VoxClip --packAuthors "Haugas Development OU" --packDir out\<rid>\app --mainExe VoxClip.exe --icon src\VoxClip.App\Assets\VoxClip.ico --channel <rid> --runtime <rid> --noPortable --releaseNotes <notes file from CHANGELOG.md> --signTemplate "<wrapper command> {{file...}}" -o out\<rid>\releases`. The sign template points at the same wrapper, so Velopack's own `Update.exe` and the `Setup.exe` are signed with the same identity, and files already signed are left alone.
   3. **Sign the installer:** if `VoxClip-<rid>-Setup.exe` is not `Valid` after packing, sign it with the wrapper (post-signing Setup.exe is allowed).

   The `finally` block runs `Remove-Item Env:AZURE_TENANT_ID, Env:AZURE_CLIENT_ID, Env:AZURE_CLIENT_SECRET -ErrorAction SilentlyContinue` and clears `$Creds`, whether signing succeeded or not.
7. **Verify phase, credentials already removed** (fail the release on any miss). For each `rid`:
   - every PE in `out\<rid>\app` has status `Valid`;
   - `VoxClip-<rid>-Setup.exe` is `Valid` and its signer subject contains `Haugas Development OU`; `signtool verify /pa /v` succeeds on it;
   - copy the full `.nupkg` to a `.zip`, expand it to a temp folder, and every PE inside is `Valid`;
   - smoke install: run the Setup.exe silently into a temp folder (`--silent --installto <temp>`; check the flags against the pinned Velopack version), check that every PE under it (including `Update.exe`) is `Valid`, that `current\LICENSE`, `current\THIRD_PARTY_NOTICES.md`, `current\licenses\FFmpeg-LICENSE.txt` and `current\licenses\FFmpeg-BUILD.txt` exist, run `current\voxclip-cli.exe version` and compare with `<version>`, then uninstall silently. The x64 installer runs under emulation on the ARM64 VM.
8. Collect the upload set into `out\upload\`: both Setup.exe files, every `.nupkg` listed in `assets.<rid>.json` for this version, and `releases.<rid>.json`. Write `SHA256SUMS-windows.txt` (`<lowercase sha256><two spaces><file name>`, LF endings, ASCII). The Mac driver adds the FFmpeg source asset to it (section 3.3).
9. Remove `$BuildDir\signing\` and `$BuildDir\src.tar`. Exit 0.

### 3.5 Signing wrapper (`apps/windows/build/sign-if-needed.ps1`)

Parameters: `-SignTool <path> -Dlib <path> -Metadata <path> <files...>`. For each file: skip if `Get-AuthenticodeSignature` is `Valid`; collect the rest and run, in batches of 50:

```text
"<SignTool>" sign /v /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib "<Dlib>" /dmdf "<Metadata>" <file> <file> …
```

Exit non-zero if signtool fails or if any file is still not `Valid` afterwards. The wrapper reads credentials only from the process environment it inherits.

### 3.6 What the Windows flow guarantees

- The VM builds exactly the tagged commit (clean `git archive`, the old tree deleted first), so files deleted locally never survive on the VM.
- Every PE file in the install folder, the packages and the installer carries a valid Authenticode signature, most of them ours (Smart App Control checks every loaded module).
- Failures are detected by exit codes, not by grepping logs.
- Credentials exist only in the memory of one SSH session on the VM: in a script variable during the build phase, and in that one PowerShell process's environment only during the signing phase. No build tool, MSBuild node, compiler server, binlog, installer or smoke-test process ever sees them.
- The install folder carries VoxClip's `LICENSE`, the full `THIRD_PARTY_NOTICES.md` and the FFmpeg licence and build notes, and every release carries the FFmpeg corresponding source.
- Results are hash-checked after the copy back, and optionally signature-checked on the Mac with `osslsigncode`.

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
7. Smoke-test from the draft: `gh release download vX.Y.Z --pattern 'VoxClip-*' -D /tmp/vc-rc`; on a second macOS account open the DMG (quarantined download) and launch; on a clean Windows VM snapshot run both installers. For stable releases only, check that an installed previous version updates (Windows) and that "Check for Updates…" sees the new version once published (macOS). Beta smoke tests cover the downloaded DMG and installers; neither update check offers betas (architecture.md sections 13.1 and 13.2).
8. Publish stable releases with `gh release edit vX.Y.Z --draft=false --latest`. Publish betas with `gh release edit vX.Y.Z-beta.N --draft=false`, keeping the draft's prerelease flag; never pass `--latest` for a beta.
9. **Stable releases only:** check the download page redirects: `curl -sI https://voxconvo.com/download/macos | grep -i location` (and `windows`, `windows-arm64`) point at `releases/latest/download/<asset>`, and those URLs return 302 to the new files. For betas, the download page keeps serving the last stable release.

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
| Download page serves an old version | The new release is still a draft or marked pre-release. `releases/latest` only follows published, non-pre-release releases |
| `azure-signing.env` missing in a git worktree | Not applicable to VoxClip: the env file is never in the repo; `VOXCLIP_SIGNING_ENV` names its absolute path |
