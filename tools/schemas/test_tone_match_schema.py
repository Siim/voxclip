#!/usr/bin/env python3
"""Schema regressions for the tone match's optional audio.tiltDbPerOctave (voice-lab.md section 8.7 item 2b)."""
import copy
import json
import pathlib
import sys
import unittest

sys.dont_write_bytecode = True

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ToneMatchSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.validator = Draft202012Validator(schemas["project.schema.json"], registry=registry, format_checker=FormatChecker())
        cls.project = json.loads((ROOT / "shared/fixtures/voice-lab/passage-render-v3.voxclip").read_text())

    def with_tilt(self, value):
        project = copy.deepcopy(self.project)
        segment = project["voiceLab"]["segments"][0]
        segment["audio"]["tiltDbPerOctave"] = value
        for candidate in segment["candidates"]:
            if candidate.get("recipe"):
                candidate["recipe"]["audio"]["tiltDbPerOctave"] = value
        return project

    def test_absent_and_in_range_tilts_validate(self):
        self.validator.validate(self.project)
        for value in [-2, -0.4, 0.1, 1.5, 2]:
            with self.subTest(value=value):
                self.validator.validate(self.with_tilt(value))

    def test_zero_out_of_range_and_non_numbers_are_refused(self):
        for value in [0, 2.1, -2.5, "1.0", None]:
            with self.subTest(value=value):
                self.assertTrue(list(self.validator.iter_errors(self.with_tilt(value))))


if __name__ == "__main__":
    unittest.main()
