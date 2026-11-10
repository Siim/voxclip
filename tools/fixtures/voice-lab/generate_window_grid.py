#!/usr/bin/env python3
"""Write window vectors off the source sample grid, loading only the single-window reference's definitions.

voice-lab.md section 10.1 (2026-11-10): a word meets a replace range on the source sample grid, by its boundaries rounded
with the fit's JavaScript half-up rule, because the fit plan and the recipe store each window edge as its sample over the
source rate (section 8.9.2). Before, validation and the output planner compared in exact seconds, so a touching boundary
off the grid could not be stored without a word crossing it by under a sample: a seam at a cut was refused in `place`
(windowCrossesWord), and a hard seam at a touching kept word placed but failed at Use (invalidRange). Every accepted window
here validates and prepares in its scope and in the full take, both as `place` returns it and as the fit stores it.

`grid` pins the rule itself: whether an item lies inside a range and whether it crosses either edge.
"""
import ast
import json
from decimal import getcontext
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[2] / 'shared/fixtures/voice-lab/window-grid-cases.json'
SCHEMA = 'voxclip-voice-lab-window-grid-cases/1'


def definitions():
    path = HERE / 'generate_window.py'
    tree = ast.parse(path.read_text(encoding='utf-8'), str(path))
    body = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef))
            or isinstance(node, ast.Assign) and all(isinstance(target, ast.Name) and target.id.isupper() for target in node.targets)]
    namespace = {'__file__': str(path), '__name__': path.stem}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(path), 'exec'), namespace)
    getcontext().prec = 60
    return namespace


def generate(reference):
    word, window_case, render_failure = reference['word'], reference['window_case'], reference['render_failure']
    stored_window, samples = reference['stored_window'], reference['samples']
    grid_inside, grid_crosses = reference['grid_inside'], reference['grid_crosses']

    def chain(names, start, ends):
        """Words that touch: each starts where the one before it ends. `ends` gives each word's end."""
        items, time = [], start
        for name, end in zip(names, ends):
            items.append(word(name, time, end))
            time = end
        return items

    cases = []

    def add(name, items, first, last, rate=48000, tail=0.8, duration=None, **options):
        duration = items[-1]['end'] + tail if duration is None else duration
        case = window_case(name, items, duration, first=first, last=last, rate=rate, **options)
        expected, project = case['expected'], case['input']
        if 'error' in expected:
            case['stored'] = None
        else:
            stored = stored_window(expected, project['sampleRate'])
            clip = project['clipId']
            for window in (expected, stored):
                for scope in (clip, None) if clip is not None else (None,):
                    failure = render_failure(project, scope, window)
                    assert failure is None, (name, scope, failure)
            case['stored'] = {'start': stored['start'], 'end': stored['end']}
        cases.append(case)
        return case

    # The user's shape (MVP48, 2026-11-09): a cut word touching the phrase, its end stored as 15.655000000000001, one ulp
    # past 15.655. The seam rounds to sample 751 440, which the fit stores as 15.655: under the cut word's end by an ulp.
    ulp = 15.655000000000001
    take = [word('w1', 14.2, 14.9), word('w2', 15.1, 15.4)] + chain(['um', 'we', 'ship', 'it'], 15.4, [ulp, 15.9, 16.3, 16.7])
    add('seam-at-cut-ulp-off-grid', take, 'we', 'ship', cut=['um'])
    # Exactly half a sample off the 48 kHz grid: 534 480.5 rounds half up to 534 481, the seam's sample.
    half = 534480.5 / 48000
    take = [word('w1', 10.2, 10.8)] + chain(['so', 'we', 'ship', 'it'], 10.8, [half, 11.5, 11.9, 12.3])
    add('seam-at-cut-half-sample', take, 'we', 'ship', cut=['so'])
    # A hard seam at a touching kept word: no gap within three words on either side, every boundary off the 44.1 kHz grid.
    take = chain(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'], 0.5,
                 [0.8123, 1.1347, 1.4571, 1.7795, 2.1019, 2.4243, 2.7467, 3.0691, 3.3915])
    add('hard-seam-touching-kept-words-44100', take, 'e', 'e', rate=44100)
    add('hard-seam-touching-kept-words-48000', take, 'e', 'e')
    # The same touching kept word exactly half a sample off the grid, on both sides of the passage.
    take = chain(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'], 0.5,
                 [0.8, 1.1, 1.4, 81_600.5 / 48000, 2.0, 100_800.5 / 48000, 2.4, 2.7, 3.0, 3.3])
    add('hard-seam-touching-kept-word-half-sample', take, 'e', 'f')
    # The take's end off the grid by half a sample: the window closes on the take end, which the fit stores one sample
    # past durationSeconds (sample jsRound(durationSeconds x rate)).
    take = chain(['a', 'b', 'c', 'd'], 0.5, [0.8, 1.1, 1.4, 1.7])
    add('take-end-half-sample', take, 'd', 'd', duration=90_000.5 / 48000)
    # A clip that opens mid-take on a word touching the one before it, off the 44.1 kHz grid: the window opens the clip's
    # output at the clip's own start, which the fit stores on the grid.
    take = chain(['and', 'w1', 'w2', 'w3', 'w4'], 0.7, [1.0003, 1.3007, 1.6011, 1.9015, 2.2019])
    add('clip-start-off-grid', take, 'w1', 'w1', rate=44100, clip='c1', clips=[('c1', 'w1', 'w3')])
    # Still refused: a kept word that really crosses the passage's start, overlapping it by 2.5 samples, with no gap within
    # three words before it, so the seam is hard at the passage's start.
    take = [word('x', 0.0, 0.2), word('y', 0.2, 0.5), word('a', 0.5, 0.8), word('b', 0.8, 1.1 + 2.5 / 48000), word('c', 1.1, 1.4),
            word('d', 1.4, 1.7), word('e', 1.9, 2.2)]
    add('kept-word-crossing-still-refused', take, 'c', 'c')

    def by(name):
        return next(case for case in cases if case['name'] == name)

    seam = by('seam-at-cut-ulp-off-grid')['expected']['leftSeam']
    assert seam['kind'] == 'hard' and seam['sample'] == 751440 and seam['time'] == ulp, seam
    assert by('seam-at-cut-ulp-off-grid')['stored']['start'] == 15.655 < ulp
    assert by('seam-at-cut-half-sample')['expected']['leftSeam']['sample'] == 534481
    for name in ('hard-seam-touching-kept-words-44100', 'hard-seam-touching-kept-words-48000', 'hard-seam-touching-kept-word-half-sample'):
        expected = by(name)['expected']
        assert expected['leftSeam']['kind'] == expected['rightSeam']['kind'] == 'hard', name
        assert by(name)['stored']['start'] != expected['start'] or by(name)['stored']['end'] != expected['end'], name
    assert by('hard-seam-touching-kept-word-half-sample')['expected']['startSample'] == 81601
    assert by('take-end-half-sample')['expected']['rightSeam']['kind'] == 'none'
    assert by('take-end-half-sample')['stored']['end'] > by('take-end-half-sample')['input']['durationSeconds']
    clip_left = by('clip-start-off-grid')['expected']['leftSeam']
    assert clip_left['kind'] == 'hard' and by('clip-start-off-grid')['stored']['start'] != clip_left['time'], clip_left
    assert by('kept-word-crossing-still-refused')['expected'] == {'error': 'windowCrossesWord', 'wordId': 'b'}

    # The rule itself: an item (start, end) against a range (lo, hi) at a source rate.
    grid = []

    def check(name, rate, item, span):
        lo, hi = span
        grid.append({'name': name, 'sampleRate': rate, 'item': {'start': item[0], 'end': item[1]}, 'range': {'start': lo, 'end': hi},
                     'inside': grid_inside(lo, hi, item[0], item[1], rate),
                     'crossesStart': grid_crosses(item[0], item[1], samples(lo, rate), rate),
                     'crossesEnd': grid_crosses(item[0], item[1], samples(hi, rate), rate)})

    check('touching-before-ulp', 48000, (15.1, ulp), (15.655, 16.3))
    check('passage-after-ulp', 48000, (ulp, 15.9), (15.655, 16.3))
    check('half-sample-meets-next-sample', 48000, (half, 11.5), (534481 / 48000, 11.9))
    check('half-sample-before-meets', 48000, (10.8, half), (534481 / 48000, 11.9))
    check('under-half-sample-rounds-down', 44100, (1.0, 44_100.4 / 44100), (1.0 + 1 / 44100, 1.5))
    check('crosses-by-two-and-a-half-samples', 48000, (0.8, 1.1 + 2.5 / 48000), (1.1, 1.4))
    check('crosses-end-by-two-samples', 48000, (1.3, 1.4 + 2 / 48000), (1.1, 1.4))
    check('rounds-past-the-edge-crosses', 48000, (0.8, 52_800.6 / 48000), (1.1, 1.4))
    check('wholly-inside', 44100, (1.2, 1.3), (1.1, 1.4))
    check('wholly-outside', 44100, (0.2, 0.3), (1.1, 1.4))
    expected = {name: (inside, start, end) for name, inside, start, end in [
        ('touching-before-ulp', False, False, False), ('passage-after-ulp', True, False, False),
        ('half-sample-meets-next-sample', True, False, False), ('half-sample-before-meets', False, False, False),
        ('under-half-sample-rounds-down', False, False, False), ('crosses-by-two-and-a-half-samples', False, True, False),
        ('crosses-end-by-two-samples', False, False, True), ('rounds-past-the-edge-crosses', False, True, False),
        ('wholly-inside', True, False, False), ('wholly-outside', False, False, False)]}
    for case in grid:
        assert (case['inside'], case['crossesStart'], case['crossesEnd']) == expected[case['name']], case
    print('window grid: %d window cases (%d accepted), %d grid cases'
          % (len(cases), sum('error' not in case['expected'] for case in cases), len(grid)))
    return {'schema': SCHEMA, 'caseCount': len(cases) + len(grid), 'windows': cases, 'grid': grid}


if __name__ == '__main__':
    document = generate(definitions())
    windows, document['windows'] = document['windows'], '@@windows@@'
    grid, document['grid'] = document['grid'], '@@grid@@'
    # One case per line keeps the file reviewable.
    text = json.dumps(document, indent=2)
    for key, items in (('windows', windows), ('grid', grid)):
        text = text.replace('"@@%s@@"' % key, '[\n' + ',\n'.join('    ' + json.dumps(case) for case in items) + '\n  ]')
    OUT.write_text(text + '\n', encoding='utf-8')
