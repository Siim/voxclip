#!/usr/bin/env python3
"""Add a clip's opening lead-in, `edits.clips[].leadInSeconds`, to shared/schemas/project.schema.json (ADR-R48, doc/design.md
section 6.7.1, "Opens on a clear look at you").

Schema-version decision: the lead-in stays in schemaVersion 4, as the other "Claude sees the picture" fields do (clip controls'
`reframe` and `coverSeconds`, written by generate_clip_controls_schema.py). It is optional and omitted when absent, so a
project without one saves byte-identically; versions 1-3 must not carry it, and storing one promotes the project to 4.

Run after generate_clip_controls_schema.py. Idempotent: running it twice leaves the same bytes. Run from anywhere.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'shared/schemas/project.schema.json'

LEAD_IN = {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 0.6,
           'description': 'Schema v4: the clip opens this many seconds before its first word, in the silence before it and never '
                          'across the item before it (ADR-R48). Omitted when the clip opens as the editor places it.'}
EXCLUSION = {'properties': {'edits': {'properties': {'clips': {'items': {'not': {'required': ['leadInSeconds']}}}}}}}


def main():
    schema = json.loads(PATH.read_text())
    schema['$defs']['clipRange']['properties']['leadInSeconds'] = LEAD_IN
    for rule in schema['allOf']:
        versions = rule.get('if', {}).get('properties', {}).get('schemaVersion', {}).get('enum')
        if versions == [1, 2, 3] and 'not' in rule.get('then', {}):
            rule['then'].setdefault('allOf', [])
            if EXCLUSION not in rule['then']['allOf']:
                rule['then']['allOf'].append(EXCLUSION)
            break
    else:
        raise SystemExit('project.schema.json has no v1-3 exclusion rule for v4 fields')
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
