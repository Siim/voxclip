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
| `VoxClip-win-ffmpeg-source.tar.xz` | Windows | Corresponding source for the shipped LGPL FFmpeg DLLs: FFmpeg at `sourceCommit`, the BtbN FFmpeg-Builds scripts at `btbnCommit`, the source of every library linked into the DLLs, and `BUILD.txt` with the configure line (architecture.md section 6.1). Constant name; attached to every release that ships Windows |
| `SHA256SUMS-windows.txt` | Windows | `<sha256>  <file>` lines for every Windows asset above |

The download-page targets never carry a version in their names, so `https://github.com/Siim/voxclip/releases/latest/download/<asset>` always resolves to the newest **published** release. Drafts and pre-releases are never "latest". Velopack's package files carry versions by design; Velopack finds them through the feed files.

Not uploaded: `RELEASES-*` (legacy Squirrel feeds), `assets.*.json` (local build metadata), Portable zips (disabled with `--noPortable`).

---

## 2. macOS release

### 2.1 Prerequisites (on the release Mac)

- Xcode with the newest macOS SDK, licence accepted (`sudo xcodebuild -license accept`). Check `xcrun --sdk macosx --show-sdk-version`.
- The Developer ID identity in the login keychain: `security find-identity -v -p codesigning | grep "Developer ID Application: Haugas Development OU (5ZJ9N8WURW)"`.
- The notary profile works: `xcrun notarytool history --keychain-profile superscribe-notarize-2` (an authenticated call; `security find-generic-password` failing to find it proves nothing).
- `create-dmg` (`brew install create-dmg`), `gh` signed in with release rights on `Siim/voxclip`.

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

### 2.3 `bundle.sh` (template; lives at `apps/macos/bundle.sh`)

Modes:

| Command | Result |
|---|---|
| `./bundle.sh` | debug build, ad-hoc signed. Anyone can run it |
| `./bundle.sh --sign-only` | release build signed with the Developer ID, no notarization. Same designated requirement as releases, so camera/mic grants and Keychain access survive rebuilds |
| `./bundle.sh --release --no-upload` | signed, notarized, stapled `.app`, zip and DMG in `dist/`; nothing leaves the machine |
| `./bundle.sh --upload-only` | attach the `dist/` artifacts to the draft release `v<version>` |
| `./bundle.sh --release` | both of the above |
| `--allow-dirty` | permit a dirty tree or untagged HEAD (test builds only; refused together with `--upload-only`) |

```bash
#!/bin/bash
# Build, sign, notarize and package VoxClip for macOS (arm64).
# Signing follows doc/release.md. Override SIGNING_IDENTITY / TEAM_ID / NOTARIZE_PROFILE for forks.
# bash 3.2 (macOS /bin/bash): no `set -u` (empty "${arr[@]}" is an error there). Never use `set -x`.
set -eo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"

EXECUTABLE="VoxClip"
CLI="voxclip-cli"
DISPLAY_NAME="VoxClip"
BUNDLE_ID="com.voxconvo.voxclip"
INFO_PLIST="Sources/VoxClip/Info.plist"
ENTITLEMENTS="VoxClip.entitlements"
DIST="dist"
APP_BUNDLE="$DIST/$DISPLAY_NAME.app"
DMG="$DIST/VoxClip-macOS.dmg"
ZIP="$DIST/VoxClip-macOS.zip"
SUMS="$DIST/SHA256SUMS-macOS.txt"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Haugas Development OU (5ZJ9N8WURW)}"
TEAM_ID="${TEAM_ID:-5ZJ9N8WURW}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-superscribe-notarize-2}"
GITHUB_REPO="${GITHUB_REPO:-Siim/voxclip}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
PLIST_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")
[ "$PLIST_ID" = "$BUNDLE_ID" ] || { echo "Info.plist says $PLIST_ID, script says $BUNDLE_ID" >&2; exit 1; }
TAG="v$VERSION"

RELEASE=false; SIGN_ONLY=false; NO_UPLOAD=false; UPLOAD_ONLY=false; ALLOW_DIRTY=false
for arg in "$@"; do
  case "$arg" in
    --release|-r)  RELEASE=true ;;
    --sign-only)   RELEASE=true; SIGN_ONLY=true ;;
    --no-upload)   NO_UPLOAD=true ;;
    --upload-only) UPLOAD_ONLY=true ;;
    --allow-dirty) ALLOW_DIRTY=true ;;
    *) echo "Unknown option $arg" >&2; exit 2 ;;
  esac
done

# ---------- release preconditions: clean tree, HEAD is the tag, versions agree ----------
check_release_tree() {
  [ "$ALLOW_DIRTY" = true ] && return 0
  [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || { echo "Working tree is dirty. Commit or use --allow-dirty (no upload)." >&2; exit 1; }
  [ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$(git -C "$REPO_ROOT" rev-parse "$TAG^{commit}" 2>/dev/null)" ] \
    || { echo "HEAD is not tagged $TAG." >&2; exit 1; }
  "$REPO_ROOT/tools/release/check-version.sh" >/dev/null
}

# ---------- publish a previous --no-upload build ----------
upload() {
  [ "$ALLOW_DIRTY" = true ] && { echo "--allow-dirty builds are never uploaded." >&2; exit 1; }
  for f in "$DMG" "$ZIP" "$SUMS"; do [ -f "$f" ] || { echo "Missing $f: run ./bundle.sh --release --no-upload" >&2; exit 1; }; done
  xcrun stapler validate "$APP_BUNDLE" >/dev/null
  xcrun stapler validate "$DMG" >/dev/null
  (cd "$DIST" && shasum -a 256 -c "$(basename "$SUMS")")
  command -v gh >/dev/null || { echo "Install the GitHub CLI (gh)" >&2; exit 1; }
  if ! gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    NOTES=$(mktemp); awk -v v="$VERSION" '$0 ~ "^## "v {f=1; next} /^## / && f {exit} f' "$REPO_ROOT/CHANGELOG.md" > "$NOTES"
    gh release create "$TAG" --repo "$GITHUB_REPO" --draft --verify-tag --title "VoxClip $VERSION" --notes-file "$NOTES"
  fi
  [ "$(gh release view "$TAG" --repo "$GITHUB_REPO" --json isDraft --jq .isDraft)" = "true" ] \
    || { echo "$TAG is already published; refusing to replace assets." >&2; exit 1; }
  gh release upload "$TAG" "$DMG" "$ZIP" "$SUMS" --repo "$GITHUB_REPO" --clobber
  echo "Attached to draft release $TAG. Review and publish it on GitHub."
}
if [ "$UPLOAD_ONLY" = true ]; then check_release_tree; upload; exit 0; fi

# ---------- identity check (release modes) ----------
if [ "$RELEASE" = true ]; then
  [ "$SIGN_ONLY" = true ] || check_release_tree
  security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY" || {
    echo "Signing identity not in the keychain: $SIGNING_IDENTITY" >&2
    echo "Contributors: run ./bundle.sh without flags for an ad-hoc build." >&2; exit 1; }
fi

# ---------- SDK pin: the SDK stamped into the binary decides how macOS draws the app ----------
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
SDK_VERSION=$(/usr/bin/plutil -extract Version raw -o - "$SDK_PATH/SDKSettings.json" 2>/dev/null \
  || /usr/bin/plutil -extract Version raw -o - "$SDK_PATH/SDKSettings.plist" 2>/dev/null || true)
MIN_MACOS=$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' Package.swift | head -1)
[ -n "$SDK_VERSION" ] && [ -n "$MIN_MACOS" ] || {
  echo "Cannot read the SDK version (${SDK_PATH:-none}) or the minimum macOS in Package.swift" >&2; exit 1; }
SDK_MAJOR="${SDK_VERSION%%.*}"; MIN_MAJOR="${MIN_MACOS%%.*}"
[ "$SDK_MAJOR" -ge "$MIN_MAJOR" ] || { echo "SDK $SDK_VERSION is older than the minimum macOS $MIN_MACOS" >&2; exit 1; }
BUILD_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION")
CONFIG=$([ "$RELEASE" = true ] && echo release || echo debug)

[ "$(uname -m)" = "arm64" ] || { echo "Build on Apple silicon: v1 ships arm64 only." >&2; exit 1; }
echo "Building $DISPLAY_NAME $VERSION ($BUILD_NUMBER), $CONFIG, arm64, macOS $MIN_MACOS+, SDK $SDK_VERSION"
swift build -c "$CONFIG" "${BUILD_FLAGS[@]}"                                       # host arch (arm64); no --arch
BIN_DIR=$(swift build -c "$CONFIG" "${BUILD_FLAGS[@]}" --show-bin-path)            # Xcode 27 moved .build paths

OTOOL=""
for c in "$(xcrun --find otool 2>/dev/null || true)" /Library/Developer/CommandLineTools/usr/bin/otool \
         /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/otool; do
  if [ -n "$c" ] && [ -x "$c" ]; then OTOOL="$c"; break; fi
done
[ -n "$OTOOL" ] || { echo "No otool found" >&2; exit 1; }
for b in "$BIN_DIR/$EXECUTABLE" "$BIN_DIR/$CLI"; do
  BUILT_SDK=$("$OTOOL" -l "$b" | awk '/LC_BUILD_VERSION/ {f=1} f && $1=="sdk" {print $2; exit}')
  [ "$BUILT_SDK" = "$SDK_VERSION" ] || { echo "$b says SDK ${BUILT_SDK:-none}, expected $SDK_VERSION" >&2; exit 1; }
done

# ---------- licence gate: no GPL code in anything we ship ----------
for b in "$BIN_DIR/$EXECUTABLE" "$BIN_DIR/$CLI" "$BIN_DIR"/*.framework/Versions/A/*; do
  [ -f "$b" ] || continue
  if nm "$b" 2>/dev/null | grep -Eq '_espeak_ng_|_x264_encoder_open|_x265_encoder_open|_avcodec_open2'; then
    echo "Licence gate: GPL or ffmpeg symbols found in $b (VoxClip ships no espeak-ng, x264, x265 or ffmpeg on macOS)." >&2
    exit 1
  fi
done

# ---------- assemble the bundle ----------
rm -rf "$APP_BUNDLE"; mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
cp "$BIN_DIR/$EXECUTABLE" "$BIN_DIR/$CLI" "$APP_BUNDLE/Contents/MacOS/"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
cp "$REPO_ROOT/shared/brand/macos/AppIcon.icns" "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$REPO_ROOT/LICENSE" \
   "$APP_BUNDLE/Contents/Resources/"
# The runtime shared/ folders (architecture.md section 2.4); never fixtures, brand sources or tools.
SHARED_DIRS="caption-styles catalog design fonts prompts schemas"
mkdir -p "$APP_BUNDLE/Contents/Resources/shared"
for d in $SHARED_DIRS; do
  [ -d "$REPO_ROOT/shared/$d" ] || { echo "Missing shared/$d" >&2; exit 1; }
  cp -R "$REPO_ROOT/shared/$d" "$APP_BUNDLE/Contents/Resources/shared/"
done
for d in $SHARED_DIRS; do                                                        # bundle parity (prompts README test 3)
  diff -r "$REPO_ROOT/shared/$d" "$APP_BUNDLE/Contents/Resources/shared/$d" >/dev/null \
    || { echo "shared/$d copy differs from the repository" >&2; exit 1; }
done
for fw in "$BIN_DIR"/*.framework; do                                             # e.g. whisper.framework
  [ -d "$fw" ] || continue
  dest="$APP_BUNDLE/Contents/Frameworks/$(basename "$fw")"
  ditto "$fw" "$dest"
  find "$dest" -name '*.dSYM' -prune -exec rm -rf {} +                           # never ship debug symbols
  name="$(basename "$fw" .framework)"
  bin="$dest/Versions/A/$name"
  [ -f "$bin" ] || bin="$dest/$name"
  if [ "$(lipo -archs "$bin")" != "arm64" ]; then lipo -thin arm64 "$bin" -output "$bin"; fi   # v1 is arm64 only
done
for b in "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$CLI"; do
  "$OTOOL" -l "$b" | grep -q '@executable_path/../Frameworks' \
    || install_name_tool -add_rpath @executable_path/../Frameworks "$b"
done
rmdir "$APP_BUNDLE/Contents/Frameworks" 2>/dev/null || true                      # only if empty

# ---------- sign: nested code first, then the CLI, then the main binary, then the bundle ----------
if [ "$RELEASE" = true ]; then
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
  for fw in "$APP_BUNDLE/Contents/Frameworks"/*.framework; do [ -d "$fw" ] && "${SIGN[@]}" "$fw"; done
  "${SIGN[@]}" "$APP_BUNDLE/Contents/MacOS/$CLI"                                   # no entitlements: never uses camera/mic
  "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
  "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
  codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"
  # The signed entitlements must equal VoxClip.entitlements exactly (plutil xml1 output has sorted keys).
  codesign -d --entitlements - --xml "$APP_BUNDLE" > "$DIST/ent-signed.plist" 2>/dev/null
  plutil -convert xml1 "$DIST/ent-signed.plist"
  plutil -convert xml1 -o "$DIST/ent-expected.plist" "$ENTITLEMENTS"
  cmp -s "$DIST/ent-signed.plist" "$DIST/ent-expected.plist" \
    || { echo "Signed entitlements differ from $ENTITLEMENTS" >&2; exit 1; }
  rm -f "$DIST/ent-signed.plist" "$DIST/ent-expected.plist"
else
  codesign --force --deep --sign - "$APP_BUNDLE"
  codesign --verify --verbose "$APP_BUNDLE"
fi
echo "Built $APP_BUNDLE"
if [ "$SIGN_ONLY" = true ]; then echo "Developer ID signed local build: open \"$APP_BUNDLE\""; exit 0; fi
if [ "$RELEASE" != true ]; then echo "Run: open \"$APP_BUNDLE\"   Release: ./bundle.sh --release --no-upload"; exit 0; fi

# ---------- notarize (status read from JSON, log printed on failure) ----------
notarize() {
  local file="$1" json status id
  json=$(mktemp)
  xcrun notarytool submit "$file" --keychain-profile "$NOTARIZE_PROFILE" --wait --output-format json > "$json" || true
  status=$(/usr/bin/plutil -extract status raw -o - "$json" 2>/dev/null || echo "")
  id=$(/usr/bin/plutil -extract id raw -o - "$json" 2>/dev/null || echo "")
  if [ "$status" != "Accepted" ]; then
    echo "Notarization of $file: ${status:-no status}" >&2; cat "$json" >&2
    # HTTP 403 "A required agreement is missing or has expired": the Account Holder must accept it at developer.apple.com.
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARIZE_PROFILE" >&2 || true
    exit 1
  fi
  echo "Notarized $file ($id)"
}

rm -f "$ZIP" "$DMG" "$SUMS"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
rm -f "$ZIP"; ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"     # the zip now carries the ticket
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

command -v create-dmg >/dev/null || { echo "create-dmg missing: brew install create-dmg" >&2; exit 1; }
create-dmg --volname "$DISPLAY_NAME" --background "dmg-background.png" \
  --window-pos 200 120 --window-size 600 400 --icon-size 100 \
  --icon "$DISPLAY_NAME.app" 150 190 --hide-extension "$DISPLAY_NAME.app" --app-drop-link 450 190 \
  "$DMG" "$APP_BUNDLE" || {
    echo "create-dmg failed, falling back to hdiutil"
    rm -f "$DMG"; hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG"; }
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
notarize "$DMG"                                                                    # the DMG is notarized separately
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > "$(basename "$SUMS")")
echo "Release artifacts (signed, notarized, stapled): $DMG, $ZIP, $SUMS"
if [ "$NO_UPLOAD" = true ]; then echo "Not uploaded. Publish with: ./bundle.sh --upload-only"; exit 0; fi
upload
```

What the template guarantees, step by step:

1. **SDK pin check.** Reads the SDK version from `SDKSettings`, passes `-platform_version macos <min> <sdk>` to the linker, and verifies `LC_BUILD_VERSION sdk` on both executables with a real `otool` (since Xcode 27, `/usr/bin/otool` goes through `xcrun`). A wrong stamp makes macOS draw pre-Liquid-Glass controls.
2. **Licence gate.** Fails if espeak-ng, x264, x265 or ffmpeg symbols are linked.
3. **Resources.** Copies exactly the runtime `shared/` folders (`caption-styles catalog design fonts prompts schemas`) and checks them byte for byte against the repository; copies the root `THIRD_PARTY_NOTICES.md`, `LICENSE` and the icon from `shared/brand`; strips dSYMs and thins every embedded framework to arm64.
4. **Nested-first signing with `--timestamp`.** Frameworks (whisper.cpp), then `voxclip-cli` (no entitlements), then the main executable with entitlements, then the bundle. Same Team ID everywhere, so library validation passes without `disable-library-validation`. Hardened runtime on every Mach-O; no other runtime exceptions.
5. **Entitlement check.** The signed bundle must carry exactly camera + audio-input.
6. **Notarize the zip**, parse `status` from `--output-format json`, require `Accepted`, otherwise print `notarytool log`. **Staple** the app and re-zip so the zip carries the ticket. `spctl --assess --type execute`.
7. **DMG** with `create-dmg` (fallback `hdiutil`), **sign the DMG** with `--timestamp`, **notarize the DMG separately**, staple, validate, `spctl --assess --type open --context context:primary-signature`.
8. **sha256** sums in `SHA256SUMS-macOS.txt`.
9. **Upload** to a **draft** GitHub Release `v<version>` (created with notes from `CHANGELOG.md` if missing; refuses to touch a published release).

`dist/` is ignored by git (`*.app`, `*.dmg`, `*.zip` patterns in `.gitignore`; add `apps/macos/dist/` when scaffolding).

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

Env vars: `VOXCLIP_WIN_HOST` (required, `user@host`), `VOXCLIP_SIGNING_ENV` (required), `VOXCLIP_WIN_BUILD_DIR` (default `C:\voxclip-build`), `VOXCLIP_VM_SIGNTOOL` (default `C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe`), `VOXCLIP_VM_DLIB` (default `C:\trusted-signing-client\bin\x64\Azure.CodeSigning.Dlib.dll`). Flags: `--no-upload`, `--upload-only`.

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

# 1. Ship a clean archive of the TAG (not the working tree) and replace the VM source tree entirely.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git archive --format=tar --prefix=src/ -o "$TMP/src.tar" "$TAG" apps/windows shared LICENSE THIRD_PARTY_NOTICES.md CHANGELOG.md
ssh "$HOST" "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '$BUILD_DIR' | Out-Null\""
scp -q "$TMP/src.tar" "$HOST:${BUILD_DIR//\\//}/src.tar"
ssh "$HOST" "powershell -NoProfile -Command \"Remove-Item -Recurse -Force '$BUILD_DIR\\src','$BUILD_DIR\\out' -ErrorAction SilentlyContinue; tar -xf '$BUILD_DIR\\src.tar' -C '$BUILD_DIR'; if (\$LASTEXITCODE) { exit 1 }\""

# 2. Build, sign, pack, verify on the VM. Credentials go over stdin only.
grep -E "^($NAMES)=" "$SIGNING_ENV" | tr -d '\r' | ssh "$HOST" \
  "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$BUILD_DIR\\src\\apps\\windows\\build\\vm-release.ps1\" -Version $VERSION -BuildDir \"$BUILD_DIR\" -SignTool \"$SIGNTOOL\" -Dlib \"$DLIB\""

# 3. Copy the upload set back (individual files, no zip: Windows zips drop directory execute bits).
rm -rf "$DIST"; mkdir -p "$DIST"
scp -q "$HOST:${BUILD_DIR//\\//}/out/upload/*" "$DIST/"
(cd "$DIST" && shasum -a 256 -c SHA256SUMS-windows.txt)

# 4. LGPL corresponding source for the shipped FFmpeg DLLs (architecture.md section 6.1), built on the Mac
#    from the sha256-pinned sourceAssets in ffmpeg.json, then added to the checksum file.
SRC="$TMP/ffmpeg-source"; mkdir -p "$SRC"
python3 - "$SRC" <<'PY'
import hashlib, json, sys, urllib.request, pathlib
out = pathlib.Path(sys.argv[1]); pin = json.load(open("apps/windows/build/ffmpeg.json"))
for a in pin["sourceAssets"]:
    data = urllib.request.urlopen(a["url"], timeout=600).read()
    if hashlib.sha256(data).hexdigest() != a["sha256"]: sys.exit(f"sha256 mismatch: {a['name']}")
    (out / a["name"]).write_bytes(data)
(out / "BUILD.txt").write_text("FFmpeg %s, BtbN FFmpeg-Builds %s\nconfigure: %s\nlicense: %s\n"
    % (pin["sourceCommit"], pin["btbnCommit"], pin["configure"], pin["license"]), encoding="ascii")
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
   3. **FFmpeg and notices:** read `build\ffmpeg.json`; download the `<rid>` zip into `$BuildDir\cache\` if absent; `Get-FileHash -Algorithm SHA256` must equal the pinned hash (otherwise delete and fail); extract; copy the DLLs listed in `dlls` from its `bin\` into the app folder; copy its `LICENSE.txt` to `licenses\FFmpeg-LICENSE.txt` (plus the LGPLv3 and GPLv3 texts when `ffmpeg.json` `license` says version 3); write `licenses\FFmpeg-BUILD.txt` with `sourceCommit`, `btbnCommit` and `configure`; copy the repository `LICENSE` and `THIRD_PARTY_NOTICES.md` into `out\<rid>\app\`.
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

1. Pick the version `X.Y.Z` (semver; pre-releases are `X.Y.Z-beta.N` and are created with `gh release create --prerelease`, never "latest").
2. Run `tools/release/set-version.sh X.Y.Z`. It sets `CFBundleShortVersionString` to `X.Y.Z`, increments `CFBundleVersion` by 1 in `apps/macos/Sources/VoxClip/Info.plist`, and sets `<Version>` in `apps/windows/Directory.Build.props`. `tools/release/check-version.sh` (also run in CI) fails if the two disagree.
3. Add a `## X.Y.Z - YYYY-MM-DD` section at the top of `CHANGELOG.md` (user-facing changes, one line each).
3a. **Subscription connector gate** (ADR-R20). If ai.md section 14 item 8 has no recorded written answer from Anthropic, set `enabled: false` for `claude-code` in `shared/catalog/llm-providers.json` for this release; likewise `codex` without a written answer from OpenAI. The switch is bundled data, so this is the only point where it protects users.
3b. **Notices.** Every component added since the last release has its section in `THIRD_PARTY_NOTICES.md` with the exact licence text from the pinned package (not a placeholder).
4. Commit `Release X.Y.Z`, create the annotated tag `git tag -a vX.Y.Z -m "VoxClip X.Y.Z"`, push the commit and the tag. CI must be green on that commit.
5. macOS: `cd apps/macos && ./bundle.sh --release` (creates the draft release `vX.Y.Z` and uploads `VoxClip-macOS.dmg`, `VoxClip-macOS.zip`, `SHA256SUMS-macOS.txt`).
6. Windows: start the VM, then `VOXCLIP_WIN_HOST=… VOXCLIP_SIGNING_ENV=… apps/windows/build/release-windows.sh` (uploads both Setup.exe files, the feeds, the packages and `SHA256SUMS-windows.txt` to the same draft).
7. Smoke-test from the draft: `gh release download vX.Y.Z --pattern 'VoxClip-*' -D /tmp/vc-rc`; on a second macOS account open the DMG (quarantined download) and launch; on a clean Windows VM snapshot run both installers; check that an installed previous version updates (Windows) and that "Check for Updates…" sees the new version once published (macOS).
8. Publish: `gh release edit vX.Y.Z --draft=false --latest`.
9. Check the download page redirects: `curl -sI https://voxconvo.com/download/macos | grep -i location` (and `windows`, `windows-arm64`) point at `releases/latest/download/<asset>`, and those URLs return 302 to the new files.

---

## 5. Known gotchas

| Symptom | Cause and fix |
|---|---|
| `notarytool submit` → `HTTP status code: 403. A required agreement is missing or has expired.` | Not a credential problem. Apple revised the Program License Agreement. The Account Holder must accept it at developer.apple.com → Agreements, Tax, and Banking. It cannot be scripted. `set -e` stops the script before stapling or uploading, so published assets are untouched; re-run after accepting |
| Notary profile "missing" | The `superscribe-notarize-2` profile lives in the login keychain and is lost with it (the original `superscribe-notarize` died on 22 Sep 2026). Test with `xcrun notarytool history --keychain-profile superscribe-notarize-2`. Re-create interactively with `xcrun notarytool store-credentials superscribe-notarize-2 --apple-id <the Apple ID from the maintainer's private notes> --team-id 5ZJ9N8WURW`; it prompts for an app-specific password, so the password never reaches shell history. Never write the Apple ID or password into this repo |
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
