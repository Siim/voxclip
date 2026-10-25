"""Caption track construction: spec sections 4 (measurement), 6 (paging and line breaking),
7 (placement) and 8 (page timing). All fit decisions are integer comparisons."""
import itertools
import math
import os

from . import text as tx
from .style import color, resolve
from .util import STYLES, clamp, load_json, round_half_up

SAFE_INSETS = {  # left, right, top, bottom as fractions of W and H (spec 5.2)
    "portrait": (0.06, 0.06, 0.06, 0.10),
    "square": (0.05, 0.05, 0.05, 0.07),
    "landscape": (0.05, 0.05, 0.05, 0.07),
}


class Lexicon:
    def __init__(self):
        self.stopwords = {k: set(v) for k, v in load_json(os.path.join(STYLES, "stopwords.json"))["languages"].items()}
        self.emoji = load_json(os.path.join(STYLES, "emoji-keywords.json"))["languages"]

    def is_stopword(self, key, lang):
        return key in self.stopwords.get(lang, set())

    def emoji_for(self, key, lang):
        table = self.emoji.get(lang)
        if not table or not key:
            return None
        if key in table:
            return table[key]
        best = None
        for k, v in table.items():
            if k.endswith("*"):
                prefix = k[:-1]
                if len(prefix) >= 3 and key.startswith(prefix):
                    if best is None or len(prefix) > len(best[0]) or (len(prefix) == len(best[0]) and prefix < best[0]):
                        best = (prefix, v)
        return best[1] if best else None


def measure(text, file, st, fontdb, lang, scale):
    """Spec 4.2-4.5: font cascade per grapheme cluster, per-run shaping, width in layout units."""
    ref = fontdb.get(st["font"]["file"])
    primary = fontdb.get(file)
    cascade = [file] + list(st["font"]["fallbackFiles"]) + [fontdb.noto_for(primary.weight)]
    runs, dropped = [], []
    kept = []
    for cl in tx.graphemes(text):
        cps = [ord(c) for c in cl]
        core = [c for c in cps if c not in tx.IGNORABLE]
        if not core:
            dropped.append(cl)
            continue
        chosen = next((f for f in cascade if all(fontdb.get(f).covers(c) for c in core)), None)
        if chosen is None:
            chosen = next((f for f in cascade if fontdb.get(f).covers(core[0])), None)
        if chosen is None:
            dropped.append(cl)
            continue
        font = fontdb.get(chosen)
        cps = [c for c in cps if c in tx.IGNORABLE or font.covers(c)]
        k = len(kept)
        kept.append("".join(chr(c) for c in cps))
        if runs and runs[-1]["file"] == chosen:
            runs[-1]["cps"].extend(cps)
            runs[-1]["clusterOf"].extend([k] * len(cps))
        else:
            runs.append({"file": chosen, "cps": list(cps), "clusterOf": [k] * len(cps)})
    if not runs:
        return None
    features = st["font"]["features"]
    total, glyph_count = 0, 0
    out_runs = []
    for run in runs:
        font = fontdb.get(run["file"])
        glyphs = font.shape(run["cps"], features, lang)
        s = sum(g["advance"] for g in glyphs)
        if font.upem == ref.upem:
            lu = s
        else:
            lu = (2 * s * ref.upem + font.upem) // (2 * font.upem)
        total += lu
        glyph_count += len(glyphs)
        out_runs.append({
            "file": run["file"],
            "text": "".join(chr(c) for c in run["cps"]),
            "glyphs": [g["gid"] for g in glyphs],
            "advances": [g["advance"] for g in glyphs],
            "offsets": [[g["dx"], g["dy"]] for g in glyphs],
            "clusters": [run["clusterOf"][g["cluster"]] for g in glyphs],
            "units": lu,
        })
    ls = round_half_up(st["font"]["letterSpacingEm"] * ref.upem)
    base = total + (glyph_count - 1) * ls
    units = base if scale == 1 else round_half_up(base * scale)
    return {"text": "".join(kept), "clusters": len(kept), "runs": out_runs, "units": units,
            "baseUnits": base, "scale": scale, "dropped": dropped}


def emphasis_points(display, lang, lex):
    cps = [ord(c) for c in display]
    letters = sum(1 for c in cps if tx.category(c)[0] in "LN")
    has_digit = any(tx.category(c) == "Nd" for c in cps)
    content = not lex.is_stopword(tx.matching_key(display, lang), lang)
    return 300 * has_digit + 100 * (letters >= 6) + 100 * content + min(letters, 99)


class Fit:
    def __init__(self, f64, limit64, upem):
        self.f64, self.limit64, self.upem = f64, limit64, upem

    def __call__(self, units):
        return units * self.f64 <= self.limit64 * self.upem


def line_units(widths, gap, idxs):
    return sum(widths[i] for i in idxs) + gap * (len(idxs) - 1)


def break_lines(widths, gap, fits, balance):
    """Spec 6.3. widths: list of layout-unit widths for the page's words (page-local order)."""
    n = len(widths)
    lines, cur = [[0]], widths[0]
    for i in range(1, n):
        if fits(cur + gap + widths[i]):
            lines[-1].append(i)
            cur += gap + widths[i]
        else:
            lines.append([i])
            cur = widths[i]
    count = len(lines)
    if balance == "balanced" and 2 <= count <= 3 and all(fits(line_units(widths, gap, l)) for l in lines):
        best = None
        for breaks in itertools.combinations(range(1, n), count - 1):
            bounds = (0,) + breaks + (n,)
            parts = [list(range(bounds[j], bounds[j + 1])) for j in range(count)]
            us = [line_units(widths, gap, p) for p in parts]
            if not all(fits(u) for u in us):
                continue
            key = (max(us), breaks)
            if best is None or key < best[0]:
                best = (key, parts)
        lines = best[1]
    return lines


def rounded_radius(box, w, h, fp):
    if box.get("pill"):
        return h / 2
    return min(box["radiusEm"] * fp, w / 2, h / 2)


def build_track(style, captions, width, height, words_in, lang, duration, fontdb, lex):
    """style: the style file as loaded; captions: {overrides, position, positionByAspect} from the project."""
    st = resolve(style, captions, width, height)
    cls = st["_aspect"]
    ref = fontdb.get(st["font"]["file"])
    upem = ref.upem

    # 5.3 font size in 1/64 px, 5.2 safe area, 5.4 line limit
    sref = st["font"]["sizeRef"]
    R = min(width, height) if sref == "shortEdge" else (height if sref == "height" else width)
    f64 = max(1, round_half_up(st["font"]["sizeSh"] * R * st["_sizeScale"] * 64))
    F = f64 / 64.0

    left, right, top, bottom = SAFE_INSETS[cls]
    safe = (width * left, width * (1 - right), height * top, height * (1 - bottom))
    box = st.get("box")
    pad_x0 = box["paddingXEm"] * F if box and box["scope"] in ("page", "line") else 0.0
    limit_px = min(st["layout"]["maxLineWidthW"] * width, (safe[1] - safe[0]) - 2 * pad_x0)
    limit64 = math.floor(limit_px * 64)
    fits = Fit(f64, limit64, upem)

    if "wordSpacingEm" in st["font"]:
        gap = round_half_up(st["font"]["wordSpacingEm"] * upem)
    else:
        gap = ref.space_advance + round_half_up(st["font"]["letterSpacingEm"] * upem)

    emph = st["emphasis"]
    emph_on = emph["source"] in ("rule", "llm", "manual")
    min_points = round_half_up(emph["minScore"] * 100)
    tr, punct = st["text"]["transform"], st["text"]["punctuation"]

    # 3 + 4: normalise and measure
    words, dropped = [], []
    for si, w in enumerate(words_in):
        display = tx.normalize(w["text"], punct, tr, lang)
        m = measure(display, st["font"]["file"], st, fontdb, lang, 1) if display else None
        if m is None:
            dropped.append({"sourceIndex": si, "text": w["text"], "reason": "empty" if not display else "no-glyphs"})
            continue
        manual = w.get("emphasis")
        pts = emphasis_points(m["text"], lang, lex)
        candidate = False
        if emph_on:
            if manual is True:
                candidate = True
            elif manual is None and emph["source"] in ("rule", "llm") and pts >= min_points:
                candidate = True
        me = None
        if candidate:
            me = measure(m["text"], emph.get("fontFile", st["font"]["file"]), st, fontdb, lang, emph["scale"])
        words.append({"sourceIndex": si, "id": w.get("id"), "raw": w["text"], "start": w["start"], "end": w["end"],
                      "m": m, "me": me, "points": pts, "candidate": candidate, "manual": manual,
                      "manualEmoji": w.get("emoji")})

    def paging_width(w):
        return max(w["m"]["units"], w["me"]["units"]) if w["me"] else w["m"]["units"]

    lay = st["layout"]

    def page_fits(idxs):
        ws = [paging_width(words[i]) for i in idxs]
        lines = break_lines(ws, gap, fits, lay["balance"])
        if len(lines) > lay["maxLines"]:
            return False
        return len(idxs) == 1 or all(fits(line_units(ws, gap, l)) for l in lines)

    # 6.1 paging
    pages, cur = [], []
    for i, w in enumerate(words):
        if cur:
            prev, first = words[cur[-1]], words[cur[0]]
            brk = (len(cur) >= lay["maxWords"]
                   or (lay["breakOnSentence"] and tx.ends_sentence(prev["raw"]))
                   or (lay["breakOnComma"] and len(cur) >= 2 and tx.ends_clause(prev["raw"]))
                   or (lay["breakOnGapSec"] is not None and w["start"] - prev["end"] >= lay["breakOnGapSec"])
                   or (lay["maxPageSec"] is not None and w["end"] - first["start"] > lay["maxPageSec"])
                   or not page_fits(cur + [i]))
            if brk:
                pages.append(cur)
                cur = []
        cur.append(i)
    if cur:
        pages.append(cur)

    # 9.1 emphasis selection, 9.2 emoji selection
    palette_i = 0
    emo = st["emoji"]
    prev_emoji = None
    out_pages = []
    for pi, idxs in enumerate(pages):
        chosen = []
        if emph_on:
            manual = [i for i in idxs if words[i]["manual"] is True]
            rule = sorted([i for i in idxs if words[i]["candidate"] and words[i]["manual"] is None],
                          key=lambda i: (-words[i]["points"], i))
            chosen = manual + rule[:max(0, emph["maxPerPage"] - len(manual))]
            chosen.sort()
        emph_words = {}
        for i in chosen:
            if "palette" in emph:
                emph_words[i] = emph["palette"][palette_i % len(emph["palette"])]
                palette_i += 1
            else:
                emph_words[i] = None
        emoji = None
        if emo["enabled"]:
            for i in idxs:
                if words[i]["manualEmoji"]:
                    emoji = (i, words[i]["manualEmoji"])
                    break
            if emoji is None and emo["maxPerPage"] >= 1 and emo["source"] in ("rule", "llm"):
                for i in idxs:
                    cp = lex.emoji_for(tx.matching_key(words[i]["m"]["text"], lang), lang)
                    if cp and cp != prev_emoji:
                        emoji = (i, cp)
                        break
        prev_emoji = emoji[1] if emoji else None
        out_pages.append({"idxs": idxs, "emph": emph_words, "emoji": emoji})

    # 8 page timing
    for pi, p in enumerate(out_pages):
        first, last = words[p["idxs"][0]], words[p["idxs"][-1]]
        nxt = words[out_pages[pi + 1]["idxs"][0]]["start"] if pi + 1 < len(out_pages) else None
        start = first["start"]
        end = last["end"] + lay["holdGapSec"]
        if nxt is not None:
            end = min(end, nxt)
        if end - start < lay["minPageSec"]:
            end = start + lay["minPageSec"]
            if nxt is not None:
                end = min(end, nxt)
        if duration is not None:
            end = min(end, duration)
        p["start"], p["end"] = start, end

    # 6.3 + 6.4 + 7 placement
    for p in out_pages:
        idxs = p["idxs"]
        units = [(words[i]["me"] if i in p["emph"] else words[i]["m"])["units"] for i in idxs]
        lines = break_lines(units, gap, fits, lay["balance"])
        fp64 = f64
        shrunk = False
        if len(idxs) == 1 and not fits(units[0]):
            fp64 = max(math.ceil(f64 * lay["minShrink"]), min(f64, (limit64 * upem) // units[0]))
            shrunk = True
        p.update(place(st, p, words, idxs, units, lines, gap, fp64, width, height, safe, ref))
        p["fontPx64"], p["shrunk"] = fp64, shrunk

    return {"style": st, "aspect": cls, "f64": f64, "limit64": limit64, "limitPx": limit_px, "safe": safe,
            "gap": gap, "upem": upem, "words": words, "dropped": dropped, "pages": out_pages, "duration": duration}


def place(st, p, words, idxs, units, lines, gap, fp64, width, height, safe, ref):
    fp = fp64 / 64.0
    upem = ref.upem

    def px(u):
        return u * fp / upem

    box = st.get("box")
    pad_x = pad_y = 0.0
    if box and box["scope"] in ("page", "line"):
        pad_x, pad_y = box["paddingXEm"] * fp, box["paddingYEm"] * fp
    line_units_list = [line_units(units, gap, l) for l in lines]
    line_w = [px(u) for u in line_units_list]
    block_w = max(line_w)
    L = st["font"]["lineHeightEm"] * fp
    pitch = L + st["layout"]["lineGapEm"] * fp
    block_h = L + (len(lines) - 1) * pitch
    vw, vh = block_w + 2 * pad_x, block_h + 2 * pad_y
    pos = st["position"]
    ax, ay = pos["x"] * width, pos["y"] * height
    vx = {"center": ax - vw / 2, "left": ax, "right": ax - vw}[pos["anchorX"]]
    vy = {"center": ay - vh / 2, "top": ay, "bottom": ay - vh}[pos["anchorY"]]

    emo = st["emoji"]
    e_size = round_half_up(emo["sizeEm"] * fp) if p["emoji"] else 0
    ux0, uy0, ux1, uy1 = vx, vy, vx + vw, vy + vh
    if p["emoji"]:
        ex = vx + vw / 2 - e_size / 2
        ey = vy - emo["gapEm"] * fp - e_size
        ux0, uy0, ux1 = min(ux0, ex), min(uy0, ey), max(ux1, ex + e_size)

    def shift(lo, hi, s_lo, s_hi):
        if hi - lo > s_hi - s_lo:
            return (s_lo + s_hi) / 2 - (lo + hi) / 2
        if lo < s_lo:
            return s_lo - lo
        if hi > s_hi:
            return s_hi - hi
        return 0.0

    dx = shift(ux0, ux1, safe[0], safe[1])
    dy = shift(uy0, uy1, safe[2], safe[3])
    bx = round_half_up(vx + dx + pad_x)
    by = round_half_up(vy + dy + pad_y)
    cap = ref.cap_height / upem * fp

    out_lines, word_rects = [], []
    align = st["layout"]["align"]
    for li, l in enumerate(lines):
        top = by + li * pitch
        baseline = top + L / 2 + cap / 2
        lw = line_w[li]
        lx = {"center": bx + (block_w - lw) / 2, "left": bx, "right": bx + block_w - lw}[align]
        prefix = 0
        for k, local in enumerate(l):
            wx = lx + px(prefix)
            ww = px(units[local])
            word_rects.append({"word": idxs[local], "line": li, "x": wx, "y": top, "w": ww, "h": L,
                               "baseline": baseline, "cx": wx + ww / 2, "cy": baseline - cap / 2})
            prefix += units[local] + gap
        out_lines.append({"words": [idxs[i] for i in l], "units": line_units_list[li], "x": lx, "top": top,
                          "baseline": baseline, "width": lw})

    visual = {"x": bx - pad_x, "y": by - pad_y, "w": vw, "h": vh}
    boxes = []
    if box and box["scope"] == "page":
        boxes.append({"kind": "page", **visual, "r": rounded_radius(box, vw, vh, fp)})
    if box and box["scope"] == "line":
        for ln in out_lines:
            w, h = ln["width"] + 2 * pad_x, L + 2 * pad_y
            boxes.append({"kind": "line", "x": ln["x"] - pad_x, "y": ln["top"] - pad_y, "w": w, "h": h,
                          "r": rounded_radius(box, w, h, fp)})
    if box and box["scope"] == "word":
        for r in word_rects:
            w, h = r["w"] + 2 * box["paddingXEm"] * fp, L + 2 * box["paddingYEm"] * fp
            boxes.append({"kind": "word", "word": r["word"], "x": r["x"] - box["paddingXEm"] * fp,
                          "y": r["y"] - box["paddingYEm"] * fp, "w": w, "h": h, "r": rounded_radius(box, w, h, fp)})
    emoji = None
    if p["emoji"]:
        ex = round_half_up(bx - pad_x + vw / 2 - e_size / 2)
        ey = round_half_up(by - pad_y - emo["gapEm"] * fp - e_size)
        emoji = {"word": p["emoji"][0], "codepoints": p["emoji"][1], "x": ex, "y": ey, "size": e_size}
    return {"lines": out_lines, "wordRects": word_rects, "block": {"x": bx, "y": by, "w": block_w, "h": block_h},
            "visual": visual, "boxes": boxes, "emojiRect": emoji, "lineHeight": L, "pitch": pitch, "cap": cap,
            "anchorPoint": (ax, ay), "clampShift": (dx, dy)}


def resolve_fill(st, state, emphasised_color, is_emph):
    """Spec 10.3 precedence: emphasis > word state > base fill. Returns a description string."""
    paint = st["fill"]
    src = "base"
    sp = st["words"].get(state, {}).get("fill")
    if sp is not None:
        paint, src = sp, state
    if is_emph:
        e = st["emphasis"]
        if emphasised_color is not None:
            paint, src = {"type": "solid", "color": emphasised_color}, "emphasis"
        elif "fill" in e:
            paint, src = e["fill"], "emphasis"
    if paint["type"] == "solid":
        r, g, b, a = color(st, paint["color"])
        return src, "#%02X%02X%02X%02X" % (r, g, b, a)
    return src, "linear"
