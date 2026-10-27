#!/usr/bin/env python3
"""Generate shared/fixtures/captions/gallery-samples.json, the caption gallery tile samples (doc/spec/captions.md
sections 15.2 and 15.3), from tools/captions/gallery-cases.json.

    python3 -I tools/captions/gen_gallery.py

Standard library only, plus Node 22.13 or newer: card_plans.mjs plans every project with the editing fixture
generator's reference (tools/fixtures/editing), as for gen_cards.py. When `jsonschema` is importable, every project is
also checked against shared/schemas/project.schema.json. The rules come from captionref.card: the scope's words as a
caption page holds them, 6.1 paging (without the 6.2 fit, which needs glyph widths), weak words, the key word and the
drawn moment of doc/design.md section 5.4.2. A word is taken only when the style's primary font covers every scalar of
its display text, so the font cascade keeps it whole without UAX #29 clusters. Every sample is refused unless the
page at the tile time contains the drawn word; the tile timing may split an overlong sample. The output is deterministic;
re-running gives a byte-identical file.
"""
import math
import os
import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the source tree
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from captionref import card as cd  # noqa: E402
from captionref import text as tx  # noqa: E402
from captionref.style import load_style, with_defaults  # noqa: E402
from captionref.takes import build_projects, caption_copies, validate  # noqa: E402
from captionref.util import FIXTURES, STYLES, load_json, write_json  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


class WholeWords(cd.Coverage):
    """The 4.4 cascade for words whose every scalar the style's primary font covers: each cluster keeps all of its
    scalars, whatever the clusters are, so the word stays whole. Any other word is refused."""

    def kept(self, text, style):
        primary = style["font"]["file"]
        for c in text:
            if ord(c) in tx.IGNORABLE or not self.covers(primary, ord(c)):
                raise SystemExit("%r needs grapheme clusters (U+%04X); gen_gallery.py takes words that %s covers whole"
                                 % (text, ord(c), primary))
        return text


def tile_words(words):
    """The sample as caption input: word i spans [0.4 i, 0.4 i + 0.35] (captions spec 15.3)."""
    return [{"id": w["id"], "text": w["text"], "start": 0.4 * i, "end": 0.4 * i + 0.35} for i, w in enumerate(words)]


def page_ends(pages, layout, duration):
    """Captions spec 8.1: where each page stops being visible."""
    ends = []
    for i, page in enumerate(pages):
        start = page[0]["start"]
        following = pages[i + 1][0]["start"] if i + 1 < len(pages) else math.inf
        end = min(page[-1]["end"] + layout["holdGapSec"], following)
        if end - start < layout["minPageSec"]:
            end = min(start + layout["minPageSec"], following)
        ends.append(min(end, duration))
    return ends


def preview(style):
    """The style's own sample: preview.text at preview.activeWord, preview.progress (default 1) into it."""
    pv = with_defaults(style)["preview"]
    words = [{"id": "preview-%d" % i, "text": t} for i, t in enumerate(t for t in pv["text"].split(" ") if t)]
    active = max(0, min(pv["activeWord"], len(words) - 1))
    return "preview", words, 0.4 * active + 0.35 * min(pv["progress"], 0.98), None


def sample(project, copy, duration, style, playhead, visible, coverage, stopwords):
    """Captions spec 15.2 and 15.3: the source, the page's words and the tile time, plus the resolved style."""
    transcript = project.get("transcript")
    if not visible or transcript is None or copy is None:
        return preview(style)
    captions = dict(project["captions"])
    if style["id"] != captions.get("styleId"):
        captions["overrides"] = {}
    st = cd.resolved_style(style, dict(project, captions=captions))
    lang = cd.language(transcript.get("language"))
    words = [e for e in (cd.entry(w["id"], w["text"], w["start"], w["end"], st, lang, coverage) for w in copy) if e]
    if not words:
        return preview(style)
    stops = stopwords.get(lang)
    for w in words:
        w["weak"] = cd.is_weak(w, lang, stops)
    pages = cd.group(words, st["layout"])
    ends = page_ends(pages, st["layout"], duration)
    shown = next((i for i, page in enumerate(pages) if page[0]["start"] <= playhead < ends[i]), None)
    later = next((i for i, page in enumerate(pages) if page[0]["start"] > playhead), None)
    page = pages[shown if shown is not None else later if later is not None else len(pages) - 1]
    if shown is not None:
        active = max(i for i, w in enumerate(page) if w["start"] <= playhead)  # captions spec 8.2
        if playhead < page[active]["end"]:
            return "page", page, 0.4 * active + 0.35 * 0.98, st
    return "page", page, cd.timing(page, cd.key_index(page), cd.draws_at_last_word(st), cd.hold_gap(st))[1], st


def check_tile(case_id, words, time, st):
    """Refuse a sample whose page at the tile time does not contain the drawn word. Timing may split the sample."""
    if st is None:
        return
    timed = [dict(w, raw=tx.source_text(w["text"])) for w in tile_words(words)]
    pages = cd.group(timed, st["layout"])
    ends = page_ends(pages, st["layout"], 0.4 * len(words) + 0.5)
    shown = next((page for page, end in zip(pages, ends) if page[0]["start"] <= time < end), None)
    anchor = min(len(timed) - 1, math.floor(time / 0.4))
    if shown is None or not any(w["id"] == timed[anchor]["id"] for w in shown):
        raise SystemExit("%s: the drawn word is not visible at %r" % (case_id, time))


def main():
    doc = load_json(os.path.join(HERE, "gallery-cases.json"))
    projects = build_projects(doc, "voxclip-gallery")
    try:
        validate(projects)
    except ImportError:
        print("jsonschema is not installed: projects not checked against the project schema")
    copies = caption_copies(projects)
    coverage = WholeWords()
    stopwords = {k: set(v) for k, v in load_json(os.path.join(STYLES, "stopwords.json"))["languages"].items()}
    styles = sorted(f[:-5] for f in os.listdir(os.path.join(STYLES, "styles")) if f.endswith(".json"))
    cases = list(doc["cases"])
    matrix = doc["matrix"]
    cases += [{"id": "%s-%s-%s" % (matrix["prefix"], sid, name), "project": matrix["project"], "style": sid, "playhead": playhead}
              for sid in styles for name, playhead in matrix["playheads"]]
    out, used, ids = [], set(), set()
    for case in cases:
        if case["id"] in ids:
            raise SystemExit("duplicate case id " + case["id"])
        ids.add(case["id"])
        name, scope, visible = case["project"], case.get("scope"), case.get("wordsVisible", True)
        project = projects[name]
        used.add(name)
        copy, duration = None, None
        if project.get("transcript") is not None:
            plan = copies[name]
            if scope is not None and scope not in plan["clips"]:
                raise SystemExit("%s: project %s has no clip %s" % (case["id"], name, scope))
            copy = plan["take"] if scope is None else plan["clips"][scope]
            duration = plan["durations"]["take"] if scope is None else plan["durations"]["clips"][scope]
        source, words, time, st = sample(project, copy, duration, load_style(case["style"]), case["playhead"], visible,
                                         coverage, stopwords)
        check_tile(case["id"], words, time, st)
        out.append({"id": case["id"], "project": name, "style": case["style"], "scope": scope, "playhead": case["playhead"],
                    "wordsVisible": visible,
                    "expected": {"source": source, "words": tile_words(words), "duration": 0.4 * len(words) + 0.5, "time": time}})
    write_json(os.path.join(FIXTURES, "gallery-samples.json"), {
        "fixture": "voxclip-caption-gallery/1",
        "description": "Caption gallery tile samples (doc/spec/captions.md sections 15.2 and 15.3) for a project, a scope (null "
                       "for the full take, else a clip id), a library style, the playhead in the scope's edited time and the "
                       "Settings switch. The words are the caption page at the playhead (section 6.1 paging with project "
                       "overrides only for the selected tile, without the 6.2 fit), the next page in a gap or before the first page, the last page after "
                       "it, or the style's preview.text when the scope has no caption words or words are hidden. They are timed "
                       "[0.4 i, 0.4 i + 0.35] with the text as stored and no emphasis; duration is 0.4 n + 0.5. time is 0.35 x "
                       "0.98 into the word the playhead is in; otherwise the caption card's drawn moment (doc/design.md section "
                       "5.4.2); for preview.text, 0.4 a + 0.35 min(progress, 0.98) with a = min(activeWord, n - 1) and progress "
                       "1 when absent.",
        "projects": {name: projects[name] for name in sorted(used)},
        "cases": out})
    print("wrote %d gallery cases over %d projects" % (len(out), len(used)))


if __name__ == "__main__":
    sys.exit(main())
