#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")/.."
command -v magick >/dev/null || { printf '%s\n' 'Install ImageMagick to regenerate the background.' >&2; exit 1; }
magick -background none dmg-background.svg \
    -font ../../shared/fonts/dm-sans/DMSans-Bold.ttf -fill '#F3F0E7' -pointsize 27 \
    -gravity North -annotate +0+38 'VoxClip' \
    -font ../../shared/fonts/dm-sans/DMSans-Medium.ttf -fill '#F3F0E7' -pointsize 15 \
    -gravity North -annotate +0+332 'Drag VoxClip to Applications' \
    -strip PNG24:dmg-background.png
