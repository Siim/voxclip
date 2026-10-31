#!/usr/bin/env python3
"""Write training-spans.json: the Voice Lab section 6.5.1 span-selection vectors that both Cores replay.

An independent standard-library reference of the section's six steps, written from the spec rather than from either
Core: usable words, runs, the split at the longest pause, the take-relative SNR, the 30 s minimum and the pick up to
120 s. The pick ranks the spans that overlap the optional `preferRange` first (voice-lab.md section 6.5.1, amended by
the clip-first Rewrite design of 2026-10-31) and reports `preferredMs`. The inputs are synthetic and hand-authored;
the twelve original cases keep their inputs and selections and gain only `preferredMs` 0. Two runs give identical
bytes. See shared/fixtures/voice-lab/training-spans-README.md."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/training-spans.json'

MIN_CONF = 0.8
MAX_GAP = 2_000
SPAN_MIN = 5_000
SPAN_MAX = 30_000
VOICED = -45.0
MIN_SNR = 20.0
TOTAL_MIN = 30_000
TOTAL_MAX = 120_000


def ms(seconds):
    """ms(t) = floor(t x 1000 + 0.5) in binary64."""
    return int((seconds * 1000 + 0.5) // 1)


def select(items, excluded, frames, duration, prefer):
    total = ms(duration)
    ranges = [(ms(start), ms(end)) for start, end in excluded]
    level = [db for count, db in frames for _ in range(count)]
    # Steps 1 and 2: runs of consecutive usable words, each a list of (start, end) in milliseconds.
    runs, run, speaker, run_end = [], [], None, 0
    for item in items:
        start, end = ms(item['start']), ms(item['end'])
        usable = (item['kind'] == 'word' and (item['conf'] is None or item['conf'] >= MIN_CONF) and not item['synthetic']
                  and start < end <= total and not any(xs < end and xe > start for xs, xe in ranges))
        if not usable:
            if run:
                runs.append(run)
            run = []
            continue
        joins = (run and item['speaker'] == speaker and start - run_end <= MAX_GAP
                 and not any(xs < start and xe > run_end for xs, xe in ranges))
        if joins:
            run.append((start, end))
            run_end = max(run_end, end)
        else:
            if run:
                runs.append(run)
            run, speaker, run_end = [(start, end)], item['speaker'], end
    if run:
        runs.append(run)

    # Step 3: pieces in production order, (start, end, reason or None).
    pieces = []

    def split(words):
        start, end = words[0][0], max(word[1] for word in words)
        if end - start < SPAN_MIN:
            pieces.append((start, end, 'short'))
            return
        if end - start <= SPAN_MAX:
            pieces.append((start, end, None))
            return
        best = None
        for boundary in range(len(words) - 1):
            left_end = max(word[1] for word in words[:boundary + 1])
            right_start, right_end = words[boundary + 1][0], max(word[1] for word in words[boundary + 1:])
            if left_end - start < SPAN_MIN or right_end - right_start < SPAN_MIN:
                continue
            key = (-(right_start - left_end), abs(left_end + right_start - start - end), boundary)
            if best is None or key < best:
                best = key
        if best is None:
            pieces.append((start, end, 'unsplittable'))
            return
        split(words[:best[2] + 1])
        split(words[best[2] + 1:])

    for words in runs:
        split(words)

    # Step 4: the median voiced frame over the take's 10th-percentile frame.
    count = len(level)
    floor_db = sorted(level)[count // 10] if count else None
    qualifying, rejected = [], []
    for start, end, reason in pieces:
        if reason is not None:
            rejected.append({'startMs': start, 'endMs': end, 'reason': reason, 'snrDb': None})
            continue
        low = min(max((start + 5) // 10, 0), count)
        high = min(max((end + 5) // 10, 0), count)
        voiced = sorted(db for db in level[low:high] if db > VOICED)
        snr = voiced[len(voiced) // 2] - floor_db if voiced and floor_db is not None else None
        if snr is not None and snr >= MIN_SNR:
            qualifying.append({'startMs': start, 'endMs': end, 'snrDb': snr})
        else:
            rejected.append({'startMs': start, 'endMs': end, 'reason': 'lowSnr', 'snrDb': snr})
    # Source order; sorted() is stable, so equal starts keep production order.
    qualifying.sort(key=lambda span: span['startMs'])
    rejected.sort(key=lambda piece: piece['startMs'])
    available = sum(span['endMs'] - span['startMs'] for span in qualifying)
    result = {'status': 'belowMinimum', 'availableMs': available, 'selectedMs': 0, 'preferredMs': 0,
              'selected': [], 'qualifying': qualifying, 'rejected': rejected}
    if available < TOTAL_MIN:
        return result

    # Steps 5 and 6: the preferred group, then the other, each by best SNR, then longest, then earliest.
    lo, hi = (ms(prefer[0]), ms(prefer[1])) if prefer is not None else (None, None)

    def preferred(span):
        return prefer is not None and span['startMs'] < hi and span['endMs'] > lo

    order = sorted(range(len(qualifying)), key=lambda index: (
        not preferred(qualifying[index]), -qualifying[index]['snrDb'],
        -(qualifying[index]['endMs'] - qualifying[index]['startMs']), index))
    chosen, selected = set(), 0
    for index in order:
        length = qualifying[index]['endMs'] - qualifying[index]['startMs']
        if selected + length <= TOTAL_MAX:
            chosen.add(index)
            selected += length
    spans = [qualifying[index] for index in sorted(chosen)]
    overlap = sum(max(0, min(span['endMs'], hi) - max(span['startMs'], lo)) for span in spans) if prefer is not None else 0
    result.update(status='ok', selectedMs=selected, preferredMs=overlap, selected=spans)
    return result


def w(start, end, conf=None, speaker=None, synthetic=False, kind='word'):
    return {'kind': kind, 'start': start, 'end': end, 'conf': conf, 'speaker': speaker, 'synthetic': synthetic}


def speech(start, end):
    """Words of at most 10 s with 0.5 s pauses from start to end, all at confidence 0.9 and with no speaker label."""
    words, at = [], start
    while end - at > 10:
        words.append(w(at, at + 9.5, conf=0.9))
        at += 10
    words.append(w(at, end, conf=0.9))
    return words


def levels(duration, *regions):
    """Run-length 10 ms levels: each (start, end, dBFS) region in seconds, -70 dBFS everywhere else."""
    pairs, at = [], 0
    for start, end, db in regions:
        if round(start * 100) > at:
            pairs.append([round(start * 100) - at, -70.0])
        pairs.append([round(end * 100) - round(start * 100), db])
        at = round(end * 100)
    if round(duration * 100) > at:
        pairs.append([round(duration * 100) - at, -70.0])
    return pairs


def case(identifier, duration, items, excluded, frames, prefer=None):
    value = {'id': identifier, 'duration': duration, 'items': items, 'excluded': excluded, 'frames': frames}
    if prefer is not None:
        value['preferRange'] = prefer
    return value


def preferring(identifier, duration, prefer, *regions):
    """A preferRange case whose speech is the given (start, end, dBFS) regions, each spoken as one run of words."""
    items = [word for start, end, _ in regions for word in speech(start, end)]
    return case(identifier, duration, items, [], levels(duration, *regions), prefer=prefer)


CASES = [
    case('happy-path', 40.0,
         [w(1.0, 5.0, conf=0.95),
          w(5.2, 9.8),
          w(10.0, 14.6, conf=0.8),
          w(14.8, 19.0, conf=0.9),
          w(22.0, 26.0, conf=0.9),
          w(26.3, 30.5, conf=0.99),
          w(30.6, 35.0),
          w(35.2, 38.0, conf=0.85)],
         excluded=[],
         frames=[[100, -70.0], [1800, -20.0], [300, -70.0], [1600, -20.0], [200, -70.0]]),
    case('low-confidence-split', 50.0,
         [w(0.5, 4.5, conf=0.9),
          w(4.6, 9.0, conf=0.8),
          w(9.1, 13.0, conf=0.95),
          w(13.1, 17.5, conf=0.85),
          w(17.6, 18.4, conf=0.79),
          w(18.5, 21.0, conf=0.9),
          w(21.1, 22.0, conf=0.9),
          w(22.1, 22.6, conf=0.5),
          w(22.7, 27.0),
          w(27.1, 31.5),
          w(31.6, 36.0),
          w(36.1, 40.2)],
         excluded=[],
         frames=[[50, -70.0], [3970, -22.0], [980, -70.0]]),
    case('event-inside', 45.0,
         [w(1.0, 6.0, conf=0.9),
          w(6.1, 11.0, conf=0.9),
          w(11.1, 12.0, kind='event'),
          w(12.1, 17.0, conf=0.9),
          w(17.1, 22.0, conf=0.9),
          w(22.1, 24.0, conf=0.9),
          w(24.1, 25.0, kind='unlabeledSpeech'),
          w(25.1, 30.0, conf=0.9),
          w(30.1, 34.6, conf=0.9)],
         excluded=[],
         frames=[[100, -70.0], [3360, -25.0], [1040, -70.0]]),
    case('two-speakers', 60.0,
         [w(0.0, 5.0, conf=0.9, speaker='speaker_0'),
          w(5.0, 10.0, conf=0.9, speaker='speaker_0'),
          w(10.0, 14.0, conf=0.9, speaker='speaker_0'),
          w(14.0, 19.0, conf=0.9, speaker='speaker_1'),
          w(19.0, 24.0, conf=0.9, speaker='speaker_1'),
          w(24.2, 30.0, conf=0.9, speaker='speaker_0'),
          w(30.0, 36.0, conf=0.9, speaker='speaker_0'),
          w(36.0, 38.0, conf=0.9)],
         excluded=[],
         frames=[[1400, -20.0], [1000, -30.0], [1400, -20.0], [2200, -70.0]]),
    case('synthetic-excluded', 75.0,
         [w(0.0, 4.0, conf=0.9),
          w(4.1, 8.0, conf=0.9),
          w(8.1, 12.0, conf=0.9),
          w(12.1, 16.0, conf=0.9, synthetic=True),
          w(16.1, 19.9, conf=0.9, synthetic=True),
          w(20.1, 25.0, conf=0.9),
          w(25.1, 30.0, conf=0.9),
          w(30.1, 35.0, conf=0.9),
          w(35.1, 39.9, conf=0.9),
          w(40.4, 45.0, conf=0.9),
          w(45.1, 50.0, conf=0.9),
          w(50.1, 52.0, conf=0.9),
          w(52.1, 56.0, conf=0.9),
          w(56.1, 58.0, conf=0.9),
          w(58.1, 59.0, conf=0.9, synthetic=True),
          w(59.1, 65.0, conf=0.9)],
         excluded=[[12.05, 20.0], [40.0, 40.3], [51.0, 51.5]],
         frames=[[6500, -20.0], [1000, -70.0]]),
    case('low-snr-rejected', 70.0,
         [w(1.0, 6.0, conf=0.9),
          w(6.1, 11.0, conf=0.9),
          w(11.1, 16.0, conf=0.9),
          w(16.1, 21.0, conf=0.9),
          w(24.0, 29.0, conf=0.9),
          w(29.1, 34.0, conf=0.9),
          w(34.1, 39.0, conf=0.9),
          w(39.1, 43.0, conf=0.9),
          w(46.0, 51.0, conf=0.9),
          w(51.1, 56.0, conf=0.9),
          w(59.0, 64.0, conf=0.9),
          w(64.1, 65.0, conf=0.9)],
         excluded=[],
         frames=[[100, -55.0], [2000, -20.0], [300, -55.0], [1900, -36.0], [300, -55.0], [1000, -35.0], [300, -55.0], [600, -50.0], [500, -55.0]]),
    case('long-run-split-at-pauses', 80.0,
         [w(1.0, 5.0, conf=0.9),
          w(7.0, 9.0, conf=0.9),
          w(9.1, 13.0, conf=0.9),
          w(13.6, 18.0, conf=0.9),
          w(18.1, 22.0, conf=0.9),
          w(22.1, 26.0, conf=0.9),
          w(27.5, 31.0, conf=0.9),
          w(31.1, 35.0, conf=0.9),
          w(35.1, 39.0, conf=0.9),
          w(40.0, 44.0, conf=0.9),
          w(44.1, 48.0, conf=0.9),
          w(48.1, 52.0, conf=0.9),
          w(53.0, 57.0, conf=0.9),
          w(57.1, 61.0, conf=0.9),
          w(61.1, 65.0, conf=0.9),
          w(65.6, 70.0, conf=0.9),
          w(70.1, 72.0, conf=0.9)],
         excluded=[],
         frames=[[100, -70.0], [7100, -20.0], [800, -70.0]]),
    case('unsplittable-run-and-30-second-span', 70.0,
         [w(0.0, 28.0, conf=0.9),
          w(28.1, 31.5, conf=0.9),
          w(35.0, 50.0, conf=0.9),
          w(50.0, 65.0, conf=0.9)],
         excluded=[],
         frames=[[3150, -20.0], [350, -70.0], [3000, -20.0], [500, -70.0]]),
    case('cap-120-seconds', 180.0,
         [w(0.5, 13.0, conf=0.9),
          w(13.1, 25.5, conf=0.9),
          w(28.0, 42.0, conf=0.9),
          w(42.1, 56.0, conf=0.9),
          w(59.0, 74.0, conf=0.9),
          w(74.1, 89.0, conf=0.9),
          w(92.0, 102.0, conf=0.9),
          w(102.1, 112.0, conf=0.9),
          w(115.0, 128.0, conf=0.9),
          w(128.1, 141.0, conf=0.9),
          w(144.0, 147.0, conf=0.9),
          w(147.1, 150.0, conf=0.9),
          w(153.0, 161.0, conf=0.9),
          w(161.1, 169.0, conf=0.9)],
         excluded=[],
         frames=[[50, -70.0], [2500, -30.0], [250, -70.0], [2800, -20.0], [300, -70.0], [3000, -25.0], [300, -70.0], [2000, -20.0], [300, -70.0], [2600, -28.0], [300, -70.0], [600, -35.0], [300, -70.0], [1600, -35.0], [1100, -70.0]]),
    case('below-minimum', 60.0,
         [w(0.0, 7.5, conf=0.9),
          w(7.5, 15.0, conf=0.9),
          w(17.001, 22.0, conf=0.9),
          w(22.0, 26.991, conf=0.9),
          w(40.0, 44.999, conf=0.9),
          w(50.0, 52.5, conf=0.9),
          w(52.5, 55.0, conf=0.9)],
         excluded=[],
         frames=[[1500, -20.0], [200, -70.0], [999, -20.0], [1301, -70.0], [500, -20.0], [500, -70.0], [500, -20.0], [500, -70.0]]),
    case('snr-percentiles', 10.0,
         [w(1.0, 4.0, conf=0.9),
          w(4.1, 7.0, conf=0.9)],
         excluded=[],
         frames=[[100, -62.0], [300, -30.0], [300, -22.0], [300, -60.0]]),
    case('empty-transcript', 10.0,
         [],
         excluded=[],
         frames=[[1000, -70.0]]),
    # preferRange: spans that overlap the range are walked first, whatever their SNR.
    preferring('prefer-fills-cap', 200.0, [28.0, 195.0],
               (2.0, 27.0, -20.0), (30.0, 60.0, -30.0), (63.0, 93.0, -28.0), (96.0, 126.0, -32.0),
               (129.0, 159.0, -26.0), (162.0, 192.0, -24.0)),
    preferring('prefer-below-cap-filled-from-other', 180.0, [60.0, 100.0],
               (1.0, 31.0, -20.0), (34.0, 44.0, -44.0), (62.0, 82.0, -35.0), (85.0, 100.0, -40.0),
               (103.0, 133.0, -25.0), (136.0, 166.0, -30.0)),
    preferring('prefer-partial-overlap', 200.0, [19.9996, 96.0004],
               (1.0, 25.0, -40.0), (28.0, 58.0, -42.0), (61.0, 91.0, -35.0), (96.0, 126.0, -44.0),
               (129.0, 159.0, -20.0), (162.0, 192.0, -25.0)),
    preferring('prefer-overlap-at-end', 200.0, [50.0, 110.0],
               (2.0, 32.0, -20.0), (35.0, 45.0, -25.0), (55.0, 85.0, -35.0), (95.0, 125.0, -40.0),
               (130.0, 160.0, -30.0), (165.0, 190.0, -28.0)),
    preferring('prefer-no-qualifying-span', 200.0, [40.0, 60.0],
               (1.0, 21.0, -20.0), (24.0, 40.0, -44.0), (43.0, 51.0, -50.0), (54.0, 57.0, -20.0),
               (60.0, 90.0, -42.0), (93.0, 123.0, -25.0), (126.0, 156.0, -30.0), (159.0, 189.0, -35.0)),
    preferring('prefer-ties-across-groups', 200.0, [60.0, 200.0],
               (1.0, 31.0, -30.0), (34.0, 44.0, -30.0), (61.0, 91.0, -30.0), (94.0, 124.0, -30.0),
               (127.0, 157.0, -30.0), (160.0, 180.0, -30.0)),
    preferring('prefer-below-minimum', 40.0, [0.0, 40.0],
               (1.0, 21.0, -20.0), (24.0, 28.0, -20.0)),
]


def compact(value):
    return json.dumps(value, separators=(',', ':'))


def span_lines(name, spans, indent):
    if not spans:
        return [f'{indent}"{name}": []']
    return [f'{indent}"{name}": ['] + [f'{indent}  {compact(span)}' + (',' if index < len(spans) - 1 else '')
                                       for index, span in enumerate(spans)] + [f'{indent}]']


def case_lines(value):
    expected = select(value['items'], value['excluded'], value['frames'], value['duration'], value.get('preferRange'))
    lines = ['    {', f'      "id": {json.dumps(value["id"])},', f'      "duration": {json.dumps(value["duration"])},']
    if value['items']:
        lines += ['      "items": ['] + [f'        {compact(item)}' + (',' if index < len(value['items']) - 1 else '')
                                        for index, item in enumerate(value['items'])] + ['      ],']
    else:
        lines.append('      "items": [],')
    lines.append(f'      "excluded": {compact(value["excluded"])},')
    if 'preferRange' in value:
        lines.append(f'      "preferRange": {compact(value["preferRange"])},')
    lines += [f'      "frames": {compact(value["frames"])},', '      "expected": {',
              f'        "status": {json.dumps(expected["status"])},',
              f'        "availableMs": {expected["availableMs"]},',
              f'        "selectedMs": {expected["selectedMs"]},',
              f'        "preferredMs": {expected["preferredMs"]},']
    for name in ('selected', 'qualifying', 'rejected'):
        block = span_lines(name, expected[name], '        ')
        block[-1] += ',' if name != 'rejected' else ''
        lines += block
    return lines + ['      }', '    }']


constants = {'minConf': MIN_CONF, 'maxGapMs': MAX_GAP, 'spanMinMs': SPAN_MIN, 'spanMaxMs': SPAN_MAX,
             'voicedDb': VOICED, 'minSnrDb': MIN_SNR, 'totalMinMs': TOTAL_MIN, 'totalMaxMs': TOTAL_MAX}
lines = ['{', '  "schema": "voxclip-voice-lab-training-spans/1",', f'  "constants": {json.dumps(constants)},', '  "cases": [']
for index, value in enumerate(CASES):
    block = case_lines(value)
    if index < len(CASES) - 1:
        block[-1] += ','
    lines += block
lines += ['  ]', '}']
OUT.write_text('\n'.join(lines) + '\n', encoding='utf-8')
