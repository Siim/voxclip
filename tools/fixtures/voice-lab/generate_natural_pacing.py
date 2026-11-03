import argparse
import json
from pathlib import Path


def document():
    def cut(case_id, quiet, removed=1.4, expected=None, speech=None, levels=None):
        return {'id': case_id, 'windowStartSample': 0, 'windowEndSample': 240000,
                'outputSamples': 240000 - round(removed * 48000), 'quietBlocks': quiet,
                'levels': levels or [], 'speech': speech or [], 'expected': expected or []}

    cut_cases = [
        cut('continuous-speech-short-boundaries', [[80, 86], [220, 226]],
            expected=[[38400, 105600]],
            speech=[{'kind': 'word', 'start': 0.86, 'end': 2.2}]),
        cut('no-boundary-pair', [[80, 84], [225, 229]]),
        cut('speech-onset-is-not-quiet-boundary', [[80, 84], [216, 220]]),
        cut('edge-guards-refuse', [[0, 6], [140, 146]]),
        cut('edge-guard-inclusive', [[26, 34], [170, 176]], expected=[[14400, 81600]]),
        cut('runs-under-forty-ms-refuse', [[80, 83], [220, 223]]),
        cut('word-blocks-boundary', [[80, 86], [220, 226]],
            speech=[{'kind': 'word', 'start': 0.8, 'end': 0.86}]),
        cut('unlabeled-speech-blocks-boundary', [[80, 86], [220, 226]],
            speech=[{'kind': 'unlabeled-speech', 'start': 0.8, 'end': 0.86}]),
        cut('earliest-boundary-tie', [[80, 86], [220, 226]], expected=[[38400, 105600]]),
        cut('lowest-boundary-power', [[80, 86], [220, 226]], expected=[[38880, 106080]],
            levels=[[81, 0.001], [221, 0.001]]),
        cut('whole-quiet-run-still-valid', [[100, 400]], removed=2, expected=[[48000, 144000]]),
        cut('two-spans-only-without-single', [[50, 56], [100, 106], [250, 256], [300, 306]],
            removed=1, expected=[[24000, 48000], [120000, 144000]]),
        cut('fractional-block-length', [[80, 86], [220, 226]], removed=1.405,
            expected=[[38400, 105840]]),
    ]
    pause_cases = [
        {'id': 'tagged-growth', 'windowSeconds': 1.8, 'beforeToken': 1, 'kind': 'insert', 'editedGap': 2},
        {'id': 'tagged-shrink', 'windowSeconds': 1.2, 'beforeToken': 1, 'kind': 'remove', 'editedGap': 2},
        {'id': 'other-tagged-gap', 'windowSeconds': 1.8, 'beforeToken': 2, 'kind': 'insert', 'editedGap': 1},
    ]
    return {
        'schema': 'voxclip-natural-pacing/2',
        'sourceSampleRate': 48000,
        'caseCount': 2,
        'cases': [
            {'id': 'short-hard-window', 'windowSeconds': 0.3,
             'reserveSeconds': 0.06, 'speechSeconds': 0.18},
            {'id': 'long-hard-window', 'windowSeconds': 1.1,
             'reserveSeconds': 0.14, 'speechSeconds': 0.82},
        ],
        'cutCaseCount': len(cut_cases), 'cutCases': cut_cases,
        'pauseCaseCount': len(pause_cases), 'pauseCases': pause_cases,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/natural-pacing-cases.json'
    rendered = json.dumps(document(), indent=2) + '\n'
    if args.check:
        if path.read_text() != rendered:
            raise SystemExit('natural-pacing-cases.json differs; regenerate it')
        print('natural-pacing-cases.json: identical')
    else:
        path.write_text(rendered)
