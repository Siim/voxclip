#!/usr/bin/env python3
"""Generate the shared `voxclip-cli autopilot` picture vectors (ADR-R48 part 2, package W6 of "Windows sees the picture").

Writes shared/fixtures/clip-frames/autopilot-picture-cases.json (schema voxclip-autopilot-picture-cases/1), a new file of its own
so no existing replay's keys or counts change. Each case is what a clip's plan request carried of the picture (the frames sent,
whether as images, their token estimate, the blur and cover candidates), the reply's frame choices, the four picture decisions
as `ClipPicture.apply` left them, the shapes the clip exports in and whether a face was measured; and the `frames` and `picture`
objects the autopilot's JSON gives that clip, as the Mac's `CLIWorkflow.framesJSON` and `pictureJSON` build them
(apps/macos/Sources/voxclip-cli/Autopilot.swift). The Windows `CliAutopilotFramesVectorTests` rebuilds every case through the
Windows CLI's own JSON code and compares keys and values exactly; key order is not compared (the Mac prints sorted keys).

The only arithmetic is the opening's `earlier` (the clip's old start minus its new one) and its negation as `shift`: pure IEEE,
so byte-exact (check_drift.py lists it as EXACT); run from anywhere.
"""
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-frames/autopilot-picture-cases.json'

SHUT = 'Your eyes were shut on the first frame'
AWAY = 'You were looking away on the first frame'


def blur(id_, start, end, rect=(0.62, 0.3, 0.12, 0.4), frames=1):
    x, y, width, height = rect
    return {'id': id_, 'start': start, 'end': end, 'rect': {'x': x, 'y': y, 'width': width, 'height': height}, 'frames': frames}


def cover(id_, frame, time, score):
    return {'id': id_, 'frame': frame, 'time': time, 'score': score}


def opening(old_start, new_start, lead_in, chosen, reason):
    return {'leadIn': lead_in, 'earlier': old_start - new_start, 'start': new_start, 'chosen': chosen, 'reason': reason}


# MARK: The Mac CLI's two objects

def frames_json(case):
    """`framesJSON`: the frames as sent, the screens the reply chose to blur (whether or not they could be applied) and the
    cover's time: the reply's named candidate, else the best measured one, else null."""
    sent, reply = case['sent'], case['reply']
    candidates = {item['id']: item for item in sent['blur']}
    covers = {item['id']: item for item in sent['cover']}
    chosen = [] if reply is None else [candidates[item['id']] for item in reply['blur'] if item['blur'] and item['id'] in candidates]
    named = None if reply is None or reply['cover'] is None else covers.get(reply['cover']['id'])
    picked = named if named is not None else (sent['cover'][0] if sent['cover'] else None)
    return {'sent': sent['frames'], 'images': sent['images'], 'imageTokens': sent['imageTokens'] if sent['images'] else 0,
            'blur': [{'id': item['id'], 'start': item['start'], 'end': item['end']} for item in chosen],
            'cover': None if picked is None else picked['time']}


def picture_json(case):
    """`pictureJSON`: the opening's shift and why (0 and null when the start stayed), the crop for the first 9:16 or 1:1
    shape (null without one), each screen and whether it is blurred, and the cover (null without one)."""
    decisions, sent = case['decisions'], case['sent']
    candidates = {item['id']: item for item in sent['blur']}
    covers = {item['id']: item for item in sent['cover']}
    moved = decisions['opening']
    opening_ = ({'shift': -moved['earlier'], 'leadIn': moved['leadIn'], 'start': moved['start'], 'frame': moved['chosen'],
                 'reason': moved['reason']} if moved is not None else {'shift': 0, 'reason': None})
    shape = next((item for item in case['shapes'] if item in ('9:16', '1:1')), None)
    crop = None
    if shape is not None:
        centre = decisions['crop']
        crop = {'aspect': shape, 'faceFound': case['faceFound'],
                'center': None if centre is None else {'x': centre['centerX'], 'y': centre['centerY']}}
    screens = [{'id': item['id'], 'start': candidates[item['id']]['start'], 'end': candidates[item['id']]['end'],
                'blurred': item['blurred'], 'reason': item['reason']} for item in decisions['blurs']]
    chosen = decisions['cover']
    cover_ = (None if chosen is None else
              {'id': chosen['id'], 'time': covers[chosen['id']]['time'], 'fallback': not chosen['named'], 'reason': chosen['reason']})
    return {'opening': opening_, 'crop': crop, 'blur': screens, 'cover': cover_}


# MARK: The cases

def cases():
    yield {
        'id': 'images-blur-and-named-cover',
        'note': 'Images on a plan: the opening moved off shut eyes, the face-follow crop, B1 blurred as the reply chose and its named cover.',
        'sent': {'frames': 2, 'images': True, 'imageTokens': 154, 'blur': [blur('B1', 2.0, 4.0)],
                 'cover': [cover('C1', 1, 2.95, 0.81), cover('C2', 2, 3.9, 0.74)]},
        'reply': {'blur': [{'id': 'B1', 'blur': True, 'reason': 'It shows calendar entries with names'}],
                  'cover': {'id': 'C2', 'reason': 'Eyes open, face centred', 'fallback': False}},
        'decisions': {'opening': opening(2.48, 2.0, 0.6, 2.0, SHUT), 'crop': {'centerX': 0.4, 'centerY': 0.5},
                      'blurs': [{'id': 'B1', 'blurred': True, 'reason': 'It shows calendar entries with names'}],
                      'cover': {'id': 'C2', 'named': True, 'reason': 'Eyes open, face centred'}},
        'shapes': ['9:16'], 'faceFound': True,
    }
    yield {
        'id': 'text-only-chosen-but-left-sharp',
        'note': 'A text-only send: the reply named B1 (frames.blur lists it) but nothing could see it, so the picture leaves it sharp.',
        'sent': {'frames': 3, 'images': False, 'imageTokens': 0, 'blur': [blur('B1', 1.25, 3.5)], 'cover': [cover('C1', 2, 1.75, 0.66)]},
        'reply': {'blur': [{'id': 'B1', 'blur': True, 'reason': 'Names in a chat'}], 'cover': {'id': 'C1', 'reason': '', 'fallback': False}},
        'decisions': {'opening': None, 'crop': {'centerX': 0.512, 'centerY': 0.437},
                      'blurs': [{'id': 'B1', 'blurred': False, 'reason': 'Names in a chat'}],
                      'cover': {'id': 'C1', 'named': True, 'reason': None}},
        'shapes': ['9:16'], 'faceFound': True,
    }
    yield {
        'id': 'landscape-has-no-crop',
        'note': '16:9 only: no crop to decide, so crop is null; the opening moved for a turned-away face.',
        'sent': {'frames': 1, 'images': True, 'imageTokens': 77, 'blur': [], 'cover': [cover('C1', 1, 10.4, 0.7)]},
        'reply': {'blur': [], 'cover': {'id': 'C1', 'reason': 'The clearest look', 'fallback': False}},
        'decisions': {'opening': opening(10.08, 9.7, 0.4, 9.7, AWAY), 'crop': None, 'blurs': [],
                      'cover': {'id': 'C1', 'named': True, 'reason': 'The clearest look'}},
        'shapes': ['16:9'], 'faceFound': True,
    }
    yield {
        'id': 'square-without-a-face',
        'note': 'No face measured: the crop stays centred (center null) for the first portrait or square shape, here 1:1.',
        'sent': {'frames': 2, 'images': True, 'imageTokens': 154, 'blur': [], 'cover': []},
        'reply': {'blur': [], 'cover': None},
        'decisions': {'opening': None, 'crop': None, 'blurs': [], 'cover': None},
        'shapes': ['16:9', '1:1'], 'faceFound': False,
    }
    yield {
        'id': 'unknown-cover-falls-back',
        'note': 'The reply named C9, which was not listed: the best measured cover is taken, fallback true and no reason.',
        'sent': {'frames': 4, 'images': True, 'imageTokens': 308, 'blur': [], 'cover': [cover('C1', 3, 6.15, 0.9), cover('C2', 1, 4.0, 0.5)]},
        'reply': {'blur': [], 'cover': {'id': 'C9', 'reason': 'A guess', 'fallback': True}},
        'decisions': {'opening': None, 'crop': {'centerX': 0.333, 'centerY': 0.25}, 'blurs': [],
                      'cover': {'id': 'C1', 'named': False, 'reason': None}},
        'shapes': ['1:1', '9:16'], 'faceFound': True,
    }
    yield {
        'id': 'no-frame-choices-in-the-reply',
        'note': 'A reply without frames: nothing chosen to blur, the cover is the best measured one, the screen listed sharp.',
        'sent': {'frames': 2, 'images': True, 'imageTokens': 154, 'blur': [blur('B1', 0.5, 2.5, (0.1, 0.05, 0.3, 0.2), 2)],
                 'cover': [cover('C1', 2, 2.2, 0.55)]},
        'reply': None,
        'decisions': {'opening': opening(0.88, 0.4, 0.6, 0.4, SHUT), 'crop': {'centerX': 0.6, 'centerY': 0.45},
                      'blurs': [{'id': 'B1', 'blurred': False, 'reason': None}],
                      'cover': {'id': 'C1', 'named': False, 'reason': None}},
        'shapes': ['9:16'], 'faceFound': True,
    }
    yield {
        'id': 'two-screens-one-blurred',
        'note': 'Two screens: B1 blurred with its reason, B2 left sharp with the reply\'s reason; frames.blur lists B1 only.',
        'sent': {'frames': 6, 'images': True, 'imageTokens': 462,
                 'blur': [blur('B1', 3.0, 7.5), blur('B2', 12.25, 15.0, (0.05, 0.6, 0.5, 0.3), 3)],
                 'cover': [cover('C1', 5, 13.8, 0.72), cover('C2', 1, 3.4, 0.7), cover('C3', 4, 11.1, 0.61)]},
        'reply': {'blur': [{'id': 'B1', 'blur': True, 'reason': 'An inbox with names'}, {'id': 'B2', 'blur': False, 'reason': 'A public web page'}],
                  'cover': {'id': 'C3', 'reason': 'Mid-sentence smile', 'fallback': False}},
        'decisions': {'opening': None, 'crop': {'centerX': 0.47, 'centerY': 0.41},
                      'blurs': [{'id': 'B1', 'blurred': True, 'reason': 'An inbox with names'},
                                {'id': 'B2', 'blurred': False, 'reason': 'A public web page'}],
                      'cover': {'id': 'C3', 'named': True, 'reason': 'Mid-sentence smile'}},
        'shapes': ['9:16'], 'faceFound': True,
    }


def main():
    rows = []
    for case in cases():
        case = dict(case)
        case['frames'] = frames_json(case)
        case['picture'] = picture_json(case)
        rows.append(case)
    document = {
        'schema': 'voxclip-autopilot-picture-cases/1',
        'description': ('The frames and picture objects of voxclip-cli autopilot\'s JSON for one clip (ADR-R48 part 2), from what its plan '
                        'request carried, the reply\'s frame choices and the four picture decisions, as the Mac\'s CLIWorkflow.framesJSON '
                        'and pictureJSON build them. Generated by tools/fixtures/clip-frames/generate_autopilot_picture.py; the Windows '
                        'CliAutopilotFramesVectorTests replays every case, keys and values exact.'),
        'caseCount': len(rows),
        'cases': rows,
    }
    DESTINATION.write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
