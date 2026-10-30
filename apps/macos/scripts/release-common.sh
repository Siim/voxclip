#!/bin/bash

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage_error() {
    printf 'Error: %s\n' "$*" >&2
    exit 2
}

verify_build_commit() {
    [ "$ALLOW_DIRTY" = false ] || return 0
    local changes current_commit
    changes=$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- . ':(exclude)apps/macos/dist') \
        || die "Cannot check the release working tree."
    [ -z "$changes" ] || die "Working tree is dirty. For a local test use --release --no-upload --allow-dirty."
    current_commit=$(git -C "$REPO_ROOT" rev-parse HEAD) || die "Cannot read release HEAD."
    [ "$current_commit" = "$BUILD_COMMIT" ] || die "HEAD changed since the build started; refusing to sign or record release metadata."
}

check_release_tree() {
    check_ignored_resources
    BUILD_COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD) || die "Cannot read release HEAD."
    if [ "$ALLOW_DIRTY" = true ]; then
        printf '%s\n' 'TEST BUILD: bypassing clean-tree/tag checks; uploads are permanently disabled for these artifacts.'
        return
    fi
    verify_build_commit
    [ "$(git -C "$REPO_ROOT" cat-file -t "$TAG" 2>/dev/null || true)" = tag ] \
        || die "Release requires the annotated tag $TAG."
    [ "$BUILD_COMMIT" = "$(git -C "$REPO_ROOT" rev-parse "$TAG^{commit}")" ] \
        || die "HEAD is not tagged $TAG."
    [ -x "$REPO_ROOT/tools/release/check-version.sh" ] || die "Missing tools/release/check-version.sh."
    "$REPO_ROOT/tools/release/check-version.sh"
}

release_preflight() {
    check_release_tree
    [ "$NO_UPLOAD" = true ] || upload_preflight
    command -v create-dmg >/dev/null || die "create-dmg missing: brew install create-dmg"
    check_unlocked_screen
}

locked_screen_error() {
    die "The Mac screen is locked (doc/release.md §5); unlock it and re-run. Do not re-create the notary profile."
}

check_unlocked_screen() {
    ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - > "$WORK_DIR/console-users.plist" \
        || die "Cannot check the Mac screen lock state."
    grep -A1 CGSSessionScreenIsLocked "$WORK_DIR/console-users.plist" > "$WORK_DIR/screen-lock-state" \
        || [ "$?" -eq 1 ] || die "Cannot inspect the Mac screen lock state."
    if grep -E '<true[[:space:]]*/>' "$WORK_DIR/screen-lock-state" >/dev/null; then
        locked_screen_error
    fi
}

check_ignored_resources() {
    local directory ignored found=false paths=()
    for directory in "${SHARED_DIRS[@]}"; do
        paths+=("shared/$directory")
    done
    git -C "$REPO_ROOT" ls-files -z --others --ignored --exclude-standard -- "${paths[@]}" > "$WORK_DIR/ignored.files" \
        || die "Cannot list ignored files in shipped shared directories."
    while IFS= read -r -d '' ignored; do
        case "$ignored" in
            .DS_Store|*/.DS_Store) continue ;;
        esac
        printf '%s\n' "$ignored" >&2
        found=true
    done < "$WORK_DIR/ignored.files"
    if [ "$found" = true ]; then
        die "Ignored files exist in shipped shared directories; remove them before releasing."
    fi
}

copy_shared_resources() {
    local directory manifest changes
    for directory in "${SHARED_DIRS[@]}"; do
        [ -d "$REPO_ROOT/shared/$directory" ] || die "Missing shared/$directory."
        manifest="$WORK_DIR/shared-$directory.files"
        git -C "$REPO_ROOT" ls-files -z -- "shared/$directory" ':(exclude,glob)shared/**/fixtures/**' > "$manifest"
        [ -s "$manifest" ] || die "No tracked files in shared/$directory."
        rsync -a --from0 --files-from="$manifest" "$REPO_ROOT/" "$APP_BUNDLE/Contents/Resources/"
        changes=$(rsync -rcn --from0 --files-from="$manifest" --out-format='%n' \
            "$REPO_ROOT/" "$APP_BUNDLE/Contents/Resources/")
        [ -z "$changes" ] || die "Bundled shared/$directory differs from its tracked source files."
    done
}

compile_asset_catalog() {
    local accent partial="$WORK_DIR/asset-catalog-info.plist" log="$WORK_DIR/actool.log"
    accent=$(/usr/libexec/PlistBuddy -c 'Print :NSAccentColorName' "$INFO_PLIST" 2>/dev/null) \
        || die "Info.plist has no NSAccentColorName."
    # actool only warns about a missing accent colour, so require it in the partial plist.
    if ! xcrun actool "$ASSET_CATALOG" --compile "$APP_BUNDLE/Contents/Resources" --platform macosx \
        --minimum-deployment-target "$MIN_MACOS" --accent-color "$accent" --output-partial-info-plist "$partial" \
        --output-format human-readable-text --errors --warnings > "$log" 2>&1; then
        cat "$log" >&2
        die "actool could not compile $ASSET_CATALOG."
    fi
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :NSAccentColorName' "$partial" 2>/dev/null)" != "$accent" ]; then
        cat "$log" >&2
        die "$ASSET_CATALOG has no $accent colour."
    fi
}

framework_notice_gate() {
    local component notice kind
    linked_ort_notice_gate
    while IFS= read -r -d '' component; do
        kind=framework
        [[ "$component" != *.dylib ]] || kind=library
        case "$(basename "$component")" in
            whisper.framework|libwhisper.dylib) notice='Copyright (c) 2023-2026 The ggml authors' ;;
            onnxruntime.framework) die "Static ONNX Runtime framework must not be embedded." ;;
            *) die "No known licence notice for $kind: $(basename "$component")." ;;
        esac
        grep -F "$notice" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md" >/dev/null \
            || die "Missing $kind licence notice for $(basename "$component") in bundled THIRD_PARTY_NOTICES.md."
    done < <(find "$APP_BUNDLE/Contents/Frameworks" \( -type d -name '*.framework' -o -name '*.dylib' \) -print0)
}

linked_ort_notice_gate() {
    local binary notices symbols
    notices="$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
    for binary in "$APP_BUNDLE"/Contents/MacOS/*; do
        [ -f "$binary" ] || continue
        symbols=$(nm -g "$binary") || die "Cannot inspect linked runtime symbols: $binary"
        if printf '%s\n' "$symbols" | grep -E '[[:space:]]_OrtGetApiBase$' >/dev/null; then
            grep -Fx '#### ONNX Runtime SwiftPM 1.19.2' "$notices" >/dev/null \
                && grep -F '28787ee2f966a2c47eb293322c733c5dc4b5e3327cec321c1fe31a7c698edf68' "$notices" >/dev/null \
                || die "Missing pinned ONNX Runtime SwiftPM 1.19.2 notice for linked runtime."
        fi
    done
}

copy_dynamic_frameworks() {
    local framework binary
    for framework in "$BIN_DIR"/*.framework; do
        [ -d "$framework" ] || continue
        binary="$framework/$(basename "$framework" .framework)"
        file -L "$binary" | grep 'current ar archive' >/dev/null && continue
        file -L "$binary" | grep 'dynamically linked shared library' >/dev/null \
            || die "Unsupported framework binary: $(basename "$framework")."
        ditto "$framework" "$APP_BUNDLE/Contents/Frameworks/$(basename "$framework")"
    done
}

reject_embedded_archives() {
    local binary
    while IFS= read -r -d '' binary; do
        if file "$binary" | grep 'current ar archive' >/dev/null; then
            die "Static archive must not be bundled: $binary"
        fi
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)
}

release_notes() {
    local notes
    [ -f "$REPO_ROOT/CHANGELOG.md" ] || die "Missing CHANGELOG.md; add a nonempty ## $VERSION release section."
    notes=$(awk -v version="$VERSION" '
        $1 == "##" && $2 == version {found=1; next}
        /^##[[:space:]]/ && found {exit}
        found {print}
    ' "$REPO_ROOT/CHANGELOG.md")
    printf '%s\n' "$notes" | grep '[^[:space:]]' >/dev/null \
        || die "CHANGELOG.md has no nonempty ## $VERSION release section."
    printf '%s\n' "$notes"
}

verify_upload_tag() {
    local local_tag remote_tag
    [ "$(git -C "$REPO_ROOT" cat-file -t "$TAG" 2>/dev/null || true)" = tag ] \
        || die "Release requires the annotated tag $TAG."
    [ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$(git -C "$REPO_ROOT" rev-parse "$TAG^{commit}")" ] \
        || die "HEAD is not tagged $TAG."
    local_tag=$(git -C "$REPO_ROOT" rev-parse "$TAG")
    remote_tag=$(gh api "repos/$GITHUB_REPO/git/ref/tags/$TAG" --jq .object.sha) \
        || die "Remote tag $TAG is missing or inaccessible; push the annotated tag first."
    [ "$remote_tag" = "$local_tag" ] || die "Remote tag $TAG does not match the local annotated tag object."
}

upload_preflight() {
    local release draft release_tag prerelease expected_prerelease=false
    local errors="$WORK_DIR/release-view.stderr"
    [[ "$VERSION" != *-beta.* ]] || expected_prerelease=true
    command -v gh >/dev/null || die "Install the GitHub CLI (gh)."
    gh auth status --hostname github.com --active >/dev/null 2>&1 \
        || die "GitHub CLI authentication for github.com failed; run gh auth login -h github.com."
    verify_upload_tag
    RELEASE_EXISTS=false
    if release=$(gh release view "$TAG" --repo "$GITHUB_REPO" --json isDraft,tagName,isPrerelease \
            --jq '[.isDraft,.tagName,.isPrerelease] | @tsv' 2> "$errors"); then
        IFS=$'\t' read -r draft release_tag prerelease <<< "$release"
        [ "$release_tag" = "$TAG" ] || die "Release tagName ${release_tag:-missing} differs from $TAG."
        [ "$draft" = true ] || die "$TAG is already published; refusing to replace assets."
        [ "$prerelease" = "$expected_prerelease" ] || die "Release isPrerelease disagrees with version $VERSION."
        RELEASE_EXISTS=true
    else
        if ! grep -Fi 'release not found' "$errors" >/dev/null; then
            cat "$errors" >&2
            die "Cannot query release $TAG; not creating a draft"
        fi
        release_notes > "$WORK_DIR/release-notes.md"
    fi
}

prepare_draft() {
    upload_preflight
    [ "$RELEASE_EXISTS" = false ] || return 0
    local create_args=(release create "$TAG" --repo "$GITHUB_REPO" --draft --verify-tag
        --title "VoxClip $VERSION" --notes-file "$WORK_DIR/release-notes.md")
    [[ "$VERSION" != *-beta.* ]] || create_args+=(--prerelease)
    if [ "$DRY_RUN" = true ]; then
        printf 'Dry run; would execute:'
        printf ' %q' gh "${create_args[@]}"
        printf '\n'
    else
        gh "${create_args[@]}"
        upload_preflight
        [ "$RELEASE_EXISTS" = true ] || die "Created draft $TAG could not be verified; refusing to upload."
    fi
}

verify_cli_identity() {
    local identifier cli_requirement app_requirement
    identifier=$(codesign -d --verbose=4 "$APP_BUNDLE/Contents/MacOS/$CLI" 2>&1)
    printf '%s\n' "$identifier" | grep -Fx "Identifier=$BUNDLE_ID.cli" >/dev/null \
        || die "CLI signing identifier differs from $BUNDLE_ID.cli."
    cli_requirement=$(codesign -d -r- "$APP_BUNDLE/Contents/MacOS/$CLI" 2>&1 | sed -n -E 's/^(# )?designated => //p')
    app_requirement=$(codesign -d -r- "$APP_BUNDLE" 2>&1 | sed -n -E 's/^(# )?designated => //p')
    [ -n "$cli_requirement" ] && [ -n "$app_requirement" ] && [ "$cli_requirement" != "$app_requirement" ] \
        || die "CLI and app must have distinct designated requirements."
}

is_macho() {
    case "$(file -b "$1")" in
        *Mach-O*) return 0 ;;
        *) return 1 ;;
    esac
}

verify_sdk() {
    local binary="$1" commands built_sdk built_minimum
    [ -f "$binary" ] || die "Missing executable: $binary"
    [ "$(lipo -archs "$binary")" = arm64 ] || die "Expected arm64 executable: $binary"
    commands=$("$OTOOL" -l "$binary")
    built_sdk=$(printf '%s\n' "$commands" | awk '/LC_BUILD_VERSION/ {found=1} found && $1=="sdk" {print $2; found=0}')
    built_minimum=$(printf '%s\n' "$commands" | awk '/LC_BUILD_VERSION/ {found=1} found && $1=="minos" {print $2; found=0}')
    [ "$built_sdk" = "$SDK_VERSION" ] || die "$binary SDK stamp is ${built_sdk:-missing}, expected $SDK_VERSION."
    [ "$built_minimum" = "$MIN_MACOS" ] || die "$binary minimum macOS is ${built_minimum:-missing}, expected $MIN_MACOS."
    printf 'SDK pin verified: %s (macOS %s, SDK %s)\n' "$(basename "$binary")" "$built_minimum" "$built_sdk"
}

license_gate() {
    local binary="$1" symbols="$WORK_DIR/nm.stdout" dependencies="$WORK_DIR/otool.dependencies" scan_status
    "$NM" -a "$binary" > "$symbols" 2> "$WORK_DIR/nm.stderr" || die "Cannot inspect symbols in $binary."
    "$OTOOL" -L "$binary" > "$WORK_DIR/otool.stdout" || die "Cannot inspect linked libraries in $binary."
    sed '1d' "$WORK_DIR/otool.stdout" > "$dependencies"
    if grep -E '(^|[[:space:]])_(espeak_|espeak_ng_|x264_|x265_|av_|avcodec_|avformat_|avfilter_|avutil_|avdevice_|swresample_|swscale_|swr_|sws_|postproc_|pp_)' "$symbols" >/dev/null; then
        die "Licence gate: forbidden espeak, x264, x265 or FFmpeg code in $binary."
    else
        scan_status=$?
        [ "$scan_status" -eq 1 ] || die "Cannot scan symbols in $binary."
    fi
    if grep -E '/lib(espeak(-ng)?|x264|x265|av(codec|format|filter|util|device)|sw(resample|scale)|postproc)' "$dependencies" >/dev/null; then
        die "Licence gate: forbidden espeak, x264, x265 or FFmpeg code in $binary."
    else
        scan_status=$?
        [ "$scan_status" -eq 1 ] || die "Cannot scan linked libraries in $binary."
    fi
    printf 'Licence gate passed: %s\n' "$(basename "$binary")"
}

notarize() {
    local artifact="$1" label="$2" json errors status submission_id exit_code=0
    check_unlocked_screen
    json="$DIST/notarization/$label.json"
    errors="$DIST/notarization/$label.stderr"
    printf 'Submitting %s for notarization...\n' "$(basename "$artifact")"
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARIZE_PROFILE" --wait --output-format json \
        > "$json" 2> "$errors" || exit_code=$?
    if ! status=$(/usr/bin/plutil -extract status raw -o - "$json" 2>/dev/null); then status=""; fi
    if ! submission_id=$(/usr/bin/plutil -extract id raw -o - "$json" 2>/dev/null); then submission_id=""; fi
    [[ "$submission_id" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] || submission_id=""
    if [ "$exit_code" -ne 0 ] || [ "$status" != Accepted ] || [ -z "$submission_id" ]; then
        printf 'Notarization failed: %s; status=%s; id=%s; exit=%s\n' "$artifact" "${status:-missing}" "${submission_id:-missing}" "$exit_code" >&2
        cat "$json" "$errors" >&2
        if grep -F 'No Keychain password item found for profile' "$json" "$errors" >/dev/null; then
            locked_screen_error
        fi
        if grep -Ei '403.*agreement|A required agreement is missing or has expired' "$json" "$errors" >/dev/null; then
            die "Apple developer agreement must be accepted by the Account Holder. No retry was attempted."
        fi
        if [ -n "$submission_id" ]; then
            xcrun notarytool log "$submission_id" --keychain-profile "$NOTARIZE_PROFILE" \
                > "$DIST/notarization/$label.log.json" 2>&1 || true
            cat "$DIST/notarization/$label.log.json" >&2
        fi
        die "Notarization did not succeed; no stapling or upload will follow."
    fi
    printf 'Notarization Accepted: %s (id: %s)\n' "$(basename "$artifact")" "$submission_id"
}

create_disk_image() {
    local stage="$WORK_DIR/dmg-stage"
    command -v create-dmg >/dev/null || die "create-dmg missing: brew install create-dmg"
    mkdir -p "$stage"
    ditto "$APP_BUNDLE" "$stage/VoxClip.app"
    if create-dmg --volname VoxClip --background "$PWD/dmg-background.png" \
            --window-pos 200 120 --window-size 600 400 --icon-size 100 \
            --icon VoxClip.app 150 190 --hide-extension VoxClip.app --app-drop-link 450 190 \
            "$DMG" "$stage"; then
        return
    fi
    printf '%s\n' 'create-dmg failed; using hdiutil with the same app, background and Applications link.'
    rm -f "$DMG"
    mkdir -p "$stage/.background"
    cp dmg-background.png "$stage/.background/dmg-background.png"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname VoxClip -srcfolder "$stage" -ov -format UDZO "$DMG"
}
