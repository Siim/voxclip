#!/bin/bash
set +x
set -Eeo pipefail
trap 'exit 1' ERR
cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
EXECUTABLE="VoxClip"
CLI="voxclip-cli"
BUNDLE_ID="com.voxconvo.voxclip"
INFO_PLIST="Sources/VoxClip/Info.plist"
ASSET_CATALOG="Resources/Assets.xcassets"
ENTITLEMENTS="VoxClip.entitlements"
DIST="$PWD/dist"
APP_BUNDLE="$DIST/VoxClip.app"
DMG="$DIST/VoxClip-macOS.dmg"
ZIP="$DIST/VoxClip-macOS.zip"
SUMS="$DIST/SHA256SUMS-macOS.txt"
METADATA="$DIST/release-metadata.plist"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Haugas Development OU (5ZJ9N8WURW)}"
TEAM_ID="${TEAM_ID:-5ZJ9N8WURW}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-superscribe-notarize-2}"
GITHUB_REPO="${GITHUB_REPO:-Siim/voxclip}"
MODE=debug
NO_UPLOAD=false
ALLOW_DIRTY=false
DRY_RUN=false
SHARED_DIRS=(caption-styles catalog design fonts prompts schemas)

source "$PWD/scripts/release-common.sh"

usage() {
    cat <<'HELP'
Usage: ./bundle.sh [MODE] [OPTIONS]
  (no mode)        Debug build, ad-hoc signed dist/VoxClip.app.
  --sign-only     Release build, Developer ID signed; no notarization.
  --release, -r   Build, sign, notarize, staple, package, then upload.
  --upload-only   Upload verified artifacts; create the draft if missing.
  --no-upload     With --release: stop after local artifacts are verified.
  --allow-dirty   With --release --no-upload: untagged/dirty test build only.
  --dry-run       With --upload-only: validate and print, but never upload.
  --universal     Reserved; rejected (v1 ships arm64 only).
  --help, -h      Show this help.
HELP
}

select_mode() {
    [ "$MODE" = debug ] || usage_error "Choose only one build/upload mode."
    MODE="$1"
}

for argument in "$@"; do
    case "$argument" in
        --release|-r) select_mode release ;;
        --sign-only) select_mode sign-only ;;
        --upload-only) select_mode upload-only ;;
        --no-upload) NO_UPLOAD=true ;;
        --allow-dirty) ALLOW_DIRTY=true ;;
        --dry-run) DRY_RUN=true ;;
        --universal) usage_error "--universal is reserved; VoxClip v1 ships arm64 only." ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; usage_error "Unknown option: $argument" ;;
    esac
done

[ "$NO_UPLOAD" = false ] || [ "$MODE" = release ] || usage_error "--no-upload requires --release."
[ "$DRY_RUN" = false ] || [ "$MODE" = upload-only ] || usage_error "--dry-run requires --upload-only."
if [ "$ALLOW_DIRTY" = true ]; then
    [ "$MODE" = release ] && [ "$NO_UPLOAD" = true ] \
        || usage_error "--allow-dirty requires --release --no-upload; test artifacts can never be uploaded."
fi

mkdir -p .build
LOCK="$PWD/.build/bundle.lock"
/usr/bin/shlock -f "$LOCK" -p $$ || die "Another bundle.sh is running in this checkout."
WORK_DIR=""
trap 'rm -rf "$WORK_DIR"; rm -f "$LOCK"' EXIT
WORK_DIR=$(mktemp -d "$PWD/.build/voxclip-release.XXXXXX")

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")
PLIST_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] || die "Invalid app version; expected X.Y.Z or X.Y.Z-beta.N."
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "CFBundleVersion must be a positive integer."
[ "$PLIST_ID" = "$BUNDLE_ID" ] || die "Info.plist bundle ID differs from $BUNDLE_ID."
TAG="v$VERSION"

upload() {
    local artifact saved_commit saved_version saved_build test_build
    for artifact in "$APP_BUNDLE/Contents/Info.plist" "$DMG" "$ZIP" "$SUMS" "$METADATA"; do
        [ -f "$artifact" ] || die "Missing $artifact; build with --release --no-upload first."
    done
    test_build=$(/usr/libexec/PlistBuddy -c 'Print :TestBuild' "$METADATA")
    [ "$test_build" = false ] || die "Test-build artifacts cannot be uploaded, even in a later invocation."
    saved_commit=$(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "$METADATA")
    saved_version=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$METADATA")
    saved_build=$(/usr/libexec/PlistBuddy -c 'Print :BuildNumber' "$METADATA")
    [ "$saved_commit" = "$(git -C "$REPO_ROOT" rev-parse HEAD)" ] \
        && [ "$saved_version" = "$VERSION" ] && [ "$saved_build" = "$BUILD_NUMBER" ] \
        || die "Artifacts were built from a different commit or version."
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")" = "$VERSION" ] \
        || die "Bundled version differs from the release version."
    (cd "$DIST" && shasum -a 256 -c "$(basename "$SUMS")")
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    codesign --verify --strict --verbose=2 "$DMG"
    xcrun stapler validate "$APP_BUNDLE"
    xcrun stapler validate "$DMG"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    prepare_draft
    if [ "$DRY_RUN" = true ]; then
        printf 'Dry run; would execute:'
        printf ' %q' gh release upload "$TAG" "$DMG" "$ZIP" "$SUMS" --repo "$GITHUB_REPO" --clobber
        printf '\n'
        return
    fi
    gh release upload "$TAG" "$DMG" "$ZIP" "$SUMS" --repo "$GITHUB_REPO" --clobber
    printf 'Attached artifacts to draft %s; publication remains manual.\n' "$TAG"
}

if [ "$MODE" = upload-only ]; then
    check_release_tree
    upload
    exit 0
fi
if [ "$MODE" = release ]; then
    release_preflight
fi
[ "$(uname -m)" = arm64 ] || die "Build on Apple silicon; v1 ships arm64 only."
if [ "$MODE" != debug ]; then
    identities=$(security find-identity -v -p codesigning)
    printf '%s\n' "$identities" | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null \
        || die "Developer ID identity is missing; use the default ad-hoc build instead."
    [[ "$SIGNING_IDENTITY" == *"($TEAM_ID)" ]] || die "Signing identity and TEAM_ID disagree."
fi

SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SDK_VERSION=$(/usr/bin/plutil -extract Version raw -o - "$SDK_PATH/SDKSettings.json" 2>/dev/null \
    || /usr/bin/plutil -extract Version raw -o - "$SDK_PATH/SDKSettings.plist")
MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")
PACKAGE_MIN=$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' Package.swift)
[ "$PACKAGE_MIN" = "$MIN_MACOS" ] || die "Package.swift and Info.plist minimum macOS versions differ."
[[ "$SDK_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Cannot read the SDK version."
[ "${SDK_VERSION%%.*}" -ge "${MIN_MACOS%%.*}" ] || die "SDK is older than the minimum macOS."
BUILD_FLAGS=(--sdk "$SDK_PATH" -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION")
CONFIG=release
[ "$MODE" != debug ] || CONFIG=debug
printf 'Building VoxClip %s (%s), %s, arm64, macOS %s+, SDK %s\n' "$VERSION" "$BUILD_NUMBER" "$CONFIG" "$MIN_MACOS" "$SDK_VERSION"
swift build --jobs 2 -c "$CONFIG" "${BUILD_FLAGS[@]}"
BIN_DIR=$(swift build --jobs 2 -c "$CONFIG" "${BUILD_FLAGS[@]}" --show-bin-path)
OTOOL=$(xcrun --find otool)
NM=$(xcrun --find nm)
mkdir -p "$DIST"

for binary in "$BIN_DIR/$EXECUTABLE" "$BIN_DIR/$CLI"; do
    verify_sdk "$binary"
done

rm -rf "$APP_BUNDLE"
rm -f "$METADATA" "$SUMS"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/shared" "$APP_BUNDLE/Contents/Frameworks"
cp "$BIN_DIR/$EXECUTABLE" "$BIN_DIR/$CLI" "$APP_BUNDLE/Contents/MacOS/"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
cp "$REPO_ROOT/shared/brand/macos/AppIcon.icns" "$REPO_ROOT/THIRD_PARTY_NOTICES.md" \
    "$REPO_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/"
copy_shared_resources
compile_asset_catalog

for framework in "$BIN_DIR"/*.framework; do
    [ -d "$framework" ] || continue
    ditto "$framework" "$APP_BUNDLE/Contents/Frameworks/$(basename "$framework")"
done
for library in "$BIN_DIR"/*.dylib; do
    [ -f "$library" ] || continue
    cp "$library" "$APP_BUNDLE/Contents/Frameworks/"
done
[ "$MODE" != release ] || framework_notice_gate
find "$APP_BUNDLE/Contents/Frameworks" -name '*.dSYM' -prune -exec rm -rf {} +
while IFS= read -r -d '' binary; do
    is_macho "$binary" || continue
    architectures=$(lipo -archs "$binary")
    if [ "$architectures" != arm64 ]; then
        lipo "$binary" -thin arm64 -output "$WORK_DIR/thinned"
        cat "$WORK_DIR/thinned" > "$binary"
    fi
done < <(find "$APP_BUNDLE/Contents/Frameworks" -type f -print0)
for binary in "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$CLI"; do
    load_commands=$("$OTOOL" -l "$binary")
    if ! printf '%s\n' "$load_commands" | grep -F '@executable_path/../Frameworks' >/dev/null; then
        install_name_tool -add_rpath '@executable_path/../Frameworks' "$binary"
    fi
done
while IFS= read -r -d '' binary; do
    is_macho "$binary" || continue
    [ "$(lipo -archs "$binary")" = arm64 ] || die "Non-arm64 code in the app: $binary"
    license_gate "$binary"
done < <(find "$APP_BUNDLE/Contents" -type f -print0)

[ "$MODE" != release ] || verify_build_commit
SIGN=(codesign --force --sign -)
if [ "$MODE" != debug ]; then
    SIGN=(codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
fi
while IFS= read -r -d '' binary; do
    is_macho "$binary" || continue
    "${SIGN[@]}" "$binary"
done < <(find "$APP_BUNDLE/Contents/Frameworks" -depth -type f -print0)
while IFS= read -r -d '' framework; do
    "${SIGN[@]}" "$framework"
done < <(find "$APP_BUNDLE/Contents/Frameworks" -depth -type d -name '*.framework' -print0)
rmdir "$APP_BUNDLE/Contents/Frameworks" 2>/dev/null || true
"${SIGN[@]}" --identifier "$BUNDLE_ID.cli" "$APP_BUNDLE/Contents/MacOS/$CLI"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
verify_cli_identity
codesign -d --entitlements - --xml "$APP_BUNDLE" > "$WORK_DIR/signed-entitlements.plist" 2>/dev/null
plutil -convert xml1 "$WORK_DIR/signed-entitlements.plist"
plutil -convert xml1 -o "$WORK_DIR/expected-entitlements.plist" "$ENTITLEMENTS"
cmp -s "$WORK_DIR/signed-entitlements.plist" "$WORK_DIR/expected-entitlements.plist" \
    || die "Signed entitlements differ from $ENTITLEMENTS."
if [ "$MODE" != debug ]; then
    while IFS= read -r -d '' binary; do
        is_macho "$binary" || continue
        signature=$(codesign -d --verbose=4 "$binary" 2>&1)
        printf '%s\n' "$signature" | grep -Fx "TeamIdentifier=$TEAM_ID" >/dev/null \
            || die "Signed code has the wrong Team ID: $binary"
        printf '%s\n' "$signature" | grep -E 'flags=.*\(runtime\)' >/dev/null \
            || die "Hardened runtime is missing: $binary"
        printf '%s\n' "$signature" | grep '^Timestamp=' >/dev/null \
            || die "Secure timestamp is missing: $binary"
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)
fi
printf 'Built %s\n' "$APP_BUNDLE"
if [ "$MODE" != release ]; then
    printf 'Run: open "%s"\n' "$APP_BUNDLE"
    exit 0
fi

mkdir -p "$DIST/notarization"
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"
notarize "$ZIP" app
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
create_disk_image
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
notarize "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > "$(basename "$SUMS")")
verify_build_commit
plutil -create xml1 "$METADATA"
plutil -insert Version -string "$VERSION" "$METADATA"
plutil -insert BuildNumber -string "$BUILD_NUMBER" "$METADATA"
plutil -insert GitCommit -string "$BUILD_COMMIT" "$METADATA"
plutil -insert TestBuild -bool "$ALLOW_DIRTY" "$METADATA"
cat "$SUMS"
printf 'Release artifacts: %s, %s, %s\n' "$DMG" "$ZIP" "$SUMS"
if [ "$NO_UPLOAD" = true ]; then
    printf '%s\n' 'No GitHub upload performed.'
    exit 0
fi
upload
