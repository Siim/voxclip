"""Poster/contact helpers adapted from the author's A10 trailer tooling.

Source: tools/trailer/poster.py (cover, shadow, headline, footer), contact.py.
Only the author's generic Pillow geometry is reused; see doc/media/provenance.md.
"""
from functools import lru_cache
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[3]


@lru_cache(maxsize=64)
def font(size, mono=False):
    path = ROOT / 'shared/fonts' / ('jetbrains-mono/JetBrainsMono-SemiBold.ttf' if mono else 'dm-sans/DMSans-Medium.ttf')
    return ImageFont.truetype(str(path), max(1, round(size)))


@lru_cache(maxsize=1)
def palette():
    colors = json.loads((ROOT / 'shared/design/tokens.json').read_text())['color']
    return {name: colors[group][key]['$value']['dark'] for name, group, key in (
        ('paper', 'text', 'primary'), ('muted', 'text', 'secondary'),
        ('ink', 'bg', 'surface'), ('accent', 'accent', 'text'),
        ('raised', 'bg', 'elevated'), ('pressedLabel', 'word', 'playingForeground'))}


def cover(image, width, height, fx=0.5, fy=0.5):
    scale = max(width / image.width, height / image.height)
    if scale > 1:
        raise ValueError('cover output would upscale the source; use a smaller size')
    image = image.resize((math.ceil(image.width * scale), math.ceil(image.height * scale)), Image.Resampling.LANCZOS)
    x = round(min(max(fx * image.width - width / 2, 0), image.width - width))
    y = round(min(max(fy * image.height - height / 2, 0), image.height - height))
    return image.crop((x, y, x + width, y + height))


def shadow(base, box, radius=12, blur=24, opacity=0.28, offset=(0, 12)):
    mask = Image.new('L', base.size)
    x0, y0, x1, y1 = box
    ImageDraw.Draw(mask).rounded_rectangle((x0 + offset[0], y0 + offset[1], x1 + offset[0], y1 + offset[1]), radius, fill=round(255 * opacity))
    mask = mask.filter(ImageFilter.GaussianBlur(blur))
    layer = Image.new('RGBA', base.size, (0, 0, 0, 0))
    layer.putalpha(mask)
    base.alpha_composite(layer)


def headline(base, text, xy=(48, 42), size=56, color=None):
    ImageDraw.Draw(base).text(xy, text, font=font(size), fill=color or palette()['paper'])


def footer(base, text, margin=48, size=22):
    ImageDraw.Draw(base).text((margin, base.height - margin), text, font=font(size, True), fill=palette()['muted'], anchor='ls')


def contact_sheet(images, labels=None, columns=3, width=320):
    if not images or columns < 1 or width < 64:
        raise ValueError('contact sheet needs images, columns >= 1 and width >= 64')
    colors = palette()
    height = round(width * 9 / 16)
    sheet = Image.new('RGB', (columns * (width + 16) + 16, math.ceil(len(images) / columns) * (height + 48) + 16), colors['ink'])
    for i, image in enumerate(images):
        x, y = 16 + (i % columns) * (width + 16), 16 + (i // columns) * (height + 48)
        thumb = image.convert('RGB')
        thumb.thumbnail((width, height), Image.Resampling.LANCZOS)
        sheet.paste(thumb, (x + (width - thumb.width) // 2, y))
        ImageDraw.Draw(sheet).text((x, y + height + 8), (labels or [str(j + 1) for j in range(len(images))])[i], font=font(14, True), fill=colors['paper'])
    return sheet
