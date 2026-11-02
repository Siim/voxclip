#!/usr/bin/env python3
"""Independent short-speech recipe vectors, without changing existing twin fixtures."""
import copy
import json
import pathlib
import unittest

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "shared/fixtures/voice-lab"


class ShortSpeechRecipeSchemaTests(unittest.TestCase):
    def test_shared_cases_preserve_v3_and_v4(self):
        cases = json.loads((FIXTURES / "short-speech-recipe-cases.json").read_text())
        self.assertEqual("voxclip-voice-lab-short-speech-recipe-cases/1", cases["schema"])
        self.assertEqual({"schema", "baseProject", "caseCount", "cases"}, set(cases))
        self.assertEqual(cases["caseCount"], len(cases["cases"]))
        self.assertEqual(len(cases["cases"]), len({case["name"] for case in cases["cases"]}))
        registry, schemas = load_registry()
        validator = Draft202012Validator(schemas["project.schema.json"], registry=registry, format_checker=FormatChecker())
        base = json.loads((FIXTURES / cases["baseProject"]).read_text())
        for case in cases["cases"]:
            for version in (3, 4):
                with self.subTest(case=case["name"], version=version):
                    project = copy.deepcopy(base)
                    project["schemaVersion"] = version
                    segment = project["voiceLab"]["segments"][0]
                    qa = segment["candidates"][0]["recipe"]["qa"]
                    qa.update(case["qa"])
                    segment["qa"]["speakerScore"] = qa["speakerScore"]
                    self.assertEqual(case["schemaValid"], not list(validator.iter_errors(project)))


if __name__ == "__main__":
    unittest.main()
