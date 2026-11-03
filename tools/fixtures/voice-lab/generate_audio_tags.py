import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
catalog = json.loads((root / 'shared/data/voice-audio-tags.json').read_text())
tags = [{'beforeToken': 1, 'tag': 'laughs'}, {'beforeToken': 2, 'tag': 'short pause'}]
requests = [{'modelID': model, 'words': 'Hello there', 'audioTags': tags,
             'expected': 'Hello [laughs] there [short pause]' if model in catalog['models'] else 'Hello there',
             'allowance': 1.05 if model in catalog['models'] else 0}
            for model in ['eleven_v3', 'eleven_v4', 'eleven_multilingual_v2', 'unknown']]
alignment = []
for text in ['Hello [laughs] there', 'Hello there']:
    alignment.append({'characters': list(text), 'starts': [index / 100 for index in range(len(text))],
                      'ends': [(index + 1) / 100 for index in range(len(text))],
                      'expectedText': 'Hello there', 'expectedWords': ['Hello', 'there'],
                      'expectedStarts': [0, text.index('there') / 100]})
normalized = [{'typed': 'I have 21 apples', 'normalized': 'I have twenty one apples',
               'expectedWords': ['I', 'have', '21', 'apples']},
              {'typed': 'We paid $12 today', 'normalized': 'We paid twelve dollars today',
               'expectedWords': ['We', 'paid', '$12', 'today']}]
fallbacks = []
for row in normalized:
    characters = list(row['normalized'])
    fallbacks.append({'modelID': 'eleven_v4', 'typed': row['typed'], 'alignment': None,
                      'normalized_alignment': {'characters': characters,
                          'character_start_times_seconds': [index / 2000 for index in range(len(characters))],
                          'character_end_times_seconds': [(index + 1) / 2000 for index in range(len(characters))]},
                      'segmentEnd': len(characters), 'expectedWords': row['expectedWords']})
roundtrips = [{'original': 'Old words', 'new': 'Hello there'},
              {'original': 'Old words', 'new': 'Hello there', 'audioTags': tags}]
doc = {'schema': 'voxclip-voice-audio-tags/1', 'requests': requests,
       'drop': {'words': 'Hello there', 'audioTags': [{'beforeToken': -1, 'tag': 'laughs'},
                  {'beforeToken': 0, 'tag': 'shouts'}, {'beforeToken': 9, 'tag': 'sighs'},
                  {'beforeToken': 1, 'tag': 'laughs'}], 'expected': [{'beforeToken': 1, 'tag': 'laughs'}]},
       'qaEvents': catalog['scribeEvents'], 'alignments': alignment, 'normalized': normalized,
       'dialogueFallbacks': fallbacks,
       'roundTrips': roundtrips, 'durations': catalog['tags']}
doc['caseCount'] = len(requests) + 1 + len(catalog['scribeEvents']) + len(alignment) + len(normalized) + len(fallbacks) + len(roundtrips) + len(catalog['tags'])
edge_extents = []
for model in catalog['models']:
    for side in ['leading', 'trailing']:
        for has_characters in [True, False]:
            for seam in ['hard', 'gap']:
                leading = side == 'leading'
                annotation = {'beforeToken': 0 if leading else 2, 'tag': 'sighs' if leading else 'laughs'}
                characters = [{'character': 'Hello', 'start': .3, 'end': .5},
                              {'character': ' ', 'start': .5, 'end': .6},
                              {'character': 'there', 'start': .6, 'end': .8}]
                if has_characters:
                    tag = {'character': '[' + annotation['tag'] + ']',
                           'start': .1 if leading else 1, 'end': .2 if leading else 1.2}
                    characters = [tag] + characters if leading else characters + [tag]
                edge_extents.append({'id': f'{model}-{side}-{"characters" if has_characters else "acoustic"}-{seam}',
                    'modelID': model, 'seam': seam, 'sampleRate': 1000, 'sampleCount': 2000,
                    'sampleRuns': [[300, 800], [100, 200] if leading else [1000, 1200]] +
                                  ([[0, 50] if leading else [1400, 1500]] if has_characters else []),
                    'words': [{'text': 'Hello', 'start': .3, 'end': .5, 'synthetic': True},
                              {'text': 'there', 'start': .6, 'end': .8, 'synthetic': True}],
                    'audioTags': [annotation], 'tokenCount': 2, 'characters': characters,
                    'expectedStart': .1 if leading else .3, 'expectedEnd': .8 if leading else 1.2})
for model, boundary, tag, name in [('eleven_v3', 1, 'short pause', 'mid-phrase-normal-trim'),
                                   ('eleven_multilingual_v2', 2, 'laughs', 'unsupported-normal-trim'),
                                   ('unknown', 0, 'sighs', 'unknown-normal-trim')]:
    row = dict(edge_extents[0])
    row.update(id=name, modelID=model, audioTags=[{'beforeToken': boundary, 'tag': tag}],
               expectedStart=.3, expectedEnd=.8, expectedTrimStart=.27, expectedTrimEnd=.86)
    edge_extents.append(row)
for side in ['leading', 'trailing']:
    row = dict(next(item for item in edge_extents if item['id'] == f'eleven_v3-{side}-acoustic-hard'))
    row.update(id=f'{side}-clamped-to-asset')
    if side == 'leading':
        row.update(sampleRuns=[[0, 200], [300, 800]], expectedStart=0)
    else:
        row.update(sampleCount=1100, sampleRuns=[[300, 800], [1000, 1100]], expectedEnd=1.1)
    edge_extents.append(row)
event_filters = [
    {'id': 'punctuated-haha', 'expected': 'Hello there', 'recognized': ['Hello', 'Haha.', 'there'], 'tagged': True, 'filtered': ['hello', 'there']},
    {'id': 'typed-ha', 'expected': 'Ha, got you', 'recognized': ['ha', 'got', 'you'], 'tagged': True, 'filtered': ['ha', 'got', 'you']},
    {'id': 'typed-ha-before-extra', 'expected': 'Ha, got you', 'recognized': ['ha', 'got', 'you', 'ha'], 'tagged': True, 'filtered': ['ha', 'got', 'you']},
    {'id': 'typed-ha-after-extra', 'expected': 'got you ha', 'recognized': ['ha', 'got', 'you', 'ha'], 'tagged': True, 'filtered': ['got', 'you', 'ha']},
    {'id': 'repeated-expected-ha', 'expected': 'Ha ha', 'recognized': ['ha', 'Ha,', 'HA!'], 'tagged': True, 'filtered': ['ha', 'ha']},
    {'id': 'untagged-no-filter', 'expected': 'Hello there', 'recognized': ['Hello', 'haha', 'there'], 'tagged': False, 'filtered': ['hello', 'haha', 'there']},
    {'id': 'untagged-typed-ha', 'expected': 'Ha, got you', 'recognized': ['ha', 'got', 'you'], 'tagged': False, 'filtered': ['ha', 'got', 'you']},
    {'id': 'extra-bracket-events', 'expected': 'Hello there', 'recognized': ['(laughs)', 'Hello', '[sighs]', 'there'], 'tagged': True, 'filtered': ['hello', 'there']},
    {'id': 'missing-word-stays-hard', 'expected': 'Ha ha there', 'recognized': ['ha', 'there'], 'tagged': True, 'filtered': ['ha', 'there']},
    {'id': 'extra-real-word-stays-hard', 'expected': 'Hello there', 'recognized': ['Hello', 'wrong', 'there'], 'tagged': True, 'filtered': ['hello', 'wrong', 'there']}
]
doc['edgeExtents'] = edge_extents
doc['eventFilters'] = event_filters
doc['caseCount'] += len(edge_extents) + len(event_filters)
(root / 'shared/fixtures/voice-lab/audio-tag-cases.json').write_text(json.dumps(doc, ensure_ascii=False, indent=2) + '\n')

schema_path = root / 'shared/schemas/project.schema.json'
schema = json.loads(schema_path.read_text())
annotation = {'type': 'object', 'additionalProperties': False, 'required': ['beforeToken', 'tag'],
              'properties': {'beforeToken': {'type': 'integer', 'minimum': 0},
                             'tag': {'type': 'string', 'enum': [item['tag'] for item in catalog['tags']]}}}
schema['$defs']['voiceLabAudioTag'] = annotation
schema_path.write_text(json.dumps(schema, ensure_ascii=False, indent=2) + '\n')
