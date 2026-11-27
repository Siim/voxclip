#!/usr/bin/env python3
"""Generate schema v7's spoken companions and version gates (ADR-R54)."""
import json
from pathlib import Path


PATH = Path(__file__).resolve().parents[2] / 'shared/schemas/project.schema.json'


def populate(schema):
    versions = sorted(set(schema['properties']['schemaVersion']['enum']) | {7})
    schema['properties']['schemaVersion']['enum'] = versions
    schema['title'] = 'VoxClip project file (.voxclip), schemaVersion ' + ', '.join(map(str, versions[:-1])) + f' or {versions[-1]}'
    for rule in schema['allOf']:
        voice = rule.get('then', {}).get('properties', {}).get('voiceLab', {})
        if voice.get('$ref') == '#/$defs/voiceLabV3':
            supported = rule['if']['properties']['schemaVersion']['enum']
            rule['if']['properties']['schemaVersion']['enum'] = sorted(set(supported) | {7})
    schema['$defs']['spokenSource'] = {
        'type': 'object', 'additionalProperties': False,
        'required': ['sourceKey', 'offsetSeconds', 'wordIdPrefix', 'transcript'],
        'properties': {
            'sourceKey': {'type': 'string', 'pattern': '^[a-f0-9]{64}$'},
            'label': {'type': 'string', 'maxLength': 24},
            'offsetSeconds': {'type': 'integer', 'minimum': 1, 'maximum': 2147483647},
            'wordIdPrefix': {'type': 'string', 'pattern': r'^r(?:[2-9]|[1-9][0-9]{1,9})\.$'},
            'gainDb': {'type': 'number', 'minimum': -12, 'maximum': 12},
            'transcript': {'$ref': '#/$defs/transcript'},
        },
    }
    schema['properties']['media']['properties']['spokenSources'] = {
        'type': 'array', 'minItems': 1, 'maxItems': 5, 'uniqueItems': True, 'items': {'$ref': '#/$defs/spokenSource'},
        'description': 'In clock order. Companion membership, guard gaps and distinct prefixes are checked by Core.',
    }
    legacy_parts = {'items': {'not': {'required': ['takeReason']}}}
    rule = {
        'if': {'properties': {'schemaVersion': {'const': 7}}},
        'then': {'properties': {'media': {'required': ['additionalSources', 'spokenSources']},
                                'transcript': {'$ref': '#/$defs/transcript'}}},
        'else': {'properties': {'media': {'not': {'required': ['spokenSources']}}, 'edits': {'properties': {
            'clips': {'items': {'properties': {'parts': legacy_parts}}},
        }}}},
    }
    if 8 in versions:
        rule['else'] = {'if': {'properties': {'schemaVersion': {'maximum': 6}}}, 'then': rule['else']}
    for index, existing in enumerate(schema['allOf']):
        if existing.get('if') == rule['if']:
            schema['allOf'][index] = rule
            break
    else:
        schema['allOf'].append(rule)


def main():
    schema = json.loads(PATH.read_text())
    populate(schema)
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
