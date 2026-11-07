#!/usr/bin/env python3
"""Add the schema-v4 `clipControls` root field to shared/schemas/project.schema.json (doc/design.md section 6.9).

Schema-version decision: clip controls stay in schemaVersion 4, as `music` does. Version 4 is unreleased (0.1.0 is
Unreleased), already carries the optional root features (contextDemo, motionCues, music), and `clipControls` is omitted when
empty and never stores an entry at its defaults, so a project without clip controls saves byte-identically. Versions 1-3
must not carry it; storing a clip's first control promotes the project to 4. Windows opens, validates and saves the field
unchanged and refuses to export a clip that uses it.

Idempotent: running it twice leaves the same bytes. Run from anywhere; it rewrites the schema in place.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'shared/schemas/project.schema.json'

IDENTIFIER = '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'


def clip_controls_definition():
    fields = {
        'clipId': {'type': 'string', 'pattern': IDENTIFIER, 'description': 'The clip these controls apply to; at most one entry per clip.'},
        'speed': {'type': 'number', 'minimum': 0.5, 'maximum': 2,
                  'description': 'Playback rate; 1 plays as recorded. The voice keeps its pitch; captions, cuts and motion follow.'},
        'shape': {'oneOf': [{'type': 'null'}, {'enum': ['16:9', '9:16', '1:1', '4:5']}],
                  'description': 'The clip\'s own frame; null keeps the project export frame (export.aspect).'},
        'look': {'enum': ['original', 'muted', 'warm', 'bw'], 'description': 'The colour look, the same ids the clip planner writes.'},
        'gainDb': {'type': 'number', 'minimum': -24, 'maximum': 12, 'description': 'Source audio level in dB; 0 leaves it unchanged.'},
        'fadeInSeconds': {'type': 'number', 'minimum': 0, 'maximum': 5},
        'fadeOutSeconds': {'type': 'number', 'minimum': 0, 'maximum': 5},
        'muteSource': {'type': 'boolean', 'description': 'Silences the clip\'s own audio; a music bed still plays.'},
        'flipHorizontal': {'type': 'boolean'},
        'rotationDegrees': {'enum': [0, 90, 180, 270], 'description': 'Clockwise quarter turns.'}}
    required = list(fields)
    # Optional, omitted when absent (ADR-R48, "Claude sees the picture" part 2).
    fields['reframe'] = {
        'type': 'object', 'additionalProperties': False, 'required': ['mode', 'zoom', 'centerX', 'centerY'],
        'description': '"9:16 follows your face": the 9:16 and 1:1 crops centre on the measured face (picture space as filmed, '
                       'top-left origin); 16:9 ignores it. Omitted for the centre crop.',
        'properties': {'mode': {'const': 'face'}, 'zoom': {'const': 1},
                       'centerX': {'type': 'number', 'minimum': 0, 'maximum': 1},
                       'centerY': {'type': 'number', 'minimum': 0, 'maximum': 1}}}
    fields['coverSeconds'] = {'type': 'number', 'minimum': 0,
                              'description': '"Cover frame chosen": the source second of the clip\'s cover, written beside each '
                                             'export as <name>-cover.jpg and embedded as its cover art. Omitted when there is none.'}
    return {
        'description': 'One clip\'s playback controls; doc/design.md section 6.9. Every required key is written; reframe and '
                       'coverSeconds are omitted when absent. Runtime also checks that '
                       'the clip exists, that a clip has one entry and that no entry is stored at its defaults.',
        'type': 'object', 'additionalProperties': False, 'required': required, 'properties': fields}


def main():
    schema = json.loads(PATH.read_text())
    schema['$defs']['clipControls'] = clip_controls_definition()
    schema['properties']['clipControls'] = {
        'type': 'array', 'minItems': 1, 'maxItems': 64, 'items': {'$ref': '#/$defs/clipControls'},
        'description': 'Schema-v4 per-clip speed, frame, look, volume, fades, mute, flip and rotation; omit when empty. '
                       'Versions 1-3 never carry it.'}
    for rule in schema['allOf']:
        excluded = rule.get('then', {}).get('not', {}).get('anyOf')
        if excluded is not None and {'required': ['contextDemo']} in excluded:
            if {'required': ['clipControls']} not in excluded:
                excluded.append({'required': ['clipControls']})
            break
    else:
        raise SystemExit('project.schema.json has no v1-3 exclusion rule for v4 root fields')
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
