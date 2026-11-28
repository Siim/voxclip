#!/usr/bin/env python3
"""Add the schema-v4 `clipControls` root field to shared/schemas/project.schema.json (doc/design.md section 6.9).

Schema-version decision: clip controls stay in schemaVersion 4, as `music` does. Version 4 is unreleased (0.1.0 is
Unreleased), already carries the optional root features (contextDemo, motionCues, music), and `clipControls` is omitted when
empty and never stores an entry at its defaults, so a project without clip controls saves byte-identically. Versions 1-3
must not carry it; storing a clip's first control promotes the project to 4. Color presets keep the existing look IDs;
non-neutral adjustments are stored separately.

The optional `colorGrade` (looks spec 2026-11-28, section 8.1) holds the Fix, the newer look controls, Amount and a
preset's toning as whole points. It needs schema v8: its first write promotes a project to 8 through the Cores' one
`requiredVersion`, and versions 1-7 never carry it. Runtime alone checks that curve values never decrease.

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
    fields['coverTitle'] = {'type': 'string', 'minLength': 1, 'maxLength': 80,
                            'description': 'Optional text on the exported cover image, never on the clip video.'}
    color_controls = ['brightness', 'contrast', 'saturation', 'warmth']
    fields['colorAdjustments'] = {
        'type': 'object', 'additionalProperties': False, 'required': color_controls,
        'description': 'Signed color adjustments applied after the base look. Omit when all values are zero.',
        'properties': {name: {'type': 'integer', 'minimum': -100, 'maximum': 100} for name in color_controls},
        'not': {'properties': {name: {'const': 0} for name in color_controls}}}
    fields['colorGrade'] = {'$ref': '#/$defs/clipColorGrade'}
    return {
        'description': 'One clip\'s playback controls; doc/design.md section 6.9. Every required key is written; reframe and '
                       'coverSeconds, coverTitle, colorAdjustments and colorGrade are omitted when absent. Runtime also checks '
                       'that the clip exists, that a clip has one entry and that no entry is stored at its defaults.',
        'type': 'object', 'additionalProperties': False, 'required': required, 'properties': fields,
        'dependentRequired': {'coverTitle': ['coverSeconds']}}


GRADE_SLIDERS = ['exposure', 'temperature', 'tint', 'highlights', 'shadows', 'vibrance', 'fade', 'vignette', 'grain']
GRADE_ADDING = {'fade', 'vignette', 'grain'}
CURVE_CHANNELS = ['master', 'red', 'green', 'blue']
SPLIT_TONE = {'shadowHue': (0, 359), 'shadowSaturation': (0, 100), 'highlightHue': (0, 359), 'highlightSaturation': (0, 100),
              'balance': (-100, 100)}
# The rule that keeps colorGrade out of versions 1-7. Its `if` names clipControls, so it never collides with the cut edges
# rule's plain `schemaVersion <= 7` test (generate_cut_edges_schema.py replaces its rule by that `if`).
COLOR_GRADE_GATE = {'properties': {'schemaVersion': {'maximum': 7}}, 'required': ['clipControls']}


def integer(low, high):
    return {'type': 'integer', 'minimum': low, 'maximum': high}


def clip_color_grade_definition():
    knots = {'type': 'array', 'minItems': 5, 'maxItems': 5, 'items': integer(0, 1000),
             'description': 'Y in thousandths at x = 0, 1/4, 1/2, 3/4 and 1; runtime checks it never decreases.'}
    properties = {
        'preset': {'type': 'string', 'pattern': '^[A-Za-z0-9]{1,40}$',
                   'description': 'The look in shared/looks/clip-looks.json these values came from; display only, never rendered. '
                                  'An ID a build does not know shows "Custom".'},
        'amount': {**integer(0, 99), 'description': 'The look\'s strength in percent, mixed over the Fix; omitted at 100.'},
        **{name: integer(0, 100) if name in GRADE_ADDING else integer(-100, 100) for name in GRADE_SLIDERS},
        'curve': {'type': 'object', 'additionalProperties': False, 'minProperties': 1,
                  'properties': {name: knots for name in CURVE_CHANNELS},
                  'description': 'A preset\'s tone curves: master on every channel, then the channel curves. Data only.'},
        'splitTone': {'type': 'object', 'additionalProperties': False, 'required': list(SPLIT_TONE),
                      'properties': {name: integer(*bounds) for name, bounds in SPLIT_TONE.items()},
                      'description': 'A preset\'s split toning. Data only.'}}
    return {
        'description': 'Schema v8 only: a clip\'s Fix (exposure, temperature, tint), the newer look controls, Amount and a '
                       'preset\'s toning, in whole points; looks spec section 8.1. Every slider key is written; preset, curve '
                       'and splitTone are omitted when absent and amount at 100. Never neutral: a preset alone stores nothing.',
        'type': 'object', 'additionalProperties': False, 'required': GRADE_SLIDERS, 'properties': properties,
        'not': {'properties': {name: {'const': 0} for name in GRADE_SLIDERS},
                'not': {'anyOf': [{'required': ['amount']}, {'required': ['curve']}, {'required': ['splitTone']}]}}}


def main():
    schema = json.loads(PATH.read_text())
    schema['$defs']['clipControls'] = clip_controls_definition()
    schema['$defs']['clipColorGrade'] = clip_color_grade_definition()
    gate = {'if': COLOR_GRADE_GATE,
            'then': {'properties': {'clipControls': {'items': {'not': {'required': ['colorGrade']}}}}}}
    for index, rule in enumerate(schema['allOf']):
        if rule.get('if') == COLOR_GRADE_GATE:
            schema['allOf'][index] = gate
            break
    else:
        schema['allOf'].append(gate)
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
