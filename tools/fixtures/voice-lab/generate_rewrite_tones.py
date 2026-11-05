#!/usr/bin/env python3
"""Write and check shared/data/rewrite-tones.json, the Rewrite tone presets (doc/design.md section 6.3.1).

The tones are the chips under Rewrite's field ("✦ Viral YouTuber", "Punchy Reel", ...), the clip style card's Tone menu
(section 6.6) and the planner's tone input (doc/spec/ai.md section 16). Each tone's `instruction` is the exact text Rewrite
sends as the user instruction (`PatchRewriteRequest.instruction`, at most 1,000 UTF-8 bytes) and the planner applies to
its rewrites. This file is the source of truth: edit the tones here, run it, and commit both. `check()` holds every rule
both apps rely on; CI runs this generator and fails on drift (tools/fixtures/voice-lab/check_drift.py lists the output as
byte-exact). Run from anywhere: python3 tools/fixtures/voice-lab/generate_rewrite_tones.py [--check]
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / 'shared/data/rewrite-tones.json'

LIMITS = {
    'maxTitleScalars': 32,
    'maxDescriptorScalars': 40,
    'maxInstructionBytes': 1000,
    'maxMyTones': 20,
}
SLUG = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')
# Ids the card and settings reserve: Auto, As I said it, and the user's saved tones ("my-…").
RESERVED = {'auto', 'as-said'}
MY_PREFIX = 'my-'

# Every instruction ends with these, so a tone never changes what the speaker said and the cloned voice can say every line.
KEEP = ('Keep my facts, names, numbers and meaning, and keep my voice. Every line must be speakable as is: '
        'no emoji, hashtags, links or stage directions.')
# The video keeps running under the new words (ai.md §12.9), so no tone may make a phrase longer than what it replaces.
FIT = ('Each rewritten phrase must take no longer to say than the words it replaces, because the video keeps running '
       'under it. Shorter is fine; never pad with filler words or connectors.')
FIT_SHORTER = ('Make it tighter by cutting rather than adding: each rewritten phrase is as long as the words it replaces '
               'or shorter, never longer, because the video keeps running under it. Never pad with filler words or '
               'connectors.')

# (id, title, descriptor, shortens, featured, body). The body is written as an editor and copywriter would brief it.
TONES = [
    ('viral-youtuber', 'Viral YouTuber', 'hook, punchy, payoff', True, True,
     'Rewrite it the way a top YouTuber would say it. Put a hook in the first sentence that makes a stranger stop '
     'scrolling, by rewording my opening rather than adding a line before it. Then short, punchy sentences, one thought '
     'each. Where attention would dip, make a pattern interrupt by turning a line into a sharp question or a quick turn. '
     'Build to one clear payoff and land it. Energetic but natural, like me on my best take, never hype for its own sake.'),
    ('punchy-reel', 'Punchy Reel', '≤ 30 s, fast cuts', True, False,
     'Make it a fast Reel that runs under 30 seconds. Start on the most surprising line, cut every word that does not earn '
     'its place, and keep one idea per sentence. Short, rhythmic lines that build to a quick, memorable ending.'),
    ('storyteller', 'Storyteller', 'setup, tension, payoff', False, False,
     'Tell it as a story. A quick setup that puts the listener in the moment, then the problem or tension, then the turn '
     'and the payoff. Use the concrete details I already gave, in plain spoken words. Warm and vivid, never dramatic for '
     'its own sake.'),
    ('clear-explainer', 'Clear explainer', 'step by step', False, False,
     'Make it easy to follow. Say the point first, then explain it step by step in plain words, one idea per sentence. '
     'Swap jargon for everyday words unless the term matters, and end with what it means for the listener.'),
    ('linkedin-pro', 'LinkedIn pro', 'calm, credible', False, False,
     'Make it sound like a credible professional on LinkedIn. Open with the insight, back it with what I actually did or '
     'saw, and end with a takeaway people can use. Calm, confident and specific. No buzzwords, humblebrag or clickbait.'),
    ('funny', 'Funny', 'light, one joke', False, False,
     'Make it light and funny. Keep my point, and turn one line into a well-placed joke or witty turn of phrase that '
     'grows out of what I said, ideally near the end. Playful and warm, never mean, sarcastic or forced.'),
    ('hype-launch', 'Hype launch', 'big news, clear ask', False, False,
     'Make it a launch announcement. Lead with the news, say who it is for and why it matters now, and end with one clear '
     'call to action. Excited and confident, with real energy, but every claim stays exactly as true as what I said.'),
    ('calm-sincere', 'Calm & sincere', 'honest, unhurried', True, False,
     'Make it calm and sincere. Unhurried sentences, honest and personal, as if I were speaking to one person I respect. '
     'Remove hype, filler and exaggeration, and let the point land quietly.'),
]

CHOICES = [
    {'id': 'auto', 'label': 'Auto', 'detail': 'Claude picks per clip'},
    {'id': 'as-said', 'label': 'As I said it', 'detail': 'no tone change'},
]


def instruction(body, shortens):
    return ' '.join([body, FIT_SHORTER if shortens else FIT, KEEP])


def document():
    return {
        'schema': 'voxclip-rewrite-tones/1',
        'schemaVersion': 1,
        'description': ('Rewrite tone presets (doc/design.md section 6.3.1): the chips under Rewrite\'s field, the clip '
                        'style card\'s Tone menu (section 6.6) and the clip planner\'s tone (doc/spec/ai.md section 16). '
                        '`instruction` is the exact text Rewrite sends and the planner applies. `choices` are the card\'s '
                        'two non-tone entries. A user\'s saved tone (settings `rewrite.myTones`) has an id starting with '
                        '"my-". Generated by tools/fixtures/voice-lab/generate_rewrite_tones.py; do not edit by hand.'),
        'limits': LIMITS,
        'myTonePrefix': MY_PREFIX,
        'choices': CHOICES,
        'tones': [{'id': id, 'title': title, 'descriptor': descriptor, 'shortens': shortens, 'featured': featured,
                   'instruction': instruction(body, shortens)}
                  for id, title, descriptor, shortens, featured, body in TONES],
    }


def speakable(text):
    """No emoji or pictographs, hashtags, links, bracket tags or line breaks: the cloned voice must say every line."""
    if re.search(r'[#\[\]{}<>\n\r\t]|https?://|www\.', text):
        return False
    for char in text:
        category = unicodedata.category(char)
        if ord(char) > 0xFFFF or category in ('So', 'Cs', 'Co', 'Cn') or category.startswith('C'):
            return False
    return True


def check(doc):
    """Every rule both apps rely on; returns a list of problems (empty when valid)."""
    problems = []
    limits = doc.get('limits', {})
    if doc.get('schema') != 'voxclip-rewrite-tones/1' or doc.get('schemaVersion') != 1:
        problems.append('schema')
    if doc.get('myTonePrefix') != MY_PREFIX:
        problems.append('myTonePrefix')
    if [choice.get('id') for choice in doc.get('choices', [])] != ['auto', 'as-said']:
        problems.append('choices')
    tones = doc.get('tones', [])
    if not 4 <= len(tones) <= 12:
        problems.append('tone count')
    seen = set()
    featured = 0
    for index, tone in enumerate(tones):
        where = f'tones[{index}]'
        id = tone.get('id', '')
        if not SLUG.match(id) or id in RESERVED or id.startswith(MY_PREFIX) or id in seen:
            problems.append(f'{where}.id')
        seen.add(id)
        title, descriptor, text = tone.get('title', ''), tone.get('descriptor', ''), tone.get('instruction', '')
        if not 1 <= len(title) <= limits.get('maxTitleScalars', 0) or title != title.strip():
            problems.append(f'{where}.title')
        if not 1 <= len(descriptor) <= limits.get('maxDescriptorScalars', 0):
            problems.append(f'{where}.descriptor')
        if not 1 <= len(text.encode('utf-8')) <= limits.get('maxInstructionBytes', 0) or text != text.strip():
            problems.append(f'{where}.instruction length')
        if not speakable(text) or not speakable(title):
            problems.append(f'{where}.instruction speakable')
        if not text.endswith(KEEP):
            problems.append(f'{where}.instruction keeps facts')
        if (FIT_SHORTER if tone.get('shortens') else FIT) not in text:
            problems.append(f'{where}.instruction fit')
        if not isinstance(tone.get('shortens'), bool) or not isinstance(tone.get('featured'), bool):
            problems.append(f'{where}.flags')
        featured += tone.get('featured') is True
    if featured != 1 or not tones or tones[0].get('featured') is not True:
        problems.append('exactly one featured tone, first')
    return problems


def main():
    doc = document()
    problems = check(doc)
    if problems:
        raise SystemExit('rewrite-tones.json is invalid: ' + ', '.join(problems))
    text = json.dumps(doc, indent=1, ensure_ascii=False) + '\n'
    if '--check' in sys.argv[1:]:
        current = OUTPUT.read_text() if OUTPUT.exists() else ''
        if current != text:
            raise SystemExit(f'{OUTPUT.relative_to(ROOT)} drifted; run this generator')
        problems = check(json.loads(current))
        if problems:
            raise SystemExit('rewrite-tones.json is invalid: ' + ', '.join(problems))
        return
    OUTPUT.write_text(text)


if __name__ == '__main__':
    main()
