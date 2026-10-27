#!/usr/bin/env python3
"""Independent reference for the Voice Lab fit planner (voice-lab.md sections 8.9 and 8.9.2).

generate.py runs this module, which writes shared/fixtures/voice-lab/fit-cases.json: named vectors for every pause
rule, limit, seam kind, take edge, rounding path and refusal, and a seeded property section that both native Cores
replay. Standard library only; the output is byte-identical on every run.
"""
import json
import math
import struct
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/fit-cases.json'

# section 8.3, in seconds unless named otherwise; VoiceLabPatchConstants holds the same values on both platforms.
SEAM_FADE = 0.020
HARD_SEAM_FADE = 0.012
TTS_TRIM_LEAD = 0.03
TTS_TRIM_TAIL = 0.06
PAUSE_SLACK_KEEP = 0.15
SEAM_PAD_MAX = 0.3
HARD_SEAM_PAD_MAX = 0.060
PAUSE_FLOOR_PHRASE = 0.060
PAUSE_FLOOR_PUNCT = 0.150
PAUSE_GROWTH_MAX = 0.25
LENGTH_AIM_MIN = 0.92
LENGTH_AIM_MAX = 0.97
VOICED_FRAME = -45.0
VOICED_FRAME_LEVEL = 0.005623413251903491
RMS_FRAME = 0.010
SAMPLE_LIMIT = float(2 ** 53)  # sample counts below this stay exact in binary64
FRAME_LIMIT = 2 ** 31          # paid-asset frames: every product in the proportional split fits in Int64
# Source rates the planner accepts: the schema's 1 Hz floor, and a ceiling under which no borrow overflows Int64.
SOURCE_RATE_MIN, SOURCE_RATE_MAX = 1.0, 1000000.0

# The source is ASCII: other characters are written with chr(), so a reviewer can see what each vector tests.
assert Path(__file__).read_text(encoding='utf-8').isascii(), 'write non-ASCII characters with chr()'


class FitError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


# The reference helpers of generate_window.py: editing section 4.1 jsRound, the 10 ms envelope frame and binary32.

def js_round(x):
    floor = math.floor(x)
    return floor + 1 if x - floor >= 0.5 else floor


def whole(seconds, rate):
    """Seconds to whole frames or samples."""
    return js_round(seconds * rate)


def frame_size(rate):
    return max(1, js_round(rate * RMS_FRAME))


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def number(*values):
    return all(isinstance(value, float) and math.isfinite(value) for value in values)


def is_punctuation(token):
    """The token's last Unicode scalar has general category P (Pc, Pd, Ps, Pe, Pi, Pf or Po)."""
    return unicodedata.category(token[-1])[0] == 'P'


def spread(amount, group, lengths, rooms, alloc):
    """Distribution steps 1 and 2: amount frames over the pauses in group, in proportion to their lengths. Every pause
    whose exact share would pass its room stops at the room, and the rest is spread again over the others. The last
    spread is split by the largest-remainder rule: each pause takes the floor of its share, and the frames left over go
    one each to the largest remainders, ties to the earlier pause. Returns what the group cannot hold. An amount that
    covers every room fills each pause to its room, as the spread would; below that, every product stays under 2^62."""
    active = [i for i in group if rooms[i] > 0]
    if amount >= sum(rooms[i] for i in active):
        for i in active:
            alloc[i] = rooms[i]
        return amount - sum(rooms[i] for i in active)
    while amount > 0 and active:
        total = sum(lengths[i] for i in active)
        full = [i for i in active if amount * lengths[i] > rooms[i] * total]
        if full:
            for i in full:
                alloc[i] = rooms[i]
                amount -= rooms[i]
            active = [i for i in active if i not in full]
            continue
        shares = [amount * lengths[i] // total for i in active]
        remainders = [amount * lengths[i] % total for i in active]
        for j in sorted(range(len(active)), key=lambda j: (-remainders[j], j))[:amount - sum(shares)]:
            shares[j] += 1
        for j, i in enumerate(active):
            alloc[i] = shares[j]
        amount = 0
    return amount


def split(amount, caps):
    """Distribution step 3: half at each seam, the incoming seam taking the odd frame or sample. A seam at its limit
    passes the rest to the other seam."""
    first, second = min(amount - amount // 2, caps[0]), min(amount // 2, caps[1])
    rest = amount - first - second
    more = min(rest, caps[1] - second)
    return [first + min(rest - more, caps[0] - first), second + more]


def word_spans(words, asset_rate):
    """A word covers every paid-asset frame its aligned span touches."""
    return [(math.floor(start * asset_rate), math.ceil(end * asset_rate)) for _, start, end in words]


def window_times(window, rate):
    return (window['start'] if 'start' in window else window['startSample'] / rate,
            window['end'] if 'end' in window else window['endSample'] / rate)


def plan_fit(case):
    """Section 8.9.2 for one vector input. Returns the result object or raises FitError."""
    window, take, tokens = case['window'], case['take'], case['tokens']
    rate, asset_rate, total = case['sourceSampleRate'], take['assetSampleRate'], take['assetFrames']
    kinds = (window['leftKind'], window['rightKind'])
    silences = (case['incomingSilence'], case['outgoingSilence'])
    envelope = take['envelope']
    levels = [level for level, count in envelope['runs'] for _ in range(count)]

    # Inputs, in this order: invalidInput, alignmentUnavailable, alignmentMismatch, invalidWordTiming.
    if not (number(rate) and SOURCE_RATE_MIN <= rate <= SOURCE_RATE_MAX and isinstance(asset_rate, int) and asset_rate > 0
            and 0 < total < FRAME_LIMIT):
        raise FitError('invalidInput')
    start_sample, end_sample = window['startSample'], window['endSample']
    start, end = window_times(window, rate)
    if not (all(kind in ('none', 'gap', 'hard') for kind in kinds) and 0 <= start_sample < end_sample
            and (kinds[0] != 'none' or start_sample == 0) and number(start, end)):
        raise FitError('invalidInput')
    for kind, silence in zip(kinds, silences):
        if (kind == 'hard') != (silence is None) or silence is not None and not (
                number(silence) and silence >= 0 and silence * rate < SAMPLE_LIMIT and silence * asset_rate < SAMPLE_LIMIT):
            raise FitError('invalidInput')
    reach = [whole(silence, rate) if kind == 'gap' else 0 for kind, silence in zip(kinds, silences)]
    if reach[0] > start_sample or float(end_sample + reach[1]) * float(asset_rate) >= SAMPLE_LIMIT:
        raise FitError('invalidInput')
    size = frame_size(asset_rate)
    if envelope['sampleRate'] != asset_rate or len(levels) != total // size or \
            any(not (math.isfinite(level) and level >= 0) for level in levels):
        raise FitError('invalidInput')
    trim_start, trim_end = take['trimStart'], take['trimEnd']
    if not (number(trim_start, trim_end) and 0 <= trim_start < trim_end and trim_start * asset_rate < SAMPLE_LIMIT
            and trim_end * asset_rate < SAMPLE_LIMIT):
        raise FitError('invalidInput')
    t0, t1 = whole(trim_start, asset_rate), whole(trim_end, asset_rate)
    if not 0 <= t0 < t1 <= total:
        raise FitError('invalidInput')
    words = take['words']
    if not words:
        raise FitError('alignmentUnavailable')
    if len(tokens) != len(words) or '' in tokens or any(not word[0] for word in words):
        raise FitError('alignmentMismatch')
    previous = 0.0
    for _, w_start, w_end in words:
        if not (number(w_start, w_end) and previous <= w_start < w_end and (w_end - w_start) * rate >= 1
                and w_end * asset_rate < SAMPLE_LIMIT):
            raise FitError('invalidWordTiming')
        previous = w_end
    spans = word_spans(words, asset_rate)
    if spans[0][0] < t0 or spans[-1][1] > t1:
        raise FitError('invalidWordTiming')

    # Pauses: the longest run of whole envelope frames, counted from the paid asset's first sample, between two words'
    # spans with every frame below VOICED_FRAME. Ties go to the earliest run.
    unvoiced = [float(level) < VOICED_FRAME_LEVEL for level in levels]
    pauses = []
    for k in range(len(words) - 1):
        best, first, run = 0, 0, 0
        for block in range((spans[k][1] + size - 1) // size, min(spans[k + 1][0] // size, len(levels))):
            run = run + 1 if unvoiced[block] else 0
            if run > best:
                best, first = run, block + 1 - run
        if best:
            pauses.append({'word': k, 'start': first * size, 'end': (first + best) * size,
                           'punctuation': is_punctuation(tokens[k])})

    # The take must fill w = duration(W) - e frames; rho > 0 means it is too long.
    fade = whole(SEAM_FADE, asset_rate)
    edge = [max(0, whole(silences[0], asset_rate) - (spans[0][0] - t0)) if kinds[0] == 'none' else 0,
            max(0, whole(silences[1], asset_rate) - (t1 - spans[-1][1])) if kinds[1] == 'none' else 0]
    n = end_sample - start_sample
    target = js_round(float(n) * float(asset_rate) / rate)
    natural = edge[0] + edge[1] + t1 - t0
    rho = natural - target
    shorten = rho > 0
    lengths = [p['end'] - p['start'] for p in pauses]
    if shorten:
        floors = {True: whole(PAUSE_FLOOR_PUNCT, asset_rate), False: whole(PAUSE_FLOOR_PHRASE, asset_rate)}
        rooms = [max(0, length - floors[p['punctuation']]) for p, length in zip(pauses, lengths)]
    else:
        # One edit per pause, centred in its run, with one SEAM_FADE join whose halves both lie in the run.
        growth = whole(PAUSE_GROWTH_MAX, asset_rate)
        rooms = [min(growth, length - fade) if length > fade else 0 for length in lengths]
    alloc = [0] * len(pauses)
    remaining = abs(rho)
    for punctuation in (True, False):
        group = [i for i, p in enumerate(pauses) if p['punctuation'] == punctuation]
        remaining = spread(remaining, group, lengths, rooms, alloc)

    # Seams: borrow source samples into a gap, keeping PAUSE_SLACK_KEEP beside the kept word, or pad silence.
    borrow, pad, exact, lend = [0, 0], list(edge), True, [0, 0]
    if remaining and shorten:
        keep = whole(PAUSE_SLACK_KEEP, rate)
        caps = lend = [max(0, value - keep) for value in reach]
        widest = js_round(float(n + caps[0] + caps[1]) * float(asset_rate) / rate)
        if target + remaining <= widest:
            borrow = split(js_round(float(remaining) * rate / float(asset_rate)), caps)
        else:
            borrow, exact = caps, False
    elif remaining:
        caps = [whole(HARD_SEAM_PAD_MAX if kind == 'hard' else SEAM_PAD_MAX, asset_rate) for kind in kinds]
        extra = split(remaining, caps)
        pad = [pad[0] + extra[0], pad[1] + extra[1]]
        exact = extra[0] + extra[1] == remaining
    deltas = [-a if shorten else a for a in alloc]
    n_final = n + borrow[0] + borrow[1]
    window_frames = js_round(float(n_final) * float(asset_rate) / rate)
    output = pad[0] + t1 - t0 + sum(deltas) + pad[1]
    if exact and output != window_frames:
        # The rounding residual: a gap or edge pad, incoming first, while it stays non-negative; then the tail trim,
        # then the lead trim, each keeping the aligned words inside the trim and the trim inside the asset.
        residual = window_frames - output
        if kinds[0] != 'hard' and pad[0] + residual >= 0:
            pad[0] += residual
        elif kinds[1] != 'hard' and pad[1] + residual >= 0:
            pad[1] += residual
        elif spans[-1][1] <= t1 + residual <= total:
            t1 += residual
        elif 0 <= t0 - residual <= spans[0][0]:
            t0 -= residual
        elif borrow[0] + borrow[1] < lend[0] + lend[1]:
            # Nothing can take a negative residual: the seams borrow the fewest more source samples whose widened
            # window holds the planned frames, within their limits and split again, and the residual, now zero or
            # more, pads the gap seam that borrowed, the incoming one first.
            lent = borrow[0] + borrow[1]
            while lent < lend[0] + lend[1] and js_round(float(n + lent) * float(asset_rate) / rate) < output:
                lent += 1
            borrow = split(lent, lend)
            window_frames = js_round(float(n + lent) * float(asset_rate) / rate)
            if window_frames < output:
                raise FitError('fitTouchesVoice')
            pad[0 if borrow[0] else 1] += window_frames - output
        else:
            raise FitError('fitTouchesVoice')
        output = window_frames

    edits = [['remove' if shorten else 'insert', p['start'] + (p['end'] - p['start'] - a) // 2, a]
             for p, a in zip(pauses, alloc) if a]
    by_word = {p['word']: delta for p, delta in zip(pauses, deltas)}
    out_words, shift = [], 0
    for k, (_, w_start, w_end) in enumerate(words):
        offset = pad[0] - t0 + shift
        out_words.append([w_start + offset / asset_rate, w_end + offset / asset_rate])
        shift += by_word.get(k, 0)
    result = {'result': 'exact' if exact else 'changedDuration'}
    window_start = (start_sample - borrow[0]) / rate
    window_end = (end_sample + borrow[1]) / rate
    # Each word ends inside the output the recipe states: the window, plus residualSeconds after a partial fit.
    duration = window_end - window_start
    if not exact:
        result.update(naturalOut=natural / asset_rate, residualSeconds=(output - window_frames) / asset_rate)
        duration = window_end - window_start + result['residualSeconds']
    out_words = [[min(w_start, duration), min(w_end, duration)] for w_start, w_end in out_words]
    previous = 0.0
    for w_start, w_end in out_words:
        if not (w_start >= previous and w_end > w_start and w_end <= duration
                and whole(w_end, rate) > whole(w_start, rate) and whole(w_end, rate) <= whole(duration, rate)):
            raise FitError('invalidWordTiming')
        previous = w_end
    result.update(edits=edits, incoming=[pad[0], borrow[0]], outgoing=[pad[1], borrow[1]], trims=[t0, t1],
                  window=[start_sample - borrow[0], end_sample + borrow[1]], outputFrames=output,
                  windowStart=window_start, windowEnd=window_end, words=out_words)
    check_voice(result, spans, unvoiced, size, fade)
    return result


def check_voice(result, spans, unvoiced, size, fade):
    """The never-touch-voice invariant both Cores assert before returning a plan: every edit and its join lie inside
    the trim, in order and apart, clear of every word span and of every envelope frame at or above VOICED_FRAME, so
    every other output sample is a copy of its paid frame; and the output length adds up."""
    t0, t1 = result['trims']
    cursor, frames = t0, result['incoming'][0] + result['outgoing'][0] + t1 - t0
    if min(result['incoming'][0], result['outgoing'][0]) < 0:
        raise FitError('fitTouchesVoice')
    for kind, start, count in result['edits']:
        lo, hi = start - fade // 2, start + count + fade - fade // 2
        if not (count > 0 and cursor <= lo and hi <= t1) or any(a < hi and lo < b for a, b in spans) or \
                not all(block < len(unvoiced) and unvoiced[block] for block in range(lo // size, (hi + size - 1) // size)):
            raise FitError('fitTouchesVoice')
        cursor = hi
        frames += count if kind == 'insert' else -count
    if frames != result['outputFrames']:
        raise FitError('fitTouchesVoice')


def run_case(case):
    try:
        return plan_fit(case)
    except FitError as error:
        return {'error': error.code}


# Vector inputs. A take is a paid asset with its section 8.7 trims, aligned words and 10 ms envelope; the window comes
# from section 8.4 with the outside silence of each gap and take-edge seam. A window's times default to its samples
# divided by the source rate.

SPEECH = 0.25
QUIET = 0.0009765625   # 2^-10, about -60 dBFS: a pause frame


def f32_step(value, steps):
    bits = struct.unpack('<I', struct.pack('<f', value))[0]
    return struct.unpack('<f', struct.pack('<I', bits + steps))[0]


# The binary32 levels on either side of VOICED_FRAME: a frame at or above it is voiced, one below it is a pause frame.
ABOVE = f32(VOICED_FRAME_LEVEL) if f32(VOICED_FRAME_LEVEL) >= VOICED_FRAME_LEVEL else f32_step(f32(VOICED_FRAME_LEVEL), 1)
BELOW = f32_step(ABOVE, -1)
assert float(BELOW) < VOICED_FRAME_LEVEL <= float(ABOVE)
# Each Core reads General Category from its platform's Unicode tables, as this reference does, so the vectors use only
# scalars whose category every Unicode version agrees on.
ELLIPSIS, RIGHT_GUILLEMET, LEFT_DOUBLE_QUOTE = chr(0x2026), chr(0xBB), chr(0x201C)


def runs(levels):
    out = []
    for level in levels:
        if out and out[-1][0] == level:
            out[-1][1] += 1
        else:
            out.append([level, 1])
    return out


def take_levels(words, asset_rate, total, overrides):
    """SPEECH on every envelope frame a word span touches and QUIET elsewhere, then each override (start, end, level),
    in asset seconds, on every frame it touches."""
    size = frame_size(asset_rate)
    spans = word_spans(words, asset_rate)
    levels = [SPEECH if any(lo < block * size + size and block * size < hi for lo, hi in spans) else QUIET
              for block in range(total // size)]
    for start, end, level in overrides:
        lo, hi = math.floor(start * asset_rate), math.ceil(end * asset_rate)
        for block in range(lo // size, min(len(levels), (hi + size - 1) // size)):
            levels[block] = level
    return levels


def window_samples(frames, asset_rate, rate):
    """The fewest source samples whose window holds exactly `frames` asset frames, or else the nearest count."""
    guess = js_round(float(frames) * rate / float(asset_rate))
    return min(range(max(1, guess - 3), guess + 4),
               key=lambda n: (abs(js_round(float(n) * float(asset_rate) / rate) - frames), n))


def edge_pads(case):
    """The section 8.9.2 edge pads of a valid input, as plan_fit computes them."""
    take, window = case['take'], case['window']
    rate = take['assetSampleRate']
    t0, t1 = whole(take['trimStart'], rate), whole(take['trimEnd'], rate)
    spans = word_spans(take['words'], rate)
    return (max(0, whole(case['incomingSilence'], rate) - (spans[0][0] - t0)) if window['leftKind'] == 'none' else 0,
            max(0, whole(case['outgoingSilence'], rate) - (t1 - spans[-1][1])) if window['rightKind'] == 'none' else 0)


def natural_frames(case):
    """The edge pads and the trimmed take, in asset frames: e + D."""
    take = case['take']
    return sum(edge_pads(case)) + whole(take['trimEnd'], take['assetSampleRate']) - whole(take['trimStart'], take['assetSampleRate'])


def rho_of(case):
    """The natural length less the window, in asset frames."""
    n = case['window']['endSample'] - case['window']['startSample']
    return natural_frames(case) - js_round(float(n) * float(case['take']['assetSampleRate']) / case['sourceSampleRate'])


def fit_input(words, asset_rate=44100, rate=48000.0, asset_end=None, kinds=('gap', 'gap'), silences=(0.6, 0.6), rho=0,
              window=None, start=None, tokens=None, overrides=(), trim=None):
    """A vector input. `words` are (text, start, end) in asset seconds and the trims follow section 8.7 step 1 unless
    given. The window is the take's natural length minus `rho` asset frames, unless `window` gives its source samples.
    A hard seam has no outside silence."""
    words = [[text, s, e] for text, s, e in words]
    asset_end = words[-1][2] + 0.2 if asset_end is None else asset_end
    total = js_round(asset_end * asset_rate)
    if trim is None:
        trim = (max(0.0, words[0][1] - TTS_TRIM_LEAD), min(total / asset_rate, words[-1][2] + TTS_TRIM_TAIL))
    silences = tuple(None if kind == 'hard' else silence for kind, silence in zip(kinds, silences))
    case = {'sourceSampleRate': rate, 'window': {'startSample': 0, 'endSample': 1, 'leftKind': kinds[0], 'rightKind': kinds[1]},
            'incomingSilence': silences[0], 'outgoingSilence': silences[1],
            'take': {'assetFrames': total, 'assetSampleRate': asset_rate, 'trimStart': trim[0], 'trimEnd': trim[1],
                     'words': words, 'envelope': {'sampleRate': asset_rate,
                                                  'runs': runs(take_levels(words, asset_rate, total, overrides))}},
            'tokens': list(tokens) if tokens is not None else [w[0] for w in words]}
    if window is None:
        window = window_samples(natural_frames(case) - rho, asset_rate, rate)
    if start is None:
        start = 0 if kinds[0] == 'none' else whole((silences[0] or 0.0) + 0.5, rate)
    case['window'].update(startSample=start, endSample=start + window)
    return case


NAMED, FAILURES = [], []


def vector(name, category, note, case, check=None):
    """Adds a named vector. `check` states what the vector pins, so a generator change that loses it fails the run."""
    expected = run_case(case)
    if check is not None and not check(expected):
        FAILURES.append((name, expected))
    NAMED.append({'name': name, 'category': category, 'note': note, 'input': case, 'expected': expected})
    return expected


def search(name, category, note, make, check, tries=3000):
    """The first input `make(i)` whose result passes `check`, as a named vector."""
    for i in range(tries):
        case = make(i)
        if check(case, run_case(case)):
            return vector(name, category, note, case)
    FAILURES.append((name, 'no input found'))


def edits(result):
    return [tuple(edit) for edit in result['edits']]


def counts(result):
    return [edit[2] for edit in result['edits']]


def seams(result):
    return tuple(result['incoming'] + result['outgoing'])


def is_exact(result):
    return result.get('result') == 'exact'


def is_changed(result):
    return result.get('result') == 'changedDuration'


def trims_moved(case, result):
    take = case['take']
    rate = take['assetSampleRate']
    return result['trims'][0] - whole(take['trimStart'], rate), result['trims'][1] - whole(take['trimEnd'], rate)


# A four-word sentence trimmed to [0.02, 1.96] s, with each word edge 0.1 ms inside its 10 ms envelope frame so no
# rounding moves a pause: a 350 ms punctuation pause after "Well," and intra-phrase pauses of 200 and 150 ms. At 44.1 kHz
# an envelope frame is 441 frames, and the pauses are 15,435, 8,820 and 6,615 frames. Shortening can take 8,820, 6,174
# and 3,969 frames (to 150, 60 and 60 ms); lengthening can add 11,025 (PAUSE_GROWTH_MAX), 7,938 and 5,733 (each run
# less SEAM_FADE).
SENTENCE = [('Well,', 0.05, 0.3999), ('this', 0.7501, 0.9499), ('is', 1.1501, 1.2999), ('it.', 1.4501, 1.90)]
SHORTEN_ROOM = 8820 + 6174 + 3969
LENGTHEN_ROOM = 11025 + 7938 + 5733
ONE_WORD = [('Absolutely', 0.05, 1.05)]

# Pauses.
vector('pause-punctuation-first', 'pauses', 'Too long by 150 ms: the punctuation pause gives all of it, centred in its '
       'run, before any intra-phrase pause changes.', fit_input(SENTENCE, rho=6615),
       lambda r: is_exact(r) and edits(r) == [('remove', 22050, 6615)])
vector('pause-punctuation-versus-phrase', 'pauses', 'Two 300 ms pauses, one after "today," and one after "and": only '
       'the punctuation pause shortens.',
       fit_input([('today,', 0.05, 0.4999), ('and', 0.8001, 0.9999), ('then', 1.3001, 1.60)], rho=2205,
                 kinds=('hard', 'hard')),
       lambda r: is_exact(r) and edits(r) == [('remove', 22050 + (13230 - 2205) // 2, 2205)])
vector('pause-at-floor', 'pauses', 'A punctuation pause of exactly 150 ms is at its floor and is not shortened; the '
       'intra-phrase pause gives the time instead.',
       fit_input([('Yes.', 0.05, 0.3999), ('We', 0.5501, 0.7499), ('ship', 1.0501, 1.40)], rho=2205, kinds=('hard', 'hard')),
       lambda r: is_exact(r) and edits(r) == [('remove', 33075 + (13230 - 2205) // 2, 2205)])
vector('pause-at-floor-lengthens', 'pauses', 'The same 150 ms pause at its floor lengthens when the take is too short, '
       'punctuation first.',
       fit_input([('Yes.', 0.05, 0.3999), ('We', 0.5501, 0.7499), ('ship', 1.0501, 1.40)], rho=-2205, kinds=('hard', 'hard')),
       lambda r: is_exact(r) and edits(r) == [('insert', 17640 + (6615 - 2205) // 2, 2205)])
vector('pause-run-shorter-than-fade', 'pauses', 'A 10 ms run is shorter than SEAM_FADE and is never edited: the take '
       'pads at its seams instead.',
       fit_input([('one,', 0.05, 0.3999), ('two', 0.4101, 0.80)], rho=-1000),
       lambda r: is_exact(r) and edits(r) == [] and seams(r) == (500, 0, 500, 0))
vector('pause-run-equal-to-fade', 'pauses', 'A 20 ms run equals SEAM_FADE: its one join needs the whole run, so it has '
       'no room to lengthen and the take pads instead.',
       fit_input([('one,', 0.05, 0.3999), ('two', 0.4201, 0.80)], rho=-1000),
       lambda r: is_exact(r) and edits(r) == [] and seams(r) == (500, 0, 500, 0))
vector('pause-run-just-longer-than-fade', 'pauses', 'A 30 ms run can lengthen by 10 ms (the run less SEAM_FADE); the '
       'rest pads.',
       fit_input([('one,', 0.05, 0.3999), ('two', 0.4301, 0.80)], rho=-1000),
       lambda r: is_exact(r) and edits(r) == [('insert', 17640 + 441, 441)] and seams(r) == (280, 0, 279, 0))
vector('pause-longest-run', 'pauses', 'A voiced breath splits a 400 ms gap into runs of 120 and 250 ms: the longer '
       'run is the pause, and its length decides its room.',
       fit_input([('Right,', 0.05, 0.3999), ('so', 0.8001, 1.10)], rho=3000, kinds=('hard', 'hard'),
                 overrides=[(0.5201, 0.5499, SPEECH)]),
       lambda r: is_exact(r) and edits(r) == [('remove', 24255 + (11025 - 3000) // 2, 3000)])
vector('pause-longest-run-tie', 'pauses', 'Two equal 150 ms runs around a breath: the earlier run is the pause.',
       fit_input([('Right,', 0.05, 0.3999), ('so', 0.7601, 1.10)], rho=-1000, kinds=('hard', 'hard'),
                 overrides=[(0.5501, 0.6099, SPEECH)]),
       lambda r: is_exact(r) and edits(r) == [('insert', 17640 + (6615 - 1000) // 2, 1000)])
vector('pause-threshold-above', 'pauses', 'A frame at the binary32 level just above VOICED_FRAME is voiced: it splits '
       'the 400 ms gap into runs of 200 and 190 ms, and the earlier, longer run is the pause.',
       fit_input([('Right,', 0.05, 0.3999), ('so', 0.8001, 1.10)], rho=2000, kinds=('hard', 'hard'),
                 overrides=[(0.6001, 0.6099, ABOVE)]),
       lambda r: is_exact(r) and edits(r) == [('remove', 17640 + (8820 - 2000) // 2, 2000)])
vector('pause-threshold-below', 'pauses', 'A frame at the binary32 level just below VOICED_FRAME stays a pause '
       'frame, so the 400 ms run stays whole.',
       fit_input([('Right,', 0.05, 0.3999), ('so', 0.8001, 1.10)], rho=2000, kinds=('hard', 'hard'),
                 overrides=[(0.6001, 0.6099, BELOW)]),
       lambda r: is_exact(r) and edits(r) == [('remove', 17640 + (17640 - 2000) // 2, 2000)])
vector('pause-frames-from-asset-start', 'pauses', 'At 22.05 kHz an envelope frame is jsRound(220.5) = 221 samples, '
       'counted from the paid asset\'s first sample rather than from the trim at sample 470: the run is frames 9 to 29, '
       'samples 1,989 to 6,630.',
       fit_input([('Hi,', 0.0513, 0.0897), ('there', 0.3034, 0.6011)], asset_rate=22050, rho=800, kinds=('hard', 'hard')),
       lambda r: is_exact(r) and r['trims'][0] == 470 and edits(r) == [('remove', 1989 + (4641 - 800) // 2, 800)])
vector('pause-take-edges-are-not-pauses', 'pauses', 'The lead and tail silence inside the trims is not an internal '
       'pause: a one-word take that is too long has nothing to shorten.',
       fit_input(ONE_WORD, rho=500, kinds=('hard', 'hard')),
       lambda r: is_changed(r) and edits(r) == [])
vector('punctuation-categories', 'pauses', 'Tokens ending in an ellipsis (Po), a right guillemet (Pf), a closing '
       'parenthesis (Pe), a left double quote (Pi) and a percent sign (Po) are punctuation pauses; a dollar sign (Sc) '
       'and a digit (Nd) are not.',
       fit_input([('one', 0.05, 0.2999), ('two', 0.6001, 0.8499), ('three', 1.1501, 1.3999), ('four', 1.7001, 1.9499),
                  ('five', 2.2501, 2.4999), ('six', 2.8001, 3.0499), ('seven', 3.3501, 3.5999), ('eight', 3.9001, 4.15)],
                 tokens=['one' + ELLIPSIS, 'two' + RIGHT_GUILLEMET, 'three)', 'four' + LEFT_DOUBLE_QUOTE, '5%', 'six$',
                         'seven2', 'eight'], rho=5 * 4410, kinds=('hard', 'hard')),
       lambda r: is_exact(r) and edits(r) == [('remove', start + 4410, 4410) for start in (13230, 37485, 61740, 85995, 110250)])

# Limits.
vector('limit-punctuation-floor', 'limits', 'The punctuation pause stops at PAUSE_FLOOR_PUNCT (150 ms = 6,615 '
       'frames); the intra-phrase pauses take the rest in proportion to their lengths (8,820 : 6,615).',
       fit_input(SENTENCE, rho=8820 + 4410),
       lambda r: is_exact(r) and counts(r) == [8820, 2520, 1890])
vector('limit-phrase-floor', 'limits', 'Every pause stops at its floor (150, 60 and 60 ms) and the last 2,205 frames '
       'are borrowed: 2,400 source samples, 1,200 at each gap seam.', fit_input(SENTENCE, rho=SHORTEN_ROOM + 2205),
       lambda r: is_exact(r) and counts(r) == [8820, 6174, 3969] and seams(r) == (0, 1200, 0, 1200))
vector('limit-growth-max', 'limits', 'The punctuation pause grows by exactly PAUSE_GROWTH_MAX (11,025 frames) and the '
       'intra-phrase pauses take the rest, 2,520 and 1,890.', fit_input(SENTENCE, rho=-(11025 + 4410)),
       lambda r: is_exact(r) and counts(r) == [11025, 2520, 1890])
vector('limit-growth-run', 'limits', 'The intra-phrase pauses grow only by their runs less SEAM_FADE (7,938 and 5,733 '
       'frames), and the rest pads equally at the two gap seams.', fit_input(SENTENCE, rho=-(LENGTHEN_ROOM + 2205)),
       lambda r: is_exact(r) and counts(r) == [11025, 7938, 5733] and seams(r) == (1103, 0, 1102, 0))
vector('limit-pad-gap', 'limits', 'Each gap seam pads at most SEAM_PAD_MAX (300 ms = 13,230 frames); 441 frames remain '
       'and the duration changes.', fit_input(SENTENCE, rho=-(LENGTHEN_ROOM + 2 * 13230 + 441)),
       lambda r: is_changed(r) and seams(r) == (13230, 0, 13230, 0) and r['residualSeconds'] == -441 / 44100)
vector('limit-pad-hard', 'limits', 'Each hard seam pads at most HARD_SEAM_PAD_MAX (60 ms = 2,646 frames).',
       fit_input(SENTENCE, kinds=('hard', 'hard'), rho=-(LENGTHEN_ROOM + 2 * 2646 + 441)),
       lambda r: is_changed(r) and seams(r) == (2646, 0, 2646, 0))
vector('limit-pad-edge', 'limits', 'A take edge pads at most SEAM_PAD_MAX beyond its edge pad: 16,317 + 13,230 frames '
       'at the take start.', fit_input(SENTENCE, kinds=('none', 'gap'), silences=(0.4, 0.6),
                                       rho=-(LENGTHEN_ROOM + 2 * 13230 + 441)),
       lambda r: is_changed(r) and seams(r) == (16317 + 13230, 0, 13230, 0))
vector('limit-borrow-slack', 'limits', 'Borrowing keeps PAUSE_SLACK_KEEP (7,200 samples at 48 kHz) beside each kept '
       'word: 0.4 s and 0.2 s of outside silence lend 12,000 and 2,400 samples, and the duration changes.',
       fit_input(ONE_WORD, silences=(0.4, 0.2), rho=17640),
       lambda r: is_changed(r) and seams(r) == (0, 12000, 0, 2400) and r['residualSeconds'] == 4410 / 44100)

# Redistribution at limits.
vector('redistribute-punctuation', 'redistribution', 'Punctuation pauses of 400 and 200 ms share 300 ms as 200 : 100; '
       'the shorter one stops at its floor after 50 ms, and the longer one takes the remaining 250 ms.',
       fit_input([('First,', 0.05, 0.3999), ('then.', 0.8001, 1.0999), ('Done', 1.3001, 1.60)], rho=13230,
                 kinds=('hard', 'hard')),
       lambda r: is_exact(r) and counts(r) == [11025, 2205])
vector('redistribute-to-phrase', 'redistribution', 'With the punctuation pause at its floor, the last 100 frames go '
       'to the intra-phrase pauses: shares of 57.1 and 42.9 give 57 and 42, and the frame left over goes to the larger '
       'remainder.', fit_input(SENTENCE, rho=8820 + 100, kinds=('hard', 'hard')),
       lambda r: is_exact(r) and counts(r) == [8820, 57, 43])
vector('redistribute-tie-earlier', 'redistribution', 'Three equal punctuation pauses share 4 frames: each takes one, and '
       'the frame left over goes to the earliest of the equal remainders.',
       fit_input([('a,', 0.05, 0.2999), ('b,', 0.6001, 0.8499), ('c,', 1.1501, 1.3999), ('d', 1.7001, 1.95)], rho=4,
                 kinds=('hard', 'hard'), rate=44100.0),
       lambda r: is_exact(r) and counts(r) == [2, 1, 1])
vector('redistribute-largest-remainder', 'redistribution', 'Pauses of 300, 200 and 100 ms share 7 frames: shares 3.5, '
       '2.33 and 1.17 give 3, 2 and 1, and the frame left over goes to the largest remainder (the first pause).',
       fit_input([('a,', 0.05, 0.2999), ('b,', 0.6001, 0.8499), ('c,', 1.0501, 1.2999), ('d', 1.4001, 1.65)], rho=-7,
                 kinds=('hard', 'hard'), rate=44100.0),
       lambda r: is_exact(r) and counts(r) == [4, 2, 1])
vector('redistribute-together', 'redistribution', 'Two 200 ms punctuation pauses pass their 50 ms rooms in the same '
       'round and both stop at their floors; the 1 s pause takes the rest.',
       fit_input([('a,', 0.05, 0.2999), ('b,', 0.5001, 0.7499), ('c,', 0.9501, 1.1999), ('d', 2.2001, 2.45)], rho=20000,
                 kinds=('hard', 'hard')),
       lambda r: is_exact(r) and counts(r) == [2205, 2205, 15590])

# Seams.
vector('seam-borrow-both-gaps', 'seams', 'With no pause, the residual is borrowed equally at the two gap seams.',
       fit_input(ONE_WORD, rate=44100.0, rho=1000), lambda r: is_exact(r) and seams(r) == (0, 500, 0, 500))
vector('seam-borrow-odd-sample', 'seams', 'An odd number of borrowed samples puts the extra sample at the incoming '
       'seam.', fit_input(ONE_WORD, rate=44100.0, rho=1001), lambda r: is_exact(r) and seams(r) == (0, 501, 0, 500))
vector('seam-borrow-passes-to-other', 'seams', 'The incoming gap lends only 441 samples (0.16 s less PAUSE_SLACK_KEEP), '
       'so it passes the rest of its half to the outgoing seam.',
       fit_input(ONE_WORD, rate=44100.0, silences=(0.16, 0.6), rho=2000),
       lambda r: is_exact(r) and seams(r) == (0, 441, 0, 1559))
vector('seam-borrow-hard-incoming', 'seams', 'A hard seam has no gap to borrow from: the outgoing gap lends everything.',
       fit_input(ONE_WORD, rate=44100.0, kinds=('hard', 'gap'), rho=2000),
       lambda r: is_exact(r) and seams(r) == (0, 0, 0, 2000))
vector('seam-borrow-none-incoming', 'seams', 'A take edge has no outside silence to borrow: the outgoing gap lends '
       'everything, and the edge pad stays.', fit_input(ONE_WORD, rate=44100.0, kinds=('none', 'gap'),
                                                        silences=(0.2, 0.6), rho=2000),
       lambda r: is_exact(r) and seams(r) == (7497, 0, 0, 2000))
vector('seam-silence-within-slack', 'seams', 'Outside silences of 0.1 and 0.15 s hold no more than PAUSE_SLACK_KEEP, so '
       'nothing is borrowed and the duration changes.', fit_input(ONE_WORD, silences=(0.1, 0.15), rho=500),
       lambda r: is_changed(r) and seams(r) == (0, 0, 0, 0))
vector('seam-pad-both-gaps', 'seams', 'With no pause, a short take pads equally at the two gap seams.',
       fit_input(ONE_WORD, rho=-2000), lambda r: is_exact(r) and seams(r) == (1000, 0, 1000, 0))
vector('seam-pad-odd-frame', 'seams', 'An odd number of padded frames puts the extra frame at the incoming seam.',
       fit_input(ONE_WORD, rho=-2001), lambda r: is_exact(r) and seams(r) == (1001, 0, 1000, 0))
vector('seam-pad-hard-passes', 'seams', 'A hard incoming seam stops at HARD_SEAM_PAD_MAX (2,646 frames) and passes the '
       'rest of its half to the outgoing gap seam.', fit_input(ONE_WORD, kinds=('hard', 'gap'), rho=-6000),
       lambda r: is_exact(r) and seams(r) == (2646, 0, 3354, 0))
vector('seam-pad-gap-to-hard', 'seams', 'A hard outgoing seam stops at its limit and passes the rest to the incoming '
       'gap seam.', fit_input(ONE_WORD, kinds=('gap', 'hard'), rho=-10000),
       lambda r: is_exact(r) and seams(r) == (7354, 0, 2646, 0))
OFF_GRID = fit_input(ONE_WORD, kinds=('hard', 'none'), silences=(None, 0.3), rho=-1000)
OFF_GRID['window'].update(start=OFF_GRID['window']['startSample'] / 48000 - 0.0000031,
                          end=OFF_GRID['window']['endSample'] / 48000 + 0.0000042)
vector('seam-times-off-grid', 'seams', 'A hard seam and the take end may lie off the sample grid, as section 8.4 places '
       'them. The planner returns both times on the source grid, even without borrowing.', OFF_GRID,
       lambda r: is_exact(r) and r['windowStart'] == r['window'][0] / 48000 and r['windowEnd'] == r['window'][1] / 48000
       and r['windowStart'] != OFF_GRID['window']['start'] and r['windowEnd'] != OFF_GRID['window']['end'])
OFF_GRID_BORROW = fit_input(ONE_WORD, kinds=('gap', 'hard'), rho=1000)
OFF_GRID_BORROW['window'].update(end=OFF_GRID_BORROW['window']['endSample'] / 48000 + 0.0000042)
vector('seam-times-borrowed', 'seams', 'A gap seam that borrows moves by whole source samples, and its time becomes the '
       'new sample over the source rate; the hard seam also returns its sample-grid time.', OFF_GRID_BORROW,
       lambda r: is_exact(r) and r['windowStart'] == r['window'][0] / 48000 and r['windowEnd'] == r['window'][1] / 48000)

# Take edges.
vector('edge-start', 'edges', 'At the take start the edge pad keeps the first aligned word 0.4 s from the edge, as in '
       'the source: 17,640 frames less the take\'s own 1,323-frame lead.',
       fit_input(SENTENCE, kinds=('none', 'gap'), silences=(0.4, 0.6)),
       lambda r: is_exact(r) and seams(r) == (16317, 0, 0, 0) and abs(r['words'][0][0] - 0.4) < 1e-12)
vector('edge-end', 'edges', 'At the take end the edge pad keeps the last aligned word 0.5 s from the end.',
       fit_input(SENTENCE, kinds=('gap', 'none'), silences=(0.6, 0.5)),
       lambda r: is_exact(r) and seams(r) == (0, 0, 19404, 0))
vector('edge-both', 'edges', 'A window over the whole take has an edge pad at each end, and e is their sum. A take too '
       'short for its pauses pads equally beyond both edge pads.',
       fit_input(SENTENCE, kinds=('none', 'none'), silences=(0.4, 0.5), rho=-(LENGTHEN_ROOM + 2000)),
       lambda r: is_exact(r) and seams(r) == (16317 + 1000, 0, 19404 + 1000, 0))
vector('edge-never-negative', 'edges', 'The source word starts only 10 ms after the take start, nearer than the take\'s '
       '30 ms lead: the edge pad is 0, never negative.', fit_input(SENTENCE, kinds=('none', 'gap'), silences=(0.01, 0.6)),
       lambda r: is_exact(r) and seams(r) == (0, 0, 0, 0))
vector('edge-pads-beyond', 'edges', 'A short take at both edges pads up to SEAM_PAD_MAX at each edge beyond its edge pad.',
       fit_input(ONE_WORD, kinds=('none', 'none'), silences=(0.3, 0.3), rho=-26460),
       lambda r: is_exact(r) and seams(r) == (11907 + 13230, 0, 10584 + 13230, 0))
vector('edge-too-long', 'edges', 'A long take at the take start keeps its edge pad and shortens its pauses; the take '
       'edge lends nothing.', fit_input(SENTENCE, kinds=('none', 'hard'), silences=(0.4, None), rho=6615),
       lambda r: is_exact(r) and seams(r) == (16317, 0, 0, 0) and edits(r) == [('remove', 22050, 6615)])

# changedDuration.
vector('changed-longer', 'changedDuration', 'Too long beyond every pause floor between hard seams: every edit stays at '
       'its limit and the positive residual changes the duration.',
       fit_input(SENTENCE, kinds=('hard', 'hard'), rho=SHORTEN_ROOM + 4410),
       lambda r: is_changed(r) and counts(r) == [8820, 6174, 3969] and r['residualSeconds'] == 0.1)
vector('changed-shorter', 'changedDuration', 'Too short beyond every growth limit and hard-seam pad: the negative '
       'residual changes the duration.', fit_input(SENTENCE, kinds=('hard', 'hard'), rho=-(LENGTHEN_ROOM + 5292 + 4410)),
       lambda r: is_changed(r) and seams(r) == (2646, 0, 2646, 0) and r['residualSeconds'] == -0.1)
vector('changed-borrow-at-limit', 'changedDuration', 'Pauses at their floors and both gap seams at PAUSE_SLACK_KEEP: '
       'the window widens by every borrowed sample and the take is still longer.',
       fit_input(SENTENCE, silences=(0.3, 0.3), rho=SHORTEN_ROOM + 2 * 6615 + 4410),
       lambda r: is_changed(r) and seams(r) == (0, 7200, 0, 7200) and r['residualSeconds'] == 0.1)

# jsRound ties. Every value the planner rounds is non-negative, so a tie always goes up: a take that is too long then
# loses one frame less, and a take that is too short gains one frame more.
D_22050 = natural_frames(fit_input(ONE_WORD, asset_rate=22050, rate=44100.0, kinds=('hard', 'hard')))
vector('round-tie-window-longer', 'rounding', 'A 22.05 kHz take in a 44.1 kHz window of an odd sample count: n x 0.5 '
       'ends in .5 and rounds up to the take\'s own length, so the take fits exactly between hard seams. Rounding down '
       'would leave it one frame too long, with nothing to absorb it.',
       fit_input(ONE_WORD, asset_rate=22050, rate=44100.0, kinds=('hard', 'hard'), window=2 * D_22050 - 1),
       lambda r: is_exact(r) and edits(r) == [] and seams(r) == (0, 0, 0, 0))
vector('round-tie-window-shorter', 'rounding', 'The same tie one frame higher: the window holds one frame more than the '
       'take, which pads it at the incoming seam. Rounding down would leave the take unpadded.',
       fit_input(ONE_WORD, asset_rate=22050, rate=44100.0, kinds=('hard', 'hard'), window=2 * D_22050 + 1),
       lambda r: is_exact(r) and seams(r) == (1, 0, 0, 0))
search('round-tie-borrow', 'rounding', 'A 48 kHz take in a 44.1 kHz window must borrow 240 frames: 240 x 44,100 / '
       '48,000 = 220.5 rounds up to 221 samples, 111 incoming and 110 outgoing (round-half-even would give 220).',
       lambda i: fit_input([('Absolutely', 0.05, 1.05 + i / 48000)], asset_rate=48000, rate=44100.0, rho=240),
       lambda c, r: rho_of(c) == 240 and is_exact(r) and (seams(r)[1], seams(r)[3]) == (111, 110))
vector('round-tie-edge-pad', 'rounding', 'A 0.25 s source edge silence at 22.05 kHz is 5,512.5 frames and rounds up to '
       '5,513; less the take\'s 661-frame lead, the edge pad is 4,852 frames.',
       fit_input(ONE_WORD, asset_rate=22050, rate=48000.0, kinds=('none', 'hard'), silences=(0.25, None)),
       lambda r: is_exact(r) and seams(r)[0] == 5513 - (math.floor(0.05 * 22050) - whole(0.02, 22050)) == 4852)
vector('round-tie-growth-22050', 'rounding', 'At 22.05 kHz PAUSE_GROWTH_MAX is jsRound(5,512.5) = 5,513 frames: a '
       '27-frame run (5,967 samples) grows by exactly 5,513, and the hard seams pad the rest.',
       fit_input([('So,', 0.0113, 0.30), ('yes', 0.5809, 0.90)], asset_rate=22050, rho=-7000, kinds=('hard', 'hard')),
       lambda r: is_exact(r) and edits(r) == [('insert', 6630 + (5967 - 5513) // 2, 5513)] and seams(r) == (744, 0, 743, 0))
vector('round-tie-punctuation-floor-22050', 'rounding', 'At 22.05 kHz PAUSE_FLOOR_PUNCT is 0.15 x 22,050, which is '
       '3,307.5 in binary64 and rounds up to 3,308 frames: a 20-frame run (4,420 samples) shortens by 1,112.',
       fit_input([('So,', 0.0113, 0.30), ('yes', 0.505, 0.90)], asset_rate=22050, rho=3000, kinds=('hard', 'hard')),
       lambda r: is_changed(r) and edits(r) == [('remove', 6630 + (4420 - 1112) // 2, 1112)])


# The rounding residual: only borrowing converts between the two sample grids. Its sign depends on how the borrowed
# samples round and on where the take's length falls on the window's grid, so the one-word take of a 48 kHz asset in
# a 44.1 kHz window tries 11 residuals at each length, one frame longer each time, until the residual lands where each
# vector needs it. `edges` puts the tail trim, or both trims, on the word.
def residual_input(kinds, silences=(0.6, 0.6), edges='', asset_rate=48000, rate=44100.0):
    def make(i):
        end = 1.05 + i // 11 / asset_rate
        trim = None
        if edges:
            last = math.ceil(end * asset_rate) / asset_rate
            trim = (math.floor(0.05 * asset_rate) / asset_rate if edges == 'both' else 0.02, last)
        return fit_input([('Absolutely', 0.05, end)], asset_rate=asset_rate, rate=rate, kinds=kinds, silences=silences,
                         rho=300 + i % 11, trim=trim)
    return make


def raised(case, result):
    """The source samples the seams borrowed beyond jsRound(remainder x sourceRate / assetRate), for a take with no
    pause, where the remainder is all of rho."""
    need = js_round(float(rho_of(case)) * case['sourceSampleRate'] / float(case['take']['assetSampleRate']))
    return seams(result)[1] + seams(result)[3] - need


search('residual-incoming-pad', 'residual', 'Borrowing leaves the output one frame short of jsRound(n x 48,000 / 44,100): '
       'the frame pads the incoming gap seam.', residual_input(('gap', 'gap')),
       lambda c, r: is_exact(r) and seams(r)[0] == 1)
search('residual-incoming-edge-pad', 'residual', 'The output is one frame long: the incoming take-edge pad gives it up.',
       residual_input(('none', 'gap'), silences=(0.2, 0.6)),
       lambda c, r: is_exact(r) and seams(r)[0] == edge_pads(c)[0] - 1)
search('residual-outgoing-pad', 'residual', 'A hard incoming seam takes no residual: the frame pads the outgoing gap.',
       residual_input(('hard', 'gap')), lambda c, r: is_exact(r) and seams(r)[2] == 1)
search('residual-outgoing-edge-pad', 'residual', 'The output is one frame long and the incoming gap pad is empty: the '
       'outgoing take-edge pad gives it up.', residual_input(('gap', 'none'), silences=(0.6, 0.2)),
       lambda c, r: is_exact(r) and seams(r)[0] == 0 and seams(r)[2] == edge_pads(c)[1] - 1)
search('residual-tail-trim', 'residual', 'The output is one frame long and no pad can shrink: the TTS tail trim ends '
       'one frame earlier.', residual_input(('gap', 'hard')),
       lambda c, r: is_exact(r) and trims_moved(c, r) == (0, -1))
search('residual-lead-trim', 'residual', 'The tail trim already ends at the last aligned character: the TTS lead trim '
       'starts one frame later instead.', residual_input(('gap', 'hard'), edges='tail'),
       lambda c, r: is_exact(r) and trims_moved(c, r) == (1, 0))
search('residual-unplaced', 'residual', 'The aligned words fill both trims and no pad can shrink, so no pad or trim can '
       'take the residual frame. The incoming gap borrows the fewest more source samples whose widened window holds '
       'the planned frames, and the plan stays exact.', residual_input(('gap', 'hard'), edges='both'),
       lambda c, r: is_exact(r) and trims_moved(c, r) == (0, 0) and seams(r)[3] == 0 and raised(c, r) > 0)
search('residual-raise-outgoing-borrow', 'residual', 'The same with a hard incoming seam, as a 44.1 kHz take in a '
       '48 kHz source: the outgoing gap borrows one more source sample, and the plan stays exact.',
       residual_input(('hard', 'gap'), edges='both', asset_rate=44100, rate=48000.0),
       lambda c, r: is_exact(r) and trims_moved(c, r) == (0, 0) and seams(r)[1] == 0 and raised(c, r) == 1)


vector('residual-zero-borrow', 'residual', 'A 48 kHz asset in a 16 kHz source leaves one frame after pauses. The first '
       'borrow rounds to zero and neither trim can shrink, so the incoming gap borrows one sample and pads two frames.',
       fit_input([('Absolutely', 0.05, 1.0500208)], asset_rate=48000, rate=16000.0, asset_end=60001 / 48000,
                 kinds=('gap', 'hard'), trim=(2400 / 48000, 50401 / 48000), rho=1),
       lambda r: is_exact(r) and r['incoming'] == [2, 1] and r['outgoing'] == [0, 0])
vector('refuse-word-below-source-sample', 'refusals', 'An aligned word shorter than one source sample is refused '
       'before fitting, even when the take has ample trailing silence.',
       fit_input([('Tiny', 0.05, 0.050001)], asset_rate=48000, rate=16000.0),
       lambda r: r.get('error') == 'invalidWordTiming')
vector('refuse-word-straddles-source-sample', 'refusals', 'A 0.71-source-sample middle word straddles a source sample '
       'boundary after its offset. Only the input span rule refuses it, not the later output sample check.',
       fit_input([('a', 0.1, 0.5), ('b', 0.6 + 0.49 / 48000, 0.6 + 1.2 / 48000), ('c', 0.7, 1.0)],
                 asset_rate=48000, rate=48000.0),
       lambda result: result.get('error') == 'invalidWordTiming')
vector('refuse-empty-word-text', 'refusals', 'Aligned word text must be nonempty even when its patch token is not empty.',
       fit_input([('', 0.05, 1.05)], tokens=['Patch']), lambda result: result.get('error') == 'alignmentMismatch')
vector('refuse-final-word-clamp-collapse', 'refusals', 'A final word inside the last half asset frame would clamp '
       'to an empty span at the output boundary. It is invalid timing, not a planner fault.',
       fit_input([('Tiny', 800.8 / 16000, 800.9 / 16000)], asset_rate=16000, rate=1000000.0,
                 kinds=('hard', 'hard'), trim=(800 / 16000, 801 / 16000), window=32),
       lambda r: r.get('error') == 'invalidWordTiming')
vector('round-unity-recipe-half-frame', 'rounding', 'An odd 48 kHz source window rounds up at half a 24 kHz asset '
       'frame. Its unity recipe trims bound the output frames, not outDuration times an approximate stretch ratio.',
       fit_input([('Patch', 0.05, 0.25)], asset_rate=24000, rate=48000.0, kinds=('hard', 'hard'),
                 trim=(0.03, 0.31), window=13441),
       lambda r: is_exact(r) and r['outputFrames'] == 6721
       and abs(1 - (r['windowEnd'] - r['windowStart']) / (r['outputFrames'] / 24000)) > 1e-6)


OFF_GRID_CHANGED = fit_input([('Patch', 0.05, 25280 / 24000)], asset_rate=24000, rate=44100.0,
                             kinds=('hard', 'hard'), trim=(0.05, 25280 / 24000), window=44232, start=66150)
OFF_GRID_CHANGED['window'].update(start=1.5, end=2.503)
vector('changed-offgrid-hard-residual-eight', 'changedDuration', 'An off-grid 44.1 kHz hard/hard window with eight '
       '24 kHz residual frames returns both seams on the source grid before computing its output duration.',
       OFF_GRID_CHANGED, lambda result: result.get('result') == 'changedDuration' and result['outputFrames'] == 24080
       and result['residualSeconds'] == 8 / 24000 and result['windowStart'] == 66150 / 44100 and result['windowEnd'] == 110382 / 44100)


def clamped(case, result):
    """Whether the one word, moved by the incoming pad, would end after the window and ends at its end instead."""
    take = case['take']
    moved = take['words'][-1][2] + (result['incoming'][0] - result['trims'][0]) / take['assetSampleRate']
    duration = result['windowEnd'] - result['windowStart']
    return moved > duration and result['words'][-1][1] == duration


search('round-word-end-clamped', 'rounding', 'A 16 kHz take in a 48 kHz source with both trims on its one word and no '
       'outgoing pad: the output holds jsRound(n / 3) frames, up to a third of a frame more than the window, so the '
       'word would end after windowEnd - windowStart. Its end is clamped to that duration.',
       residual_input(('gap', 'gap'), edges='both', asset_rate=16000, rate=48000.0),
       lambda c, r: is_exact(r) and trims_moved(c, r) == (0, 0) and seams(r)[2] == 0 and clamped(c, r))

# Sample rates: a 22.05, 44.1 or 48 kHz take in an 8, 16, 22.05, 44.1 or 48 kHz source, shortening pauses to their floors and
# borrowing 50 ms more at both gap seams.
for asset_rate in (22050, 44100, 48000):
    for rate in (8000.0, 16000.0, 22050.0, 44100.0, 48000.0):
        floors = run_case(fit_input(SENTENCE, asset_rate=asset_rate, rate=rate, kinds=('hard', 'hard'), window=1))
        vector('rates-%d-in-%d' % (asset_rate, rate), 'rates', 'The sentence as a %g kHz take in a %g kHz source, 50 ms '
               'longer than its pauses can absorb: the pauses reach their floors and both gap seams borrow.'
               % (asset_rate / 1000, rate / 1000),
               fit_input(SENTENCE, asset_rate=asset_rate, rate=rate, rho=sum(counts(floors)) + whole(0.05, asset_rate)),
               lambda r: is_exact(r) and len(edits(r)) == 3 and seams(r)[1] > 0 and seams(r)[3] > 0)

# voice-lab.md section 15, test 4.
LONG = [('First,', 0.05, 2.9999), ('then', 3.3001, 6.00)]
D_SENTENCE = natural_frames(fit_input(SENTENCE, rate=44100.0))
D_LONG = natural_frames(fit_input(LONG, rate=44100.0))
vector('s15-five-percent-longer', 'spec15', 'D = 1.05 x w: the punctuation pause gives the residual above its floor, '
       'the take fits exactly, and every word keeps its aligned duration.',
       fit_input(SENTENCE, rate=44100.0, window=js_round(D_SENTENCE / 1.05)),
       lambda r: is_exact(r) and len(edits(r)) == 1 and seams(r) == (0, 0, 0, 0))
vector('s15-five-percent-shorter', 'spec15', 'D = 0.95 x w: the pause lengthens by PAUSE_GROWTH_MAX and the rest pads '
       'equally at the two gap seams.', fit_input(LONG, rate=44100.0, window=js_round(D_LONG / 0.95)),
       lambda r: is_exact(r) and counts(r) == [11025] and abs(seams(r)[0] - seams(r)[2]) <= 1)
vector('s15-one-word-hard-seams', 'spec15', 'A one-word take shorter than its window between hard seams pads '
       'HARD_SEAM_PAD_MAX at each, and the rest changes the duration.',
       fit_input([('Fine', 0.05, 0.45)], kinds=('hard', 'hard'), rho=-8820),
       lambda r: is_changed(r) and seams(r) == (2646, 0, 2646, 0) and r['residualSeconds'] == -3528 / 44100)
vector('s15-borrow-beside-pause', 'spec15', 'D = 1.15 x w beside a 0.6 s source pause whose seam leaves 0.55 s outside '
       'the window: the take\'s pauses reach their floors, then the outgoing gap lends the rest and keeps '
       'PAUSE_SLACK_KEEP beside the kept word.',
       fit_input([('Yes,', 0.05, 0.5999), ('we', 0.8501, 1.2999), ('can', 1.4001, 2.00)], rate=44100.0, kinds=('hard', 'gap'),
                 silences=(None, 0.55), window=js_round((whole(2.06, 44100) - whole(0.02, 44100)) / 1.15)),
       lambda r: is_exact(r) and counts(r) == [4410, 1764] and seams(r) == (0, 0, 0, 5560))
vector('s15-forty-percent-longer', 'spec15', 'D = 1.4 x w with no pause and no seam silence: changedDuration with no '
       'edit and residualSeconds = 0.4 x w (16,128 of 40,320 frames).',
       fit_input([('Absolutely', 0.05, 1.24)], rate=44100.0, kinds=('hard', 'hard'), window=40320),
       lambda r: is_changed(r) and edits(r) == [] and r['residualSeconds'] == 16128 / 44100)
vector('s15-partial-at-limits', 'spec15', 'Pauses and seams hold only part of the residual: every edit is at its limit '
       'and the window plus residualSeconds is the output.',
       fit_input(SENTENCE, silences=(0.3, 0.2), rho=SHORTEN_ROOM + 13230),
       lambda r: is_changed(r) and counts(r) == [8820, 6174, 3969] and seams(r) == (0, 7200, 0, 2400))
vector('s15-take-edge', 'spec15', 'At a take edge the pad keeps the first aligned word at its source distance (0.25 s) '
       'from the edge, while the pauses absorb a 5% longer take.',
       fit_input(SENTENCE, kinds=('none', 'gap'), silences=(0.25, 0.6), rho=4074),
       lambda r: is_exact(r) and seams(r)[0] == 9702 and abs(r['words'][0][0] - 0.25) < 1e-12)


# Refusals: a valid input with one field changed.
def refused(name, code, note, change):
    case = fit_input(SENTENCE, rho=2205)
    change(case)
    vector(name, 'refusals', note, case, lambda r: r == {'error': code})


def set_in(path, value):
    def change(case):
        target = case
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
    return change


refused('refuse-synth-to-synth', 'invalidInput', 'The planner places only none, gap and hard seams.',
        set_in(('window', 'leftKind'), 'synthToSynth'))
refused('refuse-gap-without-silence', 'invalidInput', 'A gap seam needs its outside silence.',
        set_in(('incomingSilence',), None))
refused('refuse-hard-with-silence', 'invalidInput', 'A hard seam has no outside silence.',
        set_in(('window', 'rightKind'), 'hard'))
refused('refuse-negative-silence', 'invalidInput', 'An outside silence is never negative.',
        set_in(('outgoingSilence',), -0.1))
refused('refuse-take-start-off-zero', 'invalidInput', 'A take-start seam lies on source sample 0.',
        set_in(('window', 'leftKind'), 'none'))
refused('refuse-silence-before-take', 'invalidInput', 'The incoming gap\'s outside silence cannot reach before the '
        'take start.', set_in(('incomingSilence',), 1.2))
refused('refuse-empty-window', 'invalidInput', 'The window holds at least one source sample.',
        lambda case: case['window'].update(endSample=case['window']['startSample']))
refused('refuse-envelope-rate', 'invalidInput', 'The envelope is on the paid asset\'s sample rate.',
        set_in(('take', 'envelope', 'sampleRate'), 48000))
refused('refuse-envelope-length', 'invalidInput', 'The envelope holds every whole 10 ms frame of the paid asset.',
        lambda case: case['take']['envelope']['runs'][-1].__setitem__(1, case['take']['envelope']['runs'][-1][1] - 1))
refused('refuse-asset-too-long', 'invalidInput', 'A paid asset of 2^31 frames or more is refused before its envelope '
        'is read.', set_in(('take', 'assetFrames'), FRAME_LIMIT))
refused('refuse-trim-outside-asset', 'invalidInput', 'The trims lie inside the paid asset.',
        set_in(('take', 'trimEnd'), 2.2))
refused('refuse-trim-end-before-start', 'invalidInput', 'The trims are in order, checked in seconds before either is '
        'converted to frames, so a tail trim far below zero is refused rather than overflowing.',
        set_in(('take', 'trimEnd'), -1e300))
refused('refuse-source-rate-too-low', 'invalidInput', 'The source rate is at least 1 Hz, the schema\'s floor.',
        set_in(('sourceSampleRate',), 1e-12))
refused('refuse-source-rate-too-high', 'invalidInput', 'The source rate is at most 1 MHz, so no borrowed sample '
        'count overflows 64 bits.', set_in(('sourceSampleRate',), 1e300))
refused('refuse-no-words', 'alignmentUnavailable', 'A take without aligned words cannot be fitted.',
        lambda case: (case['take'].update(words=[]), case.update(tokens=[])))
refused('refuse-token-count', 'alignmentMismatch', 'Each aligned word has its patch token.',
        lambda case: case['tokens'].append('more'))
refused('refuse-empty-token', 'alignmentMismatch', 'A patch token is never empty.',
        set_in(('tokens', 0), ''))
refused('refuse-word-before-trim', 'invalidWordTiming', 'Every aligned word lies inside the trims.',
        set_in(('take', 'trimStart'), 0.06))
refused('refuse-words-overlap', 'invalidWordTiming', 'Aligned words are in order and do not overlap.',
        set_in(('take', 'words', 1, 1), 0.35))
refused('refuse-empty-word', 'invalidWordTiming', 'An aligned word ends after it starts.',
        set_in(('take', 'words', 2, 2), 1.1501))


# The property section: random takes, windows and seams from LCG seed 20261027.

class Lcg:
    """Knuth's MMIX constants, as in generate_window.py, so the cases depend only on the seed."""

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


PROPERTY_SEED = 20261027
PROPERTY_CASES = 2000
PUNCTUATION = ['', '', '', '', ',', '.', '?', '!', ';', ':', '-', ELLIPSIS, RIGHT_GUILLEMET, LEFT_DOUBLE_QUOTE, '%', '$', '2']


def fuzz_input(rng):
    """A random take of one to five words on a 0.1 ms grid, with breaths and threshold frames inside its pauses, in a
    window 0.7 to 1.35 times its length with random seam kinds and outside silences. One case in twelve has a trim on
    a word's edge frame or the asset edge, and one in thirty changes a field so that the input is refused."""
    rate = rng.pick([8000.0, 16000.0, 22050.0, 44100.0, 48000.0])
    asset_rate = rng.pick([16000, 22050, 22050, 24000, 44100, 44100, 48000])
    cursor, items = rng.between(0, 1500), []
    for k in range(rng.between(1, 5)):
        if k:
            kind = rng.below(100)
            cursor += (rng.between(0, 300) if kind < 25 else rng.between(300, 1500) if kind < 45 else
                       rng.between(1500, 4500) if kind < 85 else rng.between(4500, 9000))
        length = rng.between(400, 5000)
        items.append((cursor, cursor + length))
        cursor += length
    asset_end = (cursor + rng.between(0, 2000)) / 10000
    words = [('w%d%s' % (k, rng.pick(PUNCTUATION)), a / 10000, b / 10000) for k, (a, b) in enumerate(items)]
    overrides = []
    for (_, b), (c, _) in zip(items, items[1:]):
        if c - b > 300 and rng.chance(35):
            at = rng.between(b, c - 100)
            overrides.append((at / 10000, (at + 100) / 10000, rng.pick([ABOVE, BELOW, SPEECH, 0.004])))
    kinds = (rng.pick(['gap', 'gap', 'hard', 'none']), rng.pick(['gap', 'gap', 'hard', 'none']))
    silences = tuple(None if kind == 'hard' else rng.between(0, 12000) / 10000 for kind in kinds)
    trim = None
    if rng.chance(8):
        total = js_round(asset_end * asset_rate)
        trim = (rng.pick([0.0, math.floor(words[0][1] * asset_rate) / asset_rate]),
                rng.pick([total / asset_rate, math.ceil(words[-1][2] * asset_rate) / asset_rate]))
    start = None
    if kinds[0] == 'gap':
        start = whole(silences[0], rate) + rng.between(0, 48000)
    elif kinds[0] == 'hard':
        start = rng.between(0, 96000)
    case = fit_input(words, asset_rate=asset_rate, rate=rate, asset_end=asset_end, kinds=kinds, silences=silences,
                     start=start, overrides=overrides, trim=trim)
    natural = natural_frames(case)
    case['window']['endSample'] = case['window']['startSample'] + window_samples(
        js_round(natural * 100 / rng.between(70, 135)), asset_rate, rate)
    if rng.chance(3):
        change = rng.below(6)
        if change == 0:
            case['tokens'] = case['tokens'][:-1]
        elif change == 1:
            case['take']['trimStart'] = case['take']['words'][0][1] + 0.001
        elif change == 2:
            case['take']['envelope']['runs'][-1][1] += 1
        elif change == 3:
            case['window']['leftKind'] = 'none'
        elif change == 4:
            case['incomingSilence'] = None
        else:
            case['take']['words'] = case['take']['words'][::-1]
    return case


def check_property(case, result):
    """The section 8.9.2 properties of one result beyond check_voice, derived from the plan alone: the output length,
    the residual's sign, each edit's run and limits, the seam limits and the word times. Both Cores' suites check the
    same properties on their own plans."""
    if 'error' in result:
        return
    take, window = case['take'], case['window']
    asset_rate, rate = take['assetSampleRate'], case['sourceSampleRate']
    window_frames = js_round(float(result['window'][1] - result['window'][0]) * float(asset_rate) / rate)
    if is_exact(result):
        assert result['outputFrames'] == window_frames
    else:
        residual = result['outputFrames'] - window_frames
        assert residual != 0 and (residual > 0) == (rho_of(case) > 0) and result['residualSeconds'] == residual / asset_rate
        assert result['naturalOut'] == natural_frames(case) / asset_rate
    # Each edit lies in the unvoiced run between two words that holds its join, centred, and keeps that run's limits.
    words, size, fade = take['words'], frame_size(asset_rate), whole(SEAM_FADE, asset_rate)
    spans = word_spans(words, asset_rate)
    levels = [level for level, count in take['envelope']['runs'] for _ in range(count)]
    for kind, start, count in result['edits']:
        k = max(i for i in range(len(words) - 1) if spans[i][1] <= start)
        lo, hi = start // size, -(-(start + count) // size)
        while lo * size - size >= spans[k][1] and float(levels[lo - 1]) < VOICED_FRAME_LEVEL:
            lo -= 1
        while hi * size + size <= spans[k + 1][0] and hi < len(levels) and float(levels[hi]) < VOICED_FRAME_LEVEL:
            hi += 1
        length = (hi - lo) * size
        assert start - lo * size == (length - count) // 2 and count + fade <= length
        if kind == 'remove':
            punctuation = is_punctuation(case['tokens'][k])
            assert length - count >= whole(PAUSE_FLOOR_PUNCT if punctuation else PAUSE_FLOOR_PHRASE, asset_rate)
        else:
            assert count <= whole(PAUSE_GROWTH_MAX, asset_rate)
    keep, edges = whole(PAUSE_SLACK_KEEP, rate), edge_pads(case)
    for (padded, borrowed), kind, silence, edge in ((result['incoming'], window['leftKind'], case['incomingSilence'], edges[0]),
                                                   (result['outgoing'], window['rightKind'], case['outgoingSilence'], edges[1])):
        assert 0 <= borrowed <= (max(0, whole(silence, rate) - keep) if kind == 'gap' else 0)
        cap = whole(HARD_SEAM_PAD_MAX if kind == 'hard' else SEAM_PAD_MAX, asset_rate)
        assert padded >= 0 and padded - edge <= cap and (padded >= edge or kind != 'hard')
    # Each word keeps its aligned frames and moves by the incoming pad and the edits before it, inside the output: its
    # times stop at the output's duration as the recipe states it, so the section 10.5 render validator accepts them.
    duration = result['windowEnd'] - result['windowStart']
    if not is_exact(result):
        duration = result['windowEnd'] - result['windowStart'] + result['residualSeconds']
    previous = 0.0
    for (_, w_start, w_end), out, span in zip(words, result['words'], spans):
        shift = sum(count if kind == 'insert' else -count for kind, start, count in result['edits'] if start < span[0])
        offset = result['incoming'][0] - result['trims'][0] + shift
        assert out == [min(w_start + offset / asset_rate, duration), min(w_end + offset / asset_rate, duration)]
        assert 0 <= span[0] + offset and span[1] + offset <= result['outputFrames']
        assert out[1] <= duration and js_round(out[1] * rate) <= js_round(duration * rate)
        assert out[0] >= previous and out[1] > out[0] and whole(out[1], rate) > whole(out[0], rate)
        previous = out[1]
    assert result['windowStart'] == result['window'][0] / rate
    assert result['windowEnd'] == result['window'][1] / rate
    if is_exact(result):
        assert whole(duration, rate) == result['window'][1] - result['window'][0]


fuzz_rng = Lcg(PROPERTY_SEED)
property_cases = []
stats = {'seed': PROPERTY_SEED, 'cases': PROPERTY_CASES, 'exact': 0, 'changedDuration': 0, 'refused': {}, 'longer': 0,
         'shorter': 0, 'edits': 0, 'borrowing': 0, 'padding': 0, 'takeEdges': 0, 'trimsMoved': 0}
for index in range(PROPERTY_CASES):
    case = fuzz_input(fuzz_rng)
    result = run_case(case)
    assert result.get('error') != 'fitTouchesVoice', index
    check_property(case, result)
    if 'error' in result:
        stats['refused'][result['error']] = stats['refused'].get(result['error'], 0) + 1
    else:
        stats[result['result']] += 1
        rho = rho_of(case)
        stats['longer'] += rho > 0
        stats['shorter'] += rho < 0
        stats['edits'] += len(result['edits'])
        stats['borrowing'] += bool(result['incoming'][1] or result['outgoing'][1])
        stats['padding'] += rho < 0 and seams(result)[0] + seams(result)[2] > sum(edge_pads(case))
        stats['takeEdges'] += 'none' in (case['window']['leftKind'], case['window']['rightKind'])
        stats['trimsMoved'] += trims_moved(case, result) != (0, 0)
        # The floating-point fields follow from the integer plan; the suites recompute them (section 8.9.2 Output).
        for key in ('windowStart', 'windowEnd', 'words'):
            del result[key]
    property_cases.append({'name': 'property-%04d' % index, 'input': case, 'expected': result})
stats['refused'] = dict(sorted(stats['refused'].items()))

for case in NAMED:
    assert case['expected'].get('error') != 'fitTouchesVoice', case['name']
    check_property(case['input'], case['expected'])
assert len({case['name'] for case in NAMED}) == len(NAMED)
assert not FAILURES, '\n'.join('%s: %s' % failure for failure in FAILURES)

categories = {}
for case in NAMED:
    categories[case['category']] = categories.get(case['category'], 0) + 1
document = {
    'schema': 'voxclip-voice-lab-fit-cases/1',
    'constants': {'SEAM_FADE': SEAM_FADE, 'HARD_SEAM_FADE': HARD_SEAM_FADE, 'TTS_TRIM_LEAD': TTS_TRIM_LEAD,
                  'TTS_TRIM_TAIL': TTS_TRIM_TAIL, 'PAUSE_SLACK_KEEP': PAUSE_SLACK_KEEP, 'SEAM_PAD_MAX': SEAM_PAD_MAX,
                  'HARD_SEAM_PAD_MAX': HARD_SEAM_PAD_MAX, 'PAUSE_FLOOR_PHRASE': PAUSE_FLOOR_PHRASE,
                  'PAUSE_FLOOR_PUNCT': PAUSE_FLOOR_PUNCT, 'PAUSE_GROWTH_MAX': PAUSE_GROWTH_MAX,
                  'LENGTH_AIM_MIN': LENGTH_AIM_MIN, 'LENGTH_AIM_MAX': LENGTH_AIM_MAX, 'VOICED_FRAME': VOICED_FRAME,
                  'VOICED_FRAME_LEVEL': VOICED_FRAME_LEVEL, 'RMS_FRAME': RMS_FRAME},
    'categories': categories,
    'cases': '@@cases@@',
    'propertyFuzz': stats,
    'propertyCases': '@@propertyCases@@',
    'caseCount': len(NAMED) + len(property_cases),
}
# One case per line keeps the file reviewable and its diffs local.
text = json.dumps(document, indent=2)
for key, items, separators in (('cases', NAMED, (', ', ': ')), ('propertyCases', property_cases, (',', ':'))):
    text = text.replace('"@@%s@@"' % key, '[\n' + ',\n'.join('    ' + json.dumps(item, separators=separators)
                                                             for item in items) + '\n  ]')
OUT.write_text(text + '\n')
print('fit cases: %d named in %d categories, %d property (seed %d): %d exact, %d changedDuration, refused %s; '
      '%d longer, %d shorter, %d edits, %d borrowing, %d padding, %d at a take edge, %d moving a trim'
      % (len(NAMED), len(categories), PROPERTY_CASES, PROPERTY_SEED, stats['exact'], stats['changedDuration'],
         stats['refused'], stats['longer'], stats['shorter'], stats['edits'], stats['borrowing'], stats['padding'],
         stats['takeEdges'], stats['trimsMoved']))
