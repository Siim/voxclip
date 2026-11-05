#!/usr/bin/env python3
"""Write shared/fixtures/clip-style/caption-look-cases.json (voxclip-caption-look-cases/1): each clip's caption look
(doc/design.md section 6.6), produced independently of both apps. Standard library only; deterministic.

`wire` lists picks a project may store (`valid`) and must refuse (`invalid`; `runtimeOnly` cases pass the JSON schema and
are refused by the readers); each case is one `clipStyle.captionPicks` entry. `resolve` lists a project's captions and clip style with the captions a render of each clip uses:

- the creator's own pick (`by: "user"`) always applies to its clip;
- Claude's pick applies while the clip style's captions are "auto", or when it keeps the style the creator fixed;
- otherwise, and for a clip without a pick or the full take (""), the project's captions apply;
- a pick's `overrides` replace the project's; without them a pick keeps the project's overrides only when the styles
  match, else none.

Mac Core (CaptionLookTests) and Windows Core (CaptionLookVectorTests) replay every case.

    python3 -I tools/fixtures/clip-style/generate_caption_looks.py
"""
import json
import os
import sys

sys.dont_write_bytecode = True
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
OUT = os.path.join(REPO, "shared", "fixtures", "clip-style", "caption-look-cases.json")

UPPER = {"text": {"transform": "uppercase"}, "layout": {"maxWords": 3}}
ONE_WORD = {"layout": {"maxWords": 1, "maxLines": 1}}
PROJECT_OVERRIDES = {"accent": "#5CE1FF"}


def style(captions, picks):
    return {"preset": "auto" if captions == "auto" else "mine", "captions": captions, "music": "auto", "maxLengthSec": 60,
            "shapes": ["16:9", "9:16"], "rewording": "fix-only", "captionPicks": picks}


def resolve(captions, clip_style, clip):
    pick = (clip_style or {}).get("captionPicks", {}).get(clip) if clip else None
    if pick is not None and pick.get("by") != "user":
        fixed = None if clip_style["captions"] == "auto" else clip_style["captions"]
        if fixed is not None and pick["styleId"] != fixed:
            pick = None
    if pick is None:
        return {"styleId": captions["styleId"], "overrides": captions["overrides"]}
    overrides = pick.get("overrides")
    if overrides is None:
        overrides = captions["overrides"] if pick["styleId"] == captions["styleId"] else {}
    return {"styleId": pick["styleId"], "overrides": overrides}


def resolve_case(case_id, captions, clip_style, clips):
    return {"id": case_id, "captions": captions, "clipStyle": clip_style,
            "expected": {clip: resolve(captions, clip_style, clip) for clip in clips}}


def generated():
    project = {"styleId": "vox-highlight", "overrides": PROJECT_OVERRIDES}
    three = {
        "clip-1": {"styleId": "marker", "reason": "Bold claims.", "overrides": UPPER},
        "clip-2": {"styleId": "minimal", "reason": "A quiet story.", "overrides": ONE_WORD},
        "clip-3": {"styleId": "punch-in", "reason": "Fast tips."},
    }
    mixed = {
        "clip-1": {"styleId": "glow", "reason": "", "by": "user"},
        "clip-2": {"styleId": "marker", "reason": "Kept the fixed style.", "overrides": UPPER},
        "clip-3": {"styleId": "punch-in", "reason": "Another style."},
        "clip-4": {"styleId": "off", "reason": "", "by": "user"},
        "clip-5": {"styleId": "vox-highlight", "reason": "", "by": "user"},
    }
    clips = ["clip-1", "clip-2", "clip-3", "clip-4", "clip-5", "clip-z", ""]
    resolve_cases = [
        resolve_case("three-clips-three-looks", project, style("auto", three), clips),
        resolve_case("no-clip-style", project, None, clips),
        resolve_case("auto-without-picks", project, style("auto", {}), clips),
        resolve_case("fixed-keeps-the-creators-and-matching-picks", {"styleId": "marker", "overrides": {}}, style("marker", mixed), clips),
        resolve_case("auto-with-creator-picks", project, style("auto", mixed), clips),
        resolve_case("off-keeps-only-the-creators", {"styleId": "off", "overrides": {}}, style("off", mixed), clips),
    ]
    valid = [
        {"id": "claude-pick", "pick": {"styleId": "marker", "reason": "Bold claims."}},
        {"id": "claude-pick-with-overrides", "pick": {"styleId": "marker", "reason": "Bold claims.", "overrides": UPPER}},
        {"id": "creator-pick", "pick": {"styleId": "glow", "reason": "", "by": "user"}},
        {"id": "creator-pick-off", "pick": {"styleId": "off", "reason": "", "by": "user"}},
        {"id": "creator-pick-with-overrides", "pick": {"styleId": "minimal", "reason": "", "overrides": ONE_WORD, "by": "user"}},
        {"id": "empty-overrides", "pick": {"styleId": "minimal", "reason": "", "overrides": {}}},
    ]
    invalid = [
        {"id": "by-ai-is-never-written", "pick": {"styleId": "marker", "reason": "", "by": "ai"}},
        {"id": "by-claude", "pick": {"styleId": "marker", "reason": "", "by": "claude"}},
        {"id": "overrides-not-an-object", "pick": {"styleId": "marker", "reason": "", "overrides": "uppercase"}},
        {"id": "overrides-array", "pick": {"styleId": "marker", "reason": "", "overrides": [UPPER]}},
        {"id": "unknown-key", "pick": {"styleId": "marker", "reason": "", "position": {"x": 0.5}}},
        {"id": "auto-style", "runtimeOnly": True, "pick": {"styleId": "auto", "reason": "", "by": "user"}},
        {"id": "no-reason", "pick": {"styleId": "marker", "by": "user"}},
    ]
    return {
        "schema": "voxclip-caption-look-cases/1",
        "description": "Each clip's caption look (doc/design.md section 6.6): the picks a project stores and the captions a "
                       "render of each clip uses. Generated by tools/fixtures/clip-style/generate_caption_looks.py; do not "
                       "hand-edit.",
        "wire": {"valid": valid, "invalid": invalid},
        "resolve": resolve_cases,
    }


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(json.dumps(generated(), indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
