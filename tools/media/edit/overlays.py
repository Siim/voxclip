"""Pillow overlays adapted from the author's A10 trailer tooling.

Generic keycap, callout, loupe and card geometry from tutorial/edit.py and
trailer/animatic_v2.py. Cursor/ripples are new and use the same UI event log.
"""
import math
from PIL import Image, ImageDraw
from .art import font, palette
from .model import events_by_step

KINDS = {'keycap', 'ring', 'box', 'loupe', 'chapter', 'title', 'end'}


def render_overlay(base, time, overlays, events):
    width, height = base.size
    layer = Image.new('RGBA', base.size)
    draw = ImageDraw.Draw(layer)
    colors = palette()
    accent, paper, ink = colors['accent'], colors['paper'], colors['ink']
    card_active = False
    for spec in overlays:
        start, end = spec['start'], spec['end']
        if not start <= time < end:
            continue
        kind = spec['kind']
        if kind not in KINDS:
            raise ValueError(f'unknown overlay: {kind}')
        rect = spec.get('rect', [width * .1, height * .25, width * .3, height * .2])
        x, y, w, h = rect
        label = spec.get('text', '')
        size = max(12, round(height * .065))
        if kind == 'keycap':
            f = font(size, True)
            key_width = max(w, f.getlength(label) + 24)
            draw.rounded_rectangle((x, y + 4, x + key_width, y + h + 4), 6, fill=colors['muted'])
            draw.rounded_rectangle((x, y, x + key_width, y + h), 6, fill=accent if spec.get('pressed') else colors['raised'])
            draw.text((x + key_width / 2, y + h / 2), label, font=f, fill=colors['pressedLabel'] if spec.get('pressed') else paper, anchor='mm')
        elif kind in {'box', 'ring'}:
            grow = max(0, 1 - (time - start) * 5) * height * .015
            bounds = (x - grow, y - grow, x + w + grow, y + h + grow)
            if kind == 'box':
                draw.rounded_rectangle(bounds, 6, outline=accent, width=3)
            else:
                draw.ellipse(bounds, outline=accent, width=3)
                draw.line((x + w, y + h / 2, x + w + 16, y - 10), fill=accent, width=2)
            draw.text((x, max(2, y - size - 6)), label, font=font(size), fill=paper)
        elif kind == 'loupe':
            zoom = spec.get('zoom', 2)
            radius = max(4, round(spec.get('radius', height * .18)))
            px, py = spec.get('position', [width * .76, height * .4])
            cx, cy = x + w / 2, y + h / 2
            sr = radius / zoom
            crop = base.crop((round(cx - sr), round(cy - sr), round(cx + sr), round(cy + sr))).resize((radius * 2, radius * 2), Image.Resampling.LANCZOS)
            mask = Image.new('L', crop.size)
            ImageDraw.Draw(mask).ellipse((0, 0, radius * 2 - 1, radius * 2 - 1), fill=255)
            layer.paste(crop.convert('RGBA'), (round(px - radius), round(py - radius)), mask)
            draw.ellipse((px - radius, py - radius, px + radius, py + radius), outline=accent, width=3)
            angle = math.atan2(py - cy, px - cx)
            draw.line((cx, cy, px - math.cos(angle) * radius, py - math.sin(angle) * radius), fill=accent, width=2)
        else:
            card_active = True
            # Title, chapter and end cards share the same restrained typographic system.
            draw.rectangle((0, 0, width, height), fill=ink)
            kicker = spec.get('kicker', {'chapter': 'NEXT', 'title': 'VOXCLIP', 'end': 'FREE / MIT'}[kind])
            draw.text((width / 2, height * .32), kicker, font=font(height * .055, True), fill=accent, anchor='mm')
            title_size = max(12, round(height * .12))
            while title_size > 12 and font(title_size).getlength(label) > width * .88:
                title_size -= 1
            draw.text((width / 2, height * .5), label, font=font(title_size), fill=paper, anchor='mm')
            draw.line((width * .4, height * .65, width * .6, height * .65), fill=accent, width=3)
    if card_active:
        return layer
    # A deterministic interpolated pointer. Click events get a 0.5-second expanding ring.
    by_step = events_by_step(events)
    ordered = list(by_step.values())
    past = [event for event in ordered if event['timestamp'] <= time]
    if past:
        previous = past[-1]
        following = next((event for event in ordered if event['timestamp'] > time), previous)
        def center(event):
            x, y, w, h = event['targetFrame']
            return x + w / 2, y + h / 2
        ax, ay = center(previous)
        bx, by = center(following)
        delta = following['timestamp'] - previous['timestamp']
        progress = min(1, (time - previous['timestamp']) / delta) if delta else 0
        x, y = ax + (bx - ax) * progress, ay + (by - ay) * progress
        scale = max(.6, height / 720)
        points = [(x, y), (x + 5 * scale, y + 23 * scale), (x + 10 * scale, y + 15 * scale), (x + 19 * scale, y + 13 * scale)]
        draw.polygon(points, fill=paper, outline=ink, width=2)
        for event in past:
            age = time - event['timestamp']
            if event.get('click') and 0 <= age < .5:
                cx, cy = center(event)
                radius = (8 + 30 * age / .5) * scale
                rgba = tuple(bytes.fromhex(accent.lstrip('#'))) + (round(255 * (1 - age / .5)),)
                draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), outline=rgba, width=3)
    return layer
