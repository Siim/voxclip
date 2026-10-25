#!/usr/bin/env bash
# Caption parity (doc/spec/captions.md sections 16.4 to 16.6).
# Renders every golden sample of every layout fixture, and every gallery tile, with the Swift CLI and
# the C# CLI on this Mac, compares Swift against C#, and compares both against the committed goldens
# when they exist. Needs: Xcode with the macOS 26 SDK, the .NET 10 SDK, python3 with numpy.
#
#   tools/captions/parity.sh [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$(mktemp -d -t voxclip-parity)}"
FIX="$ROOT/shared/fixtures/captions"
GOLDEN="$FIX/golden"
mkdir -p "$OUT/swift" "$OUT/dotnet" "$OUT/diff"

echo "Building the CLIs"
swift build --package-path "$ROOT/apps/macos" -c release --product voxclip-cli
dotnet build "$ROOT/apps/windows/src/VoxClip.Cli" -c Release

swift_cli() { swift run --package-path "$ROOT/apps/macos" -c release --skip-build voxclip-cli "$@"; }
dotnet_cli() { dotnet run --project "$ROOT/apps/windows/src/VoxClip.Cli" -c Release --no-build -- "$@"; }

echo "Rendering into $OUT"
for f in "$FIX"/layout/*.json; do
  swift_cli render-caption --case "$f" --out "$OUT/swift"
  dotnet_cli render-caption --case "$f" --out "$OUT/dotnet"
done
swift_cli render-caption --tiles "$FIX/preview-tiles.json" --out "$OUT/swift"
dotnet_cli render-caption --tiles "$FIX/preview-tiles.json" --out "$OUT/dotnet"

PY=python3
if ! python3 -c 'import numpy' 2>/dev/null; then
  python3 -m venv "$OUT/venv"
  "$OUT/venv/bin/pip" install -q "$(grep '^numpy==' "$ROOT/tools/captions/requirements.txt")"
  PY="$OUT/venv/bin/python"
fi
compare() { "$PY" -I "$ROOT/tools/captions/compare_overlays.py" --dirs "$1" "$2" --diff-dir "$3"; }

status=0
echo "Swift vs C#"
compare "$OUT/swift" "$OUT/dotnet" "$OUT/diff/swift-vs-dotnet" || status=1
if [ -d "$GOLDEN" ]; then
  echo "Goldens vs Swift"
  compare "$GOLDEN" "$OUT/swift" "$OUT/diff/golden-vs-swift" || status=1
  echo "Goldens vs C#"
  compare "$GOLDEN" "$OUT/dotnet" "$OUT/diff/golden-vs-dotnet" || status=1
fi
exit $status
