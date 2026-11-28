#!/usr/bin/env python3
"""Generate the shared schema-v4 clip-controls wire fixtures (doc/design.md section 6.9).

Writes shared/fixtures/clip-controls/clip-controls-project.voxclip and clip-controls-wire-cases.json (format
voxclip-clip-controls-wire-cases/1), a new file of its own so neither Core's existing replays change. Both Cores replay it:
Swift ClipControlsProjectWireTests and C# ClipControlsProjectWireTests. `schemaValid: true` on an invalid case marks a rule
JSON Schema cannot express (the clip exists, one entry per clip, no entry stored at its defaults). Deterministic; run from
anywhere.

clip-controls-color-grade-cases.json (format voxclip-clip-color-grade-wire-cases/1) holds the schema-v8 `colorGrade`
cases (looks spec 2026-11-28, sections 8.1 and 11.5) on the same project: each case first sets schemaVersion 8, then its
own patches. A valid case round-trips byte for byte at v8; `schemaValid: true` on an invalid case marks a rule only the
Cores check (a curve never decreases).
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
    reject('future-project', [set_value('/schemaVersion', 999)])
    invalid[-1]['tooNew'] = True
    cases = {'format': 'voxclip-clip-controls-wire-cases/1', 'project': 'fixtures/clip-controls/clip-controls-project.voxclip',
             'valid': valid, 'invalid': invalid}
    return {'clip-controls-project.voxclip': project, 'clip-controls-wire-cases.json': cases,
            'clip-controls-color-grade-cases.json': color_grade_cases(defaults)}


SLIDERS = ['exposure', 'temperature', 'tint', 'highlights', 'shadows', 'vibrance', 'fade', 'vignette', 'grain']


def grade(**values):
    """A colorGrade as the Cores write it: preset and amount first when present, all nine sliders, then the toning."""
    result = {key: values.pop(key) for key in ('preset', 'amount') if key in values}
    result.update({name: values.pop(name, 0) for name in SLIDERS})
    result.update({key: values.pop(key) for key in ('curve', 'splitTone') if key in values})
    assert not values, values
    return result


def color_grade_cases(defaults):
    def set_value(path, value):
        return {'path': path, 'value': value}

    def remove(path):
        return {'path': path, 'remove': True}

    at = '/clipControls/0/colorGrade'
    v8 = set_value('/schemaVersion', 8)
    split = {'shadowHue': 200, 'shadowSaturation': 10, 'highlightHue': 38, 'highlightSaturation': 30, 'balance': 0}
    reference = grade(preset='warmPrint', amount=70, highlights=-15, vibrance=20, fade=20, grain=20,
                      curve={'master': [0, 245, 500, 760, 965]}, splitTone=split)
    vibrant = grade(vibrance=25)
    valid = [
        # The reference task (spec section 8.1): Warm Print at 70% with vibrance +20 and highlights -15.
        {'id': 'reference-task', 'patches': [set_value('/clipControls/0/look', 'original'),
                                             set_value('/clipControls/0/colorAdjustments', {'brightness': 0, 'contrast': 0, 'saturation': -10, 'warmth': 26}),
                                             set_value(at, reference)]},
        {'id': 'muted-at-seventy', 'patches': [set_value(at, grade(preset='muted', amount=70))]},
        {'id': 'fix-only', 'patches': [set_value('/clipControls/0/look', 'original'), set_value(at, grade(exposure=20))]},
        {'id': 'grade-only-entry', 'patches': [set_value('/clipControls', [{**defaults, 'colorGrade': vibrant}])]},
        {'id': 'every-slider-at-its-top', 'patches': [set_value(at, grade(
            amount=0, **{name: 100 for name in SLIDERS},
            curve={'master': [0, 0, 0, 0, 0], 'red': [1000, 1000, 1000, 1000, 1000], 'green': [0, 250, 500, 750, 1000],
                   'blue': [0, 1, 1, 999, 1000]},
            splitTone={'shadowHue': 0, 'shadowSaturation': 100, 'highlightHue': 359, 'highlightSaturation': 100, 'balance': -100}))]},
        {'id': 'every-slider-at-its-bottom', 'patches': [set_value(at, grade(
            amount=99, **{name: (0 if name in ('fade', 'vignette', 'grain') else -100) for name in SLIDERS}))]},
        {'id': 'unknown-preset-renders-from-values', 'patches': [set_value(at, grade(preset='futureLook9', vibrance=10))]},
        {'id': 'longest-preset', 'patches': [set_value(at, grade(preset='a' * 40, fade=5))]},
        {'id': 'one-channel-curve', 'patches': [set_value(at, grade(curve={'red': [0, 260, 510, 760, 1000]}))]},
        {'id': 'split-tone-only', 'patches': [set_value(at, grade(splitTone={**split, 'balance': 100}))]},
        {'id': 'amount-alone', 'patches': [set_value(at, grade(preset='muted', amount=0))]}]
    for case in valid:
        case['patches'].insert(0, v8)

    invalid = []

    def reject(identity, patches, schema_valid=False, version=v8):
        invalid.append({'id': identity, 'schemaValid': schema_valid, 'patches': [version] + patches})

    def field(name, value):
        return [set_value(at, vibrant), set_value(f'{at}/{name}', value)]

    reject('neutral-grade', [set_value(at, grade())])
    reject('preset-alone', [set_value(at, grade(preset='warmPrint'))])
    reject('full-amount-written', [set_value(at, grade(amount=100, vibrance=25))])
    reject('null-grade', [set_value(at, None)])
    reject('list-grade', [set_value(at, [vibrant])])
    reject('unknown-grade-field', field('whites', 0))
    for name in SLIDERS:
        reject(f'missing-{name}', [set_value(at, vibrant), remove(f'{at}/{name}')])
    reject('exposure-too-high', field('exposure', 101))
    reject('vibrance-too-low', field('vibrance', -101))
    reject('negative-fade', field('fade', -1))
    reject('vignette-too-high', field('vignette', 101))
    reject('grain-too-high', field('grain', 101))
    reject('negative-amount', field('amount', -1))
    reject('fractional-point', field('highlights', 1.5))
    reject('string-point', field('tint', '5'))
    reject('boolean-point', field('shadows', True))
    reject('empty-preset', field('preset', ''))
    reject('long-preset', field('preset', 'a' * 41))
    reject('preset-with-a-dash', field('preset', 'warm-print'))
    reject('accented-preset', field('preset', 'caf\u00e9'))
    reject('numeric-preset', field('preset', 5))
    reject('empty-curve', field('curve', {}))
    reject('unknown-curve-channel', field('curve', {'alpha': [0, 250, 500, 750, 1000]}))
    reject('short-curve', field('curve', {'master': [0, 250, 750, 1000]}))
    reject('long-curve', field('curve', {'master': [0, 200, 400, 600, 800, 1000]}))
    reject('curve-above-1000', field('curve', {'master': [0, 250, 500, 750, 1001]}))
    reject('negative-curve', field('curve', {'master': [-1, 250, 500, 750, 1000]}))
    reject('fractional-curve', field('curve', {'master': [0, 245.5, 500, 760, 965]}))
    reject('null-curve-channel', field('curve', {'master': None}))
    reject('falling-curve', field('curve', {'master': [0, 500, 400, 760, 965]}), True)
    reject('hue-360', field('splitTone', {**split, 'shadowHue': 360}))
    reject('negative-hue', field('splitTone', {**split, 'highlightHue': -1}))
    reject('split-saturation-too-high', field('splitTone', {**split, 'shadowSaturation': 101}))
    reject('balance-too-high', field('splitTone', {**split, 'balance': 101}))
    reject('fractional-hue', field('splitTone', {**split, 'shadowHue': 200.5}))
    reject('split-missing-balance', field('splitTone', {key: value for key, value in split.items() if key != 'balance'}))
    reject('split-extra-key', field('splitTone', {**split, 'midtoneHue': 90}))
    # A colour grade needs the v8 frame (spec section 8.4): a v4 or v6 project with one is refused.
    for version in (4, 6):
        reject(f'v{version}-color-grade', [set_value(at, vibrant)], version=set_value('/schemaVersion', version))
    return {'format': 'voxclip-clip-color-grade-wire-cases/1', 'project': 'fixtures/clip-controls/clip-controls-project.voxclip',
            'valid': valid, 'invalid': invalid}


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
