#!/usr/bin/env python3
"""Generate the whole-clip revoice's fit on the clip as edited (ADR-R46 update 2026-11-08, voice-lab section 8.14 item 4).

Writes shared/fixtures/voice-lab/whole-clip-fit-cases.json (format voxclip-whole-clip-fit/1), a file of its own so the twin's
replay of whole-clip-revoice-cases.json keeps its key set:
- usersClip: the user's live run in MVP44 (2026-11-08) as numbers only. Every transcript word's start, end, whether the edit cuts
  it and whether it ends a sentence; the clip's first and last word; the pauses the edit tightens (by the word they follow); the
  project's pause threshold and keep; the source's length and rate; the script's words; the voice's measured seconds; and what
  the panel and the log showed (the clip as edited 0:31.4, the parts' source windows 48.6 s). No word of the recording.
- fit: the verdict on the voice against the clip as edited: within 8% matched, shorter laid out (never a longer wording),
  longer a shorter wording of about words / factor, then cannotFit after two rounds; with each verdict's copy.
- rewordFits: check before paying, the reworded script's estimate scaled by the measured voice against the clip plus 8%.
- layoutCuts: the clip's own cuts moved to remove exactly a number of window samples (trim the end, or give cut picture back
  from the latest cut), or null when the window can't.
- editedCuts: the clip's own cuts inside a window, read off the source pieces of the clip's output plan.
- pauseBound: the layout's sentence-pause bound from the project's pause threshold.
An independent stdlib reference of the Mac WholeClipRevoice.swift; both Cores replay every case (Swift WholeClipFitReplayTests,
C# WholeClipFitReplayTests). Rounding is half away from zero on the exact binary64 value. Byte-exact in check_drift.py.
"""
import json
import math
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/whole-clip-fit-cases.json'

FIT_TOLERANCE = 0.08
MAXIMUM_REWORD_ROUNDS = 2
PAUSE_FLOOR_PUNCT = 0.150
PAUSE_FLOOR_PHRASE = 0.060
EDITED_CUT_ZOOM = 1.0
MAXIMUM_EDITED_CUTS = 512
MINUS = chr(0x2212)
PLUS_MINUS = chr(0xB1)

# The user's clip, numbers only: [start, end, cut, endsSentence] for every transcript word, in order.
USER_WORDS = [
    [0, 0.345, 0, 0], [0.345, 0.595, 0, 0], [0.595, 1.045, 0, 0], [1.045, 1.625, 0, 0], [1.625, 2.32, 0, 0], [2.93, 3.9, 0, 0],
    [4.03, 4.425, 0, 0], [4.425, 5.015, 0, 0], [5.015, 5.11, 0, 0], [5.12, 5.195, 0, 0], [5.195, 5.54, 0, 0], [5.58, 6, 0, 0],
    [6.6, 6.725, 1, 0], [6.725, 7.23, 1, 0], [7.23, 8.16, 1, 0], [8.27, 8.69, 0, 0], [8.75, 9.155, 0, 0], [9.155, 9.83, 0, 1],
    [10.47, 11.135, 1, 0], [11.135, 11.335, 0, 0], [11.335, 11.51, 0, 0], [11.54, 11.675, 0, 0], [11.675, 12.27, 0, 1],
    [12.81, 13.11, 0, 0], [13.11, 13.345, 0, 0], [13.345, 13.57, 0, 0], [13.57, 13.99, 0, 1], [14.85, 15.08, 0, 0],
    [15.12, 15.44, 0, 0], [15.45, 15.655, 0, 0], [15.655, 15.94, 0, 0], [16.8, 17.225, 0, 0], [17.225, 17.61, 0, 0],
    [17.64, 17.96, 0, 0], [18, 18.56, 0, 1], [18.91, 19.65, 1, 0], [21.46, 21.545, 1, 0], [21.545, 22.13, 1, 1],
    [24.02, 24.69, 0, 0], [25.01, 25.98, 0, 0], [26.25, 27.05, 0, 0], [28.28, 28.725, 0, 0], [28.725, 29.32, 0, 1],
    [29.96, 30.14, 0, 0], [30.14, 30.42, 0, 0], [30.42, 30.68, 0, 0], [31.76, 32.28, 0, 1], [34.14, 34.65, 1, 0],
    [34.66, 34.865, 1, 0], [34.865, 35.73, 1, 0], [36.13, 36.64, 1, 0], [37.38, 37.45, 0, 0], [37.46, 37.745, 0, 0],
    [37.745, 38.65, 0, 0], [40.73, 41.11, 0, 0], [42.32, 42.8, 0, 0], [43.66, 44.22, 0, 0], [44.22, 44.565, 0, 0],
    [44.565, 44.805, 0, 0], [44.805, 45.015, 0, 0], [45.015, 45.68, 0, 0], [46.47, 47.12, 0, 0], [48.6, 48.735, 0, 0],
    [48.735, 49.16, 0, 0], [49.23, 50.08, 0, 1], [51.11, 51.82, 0, 0]]


def away(value):
    """Round half away from zero on the exact value of a double."""
    return int(Decimal(value).to_integral_value(rounding=ROUND_HALF_UP))


def signed_percent(factor):
    percent = (factor - 1) * 100
    rounded = away(percent * 10) / 10
    sign = MINUS if rounded < 0 else '+' if rounded > 0 else PLUS_MINUS
    return f'{sign}{"%.1f" % abs(rounded)}%'


def users_clip():
    return {
        'words': USER_WORDS,
        'clipFirstWord': 4, 'clipLastWord': 64,
        'cutPausesAfterWord': [26, 30, 37, 40, 45, 46, 53, 54, 55, 61],
        'pauseThresholdSeconds': 0.8, 'pauseKeepSeconds': 0.15,
        'durationSeconds': 52.628, 'sampleRate': 48000,
        'scriptWords': 49, 'voiceSeconds': 27.0,
        'shown': {'editedSeconds': 31.4, 'sourceWindowSeconds': 48.6},
        'expected': fit(27.0, 31.4, 49, 0),
        'before': {'kind': 'reword', 'shorter': False, 'targetWords': away(49 / (27.0 / 48.6))},
    }


# MARK: - Fit

def fit(voice, video, words, rounds):
    if not (math.isfinite(voice) and math.isfinite(video)) or voice <= 0 or video <= 0:
        return {'kind': 'cannotFit'}
    factor = voice / video
    if abs(factor - 1) <= FIT_TOLERANCE + 1e-9:
        return {'kind': 'matched', 'factor': factor, 'copy': f'video matched ({signed_percent(factor)})'}
    if factor < 1:
        return {'kind': 'laidOut', 'factor': factor, 'copy': f"laid out on the clip's pauses ({signed_percent(factor)})"}
    if rounds >= MAXIMUM_REWORD_ROUNDS or words <= 0:
        return {'kind': 'cannotFit'}
    return {'kind': 'reword', 'targetWords': max(1, away(words / factor))}


def fit_cases():
    rows = [(27, 31.4, 49, 0), (27, 48.6, 49, 0), (27, 31.4, 49, 2), (30.6, 31, 74, 0), (36, 31, 7, 0), (36, 31, 7, 1),
            (36, 31, 7, 2), (40, 31, 0, 0), (108, 100, 74, 0), (108.1, 100, 100, 0), (92, 100, 74, 0), (91.9, 100, 74, 0),
            (10, 100, 74, 0), (0.5, 100, 3, 2), (0, 31, 10, 0), (31, 0, 10, 0), (-1, 31, 10, 0), (100, 100, 50, 0),
            (106.25, 100, 9, 0), (93.75, 100, 9, 0)]
    return [{'voiceSeconds': voice, 'videoSeconds': video, 'words': words, 'round': rounds, 'expected': fit(voice, video, words, rounds)}
            for voice, video, words, rounds in rows]


# MARK: - Check before paying

def predicted(voice, estimate, new_estimate):
    values = [voice, estimate, new_estimate]
    if not all(math.isfinite(value) and value > 0 for value in values):
        return None
    return voice * new_estimate / estimate


def reword_fits(voice, estimate, new_estimate, video):
    found = predicted(voice, estimate, new_estimate)
    if found is None or not math.isfinite(video) or video <= 0:
        return False
    return found <= video * (1 + FIT_TOLERANCE) + 1e-9


def reword_cases():
    rows = [(36, 10, 9.8, 31), (36, 10, 8.6, 31), (36, 10, 9.3, 31), (36, 10, 9.299, 31), (36, 10, 12, 31), (36, 0, 8, 31),
            (36, 10, 0, 31), (0, 10, 8, 31), (36, 10, 8, 0), (40, 20, 18.6, 34.4), (33.48, 10, 10, 31)]
    return [{'voiceSeconds': voice, 'estimateSeconds': estimate, 'newEstimateSeconds': new, 'videoSeconds': video,
             'predicted': predicted(voice, estimate, new), 'fits': reword_fits(voice, estimate, new, video)}
            for voice, estimate, new, video in rows]


# MARK: - The picture under a laid-out voice

def layout_cuts(cuts, start, end, removed):
    span = end - start
    if span <= 0 or removed < 0 or removed >= span:
        return None
    if not all(c[0] >= start and c[1] <= end and c[1] > c[0] for c in cuts):
        return None
    ordered = sorted(cuts, key=lambda c: c[0])
    if any(a[1] > b[0] for a, b in zip(ordered, ordered[1:])):
        return None
    total = sum(c[1] - c[0] for c in ordered)
    if removed <= total:
        give = total - removed
        result = [list(c) for c in ordered]
        for index in reversed(range(len(result))):
            if give <= 0:
                break
            take = min(give, result[index][1] - result[index][0])
            result[index][0] += take
            give -= take
        return [c for c in result if c[1] > c[0]]
    kept = []
    cursor = start
    for c in ordered:
        if c[0] > cursor:
            kept.append([cursor, c[0]])
        cursor = c[1]
    if cursor < end:
        kept.append([cursor, end])
    extra = removed - total
    for index in reversed(range(len(kept))):
        if extra <= 0:
            break
        take = min(extra, kept[index][1] - kept[index][0])
        kept[index][1] -= take
        extra -= take
    kept = [k for k in kept if k[1] > k[0]]
    if extra != 0 or not kept:
        return None
    result = []
    cursor = start
    for k in kept:
        if k[0] > cursor:
            result.append([cursor, k[0]])
        cursor = k[1]
    if cursor < end:
        result.append([cursor, end])
    return result


def layout_cases():
    two = [[1000, 1500], [3000, 3200]]
    rows = [
        ('the clip as edited exactly', two, 0, 5000, 700),
        ('a shorter voice trims the end', two, 0, 5000, 1000),
        ('the trim reaches past a cut into the stretch before it', two, 0, 5000, 2700),
        ('the trim meets a cut at the end', [[1000, 1500], [4000, 5000]], 0, 5000, 2000),
        ('a longer voice gives back the latest cut first', two, 0, 5000, 600),
        ('give back reaches the earlier cut', two, 0, 5000, 300),
        ('every cut given back', two, 0, 5000, 0),
        ('a window with no cuts trims its end', [], 0, 5000, 400),
        ('a window with no cuts and nothing to remove', [], 0, 5000, 0),
        ('a cut at the window start stays', [[0, 400], [2000, 2100]], 0, 5000, 600),
        ('nothing may be left', two, 0, 5000, 5000),
        ('a negative removal', two, 0, 5000, -1),
        ('a cut outside the window', [[4900, 5100]], 0, 5000, 300),
        ('overlapping cuts', [[100, 300], [200, 400]], 0, 5000, 300),
        ('unordered cuts are ordered', [[3000, 3200], [1000, 1500]], 0, 5000, 900),
        ('an offset window', [[12000, 12500]], 10000, 20000, 1500),
    ]
    return [{'id': name, 'cuts': [{'startSample': c[0], 'endSample': c[1]} for c in cuts], 'startSample': start, 'endSample': end,
             'removedSamples': removed,
             'expected': None if (found := layout_cuts(cuts, start, end, removed)) is None
             else [{'startSample': c[0], 'endSample': c[1]} for c in found]}
            for name, cuts, start, end, removed in rows]


# MARK: - The clip's own cuts in a window

def edited_cuts(pieces, start, end):
    if end <= start:
        return []
    cuts, cursor = [], start
    for piece in sorted(pieces, key=lambda p: p[0]):
        if piece[1] <= start or piece[0] >= end:
            continue
        lower = max(piece[0], start)
        if lower > cursor:
            cuts.append([cursor, lower])
        cursor = max(cursor, min(piece[1], end))
    if cursor < end:
        cuts.append([cursor, end])
    return cuts


def edited_cases():
    pieces = [[1000, 2000], [2500, 4000], [4100, 6000]]
    rows = [
        ('two cuts inside the window', pieces, 1000, 6000),
        ('the window starts before the first piece', pieces, 500, 6000),
        ('the window ends after the last piece', pieces, 1000, 6500),
        ('a window inside one piece', pieces, 2600, 3900),
        ('a window over only a cut', pieces, 2100, 2400),
        ('an empty window', pieces, 3000, 3000),
        ('pieces out of order', [[4100, 6000], [1000, 2000], [2500, 4000]], 1000, 6000),
    ]
    return [{'id': name, 'pieces': [{'sourceStartSample': p[0], 'sourceEndSample': p[1]} for p in pieces], 'startSample': start,
             'endSample': end, 'expected': [{'startSample': c[0], 'endSample': c[1]} for c in edited_cuts(pieces, start, end)]}
            for name, pieces, start, end in rows]


def pause_bound_cases():
    return [{'pauseThresholdSeconds': value, 'bound': max(PAUSE_FLOOR_PUNCT, value)} for value in [0.8, 1.0, 0.3, 0.1, 2.5]]


def main():
    document = {
        'format': 'voxclip-whole-clip-fit/1',
        'constants': {'fitTolerance': FIT_TOLERANCE, 'maximumRewordRounds': MAXIMUM_REWORD_ROUNDS,
                      'editedCutZoom': EDITED_CUT_ZOOM, 'maximumEditedCuts': MAXIMUM_EDITED_CUTS,
                      'pauseFloorPunct': PAUSE_FLOOR_PUNCT, 'pauseFloorPhrase': PAUSE_FLOOR_PHRASE},
        'usersClip': users_clip(),
        'fit': fit_cases(),
        'rewordFits': reword_cases(),
        'layoutCuts': layout_cases(),
        'editedCuts': edited_cases(),
        'pauseBound': pause_bound_cases(),
    }
    OUT.write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
