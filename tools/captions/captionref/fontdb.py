"""Font access for the reference: metrics from fonts.json, coverage from the cmap, shaping with HarfBuzz.

Shaping follows spec section 4.3: one HarfBuzz buffer per run, scale = unitsPerEm (integer
design units), direction LTR, script guessed from the text, language = the transcript language,
features kern/liga/calt as the style says. Cluster values are scalar indices (add_codepoints).
"""
import os

import uharfbuzz as hb
from fontTools.ttLib import TTFont

from .util import FONTS, load_json


class Font:
    def __init__(self, entry):
        self.entry = entry
        self.file = entry["file"]
        self.path = os.path.join(FONTS, entry["path"])
        self.upem = entry["unitsPerEm"]
        self.cap_height = entry["capHeight"]
        self.space_advance = entry["spaceAdvance"]
        self.weight = entry["weight"]
        self._cmap = None
        self._hb = None

    @property
    def cmap(self):
        if self._cmap is None:
            self._cmap = set(TTFont(self.path).getBestCmap().keys())
            covered = set()
            for a, b in self.entry["coverage"]:
                covered.update(range(a, b + 1))
            if covered != self._cmap:
                raise SystemExit("fonts.json coverage is stale for " + self.file)
        return self._cmap

    def covers(self, cp):
        return cp in self.cmap

    def shape(self, codepoints, features, language):
        if self._hb is None:
            blob = hb.Blob.from_file_path(self.path)
            face = hb.Face(blob)
            font = hb.Font(face)
            font.scale = (self.upem, self.upem)
            self._hb = font
        buf = hb.Buffer()
        buf.add_codepoints(codepoints)
        buf.direction = "ltr"
        if language:
            buf.language = language
        buf.guess_segment_properties()
        hb.shape(self._hb, buf, {"kern": features["kern"], "liga": features["liga"], "calt": features["calt"]})
        out = []
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            out.append({"gid": info.codepoint, "cluster": info.cluster, "advance": pos.x_advance,
                        "dx": pos.x_offset, "dy": pos.y_offset})
        return out


class FontDB:
    def __init__(self):
        self.manifest = load_json(os.path.join(FONTS, "fonts.json"))
        self.fonts = {e["file"]: Font(e) for e in self.manifest["fonts"]}
        self.fallbacks = [(f["weight"], f["file"]) for f in self.manifest["fallback"]["files"]]
        self.emoji = {e["codepoints"]: e for e in self.manifest["emoji"]["images"]}

    def get(self, file):
        if file not in self.fonts:
            raise SystemExit("font not in shared/fonts/fonts.json: " + file)
        return self.fonts[file]

    def noto_for(self, weight):
        """Nearest weight; ties go to the heavier file (spec 4.4)."""
        best = None
        for w, f in self.fallbacks:
            d = abs(w - weight)
            if best is None or d < best[0] or (d == best[0] and w > best[1]):
                best = (d, w, f)
        return best[2]
