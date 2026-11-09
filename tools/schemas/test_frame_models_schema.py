#!/usr/bin/env python3
"""The Windows face-model catalogue's schema (shared/catalog/frame-models.json, ADR-R48 Windows): licences, notices, the
off switch. The C# FrameModelCatalogTests check the same rules at run time."""
import copy
import json
import pathlib
import sys
import unittest

sys.dont_write_bytecode = True

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]


class FrameModelsSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        registry, schemas = load_registry()
        cls.validator = Draft202012Validator(schemas["frame-models.schema.json"], registry=registry,
                                             format_checker=FormatChecker())
        cls.catalogue = json.loads((ROOT / "shared/catalog/frame-models.json").read_text(encoding="utf-8"))

    def valid(self, document):
        return not list(self.validator.iter_errors(document))

    def test_the_shipped_catalogue_is_valid_and_off(self):
        self.assertTrue(self.valid(self.catalogue))
        self.assertIs(False, self.catalogue["enabled"])
        self.assertEqual("provisional", self.catalogue["models"][0]["calibration"]["status"])

    def test_every_file_needs_a_licence_and_a_notice(self):
        for index in range(2):
            for key in ["license", "licenseUrl", "notice", "trainingData"]:
                with self.subTest(file=index, key=key):
                    document = copy.deepcopy(self.catalogue)
                    del document["models"][0]["files"][index][key]
                    self.assertFalse(self.valid(document))
                    document["models"][0]["files"][index][key] = ""
                    self.assertFalse(self.valid(document))

    def test_the_model_needs_a_licence(self):
        document = copy.deepcopy(self.catalogue)
        del document["models"][0]["license"]
        self.assertFalse(self.valid(document))

    def test_enabling_needs_every_file_hosted_or_bundled_and_a_finished_calibration(self):
        document = copy.deepcopy(self.catalogue)
        document["enabled"] = True
        self.assertFalse(self.valid(document), "a provisional calibration must not be enabled")
        document["models"][0]["calibration"]["status"] = "calibrated"
        self.assertTrue(self.valid(document))
        del document["models"][0]["files"][1]["bundled"]
        self.assertFalse(self.valid(document), "a file neither hosted nor bundled must not be enabled")
        document["models"][0]["files"][1]["url"] = "https://example.invalid/face_mesh_v2.onnx"
        self.assertTrue(self.valid(document))

    def test_both_files_are_bundled_as_catalogued(self):
        import hashlib
        for file in self.catalogue["models"][0]["files"]:
            with self.subTest(file=file["name"]):
                self.assertEqual(f"apps/windows/models/frames/{file['name']}", file["bundled"])
                data = (ROOT / file["bundled"]).read_bytes()
                self.assertEqual((file["bytes"], file["sha256"]), (len(data), hashlib.sha256(data).hexdigest()))
        document = copy.deepcopy(self.catalogue)
        document["models"][0]["files"][0]["bundled"] = "apps/windows/models/frames/../x.onnx"
        self.assertFalse(self.valid(document))

    def test_hashes_sizes_and_total(self):
        model = self.catalogue["models"][0]
        self.assertEqual(model["totalBytes"], sum(file["bytes"] for file in model["files"]))
        self.assertEqual(["detector", "landmarks"], [file["role"] for file in model["files"]])
        document = copy.deepcopy(self.catalogue)
        document["models"][0]["files"][0]["sha256"] = "EBAFCE" + document["models"][0]["files"][0]["sha256"][6:]
        self.assertFalse(self.valid(document))


if __name__ == "__main__":
    unittest.main()
