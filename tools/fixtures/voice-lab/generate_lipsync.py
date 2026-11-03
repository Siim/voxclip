#!/usr/bin/env python3
import json
from pathlib import Path

RATE = 48_000


def window(start, end, duration, phrase):
    start, end, total = round(start * RATE), round(end * RATE), round(duration * RATE)
    lower, upper = max(0, start - RATE), min(total, end + RATE)
    if upper - lower < RATE * 3:
        lower = max(0, lower - (RATE * 3 - (upper - lower) + 1) // 2)
        upper = min(total, lower + RATE * 3)
        lower = upper - RATE * 3
    return {"startSample": lower, "endSample": upper, "phraseIDs": [phrase]}


cases = []
for name, start, end, duration in [
    ("handles", 2, 4, 10), ("start-clamped", .1, .5, 10),
    ("end-clamped", 9.5, 9.8, 10), ("minimum-centered", 4, 4.1, 10),
    ("whole-three-second-take", 1, 2, 3), ("long-phrase", 10, 24, 60),
]:
    cases.append({"id": name, "seamIn": round(start * RATE), "seamOut": round(end * RATE),
                  "totalSamples": round(duration * RATE), "sampleRate": RATE,
                  "phraseID": 0, "expected": window(start, end, duration, 0)})

merges = [
    {"id": "touch", "windows": [window(2, 3, 20, 0), window(5, 6, 20, 1)],
     "expected": [{"startSample": RATE, "endSample": RATE * 7, "phraseIDs": [0, 1]}]},
    {"id": "overlap", "windows": [window(2, 3, 20, 0), window(3, 4, 20, 1)],
     "expected": [{"startSample": RATE, "endSample": RATE * 5, "phraseIDs": [0, 1]}]},
    {"id": "separate", "windows": [window(2, 3, 20, 0), window(7, 8, 20, 1)],
     "expected": [window(2, 3, 20, 0), window(7, 8, 20, 1)]},
    {"id": "unsorted-and-contained", "windows": [window(5, 8, 20, 1), window(2, 10, 20, 0)],
     "expected": [{"startSample": RATE, "endSample": RATE * 11, "phraseIDs": [0, 1]}]},
]
output = {"schema": "voxclip-lipsync-windows/1", "caseCount": len(cases) + len(merges),
          "windows": cases, "merges": merges}
path = Path(__file__).resolve().parents[3] / "shared/fixtures/voice-lab/lipsync-window-cases.json"
path.write_text(json.dumps(output, indent=2) + "\n")
