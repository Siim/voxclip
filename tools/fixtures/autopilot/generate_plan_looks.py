#!/usr/bin/env python3
"""Generate shared/fixtures/autopilot/plan-look-cases.json (schema voxclip-autopilot-look-cases/1): how the Make it postable
planner's validator reads the reply's look (looks spec 2026-11-28, sections 9.1, 9.4 and 9.5) against
shared/looks/clip-looks.json.

Each case is the reply's look fields (look, lookAmount, lookFix, lookAlternatives, lookReason; any may be absent), the
frames the request carried (null: none; otherwise one entry per sheet frame, its measured light in the Mac's FrameLight
shape or null when unmeasured), and the plan's look with the repairs the validator logs, as sorted [field, action] pairs
(the detail text is not pinned). The rules, written here independently of either Core:

- The look is matched by its letters only, lowercased, against the IDs and labels of the looks the pickers offer (not
  hidden), with the aliases blackandwhite, blackwhite and monochrome for bw and none and asfilmed for original. An unknown
  look becomes original without its reason (a repair on look). A reply with no look keeps original.
- lookAmount: missing keeps 100; a number from 0 to 1 is a fraction; it is rounded to the nearest 5 (half away from zero),
  kept within 40-100, and a strong look within 85. A changed or unreadable value is a repair on lookAmount. As filmed has
  no look to blend, so its amount is 100 and never a repair.
- lookFix is kept only when a frame's light was measured; otherwise it is off (a repair on lookFix when it was asked for).
- The dim-face repair: Moody and Teal & Amber become Soft Skin at its planner amount when the median of the frames'
  measured face median lumas is below measure.light.dimFaceLuma; the reason gains "brightened for a dim face" (a repair on
  look).
- lookAlternatives: each matched as the look is; an unknown one, one equal to the look, a repeat, or one past the second is
  dropped (lookAlternatives[i]). An absent or non-list value is no alternatives.

Swift ClipAutopilotLookTests and C# ClipAutopilotLookTests replay every case. Deterministic; run from anywhere.
"""
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LOOKS_PATH = ROOT / 'shared/looks/clip-looks.json'
DESTINATION = ROOT / 'shared/fixtures/autopilot/plan-look-cases.json'
ALIASES = {'blackandwhite': 'bw', 'blackwhite': 'bw', 'monochrome': 'bw', 'none': 'original', 'asfilmed': 'original'}
DIM_FACE_LOOKS = ('moody', 'tealAmber')
DIM_FACE_REPLACEMENT = 'softSkin'
DIM_FACE_REASON = 'brightened for a dim face'

LIBRARY = json.loads(LOOKS_PATH.read_text(encoding='utf-8'))
VISIBLE = [look for look in LIBRARY['looks'] if not look.get('hidden')]
BY_ID = {look['id']: look for look in VISIBLE}
DIM_FACE_LUMA = LIBRARY['measure']['light']['dimFaceLuma']


def key(text):
    return ''.join(character for character in text.lower() if character.isalpha())


def match(name):
    if not isinstance(name, str):
        return None
    wanted = ALIASES.get(key(name), key(name))
    for look in VISIBLE:
        if look['id'].lower() == wanted or key(look['label']) == wanted:
            return look
    return None


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def round_half_away(value):
    return int(math.floor(abs(value) + 0.5)) * (1 if value >= 0 else -1)


def checked(reply, frames):
    repairs = []
    if 'look' not in reply or reply['look'] is None:
        return {'id': 'original', 'amount': 100, 'fix': False, 'alternatives': [], 'reason': ''}, repairs
    look = match(reply['look'])
    if look is None:
        repairs.append(['look', 'repaired'])
        return {'id': 'original', 'amount': 100, 'fix': False, 'alternatives': [], 'reason': ''}, repairs
    reason = (reply.get('lookReason') or '').strip()
    measured = [light for light in (frames or []) if light is not None]
    faces = [light['faceMedianLuma'] for light in measured if 'faceMedianLuma' in light]
    if look['id'] in DIM_FACE_LOOKS and faces and median(faces) < DIM_FACE_LUMA:
        look = BY_ID[DIM_FACE_REPLACEMENT]
        reason = f'{reason}; {DIM_FACE_REASON}' if reason else DIM_FACE_REASON[0].upper() + DIM_FACE_REASON[1:]
        repairs.append(['look', 'repaired'])
        amount = look['planner']['amount']
    else:
        amount = 100
        if reply.get('lookAmount') is not None and look['id'] != 'original':
            given = reply['lookAmount']
            if isinstance(given, (int, float)) and not isinstance(given, bool) and math.isfinite(given):
                value = given * 100 if 0 <= given <= 1 else given
                amount = min(100, max(40, round_half_away(value / 5) * 5))
                if look['strength'] == 'strong':
                    amount = min(amount, 85)
                if amount != given:
                    repairs.append(['lookAmount', 'repaired'])
            else:
                repairs.append(['lookAmount', 'repaired'])
    fix = reply.get('lookFix') is True
    if fix and not measured:
        fix = False
        repairs.append(['lookFix', 'repaired'])
    alternatives = []
    items = reply.get('lookAlternatives')
    for index, item in enumerate(items if isinstance(items, list) else []):
        found = match(item)
        if found is None or found['id'] == look['id'] or found['id'] in alternatives or len(alternatives) == 2:
            repairs.append([f'lookAlternatives[{index}]', 'dropped'])
            continue
        alternatives.append(found['id'])
    return {'id': look['id'], 'amount': amount, 'fix': fix, 'alternatives': alternatives, 'reason': reason}, sorted(repairs)


def light(face_median=None, median_luma=0.45):
    value = {'medianLuma': median_luma, 'p95Luma': 0.9, 'meanChroma': 0.12, 'neutralMeans': [0.5, 0.46875, 0.4375]}
    if face_median is not None:
        value.update({'faceMeanLuma': face_median, 'faceMedianLuma': face_median, 'faceClippedShare': 0.0})
    return value


LIT = [light(0.5), light(0.46), None]
DIM = [light(0.25), light(0.28), light(None, 0.2)]
CASES = [
    ('a-known-look-with-its-amount-fix-and-alternatives', LIT,
     {'look': 'Warm Print', 'lookAmount': 70, 'lookFix': True, 'lookAlternatives': ['Golden Hour', 'Natural Boost'],
      'lookReason': 'Soft window light suits a memory'}),
    ('an-unknown-look-stays-as-filmed', LIT, {'look': 'Neon Dream', 'lookAmount': 70, 'lookReason': 'Bold'}),
    ('no-look-keeps-as-filmed', LIT, {}),
    ('a-reply-from-before-amounts-keeps-the-whole-look', None, {'look': 'warm', 'lookReason': 'Friendly founder talk'}),
    ('an-amount-as-a-fraction', LIT, {'look': 'goldenHour', 'lookAmount': 0.7, 'lookReason': 'Sunset'}),
    ('an-amount-of-one-is-the-whole-look', LIT, {'look': 'goldenHour', 'lookAmount': 1, 'lookReason': 'Sunset'}),
    ('an-amount-below-the-floor', LIT, {'look': 'goldenHour', 'lookAmount': 33, 'lookReason': 'Sunset'}),
    ('an-amount-rounded-to-five', LIT, {'look': 'goldenHour', 'lookAmount': 72, 'lookReason': 'Sunset'}),
    ('an-amount-above-the-whole-look', LIT, {'look': 'goldenHour', 'lookAmount': 130, 'lookReason': 'Sunset'}),
    ('an-amount-past-any-whole-number', LIT, {'look': 'goldenHour', 'lookAmount': 1e300, 'lookReason': 'Sunset'}),
    ('an-amount-below-any-whole-number', LIT, {'look': 'goldenHour', 'lookAmount': -1e300, 'lookReason': 'Sunset'}),
    ('a-strong-look-at-95', LIT, {'look': 'matteFilm', 'lookAmount': 95, 'lookReason': 'Calm storytelling'}),
    ('an-unreadable-amount', LIT, {'look': 'warmPrint', 'lookAmount': 'seventy', 'lookReason': 'Memories'}),
    ('as-filmed-takes-no-amount', LIT, {'look': 'As filmed', 'lookAmount': 60, 'lookFix': True, 'lookReason': 'A screen demo'}),
    ('a-fix-without-frames-is-ignored', None, {'look': 'naturalBoost', 'lookFix': True, 'lookReason': 'Business talk'}),
    ('a-fix-without-measured-light-is-ignored', [None, None], {'look': 'naturalBoost', 'lookFix': True, 'lookReason': 'Business talk'}),
    ('aliases-and-labels', LIT, {'look': 'black and white', 'lookAlternatives': ['Soft B&W', 'TEAL & amber'], 'lookReason': 'A reflective beat'}),
    ('duplicate-same-and-extra-alternatives-are-dropped', LIT,
     {'look': 'goldenHour', 'lookAlternatives': ['goldenHour', 'Warm Print', 'warmprint', 'Neon', 'Sepia', 'Teal & Amber'],
      'lookReason': 'Travel win'}),
    ('alternatives-that-are-not-a-list', LIT, {'look': 'cleanPop', 'lookAlternatives': 'boldPop', 'lookReason': 'Fast tips'}),
    ('a-dim-face-with-moody-becomes-soft-skin', DIM, {'look': 'Moody', 'lookAmount': 65, 'lookFix': True, 'lookReason': 'A confessional story'}),
    ('a-dim-face-with-teal-and-amber-becomes-soft-skin', DIM,
     {'look': 'tealAmber', 'lookAmount': 70, 'lookAlternatives': ['Soft Skin', 'Moody'], 'lookReason': ''}),
    ('a-lit-face-keeps-moody', LIT, {'look': 'moody', 'lookAmount': 65, 'lookReason': 'A true story'}),
    ('a-dim-face-keeps-other-looks', DIM, {'look': 'warm', 'lookReason': 'Friendly'}),
]


def main():
    cases = []
    for identity, frames, reply in CASES:
        look, repairs = checked(reply, frames)
        cases.append({'id': identity, 'reply': reply, 'frames': frames, 'expect': {'look': look, 'repairs': repairs}})
    document = {
        'schema': 'voxclip-autopilot-look-cases/1',
        'description': 'How the planner validator reads the reply\'s look (looks spec 2026-11-28, sections 9.1, 9.4 and 9.5). '
                       'Generated by tools/fixtures/autopilot/generate_plan_looks.py from shared/looks/clip-looks.json; Swift '
                       'and C# ClipAutopilotLookTests replay every case. frames null: the request carried none; a null frame '
                       'entry: a sheet frame without measured light. repairs are sorted [field, action] pairs.',
        'sources': {'shared/looks/clip-looks.json': hashlib.sha256(LOOKS_PATH.read_bytes().replace(b'\r\n', b'\n')).hexdigest()},
        'dimFaceLooks': list(DIM_FACE_LOOKS),
        'dimFaceReplacement': DIM_FACE_REPLACEMENT,
        'cases': cases,
    }
    DESTINATION.write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
