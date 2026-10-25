#!/usr/bin/env python3
"""Validate every shared/caption-styles/styles/*.json against the schema and the semantic rules of
doc/spec/captions.md section 2.5. Exit status 1 on any error.

    /tmp/voxclip-captions-venv/bin/python -I tools/captions/check_styles.py
"""
import json
import os
import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the source tree
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from jsonschema import Draft202012Validator  # noqa: E402

from captionref.util import FONTS, STYLES, load_json  # noqa: E402

MIN_STYLES = 17


def walk_colors(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk_colors(v, path + "/" + k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk_colors(v, "%s/%d" % (path, i))
    elif isinstance(node, str) and (node.startswith("#") or node.startswith("$accent")):
        yield path, node


def check(style, fonts, emoji_codes):
    errors = []
    sid = style.get("id")
    f = style["font"]
    entry = fonts.get(f["file"])
    if entry is None:
        errors.append("font.file %s is not in fonts.json" % f["file"])
    else:
        if entry["family"] != f["family"]:
            errors.append("font.family %r != manifest %r" % (f["family"], entry["family"]))
        if entry["weight"] != f["weight"]:
            errors.append("font.weight %r != manifest %r" % (f["weight"], entry["weight"]))
        if entry["italic"] != f.get("italic", False):
            errors.append("font.italic does not match the manifest")
    for extra in f.get("fallbackFiles", []) + ([style["emphasis"]["fontFile"]] if "fontFile" in style.get("emphasis", {}) else []):
        if extra not in fonts:
            errors.append("font file %s is not in fonts.json" % extra)
    for path, value in walk_colors({k: v for k, v in style.items() if k not in ("preview", "accent")}):
        if value.startswith("$accent") and "accent" not in style:
            errors.append("%s uses $accent but the style has no accent" % path)
    def stops_ok(paint, where):
        if paint and paint.get("type") == "linear":
            offs = [s["offset"] for s in paint["stops"]]
            if offs != sorted(offs):
                errors.append(where + ": gradient stop offsets must be ascending")
    stops_ok(style["fill"], "fill")
    for state, ws in style.get("words", {}).items():
        stops_ok(ws.get("fill"), "words." + state + ".fill")
        b = ws.get("box")
        if b and b.get("borderWidthEm", 0) > 0 and "borderColor" not in b:
            errors.append("words.%s.box: borderWidthEm needs borderColor" % state)
        if state != "active" and b:
            errors.append("words.%s.box: only the active state may have a box" % state)
    b = style.get("box")
    if b and b.get("borderWidthEm", 0) > 0 and "borderColor" not in b:
        errors.append("box: borderWidthEm needs borderColor")
    rv = style.get("reveal", {})
    if "cursor" in rv and rv.get("unit") != "char":
        errors.append("reveal.cursor requires reveal.unit 'char'")
    em = style.get("emphasis", {})
    if em.get("source", "none") != "none" and "fill" not in em and "palette" not in em and "fontFile" not in em and em.get("scale", 1) == 1:
        errors.append("emphasis has no visible effect")
    if style.get("emoji", {}).get("enabled") and not emoji_codes:
        errors.append("emoji enabled but no emoji images are bundled")
    words = style["preview"]["text"].split()
    if style["preview"].get("activeWord", 0) >= len(words):
        errors.append("preview.activeWord is past the last sample word")
    return errors


def main():
    schema = load_json(os.path.join(STYLES, "schema.json"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    manifest = load_json(os.path.join(FONTS, "fonts.json"))
    fonts = {e["file"]: e for e in manifest["fonts"]}
    emoji_codes = {e["codepoints"] for e in manifest["emoji"]["images"]}
    lex = load_json(os.path.join(STYLES, "emoji-keywords.json"))
    failures = 0
    for lang, table in lex["languages"].items():
        for key, cp in table.items():
            if cp not in emoji_codes:
                print("emoji-keywords.json: %s/%s -> %s has no PNG" % (lang, key, cp))
                failures += 1
    ids, orders = set(), {}
    files = sorted(f for f in os.listdir(os.path.join(STYLES, "styles")) if f.endswith(".json"))
    for name in files:
        style = load_json(os.path.join(STYLES, "styles", name))
        errs = [e.message + " at /" + "/".join(str(p) for p in e.absolute_path) for e in validator.iter_errors(style)]
        if not errs:
            errs = check(style, fonts, emoji_codes)
            if style["id"] + ".json" != name:
                errs.append("id must equal the file name")
        if style.get("id") in ids:
            errs.append("duplicate id")
        if style.get("id") == "off":
            errs.append("'off' is reserved for captions turned off")
        ids.add(style.get("id"))
        orders.setdefault(style.get("order", 500), []).append(style.get("id"))
        for e in errs:
            print("%s: %s" % (name, e))
        failures += len(errs)
    if len(files) < MIN_STYLES:
        print("only %d styles; at least %d are required" % (len(files), MIN_STYLES))
        failures += 1
    print("%d styles checked, %d problems" % (len(files), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
