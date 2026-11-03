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
(root / 'shared/fixtures/voice-lab/audio-tag-cases.json').write_text(json.dumps(doc, ensure_ascii=False, indent=2) + '\n')

schema_path = root / 'shared/schemas/project.schema.json'
schema = json.loads(schema_path.read_text())
annotation = {'type': 'object', 'additionalProperties': False, 'required': ['beforeToken', 'tag'],
              'properties': {'beforeToken': {'type': 'integer', 'minimum': 0},
                             'tag': {'type': 'string', 'enum': [item['tag'] for item in catalog['tags']]}}}
schema['$defs']['voiceLabAudioTag'] = annotation
schema_path.write_text(json.dumps(schema, ensure_ascii=False, indent=2) + '\n')
