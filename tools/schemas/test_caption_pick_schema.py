#!/usr/bin/env python3
"""Schema-only caption-look wire regressions (doc/design.md section 6.6); runtime-only cases run in Swift and C#."""
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
CASES = ROOT / "shared/fixtures/clip-style/caption-look-cases.json"
PROJECT = ROOT / "shared/fixtures/clip-controls/clip-controls-project.voxclip"


def with_pick(project, pick):
    result = copy.deepcopy(project)
    result["clipStyle"] = {"preset": "auto", "captions": "auto", "music": "auto", "maxLengthSec": 60,
                           "shapes": ["16:9", "9:16"], "rewording": "fix-only", "captionPicks": {"clip-1": pick}}
    return result


class CaptionPickSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.validator = Draft202012Validator(schemas["project.schema.json"], registry=registry, format_checker=FormatChecker())
        cls.project = json.loads(PROJECT.read_text())
        cls.cases = json.loads(CASES.read_text())

    def test_valid_picks(self):
        for case in self.cases["wire"]["valid"]:
            with self.subTest(case=case["id"]):
                self.validator.validate(with_pick(self.project, case["pick"]))

    def test_invalid_picks_distinguish_runtime_invariants(self):
        for case in self.cases["wire"]["invalid"]:
            with self.subTest(case=case["id"]):
                valid = not list(self.validator.iter_errors(with_pick(self.project, case["pick"])))
                self.assertEqual(valid, case.get("runtimeOnly", False))

    def test_resolve_cases_store_valid_clip_styles(self):
        for case in self.cases["resolve"]:
            if case["clipStyle"] is None:
                continue
            with self.subTest(case=case["id"]):
                project = copy.deepcopy(self.project)
                project["clipStyle"] = case["clipStyle"]
                project["captions"]["styleId"] = case["captions"]["styleId"]
                project["captions"]["overrides"] = case["captions"]["overrides"]
                self.validator.validate(project)

    def test_generators_are_idempotent(self):
        for script, path in (("tools/schemas/generate_caption_pick_schema.py", "shared/schemas/project.schema.json"),
                             ("tools/fixtures/clip-style/generate_caption_looks.py", str(CASES.relative_to(ROOT)))):
            before = (ROOT / path).read_bytes()
            subprocess.run([sys.executable, str(ROOT / script)], check=True)
            self.assertEqual((ROOT / path).read_bytes(), before, script)


if __name__ == "__main__":
    unittest.main()
