#!/usr/bin/env python3
"""Generate shared/fixtures/voice-lab/homophone-word-check-cases.json (voice-lab.md §8.11).

The take word check counts a near-homophone of one of the user's own replacement words as that word: the same
letters-only Soundex key, at least three letters, at most two letters' difference in length, and only for a recognized
token that is not itself expected. This generator computes every expectation independently of both Cores: its own
Soundex, token normalization, replacement-word set and LCS ratio. Inputs are ASCII so the normalization is plain
lowercasing of letters and digits. Run from any directory."""
import json
from pathlib import Path

CODES = {**dict.fromkeys('bfpv', '1'), **dict.fromkeys('cgjkqsxz', '2'), **dict.fromkeys('dt', '3'),
         'l': '4', **dict.fromkeys('mn', '5'), 'r': '6'}


def sound_key(word):
    letters = word.lower()
    if len(letters) < 3 or any(not ('a' <= letter <= 'z') for letter in letters):
        return None
    key, last = letters[0].upper(), CODES.get(letters[0])
    for letter in letters[1:]:
        digit = CODES.get(letter)
        if digit is not None and digit != last:
            key += digit
        if letter not in 'hw':
            last = digit
        if len(key) == 4:
            break
    return key


def sounds_alike(word, heard):
    if word == heard or abs(len(word) - len(heard)) > 2:
        return False
    key = sound_key(word)
    return key is not None and sound_key(heard) == key


def tokens(text):
    normalized = (''.join(character for character in token.lower() if character.isalnum()) for token in text.split())
    return [token for token in normalized if token]


def normalize(recognized, expected, replacement):
    if not replacement:
        return list(recognized)
    expected_set = set(expected)
    candidates = sorted(word for word in replacement if word in expected_set)
    return [heard if heard in expected_set else next((word for word in candidates if sounds_alike(word, heard)), heard)
            for heard in recognized]


def ratio(expected, recognized):
    previous = [0] * (len(recognized) + 1)
    for token in expected:
        current = [0] * (len(recognized) + 1)
        for index, heard in enumerate(recognized):
            current[index + 1] = previous[index] + 1 if token == heard else max(previous[index + 1], current[index])
        previous = current
    return 2 * previous[-1] / (len(expected) + len(recognized))


def replacement_words(text, items, first, last):
    asked = set(tokens(text))
    ids = [item['id'] for item in items]
    if first not in ids or last not in ids or ids.index(first) > ids.index(last):
        return sorted(asked)
    recorded = {token for item in items[ids.index(first):ids.index(last) + 1] for token in tokens(item['text'])}
    return sorted(asked - recorded)


NINE = 'bring your own Claude Code subscription or Codex subscription'
HEARD_NINE = ['bring', 'your', 'own', 'cloud', 'code', 'subscription', 'or', 'codex', 'subscription']
CHECKS = [
    ('claude-code-nine-words', NINE, HEARD_NINE, ['claude']),
    ('claude-code-nine-words-without-replacement-words', NINE, HEARD_NINE, []),
    ('claude-code-eight-words', 'bring your own Claude Code subscription or Codex', HEARD_NINE[:8], ['claude']),
    ('short-phrase-made-exact', 'Claude Code', ['cloud', 'code'], ['claude']),
    ('different-sound-stays-wrong', NINE, ['crowd' if word == 'cloud' else word for word in HEARD_NINE], ['claude']),
    ('only-replacement-words-are-normalized', NINE, ['cortex' if word == 'codex' else word for word in HEARD_NINE], ['subscription']),
    ('expected-token-is-never-rewritten', 'the cloud runs Claude', ['the', 'cloud', 'runs', 'cloud'], ['claude']),
    ('length-difference-over-two', 'Claude Code', ['cld', 'code'], ['claude']),
    ('length-difference-of-two', 'Claude Code', ['clad', 'code'], ['claude']),
    ('replacement-word-not-asked', 'cloud code', ['clod', 'code'], ['claude']),
    ('first-sorted-candidate-wins', 'Claude and clod', ['cloud', 'and', 'clod'], ['clod', 'claude']),
    ('digits-never-sound-alike', 'T3 Code', ['tea', 'code'], ['t3']),
]

checks = []
for name, expected_text, recognized, replacement in CHECKS:
    expected = tokens(expected_text)
    normalized = normalize(recognized, expected, set(replacement))
    value = ratio(expected, normalized)
    exact = expected == normalized
    passed = exact if len(expected) <= 5 else value >= 0.9
    checks.append({'id': name, 'expected': expected_text, 'recognized': recognized, 'replacementWords': replacement,
                   'normalized': normalized, 'rawMatch': ratio(expected, recognized), 'transcriptMatch': value,
                   'exact': exact, 'passed': passed})

KEY_WORDS = ['claude', 'cloud', 'crowd', 'clod', 'ashcraft', 'pfister', 'tymczak', 'robert', 'rupert', 'honeyman',
             'codex', 'cortex', 'an', 't3', 'Claude', 'naive2']
sound_keys = [{'word': word, 'key': sound_key(word)} for word in KEY_WORDS]
PAIRS = [('claude', 'cloud'), ('claude', 'claude'), ('claude', 'clod2'), ('t3', 'tea'), ('an', 'in'), ('claude', 'cld'),
         ('claude', 'clad'), ('robert', 'rupert'), ('codex', 'cortex'), ('claude', 'crowd')]
alike = [{'word': word, 'heard': heard, 'expected': sounds_alike(word, heard)} for word, heard in PAIRS]

WINDOW_ITEMS = [{'id': 'a', 'text': 'So'}, {'id': 'b', 'text': 'cloud'}, {'id': 'c', 'text': 'code,'}, {'id': 'd', 'text': 'Claude'}]
REPLACEMENTS = [
    ('claude-code-over-cloud-code', 'Claude Code', WINDOW_ITEMS[1:3], 'b', 'c'),
    ('words-outside-the-window-do-not-count', 'Claude Code rocks', WINDOW_ITEMS, 'b', 'c'),
    ('window-not-found-keeps-every-word', 'Claude Code', WINDOW_ITEMS, 'b', 'z'),
    ('reversed-window-keeps-every-word', 'Claude Code', WINDOW_ITEMS, 'c', 'b'),
]
replacements = [{'id': name, 'text': text, 'items': items, 'firstWordId': first, 'lastWordId': last,
                 'expected': replacement_words(text, items, first, last)} for name, text, items, first, last in REPLACEMENTS]

document = {'schema': 'voxclip-homophone-word-check/1',
            'caseCount': len(sound_keys) + len(alike) + len(replacements) + len(checks),
            'soundKeys': sound_keys, 'soundsAlike': alike, 'replacementWords': replacements, 'checks': checks}
path = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/homophone-word-check-cases.json'
path.write_text(json.dumps(document, indent=2) + '\n')
