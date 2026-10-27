#!/bin/sh
set -eu
cd "$(dirname "$0")/../../../.."
remote=${VOXCLIP_VM_HOST:?Set VOXCLIP_VM_HOST to the Windows SSH target}
native_zip=${VOXCLIP_FFMPEG_ZIP:-}
if [ -n "$native_zip" ]; then test -s "$native_zip"; fi
shipping_rid=${VOXCLIP_SHIPPING_RID:-}
scratch=${VOXCLIP_VM_SCRATCH:-win-media}
case "$scratch" in ''|-*|*[!a-z0-9-]*) echo 'VOXCLIP_VM_SCRATCH must be one lowercase track directory name' >&2; exit 2 ;; esac
if [ -n "$shipping_rid" ]; then
  case "$shipping_rid" in win-arm64|win-x64) ;; *) echo 'VOXCLIP_SHIPPING_RID must be win-arm64 or win-x64' >&2; exit 2 ;; esac
  test -n "$native_zip" || { echo 'VOXCLIP_FFMPEG_ZIP is required for shipping acceptance' >&2; exit 2; }
  build_report="$(dirname "$native_zip")/report.json"
  python3 - "$shipping_rid" "$native_zip" "$build_report" <<'PY'
import hashlib, json, pathlib, sys, zipfile
rid, archive_path, report_path = sys.argv[1:]
manifest = json.loads(pathlib.Path('apps/windows/build/ffmpeg.json').read_text())
report = json.loads(pathlib.Path(report_path).read_text())
archive = pathlib.Path(archive_path)
build = manifest['builds'][rid]
assert archive.name == build['name'] == report['archive']
assert report['rid'] == rid
assert report['buildInputsSha256'] == manifest['buildInputsSha256']
assert archive.stat().st_size == build['size'] == report['size']
digest = hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest()
assert digest == build['sha256'] == report['sha256']
with zipfile.ZipFile(archive) as z:
    actual = {i.filename: i for i in z.infolist()}
    expected = {'bin/' + name for name in report['dlls']}
    assert set(actual) == expected
    for name, data in report['dlls'].items():
        entry = actual['bin/' + name]
        assert entry.file_size == data['size']
        assert hashlib.sha256(z.read(entry)).hexdigest() == data['sha256']
print(f'{rid} shipping ZIP, input digest and six DLLs match manifest/report: {digest}')
PY
fi
command -v timeout >/dev/null
owner="$scratch-$(date +%s)-$$"
root="C:\\voxclip-build\\$scratch"
workspace="$root\\source-$owner"
runs=apps/windows/tests/VoxClip.Media.Tests/.runs
mkdir -p "$runs"
archive="$runs/workspace-$owner.tar"
fixtures="$runs/fixtures-$owner.tar"
acquired=false
remote_ps() {
  encoded=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\r\n')
  timeout -k 5 "${2:-30}" ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$remote" "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
}
cleanup() {
  rm -f "$archive" "$fixtures"
  if [ "$acquired" = true ]; then
    mkdir -p "$runs/$owner"
    timeout -k 5 30 scp -o BatchMode=yes -o ConnectTimeout=5 "$remote:C:/voxclip-build/$scratch/source-$owner/apps/windows/tests/VoxClip.Media.Tests/.runs/*.log" "$runs/$owner/" || true
    mkdir -p "$runs/$owner/e2e"
    timeout -k 5 30 scp -o BatchMode=yes -o ConnectTimeout=5 "$remote:C:/voxclip-build/$scratch/source-$owner/apps/windows/tests/VoxClip.Media.Tests/.runs/e2e/*.json" "$runs/$owner/e2e/" || true
    if [ -n "$shipping_rid" ]; then
      timeout -k 5 30 scp -o BatchMode=yes -o ConnectTimeout=5 "$remote:C:/voxclip-build/$scratch/source-$owner/apps/windows/tests/VoxClip.Media.Tests/.runs/loaded-modules.json" "$runs/$owner/" || true
      timeout -k 5 30 scp -o BatchMode=yes -o ConnectTimeout=5 "$remote:C:/voxclip-build/$scratch/source-$owner/apps/windows/tests/VoxClip.Media.Tests/.runs/loaded-cli-modules.json" "$runs/$owner/" || true
      timeout -k 5 30 scp -o BatchMode=yes -o ConnectTimeout=5 "$remote:C:/voxclip-build/$scratch/source-$owner/apps/windows/tests/VoxClip.Media.Tests/.runs/e2e/*.csv" "$runs/$owner/e2e/" || true
    fi
  fi
  remote_ps "\$marker='C:\voxclip-build\vm.lock\owner'; if ((Test-Path \$marker) -and (Get-Content \$marker) -eq '$owner') { try { \$pidFile='$workspace\apps\windows\tests\VoxClip.Media.Tests\.runs\runner.pid'; if (Test-Path \$pidFile) { taskkill.exe /PID ([int](Get-Content \$pidFile)) /T /F 2>\$null }; Remove-Item -Recurse -Force '$workspace' -ErrorAction Stop } finally { if ((Get-Content \$marker) -eq '$owner') { Remove-Item -Recurse 'C:\voxclip-build\vm.lock' } } }" 30 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
deadline=$(($(date +%s) + 1800))
while :; do
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || { echo 'VM lock wait reached 30 minutes; the owner was not disturbed.' >&2; exit 1; }
  command_timeout=20
  if [ "$remaining" -lt "$command_timeout" ]; then command_timeout=$remaining; fi
  status=0
  remote_ps "try { New-Item -ItemType Directory 'C:\voxclip-build\vm.lock' -ErrorAction Stop | Out-Null } catch { \$lock=Get-Item 'C:\voxclip-build\vm.lock'; \$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime; if (\$lock.PSIsContainer) { Get-Content 'C:\voxclip-build\vm.lock\owner' -ErrorAction SilentlyContinue } else { Get-Content 'C:\voxclip-build\vm.lock' -ErrorAction SilentlyContinue }; Write-Output ('Lock created: ' + \$lock.CreationTime + '; boot: ' + \$boot); if (\$lock.CreationTime -lt \$boot) { Write-Output 'Lock may be stale; report to the lead. It was not removed.'; exit 23 }; if (\$lock.PSIsContainer -and -not (Test-Path 'C:\voxclip-build\vm.lock\owner') -and ((Get-Date) - \$lock.CreationTime).TotalSeconds -gt 90) { Write-Output 'Lock owner marker is missing; report to the lead. It was not removed.'; exit 24 }; exit 22 }; Set-Content 'C:\voxclip-build\vm.lock\owner' '$owner'" "$command_timeout" || status=$?
  if [ "$status" -eq 0 ]; then acquired=true; break; fi
  if [ "$status" -ne 22 ]; then exit "$status"; fi
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || { echo 'VM lock wait reached 30 minutes; the owner was not disturbed.' >&2; exit 1; }
  if [ "$remaining" -gt 30 ]; then sleep 30; else sleep "$remaining"; fi
done
remote_ps "New-Item -ItemType Directory '$workspace' -ErrorAction Stop | Out-Null" 20
git archive --format=tar HEAD apps/windows shared THIRD_PARTY_NOTICES.md > "$archive"
test -s apps/windows/tests/VoxClip.Media.Tests/Fixtures/generated/hevc10-two-audio.mp4 || {
  echo 'Run: sh apps/windows/tests/VoxClip.Media.Tests/generate-fixtures.sh' >&2; exit 1;
}
COPYFILE_DISABLE=1 tar -cf "$fixtures" apps/windows/tests/VoxClip.Media.Tests/Fixtures/generated
timeout 90 scp -o BatchMode=yes -o ConnectTimeout=5 "$archive" "$remote:C:/voxclip-build/$scratch/source-$owner/workspace.tar"
timeout 90 scp -o BatchMode=yes -o ConnectTimeout=5 "$fixtures" "$remote:C:/voxclip-build/$scratch/source-$owner/fixtures.tar"
timeout 45 ssh "$remote" "cd /d $workspace && tar -xf workspace.tar && tar -xf fixtures.tar && del workspace.tar fixtures.tar"
if [ -n "$native_zip" ]; then
  timeout 90 scp -o BatchMode=yes -o ConnectTimeout=5 "$native_zip" "$remote:C:/voxclip-build/$scratch/source-$owner/ffmpeg.zip"
  if [ -n "$shipping_rid" ]; then
    timeout 30 scp -o BatchMode=yes -o ConnectTimeout=5 "$build_report" "$remote:C:/voxclip-build/$scratch/source-$owner/report.json"
    set -- -ShippingAcceptance -ShippingRid "$shipping_rid" -BuildReport "$workspace\report.json" "$@"
  else
    remote_ps "Expand-Archive -LiteralPath '$workspace\ffmpeg.zip' -DestinationPath '$workspace\native' -ErrorAction Stop; Remove-Item '$workspace\ffmpeg.zip'" 45
  fi
  set -- -FfmpegDirectory "$workspace\native\bin" "$@"
fi
require_evidence=
if [ -n "$shipping_rid" ]; then require_evidence="\$env:VOXCLIP_REQUIRE_VM_EVIDENCE='1'; "; fi
# The VM has an audio output device, so every run requires the real WASAPI preview test; hosted CI never sets this.
remote_ps "\$env:VOXCLIP_REQUIRE_AUDIO_OUTPUT='1'; $require_evidence& '$workspace\apps\windows\tests\VoxClip.Media.Tests\verify-windows.ps1' -LockOwner '$owner' -ScratchRoot '$root' $*" 1800
