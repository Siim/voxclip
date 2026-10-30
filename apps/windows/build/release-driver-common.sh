#!/bin/bash

SIGNING_NAMES='AZURE_TENANT_ID|AZURE_CLIENT_ID|AZURE_CLIENT_SECRET|AZURE_SIGNING_KVT|AZURE_SIGNING_KVI|AZURE_SIGNING_KVS|AZURE_SIGNING_ENDPOINT|AZURE_SIGNING_ACCOUNT|AZURE_SIGNING_PROFILE'
STEP_PID=''

ps_literal() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

archive_release_paths() {
    COPYFILE_DISABLE=1 tar -czf "$2" --no-recursion -C "$1" \
        --exclude='*.[eE][nN][vV]' --exclude='.[eE][nN][vV]*' \
        --exclude='[aA][zZ][uU][rR][eE]-[sS][iI][gG][nN][iI][nN][gG]*' \
        --exclude='*.[pP][fF][xX]' --exclude='*.[pP]12' --exclude='*.[cC][eE][rR]' \
        --exclude='*.[kK][eE][yY]' --exclude='*.[pP][eE][mM]' \
        --exclude='[sS][iI][gG][nN][iI][nN][gG]' --null -T "$3"
}

stream_signing_credentials() {
    "$TIMEOUT" 30 python3 -I -c '
import os, re, sys
try:
    metadata_patterns = {
        "AZURE_SIGNING_ACCOUNT": r"[A-Za-z0-9][A-Za-z0-9-]{1,63}",
        "AZURE_SIGNING_PROFILE": r"[A-Za-z0-9][A-Za-z0-9-]{1,63}",
        "AZURE_SIGNING_ENDPOINT": r"https://[a-z]{2,8}[0-9]?\.codesigning\.azure\.net",
    }
    def unquote(value):
        if len(value) >= 2 and value[0] in "\x27\x22" and value[-1] == value[0]:
            return value[1:-1]
        return value
    names = sys.argv[2]
    prefix = re.compile(rb"^\s*(?:export\s+)?(" + names.encode("ascii") + rb")\b")
    word = r"(?:\x27[^\x27\r\n]*\x27|\x22[^\x22\r\n]*\x22|[^\s\x27\x22#;|&<>()`\\]+)"
    assignment = re.compile(r"\s*(?:export\s+)?(" + names + r")\s*=\s*(" + word + r")\s*")
    values = {}
    with open(sys.argv[1], "rb") as source:
        contents = source.read()
    if contents.startswith(b"\xef\xbb\xbf"):
        contents = contents[3:]
    for raw_line in re.split(rb"\r\n|\r|\n", contents):
        candidate = prefix.match(raw_line)
        if not candidate:
            continue
        name = candidate[1].decode("ascii")
        try:
            line = raw_line.decode("utf-8")
        except UnicodeError:
            raise SystemExit(name if name in metadata_patterns else "Malformed signing variable: " + name)
        match = assignment.fullmatch(line)
        if not match:
            raise SystemExit(name if name in metadata_patterns else "Malformed signing variable: " + name)
        values[match[1]] = match[2]
    for required in (("AZURE_TENANT_ID", "AZURE_SIGNING_KVT"), ("AZURE_CLIENT_ID", "AZURE_SIGNING_KVI"),
                     ("AZURE_CLIENT_SECRET", "AZURE_SIGNING_KVS")):
        canonical = unquote(values.get(required[0], ""))
        effective = canonical if canonical else unquote(values.get(required[1], ""))
        if not effective.strip():
            raise SystemExit("Signing env file requires non-empty " + " or ".join(required) + ".")
    for name, pattern in metadata_patterns.items():
        present = name in values
        default = "https://neu.codesigning.azure.net" if name == "AZURE_SIGNING_ENDPOINT" else ""
        value = unquote(values[name]) if present else os.environ.get(name, default)
        if not re.fullmatch(pattern, value):
            raise SystemExit(name)
        if not present:
            values[name] = value
    output = "".join(name + "=" + value + "\n" for name, value in values.items()).encode("utf-8")
    if sys.argv[3] != "--validate":
        sys.stdout.buffer.write(output)
except SystemExit:
    raise
except Exception:
    raise SystemExit("Signing env file could not be parsed.")
' "$SIGNING_REAL" "$SIGNING_NAMES" "${1:-}"
}

remote_ps() {
    local encoded limit="${2:-120}"
    encoded="$(printf '%s' "\$ProgressPreference='SilentlyContinue'; try { & { $1 } *>&1 } catch { Write-Output \$_.Exception.Message; exit 1 }" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\r\n')"
    exec "$TIMEOUT" --kill-after=15 "$limit" ssh "${SSH_OPTIONS[@]}" "$HOST" powershell.exe -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand "$encoded"
}

run_step() {
    local result=0
    "$@" <&0 &
    STEP_PID=$!
    wait "$STEP_PID" || result=$?
    STEP_PID=''
    return "$result"
}

stop_step() {
    if [ -n "$STEP_PID" ]; then
        kill -TERM "$STEP_PID" 2>/dev/null || true
        wait "$STEP_PID" 2>/dev/null || true
        STEP_PID=''
    fi
}

stop_heartbeat() {
    if [ -n "$HEARTBEAT_PID" ]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_PID=''
    fi
}

retry_remote_ps() {
    local script="$1" limit="${2:-120}" operation="${3:-}" attempt result delay
    for attempt in 1 2 3; do
        result=0
        run_step remote_ps "$script" "$limit" </dev/null || result=$?
        case "$result" in
            0) return 0 ;;
            74)
                if [ "$operation" = Release ] && [ "$attempt" -gt 1 ]; then
                    echo 'VM lock no longer owned by this invocation (an earlier release reply was lost)'
                    run_step remote_ps "$(lock_command Describe)" 30 </dev/null || true
                    return 0
                fi
                return "$result" ;;
            124|255) ;;
            *) return "$result" ;;
        esac
        [ "$attempt" -lt 3 ] || return "$result"
        delay=$((attempt * 20))
        echo "VM cleanup transport unavailable; retrying in ${delay}s ($attempt/3)." >&2
        run_step "$TIMEOUT" --kill-after=2 "$((delay + 2))" sleep "$delay" || return
    done
}

verify_release_sums() {
    cd "$1/upload" || return
    exec "$TIMEOUT" --kill-after=15 120 shasum -a 256 -c SHA256SUMS-windows.txt
}

verify_release_signatures() {
    local installer
    if ! command -v osslsigncode >/dev/null; then
        echo 'Notice: osslsigncode is not installed; skipping optional Mac signature verification.'
        return 0
    fi
    for installer in "$1/upload"/*-Setup.exe; do
        [ -f "$installer" ] || continue
        run_step "$TIMEOUT" --kill-after=15 120 osslsigncode verify -in "$installer" >/dev/null || {
            echo "Signature check failed: $installer" >&2
            return 1
        }
    done
}

ensure_release_draft() {
    local status_file="$1"
    if ! run_step "$TIMEOUT" --kill-after=15 60 gh release view "$TAG" --repo "$GITHUB_REPO" --json isDraft --jq .isDraft > "$status_file"; then
        if [[ "$VERSION" == *-* ]]; then
            run_step "$TIMEOUT" --kill-after=15 120 gh release create "$TAG" --repo "$GITHUB_REPO" --draft --prerelease --verify-tag --title "VoxClip $VERSION" --notes 'Windows build' || return
        else
            run_step "$TIMEOUT" --kill-after=15 120 gh release create "$TAG" --repo "$GITHUB_REPO" --draft --verify-tag --title "VoxClip $VERSION" --notes 'Windows build' || return
        fi
        run_step "$TIMEOUT" --kill-after=15 60 gh release view "$TAG" --repo "$GITHUB_REPO" --json isDraft --jq .isDraft > "$status_file" || return
    fi
    [ "$(<"$status_file")" = true ] || { echo 'Refusing to replace assets on a published release.' >&2; return 1; }
}

lock_command() {
    printf '& { %s } -Operation %s -Path %s -RunId %s' "$LOCK_SCRIPT" "$1" "$(ps_literal "$LOCK")" "$(ps_literal "$LOCK_OWNER")"
}

heartbeat_loop() {
    local interval="${1:-60}" retry_delay="${2:-20}" attempt result
    trap 'stop_step; exit 0' INT TERM
    trap - EXIT
    while run_step "$TIMEOUT" --kill-after=2 "$(( ${interval%.*} + 5 ))" sleep "$interval"; do
        for attempt in 1 2 3; do
            result=0
            run_step remote_ps "$(lock_command Check)" 30 </dev/null || result=$?
            [ "$result" -ne 0 ] || break
            if [ "$result" -eq 74 ]; then
                echo 'VM lock ownership lost; aborting immediately.' >&2
                kill -TERM "$RELEASE_PID"
                return 1
            fi
            if [ "$attempt" -eq 3 ]; then
                echo 'VM ownership heartbeat failed three times; aborting.' >&2
                kill -TERM "$RELEASE_PID"
                return 1
            fi
            echo "VM ownership check unavailable; retrying ($attempt/3)." >&2
            run_step "$TIMEOUT" --kill-after=2 "$(( ${retry_delay%.*} + 5 ))" sleep "$retry_delay"
        done
    done
}
