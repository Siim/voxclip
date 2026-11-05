#!/usr/bin/env python3
"""Add the clip style's optional `tone` to shared/schemas/project.schema.json (doc/design.md section 6.6).

Schema-version decision: `clipStyle.tone` is allowed in every schema version and needs no bump. `clipStyle` itself is
valid in versions 1-4, 0.1.0 is unreleased (no released reader refuses the key), and the field is omitted at Auto, its
default, so a project whose card never chose a tone saves byte-identically. It is never written as "auto". The value is a
tone id from shared/data/rewrite-tones.json, "as-said" (no tone change) or a saved tone's "my-..." id from settings
`rewrite.myTones`; readers check only its shape, because a saved tone lives in the settings of the machine that chose it.
An id the reader does not know plans as Auto. Windows reads, validates and saves it unchanged.

Idempotent: running it twice leaves the same bytes. Run from anywhere; it rewrites the schema in place.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'shared/schemas/project.schema.json'


def tone_definition():
    return {
        'type': 'string', 'pattern': '^[a-z0-9]+(?:-[a-z0-9]+)*$', 'not': {'const': 'auto'}, 'maxLength': 64,
        'description': 'The tone Claude writes in (design.md sections 6.3.1 and 6.6): a tone id from '
                       'shared/data/rewrite-tones.json, "as-said" for no tone change, or a saved tone\'s "my-..." id from '
                       'settings rewrite.myTones. Omitted means Auto (Claude picks per clip) and is never written as '
                       '"auto". An id the reader does not know plans as Auto.'}


def main():
    schema = json.loads(PATH.read_text())
    schema['$defs']['clipStyle']['properties']['tone'] = tone_definition()
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
