#!/usr/bin/env python3
"""Deterministic still exports; adapted from the author's A10 trailer tooling.

macOS inputs retain their native alpha/shadow; Windows inputs get one soft shadow.
Lossless inputs and generated social/contact PNGs belong outside git.
"""
import argparse
from pathlib import Path

from PIL import Image, ImageOps
from edit.art import contact_sheet, footer, headline, palette, shadow


def normalize(image, platform):
    image = ImageOps.exif_transpose(image).convert('RGBA')
    if platform == 'macos':
        return image.copy()
    if platform != 'windows':
        raise ValueError('platform must be macos or windows')
    pad = max(12, round(image.width * 0.04))
    base = Image.new('RGBA', (image.width + 2 * pad, image.height + 2 * pad))
    shadow(base, (pad, pad, pad + image.width - 1, pad + image.height - 1),
           radius=max(4, round(image.width * .008)), blur=pad * .35, offset=(0, round(pad * .25)))
    base.alpha_composite(image, (pad, pad))
    return base


def export(image, output, platform):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    normalized = normalize(image, platform)
    for name, width in [('readme', 1600), ('site', 2400)]:
        width = min(width, image.width, normalized.width)
        sized = normalized.resize((width, max(1, round(normalized.height * width / normalized.width))), Image.Resampling.LANCZOS)
        sized.save(output / f'{name}.webp', format='WEBP', quality=82, method=6, exact=True)
    social = Image.new('RGBA', (1280, 640), palette()['ink'])
    headline(social, 'Cut video by its words.', (48, 28), 54)
    thumb = normalized.copy()
    thumb.thumbnail((1120, 410), Image.Resampling.LANCZOS)
    social.alpha_composite(thumb, ((1280 - thumb.width) // 2, 128))
    footer(social, 'VoxClip / Mac + Windows / MIT', size=19, margin=34)
    target = output / 'social.png'
    # Fixed quantization, no metadata or random dithering; noisy masters stay < 1 MB.
    social.convert('RGB').quantize(colors=192, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(target, optimize=True)
    if target.stat().st_size >= 1_000_000:
        raise ValueError('social preview exceeds 1 MB')
    contact_sheet([normalized], [platform], columns=1, width=640).save(output / 'contact.png', optimize=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--platform', choices=['macos', 'windows'], required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    with Image.open(args.input, formats=('PNG', 'JPEG', 'WEBP', 'TIFF')) as image:
        export(image, args.out, args.platform)


if __name__ == '__main__':
    main()
