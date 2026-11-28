#!/usr/bin/env python3
"""Generate the on-use v8 project gate and agent thread wire (ADR-R55)."""
import json

from generate_spoken_sources_schema import PATH, populate as populate_spoken_sources


def obj(required, optional=None):
    return {'type': 'object', 'additionalProperties': False, 'required': list(required),
            'properties': {**required, **(optional or {})}}


def ref(name):
    return {'$ref': '#/$defs/' + name}


def arr(items, **limits):
    return {'type': 'array', 'items': items, **limits}


def choice(*values):
    return {'enum': list(values)}


def nullable(value):
    return {'anyOf': [value, {'type': 'null'}]}


def populate(schema):
    versions = sorted(set(schema['properties']['schemaVersion']['enum']) | {8})
    schema['properties']['schemaVersion']['enum'] = versions
    populate_spoken_sources(schema)
    for rule in schema['allOf']:
        voice = rule.get('then', {}).get('properties', {}).get('voiceLab', {})
        if voice.get('$ref') == '#/$defs/voiceLabV3':
            supported = rule['if']['properties']['schemaVersion']['enum']
            rule['if']['properties']['schemaVersion']['enum'] = sorted(set(supported) | {8})

    text = {'type': 'string'}
    boolean = {'type': 'boolean'}
    identifier = {'type': 'string', 'minLength': 1}
    integer = {'type': 'integer', 'minimum': 0, 'maximum': 2147483647}
    positive = {**integer, 'minimum': 1}
    patch = arr(ref('agentPatch'))
    roots = 'edits|captions|clipStyle|clipControls|clipEffects|music|motionCues|captionTranslations|voiceLab|export'
    token = r'(?:[^/~\[\]]|~[0-3])+'
    selector = rf'(?:\[id={token}\])?'
    path = {'type': 'string', 'pattern': rf'^/(?:{roots}){selector}(?:/{token}{selector})*$'}
    defs = schema['$defs']
    defs['agentThread'] = obj({'id': identifier, 'mode': choice('propose', 'claude', 'askFirst'),
                               'turns': arr(ref('agentTurn'), maxItems=200)})
    defs['agentTurn'] = obj({
        'id': identifier, 'kind': choice('agent', 'run', 'outside'), 'createdAt': ref('timestamp'),
        'request': obj({'text': text, 'context': arr(ref('agentContext'))}),
        'connector': text, 'model': text, 'summary': {**text, 'maxLength': 600},
        'steps': arr(obj({'tool': text, 'ok': boolean, 'digest': text, 'ms': integer}), maxItems=24),
        'state': choice('running', 'pending', 'kept', 'undone', 'partial', 'stopped', 'failed'),
        'changes': arr(ref('agentChange')), 'offers': arr(ref('agentOffer')), 'events': arr(ref('agentEvent')),
    }, {'revisionOf': nullable(text), 'check': nullable(obj({'ok': boolean, 'lines': arr(text)})), 'wasKept': nullable(boolean)})
    defs['agentContext'] = obj({'kind': choice('clip', 'part', 'recording', 'words', 'line', 'panel')}, {
        'clipId': nullable(text), 'part': nullable(positive), 'sourceKey': nullable(text), 'startWordId': nullable(text),
        'endWordId': nullable(text), 'line': nullable(positive), 'panel': nullable(text),
    })
    defs['agentChange'] = obj({'id': identifier, 'label': text, 'undoName': text, 'state': choice('applied', 'undone'), 'patch': patch})
    defs['agentPatch'] = obj({'path': path, 'before': {}, 'after': {}}, {
        'beforeMissing': nullable({'const': True}), 'afterMissing': nullable({'const': True}),
        'beforeIndex': nullable(integer), 'afterIndex': nullable(integer), 'previousId': nullable(text), 'nextId': nullable(text),
    })
    defs['agentOffer'] = obj({'id': identifier, 'kind': choice('generateMusic', 'revoice', 'illustration', 'lipSync', 'makeItPostable'),
                              'label': text, 'quoteUSD': {**text, 'pattern': r'^[0-9]+\.[0-9]{2}$'},
                              'state': choice('offered', 'bought', 'declined', 'failed')}, {
        'assetId': nullable(text), 'target': nullable(text), 'brief': nullable(text),
        'words': nullable({'type': 'array', 'maxItems': 500, 'items': text}),
    })
    defs['agentEvent'] = obj({'kind': choice('hand', 'keep', 'undo', 'redo', 'bought'), 'undoName': text,
                              'target': text, 'at': ref('timestamp')}, {'patch': nullable(patch)})
    schema['properties']['agentThread'] = {**ref('agentThread'), 'description': 'Present only in schema v8. Core validates patch semantics, distinct ids, and the 2 MiB thread cap.'}

    legacy_parts = {'items': {'not': {'required': ['takeReason']}}}
    without_spoken = {'properties': {'edits': {'properties': {'clips': {'items': {'properties': {'parts': legacy_parts}}}}}}}
    rule = {
        'if': {'properties': {'schemaVersion': {'const': 8}}},
        'then': {'required': ['agentThread'], 'if': {'properties': {'media': {'required': ['spokenSources']}}},
                 'then': {'properties': {'media': {'required': ['additionalSources']}, 'transcript': ref('transcript')}},
                 'else': without_spoken},
        'else': {'not': {'required': ['agentThread']}},
    }
    schema['allOf'] = [existing for existing in schema['allOf'] if existing.get('if') != rule['if']] + [rule]


if __name__ == '__main__':
    schema = json.loads(PATH.read_text())
    populate(schema)
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')
