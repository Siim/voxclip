import copy
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
accepted = {'seams': [{'side': 'left', 'excessLu': 4}], 'acceptedAt': '2026-10-25T12:10:00Z'}
cases = []


def add(name, qa, valid, schema_valid=True):
    cases.append({'name': name, 'qa': qa, 'valid': valid, 'schemaValid': schema_valid})


def advisory(name, valid=False, schema_valid=True, **changes):
    value = copy.deepcopy(accepted)
    value.update(changes)
    add(name, {'lufsJumpLu': 4, 'joinAdvisory': value}, valid, schema_valid)


add('legacy-clean', {}, True)
advisory('accepted-left', True)
advisory('accepted-right', True, seams=[{'side': 'right', 'excessLu': 4}])
advisory('accepted-both', True, seams=[{'side': 'left', 'excessLu': 3}, {'side': 'right', 'excessLu': 4}])
add('unaccepted-join', {'lufsJumpLu': 4}, False)
for name, patch in [('clipping-stays-hard', {'peakDbfs': 0}),
                    ('words-stay-hard', {'transcriptExact': False}),
                    ('voice-stays-hard', {'speakerScore': 0.1, 'speakerPassed': False})]:
    add(name, {'lufsJumpLu': 4, 'joinAdvisory': copy.deepcopy(accepted), **patch}, False)
advisory('empty-seams', schema_valid=False, seams=[])
advisory('invalid-side', schema_valid=False, seams=[{'side': 'middle', 'excessLu': 4}])
advisory('not-an-advisory', schema_valid=False, seams=[{'side': 'left', 'excessLu': 2}])
advisory('duplicate-side', seams=[{'side': 'left', 'excessLu': 4}, {'side': 'left', 'excessLu': 3}])
advisory('inconsistent-measurement', seams=[{'side': 'left', 'excessLu': 3}])
advisory('acceptance-after-recipe', acceptedAt='2026-10-25T12:10:01Z')
advisory('invalid-timestamp', schema_valid=False, acceptedAt='not-a-date')
advisory('missing-timestamp', schema_valid=False)
del cases[-1]['qa']['joinAdvisory']['acceptedAt']
document = {'schema': 'voxclip-voice-lab-join-advisory-cases/1', 'baseProject': 'passage-render-v3.voxclip',
            'caseCount': len(cases), 'cases': cases}
(root / 'shared/fixtures/voice-lab/join-advisory-cases.json').write_text(json.dumps(document, indent=2) + '\n')
