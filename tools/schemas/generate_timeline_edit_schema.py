#!/usr/bin/env python3
"""Generate the shared gain point definition and v6-only project field rules (ADR-R53)."""
import json
from pathlib import Path


PATH = Path(__file__).resolve().parents[2] / 'shared/schemas/project.schema.json'
FADES = ('fadeInSeconds', 'fadeOutSeconds')
SOUND_SHAPE = ('mediaOffsetSeconds', 'gainPoints')
MUSIC_SHAPE = ('duckDb', 'segments')


def number(minimum, maximum=None):
    return {'type': 'number', 'minimum': minimum, **({'maximum': maximum} if maximum is not None else {})}


def fades(maximum):
    return {key: number(0, maximum) for key in FADES}


def gain_points():
    return {'type': 'array', 'maxItems': 64, 'items': {'$ref': '#/$defs/gainPoint'},
            'description': 'Relative dB points in strictly increasing item-local time; checked at runtime.'}


def main():
    schema = json.loads(PATH.read_text())
    schema['$defs']['gainPoint'] = {
        'type': 'object', 'additionalProperties': False, 'required': ['t', 'db'],
        'properties': {'t': number(0), 'db': number(-60, 12)},
    }

    def legacy_items(fields):
        return {'items': {'not': {'anyOf': [{'required': [key]} for key in fields]}}}

    rule = {'if': {'properties': {'schemaVersion': {'maximum': 5}}}, 'then': {'properties': {
        'clipEffects': legacy_items(FADES + SOUND_SHAPE), 'music': legacy_items(MUSIC_SHAPE),
        'media': {'properties': {'footage': legacy_items(FADES)}},
    }}}
    if rule not in schema['allOf']:
        schema['allOf'].append(rule)
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
