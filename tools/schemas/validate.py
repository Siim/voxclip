#!/usr/bin/env python3
"""Validate VoxClip JSON documents against the schemas in shared/schemas.

Usage:
  python3 tools/schemas/validate.py                 # every shared/fixtures/projects/*.voxclip
  python3 tools/schemas/validate.py FILE [FILE...]  # explicit files (.voxclip or settings .json)

A file ending in .voxclip is checked against project.schema.json; a JSON object whose
"schema" is "voxclip-settings/1" against settings.schema.json. References between the
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
    if isinstance(document, dict) and document.get("schema") == "voxclip-settings/1":
        return by_name["settings.schema.json"]
    raise SystemExit(f"{path}: no schema applies (expected .voxclip or a voxclip-settings/1 document)")


def main(argv):
    registry, by_name = load_registry()
    files = [pathlib.Path(a) for a in argv] or sorted((ROOT / "shared" / "fixtures" / "projects").glob("*.voxclip"))
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
