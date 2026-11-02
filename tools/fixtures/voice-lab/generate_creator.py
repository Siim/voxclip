#!/usr/bin/env python3
"""Derive creator-bound recorded and project-attestation consent fixtures from the legacy fixture."""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "shared/fixtures/voice-lab"
record = json.loads((FIXTURES / "consent-record.json").read_text())
record["creator"] = {"region": "eu", "keyFingerprint": "0123456789abcdef"}
(FIXTURES / "consent-record-creator.json").write_text(json.dumps(record, indent=2) + "\n")

project = copy.deepcopy(record)
del project["statement"]
project["schema"] = "voxclip-consent/2"
project["projectConsent"] = {
    "language": "en",
    "text": "I confirm this is my own voice and I consent to creating a voice clone.",
    "audioFile": "reference.wav",
    "audioSha256": project["samples"][0]["sha256"],
}
project["samples"][0]["seconds"] = 30
for sample in project["samples"]:
    sample["source"] = "project"
(FIXTURES / "consent-record-project.json").write_text(json.dumps(project, indent=2) + "\n")
