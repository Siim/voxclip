#!/usr/bin/env python3
"""Validate VoxClip JSON documents against the schemas in shared/schemas.

Usage:
  python3 tools/schemas/validate.py                 # projects, media transcripts and the Voice Lab price catalog
  python3 tools/schemas/validate.py FILE [FILE...]  # projects, settings, price catalogs or *.transcript.json

A file ending in .voxclip is checked against project.schema.json; a JSON object whose
"schema" is "voxclip-settings/1" against settings.schema.json, and one whose "schema" is
"voxclip-voice-lab-prices/1" against voice-lab-prices.schema.json, and one whose "schema" is
"voxclip-cover-art-cases/1" (the MP4 cover-art vectors) against cover-art-cases.schema.json, and one whose "schema" is
"voxclip-frame-decision-cases/1" (the frame decisions' vectors) against frame-decision-cases.schema.json, and one whose "schema" is
"voxclip-frame-models/1" (the Windows face models) against frame-models.schema.json, and one whose "schema" is
"voxclip-frame-face-fields-cases/1" (the Windows face fields' vectors) against frame-face-fields-cases.schema.json, and one whose
"schema" is "voxclip-frame-quad-cases/1" (the Windows quad finder's vectors) against frame-quad-cases.schema.json, and one whose
"schema" is "voxclip-analyze-frames-cli-cases/1" (analyze-frames' output) against analyze-frames-cli-cases.schema.json; *.transcript.json
against project.schema.json's $defs/transcript. References between the
schemas (project.schema.json -> timed-word.schema.json) resolve through a local registry,
never over the network. Needs jsonschema >= 4.18 (tools/captions/requirements.txt).
Exit 0 when every file validates, 1 otherwise.
"""
import json
import pathlib
import sys

sys.dont_write_bytecode = True

from jsonschema import Draft202012Validator, FormatChecker  # noqa: E402
from referencing import Registry, Resource  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "shared" / "schemas"


def load_registry():
    registry = Registry()
    by_name = {}
    for path in sorted(SCHEMAS.glob("*.schema.json")):
        schema = json.loads(path.read_text(encoding="utf-8"))
        resource = Resource.from_contents(schema)
        registry = registry.with_resource(schema["$id"], resource)
        # Relative "$ref": "timed-word.schema.json" resolves against the referring $id,
        # so registering the canonical $id is enough; keep the file name for lookup here.
        by_name[path.name] = schema
    return registry, by_name


def schema_for(path, document, by_name):
    if path.suffix == ".voxclip":
        return by_name["project.schema.json"]
    if path.name.endswith(".transcript.json"):
        project = by_name["project.schema.json"]
        return {"$ref": project["$id"] + "#/$defs/transcript"}
    if isinstance(document, dict) and document.get("schema") == "voxclip-settings/1":
        return by_name["settings.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-voice-lab-prices/1":
        return by_name["voice-lab-prices.schema.json"]
    if isinstance(document, dict) and document.get("schema") in {"voxclip-consent/1", "voxclip-consent/2"}:
        return by_name["consent.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-voice-statements/1":
        return by_name["voice-statements.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-voice-models/1":
        return by_name["voice-models.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-cover-art-cases/1":
        return by_name["cover-art-cases.schema.json"]
    if isinstance(document, dict) and document.get("format") == "voxclip-context-demo":
        return by_name["context-demo.schema.json"]
    if isinstance(document, dict) and document.get("schema") in {"voxclip-export-check-cases/1",
                                                                 "voxclip-export-check-number-cases/1"}:
        return by_name["export-check-cases.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-spoken-numbers-cases/1":
        return by_name["spoken-numbers-cases.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-frame-decision-cases/1":
        return by_name["frame-decision-cases.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-frame-models/1":
        return by_name["frame-models.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-frame-face-fields-cases/1":
        return by_name["frame-face-fields-cases.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-frame-quad-cases/1":
        return by_name["frame-quad-cases.schema.json"]
    if isinstance(document, dict) and document.get("schema") == "voxclip-analyze-frames-cli-cases/1":
        return by_name["analyze-frames-cli-cases.schema.json"]
    raise SystemExit(f"{path}: no schema applies (expected .voxclip, .transcript.json, voxclip-settings/1 "
                     "or voxclip-voice-lab-prices/1)")


def main(argv):
    registry, by_name = load_registry()
    fixtures = ROOT / "shared" / "fixtures"
    files = [pathlib.Path(a) for a in argv] or sorted([
        *fixtures.joinpath("projects").glob("*.voxclip"),
        *fixtures.joinpath("context-demo").glob("*.voxclip"),
        *fixtures.joinpath("music").glob("*.voxclip"),
        *fixtures.joinpath("media").glob("*.transcript.json"),
    ]) + [ROOT / "shared" / "catalog" / "voice-lab.json",
          ROOT / "shared" / "voice-lab" / "statements.json",
          fixtures / "voice-lab" / "consent-record.json",
          fixtures / "voice-lab" / "consent-record-creator.json",
          fixtures / "voice-lab" / "consent-record-project.json",
          ROOT / "shared" / "catalog" / "voice-lab-models.json",
          ROOT / "shared" / "catalog" / "frame-models.json",
          fixtures / "export-check" / "check-cases.json",
          fixtures / "export-check" / "number-check-cases.json",
          fixtures / "spoken-numbers" / "number-cases.json",
          fixtures / "clip-frames" / "decision-cases.json",
          fixtures / "clip-frames" / "frame-face-fields-cases.json",
          fixtures / "clip-frames" / "frame-quad-cases.json",
          fixtures / "clip-frames" / "analyze-frames-cli-cases.json",
          fixtures / "cover-art" / "cover-art-cases.json"]
    if not files:
        print("no files to validate", file=sys.stderr)
        return 1
    failed = 0
    for path in files:
        document = json.loads(path.read_text(encoding="utf-8"))
        schema = schema_for(path, document, by_name)
        validator = Draft202012Validator(schema, registry=registry, format_checker=FormatChecker())
        errors = sorted(validator.iter_errors(document), key=lambda e: list(e.absolute_path))
        if errors:
            failed += 1
            for error in errors:
                where = "/".join(str(p) for p in error.absolute_path) or "(root)"
                print(f"{path}: {where}: {error.message}", file=sys.stderr)
        else:
            resolved = path.resolve()
            print(f"ok {resolved.relative_to(ROOT) if resolved.is_relative_to(ROOT) else path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
