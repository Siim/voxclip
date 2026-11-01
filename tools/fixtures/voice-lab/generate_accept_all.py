#!/usr/bin/env python3
"""C4 atomic acceptance vectors. Synthetic project values only; standard library, no I/O to providers."""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / 'shared/fixtures/voice-lab'


def load(name):
    return json.loads((FIXTURES / f'{name}-render-v3.voxclip').read_text())


def inputs(project):
    project = copy.deepcopy(project)
    segments = project['voiceLab']['segments']
    assets = project['voiceLab']['assets']
    voice = project['voiceLab']['voices'][0]
    voice['status'] = 'active'
    project['voiceLab']['segments'] = []
    project['voiceLab']['assets'] = []
    project['voiceLab']['voices'] = []
    return dict(project=project, segments=segments, assets=assets, voice=voice)


def stock_changer(segment):
    segment['kind'] = 'voiceChanger'
    segment['text'] = segment['words'] = None
    for candidate in segment['candidates']:
        recipe = candidate['recipe']
        recipe['words'] = recipe['roomTone'] = None
        recipe['voiceSource'] = 'stock'
        recipe['voiceRefId'] = recipe['consentVerifiedAt'] = None
        recipe['provenance']['voiceId'] = 'stock-voice'
        recipe['provenance']['consentRecordId'] = None
        recipe['provenance']['endpoint'] = 'v1/speech-to-speech/fixture'
    segment['provenance'] = copy.deepcopy(segment['candidates'][0]['recipe']['provenance'])


sets = {'touching': inputs(load('touching')), 'single': inputs(load('passage'))}
sets['mixed'] = copy.deepcopy(sets['touching'])
stock_changer(sets['mixed']['segments'][1])
sets['disjoint'] = copy.deepcopy(sets['single'])
second = copy.deepcopy(sets['disjoint']['segments'][0])
second['id'] = 'vl-later'
second['replace'] = dict(start=5.4, end=6.1, firstWordId='w9', lastWordId='w9')
for candidate in second['candidates']:
    recipe = candidate['recipe']
    recipe['video']['sourceStartSample'] = 5400
    recipe['video']['sourceEndSample'] = 6100
    recipe['chunks'][0]['sourceStartSample'] = 5400
    recipe['chunks'][0]['sourceEndSample'] = 6100
sets['disjoint']['segments'].append(second)
sets['reverse'] = copy.deepcopy(sets['disjoint'])
sets['reverse']['segments'].reverse()
sets['overlap'] = copy.deepcopy(sets['single'])
second = copy.deepcopy(sets['overlap']['segments'][0])
second['id'] = 'vl-overlap'
sets['overlap']['segments'].append(second)
sets['disabled-overlap'] = copy.deepcopy(sets['overlap'])
sets['disabled-overlap']['segments'][1]['enabled'] = False
sets['existing-overlap'] = copy.deepcopy(sets['single'])
existing = copy.deepcopy(sets['existing-overlap']['segments'][0])
existing['id'] = 'vl-existing'
sets['existing-overlap']['project']['voiceLab']['segments'] = [existing]
sets['existing-overlap']['project']['voiceLab']['assets'] = copy.deepcopy(sets['single']['assets'])
sets['existing-overlap']['project']['voiceLab']['voices'] = [copy.deepcopy(sets['single']['voice'])]
sets['bad-second-recipe'] = copy.deepcopy(sets['mixed'])
sets['bad-second-recipe']['segments'][1]['candidates'][0]['recipe']['qa']['peakDbfs'] = 0
sets['bad-alternate-scope-seam'] = copy.deepcopy(sets['touching'])
sets['bad-alternate-scope-seam']['segments'][1]['candidates'][1]['recipe']['seams']['in'].update(
    kind='gap', fadeSamples=20, sourceHandleSamples=10)
sets['duplicate-id'] = copy.deepcopy(sets['touching'])
sets['duplicate-id']['segments'][1]['id'] = sets['duplicate-id']['segments'][0]['id']
sets['reuse-assets'] = copy.deepcopy(sets['mixed'])
sets['reuse-assets']['project']['voiceLab']['assets'] = copy.deepcopy(sets['mixed']['assets'])
sets['asset-conflict'] = copy.deepcopy(sets['reuse-assets'])
sets['asset-conflict']['assets'][0]['sha256'] = 'f' * 64
sets['duplicate-asset'] = copy.deepcopy(sets['reuse-assets'])
sets['duplicate-asset']['assets'].append(copy.deepcopy(sets['duplicate-asset']['assets'][0]))
sets['voice-conflict'] = copy.deepcopy(sets['single'])
voice = copy.deepcopy(sets['single']['voice'])
voice['consentRecordId'] = 'different-consent'
sets['voice-conflict']['project']['voiceLab']['voices'] = [voice]
sets['deleted-voice'] = copy.deepcopy(sets['single'])
sets['deleted-voice']['voice']['status'] = 'deleted'
sets['deleted-voice']['project']['voiceLab']['voices'] = [copy.deepcopy(sets['deleted-voice']['voice'])]
sets['outside-clip'] = copy.deepcopy(sets['single'])
sets['outside-clip']['project']['edits']['clips'][0]['startWordId'] = 'w1'
sets['outside-clip']['project']['edits']['clips'][0]['endWordId'] = 'w3'
sets['crosses-clip'] = copy.deepcopy(sets['single'])
sets['crosses-clip']['project']['edits']['clips'][0]['startWordId'] = 'w5'
sets['cut-invalidates-seam'] = copy.deepcopy(sets['single'])
# Tightening the pause leaves just 5 ms of kept source before the 20 ms incoming fade.
sets['cut-invalidates-seam']['project']['edits']['pauseKeepSeconds'] = .105
sets['cut-invalidates-seam']['project']['edits']['cutPauseIds'] = ['pause-after-w3']
sets['group'] = inputs(load('full-take'))
original = sets['group']['segments'][0]
members = []
for index, (start, end, first, last) in enumerate([(0, 3.5, 'w1', 'w6'), (3.5, 7, 'w7', 'w9')]):
    segment = copy.deepcopy(original)
    segment['id'] = f'vl-group-{index}'
    segment['replace'] = dict(start=start, end=end, firstWordId=first, lastWordId=last)
    segment['outDuration'] = 3.5
    segment['words'] = [dict(text='part', start=.1, end=3.4, synthetic=True)]
    for candidate in segment['candidates']:
        recipe = candidate['recipe']
        recipe['words'] = copy.deepcopy(segment['words'])
        recipe['outDuration'] = 3.5
        recipe['audio']['trimEnd'] = recipe['audio']['trimStart'] + 3.5
        recipe['audio']['stretch'] = 1
        recipe['chunks'] = recipe['chunks'][:1]
        chunk = recipe['chunks'][0]
        chunk['sourceStartSample'] = round(start * 1000)
        chunk['sourceEndSample'] = round(end * 1000)
        chunk['assembledEndFrame'] = round(recipe['audio']['trimEnd'] * 24000)
        recipe['video'].update(sourceStartSample=round(start * 1000), sourceEndSample=round(end * 1000), outputSamples=3500)
        seam = dict(kind='synthToSynth', fadeSamples=20, sourceHandleSamples=0, assetHandleFrames=240)
        recipe['seams']['out' if index == 0 else 'in'] = seam
    segment['audio'] = copy.deepcopy(segment['candidates'][0]['recipe']['audio'])
    members.append(segment)
sets['group']['segments'] = members

rows = []

def case(name, set_name, error=None, scope='full'):
    row = dict(case=name, input=set_name, scope=scope)
    row['expected'] = dict(error=error) if error else dict(segmentIDs=[s['id'] for s in sets[set_name]['segments']])
    rows.append(row)

for name in ['single', 'disjoint', 'reverse', 'touching', 'mixed', 'reuse-assets', 'group']:
    case(name, name)
case('mixed-clip', 'mixed', scope='clip-main')
for name, error in [('overlap', 'overlappingReplacement'), ('disabled-overlap', 'overlappingReplacement'),
                    ('existing-overlap', 'overlappingReplacement'), ('bad-second-recipe', 'qaRejected'),
                    ('bad-alternate-scope-seam', 'invalidFadeHandles'), ('duplicate-id', 'invalidSegment'),
                    ('asset-conflict', 'invalidAsset'), ('duplicate-asset', 'invalidAsset'),
                    ('voice-conflict', 'consentUnverified'), ('deleted-voice', 'consentUnverified'),
                    ('cut-invalidates-seam', 'invalidFadeHandles')]:
    case(name, name, error)
case('outside-clip', 'outside-clip', 'invalidScope', 'clip-main')
case('crosses-clip', 'crosses-clip', 'invalidScope', 'clip-main')
case('unknown-clip', 'single', 'invalidScope', 'missing-clip')

out = dict(version=1, inputs=sets, cases=rows)
(FIXTURES / 'accept-all-cases.json').write_text(json.dumps(out, indent=2, ensure_ascii=False) + '\n')
print(f'accept-all-cases.json: {len(rows)} cases')

# Review vectors have a separate schema: the twin pins each existing file's exact cases and keys.
review = dict(schema='voxclip.accept-all-review.v1', cases=[
    dict(case='empty-set', input='single', segments=[], expected=dict(error='invalidSegment')),
])
(FIXTURES / 'accept-all-review-cases.json').write_text(json.dumps(review, indent=2) + '\n')
print(f'accept-all-review-cases.json: {len(review["cases"])} cases')
