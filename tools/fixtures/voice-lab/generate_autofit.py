#!/usr/bin/env python3
"""Independent wording-fit word targets, calibration and round selection vectors."""
import json
import math
import hashlib
import re
from pathlib import Path
from statistics import median

ROOT = Path(__file__).resolve().parents[3]


def target(rate, multiplier, lower, upper, overhead, bridges=0):
    calibrated = rate * 1.8 / multiplier
    minimum = max(1, min(2000, math.ceil(max(0, lower - overhead) * calibrated - bridges)))
    maximum = max(minimum, min(2000, math.floor(max(0, upper - overhead) * calibrated - bridges)))
    return dict(minimum=minimum, maximum=maximum)


def main():
    targets = []
    for name, values in [
        ("default", [2, 1, 2.5, 3, 0.15, 0]),
        ("slower-measured-model", [2, 1.5, 2.5, 3, 0.15, 0]),
        ("tags-and-bridges", [2.5, 0.8, 3, 3.5, 0.75, 2]),
        ("sub-word-slot", [1, 1, 0.05, 0.10, 0.15, 0]),
        ("round-inwards", [2.3, 1.1, 1.25, 1.75, 0.15, 1]),
        ("bounded", [100, 0.1, 300, 600, 0.15, 0]),
    ]:
        keys = ["wordsPerSecond", "multiplier", "minimumSeconds", "maximumSeconds", "overheadSeconds", "bridgeWords"]
        targets.append(dict(id=name, input=dict(zip(keys, values)), expected=target(*values)))
    calibration = []
    for ratios in [[], [1.7], [1.2, 1.8], [1, 7, 2], [100, 100, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]]:
        calibration.append(dict(ratios=ratios, expected=median(ratios[-10:]) if len(ratios) >= 2 else 1))
    rounds = []
    for completed, candidates, fitting, kept, stopped in [
        (0, [1, 2, 3], [2], [], False),
        (1, [1, 2, 3], [1, 2], [], False),
        (2, [1, 2, 3], [2], [1], False),
        (3, [1], [], [], False),
        (1, [1], [], [], True),
        (1, [1, 2], [1, 2], [], False),
    ]:
        expected = sorted(set(candidates) - set(fitting) - set(kept)) if completed < 3 and not stopped else []
        rounds.append(dict(roundsCompleted=completed, candidates=candidates, fitting=fitting, kept=kept, stopped=stopped, expected=expected))
    prompt_path = "shared/prompts/voice-rewrite-fit.json"
    prompt_bytes = (ROOT / prompt_path).read_bytes().replace(b"\r\n", b"\n")
    prompt = json.loads(prompt_bytes)
    templates = prompt["request"]
    requests = []
    for direction, measured, calibrated in [("longer", None, False), ("shorter", None, True), ("longer", 0.6, True), ("shorter", 4.2, True)]:
        phrase = dict(ordinal=2, original="We made the right call", proposed="We chose well", estimateSeconds=0.9,
                      slotSeconds=2.0, direction=direction, target=dict(minimum=5, maximum=7), measuredSeconds=measured, calibrated=calibrated)
        difference = max(1, 5 - 3) if direction == "longer" else max(1, 3 - 7)
        values = dict(ordinal="2", original=phrase["original"], proposed=phrase["proposed"], estimateSeconds="0.9", slotSeconds="2.0",
                      minimumWords="5", maximumWords="7", paceLine=templates["calibratedPaceLine"] if calibrated else "",
                      directionLine=templates[direction + "PhraseLine"].replace("{differenceWords}", str(difference)))
        line = re.sub(r"\{([A-Za-z]+)\}", lambda match: values[match[1]], templates["phraseLine"])
        if measured is not None:
            line += "\n" + templates["measuredPhraseLine"].replace("{measuredSeconds}", str(measured)).replace("{slotSeconds}", "2.0")
        cached = templates["sourceBlock"].replace("{language}", "en").replace("{phrases}", line)
        requests.append(dict(phrase=phrase, expected=dict(system=prompt["system"], cachedBlock=cached,
                             instruction=templates["measuredFeedbackBlock" if measured is not None else "fitFeedbackBlock"],
                             schemaName=prompt["schemaName"], schema=prompt["schema"])))
    payload = dict(schema="voxclip-voice-lab-autofit-cases/1", sources={prompt_path: hashlib.sha256(prompt_bytes).hexdigest()},
                   targets=targets, calibration=calibration, rounds=rounds, requests=requests)
    output = ROOT / "shared/fixtures/voice-lab/autofit-cases.json"
    output.write_text(json.dumps(payload, indent=2) + "\n")
    print(output.relative_to(ROOT))


if __name__ == "__main__":
    main()
