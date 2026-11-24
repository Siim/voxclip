#!/usr/bin/env python3
"""Add the schema-v4 `clipEffects` root field to shared/schemas/project.schema.json (doc/spec/ai.md section 18.2).

Schema-version decision: effects stay in schemaVersion 4, as `music` does. Version 4 is unreleased (0.1.0 is Unreleased)
and already carries the optional root features (contextDemo, motionCues, music); `clipEffects` is omitted when empty, so
a project without effects saves byte-identically and older v4 readers that do not know the field never see it. Versions
1-3 must not carry it; adding a first effect promotes a project to 4.

Each effect writes `id clipId kind start end` plus exactly the keys its kind uses (ClipEffect.kindKeys in Swift and C#).
It also registers the named motion template in the shared clip-plan schema. Run from anywhere; both updates are idempotent.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'shared/schemas/project.schema.json'
PLAN_PATH = PATH.with_name('clip-plan-effect.schema.json')
HARNESS_PATH = PATH.with_name('harness-timeline.schema.json')

IDENTIFIER = '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
KINDS = ['bleep', 'mute', 'blur', 'pixelate', 'title', 'lowerThird', 'sticker', 'arrow', 'circle', 'progress', 'freeze', 'sound',
         'colourLook', 'speedForPart', 'illustration', 'motionTemplate']
KIND_KEYS = {
    'bleep': ['wordIds'], 'mute': ['wordIds'],
    'blur': ['rect', 'tracking', 'track'], 'pixelate': ['rect', 'tracking', 'track'],
    'title': ['text', 'position'], 'lowerThird': ['text', 'position'], 'sticker': ['text', 'position', 'scale'],
    'arrow': ['rect'], 'circle': ['rect'], 'progress': ['position'], 'freeze': [], 'sound': ['sound', 'gainDb'],
    'colourLook': ['look'], 'speedForPart': ['rate'], 'illustration': ['imageFile'], 'motionTemplate': ['template']}
COMMON = ['id', 'clipId', 'kind', 'start', 'end']
POSITIONS = ['top', 'center', 'bottom', 'topLeft', 'topRight', 'bottomLeft', 'bottomRight']


def obj(fields, required=None, description=None):
    result = {'type': 'object', 'additionalProperties': False, 'required': list(required if required is not None else fields),
              'properties': fields}
    if description:
        result = {'description': description, **result}
    return result


def unit(description=None):
    value = {'type': 'number', 'minimum': 0, 'maximum': 1}
    return {**value, 'description': description} if description else value


def definitions():
    text = lambda maximum: {'type': 'string', 'minLength': 1, 'maxLength': maximum}
    rect = obj({'x': unit(), 'y': unit(), 'width': {'type': 'number', 'minimum': 0.01, 'maximum': 1},
                'height': {'type': 'number', 'minimum': 0.01, 'maximum': 1}},
               description='A normalized rect of the recorded frame as it plays (rotation applied), top-left origin. '
                           'Runtime also checks that x + width and y + height stay inside 1.')
    sample = obj({'t': {'type': 'number', 'minimum': 0}, **rect['properties']},
                 description='One tracked rect at source time t; samples are every 0.25 s, smoothed, in increasing t.')
    bundled = obj({'source': {'const': 'bundled'}, 'id': {'enum': ['whoosh', 'pop', 'ding']},
                   'durationSeconds': {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 10}, 'title': text(200),
                   'license': {'const': 'cc0'}},
                  description='A sound synthesized for VoxClip and bundled under shared/sfx (CC0).')
    library = obj({'source': {'const': 'library'},
                   'file': {'type': 'string', 'pattern': '^[0-9a-f-]{36}/sfx-[a-z0-9][a-z0-9_-]{0,57}\\.(mp3|m4a|wav|aif|aiff|flac|ogg)$',
                            'description': "<projectId>/sfx-<slug>.<ext> under the data folder's SFX root; the folder is the project id."},
                   'sha256': {'type': 'string', 'pattern': '^[0-9a-f]{64}$'},
                   'durationSeconds': {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 10}, 'title': text(200),
                   'creator': {'oneOf': [{'type': 'null'}, text(200)]},
                   'license': {'enum': ['cc0', 'by', 'pdm']},
                   'attribution': {'oneOf': [{'type': 'null'}, text(1000)]},
                   'sourceUrl': {'type': 'string', 'maxLength': 2048, 'pattern': '^https://[^\\s]+$'}},
                  description='A free library clip (Openverse category sound_effect), cc0, by or pdm only, never nc, nd or sa.')
    library['allOf'] = [{'if': {'properties': {'license': {'const': 'by'}}}, 'then': {'properties': {'attribution': {'type': 'string'}}}}]
    properties = {
        'id': {'type': 'string', 'pattern': IDENTIFIER},
        'clipId': {'oneOf': [{'type': 'null'}, {'type': 'string', 'pattern': IDENTIFIER}],
                   'description': 'The clip the effect belongs to; null for the full video. Censor kinds (bleep, mute, blur, '
                                  'pixelate) render wherever their range plays; the others only in their clip.'},
        'kind': {'enum': KINDS},
        'start': {'type': 'number', 'minimum': 0, 'description': 'Source seconds.'},
        'end': {'type': 'number', 'exclusiveMinimum': 0, 'description': 'Source seconds, after start, at most 600 s later.'},
        'wordIds': {'type': 'array', 'minItems': 1, 'maxItems': 200, 'uniqueItems': True, 'items': {'type': 'string', 'pattern': IDENTIFIER},
                    'description': 'The bleeped or muted words; captions show each of their letters and digits as a full block.'},
        'rect': {'$ref': '#/$defs/clipEffectRect'},
        'tracking': {'enum': ['none', 'face', 'saliency']},
        'track': {'type': 'array', 'maxItems': 2401, 'items': {'$ref': '#/$defs/clipEffectTrackSample'},
                  'description': 'Empty while untracked, so rect holds.'},
        'text': text(80),
        'template': {'$ref': '#/$defs/motionTemplate'},
        'position': {'enum': POSITIONS},
        'scale': {'type': 'number', 'minimum': 0.5, 'maximum': 3},
        'sound': {'oneOf': [{'$ref': '#/$defs/clipEffectBundledSound'}, {'$ref': '#/$defs/clipEffectLibrarySound'}]},
        'gainDb': {'type': 'number', 'minimum': -30, 'maximum': 6, 'description': 'Relative to the voice.'},
        'animation': {'enum': ['rise', 'pop'], 'description': 'Optional entrance on title, lowerThird or sticker.'},
        'look': {'enum': ['original', 'muted', 'warm', 'bw']},
        'rate': {'type': 'number', 'minimum': 0.5, 'maximum': 2},
        'imageFile': {'type': 'string', 'pattern': '^[0-9a-f-]{36}/illustration-[0-9a-f]{64}\\.png$'}}
    entry = {'description': 'One effect on a stretch of the recording; doc/spec/ai.md section 18.2. Every entry writes '
                            'id, clipId, kind, start and end, plus exactly the keys its kind uses. Runtime also checks the '
                            'clip and words exist, a freeze is at most 5 s, a sound spans its own length, a sticker is at '
                            'most 16 scalars and a progress bar sits at the top or bottom.',
             'type': 'object', 'additionalProperties': False, 'required': COMMON, 'properties': properties}
    entry['allOf'] = [
        {'if': {'properties': {'kind': {'const': kind}}},
         'then': {'required': COMMON + KIND_KEYS[kind],
                  'propertyNames': {'enum': COMMON + KIND_KEYS[kind] + (['animation'] if kind in ('title', 'lowerThird', 'sticker') else [])},
                  **({'properties': {'animation': {'const': 'pop' if kind == 'sticker' else 'rise'}}}
                     if kind in ('title', 'lowerThird', 'sticker') else {}),
                  **({'properties': {'clipId': {'type': 'string'}}}
                     if kind in ('colourLook', 'speedForPart', 'illustration') else {})}}
        for kind in KINDS]
    template = json.loads(PATH.with_name('motion-template.schema.json').read_text())
    del template['$id'], template['$schema']
    return {'clipEffectRect': rect, 'clipEffectTrackSample': sample, 'clipEffectBundledSound': bundled,
            'clipEffectLibrarySound': library, 'clipEffect': entry, 'motionTemplate': template}


def update_plan_schema():
    schema = json.loads(PLAN_PATH.read_text())
    fields = schema['properties']
    kinds = fields['kind']['enum']
    if 'motionTemplate' not in kinds:
        kinds.insert(kinds.index('emojiPop') + 1, 'motionTemplate')
    fields['template'] = {'$ref': 'motion-template.schema.json'}
    rule = {'if': {'properties': {'kind': {'const': 'motionTemplate'}}},
            'then': {'required': ['template'], 'maxProperties': 5}}
    if rule not in schema['allOf']:
        schema['allOf'].append(rule)
    PLAN_PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


def update_harness_schema():
    schema = json.loads(HARNESS_PATH.read_text())
    schema['properties']['effects']['items'] = {'$ref': PLAN_PATH.name}
    schema['properties']['effects']['description'] = ('Use any clip-plan entry. Footage references a sourceKey from read_clips. '
                                                       'Asset requests are reviewed in VoxClip; this tool never sends or spends.')
    HARNESS_PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


def main():
    schema = json.loads(PATH.read_text())
    media = schema['properties']['media']['properties']
    media['additionalSources'] = {'type': 'array', 'minItems': 1, 'items': {'$ref': '#/$defs/mediaReference'}}
    media['footage'] = {'type': 'array', 'minItems': 1, 'items': {'$ref': '#/$defs/clipFootage'}}
    schema['$defs']['mediaReference']['properties']['recordingHash'] = {'type': 'string', 'pattern': '^[0-9a-f]{64}$'}
    schema['$defs']['clipFootage'] = {
        'type': 'object', 'additionalProperties': False,
        'required': ['id', 'clipID', 'kind', 'start', 'end', 'footage'],
        'properties': {'id': {'type': 'string'}, 'clipID': {'type': 'string'},
                       'kind': {'enum': ['bRoll', 'screenshot', 'videoStack']},
                       'start': {'type': 'number', 'minimum': 0}, 'end': {'type': 'number', 'minimum': 0},
                       'footage': {'type': 'object', 'additionalProperties': False, 'required': ['sourceKey', 'start'],
                                   'properties': {'sourceKey': {'type': 'string', 'pattern': '^[0-9a-f]{64}$'},
                                                  'start': {'type': 'number', 'minimum': 0}}}}}
    for name, value in definitions().items():
        schema['$defs'][name] = value
    schema['properties']['clipEffects'] = {
        'type': 'array', 'minItems': 1, 'maxItems': 500, 'items': {'$ref': '#/$defs/clipEffect'},
        'description': 'Schema-v4 effects (Ask Claude toolbox, doc/spec/ai.md section 18); omit when empty. Versions 1-3 never carry it.'}
    for rule in schema['allOf']:
        excluded = rule.get('then', {}).get('not', {}).get('anyOf')
        if excluded is not None and {'required': ['contextDemo']} in excluded:
            for key in ('additionalSources', 'footage'):
                exclusion = {'properties': {'media': {'required': [key]}}}
                if exclusion not in excluded:
                    excluded.append(exclusion)
            exclusion = {'properties': {'media': {'properties': {'source': {'required': ['recordingHash']}}}}}
            if exclusion not in excluded:
                excluded.append(exclusion)
            if {'required': ['clipEffects']} not in excluded:
                excluded.append({'required': ['clipEffects']})
            break
    else:
        raise SystemExit('project.schema.json has no v1-3 exclusion rule for v4 root fields')
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')
    update_plan_schema()
    update_harness_schema()


if __name__ == '__main__':
    main()
