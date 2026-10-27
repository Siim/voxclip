#!/usr/bin/env python3
"""Write the shared Voice Lab text-length vectors (voice-lab §8.9.1).

The length of a text is its number of Unicode scalars of general category L* or Nd after NFC. Each case's expected
length is written out by hand and checked here against unicodedata, an oracle independent of both Cores. Non-ASCII
text is built with chr() so precomposed and decomposed forms stay explicit. Every assigned character is from Unicode
8.0 or older (U+1F3FD is the newest), and the noncharacters are permanently reserved, so categories and NFC forms are
the same in every current Unicode version. Running the generator twice gives identical bytes. See
shared/fixtures/voice-lab/rewrite-README.md.
"""
import json
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/text-length-cases.json'


def u(*values):
    return ''.join(chr(value) for value in values)


def length(text):
    return sum(1 for scalar in unicodedata.normalize('NFC', text)
               if unicodedata.category(scalar).startswith('L') or unicodedata.category(scalar) == 'Nd')


ARABIC_INDIC_2025 = u(0x662, 0x660, 0x662, 0x665)
DEVANAGARI_2025 = u(0x968, 0x966, 0x968, 0x96B)
JAMO = u(0x1112, 0x1161, 0x11AB, 0x1100, 0x116E, 0x11A8)  # the two syllables U+D55C U+AD6D, decomposed
WOMAN_TECHNOLOGIST = u(0x1F469, 0x200D, 0x1F4BB)

# (id, text, expected length, note)
CASES = [
    ('empty', '', 0, 'The empty string.'),
    ('whitespace-only', ' \t\n' + u(0xA0, 0x3000), 0, 'Spaces, controls and ideographic space are not letters.'),
    ('ascii-punctuation', 'Wait... what?! (Really.)', 14, 'Only the 14 letters count.'),
    ('apostrophe-and-hyphen', 'Don' + u(0x2019) + 't stop ' + u(0x2014) + ' it' + u(0x2019) + 's well-known.', 20,
     'Punctuation inside a word does not count.'),
    ('estonian-precomposed', u(0xF5, 0xE4, 0xF6, 0xFC, 0x161, 0x17E), 6,
     'Precomposed o-tilde, a, o and u with diaeresis, s and z with caron.'),
    ('estonian-precomposed-capitals', u(0xD5, 0xC4, 0xD6, 0xDC, 0x160, 0x17D), 6, 'The same letters as precomposed capitals.'),
    ('estonian-decomposed', 'o' + u(0x303) + 'a' + u(0x308) + 'o' + u(0x308) + 'u' + u(0x308) + 's' + u(0x30C) + 'z' + u(0x30C), 6,
     'Base letter plus combining mark; NFC composes each pair into one letter.'),
    ('estonian-sentence-mixed-forms', 'To' + u(0x303) + 'esti, ' + u(0xFC) + 'he o' + u(0x308) + 'o' + u(0x308) + ' j' + u(0xE4)
     + 'a' + u(0x308) + 'tis!', 17, 'A sentence mixing precomposed and decomposed letters.'),
    ('hangul-syllables', u(0xD55C, 0xAD6D, 0xC5B4), 3, 'Precomposed Hangul syllables are Lo.'),
    ('hangul-conjoining-jamo', JAMO, 2,
     'Six conjoining jamo (all Lo); NFC composes them into two syllables, so NFC changes this count.'),
    ('hangul-modern-leading-archaic-vowel', u(0x1100, 0x1176), 2, 'U+1176 is outside the modern vowel range.'),
    ('hangul-archaic-leading-modern-vowel', u(0x1113, 0x1161), 2, 'U+1113 is outside the modern leading range.'),
    ('hangul-both-archaic-with-trailing', u(0x1113, 0x1176, 0x11A8), 3, 'Neither archaic jamo composes.'),
    ('hangul-compatibility-jamo', u(0x314B, 0x314B, 0x314B), 3, 'Compatibility jamo do not compose; each is Lo.'),
    ('hangul-lv-syllable-and-trailing-jamo', u(0xAC00, 0x11A8), 1,
     'A precomposed LV syllable and a trailing consonant compose to U+AC01, one letter.'),
    ('hangul-lv-syllable-and-u11a7', u(0xAC00, 0x11A7), 2,
     'U+11A7 is no trailing consonant (those run from U+11A8 to U+11C2), so nothing composes: two letters.'),
    ('hangul-jamo-and-u11c3', u(0x1100, 0x1161, 0x11C3), 2,
     'The L and V jamo compose to U+AC00, but U+11C3 is no trailing consonant and stays: two letters.'),
    ('arabic-indic-digits', ARABIC_INDIC_2025, 4, 'Arabic-Indic digits are Nd.'),
    ('devanagari-digits', DEVANAGARI_2025, 4, 'Devanagari digits are Nd.'),
    ('mixed-script-digits', '2025 ' + ARABIC_INDIC_2025 + ' ' + DEVANAGARI_2025, 12, 'Digits from three scripts.'),
    ('fullwidth-digits', u(0xFF12, 0xFF10, 0xFF12, 0xFF15), 4, 'Fullwidth digits are Nd; NFC keeps them.'),
    ('other-numbers-no', ' '.join(u(value) for value in (0xBD, 0xB2, 0xB3, 0x2460, 0x2473, 0xBC)), 0,
     'Fractions, superscripts and circled numbers are No.'),
    ('letter-numbers-nl', ' '.join(u(value) for value in (0x216B, 0x2177, 0x3007, 0x16EE)), 0,
     'Roman numerals, ideographic zero and a runic number are Nl.'),
    ('digits-and-number-forms', 'Chapter 3 ' + u(0xBD) + ' ' + u(0x2163), 8, 'Letters and the Nd digit count; the No and Nl forms do not.'),
    ('emoji', u(0x1F44D, 0x1F389, 0x1F642), 0, 'Emoji are So.'),
    ('emoji-modifier-and-flag', u(0x1F44D, 0x1F3FD) + ' ' + u(0x1F1EA, 0x1F1EA), 0,
     'A skin-tone modifier (Sk) and regional indicators (So).'),
    ('zwj-sequences', WOMAN_TECHNOLOGIST + ' ' + u(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467), 0,
     'Emoji joined by ZERO WIDTH JOINER (Cf).'),
    ('zwj-sequence-in-text', 'Code ' + WOMAN_TECHNOLOGIST + ' ok', 6, 'Letters around a ZWJ emoji sequence.'),
    ('zwj-devanagari-half-form', u(0x915, 0x94D, 0x200D, 0x937), 2, 'KA, virama (Mn), ZWJ (Cf), SSA: two letters.'),
    ('combining-marks', 'q' + u(0x307) + ' e' + u(0x301) + ' ' + u(0x301), 2,
     'q with a dot above has no precomposed form, e with an acute composes, and a lone mark (Mn) counts 0.'),
    ('devanagari-vowel-signs', u(0x939, 0x93F, 0x928, 0x94D, 0x926, 0x940), 3,
     'Three consonants (Lo); vowel signs (Mc) and the virama (Mn) do not count.'),
    ('kana-decomposed', u(0x304B, 0x3099, 0x3044), 2, 'KA plus a combining voiced mark composes into GA under NFC.'),
    ('cjk-and-kana', u(0x65E5, 0x672C, 0x8A9E, 0x3067, 0x3059, 0x3002), 5,
     'Ideographs and kana are Lo; the ideographic full stop is Po.'),
    ('modifier-and-titlecase-letters', u(0x1C5) + 'emal Hawai' + u(0x2BB) + 'i', 12,
     'A titlecase letter (Lt) and the okina, a modifier letter (Lm), both count.'),
    ('astral-letters-and-digits', u(0x1D400, 0x1D7D0, 0x20000), 3,
     'Astral scalars count once each: a bold capital (Lu), a bold digit (Nd) and a CJK Extension B ideograph (Lo).'),
    ('noncharacter-fffe', 'a' + u(0xFFFE) + 'b', 2,
     'U+FFFE is a noncharacter (Cn) and does not count. .NET Normalize rejects it, so the Windows Core first makes it U+FFFD.'),
    ('noncharacter-fffe-alone', u(0xFFFE), 0, 'A text that is only U+FFFE.'),
    ('noncharacter-fffe-before-mark', 'x' + u(0xFFFE, 0x301) + 'y', 2,
     'A combining mark after U+FFFE stays with it, and neither counts.'),
    ('other-noncharacters', 'a' + u(0xFFFF) + 'b' + u(0xFDD0) + 'c' + u(0x1FFFE) + 'd' + u(0x10FFFF), 4,
     'U+FFFF, U+FDD0, U+1FFFE and U+10FFFF are noncharacters too; .NET normalises them, and none counts.'),
]
NONCHARACTERS = {*range(0xFDD0, 0xFDF0), *(plane * 0x10000 + low for plane in range(17) for low in (0xFFFE, 0xFFFF))}

ids = [case[0] for case in CASES]
assert len(ids) == len(set(ids)), 'duplicate case id'
for case_id, text, expected, _ in CASES:
    assert length(text) == expected, f'{case_id}: unicodedata gives {length(text)}, the case says {expected}'
    assert all(unicodedata.category(scalar) != 'Cn' or ord(scalar) in NONCHARACTERS for scalar in text), f'{case_id}: unassigned scalar'
assert length(JAMO) != sum(1 for scalar in JAMO if unicodedata.category(scalar).startswith('L')), 'the jamo case must depend on NFC'

document = {
    'version': 1,
    'rule': 'Count the Unicode scalars of general category L* or Nd after NFC (voice-lab ' + u(0xA7) + '8.9.1).',
    'cases': [{'id': case_id, 'text': text, 'scalars': ' '.join(f'U+{ord(scalar):04X}' for scalar in text),
               'length': expected, 'note': note} for case_id, text, expected, note in CASES],
}
OUT.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
