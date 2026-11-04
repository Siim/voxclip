#!/usr/bin/env python3
"""Add the schema-v4 `music` root field to shared/schemas/project.schema.json (doc/spec/music.md section 2).

Schema-version decision: music stays in schemaVersion 4. Version 4 is unreleased (0.1.0 is Unreleased), already the
version that carries optional root features (contextDemo, motionCues), and `music` is omitted when empty, so a project
without music saves byte-identically. Versions 1-3 must not carry it; adding a first track promotes a project to 4.

Idempotent: running it twice leaves the same bytes. Run from anywhere; it rewrites the schema in place.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'shared/schemas/project.schema.json'

IDENTIFIER = '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'


def nullable(value):
    return {'oneOf': [{'type': 'null'}, value]}


def obj(fields, description=None):
    result = {'type': 'object', 'additionalProperties': False, 'required': list(fields), 'properties': fields}
    if description:
        result = {'description': description, **result}
    return result


def music_definitions():
    text = lambda maximum: {'type': 'string', 'minLength': 1, 'maxLength': maximum}
    asset = obj({
        'file': {'type': 'string', 'pattern': '^[0-9a-f-]{36}/music-[a-z0-9][a-z0-9_-]{0,57}\\.(mp3|m4a|wav|aif|aiff|flac)$',
                 'description': '<projectId>/music-<slug>.<ext> under the data folder\'s Music root; the folder is the project id.'},
        'sha256': {'type': 'string', 'pattern': '^[0-9a-f]{64}$'},
        'durationSeconds': {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 1800}})
    entry = obj({
        'id': {'type': 'string', 'pattern': IDENTIFIER},
        'clipId': {'oneOf': [{'type': 'null'}, {'type': 'string', 'pattern': IDENTIFIER}],
                   'description': 'The clip this track plays under; null plays under the full-video export. At most one track per value.'},
        'asset': {'$ref': '#/$defs/musicAsset'},
        'source': {'enum': ['library', 'generated', 'file']},
        'title': text(200),
        'creator': nullable(text(200)),
        'license': {'enum': ['cc0', 'by', 'pdm', 'generated', 'own'],
                    'description': 'Library tracks are cc0, by or pdm only (never nc, nd or sa); generated tracks are generated; own files are own.'},
        'attribution': nullable(text(1000)),
        'sourceUrl': nullable({'type': 'string', 'maxLength': 2048, 'pattern': '^https://[^\\s]+$'}),
        'prompt': nullable(text(2000)),
        'gainDb': {'type': 'number', 'minimum': -40, 'maximum': 0,
                   'description': 'The bed level relative to the clip\'s measured speech loudness; -20 by default.'},
        'ducking': {'type': 'boolean'},
        'fadeInSeconds': {'type': 'number', 'minimum': 0, 'maximum': 10},
        'fadeOutSeconds': {'type': 'number', 'minimum': 0, 'maximum': 10},
        'startOffsetSeconds': {'type': 'number', 'minimum': 0}},
        'One background track; doc/spec/music.md section 2. Every key is written, null where a source has no value. '
        'Runtime also checks that the file folder is the project id, the clip exists and the offset is inside the track.')
    entry['allOf'] = [
        {'if': {'properties': {'source': {'const': 'library'}}},
         'then': {'properties': {'license': {'enum': ['cc0', 'by', 'pdm']}, 'sourceUrl': {'type': 'string'}, 'prompt': {'type': 'null'}}}},
        {'if': {'properties': {'source': {'const': 'generated'}}},
         'then': {'properties': {'license': {'const': 'generated'}, 'prompt': {'type': 'string'}}}},
        {'if': {'properties': {'source': {'const': 'file'}}},
         'then': {'properties': {'license': {'const': 'own'}, 'prompt': {'type': 'null'}}}},
        {'if': {'properties': {'license': {'const': 'by'}}}, 'then': {'properties': {'attribution': {'type': 'string'}}}}]
    return asset, entry


def main():
    schema = json.loads(PATH.read_text())
    asset, entry = music_definitions()
    schema['$defs']['musicAsset'] = asset
    schema['$defs']['music'] = entry
    schema['properties']['music'] = {
        'type': 'array', 'minItems': 1, 'maxItems': 65, 'items': {'$ref': '#/$defs/music'},
        'description': 'Schema-v4 background tracks under clips; omit when empty. Versions 1-3 never carry it.'}
    for rule in schema['allOf']:
        excluded = rule.get('then', {}).get('not', {}).get('anyOf')
        if excluded is not None and {'required': ['contextDemo']} in excluded:
            if {'required': ['music']} not in excluded:
                excluded.append({'required': ['music']})
            break
    else:
        raise SystemExit('project.schema.json has no v1-3 exclusion rule for v4 root fields')
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
