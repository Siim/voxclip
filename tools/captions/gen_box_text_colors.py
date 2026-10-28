#!/usr/bin/env python3
"""Generate caption box text colour vectors; captions sections 2.3 and 16."""
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from captionref.contrast import SWATCHES, ratio, text
from captionref.style import color, load_style, merge_patch, with_defaults


def main():
    root = Path(__file__).resolve().parents[2]
    cases = []

    def append(name, style_id, overrides, state="active"):
        style = with_defaults(merge_patch(load_style(style_id), overrides))
        appearance = style.get("words", {}).get(state, {})
        box = appearance.get("box", style.get("box"))["color"]
        paint = appearance.get("fill", style["fill"])
        chosen = text(paint, box, style)
        cases.append(dict(id=name, style=style_id, overrides=overrides, state=state,
                          box=list(color(style, box)), text=list(color(style, paint["color"])),
                          contrast=ratio(color(style, paint["color"]), color(style, box)),
                          expected=list(color(style, chosen["color"]))))

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
    target = root / "shared/fixtures/captions/box-text-colors.json"
    target.write_text(json.dumps(dict(fixture="voxclip-caption-box-text-colors/1", cases=cases), indent=2) + "\n")
    print(f"wrote {len(cases)} box text colour cases")


if __name__ == "__main__":
    main()
