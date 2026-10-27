"""Generate inert v3 render-contract fixtures from source-preserving v2 projects."""
import copy
import json
import math
from pathlib import Path

root = Path(__file__).resolve().parents[3]
fixtures = root / 'shared/fixtures/voice-lab'

def js_half_up(value):
    if value < 0 or not math.isfinite(value):
        raise ValueError("sample-grid fixture requires a finite nonnegative value")
    return math.floor(value + .5)

def asset(project, name, seconds, sha):
    return {'id': name, 'kind': 'audio', 'file': f"{project['id']}/{name}.wav", 'sha256': sha,
            'durationSeconds': seconds, 'sampleRate': 24000, 'createdAt': '2026-10-25T12:10:00Z'}

def recipe(project, segment, selected_asset, trim_start, trim_end, seed, request, chunks, room, seams, qa):
    audio = {'assetId': selected_asset['id'], 'trimStart': trim_start, 'trimEnd': trim_end,
             'stretch': segment['outDuration'] / (trim_end-trim_start), 'gainDb': -1 if seed == 8 else 0}
    provenance = copy.deepcopy(segment['provenance'])
    provenance['requestId'] = request
    provenance['seed'] = seed
    provenance['region'] = 'us'
    provenance['endpoint'] = 'v1/text-to-speech/fixture/with-timestamps'
    rate = project['media']['source']['audio']['sampleRate']
    return {'audio': audio, 'words': copy.deepcopy(segment['words']), 'outDuration': segment['outDuration'], 'seed': seed, 'chunks': chunks,
            'roomTone': room, 'seams': seams,
            'video': {'mode': 'source', 'sourceStartSample': js_half_up(segment['replace']['start']*rate),
                      'sourceEndSample': js_half_up(segment['replace']['end']*rate), 'outputSamples': js_half_up(segment['outDuration']*rate),
                      **{key: None for key in ['retimeFactor', 'zoom', 'faceX', 'faceY', 'assetId', 'provider', 'model', 'requestId', 'windowStartSample', 'windowEndSample', 'syncMode']}},
            'qa': qa, 'provenance': provenance, 'cost': {'quoteId': f'quote-{seed}', 'usd': None},
            'voiceSource': 'own', 'voiceRefId': 'voice-fixture', 'consentVerifiedAt': '2026-10-25T12:09:00Z'}

def chunk(start, end, assembled_start, assembled_end, request, seed, selected_asset):
    return {'sourceStartSample': start, 'sourceEndSample': end, 'requestId': request, 'seed': seed,
            'assetId': selected_asset['id'], 'assetSha256': selected_asset['sha256'],
            'assembledStartFrame': assembled_start, 'assembledEndFrame': assembled_end}

qa = {'transcriptTokens': 2, 'transcriptExact': True, 'transcriptMatch': 1,
      'lufsJumpLu': .2, 'peakDbfs': -1, 'speakerScore': .9, 'speakerThreshold': .8,
      'speakerModel': 'calibrated-fixture', 'speakerPassed': True}
none = {'kind': 'none', 'fadeSamples': 0, 'sourceHandleSamples': 0, 'assetHandleFrames': 0}
gap = {'kind': 'gap', 'fadeSamples': 20, 'sourceHandleSamples': 10, 'assetHandleFrames': 240}
for flavor in ['passage', 'full-take']:
    project = json.loads((fixtures / f'{flavor}-project.voxclip').read_text())
    project['schemaVersion'] = 3
    voice = {'id': 'voice-fixture', 'provider': 'elevenlabs', 'voiceId': 'fixture-voice',
             'consentRecordId': 'consent-fixture', 'displayName': 'Fixture voice', 'status': 'deleted'}
    project['voiceLab']['cleanAudio'] = {'mode': 'off', 'assetId': None, 'mix': None}
    project['voiceLab']['voices'] = [voice]
    project['voiceLab']['videoAssets'] = []
    segment = project['voiceLab']['segments'][0]
    segment['scope'] = 'passage' if flavor == 'passage' else 'fullTake'
    if flavor == 'full-take': segment['groupId'] = 'group-take'
    if flavor == 'passage':
        segment['outDuration'] = .7
        segment['words'] = [{'text': 'new', 'start': .1, 'end': .3, 'synthetic': True},
                            {'text': 'words', 'start': .3, 'end': .6, 'synthetic': True}]
        room = {'sourceStartSample': 4500, 'sourceEndSample': 5000, 'gainDb': 0}
        seams = {'in': gap, 'out': gap}
        start, end = 2500, 3200
        first, second = project['voiceLab']['assets']
        first['durationSeconds'] = .9
        second['durationSeconds'] = 1
        intervals = [(first, .1, .8), (second, .2, .9)]
    else:
        segment['outDuration'] = 7
        segment['words'] = [{'text': 'whole', 'start': 0, 'end': 3.4, 'synthetic': True},
                            {'text': 'take', 'start': 3.5, 'end': 7, 'synthetic': True}]
        room = None
        seams = {'in': none, 'out': none}
        start, end = 0, 7000
        first, second = project['voiceLab']['assets']
        first['durationSeconds'] = 7.2
        second['durationSeconds'] = 7.3
        intervals = [(first, .1, 7.1), (second, .2, 7.2)]
    for index, (candidate, trim_start, trim_end) in enumerate(intervals):
        seed = 7 + index
        request = f'request-{seed}'
        assembled_start = js_half_up(trim_start*24000)
        assembled_end = js_half_up(trim_end*24000)
        if flavor == 'passage':
            chunks = [chunk(start, end, assembled_start, assembled_end, request, seed, candidate)]
        else:
            midpoint = (assembled_start+assembled_end)//2
            chunks = [chunk(0, 3500, assembled_start, midpoint, request+'a', seed, candidate),
                      chunk(3500, 7000, midpoint, assembled_end, request+'b', seed, candidate)]
        segment['candidates'][index]['recipe'] = recipe(project, segment, candidate, trim_start, trim_end,
                                                         seed, request, chunks, room, seams, qa)
        if flavor == 'passage' and index == 1:
            segment['candidates'][index]['recipe']['words'][0]['start'] = .12
            segment['candidates'][index]['recipe']['words'][0]['end'] = .32
            segment['candidates'][index]['recipe']['words'][1]['start'] = .32
            segment['candidates'][index]['recipe']['words'][1]['end'] = .62
    chosen = segment['candidates'][0]['recipe']
    segment['audio'] = chosen['audio']
    segment['qa'] = {'transcriptMatch': chosen['qa']['transcriptMatch'], 'lufsJumpLu': chosen['qa']['lufsJumpLu'],
                     'peakDbfs': chosen['qa']['peakDbfs'], 'speakerScore': chosen['qa']['speakerScore']}
    segment['provenance'] = chosen['provenance']
    (fixtures / f'{flavor}-render-v3.voxclip').write_text(json.dumps(project, indent=2, ensure_ascii=False) + '\n')

# Exact disclosure thresholds use source-equal video, keeping capability separate.
base = json.loads((fixtures / 'passage-render-v3.voxclip').read_text())
for suffix, duration in [('at-30', 2.1), ('above-30', 2.101)]:
    project = copy.deepcopy(base)
    segment = project['voiceLab']['segments'][0]
    segment['replace']['end'] = 2.5 + duration
    segment['replace']['lastWordId'] = 'w8'
    segment['outDuration'] = duration
    for index, candidate in enumerate(segment['candidates']):
        asset = project['voiceLab']['assets'][index]
        recipe = candidate['recipe']
        trim_start = .1 if index == 0 else .2
        trim_end = trim_start + duration
        asset['durationSeconds'] = trim_end + .1
        recipe['outDuration'] = duration
        recipe['audio']['trimStart'] = trim_start
        recipe['audio']['trimEnd'] = trim_end
        recipe['audio']['stretch'] = 1
        recipe['chunks'][0]['sourceEndSample'] = js_half_up((2.5+duration)*1000)
        recipe['chunks'][0]['assembledStartFrame'] = js_half_up(trim_start*24000)
        recipe['chunks'][0]['assembledEndFrame'] = js_half_up(trim_end*24000)
        recipe['video']['sourceEndSample'] = js_half_up((2.5+duration)*1000)
        recipe['video']['outputSamples'] = js_half_up(duration*1000)
    selected = segment['candidates'][0]['recipe']
    segment['audio'] = selected['audio']
    (fixtures / f'disclosure-{suffix}-render-v3.voxclip').write_text(json.dumps(project, indent=2, ensure_ascii=False) + '\n')

project = copy.deepcopy(base)
segment = project['voiceLab']['segments'][0]
segment['kind'] = 'voiceChanger'
segment['replace'] = {'start': 0, 'end': 3.5, 'firstWordId': 'w1', 'lastWordId': 'w6'}
segment['outDuration'] = 3.5
segment['text'] = None
segment['words'] = None
segment['qa'] = {'transcriptMatch': None, 'lufsJumpLu': .2, 'peakDbfs': -1, 'speakerScore': None}
for index, candidate in enumerate(segment['candidates']):
    asset = project['voiceLab']['assets'][index]
    recipe = candidate['recipe']
    trim_start = 0 if index == 0 else .1
    trim_end = trim_start + 3.5
    asset['durationSeconds'] = trim_end + .1
    recipe['outDuration'] = 3.5
    recipe['words'] = None
    recipe['audio']['trimStart'] = trim_start
    recipe['audio']['trimEnd'] = trim_end
    recipe['audio']['stretch'] = 1
    recipe['chunks'][0]['sourceStartSample'] = 0
    recipe['chunks'][0]['sourceEndSample'] = 3500
    recipe['chunks'][0]['assembledStartFrame'] = js_half_up(trim_start*24000)
    recipe['chunks'][0]['assembledEndFrame'] = js_half_up(trim_end*24000)
    recipe['roomTone'] = None
    recipe['seams']['in'] = none
    recipe['video']['sourceStartSample'] = 0
    recipe['video']['sourceEndSample'] = 3500
    recipe['video']['outputSamples'] = 3500
    recipe['qa'] = {'transcriptTokens': None, 'transcriptExact': None, 'transcriptMatch': None,
                    'lufsJumpLu': .2, 'peakDbfs': -1, 'speakerScore': None, 'speakerThreshold': None,
                    'speakerModel': None, 'speakerPassed': None}
    recipe['voiceSource'] = 'stock'
    recipe['voiceRefId'] = None
    recipe['consentVerifiedAt'] = None
    recipe['provenance']['voiceId'] = 'stock-voice'
    recipe['provenance']['consentRecordId'] = None
    recipe['provenance']['endpoint'] = 'v1/speech-to-speech/fixture'
segment['audio'] = segment['candidates'][0]['recipe']['audio']
segment['provenance'] = segment['candidates'][0]['recipe']['provenance']
(fixtures / 'voice-changer-half-render-v3.voxclip').write_text(json.dumps(project, indent=2, ensure_ascii=False) + '\n')

# Two adjacent selected passages exercise one shared synth seam. A one-sample
# source gap is a separate vector: neither neighboring fade may consume it.
for flavor in ('touching', 'one-sample-gap'):
    pair = copy.deepcopy(base)
    first = pair['voiceLab']['segments'][0]
    second = copy.deepcopy(first)
    second['id'] = 'vl-follow'
    second['replace'] = {'start': 3.2, 'end': 3.5, 'firstWordId': 'w6', 'lastWordId': 'w6'}
    second['outDuration'] = .3
    second['text'] = {'original': 'uh', 'new': 'next'}
    second['words'] = [{'text': 'next', 'start': .05, 'end': .25, 'synthetic': True}]
    for index, candidate in enumerate(second['candidates']):
        selected = candidate['recipe']
        selected['outDuration'] = .3
        selected['audio']['trimEnd'] = selected['audio']['trimStart'] + .3
        selected['audio']['stretch'] = 1
        selected['words'] = copy.deepcopy(second['words'])
        selected['chunks'][0]['sourceStartSample'] = 3200
        selected['chunks'][0]['sourceEndSample'] = 3500
        selected['chunks'][0]['assembledEndFrame'] = js_half_up(selected['audio']['trimEnd']*24000)
        selected['video']['sourceStartSample'] = 3200
        selected['video']['sourceEndSample'] = 3500
        selected['video']['outputSamples'] = 300
        selected['seams']['in'] = copy.deepcopy(gap)
    second['audio'] = copy.deepcopy(second['candidates'][0]['recipe']['audio'])
    second['words'] = copy.deepcopy(second['candidates'][0]['recipe']['words'])
    if flavor == 'touching':
        for candidate in first['candidates']:
            candidate['recipe']['seams']['out'] = {'kind': 'synthToSynth', 'fadeSamples': 20,
                'sourceHandleSamples': 0, 'assetHandleFrames': 480}
        for candidate in second['candidates']:
            candidate['recipe']['seams']['in'] = {'kind': 'synthToSynth', 'fadeSamples': 20,
                'sourceHandleSamples': 0, 'assetHandleFrames': 480}
    else:
        first['replace']['end'] = 3.199
        first['outDuration'] = .699
        for candidate in first['candidates']:
            selected = candidate['recipe']
            selected['outDuration'] = .699
            selected['audio']['trimEnd'] = selected['audio']['trimStart'] + .699
            selected['audio']['stretch'] = 1
            selected['chunks'][0]['sourceEndSample'] = 3199
            selected['chunks'][0]['assembledEndFrame'] = js_half_up(selected['audio']['trimEnd']*24000)
            selected['video']['sourceEndSample'] = 3199
            selected['video']['outputSamples'] = 699
        first['audio'] = copy.deepcopy(first['candidates'][0]['recipe']['audio'])
    pair['voiceLab']['segments'].append(second)
    (fixtures / f'{flavor}-render-v3.voxclip').write_text(json.dumps(pair, indent=2, ensure_ascii=False) + '\n')

clipped = copy.deepcopy(json.loads((fixtures / 'touching-render-v3.voxclip').read_text()))
# Make the preceding source word end exactly at the internal seam so the clip's
# half-gap lead starts on that seam rather than bisecting the first passage.
next(word for word in clipped['transcript']['words'] if word['id'] == 'w5')['end'] = 3.2
clipped['edits']['clips'] = [{'id': 'clip-edge', 'startWordId': 'w6', 'endWordId': 'w8',
    'title': 'Seam edge', 'origin': 'manual', 'aiResultId': None, 'aiClipIndex': None, 'selected': True}]
clipped['edits']['activeClipId'] = 'clip-edge'
(fixtures / 'clipped-seam-render-v3.voxclip').write_text(json.dumps(clipped, indent=2, ensure_ascii=False) + '\n')

cases = {
    'source-video-equal-passage': {'file': 'passage-render-v3.voxclip', 'outputSamples': 7000, 'aiSeconds': .7, 'persistent': False, 'labelIntervals': [[0, 3.7]]},
    'source-video-equal-full-take-two-chunks': {'file': 'full-take-render-v3.voxclip', 'outputSamples': 7000, 'aiSeconds': 7, 'persistent': True, 'labelIntervals': [[0, 7]]},
    'at-all-ai-threshold': {'file': 'disclosure-at-30-render-v3.voxclip', 'aiSeconds': 2.1, 'persistent': False},
    'above-all-ai-threshold': {'file': 'disclosure-above-30-render-v3.voxclip', 'aiSeconds': 2.101, 'persistent': True},
    'stock-conversion-at-half': {'file': 'voice-changer-half-render-v3.voxclip', 'aiSeconds': 3.5, 'persistent': True, 'kinds': ['voiceChanger']},
    'touching-synth-one-seam': {'file': 'touching-render-v3.voxclip', 'sharedFadeSamples': 20},
    'one-sample-source-gap': {'file': 'one-sample-gap-render-v3.voxclip', 'keptGapSamples': 1, 'preparationError': 'overlappingFades'},
    'clipped-internal-seam': {'file': 'clipped-seam-render-v3.voxclip', 'clipId': 'clip-edge', 'preparationError': 'invalidFadeHandles'},
    'sample-grid-half-up': {'seconds': .0005, 'rate': 1000, 'samples': js_half_up(.0005*1000)},
    'mapping-only-1100-for-1000': {'sourceSamples': 3000, 'replace': [1000, 2000], 'outputSamples': 3100, 'sourceVideoCapability': 'videoModeUnsupported'}
}
cases['unity-binary64-residual-eight'] = {'replace': [1.5, 2.503], 'sourceRate': 44100, 'assetRate': 24000,
    'residualFrames': 8, 'outputFrames': 24080, 'outDuration': 1.0033333333333334, 'baseline': 'binary64'}
cases['unity-binary64-residual-nine'] = {'replace': [1.5, 2.503], 'sourceRate': 44100, 'assetRate': 24000,
    'residualFrames': 9, 'outputFrames': 24081, 'outDuration': (2.503 - 1.5) + 9 / 24000, 'baseline': 'binary64'}
cases['unity-legacy-source-grid-only'] = {'replace': [1.5, 2.503], 'sourceRate': 44100, 'assetRate': 24000,
    'residualFrames': 0, 'outputFrames': 24072, 'outDuration': 44232 / 44100, 'baseline': 'sourceGridOnly'}
cases['unity-inconsistent-alternate'] = {'replace': [1.5000416666666667, 2.503], 'sourceRate': 8000, 'assetRate': 96000,
    'outputFrames': 96288, 'outDuration': 1.003, 'baseline': 'sourceGridOnly',
    'alternateOutputFrames': 96292, 'validationError': 'invalidSegment'}
(fixtures / 'render-cases.json').write_text(json.dumps(cases, indent=2) + '\n')
