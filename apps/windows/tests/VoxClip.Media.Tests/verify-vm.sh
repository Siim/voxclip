#!/bin/sh
set -eu
cd "$(dirname "$0")/../../../.."
remote=${VOXCLIP_VM_HOST:?Set VOXCLIP_VM_HOST to the Windows SSH target}
native_zip=${VOXCLIP_FFMPEG_ZIP:-}
if [ -n "$native_zip" ]; then test -s "$native_zip"; fi
command -v timeout >/dev/null
owner="win-media-$(date +%s)-$$"
workspace="C:\\voxclip-build\\win-media\\source-$owner"
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
    timeout -k 5 30 scp -o BatchMode=yes -o ConnectTimeout=5 "$remote:C:/voxclip-build/win-media/source-$owner/apps/windows/tests/VoxClip.Media.Tests/.runs/*.log" "$runs/$owner/" || true
    mkdir -p "$runs/$owner/e2e"
    timeout -k 5 30 scp -o BatchMode=yes -o ConnectTimeout=5 "$remote:C:/voxclip-build/win-media/source-$owner/apps/windows/tests/VoxClip.Media.Tests/.runs/e2e/*.json" "$runs/$owner/e2e/" || true
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
  remote_ps "try { New-Item -ItemType Directory 'C:\voxclip-build\vm.lock' -ErrorAction Stop | Out-Null } catch { \$lock=Get-Item 'C:\voxclip-build\vm.lock'; \$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime; Get-Content 'C:\voxclip-build\vm.lock\owner' -ErrorAction SilentlyContinue; Write-Output ('Lock created: ' + \$lock.CreationTime + '; boot: ' + \$boot); if (\$lock.CreationTime -lt \$boot) { Write-Output 'Lock may be stale; report to the lead. It was not removed.'; exit 23 }; exit 22 }; Set-Content 'C:\voxclip-build\vm.lock\owner' '$owner'" "$command_timeout" || status=$?
  if [ "$status" -eq 0 ]; then acquired=true; break; fi
  if [ "$status" -ne 22 ]; then exit "$status"; fi
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || { echo 'VM lock wait reached 30 minutes; the owner was not disturbed.' >&2; exit 1; }
  if [ "$remaining" -gt 30 ]; then sleep 30; else sleep "$remaining"; fi
done
remote_ps "New-Item -ItemType Directory '$workspace' -ErrorAction Stop | Out-Null" 20
git archive --format=tar HEAD apps/windows shared > "$archive"
test -s apps/windows/tests/VoxClip.Media.Tests/Fixtures/generated/hevc10-two-audio.mp4 || {
  echo 'Run: sh apps/windows/tests/VoxClip.Media.Tests/generate-fixtures.sh' >&2; exit 1;
}
COPYFILE_DISABLE=1 tar -cf "$fixtures" apps/windows/tests/VoxClip.Media.Tests/Fixtures/generated
timeout 90 scp -o BatchMode=yes -o ConnectTimeout=5 "$archive" "$remote:C:/voxclip-build/win-media/source-$owner/workspace.tar"
timeout 90 scp -o BatchMode=yes -o ConnectTimeout=5 "$fixtures" "$remote:C:/voxclip-build/win-media/source-$owner/fixtures.tar"
timeout 45 ssh "$remote" "cd /d $workspace && tar -xf workspace.tar && tar -xf fixtures.tar && del workspace.tar fixtures.tar"
if [ -n "$native_zip" ]; then
  timeout 90 scp -o BatchMode=yes -o ConnectTimeout=5 "$native_zip" "$remote:C:/voxclip-build/win-media/source-$owner/ffmpeg.zip"
  remote_ps "Expand-Archive -LiteralPath '$workspace\ffmpeg.zip' -DestinationPath '$workspace\native' -ErrorAction Stop; Remove-Item '$workspace\ffmpeg.zip'" 45
  set -- -FfmpegDirectory "$workspace\native\bin" "$@"
fi
remote_ps "& '$workspace\apps\windows\tests\VoxClip.Media.Tests\verify-windows.ps1' -LockOwner '$owner' $*" 1800
