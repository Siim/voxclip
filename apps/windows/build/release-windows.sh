#!/bin/bash
set +x
set -euo pipefail
unset GREP_OPTIONS GREP_COLOR GREP_COLORS

BUILD_SCRIPTS="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$BUILD_SCRIPTS/../../.." && pwd -P)"
HOST="${VOXCLIP_WIN_HOST:-}"
SIGNING_ENV="${VOXCLIP_SIGNING_ENV:-}"
unset VOXCLIP_SIGNING_ENV
BUILD_DIR="${VOXCLIP_WIN_BUILD_DIR:-C:\voxclip-build}"
VM_ROOT="$BUILD_DIR\win-release"
LOCK="$BUILD_DIR\vm.lock"
TIMEOUT="${VOXCLIP_TIMEOUT:-/opt/homebrew/bin/timeout}"
BUILD_TIMEOUT="${VOXCLIP_BUILD_TIMEOUT:-5400}"
UPLOAD=true; UPLOAD_REQUESTED=false; UPLOAD_ONLY=false; DRY_RUN=false; ALLOW_DIRTY=false; SKELETON_TEST=false
EXISTING_OUTPUT=''
RESUME_RUN=''

usage() {
    cat <<'USAGE'
Usage: apps/windows/build/release-windows.sh [options]
  --allow-dirty          Test the current tree; upload is forbidden.
  --skeleton-test        Non-uploadable installer test using pinned local FFmpeg;
                         uses shared/brand/windows/app.ico if needed.
  --resume-skeleton ID   Reuse the published payload of a failed skeleton run.
  --upload              Explicitly request the default draft upload.
  --no-upload           Build/sign/pack/verify only.
  --upload-only [DIR]   Reuse the last production build (or DIR); no rebuild.
  --dry-run             Print the plan/gh commands; no SSH, signing or upload.
  --help                Show this help.
VOXCLIP_WIN_HOST and VOXCLIP_SIGNING_ENV are required for VM builds.
Release builds require clean, tagged HEAD; uploads create a missing draft only.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --upload) UPLOAD=true; UPLOAD_REQUESTED=true ;;
        --no-upload) UPLOAD=false ;;
        --upload-only)
            UPLOAD_ONLY=true; UPLOAD=true; UPLOAD_REQUESTED=true
            EXISTING_OUTPUT="$BUILD_SCRIPTS/.release/latest"
            if [ "$#" -gt 1 ] && [[ "$2" != --* ]]; then EXISTING_OUTPUT="$2"; shift; fi ;;
        --dry-run) DRY_RUN=true ;;
        --allow-dirty) ALLOW_DIRTY=true ;;
        --skeleton-test) SKELETON_TEST=true; ALLOW_DIRTY=true ;;
        --resume-skeleton) [ "$#" -gt 1 ] || { usage >&2; exit 2; }; RESUME_RUN="$2"; SKELETON_TEST=true; ALLOW_DIRTY=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
[ "$ALLOW_DIRTY:$UPLOAD_REQUESTED" != true:true ] || { echo '--allow-dirty builds can never be uploaded.' >&2; exit 2; }
if [ "$ALLOW_DIRTY" = true ]; then UPLOAD=false; fi
for command in python3 git tar shasum ssh scp iconv base64 od tr "$TIMEOUT"; do
    command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 1; }
done
VERSION="$(python3 -I "$BUILD_SCRIPTS/release-assets.py" version "$REPO_ROOT")"
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
TAG="v$VERSION"
GITHUB_REPO="${VOXCLIP_GITHUB_REPO:-${GITHUB_REPO:-Siim/voxclip}}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
if [ -n "$RESUME_RUN" ]; then
    [[ "$RESUME_RUN" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || { echo 'Invalid skeleton run ID.' >&2; exit 2; }
    RUN_ID="$RESUME_RUN"
fi
LOCK_OWNER="$RUN_ID.$$.$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
OUTPUT="$BUILD_SCRIPTS/.release/$RUN_ID"
printf -v VM_RUN '%s\\runs\\%s' "$VM_ROOT" "$RUN_ID"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
LOCKED=false; LOCK_ATTEMPTED=false; ACQUIRE_UNCERTAIN=false; RELEASE_FAILED=false; HEARTBEAT_PID=''; TEMPORARY=''
RELEASE_PID=$$
# shellcheck source=apps/windows/build/release-driver-common.sh
source "$BUILD_SCRIPTS/release-driver-common.sh"
LOCK_SCRIPT="$(<"$BUILD_SCRIPTS/Release-Lock.ps1")"

print_upload_plan() {
    local asset
    printf 'Would find or create draft: gh release view %q --repo %q --json isDraft --jq .isDraft\n' "$TAG" "$GITHUB_REPO"
    printf 'Would upload only: VoxClip-win-{x64,arm64}-Setup.exe, releases.win-{x64,arm64}.json,\n'
    printf '  VoxClip-%s-win-{x64,arm64}-full.nupkg (and feed-listed deltas),\n' "$VERSION"
    printf '  VoxClip-win-ffmpeg-source.tar.xz, SHA256SUMS-windows.txt\n'
    for asset in VoxClip-win-x64-Setup.exe VoxClip-win-arm64-Setup.exe releases.win-x64.json releases.win-arm64.json \
        "VoxClip-$VERSION-win-x64-full.nupkg" "VoxClip-$VERSION-win-arm64-full.nupkg" \
        VoxClip-win-ffmpeg-source.tar.xz SHA256SUMS-windows.txt; do
        printf 'Would run: gh release upload %q %q --repo %q --clobber\n' "$TAG" "$asset" "$GITHUB_REPO"
    done
    echo 'Never uploads assets.*.json, RELEASES-*, portable ZIPs or evidence.'
}

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: VoxClip $VERSION, commit $COMMIT; no network or signing side effects."
    if [ "$UPLOAD_ONLY" = false ]; then
        echo "Would lock $LOCK, stage source + shared/, and build win-x64 + win-arm64 at $VM_RUN."
        echo 'Would filter allowed signing names on the Mac and stream SSH stdin; never a VM credential file or secret argv.'
        echo 'Would stage pinned local self-built FFmpeg ZIPs/source, publish both apps, sign every unverified PE, pack, verify and install/uninstall.'
        echo 'Would verify corresponding source, copy assets/evidence back, and write SHA256SUMS-windows.txt.'
        [ -f "$REPO_ROOT/apps/windows/src/VoxClip.App/Assets/VoxClip.ico" ] || echo 'Preflight finding: VoxClip.ico is missing (win-ui).'
        python3 -I - "$REPO_ROOT/apps/windows/build/ffmpeg.json" <<'PY'
import json, sys
pin = json.load(open(sys.argv[1]))
if pin.get('schema') != 'voxclip-ffmpeg/2' or 'btbnCommit' in pin:
    print('Preflight finding: shipping FFmpeg requires voxclip-ffmpeg/2 (win-media/lead).')
for field in ('schema', 'buildInputsSha256', 'recipeCommit', 'builds', 'configure', 'license', 'sourceAssets', 'buildTools'):
    if not pin.get(field):
        print('Preflight finding: ffmpeg.json missing ' + field + ' (win-media/lead).')
PY
    fi
    if [ "$UPLOAD" = true ]; then print_upload_plan; fi
    exit 0
fi

if [ "$ALLOW_DIRTY" = false ]; then
    [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || { echo 'Working tree is dirty. Use --allow-dirty for a non-uploadable test.' >&2; exit 1; }
    [ "$(git -C "$REPO_ROOT" rev-parse "$TAG^{commit}" 2>/dev/null)" = "$COMMIT" ] || { echo "HEAD must be tagged $TAG." >&2; exit 1; }
    python3 -I - "$REPO_ROOT" "$VERSION" <<'PY'
from pathlib import Path
import plistlib, sys
root = Path(sys.argv[1])
with (root / 'apps/macos/Sources/VoxClip/Info.plist').open('rb') as source:
    if plistlib.load(source)['CFBundleShortVersionString'] != sys.argv[2]:
        raise SystemExit('macOS and Windows versions differ')
PY
fi

upload() {
    local directory="$1" asset attempt uploaded
    command -v gh >/dev/null || { echo 'Install/authenticate gh before uploading.' >&2; return 1; }
    run_step verify_release_sums "$directory"
    run_step "$TIMEOUT" 30 python3 -I "$BUILD_SCRIPTS/release-assets.py" upload-list "$directory/evidence" "$VERSION" "$COMMIT" > "$directory/evidence/upload-list.txt"
    ensure_release_draft "$directory/evidence/draft-status.txt"
    while IFS= read -r asset; do
        uploaded=false
        for attempt in 1 2 3; do
            ensure_release_draft "$directory/evidence/draft-status.txt" || return 1
            if run_step "$TIMEOUT" --kill-after=15 600 gh release upload "$TAG" "$directory/upload/$asset" --repo "$GITHUB_REPO" --clobber; then uploaded=true; break; fi
            echo "Upload failed for $asset (attempt $attempt/3); built assets remain on disk." >&2
            [ "$attempt" -eq 3 ] || run_step "$TIMEOUT" 10 sleep 5
        done
        [ "$uploaded" = true ] || return 1
    done < "$directory/evidence/upload-list.txt"
    echo "Attached verified Windows assets to draft $TAG. A human must publish it."
}

if [ "$UPLOAD_ONLY" = true ]; then
    EXISTING_OUTPUT="$(cd "$EXISTING_OUTPUT" && pwd -P)"
    run_step verify_release_sums "$EXISTING_OUTPUT"
    verify_release_signatures "$EXISTING_OUTPUT"
    upload "$EXISTING_OUTPUT"
    exit 0
fi
if [ "$SKELETON_TEST" = false ]; then
    python3 -I "$BUILD_SCRIPTS/release-assets.py" check-pin "$REPO_ROOT/apps/windows/build/ffmpeg.json"
    [ -f "$REPO_ROOT/apps/windows/src/VoxClip.App/Assets/VoxClip.ico" ] || { echo 'Missing release VoxClip.ico (win-ui); refusing release packaging.' >&2; exit 1; }
fi
[ -r "$SIGNING_ENV" ] || { echo 'Signing env file is missing/unreadable; refusing an unsigned build.' >&2; exit 1; }
[ -n "$HOST" ] || { echo 'Set VOXCLIP_WIN_HOST=user@vm.' >&2; exit 1; }
SIGNING_REAL="$(python3 -I - "$SIGNING_ENV" "$REPO_ROOT" <<'PY'
import os, sys
from pathlib import Path
try:
    repository = os.stat(sys.argv[2])
    signing = Path(os.path.realpath(sys.argv[1]))
    if os.stat(signing).st_nlink > 1:
        raise SystemExit('Signing env file must not be hard-linked.')
    for ancestor in (signing, *signing.parents):
        identity = os.stat(ancestor)
        if (identity.st_dev, identity.st_ino) == (repository.st_dev, repository.st_ino):
            raise SystemExit('Signing env file must remain outside the repository.')
except OSError:
    raise SystemExit('Signing env file path could not be verified.')
print(signing)
PY
)"
stream_signing_credentials --validate
release_vm() {
    stop_heartbeat
    retry_remote_ps "\$ErrorActionPreference='Stop'; if (Test-Path $(ps_literal "$VM_RUN\process.json")) { \$record=Get-Content $(ps_literal "$VM_RUN\process.json") -Raw | ConvertFrom-Json; \$process=Get-Process -Id \$record.id -ErrorAction SilentlyContinue; if (\$process -and \$process.StartTime.ToUniversalTime().ToString('o') -eq \$record.started) { & taskkill.exe /PID \$record.id /T /F | Out-Null; if (\$LASTEXITCODE -ne 0) { throw 'Remote taskkill failed' } } }; if (Test-Path $(ps_literal "$VM_RUN\out\evidence")) { \$markers=@(Get-ChildItem -LiteralPath $(ps_literal "$VM_RUN\out\evidence") -Recurse -File -Filter 'install-root.json'); if (\$markers.Count) { . $(ps_literal "$VM_RUN\Release-Common.ps1"); Remove-ReleasePendingInstalls -RunDirectory $(ps_literal "$VM_RUN") } }; if (Test-Path $(ps_literal "$VM_RUN\private")) { Remove-Item -LiteralPath $(ps_literal "$VM_RUN\private") -Recurse -Force }" 600 || { RELEASE_FAILED=true; echo "CRITICAL: VM process/install/metadata cleanup failed; retaining $LOCK for run $RUN_ID (owner $LOCK_OWNER) for human inspection." >&2; return 1; }
    retry_remote_ps "$(lock_command Release)" 30 Release || { RELEASE_FAILED=true; echo "CRITICAL: VM lock release refused or unavailable; retaining $LOCK for run $RUN_ID (owner $LOCK_OWNER) for human inspection." >&2; return 1; }
    LOCKED=false
    LOCK_ATTEMPTED=false
    ACQUIRE_UNCERTAIN=false
}
cleanup() {
    local status=$? release_result=0
    trap - EXIT
    trap '' INT TERM HUP
    set +e
    stop_heartbeat
    stop_step
    if [ "$LOCKED" = true ] && [ "$status" -ne 0 ]; then
        mkdir -p "$OUTPUT/evidence"
        run_step "$TIMEOUT" --kill-after=15 60 scp "${SSH_OPTIONS[@]}" -q -r "$HOST:${VM_RUN//\\//}/out/evidence/." "$OUTPUT/evidence/" ||
            echo 'WARNING: Bounded failure-evidence copy did not complete; inspect this run on the VM.' >&2
    fi
    if [ "$RELEASE_FAILED" = true ]; then
        :
    elif [ "$LOCKED" = true ]; then
        release_vm || status=1
    elif [ "$LOCK_ATTEMPTED" = true ] || [ "$ACQUIRE_UNCERTAIN" = true ]; then
        retry_remote_ps "$(lock_command Release)" 30 Release || release_result=$?
        case "$release_result" in
            0|74) ;;
            *) echo "WARNING: Ambiguous acquisition cleanup unavailable; inspect $LOCK for run $RUN_ID (owner $LOCK_OWNER)." >&2 ;;
        esac
    fi
    if [ -n "$TEMPORARY" ]; then chmod -R u+rwX "$TEMPORARY"; rm -rf "$TEMPORARY"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$OUTPUT"
TEMPORARY="$(mktemp -d "$OUTPUT/staging.XXXXXX")"
if [ -z "$RESUME_RUN" ]; then
    run_step "$TIMEOUT" --kill-after=15 3600 python3 -I "$BUILD_SCRIPTS/release-assets.py" stage \
        "$REPO_ROOT/apps/windows/build/ffmpeg.json" "$REPO_ROOT" \
        "${VOXCLIP_FFMPEG_CACHE:-$HOME/Library/Caches/voxclip-ffmpeg-build}" "$OUTPUT/ffmpeg" "$COMMIT"
fi
STAGED_PATHS=(apps/windows shared LICENSE THIRD_PARTY_NOTICES.md)
if [ -f "$REPO_ROOT/CHANGELOG.md" ]; then STAGED_PATHS+=(CHANGELOG.md); fi
if [ -z "$RESUME_RUN" ]; then
if [ "$ALLOW_DIRTY" = true ]; then
    run_step "$TIMEOUT" --kill-after=15 600 /bin/bash -o pipefail -s -- "$BUILD_SCRIPTS/release-driver-common.sh" "$REPO_ROOT" "$TEMPORARY/source.tar.gz" "${STAGED_PATHS[@]}" <<'BASH'
source "$1"; shift
repository="$1"; archive="$2"; shift 2
git -C "$repository" ls-files -z --cached --others --exclude-standard -- "$@" |
    python3 -I -c '
import fnmatch, os, sys
paths = sys.stdin.buffer.read().split(b"\0")
patterns = ("*.env", ".env*", "azure-signing*", "*.pfx", "*.p12", "*.cer", "*.key", "*.pem")
for path in filter(None, paths):
    components = os.fsdecode(path).lower().split("/")
    if "signing" in components[:-1] or any(fnmatch.fnmatchcase(component, pattern)
            for component in components for pattern in patterns):
        raise SystemExit("Refusing secret-named staging path: " + os.fsdecode(path))
sys.stdout.buffer.write(b"".join(path + b"\0" for path in filter(None, paths)
    if os.path.lexists(os.path.join(os.fsencode(sys.argv[1]), path))))
' "$repository" > "$archive.paths" || exit "$?"
archive_release_paths "$repository" "$archive" "$archive.paths"
BASH
else
    run_step "$TIMEOUT" --kill-after=15 600 git -C "$REPO_ROOT" archive --format=tar.gz -o "$TEMPORARY/source.tar.gz" "$TAG" "${STAGED_PATHS[@]}"
fi
python3 -I - "$TEMPORARY/config.json" "$VERSION" "$COMMIT" "$ALLOW_DIRTY" "$SKELETON_TEST" <<'PY'
import json, os, sys
configuration = dict(
    Version=sys.argv[2], Commit=sys.argv[3], AllowDirty=sys.argv[4] == 'true', SkeletonTest=sys.argv[5] == 'true',
    BuildRoot=os.getenv('VOXCLIP_WIN_BUILD_DIR', r'C:\voxclip-build') + r'\win-release',
    Dotnet=os.getenv('VOXCLIP_VM_DOTNET', r'C:\Program Files\dotnet\dotnet.exe'),
    SignTool=os.getenv('VOXCLIP_VM_SIGNTOOL', ''),
    Dlib=os.getenv('VOXCLIP_VM_DLIB', r'C:\trusted-signing-client\bin\x64\Azure.CodeSigning.Dlib.dll'),
    SigningDotnetRoot=os.getenv('VOXCLIP_VM_SIGNING_DOTNET_ROOT', ''))
with open(sys.argv[1], 'w') as destination:
    json.dump(configuration, destination, ensure_ascii=True)
PY
fi
lock_deadline=$((SECONDS + 2100))
echo "VM lock $LOCK: run $RUN_ID; invocation owner $LOCK_OWNER."
while [ "$SECONDS" -lt "$lock_deadline" ]; do
    result=0
    LOCK_ATTEMPTED=true
    run_step remote_ps "$(lock_command Acquire)" 30 </dev/null || result=$?
    if [ "$result" -eq 0 ]; then LOCKED=true; break; fi
    case "$result" in
        73) LOCK_ATTEMPTED=false ;;
        124|255) ACQUIRE_UNCERTAIN=true ;;
        *) echo "VM lock acquisition failed for run $RUN_ID (owner $LOCK_OWNER) at $LOCK; no takeover attempted." >&2; exit 1 ;;
    esac
    if [ "$ACQUIRE_UNCERTAIN" = true ]; then
        ownership=0
        run_step remote_ps "$(lock_command Check)" 30 </dev/null || ownership=$?
        if [ "$ownership" -eq 0 ]; then LOCKED=true; break; fi
        echo "VM lock acquisition unavailable for run $RUN_ID (owner $LOCK_OWNER) at $LOCK; retrying within lock deadline." >&2
    fi
    remaining=$((lock_deadline - SECONDS))
    [ "$remaining" -gt 0 ] || break
    delay=60; if [ "$remaining" -lt 60 ]; then delay=$remaining; fi
    echo "VM is busy; waiting ${delay}s (35-minute budget)."
    run_step "$TIMEOUT" --kill-after=2 "$((delay + 2))" sleep "$delay"
done
[ "$LOCKED" = true ] || { run_step remote_ps "$(lock_command Describe)" 30 </dev/null || true; echo "Timed out waiting for $LOCK for run $RUN_ID (owner $LOCK_OWNER); a human must resolve it." >&2; exit 1; }
heartbeat_loop &
HEARTBEAT_PID=$!
run_step remote_ps "$(lock_command Check); New-Item -ItemType Directory -Force -Path $(ps_literal "$VM_RUN\private") | Out-Null; foreach (\$previous in @(Get-ChildItem $(ps_literal "$VM_ROOT\runs") -Directory)) { if (\$previous.Name -ne '$RUN_ID') { Write-Host ('Removing older release run: ' + \$previous.Name); Remove-Item -LiteralPath \$previous.FullName -Recurse -Force } }; if ((Get-PSDrive -Name ([IO.Path]::GetPathRoot($(ps_literal "$VM_ROOT")).TrimEnd('\').TrimEnd(':'))).Free -lt 10GB) { throw 'Need at least 10 GiB free after deleting older release runs.' }" 300 </dev/null
VM_SCP="${VM_RUN//\\//}"
if [ -z "$RESUME_RUN" ]; then
    run_step "$TIMEOUT" --kill-after=15 600 scp "${SSH_OPTIONS[@]}" -q "$TEMPORARY/source.tar.gz" "$TEMPORARY/config.json" "$HOST:$VM_SCP/"
    run_step remote_ps "New-Item -ItemType Directory -Force -Path $(ps_literal "$VM_RUN\ffmpeg") | Out-Null" 30 </dev/null
    run_step "$TIMEOUT" --kill-after=15 600 scp "${SSH_OPTIONS[@]}" -q \
        "$OUTPUT/ffmpeg/"*.zip "$OUTPUT/ffmpeg/"*.txt "$OUTPUT/ffmpeg/"*.md \
        "$OUTPUT/ffmpeg/"*-audit.json \
        "$OUTPUT/ffmpeg/stage.json" "$HOST:$VM_SCP/ffmpeg/"
else
    run_step remote_ps "\$ErrorActionPreference='Stop'; \$config=Get-Content $(ps_literal "$VM_RUN\config.json") -Raw | ConvertFrom-Json; if (-not \$config.SkeletonTest -or -not \$config.AllowDirty -or \$config.Version -ne '$VERSION') { throw 'Only a matching non-uploadable skeleton run can resume' }; Write-Host ('Reusing published source commit: ' + \$config.Commit)" </dev/null
fi
run_step "$TIMEOUT" --kill-after=15 120 scp "${SSH_OPTIONS[@]}" -q "$BUILD_SCRIPTS/Release-Common.ps1" "$BUILD_SCRIPTS/vm-release.ps1" "$BUILD_SCRIPTS/Sign-Artifacts.ps1" "$BUILD_SCRIPTS/Pack-Velopack.ps1" "$BUILD_SCRIPTS/Test-Install.ps1" "$BUILD_SCRIPTS/Ffmpeg-LicenceGate.cs" "$HOST:$VM_SCP/"
if [ -z "$RESUME_RUN" ]; then
    echo "Building both architectures on $HOST; local evidence: $OUTPUT"
else
    echo "Resuming skeleton signing/packaging/verification on $HOST; local evidence: $OUTPUT"
fi
RESUME_FLAG=''
if [ -n "$RESUME_RUN" ]; then RESUME_FLAG='-ResumeSkeletonTest'; fi
run_step remote_ps "\$ErrorActionPreference='Stop'; & $(ps_literal "$VM_RUN\vm-release.ps1") -Config $(ps_literal "$VM_RUN\config.json") $RESUME_FLAG" "$BUILD_TIMEOUT" < <(stream_signing_credentials) > >(tee -a "$OUTPUT/vm-release.log") 2>&1
mkdir -p "$OUTPUT/upload" "$OUTPUT/evidence"
run_step "$TIMEOUT" --kill-after=15 1200 scp "${SSH_OPTIONS[@]}" -q "$HOST:$VM_SCP/out/upload/*" "$OUTPUT/upload/"
run_step "$TIMEOUT" --kill-after=15 300 scp "${SSH_OPTIONS[@]}" -q -r "$HOST:$VM_SCP/out/evidence/." "$OUTPUT/evidence/"
chmod -R u+rwX "$OUTPUT"
(cd "$OUTPUT/upload" && shasum -a 256 -c SHA256SUMS-windows.txt)
release_vm || echo 'VM lock retained; continuing hash-verified Mac-only release steps.' >&2
if [ "$SKELETON_TEST" = true ]; then
    echo 'SKELETON TEST ONLY: no corresponding-source asset is attached; these artifacts MUST NOT be released.'
else
    run_step "$TIMEOUT" --kill-after=15 3600 python3 -I "$BUILD_SCRIPTS/release-assets.py" source "$OUTPUT/ffmpeg" "$OUTPUT/upload/VoxClip-win-ffmpeg-source.tar.xz"
    python3 -I "$BUILD_SCRIPTS/release-assets.py" manifest "$OUTPUT/upload" "$OUTPUT/evidence" "$VERSION" "$COMMIT"
fi
(cd "$OUTPUT/upload" && shasum -a 256 -c SHA256SUMS-windows.txt)
verify_release_signatures "$OUTPUT"
if [ "$ALLOW_DIRTY" = false ]; then ln -sfn "$RUN_ID" "$BUILD_SCRIPTS/.release/latest"; fi
echo "Verified release artifacts: $OUTPUT/upload"
if [ "$UPLOAD" = true ]; then
    upload "$OUTPUT"
elif [ "$SKELETON_TEST" = true ]; then
    echo 'No upload. Skeleton artifacts are permanently non-uploadable; do not use --upload-only.'
else
    echo "No upload. Reuse with: $0 --upload-only $OUTPUT"
fi
if [ "$RELEASE_FAILED" = true ]; then
    echo "Release steps finished; VM lock $LOCK for run $RUN_ID (owner $LOCK_OWNER) is retained for a human." >&2
    exit 75
fi
