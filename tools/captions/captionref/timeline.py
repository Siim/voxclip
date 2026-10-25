"""Time-dependent state (spec sections 8, 10 and 11): everything is a pure function of t."""
import math

from .layout import resolve_fill
from .util import clamp, round_half_up

M32 = 0xFFFFFFFF


def imul(a, b):
    return (a * b) & M32


def mulberry32(seed):
    """Spec 11.4. Unsigned 32-bit arithmetic; returns a generator of doubles in [0, 1)."""
    state = seed & M32
    while True:
        state = (state + 0x6D2B79F5) & M32
        t = state
        t = imul(t ^ (t >> 15), t | 1)
        t = ((t + imul(t ^ (t >> 7), t | 61)) & M32) ^ t
        yield ((t ^ (t >> 14)) & M32) / 4294967296.0


def ease(name, p, overshoot=1.70158):
    # Spec 11.2: evaluate on p clamped to [0, 1], exactly 0 at p = 0 and exactly 1 at p = 1.
    p = clamp(p, 0.0, 1.0)
    if p == 0.0:
        return 0.0
    if p == 1.0:
        return 1.0
    if name == "linear":
        return p
    if name == "easeOutCubic":
        return 1 - (1 - p) ** 3
    if name == "easeInOutCubic":
        return 4 * p ** 3 if p < 0.5 else 1 - (-2 * p + 2) ** 3 / 2
    if name == "easeOutBack":
        c1 = overshoot
        return 1 + (c1 + 1) * (p - 1) ** 3 + c1 * (p - 1) ** 2
    raise ValueError(name)


def progress(t, t0, d):
    if d <= 0:
        return 1.0
    return clamp((t - t0) / d, 0.0, 1.0)


def anim_in(a, t, t0, fp, target=1.0, reduced=False):
    """Returns (scale, alpha, dy) for an entrance animation (spec 11.2)."""
    if a is None or a["type"] == "none":
        return target, 1.0, 0.0
    p = 1.0 if reduced else progress(t, t0, a["durationSec"])
    e = ease(a["easing"], p, a["overshoot"])
    k = a["type"]
    s0 = a["fromScale"]
    if k == "fade":
        return target, clamp(e, 0.0, 1.0), 0.0
    if k == "pop":
        return s0 + (target - s0) * e, 1.0, 0.0
    if k == "zoom":
        return s0 + (target - s0) * e, clamp(e, 0.0, 1.0), 0.0
    if k == "slide-up":
        return target, clamp(e, 0.0, 1.0), a["fromOffsetEm"] * fp * (1 - e)
    raise ValueError(k)


def anim_out(a, t, end, fp, reduced=False):
    if a is None or a["type"] == "none" or reduced:
        return 1.0, 1.0, 0.0
    d = a["durationSec"]
    e = ease(a["easing"], progress(t, end - d, d), a["overshoot"])
    k = a["type"]
    s0 = a["fromScale"]
    if k == "fade":
        return 1.0, clamp(1 - e, 0.0, 1.0), 0.0
    if k == "pop":
        return 1 + (s0 - 1) * e, 1.0, 0.0
    if k == "zoom":
        return 1 + (s0 - 1) * e, clamp(1 - e, 0.0, 1.0), 0.0
    if k == "slide-up":
        return 1.0, clamp(1 - e, 0.0, 1.0), -a["fromOffsetEm"] * fp * e
    raise ValueError(k)


def page_at(track, t):
    for i, p in enumerate(track["pages"]):
        if p["start"] <= t < p["end"]:
            return i
    return None


def typed_clusters(w, t, cps):
    """Spec 10.5: cluster k of n appears at start + (k/n) * min(end - start, n / cps)."""
    n = w["m"]["clusters"]
    dur = min(w["end"] - w["start"], n / cps)
    count = 0
    for k in range(n):
        if t >= w["start"] + (k / n) * dur:
            count = k + 1
    return count, dur


def advance_px_of_clusters(m, count, fp, upem_ref, fontdb, ls_units):
    """Pen position after the last glyph of the first `count` clusters, in px at scale 1."""
    pen = 0.0
    glyphs = []
    for run in m["runs"]:
        f = fontdb.get(run["file"])
        for adv, cl in zip(run["advances"], run["clusters"]):
            glyphs.append((adv * fp / f.upem, cl))
    last = None
    for gi, (adv, cl) in enumerate(glyphs):
        if cl < count:
            last = gi
    for gi in range(0 if last is None else last + 1):
        pen += glyphs[gi][0]
        if gi < last:
            pen += ls_units * fp / upem_ref
    return pen


def evaluate(track, t, fontdb, reduced=False):
    st = track["style"]
    pi = page_at(track, t)
    if pi is None:
        return {"t": t, "page": None}
    p = track["pages"][pi]
    fp = p["fontPx64"] / 64.0
    words = track["words"]
    idxs = p["idxs"]
    active_local = max(k for k, i in enumerate(idxs) if words[i]["start"] <= t)
    anim = st["animation"]
    s_in, a_in, dy_in = anim_in(anim.get("pageIn"), t, p["start"], fp, reduced=reduced)
    s_out, a_out, dy_out = anim_out(anim.get("pageOut"), t, p["end"], fp, reduced=reduced)
    jitter = [0.0, 0.0]
    jit = st["effects"].get("jitter")
    if jit and not reduced:
        k = math.floor(t * jit["rateHz"] + 1e-6)
        r = mulberry32((jit["seed"] ^ k) & M32)
        jitter = [(next(r) * 2 - 1) * jit["amplitudeEm"] * fp, (next(r) * 2 - 1) * jit["amplitudeEm"] * fp]
    reveal = st["reveal"]["unit"]
    out_words = []
    cursor = None
    for k, i in enumerate(idxs):
        w = words[i]
        state = "past" if k < active_local else ("active" if k == active_local else "future")
        ws = st["words"].get(state, {})
        base_scale = ws.get("scale", 1.0)
        w_s, w_a, w_dy = (1.0, 1.0, 0.0) if state == "future" else anim_in(anim.get("wordIn"), t, w["start"], fp, reduced=reduced)
        if state == "active":
            a_s, a_a, a_dy = anim_in(anim.get("activeIn"), t, w["start"], fp, target=base_scale, reduced=reduced)
        else:
            a_s, a_a, a_dy = base_scale, 1.0, 0.0
        scale = a_s * w_s
        opacity = ws.get("opacity", 1.0) * w_a * a_a
        dy = w_dy + a_dy
        visible = True
        if reveal in ("word", "char") and state == "future":
            visible = False
        entry = {"word": i, "state": state, "visible": visible, "opacity": opacity, "scale": scale, "dy": dy}
        src, col = resolve_fill(st, state, p["emph"].get(i), i in p["emph"])
        entry["fill"] = col
        entry["fillSource"] = src
        if reveal == "wipe" and state == "active":
            entry["wipe"] = progress(t, w["start"], max(0.001, w["end"] - w["start"]))
            fsrc, fcol = resolve_fill(st, "future", p["emph"].get(i), i in p["emph"])
            entry["wipeFrom"] = fcol
        if reveal == "char":
            if state == "past":
                entry["visibleClusters"] = w["m"]["clusters"]
            elif state == "future":
                entry["visibleClusters"] = 0
            else:
                count, dur = typed_clusters(w, t, st["reveal"]["maxCharsPerSec"])
                entry["visibleClusters"] = count
                cur = st["reveal"].get("cursor")
                if cur:
                    typing_end = w["start"] + dur
                    if t < typing_end or cur["blinkHz"] == 0 or reduced:
                        on = True
                    else:
                        on = math.floor((t - typing_end) * cur["blinkHz"] * 2) % 2 == 0
                    m = w["me"] if i in p["emph"] else w["m"]
                    ls = round_half_up(st["font"]["letterSpacingEm"] * track["upem"])
                    rect = next(r for r in p["wordRects"] if r["word"] == i)
                    pen = advance_px_of_clusters(m, count, fp, track["upem"], fontdb, ls) * m["scale"]
                    cx = rect["x"] + pen + 0.05 * fp
                    cursor = {"visible": on, "word": i, "x": cx, "w": cur["widthEm"] * fp,
                              "y": rect["baseline"] - p["cap"] - 0.1 * fp, "h": p["cap"] + 0.2 * fp}
        out_words.append(entry)
    return {"t": t, "page": pi, "activeWord": idxs[active_local],
            "progress": progress(t, words[idxs[active_local]]["start"],
                                 max(0.001, words[idxs[active_local]]["end"] - words[idxs[active_local]]["start"])),
            "pageAlpha": a_in * a_out, "pageScale": s_in * s_out, "pageDy": dy_in + dy_out,
            "jitter": jitter, "words": out_words, "cursor": cursor}
