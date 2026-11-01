#!/usr/bin/env python3
"""Write exact several-window vectors, loading only the single-window reference's definitions."""
import ast
import json
from copy import deepcopy
from decimal import getcontext
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[2] / 'shared/fixtures/voice-lab/window-all-cases.json'


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
    place = reference['place']
    failure = reference['GeometryError']
    split = reference['split_white_space']

    def touches(left, right):
        return (left['start'] <= right['end'] and right['start'] <= left['end']
                or left['startSample'] <= right['endSample'] and right['startSample'] <= left['endSample'])

    def all_windows(project, scope, envelope, hunks):
        project = deepcopy(project)
        project['edits']['cutWordIds'] += [id_ for hunk in hunks if hunk['kind'] == 'cut' for id_ in hunk['sourceWordIds']]
        words = project['words']
        positions = {word['id']: index for index, word in enumerate(words)}
        key = lambda index: (positions.get(next(iter(hunks[index]['sourceWordIds']), None), 2**53), index)
        order = sorted((index for index, hunk in enumerate(hunks) if hunk['kind'] == 'voice'), key=key)
        accepted, refused = [], []
        corrections = project['edits'].get('corrections', {}).copy()
        for hunk in hunks:
            if hunk['kind'] == 'textOnly':
                corrections.update(zip(hunk['sourceWordIds'], hunk['correctedTexts']))

        def bridge_tokens(ids):
            return [token for id_ in ids for token in split(corrections.get(id_, words[positions[id_]]['text']))]

        def token_count(result):
            window, hunk = result['window'], result['hunk']
            return len(hunk['newTokens']) + len(bridge_tokens(window['leftBridgeWordIds'] + window['rightBridgeWordIds']))

        for offset, index in enumerate(order):
            working = deepcopy(accepted)
            current, indices, collision = deepcopy(hunks[index]), [index], None
            try:
                while True:
                    ids = current['sourceWordIds']
                    if not ids:
                        raise failure('insertionUnsupported')
                    window = place(project, scope, envelope, ids[0], ids[-1])
                    hit = next((at for at, result in enumerate(working) if touches(result['window'], window)), None)
                    if hit is None:
                        reserved = deepcopy(project)
                        names = {}
                        for at, result in enumerate(working):
                            name = 'voice-lab-review-%d' % at
                            while any(segment['id'] == name for segment in reserved['segments']):
                                name += '-'
                            names[name] = at
                            reserved['segments'].append({'id': name, 'enabled': True, 'window': result['window']})
                        try:
                            window = place(reserved, scope, envelope, ids[0], ids[-1])
                            hit = next((at for at, result in enumerate(working) if touches(result['window'], window)), None)
                        except failure as error:
                            if error.value.get('segmentId') not in names:
                                raise
                            hit = names[error.value['segmentId']]
                    if hit is not None:
                        earlier = working[hit]
                        if collision is None:
                            collision = earlier['indices'][0]
                        left, right = positions[earlier['hunk']['sourceWordIds'][-1]], positions[current['sourceWordIds'][0]]
                        if left >= right:
                            raise failure('invalidInput')
                        between = words[left + 1:right]
                        cuts = set(project['edits']['cutWordIds']) | {id_ for hunk in hunks if hunk['kind'] == 'cut'
                                                                    for id_ in hunk['sourceWordIds']}
                        if any(word['kind'] != 'word' or word['id'] in cuts for word in between):
                            raise failure('invalidInput')
                        bridges = [word['id'] for word in between]
                        prior = earlier['hunk']
                        current = {**prior, 'sourceWordIds': prior['sourceWordIds'] + bridges + current['sourceWordIds'],
                                   'newTokens': prior['newTokens'] + bridge_tokens(bridges) + current['newTokens'],
                                   'absorbedItemIds': prior['absorbedItemIds'] + current['absorbedItemIds'],
                                   'bridgeWordIds': prior['bridgeWordIds'] + bridges + current['bridgeWordIds'],
                                   'sourceEndIndex': current['sourceEndIndex'], 'anchorSeconds': None}
                        absorbed = [at for at, hunk in enumerate(hunks) if hunk['kind'] == 'textOnly'
                                    and hunk['sourceWordIds'] and set(hunk['sourceWordIds']) <= set(current['sourceWordIds'])]
                        indices = sorted(set(indices + earlier['indices'] + absorbed), key=key)
                        working.pop(hit)
                        continue
                    result = {'status': 'placed', 'indices': indices, 'hunk': current, 'window': window}
                    if collision is not None:
                        count = sum(token_count(item) for item in working + [result])
                        count += sum(len(hunks[at]['newTokens']) for at in order[offset + 1:])
                        denominator = sum(word['kind'] == 'word' for word in words)
                        if count * 100 > 15 * denominator or count > 60:
                            raise failure('invalidInput')
                    working.append(result)
                    accepted = sorted(working, key=lambda item: item['window']['startSample'])
                    break
            except failure as error:
                reason = error.value if collision is None else {'error': 'collidesWithChange', 'index': collision}
                refused.append({'status': 'refused', 'indices': [index], 'hunk': hunks[index], 'reason': reason})
        return sorted(accepted + refused, key=lambda item: key(item['indices'][0]))

    def make_hunk(items, first, last=None, count=1, kind='voice', text=None):
        last = first if last is None else last
        return {'kind': kind, 'sourceWordIds': [word['id'] for word in items[first:last + 1]],
                'newTokens': [text or 'new%d' % first] * count, 'correctedTexts': [text] if kind == 'textOnly' else [],
                'absorbedItemIds': [], 'bridgeWordIds': [], 'sourceStartIndex': first, 'sourceEndIndex': last + 1,
                'anchorSeconds': None}

    def case(name, indices, total=100, counts=None, timing=None, rate=48000, **options):
        items = [reference['word']('w%d' % index, 0.2 + index * 0.5, 0.45 + index * 0.5) for index in range(total)]
        if timing:
            for index, (start, end) in enumerate(timing):
                items[index].update(start=start, end=end)
        duration = items[-1]['end'] + 0.5
        result = reference['window_case'](name, items, duration, first=items[indices[0]]['id'], last=items[indices[0]]['id'],
                                          rate=rate, **options)
        result.pop('expected')
        result.pop('lendableSilence', None)
        result['input']['hunks'] = [make_hunk(items, index, count=(counts or {}).get(index, 1)) for index in indices]
        return result

    cases = [case('all-two-windows', [2, 12]), case('all-three-windows-source-order', [22, 2, 12]),
             case('all-touch-merges-within-budget', [2, 3]), case('all-three-touch-transitive', [2, 3, 4]),
             case('all-merge-over-15-percent', [2, 3], total=20, counts={2: 2, 3: 2}),
             case('all-merge-at-15-percent', [2, 3], total=20, counts={2: 1, 3: 2}),
             case('all-merge-at-60-tokens', [2, 3], total=400, counts={2: 30, 3: 30}),
             case('all-merge-over-60-tokens', [2, 3], total=500, counts={2: 30, 3: 31}),
             case('all-budget-counts-the-whole-review', [2, 3, 20], total=100, counts={2: 7, 3: 7, 20: 2}),
             case('all-refusal-keeps-original-input-index', [12, 3, 2], total=20, counts={2: 2, 3: 2}),
             case('all-existing-replacement-refused', [2, 20], replacements=[('w20', 'w20', True, None)]),
             case('all-beside-existing-replacement', [2, 19], replacements=[('w20', 'w20', True, None)]),
             case('all-44100-binary64', [2, 3, 12], rate=44100),
             case('all-odd-rate-binary64', [2, 3, 12], rate=11025)]
    timing = [(0.2, 0.5), (0.7, 0.9), (0.95, 1.05), (1.1, 1.4), (1.45, 1.8), (1.85, 1.95), (2.0, 2.4), (2.6, 3.0)]
    cases += [case('all-overlap-after-seam-widening', [2, 4], timing=timing),
              case('all-bridges-cross-budget', [2, 4], total=20, timing=timing),
              case('all-merge-over-budget-keeps-earlier', [2, 4, 12], total=40, timing=timing, counts={4: 6}),
              case('all-three-widened-transitive', [6, 2, 4], timing=timing),
              case('all-cut-word-refuses-seam-before-merge', [2, 4], timing=timing, cut=['w3'])]
    correction = case('all-corrected-bridges-and-text-only', [2, 4], timing=timing)
    correction['input']['edits']['corrections'] = {'w1': 'corrected words'}
    correction['input']['hunks'].insert(1, make_hunk(correction['input']['words'], 3, kind='textOnly', text='W3!'))
    cases.append(correction)
    project_correction = case('all-project-correction-in-bridge', [2, 4], timing=timing)
    project_correction['input']['edits']['corrections'] = {'w3': 'corrected words'}
    cases.append(project_correction)
    dense = [(0.0, 0.3), (0.301, 0.6), (0.601, 0.9), (0.901, 0.902),
             (0.903, 1.2), (1.201, 1.5), (1.501, 1.8), (1.801, 2.1)]
    cases.append(case('all-fades-collide-without-touching', [2, 4], timing=dense))
    cases.append(case('all-hard-seams-binary64', [2, 4], timing=dense, rate=11025))
    real_id = case('all-real-review-like-id-overlap', [2, 20], replacements=[('w20', 'w20', True, None)])
    real_id['input']['segments'][0]['id'] = 'voice-lab-review-0'
    cases.append(real_id)
    for name, kind in [('all-event-prevents-merge', 'event'), ('all-unlabeled-prevents-merge', 'unlabeledSpeech')]:
        blocked = case(name, [2, 4], timing=dense)
        blocked['input']['words'][3]['kind'] = kind
        cases.append(blocked)
    cut_hunk = case('all-cut-hunk-refuses-seam-before-merge', [2, 4], timing=timing)
    cut_hunk['input']['hunks'].insert(1, make_hunk(cut_hunk['input']['words'], 3, kind='cut', count=0))
    cases.append(cut_hunk)
    review_timing = [(0.2, 0.5), (0.7, 0.9), (0.95, 1.05), (1.1, 1.4),
                     (1.45, 1.8), (2.2, 2.4), (2.45, 2.6), (2.65, 3.0)]
    for name, indices in [('all-review-cut-in-seam-search', [2]), ('all-review-cut-before-later-voice', [2, 6])]:
        review_cut = case(name, indices, timing=review_timing)
        review_cut['input']['hunks'].insert(1, make_hunk(review_cut['input']['words'], 4, kind='cut', count=0))
        cases.append(review_cut)
    insertion = case('all-insertion-stays-unsupported', [2])
    insertion['input']['hunks'][0].update(sourceWordIds=[], sourceEndIndex=2, anchorSeconds=1.2)
    cases.append(insertion)
    invalid = case('all-invalid-envelope', [2, 12])
    invalid['input']['envelope']['sampleRate'] = 44100
    cases.append(invalid)
    cases.append(case('all-clip-scope', [2, 3, 12], clips=[('clip', 'w1', 'w15')], clip='clip'))
    for result in cases:
        raw = result['input']
        token_positions = {}
        token_count = 0
        for word in raw['words']:
            start = token_count
            if word['kind'] == 'word':
                token_count += len(split(raw['edits'].get('corrections', {}).get(word['id'], word['text'])))
            token_positions[word['id']] = (start, token_count)
        for hunk in raw['hunks']:
            if hunk['sourceWordIds']:
                hunk['sourceStartIndex'] = token_positions[hunk['sourceWordIds'][0]][0]
                hunk['sourceEndIndex'] = token_positions[hunk['sourceWordIds'][-1]][1]
        project = {key: deepcopy(raw[key]) for key in ('sampleRate', 'durationSeconds', 'words', 'edits', 'segments')}
        envelope = {'sampleRate': raw['envelope']['sampleRate'],
                    'levels': [level for level, count in raw['envelope']['runs'] for _ in range(count)]}
        result['expected'] = all_windows(project, raw['clipId'], envelope, raw['hunks'])
        project['edits']['cutWordIds'] += [id_ for hunk in raw['hunks'] if hunk['kind'] == 'cut' for id_ in hunk['sourceWordIds']]
        for accepted in result['expected']:
            if accepted['status'] == 'placed':
                assert reference['render_failure'](project, raw['clipId'], accepted['window']) is None, result['name']
                project['segments'].append({'id': 'check-%d' % len(project['segments']), 'enabled': True, 'window': accepted['window']})
    named = {case['name']: case for case in cases}
    for name in ('all-touch-merges-within-budget', 'all-overlap-after-seam-widening', 'all-fades-collide-without-touching',
                 'all-project-correction-in-bridge', 'all-merge-at-15-percent', 'all-merge-at-60-tokens'):
        assert named[name]['expected'][0]['indices'] == [0, 1], name
    for name in ('all-merge-over-15-percent', 'all-merge-over-60-tokens', 'all-bridges-cross-budget',
                 'all-event-prevents-merge', 'all-unlabeled-prevents-merge'):
        assert len(named[name]['expected']) == 2, name
        assert named[name]['expected'][1]['reason']['error'] == 'collidesWithChange', name
    for name in ('all-review-cut-in-seam-search', 'all-review-cut-before-later-voice'):
        assert all(result['status'] == 'placed' and 'w4' not in result['window']['rightBridgeWordIds']
                   for result in named[name]['expected']), name
    return cases


if __name__ == '__main__':
    cases = generate(definitions())
    document = {'schema': 'voxclip-voice-lab-window-all-cases/1', 'caseCount': len(cases), 'cases': '@@cases@@'}
    text = json.dumps(document, indent=2).replace('"@@cases@@"', '[\n' + ',\n'.join('    ' + json.dumps(case) for case in cases) + '\n  ]')
    OUT.write_text(text + '\n', encoding='utf-8')
    print('placeAll: %d exact cases' % len(cases))
