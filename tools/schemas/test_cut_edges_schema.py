#!/usr/bin/env python3
"""Schema checks for edits.cutEdges (doc/spec/editing.md section 5.10) against the shared cut-edge-project vectors.

The schema admits cut edges only at v8 and a v8 file without an agent thread; the word, gap and window rules are Core's,
so those refused vectors stay schema-valid."""
import copy
import json
import pathlib
import sys
import unittest

sys.dont_write_bytecode = True

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]
VECTORS = sorted((ROOT / "shared/fixtures/editing/projects").glob("cut-edges-*.json"))


def apply(vector):
    project = json.loads((ROOT / vector["input"]["projectPath"]).read_text())
    for operation in vector["input"]["set"]:
        keys = operation["path"].split("/")[1:]
        parent = project
        for key in keys[:-1]:
            parent = parent[int(key)] if isinstance(parent, list) else parent[key]
        last = keys[-1]
        if isinstance(parent, list):
            parent[int(last)] = copy.deepcopy(operation["value"])
        else:
            parent[last] = copy.deepcopy(operation["value"])
    return project


class CutEdgesSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.validator = Draft202012Validator(schemas["project.schema.json"], registry=registry, format_checker=FormatChecker())

    def test_vectors(self):
        self.assertTrue(VECTORS)
        for path in VECTORS:
            vector = json.loads(path.read_text())
            with self.subTest(vector=vector["id"]):
                errors = list(self.validator.iter_errors(apply(vector)))
                needs_v8 = vector["expected"].get("reason") == "cut edges need schema v8"
                self.assertEqual(bool(errors), needs_v8, [error.message for error in errors[:3]])

    def test_values_are_seconds_and_keys_word_ids(self):
        vector = json.loads((ROOT / "shared/fixtures/editing/projects/cut-edges-v8.json").read_text())
        for edges in ({"w2": -0.1}, {"w2": "0.66"}, {"not an id!": 0.66}):
            with self.subTest(edges=edges):
                project = apply(vector)
                project["edits"]["cutEdges"] = edges
                self.assertTrue(list(self.validator.iter_errors(project)))


if __name__ == "__main__":
    unittest.main()
