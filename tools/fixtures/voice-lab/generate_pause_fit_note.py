#!/usr/bin/env python3
"""Pin invariant printf %.1f pause notes, including binary ties and signed zero."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SECONDS = [0.0, -0.0, 0.04, -0.04, 0.05, -0.05, 0.06, -0.06,
           0.15, -0.15, 1.25, -1.25, 1.35, -2.0, 999999.95, -999999.95,
           1000000000000.25, -1000000000000.25]
fixture = {"schema": "voxclip-voice-lab-pause-fit-note/1", "cases": [
    {"seconds": seconds, "expected": "pauses " + ("+" if seconds >= 0 else "−") + f"{abs(seconds):.1f} s"}
    for seconds in SECONDS
]}
(ROOT / "shared/fixtures/voice-lab/pause-fit-note-cases.json").write_text(
    json.dumps(fixture, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
