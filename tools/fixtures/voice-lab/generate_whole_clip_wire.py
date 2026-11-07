#!/usr/bin/env python3
"""Generate the shared whole-clip revoice wire fixtures (ADR-R46, voice-lab section 8.14).

Writes shared/fixtures/voice-lab/whole-clip-revoice-project.voxclip (the committed lipsync-render-v3.voxclip with one
`voiceLab.wholeClipRevoices` record over both of its segments) and whole-clip-revoice-wire-cases.json (format
voxclip-whole-clip-revoice-wire/1), a new file of its own so neither Core's existing replays change. Both Cores replay it:
Swift WholeClipRevoiceWireReplayTests and C# WholeClipRevoiceWireTests.

Each valid case opens, validates, saves with every record key written (nulls included) and says what the export's
disclosure reads: its kinds, its post text and the burned-in chip, and whether clip-main shows the AI voice tag.
`schemaValid: true` on an invalid case marks a rule JSON Schema cannot express (the clip and segments exist, a segment
belongs to one record, record ids are distinct, a timestamp carries its zone). Deterministic; run from anywhere.
"""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/voice-lab'
LIPSYNC2 = 'fal-ai/sync-lipsync/v2:lipsync-2'
SYNC3 = 'fal-ai/sync-lipsync/v3'
REVOICE_LINE = 'Voice and lip movement generated with AI.'
REVOICE_CHIP = 'Voice and lip movement generated with AI'
PATCH_LINE = ('Some words in this video were re-voiced with an AI copy of my own voice. '
              'Lip movements in parts of it were generated with AI.')
RECORD = '/voiceLab/wholeClipRevoices/0'


def record(identity='wholeclip-1', segments=('vl-passage', 'vl-thanks')):
    return {'id': identity, 'clipId': 'clip-main', 'segmentIds': list(segments), 'script': 'Thanks for watching.',
            'consentRecordId': 'consent-fixture', 'videoRetime': 0.987, 'lipsyncModel': LIPSYNC2, 'usd': 1.58,
            'match': {'take': 0.81, 'anchorBaseline': 0.54, 'realSpeech': None}, 'createdAt': '2026-11-07T09:00:00.000Z'}


def set_value(path, value):
    return {'path': path, 'value': value}


def remove(path):
    return {'path': path, 'remove': True}


def generated():
    project = json.loads((DESTINATION / 'lipsync-render-v3.voxclip').read_text())
    project['title'] = 'Synthetic whole-clip revoice wire fixture'
    project['voiceLab']['wholeClipRevoices'] = [record()]

    def expect(revoiced=True, post=REVOICE_LINE, chip=REVOICE_CHIP):
        kinds = ['lipsync', 'revoice', 'tts'] if revoiced else ['lipsync', 'tts']
        return {'revoiced': revoiced, 'kinds': kinds, 'postText': post, 'chip': chip}

    valid = [
        {'id': 'record', 'patches': [], **expect()},
        {'id': 'no-match-yet', 'patches': [set_value(RECORD + '/match', None)], **expect()},
        {'id': 'every-score', 'patches': [set_value(RECORD + '/match', {'take': -1, 'anchorBaseline': 1, 'realSpeech': 0.5})], **expect()},
        {'id': 'take-only', 'patches': [set_value(RECORD + '/match', {'take': 0.7, 'anchorBaseline': None, 'realSpeech': None})], **expect()},
        {'id': 'unpriced', 'patches': [set_value(RECORD + '/usd', None)], **expect()},
        {'id': 'free', 'patches': [set_value(RECORD + '/usd', 0)], **expect()},
        {'id': 'sync-3-upgrade', 'patches': [set_value(RECORD + '/lipsyncModel', SYNC3)], **expect()},
        {'id': 'slowest-retime', 'patches': [set_value(RECORD + '/videoRetime', 0.92)], **expect()},
        {'id': 'fastest-retime', 'patches': [set_value(RECORD + '/videoRetime', 1.08)], **expect()},
        {'id': 'one-segment', 'patches': [set_value(RECORD + '/segmentIds', ['vl-thanks'])], **expect()},
        {'id': 'two-records', 'patches': [set_value('/voiceLab/wholeClipRevoices',
                                                    [record('wholeclip-1', ['vl-passage']), record('wholeclip-2', ['vl-thanks'])])], **expect()},
        {'id': 'one-segment-off', 'patches': [set_value('/voiceLab/segments/0/enabled', False)], **expect()},
        {'id': 'estonian', 'patches': [set_value('/transcript/language', 'et')],
         **expect(post='Hääl ja huulte liikumine on loodud tehisintellektiga.')},
        {'id': 'none-is-omitted', 'patches': [remove('/voiceLab/wholeClipRevoices')],
         **expect(revoiced=False, post=PATCH_LINE, chip='Lip movement generated with AI')}]

    invalid = []

    def reject(identity, patches, schema_valid=False):
        invalid.append({'id': identity, 'schemaValid': schema_valid, 'patches': patches})

    reject('unknown-field', [set_value(RECORD + '/unexpected', True)])
    reject('unknown-match-field', [set_value(RECORD + '/match/unexpected', 1)])
    for key in record():
        reject(f'missing-{key}', [remove(f'{RECORD}/{key}')])
    for key in ('take', 'anchorBaseline', 'realSpeech'):
        reject(f'missing-match-{key}', [remove(f'{RECORD}/match/{key}')])
    reject('bad-identifier', [set_value(RECORD + '/id', '-bad')])
    reject('bad-clip-identifier', [set_value(RECORD + '/clipId', 'clip main')])
    reject('unknown-clip', [set_value(RECORD + '/clipId', 'clip-missing')], True)
    reject('no-segments', [set_value(RECORD + '/segmentIds', [])])
    reject('repeated-segment', [set_value(RECORD + '/segmentIds', ['vl-passage', 'vl-passage'])])
    reject('empty-segment-id', [set_value(RECORD + '/segmentIds', [''])])
    reject('unknown-segment', [set_value(RECORD + '/segmentIds', ['vl-missing'])], True)
    reject('segment-in-two-records', [set_value('/voiceLab/wholeClipRevoices',
                                                [record('wholeclip-1'), record('wholeclip-2', ['vl-thanks'])])], True)
    reject('repeated-record-id', [set_value('/voiceLab/wholeClipRevoices',
                                            [record('wholeclip-1', ['vl-passage']), record('wholeclip-1', ['vl-thanks'])])], True)
    reject('empty-script', [set_value(RECORD + '/script', '')])
    reject('script-too-long', [set_value(RECORD + '/script', 'a' * 20001)])
    reject('empty-consent', [set_value(RECORD + '/consentRecordId', '')])
    reject('retime-too-slow', [set_value(RECORD + '/videoRetime', 0.91)])
    reject('retime-too-fast', [set_value(RECORD + '/videoRetime', 1.09)])
    reject('string-retime', [set_value(RECORD + '/videoRetime', '1')])
    reject('another-lipsync-model', [set_value(RECORD + '/lipsyncModel', 'fal-ai/latentsync')])
    reject('lipsync-2-pro', [set_value(RECORD + '/lipsyncModel', 'fal-ai/sync-lipsync/v2:lipsync-2-pro')])
    reject('negative-price', [set_value(RECORD + '/usd', -1)])
    reject('string-price', [set_value(RECORD + '/usd', '1.58')])
    reject('take-above-one', [set_value(RECORD + '/match/take', 1.5)])
    reject('null-take', [set_value(RECORD + '/match/take', None)])
    reject('baseline-below-minus-one', [set_value(RECORD + '/match/anchorBaseline', -1.01)])
    reject('real-speech-above-one', [set_value(RECORD + '/match/realSpeech', 1.01)])
    reject('local-time', [set_value(RECORD + '/createdAt', '2026-11-07T09:00:00')], schema_valid=True)
    reject('empty-list', [set_value('/voiceLab/wholeClipRevoices', [])])
    reject('null-list', [set_value('/voiceLab/wholeClipRevoices', None)])
    reject('single-object', [set_value('/voiceLab/wholeClipRevoices', record())])
    reject('future-project', [set_value('/schemaVersion', 5)])
    invalid[-1]['tooNew'] = True
    cases = {'format': 'voxclip-whole-clip-revoice-wire/1', 'project': 'fixtures/voice-lab/whole-clip-revoice-project.voxclip',
             'clipId': 'clip-main', 'valid': valid, 'invalid': invalid}
    return {'whole-clip-revoice-project.voxclip': project, 'whole-clip-revoice-wire-cases.json': cases}


def main():
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
