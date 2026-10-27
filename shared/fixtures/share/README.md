# Share-text fixtures

`generate_share_cases.py` is the reference implementation of the share-text rules in `doc/publishing.md` §2.1 and the disclosure-line rules in `doc/spec/voice-lab.md` §11.3. It writes `shared/data/share-text.json` (the constants both Cores load at runtime) and `cases.json` (the cases both Core suites replay). Standard library only; two runs write identical bytes:

```sh
python3 -I shared/fixtures/share/generate_share_cases.py /tmp/voxclip-unicode-15.1.0/emoji-data.txt
```

The argument is a local copy of Unicode 15.1 `emoji-data.txt`. If no file exists at that path, the generator downloads it once from unicode.org. Either way its sha256 must match the pinned value in the generator. Expected values are never edited by hand; change the rules or the case list in the generator and review the regenerated diff as a behaviour change.

`cases.json` holds:

- `cases`: each `text` (and the disclosure `line`, or null) with the expected `xWeight`, `linkedInLength`, `voxConvoLength`, `composerX` and `composerVoxConvo`, and, when a line is given, `present` and `fieldText`. `clusters` is the run-length list `[scalars per extended grapheme cluster, count]` of the NFC text; Swift `Character`s and .NET `StringInfo` text elements must match it. The texts use only Unicode 15.0 emoji and no Indic conjuncts, so toolchains on different Unicode versions agree. The generator scans every cut from the longest down while the Cores bisect, or weigh X first-word cuts in one pass; the `space-free-*`, `url-prefix-first-word` and `word-*` cases pin both to the same cuts. The generator asserts its own one-pass X cut on every case and 60 random words, and that every `word-*` case is cut inside its first word for X (`check_case_rules`); `mark-on-space-first-word` pins the rule-4 cut after a first word of one U+0301 on a space. The `hangul-lv-t*` cases pin NFC (Foundation alone leaves U+AC00 U+11A8 uncomposed), the `prepend-*` cases the cluster rule of composer rule 4, and `field-text-cap` the 3,000-scalar field text of voice-lab.md §11.3.
- `defaultCaptions`: title, words and the expected default caption.
- `lines`: the §11.3 line for each combination of kinds, in `en` and `et`, as `VoiceLabDisclosurePlan.postText` joins the sentences.
- `languages`: transcript language codes and whether the line is Estonian; the render-contract suites check them against `postText`.
