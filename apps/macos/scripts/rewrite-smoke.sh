#!/bin/zsh
# The Rewrite smoke (doc/release.md): drives the Rewrite flow through nine stuck scenarios with a scripted AI and
# ElevenLabs, offscreen, and checks the panel after every step. Run it before every handed-over test build.
#
#   apps/macos/scripts/rewrite-smoke.sh [<VoxClip.app | debug executable | build directory>] [--keep <dir>]
#       [--only S1,S4] [--known-failing I2,I7]
#
# With no path it builds the DEBUG app (swift build --product VoxClip) in apps/macos and runs .build/debug/VoxClip.
# It prints summary.txt and exits non-zero when any invariant not named in --known-failing fails. The report
# (rewrite-smoke.json, summary.txt and a PNG of the panel per failing step) stays in --keep's directory, else in a
# temporary one that is printed. No paid or live request is made; it is safe while the Mac is in use.
set -euo pipefail

script_dir=${0:A:h}
package=${script_dir:h}
target=""
keep=""
only=""
known=""
while (( $# > 0 )); do
    case $1 in
        --keep) keep=$2; shift 2 ;;
        --only) only=$2; shift 2 ;;
        --known-failing) known=$2; shift 2 ;;
        -h|--help) sed -n 2,10p "$0"; exit 0 ;;
        *) target=$1; shift ;;
    esac
done

if [[ -z $target ]]; then
    (cd "$package" && nice -n 10 swift build --product VoxClip >&2)
    executable=$package/.build/debug/VoxClip
elif [[ -d $target && -x $target/Contents/MacOS/VoxClip ]]; then
    executable=$target/Contents/MacOS/VoxClip
elif [[ -d $target && -x $target/VoxClip ]]; then
    executable=$target/VoxClip
else
    executable=$target
fi
[[ -x $executable ]] || { print -u2 "rewrite-smoke: no VoxClip executable at $executable"; exit 2; }

work=$(mktemp -d /tmp/voxclip-rewrite-smoke.XXXXXX)
output=${keep:-$work/out}
mkdir -p "$output" "$work/data"
arguments=(-ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO -rewriteSmoke "$output")
[[ -n $only ]] && arguments+=(-rewriteSmokeOnly "$only")
[[ -n $known ]] && arguments+=(-rewriteSmokeKnownFailing "$known")

# A clean environment: no provider keys or tokens reach the app, the data folder is temporary and nothing downloads.
result=0
env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
    VOXCLIP_SHARED_DIR="${package:h:h}/shared" VOXCLIP_DATA_DIR="$work/data" VOXCLIP_NO_KEYCHAIN=1 \
    VOXCLIP_LIVE_TESTS=0 VOXCLIP_TEST_DOWNLOAD=0 \
    "$executable" "${arguments[@]}" > "$work/app.log" 2>&1 || result=$?
rm -rf "${work:?}/data"

if [[ -f $output/summary.txt ]]; then
    cat "$output/summary.txt"
else
    print -u2 "rewrite-smoke: the app exited $result without a report; its log:"
    tail -20 "$work/app.log" >&2
    (( result == 0 )) && result=1
fi
print "Report: $output/rewrite-smoke.json"
exit $result
