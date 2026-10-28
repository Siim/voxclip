#!/usr/bin/env python3
"""Generate the caption layout fixtures in shared/fixtures/captions from tools/captions/cases.json.

    /tmp/voxclip-captions-venv/bin/python -I tools/captions/gen_fixtures.py

Outputs (all JSON):
  layout/<case-id>.json      input + expected track (pages, lines, word boxes) + expected samples
  text-normalization.json    normalisation, matching keys, sentence and clause tests
  math.json                  rounding, easing, mulberry32, jitter, blur, rounded-rect and gradient vectors
  preview-tiles.json         the gallery tile state of every style
  index.json                 list of files
Run check_styles.py first. The output is deterministic; re-running must give byte-identical files.
"""
import math
import os
import shutil
import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the source tree
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from captionref import mathref  # noqa: E402
from captionref import text as tx  # noqa: E402
from captionref.contrast import SWATCHES  # noqa: E402
from captionref.fontdb import FontDB  # noqa: E402
from captionref.layout import SAFE_INSETS, Lexicon, build_track  # noqa: E402
from captionref.style import load_style, with_defaults  # noqa: E402
from captionref.timeline import ease, evaluate, mulberry32  # noqa: E402
from captionref.util import FIXTURES, STYLES, load_json, r3, r6, round_half_up, write_json  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FORMAT = "voxclip-caption-layout/1"


def t6(t):
    return float("%.6f" % t)


def rect(d):
    return {k: r3(d[k]) for k in ("x", "y", "w", "h")}


def word_out(w):
    def runs(m):
        return [{"file": r["file"], "text": r["text"], "units": r["units"], "glyphs": r["glyphs"],
                 "advances": r["advances"], "offsets": r["offsets"], "clusters": r["clusters"]} for r in m["runs"]]
    out = {"sourceIndex": w["sourceIndex"], "id": w["id"], "raw": w["raw"], "text": w["m"]["text"],
           "start": w["start"], "end": w["end"], "units": w["m"]["units"], "clusters": w["m"]["clusters"],
           "runs": runs(w["m"]), "emphasisPoints": w["points"], "emphasisCandidate": w["candidate"]}
    if w["m"]["dropped"]:
        out["droppedClusters"] = w["m"]["dropped"]
    if w["me"]:
        out["emphasisUnits"] = w["me"]["units"]
        out["emphasisRuns"] = runs(w["me"])
    return out


def page_out(i, p):
    out = {"index": i, "words": p["idxs"], "start": r6(p["start"]), "end": r6(p["end"]),
           "fontPx64": p["fontPx64"], "fontPx": p["fontPx64"] / 64, "shrunk": p["shrunk"],
           "lines": [{"words": l["words"], "units": l["units"], "x": r3(l["x"]), "top": r3(l["top"]),
                      "baseline": r3(l["baseline"]), "width": r3(l["width"])} for l in p["lines"]],
           "wordRects": [{"word": r["word"], "line": r["line"], "x": r3(r["x"]), "y": r3(r["y"]), "w": r3(r["w"]),
                          "h": r3(r["h"]), "baseline": r3(r["baseline"]), "cx": r3(r["cx"]), "cy": r3(r["cy"])}
                         for r in p["wordRects"]],
           "block": rect(p["block"]), "visual": rect(p["visual"]),
           "boxes": [dict({"kind": b["kind"]}, **({"word": b["word"]} if "word" in b else {}), **rect(b), r=r3(b["r"]))
                     for b in p["boxes"]],
           "emphasised": [{"word": k, "paletteColor": v} for k, v in sorted(p["emph"].items())],
           "emoji": p["emojiRect"],
           "clampShift": [r3(p["clampShift"][0]), r3(p["clampShift"][1])]}
    return out


def sample_out(ev):
    if ev["page"] is None:
        return {"t": ev["t"], "page": None}
    words = []
    for w in ev["words"]:
        e = {"word": w["word"], "state": w["state"], "visible": w["visible"], "opacity": r6(w["opacity"]),
             "scale": r6(w["scale"]), "dy": r3(w["dy"]), "fill": w["fill"], "fillSource": w["fillSource"]}
        for flag in ("boxContrast", "wipeFromBoxContrast"):
            if w.get(flag):
                e[flag] = True
        if "wipe" in w:
            e["wipe"] = r6(w["wipe"])
            e["wipeFrom"] = w["wipeFrom"]
        if "visibleClusters" in w:
            e["visibleClusters"] = w["visibleClusters"]
        words.append(e)
    cur = ev["cursor"]
    if cur:
        cur = {"visible": cur["visible"], "word": cur["word"], "x": r3(cur["x"]), "y": r3(cur["y"]),
               "w": r3(cur["w"]), "h": r3(cur["h"])}
    return {"t": ev["t"], "page": ev["page"], "activeWord": ev["activeWord"], "progress": r6(ev["progress"]),
            "pageAlpha": r6(ev["pageAlpha"]), "pageScale": r6(ev["pageScale"]), "pageDy": r3(ev["pageDy"]),
            "jitter": [r3(ev["jitter"][0]), r3(ev["jitter"][1])], "words": words, "cursor": cur}


def auto_times(track):
    st = track["style"]
    ts = set()
    pages = track["pages"]
    pin = st["animation"].get("pageIn")
    for i, p in enumerate(pages):
        if p["end"] <= p["start"]:
            continue
        ws = [track["words"][k] for k in p["idxs"]]
        ts.add(p["start"])
        if pin and pin["durationSec"] > 0:
            ts.add(p["start"] + pin["durationSec"] / 2)
        for w in (ws[0], ws[len(ws) // 2], ws[-1]):
            ts.add((w["start"] + w["end"]) / 2)
        if ws[-1]["end"] < p["end"]:
            ts.add(ws[-1]["end"] + min(0.01, (p["end"] - ws[-1]["end"]) / 2))
        if p["end"] - 0.001 > p["start"]:
            ts.add(p["end"] - 0.001)
        ts.add(p["end"])
        if i + 1 < len(pages) and pages[i + 1]["start"] > p["end"]:
            ts.add((p["end"] + pages[i + 1]["start"]) / 2)
    return sorted({t6(t) for t in ts})


def mark_golden(track, samples, frames):
    """Spec 16.4: the samples the platform renderers turn into pixel goldens."""
    shown = [s for s in samples if s["page"] is not None]
    if not shown:
        return
    if frames:
        chosen = {id(s) for s in shown[::5]}
    else:
        chosen = {id(shown[0])}
        pin = track["style"]["animation"].get("pageIn")
        if pin and pin["durationSec"] > 0:
            t_half = t6(track["pages"][shown[0]["page"]]["start"] + pin["durationSec"] / 2)
            chosen |= {id(s) for s in shown if s["t"] == t_half}
        for s in shown:
            page = track["pages"][s["page"]]
            if len(page["lines"]) > 1 and s["activeWord"] in page["lines"][1]["words"]:
                chosen.add(id(s))
                break
        last = [s for s in shown if s["page"] == shown[-1]["page"]]
        chosen.add(id(last[len(last) // 2]))
    for s in samples:
        if id(s) in chosen:
            s["golden"] = True


def case_fixture(case, sets, db, lex):
    ws = sets[case["words"]]
    words = []
    for k, item in enumerate(ws["words"]):
        w = {"id": "%s-%d" % (case["words"], k), "text": item[0], "start": item[1], "end": item[2]}
        if len(item) > 3:
            w.update(item[3])
        words.append(w)
    style = load_style(case["style"])
    width, height = case["frame"]
    captions = {k: case[k] for k in ("overrides", "position", "positionByAspect") if k in case}
    track = build_track(style, captions, width, height, words, ws["language"], ws["duration"], db, lex)
    times = auto_times(track)
    frame_meta = None
    if "samplesEvery" in case:
        a, b, step = case["samplesEvery"]
        n = int(round((b - a) / step))
        times = sorted(set(times) | {t6(a + i * step) for i in range(n + 1)})
    if "frameSamples" in case:
        fs = case["frameSamples"]
        frame_meta = fs
        times = [(fs["first"] + i) * fs["fpsDen"] / fs["fpsNum"] for i in range(fs["count"])]
    samples = [sample_out(evaluate(track, t if frame_meta else t6(t), db)) for t in times]
    mark_golden(track, samples, frame_meta is not None)
    rs = track["style"]
    left, right, top, bottom = SAFE_INSETS[track["aspect"]]
    expected = {
        "aspect": track["aspect"],
        "preset": rs["_preset"],
        "resolved": {"sizeSh": rs["font"]["sizeSh"], "sizeScale": rs["_sizeScale"], "x": rs["position"]["x"],
                     "y": rs["position"]["y"], "anchorX": rs["position"]["anchorX"], "anchorY": rs["position"]["anchorY"],
                     "maxLineWidthW": rs["layout"]["maxLineWidthW"], "maxWords": rs["layout"]["maxWords"],
                     "transform": rs["text"]["transform"], "punctuation": rs["text"]["punctuation"],
                     "accent": rs.get("accent")},
        "fontPx64": track["f64"], "fontPx": track["f64"] / 64,
        "safeRect": {"x": r3(track["safe"][0]), "y": r3(track["safe"][2]), "w": r3(track["safe"][1] - track["safe"][0]),
                     "h": r3(track["safe"][3] - track["safe"][2])},
        "safeInsets": {"left": left, "right": right, "top": top, "bottom": bottom},
        "limitPx": r3(track["limitPx"]), "limitPx64": track["limit64"], "unitsPerEm": track["upem"],
        "gapUnits": track["gap"],
        "words": [word_out(w) for w in track["words"]],
        "dropped": track["dropped"],
        "pages": [page_out(i, p) for i, p in enumerate(track["pages"])],
        "samples": samples,
    }
    doc = {"fixture": FORMAT, "id": case["id"]}
    if "note" in case:
        doc["note"] = case["note"]
    doc["input"] = {"style": case["style"], "frame": {"width": width, "height": height}, "language": ws["language"],
                    "duration": ws["duration"],
                    "captions": {"overrides": captions.get("overrides", {}), "position": captions.get("position"),
                                 "positionByAspect": captions.get("positionByAspect", {})},
                    "words": words}
    if frame_meta:
        doc["input"]["frameSamples"] = frame_meta
    doc["expected"] = expected
    return doc


TEXT_INPUTS = [
    ("don't", "en"), ("Don’t", "en"), ("03:15", "en"), ("03:15.", "en"), ("3.5", "en"), ("$3.50,", "en"),
    ("1,000", "en"), ("100%.", "en"), ("#1", "en"), ("@siim", "en"), ("rock'n'roll", "en"), ("'cause", "en"),
    ("students'", "en"), ("e-mail", "en"), ("U.S.", "en"), ("voxconvo.com", "en"), ("and/or", "en"),
    ("24/7", "en"), ("...so", "en"), ("well—", "en"), ("—", "en"), ("?!", "en"),
    ("“Hello,”", "en"), ("«Привет»", "ru"), ("¿Qué?", "es"), ("¡Hola!", "es"),
    ("straße", "de"), ("Straße", "de"), ("ẞ", "de"), ("istanbul", "tr"), ("İstanbul", "tr"),
    ("Istanbul", "az"), ("istanbul", "en"), ("šokolaad", "et"), ("Õhtu", "et"), ("„Väga", "et"),
    ("hea.”", "et"), ("naïve", "en"), ("ﬁne", "en"), ("Ǆ", "hr"), ("ǆ", "hr"),
    ("σοφός", "el"), ("ΣΟΦΟΣ", "el"), ("C++", "en"), ("a.m.", "en"),
    ("New " + chr(0xA0) + " York,", "en"), ("\ttab" + chr(0x2003) + "word ", "en"),
    ("e" + chr(0x301) + "te" + chr(0x301), "fr"), ("x²", "en"),
    ("50°C", "en"), ("–5", "en"), ("−5", "en"), ("‐dash", "en"), ("l·l", "ca"),
    ("foo_bar", "en"), ("\U0001F525fire", "en"), ("(laughs)", "en"), ("[music]", "en"), ("um,", "en"),
    ("Tallinn–Tartu", "et"), ("10:30–11:00", "en"), ("1.", "en"), ("v2.0.1", "en"),
    ("-5", "en"), ("–5°C", "en"), ("e.g.", "en"), ("U.S.A.", "en"), ("Mr.", "en"), ("well—that", "en"),
    ("2-3", "en"), ("-", "en"), ("ﬁ" + chr(0x200D), "en"),
]
MODES = [("keep", "none"), ("keep", "uppercase"), ("keep", "lowercase"), ("strip-keep-numeric", "none"),
         ("strip-keep-numeric", "uppercase")]


def text_fixture():
    cases = []
    for raw, lang in TEXT_INPUTS:
        results = {"%s|%s" % (p, t): tx.normalize(raw, p, t, lang) for p, t in MODES}
        cases.append({"input": raw, "inputCodepoints": ["%04X" % ord(c) for c in raw], "language": lang,
                      "results": results, "matchingKey": tx.matching_key(raw, lang),
                      "endsSentence": tx.ends_sentence(raw), "endsClause": tx.ends_clause(raw)})
    return {"fixture": "voxclip-caption-text/1",
            "description": "Spec section 3. results keys are '<punctuation>|<transform>'. An empty result means the word is not captioned.",
            "cases": cases}


def math_fixture():
    rounding = [[x, round_half_up(x)] for x in (0.0, 0.49999999999999994, 0.5, 1.5, 2.5, 2.4999, -0.5, -1.5, -2.6, 4285.44, 3068.928)]
    easing = {}
    ps = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1]
    for name in ("linear", "easeOutCubic", "easeInOutCubic"):
        easing[name] = [[p, ease(name, p) + 0.0] for p in ps]  # full precision: captions 16.3 compares easing within 1e-9
    for ov in (1.70158, 2.0, 2.4):
        easing["easeOutBack(%s)" % ov] = [[p, ease("easeOutBack", p, ov) + 0.0] for p in ps]
    rng = {}
    for seed in (0, 1, 6, 7, 123456789, 4294967295):
        g = mulberry32(seed)
        rng[str(seed)] = [next(g) for _ in range(6)]
    jitter = []
    for t in (0.0, 1 / 30, 2 / 30, 0.1, 1.0, 59 / 30, 3.3):
        k = math.floor(t * 15 + 1e-6)
        g = mulberry32((7 ^ k) & 0xFFFFFFFF)
        jitter.append({"t": t, "rateHz": 15, "seed": 7, "k": k, "r": [next(g), next(g)]})
    blur = {"kernels": [], "boxSizes": [], "rows": []}
    for s in (0.5, 1.0, 1.9):
        r, w = mathref.gaussian_kernel(s)
        blur["kernels"].append({"sigma": s, "radius": r, "weights": [round(x, 12) for x in w]})
    for s in (2.0, 2.5, 3.2, 3.5, 4.0, 6.4, 10.0, 33.5):
        d = mathref.box_size(s)
        blur["boxSizes"].append({"sigma": s, "d": d, "passes": mathref.box_passes(d)})
    row = [0] * 24 + [255] * 16 + [0] * 24
    for s in (1.0, 3.5, 4.0):
        blur["rows"].append({"sigma": s, "input": row, "output": mathref.blur_1d(row, s)})
    rects = []
    for (x, y, w, h, r) in ((10, 20, 200, 60, 12), (0, 0, 120, 40, 20), (5.5, 7.25, 30, 30, 0), (0, 0, 50, 20, 30)):
        rects.append({"rect": [x, y, w, h], "radius": r,
                      "path": [[c[0]] + [round(v, 9) for v in c[1:]] for c in mathref.rounded_rect_path(x, y, w, h, r)]})
    grads = []
    for a in (0, 45, 90, 180, -30, 270):
        p0, p1 = mathref.gradient_points(100, 50, 400, 100, a)
        grads.append({"rect": [100, 50, 400, 100], "angleDeg": a, "p0": [round(v, 9) for v in p0], "p1": [round(v, 9) for v in p1]})
    return {"fixture": "voxclip-caption-math/1",
            "description": "Spec sections 1.3 (rounding), 10.4 (gradients), 11 (easing, mulberry32, jitter), 12.1 (rounded rectangles) and 13.2 (blur). Blur rows are one horizontal pass over an 8-bit row; the vertical pass is identical.",
            "roundHalfUp": rounding, "easing": easing, "mulberry32": rng, "jitter": jitter, "blur": blur,
            "kappa": mathref.KAPPA, "roundedRects": rects, "gradients": grads}


def preview_fixture(db, lex):
    styles = sorted(f[:-5] for f in os.listdir(os.path.join(STYLES, "styles")) if f.endswith(".json"))
    out = []
    for sid in styles:
        style = load_style(sid)
        pv = with_defaults(style)["preview"]
        texts = pv["text"].split()
        words = [{"id": "p%d" % i, "text": w, "start": round(0.4 * i, 6), "end": round(0.4 * i + 0.35, 6)} for i, w in enumerate(texts)]
        a = min(pv["activeWord"], len(words) - 1)
        t = t6(0.4 * a + 0.35 * min(pv["progress"], 0.98))
        for frame in ((1080, 1920), (1920, 1080)):
            track = build_track(style, None, frame[0], frame[1], words, "en", 0.4 * len(words) + 0.5, db, lex)
            ev = evaluate(track, t, db, reduced=True)
            out.append({"style": sid, "frame": {"width": frame[0], "height": frame[1]}, "background": pv["background"],
                        "t": t, "page": page_out(ev["page"], track["pages"][ev["page"]]), "sample": sample_out(ev),
                        "words": [{"text": w["m"]["text"], "start": w["start"], "end": w["end"]} for w in track["words"]]})
    return {"fixture": "voxclip-caption-preview/1",
            "description": "Gallery tile state (spec 15.3): preview.text words timed at [0.4 i, 0.4 i + 0.35], evaluated at t = 0.4 activeWord + 0.35 min(progress, 0.98) with reduced motion (animations at rest, no jitter, cursor on).",
            "tiles": out}


def main():
    cases_doc = load_json(os.path.join(HERE, "cases.json"))
    db, lex = FontDB(), Lexicon()
    layout_dir = os.path.join(FIXTURES, "layout")
    if os.path.isdir(layout_dir):
        shutil.rmtree(layout_dir)
    index = {"fixture": "voxclip-caption-index/1", "layout": [], "files": ["text-normalization.json", "math.json", "preview-tiles.json"]}
    ids = set()
    all_styles = {f[:-5] for f in os.listdir(os.path.join(STYLES, "styles")) if f.endswith(".json")}
    cases = list(cases_doc["cases"])
    preview = load_style("box-highlight")["preview"]
    texts = preview["text"].split()
    cases_doc["wordSets"]["box-swatches"] = {
        "language": "en", "duration": 0.4 * len(texts) + 0.5,
        "words": [[word, round(0.4 * index, 6), round(0.4 * index + 0.35, 6)]
                  for index, word in enumerate(texts)]}
    for name, accent in SWATCHES.items():
        for aspect, frame in (("portrait", [1080, 1920]), ("landscape", [1920, 1080])):
            cases.append({"id": "box-highlight-" + name + "-" + aspect, "style": "box-highlight",
                          "frame": frame, "words": "box-swatches", "overrides": {"accent": accent}})
    cases_doc["wordSets"]["box-final-paints"] = {
        "language": "en", "duration": 0.4 * len(texts) + 0.5,
        "words": [[word, round(0.4 * index, 6), round(0.4 * index + 0.35, 6), {"emphasis": index == 0}]
                  for index, word in enumerate(texts)]}
    dark_gradient = {"type": "linear", "color": None, "angleDeg": 0, "space": "word",
                     "stops": [{"offset": 0, "color": "#000000"}, {"offset": 1, "color": "#333333"}]}
    light_gradient = {"type": "linear", "color": None, "angleDeg": 0, "space": "word",
                      "stops": [{"offset": 0, "color": "#000000"}, {"offset": 1, "color": "#FFFFFF"}]}
    probes = {
        "emphasis-fill": {"emphasis": {"source": "manual", "fill": {"type": "solid", "color": "#FFFFFF"}}},
        "palette": {"emphasis": {"source": "manual", "fill": {"type": "solid", "color": "#111111"}, "palette": ["#FFFFFF"]}},
        "wipe": {"reveal": {"unit": "wipe"}, "words": {"active": {"fill": {"type": "solid", "color": "#7C3AED"}}}},
        "gradient-kept": {"fill": dark_gradient},
        "gradient-replaced": {"fill": light_gradient},
    }
    for name, patch in probes.items():
        cases.append({"id": "box-final-" + name, "style": "box-highlight", "frame": [1080, 1920],
                      "words": "box-final-paints", "overrides": {"accent": "#FFFFFF", **patch},
                      "frameSamples": {"fpsNum": 30, "fpsDen": 1, "first": 3, "count": 6}})
    explicit = {c["id"] for c in cases}
    matrix = cases_doc.get("matrix")
    if matrix:
        names = {"portrait": (1080, 1920), "square": (1080, 1080), "landscape": (1920, 1080)}
        for sid in sorted(all_styles):
            for aspect in matrix["aspects"]:
                cid = "%s-%s-%s" % (sid, aspect, matrix["words"])
                if cid not in explicit:
                    cases.append({"id": cid, "style": sid, "frame": list(names[aspect]), "words": matrix["words"]})
    for case in cases:
        if case["id"] in ids:
            raise SystemExit("duplicate case id " + case["id"])
        ids.add(case["id"])
        doc = case_fixture(case, cases_doc["wordSets"], db, lex)
        write_json(os.path.join(layout_dir, case["id"] + ".json"), doc)
        index["layout"].append({"file": "layout/%s.json" % case["id"], "style": case["style"],
                                "frame": case["frame"], "pages": len(doc["expected"]["pages"]),
                                "samples": len(doc["expected"]["samples"])})
    write_json(os.path.join(FIXTURES, "text-normalization.json"), text_fixture())
    write_json(os.path.join(FIXTURES, "math.json"), math_fixture())
    write_json(os.path.join(FIXTURES, "preview-tiles.json"), preview_fixture(db, lex))
    styles_covered = {c["style"] for c in cases}
    if all_styles - styles_covered:
        raise SystemExit("styles without a layout case: %s" % sorted(all_styles - styles_covered))
    write_json(os.path.join(FIXTURES, "index.json"), index)
    print("wrote %d layout fixtures + text, math, preview, index" % len(index["layout"]))


if __name__ == "__main__":
    sys.exit(main())
