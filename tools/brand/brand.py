#!/usr/bin/env python3
"""VoxClip brand assets: SVG sources from one geometry, then the rendered app icons.

    python3 -I tools/brand/brand.py svg        # SVG sources (standard library only)
    python3 -I tools/brand/brand.py wordmark   # voxclip-wordmark.svg (fonttools, uharfbuzz)
    python3 -I tools/brand/brand.py render     # PNGs, AppIcon.icns, app.ico (Pillow; rsvg-convert or magick; iconutil)
    python3 -I tools/brand/brand.py all

Everything is written to shared/brand/. The SVGs are generated: change the geometry or colours here
and rerun, do not edit the files by hand. See shared/brand/README.md.
"""
from __future__ import annotations

import io
import shutil
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BRAND = REPO / "shared" / "brand"
DM_SANS = REPO / "shared" / "fonts" / "dm-sans"

# Colours. Plate and paper come from the VoxConvo / VoxClip titanium palette, coral is the cut colour
# (tokens.json cut.stroke dark #F38F83, light #C4453F).
GRAPHITE_TOP, GRAPHITE_BOTTOM = "#2C2E35", "#0F1013"
PAPER, PAPER_TOP, PAPER_BOTTOM = "#F3F0E7", "#FBF9F3", "#E3E0D6"
CORAL, CORAL_TOP, CORAL_BOTTOM = "#F38F83", "#FFA396", "#EE6A5E"
INK, CUT_ON_LIGHT = "#131419", "#C4453F"
SMALL_TOP, SMALL_BOTTOM = "#2E3037", "#15161A"  # plate of the pixel-hinted sizes

# The glyph, in 1024-master pixels relative to its centre: (centre x, width, height).
# Four bars in VoxConvo's waveform rhythm (short, tall | mid, short), split by a wider cut gap
# where the peak was; the coral seam is where the two halves join.
BARS = [(-230, 84, 230), (-118, 84, 390), (118, 84, 320), (230, 84, 190)]
SEAM = (0, 36, 500)
GLYPH_W, GLYPH_H = 544, 500

# The line mark (menus, README, wordmark): same rhythm and split, drawn on a 15 x 16 grid so it is
# pixel-exact at 16, 32, 48 and 64 px tall. Lighter than the icon glyph, like VoxConvo's mark.
# (x0, x1, y0, y1) in grid units.
MARK_W, MARK_H = 15, 16
MARK_BARS = [(0, 2, 5, 11), (3, 5, 2, 14), (10, 12, 3, 13), (13, 15, 5, 11)]
MARK_SEAM = (7, 8, 1, 15)

# Pixel-hinted sources for small sizes: integer edges so every bar lands on whole pixels.
# plate = (x, y, size, corner radius); bars and seam = (x0, x1, y0, y1).
HINTED = {
    "voxclip-icon-16.svg": dict(size=16, shape="squircle", plate=(1, 1, 14, 3.15),
                                bars=[(3, 5, 6, 10), (6, 8, 4, 12), (11, 13, 5, 11)], seam=(9, 10, 3, 13)),
    "voxclip-icon-32.svg": dict(size=32, shape="squircle", plate=(3, 3, 26, 5.85),
                                bars=[(6, 9, 12, 20), (10, 13, 10, 22), (19, 22, 11, 21), (23, 26, 13, 19)],
                                seam=(15, 17, 8, 24)),
    "voxclip-icon-64.svg": dict(size=64, shape="squircle", plate=(6, 6, 52, 11.7),
                                bars=[(15, 20, 25, 39), (22, 27, 20, 44), (37, 42, 22, 42), (44, 49, 26, 38)],
                                seam=(31, 33, 16, 48)),
    "voxclip-icon-flat-16.svg": dict(size=16, shape="rect", plate=(0, 0, 16, 3.5),
                                     bars=[(3, 5, 6, 10), (6, 8, 4, 12), (11, 13, 5, 11)], seam=(9, 10, 3, 13)),
    "voxclip-icon-flat-24.svg": dict(size=24, shape="rect", plate=(1, 1, 22, 4.5),
                                     bars=[(4, 6, 9, 15), (7, 9, 7, 17), (15, 17, 8, 16), (18, 20, 10, 14)],
                                     seam=(11, 13, 5, 19)),
    "voxclip-icon-flat-32.svg": dict(size=32, shape="rect", plate=(2, 2, 28, 5.5),
                                     bars=[(6, 9, 12, 20), (10, 13, 9, 23), (19, 22, 10, 22), (23, 26, 13, 19)],
                                     seam=(15, 17, 7, 25)),
    "voxclip-icon-flat-48.svg": dict(size=48, shape="rect", plate=(3, 3, 42, 8.25),
                                     bars=[(10, 14, 18, 30), (16, 20, 14, 34), (28, 32, 16, 32), (34, 38, 19, 29)],
                                     seam=(23, 25, 11, 37)),
}

# Which source renders each size.
MAC_ICONSET = {  # iconset file name -> (source, pixels)
    "icon_16x16.png": ("hinted/voxclip-icon-16.svg", 16),
    "icon_16x16@2x.png": ("hinted/voxclip-icon-32.svg", 32),
    "icon_32x32.png": ("hinted/voxclip-icon-32.svg", 32),
    "icon_32x32@2x.png": ("hinted/voxclip-icon-64.svg", 64),
    "icon_128x128.png": ("voxclip-icon.svg", 128),
    "icon_128x128@2x.png": ("voxclip-icon.svg", 256),
    "icon_256x256.png": ("voxclip-icon.svg", 256),
    "icon_256x256@2x.png": ("voxclip-icon.svg", 512),
    "icon_512x512.png": ("voxclip-icon.svg", 512),
    "icon_512x512@2x.png": ("voxclip-icon.svg", 1024),
}
WIN_SIZES = {16: "hinted/voxclip-icon-flat-16.svg", 24: "hinted/voxclip-icon-flat-24.svg",
             32: "hinted/voxclip-icon-flat-32.svg", 48: "hinted/voxclip-icon-flat-48.svg",
             64: "voxclip-icon-flat.svg", 128: "voxclip-icon-flat.svg", 256: "voxclip-icon-flat.svg"}

HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'


def num(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def rect(x, y, w, h, r, extra=""):
    return f'<rect x="{num(x)}" y="{num(y)}" width="{num(w)}" height="{num(h)}" rx="{num(r)}"{extra}/>'


# Continuous-corner rounded rectangle (the Apple icon shape), as a cubic path.
_K = (1.52866483, 1.08849296, 0.86840694, 0.66993427, 0.06549600, 0.63149399, 0.07491100, 0.37282392, 0.16905899)


def squircle(x, y, w, h, r):
    a, b, c, d, e, f, g, i, j = (k * r for k in _K)
    X, Y = x + w, y + h

    def p(*pts):
        return " ".join(f"{num(px)},{num(py)}" for px, py in pts)

    return "".join([
        f"M{p((x + a, y))}H{num(X - a)}",
        f"C{p((X - b, y), (X - c, y), (X - d, y + e))}L{p((X - f, y + g))}",
        f"C{p((X - i, y + j), (X - j, y + i), (X - g, y + f))}L{p((X - e, y + d))}",
        f"C{p((X, y + c), (X, y + b), (X, y + a))}V{num(Y - a)}",
        f"C{p((X, Y - b), (X, Y - c), (X - e, Y - d))}L{p((X - g, Y - f))}",
        f"C{p((X - j, Y - i), (X - i, Y - j), (X - f, Y - g))}L{p((X - d, Y - e))}",
        f"C{p((X - c, Y), (X - b, Y), (X - a, Y))}H{num(x + a)}",
        f"C{p((x + b, Y), (x + c, Y), (x + d, Y - e))}L{p((x + f, Y - g))}",
        f"C{p((x + i, Y - j), (x + j, Y - i), (x + g, Y - f))}L{p((x + e, Y - d))}",
        f"C{p((x, Y - c), (x, Y - b), (x, Y - a))}V{num(y + a)}",
        f"C{p((x, y + b), (x, y + c), (x + e, y + d))}L{p((x + g, y + f))}",
        f"C{p((x + j, y + i), (x + i, y + j), (x + f, y + g))}L{p((x + d, y + e))}",
        f"C{p((x + c, y), (x + b, y), (x + a, y))}Z",
    ])


def glyph(scale, cx, cy, bar_attr, seam_attr, indent="    "):
    """The four bars and the seam, scaled from master pixels and centred on (cx, cy)."""
    out = []
    for x, w, h in BARS:
        W, H = w * scale, h * scale
        out.append(rect(cx + x * scale - W / 2, cy - H / 2, W, H, W / 2, bar_attr))
    x, w, h = SEAM
    W, H = w * scale, h * scale
    out.append(rect(cx + x * scale - W / 2, cy - H / 2, W, H, W / 2, seam_attr))
    return ("\n" + indent).join(out)


def svg_open(w, h, label="VoxClip", extra=""):
    return (HEAD + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {num(w)} {num(h)}" '
            f'width="{num(w)}" height="{num(h)}" role="img" aria-label="{label}"{extra}>\n  <title>{label}</title>\n')


def vgrad(gid, y0, y1, top, bottom):
    return (f'<linearGradient id="{gid}" x1="0" y1="{num(y0)}" x2="0" y2="{num(y1)}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>')


def mac_icon():
    plate = squircle(100, 100, 824, 824, 185.4)
    cy = 508
    y0, y1 = cy - GLYPH_H / 2, cy + GLYPH_H / 2
    return svg_open(1024, 1024) + f'''  <!-- macOS master. Apple icon grid: 1024 canvas, 824 x 824 body at 100,100 with a continuous corner
       (radius 185.4); the margin holds the drop shadow. Sizes 16, 32 and 64 use hinted/ instead. -->
  <defs>
    {vgrad("vc-plate", 100, 924, GRAPHITE_TOP, GRAPHITE_BOTTOM)}
    <linearGradient id="vc-rim" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.06"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.10"/></linearGradient>
    <radialGradient id="vc-sheen" cx="512" cy="100" r="620" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.07"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>
    {vgrad("vc-paper", y0, y1, PAPER_TOP, PAPER_BOTTOM)}
    {vgrad("vc-coral", y0, y1, CORAL_TOP, CORAL_BOTTOM)}
    <filter id="vc-plate-shadow" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="vc-glyph-shadow" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="10"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.45"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <path d="{plate}" fill="url(#vc-plate)" filter="url(#vc-plate-shadow)"/>
  <path d="{plate}" fill="url(#vc-sheen)"/>
  <path d="{squircle(101.5, 101.5, 821, 821, 184)}" fill="none" stroke="url(#vc-rim)" stroke-width="3"/>
  <g filter="url(#vc-glyph-shadow)">
    {glyph(1.0, 512, cy, ' fill="url(#vc-paper)"', ' fill="url(#vc-coral)"')}
  </g>
</svg>
'''


def flat_icon():
    # Windows: a Fluent-style tile filling the canvas (16 px padding at 256), no outer shadow.
    # A tile, because an unpackaged .exe has one icon for light and dark taskbars.
    scale = 0.28
    cy = 127
    y0, y1 = cy - GLYPH_H * scale / 2, cy + GLYPH_H * scale / 2
    return svg_open(256, 256) + f'''  <!-- Windows master (taskbar, Start, Explorer, title bar). Sizes 16 to 48 use hinted/ instead. -->
  <defs>
    {vgrad("vc-tile", 16, 240, GRAPHITE_TOP, "#121317")}
    <linearGradient id="vc-edge" x1="0" y1="16" x2="0" y2="240" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.20"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.06"/></linearGradient>
    {vgrad("vc-paper", y0, y1, PAPER_TOP, PAPER_BOTTOM)}
    {vgrad("vc-coral", y0, y1, CORAL_TOP, CORAL_BOTTOM)}
  </defs>
  {rect(16, 16, 224, 224, 44, ' fill="url(#vc-tile)"')}
  {rect(16.75, 16.75, 222.5, 222.5, 43.25, ' fill="none" stroke="url(#vc-edge)" stroke-width="1.5"')}
  <g>
    {glyph(scale, 128, cy, ' fill="url(#vc-paper)"', ' fill="url(#vc-coral)"')}
  </g>
</svg>
'''


def hinted(spec):
    size = spec["size"]
    x, y, s, r = spec["plate"]
    shape = (f'<path d="{squircle(x, y, s, s, r)}" fill="url(#vc-plate)"/>' if spec["shape"] == "squircle"
             else rect(x, y, s, s, r, ' fill="url(#vc-plate)"'))
    parts = [rect(x0, y0, x1 - x0, y1 - y0, (x1 - x0) / 2, f' fill="{PAPER}"') for x0, x1, y0, y1 in spec["bars"]]
    x0, x1, y0, y1 = spec["seam"]
    parts.append(rect(x0, y0, x1 - x0, y1 - y0, (x1 - x0) / 2, f' fill="{CORAL}"'))
    platform = "macOS" if spec["shape"] == "squircle" else "Windows"
    body = "\n  ".join(parts)
    return svg_open(size, size) + f'''  <!-- {platform} {size} px, hinted to the pixel grid. Render at exactly {size} px. -->
  <defs>{vgrad("vc-plate", y, y + s, SMALL_TOP, SMALL_BOTTOM)}</defs>
  {shape}
  {body}
</svg>
'''


def mark_rects(unit, ox, oy, bar_attr, seam_attr, indent="  "):
    """The line mark, scaled from grid units, with its top-left grid corner at (ox, oy)."""
    out = []
    for (x0, x1, y0, y1), attr in [(b, bar_attr) for b in MARK_BARS] + [(MARK_SEAM, seam_attr)]:
        w = (x1 - x0) * unit
        out.append(rect(ox + x0 * unit, oy + y0 * unit, w, (y1 - y0) * unit, w / 2, attr))
    return ("\n" + indent).join(out)


def mark():
    # viewBox in grid units; the default size is 4x (60 x 64 px), which stays on whole pixels.
    head = svg_open(MARK_W, MARK_H, extra=' fill="currentColor"').replace(
        f'width="{MARK_W}" height="{MARK_H}"', f'width="{MARK_W * 4}" height="{MARK_H * 4}"')
    return head + f'''  <!-- Monochrome mark: one colour (currentColor, black when used as an image). The seam is told
       apart by shape alone: thinner and taller than the bars. Drawn on a 15 x 16 grid: render it
       16, 32, 48 or 64 px tall for whole-pixel edges. -->
  {mark_rects(1, 0, 0, "", "")}
</svg>
'''


def icon_composer_layer(which):
    # Icon Composer draws the plate itself on a full-bleed 1024 canvas, so the glyph is scaled by 1024/824.
    scale = 1024 / 824
    cy = (508 - 100) * scale
    if which == "bars":
        body = "\n  ".join(glyph(scale, 512, cy, f' fill="{PAPER}"', "", indent="  ").split("\n  ")[:-1])
    else:
        x, w, h = SEAM
        body = rect(512 - w * scale / 2, cy - h * scale / 2, w * scale, h * scale, w * scale / 2, f' fill="{CORAL}"')
    return svg_open(1024, 1024, label=f"VoxClip icon layer: {which}") + f"  {body}\n</svg>\n"


def write_svgs():
    (BRAND / "hinted").mkdir(parents=True, exist_ok=True)
    (BRAND / "icon-composer").mkdir(parents=True, exist_ok=True)
    files = {
        "voxclip-icon.svg": mac_icon(),
        "voxclip-icon-flat.svg": flat_icon(),
        "voxclip-mark.svg": mark(),
        "icon-composer/bars.svg": icon_composer_layer("bars"),
        "icon-composer/seam.svg": icon_composer_layer("seam"),
    }
    files.update({f"hinted/{n}": hinted(s) for n, s in HINTED.items()})
    for rel, text in files.items():
        (BRAND / rel).write_text(text)
        print("wrote", (BRAND / rel).relative_to(REPO))


# Wordmark: the mark plus "voxclip." outlined from DM Sans (OFL), set like VoxConvo's lockup
# (lowercase, heavier "vox", tracking -0.048 em, trailing period).
def write_wordmark():
    import uharfbuzz as hb
    from fontTools.pens.boundsPen import BoundsPen
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen

    size, tracking = 100.0, -0.048
    # The seam is 0.9 em tall and the mark is centred on half the cap height; its bars then match the
    # stem weight of DM Sans Bold.
    unit = 0.9 * size / (MARK_SEAM[3] - MARK_SEAM[2])
    gap, mark_mid = 0.36 * size, 0.35 * size

    def outline(text, font_file, x):
        face = hb.Face(hb.Blob.from_file_path(str(font_file)))
        font = hb.Font(face)
        k = size / face.upem
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(font, buf, {"kern": True, "liga": True})
        cmds, bounds = [], BoundsPen(None)
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            t = (k, 0, 0, -k, x + pos.x_offset * k, -pos.y_offset * k)  # baseline at y = 0, y down
            pen = SVGPathPen(None, ntos=num)
            font.draw_glyph_with_pen(info.codepoint, TransformPen(pen, t))
            font.draw_glyph_with_pen(info.codepoint, TransformPen(bounds, t))
            cmds.append(pen.getCommands())
            x += pos.x_advance * k + tracking * size
        return " ".join(c for c in cmds if c), x, bounds.bounds

    mark_w, mark_top = MARK_W * unit, -mark_mid - MARK_H * unit / 2
    vox, x, b1 = outline("vox", DM_SANS / "DMSans-Bold.ttf", mark_w + gap)
    clip, x, b2 = outline("clip.", DM_SANS / "DMSans-Medium.ttf", x)
    # BoundsPen saw the flipped (y-down) coordinates, so bounds are (xmin, ymin, xmax, ymax) on screen.
    top = min(b1[1], b2[1], mark_top + MARK_SEAM[2] * unit)
    bottom = max(b1[3], b2[3], mark_top + MARK_SEAM[3] * unit)
    width, height = max(b1[2], b2[2]), bottom - top
    g = mark_rects(unit, 0, mark_top, ' class="vc-ink"', ' class="vc-cut"', indent="    ")
    svg = svg_open(width, height) + f'''  <!-- Wordmark: mark + "voxclip." in DM Sans Bold / Medium (SIL OFL 1.1), outlined. Ink on light
       backgrounds, paper on dark (prefers-color-scheme). For a fixed colour, edit the two classes. -->
  <style>.vc-ink{{fill:{INK}}}.vc-cut{{fill:{CUT_ON_LIGHT}}}@media (prefers-color-scheme:dark){{.vc-ink{{fill:{PAPER}}}.vc-cut{{fill:{CORAL}}}}}</style>
  <g transform="translate(0 {num(-top)})">
    {g}
    <path class="vc-ink" d="{vox}"/>
    <path class="vc-ink" d="{clip}"/>
  </g>
</svg>
'''
    (BRAND / "voxclip-wordmark.svg").write_text(svg)
    print("wrote", (BRAND / "voxclip-wordmark.svg").relative_to(REPO), f"({num(width)} x {num(height)})")


# Rendering
def renderer():
    if shutil.which("rsvg-convert"):
        return lambda svg, px, out: ["rsvg-convert", "-w", str(px), "-h", str(px), str(svg), "-o", str(out)]
    if shutil.which("magick"):
        return lambda svg, px, out: ["magick", "-background", "none", "-density", "1200", str(svg),
                                     "-resize", f"{px}x{px}", str(out)]
    sys.exit("Need rsvg-convert (librsvg) or ImageMagick to render SVG.")


def render_png(cmd, src, px, out):
    from PIL import Image

    subprocess.run(cmd(BRAND / src, px, out), check=True)
    with Image.open(out) as im:
        if im.size != (px, px) or im.mode != "RGBA":
            sys.exit(f"{out}: expected {px}x{px} RGBA, got {im.size} {im.mode}")


def write_ico(path, pngs):
    """ICO with 32-bit BMP entries below 256 px and a PNG entry at 256 px (the Windows SDK layout)."""
    from PIL import Image

    entries = []
    for px, png in sorted(pngs.items()):
        if px >= 256:
            data = png.read_bytes()
        else:
            im = Image.open(png).convert("RGBA")
            w, h = im.size
            rows = im.tobytes("raw", "BGRA")
            xor = b"".join(rows[(h - 1 - r) * w * 4:(h - r) * w * 4] for r in range(h))  # bottom-up
            stride = ((w + 31) // 32) * 4
            alpha = im.getchannel("A").tobytes()
            mask = bytearray()
            for r in range(h - 1, -1, -1):
                row = bytearray(stride)
                for c in range(w):
                    if alpha[r * w + c] == 0:
                        row[c // 8] |= 0x80 >> (c % 8)
                mask += row
            header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(xor) + len(mask), 0, 0, 0, 0)
            data = header + xor + bytes(mask)
        entries.append((px, data))
    out = io.BytesIO()
    out.write(struct.pack("<HHH", 0, 1, len(entries)))
    offset = 6 + 16 * len(entries)
    for px, data in entries:
        d = 0 if px >= 256 else px
        out.write(struct.pack("<BBBBHHII", d, d, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    for _, data in entries:
        out.write(data)
    path.write_bytes(out.getvalue())


def render():
    from PIL import Image

    cmd = renderer()
    iconset = BRAND / "macos" / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)
    for name, (src, px) in MAC_ICONSET.items():
        render_png(cmd, src, px, iconset / name)
    print("rendered", iconset.relative_to(REPO), f"({len(MAC_ICONSET)} PNGs)")
    if shutil.which("iconutil"):
        icns = BRAND / "macos" / "AppIcon.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
        print("built", icns.relative_to(REPO))
    else:
        print("iconutil not found (macOS only): AppIcon.icns not rebuilt")

    win = BRAND / "windows"
    win.mkdir(parents=True, exist_ok=True)
    pngs = {}
    for px, src in WIN_SIZES.items():
        pngs[px] = win / f"app-{px}.png"
        render_png(cmd, src, px, pngs[px])
    ico = win / "app.ico"
    write_ico(ico, pngs)
    with Image.open(ico) as im:
        found = sorted(s[0] for s in im.info["sizes"])
        if found != sorted(WIN_SIZES):
            sys.exit(f"{ico}: sizes {found}, expected {sorted(WIN_SIZES)}")
        for px in WIN_SIZES:  # every entry must be the hinted render, not a rescale
            with Image.open(pngs[px]) as ref:
                if im.ico.getimage((px, px)).convert("RGBA").tobytes() != ref.convert("RGBA").tobytes():
                    sys.exit(f"{ico}: entry {px} differs from {pngs[px].name}")
    print("built", ico.relative_to(REPO), "sizes", found)


def main(argv):
    step = argv[1] if len(argv) > 1 else "all"
    if step not in ("svg", "wordmark", "render", "all"):
        sys.exit(__doc__)
    if step in ("svg", "all"):
        write_svgs()
    if step in ("wordmark", "all"):
        write_wordmark()
    if step in ("render", "all"):
        render()


if __name__ == "__main__":
    main(sys.argv)
