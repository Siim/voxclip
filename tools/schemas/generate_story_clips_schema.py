#!/usr/bin/env python3
"""Add the v5 story-clip extension and generate a portable example project."""
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / 'shared/schemas/project.schema.json'


def no_fields(*names):
    return {'not': {'anyOf': [{'required': [name]} for name in names]}}


def part_array(definition):
    return {'type': 'array', 'minItems': 2, 'maxItems': 12, 'items': {'$ref': f'#/$defs/{definition}'}}


def main():
    schema = json.loads(SCHEMA.read_text())
    versions = sorted(set(schema['properties']['schemaVersion']['enum']) | {5, 6})
    schema['title'] = 'VoxClip project file (.voxclip), schemaVersion ' + ', '.join(map(str, versions[:-1])) + f' or {versions[-1]}'
    schema['properties']['schemaVersion']['enum'] = versions
    for rule in schema['allOf']:
        versions = rule['if']['properties']['schemaVersion'].get('enum')
        if versions in ([3, 4], [3, 4, 5]):
            versions[:] = [3, 4, 5, 6]

    defs = schema['$defs']
    words = {key: {'$ref': '#/$defs/wordId'} for key in ('startWordId', 'endWordId')}
    defs['clipWordRange'] = {'type': 'object', 'additionalProperties': False, 'required': list(words), 'properties': words}
    defs['clipPart'] = {'type': 'object', 'additionalProperties': False, 'required': ['id', *words], 'properties': {
        'id': {'$ref': '#/$defs/id'}, **words, 'reframe': {'$ref': '#/$defs/clipControls/properties/reframe'},
        'takeReason': {'type': 'string', 'maxLength': 160},
    }}
    clip = defs['clipRange']
    clip['description'] = 'A clip in the range layer. For a story the inclusive outer word range is the source hull of its parts.'
    clip['properties'].update(parts=part_array('clipPart'), kind={'enum': ['story', 'showreel']})
    clip['dependentRequired'] = {'kind': ['parts']}
    defs['aiClip']['properties'].update(parts=part_array('clipWordRange'), notInTake={'type': 'string', 'maxLength': 200})
    story_clips = {'contains': {'required': ['parts']}}
    legacy_clips = {'items': no_fields('parts', 'kind')}
    legacy_ai_results = {'items': {'properties': {'clips': {'items': no_fields('parts', 'notInTake')}}}}
    rule = {
        'if': {'properties': {'schemaVersion': {'const': 5}}},
        'then': {'properties': {'edits': {'properties': {'clips': story_clips}}}},
        'else': {'if': {'properties': {'schemaVersion': {'maximum': 4}}}, 'then': {'properties': {
            'edits': {'properties': {'clips': legacy_clips}},
            'ai': {'properties': {'results': legacy_ai_results}},
        }}},
    }
    for index, existing in enumerate(schema['allOf']):
        if existing['if']['properties']['schemaVersion'].get('const') == 5:
            schema['allOf'][index] = rule
            break
    else:
        schema['allOf'].append(rule)
    SCHEMA.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')

    example = json.loads((ROOT / 'shared/fixtures/clip-controls/clip-controls-project.voxclip').read_text())
    example['schemaVersion'] = 5
    example.pop('clipControls', None)
    example['edits']['clips'] = [{
        'id': 'clip-main', 'startWordId': 'w1', 'endWordId': 'w7', 'title': 'Two moments', 'origin': 'manual',
        'aiResultId': None, 'aiClipIndex': None, 'selected': True, 'kind': 'story', 'parts': [
            {'id': 'first', 'startWordId': 'w6', 'endWordId': 'w7', 'reframe': {'mode': 'face', 'zoom': 1, 'centerX': 0.3, 'centerY': 0.5}},
            {'id': 'second', 'startWordId': 'w1', 'endWordId': 'w2'},
        ],
    }]
    output = ROOT / 'shared/fixtures/story-clips/story-project.voxclip'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(example, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
