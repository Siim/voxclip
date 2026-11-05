#!/usr/bin/env python3
"""Add each clip's caption look to `clipStyle.captionPicks` in shared/schemas/project.schema.json (doc/design.md 6.6).

A pick may carry `overrides` (the caption overrides that clip renders with: Make it postable's case, words per line and
font, a JSON merge patch over the style like `captions.overrides`) and `by: "user"` (the creator chose this clip's style;
Claude's picks omit it). Every clip then exports in its own caption look.

Schema-version decision: both keys are optional and allowed in every schema version; no bump. `clipStyle` is valid in
versions 1-4, 0.1.0 is unreleased (no released reader refuses the keys), and a pick without them saves byte-identically.
Windows Core reads, validates and saves them unchanged.

Idempotent: running it twice leaves the same bytes. Run from anywhere; it rewrites the schema in place.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'shared/schemas/project.schema.json'


def picks_definition():
    return {
        'description': 'Each clip\'s caption look by clip id: Claude\'s pick (Pick styles, Make it postable), used while '
                       'captions are auto or when it keeps the fixed style, or the creator\'s own choice for that clip '
                       '(by "user"), always used. A clip without a pick renders with the project\'s captions. Picks for '
                       'clips that no longer exist are ignored and dropped the next time picks are recorded.',
        'type': 'object',
        'additionalProperties': {
            'type': 'object',
            'additionalProperties': False,
            'required': ['styleId', 'reason'],
            'properties': {
                'styleId': {'type': 'string', 'pattern': '^[a-z0-9]+(?:-[a-z0-9]+)*$'},
                'reason': {'type': 'string', 'maxLength': 120},
                'overrides': {
                    'type': 'object',
                    'description': 'The caption overrides this clip renders with, as captions.overrides (a JSON merge '
                                   'patch over the style). Omitted: the project\'s overrides while the style is the '
                                   'project\'s, else none.'},
                'by': {'const': 'user', 'description': 'The creator chose this clip\'s style. Omitted for Claude\'s picks.'},
            },
        },
    }


def main():
    schema = json.loads(PATH.read_text())
    clip_style = schema['$defs']['clipStyle']
    clip_style['properties']['captionPicks'] = picks_definition()
    clip_style['description'] = (
        'How clips should be made (doc/design.md section 6.6): the chosen preset and its fields. Absent until the user '
        'chooses on the clip style card. \'auto\' in captions or music leaves that choice to the AI per clip; a caption '
        'style id here is the user\'s fixed choice and Claude never overrides it. The creator\'s own choice for one clip '
        '(captionPicks by "user") wins for that clip.')
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
