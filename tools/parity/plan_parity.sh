#!/usr/bin/env bash
# Compare both native CLI plans and the committed project-plan take expectations.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -z "${VOXCLIP_MAC_CLI:-}" ]; then
  swift build --package-path "$ROOT/apps/macos" -c release --jobs 2 --product voxclip-cli
  VOXCLIP_MAC_CLI="$(swift build --package-path "$ROOT/apps/macos" -c release --show-bin-path)/voxclip-cli"
fi
if [ -z "${VOXCLIP_WIN_CLI:-}" ]; then
  dotnet build "$ROOT/apps/windows/src/VoxClip.Cli/VoxClip.Cli.csproj" -c Release -m:1 -nodeReuse:false -p:UseSharedCompilation=false
  VOXCLIP_WIN_CLI="$ROOT/apps/windows/src/VoxClip.Cli/bin/Release/net10.0/voxclip-cli"
fi
test -x "$VOXCLIP_MAC_CLI" && test -f "$VOXCLIP_WIN_CLI"
PY="${VOXCLIP_PLAN_PYTHON:-python3}"
OUT="$(mktemp -d -t voxclip-plan-parity)"
trap 'rm -rf "$OUT"' EXIT
count=0
for project in "$ROOT"/shared/fixtures/projects/*.voxclip; do
  name="$(basename "$project" .voxclip)"
  fixture="$ROOT/shared/fixtures/editing/projects/$name.json"
  test -f "$fixture" || { echo "Missing take expectation: $fixture" >&2; exit 1; }
  VOXCLIP_SHARED_DIR="$ROOT/shared" "$VOXCLIP_MAC_CLI" plan --open "$project" --json > "$OUT/mac.json"
  VOXCLIP_SHARED_DIR="$ROOT/shared" "$VOXCLIP_WIN_CLI" plan --open "$project" --json > "$OUT/win.json"
  "$PY" - "$name" "$OUT/mac.json" "$OUT/win.json" "$fixture" <<'PY'
import json
import sys
from pathlib import Path

name, mac_path, win_path, fixture_path = sys.argv[1:]
mac, win, fixture = [json.loads(Path(path).read_text(encoding="utf-8"))
                     for path in (mac_path, win_path, fixture_path)]
assert isinstance(mac, dict) and isinstance(win, dict), f"{name}: plan output must be objects"
assert mac.get("ok") is True and win.get("ok") is True, f"{name}: plan command failed"
mac.pop("version", None)
win.pop("version", None)
assert mac == win, f"{name}: Swift and .NET plans differ: {mac!r} != {win!r}"
expected = fixture["expected"]
assert fixture["kind"] == "project-plan"
for key in ("sampleRate", "outputSamples", "durationSeconds", "kept"):
    wanted = expected[key] if key == "sampleRate" else expected["take"][key]
    assert mac[key] == wanted, f"{name}: {key} differs from take fixture"
assert mac["totalSamples"] == round(expected["sourceDurationSeconds"] * expected["sampleRate"]), (
    f"{name}: totalSamples differs from take fixture")
print(f"{name}: both CLI plans match the take fixture")
PY
  count=$((count + 1))
done
test "$count" -gt 0 || { echo 'No shared project fixtures found' >&2; exit 1; }
echo "Compared $count shared project plans"
