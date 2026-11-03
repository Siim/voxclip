"""Natural-pacing review vectors: paid-rate cut length, borrowed hard reserve and empty pause classes.

Kept apart from natural-pacing-cases.json, whose exact keys and case counts both Cores already replay.
"""
import argparse
import json
from pathlib import Path

SOURCE_RATE = 48000
PAUSE_SECONDS = 0.14
WINDOW_PAUSE_FRACTION = 0.20
PAUSE_FLOOR_PUNCT = 0.150
PAUSE_FLOOR_PHRASE = 0.060


def js_round(value):
    return int(value + 0.5) if value >= 0 else -int(-value + 0.5)


def paid_rate_cut(case_id, window_end, asset_rate, take_frames, cut_start):
    # The video output is jsRound((windowEnd − windowStart + residual) × sourceRate), not take frames scaled to the
    # source rate. Over an odd window at half the source rate the two differ by one sample.
    window_frames = js_round(window_end * asset_rate / SOURCE_RATE)
    residual_frames = take_frames - window_frames
    output = window_end + residual_frames * SOURCE_RATE // asset_rate
    return {'id': case_id, 'assetSampleRate': asset_rate, 'takeFrames': take_frames, 'windowEndSample': window_end,
            'sourceQuietBlocks': [[50, 56], [190, 196]], 'outputSamples': output,
            'expectedCuts': [[cut_start, cut_start + window_end - output]]}


def borrowed_reserve(case_id, window_seconds, outgoing_silence, speech_seconds):
    # One voiced word longer than its slot borrows from the gap side; the hard side then reserves 20% of the widened
    # window w, which holds the reserve and the word: w = speech + 0.2 w.
    widened = speech_seconds / (1 - WINDOW_PAUSE_FRACTION)
    assert widened * WINDOW_PAUSE_FRACTION < PAUSE_SECONDS and widened - window_seconds < outgoing_silence
    reserve = round(widened * WINDOW_PAUSE_FRACTION * SOURCE_RATE)
    return {'id': case_id, 'windowSeconds': window_seconds, 'outgoingSilenceSeconds': outgoing_silence,
            'speechSeconds': speech_seconds, 'reserveFrames': reserve,
            'windowEndSample': round(speech_seconds * SOURCE_RATE) + reserve}


def empty_class(case_id, tokens, within, between, punctuation):
    # Words 0–0.3 s and 0.6–1.0 s around one 0.3 s pause, fitted into 0.7 s: the class has no measured pauses, so the
    # pause keeps its legacy floor instead of shrinking to the 45 ms fade minimum.
    floor = PAUSE_FLOOR_PUNCT if punctuation else PAUSE_FLOOR_PHRASE
    return {'id': case_id, 'tokens': tokens, 'withinSentence': within, 'betweenSentences': between,
            'windowSeconds': 0.7, 'removedFrames': round((0.3 - floor) * SOURCE_RATE)}


def document():
    paid = [paid_rate_cut('odd-window-half-rate-take', 115201, 24000, 24000, 24000)]
    borrowed = [borrowed_reserve('short-hard-window-borrows-gap', 0.5, 0.4, 0.45)]
    empty = [
        empty_class('empty-between-sentence-class', ['done.', 'next'], [0.1, 0.2, 0.3], [], True),
        empty_class('empty-within-sentence-class', ['one', 'two'], [], [0.1, 0.2, 0.3], False),
    ]
    return {
        'schema': 'voxclip-natural-pacing-review/1',
        'sourceSampleRate': SOURCE_RATE,
        'paidRateCutCaseCount': len(paid), 'paidRateCutCases': paid,
        'borrowedReserveCaseCount': len(borrowed), 'borrowedReserveCases': borrowed,
        'emptyClassCaseCount': len(empty), 'emptyClassCases': empty,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/natural-pacing-review-cases.json'
    rendered = json.dumps(document(), indent=2) + '\n'
    if args.check:
        if path.read_text() != rendered:
            raise SystemExit('natural-pacing-review-cases.json differs; regenerate it')
        print('natural-pacing-review-cases.json: identical')
    else:
        path.write_text(rendered)
