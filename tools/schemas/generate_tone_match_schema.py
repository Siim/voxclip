#!/usr/bin/env python3
"""Add the tone match's optional `audio.tiltDbPerOctave` to shared/schemas/project.schema.json (voice-lab.md section 8.7
item 2b, ADR-R44).

Schema-version decision: the key is allowed in every version that has Voice Lab segment audio and needs no bump. It is
omitted when a take has no tilt, so every existing project and render recipe saves byte-identically; 0.1.0 is unreleased.
The value is the tilt in dB per octave, in 0.1 steps, never 0, within plus or minus 2. The Mac measures and applies it;
Windows reads, validates and saves it unchanged and renders without it (owed; voice-lab section 8.7 item 2b).

Idempotent: running it twice leaves the same bytes. Run from anywhere; it rewrites the schema in place.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'shared/schemas/project.schema.json'
OWNERS = ['voiceLabSegment', 'voiceLabRenderRecipe', 'voiceLabSegmentV3']


def tilt_definition():
    return {
        'type': 'number', 'minimum': -2, 'maximum': 2, 'not': {'const': 0},
        'description': 'The tone match (voice-lab.md section 8.7 item 2b): the generated take tilted towards the spectral '
                       'slope of the original speech beside it, in dB per octave (0.1 steps, within plus or minus 2), applied '
                       'from the asset\'s first frame before gainDb. Omitted when the take is left as it is. Windows renders '
                       'without it for now.'}


def main():
    schema = json.loads(PATH.read_text())
    for owner in OWNERS:
        schema['$defs'][owner]['properties']['audio']['properties']['tiltDbPerOctave'] = tilt_definition()
    PATH.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
