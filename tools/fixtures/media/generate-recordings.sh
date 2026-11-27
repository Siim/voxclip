#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../shared/fixtures/media"

generate() {
    local counter='' bit
    for bit in {0..7}; do
        counter+=",drawbox=x=$((28 + 11 * bit)):y=56:w=8:h=16:c=yellow:t=fill:enable='mod(floor(n/$((1 << bit))),2)'"
    done
    ffmpeg -nostdin -hide_banner -loglevel error -y \
        -f lavfi -i "color=$1:s=$2:r=30:d=6,drawgrid=w=$3:h=$4:t=4:c=white,drawbox=x=24:y=52:w=92:h=24:c=black:t=fill${counter}" \
        -f lavfi -i "aevalsrc=$5*sin(2*PI*($6*t+7*t*t)):s=$7:d=6" \
        -c:v libx264 -pix_fmt yuv420p -threads 1 -c:a aac -b:a 96k -movflags +faststart "$8"
}

generate navy 320x180 160 30 0.20 293 48000 recording-0007.mp4
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
generate darkred 144x256 24 128 0.10 487 44100 "$temporary/0010.mp4"
ffmpeg -nostdin -hide_banner -loglevel error -y -display_rotation:v:0 90 -i "$temporary/0010.mp4" \
    -map 0 -c copy -movflags +faststart recording-0010.mp4
