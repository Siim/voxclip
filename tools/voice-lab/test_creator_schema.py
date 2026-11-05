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


    def test_learned_references_are_additive_and_bounded(self):
        """ADR-R41: speaker.references is optional; each entry is an embedding with its project, time, score and model."""
        schema = json.loads((ROOT / "shared/schemas/consent.schema.json").read_text())
        validator = Draft202012Validator(schema)
        record = json.loads((ROOT / "shared/fixtures/voice-lab/consent-record.json").read_text())
        self.assertNotIn("references", record["speaker"])
        reference = {"embedding": record["speaker"]["embedding"], "contentKey": "a" * 64,
                     "addedAt": "2026-11-05T12:00:00Z", "statementScore": 0.91, "model": record["speaker"]["model"]}
        learned = copy.deepcopy(record)
        learned["speaker"]["references"] = [reference]
        self.assertTrue(validator.is_valid(learned))
        learned["speaker"]["references"] = [dict(reference, contentKey=f"project-{index}") for index in range(16)]
        self.assertTrue(validator.is_valid(learned))
        for mutation in ["seventeen", "empty", "extra", "missing", "path", "score"]:
            invalid = copy.deepcopy(record)
            if mutation == "seventeen": invalid["speaker"]["references"] = [dict(reference, contentKey=f"p{index}") for index in range(17)]
            elif mutation == "empty": invalid["speaker"]["references"] = []
            elif mutation == "extra": invalid["speaker"]["references"] = [dict(reference, audioFile="clip.wav")]
            elif mutation == "missing": invalid["speaker"]["references"] = [{k: v for k, v in reference.items() if k != "model"}]
            elif mutation == "path": invalid["speaker"]["references"] = [dict(reference, contentKey="../Desktop/video.mp4")]
            else: invalid["speaker"]["references"] = [dict(reference, statementScore=1.5)]
            self.assertFalse(validator.is_valid(invalid), mutation)

    def test_project_attestation_is_distinct_from_recorded_consent(self):
        schema = json.loads((ROOT / "shared/schemas/consent.schema.json").read_text())
        validator = Draft202012Validator(schema)
        legacy = json.loads((ROOT / "shared/fixtures/voice-lab/consent-record.json").read_text())
        attested = json.loads((ROOT / "shared/fixtures/voice-lab/consent-record-project.json").read_text())
        self.assertEqual(attested["projectConsent"]["audioSha256"], attested["samples"][0]["sha256"])
        self.assertEqual(sum(sample["seconds"] for sample in attested["samples"]), 30)
        self.assertTrue(validator.is_valid(attested))
        for mutation in ["mixed", "downgrade", "missing", "text", "filename", "source", "unchecked"]:
            invalid = copy.deepcopy(attested)
            if mutation == "mixed": invalid["statement"] = legacy["statement"]
            elif mutation == "downgrade": invalid["schema"] = "voxclip-consent/1"
            elif mutation == "missing": del invalid["projectConsent"]
            elif mutation == "text": invalid["projectConsent"]["text"] = "I might agree"
            elif mutation == "filename": invalid["projectConsent"]["audioFile"] = "statement.wav"
            elif mutation == "source": invalid["samples"][0]["source"] = "readAloud"
            else: invalid["attestations"]["ownVoice"] = False
            self.assertFalse(validator.is_valid(invalid), mutation)
        invalid = copy.deepcopy(legacy)
        invalid["projectConsent"] = attested["projectConsent"]
        self.assertFalse(validator.is_valid(invalid))


if __name__ == "__main__":
    unittest.main()
