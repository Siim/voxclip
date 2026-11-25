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
        "music": {**obj({"trackId": text(), "brief": text(500)}), **one_of("trackId", "brief")},
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
        **obj({"target": target, "reason": reason, **edits}, ["target", "reason"]),
        "anyOf": [requires(key) for key in edits],
        "allOf": [parts_for_new({"properties": {"target": requires("new")}}, "target")],
    })
    legacy_music = {"musicTrackId": {**text(), "deprecated": True}, "generateMusic": {**text(500), "deprecated": True}}
    legacy_edits = {key: edits[key] for key in ("cuts", "captionStyle", "title", "effects")} | legacy_music
    legacy = {**obj({"clipId": clip_id, "reason": reason, **legacy_edits}, ["clipId", "reason"]),
              "anyOf": [requires(key) for key in legacy_edits], "not": requires(*legacy_music)}
    harness_edits = {**edits, "effects": {**edits["effects"], "description": (
        "Use any clip-plan entry. Footage references a sourceKey from read_clips. "
        "Asset requests are reviewed in VoxClip; this tool never sends or spends.")}}
    write("harness-timeline", "VoxClip harness timeline v2", {
        **obj({"clipId": clip_id, "newClip": new_clip, "reason": reason, **harness_edits, **legacy_music}, ["reason"]),
        **one_of("clipId", "newClip"), "anyOf": [requires(key) for key in edits | legacy_music],
        "allOf": [parts_for_new(requires("newClip"), "newClip"),
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
