#!/bin/bash
set -euo pipefail
host_idle_seconds() {
    /usr/sbin/ioreg -c IOHIDSystem | awk '/"HIDIdleTime"/ { print int($NF / 1000000000); found = 1; exit } END { if (!found) exit 1 }'
}
idle_clock() { date +%s; }
idle_pause() { sleep 30; }
record_input_gate() {
    printf '{"step":"%s","architecture":"%s","configuration":"%s","idleBefore":%s,"idleAfter":%s,"result":"%s","evidence":"%s"}\n' \
        "$1" "$3" "$2" "$4" "$5" "$6" "${INPUT_EVIDENCE:-not-started}" >> "$STAGING/idle-gate.jsonl"
}
run_input_step() {
    local step=$1 configuration=$2 architecture=$3
    shift 3
    local deadline=$(( $(idle_clock) + 1800 )) before after started elapsed result
    while [ "$(idle_clock)" -lt "$deadline" ]; do
        if ! before=$(host_idle_seconds); then
            record_input_gate "$step" "$configuration" "$architecture" null null owed-idle-unavailable
            return 75
        fi
        if [ "$before" -lt 300 ]; then idle_pause; continue; fi
        started=$(idle_clock)
        result=0
        "$@" || result=$?
        elapsed=$(( $(idle_clock) - started ))
        if ! after=$(host_idle_seconds); then
            record_input_gate "$step" "$configuration" "$architecture" "$before" null void-idle-unavailable
            return 75
        fi
        if [ "$result" = 86 ]; then
            record_input_gate "$step" "$configuration" "$architecture" "$before" "$after" failed-theme-restore
            return 86
        fi
        if [ "$after" -lt "$before" ] || [ "$after" -lt $(( before + elapsed - 2 )) ]; then
            record_input_gate "$step" "$configuration" "$architecture" "$before" "$after" void-user-input
            echo "Voided $step: Mac HID idle dropped; rerunning only after 300 s idle."
            continue
        fi
        if [ "$result" = 0 ]; then
            record_input_gate "$step" "$configuration" "$architecture" "$before" "$after" passed
        else
            record_input_gate "$step" "$configuration" "$architecture" "$before" "$after" failed
        fi
        return "$result"
    done
    record_input_gate "$step" "$configuration" "$architecture" null null owed-idle-timeout
    echo "Input step $step is owed: no uncontested idle window within 30 minutes. Releasing the lease."
    return 75
}
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return; fi
TIMEOUT=/opt/homebrew/bin/timeout
REMOTE=siim@192.168.64.3
ROOT=$(cd "$(dirname "$0")/../../../../../.." && pwd)
CONFIGURATION=${1:-Debug}
RID=${2:-win-arm64}
STAGING=${VOXCLIP_UI_STAGING:-/tmp/voxclip-win-ui-r2}
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
        "$TIMEOUT" 25 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" "powershell.exe -NoProfile -NonInteractive -Command \"\$ErrorActionPreference = 'Stop'; if ((Get-Content -LiteralPath 'C:\\voxclip-build\\vm.lock\\owner' -Raw).Trim() -ne '$LOCK_OWNER') { throw 'Lock ownership changed' }; Remove-Item -LiteralPath 'C:\\voxclip-build\\vm.lock\\owner'; Remove-Item -LiteralPath 'C:\\voxclip-build\\vm.lock'\"" || result=1
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
native_voice_lab_step() {
    local step=$1 configuration=$2 rid=$3
    INPUT_EVIDENCE="voice-lab-evidence/$configuration-$rid-$step-$(uuidgen)"
    "$TIMEOUT" 540 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\voxclip-build\\win-ui\\apps\\windows\\tests\\VoxClip.Core.Tests\\Tracks\\win-ui\\native-accessibility-walk.ps1 -Root C:\\voxclip-build\\win-ui -DataRoot C:\\voxclip-build\\win-ui\\capture-data -EvidenceDir C:\\voxclip-build\\win-ui\\$INPUT_EVIDENCE -RuntimeIdentifier $rid -Configuration $configuration -VoiceLabStep $step -Schedule"
}
clear_voice_lab_build() {
    "$TIMEOUT" 90 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" 'powershell.exe -NoProfile -NonInteractive -Command "Remove-Item -LiteralPath '\''C:\voxclip-build\win-ui\apps\windows\src\VoxClip.App\bin'\'', '\''C:\voxclip-build\win-ui\apps\windows\src\VoxClip.App\obj'\'' -Recurse -Force -ErrorAction SilentlyContinue"'
}
if [ "${3:-}" = voice-lab ]; then
    owed=0
    for configuration_rid in Debug:win-arm64 Release:win-arm64 Release:win-x64; do
        configuration=${configuration_rid%%:*}
        rid=${configuration_rid#*:}
        clear_voice_lab_build
        build "$configuration" "$rid"
        if [ "$configuration" = Debug ]; then
            steps="pane cancel turn-on cap label light dark night-sky"
        elif [ "$rid" = win-arm64 ]; then
            steps="release-off release-on"
        else
            steps="release-smoke"
        fi
        for step in $steps; do
            status=0
            run_input_step "$step" "$configuration" "$rid" native_voice_lab_step "$step" "$configuration" "$rid" || status=$?
            if [ "$status" = 75 ]; then owed=75; break 2; fi
            if [ "$status" = 86 ]; then owed=86; break 2; fi
            if [ "$status" != 0 ]; then owed=1; fi
        done
    done
    "$TIMEOUT" 120 scp -r -o ConnectTimeout=8 "$REMOTE:C:/voxclip-build/win-ui/voice-lab-evidence" "$STAGING/" || owed=1
    exit "$owed"
fi
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
    run_input_step screenshots "$CONFIGURATION" "$RID" "$TIMEOUT" 510 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\voxclip-build\\win-ui\\apps\\windows\\tests\\VoxClip.Core.Tests\\Tracks\\win-ui\\run-screenshots.ps1 $SHOT_ARGUMENTS" || SHOTS_STATUS=$?
    "$TIMEOUT" 25 ssh -o ConnectTimeout=8 -o BatchMode=yes "$REMOTE" 'powershell.exe -NoProfile -Command "if (Test-Path '\''C:\voxclip-build\win-ui\capture-data\Logs\voxclip.log'\'') { Copy-Item '\''C:\voxclip-build\win-ui\capture-data\Logs\voxclip.log'\'' '\''C:\voxclip-build\win-ui\screenshots\startup.log'\'' -Force }"' || true
    "$TIMEOUT" 90 scp -o ConnectTimeout=8 "$REMOTE:C:/voxclip-build/win-ui/screenshots/*-window.jpg" "$REMOTE:C:/voxclip-build/win-ui/screenshots/*.json" "$REMOTE:C:/voxclip-build/win-ui/screenshots/startup.log" "$STAGING/" || SHOTS_STATUS=1
    if [ "$SHOTS_STATUS" != 0 ]; then "$TIMEOUT" 25 scp -o ConnectTimeout=8 "$REMOTE:C:/voxclip-build/win-ui/screenshots/error.txt" "$STAGING/" || true; fi
    exit "$SHOTS_STATUS"
fi
