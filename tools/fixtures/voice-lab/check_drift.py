#!/usr/bin/env python3
"""Compare regenerated Voice Lab fixtures that hold computed floats with the committed files.

The audio-math generator calls libm (log10, tan, pow) and NumPy reductions whose last bits differ between
platforms: a hosted Ubuntu runner and an Apple silicon Mac disagree by 1 ULP on some coefficients and by up to
~1e-13 on accumulated loudness values. Such a file passes when its structure, strings, booleans and integers are
identical and every float agrees within REL_TOL / ABS_TOL; the committed bytes are then restored so the
byte-exact `git diff --exit-code` that follows checks only the other generators. Run from the repository root,
after the generators."""
import json
import math
import subprocess
import sys

TOLERANT = ['shared/fixtures/voice-lab/audio-math-cases.json']
EXACT = ['shared/fixtures/voice-lab/continuity-cases.json']
REL_TOL = 1e-10
ABS_TOL = 1e-12


def differences(committed, regenerated, where='$'):
    if isinstance(committed, float) and isinstance(regenerated, float):
        close = math.isclose(committed, regenerated, rel_tol=REL_TOL, abs_tol=ABS_TOL)
        return [] if close else [f'{where}: {committed!r} -> {regenerated!r}']
    if type(committed) is not type(regenerated):
        return [f'{where}: {committed!r} -> {regenerated!r}']
    if isinstance(committed, dict):
        if list(committed) != list(regenerated):
            return [f'{where}: keys {list(committed)} -> {list(regenerated)}']
        return [line for key in committed for line in differences(committed[key], regenerated[key], f'{where}.{key}')]
    if isinstance(committed, list):
        if len(committed) != len(regenerated):
            return [f'{where}: {len(committed)} items -> {len(regenerated)}']
        return [line for index, pair in enumerate(zip(committed, regenerated))
                for line in differences(*pair, f'{where}[{index}]')]
    return [] if committed == regenerated else [f'{where}: {committed!r} -> {regenerated!r}']


def main():
    failed = False
    for path in EXACT:
        committed_bytes = subprocess.run(['git', 'show', f'HEAD:{path}'], check=True, capture_output=True).stdout
        with open(path, 'rb') as file:
            regenerated_bytes = file.read()
        if committed_bytes != regenerated_bytes:
            failed = True
            print(f'::error::{path} must match byte for byte')
        else:
            print(f'{path}: identical')
    for path in TOLERANT:
        committed_bytes = subprocess.run(['git', 'show', f'HEAD:{path}'], check=True, capture_output=True).stdout
        with open(path, 'rb') as file:
            regenerated_bytes = file.read()
        if regenerated_bytes == committed_bytes:
            print(f'{path}: identical')
            continue
        found = differences(json.loads(committed_bytes), json.loads(regenerated_bytes))
        if found:
            failed = True
            print(f'::error::{path} drifted beyond the float tolerance ({len(found)} values):')
            for line in found[:40]:
                print(f'  {line}')
            continue
        with open(path, 'wb') as file:
            file.write(committed_bytes)
        print(f'{path}: equal within rel {REL_TOL:g} / abs {ABS_TOL:g}; committed bytes restored')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
