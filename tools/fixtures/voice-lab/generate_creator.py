#!/usr/bin/env python3
"""Derive the creator-bound consent fixture from the legacy schema fixture."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "shared/fixtures/voice-lab"
record = json.loads((FIXTURES / "consent-record.json").read_text())
record["creator"] = {"region": "eu", "keyFingerprint": "0123456789abcdef"}
(FIXTURES / "consent-record-creator.json").write_text(json.dumps(record, indent=2) + "\n")
