#!/usr/bin/env python3
import json
from pathlib import Path


SCHEMAS = Path(__file__).resolve().parents[2] / "shared/schemas"
BASE = "https://raw.githubusercontent.com/Siim/voxclip/main/shared/schemas/"


def obj(properties, required=()):
    return {"type": "object", "additionalProperties": False, "properties": properties,
            **({"required": list(required)} if required else {})}


def text(limit=None):
    return {"type": "string", "minLength": 1, **({"maxLength": limit} if limit else {})}


def array(items, limit, minimum=1):
    return {"type": "array", "minItems": minimum, "maxItems": limit, "items": items}


def requires(*keys):
    return {"required": list(keys)}


def one_of(*keys):
    return {"oneOf": [requires(key) for key in keys]}


def timeline_commands(index, use_recording):
    number = {"type": "number"}
    seconds = {**number, "minimum": 0}
    count = {"type": "integer", "minimum": -2147483648, "maximum": 2147483647}
    single = {"item": text()}
    selection = {"items": {**array(text(), 30), "uniqueItems": True}}
    split = {"items": {**selection["items"], "minItems": 0}}
    def command(op, fields, optional=None):
        return obj({"op": {"const": op}, **fields, **(optional or {})}, ["op", *fields])
    content_key = {"type": "string", "pattern": "^[a-f0-9]{64}$"}
    variants = [command(use_recording["properties"]["op"]["const"], {"key": content_key},
                        {"transcriptRevision": {**content_key, "readOnly": True}}),
                command("trim", {**single, "edge": {"enum": ["start", "end"]}, "toWord": index}),
                command("splitAll", {"atWord": index}),
                command("fade", {**single, "edge": {"enum": ["in", "out"]}, "seconds": seconds}),
                command("setGain", {**single, "db": number}),
                command("setTrackGain", {"track": text(), "db": number}),
                command("dipGain", {**single, "startWord": index, "endWord": index, "byDb": number}),
                command("addGainPoint", {**single, "atWord": index, "db": number}),
                command("moveGainPoint", {**single, "fromSeconds": seconds, "toWord": index, "db": number}),
                command("removeGainPoint", {**single, "atSeconds": seconds}),
                command("slip", {**single, "bySeconds": number}),
                command("setLoop", {**single, "enabled": {"type": "boolean"}}),
                command("setDuck", {"track": text(), "db": number})]
    for selected in (single, selection):
        variants += [command("move", {**selected, "toWord": index}),
                     command("nudge", {**selected, "frames": count}), command("nudge", {**selected, "words": count}),
                     command("split", {**(split if selected == selection else single), "atWord": index}),
                     command("duplicate", selected, {"toWord": index}), command("delete", selected)]
    return {**array({"oneOf": variants}, 30), "contains": use_recording, "minContains": 0, "maxContains": 1}


def music_shape(index):
    def number(minimum, maximum):
        return {"type": "number", "minimum": minimum, "maximum": maximum}
    fades = {"fadeIn": number(0, 10), "fadeOut": number(0, 10)}
    segment = obj({"startWord": index, "endWord": index, "songFrom": number(0, 1800),
                   "loop": {"type": "boolean"}, "gainDb": number(-40, 12), **fades}, ["startWord", "endWord"])
    return {**fades, "duckDb": number(-24, 0), "segments": array(segment, 8, minimum=0)}


def write(name, title, body):
    filename = f"{name}.schema.json"
    schema = {"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": BASE + filename,
              "title": title, **body}
    (SCHEMAS / filename).write_text(json.dumps(schema, indent=2) + "\n")


def main():
    index = {"type": "integer", "minimum": 0}
    reason = text(240)
    span = {"startWord": index, "endWord": index}
    new_clip = obj({"kind": {"enum": ["stretch", "story", "showreel"]}, "title": text(120)}, ["kind", "title"])
    edits = {
        "parts": array(obj(span, span), 12),
        "cuts": array(obj({**span, "kind": {"enum": ["filler", "stumble", "repeat", "falseStart", "tangent", "other"]},
                           "reason": reason}, [*span, "kind", "reason"]), 30),
        "pauseCuts": array(obj({"afterWord": index, "reason": reason}, ["afterWord", "reason"]), 30),
        "corrections": array(obj({"word": index, "heard": text(120), "text": text(120), "reason": reason},
                                 ["word", "heard", "text", "reason"]), 30),
        "captionStyle": text(),
        "font": obj({"family": text(80), "weight": {"type": "integer", "minimum": 100, "maximum": 900}}, ["family", "weight"]),
        "case": {"enum": ["upper", "lower", "asSaid"]},
        "wordsPerCaption": {"type": "integer", "minimum": 1, "maximum": 12},
        "look": obj({"id": {"enum": ["original", "muted", "warm", "bw"]}, "reason": reason}, ["id"]),
        "speed": obj({"rate": {"type": "number", "minimum": 0.5, "maximum": 2}, "reason": reason}, ["rate"]),
        "hook": text(80), "title": text(120), "postText": text(500), "coverTitle": text(80),
        "music": {**obj({"trackId": text(), "brief": text(500), **music_shape(index)}), **one_of("trackId", "brief")},
        "effects": array({"$ref": "clip-plan-effect.schema.json"}, 12),
        "rewrites": array(obj({**span, "text": text(2000), "reason": reason}, [*span, "text", "reason"]), 12),
    }
    clip_id = {**text(), "description": "An existing clip id from read_clips."}
    target = {**obj({"clipId": clip_id, "new": new_clip}), **one_of("clipId", "new")}

    def parts_for_new(condition, target_key):
        return {"if": condition, "then": {**requires("parts"), "if": {"properties": {
            target_key: {"properties": {"kind": {"const": "stretch"}}} if target_key == "newClip" else {
                "properties": {"new": {"properties": {"kind": {"const": "stretch"}}}}},
        }}, "then": {"properties": {"parts": {"maxItems": 1}}},
            "else": {"properties": {"parts": {"minItems": 2}}}}}

    write("clip-proposal", "VoxClip canonical clip proposal", {
        **obj({"target": target, "reason": reason, **edits, "parts": array(obj({**span, "takeReason": text(160)}, span), 12)},
              ["target", "reason"]),
        "anyOf": [requires(key) for key in edits],
        "allOf": [parts_for_new({"properties": {"target": requires("new")}}, "target")],
    })
    legacy_music = {"musicTrackId": {**text(), "deprecated": True}, "generateMusic": {**text(500), "deprecated": True}}
    legacy_edits = {key: edits[key] for key in ("cuts", "captionStyle", "title", "effects")} | legacy_music
    legacy = {**obj({"clipId": clip_id, "reason": reason, **legacy_edits}, ["clipId", "reason"]),
              "anyOf": [requires(key) for key in legacy_edits], "not": requires(*legacy_music)}
    use_recording = {"properties": {"op": {"const": "useRecording"}}}
    harness_edits = {**edits, "edits": timeline_commands(index, use_recording), "effects": {**edits["effects"], "description": (
        "Use any clip-plan entry. Footage references a sourceKey from read_clips. "
        "Asset requests are reviewed in VoxClip; this tool never sends or spends.")}}
    write("harness-timeline", "VoxClip harness timeline v2", {
        **obj({"clipId": clip_id, "newClip": new_clip, "reason": reason, **harness_edits, **legacy_music}, ["reason"]),
        **one_of("clipId", "newClip"), "anyOf": [requires(key) for key in harness_edits | legacy_music],
        "allOf": [parts_for_new(requires("newClip"), "newClip"),
                  {"if": requires("newClip", "edits"), "then": {"properties": {"edits": {"items": use_recording}}}},
                  {"not": {"anyOf": [requires(first, second) for first, second in (
                      ("music", "musicTrackId"), ("music", "generateMusic"), ("musicTrackId", "generateMusic"))]}}],
    })
    write("harness-proposal", "VoxClip pending harness proposal", {
        **obj({"version": {"enum": [1, 2]}, "id": {"type": "string", "format": "uuid"},
               "projectId": text(), "baseRevision": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
               "timeline": legacy, "timelines": array({"$ref": "harness-timeline.schema.json"}, 6)},
              ["version", "id", "projectId", "baseRevision"]),
        "if": {"properties": {"version": {"const": 1}}},
        "then": {**requires("timeline"), "not": requires("timelines")},
        "else": {**requires("timelines"), "not": requires("timeline")},
    })


if __name__ == "__main__":
    main()
