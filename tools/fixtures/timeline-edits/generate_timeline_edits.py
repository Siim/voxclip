#!/usr/bin/env python3
import copy
import json
import math
from pathlib import Path


SHARED = Path(__file__).resolve().parents[3] / "shared" / "fixtures"
OUTPUT = SHARED / "timeline-edits"
RATE = 48_000
CLIP = "clip-main"
INSIDE_PART = "Place it inside one part."
WHOLE_WORDS = "A bleep covers whole words. Trim it to fewer words instead."
READ_ONLY = "This item is read-only."
NO_ITEM = "Select an item on this timeline."


def load(path):
    return json.loads((SHARED / path).read_text())


def write(path, bases, cases):
    wrapper = {"sampleRate": RATE, "bases": bases, "cases": cases}
    (OUTPUT / path).write_text(json.dumps(wrapper, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def samples(time):
    return math.floor(time * RATE + 0.5)


def plan(*kept, seams=(), duration=8):
    return {"kept": [[samples(start), samples(end)] for start, end in kept],
            "seams": [samples(seam) for seam in seams], "total": samples(duration)}


def cadence():
    project = load("clip-effects/effects-project.voxclip")
    templates = project.pop("clipEffects")
    project["media"]["source"]["durationSeconds"] = 8
    template = project["transcript"]["words"][0]
    project["transcript"]["words"] = [dict(template, id=f"w{index + 1}", start=index / 2, end=(index + 1) / 2,
                                            rawStart=index / 2, rawEnd=(index + 1) / 2) for index in range(16)]
    project["edits"]["clips"][0]["endWordId"] = "w16"
    project["edits"]["corrections"] = {}
    return project, templates


def story(project, reverse=False):
    result = copy.deepcopy(project)
    result["schemaVersion"] = 6
    parts = [dict(id="first", startWordId="w1", endWordId="w8"), dict(id="second", startWordId="w9", endWordId="w16")]
    result["edits"]["clips"][0].update(kind="story", parts=parts[::-1] if reverse else parts)
    return result


def layout_item(identity, kind, lane, anchor, edited, axis=None, part=CLIP, row=0, marker=None, notches=(), reason=None):
    return dict(id=identity, kind=kind, lane=lane, row=row, part=part, anchor=anchor, edited=edited,
                axis=edited if axis is None else axis, hidden=not edited, marker=marker, notches=notches, reason=reason)


def edit_vectors(project, templates, asset, track):
    bases = {}
    cases = []
    effects = [dict(value, id=value["kind"], clipId=CLIP, start=2, end=3) for value in templates]
    effects.append(dict(id="motionTemplate", kind="motionTemplate", clipId=CLIP, start=2, end=3,
                        template=dict(name="titleCard", text="A faster edit")))

    def edit(base, op, change=None, undo=None, refusal=None, label=None, scope=CLIP, edit_plan=None, **parameters):
        row = dict(name=label or f"{base}/{op}", base=base, scope=scope, plan=edit_plan or plan((0, 8)), edit=dict(op=op, **parameters))
        if refusal:
            row["refusal"] = refusal
        else:
            row["expected"] = {"schemaVersion": 6, **(change or {})}
            row["undo"] = undo
        cases.append(row)

    for kind, item_type, original in [(value["kind"], "effect", value) for value in effects] + [
        (kind, "footage", dict(id=kind, kind=kind, clipID=CLIP, start=2, end=3, footage=dict(sourceKey=asset["recordingHash"], start=0.5)))
        for kind in ["bRoll", "screenshot", "videoStack"]
    ] + [
        ("zoom", "motion", dict(id="zoom", clipID=CLIP, sourceStart=2, sourceEnd=3,
                                keyframes=[dict(progress=0, scale=1, anchorX=0.5, anchorY=0.5),
                                           dict(progress=1, scale=1.25, anchorX=0.5, anchorY=0.5)])),
        ("music", "music", dict(id="music", anchorSeconds=2, lengthSeconds=1, songFromSeconds=0.5, loop=True, gainDb=0,
                               fadeInSeconds=0.25, fadeOutSeconds=0.125))
    ]:
        basis = copy.deepcopy(project)
        if kind in ("bleep", "mute"):
            original["wordIds"] = ["w5", "w6"]
        if kind == "sound":
            original["sound"]["durationSeconds"] = 2
            original["mediaOffsetSeconds"] = 0.125
        if kind in ("music", "sound"):
            original["gainPoints"] = [dict(t=0.25, db=-8), dict(t=0.75, db=-12)]
            basis["schemaVersion"] = 6

        def fields(*values, **track_changes):
            if item_type == "effect":
                return dict(clipEffects=list(values) or None)
            if item_type == "footage":
                media = dict(basis["media"], additionalSources=[asset])
                media.pop("footage", None)
                if values:
                    media["footage"] = list(values)
                return dict(media=media)
            if item_type == "motion":
                return dict(motionCues=list(values) or None)
            return dict(music=[dict(track, segments=list(values), **track_changes)] if values else None)

        basis.update(fields(original))
        bases[kind] = basis
        identity = [item_type, kind]
        start_key, end_key = {"motion": ("sourceStart", "sourceEnd"), "music": ("anchorSeconds", "lengthSeconds")}.get(item_type, ("start", "end"))

        def span(start, end, **changes):
            end_value = end if item_type != "music" else (samples(end) - samples(start)) / RATE
            value = dict(original, **{start_key: start, end_key: end_value}, **changes)
            return value

        def at_anchor(start, end, **changes):
            value = span(start, end, **changes)
            if original.get("track"):
                value["track"] = [dict(point, t=(samples(point["t"]) + samples(start) - 2 * RATE) / RATE) for point in original["track"]]
            return value

        def case(op, *values, undo=None, refusal=None, multi=False, patch=None, **params):
            selector = {"items": [identity]} if multi else {"item": identity}
            edit(kind, op, patch if patch is not None else fields(*values), undo, refusal, **selector, **params)

        label = {"lowerThird": "lower third", "sticker": "emoji", "motionTemplate": "template", "bRoll": "B-roll",
                 "videoStack": "video stack", "colourLook": "look", "speedForPart": "speed change"}.get(kind, kind)
        word_locked = kind in ("bleep", "mute")
        audio = kind in ("sound", "music")
        fader = item_type != "motion" and kind not in ("bleep", "mute", "speedForPart", "freeze")
        moved = 3 + 1 / RATE
        moved_item = span(3, 4, wordIds=["w7", "w8"]) if word_locked else at_anchor(moved, 4 + 1 / RATE)
        case("move", moved_item, undo=f"Move {label}", multi=True, source=3.000013)
        trimmed = span(2.5, 3, wordIds=["w6"]) if word_locked else span(2.25, 3)
        if kind == "sound":
            trimmed.update(mediaOffsetSeconds=0.375, gainPoints=[dict(t=0, db=-8), dict(t=0.5, db=-12)])
        elif kind == "music":
            trimmed.update(songFromSeconds=0.75, gainPoints=[dict(t=0, db=-8), dict(t=0.5, db=-12)])
        elif item_type == "footage" and kind != "screenshot":
            trimmed["footage"] = dict(original["footage"], start=0.75)
        case("trim", trimmed, undo=f"Trim {label}", edge="start", source=2.49 if word_locked else 2.250005)

        if word_locked:
            case("split", refusal=WHOLE_WORDS, multi=True, source=2.5)
        else:
            left, right = span(2, 2.5), span(2.5, 3, id=kind + "-2")
            if fader and kind != "illustration":
                left["fadeOutSeconds"] = 0
                right["fadeInSeconds"] = 0
            if kind == "zoom":
                pose = dict(scale=1.125, anchorX=0.5, anchorY=0.5)
                left["keyframes"] = [original["keyframes"][0], dict(progress=1, **pose)]
                right["keyframes"] = [dict(progress=0, **pose), original["keyframes"][1]]
            if audio:
                left["gainPoints"] = [dict(t=0.25, db=-8), dict(t=0.5, db=-10)]
                right["gainPoints"] = [dict(t=0, db=-10), dict(t=0.25, db=-12)]
            if kind == "music":
                right["songFromSeconds"] = 1
            if kind == "sound":
                right["mediaOffsetSeconds"] = 0.625
            if item_type == "footage" and kind != "screenshot":
                right["footage"] = dict(original["footage"], start=1)
            case("split", left, right, undo=f"Split {label}", multi=True, source=2.5)
        expected_edits = copy.deepcopy(basis["edits"])
        expected_edits["clips"][0].update(kind="story", parts=[dict(id=CLIP, startWordId="w1", endWordId="w5"),
                                                              dict(id=f"{CLIP}-2", startWordId="w6", endWordId="w16")])
        split_items = fields(original) if word_locked else fields(left, right)
        edit(kind, "splitAll", dict(edits=expected_edits, **split_items), "Split all", source=2.5)

        case("fade", dict(original, fadeInSeconds=0.25), undo=f"Fade {label}",
             refusal=None if fader else f"You can’t fade this {label}.", edge="start", seconds=0.250005)
        for op, params, changes, undo in [
            ("setGain", dict(db=-7), dict(gainDb=-7), "Change volume"),
            ("addGainPoint", dict(source=2.5, db=-10), dict(gainPoints=[dict(t=0.25, db=-8), dict(t=0.5, db=-10), dict(t=0.75, db=-12)]), "Add volume keyframe"),
            ("moveGainPoint", dict(old=0.25, source=2.125, db=-6), dict(gainPoints=[dict(t=0.125, db=-6), dict(t=0.75, db=-12)]), "Move volume keyframe"),
            ("removeGainPoint", dict(old=0.25), dict(gainPoints=[dict(t=0.75, db=-12)]), "Remove volume keyframe"),
        ]:
            case(op, dict(original, **changes), undo=undo, refusal=None if audio else f"You can’t change the volume of this {label}.", **params)
        slipped = dict(original)
        if kind == "sound":
            slipped["mediaOffsetSeconds"] = 0.25
        if kind == "music":
            slipped["songFromSeconds"] = 0.625
        if item_type == "footage":
            slipped["footage"] = dict(original["footage"], start=0.625)
        case("slip", slipped, undo=f"Slip {label}", refusal=None if audio or item_type == "footage" else f"You can’t slip this {label}.", seconds=0.125)
        case("setLoop", dict(original, loop=False), undo="Loop music", refusal=None if kind == "music" else f"You can’t loop this {label}.", enabled=False)
        edit(kind, "setDuck", fields(original, duckDb=-18) if kind == "music" else {}, "Change ducking",
             refusal=None if kind == "music" else NO_ITEM, track=track["id"], db=-18)
        case("duplicate", original, dict(moved_item, id=kind + "-2"), undo=f"Duplicate {label}", multi=True, source=3.000013)
        case("delete", undo=f"Delete {label}", multi=True)
        frame = 1 / 30
        case("nudge", at_anchor(2 + frame, 3 + frame) if not word_locked else original, undo=f"Nudge {label}", multi=True, unit="frames", count=1,
             patch=dict(schemaVersion=basis["schemaVersion"]) if word_locked else None)
        later = at_anchor(2.5, 3.5, **({"wordIds": ["w6", "w7"]} if word_locked else {}))
        edit(kind, "nudge", fields(later), f"Nudge {label}", label=f"{kind}/nudge-word", items=[identity], unit="words", count=1)

    bases["bed"] = dict(project, music=[track])
    bed = dict(id=track["id"], anchorSeconds=0.5, lengthSeconds=7.5, songFromSeconds=track["startOffsetSeconds"], loop=True,
               gainDb=0, fadeInSeconds=track["fadeInSeconds"], fadeOutSeconds=track["fadeOutSeconds"])
    edit("bed", "setGain", dict(music=[dict(track, segments=[dict(bed, gainDb=-4)])]), "Change volume", edit_plan=plan((0.5, 8)),
         item=["music", track["id"]], db=-4)
    edit("bed", "setTrackGain", dict(music=[dict(track, gainDb=-40)]), "Change volume",
         edit_plan=plan((0.5, 8)), track=track["id"], db=-50)
    edit("bed", "setTrackGain", dict(schemaVersion=bases["bed"]["schemaVersion"]), "Change volume", label="bed/unchanged-track-gain",
         track=track["id"], db=track["gainDb"])
    edit("music", "setTrackGain", dict(music=[dict(bases["music"]["music"][0], gainDb=-10)]), "Change volume",
         track=track["id"], db=-10)
    edit("bed", "setTrackGain", refusal=NO_ITEM, label="bed/track-outside-scope", scope=None, track=track["id"], db=-10)
    edit("bed", "delete", dict(music=None), "Delete music", items=[["music", track["id"]]])
    bases["nonloop"] = dict(bases["music"], music=[dict(track, asset=dict(track["asset"], durationSeconds=161),
                                                      segments=[dict(bases["music"]["music"][0]["segments"][0], loop=False, songFromSeconds=160)])])
    edit("nonloop", "trim", refusal="The song ends at 2:41. Turn on Loop to extend it.", item=["music", "music"], edge="end", source=3.5)
    bases["story"] = story(bases["title"])
    edit("story", "move", refusal=INSIDE_PART, items=[["effect", "title"]], source=3.5, edit_plan=plan((0, 4), (4, 8), seams=[4]))
    reversed_story = story(bases["title"], reverse=True)
    edit("story", "move", dict(edits=reversed_story["edits"]), "Move part", label="story/reorder", items=[["part", "first"]], source=4,
         edit_plan=plan((0, 4), (4, 8), seams=[4]))
    edit("story", "trim", dict(edits=dict(bases["story"]["edits"], clips=[dict(bases["story"]["edits"]["clips"][0],
         parts=[dict(id="first", startWordId="w1", endWordId="w4"), dict(id="second", startWordId="w9", endWordId="w16")])])),
         "Trim part 1", label="story/trim-retains-title", item=["part", "first"], edge="end", source=2,
         edit_plan=plan((0, 4), (4, 8), seams=[4]))
    bases["paid"] = load("voice-lab/lipsync-render-v3.voxclip")
    edit("paid", "trim", refusal="Part 1 cuts through a lip-synced stretch. Include all of 0:01–0:04 or none of it.",
         edit_plan=plan((1.05, 4.45), duration=7), item=["clip", CLIP], edge="end", source=3.1)
    bases["stretch"] = project
    clip = project["edits"]["clips"][0]
    start_clip = dict(clip, startWordId="w6")
    edit("stretch", "trim", dict(edits=dict(project["edits"], clips=[start_clip])), "Trim clip", item=["clip", CLIP], edge="start", source=2.5)
    edit("stretch", "split", refusal="Use Split All to split speech.", items=[["clip", CLIP]], source=2.5)
    edit("stretch", "duplicate", refusal=READ_ONLY, items=[["clip", CLIP]])
    edit("stretch", "delete", refusal=READ_ONLY, items=[["clip", CLIP]])
    bases["contextDemo"] = load("context-demo/v4-project.voxclip")
    for base, item, scope, operations in [
        ("contextDemo", ["contextDemo", "placement-a"], None, {"move", "nudge", "trim", "split", "fade", "setGain", "addGainPoint",
         "moveGainPoint", "removeGainPoint", "slip", "setLoop", "duplicate", "delete"}),
        ("stretch", ["clip", CLIP], CLIP, {"move", "nudge", "fade", "setGain", "addGainPoint", "moveGainPoint", "removeGainPoint", "slip", "setLoop"}),
        ("story", ["part", "first"], CLIP, {"split", "fade", "setGain", "addGainPoint", "moveGainPoint", "removeGainPoint", "slip", "setLoop", "duplicate", "delete"}),
    ]:
        for op in sorted(operations):
            selector = {"items": [item]} if op in ("move", "nudge", "split", "duplicate", "delete") else {"item": item}
            refusal = "Use Split All to split speech." if op == "split" and item[0] == "part" else READ_ONLY
            edit(base, op, refusal=refusal, scope=scope, edit_plan=plan((0, 7), duration=7) if scope is None else None,
                 **selector, source=2, unit="frames", count=1, seconds=0.25, db=-5, old=0, edge="start", enabled=False)
        edit(base, "setDuck", refusal=NO_ITEM, scope=scope, track=track["id"], db=-10)

    full_title = dict(bases["title"]["clipEffects"][0], clipId=None)
    bases["full"] = dict(project, clipEffects=[full_title])
    new_clip = dict(id="clip-2", startWordId="w1", endWordId="w16", title=None, origin="manual", aiResultId=None,
                    aiClipIndex=None, selected=True, kind="story", parts=[dict(id="clip-2", startWordId="w1", endWordId="w5"),
                                                                         dict(id="clip-2-2", startWordId="w6", endWordId="w16")])
    edit("full", "splitAll", dict(edits=dict(project["edits"], activeClipId="clip-2", clips=project["edits"]["clips"] + [new_clip]),
         clipEffects=[full_title, dict(full_title, id="title-2", clipId="clip-2", end=2.5, fadeOutSeconds=0),
                      dict(full_title, id="title-2-2", clipId="clip-2", start=2.5, fadeInSeconds=0)]), "Split all", scope=None, source=2.5)
    bases["pause"] = copy.deepcopy(bases["title"])
    bases["pause"]["clipEffects"][0]["end"] = 4
    for word in bases["pause"]["transcript"]["words"][5:]:
        for key in ["start", "end", "rawStart", "rawEnd"]:
            word[key] += 1
    bases["pause"]["media"]["source"]["durationSeconds"] = 9
    pause_clip = dict(clip, kind="story", parts=[dict(id=CLIP, startWordId="w1", endWordId="w5"),
                                                dict(id=f"{CLIP}-2", startWordId="w6", endWordId="w16")])
    pause_title = bases["pause"]["clipEffects"][0]
    edit("pause", "splitAll", dict(edits=dict(project["edits"], clips=[pause_clip]),
         clipEffects=[dict(pause_title, end=2.75, fadeOutSeconds=0), dict(pause_title, id="title-2", start=3.38, fadeInSeconds=0)]),
         "Split all", edit_plan=plan((0, 9), duration=9), source=3)
    bases["paid-before-window"] = copy.deepcopy(bases["paid"])
    bases["paid-before-window"]["edits"]["clips"][0]["startWordId"] = "w1"
    paid_trim = dict(bases["paid-before-window"]["edits"]["clips"][0], endWordId="w2")
    edit("paid-before-window", "trim", dict(edits=dict(bases["paid-before-window"]["edits"], clips=[paid_trim])), "Trim clip",
         item=["clip", CLIP], edge="end", source=1, edit_plan=plan((0.18, 4.45), duration=7))
    bases["paid-story"] = load("voice-lab/recorded-lipsync-render-v3.voxclip")
    bases["paid-story"]["schemaVersion"] = 6
    bases["paid-story"]["edits"]["clips"][0].update(kind="story", startWordId="w1", parts=[
        dict(id="opening", startWordId="w1", endWordId="w2"), dict(id="paid-part", startWordId="w3", endWordId="w8")])
    edit("paid-story", "trim", refusal="Part 2 cuts through a lip-synced stretch. Include all of 0:01–0:04 or none of it.",
         item=["part", "paid-part"], edge="end", source=3.4, edit_plan=plan((0.18, 1.05), (1.05, 4.45), seams=[0.87], duration=7))
    exhausted = copy.deepcopy(bases["music"])
    segment = exhausted["music"][0]["segments"][0]
    exhausted["music"][0]["segments"] = [dict(segment, id=f"segment-{index}") for index in range(8)]
    bases["eight-segments"] = exhausted
    edit("eight-segments", "duplicate", refusal="A track can have up to 8 segments.", items=[["music", "segment-0"]])
    edit("zoom", "split", refusal="Too short to split here.", label="zoom/split-too-short", items=[["motion", "zoom"]], source=2.125)
    edit("sound", "addGainPoint", refusal="There is already a volume keyframe here.", label="sound/reject-duplicate-keyframe",
         item=["effect", "sound"], source=2.25, db=-6)
    sound = bases["sound"]["clipEffects"][0]
    edit("sound", "dipGain", dict(clipEffects=[dict(sound, gainPoints=[
        dict(t=0.125, db=-8), dict(t=0.175, db=-14), dict(t=0.825, db=-18), dict(t=0.875, db=-12),
    ])]), "Dip volume", item=["effect", "sound"], fromSource=2.125005, toSource=2.875005, byDb=-6)
    music = bases["music"]["music"][0]
    segment = music["segments"][0]
    edit("music", "dipGain", dict(music=[dict(music, segments=[dict(segment, gainPoints=[
        dict(t=0.125, db=-8), dict(t=7500 / RATE, db=-60), dict(t=9001 / RATE, db=-60), dict(t=10501 / RATE, db=-8),
        *segment["gainPoints"],
    ])])]), "Dip volume", item=["music", "music"], fromSource=2.125, toSource=2 + 10501 / RATE, byDb=-75)
    edit("sound", "dipGain", refusal="Select a longer range inside the item.", label="sound/dip-below-three-samples",
         item=["effect", "sound"], fromSource=2.5, toSource=2.5 + 2 / RATE, byDb=-6)
    bases["dense-sound"] = dict(bases["sound"], clipEffects=[dict(sound, gainPoints=[
        dict(t=index / 256, db=-8) for index in range(61)
    ])])
    edit("dense-sound", "dipGain", refusal="An item can have up to 64 volume keyframes.",
         item=["effect", "sound"], fromSource=2.5, toSource=2.75, byDb=-6)
    edit("dense-sound", "dipGain", undo="Dip volume", label="dense-sound/zero-depth-dip",
         item=["effect", "sound"], fromSource=2.5, toSource=2.75, byDb=0)
    edit("bRoll", "duplicate", refusal="Place it where no other recording plays.", label="bRoll/reject-overlap", items=[["footage", "bRoll"]], source=2.2)
    media = bases["bRoll"]["media"]
    edit("bRoll", "duplicate", dict(media=dict(media, footage=media["footage"] + [dict(media["footage"][0], id="bRoll-2", start=3, end=4)])),
         "Duplicate B-roll", label="bRoll/duplicate-without-overlap", items=[["footage", "bRoll"]])
    edit("title", "move", refusal=NO_ITEM, label="selection/refuse-atomically", items=[["effect", "title"], ["effect", "missing"]], source=4)
    return bases, cases


def layout_vectors(project, edit_bases):
    bases = {}
    cases = []
    title = edit_bases["title"]["clipEffects"][0]
    sound = edit_bases["sound"]["clipEffects"][0]
    bases["connected"] = dict(project, schemaVersion=6, clipEffects=[title, dict(title, id="title-next", start=2.25, end=3.5), sound])

    def layout(base, label, edit_plan, items, axis="edited", scope=CLIP, rows=None, snaps=(), missing=(), playhead=None, all_items=False):
        cases.append(dict(name=label, base=base, plan=edit_plan, scope=scope, axis=axis, items=items,
                          rows=rows or {}, snaps=snaps, missing=missing, playhead=playhead, allItems=all_items))

    layout("connected", "cut anchor and hide covered words", plan((0, 2), (3, 8)), [
        layout_item(["effect", "title"], "title", "T1", 2, [], marker=2, reason="Hidden · its words are cut"),
        layout_item(["effect", "title-next"], "title", "T1", 2.25, [[2, 2.5]]),
        layout_item(["clip", CLIP], "clip", "V1", 0, [[0, 2], [2, 7]], notches=[2]),
        layout_item(["effect", "sound"], "sound", "S1", 2, [[2, 3]]),
    ], rows=dict(T1=1), snaps=[[2, "word", None], [2, "playhead", None], [2.25, "gainPoint", ["effect", "sound"]], [7, "scopeEdge", None]], playhead=2,
        all_items=True)
    layout("connected", "restore both placements and stack overlaps", plan((0, 8)), [
        layout_item(["effect", "title"], "title", "T1", 2, [[2, 3]]),
        layout_item(["effect", "title-next"], "title", "T1", 2.25, [[2.25, 3.5]], row=1),
        layout_item(["effect", "sound"], "sound", "S1", 2, [[2, 3]]),
    ], rows=dict(T1=2, CC=1, M1=1), snaps=[[3, "item", ["effect", "sound"]], [2.75, "gainPoint", ["effect", "sound"]]])
    layout("connected", "source axis keeps cut word targets", plan((0, 2), (3, 8)), [
        layout_item(["effect", "title"], "title", "T1", 2, [], marker=2, reason="Hidden · its words are cut"),
        layout_item(["effect", "sound"], "sound", "S1", 2, [[2, 3]], axis=[[2, 4]]),
    ], axis="source", snaps=[[2.5, "word", None], [3.25, "gainPoint", ["effect", "sound"]]])
    cases[-1]["drop"] = dict(time=2.5, anchor=2.5, hint="Lands on a cut · plays at the seam")
    layout("connected", "edited axis omits fully cut word targets", plan((0, 2), (3, 8)), [], missing=[[2.25, "word", None]])
    cases[-1]["drop"] = dict(time=2, anchor=3, hint=None)
    bases["split-range"] = dict(project, clipEffects=[dict(title, start=1.5, end=3.5)])
    layout("split-range", "covered range keeps a cut notch", plan((0, 2), (3, 8)), [
        layout_item(["effect", "title"], "title", "T1", 1.5, [[1.5, 2], [2, 2.5]], notches=[2])])
    bases["silence-under-cut-words"] = copy.deepcopy(edit_bases["pause"])
    bases["silence-under-cut-words"]["clipEffects"][0]["end"] = 3.5
    bases["silence-under-cut-words"]["edits"]["cutWordIds"] = ["w5"]
    layout("silence-under-cut-words", "title whose only word is cut stays hidden over remaining silence", plan((0, 2), (2.6, 9), duration=9), [
        layout_item(["effect", "title"], "title", "T1", 2, [], marker=2, reason="Hidden · its words are cut"),
    ])
    bases["trimmed"] = copy.deepcopy(bases["connected"])
    bases["trimmed"]["edits"]["clips"][0]["startWordId"] = "w8"
    layout("trimmed", "clip trim keeps the original placements hidden", plan((3.5, 8)), [
        layout_item(["effect", "title"], "title", "T1", 2, [], part=None, marker=0, reason="Hidden · outside this clip"),
        layout_item(["effect", "sound"], "sound", "S1", 2, [], part=None, marker=0, reason="Hidden · outside this clip"),
    ])
    bases["story"] = story(dict(bases["connected"], music=edit_bases["music"]["music"]))
    bases["story"]["music"][0]["segments"][0].update(anchorSeconds=3.5, lengthSeconds=2)
    bases["reordered"] = copy.deepcopy(bases["story"])
    bases["reordered"]["edits"]["clips"][0]["parts"].reverse()
    layout("story", "music plays through a story join", plan((0, 4), (4, 8), seams=[4]), [
        layout_item(["effect", "title"], "title", "T1", 2, [[2, 3]], part="first"),
        layout_item(["music", "music"], "music", "M1", 3.5, [[3.5, 5.5]], part="first"),
    ], snaps=[[4, "partSeam", None]])
    layout("reordered", "reorder carries connected items with their part", plan((4, 8), (0, 4), seams=[4]), [
        layout_item(["effect", "title"], "title", "T1", 2, [[6, 7]], part="first"),
        layout_item(["effect", "sound"], "sound", "S1", 2, [[6, 7]], part="first"),
        layout_item(["music", "music"], "music", "M1", 3.5, [[7.5, 8]], part="first"),
    ])
    layout("reordered", "cut anchor uses its reordered part seam", plan((4, 8), (0, 2), (3, 4), seams=[4]), [
        layout_item(["effect", "sound"], "sound", "S1", 2, [[6, 7]], part="first"),
    ])
    bases["short-recording"] = copy.deepcopy(edit_bases["bRoll"])
    bases["short-recording"]["schemaVersion"] = 6
    bases["short-recording"]["media"]["additionalSources"][0]["durationSeconds"] = 1.25
    layout("short-recording", "b-roll runs continuously and hatches its short tail", plan((0, 2.25), (2.5, 8)), [
        layout_item(["footage", "bRoll"], "bRoll", "B1", 2, [[2, 2.25], [2.25, 2.75]], notches=[2.25]),
    ])
    layout("short-recording", "restoring the cut exposes the recording limit", plan((0, 8)), [
        layout_item(["footage", "bRoll"], "bRoll", "B1", 2, [[2, 2.75]], reason="The recording ends here."),
    ])
    bases["context"] = edit_bases["contextDemo"]
    layout("context", "context-demo placement uses its edited clock", plan((0.5, 7), duration=7), [
        layout_item(["contextDemo", "placement-a"], "contextDemo", "B1", 1.5, [[1, 2]], part=None),
    ], scope=None)
    return bases, cases


def main():
    project, templates = cadence()
    asset = load("clip-effects/footage-project-cases.json")["companion"]
    track = load("music/music-project.voxclip")["music"][0]
    OUTPUT.mkdir(parents=True, exist_ok=True)
    edit_bases, edits = edit_vectors(project, templates, asset, track)
    layout_bases, layouts = layout_vectors(project, edit_bases)
    write("edit-cases.json", edit_bases, edits)
    write("layout-cases.json", layout_bases, layouts)


if __name__ == "__main__":
    main()
