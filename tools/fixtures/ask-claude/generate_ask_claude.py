#!/usr/bin/env python3
"""Generate the Ask Claude vectors (doc/spec/ai.md section 18): shared/fixtures/ask-claude/ask-claude-cases.json.

Format voxclip-ask-claude/1. A synthetic v4 project (the "invoice" recording of the approved mockup), request cases whose
expected instruction this script renders independently from shared/prompts/ask-claude.json, and stub-reply cases with
hand-derived expected operations and repair counts. The Swift AskClaudeTests replay every case; no Windows twin yet (the
Ask Claude request and validator are Mac Core only, ai.md section 18.7). Deterministic; run from anywhere.
"""
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/ask-claude'
PROMPT = ROOT / 'shared/prompts/ask-claude.json'

TEXT = ('So here is the invoice for March. The total is four thousand two hundred dollars, '
        'and honestly that damn number scared me. We ship today.').split(' ')


def project():
    base = json.loads((ROOT / 'shared/fixtures/context-demo/v4-project.voxclip').read_text())
    base.pop('contextDemo')
    base.pop('motionCues')
    base['title'] = 'Synthetic Ask Claude fixture'
    words, time = [], 0.5
    for index, text in enumerate(TEXT):
        length = round(0.2 + 0.03 * len(text), 2)
        words.append({'id': f'w{index + 1}', 'text': text, 'kind': 'word', 'start': round(time, 2), 'end': round(time + length, 2),
                      'rawStart': round(time, 2), 'rawEnd': round(time + length, 2), 'conf': 0.95, 'speaker': None, 'timing': 'native'})
        time += length + (0.5 if text.endswith('.') else 0.1)
    template = base['transcript']['words'][0]
    base['transcript']['words'] = [{**{key: template[key] for key in template}, **word} for word in words]
    base['transcript']['durationSeconds'] = round(time + 0.5, 2)
    base['media']['source']['durationSeconds'] = round(time + 0.5, 2)
    base['edits']['clips'] = [{'id': 'clip-main', 'startWordId': 'w1', 'endWordId': f'w{len(words)}', 'title': 'Invoice day',
                               'origin': 'manual', 'aiResultId': None, 'aiClipIndex': None, 'selected': True}]
    base['edits']['cutWordIds'] = []
    base['edits']['corrections'] = {}
    base['edits']['cutPauseIds'] = []
    return base


def number(value):
    return f'{value:.2f}'


def fill(template, values):
    for key, value in values.items():
        template = template.replace('{' + key + '}', value)
    return template


def instruction(prompt, doc, case):
    request = prompt['request']
    words = doc['transcript']['words']
    first, last = case['selection']['words']
    start, end = words[first]['start'], words[last]['end']
    selection = fill(request['selectionWords'], {'first': str(first), 'last': str(last), 'start': number(start), 'end': number(end)})
    lines = '\n'.join(fill(request['wordLine'], {'index': str(i), 'start': number(words[i]['start']), 'end': number(words[i]['end']),
                                                  'text': words[i]['text']}) for i in range(first, last + 1))
    context = prompt['limits']['contextWords']
    before = ' '.join(word['text'] for word in words[max(0, first - context):first]) or request['noContext']
    after = ' '.join(word['text'] for word in words[last + 1:last + 1 + context]) or request['noContext']
    clip = fill(request['clipLine'], {'title': 'Invoice day', 'start': number(words[0]['start']), 'end': number(words[-1]['end'])})
    frame = fill(request['frameLine'], {'width': '1920', 'height': '1080', 'aspect': case['aspect']})
    detections = []
    for item in case['detections']:
        reads = fill(request['detectionText'], {'text': item['text']}) if item.get('text') else ''
        detections.append(fill(request['detectionLine'], {'label': item['label'], 'kind': item['kind'], 'start': number(item['start']),
                                                           'end': number(item['end']), 'x': number(item['x']), 'y': number(item['y']),
                                                           'width': number(item['width']), 'height': number(item['height']), 'text': reads}))
    tools = '\n'.join(fill(request['toolLine'], tool) for tool in prompt['toolbox'])
    return fill(request['instruction'], {'instruction': case['instruction'], 'selection': selection, 'words': lines, 'before': before,
                                         'after': after, 'clip': clip, 'frame': frame, 'current': request['nothingCurrent'],
                                         'detections': '\n'.join(detections) if detections else request['noDetections'], 'toolbox': tools})


def op(kind, **fields):
    value = {'kind': kind, 'startWord': -1, 'endWord': -1, 'start': -1, 'end': -1, 'text': '', 'target': '', 'x': 0, 'y': 0, 'width': 0,
             'height': 0, 'tracking': '', 'position': '', 'rate': 0, 'scale': 0, 'sound': '', 'language': '', 'choice': '', 'reason': f'{kind} reason'}
    value.update(fields)
    return value


def generated():
    prompt = json.loads(PROMPT.read_text())
    doc = project()
    words = doc['transcript']['words']
    invoice = {'label': 'D1', 'kind': 'text', 'start': words[3]['start'], 'end': words[17]['end'], 'x': 0.55, 'y': 0.3, 'width': 0.3,
               'height': 0.2, 'text': 'INVOICE #1042 $4,200'}
    face = {'label': 'D2', 'kind': 'face', 'start': words[0]['start'], 'end': words[-1]['end'], 'x': 0.12, 'y': 0.18, 'width': 0.18, 'height': 0.3}
    face_right = {'label': 'D3', 'kind': 'face', 'start': words[0]['start'], 'end': words[-1]['end'], 'x': 0.7, 'y': 0.2, 'width': 0.1, 'height': 0.16}
    amount = (10, 14)  # "four thousand two hundred dollars,"
    request = {'id': 'mockup-request', 'instruction': 'blur the invoice on screen and bleep the amount', 'selection': {'words': [3, 17]},
               'clipID': 'clip-main', 'aspect': '9:16', 'detections': [invoice, face]}
    request['expectedInstruction'] = instruction(prompt, doc, request)
    sel = words[3]['start'], words[17]['end']
    replies = [
        {'id': 'mockup-blur-and-bleep', 'selection': {'words': [3, 17]}, 'clipID': 'clip-main', 'detections': [invoice, face],
         'reply': {'summary': 'Blurred the invoice and bleeped the amount.',
                   'ops': [op('blur', target='D1', tracking='none', start=sel[0], end=sel[1]), op('bleep', startWord=amount[0], endWord=amount[1])]},
         'expect': [{'decision': 'blur', 'kind': 'blur', 'start': sel[0], 'end': sel[1], 'rect': [0.55, 0.3, 0.3, 0.2], 'tracking': 'none'},
                    {'decision': 'bleep', 'kind': 'bleep', 'start': words[amount[0]]['start'], 'end': words[amount[1]]['end'],
                     'wordIds': [f'w{i + 1}' for i in range(amount[0], amount[1] + 1)]}],
         'repairs': 0},
        {'id': 'ambiguous-face-is-pre-picked', 'selection': {'words': [0, 8]}, 'clipID': 'clip-main', 'detections': [face, face_right],
         'reply': {'summary': 'Blurred a face.', 'ops': [op('blur', choice='')]},
         'expect': [{'decision': 'blur', 'kind': 'blur', 'start': words[0]['start'], 'end': words[8]['end'], 'rect': [0.12, 0.18, 0.18, 0.3],
                     'tracking': 'face', 'choice': 'the face at the left'}],
         'repairs': 0},
        {'id': 'overlays-clamped-to-the-selection', 'selection': {'words': [0, 8]}, 'clipID': 'clip-main', 'detections': [],
         'reply': {'summary': 'Added a title, an emoji and a progress bar.',
                   'ops': [op('title', text='  Day 1 ', start=0, end=99, position='middle'),
                           op('sticker', text='\U0001F525', scale=9, position='topLeft'),
                           op('sticker', text='fire'),
                           op('progress', position='center'),
                           op('lowerThird', text='')]},
         'expect': [{'decision': 'overlay', 'kind': 'title', 'start': words[0]['start'], 'end': words[8]['end'], 'text': 'Day 1', 'position': 'top'},
                    {'decision': 'overlay', 'kind': 'sticker', 'start': words[0]['start'], 'end': words[8]['end'], 'text': '\U0001F525',
                     'position': 'topLeft', 'scale': 3},
                    {'decision': 'overlay', 'kind': 'progress', 'start': words[0]['start'], 'end': words[8]['end'], 'position': 'bottom'}],
         'repairs': 2},
        {'id': 'timing-sound-and-words', 'selection': {'words': [9, 20]}, 'clipID': 'clip-main', 'detections': [],
         'reply': {'summary': 'Slowed the number, froze, zoomed, added a pop, fixed a word and cut one.',
                   'ops': [op('speed', startWord=9, endWord=13, rate=0.5), op('speed', rate=1), op('freeze', start=words[14]['start']),
                           op('zoom', startWord=17, endWord=20, scale=5), op('sound', start=words[9]['start'], sound='click'),
                           op('correction', startWord=18, text='darn'), op('jumpCut', startWord=17, endWord=17),
                           op('rewrite', startWord=17, endWord=20, text='that number really scared me.'),
                           op('translate', startWord=9, endWord=13, language='ES', text='cuatro mil doscientos dólares,'),
                           op('duck'), op('explode')]},
         'expect': [{'decision': 'stretch', 'kind': 'stretch', 'start': words[9]['start'], 'end': words[13]['end'], 'rate': 0.5},
                    {'decision': 'freeze', 'kind': 'freeze', 'start': words[14]['start'], 'end': round(words[14]['start'] + 1, 6)},
                    {'decision': 'zoom', 'kind': 'zoom', 'start': words[17]['start'], 'end': words[20]['end'], 'scale': 1.35},
                    {'decision': 'sound', 'kind': 'sound', 'start': words[9]['start'], 'end': round(words[9]['start'] + 0.12, 6), 'sound': 'pop',
                     'choice': 'a pop'},
                    {'decision': 'correction', 'kind': 'correction', 'wordIds': ['w19'], 'text': 'darn'},
                    {'decision': 'cut', 'kind': 'jumpCut', 'wordIds': ['w18']},
                    {'decision': 'rewrite', 'kind': 'rewrite', 'wordRange': [17, 20], 'text': 'that number really scared me.', 'paid': True},
                    {'decision': 'translate', 'kind': 'translate', 'wordRange': [9, 13], 'language': 'es', 'text': 'cuatro mil doscientos dólares,',
                     # Applied as the clip's translated captions (project captionTranslations, ai.md section 18.2).
                     'translation': {'id': 'tr-1', 'clipId': 'clip-main', 'startWordId': 'w10', 'endWordId': 'w14', 'language': 'es',
                                     'text': 'cuatro mil doscientos dólares,'}}],
         'repairs': 3},
        # Word ranges reaching past the selection are clamped to it; one wholly outside it is left out.
        {'id': 'censor-words-clamped-to-the-selection', 'selection': {'words': [3, 17]}, 'clipID': 'clip-main', 'detections': [],
         'reply': {'summary': 'Bleeped and muted the words.',
                   'ops': [op('bleep', startWord=0, endWord=12), op('mute', startWord=15, endWord=40), op('bleep', startWord=20, endWord=22)]},
         'expect': [{'decision': 'bleep', 'kind': 'bleep', 'start': words[3]['start'], 'end': words[12]['end'],
                     'wordIds': [f'w{i + 1}' for i in range(3, 13)]},
                    {'decision': 'bleep', 'kind': 'mute', 'start': words[15]['start'], 'end': words[17]['end'],
                     'wordIds': [f'w{i + 1}' for i in range(15, 18)]}],
         'repairs': 1},
    ]
    prompt_sha = hashlib.sha256(PROMPT.read_bytes()).hexdigest()
    return {'format': 'voxclip-ask-claude/1', 'promptSha256': prompt_sha, 'project': doc, 'requests': [request], 'replies': replies}


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    (DESTINATION / 'ask-claude-cases.json').write_text(json.dumps(generated(), indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
