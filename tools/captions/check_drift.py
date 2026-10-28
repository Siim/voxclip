#!/usr/bin/env python3
"""Check caption generator drift, allowing only box contrast libm last-bit differences."""
import json
import runpy
import subprocess
from pathlib import Path

TOLERANT = ["shared/fixtures/captions/box-text-colors.json"]


def main():
    root = Path(__file__).resolve().parents[2]
    checker = runpy.run_path(str(root / "tools/fixtures/voice-lab/check_drift.py"))
    paths = subprocess.run(["git", "ls-files", "shared/fixtures/captions"], check=True,
                           capture_output=True, text=True, cwd=root).stdout.splitlines()
    failed = False
    checked = 0
    for path in paths:
        if not path.endswith(".json") or "/golden/" in path:
            continue
        committed = subprocess.run(["git", "show", "HEAD:" + path], check=True,
                                   capture_output=True, cwd=root).stdout
        regenerated = (root / path).read_bytes()
        checked += 1
        if committed == regenerated:
            continue
        if path not in TOLERANT or checker["differences"](json.loads(committed), json.loads(regenerated)):
            print(f"::error::{path} drifted")
            failed = True
        else:
            (root / path).write_bytes(committed)
            print(f"{path}: equal within rel {checker['REL_TOL']:g} / abs {checker['ABS_TOL']:g}; committed bytes restored")
    print(f"checked {checked} caption JSON fixtures; all but box-text-colors.json are byte-exact")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
