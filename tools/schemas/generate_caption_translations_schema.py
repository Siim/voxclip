#!/usr/bin/env python3
"""Add the schema-v4 `captionTranslations` root field to shared/schemas/project.schema.json (doc/spec/ai.md section 18.2).

Ask Claude's `translate` stores the captions of a run of words in another language. The translated text replaces those
words in the captions only (preview, export, SRT); the voice, the transcript and the edits stay.

Schema-version decision: like `clipControls`, the field stays in schemaVersion 4. Version 4 is unreleased (0.1.0 is
Unreleased) and the field is omitted when empty, so a project without translations saves byte-identically. Versions 1-3
must not carry it; storing the first translation promotes the project to 4. Windows opens, validates and saves the field
unchanged and refuses to render or export a project that has one, with a reason, until a Windows package renders it.

Idempotent: running it twice leaves the same bytes. Run from anywhere; it rewrites the schema in place.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'shared/schemas/project.schema.json'

IDENTIFIER = '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'


def caption_translation_definition():
    fields = {
        'id': {'type': 'string', 'pattern': '^tr-[1-9][0-9]{0,5}$'},
        'clipId': {'oneOf': [{'type': 'null'}, {'type': 'string', 'pattern': IDENTIFIER}],
                   'description': 'The clip it was made in, which alone shows it; null shows it in every render of those words.'},
        'startWordId': {'type': 'string', 'pattern': IDENTIFIER, 'description': 'The first transcript word it covers.'},
        'endWordId': {'type': 'string', 'pattern': IDENTIFIER, 'description': 'The last transcript word it covers.'},
        'language': {'type': 'string', 'pattern': '^[a-z]{2,3}(-[a-z0-9]{2,8})*$', 'description': 'A lower-case BCP 47 tag: "es", "pt-br".'},
        'text': {'type': 'string', 'minLength': 1, 'maxLength': 1000,
                 'description': 'The translation, trimmed. Its words are spread over the shown words of the range.'}}
    return {
        'description': 'The captions of a run of words in another language; doc/spec/ai.md section 18.2. Every key is written. '
                       'Runtime also checks that the words exist in order, that the clip exists, that the text is trimmed and at '
                       'most 1000 scalars, and that two translations in one scope never cover the same word.',
        'type': 'object', 'additionalProperties': False, 'required': list(fields), 'properties': fields}


def main():
    schema = json.loads(PATH.read_text())
    schema['$defs']['captionTranslation'] = caption_translation_definition()
    schema['properties']['captionTranslations'] = {
        'type': 'array', 'minItems': 1, 'maxItems': 200, 'items': {'$ref': '#/$defs/captionTranslation'},
        'description': 'Schema-v4 translated captions over runs of words; omit when empty. Versions 1-3 never carry it.'}
    for rule in schema['allOf']:
        excluded = rule.get('then', {}).get('not', {}).get('anyOf')
        if excluded is not None and {'required': ['contextDemo']} in excluded:
            if {'required': ['captionTranslations']} not in excluded:
                excluded.append({'required': ['captionTranslations']})
            break
    else:
        raise SystemExit('project.schema.json has no v1-3 exclusion rule for v4 root fields')
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
