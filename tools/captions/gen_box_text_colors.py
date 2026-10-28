#!/usr/bin/env python3
"""Generate caption box text colour vectors; captions sections 2.3 and 16."""
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from captionref.contrast import SWATCHES, ratio
from captionref.layout import resolve_paint
from captionref.style import color, load_style, merge_patch, with_defaults


def main():
    root = Path(__file__).resolve().parents[2]
    cases = []

    def normalized(paint, style):
        if paint["type"] == "solid":
            return dict(type="solid", color="#%02X%02X%02X%02X" % color(style, paint["color"]))
        return dict(paint, stops=[dict(stop, color="#%02X%02X%02X%02X" % color(style, stop["color"]))
                                  for stop in paint["stops"]])

    def append(name, style_id, overrides, state="active", box_state=None, emphasised=False):
        style = with_defaults(merge_patch(load_style(style_id), overrides))
        palette = style["emphasis"].get("palette", [None])[0] if emphasised else None
        source, paint, chosen, box = resolve_paint(style, state, palette, emphasised, box_state)
        background = color(style, box["color"]) if box else None
        tokens = [paint["color"]] if paint["type"] == "solid" else [stop["color"] for stop in paint["stops"]]
        cases.append(dict(id=name, style=style_id, overrides=overrides, state=state,
                          boxState=box_state or state, emphasised=emphasised, palette=palette,
                          box=list(background) if background else None, paint=normalized(paint, style),
                          contrasts=[ratio(color(style, token), background) for token in tokens] if box else [],
                          expected=normalized(chosen, style), source=source, replaced=chosen != paint))

    for path in sorted((root / "shared/caption-styles/styles").glob("*.json")):
        style = json.loads(path.read_text())
        if not style.get("box") and not style.get("words", {}).get("active", {}).get("box"):
            continue
        append(style["id"] + "-default", style["id"], {})
        for name, accent in SWATCHES.items():
            append(style["id"] + "-" + name, style["id"], dict(accent=accent))
    for name, foreground, background in (
            ("keep-tinted", "#7C3AED", "#F3F0E7"),
            ("keep-alpha", "#11111180", "#FFFFFF80"),
            ("black-below-minimum", "#000000", "#747474"),
            ("black-above-minimum", "#000000", "#757575"),
            ("white-below-minimum", "#FFFFFF", "#777777"),
            ("white-above-minimum", "#FFFFFF", "#767676"),
            ("prefer-white", "#222222", "#000000"),
            ("prefer-black", "#FFFFFF", "#FFFFFF")):
        append(name, "box-highlight", dict(words=dict(active=dict(
            fill=dict(type="solid", color=foreground), box=dict(color=background)))))
    append("patched-base-box", "pill", dict(box=dict(color="#111111")))
    append("patched-past-fill", "pill", dict(words=dict(past=dict(fill=dict(type="solid", color="#FFFFFF")))), "past")
    append("patched-future-fill", "pill", dict(words=dict(future=dict(fill=dict(type="solid", color="#FFFFFF")))), "future")
    append("active-box-over-page-box", "box-highlight", dict(box=dict(scope="page", color="#000000"), accent="#FFFFFF"))
    for scope in ("word", "line", "page", "unboxed"):
        background = {"accent": "#FFFFFF"}
        if scope != "word":
            background["words"] = {"active": {"box": None}}
            background["box"] = {"scope": scope, "color": "#FFFFFF"} if scope != "unboxed" else None
        for name, patch, emphasised, state in (
                ("emphasis-fill", {"emphasis": {"source": "manual", "fill": {"type": "solid", "color": "#FFFFFF"}}}, True, "active"),
                ("palette", {"emphasis": {"source": "manual", "fill": {"type": "solid", "color": "#111111"}, "palette": ["#FFFFFF"]}}, True, "active"),
                ("wipe-first-pass", {"reveal": {"unit": "wipe"}}, False, "future"),
                ("gradient-kept", {"fill": {"type": "linear", "color": None, "angleDeg": 25, "space": "word", "stops": [
                    {"offset": 0, "color": "#000000"}, {"offset": 1, "color": "#333333"}]}}, False, "active"),
                ("gradient-replaced", {"fill": {"type": "linear", "color": None, "angleDeg": 25, "space": "word", "stops": [
                    {"offset": 0, "color": "#000000"}, {"offset": 1, "color": "#FFFFFF"}]}}, False, "active")):
            append(name + "-" + scope, "box-highlight", {**background, **patch}, state, "active", emphasised)
    target = root / "shared/fixtures/captions/box-text-colors.json"
    target.write_text(json.dumps(dict(fixture="voxclip-caption-box-text-colors/2", cases=cases), indent=2) + "\n")
    print(f"wrote {len(cases)} box text colour cases")


if __name__ == "__main__":
    main()
