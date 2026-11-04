#!/usr/bin/env python3
"""Generate the shared schema-v4 background-music wire fixtures (doc/spec/music.md section 2).

Writes shared/fixtures/music/music-project.voxclip and music-wire-cases.json (format voxclip-music-wire-cases/1).
Both Cores replay them: Swift MusicProjectWireTests and C# MusicProjectWireTests. `schemaValid: true` on an invalid case
marks a rule JSON Schema cannot express (clip identity, the project's own asset folder, one track per clip, an offset
inside the track). Synthetic metadata only: no audio, no downloaded music. Deterministic; run from anywhere.
"""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/music'


def generated():
    project = json.loads((ROOT / 'shared/fixtures/context-demo/v4-project.voxclip').read_text())
    project.pop('contextDemo')
    project.pop('motionCues')
    project['title'] = 'Synthetic background music wire fixture'
    pid = project['id']
    library = {
        'id': 'music-main', 'clipId': 'clip-main',
        'asset': {'file': f'{pid}/music-calm-intro.mp3', 'sha256': 'a' * 64, 'durationSeconds': 222},
        'source': 'library', 'title': 'Synthetic calm intro', 'creator': 'Synthetic artist', 'license': 'by',
        'attribution': '"Synthetic calm intro" by Synthetic artist is licensed under CC BY 3.0.',
        'sourceUrl': 'https://example.com/track/1', 'prompt': None,
        'gainDb': -20, 'ducking': True, 'fadeInSeconds': 0.5, 'fadeOutSeconds': 1.5, 'startOffsetSeconds': 0}
    generated_track = {
        'id': 'music-full', 'clipId': None,
        'asset': {'file': f'{pid}/music-generated-1.mp3', 'sha256': 'b' * 64, 'durationSeconds': 8},
        'source': 'generated', 'title': 'Warm focus bed', 'creator': None, 'license': 'generated', 'attribution': None,
        'sourceUrl': None, 'prompt': 'Instrumental background music, warm focus mood, steady, sits under a voice',
        'gainDb': -24.5, 'ducking': False, 'fadeInSeconds': 0, 'fadeOutSeconds': 3, 'startOffsetSeconds': 2.25}
    own = {**library, 'id': 'music-own', 'asset': {**library['asset'], 'file': f'{pid}/music-own-file.m4a'},
           'source': 'file', 'title': 'my-track', 'creator': None, 'license': 'own', 'attribution': None, 'sourceUrl': None}
    project['music'] = [library, generated_track]

    def set_value(path, value):
        return {'path': path, 'value': value}

    def remove(path):
        return {'path': path, 'remove': True}

    valid = [
        {'id': 'library-and-generated', 'patches': []},
        {'id': 'library-only', 'patches': [set_value('/music', [library])]},
        {'id': 'own-file', 'patches': [set_value('/music', [own])]},
        {'id': 'cc0-without-attribution', 'patches': [set_value('/music/0/license', 'cc0'), set_value('/music/0/attribution', None)]},
        {'id': 'public-domain', 'patches': [set_value('/music/0/license', 'pdm')]},
        {'id': 'no-music-is-omitted', 'patches': [remove('/music')]},
        {'id': 'aiff-and-wav', 'patches': [set_value('/music/0/asset/file', f'{pid}/music-a.aiff'),
                                           set_value('/music/1/asset/file', f'{pid}/music-b.wav')]},
        {'id': 'quietest-and-loudest', 'patches': [set_value('/music/0/gainDb', -40), set_value('/music/1/gainDb', 0)]},
        {'id': 'longest-fades', 'patches': [set_value('/music/0/fadeInSeconds', 10), set_value('/music/0/fadeOutSeconds', 10)]}]

    invalid = []

    def reject(identity, patches, schema_valid=False):
        invalid.append({'id': identity, 'schemaValid': schema_valid, 'patches': patches})

    reject('unknown-entry-field', [set_value('/music/0/unexpected', True)])
    reject('unknown-asset-field', [set_value('/music/0/asset/unexpected', True)])
    for key in ['clipId', 'creator', 'attribution', 'sourceUrl', 'prompt', 'ducking', 'startOffsetSeconds']:
        reject(f'missing-{key}', [remove(f'/music/0/{key}')])
    reject('missing-asset-hash', [remove('/music/0/asset/sha256')])
    for license in ['by-nc', 'by-sa', 'by-nd', 'by-nc-sa', 'nc', 'sa', 'nd']:
        reject(f'license-{license}', [set_value('/music/0/license', license)])
    reject('library-generated-license', [set_value('/music/0/license', 'generated')])
    reject('library-own-license', [set_value('/music/0/license', 'own')])
    reject('generated-library-license', [set_value('/music/1/license', 'cc0')])
    reject('own-file-cc-license', [set_value('/music', [{**own, 'license': 'by'}])])
    reject('unknown-source', [set_value('/music/0/source', 'stream')])
    reject('by-without-attribution', [set_value('/music/0/attribution', None)])
    reject('library-without-url', [set_value('/music/0/sourceUrl', None)])
    reject('library-http-url', [set_value('/music/0/sourceUrl', 'http://example.com/track/1')])
    reject('generated-without-prompt', [set_value('/music/1/prompt', None)])
    reject('library-with-prompt', [set_value('/music/0/prompt', 'calm')])
    reject('empty-title', [set_value('/music/0/title', '')])
    reject('numeric-title', [set_value('/music/0/title', 7)])
    reject('string-ducking', [set_value('/music/0/ducking', 'true')])
    reject('numeric-ducking', [set_value('/music/0/ducking', 1)])
    reject('string-gain', [set_value('/music/0/gainDb', '-20')])
    reject('gain-too-loud', [set_value('/music/0/gainDb', 0.5)])
    reject('gain-too-quiet', [set_value('/music/0/gainDb', -40.5)])
    reject('fade-too-long', [set_value('/music/0/fadeOutSeconds', 10.5)])
    reject('negative-fade', [set_value('/music/0/fadeInSeconds', -0.1)])
    reject('negative-offset', [set_value('/music/0/startOffsetSeconds', -1)])
    reject('zero-duration', [set_value('/music/0/asset/durationSeconds', 0)])
    reject('too-long-track', [set_value('/music/0/asset/durationSeconds', 1800.5)])
    reject('uppercase-hash', [set_value('/music/0/asset/sha256', 'A' * 64)])
    reject('ogg-file', [set_value('/music/0/asset/file', f'{pid}/music-calm.ogg')])
    reject('unprefixed-file', [set_value('/music/0/asset/file', f'{pid}/calm.mp3')])
    reject('traversal-file', [set_value('/music/0/asset/file', '../music-calm.mp3')])
    reject('empty-music-list', [set_value('/music', [])])
    reject('null-music', [set_value('/music', None)])
    reject('bad-identifier', [set_value('/music/0/id', '-bad')])
    reject('other-project-folder', [set_value('/music/0/asset/file', '00000000-0000-0000-0000-000000000001/music-calm.mp3')], True)
    reject('unknown-clip', [set_value('/music/0/clipId', 'clip-missing')], True)
    reject('two-tracks-one-clip', [set_value('/music/1/clipId', 'clip-main')], True)
    reject('duplicate-identity', [set_value('/music/1/id', 'music-main')], True)
    reject('offset-past-track', [set_value('/music/1/startOffsetSeconds', 8)], True)
    for version in (1, 2, 3):
        reject(f'v{version}-music', [set_value('/schemaVersion', version)])
    reject('future-project', [set_value('/schemaVersion', 5)])
    invalid[-1]['tooNew'] = True
    cases = {'format': 'voxclip-music-wire-cases/1', 'project': 'fixtures/music/music-project.voxclip',
             'valid': valid, 'invalid': invalid}
    return {'music-project.voxclip': project, 'music-wire-cases.json': cases}


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
