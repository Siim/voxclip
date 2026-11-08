#!/usr/bin/env python3
"""Shared vectors for the export self-check (ADR-R49): its four rules on inputs already measured, in output seconds.

Writes shared/fixtures/export-check/check-cases.json (schema voxclip-export-check-cases/1), a file of its own so no
existing replay changes, and shared/fixtures/export-check/number-check-cases.json (schema
voxclip-export-check-number-cases/1): the words check on numbers written one way and heard another (SpokenNumbers), in
the same case shape with the result's `unverified` count. Each case is one input to `ExportCheck.run` and what its `check` must report: the status and
every item's kind and time, with the expected and heard words, the band edge, the phrase and the measured value where
they apply. Every expectation is derived by hand from the rules in its `derivation`, never from the code under test.
Swift ExportCheckReplayTests replays every case; the Windows twin owes the same replay. Deterministic; run from anywhere:

    python3 -I tools/fixtures/export-check/generate_check_cases.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/export-check/check-cases.json'
NUMBER_OUT = ROOT / 'shared/fixtures/export-check/number-check-cases.json'

FPS30 = 1 / 30
PORTRAIT = {'width': 1080, 'height': 1920}
SQUARE = {'width': 1080, 'height': 1080}
LANDSCAPE = {'width': 1920, 'height': 1080}


def spoken(text, start=1.0, step=0.5, length=0.4, optional=(), phrase=None, phrased=()):
    """Words of `text` from `start`, one every `step` seconds, each `length` long. `optional` and `phrased` are the
    indices of kept fillers and of the words a phrase speaks."""
    words = []
    for index, word in enumerate(text.split()):
        entry = {'text': word, 'start': round(start + index * step, 6), 'end': round(start + index * step + length, 6)}
        if index in optional:
            entry['optional'] = True
        if phrase and index in phrased:
            entry['phrase'] = phrase
        words.append(entry)
    return words


def heard(text, start=1.0, step=0.5, length=0.4, skip=(), shift=0.0, shifted=()):
    """What the engine heard: `text` timed like `spoken`, without the indices in `skip`, the ones in `shifted` later by
    `shift` seconds."""
    words = []
    for index, word in enumerate(text.split()):
        if index in skip:
            continue
        offset = shift if index in shifted else 0.0
        begin = round(start + index * step + offset, 6)
        words.append({'text': word, 'start': begin, 'end': round(begin + length, 6)})
    return words


def base(**overrides):
    document = {'expected': [], 'heard': [], 'cuts': [], 'phrases': [],
                'video': {'start': 0.0, 'end': 10.0}, 'audio': {'start': 0.0, 'end': 10.0}, 'frameSeconds': FPS30,
                'loudness': {'setting': 'social', 'integratedLufs': -14.0, 'truePeakDbtp': -1.2}, 'boxes': [], 'frame': PORTRAIT}
    document.update(overrides)
    return document


def case(identity, category, derivation, input_, status, items=(), **fields):
    expect = {'status': status, 'items': list(items)}
    expect.update(fields)
    return {'id': identity, 'check': category, 'derivation': derivation, 'input': input_, 'expect': expect}


def item(kind, time, **fields):
    entry = {'kind': kind, 'time': time}
    entry.update(fields)
    return entry


def box(kind, time, x, y, width, height):
    return {'kind': kind, 'time': time, 'rect': {'x': x, 'y': y, 'width': width, 'height': height}}


TEN = 'so we close deals every single week with our team'
PHRASED = 'the app ships on Friday for everyone who signed up early'


def word_cases():
    return [
        case('source-mismatch-is-reported', 'words',
             'Ten source words; "deals" (the fourth, at 2.5 s) is heard as "details", which is not a near-homophone (Soundex '
             'D42 against D342). One mismatch at its output time; 9 of 10 match, which is the 90% floor, so the check stays ok.',
             base(expected=spoken(TEN), heard=heard('so we close details every single week with our team')),
             'ok', [item('mismatch', 2.5, expected='deals', heard='details')], matched=9, total=10),
        case('mismatches-below-the-floor-warn', 'words',
             'Five words, one heard wrong: 4 of 5 is under the 90% floor, so the check warns.',
             base(expected=spoken('we close deals every week'), heard=heard('we close details every week')),
             'warning', [item('mismatch', 2.0, expected='deals', heard='details')], matched=4, total=5),
        case('cut-off-at-a-cut', 'words',
             'A cut at 2.45 s joins "close" (2.0-2.4 s) to "everything" (2.5 s). "everything" is heard as the shorter '
             '"every": a cut-off, reported as one, not as a mismatch.',
             base(expected=spoken('so we close everything for the team today'), cuts=[2.45],
                  heard=heard('so we close every for the team today')),
             'warning', [item('cutOff', 2.5, expected='everything', heard='every')], matched=7, total=8),
        case('cut-off-at-the-clip-edge', 'words',
             'The clip\'s last word "today" (4.5 s) is not heard: the last word sits at the clip\'s edge, so it is cut off.',
             base(expected=spoken('so we close everything for the team today'), heard=heard('so we close everything for the team', skip=())),
             'warning', [item('cutOff', 4.5, expected='today')], matched=7, total=8),
        case('cut-off-where-the-words-touch', 'words',
             'A recognizer\'s words touch: "close" ends at 2.5 s where "everything" starts, and the cut lies on that '
             'boundary. "everything" heard as "every" is still a cut-off: the edge test is inclusive.',
             base(expected=spoken('so we close everything for the team today', length=0.5), cuts=[2.5],
                  heard=heard('so we close every for the team today', length=0.5)),
             'warning', [item('cutOff', 2.5, expected='everything', heard='every')], matched=7, total=8),
        case('a-missing-word-away-from-cuts-is-a-mismatch', 'words',
             'The same words with no cut: "for" (3.0 s) is not heard. It is not next to a cut or an edge, so it is a mismatch '
             'with nothing heard; 9 of 10 match.',
             base(expected=spoken('so we close everything for the whole team every day'),
                  heard=heard('so we close everything for the whole team every day', skip=(4,))),
             'ok', [item('mismatch', 3.0, expected='for')], matched=9, total=10),
        case('a-kept-filler-whisper-dropped', 'words',
             'The edit keeps "um" (1.5 s, optional). Whisper drops it: not a mismatch, and it is not counted.',
             base(expected=spoken('so um we close deals', optional=(1,)), heard=heard('so we close deals', start=1.0)),
             'ok', [], matched=4, total=4),
        case('a-near-homophone-name', 'words',
             '"Claude" heard as "cloud" (both Soundex C43, one letter apart) is the name the recognizer does not know: matched.',
             base(expected=spoken('we built it with Claude Code'), heard=heard('we built it with cloud code')),
             'ok', [], matched=6, total=6),
        case('a-rewritten-phrase-is-heard-with-its-new-words', 'words',
             'A Rewrite placed "ships on Friday" (phrase p1) where the source said "shipped on Monday". The expected words '
             'are the new words, and the export says them: every word matches.',
             base(expected=spoken(PHRASED, phrase='p1', phrased=(2, 3, 4)),
                  heard=heard(PHRASED), phrases=[{'id': 'p1', 'start': 2.0, 'end': 3.5}], cuts=[2.0, 3.5]),
             'ok', [], matched=11, total=11),
        case('a-rewritten-phrase-heard-with-the-source-words', 'words',
             'The same phrase heard as the source words: "Monday" against the expected "Friday" (3.0 s) is a phrase word '
             'heard wrong, which warns although 10 of 11 is above the floor.',
             base(expected=spoken(PHRASED, phrase='p1', phrased=(2, 3, 4)),
                  heard=heard(PHRASED.replace('Friday', 'Monday')), phrases=[{'id': 'p1', 'start': 2.0, 'end': 3.5}],
                  cuts=[2.0, 3.5]),
             'warning', [item('mismatch', 3.0, expected='Friday', heard='monday', phrase='p1')], matched=10, total=11),
        case('no-local-engine-skips-words', 'words',
             'Nothing heard the export: the words check is skipped with the reason.',
             base(expected=spoken('we close deals'), heard=None),
             'skipped', [], reason='No local transcription model'),
    ]


def sync_cases():
    return [
        case('audio-two-frames-late', 'sync',
             'At 30 fps the audio track starts at 0.0667 s, two frames after the video: more than one frame, a trackStart.',
             base(audio={'start': 2 * FPS30, 'end': 10.0}), 'warning', [item('trackStart', 0.0, value=2 * FPS30, limit=FPS30)],
             startOffset=2 * FPS30, endOffset=0.0),
        case('tracks-end-within-a-frame', 'sync',
             'The audio ends 0.02 s after the video, under one 30 fps frame (0.0333 s): ok.',
             base(audio={'start': 0.0, 'end': 10.02}), 'ok', [], startOffset=0.0, endOffset=0.02),
        case('a-phrase-heard-outside-the-tolerance', 'sync',
             'Phrase p1\'s words are heard 0.5 s after their placed times: the median offset 0.5 s is over 0.30 s.',
             base(expected=spoken('the app ships on Friday for everyone', phrase='p1', phrased=(2, 3, 4)),
                  heard=heard('the app ships on Friday for everyone', shift=0.5, shifted=(2, 3, 4)),
                  phrases=[{'id': 'p1', 'start': 2.0, 'end': 3.5}]),
             'warning', [item('phraseOffset', 2.0, value=0.5, limit=0.3, phrase='p1')], startOffset=0.0, endOffset=0.0),
        case('a-phrase-heard-inside-the-tolerance', 'sync',
             'The same phrase heard 0.1 s late: within 0.30 s, ok.',
             base(expected=spoken('the app ships on Friday for everyone', phrase='p1', phrased=(2, 3, 4)),
                  heard=heard('the app ships on Friday for everyone', shift=0.1, shifted=(2, 3, 4)),
                  phrases=[{'id': 'p1', 'start': 2.0, 'end': 3.5}]),
             'ok', [], startOffset=0.0, endOffset=0.0),
        case('a-phrase-not-heard', 'sync',
             'None of p1\'s words are heard: its placement cannot be measured, which warns.',
             base(expected=spoken('the app ships on Friday for everyone', phrase='p1', phrased=(2, 3, 4)),
                  heard=heard('the app ships on Friday for everyone', skip=(2, 3, 4)),
                  phrases=[{'id': 'p1', 'start': 2.0, 'end': 3.5}]),
             'warning', [item('phraseNotHeard', 2.0, phrase='p1')], startOffset=0.0, endOffset=0.0),
        case('phrases-skipped-without-an-engine', 'sync',
             'Nothing heard the export: the tracks are still measured (ok), and the phrases are listed as skipped.',
             base(expected=spoken('the app ships on Friday', phrase='p1', phrased=(2, 3, 4)), heard=None,
                  phrases=[{'id': 'p1', 'start': 2.0, 'end': 3.5}]),
             'ok', [item('phrasesSkipped', 2.0, reason='No local transcription model')], startOffset=0.0, endOffset=0.0),
        case('audio-only-export', 'sync', 'No video track and no phrase: nothing to measure.',
             base(video=None), 'skipped', [], reason='No video track'),
    ]


def loudness_cases():
    def measured(lufs, peak, setting='social'):
        return {'setting': setting, 'integratedLufs': lufs, 'truePeakDbtp': peak}
    return [
        case('minus-20-lufs-warns', 'loudness', '-20 LUFS is 6 LU under -14, outside the 1 LU tolerance.',
             base(loudness=measured(-20.0, -6.0)), 'warning', [item('integratedLoudness', 0.0, value=-20.0, limit=-14.0)],
             integratedLufs=-20.0, truePeakDbtp=-6.0),
        case('minus-14-passes', 'loudness', '-14.0 LUFS with the true peak at -1.0 dBTP: on target.',
             base(loudness=measured(-14.0, -1.0)), 'ok', [], integratedLufs=-14.0, truePeakDbtp=-1.0),
        case('aac-ringing-within-the-meter-tolerance', 'loudness',
             '-14.6 LUFS (within 1 LU) and a decoded true peak of -0.85 dBTP: AAC rings past the PCM\'s -1 dBTP, within the '
             '0.2 dB meter tolerance.',
             base(loudness=measured(-14.6, -0.85)), 'ok', [], integratedLufs=-14.6, truePeakDbtp=-0.85),
        case('a-true-peak-over-the-ceiling', 'loudness', 'A true peak of -0.5 dBTP is 0.5 dB over the -1 dBTP ceiling.',
             base(loudness=measured(-14.2, -0.5)), 'warning', [item('truePeak', 0.0, value=-0.5, limit=-1.0)],
             integratedLufs=-14.2, truePeakDbtp=-0.5),
        case('loudness-off-is-skipped', 'loudness', 'The export ran with loudness off: skipped with that reason.',
             base(loudness=measured(-23.0, -9.0, 'off')), 'skipped', [], reason='Loudness is off for this export'),
        case('a-silent-export', 'loudness', 'Nothing above the gate: no integrated loudness, which warns.',
             base(loudness=measured(None, None)), 'warning', [item('silent', 0.0)]),
        case('no-audio-track', 'loudness', 'No audio track: skipped.', base(loudness=None), 'skipped', [], reason='No audio track'),
    ]


def caption_cases():
    return [
        case('a-caption-in-the-9x16-bottom-band', 'captions',
             'A 9:16 card from 0.74 to 0.86 of the height reaches 0.08 into the bottom 22% band (from 0.78).',
             base(boxes=[box('caption', 1.0, 0.1, 0.74, 0.8, 0.12)]), 'warning',
             [item('captionBand', 1.0, value=0.08, limit=0.22, band='bottom')]),
        case('a-caption-clear-of-the-9x16-bands', 'captions', 'A 9:16 card from 0.6 to 0.7 is clear of both bands.',
             base(boxes=[box('caption', 1.0, 0.1, 0.6, 0.8, 0.1)]), 'ok', []),
        case('a-title-in-the-9x16-top-band', 'captions',
             'A 9:16 title from 0.1 to 0.18 reaches 0.02 into the top 12% band.',
             base(boxes=[box('title', 0.0, 0.04, 0.1, 0.92, 0.08)]), 'warning',
             [item('titleBand', 0.0, value=0.02, limit=0.12, band='top')]),
        case('the-same-card-on-16x9', 'captions',
             'On 16:9 only the bottom 10% is a band: a card from 0.74 to 0.86 is clear, one from 0.85 to 0.95 reaches 0.05 in.',
             base(frame=LANDSCAPE, boxes=[box('caption', 1.0, 0.1, 0.74, 0.8, 0.12), box('caption', 2.0, 0.1, 0.85, 0.8, 0.1)]),
             'warning', [item('captionBand', 2.0, value=0.05, limit=0.1, band='bottom')]),
        case('1x1-bottom-band', 'captions', 'On 1:1 the bottom 12% is the band: a card ending at 0.9 reaches 0.02 in.',
             base(frame=SQUARE, boxes=[box('caption', 1.0, 0.1, 0.8, 0.8, 0.1)]), 'warning',
             [item('captionBand', 1.0, value=0.02, limit=0.12, band='bottom')]),
        case('cards-at-one-place-report-once', 'captions',
             'Three 9:16 cards at the same place in the bottom band, then a clear one: one finding at the first card\'s time '
             'with a count of 3.',
             base(boxes=[box('caption', 1.0, 0.1, 0.74, 0.8, 0.12), box('caption', 1.5, 0.1, 0.74, 0.8, 0.12),
                         box('caption', 2.0, 0.1, 0.74, 0.8, 0.12), box('caption', 2.5, 0.1, 0.6, 0.8, 0.1)]), 'warning',
             [item('captionBand', 1.0, value=0.08, limit=0.22, band='bottom', count=3)]),
        case('nothing-drawn', 'captions', 'No caption card and no title: skipped.', base(), 'skipped', [],
             reason='No captions or title in this export'),
    ]


PAID = 'we paid a three hundred dollar bill for it'


def number_cases():
    return [
        case('a-spelled-amount-heard-in-digits', 'words',
             'The lead\'s real case: the edit says "a three hundred dollar bill" (a cut at 2.45 s before "three") and '
             'Whisper writes "a $300 bill". "$300" reads three hundred dollars, so "three", "hundred" and "dollar" all '
             'match it: no cut-off, no mismatch, 9 of 9.',
             base(expected=spoken(PAID), cuts=[2.45], heard=heard('we paid a $300 bill for it')),
             'ok', [], matched=9, total=9),
        case('an-amount-in-digits-heard-spelled', 'words',
             'The reverse: the edit writes "$300" and Whisper spells "three hundred dollars". 5 of 5.',
             base(expected=spoken('we paid $300 for it'), heard=heard('we paid three hundred dollars for it')),
             'ok', [], matched=5, total=5),
        case('a-wrong-amount-in-digits-is-a-mismatch', 'words',
             'Heard "$30" where the edit says "three hundred dollar", with the cut before "three". 30 is not 300, so the '
             'three words are mismatches; "three" takes "30", which is a numeral, so it is never a shorter word cut off. '
             '6 of 9 is under the floor: warning.',
             base(expected=spoken(PAID), cuts=[2.45], heard=heard('we paid a $30 bill for it')),
             'warning', [item('mismatch', 2.5, expected='three', heard='30'), item('mismatch', 3.0, expected='hundred'),
                         item('mismatch', 3.5, expected='dollar')], matched=6, total=9),
        case('a-number-in-another-language-is-unverified', 'words',
             'German: the edit says "dreihundert" and Whisper writes "300". With no spelled-number table for German the '
             'number is unverified: neither matched nor a mismatch, left out of the total and counted once.',
             base(expected=spoken('das kostet dreihundert Euro heute'), heard=heard('das kostet 300 Euro heute')),
             'ok', [], matched=4, total=4, unverified=1),
    ]


def write_numbers():
    cases = number_cases()
    document = {
        'schema': 'voxclip-export-check-number-cases/1',
        'description': ('The export self-check\'s words check (ADR-R49) on numbers written one way in the edit and heard '
                        'another (SpokenNumbers, shared/fixtures/spoken-numbers/number-cases.json): a numeral matches a run '
                        'of English number words saying the same number, a number heard as a numeral is never cut off, and '
                        'a numeral facing only another language\'s words is unverified, out of matched and total, and '
                        'counted in `unverified`. Same case shape and replay rules as check-cases.json. Generated by '
                        'tools/fixtures/export-check/generate_check_cases.py; do not hand-edit.'),
        'constants': {'matchFloor': 0.9},
        'caseCount': len(cases),
        'counts': {'words': len(cases)},
        'cases': cases,
    }
    NUMBER_OUT.write_text(json.dumps(document, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')


def main():
    cases = word_cases() + sync_cases() + loudness_cases() + caption_cases()
    counts = {}
    for entry in cases:
        counts[entry['check']] = counts.get(entry['check'], 0) + 1
    document = {
        'schema': 'voxclip-export-check-cases/1',
        'description': ('The export self-check (ADR-R49) on measured inputs, all times in output seconds. Each case is one '
                        'ExportCheckInput and the status and items its `check` reports. Words: matched on VoiceLabTakeQuality '
                        'tokens with near-homophones of expected words accepted; a word next to a cut or a clip edge that is '
                        'missing or heard as one shorter different word is a cutOff; kept fillers are optional; warning on a '
                        'cutOff, a phrase word heard wrong or under 90% matched. Sync: tracks within one frame at start and '
                        'end; each phrase\'s median heard-minus-placed start offset within 0.30 s. Loudness: -14 LUFS within '
                        '1 LU, true peak at most -1 dBTP plus 0.2 dB. Captions: boxes clear of the safe-zone bands (9:16 top '
                        '12% and bottom 22%, 1:1 bottom 12%, 16:9 bottom 10%), a run of cards at one depth reported once with its count. Replays compare statuses, kinds, words, bands '
                        'and phrases exactly and numbers within 1e-9. Generated by '
                        'tools/fixtures/export-check/generate_check_cases.py; do not hand-edit.'),
        'constants': {'matchFloor': 0.9, 'phraseToleranceSeconds': 0.3, 'targetLufs': -14.0, 'loudnessToleranceLu': 1.0,
                      'ceilingDbtp': -1.0, 'truePeakToleranceDb': 0.2,
                      'bands': {'portrait': {'top': 0.12, 'bottom': 0.22}, 'square': {'bottom': 0.12}, 'landscape': {'bottom': 0.1}}},
        'caseCount': len(cases),
        'counts': counts,
        'cases': cases,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(document, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
    write_numbers()


if __name__ == '__main__':
    main()
