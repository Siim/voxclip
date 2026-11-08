#!/usr/bin/env python3
"""Generate the shared frame-decision vectors (ADR-R48, doc/spec/ai.md section 19).

Writes shared/fixtures/clip-frames/decision-cases.json (schema voxclip-frame-decision-cases/1), a new file of its own so no
existing replay's keys or counts change. It holds the pure decisions "Claude sees the picture" makes from fabricated
observations: eye states, clear looks, the opening frame, the cover, the face-follow crop, screens, blur spans and their
candidates, the frame sheet's text summary and the sampling times, plus an analysis-v2.json sample for the JSON round trip.
Every input observation and every expected decision is written in the Mac's JSON shape (Swift's synthesized Codable: a nil
optional is left out), so both Cores decode the inputs and encode their answers through their real code. Swift
FrameDecisionVectorTests and C# FrameDecisionVectorTests replay every case.

This is a reference implementation of apps/macos/Sources/VoxClipCore/Domain/Frames. It keeps Swift's order of IEEE
operations: sums are left folds from 0 (never Python's compensated sum()), Swift's rounded() is half away from zero (never
Python's round()), and a maximum keeps the first of equals. The cover's centring distance is sqrt(dx*dx + dy*dy) here, which
is correctly rounded on every platform, where the Cores call hypot (libm and .NET may round it 1 ULP apart); the replays
compare numbers within 1e-12. Pure IEEE arithmetic, so byte-exact (check_drift.py lists it as EXACT); run from anywhere.
"""
import json
import math
from decimal import ROUND_HALF_EVEN, Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-frames/decision-cases.json'

CLOSED_BELOW = 0.20
GOOD_QUALITY = 0.4
YAW_LIMIT = 0.35
PITCH_LIMIT = 0.35
START_TOLERANCE = 0.05
QUALITY_MARGIN = 0.15
OPENING_SPAN = 0.6
OPENING_STEP = 0.1
DEAD_ZONE = 0.15
MAXIMUM_SPEED = 0.5
MEDIAN_WINDOW = 5
BLINK_WINDOW = 0.25
QUALITY_WEIGHT = 0.4
CENTRED_WEIGHT = 0.3
EYES_WEIGHT = 0.2
FACING_WEIGHT = 0.1
MINIMUM_BOXES = 3
MINIMUM_COVERAGE = 0.04
MINIMUM_AREA = 0.01
CLUSTER_BOXES = 8
MINIMUM_OVERLAP = 0.2
BLUR_MAX_GAP = 8.0
BLUR_PAD = 1.0
MAXIMUM_COVERS = 3
MAXIMUM_SENTENCES = 24
MAXIMUM_SENTENCE_WORDS = 40
PIXELS_PER_TOKEN = 750.0
MINIMUM_RECT_SIDE = 0.01
SUMMARY_HEADER = 'Frames measured on this Mac (one per sentence; rects are x,y,w,h of the picture, top-left origin):'


# MARK: Arithmetic as Swift does it

def fold(values):
    total = 0.0
    for value in values:
        total = total + value
    return total


def rounded(value):
    """Swift's rounded(): half away from zero."""
    whole = math.floor(abs(value))
    result = whole + 1 if abs(value) - whole >= 0.5 else whole
    return math.copysign(result, value)


def median(values):
    ordered = sorted(values)
    if not ordered:
        return 0.5
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 == 1 else (ordered[middle - 1] + ordered[middle]) / 2


def fixed(value, places=2):
    """The Mac's String(format: "%.<places>f", locale: en_US_POSIX): the shortest round-trip decimal of the value, rounded
    half to even, sign kept (-0.00). Not printf, which rounds the exact binary value: 0.615 is "0.62" here, "0.61" there."""
    rounded = Decimal(repr(value)).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_EVEN)
    text = format(rounded, f'.{places}f')
    return '-' + text if math.copysign(1.0, value) < 0 and not text.startswith('-') else text


def two(value):
    return fixed(value, 2)


# MARK: Rects (ClipEffect.Rect) as dicts

def rect(x, y, width, height):
    return {'x': x, 'y': y, 'width': width, 'height': height}


def mid_x(box):
    return box['x'] + box['width'] / 2


def mid_y(box):
    return box['y'] + box['height'] / 2


def is_valid(box):
    values = [box['x'], box['y'], box['width'], box['height']]
    return (all(math.isfinite(v) for v in values) and box['x'] >= 0 and box['y'] >= 0 and box['width'] >= MINIMUM_RECT_SIDE
            and box['height'] >= MINIMUM_RECT_SIDE and box['x'] + box['width'] <= 1 + 1e-9 and box['y'] + box['height'] <= 1 + 1e-9)


def clamped(box):
    side = MINIMUM_RECT_SIDE
    w = min(1, max(side, box['width']))
    h = min(1, max(side, box['height']))
    return rect(min(1 - w, max(0, box['x'])), min(1 - h, max(0, box['y'])), w, h)


def area(box):
    return max(0, box['width']) * max(0, box['height'])


def contains(box, x, y):
    return box['x'] <= x <= box['x'] + box['width'] and box['y'] <= y <= box['y'] + box['height']


def overlaps(a, b):
    return a['x'] < b['x'] + b['width'] and b['x'] < a['x'] + a['width'] and a['y'] < b['y'] + b['height'] and b['y'] < a['y'] + a['height']


def union(boxes):
    left = min(b['x'] for b in boxes)
    top = min(b['y'] for b in boxes)
    right = max(b['x'] + b['width'] for b in boxes)
    bottom = max(b['y'] + b['height'] for b in boxes)
    return rect(left, top, right - left, bottom - top)


def iou(a, b):
    left, right = max(a['x'], b['x']), min(a['x'] + a['width'], b['x'] + b['width'])
    top, bottom = max(a['y'], b['y']), min(a['y'] + a['height'], b['y'] + b['height'])
    if not (right > left and bottom > top):
        return 0
    overlap = (right - left) * (bottom - top)
    total = area(a) + area(b) - overlap
    return overlap / total if total > 0 else 0


# MARK: Faces and observations, in the Mac's JSON shape

def eye_state(left, right):
    values = [v for v in (left, right) if v is not None]
    if not values:
        return 'unknown'
    return 'closed' if fold(values) / len(values) < CLOSED_BELOW else 'open'


def eye_ratio(points):
    if len(points) < 3:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    width = max(xs) - min(xs)
    height = max(ys) - min(ys)
    return height / width if width > 0 else None


def face(box, quality=None, left=None, right=None, yaw=None, pitch=None):
    value = {'rect': box}
    for key, item in (('captureQuality', quality), ('leftEyeAspect', left), ('rightEyeAspect', right), ('yaw', yaw), ('pitch', pitch)):
        if item is not None:
            value[key] = item
    value['eyes'] = eye_state(left, right)
    return value


def screen(box, boxes, coverage, framed):
    return {'rect': box, 'textBoxes': boxes, 'textCoverage': coverage, 'framed': framed}


def observation(time, face_value=None, face_count=None, texts=(), screens=()):
    value = {'time': time, 'faceCount': face_count if face_count is not None else (1 if face_value else 0)}
    if face_value is not None:
        value['face'] = face_value
    value['textRects'] = list(texts)
    value['screens'] = list(screens)
    return value


def faces_camera(face_value, baseline):
    measured = False
    yaw = face_value.get('yaw')
    if yaw is not None:
        measured = True
        if abs(yaw) > YAW_LIMIT:
            return False
    pitch = face_value.get('pitch')
    if pitch is not None:
        measured = True
        if abs(pitch - (baseline if baseline is not None else 0)) > PITCH_LIMIT:
            return False
    return True if measured else None


def pitch_baseline(frames):
    pitches = sorted(f['face']['pitch'] for f in frames if f.get('face') and f['face'].get('pitch') is not None)
    if not pitches:
        return None
    return median(pitches)


def clear_look(frame, baseline):
    found = frame.get('face')
    if not found:
        return False
    return found['eyes'] == 'open' and (found.get('captureQuality') or 0) >= GOOD_QUALITY and faces_camera(found, baseline) is not False


def open_look(frame, baseline):
    found = frame.get('face')
    return bool(found) and found['eyes'] == 'open' and faces_camera(found, baseline) is not False


def quality(frame):
    found = frame.get('face')
    return (found.get('captureQuality') or 0) if found else 0


# MARK: Clips (FrameClip)

def word(identity, text, start, end, kind='word'):
    return {'id': identity, 'text': text, 'kind': kind, 'start': start, 'end': end}


def frame_clip(words, first, last, cut):
    if first < 0 or last >= len(words) or first > last:
        return None
    kept = [i for i in range(first, last + 1) if words[i]['kind'] == 'word' and words[i]['id'] not in cut]
    if not kept:
        return None
    start = words[kept[0]]['start']
    floors = [w['end'] for w in words[:kept[0]] if w['end'] <= start + 1e-9]
    return {'words': words, 'first': first, 'last': last, 'kept': kept, 'start': start, 'end': words[kept[-1]]['end'],
            'leadInFloor': max(floors) if kept[0] > 0 and floors else 0.0}


def choose_opening(clip, scan, baseline):
    start = clip['start']
    earliest = start - OPENING_SPAN - 1e-9
    floor = max(clip['leadInFloor'], max(0, earliest))
    ordered = sorted((f for f in scan if math.isfinite(f['time'])), key=lambda f: f['time'])
    current = None
    for frame in ordered:
        if abs(frame['time'] - start) > START_TOLERANCE:
            continue
        if current is not None and abs(current['time'] - start) <= abs(frame['time'] - start):
            continue
        current = frame
    if current is not None and clear_look(current, baseline):
        return {'shift': 0.0, 'time': start}
    if current is not None and open_look(current, baseline):
        needed = max(GOOD_QUALITY, quality(current) + QUALITY_MARGIN)
    else:
        needed = GOOD_QUALITY - QUALITY_MARGIN
    for frame in ordered:
        in_silence = floor - 1e-9 <= frame['time'] <= start + 1e-9
        if in_silence and open_look(frame, baseline) and quality(frame) >= needed - 1e-9:
            time = min(start, max(floor, frame['time']))
            return {'shift': time - start, 'time': time}
    return None


# MARK: Face-follow crop

def crop_clamp(value, size):
    half = min(0.5, size / 2)
    return min(1 - half, max(half, value))


def running_median(values):
    half = MEDIAN_WINDOW // 2
    return [median(values[max(0, i - half):min(len(values) - 1, i + half) + 1]) for i in range(len(values))]


def follow(targets, times, size, start):
    if not size < 1 - 1e-9:
        return [0.5 for _ in targets]
    current = start
    previous = times[0] if times else 0
    path = []
    zone = DEAD_ZONE * size
    for index, target in enumerate(targets):
        elapsed = max(0, times[index] - previous)
        previous = times[index]
        offset = target - current
        if abs(offset) > zone:
            wanted = offset - (zone if offset > 0 else -zone)
            limit = MAXIMUM_SPEED * size * elapsed
            current += max(-limit, min(limit, wanted))
        current = crop_clamp(current, size)
        path.append(current)
    return path


def crop_plan(samples, source_aspect, target_aspect):
    if not (source_aspect > 0 and target_aspect > 0):
        return None
    width = min(1, target_aspect / source_aspect)
    height = min(1, source_aspect / target_aspect)
    ordered = sorted(samples, key=lambda s: s['time'])
    faces = [s['face'] for s in ordered if s.get('face')]
    if not faces:
        return {'cropWidth': width, 'cropHeight': height, 'centerX': 0.5, 'centerY': 0.5,
                'path': [{'t': s['time'], 'x': 0.5, 'y': 0.5} for s in ordered]}
    held_x, held_y = mid_x(faces[0]), mid_y(faces[0])
    xs, ys = [], []
    for sample in ordered:
        if sample.get('face'):
            held_x, held_y = mid_x(sample['face']), mid_y(sample['face'])
        xs.append(held_x)
        ys.append(held_y)
    target_x, target_y = running_median(xs), running_median(ys)
    times = [s['time'] for s in ordered]
    path_x = follow(target_x, times, width, crop_clamp(target_x[0], width))
    path_y = follow(target_y, times, height, crop_clamp(target_y[0], height))
    return {'cropWidth': width, 'cropHeight': height, 'centerX': crop_clamp(median(xs), width),
            'centerY': crop_clamp(median(ys), height),
            'path': [{'t': times[i], 'x': path_x[i], 'y': path_y[i]} for i in range(len(times))]}


# MARK: Cover

def cover_score(frame, neighbours, baseline):
    found = frame.get('face')
    if not found or found['eyes'] != 'open':
        return None
    for other in neighbours:
        if other['time'] != frame['time'] and abs(other['time'] - frame['time']) <= BLINK_WINDOW \
                and other.get('face') and other['face']['eyes'] == 'closed':
            return None
    q = min(1, max(0, found.get('captureQuality') or 0))
    dx, dy = mid_x(found['rect']) - 0.5, mid_y(found['rect']) - 0.5
    offset = math.sqrt(dx * dx + dy * dy)
    centred = max(0, 1 - 2 * offset)
    ratios = [found[key] for key in ('leftEyeAspect', 'rightEyeAspect') if key in found]
    mean = fold(ratios) / len(ratios) if ratios else CLOSED_BELOW
    openness = min(1, max(0, (mean - CLOSED_BELOW) / 0.15))
    facing = 0 if faces_camera(found, baseline) is False else 1
    weighted = QUALITY_WEIGHT * q + CENTRED_WEIGHT * centred
    return weighted + EYES_WEIGHT * openness + FACING_WEIGHT * facing


def cover_pick(frames, baseline):
    best = None
    for frame in sorted(frames, key=lambda f: f['time']):
        value = cover_score(frame, frames, baseline)
        if value is None:
            continue
        if best is None or value > best['score'] + 1e-12:
            best = {'time': frame['time'], 'score': value}
    return best


def cover_candidates(sheet, baseline):
    observations = [item['observation'] for item in sheet]
    scored = []
    for item in sheet:
        value = cover_score(item['observation'], observations, baseline)
        if value is not None:
            scored.append((item, value))
    ranked = sorted(enumerate(scored), key=lambda pair: pair[0])
    # Best first; the earlier frame wins a tie within 1e-12 (an insertion sort keeps Swift's comparator exactly).
    ordered = []
    for offset, pair in ranked:
        position = len(ordered)
        while position > 0:
            other_offset, other = ordered[position - 1]
            better = pair[1] > other[1] if abs(pair[1] - other[1]) > 1e-12 else offset < other_offset
            if not better:
                break
            position -= 1
        ordered.insert(position, (offset, pair))
    return [{'id': f'C{rank + 1}', 'frame': pair[0]['index'], 'time': pair[0]['observation']['time'], 'score': pair[1]}
            for rank, (_, pair) in enumerate(ordered[:MAXIMUM_COVERS])]


# MARK: Screens and blur spans

def clusters(boxes):
    parent = list(range(len(boxes)))

    def root(index):
        while parent[index] != index:
            index = parent[index]
        return index

    grown = []
    for box in boxes:
        pad = box['height'] / 2
        grown.append(rect(box['x'] - pad, box['y'] - pad, box['width'] + 2 * pad, box['height'] + 2 * pad))
    for first in range(len(boxes)):
        for second in range(first + 1, len(boxes)):
            if overlaps(grown[first], grown[second]):
                parent[root(second)] = root(first)
    groups, order = {}, []
    for index, box in enumerate(boxes):
        key = root(index)
        if key not in groups:
            order.append(key)
            groups[key] = []
        groups[key].append(box)
    return [groups[key] for key in order]


def detect_screens(rectangles, texts):
    screens, claimed = [], set()
    for box in rectangles:
        if area(box) < MINIMUM_AREA:
            continue
        inside = [i for i, text in enumerate(texts) if contains(box, mid_x(text), mid_y(text))]
        coverage = min(1, fold(area(texts[i]) for i in inside) / area(box))
        if len(inside) < MINIMUM_BOXES or coverage < MINIMUM_COVERAGE:
            continue
        claimed.update(inside)
        screens.append(screen(clamped(box), len(inside), coverage, True))
    for cluster in clusters([text for i, text in enumerate(texts) if i not in claimed]):
        if len(cluster) < CLUSTER_BOXES:
            continue
        bounds = union(cluster)
        screens.append(screen(clamped(bounds), len(cluster), min(1, fold(area(b) for b in cluster) / max(area(bounds), 1e-9)), False))
    return screens


def merge_spans(frames, max_gap, pad):
    spans = []
    for frame in sorted(frames, key=lambda f: f['time']):
        for found in frame['screens']:
            match = None
            for index, span in enumerate(spans):
                if frame['time'] - span['last'] <= max_gap + 1e-9:
                    if match is None or iou(spans[match]['lastRect'], found['rect']) < iou(span['lastRect'], found['rect']):
                        match = index
            if match is not None and iou(spans[match]['lastRect'], found['rect']) >= MINIMUM_OVERLAP:
                span = spans[match]
                span['last'] = frame['time']
                span['lastRect'] = found['rect']
                span['union'] = union([span['union'], found['rect']])
                span['frames'] += 1
            else:
                spans.append({'first': frame['time'], 'last': frame['time'], 'lastRect': found['rect'], 'union': found['rect'], 'frames': 1})
    result = [{'start': max(0, s['first'] - pad), 'end': s['last'] + pad, 'rect': clamped(s['union']), 'frames': s['frames']} for s in spans]
    return sorted(result, key=lambda s: s['start'])


def blur_candidates(frames, clip_start, clip_end):
    result = []
    for span in merge_spans(frames, BLUR_MAX_GAP, BLUR_PAD):
        start, end = max(span['start'], clip_start), min(span['end'], clip_end)
        if not (end > start) or not is_valid(span['rect']):
            continue
        result.append({'id': f'B{len(result) + 1}', 'start': start, 'end': end, 'rect': span['rect'], 'frames': span['frames']})
    return result


# MARK: The frame sheet's summary

def rect_text(box):
    return ','.join(two(v) for v in (box['x'], box['y'], box['width'], box['height']))


def summary_line(index, frame, baseline):
    parts = []
    found = frame.get('face')
    if found:
        part = f'face at {rect_text(found["rect"])}'
        if frame['faceCount'] > 1:
            part += f' (largest of {frame["faceCount"]})'
        parts.append(part)
        parts.append(f'eyes {found["eyes"]}')
        if 'captureQuality' in found:
            parts.append(f'quality {two(found["captureQuality"])}')
        facing = faces_camera(found, baseline)
        if facing is not None:
            parts.append('facing camera' if facing else 'turned away')
    else:
        parts.append('no face')
    for item in frame['screens']:
        parts.append(f'{"screen" if item["framed"] else "dense text"} with {item["textBoxes"]} text boxes at {rect_text(item["rect"])}')
    if not frame['screens'] and frame['textRects']:
        parts.append(f'{len(frame["textRects"])} text boxes')
    return f'F{index} {two(frame["time"])} s: ' + ', '.join(parts)


def summary(sheet, baseline):
    sheet = sheet[:MAXIMUM_SENTENCES]
    if not sheet:
        return ''
    return '\n'.join([SUMMARY_HEADER] + [summary_line(item['index'], item['observation'], baseline) for item in sheet])


# MARK: Sampling

def ends_sentence(text):
    return len(text) > 0 and text[-1] in '.?!…'


def spread(items, limit):
    if limit <= 0:
        return []
    if len(items) <= limit:
        return items
    if limit == 1:
        return [items[0]]
    span, steps = float(len(items) - 1), float(limit - 1)
    return [items[int(rounded(step * span / steps))] for step in range(limit)]


def sentence_samples(clip, limit):
    if limit <= 0:
        return []
    sentences, current = [], []
    for index in clip['kept']:
        current.append(index)
        if ends_sentence(clip['words'][index]['text']) or len(current) >= MAXIMUM_SENTENCE_WORDS:
            sentences.append(current)
            current = []
    if current:
        sentences.append(current)
    samples = []
    for sentence in spread(sentences, limit):
        middle = clip['words'][sentence[len(sentence) // 2]]
        samples.append({'time': (middle['start'] + middle['end']) / 2, 'firstWord': sentence[0], 'lastWord': sentence[-1]})
    return samples


def video_samples(words):
    whole = frame_clip(words, 0, len(words) - 1, set()) if words else None
    return sentence_samples(whole, 1 << 62) if whole else []


def clip_samples(video, clip, limit):
    spans = [(clip['words'][i]['start'], clip['words'][i]['end']) for i in clip['kept']]
    inside = [s for s in video if clip['start'] - 1e-9 <= s['time'] <= clip['end'] + 1e-9
              and any(a - 1e-9 <= s['time'] <= b + 1e-9 for a, b in spans)]
    return spread(inside, limit) if inside else sentence_samples(clip, limit)


def opening_times(start):
    steps = int(rounded(OPENING_SPAN / OPENING_STEP))
    times = []
    for step in range(-steps, steps + 1):
        time = start + step * OPENING_STEP
        if time >= 0:
            times.append(rounded(time * 1000) / 1000)
    return times


# MARK: Cases

CENTRED = rect(0.4, 0.3, 0.2, 0.4)


def at(centre_x):
    return rect(centre_x - 0.1, 0.3, 0.2, 0.4)


def look(time, q=0.6, eyes=0.3, yaw=0.0, pitch=0.0, box=CENTRED):
    return observation(time, face(box, q, eyes, eyes, yaw, pitch))


def lead_clip(previous_end, start):
    """'Before.' ending at previous_end, then a clip 'Hello there.' whose first word starts at start."""
    return [word('p', 'Before.', previous_end - 1, previous_end), word('a', 'Hello', start, start + 0.4),
            word('b', 'there.', start + 0.5, start + 0.9)], 1, 2, []


def eye_cases():
    ratios = [
        ('contour-height-over-width', [[0, 5], [10, 4], [20, 5], [30, 6], [40, 5], [30, 12], [20, 13], [10, 12]]),
        ('two-points-give-none', [[0, 0], [1, 1]]),
        ('flat-contour-gives-none', [[5, 0], [5, 3], [5, 6]]),
        ('a-blink', [[0, 0], [10, -1], [20, 0], [30, 1], [20, 2], [10, 2]]),
    ]
    states = [
        ('at-the-line-is-open', 0.2, 0.2),
        ('just-below-the-line-is-closed', 0.199, 0.199),
        ('the-mean-decides-open', 0.17, 0.24),
        ('the-mean-decides-closed', 0.17, 0.22),
        ('one-eye-open', None, 0.21),
        ('one-eye-closed', 0.19, None),
        ('no-eyes-unknown', None, None),
    ]
    return ([{'id': i, 'kind': 'ratio', 'points': p, 'expect': eye_ratio(p)} for i, p in ratios]
            + [{'id': i, 'kind': 'state', 'left': l, 'right': r, 'expect': eye_state(l, r)} for i, l, r in states])


def look_cases():
    cases = [
        ('no-face', observation(1.0), None),
        ('open-sharp-facing', look(1.0), None),
        ('eyes-closed', look(1.0, eyes=0.12), None),
        ('quality-just-under-good', look(1.0, q=0.39), None),
        ('quality-at-good', look(1.0, q=0.4), None),
        ('quality-not-measured', observation(1.0, face(CENTRED, None, 0.3, 0.3, 0.0, 0.0)), None),
        ('turned-away', look(1.0, yaw=0.5), None),
        ('camera-height-against-its-baseline', look(1.0, pitch=0.45), 0.45),
        ('camera-height-judged-from-zero', look(1.0, pitch=0.45), None),
        ('no-angles-is-not-turned-away', observation(1.0, face(CENTRED, 0.6, 0.3, 0.3)), 0.2),
        ('eyes-unknown', observation(1.0, face(CENTRED, 0.9, None, None, 0.0, 0.0)), None),
    ]
    return [{'id': i, 'frame': f, 'pitchBaseline': b, 'expect': {
        'clearLook': clear_look(f, b), 'facing': faces_camera(f['face'], b) if f.get('face') else None}} for i, f, b in cases]


def opening_cases():
    def clear(time, ok):
        return look(time, q=0.7, eyes=0.3 if ok else 0.1)

    def scan(begin, end, ok):
        count = int(rounded((end - begin) / 0.1))
        times = [rounded((begin + step * 0.1) * 1000) / 1000 for step in range(count + 1)]
        return [clear(t, ok(t)) for t in times]

    cases = []

    def add(identity, clip, frames, baseline=None):
        words, first, last, cut = clip
        made = frame_clip(words, first, last, set(cut))
        cases.append({'id': identity, 'words': words, 'first': first, 'last': last, 'cut': cut, 'scan': frames, 'pitchBaseline': baseline,
                      'expect': {'clip': {'start': made['start'], 'end': made['end'], 'leadInFloor': made['leadInFloor'], 'kept': made['kept']},
                                 'choice': choose_opening(made, frames, baseline)}})

    add('shift-stays-in-the-silence-and-never-crosses-a-word', lead_clip(9.6, 10.0),
        scan(9.4, 10.6, lambda t: t < 9.6 or abs(t - 9.8) < 1e-6))
    add('only-frames-inside-the-earlier-word-or-after-the-start', lead_clip(9.6, 10.0),
        scan(9.4, 10.6, lambda t: t < 9.6 or t > 10.05))
    add('a-clear-start-stays', lead_clip(7.0, 10.0), scan(9.4, 10.6, lambda t: True))
    add('no-further-back-than-the-scan', lead_clip(7.0, 10.0), [clear(9.0, True), clear(10.0, False)])
    add('earliest-acceptable-frame', lead_clip(7.0, 10.0), list(reversed(scan(9.4, 10.6, lambda t: t < 9.95))))
    add('dim-open-start-stays-for-a-slightly-better-frame', lead_clip(7.0, 10.0), [look(9.6, q=0.438), look(10.0, q=0.386)])
    add('dim-open-start-stays-for-a-second-slightly-better-frame', lead_clip(7.0, 10.0), [look(9.7, q=0.416), look(10.0, q=0.385)])
    add('a-clearly-better-frame-moves-the-start', lead_clip(7.0, 10.0), [look(9.6, q=0.55), look(10.0, q=0.3)])
    add('shut-eyes-move-to-a-dim-open-look', lead_clip(7.0, 10.0), [look(9.6, q=0.3), look(10.0, q=0.36, eyes=0.1)])
    add('turned-away-moves', lead_clip(7.0, 10.0), [look(9.5, q=0.33), look(10.0, q=0.5, yaw=0.8)])
    add('never-to-a-frame-too-poor-to-use', lead_clip(7.0, 10.0), [look(9.6, q=0.2), look(10.0, q=0.36, eyes=0.1)])
    add('no-face-at-the-start-moves-to-a-usable-look', lead_clip(7.0, 10.0), [look(9.6, q=0.26), observation(10.0)])
    add('no-face-at-the-start-and-none-usable', lead_clip(7.0, 10.0), [look(9.6, q=0.24), observation(10.0)])
    add('camera-height-start-is-clear-against-its-baseline', lead_clip(7.0, 10.0), [look(9.6, pitch=0.45), look(10.0, pitch=0.45)], 0.45)
    add('camera-height-judged-from-zero-nothing-faces', lead_clip(7.0, 10.0), [look(9.6, pitch=0.45), look(10.0, pitch=0.45)])
    add('tilted-past-the-baseline-moves-to-a-level-look', lead_clip(7.0, 10.0), [look(9.6, pitch=0.45), look(10.0, pitch=0.9)], 0.45)
    add('a-frame-within-the-start-tolerance-is-the-start', lead_clip(7.0, 10.0), [look(9.5, q=0.7), look(10.04, q=0.7)])
    add('a-frame-past-the-start-tolerance-is-not', lead_clip(7.0, 10.0), [look(9.5, q=0.7), look(10.06, q=0.7)])
    add('the-nearer-of-two-frames-is-the-start', lead_clip(7.0, 10.0), [look(9.5, q=0.7), look(9.98, q=0.7, eyes=0.1), look(10.01, q=0.7)])
    add('the-first-word-of-the-transcript-floors-at-zero', ([word('a', 'Hi', 0.3, 0.6), word('b', 'there.', 0.7, 1.0)], 0, 1, []),
        [look(0.0, q=0.7), look(0.1, q=0.7), look(0.3, q=0.7, eyes=0.1)])
    add('a-cut-first-word-is-still-a-floor',
        ([word('a', 'One.', 1, 2), word('b', 'um', 2.2, 2.6), word('c', 'Two', 3, 3.4), word('d', 'words.', 3.5, 4)], 1, 3, ['b']),
        [look(2.5, q=0.7), look(2.7, q=0.7), look(3.0, q=0.7, eyes=0.1)])
    add('an-event-before-the-start-is-a-floor',
        ([word('a', 'One.', 1, 2), word('e', '[laughs]', 2.1, 2.8, 'event'), word('c', 'Two', 3, 3.4), word('d', 'words.', 3.5, 4)], 1, 3, []),
        [look(2.6, q=0.7), look(2.9, q=0.7), look(3.0, q=0.7, eyes=0.1)])
    return cases


def cover_cases():
    def sharp(time, box=CENTRED, q=0.8, eyes=0.3, yaw=0.0, pitch=0.0):
        return observation(time, face(box, q, eyes, eyes, yaw, pitch))

    closed = observation(8, face(CENTRED, 0.9, 0.1, 0.1))
    blink = observation(1.9, face(CENTRED, None, 0.05, 0.05))
    base = [sharp(4, at(0.85)), sharp(6, q=0.3), sharp(2), closed]
    cases = [
        ('a-centred-sharp-open-face-wins', base, None),
        ('a-blink-neighbour-rules-a-frame-out', base + [blink], None),
        ('nothing-can-be-a-cover', [closed, observation(9)], None),
        ('a-tie-goes-to-the-earlier-frame', [sharp(5), sharp(3), sharp(4, q=0.5)], None),
        ('facing-is-judged-against-the-baseline', [sharp(2, q=0.6, pitch=0.45), sharp(3, at(0.55), q=0.6, pitch=0.0)], 0.45),
        ('facing-judged-from-zero', [sharp(2, q=0.6, pitch=0.45), sharp(3, at(0.55), q=0.6, pitch=0.0)], None),
        ('the-best-three-best-first', [sharp(1, q=0.5), sharp(2, q=0.9), sharp(3, q=0.7), sharp(4, q=0.6), sharp(5, q=0.8)], None),
        ('quality-is-clamped-and-missing-is-zero', [sharp(1, q=1.4), observation(2, face(CENTRED, None, 0.3, 0.3, 0.0, 0.0)), sharp(3, q=-0.2)], None),
        ('openness-saturates-and-one-eye-counts', [sharp(1, eyes=0.5), observation(2, face(CENTRED, 0.8, None, 0.28, 0.0, 0.0)), sharp(3, eyes=0.21)], None),
        ('a-corner-face-scores-no-centring', [sharp(1, rect(0.0, 0.0, 0.1, 0.1)), sharp(2, rect(0.9, 0.9, 0.1, 0.1), q=0.9)], None),
        ('eyes-unknown-is-no-cover', [observation(1, face(CENTRED, 0.9, None, None, 0.0, 0.0)), sharp(2, q=0.2)], None),
    ]
    result = []
    for identity, frames, baseline in cases:
        sheet = [{'index': i + 1, 'observation': f} for i, f in enumerate(frames)]
        result.append({'id': identity, 'frames': frames, 'pitchBaseline': baseline, 'expect': {
            'scores': [cover_score(f, frames, baseline) for f in frames],
            'pick': cover_pick(frames, baseline),
            'candidates': cover_candidates(sheet, baseline)}})
    return result


def crop_cases():
    offsets = [0.0, 0.02, -0.03, 0.01, -0.02, 0.03, -0.01, 0.02, 0.0, -0.03]
    jitter = [{'time': i * 0.5, 'face': at(0.6 + o)} for i, o in enumerate(offsets)]
    jitter[5]['face'] = at(0.1)
    jitter[7]['face'] = None
    pan = [{'time': i * 0.5, 'face': at(0.3 if i < 8 else 0.98)} for i in range(20)]
    late = [{'time': 0.0, 'face': None}, {'time': 0.5, 'face': None}, {'time': 1.0, 'face': at(0.7)}, {'time': 1.5, 'face': None},
            {'time': 2.0, 'face': at(0.72)}]
    vertical = [{'time': i * 0.4, 'face': rect(0.4, 0.1 + 0.05 * i, 0.2, 0.2)} for i in range(8)]
    shuffled = [{'time': t, 'face': at(c)} for t, c in [(2.0, 0.4), (0.0, 0.6), (1.0, 0.5), (3.0, 0.3), (0.5, 0.55)]]
    edge = [{'time': i * 0.5, 'face': rect(0.0, 0.3, 0.1, 0.3)} for i in range(4)]
    cases = [
        ('jitter-and-one-wrong-detection-hold', jitter, 16.0 / 9.0, 9.0 / 16.0),
        ('a-move-pans-slowly-and-stays-inside', pan, 16.0 / 9.0, 1.0),
        ('the-same-move-at-9x16', pan, 16.0 / 9.0, 9.0 / 16.0),
        ('no-faces-is-centred', [{'time': 0.0, 'face': None}, {'time': 1.0, 'face': None}], 16.0 / 9.0, 9.0 / 16.0),
        ('a-square-source-needs-no-square-crop', [{'time': 0.0, 'face': at(0.9)}], 1.0, 1.0),
        ('samples-before-the-first-face-hold-it', late, 16.0 / 9.0, 9.0 / 16.0),
        ('a-portrait-source-follows-vertically', vertical, 9.0 / 16.0, 1.0),
        ('samples-are-read-in-time-order', shuffled, 16.0 / 9.0, 9.0 / 16.0),
        ('a-face-at-the-edge-is-clamped', edge, 4.0 / 3.0, 9.0 / 16.0),
        ('no-samples', [], 16.0 / 9.0, 1.0),
        ('a-zero-aspect-gives-none', [{'time': 0.0, 'face': CENTRED}], 0.0, 1.0),
    ]
    return [{'id': i, 'samples': s, 'sourceAspect': a, 'targetAspect': t, 'expect': crop_plan(s, a, t)} for i, s, a, t in cases]


def screen_cases():
    phone = rect(0.6, 0.3, 0.2, 0.4)
    lines = [rect(0.62, 0.35 + i * 0.06, 0.15, 0.03) for i in range(4)]
    page = [rect(0.1, 0.1 + i * 0.04, 0.3, 0.025) for i in range(8)]
    tiny = [rect(0.62, 0.35 + i * 0.1, 0.01, 0.005) for i in range(3)]
    cases = [
        ('a-rectangle-with-dense-text-is-a-screen', [phone], lines),
        ('two-boxes-are-not-enough', [phone], lines[:2]),
        ('three-boxes-are', [phone], lines[:3]),
        ('sparse-text-is-not-a-screen', [phone], tiny),
        ('a-rectangle-under-the-minimum-area-is-ignored', [rect(0.6, 0.3, 0.09, 0.1)], lines),
        ('text-without-a-rectangle-needs-a-cluster', [], lines),
        ('eight-boxes-make-a-dense-text-cluster', [], page),
        ('seven-do-not', [], page[:7]),
        ('boxes-a-screen-claims-never-join-a-cluster', [phone], lines + page[:4]),
        ('a-rectangle-past-the-edge-is-clamped', [rect(0.85, -0.05, 0.3, 0.5)], [rect(0.88, 0.02 + i * 0.08, 0.1, 0.04) for i in range(4)]),
        ('two-clusters-apart', [], page + [rect(0.6, 0.6 + i * 0.04, 0.3, 0.025) for i in range(8)]),
        ('two-screens-in-one-frame', [phone, rect(0.05, 0.3, 0.2, 0.4)], lines + [rect(0.07, 0.35 + i * 0.06, 0.15, 0.03) for i in range(3)]),
    ]
    return [{'id': i, 'rectangles': r, 'texts': t, 'expect': detect_screens(r, t)} for i, r, t in cases]


def blur_cases():
    left, nudged, right = rect(0.1, 0.2, 0.2, 0.4), rect(0.12, 0.21, 0.2, 0.4), rect(0.7, 0.2, 0.2, 0.4)

    def seen(time, *boxes, framed=True):
        return observation(time, screens=[screen(b, 5, 0.2, framed) for b in boxes])

    sheet = [seen(8.25, rect(0.62, 0.3, 0.2, 0.4)), seen(11.75, rect(0.63, 0.31, 0.19, 0.39)), seen(15.25, rect(0.1, 0.6, 0.3, 0.2), framed=False),
             observation(1.25), observation(4.75)]
    cases = [
        ('a-matching-screen-merges-and-splits-on-a-gap-or-a-move',
         [seen(1, left), seen(2, nudged), seen(3, left, right), observation(4), seen(9, left)], 2.0, 0.5, 0.0, 20.0),
        ('the-plan-request-screens', sheet, BLUR_MAX_GAP, BLUR_PAD, 0.0, 15.0),
        ('the-best-overlap-takes-the-screen', [seen(1, left, rect(0.15, 0.2, 0.2, 0.4)), seen(2, rect(0.16, 0.2, 0.2, 0.4))], 2.0, 0.0, 0.0, 5.0),
        ('the-pad-stops-at-zero-and-the-clip-ends', [seen(0.4, left), seen(6, right)], BLUR_MAX_GAP, BLUR_PAD, 0.0, 6.5),
        ('a-span-outside-the-clip-is-no-candidate', [seen(1, left), seen(30, right)], BLUR_MAX_GAP, BLUR_PAD, 10.0, 25.0),
        ('frames-are-read-in-time-order', [seen(5, left), seen(1, left), seen(3, nudged)], 2.0, 0.0, 0.0, 10.0),
        ('no-screens', [observation(1), observation(2)], BLUR_MAX_GAP, BLUR_PAD, 0.0, 10.0),
    ]
    return [{'id': i, 'frames': f, 'maxGap': g, 'pad': p, 'clipStart': s, 'clipEnd': e,
             'expect': {'spans': merge_spans(f, g, p), 'candidates': blur_candidates(f, s, e)}} for i, f, g, p, s, e in cases]


def summary_cases():
    def seen(time, box, q, eyes, faces=1, yaw=0.0, pitch=0.0, screens=(), texts=()):
        return observation(time, face(box, q, eyes, eyes, yaw, pitch), faces, texts, screens)

    plan = [
        seen(1.25, rect(0.40, 0.20, 0.20, 0.36), 0.55, 0.3),
        seen(4.75, rect(0.41, 0.21, 0.20, 0.35), 0.48, 0.1),
        seen(8.25, rect(0.39, 0.19, 0.21, 0.36), 0.62, 0.3, screens=[screen(rect(0.62, 0.30, 0.20, 0.40), 6, 0.2, True)]),
        seen(11.75, rect(0.40, 0.20, 0.20, 0.36), 0.50, 0.3, screens=[screen(rect(0.63, 0.31, 0.19, 0.39), 5, 0.2, True)]),
        observation(15.25, screens=[screen(rect(0.10, 0.60, 0.30, 0.20), 9, 0.3, False)]),
    ]
    mixed = [
        seen(0.0, CENTRED, 0.7, 0.3, faces=3),
        observation(1.005, face(rect(0.125, 0.375, 0.615, 0.045), None, 0.3, 0.3)),
        seen(2.675, CENTRED, 0.995, 0.25, yaw=0.6),
        observation(3.5, texts=[rect(0.1, 0.1, 0.1, 0.02)] * 4),
        observation(4.5, face(CENTRED, 0.444, None, None)),
    ]
    camera = [seen(1.0, CENTRED, 0.6, 0.3, pitch=0.45), seen(2.0, CENTRED, 0.6, 0.3, pitch=0.9)]
    many = [seen(i * 1.5, CENTRED, 0.5, 0.3) for i in range(26)]
    cases = [
        ('the-plan-request-summary', plan, None),
        ('largest-face-rounding-and-unmeasured-parts', mixed, None),
        ('facing-against-the-baseline', camera, 0.45),
        ('facing-judged-from-zero', camera, None),
        ('at-most-24-frames', many, None),
        ('an-empty-sheet', [], None),
    ]
    result = []
    for identity, frames, baseline in cases:
        sheet = [{'index': i + 1, 'observation': f} for i, f in enumerate(frames)]
        text = summary(sheet, baseline)
        result.append({'id': identity, 'frames': frames, 'pitchBaseline': baseline, 'expect': {
            'summary': text, 'summaryTokens': math.ceil(len(text.encode('utf-8')) / 2.2)}})
    return result


def image_token_cases():
    return [{'width': w, 'height': h, 'expect': math.ceil(float(max(0, w)) * float(max(0, h)) / PIXELS_PER_TOKEN)}
            for w, h in [(320, 180), (180, 320), (320, 240), (320, 320), (0, 180), (-5, 10)]]


def sampling_transcripts():
    """The transcripts the sampling cases cut clips from, each with its whole-video samples (FrameSampling.videoSamples)."""
    sentences = []
    for sentence in range(30):
        for position in range(3):
            index = sentence * 3 + position
            sentences.append(word(f'w{index}', 'end.' if position == 2 else 'word', index * 0.5, index * 0.5 + 0.4))
    run_on = [word(f'r{i}', 'go', i * 0.3, i * 0.3 + 0.25) for i in range(95)]
    mixed = [word('a', 'So', 0.0, 0.3), word('b', 'um', 0.4, 0.6), word('e', '[music]', 0.7, 1.5, 'event'), word('c', 'yes!', 1.6, 2.0),
             word('d', 'Really?', 2.2, 2.7), word('f', 'Fine…', 3.0, 3.5), word('g', 'ok', 3.6, 3.9)]
    return {name: {'words': words, 'video': video_samples(words)}
            for name, words in (('thirty-sentences', sentences), ('run-on', run_on), ('mixed', mixed), ('empty', []))}


def sampling_cases(transcripts):
    cases = [
        ('one-sample-per-sentence', 'thirty-sentences', 0, 89, [], 100),
        ('evenly-spaced-up-to-the-limit', 'thirty-sentences', 0, 89, [], MAXIMUM_SENTENCES),
        ('a-limit-of-one-keeps-the-first', 'thirty-sentences', 0, 89, [], 1),
        ('a-limit-of-zero-gives-none', 'thirty-sentences', 0, 89, [], 0),
        ('a-run-on-sentence-splits-every-40-words', 'run-on', 0, 94, [], MAXIMUM_SENTENCES),
        ('cut-words-and-events-are-skipped', 'mixed', 0, 6, ['b'], MAXIMUM_SENTENCES),
        ('a-clip-inside-a-long-sentence-gets-its-own', 'run-on', 2, 5, [], MAXIMUM_SENTENCES),
        ('a-clip-takes-the-videos-frames-inside-its-kept-words', 'thirty-sentences', 6, 44, ['w9', 'w10', 'w11'], MAXIMUM_SENTENCES),
        ('a-clip-takes-at-most-the-limit', 'thirty-sentences', 0, 89, [], 5),
    ]
    result = []
    for identity, name, first, last, cut, limit in cases:
        clip = frame_clip(transcripts[name]['words'], first, last, set(cut))
        result.append({'id': identity, 'transcript': name, 'first': first, 'last': last, 'cut': cut, 'limit': limit, 'expect': {
            'sentences': sentence_samples(clip, limit), 'clip': clip_samples(transcripts[name]['video'], clip, limit)}})
    return result


# Values whose two decimals differ between the Mac's rule and printf, .NET "F2" or .NET "0.00" (checked against Swift on macOS
# 27, 2026-11-08): halves of the shortest decimal go to even, digits past it round normally, and the sign of zero is kept.
DECIMALS = [0.615, 2.675, 0.995, 1.005, 0.125, 0.375, 0.045, 12.345, 0.12500000000000003, 0.12499999999999999, 0.30000000000000004,
            1e-09, -0.001, -0.0, -0.005, 0.005, 1.115, 10.005, 100.125, 0.285, 1234567.125, 0.07500000000000001, 0.065, 8.245]


def decimal_cases():
    return [{'value': value, 'expect': two(value)} for value in DECIMALS]


def opening_time_cases():
    return [{'start': s, 'expect': opening_times(s)} for s in [10.0, 0.2, 0.0, 12.345, 0.55, 3.3]]


def analysis_sample():
    """An analysis-v2.json as FrameAnalysisCache writes it, and a FrameAnalysis as analyze-frames reports it."""
    frames = {
        '0.250:1250': observation(1.25, face(rect(0.40, 0.20, 0.20, 0.36), 0.55, 0.31, 0.29, -0.04, 0.12), 1,
                                  [rect(0.62, 0.35, 0.15, 0.03)]),
        '0.250:4750': observation(4.75, face(rect(0.41, 0.21, 0.2, 0.35), 0.48, 0.1, 0.12, 0.02, 0.15), 2),
        '0.250:8250': observation(8.25, face(rect(0.39, 0.19, 0.21, 0.36), 0.62, 0.3, 0.3, 0.0, 0.1), 1,
                                  [rect(0.62, 0.35 + i * 0.06, 0.15, 0.03) for i in range(3)],
                                  [screen(rect(0.6, 0.3, 0.2, 0.4), 3, 0.16875, True)]),
        '0.033:600': observation(0.6, face(rect(0.4, 0.2, 0.2, 0.36))),
        '0.033:700': observation(0.7, face(rect(0.4, 0.2, 0.2, 0.36), 0.5, None, None, 0.1)),
        '0.033:800': observation(0.8, face(rect(0.4, 0.2, 0.2, 0.36), None, None, None, None, -0.2)),
        '0.250:15250': observation(15.25),
    }
    analysis = {
        'contentKey': 'sha256-0123456789abcdef',
        'opening': [frames['0.033:600'], frames['0.033:700'], frames['0.033:800']],
        'sentences': [frames['0.250:1250'], frames['0.250:4750'], frames['0.250:8250'], frames['0.250:15250']],
        'timings': {'analyzedFrames': 6, 'cachedFrames': 1, 'openingSeconds': 0.125, 'sentenceSeconds': 1.5},
        'version': 2,
    }
    return {'fileName': 'analysis-v2.json', 'file': {'frames': frames, 'schema': 'voxclip-frames/2'}, 'frameAnalysis': analysis,
            'pitchBaseline': pitch_baseline(analysis['sentences'] + analysis['opening'])}


def generated():
    transcripts = sampling_transcripts()
    sections = {
        'eyes': eye_cases(),
        'looks': look_cases(),
        'openings': opening_cases(),
        'covers': cover_cases(),
        'crops': crop_cases(),
        'screens': screen_cases(),
        'blurSpans': blur_cases(),
        'summaries': summary_cases(),
        'imageTokens': image_token_cases(),
        'samplings': sampling_cases(transcripts),
        'openingTimes': opening_time_cases(),
        'decimals': decimal_cases(),
    }
    return {
        'schema': 'voxclip-frame-decision-cases/1',
        'description': 'The pure frame decisions of ADR-R48 on fabricated observations, inputs and answers in the Mac\'s JSON '
                       'shape (a nil optional is left out). Generated by tools/fixtures/clip-frames/generate_frame_decisions.py; '
                       'the Swift and C# FrameDecisionVectorTests replay every case, comparing numbers within 1e-12.',
        'constants': {
            'closedBelow': CLOSED_BELOW, 'goodQuality': GOOD_QUALITY, 'yawLimit': YAW_LIMIT, 'pitchLimit': PITCH_LIMIT,
            'startTolerance': START_TOLERANCE, 'qualityMargin': QUALITY_MARGIN, 'openingSpan': OPENING_SPAN, 'openingStep': OPENING_STEP,
            'deadZone': DEAD_ZONE, 'maximumSpeed': MAXIMUM_SPEED, 'medianWindow': MEDIAN_WINDOW, 'blinkWindow': BLINK_WINDOW,
            'qualityWeight': QUALITY_WEIGHT, 'centredWeight': CENTRED_WEIGHT, 'eyesWeight': EYES_WEIGHT, 'facingWeight': FACING_WEIGHT,
            'minimumBoxes': MINIMUM_BOXES, 'minimumCoverage': MINIMUM_COVERAGE, 'minimumArea': MINIMUM_AREA, 'clusterBoxes': CLUSTER_BOXES,
            'minimumOverlap': MINIMUM_OVERLAP, 'blurMaxGap': BLUR_MAX_GAP, 'blurPad': BLUR_PAD, 'maximumCovers': MAXIMUM_COVERS,
            'maximumSentences': MAXIMUM_SENTENCES, 'maximumSentenceWords': MAXIMUM_SENTENCE_WORDS, 'pixelsPerToken': PIXELS_PER_TOKEN,
        },
        'caseCount': sum(len(cases) for cases in sections.values()),
        'counts': {key: len(cases) for key, cases in sections.items()},
        'transcripts': transcripts,
        **sections,
        'analysis': analysis_sample(),
    }


def main():
    DESTINATION.write_text(json.dumps(generated(), indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
