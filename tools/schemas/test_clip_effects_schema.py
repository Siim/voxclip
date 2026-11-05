#!/usr/bin/env python3
"""Schema-only clip-effects wire regressions (doc/spec/ai.md section 18.2); runtime-only cases run in Swift and C#."""
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
GENERATOR = ROOT / "tools/fixtures/clip-effects/generate_clip_effects.py"
SPEC = importlib.util.spec_from_file_location("clip_effect_fixtures", GENERATOR)
FIXTURES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURES)
NAMES = ["effects-project.voxclip", "effects-wire-cases.json"]


class ClipEffectsSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.schema = schemas["project.schema.json"]
        cls.validator = Draft202012Validator(cls.schema, registry=registry, format_checker=FormatChecker())
        cls.project = json.loads((ROOT / "shared/fixtures/clip-effects/effects-project.voxclip").read_text())
        cls.cases = json.loads((ROOT / "shared/fixtures/clip-effects/effects-wire-cases.json").read_text())

    def test_shared_valid_cases(self):
        for case in self.cases["valid"]:
            with self.subTest(case=case["id"]):
                self.validator.validate(FIXTURES.apply_case(self.project, case))

    def test_shared_invalid_cases_distinguish_runtime_invariants(self):
        for case in self.cases["invalid"]:
            with self.subTest(case=case["id"]):
                actual = not list(self.validator.iter_errors(FIXTURES.apply_case(self.project, case)))
                self.assertEqual(case["schemaValid"], actual)

    def test_every_kind_is_in_the_fixture(self):
        kinds = self.schema["$defs"]["clipEffect"]["properties"]["kind"]["enum"]
        self.assertEqual(sorted(kinds), sorted({effect["kind"] for effect in self.project["clipEffects"]}))

    def test_library_sounds_never_accept_noncommercial_no_derivatives_or_share_alike(self):
        licenses = self.schema["$defs"]["clipEffectLibrarySound"]["properties"]["license"]["enum"]
        self.assertEqual(["cc0", "by", "pdm"], licenses)

    def test_generators_are_idempotent(self):
        schema = (ROOT / "shared/schemas/project.schema.json").read_bytes()
        fixtures = [(ROOT / "shared/fixtures/clip-effects" / name).read_bytes() for name in NAMES]
        subprocess.run([sys.executable, str(ROOT / "tools/schemas/generate_music_schema.py")], check=True)
        subprocess.run([sys.executable, str(ROOT / "tools/schemas/generate_clip_effects_schema.py")], check=True)
        subprocess.run([sys.executable, str(GENERATOR)], check=True)
        self.assertEqual(schema, (ROOT / "shared/schemas/project.schema.json").read_bytes())
        self.assertEqual(fixtures, [(ROOT / "shared/fixtures/clip-effects" / name).read_bytes() for name in NAMES])


if __name__ == "__main__":
    unittest.main()
