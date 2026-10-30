import copy
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[2]


class CreatorSchemaTests(unittest.TestCase):
    def test_legacy_and_creator_fixtures(self):
        schema = json.loads((ROOT / "shared/schemas/consent.schema.json").read_text())
        validator = Draft202012Validator(schema)
        legacy = json.loads((ROOT / "shared/fixtures/voice-lab/consent-record.json").read_text())
        bound = json.loads((ROOT / "shared/fixtures/voice-lab/consent-record-creator.json").read_text())
        self.assertNotIn("creator", legacy)
        self.assertTrue(validator.is_valid(legacy))
        for region in ["default", "us", "eu", "in", "sg"]:
            bound["creator"]["region"] = region
            self.assertTrue(validator.is_valid(bound))
        for creator in [
            {"region": 2, "keyFingerprint": "0123456789abcdef"},
            {"region": "eu", "keyFingerprint": "0123456789ABCDEF"},
            {"region": "eu", "keyFingerprint": "0123456789abcde"},
            {"region": "eu"},
            {"keyFingerprint": "0123456789abcdef"},
            {"region": "eu", "keyFingerprint": "0123456789abcdef", "key": "synthetic"},
        ]:
            invalid = copy.deepcopy(bound)
            invalid["creator"] = creator
            self.assertFalse(validator.is_valid(invalid), creator)
        invalid = copy.deepcopy(legacy)
        invalid["creatorKeyFingerprint"] = "0123456789abcdef"
        self.assertFalse(validator.is_valid(invalid))


if __name__ == "__main__":
    unittest.main()
