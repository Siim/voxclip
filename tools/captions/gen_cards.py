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
import copy
import hashlib
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the source tree
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from jsonschema import Draft202012Validator, FormatChecker  # noqa: E402
from referencing import Registry, Resource  # noqa: E402

from captionref import card as cd  # noqa: E402
from captionref.fontdb import FontDB  # noqa: E402
from captionref.layout import Lexicon, build_track  # noqa: E402
from captionref.style import load_style, merge_patch  # noqa: E402
from captionref.timeline import evaluate  # noqa: E402
from captionref.util import FIXTURES, REPO, SHARED, STYLES, load_json, write_json  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def synthetic(name, spec, template):
    """A schema-valid take built on the template project, with deterministic ids and timings."""
    project = copy.deepcopy(template)
    digest = hashlib.sha256(("voxclip-card-" + name).encode()).hexdigest()
    project["id"] = "-".join((digest[:8], digest[8:12], digest[12:16], digest[16:20], digest[20:32]))
    if spec.get("title") is None:
        project.pop("title", None)
    else:
        project["title"] = spec["title"]
    tokens = spec.get("words", "").split()
    times = spec.get("times") or [(round(0.2 + 0.45 * i, 6), round(0.55 + 0.45 * i, 6)) for i in range(len(tokens))]
    if len(times) != len(tokens):
        raise SystemExit("%s: %d words but %d times" % (name, len(tokens), len(times)))
    duration = round(max(1.0, (times[-1][1] if times else 0) + 0.5), 6)
    source = project["media"]["source"]
    source.update(absolutePath="/Users/example/Movies/%s.mov" % name, relativePath=name + ".mov", sizeBytes=1048576,
                  durationSeconds=duration, contentKey=digest)
    if spec.get("video") is False:
        source["video"] = None
    if spec.get("transcript") is False:
        project["transcript"] = None
    else:
        transcript = project["transcript"]
        transcript["words"] = [{"id": "w%d" % (i + 1), "text": text, "kind": "word", "start": start, "end": end,
                                "rawStart": start, "rawEnd": end, "conf": 0.95, "speaker": None, "timing": "native"}
                               for i, (text, (start, end)) in enumerate(zip(tokens, times))]
        transcript.update(language=spec["language"], durationSeconds=duration,
                          rawKey=hashlib.sha256(("voxclip-card-raw-" + name).encode()).hexdigest())
    project["edits"] = {
        "pauseThresholdSeconds": 0.8, "pauseKeepSeconds": 0.15, "cutWordIds": spec.get("cut", []),
        "cutPauseIds": spec.get("cutPauses", []), "corrections": spec.get("corrections", {}),
        "clips": [{"id": c["id"], "startWordId": c["start"], "endWordId": c["end"], "title": c.get("title"),
                   "origin": "manual", "aiResultId": None, "aiClipIndex": None, "selected": True}
                  for c in spec.get("clips", [])],
        "activeClipId": None}
    project["captions"] = {"styleId": spec["style"], "overrides": spec.get("overrides", {}), "position": None,
                           "positionByAspect": {}}
    project["export"]["aspect"] = spec.get("aspect", "9:16")
    project["share"] = {"captions": {}}
    return project


def build_projects(doc):
    template = load_json(os.path.join(REPO, doc["template"]))
    specs, built = doc["projects"], {}

    def get(name):
        if name not in built:
            spec = specs[name]
            if "file" in spec:
                built[name] = load_json(os.path.join(REPO, spec["file"]))
            elif "from" in spec:
                built[name] = merge_patch(get(spec["from"]), spec["patch"])
            else:
                built[name] = synthetic(name, spec, template)
        return built[name]

    for name in specs:
        get(name)
    return built


def validate(projects):
    registry, project_schema = Registry(), None
    for file in sorted(os.listdir(os.path.join(SHARED, "schemas"))):
        if file.endswith(".schema.json"):
            schema = load_json(os.path.join(SHARED, "schemas", file))
            registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
            if file == "project.schema.json":
                project_schema = schema
    validator = Draft202012Validator(project_schema, registry=registry, format_checker=FormatChecker())
    for name in sorted(projects):
        errors = sorted(validator.iter_errors(projects[name]), key=lambda e: list(e.path))
        if errors:
            raise SystemExit("project %s is not schema-valid: %s at %s" % (name, errors[0].message, list(errors[0].path)))


def caption_copies(projects):
    payload = {name: p for name, p in projects.items() if p.get("transcript") is not None}
    run = subprocess.run(["node", "--no-warnings=ExperimentalWarning", os.path.join(HERE, "card_plans.mjs")],
                         input=json.dumps(payload), capture_output=True, text=True, encoding="utf-8", check=False)
    if run.returncode != 0:
        raise SystemExit("card_plans.mjs failed:\n" + run.stderr)
    return json.loads(run.stdout)


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
    projects = build_projects(doc)
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
