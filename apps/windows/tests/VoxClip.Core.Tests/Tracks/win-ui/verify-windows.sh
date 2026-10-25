#!/bin/bash
set -euo pipefail
TIMEOUT=/opt/homebrew/bin/timeout
REMOTE=siim@192.168.64.3
ROOT=$(cd "$(dirname "$0")/../../../../../.." && pwd)
CONFIGURATION=${1:-Debug}
RID=${2:-win-arm64}
STAGING=/tmp/voxclip-win-ui-r2
LOCKED=0
LOCK_OWNER="win-ui-$(uuidgen)"
owns_lock() {
    "$TIMEOUT" 20 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" "powershell.exe -NoProfile -NonInteractive -Command \"if (([string](Get-Content 'C:\\voxclip-build\\vm.lock\\owner' -Raw -ErrorAction SilentlyContinue)).Trim() -eq '$LOCK_OWNER') { exit 0 }; exit 1\""
}
cleanup() {
    local result=$?
    if [ "$LOCKED" = 1 ]; then
        if ! owns_lock; then
            echo "VM cleanup refused: lock ownership could not be verified ($LOCK_OWNER)." >&2
            exit 1
        fi
        "$TIMEOUT" 25 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" 'powershell.exe -NoProfile -Command "if (Test-Path '\''C:\voxclip-build\win-ui\build.pid'\'') { $buildId = Get-Content '\''C:\voxclip-build\win-ui\build.pid'\''; taskkill.exe /PID $buildId /T /F; Remove-Item '\''C:\voxclip-build\win-ui\build.pid'\'' -Force }"' >/dev/null 2>&1 || true
        "$TIMEOUT" 20 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" 'schtasks /End /TN VoxClipUiWinUi & schtasks /End /TN VoxClipShotWinUi & schtasks /Delete /TN VoxClipUiWinUi /F & schtasks /Delete /TN VoxClipShotWinUi /F' >/dev/null 2>&1 || true
        "$TIMEOUT" 25 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" 'powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like '\''C:\voxclip-build\win-ui\*'\'' -and $_.Name -eq '\''VoxClip.exe'\'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force };"' || true
        "$TIMEOUT" 25 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" "powershell.exe -NoProfile -NonInteractive -Command \"\$ErrorActionPreference = 'Stop'; \$lock = 'C:\\voxclip-build\\vm.lock'; if ((Get-Content (\$lock + '\\owner') -Raw).Trim() -ne '$LOCK_OWNER') { throw 'Lock ownership changed' }; Remove-Item (\$lock + '\\owner'); Remove-Item \$lock\"" || result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
for attempt in $(seq 1 12); do
    if "$TIMEOUT" 20 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" "powershell.exe -NoProfile -NonInteractive -Command \"\$ErrorActionPreference = 'Stop'; \$lock = 'C:\\voxclip-build\\vm.lock'; New-Item -ItemType Directory -Path \$lock | Out-Null; Set-Content -LiteralPath (\$lock + '\\owner') -Value '$LOCK_OWNER' -Encoding ascii\""; then LOCKED=1; break; fi
    if owns_lock; then LOCKED=1; break; fi
    echo "VM lock busy ($attempt/12); waiting 60 seconds."
    "$TIMEOUT" 65 sleep 60
done
if [ "$LOCKED" != 1 ]; then echo "VM lock remained busy; no VM state changed."; exit 75; fi
mkdir -p "$STAGING"
"$TIMEOUT" 20 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" 'if not exist C:\voxclip-build\win-ui mkdir C:\voxclip-build\win-ui'
git -C "$ROOT" archive HEAD | "$TIMEOUT" 120 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" 'tar -xf - -C C:\voxclip-build\win-ui'
build() {
    "$TIMEOUT" 660 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\voxclip-build\\win-ui\\apps\\windows\\tests\\VoxClip.Core.Tests\\Tracks\\win-ui\\build-windows.ps1 -Configuration $1 -Rid $2"
}
if [ "$CONFIGURATION" = All ]; then
    build Debug win-arm64
    build Release win-arm64
    build Release win-x64
else
    build "$CONFIGURATION" "$RID"
fi
if [ "${3:-}" = shots ]; then
    if [ "$RID" != win-arm64 ] && [ "$CONFIGURATION" != All ]; then echo "Interactive captures require an ARM64 build on this VM."; exit 64; fi
    SHOT_ARGUMENTS=-Exercise
    if [ "$CONFIGURATION" = Release ]; then SHOT_ARGUMENTS='-Screen home -Configuration Release'; fi
    SHOTS_STATUS=0
    "$TIMEOUT" 510 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\voxclip-build\\win-ui\\apps\\windows\\tests\\VoxClip.Core.Tests\\Tracks\\win-ui\\run-screenshots.ps1 $SHOT_ARGUMENTS" || SHOTS_STATUS=$?
    "$TIMEOUT" 25 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" 'powershell.exe -NoProfile -Command "if (Test-Path '\''C:\voxclip-build\win-ui\capture-data\Logs\voxclip.log'\'') { Copy-Item '\''C:\voxclip-build\win-ui\capture-data\Logs\voxclip.log'\'' '\''C:\voxclip-build\win-ui\screenshots\startup.log'\'' -Force }"' || true
    "$TIMEOUT" 90 scp -o ConnectTimeout=8 "$REMOTE:C:/voxclip-build/win-ui/screenshots/*-window.jpg" "$REMOTE:C:/voxclip-build/win-ui/screenshots/*.json" "$REMOTE:C:/voxclip-build/win-ui/screenshots/startup.log" "$STAGING/" || SHOTS_STATUS=1
    if [ "$SHOTS_STATUS" != 0 ]; then "$TIMEOUT" 25 scp -o ConnectTimeout=8 "$REMOTE:C:/voxclip-build/win-ui/screenshots/error.txt" "$STAGING/" || true; fi
    exit "$SHOTS_STATUS"
fi
