#!/usr/bin/env python3
"""Generate edits.cutEdges, cut edges seated in the quiet (doc/spec/editing.md section 5.10), on the v8 frame.

Runs the v8 frame generator first, so this one script rebuilds the whole chain: spoken sources (v7), the v8 frame and
the agent thread, then cut edges. Core checks the rest: a key names word index 1 or later in the same recording as the
word before it, with a gap under 0.2 s, and its value lies within 0.15 s + one sample of the word edge."""
import json

from generate_agent_thread_schema import PATH, populate as populate_frame


def populate(schema):
    populate_frame(schema)
    schema['$defs']['edits']['properties']['cutEdges'] = {
        'description': 'Cut edges seated in the quiet, schema v8 only and omitted when empty: the later word at a kept/cut '
                       'boundary (its clock id, so later recordings carry their wordIdPrefix) to the edge in that '
                       "recording's local seconds, sample-rounded at the project clock rate. Word times never change.",
        'type': 'object',
        'propertyNames': {'$ref': '#/$defs/wordId'},
        'additionalProperties': {'$ref': '#/$defs/seconds'},
    }
    rule = {
        'if': {'properties': {'schemaVersion': {'maximum': 7}}},
        'then': {'properties': {'edits': {'not': {'required': ['cutEdges']}}}},
    }
    for index, existing in enumerate(schema['allOf']):
        if existing.get('if') == rule['if']:
            schema['allOf'][index] = rule
            break
    else:
        schema['allOf'].append(rule)


if __name__ == '__main__':
    schema = json.loads(PATH.read_text())
    populate(schema)
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')
