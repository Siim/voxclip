#!/usr/bin/env python3
"""Generate shared/fixtures/autopilot/plan-frames-cases.json (format voxclip-autopilot-frames/1, ADR-R48 and doc/spec/ai.md
section 19.6) and refresh the prompt hash the three hand-derived autopilot fixtures pin in `sources`.

The frames vectors: one clip's frames as the request lists them (the sheet summary, blur candidates B1-B2 and cover candidates
C1-C3), the instruction block the request adds with and without images, and hand-derived reply cases for the reply's `frames`
object: kept choices, unknown and repeated ids, an unknown cover falling back to the local best, and an old reply without
`frames`. A new file of its own (Mac Core replays it in ClipAutopilotFramesTests; the Windows twin of the frames is owed), so
no existing replay's keys or counts change. Deterministic; run from anywhere.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROMPT = ROOT / 'shared/prompts/clip-autopilot.json'
FIXTURES = ROOT / 'shared/fixtures/autopilot'
HAND_DERIVED = ['plan-validation-cases.json', 'plan-v2-cases.json', 'plan-tone-cases.json']


def prompt_sha():
    return hashlib.sha256(PROMPT.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def two(value):
    return f'{value:.2f}'


def rect(box):
    return ','.join(two(v) for v in box)


def generated(prompt):
    request = prompt['request']
    summary = '\n'.join([
        'Frames measured on this Mac (one per sentence; rects are x,y,w,h of the picture, top-left origin):',
        'F1 1.25 s: face at 0.40,0.20,0.20,0.36, eyes open, quality 0.55, facing camera',
        'F2 4.75 s: face at 0.41,0.21,0.20,0.35, eyes closed, quality 0.48, facing camera',
        'F3 8.25 s: face at 0.39,0.19,0.21,0.36, eyes open, quality 0.62, facing camera, screen with 6 text boxes at 0.62,0.30,0.20,0.40',
        'F4 11.75 s: face at 0.40,0.20,0.20,0.36, eyes open, quality 0.50, facing camera, screen with 5 text boxes at 0.63,0.31,0.19,0.39',
        'F5 15.25 s: no face, dense text with 9 text boxes at 0.10,0.60,0.30,0.20'])
    blur = [{'id': 'B1', 'start': 7.25, 'end': 12.75, 'rect': [0.62, 0.3, 0.2, 0.4], 'frames': 2},
            {'id': 'B2', 'start': 14.25, 'end': 15.0, 'rect': [0.1, 0.6, 0.3, 0.2], 'frames': 1}]
    cover = [{'id': 'C1', 'frame': 3, 'time': 8.25}, {'id': 'C2', 'frame': 1, 'time': 1.25}, {'id': 'C3', 'frame': 4, 'time': 11.75}]
    blur_lines = '\n'.join(request['blurCandidate'].replace('{id}', b['id']).replace('{start}', two(b['start']))
                           .replace('{end}', two(b['end'])).replace('{rect}', rect(b['rect'])).replace('{frames}', str(b['frames']))
                           for b in blur)
    cover_lines = '\n'.join(request['coverCandidate'].replace('{id}', c['id']).replace('{frame}', str(c['frame']))
                            .replace('{time}', two(c['time'])) for c in cover)
    block = request['frames'].replace('{summary}', summary).replace('{blur}', blur_lines).replace('{cover}', cover_lines)

    def choice(blur_items, cover_item):
        return {'blur': blur_items, 'cover': cover_item}

    cases = [
        {'id': 'blur-one-keep-one', 'reply': choice([{'id': 'B1', 'blur': True, 'reason': 'calendar names'},
                                                     {'id': 'B2', 'blur': False, 'reason': 'the slide the creator points at'}],
                                                    {'id': 'C2', 'reason': 'warm smile under the title'}),
         'expect': {'blur': [['B1', True], ['B2', False]], 'cover': ['C2', False], 'repairs': []}},
        {'id': 'ids-read-ignoring-case-and-space', 'reply': choice([{'id': ' b2 ', 'blur': True, 'reason': 'messages'}], {'id': 'c3', 'reason': ''}),
         'expect': {'blur': [['B2', True]], 'cover': ['C3', False], 'repairs': []}},
        {'id': 'unknown-and-repeated-blur-ids-are-ignored',
         'reply': choice([{'id': 'B7', 'blur': True, 'reason': 'x'}, {'id': 'B1', 'blur': True, 'reason': 'names'},
                          {'id': 'B1', 'blur': False, 'reason': 'again'}, {'id': 'C1', 'blur': True, 'reason': 'not a screen'}],
                         {'id': 'C1', 'reason': 'eyes open'}),
         'expect': {'blur': [['B1', True]], 'cover': ['C1', False],
                    'repairs': [['frames.blur[0]', 'dropped'], ['frames.blur[2]', 'dropped'], ['frames.blur[3]', 'dropped']]}},
        {'id': 'unknown-cover-falls-back-to-the-local-best', 'reply': choice([], {'id': 'C9', 'reason': 'made up'}),
         'expect': {'blur': [], 'cover': ['C1', True], 'repairs': [['frames.cover', 'repaired']]}},
        {'id': 'empty-cover-falls-back', 'reply': choice([], {'id': '', 'reason': ''}),
         'expect': {'blur': [], 'cover': ['C1', True], 'repairs': [['frames.cover', 'repaired']]}},
        {'id': 'old-reply-without-frames',
         'expect': {'blur': [], 'cover': ['C1', True], 'repairs': []}},
    ]
    return {
        'schema': 'voxclip-autopilot-frames/1', 'id': 'autopilot-plan-frames', 'origin': 'voxclip',
        'sources': {'shared/prompts/clip-autopilot.json': prompt_sha()},
        'description': 'One clip\'s frames as a plan request lists them (ADR-R48) and hand-derived checks of the reply\'s frames '
                       'object. The clip is plan-v2-cases.json\'s transcript, words 0-29 (0-15 s). Generated by '
                       'tools/fixtures/autopilot/generate_plan_frames.py.',
        'transcriptFrom': 'fixtures/autopilot/plan-v2-cases.json', 'scope': [0, 29],
        'frames': {'summary': summary, 'blur': blur, 'cover': cover},
        'block': block, 'blockWithImages': block + request['framesSent'],
        'cases': cases}


def main():
    prompt = json.loads(PROMPT.read_text())
    (FIXTURES / 'plan-frames-cases.json').write_text(json.dumps(generated(prompt), indent=2, ensure_ascii=False) + '\n')
    sha = prompt_sha()
    for name in HAND_DERIVED:
        path = FIXTURES / name
        text = path.read_text()
        document = json.loads(text)
        old = document['sources']['shared/prompts/clip-autopilot.json']
        if old != sha:
            # Only the hash changes, so the hand-derived file keeps its own formatting.
            path.write_text(text.replace(old, sha))


if __name__ == '__main__':
    main()
