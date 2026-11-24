#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")/.."
command -v magick >/dev/null || { printf '%s\n' 'Install ImageMagick to regenerate the background.' >&2; exit 1; }
command -v rsvg-convert >/dev/null || { printf '%s\n' 'Install librsvg (rsvg-convert) to regenerate the background.' >&2; exit 1; }
plate=$(mktemp -t voxclip-dmg-plate).png
trap 'rm -f "$plate"' EXIT
# librsvg draws the plate: ImageMagick's own SVG renderer drops the gradient and the arrow.
rsvg-convert -w 1200 -h 800 dmg-background.svg -o "$plate"
# 1200×800 at 144 dpi: Finder draws it at the 600×400 window size, sharp on Retina.
magick "$plate" \
    -font ../../shared/fonts/dm-sans/DMSans-Bold.ttf -fill '#F3F0E7' -pointsize 54 \
    -gravity North -annotate +0+76 'VoxClip' \
    -font ../../shared/fonts/dm-sans/DMSans-Medium.ttf -fill '#F3F0E7' -pointsize 30 \
    -gravity North -annotate +0+664 'Drag VoxClip to Applications' \
    -strip -units PixelsPerInch -density 144 PNG24:dmg-background.png
sips -s dpiWidth 144 -s dpiHeight 144 dmg-background.png >/dev/null
