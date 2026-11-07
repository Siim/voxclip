#!/usr/bin/env python3
"""Schema-only whole-clip revoice wire regressions (ADR-R46); runtime-only cases run in Swift and C#."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True

from jsonschema import Draft202012Validator
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "tools/fixtures/voice-lab/generate_whole_clip_wire.py"
SPEC = importlib.util.spec_from_file_location("whole_clip_wire_fixtures", GENERATOR)
FIXTURES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURES)
FOLDER = ROOT / "shared/fixtures/voice-lab"
NAMES = ["whole-clip-revoice-project.voxclip", "whole-clip-revoice-wire-cases.json"]


class WholeClipRevoiceSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        # No format checker: draft 2020-12 treats "format" as an annotation, and CI's pinned jsonschema asserts none, so a
        # timestamp without its zone is a runtime rule (schemaValid) wherever this runs.
        cls.validator = Draft202012Validator(schemas["project.schema.json"], registry=registry)
        cls.project = json.loads((FOLDER / NAMES[0]).read_text())
        cls.cases = json.loads((FOLDER / NAMES[1]).read_text())

    def test_shared_valid_cases(self):
        for case in self.cases["valid"]:
            with self.subTest(case=case["id"]):
                self.validator.validate(FIXTURES.apply_case(self.project, case))

    def test_shared_invalid_cases_distinguish_runtime_invariants(self):
        for case in self.cases["invalid"]:
            with self.subTest(case=case["id"]):
                actual = not list(self.validator.iter_errors(FIXTURES.apply_case(self.project, case)))
                self.assertEqual(case["schemaValid"], actual)

    def test_generator_is_idempotent(self):
        before = [(FOLDER / name).read_bytes() for name in NAMES]
        subprocess.run([sys.executable, str(GENERATOR)], check=True)
        self.assertEqual(before, [(FOLDER / name).read_bytes() for name in NAMES])


if __name__ == "__main__":
    unittest.main()
