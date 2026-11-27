#!/usr/bin/env python3
"""Write synthetic TakeMatch vectors with explicitly selected beats, spans and placements."""
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
CONSTANTS = dict(
    minimumSimilarity=0.6, minimumWordRatio=0.5, maximumWordRatio=2,
    sentencePauseSeconds=1.2, maxSentenceWords=41, sentencePunctuation=".!?。！？",
    closingPunctuation="\"'”’)", clauseBreaks=",，、-–—.。", maxRestartWords=8,
    restartMajority=0.5, falseStartSeconds=10, restartRunSeconds=3, minRestartRunWords=2,
    isolatedTailGapWords=2,
    restartPhrases={
        "en": ["sorry where was i", "let me start again", "one more time"],
        "et": ["vabandust kus ma olin", "alustan uuesti", "üks kord veel"],
        "de": ["sorry wo war ich", "ich fange noch mal an", "noch einmal"],
    },
)


def line(text, *, gap=0, pauses=None, kinds=None, confidence=None, flags=(), **signals):
    return dict(text=text, gap=gap, pauses=pauses or {}, kinds=kinds or {},
                confidence=confidence or {}, flags=flags, signals=signals)


def vector(name, scripts, beat_order, *, spans=None, solo=()):
    spans = spans or {}
    recordings, lines, takes = [], {}, {}
    for recording_index, (key, script) in enumerate(scripts.items(), 1):
        words, cursor = [], 0.0
        for line_index, row in enumerate(script, 1):
            ref = (key, line_index)
            cursor += row['gap']
            sentence = []
            for offset, text in enumerate(row['text'].split(), 1):
                cursor += row['pauses'].get(offset, 0)
                prefix = 's:' if recording_index == 1 else f'r{recording_index}.w'
                sentence.append(dict(id=f'{prefix}{len(words) + offset}', text=text,
                                     kind=row['kinds'].get(offset, 'word'), start=cursor, end=cursor + 0.5,
                                     rawStart=None, rawEnd=None, conf=row['confidence'].get(offset),
                                     speaker=None, timing='native'))
                cursor += 0.5
            words.extend(sentence)
            lines[ref] = sentence
            cut_off = line_index in (1, len(script))
            words_per_minute = 60 * sum(word['kind'] == 'word' for word in sentence) / (sentence[-1]['end'] - sentence[0]['start'])
            signals = dict(fillers=0, longestPause=0, restarts=0, wordsPerMinute=words_per_minute, cutOff=cut_off)
            signals.update(row['signals'])
            takes[ref] = dict(key=key, startWordId=sentence[0]['id'], endWordId=sentence[-1]['id'],
                              flags=[*row['flags'], *(['cutOff'] if cut_off else [])], signals=signals)
        recordings.append(dict(key=key, words=words))

    beats = []
    for index, group in enumerate(beat_order, 1):
        aligned = []
        for source in group:
            for target in group:
                if source == target:
                    continue
                words = lines[target]
                first, last, changed = spans.get((source, target), (1, len(words), ()))
                aligned.append(dict(fromKey=source[0], toKey=target[0], startWordId=words[first - 1]['id'],
                                    endWordId=words[last - 1]['id'], changedWordIds=[words[offset - 1]['id'] for offset in changed]))
        beats.append(dict(id=f'beat{index}', takes=[takes[ref] for ref in group], spans=aligned))
    assert sorted(takes) == sorted(ref for group in beat_order for ref in group), name

    runs = []
    for key, first, last, after, before in solo:
        placement = dict(key=key, startWordId=lines[key, first][0]['id'], endWordId=lines[key, last][-1]['id'],
                         sentenceCount=last - first + 1)
        if after is not None:
            placement['afterBeatId'] = f'beat{after}'
        if before is not None:
            placement['beforeBeatId'] = f'beat{before}'
        runs.append(placement)
    return dict(id=name, recordings=recordings, expected=dict(beats=beats, solo=runs))


CASES = [
    vector('three-retakes-one-rewording-one-punchline', {
        '0007': [line('We built this for creators.'), line('It saves hours every week.'), line('Now ship the next version.')],
        '0006': [line('We built this for creators.'), line('It saves hours each week.'), line('Now ship the next version.')],
        '0010': [line('We built this for creators.'), line('It saves hours every week.'),
                 line("It's a reporting tool."), line('Now ship the next version.')],
    }, [[('0007', 1), ('0006', 1), ('0010', 1)], [('0007', 2), ('0006', 2), ('0010', 2)],
        [('0010', 3)], [('0007', 3), ('0006', 3), ('0010', 4)]],
        spans={(source, target): (1, 5, (4,)) for source in [('0007', 2), ('0006', 2), ('0010', 2)]
               for target in [('0007', 2), ('0006', 2), ('0010', 2)]
               if (source[0] == '0006') != (target[0] == '0006')},
        solo=[('0010', 3, 3, 2, 4)]),
    vector('filler-heavy-and-delivery', {
        'primary': [line('We can ship today.')],
        'alternate': [line('Um, we uh can [knock] [speech] erm ship today.',
                           pauses={4: 0.75}, kinds={5: 'event', 6: 'unlabeledSpeech'},
                           confidence={1: 0.5, 9: 1}, fillers=4, longestPause=0.75, meanConfidence=0.75)],
    }, [[('primary', 1), ('alternate', 1)]],
        spans={(('primary', 1), ('alternate', 1)): (2, 9, (3, 5, 6, 7))}),
    vector('restart-flags-and-delivery-restart', {
        'take': [line('We we we can finish today.', restarts=1),
                 line('Sorry, where was I… so, so.', flags=['restart'], restarts=1),
                 line('Um, uh, well well.', flags=['restart'], fillers=2, restarts=1),
                 line('Vabandust, kus ma olin?', flags=['restart']),
                 line('Ich fange noch mal an.', flags=['restart']),
                 line('Done for today.')],
    }, [[('take', index)] for index in range(1, 7)], solo=[('take', 1, 1, None, None), ('take', 6, 6, None, None)]),
    vector('false-start-at-ten-seconds-but-not-after', {
        'take': [line('The next step.', flags=['falseStart']), line('The next step is quiet.', gap=10),
                 line('We should stop.'), line('We should stop soon.', gap=10.25)],
    },
        [[('take', index)] for index in range(1, 5)], solo=[('take', 2, 4, None, None)]),
    vector('run-on-opening', {
        '0007': [line('So I started Superscribe as, uh, a dictation tool, kind of for time.', fillers=1)],
        '0010': [line('I started Superscribe as a dictation tool that supports time tracking, and then, um, it grew.', fillers=1)],
    }, [[('0007', 1), ('0010', 1)]],
        spans={(('0007', 1), ('0010', 1)): (1, 11, (8, 9, 10, 11)),
               (('0010', 1), ('0007', 1)): (1, 13, (1, 6, 10, 11, 12, 13))}),
    vector('solo-runs-before-between-and-after', {
        'base': [line('Keep the first anchor.'), line('Close with our final point.')],
        'pickup': [line('A quiet prelude.'), line('Keep the first anchor.'), line('An extra idea.'),
                   line('A useful example.'), line('Close with our final point.'), line('The coda.')],
    }, [[('pickup', 1)], [('base', 1), ('pickup', 2)], [('pickup', 3)], [('pickup', 4)],
        [('base', 2), ('pickup', 5)], [('pickup', 6)]],
        solo=[('pickup', 1, 1, None, 2), ('pickup', 3, 4, 2, 5), ('pickup', 6, 6, 5, None)]),
    vector('different-scripts', {
        'garden': [line('Tomatoes grow in warm soil.'), line('Water them before sunrise.')],
        'budget': [line('Savings rose by nine percent.'), line('Bonuses should track revenue.')],
    }, [[('garden', 1)], [('garden', 2)], [('budget', 1)], [('budget', 2)]],
        solo=[('garden', 1, 2, None, None), ('budget', 1, 2, None, None)]),
    vector('greedy-monotonic-order', {
        'base': [line('Apples taste sweet.'), line('Lemons taste sour.')],
        'reversed': [line('Lemons taste sour.'), line('Apples taste sweet.')],
    }, [[('reversed', 1)], [('base', 1), ('reversed', 2)], [('base', 2)]],
        solo=[('base', 2, 2, 2, None), ('reversed', 1, 1, None, 2)]),
    vector('similarity-and-word-ratio-boundaries', {
        'base': [line('Red green blue orange yellow.'), line('Peach pear.'), line('Berries ripen.')],
        'alternate': [line('Red green blue amber purple.'), line('Peach pear are sweet.'), line('Berries ripen slowly every summer.')],
    }, [[('base', 1), ('alternate', 1)], [('base', 2), ('alternate', 2)], [('base', 3)], [('alternate', 3)]],
        spans={(('base', 1), ('alternate', 1)): (1, 5, (4, 5)), (('alternate', 1), ('base', 1)): (1, 5, (4, 5)),
               (('base', 2), ('alternate', 2)): (1, 4, (3, 4))},
        solo=[('base', 3, 3, 2, None), ('alternate', 3, 3, 2, None)]),
    vector('clause-prefix-and-suffix', {
        'base': [line('Keep the exact wording today.')],
        'alternate': [line('Listen— keep the exact wording today, then leave.')],
    }, [[('base', 1), ('alternate', 1)]], spans={(('base', 1), ('alternate', 1)): (2, 6, ())}),
    vector('transitive-similarity-does-not-make-a-version', {
        'base': [line('Red green blue orange yellow.')],
        'middle': [line('Red green blue silver gold.')],
        'last': [line('Blue silver gold black white.')],
    }, [[('base', 1), ('middle', 1)], [('last', 1)]],
        spans={(('base', 1), ('middle', 1)): (1, 5, (4, 5)), (('middle', 1), ('base', 1)): (1, 5, (4, 5))},
        solo=[('last', 1, 1, None, None)]),
    vector('sentence-line-breaks', {
        'only': [line(' '.join(f'word{index}' for index in range(1, 42))), line('Fresh words'),
                 line('Next line!”', gap=1.25), line('End')],
        'empty': [],
    }, [[('only', index)] for index in range(1, 5)], solo=[('only', 1, 4, None, None)]),
    vector('no-recordings', {}, []),
]


if __name__ == '__main__':
    output = ROOT / 'shared/fixtures/recordings/take-match-cases.json'
    output.write_text(json.dumps(dict(constants=CONSTANTS, cases=CASES), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
