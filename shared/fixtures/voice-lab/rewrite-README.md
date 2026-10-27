# Rewrite budget fixtures

These synthetic vectors cover the text side of re-voicing (voice-lab §8.1 and §8.9.1). Python 3 standard-library generators in `tools/fixtures/voice-lab/` write them; running a generator twice gives identical bytes. Never edit the JSON by hand. Both Core suites replay every case.

## `text-length-cases.json`

Written by `generate_text_length.py`. The vectors for `VoiceLabTextLength`: the number of Unicode scalars of general category L* or Nd after NFC (voice-lab §8.9.1). Each case has:

- `id`;
- `text`, stored with JSON escapes so that precomposed and decomposed forms stay explicit;
- `scalars`, the text's scalars as space-separated `U+XXXX`, which a suite compares first to show that its JSON reader kept the text as written;
- `length`, the expected count;
- `note`.

The generator's expected lengths are typed by hand and checked against Python's `unicodedata`. Every assigned character is from Unicode 8.0 or older (the emoji modifier U+1F3FD is the newest), and noncharacters are reserved for good, so the Swift, .NET and Python Unicode tables agree on them. The 39 cases cover the empty string, whitespace and punctuation, Estonian õ ä ö ü š ž precomposed and decomposed, Hangul syllables, conjoining jamo (the case where NFC changes the count), a precomposed syllable and a trailing jamo, which NFC composes into one letter, U+1113, U+1176, U+11A7 and U+11C3, which are inert boundary jamo and compose with nothing, and compatibility jamo, Arabic-Indic, Devanagari and fullwidth digits, No and Nl number forms (which do not count), emoji with a modifier, flags and ZWJ sequences, combining marks (Mn and Mc do not count), kana and CJK, a titlecase and a modifier letter (which do count), and astral letters and digits, which count once each. Four cases hold noncharacters, which do not count: U+FFFE between letters, alone and before a combining mark (.NET's normaliser rejects it, so Windows normalises the runs around it on their own and keeps it, editing §4.8), and U+FFFF, U+FDD0, U+1FFFE and U+10FFFF.

## `rewrite-checks-cases.json`

Written by `generate_rewrite_checks.py`. The rows for the checks both rewrite sends make (ai.md §12.8), each just below, at and just above its bound. The top level holds `rules`, a provenance note, `contextSafetyFactor`, which must equal the catalogue's, and five lists of rows, each row with an `id`:

- `answeredBy`: `connector`, `selected`, `answered` and `accepted`. The 37 rows cover exact ids; dated snapshots with and without hyphens on every kind of HTTP connector; leap days in 2028 and 2000 and none in 2026 or 2100; month 13, day 0, 31 April and the last day of a month; suffixes that are no date, a date followed by more, a date without its hyphen, a mixed form, nine digits and Arabic-Indic digits; a prefix of the selected id and the selected id as a prefix; a different case; canonically equivalent ids; Codex and Apple, which take no snapshots; and Claude Code's aliases, `default`, a selected full id and an alias missing its hyphen.
- `modelIds`: `model` and `valid`. The 16 rows cover 0, 1, 256 and 257 bytes, with two-byte and astral scalars at 256 and 257 bytes, NUL, tab, line feed, DEL and NEL, which are control characters, and a zero-width space and a space, which are not.
- `outputCaps`: `sourceTokens`, `promptCap`, `connectorCap` (or null) and the `maxOutputTokens` that results, or null when it cannot hold the source. The 12 rows cover the 512-token floor, one and a half times the source on both sides of 512, and the prompt's, Apple's and the local servers' caps.
- `contexts`: `context`, `required` and `fits`. The 12 rows cover a context below 512, the 512, 4,096, 128,000 and 1,000,000-token contexts, and 1,000 tokens, where `1000 × 0.9` is exactly 900.
- `contextResolution`: seven catalog-resolution rows (connector context, selected metadata, curated entry, then the connector-class fallback). A curated cloud model with no listed context accepts a 1,500-word source; an unlisted local model resolves to 4,096 and refuses that source. Both rewrite services replay these two sends, without live calls.

The generator checks each stated outcome against its own reading of §12.8, which uses `datetime` for dates and `unicodedata` for control characters. Both suites replay every row against their check helpers, send every `answeredBy` row through both services with a stub connector, and prepare both services with every model id.

## `patch-rewrite-cases.json`

Written by `generate_patch_rewrite.py`. The Fix with AI validation vectors (voice-lab §8.1, path 3). Every case is a canned model reply, so no case calls a provider. The top level holds:

- `rules`, a provenance note;
- `copy.checkThis`, the badge copy, which must equal `messages.checkThis` in `shared/prompts/patch-rewrite.json`;
- `language`, `entries` and `ranges`, the usual request: 18 transcript items, indices 40–57, in three lines with their ranges of letters and digits;
- `cases`.

Each case has:

- `id` and `note`;
- `instruction`, the request's instruction;
- optional `entries` and `ranges`, when the case needs a request of its own;
- `reply`, the model's whole text reply;
- optional `stop`, `refused` or `truncated`, when the reply did not end normally;
- `expected`: either `{"error": …}` with `invalidOutput`, `refused` or `truncated`, or the kept `edits` in order (each with `line`, `text`, `reason`, `length`, `inRange`, `checkThis` and `isDeletion`) and the `unknownLines`, `duplicateLines` and `malformedItems` counts;
- optional `rewriteExpected`: what `VoiceRewriteService` makes of the same reply and stop for a passage of the same words, either `{"rewrite", "proposedLength"}` or `{"error": …}`.

The generator works out each expected result with its own Python reading of the §8.1 rules: the strict JSON rule and extraction (ai.md §4.5), structural validation (§2.3), malformed edits, line matching, duplicates, deletions, the letter-and-digit length against the line's range, the 20,000-byte total and `checkThis`, and for `rewriteExpected` the passage rewrite's output rules (§8.9.1). Each case also states its outcome by hand, and the generator fails if the two disagree. The 82 cases cover:

- edits in range, below it and above it, which are all kept;
- an unknown line, and a duplicate line, where the first is kept;
- new digit runs, including other-script digits;
- a new URL, a URL from the instruction, and a new `www.` URL;
- capitalised tokens mid-sentence, at a sentence start, after a closing quote, and with a different case from the transcript;
- a token of conjoining jamo whose key equals the instruction's Hangul syllable only by canonical equivalence, so it is new;
- a precomposed syllable and a trailing jamo, which NFC turns into the instruction's syllable, so the token appears;
- decomposed text;
- deleting a whole line with empty or blank text, and a text of punctuation alone, which deletes nothing;
- malformed items: a missing field or one of the wrong type, NUL, ESC, a line break, DEL or NEL in the text, a control character in the reason, and a text over 2,000 UTF-8 bytes; a tab and a text of exactly 2,000 bytes are kept;
- edits holding exactly 20,000 bytes of text, which are kept, and more, which is invalid output;
- extra keys, a padded line label, a code-fenced reply, a one-line fence, prose around the JSON, a combining mark after a quote, a byte order mark, and a top-level array;
- repeated keys at the top level, in an item and in an ignored key, where the first value counts, and an invalid value of a repeated key, which fails;
- ten strict-key vectors built from explicit Python code points: Latin NFC/NFD in both orders, Kelvin, Hangul, nested and null-valued collisions; byte-identical repeats, different escape spellings, sibling objects and distinct-case keys. Both Core suites also replay these through the strict reply and transport-envelope parsers;
- unpaired surrogate escapes in the text, the reason, an ignored key and a key name, and a reversed pair, which all fail, and an escaped pair, which is valid;
- 64 levels of nesting, which is valid, and 65, which is not;
- numbers out of range, negative, as an integer and rounding to zero, and `NaN`, which all fail, and a subnormal number and zeros with an exponent (`0e-400`, `0e1`, `0E1`, `0.00e-1` and `-0.0e5`), which are valid;
- U+FFFE in the text, escaped or raw, and in the instruction;
- rewrites holding DEL and NEL, or only a byte order mark, which the passage rewrite rejects;
- a refused and a truncated stop;
- an empty list;
- invalid output: no JSON, and no `edits` array.

Both suites send every case through their `PatchRewriteService` with a stub connector, and the 45 cases with `rewriteExpected` through their `VoiceRewriteService` too.
