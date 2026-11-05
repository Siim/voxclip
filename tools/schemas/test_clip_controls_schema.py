#!/usr/bin/env python3
"""Schema-only clip-controls wire regressions (doc/design.md section 6.8); runtime-only cases run in Swift and C#."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "tools/fixtures/clip-controls/generate_clip_controls.py"
SPEC = importlib.util.spec_from_file_location("clip_controls_fixtures", GENERATOR)
FIXTURES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURES)
NAMES = ["clip-controls-project.voxclip", "clip-controls-wire-cases.json"]


class ClipControlsSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.schema = schemas["project.schema.json"]
        cls.validator = Draft202012Validator(cls.schema, registry=registry, format_checker=FormatChecker())
        cls.project = json.loads((ROOT / "shared/fixtures/clip-controls/clip-controls-project.voxclip").read_text())
        cls.cases = json.loads((ROOT / "shared/fixtures/clip-controls/clip-controls-wire-cases.json").read_text())

    def test_shared_valid_cases(self):
        for case in self.cases["valid"]:
            with self.subTest(case=case["id"]):
                self.validator.validate(FIXTURES.apply_case(self.project, case))

    def test_shared_invalid_cases_distinguish_runtime_invariants(self):
        for case in self.cases["invalid"]:
            with self.subTest(case=case["id"]):
                actual = not list(self.validator.iter_errors(FIXTURES.apply_case(self.project, case)))
                self.assertEqual(case["schemaValid"], actual)

    def test_looks_match_the_planner(self):
        looks = self.schema["$defs"]["clipControls"]["properties"]["look"]["enum"]
        prompt = json.loads((ROOT / "shared/prompts/clip-autopilot.json").read_text())
        self.assertEqual(["original", "muted", "warm", "bw"], looks)
        self.assertEqual(looks, [look["id"] for look in prompt["looks"]])

    def test_export_aspect_is_unchanged(self):
        self.assertEqual(["source", "16:9", "9:16", "1:1"], self.schema["$defs"]["export"]["properties"]["aspect"]["enum"])

    def test_generators_are_idempotent(self):
        schema = (ROOT / "shared/schemas/project.schema.json").read_bytes()
        fixtures = [(ROOT / "shared/fixtures/clip-controls" / name).read_bytes() for name in NAMES]
        subprocess.run([sys.executable, str(ROOT / "tools/schemas/generate_clip_controls_schema.py")], check=True)
        subprocess.run([sys.executable, str(GENERATOR)], check=True)
        self.assertEqual(schema, (ROOT / "shared/schemas/project.schema.json").read_bytes())
        self.assertEqual(fixtures, [(ROOT / "shared/fixtures/clip-controls" / name).read_bytes() for name in NAMES])


if __name__ == "__main__":
    unittest.main()
