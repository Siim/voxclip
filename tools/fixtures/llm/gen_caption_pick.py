#!/usr/bin/env python3
"""Write shared/fixtures/llm/caption-pick.json: the clip style contract and the caption pick request (AI §15,
doc/design.md §6.9), produced independently of both apps. Standard library only; deterministic.

    python3 -I tools/fixtures/llm/gen_caption_pick.py
"""
import hashlib
import json
import math
import os
import sys

sys.dont_write_bytecode = True
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
SHARED = os.path.join(REPO, "shared")
OUT = os.path.join(SHARED, "fixtures", "llm", "caption-pick.json")

# ECMAScript WhiteSpace and LineTerminator (String.prototype.trim), as EditingPrimitives.jsTrim.
JS_SPACE = {chr(c) for c in (0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, *range(0x2000, 0x200B), 0x2028, 0x2029,
                                0x202F, 0x205F, 0x3000, 0xFEFF)}


def load(rel):
    with open(os.path.join(SHARED, rel), encoding="utf-8") as f:
        return json.load(f)


def js_trim(text):
    start, end = 0, len(text)
    while start < end and text[start] in JS_SPACE:
        start += 1
    while end > start and text[end - 1] in JS_SPACE:
        end -= 1
    return text[start:end]


def utf16_prefix(text, limit):
    units = text.encode("utf-16-le")[: 2 * max(0, limit)]
    if len(units) >= 2 and 0xD800 <= int.from_bytes(units[-2:], "little") <= 0xDBFF:
        units = units[:-2]
    return units.decode("utf-16-le")


def whole_seconds(seconds):
    if not math.isfinite(seconds) or seconds <= 0 or seconds >= 1e9:
        return 0
    return int(math.floor(seconds + 0.5))


def library():
    folder = os.path.join(SHARED, "caption-styles", "styles")
    styles = [load(os.path.join("caption-styles", "styles", name)) for name in sorted(os.listdir(folder)) if name.endswith(".json")]
    return sorted(styles, key=lambda s: (s.get("order", 500), s["id"]))


def preset(catalog, pid):
    return next(p for p in catalog["presets"] if p["id"] == pid)


def candidates(styles, catalog, pid):
    excluded = set(preset(catalog, pid)["excludeCaptionTags"])
    return [s for s in styles if not excluded & set(s.get("tags", []))]


def instruction(prompt, clips, cands, preset_label):
    req = prompt["request"]
    styles = "\n".join(req["styleLine"].replace("{id}", s["id"]).replace("{name}", s["name"]).replace("{description}", s["description"]) for s in cands)
    lines = []
    for index, clip in enumerate(clips[: prompt["limits"]["maxClips"]]):
        title = js_trim(clip.get("title") or "")
        lines.append(req["clipLine"].replace("{clip}", "C%d" % (index + 1)).replace("{seconds}", str(whole_seconds(clip["seconds"])))
                     .replace("{title}", title if title else "Untitled")
                     .replace("{text}", utf16_prefix(js_trim(clip["text"]), prompt["limits"]["maxClipChars"])))
    return req["instruction"].replace("{preset}", preset_label).replace("{styles}", styles).replace("{clips}", "\n".join(lines))


def picks(prompt, reply, clips, cand_ids):
    labels = {"C%d" % (i + 1): c["id"] for i, c in enumerate(clips[: prompt["limits"]["maxClips"]])}
    out, dropped = {}, 0
    for item in reply.get("picks", []):
        label = js_trim(item["clip"]) if isinstance(item.get("clip"), str) else None
        style = js_trim(item["style"]) if isinstance(item.get("style"), str) else None
        cid = labels.get(label)
        if cid is None or cid in out or style not in cand_ids or style == "auto":
            dropped += 1
            continue
        reason = js_trim(item["reason"]) if isinstance(item.get("reason"), str) else ""
        out[cid] = {"styleId": style, "reason": reason[: prompt["limits"]["maxReasonChars"]]}
    return out, dropped


def caption_style_for(style, clip):
    if style["captions"] != "auto":
        return style["captions"]
    if not clip:
        return None
    pick = style["captionPicks"].get(clip)
    return pick["styleId"] if pick else None


def recording(style, new):
    if style["captions"] != "auto":
        return style
    merged = dict(style["captionPicks"])
    merged.update(new)
    return dict(style, captionPicks=dict(sorted(merged.items())))


def fixing(style, choice):
    nxt = dict(style, captions=choice)
    if choice != "auto" and style["preset"] == "auto":
        nxt["preset"] = "mine"
    return nxt


def preset_style(catalog, pid):
    p = preset(catalog, pid)
    return {"preset": pid, "captions": p["captions"], "music": p["music"], "maxLengthSec": p["maxLengthSec"],
            "shapes": p["shapes"], "rewording": p["rewording"], "captionPicks": {}}


def summary(catalog, style):
    return "Style: %s · ≤%d s · %s" % (preset(catalog, style["preset"])["label"], style["maxLengthSec"], "+".join(style["shapes"]))


def main():
    prompt = load("prompts/caption-pick.json")
    catalog = load("data/clip-styles.json")
    styles = library()
    clips = [
        {"id": "clip-a", "title": "Stop doing this", "seconds": 24.5, "text": "Stop editing every clip by hand. Here is the one change that saved me ten hours a week."},
        {"id": "clip-b", "title": "  ", "seconds": 41.49, "text": "  When I was a kid my grandmother kept bees, and every summer we would sit by the hives at dusk.  "},
        {"id": "clip-c", "title": "Export settings", "seconds": 58.0, "text": "Open Export, choose 9:16, then turn on captions and pick the subtitle style before you render."},
        {"id": "clip-d", "title": None, "seconds": 0.4, "text": "x" * 599 + "\U0001F525 tail"},
    ]
    requests = []
    many = [dict(clips[2], id="clip-%02d" % i) for i in range(30)]
    for case_id, pid, subset in (("auto-four", "auto", clips), ("calm-two", "calm", clips[:2]), ("punchy-one", "punchy", clips[:1]), ("demo-limit", "demo", many)):
        cands = candidates(styles, catalog, pid)
        label = preset(catalog, pid)["label"]
        requests.append({"id": case_id, "preset": pid, "clips": subset,
                         "expected": {"candidates": [s["id"] for s in cands], "system": prompt["system"],
                                      "instruction": instruction(prompt, subset, cands, label), "schemaName": prompt["output"]["name"],
                                      "maxOutputTokens": prompt["generation"]["maxOutputTokens"], "effort": prompt["generation"]["effort"],
                                      "tag": "caption-pick %d clips" % min(len(subset), prompt["limits"]["maxClips"])}})
    auto_ids = [s["id"] for s in candidates(styles, catalog, "auto")]
    calm_ids = [s["id"] for s in candidates(styles, catalog, "calm")]
    replies = []
    for case_id, cand, reply in (
        ("valid", auto_ids, {"picks": [{"clip": "C1", "style": "punch-in", "reason": "Fast, direct advice; bold caps punch each word."},
                                       {"clip": "C2", "style": "minimal", "reason": "A quiet memory reads best in small sentence case."},
                                       {"clip": "C3", "style": "clean-subtitle", "reason": "Step-by-step demo: clear subtitles."}]}),
        ("drops", auto_ids, {"picks": [{"clip": "C9", "style": "marker", "reason": "unknown clip"},
                                       {"clip": " C1 ", "style": " marker ", "reason": "  " + "r" * 130 + "  "},
                                       {"clip": "C1", "style": "glow", "reason": "duplicate clip"},
                                       {"clip": "C2", "style": "auto", "reason": "auto is not a style"},
                                       {"clip": "C3", "style": "not-a-style", "reason": "unknown style"},
                                       {"clip": "C4", "style": "emoji-pop", "reason": "\U0001F525" * 125}]}),
        ("calm-excludes-emoji", calm_ids, {"picks": [{"clip": "C1", "style": "emoji-pop", "reason": "Emoji is excluded under Calm story."},
                                                     {"clip": "C2", "style": "sing-along", "reason": "Gentle lyric lines."}]}),
        ("empty", auto_ids, {"picks": []}),
    ):
        got, dropped = picks(prompt, reply, clips, set(cand))
        replies.append({"id": case_id, "candidates": cand, "clips": [c["id"] for c in clips], "reply": reply,
                        "expected": {"picks": dict(sorted(got.items())), "dropped": dropped}})
    auto = preset_style(catalog, "auto")
    picked = recording(auto, {"clip-a": {"styleId": "punch-in", "reason": "Fast advice."}, "clip-b": {"styleId": "minimal", "reason": "Quiet story."}})
    fixed_marker = fixing(picked, "marker")
    later = {"clip-a": {"styleId": "glow", "reason": "Later AI pick."}}
    replace = {"clip-b": {"styleId": "sing-along", "reason": "Replaced."}, "clip-c": {"styleId": "clean-subtitle", "reason": "New."}}
    assert recording(fixed_marker, later) == fixed_marker
    probes = ["clip-a", "clip-b", "clip-z", ""]
    cases = [{"id": "preset-" + p["id"], "op": "preset", "preset": p["id"],
              "expected": {"style": preset_style(catalog, p["id"]), "summary": summary(catalog, preset_style(catalog, p["id"]))}} for p in catalog["presets"]]
    for case_id, style in (("auto-resolves-picks", picked), ("fixed-wins", fixed_marker), ("off-wins", fixing(picked, "off")), ("auto-without-picks", auto)):
        cases.append({"id": case_id, "op": "resolve", "style": style, "expected": {"resolved": {p: caption_style_for(style, p) for p in probes}}})
    cases += [
        {"id": "fixed-never-overridden", "op": "record", "style": fixed_marker, "picks": later, "expected": {"style": recording(fixed_marker, later)}},
        {"id": "auto-records-and-replaces", "op": "record", "style": picked, "picks": replace, "expected": {"style": recording(picked, replace)}},
        {"id": "fix-from-auto-becomes-mine", "op": "fix", "style": picked, "choice": "marker", "expected": {"style": fixed_marker}},
        {"id": "fix-keeps-named-preset", "op": "fix", "style": preset_style(catalog, "calm"), "choice": "glow", "expected": {"style": fixing(preset_style(catalog, "calm"), "glow")}},
        {"id": "back-to-auto", "op": "fix", "style": fixed_marker, "choice": "auto", "expected": {"style": fixing(fixed_marker, "auto")}},
    ]
    def sha(rel):
        with open(os.path.join(SHARED, rel), "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    doc = {"fixture": "voxclip-caption-pick/1",
           "description": "Clip style contract (design.md 6.9) and the caption pick request (AI 15). Generated by tools/fixtures/llm/gen_caption_pick.py; do not edit by hand. Both Cores replay every case.",
           "promptSha256": sha("prompts/caption-pick.json"), "clipStylesSha256": sha("data/clip-styles.json"),
           "libraryStyles": [s["id"] for s in styles], "requests": requests, "replies": replies, "clipStyles": cases}
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print("wrote %s: %d requests, %d replies, %d clip style cases" % (os.path.relpath(OUT, REPO), len(requests), len(replies), len(cases)))


if __name__ == "__main__":
    sys.exit(main())
