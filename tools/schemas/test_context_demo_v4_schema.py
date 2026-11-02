#!/usr/bin/env python3
"""Schema-only v4 wire regressions; runtime-only cases run in Swift and C#."""
import importlib.util
import json
import pathlib
import sys
import unittest

sys.dont_write_bytecode = True

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "tools/fixtures/projects/generate_context_demo_v4.py"
SPEC = importlib.util.spec_from_file_location("context_demo_fixtures", GENERATOR)
FIXTURES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURES)


class ContextDemoV4SchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.validator = Draft202012Validator(schemas["project.schema.json"], registry=registry, format_checker=FormatChecker())
        cls.project = json.loads((ROOT / "shared/fixtures/context-demo/v4-project.voxclip").read_text())
        cls.cases = json.loads((ROOT / "shared/fixtures/context-demo/wire-cases.json").read_text())

    def test_shared_valid_cases(self):
        for case in self.cases["valid"]:
            with self.subTest(case=case["id"]):
                self.validator.validate(FIXTURES.apply_case(self.project, case))

    def test_shared_invalid_cases_distinguish_runtime_invariants(self):
        for case in self.cases["invalid"]:
            with self.subTest(case=case["id"]):
                actual = not list(self.validator.iter_errors(FIXTURES.apply_case(self.project, case)))
                self.assertEqual(case["schemaValid"], actual)

    def test_real_legacy_documents_still_match(self):
        for item in self.cases["legacy"]:
            with self.subTest(version=item["version"]):
                self.validator.validate(json.loads((ROOT / "shared" / item["path"]).read_text()))


if __name__ == "__main__":
    unittest.main()
