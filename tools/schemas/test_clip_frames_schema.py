#!/usr/bin/env python3
"""Schema-only "Claude sees the picture" wire regressions (ADR-R48); runtime-only cases run in Swift and C#."""
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
GENERATOR = ROOT / "tools/fixtures/clip-frames/generate_clip_frames.py"
SPEC = importlib.util.spec_from_file_location("clip_frames_fixtures", GENERATOR)
FIXTURES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURES)
NAMES = ["clip-frames-project.voxclip", "clip-frames-wire-cases.json"]


class ClipFramesSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.schema = schemas["project.schema.json"]
        cls.validator = Draft202012Validator(cls.schema, registry=registry, format_checker=FormatChecker())
        cls.project = json.loads((ROOT / "shared/fixtures/clip-frames/clip-frames-project.voxclip").read_text())
        cls.cases = json.loads((ROOT / "shared/fixtures/clip-frames/clip-frames-wire-cases.json").read_text())

    def test_shared_valid_cases(self):
        for case in self.cases["valid"]:
            with self.subTest(case=case["id"]):
                self.validator.validate(FIXTURES.apply_case(self.project, case))

    def test_shared_invalid_cases_distinguish_runtime_invariants(self):
        for case in self.cases["invalid"]:
            with self.subTest(case=case["id"]):
                actual = not list(self.validator.iter_errors(FIXTURES.apply_case(self.project, case)))
                self.assertEqual(case["schemaValid"], actual)

    def test_lead_in_matches_the_opening_scan(self):
        # FrameSampling.openingSpan: the opening scan looks 0.6 s back, and a lead-in never reaches further.
        self.assertEqual(0.6, self.schema["$defs"]["clipRange"]["properties"]["leadInSeconds"]["maximum"])

    def test_generators_are_idempotent(self):
        schema = (ROOT / "shared/schemas/project.schema.json").read_bytes()
        fixtures = [(ROOT / "shared/fixtures/clip-frames" / name).read_bytes() for name in NAMES]
        for script in ["tools/schemas/generate_clip_controls_schema.py", "tools/schemas/generate_clip_frames_schema.py"]:
            subprocess.run([sys.executable, str(ROOT / script)], check=True)
        subprocess.run([sys.executable, str(GENERATOR)], check=True)
        self.assertEqual(schema, (ROOT / "shared/schemas/project.schema.json").read_bytes())
        self.assertEqual(fixtures, [(ROOT / "shared/fixtures/clip-frames" / name).read_bytes() for name in NAMES])


if __name__ == "__main__":
    unittest.main()
