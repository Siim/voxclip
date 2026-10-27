#!/usr/bin/env python3
"""Independent reference for Voice Lab patch geometry (voice-lab.md sections 8.3-8.10 and 10.5).

Writes shared/fixtures/voice-lab/window-cases.json: window and seam placement, minimum fade
handles, character alignment to words, TTS trim, relative word times and room-tone selection.
Standard library only; the output is byte-identical on every run.
"""
import bisect
import json
import math
import struct
import unicodedata
from decimal import Decimal, getcontext
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/window-cases.json'

# section 8.3, in seconds unless named otherwise.
SEAM_MIN_GAP = 0.12
SEAM_SEARCH_WORDS = 3
SEAM_FADE = 0.020
HARD_SEAM_FADE = 0.012
TTS_TRIM_LEAD = 0.03
TTS_TRIM_TAIL = 0.06
PAUSE_SLACK_KEEP = 0.15
VOICED_FRAME = -45.0
VOICED_FRAME_LEVEL = 0.005623413251903491
RMS_FRAME = 0.010       # one frame of the 10 ms RMS envelope that VOICED_FRAME measures
ROOM_TONE_MIN_RUN = 0.5
HARD_SEAM_REACH = 0.03  # section 8.4: a.start - min(0.03, gapBefore / 2)
ROOM_TONE_FRAMES = 50   # ROOM_TONE_MIN_RUN / 10 ms
SAMPLE_LIMIT = float(2 ** 53)  # sample counts below this stay exact in binary64

# The source is ASCII: every other character is written as an escape, so a reviewer can see what each vector tests.
assert Path(__file__).read_text(encoding='utf-8').isascii(), 'write non-ASCII characters as escapes'

getcontext().prec = 60
assert float(Decimal(10) ** (Decimal(VOICED_FRAME) / 20)) == VOICED_FRAME_LEVEL

WHITE_SPACE = {0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, *range(0x2000, 0x200B),
               0x2028, 0x2029, 0x202F, 0x205F, 0x3000}


class GeometryError(Exception):
    def __init__(self, code, **detail):
        super().__init__(code)
        self.value = {'error': code, **detail}


def js_round(x):
    floor = math.floor(x)
    return floor + 1 if x - floor >= 0.5 else floor


def samples(seconds, rate):
    return js_round(seconds * rate)


def frame_size(rate):
    return max(1, js_round(rate * RMS_FRAME))


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def check_envelope(envelope, rate):
    levels = envelope['levels']
    if envelope['sampleRate'] != rate or not levels or any(not math.isfinite(v) or v < 0 for v in levels):
        raise GeometryError('invalidInput')


def check_items(items, rate):
    """The project transcript rule (ProjectJSON.validate): unique IDs, finite times, 0 <= start < end, starts in order."""
    if len({item['id'] for item in items}) != len(items):
        raise GeometryError('invalidInput')
    previous = 0.0
    for item in items:
        if not (math.isfinite(item['start']) and math.isfinite(item['end']) and previous <= item['start'] < item['end']
                and item['end'] * rate < SAMPLE_LIMIT):
            raise GeometryError('invalidInput')
        previous = item['start']


# Decision 2: window and seam placement (section 8.4, replace only).
#
# Kept source comes from a model of the editing Core that VoiceLabOutputPlanner calls (editing.md sections 5.7, 7.2
# and 7.3): detectPauses, clipTimes, buildSegments and buildEditPlan.

def detect_pauses(items, threshold):
    return [{'id': 'pause-after-' + items[index]['id'], 'start': items[index]['end'], 'end': items[index + 1]['start']}
            for index in range(len(items) - 1) if items[index + 1]['start'] - items[index]['end'] >= threshold]


def clip_times(items, first, last):
    lead = max(0.0, items[first]['start'] - items[first - 1]['end']) / 2 if first > 0 else 0.12
    tail = max(0.0, items[last + 1]['start'] - items[last]['end']) / 2 if last + 1 < len(items) else 0.25
    return max(0.0, items[first]['start'] - min(0.12, lead)), items[last]['end'] + min(0.25, tail)


def edit_segments(items, edits, bounds):
    """buildSegments: each item as a word segment, the cut pauses and a clip's head and tail ranges, stably by start."""
    cut_words, cut_pauses = set(edits['cutWordIds']), set(edits['cutPauseIds'])
    segments = [{'id': item['id'], 'kind': 'word', 'start': item['start'], 'end': item['end'],
                 'cut': item['id'] in cut_words or (bounds is not None and not bounds[0] <= index <= bounds[1])}
                for index, item in enumerate(items)]
    segments += [{'id': pause['id'], 'kind': 'pause', 'start': pause['start'], 'end': pause['end'], 'cut': True}
                 for pause in detect_pauses(items, edits['pauseThresholdSeconds']) if pause['id'] in cut_pauses]
    if bounds is not None:
        start, end = clip_times(items, *bounds)
        if start > 0:
            segments.append({'id': 'clip-head', 'kind': 'range', 'start': 0.0, 'end': start, 'cut': True})
        tail = max(end, items[-1]['end']) + 3600
        if tail > end:
            segments.append({'id': 'clip-tail', 'kind': 'range', 'start': end, 'end': tail, 'cut': True})
    return sorted(segments, key=lambda segment: segment['start'])


def valid_segment(segment):
    return math.isfinite(segment['start']) and math.isfinite(segment['end']) and segment['end'] > segment['start']


def edit_plan(segments, duration, rate, keep):
    """buildEditPlan: each cut's section 7.3 range clamped to the sample grid and merged. Returns (cuts, kept)."""
    total = max(0, js_round(duration * rate))
    speech = sorted((index for index, segment in enumerate(segments) if segment['kind'] == 'word' and valid_segment(segment)),
                    key=lambda index: segments[index]['start'])
    rank = {position: order for order, position in enumerate(speech)}
    earlier, reached = [], 0.0
    for position in speech:
        earlier.append(reached)
        reached = max(reached, segments[position]['end'])
    starts = [segments[position]['start'] for position in speech]
    by_end = sorted(speech, key=lambda position: (segments[position]['end'], -rank[position]))
    ends = [segments[position]['end'] for position in by_end]

    def cut_range(position):
        segment = segments[position]
        if segment['kind'] == 'range':
            return segment['start'], segment['end']
        if segment['kind'] == 'pause':
            before = bisect.bisect_right(ends, segment['start'] + 1e-6) - 1
            after = bisect.bisect_left(starts, segment['end'] - 1e-6)
            kept_before = before >= 0 and not segments[by_end[before]]['cut']
            kept_after = after < len(speech) and not segments[speech[after]]['cut']
            return segment['start'] + (keep if kept_before else 0), segment['end'] - (keep if kept_after else 0)
        order = rank[position]
        if earlier[order] >= segment['end']:
            return segment['start'], segment['end']
        following = starts[order + 1] if order + 1 < len(speech) else duration
        return (segment['start'] - min(0.1, max(0.0, segment['start'] - earlier[order]) / 2),
                segment['end'] + min(0.1, max(0.0, following - segment['end']) / 2))

    selected = []
    for position, segment in enumerate(segments):
        if segment['cut'] and valid_segment(segment):
            start, end = cut_range(position)
            interval = (min(total, max(0, js_round(start * rate))), min(total, max(0, js_round(end * rate))))
            if interval[1] > interval[0]:
                selected.append((interval, position))
    cuts = []
    for (start, end), _ in sorted(selected, key=lambda pair: (pair[0][0], pair[1])):
        if cuts and start <= cuts[-1][1]:
            cuts[-1] = (cuts[-1][0], max(cuts[-1][1], end))
        else:
            cuts.append((start, end))
    kept, cursor = [], 0
    for start, end in cuts:
        if start > cursor:
            kept.append((cursor, start))
        cursor = end
    if cursor < total:
        kept.append((cursor, total))
    return cuts, kept


def resolve_scope(items, edits, clip_id):
    """The clip's item bounds and its clipTimes range, as VoiceLabOutputPlanner resolves a clip scope; None for full."""
    if clip_id is None:
        return None, None
    ids = [item['id'] for item in items]
    clip = next((clip for clip in edits['clips'] if clip['id'] == clip_id), None)
    if clip is None or clip['startWordId'] not in ids or clip['endWordId'] not in ids:
        raise GeometryError('invalidInput')
    bounds = (ids.index(clip['startWordId']), ids.index(clip['endWordId']))
    if bounds[0] > bounds[1]:
        raise GeometryError('invalidInput')
    return bounds, clip_times(items, *bounds)


def scope_replacements(segments, clip_range, rate, duration):
    """The enabled replacements VoiceLabOutputPlanner.build renders in this scope, by start, each with its synth range and
    the seams of its selected recipe. One that crosses the clip's range, has no synth samples or overlaps another leaves
    the scope unrenderable. A segment is {'id', 'enabled', 'window'}, where `window` is the `place` result it was built on."""
    selected = []
    for segment in segments:
        window = segment['window']
        start, end = window['start'], window['end']
        if not segment['enabled']:
            continue
        if not (math.isfinite(start) and math.isfinite(end) and 0 <= start < end <= duration):
            raise GeometryError('invalidInput')
        if clip_range is not None and (end <= clip_range[0] or start >= clip_range[1]):
            continue
        lo, hi = samples(start, rate), samples(end, rate)
        if clip_range is not None and (start < clip_range[0] or end > clip_range[1]) or hi <= lo:
            raise GeometryError('invalidInput')
        selected.append({'id': segment['id'], 'start': start, 'end': end, 'lo': lo, 'hi': hi,
                         'in': window['leftSeam'], 'out': window['rightSeam']})
    selected.sort(key=lambda replacement: replacement['start'])
    if any(later['lo'] < earlier['hi'] for earlier, later in zip(selected, selected[1:])):
        raise GeometryError('invalidInput')
    return selected


def subtract(intervals, ranges):
    """The parts of sorted, disjoint sample intervals that lie outside every range."""
    out = []
    for lo, hi in intervals:
        parts = [(lo, hi)]
        for cut_lo, cut_hi in ranges:
            parts = [part for start, end in parts for part in ((start, min(end, cut_lo)), (max(start, cut_hi), end)) if part[1] > part[0]]
        out += parts
    return out


def quietest_frame(levels, size, g0, g1, fade, kept):
    first = (g0 + size - 1) // size
    last = min(g1 // size - 1, len(levels) - 1)
    best = None
    for index in range(first, last + 1):
        seam = index * size + (size + 1) // 2
        # The whole centred fade lies in kept source, which also keeps it inside the take; section 10.5 never shortens it.
        if not any(start <= seam - fade // 2 and seam + fade - fade // 2 <= end for start, end in kept):
            continue
        key = (float(levels[index]), abs(2 * index * size + size - g0 - g1), index)
        if best is None or key < best[0]:
            best = (key, seam)
    return None if best is None else best[1]


class SeamLayout:
    """The synth pieces of an output plan in source order, each {'id', 'lo', 'hi', 'in', 'out'} with its seams, and the
    kept source pieces around them, in samples (section 10.5)."""

    def __init__(self, elements, pieces, total):
        self.elements, self.pieces, self.total = elements, pieces, total

    def run(self, index):
        """The kept pieces between element `index` - 1 (or the take start) and element `index` (or the take end)."""
        lo = self.elements[index - 1]['hi'] if index > 0 else 0
        hi = self.elements[index]['lo'] if index < len(self.elements) else self.total
        return [piece for piece in self.pieces if lo <= piece[0] and piece[1] <= hi]

    def beside(self, index, incoming):
        """The kept piece that ends at element `index`'s start, or starts at its end, in samples."""
        at = self.elements[index]['lo'] if incoming else self.elements[index]['hi']
        return next((hi - lo for lo, hi in self.pieces if (hi if incoming else lo) == at), 0)

    def side_ok(self, index, incoming):
        """Section 8.4 for one seam of element `index`: kinds as prepare takes them (`none` with nothing beside it,
        synthToSynth only between touching pieces that agree), and a fade's outer half in the kept source right beside it."""
        element, other = self.elements[index], index - 1 if incoming else index + 1
        seam = element['in'] if incoming else element['out']
        if seam['kind'] == 'none':
            return not self.run(index if incoming else index + 1) and not 0 <= other < len(self.elements)
        if seam['kind'] == 'synthToSynth':
            if self.run(index if incoming else index + 1) or not 0 <= other < len(self.elements):
                return False
            facing = self.elements[other]['out'] if incoming else self.elements[other]['in']
            touching = self.elements[other]['hi'] == element['lo'] if incoming else element['hi'] == self.elements[other]['lo']
            return touching and facing['kind'] == 'synthToSynth' and facing['fadeSamples'] == seam['fadeSamples']
        fade = seam['fadeSamples']
        return self.beside(index, incoming) >= (fade // 2 if incoming else fade - fade // 2)

    def fades_fit(self, index):
        """Prepare's overlappingFades rule between elements `index` and `index` + 1: the kept source between them holds the
        outer halves of both fades."""
        out_fade, in_fade = self.elements[index]['out']['fadeSamples'], self.elements[index + 1]['in']['fadeSamples']
        return sum(hi - lo for lo, hi in self.run(index + 1)) >= out_fade - out_fade // 2 + in_fade // 2

    def pair_ok(self, index):
        """The fades rule across one kept piece that fills the whole gap between elements `index` and `index` + 1."""
        if self.run(index + 1) != [(self.elements[index]['hi'], self.elements[index + 1]['lo'])]:
            return True
        return self.fades_fit(index)

    def prepare_ok(self, index, incoming):
        """Prepare's own rule for one seam of element `index`, which allows a fade across a cut: the neighbouring output piece
        is source and holds the fade's outer half, and the fades on either side of the kept source between this element and
        the next one do not overlap."""
        seam = self.elements[index]['in'] if incoming else self.elements[index]['out']
        if seam['kind'] in ('none', 'synthToSynth'):
            return self.side_ok(index, incoming)
        between, other = self.run(index if incoming else index + 1), index - 1 if incoming else index + 1
        fade = seam['fadeSamples']
        if not between:
            return False
        lo, hi = between[-1] if incoming else between[0]
        if hi - lo < (fade // 2 if incoming else fade - fade // 2):
            return False
        return not 0 <= other < len(self.elements) or self.fades_fit(min(index, other))


def place(project, clip_id, envelope, first_id, last_id):
    """`project` holds the take: sampleRate, durationSeconds, words (every transcript item, in order), edits and segments
    (the Voice Lab replacements already in the project). The window is placed for the render scope `clip_id` (None for the
    full take) exactly as VoiceLabOutputPlanner builds it, with the scope's enabled replacements."""
    rate, duration, items, edits = project['sampleRate'], project['durationSeconds'], project['words'], project['edits']
    # The take is media.source.durationSeconds long and ends at sample jsRound(duration x rate).
    if not (math.isfinite(rate) and rate > 0 and math.isfinite(duration) and duration > 0 and duration * rate < SAMPLE_LIMIT):
        raise GeometryError('invalidInput')
    total = samples(duration, rate)
    threshold, keep = edits['pauseThresholdSeconds'], edits['pauseKeepSeconds']
    if total <= 0 or not (math.isfinite(threshold) and threshold > 0 and math.isfinite(keep) and 0 <= keep <= 1):
        raise GeometryError('invalidInput')
    check_envelope(envelope, rate)
    check_items(items, rate)
    ids = [item['id'] for item in items]
    if first_id not in ids:
        raise GeometryError('unknownWord', wordId=first_id)
    if last_id not in ids:
        raise GeometryError('unknownWord', wordId=last_id)
    a, b = ids.index(first_id), ids.index(last_id)
    if a > b:
        raise GeometryError('reversedWords')
    bounds, clip_range = resolve_scope(items, edits, clip_id)
    scope = scope_replacements(project['segments'], clip_range, rate, duration)
    segments = edit_segments(items, edits, bounds)
    cut = {segment['id']: segment['cut'] for segment in segments if segment['kind'] == 'word'}
    kept_item = [not cut[item['id']] for item in items]
    # An item inside an enabled replacement is already re-voiced: it never bridges, and a take edge never absorbs it.
    replaced = [any(other['start'] <= item['start'] and item['end'] <= other['end'] for other in scope) for item in items]
    blocking = [kept or covered for kept, covered in zip(kept_item, replaced)]
    synth = [(other['lo'], other['hi']) for other in scope]
    # The outer half of each replacement's own fades, which a gap seam beside it must leave free.
    reserved = [(other['lo'] - other['in']['fadeSamples'] // 2, other['lo']) for other in scope] + \
               [(other['hi'], other['hi'] + other['out']['fadeSamples'] - other['out']['fadeSamples'] // 2) for other in scope]
    levels, size, count = envelope['levels'], frame_size(rate), len(items)
    min_gap, gap_fade, hard_fade = samples(SEAM_MIN_GAP, rate), samples(SEAM_FADE, rate), samples(HARD_SEAM_FADE, rate)

    def kept_source(passage=None, window=()):
        """Kept source pieces as the output plan builds them: the words and pauses inside every replacement and inside the
        `passage` (start, end), when given, are dropped, and neither the cuts nor the synth ranges (with `window`) are
        source."""
        dropped = [(other['start'], other['end']) for other in scope] + ([passage] if passage is not None else [])
        remaining = [segment for segment in segments if segment['kind'] not in ('word', 'pause')
                     or not any(segment['start'] >= lo and segment['end'] <= hi for lo, hi in dropped)]
        return subtract(edit_plan(remaining, duration, rate, keep)[1], synth + list(window))

    def before_end(index):
        """The latest end of the items before `index`: where the silence before item `index` begins."""
        return max((item['end'] for item in items[:index]), default=0.0)

    def after_start(index):
        """The earliest start of the items from `index` on: where the silence before item `index` ends."""
        return min((item['start'] for item in items[index:]), default=duration)

    def bridgeable(index):
        return 0 <= index < count and items[index]['kind'] == 'word' and kept_item[index] and not replaced[index]

    def gap(seam):
        return {'kind': 'gap', 'time': seam / rate, 'sample': seam, 'fadeSamples': gap_fade}

    def edge(sample, time):
        return {'kind': 'none', 'time': time, 'sample': sample, 'fadeSamples': 0}

    def hard(time):
        return {'kind': 'hard', 'time': time, 'sample': samples(time, rate), 'fadeSamples': hard_fade}

    # Take edges count kept and replaced items only: earlier or later cut items are absorbed into the window. In a clip
    # scope the window can reach a take edge only when the clip's kept range does.
    touches_start = clip_range is None or clip_range[0] <= 0
    touches_end = clip_range is None or clip_range[1] >= duration
    a_min, b_max = a, b
    while a - a_min < SEAM_SEARCH_WORDS and bridgeable(a_min - 1):
        a_min -= 1
    while b_max - b < SEAM_SEARCH_WORDS and bridgeable(b_max + 1):
        b_max += 1
    # Each search measures kept source against the widest window the other side could reach, because a cut's reach
    # depends on which items the window drops. The exact window is checked after placement.
    widest_end = duration if touches_end and not any(blocking[b_max + 1:]) else after_start(b_max + 1)
    widest_start = 0.0 if touches_start and not any(blocking[:a_min]) else before_end(a_min)

    left, first = None, a
    for bridge in range(SEAM_SEARCH_WORDS + 1):
        k = a - bridge
        if bridge > 0 and not bridgeable(k):
            break
        g0, g1 = samples(before_end(k), rate), samples(after_start(k), rate)
        if g1 - g0 < min_gap:
            continue
        seam = quietest_frame(levels, size, g0, g1, gap_fade, subtract(kept_source((after_start(k), widest_end)), reserved))
        if seam is not None:
            left, first = gap(seam), k
            break
    if left is None:
        start, end = after_start(a), before_end(a)
        # A replacement that ends in the silence before the passage keeps its own fade's outer half and this seam's: the
        # silence is measured from where both fit.
        for other in scope:
            if other['end'] <= start:
                out_fade = other['out']['fadeSamples']
                end = max(end, (other['hi'] + out_fade - out_fade // 2 + hard_fade // 2) / rate)
        # Overlapping items leave no silence: the reach is clamped at zero, as editing section 7.3 clamps a cut's reach.
        left = hard(start - min(HARD_SEAM_REACH, max(0.0, start - end) / 2))
    if touches_start and not any(blocking[:first]):
        left = edge(0, 0.0)

    right, last = None, b
    for bridge in range(SEAM_SEARCH_WORDS + 1):
        k = b + bridge
        if bridge > 0 and not bridgeable(k):
            break
        g0, g1 = samples(before_end(k + 1), rate), samples(after_start(k + 1), rate)
        if g1 - g0 < min_gap:
            continue
        seam = quietest_frame(levels, size, g0, g1, gap_fade, subtract(kept_source((widest_start, before_end(k + 1))), reserved))
        if seam is not None:
            right, last = gap(seam), k
            break
    if right is None:
        end, start = before_end(b + 1), after_start(b + 1)
        for other in scope:
            if other['start'] >= end:
                in_fade = other['in']['fadeSamples']
                start = min(start, (other['lo'] - in_fade // 2 - (hard_fade - hard_fade // 2)) / rate)
        right = hard(end + min(HARD_SEAM_REACH, max(0.0, start - end) / 2))
    if touches_end and not any(blocking[last + 1:]):
        right = edge(total, duration)

    start, end = left['time'], right['time']
    if right['sample'] <= left['sample']:
        raise GeometryError('invalidInput')
    overlapped = next((other for other in scope if other['start'] < end and start < other['end']), None)
    if overlapped is not None:
        raise GeometryError('overlapsReplacement', segmentId=overlapped['id'])
    for item in items:
        if item['start'] < start < item['end'] or item['start'] < end < item['end']:
            raise GeometryError('windowCrossesWord', wordId=item['id'])
    # The window holds the passage and its bridges. It absorbs cut items, events and unlabeled speech, but a kept word
    # that is neither a passage nor a bridge word would lose its speech.
    inside = [index for index, item in enumerate(items) if item['start'] >= start and item['end'] <= end]
    for index in range(first, last + 1):
        if index not in inside:
            raise GeometryError('windowCrossesWord', wordId=ids[index])
    for index in inside:
        if not first <= index <= last and items[index]['kind'] == 'word' and kept_item[index]:
            raise GeometryError('windowCrossesWord', wordId=ids[index])
    if left['kind'] == 'hard' and left['sample'] - hard_fade // 2 < 0:
        raise GeometryError('seamFadeOutsideTake')
    if right['kind'] == 'hard' and right['sample'] + hard_fade - hard_fade // 2 > total:
        raise GeometryError('seamFadeOutsideTake')

    # Section 10.5 on the pieces the output plan builds with the window as one more replacement: a seam with a fade needs
    # the fade's outer half in the kept source right beside it, and two replacements beside one kept piece need room for
    # both outer halves. Seam kinds follow prepare: `none` only with nothing beside it, synthToSynth only between two
    # touching replacements, which `place` never makes.
    window = {'id': None, 'lo': left['sample'], 'hi': right['sample'], 'in': left, 'out': right}
    layout = SeamLayout(sorted(scope + [window], key=lambda element: element['lo']),
                        kept_source((start, end), [(left['sample'], right['sample'])]), total)
    # The scope as it renders without the window. A replacement's check that already fails there is not the window's doing.
    alone = SeamLayout(scope, kept_source(), total)
    elements, w = layout.elements, layout.elements.index(window)

    def judge(index, incoming):
        """Raises unless replacement `index`'s seam on that side still renders beside the window. A check that holds without
        the window and fails with it is the window's doing. A check that already fails is judged by prepare's own rule, and
        when that fails without the window too, the scope was unrenderable before the window."""
        segment_id, before = elements[index]['id'], index - (index > w)
        if layout.side_ok(index, incoming):
            return
        if alone.side_ok(before, incoming):
            raise GeometryError('adjacentReplacement', segmentId=segment_id)
        if layout.prepare_ok(index, incoming):
            return
        raise GeometryError('adjacentReplacement' if alone.prepare_ok(before, incoming) else 'invalidInput', segmentId=segment_id)

    if w > 0:
        if not layout.run(w):
            raise GeometryError('adjacentReplacement', segmentId=elements[w - 1]['id'])
        judge(w - 1, False)
        if not layout.pair_ok(w - 1):
            raise GeometryError('adjacentReplacement', segmentId=elements[w - 1]['id'])
    if left['kind'] != 'none':
        needed, available = left['fadeSamples'] // 2, layout.beside(w, True)
        if available < needed:
            raise GeometryError('seamFadeCrossesCut', incoming=True, needed=needed, available=available)
    if w + 1 < len(elements):
        if not layout.run(w + 1):
            raise GeometryError('adjacentReplacement', segmentId=elements[w + 1]['id'])
        judge(w + 1, True)
        if not layout.pair_ok(w):
            raise GeometryError('adjacentReplacement', segmentId=elements[w + 1]['id'])
    if right['kind'] != 'none':
        needed, available = right['fadeSamples'] - right['fadeSamples'] // 2, layout.beside(w, False)
        if available < needed:
            raise GeometryError('seamFadeCrossesCut', incoming=False, needed=needed, available=available)
    # The validator's overlappingFades condition: the inner halves of both fades must fit inside the window.
    needed = left['fadeSamples'] - left['fadeSamples'] // 2 + right['fadeSamples'] // 2
    if needed > right['sample'] - left['sample']:
        raise GeometryError('windowTooShort', needed=needed, available=right['sample'] - left['sample'])
    # Dropping the window's items can lengthen a cut's reach past a replacement further away. Across one kept piece the
    # pair rule is prepare's own, so a pair that already breaks it leaves the scope unrenderable.
    for index, element in enumerate(elements):
        if index == w:
            continue
        judge(index, True)
        judge(index, False)
        if index + 1 not in (w, len(elements)) and not layout.pair_ok(index):
            code = 'adjacentReplacement' if alone.pair_ok(index - (index > w)) else 'invalidInput'
            raise GeometryError(code, segmentId=element['id'])
    return {'firstWordId': ids[inside[0]], 'lastWordId': ids[inside[-1]],
            'leftBridgeWordIds': ids[first:a], 'rightBridgeWordIds': ids[b + 1:last + 1],
            'start': start, 'end': end, 'startSample': left['sample'], 'endSample': right['sample'],
            'leftSeam': left, 'rightSeam': right}


# The validate and prepare model (section 15 test 3): every window `place` returns validates and prepares in its render
# scope, also beside the replacements the project already holds.
#
# render_failure is a model of the v3 validator's transcript, replace-range and seam rules (ProjectJSON.validate,
# VoiceLabProject.validate, VoiceLabRenderValidation) and of prepare's pieces and neighbour rules
# (VoiceLabOutputPlanner.build, VoiceLabRenderContract.validateSelectedSeams), for every replacement in the project. Each
# recipe uses its window's seams with unity fit. It shares only the editing model with `place`; the rest is written from
# the validator and prepare code.

def segment_failure(items, rate, duration, window):
    """VoiceLabProject.validate and VoiceLabRenderValidation for one segment whose recipe is built on `window`."""
    total, ids = samples(duration, rate), [item['id'] for item in items]
    start, end, left, right = window['start'], window['end'], window['leftSeam'], window['rightSeam']
    if not (start >= 0 and end > start and end <= duration):
        return 'invalidRange: bounds'
    first, last = ids.index(window['firstWordId']), ids.index(window['lastWordId'])
    inside = [index for index, item in enumerate(items) if item['start'] >= start and item['end'] <= end]
    if not (first <= last and items[first]['start'] >= start and items[last]['end'] <= end and inside
            and inside[0] == first and inside[-1] == last):
        return 'invalidRange: words'
    if any(item['start'] < start < item['end'] or item['start'] < end < item['end'] for item in items):
        return 'invalidRange: crossing'
    # The seams on the source grid.
    s, e = samples(start, rate), samples(end, rate)
    out = e - s
    if out <= 0 or s != left['sample'] or e != right['sample']:
        return 'invalidRange: samples'
    for seam, at_edge, incoming in ((left, s == 0, True), (right, e == total, False)):
        fade = seam['fadeSamples']
        if at_edge:
            if seam['kind'] != 'none' or fade != 0:
                return 'invalidFadeHandles: edge'
            continue
        if seam['kind'] not in ('gap', 'hard'):
            return 'missingRenderPolicy: seam kind'
        if fade != samples(HARD_SEAM_FADE if seam['kind'] == 'hard' else SEAM_FADE, rate) or fade < 2:
            return 'invalidFadeHandles: fade'
        needed = fade // 2 if incoming else fade - fade // 2
        if fade - needed > out:
            return 'invalidFadeHandles: source handle'
    if left['fadeSamples'] - left['fadeSamples'] // 2 + right['fadeSamples'] // 2 > out:
        return 'overlappingFades'
    return None


def render_failure(project, clip_id, window):
    """None when the take, holding its `segments` and a recipe built on `window` as one more enabled replacement, validates
    and prepares in its scope; otherwise the rule it breaks. With `window` None, the take as it stands."""
    rate, duration, items, edits = project['sampleRate'], project['durationSeconds'], project['words'], project['edits']
    total = samples(duration, rate)
    # ProjectJSON.validate, which prepare runs when it encodes the project.
    previous, seen = 0.0, set()
    for item in items:
        if not (math.isfinite(item['start']) and math.isfinite(item['end']) and previous <= item['start'] < item['end']) \
                or item['id'] in seen:
            return 'projectUnreadable: transcript'
        previous = item['start']
        seen.add(item['id'])
    segments = list(project['segments']) + ([{'id': 'new', 'enabled': True, 'window': window}] if window is not None else [])
    for segment in segments:
        failure = segment_failure(items, rate, duration, segment['window'])
        if failure is not None:
            return failure
    enabled = sorted((segment['window']['start'], segment['window']['end']) for segment in segments if segment['enabled'])
    if any(later[0] < earlier[1] for earlier, later in zip(enabled, enabled[1:])):
        return 'overlappingReplacement'
    # VoiceLabOutputPlanner.build: scope, dropped items, cuts trimmed at each synth range, pieces.
    bounds, clip_range = resolve_scope(items, edits, clip_id)
    scoped = [segment for segment in segments if segment['enabled'] and not (clip_range is not None and (
        segment['window']['end'] <= clip_range[0] or segment['window']['start'] >= clip_range[1]))]
    if clip_range is not None and any(segment['window']['start'] < clip_range[0] or segment['window']['end'] > clip_range[1]
                                      for segment in scoped):
        return 'invalidScope'
    if window is not None and not any(segment is segments[-1] for segment in scoped):
        return 'excluded from its scope'
    scoped.sort(key=lambda segment: segment['window']['start'])
    remaining = [segment for segment in edit_segments(items, edits, bounds) if segment['kind'] not in ('word', 'pause') or not any(
        segment['start'] >= other['window']['start'] and segment['end'] <= other['window']['end'] for other in scoped)]
    cuts = edit_plan(remaining, duration, rate, edits['pauseKeepSeconds'])[0]
    synth = [(samples(segment['window']['start'], rate), samples(segment['window']['end'], rate), segment) for segment in scoped]
    if any(hi <= lo for lo, hi, _ in synth):
        return 'invalidRange: synth'
    for lo, hi, _ in synth:
        clipped = []
        for cut_lo, cut_hi in cuts:
            if cut_hi <= lo or cut_lo >= hi:
                clipped.append((cut_lo, cut_hi))
                continue
            if cut_lo < lo:
                clipped.append((cut_lo, lo))
            if cut_hi > hi:
                clipped.append((hi, cut_hi))
        cuts = clipped
    kept, cursor = [], 0
    for lo, hi in cuts:
        if lo > cursor:
            kept.append((cursor, lo))
        cursor = hi
    if cursor < total:
        kept.append((cursor, total))
    pieces, output = [], 0
    for lo, hi in kept:
        position = lo
        for s, e, segment in synth:
            if e > position and s < hi:
                if not (s >= position and e <= hi):
                    return 'invalidRange: synth spans kept intervals'
                if s > position:
                    pieces.append({'kind': 'source', 'lo': position, 'hi': s, 'start': output, 'length': s - position})
                    output += s - position
                pieces.append({'kind': 'synth', 'lo': s, 'hi': e, 'start': output, 'length': e - s, 'window': segment['window']})
                output += e - s
                position = e
        if hi > position:
            pieces.append({'kind': 'source', 'lo': position, 'hi': hi, 'start': output, 'length': hi - position})
            output += hi - position
    # VoiceLabRenderContract.validateSelectedSeams.
    selected = [index for index, piece in enumerate(pieces) if piece['kind'] == 'synth']
    windows = []
    for index in selected:
        piece = pieces[index]
        before = pieces[index - 1] if index > 0 else None
        after = pieces[index + 1] if index + 1 < len(pieces) else None
        incoming, outgoing = piece['window']['leftSeam'], piece['window']['rightSeam']
        if before is None:
            if incoming['kind'] != 'none':
                return 'invalidFadeHandles: incoming neighbour'
        elif before['kind'] == 'synth':
            prior = before['window']['rightSeam']
            if not (before['hi'] == piece['lo'] and incoming['kind'] == prior['kind'] == 'synthToSynth'
                    and prior['fadeSamples'] == incoming['fadeSamples']):
                return 'invalidFadeHandles: touching replacements'
        elif incoming['kind'] in ('none', 'synthToSynth'):
            return 'invalidFadeHandles: incoming neighbour'
        if after is None:
            if outgoing['kind'] != 'none':
                return 'invalidFadeHandles: outgoing neighbour'
        elif after['kind'] == 'synth':
            following = after['window']['leftSeam']
            if not (piece['hi'] == after['lo'] and outgoing['kind'] == following['kind'] == 'synthToSynth'
                    and following['fadeSamples'] == outgoing['fadeSamples']):
                return 'invalidFadeHandles: touching replacements'
        elif outgoing['kind'] in ('none', 'synthToSynth'):
            return 'invalidFadeHandles: outgoing neighbour'
        centres = [(incoming, piece['start'])]
        if after is None or after['kind'] != 'synth':
            centres.append((outgoing, piece['start'] + piece['length']))
        for seam, centre in centres:
            if seam['kind'] != 'none':
                half = seam['fadeSamples'] // 2
                if centre < half or seam['fadeSamples'] - half > output - centre:
                    return 'invalidFadeHandles: fade outside output'
                windows.append((centre - half, centre + seam['fadeSamples'] - half))
    windows.sort()
    if any(later[0] < earlier[1] for earlier, later in zip(windows, windows[1:])):
        return 'overlappingFades: prepare'
    for index in selected:
        piece = pieces[index]
        incoming, outgoing = piece['window']['leftSeam'], piece['window']['rightSeam']
        if incoming['kind'] != 'none' and (pieces[index - 1]['length'] < incoming['fadeSamples'] // 2
                                           or piece['length'] < incoming['fadeSamples'] - incoming['fadeSamples'] // 2):
            return 'invalidFadeHandles: incoming pieces'
        if outgoing['kind'] != 'none' and (piece['length'] < outgoing['fadeSamples'] // 2
                                           or pieces[index + 1]['length'] < outgoing['fadeSamples'] - outgoing['fadeSamples'] // 2):
            return 'invalidFadeHandles: outgoing pieces'
    return None


# Decision 3: minimum handles (section 10.5), exactly the validator's arithmetic.

def ulp(value):
    return math.nextafter(value, math.inf) - value


def minimum_handles(fade, incoming, asset_rate, source_rate, stretch):
    if not 0 <= fade < SAMPLE_LIMIT or asset_rate <= 0 or not (math.isfinite(source_rate) and source_rate > 0) or \
            not (math.isfinite(stretch) and stretch > 0):
        raise GeometryError('invalidInput')
    needed = fade // 2 if incoming else fade - fade // 2
    raw = needed * asset_rate / (source_rate * stretch)
    if not (math.isfinite(raw) and raw < SAMPLE_LIMIT):
        raise GeometryError('invalidInput')
    nearest = math.floor(raw + 0.5)
    frames = nearest if abs(raw - nearest) <= 4 * ulp(raw) else math.ceil(raw)
    return raw, frames, fade - needed


def handle_seam(kind, fade, incoming, asset_rate, source_rate, stretch):
    if kind == 'none':
        return {'kind': 'none', 'fadeSamples': 0, 'sourceHandleSamples': 0, 'assetHandleFrames': 0}
    _, frames, source = minimum_handles(fade, incoming, asset_rate, source_rate, stretch)
    return {'kind': kind, 'fadeSamples': fade, 'sourceHandleSamples': 0 if kind == 'synthToSynth' else source,
            'assetHandleFrames': frames}


def check_trim(seams, trim_start, trim_end, duration, asset_rate):
    if not (math.isfinite(trim_start) and math.isfinite(trim_end) and math.isfinite(duration) and 0 <= trim_start < trim_end <= duration
            and asset_rate > 0 and duration * asset_rate < SAMPLE_LIMIT):
        raise GeometryError('invalidInput')
    before = samples(trim_start, asset_rate)
    after = samples(duration - trim_end, asset_rate)
    if seams['in']['assetHandleFrames'] > before:
        raise GeometryError('insufficientHandle', incoming=True, needed=seams['in']['assetHandleFrames'], available=before)
    if seams['out']['assetHandleFrames'] > after:
        raise GeometryError('insufficientHandle', incoming=False, needed=seams['out']['assetHandleFrames'], available=after)


# Decision 4: character alignment to words (section 8.8).

def normalize_for_match(text):
    out = []
    for scalar in text:
        lower = 'i' if scalar == '\u0130' else scalar.lower()
        out.extend(d for d in lower if unicodedata.category(d)[0] in 'LN')
    return ''.join(out)


def is_white_space(element):
    return element != '' and all(ord(scalar) in WHITE_SPACE for scalar in element)


def split_white_space(text):
    tokens, current = [], ''
    for scalar in text:
        if ord(scalar) in WHITE_SPACE:
            if current:
                tokens.append(current)
            current = ''
        else:
            current += scalar
    if current:
        tokens.append(current)
    return tokens


def is_noncharacter(value):
    return 0xFDD0 <= value <= 0xFDEF or value & 0xFFFE == 0xFFFE


def alignment_words(characters, starts, ends, expected):
    if characters is None or starts is None or ends is None or not characters or \
            len(characters) != len(starts) or len(starts) != len(ends) or '' in characters:
        raise GeometryError('alignmentUnavailable')
    words, buf, s, e = [], '', None, 0.0
    for i, ch in enumerate(characters):
        if is_white_space(ch):
            if s is not None and buf != '':
                words.append({'text': buf, 'start': s, 'end': e, 'synthetic': True})
            buf, s = '', None
        else:
            if s is None:
                s = starts[i]
            buf += ch
            e = ends[i]
    if s is not None and buf != '':
        words.append({'text': buf, 'start': s, 'end': e, 'synthetic': True})

    def folded(token):
        # normalize_for_match is defined on NFC text; the provider and the user may send either form. A noncharacter
        # makes the alignment mismatch on every platform, and so does a lone surrogate where a string can hold one.
        if any(is_noncharacter(ord(scalar)) or 0xD800 <= ord(scalar) <= 0xDFFF for scalar in token):
            raise GeometryError('alignmentMismatch')
        return normalize_for_match(unicodedata.normalize('NFC', token))

    if [folded(w['text']) for w in words] != [folded(t) for t in split_white_space(expected)]:
        raise GeometryError('alignmentMismatch')
    if not words:
        raise GeometryError('alignmentUnavailable')
    return words


# Decision 5: TTS trim and relative word times (section 8.7 item 1, section 8.8 step 3).

def trim_words(words, duration):
    if not (math.isfinite(duration) and duration > 0):
        raise GeometryError('invalidInput')
    if not words:
        raise GeometryError('alignmentUnavailable')
    first, last = words[0]['start'], words[-1]['end']
    if not (math.isfinite(first) and math.isfinite(last)):
        raise GeometryError('invalidWordTiming')
    start, end = max(0.0, first - TTS_TRIM_LEAD), min(duration, last + TTS_TRIM_TAIL)
    if not end > start:
        raise GeometryError('invalidWordTiming')
    return {'start': start, 'end': end}


def trim_envelope(envelope, duration):
    rate, levels = envelope['sampleRate'], envelope['levels']
    if not (math.isfinite(duration) and duration > 0 and math.isfinite(rate) and rate > 0) or \
            any(not math.isfinite(v) or v < 0 for v in levels):
        raise GeometryError('invalidInput')
    voiced = [i for i, level in enumerate(levels) if float(level) > VOICED_FRAME_LEVEL]
    if not voiced:
        raise GeometryError('noVoicedAudio')
    size = frame_size(rate)
    # The voiced span gets the aligned lead and tail, clamped to the asset.
    start = max(0.0, voiced[0] * size / rate - TTS_TRIM_LEAD)
    end = min(duration, (voiced[-1] + 1) * size / rate + TTS_TRIM_TAIL)
    if not end > start:
        raise GeometryError('invalidInput')
    return {'start': start, 'end': end}


def relative_words(words, trim_start, stretch, out_duration, rate):
    if not (math.isfinite(trim_start) and math.isfinite(stretch) and stretch > 0 and math.isfinite(out_duration)
            and out_duration > 0 and math.isfinite(rate) and rate > 0 and out_duration * rate < SAMPLE_LIMIT):
        raise GeometryError('invalidInput')
    if not words:
        raise GeometryError('alignmentUnavailable')
    out, cursor = [], 0.0
    for word in words:
        start, end = (word['start'] - trim_start) * stretch, (word['end'] - trim_start) * stretch
        if word['text'] == '' or not (math.isfinite(start) and math.isfinite(end)) or start < cursor or \
                not end > start or end > out_duration or not samples(end, rate) > samples(start, rate) or \
                samples(end, rate) > samples(out_duration, rate):
            raise GeometryError('invalidWordTiming')
        out.append({'text': word['text'], 'start': start, 'end': end, 'synthetic': True})
        cursor = end
    return out


# Decision 6: room tone (section 8.7 item 3).

def room_tone(items, envelope, rate, total):
    if not (math.isfinite(rate) and rate > 0 and 0 < total < SAMPLE_LIMIT):
        raise GeometryError('invalidInput')
    check_envelope(envelope, rate)
    check_items(items, rate)
    levels, size, length = envelope['levels'], frame_size(rate), samples(ROOM_TONE_MIN_RUN, rate)
    bounds = sorted(((samples(i['start'], rate), samples(i['end'], rate)) for i in items), key=lambda pair: pair[0])
    gaps, cursor = [], 0
    for start, end in bounds:
        if min(start, total) > cursor:
            gaps.append((cursor, min(start, total)))
        cursor = max(cursor, end)
    if total > cursor:
        gaps.append((cursor, total))
    best = None
    for g0, g1 in gaps:
        if g1 - g0 < length:
            continue
        for index in range((g0 + size - 1) // size, len(levels) - ROOM_TONE_FRAMES + 1):
            begin = index * size
            if max(begin + ROOM_TONE_FRAMES * size, begin + length) > g1:
                break
            power = 0.0
            for frame in range(index, index + ROOM_TONE_FRAMES):
                value = float(levels[frame])
                power += value * value
            if best is None or power < best[0]:
                best = (power, begin)
    if best is None:
        # No fallback run: the UI offers Clean audio instead.
        raise GeometryError('roomToneUnavailable')
    return {'sourceStartSample': best[1], 'sourceEndSample': best[1] + length, 'gainDb': 0.0}


# Synthetic inputs.

SPEECH = 0.25
ROOM = 0.0078125
QUIET = 0.0009765625
QUIETER = 0.00048828125


def word(id_, start, end, kind='word', text=None):
    return {'id': id_, 'text': text or id_, 'kind': kind, 'start': start, 'end': end}


def envelope_levels(items, rate, duration_frames, overrides=(), base=ROOM, speech=SPEECH):
    """Speech in every frame [i*F, (i+1)*F) that an item's sample span meets, room level elsewhere."""
    size = frame_size(rate)
    levels = [base] * duration_frames
    for item in items:
        lo, hi = samples(item['start'], rate), samples(item['end'], rate)
        for index in range(max(0, lo // size - 1), min(duration_frames, hi // size + 2)):
            if lo < (index + 1) * size and hi > index * size:
                levels[index] = speech
    for index, level in dict(overrides).items():
        levels[index] = level
    return levels


def runs(levels):
    out = []
    for level in levels:
        if out and out[-1][0] == level:
            out[-1][1] += 1
        else:
            out.append([level, 1])
    return out


def run_case(fn, *args):
    try:
        return fn(*args)
    except GeometryError as error:
        return error.value


def words_result(fn, *args):
    try:
        return {'words': fn(*args)}
    except GeometryError as error:
        return error.value


def place_insertion(*_):
    raise GeometryError('insertionUnsupported')


def take_input(rate, duration, items, edits, clip_id, envelope, segments=()):
    """A take as the window vectors carry it: what VoiceLabOutputPlanner reads, the replacements already in the project,
    the render scope and the envelope as runs. A replacement is {'id', 'enabled', 'window'}: the native suites build its
    recipe from `window` with the vector's room tone."""
    return {'sampleRate': rate, 'durationSeconds': duration, 'words': items, 'edits': edits, 'segments': list(segments),
            'clipId': clip_id, 'envelope': {'sampleRate': envelope['sampleRate'], 'runs': runs(envelope['levels'])}}


def passage_room_tone(expected, items, envelope, rate, duration):
    """The room tone a passage recipe for an accepted window takes from the same take, or None. The native suites select it,
    compare it, and validate and prepare a recipe with it."""
    if 'error' in expected:
        return None
    tone = run_case(room_tone, items, envelope, rate, samples(duration, rate))
    return None if 'error' in tone else tone


def window_case(name, items, duration, overrides=(), cut=(), first=None, last=None, rate=48000, after=None, envelope_rate=None,
                clip=None, clips=(), cut_pauses=(), threshold=0.8, keep=0.15, replacements=(), later_cut=(), later_cut_pauses=(),
                later_enabled=()):
    """A take with its edits and a render scope: `clip` names one of `clips` (id, first word, last word), or None for full.
    `replacements` (first word, last word, enabled, clip) are placed first, in order, by `place` itself in their own scope,
    and must each validate and prepare there. The `later_` edits come after they were accepted: more cut words and pauses,
    and replacements enabled again."""
    levels = envelope_levels(items, rate, samples(duration, rate) // frame_size(rate), overrides)
    envelope = {'sampleRate': envelope_rate or rate, 'levels': levels}
    edits = {'cutWordIds': list(cut), 'cutPauseIds': list(cut_pauses), 'pauseThresholdSeconds': threshold, 'pauseKeepSeconds': keep,
             'clips': [{'id': id_, 'startWordId': lo, 'endWordId': hi} for id_, lo, hi in clips]}
    project = {'sampleRate': float(rate), 'durationSeconds': duration, 'words': items, 'edits': edits, 'segments': []}
    for number, (lo, hi, enabled, scope) in enumerate(replacements, 1):
        placed = place(project, scope, envelope, lo, hi)
        assert render_failure(project, scope, placed) is None, (name, number)
        project['segments'].append({'id': 'r%d' % number, 'enabled': enabled, 'window': placed})
    edits['cutWordIds'] += later_cut
    edits['cutPauseIds'] += later_cut_pauses
    for segment in project['segments']:
        segment['enabled'] = segment['enabled'] or segment['id'] in later_enabled
    case = {'name': name, 'input': take_input(rate, duration, items, edits, clip, envelope, project['segments'])}
    if after is not None:
        case['input']['afterWordId'] = after
        case['expected'] = run_case(place_insertion, project, clip, envelope, after)
    else:
        case['input'].update(firstWordId=first, lastWordId=last)
        case['expected'] = run_case(place, project, clip, envelope, first, last)
    case['roomTone'] = passage_room_tone(case['expected'], items, envelope, rate, duration)
    if replacements:
        # Each replacement's recipe takes the take's room tone, whether or not this window is accepted.
        case['roomTone'] = run_case(room_tone, items, envelope, rate, samples(duration, rate))
        assert 'error' not in case['roomTone'], name
    return case


def gaps_words(spec):
    return [word(f'w{index + 1}', start, end) for index, (start, end) in enumerate(spec)]


window = []
s15_a = gaps_words([(0.20, 0.50), (0.70, 0.90), (0.95, 1.05), (1.10, 1.40), (1.45, 1.80), (1.85, 1.95), (2.00, 2.40), (2.60, 3.00)])
window.append(window_case('s15-gap-two-words-left', s15_a, 3.3, {63: QUIET, 252: QUIET}, first='w4', last='w5'))
s15_b = gaps_words([(0.20, 0.50), (0.55, 0.80), (0.85, 1.10), (1.15, 1.40), (1.50, 1.80), (1.85, 2.10), (2.14, 2.40),
                    (2.45, 2.70), (2.75, 3.00), (3.05, 3.40)])
window.append(window_case('s15-hard-no-gap-within-three', s15_b, 3.6, first='w5', last='w6'))
exact = gaps_words([(0.20, 0.60), (0.72, 1.00), (1.05, 1.30), (1.50, 1.80)])
window.append(window_case('gap-exactly-min', exact, 2.0, {60: QUIET, 140: QUIET}, first='w2', last='w3'))
below = gaps_words([(0.05, 0.60), (34559 / 48000, 1.00), (1.05, 1.30), (1.50, 1.80)])
window.append(window_case('gap-one-sample-below-min', below, 2.0, {139: QUIET}, first='w2', last='w2'))
three = gaps_words([(0.20, 0.50), (0.70, 0.90), (0.95, 1.10), (1.15, 1.30), (1.35, 1.60), (1.65, 1.90), (2.10, 2.40)])
window.append(window_case('gap-three-words-away', three, 2.6, {55: QUIET, 200: QUIET}, first='w5', last='w6'))
four = gaps_words([(0.20, 0.50), (0.70, 0.85), (0.90, 1.05), (1.10, 1.25), (1.30, 1.45), (1.50, 1.75), (1.80, 2.00), (2.20, 2.50)])
window.append(window_case('gap-four-words-away', four, 2.7, {55: QUIET, 210: QUIET}, first='w6', last='w7'))
blocked = gaps_words([(0.20, 0.50), (0.70, 0.95), (1.00, 1.30), (1.35, 1.60), (1.80, 2.10)])
window.append(window_case('cut-word-blocks-left', blocked, 2.3, {55: QUIET, 170: QUIET}, cut=['w2'], first='w3', last='w4'))
event = [word('w1', 0.20, 0.50), word('w2', 0.70, 1.00), word('e1', 1.05, 1.30, 'event', '(laughs)'), word('w3', 1.50, 1.80)]
window.append(window_case('event-blocks-right', event, 2.0, {58: QUIET, 140: QUIET}, first='w2', last='w2'))
unlabeled = [word('w1', 0.20, 0.50), word('u1', 0.70, 0.90, 'unlabeledSpeech', '\u2026'), word('w2', 0.95, 1.20),
             word('w3', 1.40, 1.70)]
window.append(window_case('unlabeled-speech-blocks-left', unlabeled, 1.9, {60: QUIET, 130: QUIET}, first='w2', last='w2'))
at_start = gaps_words([(0.00, 0.30), (0.35, 0.60), (0.80, 1.10)])
window.append(window_case('first-word-at-take-start', at_start, 1.3, {70: QUIET}, first='w1', last='w2'))
at_end = gaps_words([(0.20, 0.50), (0.70, 1.00), (1.05, 1.30)])
window.append(window_case('last-word-at-take-end', at_end, 1.3, {60: QUIET}, first='w2', last='w3'))
silences = gaps_words([(0.40, 0.70), (0.75, 1.00), (1.05, 1.50)])
window.append(window_case('leading-and-trailing-silence', silences, 2.0, {12: QUIET, 180: QUIET}, first='w1', last='w3'))
window.append(window_case('take-edge-fade-excludes-frame', silences, 2.0, {0: QUIETER, 7: QUIET, 199: QUIETER, 191: QUIET},
                          first='w1', last='w3'))
window.append(window_case('envelope-tie', s15_a, 3.3, {52: QUIET, 66: QUIET, 249: QUIET, 250: QUIET}, first='w4', last='w5'))
odd = gaps_words([(0.05, 0.60), (0.65, 1.30), (1.35, 1.60), (1.65, 1.90)])
window.append(window_case('odd-frame-44100', odd, 2.2, {205: QUIET}, first='w2', last='w3', rate=44100))
window.append(window_case('odd-frame-gap-seam-44100', odd + [word('w5', 2.30, 2.50)], 2.6, {205: QUIET}, first='w2', last='w3',
                          rate=44100))
window.append(window_case('insertion-unsupported', s15_a, 3.3, after='w4'))
window.append(window_case('unknown-word', s15_a, 3.3, first='w4', last='w99'))
window.append(window_case('reversed-words', s15_a, 3.3, first='w5', last='w4'))
overlap = gaps_words([(0.05, 0.62), (0.60, 0.90), (1.10, 1.40)])
window.append(window_case('window-crosses-word', overlap, 1.6, first='w2', last='w2'))
nested_passage = [word('w1', 0.20, 0.50), word('e1', 1.00, 1.40, 'event', '(laughs)'), word('e2', 1.10, 1.30, 'event', '(laughs)'),
                  word('e3', 1.10, 1.20, 'event', '(laughs)'), word('w2', 1.80, 2.00)]
window.append(window_case('passage-nested-in-cut-event', nested_passage, 2.4, cut=['e1'], first='e2', last='e2'))
near = gaps_words([(0.004, 0.30), (0.50, 0.80)])
window.append(window_case('hard-fade-extends-to-take-start', near, 1.0, {40: QUIET}, first='w1', last='w1'))
near_end = gaps_words([(0.20, 0.50), (0.70, 0.995)])
window.append(window_case('hard-fade-extends-to-take-end', near_end, 1.0, {60: QUIET}, first='w2', last='w2'))
window.append(window_case('hard-fade-outside-take-start', [word('e0', 0.0, 0.002, 'event', '(breath)')] + near, 1.0, {40: QUIET},
                          first='w1', last='w1'))
window.append(window_case('hard-fade-outside-take-end', near_end + [word('e1', 0.998, 1.0, 'event', '(breath)')], 1.0, {60: QUIET},
                          first='w2', last='w2'))
window.append(window_case('envelope-rate-mismatch', s15_a, 3.3, first='w4', last='w5', envelope_rate=44100))
# Connected speech four words deep on each side: both seams are hard at the passage word's edges, and the window must hold
# the inner halves of both fades.
for name, end in (('window-exactly-holds-both-fades', 0.612), ('window-too-short', 0.611)):
    spec = [(0.20, 0.30), (0.30, 0.40), (0.40, 0.50), (0.50, 0.60), (0.60, end), (end, 0.70), (0.70, 0.80), (0.80, 0.90), (0.90, 1.00)]
    window.append(window_case(name, gaps_words(spec), 1.2, first='w5', last='w5'))

# A take whose duration is off the sample grid ends at durationSeconds, not at totalSamples / rate.
d_down, d_up = 1235 / 600, 1237 / 600
d_ffmpeg = next(n * (1 / 48000) for n in range(100000, 101000) if n * (1 / 48000) < n / 48000)
window.append(window_case('take-end-rounds-down-44100', gaps_words([(0.20, 0.60), (0.90, d_down)]), d_down, {75: QUIET},
                          first='w2', last='w2', rate=44100))
window.append(window_case('take-end-rounds-up-44100', gaps_words([(0.20, 0.60), (0.90, d_up)]), d_up, {75: QUIET},
                          first='w2', last='w2', rate=44100))
window.append(window_case('take-end-ffmpeg-duration-48000', gaps_words([(0.20, 0.60), (0.90, d_ffmpeg)]), d_ffmpeg, {75: QUIET},
                          first='w2', last='w2'))
window.append(window_case('whole-take-44100', gaps_words([(0.00, 0.60), (0.90, d_up)]), d_up, first='w1', last='w2', rate=44100))
window.append(window_case('first-word-rounds-to-take-start', gaps_words([(0.000004, 0.30), (0.50, 0.80)]), 1.0, {40: QUIET},
                          first='w1', last='w1'))
window.append(window_case('take-end-extension-off-grid-44100', gaps_words([(0.20, 0.60), (0.90, d_up - 0.003)]), d_up, {75: QUIET},
                          first='w2', last='w2', rate=44100))

# A cut neighbour reaches min(0.1, gap / 2) into the gap (editing section 7.3), measured to the next item the window does not
# replace; a gap frame whose fade would enter that reach is not a candidate.
cut_near = gaps_words([(0.20, 0.50), (0.70, 1.00), (1.40, 1.70), (2.00, 2.30)])
window.append(window_case('cut-reach-excludes-quietest-frame', cut_near, 2.6, {105: QUIETER, 125: QUIET, 185: QUIET}, cut=['w2'],
                          first='w3', last='w3'))
window.append(window_case('cut-reach-fade-boundary', gaps_words([(0.20, 0.50), (0.70, 0.995), (1.40, 1.70), (2.00, 2.30)]), 2.6,
                          {109: QUIETER, 110: QUIET, 185: QUIET}, cut=['w2'], first='w3', last='w3'))
window.append(window_case('cut-reach-to-next-kept-item', gaps_words([(0.20, 0.50), (0.70, 1.00), (1.15, 1.45), (1.80, 2.10)]), 2.4,
                          {109: QUIETER, 113: QUIET, 160: QUIET}, cut=['w2'], first='w3', last='w3'))
window.append(window_case('cut-reach-right', gaps_words([(0.20, 0.50), (0.90, 1.20), (1.60, 1.90), (2.20, 2.40)]), 2.7,
                          {70: QUIET, 155: QUIETER, 140: QUIET}, cut=['w3'], first='w2', last='w2'))
# Each search measures a cut's reach against the widest window the other side could reach: a bridge, or a cut item the take
# edge absorbs. Here the passage is a 20 ms word, so whether the other side drops the next item decides the reach.
window.append(window_case('cut-reach-beyond-right-bridge', gaps_words([(0.20, 0.50), (0.70, 1.00), (1.13, 1.15), (1.16, 1.30),
                                                                      (1.80, 2.00)]), 2.4, {109: QUIETER, 111: QUIET}, cut=['w2'],
                          first='w3', last='w3'))
window.append(window_case('cut-reach-beyond-left-bridge', gaps_words([(0.40, 0.60), (1.10, 1.24), (1.25, 1.27), (1.40, 1.70),
                                                                     (1.90, 2.20)]), 2.4, {130: QUIETER, 128: QUIET}, cut=['w4'],
                          first='w3', last='w3'))
window.append(window_case('cut-reach-beyond-absorbed-end', gaps_words([(0.20, 0.50), (0.70, 1.00), (1.13, 1.15), (1.16, 1.30)]), 1.6,
                          {109: QUIETER, 111: QUIET}, cut=['w2', 'w4'], first='w3', last='w3'))
window.append(window_case('cut-reach-beyond-absorbed-start', gaps_words([(0.30, 0.44), (0.45, 0.47), (0.60, 0.90), (1.10, 1.40)]), 1.6,
                          {50: QUIETER, 48: QUIET}, cut=['w1', 'w3'], first='w2', last='w2'))
window.append(window_case('cut-hard-seam-inside-reach', gaps_words([(0.02, 0.10), (0.20, 0.50), (0.60, 0.90), (1.40, 1.70)]), 2.0,
                          {115: QUIET}, cut=['w2'], first='w3', last='w3'))
window.append(window_case('cut-hard-seam-sliver', gaps_words([(0.02, 0.10), (0.20, 0.50), (0.60, 0.61), (0.635, 0.90)]), 0.95,
                          cut=['w2'], first='w3', last='w3'))
window.append(window_case('cut-word-after-leading-silence', gaps_words([(0.20, 0.50), (0.60, 0.90), (1.40, 1.70)]), 2.0, {115: QUIET},
                          cut=['w1'], first='w2', last='w2'))

# Kept source comes from the editing plan itself, so nested items, cut pauses and a clip's head and tail count too.
# The cut filler cases were round 2's failures, a hard seam inside a cut's reach with no kept source before it; the window
# now absorbs the filler and runs to the take edge.
filler = gaps_words([(0.00, 0.25), (0.28, 0.60), (1.00, 1.30)])
window.append(window_case('cut-filler-at-take-start', filler, 1.6, {80: QUIET}, cut=['w1'], first='w2', last='w2'))
window.append(window_case('cut-filler-near-take-start-44100', gaps_words([(0.004, 0.25), (0.28, 0.60), (1.00, 1.30)]), 1.6,
                          {80: QUIET}, cut=['w1'], first='w2', last='w2', rate=44100))
window.append(window_case('two-cut-words-at-take-start', gaps_words([(0.00, 0.12), (0.12, 0.25), (0.28, 0.60), (1.00, 1.30)]), 1.6,
                          {80: QUIET}, cut=['w1', 'w2'], first='w3', last='w3'))
window.append(window_case('cut-word-at-take-end', gaps_words([(0.20, 0.50), (0.90, 1.20), (1.23, 1.50)]), 1.5, {70: QUIET},
                          cut=['w3'], first='w2', last='w2'))
nested = [word('w1', 0.20, 0.50), word('w2', 0.70, 1.00), word('w3', 1.10, 1.50), word('e1', 1.15, 1.30, 'event', '(laughs)'),
          word('w4', 2.60, 2.75), word('w5', 2.80, 3.10), word('w6', 3.50, 3.80)]
window.append(window_case('nested-event-in-cut-word', nested, 4.2, {150: QUIETER, 151: QUIET, 330: QUIET}, cut=['w3'],
                          first='w4', last='w5'))
paused = gaps_words([(0.20, 0.50), (1.50, 1.80), (2.00, 2.30)])
window.append(window_case('cut-pause-beside-window', paused, 2.6, {100: QUIETER, 140: QUIET}, cut_pauses=['pause-after-w1'],
                          first='w2', last='w2'))
paused_event = paused[:2] + [word('e1', 2.00, 2.30, 'event', '(laughs)')]
window.append(window_case('cut-pause-keeps-breath', paused_event, 2.6, {100: QUIETER, 140: QUIET}, cut_pauses=['pause-after-w1'],
                          first='w2', last='w2'))
clipped = gaps_words([(0.20, 0.50), (0.90, 1.20), (1.25, 1.50), (2.00, 2.30)])
clip_c1 = [('c1', 'w2', 'w3')]
window.append(window_case('clip-start-limits-gap-seam', clipped, 2.6, {70: QUIETER, 85: QUIET, 180: QUIET}, clips=clip_c1, clip='c1',
                          first='w2', last='w3'))
window.append(window_case('clip-take-in-full-scope', clipped, 2.6, {70: QUIETER, 85: QUIET, 180: QUIET}, clips=clip_c1,
                          first='w2', last='w3'))
window.append(window_case('passage-outside-clip', clipped, 2.6, {70: QUIETER, 85: QUIET, 180: QUIET}, clips=clip_c1, clip='c1',
                          first='w4', last='w4'))
window.append(window_case('clip-starts-at-hard-seam', gaps_words([(0.20, 0.50), (0.50, 0.80), (0.82, 1.10), (1.50, 1.80)]), 2.0,
                          {100: QUIET}, clips=clip_c1, clip='c1', first='w2', last='w2'))
window.append(window_case('clip-touching-take-start', gaps_words([(0.05, 0.30), (0.32, 0.60), (1.00, 1.30)]), 1.6, {80: QUIET},
                          clips=[('c1', 'w1', 'w2')], clip='c1', first='w1', last='w1'))
window.append(window_case('clip-start-rounds-to-take-start', gaps_words([(0.120005, 0.40), (0.45, 0.80), (1.20, 1.50)]), 1.8,
                          {0: QUIETER, 5: QUIET, 90: QUIET}, clips=[('c1', 'w1', 'w2')], clip='c1', first='w1', last='w1'))


# Round 4: the half-fade rules at rates where floor(N/2) and ceil(N/2) differ. At 22.05 kHz the frame is 221 samples and the
# gap fade 441 (220 + 221): a candidate's fade reaches 220 samples back from its seam and 221 forward, and the cut edge sits
# exactly there or one sample closer.
for name, edge in (('gap-fade-back-half-fits-22050', 50 * 221 + 111 - 220), ('gap-fade-back-half-short-22050', 50 * 221 + 111 - 219)):
    window.append(window_case(name, [word('w0', 0.02, 0.10), word('w1', 0.20, edge / 22050 - 0.1), word('w2', 1.20, 1.50),
                                     word('w3', 2.00, 2.30)], 2.6, {50: QUIETER, 60: QUIET}, cut=['w1'], first='w2', last='w2',
                              rate=22050))
for name, edge in (('gap-fade-forward-half-fits-22050', 140 * 221 + 111 + 221),
                   ('gap-fade-forward-half-short-22050', 140 * 221 + 111 + 220)):
    window.append(window_case(name, [word('w1', 0.20, 0.50), word('w2', 1.00, 1.30), word('w3', edge / 22050 + 0.1, edge / 22050 + 0.3),
                                     word('w4', 2.10, 2.40)], 3.2, {140: QUIETER, 133: QUIET}, cut=['w3'], first='w2', last='w2',
                              rate=22050))
# At 44.1 kHz the hard fade is 529 samples: an outgoing hard seam needs ceil(529 / 2) = 265 samples before the take end.
for name, seam in (('hard-fade-ends-at-take-end-44100', 44100 - 265), ('hard-fade-one-sample-past-take-end-44100', 44100 - 264)):
    middle = seam / 44100
    window.append(window_case(name, [word('w1', 0.05, 0.10), word('w2', 0.75, middle - 0.002),
                                     word('e1', middle + 0.002, 0.999, 'event', '(breath)')], 1.0, first='w2', last='w2', rate=44100))
# The window must hold ceil(Nin / 2) + floor(Nout / 2): 265 + 441 = 706 for a hard incoming and gap outgoing seam, but
# 441 + 264 = 705 the other way round.
window.append(window_case('window-too-short-hard-in-gap-out-44100',
                          [word('w1', 0.20, 0.50), word('e1', 0.80, 43616 / 44100, 'event', '(breath)'), word('w2', 43616 / 44100, 1.0),
                           word('w3', 1.30, 1.60)], 1.9, {100: QUIETER}, first='w2', last='w2', rate=44100))
for name, end in (('window-holds-gap-in-hard-out-44100', 45026), ('window-too-short-gap-in-hard-out-44100', 45025)):
    window.append(window_case(name, [word('w1', 0.20, 0.50), word('w2', 44541 / 44100, end / 44100),
                                     word('e1', end / 44100, 1.30, 'event', '(breath)'), word('w3', 1.60, 1.90)], 2.2, {100: QUIETER},
                              first='w2', last='w2', rate=44100))

# Section 8.4 step 4: the window absorbs an event that starts with the passage (the left hard seam's reach is clamped at zero
# beside the overlapping event) or lies inside its last word, but not a kept word outside the passage and its bridges.
window.append(window_case('left-clamp-absorbs-simultaneous-event', [word('w0', 0.20, 0.40), word('e0', 0.60, 0.70, 'event', '(laughs)'),
                                                                    word('w1', 0.60, 0.90), word('w2', 1.30, 1.60)], 2.4,
                          first='w1', last='w1'))
window.append(window_case('nested-event-absorbed-at-window-end', [word('w1', 0.20, 0.50), word('w2', 1.00, 1.50),
                                                                  word('e1', 1.20, 1.30, 'event', '(laughs)'), word('w3', 2.00, 2.30)], 2.8,
                          first='w2', last='w2'))
window.append(window_case('kept-word-inside-window', [word('e0', 0.20, 0.55, 'event', '(laughs)'), word('x1', 0.60, 0.70),
                                                      word('w1', 0.60, 0.90), word('w2', 1.30, 1.60)], 2.0, first='w1', last='w1'))
# The project transcript rule.
window.append(window_case('transcript-starts-out-of-order', gaps_words([(0.20, 0.50), (0.70, 0.90), (0.65, 1.20)]), 1.6,
                          first='w1', last='w1'))
window.append(window_case('transcript-zero-length-item', gaps_words([(0.20, 0.50), (0.70, 0.70), (1.00, 1.20)]), 1.6,
                          first='w1', last='w1'))

# Replacements already in the project (section 8.4): each is placed first by `place` itself, and the native suites build
# its recipe from that window. The scope selects them exactly as VoiceLabOutputPlanner.build does.
sentences = gaps_words([(0.20, 0.50), (0.80, 1.10), (1.40, 1.70), (2.00, 2.30)])
window.append(window_case('replacement-next-word', sentences, 3.2, first='w3', last='w3', replacements=[('w2', 'w2', True, None)]))
window.append(window_case('replacement-disabled', sentences, 3.2, first='w3', last='w3', replacements=[('w2', 'w2', False, None)]))
window.append(window_case('replacement-same-passage', sentences, 3.2, first='w2', last='w2', replacements=[('w2', 'w2', True, None)]))
sentence_clip = [('c1', 'w3', 'w4')]
window.append(window_case('replacement-outside-clip', sentences, 3.2, clips=sentence_clip, clip='c1', first='w3', last='w3',
                          replacements=[('w1', 'w1', True, None)]))
window.append(window_case('replacement-crosses-clip', sentences, 3.2, clips=sentence_clip, clip='c1', first='w4', last='w4',
                          replacements=[('w2', 'w3', True, None)]))
window.append(window_case('replacement-blocks-take-edge', gaps_words([(0.00, 0.30), (0.70, 1.00), (1.40, 1.70)]), 2.6, cut=['w1'],
                          first='w2', last='w2', replacements=[('w1', 'w1', True, None)]))
# Speech with no silence between words: the hard seams on each side of the boundary meet, so the window would touch the
# replacement.
connected = gaps_words([(0.25, 0.50), (0.50, 0.75), (0.75, 1.00), (1.00, 1.25), (1.25, 1.50), (1.50, 1.75), (1.75, 2.00)])
window.append(window_case('replacement-touching-left', connected, 3.0, first='w4', last='w4', replacements=[('w3', 'w3', True, None)]))
window.append(window_case('replacement-touching-right', connected, 3.0, first='w4', last='w4', replacements=[('w5', 'w5', True, None)]))
# 1/64 s of silence: the two hard seams leave 375 kept samples, enough for either outer half (288) but not for both.
window.append(window_case('replacement-kept-piece-too-short', gaps_words([(0.25, 0.50), (0.75, 1.00), (1.015625, 1.25), (1.28125, 1.50),
                                                                         (1.53125, 1.75), (1.78125, 2.00)]), 3.0,
                          first='w3', last='w3', replacements=[('w2', 'w2', True, None)]))
window.append(window_case('replacement-kept-piece-too-short-right', gaps_words([(0.25, 0.50), (0.53125, 0.75), (0.78125, 1.00),
                                                                               (1.03125, 1.25), (1.265625, 1.50), (1.75, 2.00)]), 3.0,
                          first='w4', last='w4', replacements=[('w5', 'w5', True, None)]))
# Section 8.4 steps 1 and 2: a hard seam beside a replacement measures the silence from where that replacement's fade and its
# own outer half both fit, so it lands between them when there is room. Here the replacement's gap seam is 18 ms before w3
# (the round 4 review's case), a hard seam 70 ms of silence away (480 + 288 or 288 + 288 samples needed), and the mirror.
window.append(window_case('replacement-hard-seam-clears-fade', gaps_words([(0.20, 0.50), (0.55, 0.90), (1.203, 1.50), (1.55, 1.90),
                                                                          (2.40, 2.80)]), 3.5, {118: QUIET},
                          first='w3', last='w4', replacements=[('w1', 'w2', True, None)]))
apart = gaps_words([(0.25, 0.50), (0.75, 1.00), (1.0703125, 1.25), (1.28125, 1.50), (1.53125, 1.75), (1.78125, 2.00)])
window.append(window_case('replacement-hard-seams-clear-each-other', apart, 3.0, first='w3', last='w3',
                          replacements=[('w2', 'w2', True, None)]))
window.append(window_case('replacement-hard-seam-clears-fade-right', gaps_words([(0.25, 0.50), (0.53125, 0.75), (0.78125, 1.00),
                                                                                (1.03125, 1.25), (1.3203125, 1.50), (1.75, 2.00)]), 3.0,
                          first='w4', last='w4', replacements=[('w5', 'w5', True, None)]))
# At 44.1 kHz the hard fade is odd (264 + 265) and the gap fade even (441 + 441), so these pin which half each side keeps:
# the silence starts 441 + 264 samples after r1 and ends 441 + 265 before it, and the seam lands at its midpoint.
window.append(window_case('replacement-hard-seam-clears-fade-44100', gaps_words([(0.20, 0.50), (0.55, 0.90), (53064 / 44100, 1.50),
                                                                                (1.55, 1.90), (2.40, 2.80)]), 3.5, {118: QUIET},
                          first='w3', last='w4', rate=44100, replacements=[('w1', 'w2', True, None)]))
window.append(window_case('replacement-hard-seam-clears-fade-right-44100', gaps_words([(0.20, 0.50), (0.55, 0.90), (0.95, 53217 / 44100),
                                                                                      (1.35, 1.70), (1.75, 2.10)]), 3.5, {122: QUIET},
                          first='w2', last='w3', rate=44100, replacements=[('w4', 'w5', True, None)]))
# A cut pause keeps its 0.15 s breath before w3 while a later kept word follows. Re-voicing w4 leaves no kept word after
# the pause, so its cut grows to w3's start and closes the kept piece between r1 and r2.
window.append(window_case('replacement-window-moves-cut', gaps_words([(0.20, 0.50), (1.00, 1.30), (2.50, 2.60), (3.20, 3.50)]), 4.0,
                          cut_pauses=['pause-after-w2'], threshold=0.5, first='w4', last='w4',
                          replacements=[('w2', 'w2', True, None), ('w3', 'w3', True, None)]))
# Edits made after a replacement was accepted. Cutting the pause after r1 removes the middle of the gap its seam sits in,
# so its fade now crosses a cut. Prepare still renders it beside the next output piece, and so a window anywhere else is
# judged on its own: re-voicing w1 is accepted.
window.append(window_case('replacement-pause-cut-after-acceptance', sentences, 3.2, threshold=0.25, keep=0.1, first='w1', last='w1',
                          replacements=[('w2', 'w2', True, None)], later_cut_pauses=['pause-after-w2']))
# Re-voicing the next sentence after that cut: the window drops w3 and w4, so the pause loses its breath and no gap frame
# fits, but a hard seam 70 ms after the cut keeps both fades apart in the output, and the window renders.
window.append(window_case('replacement-pause-cut-next-sentence', sentences, 3.2, threshold=0.25, keep=0.1, first='w3', last='w3',
                          replacements=[('w2', 'w2', True, None)], later_cut_pauses=['pause-after-w2']))
# With an event after w3 the breath stays, and the gap seam lands 720 samples into the kept source after the cut. r1's fade,
# which now starts that output piece, and the window's own would overlap there: prepare's rule refuses what the scope
# renders without the window.
window.append(window_case('replacement-pause-cut-window-after', sentences[:3] + [word('e1', 2.00, 2.30, 'event', '(laughs)')], 3.2,
                          threshold=0.25, keep=0.1, first='w3', last='w3', replacements=[('w2', 'w2', True, None)],
                          later_cut_pauses=['pause-after-w2']))
# Here the window, not an edit, moves the cut: the pause after w2 keeps its breath while u1 is kept, and re-voicing u1 drops
# it, so the pause cut grows into r1's fade. Prepare would still render r1 beside the source after the pause, but r1's
# fade held kept source before the window, so the window is refused. u1 is not a word, so r1 never bridged over it.
window.append(window_case('replacement-window-moves-pause-cut', [word('u1', 0.20, 0.50, 'unlabeledSpeech', '\u2026'),
                                                                 word('w2', 1.00, 1.30), word('w3', 2.50, 2.80)], 3.4,
                          {135: QUIETER}, cut_pauses=['pause-after-w2'], threshold=0.5, first='u1', last='u1',
                          replacements=[('w2', 'w2', True, None)]))
# Cutting w3 and w4 leaves a 5 ms sliver of kept source after r1, too short for its fade's outer half: the scope did not
# render before the window, and the refusal names r1. Re-voicing the cut words themselves restores kept source beside r1.
sliver = gaps_words([(0.20, 0.50), (0.80, 1.10), (1.24, 1.50), (1.705, 1.80), (2.40, 2.70)])
window.append(window_case('replacement-cut-leaves-sliver', sliver, 3.4, first='w1', last='w1', replacements=[('w2', 'w2', True, None)],
                          later_cut=['w3', 'w4']))
window.append(window_case('replacement-window-restores-kept-source', sliver, 3.4, first='w3', last='w4',
                          replacements=[('w2', 'w2', True, None)], later_cut=['w3', 'w4']))
# r2 was placed while r1 was disabled, then r1 was enabled: the kept piece between their hard seams is 495 samples, short of
# 288 + 288, which no window elsewhere can mend. Connected speech four words deep keeps both seams hard.
chain = gaps_words([(0.25, 0.50), (0.53125, 0.75), (0.78125, 1.00), (1.03125, 1.25), (1.28125, 1.50), (1.5703125, 1.75), (1.78125, 2.00),
                    (2.03125, 2.25), (2.28125, 2.50), (2.53125, 2.75)])
window.append(window_case('replacement-pair-already-too-short', chain, 3.5, first='w1', last='w1',
                          replacements=[('w5', 'w5', False, None), ('w6', 'w6', True, None)], later_enabled=['r1']))

def by_name(cases, name):
    return next(case['expected'] for case in cases if case['name'] == name)


def by_name_input(cases, name):
    return next(case['input']['words'] for case in cases if case['name'] == name)


# The vectors must exercise what their names claim.
assert by_name(window, 's15-gap-two-words-left')['leftBridgeWordIds'] == ['w2', 'w3']
assert by_name(window, 's15-gap-two-words-left')['leftSeam']['sample'] == 63 * 480 + 240
assert by_name(window, 's15-hard-no-gap-within-three')['leftSeam']['kind'] == 'hard'
assert by_name(window, 's15-hard-no-gap-within-three')['leftSeam']['time'] == 1.5 - 0.03
assert by_name(window, 's15-hard-no-gap-within-three')['rightSeam']['kind'] == 'hard'
assert samples(0.72, 48000) - samples(0.60, 48000) == samples(SEAM_MIN_GAP, 48000)
assert by_name(window, 'gap-exactly-min')['leftSeam']['kind'] == 'gap'
assert by_name(window, 'gap-exactly-min')['leftBridgeWordIds'] == []
assert samples(34559 / 48000, 48000) - samples(0.60, 48000) == samples(SEAM_MIN_GAP, 48000) - 1
assert by_name(window, 'gap-one-sample-below-min')['leftSeam']['kind'] == 'hard'
assert by_name(window, 'gap-three-words-away')['leftBridgeWordIds'] == ['w2', 'w3', 'w4']
assert by_name(window, 'gap-four-words-away')['leftSeam']['kind'] == 'hard'
# The bridge stops at the cut word, and the hard seam then lies inside that word's 0.1 s reach: nothing kept before it.
assert by_name(window, 'cut-word-blocks-left') == {'error': 'seamFadeCrossesCut', 'incoming': True, 'needed': 288, 'available': 0}
assert by_name(window, 'event-blocks-right')['rightSeam']['kind'] == 'hard'
assert by_name(window, 'unlabeled-speech-blocks-left')['leftSeam']['kind'] == 'hard'
assert by_name(window, 'first-word-at-take-start')['leftSeam'] == {'kind': 'none', 'time': 0.0, 'sample': 0, 'fadeSamples': 0}
assert by_name(window, 'last-word-at-take-end')['rightSeam']['kind'] == 'none'
# Section 8.4 take edges: with no kept item before or after the passage, the window runs to that edge whatever the gap.
for name in ('leading-and-trailing-silence', 'take-edge-fade-excludes-frame'):
    assert by_name(window, name)['leftSeam'] == {'kind': 'none', 'time': 0.0, 'sample': 0, 'fadeSamples': 0}
    assert by_name(window, name)['rightSeam'] == {'kind': 'none', 'time': 2.0, 'sample': 96000, 'fadeSamples': 0}
assert by_name(window, 'envelope-tie')['leftSeam']['sample'] == 66 * 480 + 240
assert by_name(window, 'envelope-tie')['rightSeam']['sample'] == 249 * 480 + 240
assert by_name(window, 'odd-frame-44100')['rightSeam'] == {'kind': 'none', 'time': 2.2, 'sample': 97020, 'fadeSamples': 0}
assert by_name(window, 'odd-frame-44100')['leftSeam']['fadeSamples'] == 529
assert by_name(window, 'odd-frame-gap-seam-44100')['rightSeam']['sample'] == 205 * 441 + 221
assert by_name(window, 'window-crosses-word')['error'] == 'windowCrossesWord'
# e2 lies inside e1, so the silence on each side is negative. Unclamped, both hard seams would move 0.15 s inward onto the
# same sample; clamped, the window is e2 itself, which crosses e1.
assert by_name(window, 'passage-nested-in-cut-event') == {'error': 'windowCrossesWord', 'wordId': 'e1'}
# Their hard seams would fade across the take edge: 0.003 s before sample 0 at the start, 0.9975 s past 48000 at the end.
assert samples(0.003, 48000) - samples(HARD_SEAM_FADE, 48000) // 2 < 0 < samples(0.002, 48000)
assert samples(0.9975, 48000) + samples(HARD_SEAM_FADE, 48000) // 2 > 48000
assert by_name(window, 'hard-fade-extends-to-take-start')['leftSeam'] == {'kind': 'none', 'time': 0.0, 'sample': 0, 'fadeSamples': 0}
assert by_name(window, 'hard-fade-extends-to-take-end')['rightSeam'] == {'kind': 'none', 'time': 1.0, 'sample': 48000, 'fadeSamples': 0}
assert by_name(window, 'hard-fade-outside-take-start') == {'error': 'seamFadeOutsideTake'}
assert by_name(window, 'hard-fade-outside-take-end') == {'error': 'seamFadeOutsideTake'}
assert by_name(window, 'envelope-rate-mismatch')['error'] == 'invalidInput'
assert by_name(window, 'window-exactly-holds-both-fades')['endSample'] - by_name(window, 'window-exactly-holds-both-fades')['startSample'] == 576
assert by_name(window, 'window-too-short') == {'error': 'windowTooShort', 'needed': 576, 'available': 528}
# totalSamples / rate lies before d_down and the FFmpeg-style duration and after d_up, so neither is the take end.
assert samples(d_down, 44100) / 44100 < d_down and samples(d_up, 44100) / 44100 > d_up
assert d_down * 44100 < 90772.5 and samples(d_down, 44100) == 90772 and d_up * 44100 == 90919.5 and samples(d_up, 44100) == 90920
assert samples(d_ffmpeg, 48000) / 48000 > d_ffmpeg
for name, d, rate in (('take-end-rounds-down-44100', d_down, 44100), ('take-end-rounds-up-44100', d_up, 44100),
                      ('take-end-ffmpeg-duration-48000', d_ffmpeg, 48000), ('whole-take-44100', d_up, 44100)):
    assert by_name(window, name)['rightSeam'] == {'kind': 'none', 'time': d, 'sample': samples(d, rate), 'fadeSamples': 0}
    assert by_name(window, name)['end'] == d
assert by_name(window, 'whole-take-44100')['leftSeam'] == {'kind': 'none', 'time': 0.0, 'sample': 0, 'fadeSamples': 0}
assert by_name(window, 'first-word-rounds-to-take-start')['leftSeam'] == {'kind': 'none', 'time': 0.0, 'sample': 0, 'fadeSamples': 0}
assert by_name(window, 'first-word-rounds-to-take-start')['rightSeam']['kind'] == 'gap'
# The last word ends 3 ms before an off-grid end: the window still ends at exactly durationSeconds, not at totalSamples / rate.
assert by_name(window, 'take-end-extension-off-grid-44100')['rightSeam'] == {'kind': 'none', 'time': d_up, 'sample': 90920, 'fadeSamples': 0}
# w2's cut reaches 0.1 s past 1.0 s, to sample 52800, so a 960-sample gap fade must centre at 53280 or later.
assert by_name(window, 'cut-reach-excludes-quietest-frame')['leftSeam']['sample'] == 125 * 480 + 240
# Reaching 0.1 s past 0.995 s ends on sample 52560: frame 110's fade starts exactly there, frame 109's before it.
assert samples(0.995 + 0.1, 48000) == 52560 == 110 * 480 + 240 - 480
assert by_name(window, 'cut-reach-fade-boundary')['leftSeam']['sample'] == 110 * 480 + 240
# The gap before w3 is 0.15 s, but the output plan drops w3, so w2 reaches 0.1 s (to w4 or the take end), not 0.075 s.
assert by_name(window, 'cut-reach-to-next-kept-item')['leftSeam']['sample'] == 113 * 480 + 240
assert by_name(window, 'cut-reach-right')['rightSeam']['sample'] == 140 * 480 + 240
# Take edges count kept items only. A cut filler before the passage, with nothing kept before it, is absorbed: the window
# runs from 0 and its first word is the filler, so no fade crosses the cut.
for name in ('cut-filler-at-take-start', 'cut-filler-near-take-start-44100', 'two-cut-words-at-take-start',
             'cut-word-after-leading-silence'):
    assert by_name(window, name)['leftSeam'] == {'kind': 'none', 'time': 0.0, 'sample': 0, 'fadeSamples': 0}
    assert by_name(window, name)['firstWordId'] == 'w1' and by_name(window, name)['leftBridgeWordIds'] == []
assert by_name(window, 'cut-word-at-take-end')['rightSeam'] == {'kind': 'none', 'time': 1.5, 'sample': 72000, 'fadeSamples': 0}
assert by_name(window, 'cut-word-at-take-end')['lastWordId'] == 'w3'
# A clip whose kept range starts after 0 is not at the take start: the clip head is a cut beside the hard seam.
assert by_name(window, 'clip-starts-at-hard-seam') == {'error': 'seamFadeCrossesCut', 'incoming': True, 'needed': 288, 'available': 0}
# w3's cut ends at 1.5 s (e1 is nested in it, so it reaches no further): frame 150's fade would start 240 samples inside it.
assert by_name(window, 'nested-event-in-cut-word')['leftSeam']['sample'] == 151 * 480 + 240
# The cut pause runs from 0.65 s (breath kept after w1) to 1.5 s, because the right search could bridge to w3 and leave the
# pause no kept word after it; frame 100 inside it is never chosen. With an event after the passage nothing can be
# bridged, w3's breath stays (to 1.35 s), and the quieter frame 140 is chosen.
assert by_name(window, 'cut-pause-beside-window')['leftSeam']['sample'] == 63 * 480 + 240
assert by_name(window, 'cut-pause-keeps-breath')['leftSeam']['sample'] == 140 * 480 + 240
# In clip scope the clip head (to 0.78 s) and tail (from 1.75 s) are cuts: the quietest frames 70 and 180 lie outside.
assert by_name(window, 'clip-start-limits-gap-seam')['leftSeam']['sample'] == 85 * 480 + 240
assert by_name(window, 'clip-start-limits-gap-seam')['rightSeam']['sample'] == 173 * 480 + 240
assert by_name(window, 'clip-take-in-full-scope')['leftSeam']['sample'] == 70 * 480 + 240
assert by_name(window, 'clip-take-in-full-scope')['rightSeam']['sample'] == 180 * 480 + 240
assert by_name(window, 'passage-outside-clip') == {'error': 'seamFadeCrossesCut', 'incoming': False, 'needed': 288, 'available': 0}
assert by_name(window, 'clip-touching-take-start')['leftSeam'] == {'kind': 'none', 'time': 0.0, 'sample': 0, 'fadeSamples': 0}
# The clip starts at 0.000005 s: sample 0, so nothing is cut before it, but the output plan refuses a replacement that starts
# before the clip. The window stays inside, and frame 0, whose fade would start before sample 0, is not a candidate.
assert samples(clip_times(by_name_input(window, 'clip-start-rounds-to-take-start'), 0, 1)[0], 48000) == 0
assert by_name(window, 'clip-start-rounds-to-take-start')['leftSeam']['sample'] == 5 * 480 + 240
# Dropping only the passage would leave the next item 0.16 s after the cut, a 0.08 s reach that frame 109 (or 130, or the
# mirrored 50) clears. The window also drops the bridge or the absorbed cut item, so the reach is 0.1 s and only frame 111
# (128, 48) holds the whole fade.
for name, seam in (('cut-reach-beyond-right-bridge', ('leftSeam', 111)), ('cut-reach-beyond-left-bridge', ('rightSeam', 128)),
                   ('cut-reach-beyond-absorbed-end', ('leftSeam', 111)), ('cut-reach-beyond-absorbed-start', ('rightSeam', 48))):
    assert by_name(window, name)[seam[0]]['sample'] == seam[1] * 480 + 240, name
assert by_name(window, 'cut-reach-beyond-right-bridge')['rightBridgeWordIds'] == ['w4']
assert by_name(window, 'cut-reach-beyond-left-bridge')['leftBridgeWordIds'] == ['w2']
assert by_name(window, 'cut-reach-beyond-absorbed-end')['rightSeam']['kind'] == 'none'
assert by_name(window, 'cut-reach-beyond-absorbed-start')['leftSeam']['kind'] == 'none'
# With w1 kept, prepare would join the source before w2's cut to the synth inside the fade; the fade would cross the cut.
assert by_name(window, 'cut-hard-seam-inside-reach') == {'error': 'seamFadeCrossesCut', 'incoming': True, 'needed': 288, 'available': 0}
# w2's cut reaches 0.0675 s past 0.5 s (half the gap to w4, which stays), to sample 27240: 120 samples before the seam.
assert by_name(window, 'cut-hard-seam-sliver') == {'error': 'seamFadeCrossesCut', 'incoming': True, 'needed': 288, 'available': 120}
# Round 4. At 22.05 kHz a gap seam's fade reaches floor(441 / 2) = 220 samples back and ceil(441 / 2) = 221 forward: frame
# 50 (or 140) qualifies only when the cut edge lies exactly that far away, not one sample closer.
for name, seam, edge in (('gap-fade-back-half-fits-22050', 50, -220), ('gap-fade-back-half-short-22050', 60, -219)):
    assert samples(by_name_input(window, name)[1]['end'] + 0.1, 22050) == 50 * 221 + 111 + edge
    assert by_name(window, name)['leftSeam']['sample'] == seam * 221 + 111, name
for name, seam, edge in (('gap-fade-forward-half-fits-22050', 140, 221), ('gap-fade-forward-half-short-22050', 133, 220)):
    assert samples(by_name_input(window, name)[2]['start'] - 0.1, 22050) == 140 * 221 + 111 + edge
    assert by_name(window, name)['rightSeam']['sample'] == seam * 221 + 111, name
assert by_name(window, 'hard-fade-ends-at-take-end-44100')['rightSeam']['sample'] == 44100 - 265
assert by_name(window, 'hard-fade-one-sample-past-take-end-44100') == {'error': 'seamFadeOutsideTake'}
assert by_name(window, 'window-too-short-hard-in-gap-out-44100') == {'error': 'windowTooShort', 'needed': 706, 'available': 705}
assert by_name(window, 'window-holds-gap-in-hard-out-44100')['startSample'] == 44321
assert by_name(window, 'window-holds-gap-in-hard-out-44100')['endSample'] == 44321 + 705
assert by_name(window, 'window-too-short-gap-in-hard-out-44100') == {'error': 'windowTooShort', 'needed': 705, 'available': 704}
# Unclamped, the left hard seam would move 0.05 s into e0 and cross it.
assert by_name(window, 'left-clamp-absorbs-simultaneous-event')['leftSeam'] == {'kind': 'hard', 'time': 0.6, 'sample': 28800, 'fadeSamples': 576}
assert by_name(window, 'left-clamp-absorbs-simultaneous-event')['firstWordId'] == 'e0'
assert by_name(window, 'nested-event-absorbed-at-window-end')['lastWordId'] == 'e1'
assert by_name(window, 'kept-word-inside-window') == {'error': 'windowCrossesWord', 'wordId': 'x1'}
assert by_name(window, 'transcript-starts-out-of-order') == by_name(window, 'transcript-zero-length-item') == {'error': 'invalidInput'}
# A gap seam beside a replacement leaves its outgoing half (480 samples) free and takes its own 480 after it. A disabled
# replacement, or one outside the clip, changes nothing.
assert by_name(window, 'replacement-next-word')['startSample'] == 59760 + 480 + 480
assert by_name(window, 'replacement-disabled') == window_case('-', sentences, 3.2, first='w3', last='w3')['expected']
assert by_name(window, 'replacement-disabled')['startSample'] == 59760
assert by_name(window, 'replacement-outside-clip') == window_case('-', sentences, 3.2, clips=sentence_clip, clip='c1', first='w3',
                                                                  last='w3')['expected']
assert by_name(window, 'replacement-same-passage') == {'error': 'overlapsReplacement', 'segmentId': 'r1'}
assert by_name(window, 'replacement-crosses-clip') == {'error': 'invalidInput'}
assert by_name(window, 'replacement-blocks-take-edge')['startSample'] == 23760 + 480 + 480
# The bridge search stops at r1's word, so the hard seam lands on r1's: they would touch. Bridging over it would overlap r1.
assert by_name(window, 'replacement-touching-left') == {'error': 'adjacentReplacement', 'segmentId': 'r1'}
assert by_name(window, 'replacement-touching-right') == {'error': 'adjacentReplacement', 'segmentId': 'r1'}
assert by_name(window, 'replacement-kept-piece-too-short') == {'error': 'adjacentReplacement', 'segmentId': 'r1'}
assert by_name(window, 'replacement-kept-piece-too-short-right') == {'error': 'adjacentReplacement', 'segmentId': 'r1'}
# r1 = [0, 56880] with a 960-sample gap fade; the silence is measured from (56880 + 480 + 288) / 48000 = 1.201 s.
assert by_name(window, 'replacement-hard-seam-clears-fade')['leftSeam'] == {'kind': 'hard', 'time': 1.202, 'sample': 57696,
                                                                            'fadeSamples': 576}
assert by_name(window, 'replacement-hard-seams-clear-each-other')['startSample'] - 49440 >= 288 + 288
assert 61935 - by_name(window, 'replacement-hard-seam-clears-fade-right')['endSample'] >= 288 + 288
# r1 ends on frame 118's centre, 52259; the passage starts 100 samples after 52259 + 441 + 264, and r1 of the mirror starts on
# frame 122's centre, 54023, 100 samples after the passage ends plus 441 + 265.
assert by_name(window, 'replacement-hard-seam-clears-fade-44100')['startSample'] == 52259 + 441 + 264 + 50
assert by_name(window, 'replacement-hard-seam-clears-fade-right-44100')['endSample'] == 54023 - 441 - 265 - 50
assert by_name(window, 'replacement-window-moves-cut') == {'error': 'adjacentReplacement', 'segmentId': 'r1'}
assert by_name(window, 'replacement-pause-cut-after-acceptance')['endSample'] == 62 * 480 + 240
assert by_name(window, 'replacement-pause-cut-next-sentence')['leftSeam'] == {'kind': 'hard', 'time': 1.40 - 0.03, 'sample': 65760,
                                                                              'fadeSamples': 576}
assert by_name(window, 'replacement-pause-cut-window-after') == {'error': 'adjacentReplacement', 'segmentId': 'r1'}
assert by_name(window, 'replacement-window-moves-pause-cut') == {'error': 'adjacentReplacement', 'segmentId': 'r1'}
assert by_name(window, 'replacement-cut-leaves-sliver') == {'error': 'invalidInput', 'segmentId': 'r1'}
assert by_name(window, 'replacement-window-restores-kept-source')['startSample'] == 118 * 480 + 240
assert by_name(window, 'replacement-pair-already-too-short') == {'error': 'invalidInput', 'segmentId': 'r1'}


def stretch_near(target, offset):
    """A stretch whose raw frame count lands exactly `offset` ULPs above the integer `target`."""
    base = 240 / target
    for steps in range(-64, 65):
        stretch = base
        for _ in range(abs(steps)):
            stretch = math.nextafter(stretch, math.inf if steps > 0 else -math.inf)
        raw = 441 * 24000 / (44100 * stretch)
        if raw > target and round((raw - target) / ulp(raw)) == offset:
            return stretch
    raise AssertionError('no stretch found')


def handle_case(name, kind, fade, incoming, asset_rate, source_rate, stretch):
    raw, frames, source = minimum_handles(fade, incoming, asset_rate, source_rate, stretch)
    return {'name': name, 'input': {'kind': kind, 'fadeSamples': fade, 'incoming': incoming, 'assetSampleRate': asset_rate,
                                    'sourceSampleRate': source_rate, 'stretch': stretch},
            'expected': {'rawFrames': raw, 'assetFrames': frames, 'sourceSamples': source,
                         'seam': handle_seam(kind, fade, incoming, asset_rate, source_rate, stretch)}}


handles = [
    handle_case('gap-in-24k-asset-48k-source', 'gap', samples(SEAM_FADE, 48000), True, 24000, 48000.0, 1.0),
    handle_case('gap-out-24k-asset-48k-source', 'gap', samples(SEAM_FADE, 48000), False, 24000, 48000.0, 1.0),
    handle_case('hard-in-24k-asset-48k-source', 'hard', samples(HARD_SEAM_FADE, 48000), True, 24000, 48000.0, 1.0),
    handle_case('unity-one-ulp-below-48k', 'gap', samples(SEAM_FADE, 48000), True, 24000, 48000.0, 0.9999999999999999),
    handle_case('hard-odd-in-44k', 'hard', samples(HARD_SEAM_FADE, 44100), True, 24000, 44100.0, 1.0),
    handle_case('hard-odd-out-44k', 'hard', samples(HARD_SEAM_FADE, 44100), False, 24000, 44100.0, 1.0),
    handle_case('gap-in-44k-stretch-095', 'gap', samples(SEAM_FADE, 44100), True, 24000, 44100.0, 0.95),
    handle_case('hard-out-44k-stretch-095', 'hard', samples(HARD_SEAM_FADE, 44100), False, 24000, 44100.0, 0.95),
    handle_case('ulp-within-four-44k', 'gap', samples(SEAM_FADE, 44100), True, 24000, 44100.0, stretch_near(253, 2)),
    handle_case('ulp-beyond-four-44k', 'gap', samples(SEAM_FADE, 44100), True, 24000, 44100.0, stretch_near(253, 5)),
    handle_case('synth-to-synth-out-48k', 'synthToSynth', samples(SEAM_FADE, 48000), False, 24000, 48000.0, 1.0),
    handle_case('none-edge', 'none', 0, True, 24000, 48000.0, 1.0),
]
assert by_name(handles, 'unity-one-ulp-below-48k')['rawFrames'] != 240 and by_name(handles, 'unity-one-ulp-below-48k')['assetFrames'] == 240
assert by_name(handles, 'ulp-within-four-44k')['assetFrames'] == 253 and by_name(handles, 'ulp-within-four-44k')['rawFrames'] > 253
assert by_name(handles, 'ulp-beyond-four-44k')['assetFrames'] == 254
assert by_name(handles, 'hard-odd-in-44k')['sourceSamples'] == 265 and by_name(handles, 'hard-odd-out-44k')['sourceSamples'] == 264


def seams_for(fade, rate):
    return {'in': handle_seam('gap', fade, True, 24000, rate, 1.0), 'out': handle_seam('gap', fade, False, 24000, rate, 1.0)}


def trim_handle_case(name, trim_start, trim_end, duration):
    seams = seams_for(samples(SEAM_FADE, 48000), 48000.0)
    case = {'name': name, 'input': {'seams': seams, 'trimStart': trim_start, 'trimEnd': trim_end,
                                    'assetDurationSeconds': duration, 'assetSampleRate': 24000}}
    case['expected'] = run_case(check_trim, seams, trim_start, trim_end, duration, 24000) or {'ok': True}
    return case


trim_handles = [
    trim_handle_case('enough-both-sides', 0.1, 0.9, 1.0),
    trim_handle_case('exact-both-sides', 0.01, 0.99, 1.0),
    trim_handle_case('short-before-trim-start', 0.005, 0.9, 1.0),
    trim_handle_case('short-after-trim-end', 0.1, 0.995, 1.0),
]
assert by_name(trim_handles, 'exact-both-sides') == {'ok': True}
assert by_name(trim_handles, 'short-after-trim-end')['incoming'] is False


def aligned(text, start=0.1, step=0.05, gap=0.0):
    characters, starts, ends, cursor = list(text), [], [], start
    for ch in characters:
        starts.append(cursor)
        cursor = cursor + (gap if is_white_space(ch) else step)
        ends.append(cursor)
    return characters, starts, ends


def alignment_case(name, characters, starts, ends, expected_text):
    return {'name': name, 'input': {'characters': characters, 'starts': starts, 'ends': ends, 'expectedText': expected_text},
            'expected': words_result(alignment_words, characters, starts, ends, expected_text)}


said = aligned('I said 2025', start=0.12, gap=0.02)
estonian = aligned('T\u00e4na \u00f5htul: s\u00f6\u00f6n \u00fcht \u00f5una!')
spaced = aligned(' a\u00a0b\u0085c\u200bd  e\ufeff\u3000')
alignment = [
    alignment_case('s15-i-said-2025', *said, 'I said 2025'),
    alignment_case('mismatch', *said, 'I said 2024'),
    alignment_case('null-alignment', None, None, None, 'I said 2025'),
    alignment_case('empty-alignment', [], [], [], 'I said 2025'),
    alignment_case('array-length-mismatch', said[0], said[1][:-1], said[2], 'I said 2025'),
    alignment_case('estonian-punctuation-and-case', *estonian, 't\u00e4na \u00d5htul s\u00f6\u00f6n \u00dcHT \u00f5una'),
    alignment_case('unicode-white-space', *spaced, 'a b cd e'),
    alignment_case('punctuation-only-token', *aligned('Tere \u2014 maailm'), 'Tere \u2014 maailm'),
    alignment_case('white-space-only', *aligned('  '), ' '),
    alignment_case('nfd-provider-nfc-expected', *aligned('Ta\u0308na o\u0303htul'), 'T\u00e4na \u00f5htul'),
    alignment_case('nfc-provider-nfd-expected', *aligned('T\u00e4na'), 'Ta\u0308na'),
    alignment_case('noncharacter-in-provider', *aligned('Ta' + chr(0xFFFE) + 'na'), 'Tana'),
    alignment_case('noncharacter-in-both', *aligned('Ta' + chr(0xFFFE) + 'na'), 'Ta' + chr(0xFFFE) + 'na'),
    alignment_case('noncharacter-in-expected', *aligned('Tana'), 'Ta' + chr(0xFDD0) + 'na'),
    alignment_case('supplementary-noncharacter', *aligned('Ta' + chr(0x1FFFF) + 'na'), 'Ta' + chr(0x1FFFF) + 'na'),
]
assert len(by_name(alignment, 's15-i-said-2025')['words']) == 3
assert [w['text'] for w in by_name(alignment, 'unicode-white-space')['words']] == ['a', 'b', 'c\u200bd', 'e\ufeff']
assert by_name(alignment, 'mismatch') == {'error': 'alignmentMismatch'}
# Without NFC, editing section 4.7 would drop the combining marks and compare 'tana' with 't\u00e4na'.
assert normalize_for_match('Ta\u0308na') == 'tana' != normalize_for_match('T\u00e4na')
assert [w['text'] for w in by_name(alignment, 'nfd-provider-nfc-expected')['words']] == ['Ta\u0308na', 'o\u0303htul']
assert len(by_name(alignment, 'nfc-provider-nfd-expected')['words']) == 1
# normalize_for_match alone drops a noncharacter (category Cn), so both sides would fold to 'tana' and match.
assert normalize_for_match('Ta' + chr(0xFFFE) + 'na') == 'tana'
for name in ('noncharacter-in-provider', 'noncharacter-in-both', 'noncharacter-in-expected', 'supplementary-noncharacter'):
    assert by_name(alignment, name) == {'error': 'alignmentMismatch'}

said_words = by_name(alignment, 's15-i-said-2025')['words']


def f32_step(value, steps):
    return struct.unpack('<f', struct.pack('<I', struct.unpack('<I', struct.pack('<f', value))[0] + steps))[0]


# The binary32 levels adjacent to the binary64 threshold pin the strict, widened comparison.
nearest32 = f32(VOICED_FRAME_LEVEL)
just_above, just_below = (nearest32, f32_step(nearest32, -1)) if nearest32 > VOICED_FRAME_LEVEL else (f32_step(nearest32, 1), nearest32)
assert just_above > VOICED_FRAME_LEVEL > just_below


def tts_levels(count, voiced, level=SPEECH, base=0.001953125):
    levels = [base] * count
    for index in voiced:
        levels[index] = level
    return levels


def trim_case(name, duration, words=None, levels=None):
    if words is not None:
        return {'name': name, 'input': {'words': words, 'assetDuration': duration},
                'expected': run_case(trim_words, words, duration)}
    envelope = {'sampleRate': 24000, 'levels': levels}
    return {'name': name, 'input': {'envelope': {'sampleRate': 24000, 'runs': runs(levels)}, 'assetDuration': duration},
            'expected': run_case(trim_envelope, envelope, duration)}


edge_words = [{'text': 'Hi', 'start': 0.01, 'end': 0.4, 'synthetic': True}, {'text': 'there', 'start': 0.45, 'end': 1.17, 'synthetic': True}]
trim = [
    trim_case('aligned', 1.2, words=said_words),
    trim_case('aligned-clamped-both-ends', 1.2, words=edge_words),
    trim_case('aligned-empty', 1.2, words=[]),
    trim_case('envelope-voiced-frames', 1.2, levels=tts_levels(120, range(7, 96))),
    trim_case('envelope-threshold-float32', 1.2, levels=[just_above if i == 10 else just_below if i == 50 else 0.001953125
                                                         for i in range(120)]),
    trim_case('envelope-clamped-end', 1.195, levels=tts_levels(120, range(30, 120))),
    trim_case('envelope-clamped-start', 1.2, levels=tts_levels(120, range(2, 60))),
    trim_case('envelope-no-voiced-audio', 1.2, levels=[just_below] * 120),
]
assert by_name(trim, 'aligned-clamped-both-ends') == {'start': 0.0, 'end': 1.2}
assert by_name(trim, 'envelope-threshold-float32') == {'start': 0.1 - TTS_TRIM_LEAD, 'end': 0.11 + TTS_TRIM_TAIL}
assert by_name(trim, 'envelope-clamped-end')['end'] == 1.195
assert by_name(trim, 'envelope-clamped-start') == {'start': 0.0, 'end': 0.6 + TTS_TRIM_TAIL}
assert by_name(trim, 'envelope-no-voiced-audio') == {'error': 'noVoicedAudio'}


def relative_case(name, words, trim_start, stretch, out_duration, rate):
    return {'name': name, 'input': {'words': words, 'trimStart': trim_start, 'stretch': stretch, 'outDuration': out_duration,
                                    'sourceSampleRate': rate},
            'expected': words_result(relative_words, words, trim_start, stretch, out_duration, rate)}


aligned_trim = by_name(trim, 'aligned')
unity_out = aligned_trim['end'] - aligned_trim['start']
relative = [
    relative_case('unity', said_words, aligned_trim['start'], 1.0, unity_out, 48000.0),
    relative_case('stretch-095', said_words, aligned_trim['start'], 0.95, unity_out * 0.95, 48000.0),
    relative_case('end-beyond-output', said_words, aligned_trim['start'], 1.0, 0.5, 48000.0),
    relative_case('zero-length-on-source-grid', [{'text': 'a', 'start': 0.1, 'end': 0.1004, 'synthetic': True}], 0.0, 1.0, 0.5, 1000.0),
    relative_case('overlapping-words', [{'text': 'a', 'start': 0.1, 'end': 0.3, 'synthetic': True},
                                        {'text': 'b', 'start': 0.25, 'end': 0.4, 'synthetic': True}], 0.0, 1.0, 0.5, 48000.0),
]
assert by_name(relative, 'end-beyond-output') == {'error': 'invalidWordTiming'}


def room_case(name, items, duration, overrides=(), rate=48000):
    total = samples(duration, rate)
    levels = envelope_levels(items, rate, total // frame_size(rate), overrides)
    envelope = {'sampleRate': rate, 'levels': levels}
    return {'name': name, 'input': {'sampleRate': rate, 'totalSamples': total, 'words': items,
                                    'envelope': {'sampleRate': rate, 'runs': runs(levels)}},
            'expected': run_case(room_tone, items, envelope, float(rate), total)}


def quiet_run(first, level=QUIET):
    return {index: level for index in range(first, first + ROOM_TONE_FRAMES)}


def room_gap_case(name, rate, g0, g1):
    """One gap [g0, g1) on the source grid between two words; the leading and trailing silences are too short."""
    lead, length = samples(0.1, rate), samples(0.2, rate)
    total = g1 + length + lead
    items = gaps_words([(lead / rate, g0 / rate), (g1 / rate, (g1 + length) / rate)])
    assert [samples(t, rate) for i in items for t in (i['start'], i['end'])] == [lead, g0, g1, g1 + length]
    assert samples(total / rate, rate) == total
    return room_case(name, items, total / rate, rate=rate)


# Where 50 whole frames and jsRound(0.5 x rate) differ, the run must hold both: 50*F wins at 22.05 kHz, the
# sample length at 11.025 kHz. Each short case fails only through the term that wins at its rate.
assert ROOM_TONE_FRAMES * frame_size(22050) == 11050 > samples(ROOM_TONE_MIN_RUN, 22050) == 11025
assert ROOM_TONE_FRAMES * frame_size(11025) == 5500 < samples(ROOM_TONE_MIN_RUN, 11025) == 5513
room_items = gaps_words([(0.30, 0.90), (1.70, 2.20), (3.00, 3.40)])
room = [
    room_case('tie-earliest-run', room_items, 4.0, {**quiet_run(100), **quiet_run(230)}),
    room_case('quietest-later-run', room_items, 4.0, {**quiet_run(100), **quiet_run(230, QUIETER)}),
    room_case('leading-take-edge', gaps_words([(0.60, 1.00), (1.10, 1.50)]), 2.0, quiet_run(0, QUIETER)),
    room_case('trailing-take-edge', gaps_words([(0.30, 0.60), (0.70, 1.20)]), 2.0, quiet_run(150, QUIETER)),
    room_case('event-splits-gap', [word('w1', 0.20, 0.50), word('e1', 0.85, 0.95, 'event', '(cough)'),
                                   word('w2', 1.30, 1.60), word('w3', 2.20, 2.40)], 2.6, quiet_run(55, QUIETER)),
    room_case('no-qualifying-gap', gaps_words([(0.30, 0.70), (1.10, 1.50), (1.90, 2.30)]), 2.6),
    room_gap_case('fifty-frames-fit-exactly-22050', 22050, 20 * 221, 20 * 221 + 11050),
    room_gap_case('fifty-frames-one-sample-short-22050', 22050, 20 * 221, 20 * 221 + 11049),
    room_gap_case('min-run-fits-exactly-11025', 11025, 20 * 110 + 1, 21 * 110 + 5513),
    room_gap_case('min-run-one-sample-short-11025', 11025, 20 * 110 + 1, 21 * 110 + 5512),
]
assert by_name(room, 'tie-earliest-run')['sourceStartSample'] == 100 * 480
assert by_name(room, 'quietest-later-run')['sourceStartSample'] == 230 * 480
assert by_name(room, 'leading-take-edge')['sourceStartSample'] == 0
assert by_name(room, 'trailing-take-edge')['sourceEndSample'] == samples(2.0, 48000)
assert by_name(room, 'event-splits-gap')['sourceStartSample'] == 160 * 480
assert by_name(room, 'no-qualifying-gap') == {'error': 'roomToneUnavailable'}
assert by_name(room, 'fifty-frames-fit-exactly-22050') == {'sourceStartSample': 4420, 'sourceEndSample': 4420 + 11025, 'gainDb': 0.0}
assert by_name(room, 'fifty-frames-one-sample-short-22050') == {'error': 'roomToneUnavailable'}
assert by_name(room, 'min-run-fits-exactly-11025') == {'sourceStartSample': 2310, 'sourceEndSample': 2310 + 5513, 'gainDb': 0.0}
assert by_name(room, 'min-run-one-sample-short-11025') == {'error': 'roomToneUnavailable'}

# Property fuzz: PROPERTY_CASES random takes from a fixed seed, and MULTI_CASES takes that already hold one or two
# replacements placed by `place` itself. No accepted window may fail the model, and every refusal must be typed. Every
# stride-th case is committed as `propertyCases` or `multiSegmentCases`; both Core suites replay them and validate and
# prepare a recipe for each accepted one.

class Lcg:
    """Knuth's MMIX constants, so the fuzz and its committed sample depend only on the seed."""

    def __init__(self, seed):
        self.state = seed % 2 ** 64

    def below(self, bound):
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) % 2 ** 64
        return (self.state >> 33) % bound

    def between(self, lo, hi):
        return lo + self.below(hi - lo + 1)

    def chance(self, percent):
        return self.below(100) < percent

    def pick(self, options):
        return options[self.below(len(options))]


def fuzz_gap(rng, connected=False):
    """A silence in 0.1 ms units, weighted toward the boundaries the rules care about. Connected speech has no gap a gap
    seam could use."""
    if connected:
        return 0 if rng.chance(60) else rng.between(1, 1100)
    kind = rng.below(100)
    if kind < 22:
        return 0
    if kind < 35:
        return rng.between(1, 300)
    if kind < 52:
        return rng.between(300, 1150)
    if kind < 62:
        return rng.between(1150, 1300)
    if kind < 85:
        return rng.between(1300, 5000)
    return rng.between(5000, 12000)


def fuzz_case(rng):
    """A random take: items with touching, short and long gaps, occasional nested or overlapping items, cut words and
    pauses, a clip scope, words touching the take edges and off-grid durations. One silence of at least 0.6 s always
    holds room tone, so the native suites can build a complete passage recipe."""
    rate = rng.pick([44100, 48000])
    count = rng.between(2, 10)
    connected = rng.chance(25)
    long_gap = rng.below(count + 1)
    units, cursor = [], 0 if rng.chance(30) and long_gap != 0 else fuzz_gap(rng)
    kinds = []
    for index in range(count):
        if index == long_gap:
            cursor += rng.between(6000, 9000)
        elif index > 0:
            cursor += fuzz_gap(rng, connected)
            if units and rng.chance(4):
                cursor = max(0, cursor - rng.between(10, 300))
        length = rng.between(20, 150) if rng.chance(25 if connected else 6) else rng.between(800, 6000)
        if units and index != long_gap and rng.chance(6):
            host = units[-1]
            if host[1] - host[0] > 40:
                lo = rng.between(host[0], host[1] - 20)
                units.append((lo, rng.between(lo + 10, host[1])))
                kinds.append('event')
                continue
        # Speech may overlap, but starts stay in transcript order (the project transcript rule).
        cursor = max([cursor] + [lo for lo, _ in units[-1:]])
        units.append((cursor, cursor + length))
        kinds.append(rng.pick(['word'] * 17 + ['event', 'event', 'unlabeledSpeech']))
        cursor += length
    last_end = max(end for _, end in units)
    trailing = rng.between(6000, 9000) if long_gap == count else (0 if rng.chance(30) else fuzz_gap(rng))
    duration = (last_end + trailing) / 10000
    variant = rng.below(100)
    if variant < 10:
        duration = js_round(duration * rate) * (1 / rate)
    elif variant < 18:
        duration = (js_round(duration * rate) + 0.5) / rate
    elif variant < 25:
        duration = math.ceil(duration * 600) / 600
    items = [word('w%d' % (index + 1), lo / 10000, hi / 10000, kinds[index]) for index, (lo, hi) in enumerate(units)]
    if trailing == 0:
        for item in items:
            if item['end'] == last_end / 10000:
                item['end'] = duration
    duration = max(duration, max(item['end'] for item in items))
    a = rng.below(count)
    b = min(count - 1, a + rng.pick([0, 0, 1, 1, 2]))
    cut_percent = rng.pick([0, 15, 35])
    cut = {item['id'] for item in items if rng.chance(cut_percent)}
    for index, percent in ((0, 20), (count - 1, 20), (a - 1, 30), (b + 1, 30), (a - 2, 12), (b + 2, 12)):
        if 0 <= index < count and rng.chance(percent):
            cut.add(items[index]['id'])
    edits = {'cutWordIds': [item['id'] for item in items if item['id'] in cut], 'cutPauseIds': [],
             'pauseThresholdSeconds': rng.pick([0.5, 0.8]), 'pauseKeepSeconds': rng.pick([0.15, 0.1]), 'clips': []}
    edits['cutPauseIds'] = [pause['id'] for pause in detect_pauses(items, edits['pauseThresholdSeconds']) if rng.chance(50)]
    clip_id = None
    if rng.chance(40):
        lo = max(0, a - rng.below(3)) if rng.chance(60) else rng.below(count)
        hi = min(count - 1, max(lo, b) + rng.below(3)) if rng.chance(60) else rng.between(lo, count - 1)
        edits['clips'].append({'id': 'c1', 'startWordId': items[lo]['id'], 'endWordId': items[hi]['id']})
        clip_id = 'c1'
    total, size = samples(duration, rate), frame_size(rate)
    frames = total // size
    quiet = {rng.below(frames): rng.pick([QUIET, QUIETER]) for _ in range(rng.between(2, 6))}
    levels = envelope_levels(items, rate, frames, quiet)
    project = {'sampleRate': rate, 'durationSeconds': duration, 'words': items, 'edits': edits, 'segments': []}
    return project, clip_id, {'sampleRate': rate, 'levels': levels}, items[a]['id'], items[b]['id']


PROPERTY_SEED = 20261027
PROPERTY_CASES = 20000
PROPERTY_SAMPLE = 300
PROPERTY_STRIDE = PROPERTY_CASES // PROPERTY_SAMPLE
REFUSALS = ('seamFadeCrossesCut', 'seamFadeOutsideTake', 'windowCrossesWord', 'windowTooShort')

property_cases, failures = [], []
fuzz = {'seed': PROPERTY_SEED, 'cases': PROPERTY_CASES, 'sampleStride': PROPERTY_STRIDE, 'accepted': 0,
        'acceptedInClipScope': 0, 'seams': {}, 'refused': {code: 0 for code in REFUSALS}, 'renderFailures': 0}
generator = Lcg(PROPERTY_SEED)
for index in range(PROPERTY_CASES):
    project, clip_id, envelope, first, last = fuzz_case(generator)
    expected = run_case(place, project, clip_id, envelope, first, last)
    if 'error' in expected:
        assert expected['error'] in REFUSALS, (index, expected)
        fuzz['refused'][expected['error']] += 1
    else:
        failure = render_failure(project, clip_id, expected)
        if failure is not None:
            failures.append((index, failure))
        fuzz['accepted'] += 1
        fuzz['acceptedInClipScope'] += clip_id is not None
        pair = '%s/%s' % (expected['leftSeam']['kind'], expected['rightSeam']['kind'])
        fuzz['seams'][pair] = fuzz['seams'].get(pair, 0) + 1
    if index % PROPERTY_STRIDE == 0 and len(property_cases) < PROPERTY_SAMPLE:
        rate, duration, items = project['sampleRate'], project['durationSeconds'], project['words']
        case = {'name': 'property-%05d' % index,
                'input': take_input(rate, duration, items, project['edits'], clip_id, envelope), 'expected': expected,
                'roomTone': passage_room_tone(expected, items, envelope, rate, duration)}
        case['input'].update(firstWordId=first, lastWordId=last)
        # Every take holds a silence of at least 0.6 s, so every accepted case can carry a complete passage recipe.
        assert 'error' in expected or case['roomTone'] is not None, index
        property_cases.append(case)
assert not failures, failures[:5]
fuzz['renderFailures'] = len(failures)
fuzz['seams'] = dict(sorted(fuzz['seams'].items()))
print('property fuzz seed %d: %d cases, %d accepted (%d in clip scope), seams %s, refused %s, %d render failures, %d sampled'
      % (PROPERTY_SEED, PROPERTY_CASES, fuzz['accepted'], fuzz['acceptedInClipScope'], fuzz['seams'], fuzz['refused'],
         len(failures), len(property_cases)))



def fuzz_replacements(rng, project, clip_id, envelope, a, b, check):
    """One or two replacements that `place` itself puts into the take before the passage: usually the words just before
    or just after it, which is how consecutive sentences are re-voiced, sometimes anywhere. Most share the passage's
    scope and are enabled; some are disabled, and in a clip scope some were placed for the full take. Each placement is
    a property case of its own: `check` sees every outcome, and only an accepted window joins the project."""
    count, ids = len(project['words']), [item['id'] for item in project['words']]
    for number in range(1, rng.between(1, 2) + 1):
        where, extra = rng.below(100), rng.pick([0, 0, 1, 2])
        if where < 40:
            hi = a - 1 - rng.below(2)
            lo = hi - extra
        elif where < 80:
            lo = b + 1 + rng.below(2)
            hi = lo + extra
        else:
            lo = rng.below(count)
            hi = lo + extra
        scope = clip_id if clip_id is None or rng.chance(80) else None
        enabled = rng.chance(90)
        lo, hi = max(0, lo), min(count - 1, hi)
        if lo > hi:
            continue
        placed = run_case(place, project, scope, envelope, ids[lo], ids[hi])
        if check(project, scope, placed):
            project['segments'].append({'id': 'r%d' % number, 'enabled': enabled, 'window': placed})


def fuzz_later_edits(rng, project):
    """Edits an editor makes after the replacements were accepted, in half the takes: cutting the item just before or after
    a replacement, cutting a pause its seam lies in, and enabling a disabled replacement again. A seam can then fade across
    a cut, and the scope can stop rendering. Returns whether any edit was made. The draws do not depend on the take, so a
    change in what `place` accepts never shifts the random stream of later takes."""
    edit = rng.chance(50)
    draws = [[rng.below(100) for _ in range(4)] for _ in range(2)]
    if not project['segments'] or not edit:
        return False
    items, edits = project['words'], project['edits']
    cut = set(edits['cutWordIds'])
    pauses = detect_pauses(items, edits['pauseThresholdSeconds'])
    for segment, (cut_before, cut_after, cut_pause, enable) in zip(project['segments'], draws):
        start, end = segment['window']['start'], segment['window']['end']
        before = [item for item in items if item['end'] <= start]
        after = [item for item in items if item['start'] >= end]
        if before and cut_before < 30:
            cut.add(before[-1]['id'])
        if after and cut_after < 30:
            cut.add(after[0]['id'])
        for pause in pauses:
            if (pause['start'] < start < pause['end'] or pause['start'] < end < pause['end']) and cut_pause < 60 \
                    and pause['id'] not in edits['cutPauseIds']:
                edits['cutPauseIds'].append(pause['id'])
        if not segment['enabled'] and enable < 50:
            segment['enabled'] = True
    edits['cutWordIds'] = [item['id'] for item in items if item['id'] in cut]
    return True


MULTI_SEED = 20261028
MULTI_CASES = 20000
MULTI_SAMPLE = 150
MULTI_STRIDE = MULTI_CASES // MULTI_SAMPLE
MULTI_REFUSALS = REFUSALS + ('adjacentReplacement', 'overlapsReplacement')

multi_cases, multi_failures = [], []
multi = {'seed': MULTI_SEED, 'cases': MULTI_CASES, 'sampleStride': MULTI_STRIDE, 'replacements': 0, 'disabledReplacements': 0,
         'laterEdits': 0, 'accepted': 0, 'acceptedBesideReplacement': 0, 'acceptedAfterLaterEdits': 0,
         'refused': {code: 0 for code in MULTI_REFUSALS + ('invalidInput',)}, 'invalidInputNamingReplacement': 0,
         'renderFailures': 0}


def multi_check(project, clip_id, placed):
    """Every placement in the multi-segment fuzz: a refusal must be typed, and an accepted window must render beside the
    replacements already in the project. Returns whether the window was accepted."""
    if 'error' in placed:
        if placed['error'] == 'invalidInput' and 'segmentId' in placed:
            # A replacement whose seam prepare refuses even without the window: the scope did not render before it.
            assert render_failure(project, clip_id, None) is not None, placed
        elif placed['error'] == 'invalidInput':
            # A replacement placed for the full take that crosses the clip's range, or enabled again over another one.
            _, clip_range = resolve_scope(project['words'], project['edits'], clip_id)
            assert run_case(scope_replacements, project['segments'], clip_range, project['sampleRate'],
                            project['durationSeconds']) == {'error': 'invalidInput'}, placed
        else:
            assert placed['error'] in MULTI_REFUSALS, placed
        return False
    failure = render_failure(project, clip_id, placed)
    if failure is not None:
        multi_failures.append((failure, placed))
    return True


generator = Lcg(MULTI_SEED)
for index in range(MULTI_CASES):
    project, clip_id, envelope, first, last = fuzz_case(generator)
    ids = [item['id'] for item in project['words']]
    fuzz_replacements(generator, project, clip_id, envelope, ids.index(first), ids.index(last), multi_check)
    later = fuzz_later_edits(generator, project)
    multi['laterEdits'] += later
    multi['replacements'] += len(project['segments'])
    multi['disabledReplacements'] += sum(not segment['enabled'] for segment in project['segments'])
    expected = run_case(place, project, clip_id, envelope, first, last)
    if expected.get('error') == 'invalidInput' and 'segmentId' in expected:
        multi['invalidInputNamingReplacement'] += 1
    if multi_check(project, clip_id, expected):
        multi['accepted'] += 1
        multi['acceptedAfterLaterEdits'] += later
        # Beside a replacement: an enabled one in the scope with no transcript item between it and the window.
        _, clip_range = resolve_scope(project['words'], project['edits'], clip_id)
        start, end = expected['start'], expected['end']
        multi['acceptedBesideReplacement'] += any(
            not any(min(other['end'], end) <= item['start'] and item['end'] <= max(other['start'], start) for item in project['words'])
            for other in scope_replacements(project['segments'], clip_range, project['sampleRate'], project['durationSeconds']))
    else:
        multi['refused'][expected['error']] += 1
    if index % MULTI_STRIDE == 0 and len(multi_cases) < MULTI_SAMPLE:
        rate, duration, items = project['sampleRate'], project['durationSeconds'], project['words']
        case = {'name': 'multi-%05d' % index,
                'input': take_input(rate, duration, items, project['edits'], clip_id, envelope, project['segments']),
                'expected': expected, 'roomTone': run_case(room_tone, items, envelope, rate, samples(duration, rate))}
        case['input'].update(firstWordId=first, lastWordId=last)
        assert 'error' not in case['roomTone'], index
        multi_cases.append(case)
assert not multi_failures, multi_failures[:3]
multi['renderFailures'] = len(multi_failures)
multi['refused'] = {code: count for code, count in multi['refused'].items() if count}
print('multi-segment fuzz seed %d: %d cases, %d replacements (%d disabled), %d with later edits, %d accepted (%d beside a '
      'replacement, %d after later edits), refused %s (%d invalidInput naming a replacement), %d render failures, %d sampled'
      % (MULTI_SEED, MULTI_CASES, multi['replacements'], multi['disabledReplacements'], multi['laterEdits'], multi['accepted'],
         multi['acceptedBesideReplacement'], multi['acceptedAfterLaterEdits'], multi['refused'],
         multi['invalidInputNamingReplacement'], len(multi_failures), len(multi_cases)))

cases = {
    'schema': 'voxclip-voice-lab-window-cases/3',
    'constants': {'SEAM_MIN_GAP': SEAM_MIN_GAP, 'SEAM_SEARCH_WORDS': SEAM_SEARCH_WORDS, 'SEAM_FADE': SEAM_FADE,
                  'HARD_SEAM_FADE': HARD_SEAM_FADE, 'TTS_TRIM_LEAD': TTS_TRIM_LEAD, 'TTS_TRIM_TAIL': TTS_TRIM_TAIL,
                  'PAUSE_SLACK_KEEP': PAUSE_SLACK_KEEP, 'VOICED_FRAME': VOICED_FRAME, 'VOICED_FRAME_LEVEL': VOICED_FRAME_LEVEL,
                  'ROOM_TONE_MIN_RUN': ROOM_TONE_MIN_RUN, 'RMS_FRAME': RMS_FRAME},
    'window': window, 'handles': handles, 'trimHandles': trim_handles, 'alignment': alignment, 'trim': trim,
    'relativeWords': relative, 'roomTone': room, 'propertyFuzz': fuzz, 'propertyCases': '@@propertyCases@@',
    'multiSegmentFuzz': multi, 'multiSegmentCases': '@@multiSegmentCases@@',
}
cases['caseCount'] = len(property_cases) + len(multi_cases) + sum(len(cases[key]) for key in (
    'window', 'handles', 'trimHandles', 'alignment', 'trim', 'relativeWords', 'roomTone'))
# One property case per line keeps the file reviewable.
text = json.dumps(cases, indent=2)
for key, sample in (('propertyCases', property_cases), ('multiSegmentCases', multi_cases)):
    text = text.replace('"@@%s@@"' % key, '[\n' + ',\n'.join('    ' + json.dumps(case) for case in sample) + '\n  ]')
OUT.write_text(text + '\n')
