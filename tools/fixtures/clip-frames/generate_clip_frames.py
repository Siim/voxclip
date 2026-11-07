#!/usr/bin/env python3
"""Generate the shared "Claude sees the picture" project wire fixtures (ADR-R48, doc/design.md section 6.7.1).

Writes shared/fixtures/clip-frames/clip-frames-project.voxclip and clip-frames-wire-cases.json (format
voxclip-clip-frames-wire-cases/1), a new file of its own so no existing replay changes. The project is the clip-controls
fixture with a lead-in on its clip and a face-follow crop and a cover on its controls. Swift ClipFramesProjectWireTests and C#
ClipFramesProjectWireTests replay every case: each valid case loads, validates and saves byte-identically (Windows keeps the
fields losslessly). `schemaValid: true` on an invalid case marks a rule JSON Schema cannot express. Deterministic; run from
anywhere.
"""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-frames'


def generated():
    project = json.loads((ROOT / 'shared/fixtures/clip-controls/clip-controls-project.voxclip').read_text())
    project['title'] = 'Synthetic clip frames wire fixture'
    # w1 starts at 0.3 s and is the first item: the clip may open up to 0.3 s earlier.
    project['edits']['clips'][0]['leadInSeconds'] = 0.25
    controls = project['clipControls'][0]
    controls['reframe'] = {'mode': 'face', 'zoom': 1, 'centerX': 0.42, 'centerY': 0.38}
    controls['coverSeconds'] = 1.3
    plain = {'clipId': 'clip-main', 'speed': 1, 'shape': None, 'look': 'original', 'gainDb': 0, 'fadeInSeconds': 0,
             'fadeOutSeconds': 0, 'muteSource': False, 'flipHorizontal': False, 'rotationDegrees': 0}

    def set_value(path, value):
        return {'path': path, 'value': value}

    def remove(path):
        return {'path': path, 'remove': True}

    valid = [
        {'id': 'every-field', 'patches': []},
        {'id': 'lead-in-only', 'patches': [remove('/clipControls')]},
        {'id': 'longest-lead-in', 'patches': [set_value('/edits/clips/0/leadInSeconds', 0.6)]},
        {'id': 'no-lead-in-is-omitted', 'patches': [remove('/edits/clips/0/leadInSeconds')]},
        {'id': 'face-follow-only', 'patches': [set_value('/clipControls', [{**plain, 'reframe': controls['reframe']}])]},
        {'id': 'cover-only', 'patches': [set_value('/clipControls', [{**plain, 'coverSeconds': 0}])]},
        {'id': 'face-at-the-edge', 'patches': [set_value('/clipControls/0/reframe/centerX', 1), set_value('/clipControls/0/reframe/centerY', 0)]},
        {'id': 'no-reframe-or-cover-is-omitted', 'patches': [remove('/clipControls/0/reframe'), remove('/clipControls/0/coverSeconds')]}]

    invalid = []

    def reject(identity, patches, schema_valid=False):
        invalid.append({'id': identity, 'schemaValid': schema_valid, 'patches': patches})

    reject('zero-lead-in', [set_value('/edits/clips/0/leadInSeconds', 0)])
    reject('lead-in-too-long', [set_value('/edits/clips/0/leadInSeconds', 0.61)])
    reject('negative-lead-in', [set_value('/edits/clips/0/leadInSeconds', -0.1)])
    reject('string-lead-in', [set_value('/edits/clips/0/leadInSeconds', '0.25')])
    reject('null-lead-in', [set_value('/edits/clips/0/leadInSeconds', None)])
    reject('v3-lead-in', [remove('/clipControls'), set_value('/schemaVersion', 3)])
    reject('centre-mode', [set_value('/clipControls/0/reframe/mode', 'center')])
    reject('zoomed-reframe', [set_value('/clipControls/0/reframe/zoom', 1.5)])
    reject('missing-centre', [remove('/clipControls/0/reframe/centerY')])
    reject('centre-outside', [set_value('/clipControls/0/reframe/centerX', 1.2)])
    reject('unknown-reframe-field', [set_value('/clipControls/0/reframe/path', [])])
    reject('null-reframe', [set_value('/clipControls/0/reframe', None)])
    reject('negative-cover', [set_value('/clipControls/0/coverSeconds', -0.5)])
    reject('string-cover', [set_value('/clipControls/0/coverSeconds', '1.3')])
    cases = {'format': 'voxclip-clip-frames-wire-cases/1', 'project': 'fixtures/clip-frames/clip-frames-project.voxclip',
             'valid': valid, 'invalid': invalid}
    return {'clip-frames-project.voxclip': project, 'clip-frames-wire-cases.json': cases}


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name, document in generated().items():
        (DESTINATION / name).write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n')


def apply_case(document, case):
    """JSON-pointer replacement and removal, as both Cores apply it."""
    result = copy.deepcopy(document)
    for patch in case['patches']:
        parts = patch['path'].strip('/').split('/')
        target = result
        for part in parts[:-1]:
            target = target[int(part)] if isinstance(target, list) else target[part]
        key = int(parts[-1]) if isinstance(target, list) else parts[-1]
        if patch.get('remove'):
            del target[key]
        else:
            target[key] = copy.deepcopy(patch['value'])
    return result


if __name__ == '__main__':
    main()
