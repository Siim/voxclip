#!/usr/bin/env python3
"""Generate tiny synthetic v4 wire fixtures; --patch emits an apply_patch input."""
import argparse
import copy
import difflib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
DESTINATION = ROOT / "shared" / "fixtures" / "context-demo"


def generated():
    project = json.loads((ROOT / "shared/fixtures/projects/interview-take.voxclip").read_text())
    project["schemaVersion"] = 4
    project["title"] = "Synthetic context demo wire fixture"
    project["edits"]["cutWordIds"] = []
    project["edits"]["cutPauseIds"] = []
    project["edits"]["clips"] = [{"id": "clip-main", "startWordId": "w1",
        "endWordId": project["transcript"]["words"][-1]["id"], "title": "Synthetic clip",
        "origin": "manual", "aiResultId": None, "aiClipIndex": None, "selected": True}]
    project["edits"]["activeClipId"] = "clip-main"
    project["voiceLab"] = {"segments": [], "assets": [], "cleanAudio": {"mode": "off", "assetId": None, "mix": None},
        "voices": [], "videoAssets": []}
    frame = {"progress": 0, "scale": 1, "anchorX": 0.5, "anchorY": 0.5}
    frames = [frame, {**frame, "progress": 1, "scale": 1.1}]
    cue = {"id": "motion-a", "clipID": "clip-main", "sourceStart": 1, "sourceEnd": 2, "keyframes": frames}
    project["motionCues"] = [cue]
    placement = {"id": "placement-a", "assetId": "demo-a", "source": {"start": 0, "end": 1}, "editedStartSeconds": 1}
    project["contextDemo"] = {"format": "voxclip-context-demo", "version": 1, "projectId": project["id"],
        "planId": "plan-a", "revision": 0, "sourceContentKey": project["media"]["source"]["contentKey"],
        "narration": {"sampleRate": 48000, "outputSamples": 336000, "pieces": [
            {"source": {"start": 0, "end": 7}, "output": {"start": 0, "end": 7}, "synthetic": False}]},
        "assets": [{"id": "demo-a", "requestId": "request-a",
            "target": {"kind": "webPage", "displayName": "Synthetic example", "locator": "https://example.com/demo"},
            "relativePath": f"context-demo/{project['id']}/demo-a.mp4", "sha256": "b" * 64,
            "durationSeconds": 2, "pixelWidth": 1280, "pixelHeight": 720, "byteSize": 4096,
            "createdAt": "2026-11-02T00:00:00.000Z"}], "placements": [placement]}

    def set_value(path, value):
        return {"path": path, "value": value}

    def remove(path):
        return {"path": path, "remove": True}

    invalid = []

    def reject(identity, path, value, schema_valid=False):
        invalid.append({"id": identity, "schemaValid": schema_valid, "patches": [set_value(path, value)]})

    for identity, path in [
        ("unknown-root", "/unexpected"), ("unknown-demo", "/contextDemo/unexpected"),
        ("unknown-narration", "/contextDemo/narration/unexpected"),
        ("unknown-piece", "/contextDemo/narration/pieces/0/unexpected"),
        ("unknown-range", "/contextDemo/narration/pieces/0/source/unexpected"),
        ("unknown-asset", "/contextDemo/assets/0/unexpected"),
        ("unknown-target", "/contextDemo/assets/0/target/unexpected"),
        ("unknown-placement", "/contextDemo/placements/0/unexpected"),
        ("unknown-motion", "/motionCues/0/unexpected"),
        ("unknown-keyframe", "/motionCues/0/keyframes/0/unexpected")]:
        reject(identity, path, True)
    reject("future-project", "/schemaVersion", 5)
    invalid[-1]["tooNew"] = True
    reject("future-demo", "/contextDemo/version", 2)
    invalid.append({"id": "v4-requires-v3-voice-policy", "schemaValid": False,
        "patches": [remove("/voiceLab/cleanAudio")]})
    reject("v4-unknown-voice-policy", "/voiceLab/cleanAudio/unexpected", True)
    reject("v4-numeric-voice-policy", "/voiceLab/cleanAudio/mode", 0)
    reject("null-demo", "/contextDemo", None)
    reject("null-motion", "/motionCues", None)
    invalid.append({"id": "missing-source-key", "schemaValid": False,
        "patches": [remove("/contextDemo/sourceContentKey")]})
    reject("source-key-binding", "/contextDemo/sourceContentKey", "c" * 64, True)
    reject("project-id-binding", "/contextDemo/projectId", "00000000-0000-0000-0000-000000000001", True)
    reject("invalid-source-key", "/contextDemo/sourceContentKey", "ABC")
    reject("negative-revision", "/contextDemo/revision", -1)
    reject("revision-overflow", "/contextDemo/revision", 2147483648)
    reject("unsafe-asset-path", "/contextDemo/assets/0/relativePath", "../demo.mp4")
    reject("wrong-project-asset-path", "/contextDemo/assets/0/relativePath",
        "context-demo/00000000-0000-0000-0000-000000000001/demo-a.mp4", True)
    reject("target-credentials", "/contextDemo/assets/0/target/locator", "https://user:password@example.com", True)
    reject("target-scheme", "/contextDemo/assets/0/target/locator", "ftp://example.com", True)
    reject("encoded-control-project-path", "/contextDemo/assets/0/target",
        {"kind": "codeProject", "displayName": "Synthetic project", "locator": "file:///tmp/project%00name"}, True)
    reject("unknown-target-kind", "/contextDemo/assets/0/target/kind", "shell")
    reject("numeric-target-kind", "/contextDemo/assets/0/target/kind", 2)
    reject("numeric-string-target-kind", "/contextDemo/assets/0/target/kind", "2")
    reject("target-kind-casing", "/contextDemo/assets/0/target/kind", "WebPage")
    reject("asset-hash", "/contextDemo/assets/0/sha256", "B" * 64)
    reject("asset-duration", "/contextDemo/assets/0/durationSeconds", 31)
    reject("asset-byte-budget", "/contextDemo/assets/0/byteSize", 67108865)
    reject("asset-odd-width", "/contextDemo/assets/0/pixelWidth", 1279)
    reject("asset-timestamp", "/contextDemo/assets/0/createdAt", "2026-11-02T00:00:00+02:00")
    reject("missing-asset", "/contextDemo/placements/0/assetId", "missing", True)
    reject("trim-past-asset", "/contextDemo/placements/0/source/end", 3, True)
    reject("trim-negative", "/contextDemo/placements/0/source/start", -1)
    reject("trim-empty", "/contextDemo/placements/0/source/end", 0, True)
    reject("placement-past-narration", "/contextDemo/placements/0/editedStartSeconds", 7, True)
    reject("placement-off-grid", "/contextDemo/placements/0/editedStartSeconds", 1.000001, True)
    reject("overlapping-placements", "/contextDemo/placements", [placement, {**placement, "id": "placement-b"}], True)
    reject("duplicate-assets", "/contextDemo/assets", project["contextDemo"]["assets"] * 2, True)
    reject("narration-output-samples", "/contextDemo/narration/outputSamples", 336001, True)
    reject("narration-hole", "/contextDemo/narration/pieces/0/output/start", 1, True)
    reject("narration-source-reversed", "/contextDemo/narration/pieces/0/source/start", 8, True)
    reject("narration-source-past-media", "/contextDemo/narration/pieces/0/source/end", 8, True)
    reject("narration-rate", "/contextDemo/narration/sampleRate", 0)
    reject("motion-unknown-clip", "/motionCues/0/clipID", "missing", True)
    reject("motion-past-media", "/motionCues/0/sourceEnd", 8, True)
    reject("motion-short", "/motionCues/0/sourceEnd", 1.01, True)
    reject("motion-long", "/motionCues/0/sourceEnd", 122, True)
    reject("motion-negative", "/motionCues/0/sourceStart", -1)
    reject("motion-duplicate-id", "/motionCues", [cue, cue], True)
    reject("motion-per-clip-budget", "/motionCues", [{**cue, "id": f"motion-{index}"} for index in range(65)], True)
    reject("motion-keyframe-budget", "/motionCues/0/keyframes", [{**frame, "progress": index / 8} for index in range(9)])
    reject("motion-keyframe-duplicate", "/motionCues/0/keyframes", [frame, frame, frames[1]], True)
    reject("motion-first-endpoint", "/motionCues/0/keyframes/0/progress", 0.1)
    reject("motion-last-endpoint", "/motionCues/0/keyframes/1/progress", 0.9)
    reject("motion-keyframe-reversed", "/motionCues/0/keyframes", [frame, {**frame, "progress": 0.8}, {**frame, "progress": 0.2}, frames[1]], True)
    reject("motion-scale", "/motionCues/0/keyframes/0/scale", 1.36)
    reject("motion-anchor", "/motionCues/0/keyframes/0/anchorX", -0.1)
    reject("motion-bool-number", "/motionCues/0/keyframes/0/scale", True)
    for version in (1, 2, 3):
        invalid.append({"id": f"v{version}-new-fields", "schemaValid": False,
            "patches": [set_value("/schemaVersion", version)]})
        invalid.append({"id": f"v{version}-empty-new-fields", "schemaValid": False,
            "patches": [set_value("/schemaVersion", version), remove("/contextDemo"), set_value("/motionCues", [])]})
    valid = [{"id": "both-features", "patches": []},
        {"id": "demo-only", "patches": [remove("/motionCues")]},
        {"id": "motion-only", "patches": [remove("/contextDemo")]},
        {"id": "no-features", "patches": [remove("/contextDemo"), remove("/motionCues")]},
        {"id": "empty-motion", "patches": [remove("/contextDemo"), set_value("/motionCues", [])]},
        {"id": "desktop-target", "patches": [
            set_value("/contextDemo/assets/0/target", {"kind": "desktopApp", "displayName": "Synthetic app", "locator": "com.example.synthetic"})]},
        {"id": "code-project-target", "patches": [
            set_value("/contextDemo/assets/0/target", {"kind": "codeProject", "displayName": "Synthetic project", "locator": "file:///tmp/voxclip-synthetic-project"})]},
        {"id": "maximum-revision", "patches": [set_value("/contextDemo/revision", 2147483647)]},
        {"id": "minimum-motion-duration", "patches": [set_value("/motionCues/0/sourceEnd", 1.1)]},
        {"id": "stale-narration-recoverable", "patches": [
            set_value("/contextDemo/narration/pieces/0/source/end", 6)]},
        {"id": "defensive-motion-overlap", "patches": [set_value("/motionCues", [cue, {**cue, "id": "motion-b"}])]}]
    cases = {"format": "voxclip-context-demo-wire-cases/1", "valid": valid, "invalid": invalid,
        "legacy": [{"version": 1, "path": "fixtures/projects/interview-take.voxclip"},
            {"version": 2, "path": "fixtures/voice-lab/passage-project.voxclip"},
            {"version": 3, "path": "fixtures/voice-lab/passage-render-v3.voxclip"}]}
    return {"v4-project.voxclip": project, "wire-cases.json": cases}


def apply_case(document, case):
    result = copy.deepcopy(document)
    for patch in case["patches"]:
        parts = patch["path"].strip("/").split("/")
        target = result
        for part in parts[:-1]:
            target = target[int(part)] if isinstance(target, list) else target[part]
        key = int(parts[-1]) if isinstance(target, list) else parts[-1]
        if patch.get("remove"):
            del target[key]
        else:
            target[key] = copy.deepcopy(patch["value"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--patch", action="store_true")
    mode.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    changed = False
    if arguments.patch:
        print("*** Begin Patch")
    for name, document in generated().items():
        path = DESTINATION / name
        expected = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
        actual = path.read_text() if path.exists() else ""
        if actual == expected:
            continue
        changed = True
        if arguments.check:
            print(f"fixture drift: {path.relative_to(ROOT)}", file=sys.stderr)
        elif path.exists():
            print(f"*** Update File: {path}")
            for line in list(difflib.unified_diff(actual.splitlines(True), expected.splitlines(True)))[2:]:
                print("@@\n" if line.startswith("@@ ") else line, end="")
        else:
            print(f"*** Add File: {path}")
            for line in expected.splitlines():
                print("+" + line)
    if arguments.patch:
        print("*** End Patch")
    return int(arguments.check and changed)


if __name__ == "__main__":
    sys.exit(main())
