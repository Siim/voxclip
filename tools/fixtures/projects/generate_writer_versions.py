#!/usr/bin/env python3
"""Generate the project writer-version cases (editing section 10.1, release section 1).

A runtime version that matches the release grammar is stamped as is; anything else (missing, blank or invalid)
is stamped "0.0.0". Both Core suites save and reload every case.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / 'shared/fixtures/projects/writer-versions.json'
# The release grammar from tools/release/version.py: X.Y.Z or X.Y.Z-beta.N, no leading zeros.
VERSION = re.compile(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-beta\.(?:0|[1-9][0-9]*))?')
FALLBACK = '0.0.0'
RUNTIMES = [
    None, '', ' \t\n', 'unknown', 'invalid', '1.2', '1.2.3.4', '01.2.3', '1.02.3', '1.2.03', '1.2.3-beta.01',
    '1.2.3-alpha.1', '1.2.3+build', '1.2.3\n', '1.2.3', '9.8.7-beta.2', '0.0.0', '0.0.0-beta.0',
]


def writer(runtime):
    return runtime if isinstance(runtime, str) and VERSION.fullmatch(runtime) else FALLBACK


def render():
    lines = [f'{{ "runtime": {json.dumps(runtime)}, "writer": {json.dumps(writer(runtime))} }}' for runtime in RUNTIMES]
    return '[\n' + ',\n'.join('  ' + line for line in lines) + '\n]\n'


if __name__ == '__main__':
    OUTPUT.write_text(render(), encoding='utf-8')
