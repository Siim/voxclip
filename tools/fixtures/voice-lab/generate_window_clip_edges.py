#!/usr/bin/env python3
"""Write exact clip-edge window vectors, loading only the single-window reference's definitions.

A clip that starts or ends mid-take often touches the word before or after it: Whisper word ends are back to back
(transcription.md section 5.5), so the clip's own edge leaves no silence for a seam. voice-lab.md section 8.4 makes such
an edge the clip's output edge: the seam keeps the kind and fade the full take renders it with, nothing renders beside it
in the clip, and it must still hold in the full take. Every accepted window here validates and prepares in its clip and in
the full take.
"""
import ast
import json
from decimal import getcontext
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[2] / 'shared/fixtures/voice-lab/window-clip-edge-cases.json'
SCHEMA = 'voxclip-voice-lab-window-clip-edge-cases/1'
FUZZ_SEED = 20261108
FUZZ_TAKES = 4000
FUZZ_STRIDE = 40


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
    word, window_case, place, run_case = reference['word'], reference['window_case'], reference['place'], reference['run_case']
    render_failure, clip_output_edges = reference['render_failure'], reference['clip_output_edges']
    stored_window = reference['stored_window']
    take_input, passage_room_tone = reference['take_input'], reference['passage_room_tone']
    envelope_levels, samples, frame_size = reference['envelope_levels'], reference['samples'], reference['frame_size']
    REFUSALS = reference['REFUSALS']

    def project_of(case):
        return case['input']

    def checked(case):
        """Adds what both Cores check beside the window: the sides that open or close the clip's output, and that an
        accepted window renders in its clip and in the full take."""
        project, clip_id, expected = project_of(case), case['input']['clipId'], case['expected']
        if 'error' in expected:
            case['clipOutputEdges'] = None
            return case
        # Also as the fit stores it, on the source grid (voice-lab section 8.9.2).
        for window in (expected, stored_window(expected, project['sampleRate'])):
            assert render_failure(project, clip_id, window) is None, case['name']
            assert render_failure(project, None, window) is None, case['name']
        edges = clip_output_edges(project, clip_id, expected)
        case['clipOutputEdges'] = {'incoming': True in edges, 'outgoing': False in edges}
        return case

    def touching(texts, start=0.7, length=0.3, gaps=None):
        """Words of `length` seconds from `start`, each touching the one before it unless `gaps` names the silence before it."""
        items, time = [], start
        for index, text in enumerate(texts):
            time += (gaps or {}).get(index, 0.0)
            items.append(word(text, time, time + length))
            time += length
        return items

    cases = []

    def add(name, items, clip, first, last, cut=(), rate=48000, tail=0.8, **options):
        duration = items[-1]['end'] + tail
        case = window_case(name, items, duration, cut=cut, first=first, last=last, rate=rate, clip='c1',
                           clips=[('c1',) + clip], **options)
        cases.append(checked(case))
        return case

    # The user's clip, reduced: a clip opens on a word that touches the one before it.
    plain = touching(['and', 'w1', 'w2', 'w3', 'w4', 'w5'], gaps={4: 0.5})
    add('opens-mid-take-first-word', plain, ('w1', 'w4'), 'w1', 'w1')
    add('opens-mid-take-whole-sentence', plain, ('w1', 'w4'), 'w1', 'w3')
    closes = touching(['w0', 'w1', 'w2', 'w3', 'w4', 'so'], gaps={1: 0.5})
    add('closes-mid-take-last-word', closes, ('w1', 'w4'), 'w4', 'w4')
    add('closes-mid-take-whole-sentence', closes, ('w1', 'w4'), 'w2', 'w4')
    both = touching(['and', 'w1', 'w2', 'w3', 'w4', 'so'])
    add('opens-and-closes-whole-clip', both, ('w1', 'w4'), 'w1', 'w4')
    add('opens-and-closes-first-word', both, ('w1', 'w4'), 'w1', 'w1')
    add('opens-and-closes-last-word', both, ('w1', 'w4'), 'w4', 'w4')
    # At 44.1 kHz the hard fade is 529 samples: the outgoing outer half (265) is the odd one.
    add('closes-mid-take-44100', closes, ('w1', 'w4'), 'w4', 'w4', rate=44100)
    add('opens-and-closes-44100', both, ('w1', 'w4'), 'w1', 'w4', rate=44100)
    # A 65 ms silence: the clip opens 32.5 ms before w1 and the hard seam would sit 30 ms before it, leaving a 2.5 ms sliver
    # of the clip's source beside it. The seam moves to the clip's own start and the window absorbs the sliver.
    sliver = touching(['and', 'w1', 'w2', 'w3', 'w4', 'w5'], gaps={1: 0.065, 5: 0.065})
    add('opens-after-sliver', sliver, ('w1', 'w4'), 'w1', 'w1')
    add('closes-before-sliver', sliver, ('w1', 'w4'), 'w4', 'w4')
    # Cut words at the clip's edges, touching the words outside it: the window absorbs them up to the clip's own edge.
    fillers = touching(['and', 'um', 'w2', 'w3', 'w4', 'uh', 'so'])
    add('opens-on-cut-filler', fillers, ('um', 'uh'), 'w2', 'w2', cut=['um', 'uh'])
    add('closes-on-cut-filler', fillers, ('um', 'uh'), 'w4', 'w4', cut=['um', 'uh'])
    add('cut-fillers-whole-clip', fillers, ('um', 'uh'), 'w2', 'w4', cut=['um', 'uh'])
    # The word before the clip is cut in the project: the full take holds the fade's outer half across that cut, in the
    # source before it, as prepare holds it.
    cut_before = touching(['w0', 'and', 'w2', 'w3', 'w4'], gaps={4: 0.5})
    add('full-take-fade-across-cut', cut_before, ('w2', 'w3'), 'w2', 'w2', cut=['and'])
    # Every item before the clip is cut: nothing renders before the window in the full take either, where a fade seam is
    # refused, so the window is refused with the full take's numbers.
    alone = touching(['and', 'w1', 'w2', 'w3'], start=0.0, gaps={3: 0.5})
    add('full-take-nothing-before', alone, ('w1', 'w2'), 'w1', 'w1', cut=['and'])
    # A replacement already opens the clip: the next sentence's window sits after it as before, and the replacement's
    # clip-edge seam still renders.
    add('replacement-opens-clip', plain, ('w1', 'w4'), 'w4', 'w4', replacements=[('w1', 'w1', True, 'c1')])
    # Unchanged: a passage outside the clip, and a window whose absorbed word runs past the clip's end.
    add('passage-outside-clip-still-refused', closes, ('w1', 'w3'), 'w4', 'w4')
    # The clip ends 0.25 s after its last item, an event nested in the cut word w1, which runs on past the clip's end: the
    # window holding w1 would end outside the clip, so it is not the clip's output edge and is refused as before.
    nested = [word('w0', 0.0, 0.3), word('w1', 0.3, 0.79), word('e1', 0.3301, 0.5082, 'event', '(laughs)'), word('w3', 1.5, 1.8)]
    add('absorbed-word-past-clip-end-still-refused', nested, ('w1', 'e1'), 'w1', 'e1', cut=['w1'])

    names = [case['name'] for case in cases]
    assert len(set(names)) == len(names)

    def by(name):
        return next(case for case in cases if case['name'] == name)

    hard_left = {'kind': 'hard', 'time': 1.0, 'sample': 48000, 'fadeSamples': 576}
    assert by('opens-mid-take-first-word')['expected']['leftSeam'] == hard_left
    assert by('opens-mid-take-first-word')['clipOutputEdges'] == {'incoming': True, 'outgoing': False}
    assert by('closes-mid-take-last-word')['expected']['rightSeam']['kind'] == 'hard'
    assert by('closes-mid-take-last-word')['clipOutputEdges'] == {'incoming': False, 'outgoing': True}
    assert by('opens-and-closes-whole-clip')['clipOutputEdges'] == {'incoming': True, 'outgoing': True}
    assert by('closes-mid-take-44100')['expected']['rightSeam']['fadeSamples'] == 529
    sliver_left = by('opens-after-sliver')['expected']['leftSeam']
    assert sliver_left['time'] == 1.0 + 0.065 - 0.0325 and sliver_left['kind'] == 'hard'
    assert by('closes-before-sliver')['expected']['rightSeam']['time'] == 2.265 + 0.0325
    assert by('opens-on-cut-filler')['expected']['firstWordId'] == 'um'
    assert by('closes-on-cut-filler')['expected']['lastWordId'] == 'uh'
    assert 'error' not in by('full-take-fade-across-cut')['expected']
    assert by('full-take-nothing-before')['expected'] == {'error': 'seamFadeCrossesCut', 'incoming': True, 'needed': 288,
                                                          'available': 0}
    assert by('replacement-opens-clip')['expected']['leftSeam']['kind'] == 'gap'
    assert by('passage-outside-clip-still-refused')['expected']['error'] == 'seamFadeCrossesCut'
    assert by('absorbed-word-past-clip-end-still-refused')['expected']['error'] == 'seamFadeCrossesCut'

    # The fuzz: takes of touching or nearly touching words with a clip that starts or ends mid-take, some cut words inside
    # and outside it, and passages at the clip's edges. Every placement is refused with a typed error or renders in its
    # clip and in the full take.
    rng = reference['Lcg'](FUZZ_SEED)
    fuzz = {'seed': FUZZ_SEED, 'takes': FUZZ_TAKES, 'sampleStride': FUZZ_STRIDE, 'placements': 0, 'accepted': 0,
            'opening': 0, 'closing': 0, 'refused': {code: 0 for code in REFUSALS}, 'renderFailures': 0}
    sampled = []
    for index in range(FUZZ_TAKES):
        rate = rng.pick([48000, 44100])
        count = rng.between(4, 9)
        items, time = [], 0.05 * rng.between(0, 20)
        for number in range(count):
            gap = rng.pick([0, 0, 0, 0, 0.001 * rng.between(1, 140), 0.001 * rng.between(140, 700)])
            time += gap if number else 0
            length = 0.001 * rng.between(60, 450)
            items.append(word('w%d' % number, time, time + length))
            time += length
        lo = rng.between(0, count - 2)
        hi = rng.between(lo, count - 1)
        cut = sorted({items[rng.below(count)]['id'] for _ in range(rng.below(3))})
        kept = [item['id'] for item in items[lo:hi + 1] if item['id'] not in cut]
        if not kept:
            continue
        passage = rng.pick([(kept[0], kept[0]), (kept[-1], kept[-1]), (kept[0], kept[-1]), (rng.pick(kept),) * 2])
        duration = time + 0.8
        levels = envelope_levels(items, rate, samples(duration, rate) // frame_size(rate))
        envelope = {'sampleRate': rate, 'levels': levels}
        edits = {'cutWordIds': cut, 'cutPauseIds': [], 'pauseThresholdSeconds': 0.8, 'pauseKeepSeconds': 0.15,
                 'clips': [{'id': 'c1', 'startWordId': items[lo]['id'], 'endWordId': items[hi]['id']}]}
        project = {'sampleRate': float(rate), 'durationSeconds': duration, 'words': items, 'edits': edits, 'segments': []}
        expected = run_case(place, project, 'c1', envelope, *passage)
        fuzz['placements'] += 1
        case = {'name': 'fuzz-%04d' % index, 'input': take_input(rate, duration, items, edits, 'c1', envelope)}
        case['input'].update(firstWordId=passage[0], lastWordId=passage[1])
        case['expected'] = expected
        case['roomTone'] = passage_room_tone(expected, items, envelope, rate, duration)
        if 'error' in expected:
            assert expected['error'] in REFUSALS, (index, expected)
            fuzz['refused'][expected['error']] += 1
            case['clipOutputEdges'] = None
        else:
            fuzz['accepted'] += 1
            stored = stored_window(expected, project['sampleRate'])
            failures = [render_failure(project, scope, window) for window in (expected, stored) for scope in ('c1', None)]
            fuzz['renderFailures'] += sum(failure is not None for failure in failures)
            assert failures == [None] * 4, (index, failures)
            assert case['roomTone'] is not None, index
            edges = clip_output_edges(project, 'c1', expected)
            fuzz['opening'] += True in edges
            fuzz['closing'] += False in edges
            case['clipOutputEdges'] = {'incoming': True in edges, 'outgoing': False in edges}
        if index % FUZZ_STRIDE == 0:
            sampled.append(case)
    assert fuzz['opening'] > 0 and fuzz['closing'] > 0
    fuzz['refused'] = {code: count for code, count in fuzz['refused'].items() if count}
    document = {'schema': SCHEMA, 'caseCount': len(cases) + len(sampled), 'cases': cases + sampled, 'fuzz': fuzz}
    print('clip edges: %d named cases, fuzz seed %d: %d placements, %d accepted (%d opening, %d closing the clip), refused %s, '
          '%d sampled' % (len(cases), FUZZ_SEED, fuzz['placements'], fuzz['accepted'], fuzz['opening'], fuzz['closing'],
                          fuzz['refused'], len(sampled)))
    return document


if __name__ == '__main__':
    document = generate(definitions())
    cases, document['cases'] = document['cases'], '@@cases@@'
    # One case per line keeps the file reviewable.
    text = json.dumps(document, indent=2).replace('"@@cases@@"', '[\n' + ',\n'.join('    ' + json.dumps(case) for case in cases) + '\n  ]')
    OUT.write_text(text + '\n', encoding='utf-8')
