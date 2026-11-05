#!/usr/bin/env python3
"""Schema-only caption-translation wire regressions (doc/spec/ai.md section 18.2); runtime-only cases run in Swift and C#."""
import copy
import json
import pathlib
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]
CASES = ROOT / "shared/fixtures/caption-translations/caption-translation-cases.json"


class CaptionTranslationSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.validator = Draft202012Validator(schemas["project.schema.json"], registry=registry, format_checker=FormatChecker())
        cls.cases = json.loads(CASES.read_text())
        cls.project = json.loads((ROOT / "shared" / cls.cases["baseProject"]).read_text())

    def applied(self, case):
        project = copy.deepcopy(self.project)
        project["captionTranslations"] = case["captionTranslations"]
        if "version" in case:
            project["schemaVersion"] = case["version"]
        return project

    def test_valid_lists(self):
        for case in self.cases["wire"]["valid"]:
            with self.subTest(case=case["id"]):
                self.validator.validate(self.applied(case))

    def test_invalid_lists_distinguish_runtime_invariants(self):
        for case in self.cases["wire"]["invalid"]:
            with self.subTest(case=case["id"]):
                valid = not list(self.validator.iter_errors(self.applied(case)))
                self.assertEqual(valid, case.get("runtimeOnly", False))

    def test_generators_are_idempotent(self):
        for script, path in (("tools/schemas/generate_caption_translations_schema.py", "shared/schemas/project.schema.json"),
                             ("tools/fixtures/caption-translations/generate_caption_translations.py", str(CASES.relative_to(ROOT)))):
            before = (ROOT / path).read_bytes()
            subprocess.run([sys.executable, str(ROOT / script)], check=True)
            self.assertEqual((ROOT / path).read_bytes(), before, script)


if __name__ == "__main__":
    unittest.main()
