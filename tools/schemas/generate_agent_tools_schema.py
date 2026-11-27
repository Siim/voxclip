#!/usr/bin/env python3
"""Generate the live agent's inputs without extending the saved-file harness schema."""

import copy
import json
from pathlib import Path


SCHEMAS = Path(__file__).resolve().parents[2] / "shared/schemas"
PANELS = ["captions", "music", "rewrite", "export", "settingsAI", "outline"]
OFFERS = ["generateMusic", "revoice", "illustration", "lipSync", "makeItPostable"]


def text(maximum, description=None):
    schema = {"type": "string", "minLength": 1, "maxLength": maximum}
    if description:
        schema["description"] = description
    return schema


def array(item, maximum, minimum=0):
    return {"type": "array", "items": item, "minItems": minimum, "maxItems": maximum}


def obj(properties, *required):
    return {"type": "object", "properties": properties, "required": list(required), "additionalProperties": False}


def generate():
    timeline = json.loads((SCHEMAS / "harness-timeline.schema.json").read_text())
    metadata = {key: timeline.pop(key) for key in ("$schema", "$id")}
    timeline["properties"]["label"] = text(120, "Short label for this timeline's changes on the turn card.")
    revises = text(200, "ID of a pending turn to replace in the live project.")
    single = copy.deepcopy(timeline)
    single["properties"]["revises"] = revises
    return {
        **metadata,
        "$id": metadata["$id"].replace("harness-timeline", "agent-tools"),
        "title": "VoxClip live agent tool inputs",
        "$defs": {
            "propose_timeline": {"oneOf": [single, obj({"timelines": array(timeline, 6, 1), "revises": revises}, "timelines")]},
            "check": obj({"clipId": text(200), "targets": array(text(32), 8)}, "clipId"),
            "find_music": obj({"mood": text(200), "lengthSeconds": {"type": "number", "exclusiveMinimum": 0}}, "mood", "lengthSeconds"),
            "offer": obj({"kind": {"enum": OFFERS}, "target": text(200, "Clip id from read_clips."),
                          "brief": text(2000), "words": array(text(200), 500)}, "kind", "target"),
            "point_to": obj({"panel": {"enum": PANELS}, "target": text(200)}, "panel"),
        },
    }


if __name__ == "__main__":
    (SCHEMAS / "agent-tools.schema.json").write_text(json.dumps(generate(), indent=2) + "\n")
