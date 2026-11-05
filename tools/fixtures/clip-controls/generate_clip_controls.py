#!/usr/bin/env python3
"""Generate the shared schema-v4 clip-controls wire fixtures (doc/design.md section 6.9).

Writes shared/fixtures/clip-controls/clip-controls-project.voxclip and clip-controls-wire-cases.json (format
voxclip-clip-controls-wire-cases/1), a new file of its own so neither Core's existing replays change. Both Cores replay it:
Swift ClipControlsProjectWireTests and C# ClipControlsProjectWireTests. `schemaValid: true` on an invalid case marks a rule
JSON Schema cannot express (the clip exists, one entry per clip, no entry stored at its defaults). Deterministic; run from
anywhere.
"""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-controls'


def generated():
    project = json.loads((ROOT / 'shared/fixtures/context-demo/v4-project.voxclip').read_text())
    project.pop('contextDemo')
    project.pop('motionCues')
    project['title'] = 'Synthetic clip controls wire fixture'
    main = {'clipId': 'clip-main', 'speed': 1.25, 'shape': '9:16', 'look': 'muted', 'gainDb': -3.5,
            'fadeInSeconds': 0.5, 'fadeOutSeconds': 1, 'muteSource': False, 'flipHorizontal': True, 'rotationDegrees': 90}
    project['clipControls'] = [main]
    defaults = {'clipId': 'clip-main', 'speed': 1, 'shape': None, 'look': 'original', 'gainDb': 0,
                'fadeInSeconds': 0, 'fadeOutSeconds': 0, 'muteSource': False, 'flipHorizontal': False, 'rotationDegrees': 0}

    def set_value(path, value):
        return {'path': path, 'value': value}

    def remove(path):
        return {'path': path, 'remove': True}

    valid = [
        {'id': 'every-control', 'patches': []},
        {'id': 'speed-only', 'patches': [set_value('/clipControls', [{**defaults, 'speed': 1.1}])]},
        {'id': 'slowest', 'patches': [set_value('/clipControls/0/speed', 0.5)]},
        {'id': 'fastest', 'patches': [set_value('/clipControls/0/speed', 2)]},
        {'id': 'four-five-frame', 'patches': [set_value('/clipControls/0/shape', '4:5')]},
        {'id': 'project-frame', 'patches': [set_value('/clipControls/0/shape', None)]},
        {'id': 'black-and-white', 'patches': [set_value('/clipControls/0/look', 'bw')]},
        {'id': 'warm', 'patches': [set_value('/clipControls/0/look', 'warm')]},
        {'id': 'muted-source', 'patches': [set_value('/clipControls', [{**defaults, 'muteSource': True}])]},
        {'id': 'loudest-and-longest-fades', 'patches': [set_value('/clipControls/0/gainDb', 12), set_value('/clipControls/0/fadeInSeconds', 5),
                                                        set_value('/clipControls/0/fadeOutSeconds', 5)]},
        {'id': 'quietest', 'patches': [set_value('/clipControls/0/gainDb', -24)]},
        {'id': 'half-turn', 'patches': [set_value('/clipControls/0/rotationDegrees', 180)]},
        {'id': 'no-controls-is-omitted', 'patches': [remove('/clipControls')]}]

    invalid = []

    def reject(identity, patches, schema_valid=False):
        invalid.append({'id': identity, 'schemaValid': schema_valid, 'patches': patches})

    reject('unknown-field', [set_value('/clipControls/0/unexpected', True)])
    for key in ['clipId', 'speed', 'shape', 'look', 'gainDb', 'fadeInSeconds', 'fadeOutSeconds', 'muteSource', 'flipHorizontal',
                'rotationDegrees']:
        reject(f'missing-{key}', [remove(f'/clipControls/0/{key}')])
    reject('too-slow', [set_value('/clipControls/0/speed', 0.49)])
    reject('too-fast', [set_value('/clipControls/0/speed', 2.01)])
    reject('zero-speed', [set_value('/clipControls/0/speed', 0)])
    reject('string-speed', [set_value('/clipControls/0/speed', '1.25')])
    reject('source-shape', [set_value('/clipControls/0/shape', 'source')])
    reject('unknown-shape', [set_value('/clipControls/0/shape', '2:1')])
    reject('unknown-look', [set_value('/clipControls/0/look', 'sepia')])
    reject('display-look-name', [set_value('/clipControls/0/look', 'B&W')])
    reject('gain-too-loud', [set_value('/clipControls/0/gainDb', 12.5)])
    reject('gain-too-quiet', [set_value('/clipControls/0/gainDb', -24.5)])
    reject('fade-too-long', [set_value('/clipControls/0/fadeOutSeconds', 5.1)])
    reject('negative-fade', [set_value('/clipControls/0/fadeInSeconds', -0.1)])
    reject('numeric-mute', [set_value('/clipControls/0/muteSource', 1)])
    reject('string-flip', [set_value('/clipControls/0/flipHorizontal', 'true')])
    reject('odd-rotation', [set_value('/clipControls/0/rotationDegrees', 45)])
    reject('full-turn', [set_value('/clipControls/0/rotationDegrees', 360)])
    reject('fractional-rotation', [set_value('/clipControls/0/rotationDegrees', 90.5)])
    reject('empty-list', [set_value('/clipControls', [])])
    reject('null-list', [set_value('/clipControls', None)])
    reject('bad-clip-identifier', [set_value('/clipControls/0/clipId', '-bad')])
    reject('unknown-clip', [set_value('/clipControls/0/clipId', 'clip-missing')], True)
    reject('two-entries-one-clip', [set_value('/clipControls', [main, {**main, 'speed': 1.5}])], True)
    reject('stored-defaults', [set_value('/clipControls', [defaults])], True)
    for version in (1, 2, 3):
        reject(f'v{version}-clip-controls', [set_value('/schemaVersion', version)])
    reject('future-project', [set_value('/schemaVersion', 5)])
    invalid[-1]['tooNew'] = True
    cases = {'format': 'voxclip-clip-controls-wire-cases/1', 'project': 'fixtures/clip-controls/clip-controls-project.voxclip',
             'valid': valid, 'invalid': invalid}
    return {'clip-controls-project.voxclip': project, 'clip-controls-wire-cases.json': cases}


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
