#!/usr/bin/env python3
"""Generate the shared schema-v4 clip-effects wire fixtures (doc/spec/ai.md section 18.2).

Writes shared/fixtures/clip-effects/effects-project.voxclip and effects-wire-cases.json (format
voxclip-clip-effects-wire-cases/1). Both Cores replay them: Swift ClipEffectsWireTests and C# ClipEffectsWireTests.
`schemaValid: true` on an invalid case marks a rule JSON Schema cannot express (the clip and the words exist, a rect
inside the frame, increasing track times, a freeze at most 5 s, a sound spanning its own length, the project's own sound
folder, unique ids). Synthetic metadata only: no audio, no video. Deterministic; run from anywhere.
"""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-effects'


def generated():
    project = json.loads((ROOT / 'shared/fixtures/context-demo/v4-project.voxclip').read_text())
    project.pop('contextDemo')
    project.pop('motionCues')
    project['title'] = 'Synthetic clip effects wire fixture'
    pid = project['id']
    rect = {'x': 0.1, 'y': 0.2, 'width': 0.3, 'height': 0.25}
    bleep = {'id': 'fx-bleep-1', 'clipId': 'clip-main', 'kind': 'bleep', 'start': 2.8, 'end': 3.1, 'wordIds': ['w5']}
    blur = {'id': 'fx-blur-1', 'clipId': 'clip-main', 'kind': 'blur', 'start': 1.0, 'end': 1.5, 'rect': rect, 'tracking': 'face',
            'track': [{'t': 1.0, **rect}, {'t': 1.25, 'x': 0.12, 'y': 0.2, 'width': 0.3, 'height': 0.25}, {'t': 1.5, **rect}]}
    pixelate = {'id': 'fx-pixelate-1', 'clipId': None, 'kind': 'pixelate', 'start': 0, 'end': 7, 'rect': rect, 'tracking': 'none', 'track': []}
    title = {'id': 'fx-title-1', 'clipId': 'clip-main', 'kind': 'title', 'start': 0.3, 'end': 2.3, 'text': 'Day 1', 'position': 'top'}
    lower = {'id': 'fx-lowerThird-1', 'clipId': 'clip-main', 'kind': 'lowerThird', 'start': 2.6, 'end': 4.2, 'text': 'Synthetic speaker',
             'position': 'bottomLeft'}
    sticker = {'id': 'fx-sticker-1', 'clipId': 'clip-main', 'kind': 'sticker', 'start': 5.5, 'end': 6.5, 'text': '\U0001F525',
               'position': 'topRight', 'scale': 1}
    arrow = {'id': 'fx-arrow-1', 'clipId': 'clip-main', 'kind': 'arrow', 'start': 3.5, 'end': 4.5, 'rect': rect}
    circle = {'id': 'fx-circle-1', 'clipId': 'clip-main', 'kind': 'circle', 'start': 3.5, 'end': 4.5, 'rect': rect}
    progress = {'id': 'fx-progress-1', 'clipId': 'clip-main', 'kind': 'progress', 'start': 0.3, 'end': 5.9, 'position': 'bottom'}
    freeze = {'id': 'fx-freeze-1', 'clipId': 'clip-main', 'kind': 'freeze', 'start': 4.2, 'end': 5.2}
    sound = {'id': 'fx-sound-1', 'clipId': 'clip-main', 'kind': 'sound', 'start': 2.6, 'end': 2.95, 'gainDb': -6,
             'sound': {'source': 'bundled', 'id': 'whoosh', 'durationSeconds': 0.35, 'title': 'Whoosh', 'license': 'cc0'}}
    library = {'source': 'library', 'file': f'{pid}/sfx-pop-1.wav', 'sha256': 'c' * 64, 'durationSeconds': 0.5,
               'title': 'Synthetic pop', 'creator': 'Synthetic artist', 'license': 'by',
               'attribution': '"Synthetic pop" by Synthetic artist is licensed under CC BY 4.0.', 'sourceUrl': 'https://example.com/sound/1'}
    mute = {'id': 'fx-mute-1', 'clipId': None, 'kind': 'mute', 'start': 0.7, 'end': 1.0, 'wordIds': ['w2']}
    project['clipEffects'] = [bleep, blur, pixelate, title, lower, sticker, arrow, circle, progress, freeze, sound, mute]

    def set_value(path, value):
        return {'path': path, 'value': value}

    def remove(path):
        return {'path': path, 'remove': True}

    valid = [
        {'id': 'every-kind', 'patches': []},
        {'id': 'no-effects-is-omitted', 'patches': [remove('/clipEffects')]},
        {'id': 'bleep-only', 'patches': [set_value('/clipEffects', [bleep])]},
        {'id': 'library-sound', 'patches': [set_value('/clipEffects/10/sound', library), set_value('/clipEffects/10/end', 3.1)]},
        {'id': 'library-sound-cc0', 'patches': [set_value('/clipEffects/10/sound', {**library, 'license': 'cc0', 'attribution': None, 'creator': None}),
                                                set_value('/clipEffects/10/end', 3.1)]},
        {'id': 'saliency-tracking', 'patches': [set_value('/clipEffects/1/tracking', 'saliency')]},
        {'id': 'full-frame-rect', 'patches': [set_value('/clipEffects/2/rect', {'x': 0, 'y': 0, 'width': 1, 'height': 1})]},
        {'id': 'progress-top', 'patches': [set_value('/clipEffects/8/position', 'top')]},
        {'id': 'longest-freeze', 'patches': [set_value('/clipEffects/9/start', 1.0), set_value('/clipEffects/9/end', 6.0)]},
        {'id': 'largest-sticker', 'patches': [set_value('/clipEffects/5/scale', 3)]},
        {'id': 'loudest-sound', 'patches': [set_value('/clipEffects/10/gainDb', 6)]},
        {'id': 'several-words', 'patches': [set_value('/clipEffects/0/wordIds', ['w4', 'w5']), set_value('/clipEffects/0/start', 2.6)]}]

    invalid = []

    def reject(identity, patches, schema_valid=False):
        invalid.append({'id': identity, 'schemaValid': schema_valid, 'patches': patches})

    reject('unknown-field', [set_value('/clipEffects/0/unexpected', True)])
    reject('field-of-another-kind', [set_value('/clipEffects/0/rect', rect)])
    reject('missing-clip-id', [remove('/clipEffects/0/clipId')])
    reject('missing-words', [remove('/clipEffects/0/wordIds')])
    reject('missing-track', [remove('/clipEffects/1/track')])
    reject('missing-position', [remove('/clipEffects/3/position')])
    reject('missing-scale', [remove('/clipEffects/5/scale')])
    reject('missing-gain', [remove('/clipEffects/10/gainDb')])
    reject('unknown-kind', [set_value('/clipEffects/0/kind', 'explode')])
    reject('empty-words', [set_value('/clipEffects/0/wordIds', [])])
    reject('duplicate-words', [set_value('/clipEffects/0/wordIds', ['w5', 'w5'])])
    reject('negative-start', [set_value('/clipEffects/3/start', -0.5)])
    reject('string-start', [set_value('/clipEffects/3/start', '0.3')])
    reject('unknown-tracking', [set_value('/clipEffects/1/tracking', 'object')])
    reject('unknown-position', [set_value('/clipEffects/3/position', 'middle')])
    reject('empty-title', [set_value('/clipEffects/3/text', '')])
    reject('long-title', [set_value('/clipEffects/3/text', 'x' * 81)])
    reject('numeric-title', [set_value('/clipEffects/3/text', 1)])
    reject('tiny-rect', [set_value('/clipEffects/6/rect/width', 0.001)])
    reject('rect-missing-height', [remove('/clipEffects/6/rect/height')])
    reject('rect-extra-field', [set_value('/clipEffects/6/rect/z', 0)])
    reject('sticker-too-small', [set_value('/clipEffects/5/scale', 0.25)])
    reject('gain-too-loud', [set_value('/clipEffects/10/gainDb', 6.5)])
    reject('unknown-bundled-sound', [set_value('/clipEffects/10/sound/id', 'airhorn')])
    reject('bundled-sound-licensed-by', [set_value('/clipEffects/10/sound/license', 'by')])
    reject('library-without-url', [set_value('/clipEffects/10/sound', {**library, 'sourceUrl': None}), set_value('/clipEffects/10/end', 3.1)])
    reject('library-noncommercial', [set_value('/clipEffects/10/sound', {**library, 'license': 'by-nc'}), set_value('/clipEffects/10/end', 3.1)])
    reject('library-by-without-attribution', [set_value('/clipEffects/10/sound', {**library, 'attribution': None}), set_value('/clipEffects/10/end', 3.1)])
    reject('library-traversal-file', [set_value('/clipEffects/10/sound', {**library, 'file': '../sfx-pop.wav'}), set_value('/clipEffects/10/end', 3.1)])
    reject('sound-too-long', [set_value('/clipEffects/10/sound/durationSeconds', 10.5), set_value('/clipEffects/10/end', 13.1)])
    reject('empty-effects-list', [set_value('/clipEffects', [])])
    reject('null-effects', [set_value('/clipEffects', None)])
    reject('bad-identifier', [set_value('/clipEffects/0/id', '-bad')])
    reject('end-before-start', [set_value('/clipEffects/3/end', 0.2)], True)
    reject('range-too-long', [set_value('/clipEffects/2/end', 601)], True)
    reject('rect-past-frame', [set_value('/clipEffects/6/rect/x', 0.9)], True)
    reject('track-out-of-order', [set_value('/clipEffects/1/track/1/t', 0.9)], True)
    reject('untracked-with-samples', [set_value('/clipEffects/1/tracking', 'none')], True)
    reject('freeze-too-long', [set_value('/clipEffects/9/start', 1.0), set_value('/clipEffects/9/end', 6.1)], True)
    reject('sound-range-mismatch', [set_value('/clipEffects/10/end', 3.5)], True)
    reject('long-sticker', [set_value('/clipEffects/5/text', '\U0001F525' * 17)], True)
    reject('progress-in-the-middle', [set_value('/clipEffects/8/position', 'center')], True)
    reject('unknown-clip', [set_value('/clipEffects/0/clipId', 'clip-missing')], True)
    reject('unknown-word', [set_value('/clipEffects/0/wordIds', ['w99'])], True)
    reject('duplicate-identity', [set_value('/clipEffects/1/id', 'fx-bleep-1')], True)
    reject('other-project-sound-folder', [set_value('/clipEffects/10/sound', {**library, 'file': '00000000-0000-0000-0000-000000000001/sfx-pop.wav'}),
                                          set_value('/clipEffects/10/end', 3.1)], True)
    for version in (1, 2, 3):
        reject(f'v{version}-effects', [set_value('/schemaVersion', version)])
    reject('future-project', [set_value('/schemaVersion', 5)])
    invalid[-1]['tooNew'] = True
    cases = {'format': 'voxclip-clip-effects-wire-cases/1', 'project': 'fixtures/clip-effects/effects-project.voxclip',
             'valid': valid, 'invalid': invalid}
    return {'effects-project.voxclip': project, 'effects-wire-cases.json': cases}


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
