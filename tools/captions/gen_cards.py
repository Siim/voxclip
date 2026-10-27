#!/usr/bin/env python3
"""Generate shared/fixtures/captions/cards.json, the caption card fixtures (doc/design.md section 5.4.2),
from tools/captions/card-cases.json.

    /tmp/voxclip-captions-venv/bin/python -I tools/captions/gen_cards.py

Needs requirements.txt (`regex`, `jsonschema`, `fonttools`, `uharfbuzz`) and Node 22.13 or newer: card_plans.mjs
plans every project with the editing fixture generator's reference (tools/fixtures/editing). Every project is
checked against shared/schemas/project.schema.json first, and every card and fit drop is laid out with the
reference engine and refused unless its frame at the drawn moment shows the key word (or, for a reveal style,
every word). The output is deterministic; re-running gives a byte-identical file.
"""
import os
import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the source tree
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from captionref import card as cd  # noqa: E402
from captionref.fontdb import FontDB  # noqa: E402
from captionref.layout import Lexicon, build_track  # noqa: E402
from captionref.style import load_style  # noqa: E402
from captionref.takes import build_projects, caption_copies, validate  # noqa: E402
from captionref.timeline import evaluate  # noqa: E402
from captionref.util import FIXTURES, STYLES, load_json, write_json  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def expected(result, st):
    words, key = result["words"], result["keyIndex"]
    none = result["source"] == "none"
    style_lines = 0 if none else st["layout"]["maxLines"]
    at_last = False if none else cd.draws_at_last_word(st)
    hold = 0.0 if none else cd.hold_gap(st)
    duration, time = cd.timing(words, key, at_last, hold)
    drops, current = [], words
    while True:
        shorter = cd.dropping_last_word(current)
        if shorter is None:
            break
        k = cd.key_index(shorter)
        drops.append({"words": [w["id"] for w in shorter], "keyIndex": k, "time": cd.timing(shorter, k, at_last, hold)[1]})
        current = shorter
    return {"source": result["source"], "keyIndex": key, "styleMaxLines": style_lines, "drawsAtLastWord": at_last, "holdGapSec": hold,
            "words": [{"id": w["id"], "text": w["text"], "display": w["display"], "weak": w["weak"]} for w in words],
            "maxLines": {surface: min(lines, style_lines) for surface, lines, _ in cd.SURFACES},
            "layout": {"words": cd.layout_words(words, key), "duration": duration, "time": time},
            "drops": drops}


def check_drawn(case_id, project, style, words, at_last, hold, db, lex):
    """Refuse a card whose frame at its drawn moment shows no page, does not make the key word the active word or,
    for a reveal style, has not drawn every word yet (section 5.4.2). Uses the export frame, with and without
    Reduce Motion."""
    key = cd.key_index(words)
    duration, t = cd.timing(words, key, at_last, hold)
    width, height = cd.export_frame(project)
    lang = cd.language(project["transcript"].get("language"))
    layout = cd.layout_words(words, key)
    try:
        track = build_track(style, project["captions"], width, height, layout, lang, duration, db, lex)
    except ValueError:  # a rejected patch lays the style out unpatched (captions spec 2.4)
        track = build_track(style, dict(project["captions"], overrides={}), width, height, layout, lang, duration, db, lex)
    if len(track["words"]) != len(words):
        raise SystemExit("%s: the reference layout dropped card words" % case_id)
    for reduced in (False, True):
        ev = evaluate(track, t, db, reduced=reduced)
        if ev["page"] is None:
            raise SystemExit("%s: no page at %r" % (case_id, t))
        if at_last:
            drawn = {w["word"] for w in ev["words"]
                     if w["visible"] and w.get("visibleClusters", -1) in (-1, track["words"][w["word"]]["m"]["clusters"])}
            if drawn != set(range(len(words))):
                raise SystemExit("%s: words %s not drawn at %r" % (case_id, sorted(set(range(len(words))) - drawn), t))
        elif ev["activeWord"] != key:
            raise SystemExit("%s: word %s is active at %r, not the key word %d" % (case_id, ev["activeWord"], t, key))


def main():
    doc = load_json(os.path.join(HERE, "card-cases.json"))
    projects = build_projects(doc, "voxclip-card")
    validate(projects)
    copies = caption_copies(projects)
    coverage = cd.Coverage()
    stopwords = {k: set(v) for k, v in load_json(os.path.join(STYLES, "stopwords.json"))["languages"].items()}
    styles = sorted(f[:-5] for f in os.listdir(os.path.join(STYLES, "styles")) if f.endswith(".json"))
    cases = list(doc["cases"])
    matrix = doc["matrix"]
    cases += [{"id": "%s-%s" % (matrix["prefix"], sid), "project": matrix["project"], "style": sid} for sid in styles]
    db, lex = FontDB(), Lexicon()
    out, used, ids = [], set(), set()
    for case in cases:
        if case["id"] in ids:
            raise SystemExit("duplicate case id " + case["id"])
        ids.add(case["id"])
        name = case["project"]
        project = projects[name]
        used.add(name)
        style_id = case.get("style") or project["captions"]["styleId"]
        scope = case.get("scope")
        visible = case.get("wordsVisible", True)
        captions = None
        if project.get("transcript") is not None:
            plan = copies[name]
            if scope is not None and scope not in plan["clips"]:
                raise SystemExit("%s: project %s has no clip %s" % (case["id"], name, scope))
            captions = plan["take"] if scope is None else plan["clips"][scope]
        style = load_style(style_id)
        result, st = cd.card(project, captions, style, visible, coverage, stopwords)
        current = result["words"]
        while current:
            check_drawn("%s (%d words)" % (case["id"], len(current)), project, style, current,
                        cd.draws_at_last_word(st), cd.hold_gap(st), db, lex)
            current = cd.dropping_last_word(current)
        out.append({"id": case["id"], "project": name, "style": style_id, "scope": scope, "wordsVisible": visible,
                    "expected": expected(result, st)})
    write_json(os.path.join(FIXTURES, "cards.json"), {
        "fixture": "voxclip-caption-cards/1",
        "description": "Caption card text (doc/design.md section 5.4.2) for a project, a scope (null for the full take, "
                       "else a clip id), a caption style and the Settings switch. Layout words are timed "
                       "[0.4 i, 0.4 i + 0.35] with only the key word emphasised, and drawn at time: 0.35 x 0.98 into the "
                       "key word (captions spec 15.3), or for a reveal style at its last word, at that word's end when "
                       "holdGapSec > 0. Drops are the fit's successive shorter cards (section 5.4.3). standIns are the section 5.4.1 "
                       "precedence over the 5.4.4 states: frame, card (a card without words draws only the style's "
                       "backdrop) or black.",
        "maxWords": cd.MAX_WORDS,
        "surfaces": [{"surface": surface, "lines": lines, "plates": plates} for surface, lines, plates in cd.SURFACES],
        "projects": {name: projects[name] for name in sorted(used)},
        "cases": out,
        "standIns": [{"status": status, "hasFrame": frame, "holding": holding, "hasWords": words,
                      "standIn": cd.stand_in(status, frame, holding, words)}
                     for status in cd.STATUSES for frame in (False, True) for holding in (False, True) for words in (False, True)]})
    print("wrote %d card cases over %d projects" % (len(out), len(used)))


if __name__ == "__main__":
    sys.exit(main())
