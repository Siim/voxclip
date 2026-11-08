#!/usr/bin/env python3
"""Shared vectors for numbers matched however they are written (voice-lab section 8.11, ADR-R49).

Writes shared/fixtures/spoken-numbers/number-cases.json (schema voxclip-spoken-numbers-cases/1), a file of its own so no
existing replay changes. Three lists:

- `numerals`: a raw word and the number it writes in digits (`SpokenNumbers.numeral`), or null.
- `alignments`: an expected and a recognized text, split on whitespace, and the alignment `SpokenNumbers.align` must
  return: the matched token pairs, the unverified tokens on each side, how many unverified numbers, the ratio and
  whether every token is matched or unverified.
- `takeChecks`: the take QA's word check (`VoiceLabTakeQuality.evaluate`) on a script and the recognizer's words: its
  transcript match, its unverified numbers and whether the transcript rule passes.

Every pair is derived by hand from the rules in its `derivation`, never from the code under test; the ratio is computed
here from those pairs. The Mac Core (SpokenNumbersReplayTests) and the Windows Core (SpokenNumbersReplayTests) replay
every list. Deterministic; run from anywhere:

    python3 -I tools/fixtures/spoken-numbers/generate_number_cases.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/spoken-numbers/number-cases.json'


def numeral(raw, value=None, digits=None, ordinal=False, unit=None):
    parsed = None if value is None else {'value': value, 'digits': digits if digits is not None else value.split('.')[0],
                                         'ordinal': ordinal, 'unit': unit}
    return {'raw': raw, 'numeral': parsed}


def numerals():
    return [
        numeral('300', '300'),
        numeral('$300', '300', unit='dollar'),
        numeral('$300,', '300', unit='dollar'),
        numeral('"$300."', '300', unit='dollar'),
        numeral('1,000', '1000'),
        numeral('10,000.50', '10000.50', digits='10000'),
        numeral('1.5', '1.5', digits='1'),
        numeral('1.5.', '1.5', digits='1'),
        numeral('€20', '20', unit='euro'),
        numeral('20€', '20', unit='euro'),
        numeral('£5', '5', unit='pound'),
        numeral('50%', '50', unit='percent'),
        numeral('3rd', '3', ordinal=True),
        numeral('21st', '21', ordinal=True),
        numeral('21ST', '21', ordinal=True),
        numeral('007', '7', digits='007'),
        numeral('(2026)', '2026'),
        numeral('1,5'),
        numeral('1,0000'),
        numeral('$'),
        numeral('%'),
        numeral('3x'),
        numeral('$3rd'),
        numeral('1.5th'),
        numeral('$$300'),
        numeral('.5'),
        numeral('12-14'),
        numeral('twenty'),
    ]


def normalized(word):
    return ''.join(character for character in word.lower() if character.isalnum())


def alignment(identity, category, derivation, expected, recognized, pairs, unverified_expected=(),
              unverified_recognized=(), unverified_numbers=0):
    expected_tokens = [token for token in map(normalized, expected.split()) if token]
    recognized_tokens = [token for token in map(normalized, recognized.split()) if token]
    for left, right in pairs:
        assert 0 <= left < len(expected_tokens) and 0 <= right < len(recognized_tokens), identity
    counted = len(expected_tokens) + len(recognized_tokens) - len(unverified_expected) - len(unverified_recognized)
    matched = len({left for left, _ in pairs}) + len({right for _, right in pairs})
    ratio = 1.0 if counted == 0 else matched / counted
    complete = (len({left for left, _ in pairs}) + len(unverified_expected) == len(expected_tokens)
                and len({right for _, right in pairs}) + len(unverified_recognized) == len(recognized_tokens))
    return {'id': identity, 'category': category, 'derivation': derivation, 'expected': expected, 'recognized': recognized,
            'expectedTokens': expected_tokens, 'recognizedTokens': recognized_tokens, 'pairs': [list(pair) for pair in pairs],
            'unverifiedExpected': list(unverified_expected), 'unverifiedRecognized': list(unverified_recognized),
            'unverifiedNumbers': unverified_numbers, 'ratio': ratio, 'complete': complete}


def alignments():
    return [
        # Cardinals.
        alignment('cardinal-words-heard-as-a-numeral', 'cardinal',
                  '"three hundred" reads 300: the numeral "300" pairs with both words.',
                  'it costs three hundred now', 'it costs 300 now', [(0, 0), (1, 1), (2, 2), (3, 2), (4, 3)]),
        alignment('cardinal-numeral-heard-as-words', 'cardinal',
                  'The reverse: the script\'s "300" pairs with the two words heard.',
                  'it costs 300 now', 'it costs three hundred now', [(0, 0), (1, 1), (2, 2), (2, 3), (3, 4)]),
        alignment('cardinal-thousands', 'cardinal',
                  '"two thousand twenty six" reads 2000 + 26 = 2026.',
                  'since 2026 we grow', 'since two thousand twenty six we grow',
                  [(0, 0), (1, 1), (1, 2), (1, 3), (1, 4), (2, 5), (3, 6)]),
        alignment('cardinal-thousands-heard-as-a-numeral', 'cardinal',
                  'The reverse, with "and": "two thousand and twenty six" is 2026.',
                  'since two thousand and twenty six we grow', 'since 2026 we grow',
                  [(0, 0), (1, 1), (2, 1), (3, 1), (4, 1), (5, 1), (6, 2), (7, 3)]),
        alignment('cardinal-decimal-words', 'cardinal',
                  '"one point five" reads 1.5; "million" is the same word on both sides.',
                  'about one point five million', 'about 1.5 million', [(0, 0), (1, 1), (2, 1), (3, 1), (4, 2)]),
        alignment('cardinal-decimal-numeral', 'cardinal',
                  'The reverse: the script\'s "1.5" pairs with "one point five".',
                  'about 1.5 million', 'about one point five million', [(0, 0), (1, 1), (1, 2), (1, 3), (2, 4)]),
        alignment('cardinal-a-hundred', 'cardinal', '"a hundred" reads 100.', 'a hundred times', '100 times',
                  [(0, 0), (1, 0), (2, 1)]),
        alignment('cardinal-a-hundred-heard', 'cardinal', 'The reverse.', '100 times', 'a hundred times',
                  [(0, 0), (0, 1), (1, 2)]),
        alignment('cardinal-hyphenated', 'cardinal',
                  '"twenty-six" is one token "twentysix" once its hyphen is stripped, and reads 26.',
                  'twenty-six people', '26 people', [(0, 0), (1, 1)]),
        # Years read in pairs.
        alignment('year-pair-heard-as-words', 'yearPair',
                  '"nineteen ninety seven" reads 19 then 97: the year 1997.',
                  'back in 1997 it', 'back in nineteen ninety seven it', [(0, 0), (1, 1), (2, 2), (2, 3), (2, 4), (3, 5)]),
        alignment('year-pair-heard-as-a-numeral', 'yearPair',
                  '"twenty twenty six" reads 20 then 26: 2026. It is no cardinal ("twenty twenty" is not a number).',
                  'in twenty twenty six we', 'in 2026 we', [(0, 0), (1, 1), (2, 1), (3, 1), (4, 2)]),
        alignment('year-pair-with-oh', 'yearPair', '"nineteen oh five" reads 19 then 05: 1905.', 'in 1905', 'in nineteen oh five',
                  [(0, 0), (1, 1), (1, 2), (1, 3)]),
        # Digits read one by one.
        alignment('digits-heard-as-a-numeral', 'digits', '"one two three" reads the digits 123.', 'code one two three',
                  'code 123', [(0, 0), (1, 1), (2, 1), (3, 1)]),
        alignment('digits-heard-as-words', 'digits', 'The reverse.', 'code 123', 'code one two three',
                  [(0, 0), (1, 1), (1, 2), (1, 3)]),
        alignment('digits-with-a-leading-zero', 'digits',
                  '"oh oh seven" reads the digits 007, which "007" writes as written.', 'agent 007', 'agent oh oh seven',
                  [(0, 0), (1, 1), (1, 2), (1, 3)]),
        # Ordinals.
        alignment('ordinal-heard-as-a-numeral', 'ordinal', '"third" is the ordinal 3, "3rd".', 'the third time', 'the 3rd time',
                  [(0, 0), (1, 1), (2, 2)]),
        alignment('ordinal-heard-as-a-word', 'ordinal', 'The reverse.', 'the 3rd time', 'the third time',
                  [(0, 0), (1, 1), (2, 2)]),
        alignment('ordinal-compound-heard-as-words', 'ordinal', '"twenty first" is the ordinal 21, "21st".',
                  'on the 21st', 'on the twenty first', [(0, 0), (1, 1), (2, 2), (2, 3)]),
        alignment('ordinal-compound-heard-as-a-numeral', 'ordinal', 'The reverse.', 'on the twenty first', 'on the 21st',
                  [(0, 0), (1, 1), (2, 2), (3, 2)]),
        # Commas and decimals in numerals.
        alignment('comma-numeral-heard-as-words', 'separators', '"1,000" is 1000, "one thousand".', '1,000 people',
                  'one thousand people', [(0, 0), (0, 1), (1, 2)]),
        alignment('comma-numeral-written-as-words', 'separators', 'The reverse.', 'one thousand people', '1,000 people',
                  [(0, 0), (1, 0), (2, 1)]),
        alignment('comma-numeral-against-plain-digits', 'separators',
                  'Two numerals of the same value match whatever their separators.', '1,000 people', '1000 people',
                  [(0, 0), (1, 1)]),
        # Currency.
        alignment('currency-heard-as-words', 'currency',
                  '"$300" is three hundred dollars: the numeral pairs with the reading and the unit word after it.',
                  '$300 is enough', 'three hundred dollars is enough', [(0, 0), (0, 1), (0, 2), (1, 3), (2, 4)]),
        alignment('currency-written-as-words', 'currency', 'The reverse.', 'three hundred dollars is enough', '$300 is enough',
                  [(0, 0), (1, 0), (2, 0), (3, 1), (4, 2)]),
        alignment('currency-euro', 'currency', '"€20" is twenty euros.', '€20 each', 'twenty euros each',
                  [(0, 0), (0, 1), (1, 2)]),
        alignment('currency-euro-sign-after', 'currency', '"20€" is twenty euros too.', 'twenty euros each', '20€ each',
                  [(0, 0), (1, 0), (2, 1)]),
        alignment('currency-pound', 'currency', '"£5" is five pounds.', '£5 off', 'five pounds off', [(0, 0), (0, 1), (1, 2)]),
        alignment('currency-without-its-word', 'currency',
                  'The unit word is optional: "$300" heard as "three hundred" matches.', '$300 now', 'three hundred now',
                  [(0, 0), (0, 1), (1, 2)]),
        # Percent.
        alignment('percent-heard-as-words', 'percent', '"50%" is fifty percent.', '50% more', 'fifty percent more',
                  [(0, 0), (0, 1), (1, 2)]),
        alignment('percent-written-as-two-words', 'percent', '"fifty per cent" is 50%: "per cent" is the unit.',
                  'fifty per cent more', '50% more', [(0, 0), (1, 0), (2, 0), (3, 1)]),
        # Units around a numeral.
        alignment('unit-before-a-noun', 'units',
                  'The lead\'s case: "three hundred dollar bill" heard as "$300 bill". The numeral takes the reading and '
                  'its unit word; "bill" matches itself.',
                  'a three hundred dollar bill', 'a $300 bill', [(0, 0), (1, 1), (2, 1), (3, 1), (4, 2)]),
        alignment('unit-before-a-noun-reversed', 'units', 'The reverse.', 'a $300 bill', 'a three hundred dollar bill',
                  [(0, 0), (1, 1), (1, 2), (1, 3), (2, 4)]),
        alignment('unit-word-after-a-plain-numeral', 'units',
                  '"$300" against "300 dollar": the plain numeral and its unit word say the dollar sign.',
                  '$300 bill', '300 dollar bill', [(0, 0), (0, 1), (1, 2)]),
        alignment('unit-word-of-another-currency', 'units',
                  '"$300" against "three hundred euro": the reading matches but "euro" is not the dollar, so it stays '
                  'unmatched.', '$300 bill', 'three hundred euro bill', [(0, 0), (0, 1), (1, 3)]),
        # Non-matches stay mismatches.
        alignment('non-match-three-hundred-against-thirty', 'nonMatch',
                  '"three hundred" reads 300, not 30. English number words are never unverified, so both stay mismatches.',
                  'three hundred people', '30 people', [(2, 1)]),
        alignment('non-match-another-year', 'nonMatch', '"twenty twenty six" is 2026, not 2025.', 'in twenty twenty six',
                  'in 2025', [(0, 0)]),
        alignment('non-match-another-amount', 'nonMatch', '"$300" is not "$30"; two numerals are never unverified.',
                  '$300 is enough', '$30 is enough', [(1, 1), (2, 2)]),
        alignment('non-match-decimal-against-integer', 'nonMatch',
                  '"1.5" is not 15, though both normalize to the token "15".', '1.5 times', '15 times', [(1, 1)]),
        alignment('non-match-ordinal-against-cardinal', 'nonMatch',
                  '"3rd" is the ordinal 3; "three" is the cardinal.', 'the 3rd one', 'the three one', [(0, 0), (2, 2)]),
        # Other languages: unverified, neither matched nor a mismatch.
        alignment('other-language-one-word', 'otherLanguage',
                  'German "dreihundert" faces "300" alone in its gap: unverified, one number.',
                  'kostet 300 Euro', 'kostet dreihundert Euro', [(0, 0), (2, 2)], [1], [1], 1),
        alignment('other-language-two-words', 'otherLanguage',
                  'French "trois cents" (two words, no English number among them) faces "300": unverified.',
                  'il a 300 ans', 'il a trois cents ans', [(0, 0), (1, 1), (3, 4)], [2], [2, 3], 1),
        alignment('other-language-script-spells-it', 'otherLanguage', 'The reverse: the script spells it, the recognizer writes digits.',
                  'il a trois cents ans', 'il a 300 ans', [(0, 0), (1, 1), (4, 3)], [2, 3], [2], 1),
        alignment('other-language-run-too-long', 'otherLanguage',
                  'Five words against one numeral is more than the four a number may take: mismatches.',
                  'kostet 300 heute', 'kostet drei hundert und noch mehr heute', [(0, 0), (2, 6)]),
        alignment('other-language-gap-with-another-word', 'otherLanguage',
                  'The gap holds "300 Euro" against "dreihundert Dollar": the numeral is not alone, so nothing is unverified.',
                  'kostet 300 Euro heute', 'kostet dreihundert Dollar heute', [(0, 0), (3, 3)]),
        # Without numbers the alignment is the plain one.
        alignment('plain-words', 'plain', 'No numbers: the longest common subsequence of equal tokens.',
                  'we close deals today', 'we close details today', [(0, 0), (1, 1), (3, 3)]),
    ]


def take_check(identity, derivation, expected, recognized, transcript_match, passed, unverified_numbers=0):
    return {'id': identity, 'derivation': derivation, 'expected': expected, 'recognized': recognized.split(),
            'transcriptMatch': transcript_match, 'passed': passed, 'unverifiedNumbers': unverified_numbers}


def take_checks():
    return [
        take_check('short-phrase-currency-heard-as-words',
                   'Three tokens, so the exact rule: "$300" said as "three hundred dollars" is every word said.',
                   '$300 is enough', 'three hundred dollars is enough', 1.0, True),
        take_check('short-phrase-wrong-amount', '"$30" is another number: the exact rule fails; 2 + 2 of 3 + 3 tokens match.',
                   '$300 is enough', '$30 is enough', 4 / 6, False),
        take_check('short-phrase-script-spells-it', 'The script spells the amount, the recognizer writes "$300".',
                   'three hundred dollars is enough', '$300 is enough', 1.0, True),
        take_check('short-phrase-ordinal', '"third" heard as "3rd".', 'the third time', 'the 3rd time', 1.0, True),
        take_check('long-phrase-ratio',
                   'Nine tokens, so the 0.9 ratio rule: every token matches, 9 + 11 of 20. Byte-equal tokens alone '
                   'would match 8 + 8 of 20, 0.8, and fail.',
                   'we paid $300 for the new camera last week', 'we paid three hundred dollars for the new camera last week',
                   1.0, True),
        take_check('short-phrase-other-language', 'French "trois cents" for "300": unverified, so the exact rule passes.',
                   'il a 300 ans', 'il a trois cents ans', 1.0, True, 1),
    ]


def main():
    numeral_rows, alignment_rows, take_rows = numerals(), alignments(), take_checks()
    counts = {}
    for row in alignment_rows:
        counts[row['category']] = counts.get(row['category'], 0) + 1
    document = {
        'schema': 'voxclip-spoken-numbers-cases/1',
        'description': ('Numbers matched however they are written (voice-lab section 8.11, ADR-R49). A numeral token on one '
                        'side matches a run of English number words on the other when both say the same number: cardinals, '
                        'decimals ("point"), years read in pairs, digits read one by one and ordinals; a currency or percent '
                        'sign matches its unit word, which is optional on either side. A numeral alone in a gap facing one '
                        'to four words with no numeral or English number word among them is unverified (another language). '
                        'Tokens are whitespace-separated words normalized to lowercase letters and digits. Generated by '
                        'tools/fixtures/spoken-numbers/generate_number_cases.py; do not hand-edit.'),
        'constants': {'longestRun': 10, 'longestUnverifiedRun': 4},
        'caseCount': len(numeral_rows) + len(alignment_rows) + len(take_rows),
        'counts': counts,
        'numerals': numeral_rows,
        'alignments': alignment_rows,
        'takeChecks': take_rows,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(document, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
