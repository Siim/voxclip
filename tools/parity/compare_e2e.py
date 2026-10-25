#!/usr/bin/env python3
"""Compare the ten structured CLI reports specified by architecture section 9.5."""

import argparse
import json
import math
from pathlib import Path

CASE_IDS = (
    "e2e-1-chirp-cut-fillers", "e2e-2-tone-joins",
    "e2e-3-captions-vox-bold", "e2e-3-captions-vox-highlight",
    "e2e-4-style-off", "e2e-5-everything-cut", "e2e-6-big-source",
    "e2e-7-counter-9x16", "e2e-8-bars", "e2e-9-tiny-webm",
)
FIELDS = ("width", "height", "fps", "frames", "audioSampleRate",
          "audioSamples", "aspect", "captionStyle")
WEBM = "e2e-9-tiny-webm"


def load_reports(directory: Path, platform: str) -> tuple[dict, list[str]]:
    reports = {}
    errors = []
    if not directory.is_dir():
        return reports, [f"{platform}: report directory missing: {directory}"]
    paths = sorted(directory.glob("*.json"))
    for path in paths:
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(record, dict):
                raise ValueError("expected JSON object")
            case = record.get("caseId")
            if case not in CASE_IDS or path.stem != case:
                raise ValueError(f"unexpected caseId or filename: {case!r}")
            if record.get("platform") != platform:
                raise ValueError(f"platform must be {platform}")
            if case in reports:
                raise ValueError(f"duplicate caseId: {case}")
            if type(record.get("exitCode")) is not int or not 0 <= record["exitCode"] <= 255:
                raise ValueError("exitCode must be an integer process status")
            result = record.get("result")
            if not isinstance(result, dict) or type(result.get("ok")) is not bool or result.get("command") != "export":
                raise ValueError("result must be an export JSON object with boolean ok")
            if (record["exitCode"] == 0) != result["ok"]:
                raise ValueError("exitCode and result.ok disagree")
            if result["ok"]:
                for key in FIELDS + ("durationSeconds",):
                    if key not in result:
                        raise ValueError(f"result.{key} is missing")
                for key in ("width", "height", "frames", "audioSampleRate", "audioSamples"):
                    if type(result[key]) is not int or result[key] < 0:
                        raise ValueError(f"result.{key} must be a nonnegative integer")
                for key in ("fps", "durationSeconds"):
                    if type(result[key]) not in (int, float) or not math.isfinite(result[key]) or result[key] < 0:
                        raise ValueError(f"result.{key} must be a finite nonnegative number")
                for key in ("aspect", "captionStyle"):
                    if not isinstance(result[key], str):
                        raise ValueError(f"result.{key} must be a string")
            elif not isinstance(result.get("error"), dict) or not isinstance(result["error"].get("code"), str):
                raise ValueError("failure result needs error.code")
            reports[case] = record
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
            errors.append(f"{platform}: {path.name}: {error}")
    for case in CASE_IDS:
        if case not in reports:
            errors.append(f"{platform}: missing {case}")
    if len(paths) != len(CASE_IDS):
        errors.append(f"{platform}: expected exactly ten JSON files, found {len(paths)}")
    return reports, errors


def compare(mac_dir: Path, windows_dir: Path) -> list[str]:
    mac, errors = load_reports(mac_dir, "macos")
    windows, win_errors = load_reports(windows_dir, "windows")
    errors.extend(win_errors)
    if errors:
        return errors
    for case in CASE_IDS:
        left, right = mac[case], windows[case]
        mac_result, win_result = left["result"], right["result"]
        if case == WEBM:
            if left["exitCode"] != 3 or mac_result["error"]["code"] != "unsupportedContainer":
                errors.append(f"{case}: macOS must exit 3 with unsupportedContainer")
            if right["exitCode"] != 0:
                errors.append(f"{case}: Windows must export successfully")
            continue
        if left["exitCode"] != right["exitCode"]:
            errors.append(f"{case}: exitCode {left['exitCode']} != {right['exitCode']}")
        if mac_result["ok"] != win_result["ok"]:
            errors.append(f"{case}: result.ok differs")
            continue
        if not mac_result["ok"]:
            a, b = mac_result["error"]["code"], win_result["error"]["code"]
            if a != b:
                errors.append(f"{case}: error.code {a!r} != {b!r}")
            continue
        for key in FIELDS:
            if mac_result[key] != win_result[key] or type(mac_result[key]) is not type(win_result[key]):
                errors.append(f"{case}: {key} {mac_result[key]!r} != {win_result[key]!r}")
        a, b = mac_result["durationSeconds"], win_result["durationSeconds"]
        if abs(a - b) > 0.001:
            errors.append(f"{case}: durationSeconds {a!r} != {b!r} (tolerance 0.001)")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("macos", type=Path)
    parser.add_argument("windows", type=Path)
    args = parser.parse_args()
    errors = compare(args.macos, args.windows)
    for error in errors:
        print(error)
    if not errors:
        print("Ten macOS and Windows CLI E2E reports agree under architecture 9.5")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
