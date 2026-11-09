#!/usr/bin/env python3
"""Generate the shared `voxclip-cli analyze-frames` output vectors (ADR-R48, package W5 of "Windows sees the picture").

Writes shared/fixtures/clip-frames/analyze-frames-cli-cases.json (schema voxclip-analyze-frames-cli-cases/1), a new file of its
own so no existing replay's keys or counts change. Each case is a fabricated clip analysis (words, the clip's word range, the
source's video facts, the sentence frames and opening scan in the Mac's JSON shape, the frame sheet's image sizes and byte
counts, and the whole-video pass's fields when the case has one) and the exact bytes `voxclip-cli analyze-frames --json`
prints for it: the Mac's JSONEncoder with sorted keys and unescaped slashes, Swift's number text, and a final newline. The
Mac's CLIAnalyzeFramesVectorTests and the Windows CliAnalyzeFramesTests rebuild every case through the CLIs' own report code
and compare bytes.

The decisions come from generate_frame_decisions.py, the reference implementation of the shared frame decisions, imported
as it is. Swift prints a Double as its `description` without a trailing ".0" (1.0 is "1", 1.234e-05 stays exponential
below 1e-4 and above 2^53); `swift_number` reproduces that from Python's shortest repr. Every face's centre has x = 0.5, so the
cover's centring distance is |dy| exactly whether a Core calls hypot or sqrt. Pure IEEE arithmetic, so byte-exact
(check_drift.py lists it as EXACT); run from anywhere.
"""
import json
import math
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_frame_decisions as frames  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-frames/analyze-frames-cli-cases.json'
VERSION = '0.0.0-fixture'


# MARK: The Mac CLI's JSON text

def swift_number(value):
    """A number as Swift's JSONEncoder writes it: an integer as it is; a Double as its `description` (the shortest round-trip
    digits, exponential below 1e-4 and above 2^53, two exponent digits at least) without a trailing ".0"."""
    if isinstance(value, bool):
        raise TypeError('a bool is not a number')
    if isinstance(value, int):
        return str(value)
    if not math.isfinite(value):
        raise ValueError('JSON has no infinities')
    if value == 0:
        return '-0' if math.copysign(1.0, value) < 0 else '0'
    sign = '-' if value < 0 else ''
    text = repr(abs(value))
    mantissa, exponent = (text.split('e') + ['0'])[:2]
    whole, _, fraction = mantissa.partition('.')
    every = whole + fraction
    lead = len(every) - len(every.lstrip('0'))
    digits = every.strip('0') or '0'
    scientific = len(whole) - lead - 1 + int(exponent)
    if scientific < -4 or abs(value) > 2.0 ** 53:
        rest = digits[1:]
        return f"{sign}{digits[0]}{'.' + rest if rest else ''}e{'-' if scientific < 0 else '+'}{abs(scientific):02d}"
    if scientific < 0:
        return f"{sign}0.{'0' * (-scientific - 1)}{digits}"
    integer = digits[:scientific + 1].ljust(scientific + 1, '0')
    rest = digits[scientific + 1:]
    return f"{sign}{integer}{'.' + rest if rest else ''}"


def mac_text(value):
    """JSONEncoder([.sortedKeys, .withoutEscapingSlashes]) of a JSON value, compact."""
    if value is None:
        return 'null'
    if value is True:
        return 'true'
    if value is False:
        return 'false'
    if isinstance(value, (int, float)):
        return swift_number(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return '[' + ','.join(mac_text(item) for item in value) + ']'
    return '{' + ','.join(json.dumps(key, ensure_ascii=False) + ':' + mac_text(value[key]) for key in sorted(value)) + '}'


# MARK: The CLI's report (apps/macos/Sources/voxclip-cli/AnalyzeFrames.swift, FrameAnalyzerCLI.report)

def source_aspect(video):
    if not video or video['width'] <= 0 or video['height'] <= 0:
        return 16.0 / 9.0
    width, height = float(video['width']), float(video['height'])
    return width / height if video['rotationDegrees'] % 180 == 0 else height / width


def report(case):
    clip = frames.frame_clip(case['words'], case['clip']['first'], case['clip']['last'], set(case['clip']['cut']))
    analysis = case['analysis']
    sentences, opening = analysis['sentences'], analysis['opening']
    baseline = case['videoPass']['pitchBaseline'] if case['videoPass'] is not None else frames.pitch_baseline(sentences + opening)
    sheet = [{'index': item['index'], 'observation': sentences[item['sentence']]} for item in case['sheet']]
    samples = [{'time': frame['time'], 'face': frame['face']['rect']} if frame.get('face') else {'time': frame['time']} for frame in sentences]
    aspect = source_aspect(case['video'])
    summary = frames.summary(sheet, baseline)
    decisions = {
        'pitchBaseline': baseline,
        'opening': frames.choose_opening(clip, opening, baseline),
        'cover': frames.cover_pick(opening + sentences, baseline),
        'blurSpans': frames.merge_spans(sentences, frames.BLUR_MAX_GAP, frames.BLUR_PAD),
        'blurCandidates': frames.blur_candidates(sentences, clip['start'], clip['end']),
        'coverCandidates': frames.cover_candidates(sheet, baseline),
        'crop9x16': frames.crop_plan(samples, aspect, 9.0 / 16.0),
        'crop1x1': frames.crop_plan(samples, aspect, 1),
    }
    sheet_fields = {
        'frames': len(case['sheet']),
        'imageBytes': sum(item['bytes'] for item in case['sheet']),
        'estimatedImageTokens': sum(math.ceil(float(item['width']) * float(item['height']) / frames.PIXELS_PER_TOKEN) for item in case['sheet']),
        'estimatedSummaryTokens': math.ceil(len(summary.encode('utf-8')) / 2.2),
        'summary': summary,
    }
    output = {'clipStart': clip['start'], 'clipEnd': clip['end'], 'analysis': analysis, 'decisions': decisions, 'sheet': sheet_fields,
              'ok': True, 'command': 'analyze-frames', 'version': VERSION}
    if case['videoPass'] is not None:
        output['videoPass'] = case['videoPass']
    return mac_text(output) + '\n'


# MARK: Cases

word = frames.word
rect = frames.rect
face = frames.face
observation = frames.observation


def scan(start, faces_by_time):
    """The opening scan's frames at `start`: a face where `faces_by_time` names one (by millisecond), no face elsewhere."""
    result = []
    for time in frames.opening_times(start):
        found = faces_by_time.get(round(time * 1000))
        result.append(observation(time, found) if found else observation(time))
    return result


def analysis(content_key, sentences, opening, timings):
    return {'contentKey': content_key, 'sentences': sentences, 'opening': opening, 'timings': timings, 'version': 2}


def timings(sentence, opening, cached, analyzed):
    return {'sentenceSeconds': sentence, 'openingSeconds': opening, 'cachedFrames': cached, 'analyzedFrames': analyzed}


def phone_lines():
    return [rect(0.62, 0.55 + 0.08 * line, 0.24, 0.04) for line in range(3)]


def dense_lines():
    return [rect(0.05, 0.1 + 0.05 * line, 0.3, 0.03) for line in range(8)]


def cases():
    key = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90'
    talk = [word('w1', 'Hello', 1.0, 1.3), word('w2', 'there.', 1.4, 1.8), word('w3', 'This', 2.2, 2.5),
            word('w4', 'is', 2.6, 2.8), word('w5', 'my', 2.9, 3.1), word('w6', 'phone.', 3.2, 3.6)]
    phone = phone_lines()
    first = observation(1.62, face(rect(0.4, 0.2, 0.2, 0.4), 0.71, 0.31, 0.29, 0.05, 0.12))
    second = observation(2.98, face(rect(0.4, 0.25, 0.2, 0.4), 0.55, 0.28, 0.3, -0.1, 0.18), face_count=2, texts=phone,
                         screens=frames.detect_screens([rect(0.6, 0.5, 0.3, 0.4)], phone))
    opening = scan(1.0, {800: face(rect(0.4, 0.22, 0.2, 0.4), 0.45, 0.27, 0.26, 0.02, 0.1),
                         900: face(rect(0.4, 0.22, 0.2, 0.4), 0.38, 0.24, 0.25, 0.02, 0.11),
                         1000: face(rect(0.4, 0.22, 0.2, 0.4), 0.6, 0.15, 0.16, 0.0, 0.1),
                         1100: face(rect(0.4, 0.21, 0.2, 0.4), 0.66, 0.3, 0.31, 0.01, 0.13)})
    counter = [word('w1', 'One', 0.8, 1.0), word('w2', 'two.', 1.1, 1.4), word('w3', 'Three', 2.0, 2.3), word('w4', 'four.', 2.4, 2.8)]
    dense = dense_lines()
    turned = observation(1.27, face(rect(0.4, 0.3, 0.2, 0.3), 0.64, 0.33, 0.33, 0.52, 0.04))
    reading = observation(2.61, face(rect(0.4, 0.35, 0.2, 0.3), 0.5, 0.29, 0.27, -0.03, 0.06), texts=dense,
                          screens=frames.detect_screens([], dense))
    return [
        {'id': 'faces-and-a-phone', 'note': 'A landscape talk: two sentence frames with faces (the second the larger of two, holding a '
                                            'phone with three lines inside its quad), and an opening scan whose start frame blinks, so '
                                            'the opening moves to the open look 0.2 s before.',
         'words': talk, 'clip': {'first': 0, 'last': 5, 'cut': []}, 'video': {'width': 1920, 'height': 1080, 'rotationDegrees': 0},
         'analysis': analysis(key, [first, second], opening, timings(0.4567, 1.2345678, 3, 12)),
         'sheet': [{'index': 1, 'sentence': 0, 'width': 320, 'height': 180, 'bytes': 9123},
                   {'index': 2, 'sentence': 1, 'width': 320, 'height': 180, 'bytes': 8456}],
         'videoPass': None},
        {'id': 'no-face', 'note': "The Mac's counter fixture as the CLI test reads it: no face and no text anywhere, no video facts (16:9), "
                                  'so there is no typical pitch, opening, cover or blur, and both crops hold the centre. Tiny timings '
                                  'print in Swift exponent form.',
         'words': counter, 'clip': {'first': 0, 'last': 3, 'cut': []}, 'video': None,
         'analysis': analysis(key, [observation(1.25), observation(2.6)], scan(0.8, {}), timings(0.000123, 0.00001234, 0, 15)),
         'sheet': [{'index': 1, 'sentence': 0, 'width': 320, 'height': 180, 'bytes': 4100},
                   {'index': 2, 'sentence': 1, 'width': 320, 'height': 180, 'bytes': 4096}],
         'videoPass': None},
        {'id': 'video-pass-portrait', 'note': "A phone recording turned 90° (portrait) after the whole video's pass: facing is judged "
                                              "against the pass's typical pitch, the first frame's face is turned away, the second "
                                              "reads a dense text cluster without a quad, and the first word is cut.",
         'words': counter, 'clip': {'first': 0, 'last': 3, 'cut': ['w1']}, 'video': {'width': 1920, 'height': 1080, 'rotationDegrees': 90},
         'analysis': analysis(key, [turned, reading], scan(1.1, {1100: face(rect(0.4, 0.3, 0.2, 0.3), 0.58, 0.3, 0.3, 0.0, 0.05)}),
                              timings(0.0, 0.25, 15, 0)),
         'sheet': [{'index': 1, 'sentence': 0, 'width': 180, 'height': 320, 'bytes': 7000},
                   {'index': 2, 'sentence': 1, 'width': 180, 'height': 320, 'bytes': 7311}],
         'videoPass': {'read': True, 'frames': 2, 'analyzed': 2, 'cached': 0, 'seconds': 1.5, 'clipFrames': 2, 'clipSeconds': 0.012,
                       'openingFrames': 13, 'openingSeconds': 0.25, 'pitchBaseline': 0.05}},
    ]


def number_cases():
    """Swift's Double text for the CLI's numbers, so each Core's writer is pinned on its own."""
    values = [0.0, -0.0, 1.0, 2.5, -0.19999999999999996, 0.1, 1.0 / 3.0, 100.0, 1234567.0, 0.0001, 0.00012, 0.00001234, 1e-7,
              -3.5e-6, 2.0 ** 53, 2.0 ** 53 + 2, 1e16, 1.5e300, 5e-324, 123456789.125, 16.0 / 9.0]
    return [{'value': value, 'text': swift_number(value)} for value in values]


def generated():
    built = cases()
    for case in built:
        case['json'] = report(case)
    numbers = number_cases()
    return {
        'schema': 'voxclip-analyze-frames-cli-cases/1',
        'description': 'voxclip-cli analyze-frames --json output for fabricated analyses (ADR-R48, W5): the exact bytes both CLIs print. '
                       'Regenerate with tools/fixtures/clip-frames/generate_analyze_frames.py; do not hand-edit.',
        'version': VERSION,
        'caseCount': len(built) + len(numbers),
        'counts': {'reports': len(built), 'numbers': len(numbers)},
        'reports': built,
        'numbers': numbers,
    }


def main():
    DESTINATION.write_text(json.dumps(generated(), indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
