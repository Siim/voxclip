#!/usr/bin/env python3
"""Build shared/fonts/fonts.json from the files in shared/fonts.

Run with the venv described in tools/captions/README.md:

    /tmp/voxclip-captions-venv/bin/python -I tools/captions/build_font_manifest.py

The manifest is the only source of font metrics for both apps (doc/spec/captions.md, section 4).
Fonts are read with fontTools only; nothing is modified.
"""
import hashlib
import json
import os
import sys

from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
FONTS = os.path.join(REPO, "shared", "fonts")

# Nominal weights come from the style name in the file name. Some fonts store an unusual
# usWeightClass (JetBrains Mono SemiBold stores 472), so the raw value is kept separately.
WEIGHT_NAMES = [
    ("ExtraLight", 200), ("SemiBold", 600), ("ExtraBold", 800), ("Thin", 100), ("Light", 300),
    ("Medium", 500), ("Bold", 700), ("Black", 900), ("Regular", 400), ("Italic", 400),
]

LICENCES = {
    "OFL.txt": "OFL-1.1",
    "LICENSE": "Apache-2.0",  # only noto-emoji ships a LICENSE file
}

# The fallback cascade (doc/spec/captions.md, section 4.4). Order matters only for documentation;
# the renderer picks the nearest weight.
FALLBACK_FAMILY = "noto-sans"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def nominal_weight(file_name):
    stem = os.path.splitext(file_name)[0]
    style = stem.split("-", 1)[1] if "-" in stem else "Regular"
    for name, weight in WEIGHT_NAMES:
        if style.startswith(name):
            return weight
    raise SystemExit("cannot infer weight from " + file_name)


def ranges(codepoints):
    out = []
    for cp in sorted(codepoints):
        if out and cp == out[-1][1] + 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


def cap_height(font, cmap):
    os2 = font["OS/2"]
    value = getattr(os2, "sCapHeight", 0) if os2.version >= 2 else 0
    if value > 0:
        return value, "OS/2.sCapHeight"
    glyph = cmap.get(ord("H"))
    glyf = font["glyf"]
    g = glyf[glyph]
    g.recalcBounds(glyf)
    return g.yMax, "glyf[H].yMax"


def x_height(font, cmap):
    os2 = font["OS/2"]
    value = getattr(os2, "sxHeight", 0) if os2.version >= 2 else 0
    if value > 0:
        return value
    glyf = font["glyf"]
    g = glyf[cmap.get(ord("x"))]
    g.recalcBounds(glyf)
    return g.yMax


def feature_tags(font, table):
    if table not in font:
        return []
    fl = font[table].table.FeatureList
    return sorted({fr.FeatureTag for fr in fl.FeatureRecord}) if fl else []


def describe_font(folder, file_name, sources):
    path = os.path.join(FONTS, folder, file_name)
    font = TTFont(path)
    cmap = font.getBestCmap()
    name = font["name"]
    os2 = font["OS/2"]
    hhea = font["hhea"]
    head = font["head"]
    cap, cap_source = cap_height(font, cmap)
    space_glyph = cmap.get(0x20)
    rel = folder + "/" + file_name
    src = sources["files"].get(rel)
    if src is None:
        raise SystemExit("no provenance for " + rel)
    lic_file = "OFL.txt"
    if not os.path.exists(os.path.join(FONTS, folder, lic_file)):
        raise SystemExit("missing licence file for " + rel)
    italic = bool(os2.fsSelection & 1) or bool(head.macStyle & 2)
    return {
        "file": file_name,
        "path": rel,
        "family": name.getDebugName(16) or name.getDebugName(1),
        "style": name.getDebugName(17) or name.getDebugName(2),
        "weight": nominal_weight(file_name),
        "usWeightClass": os2.usWeightClass,
        "italic": italic,
        "version": name.getDebugName(5),
        "license": LICENCES[lic_file],
        "licenseFile": folder + "/" + lic_file,
        "copyright": (name.getDebugName(0) or "").strip(),
        "source": src,
        "bytes": os.path.getsize(path),
        "sha256": sha256(path),
        "unitsPerEm": head.unitsPerEm,
        "hhea": {"ascender": hhea.ascent, "descender": hhea.descent, "lineGap": hhea.lineGap},
        "os2": {
            "version": os2.version,
            "typoAscender": os2.sTypoAscender,
            "typoDescender": os2.sTypoDescender,
            "typoLineGap": os2.sTypoLineGap,
            "winAscent": os2.usWinAscent,
            "winDescent": os2.usWinDescent,
            "useTypoMetrics": bool(os2.fsSelection & (1 << 7)),
            "capHeight": getattr(os2, "sCapHeight", None),
            "xHeight": getattr(os2, "sxHeight", None),
        },
        "capHeight": cap,
        "capHeightSource": cap_source,
        "xHeight": x_height(font, cmap),
        "spaceAdvance": font["hmtx"][space_glyph][0],
        "glyphCount": font["maxp"].numGlyphs,
        "tables": sorted(t for t in font.keys() if t in ("GPOS", "GSUB", "kern", "trak", "fvar", "morx", "kerx", "COLR", "sbix", "CBDT")),
        "features": {"GSUB": feature_tags(font, "GSUB"), "GPOS": feature_tags(font, "GPOS")},
        "coverage": ranges(cmap.keys()),
    }


def main():
    with open(os.path.join(HERE, "font-sources.json"), encoding="utf-8") as f:
        sources = json.load(f)
    fonts = []
    for folder in sorted(os.listdir(FONTS)):
        full = os.path.join(FONTS, folder)
        if not os.path.isdir(full) or folder == "noto-emoji":
            continue
        for file_name in sorted(os.listdir(full)):
            if file_name.lower().endswith(".ttf"):
                fonts.append(describe_font(folder, file_name, sources))
    for f in fonts:
        if "trak" in f["tables"] or "fvar" in f["tables"]:
            raise SystemExit(f["file"] + ": trak/fvar tables are not allowed (doc/spec/captions.md 4.1)")
    names = [f["file"] for f in fonts]
    if len(names) != len(set(names)):
        raise SystemExit("font file names must be unique across shared/fonts")

    emoji_dir = os.path.join(FONTS, "noto-emoji", "png128")
    emoji = []
    for file_name in sorted(os.listdir(emoji_dir)):
        if not file_name.endswith(".png"):
            continue
        rel = "noto-emoji/png128/" + file_name
        cps = file_name[len("emoji_u"):-len(".png")]
        emoji.append({
            "codepoints": cps,
            "text": "".join(chr(int(c, 16)) for c in cps.split("_")),
            "path": rel,
            "sha256": sha256(os.path.join(emoji_dir, file_name)),
            "bytes": os.path.getsize(os.path.join(emoji_dir, file_name)),
        })

    fallback = [f for f in fonts if f["path"].startswith(FALLBACK_FAMILY + "/")]
    manifest = {
        "manifestVersion": 1,
        "description": "Bundled caption fonts. Generated by tools/captions/build_font_manifest.py; do not edit by hand. Both apps read vertical metrics, space advance and coverage from this file (doc/spec/captions.md section 4).",
        "fonts": fonts,
        "fallback": {
            "family": "Noto Sans",
            "files": [{"file": f["file"], "weight": f["weight"]} for f in sorted(fallback, key=lambda x: x["weight"])],
            "rule": "nearest weight to the primary font's nominal weight; ties choose the heavier file; italic primaries use the upright file",
        },
        "emoji": {
            "set": "noto-emoji-png",
            "pixelSize": 128,
            "license": "Apache-2.0",
            "licenseFile": "noto-emoji/LICENSE",
            "source": sources["files"]["noto-emoji/LICENSE"],
            "note": sources["notes"]["noto-emoji"],
            "images": emoji,
        },
    }
    out = os.path.join(FONTS, "fonts.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print("wrote", os.path.relpath(out, REPO), len(fonts), "fonts,", len(emoji), "emoji")


if __name__ == "__main__":
    sys.exit(main())
