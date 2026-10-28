# tools/captions

Reference implementation and generators for the caption system. The normative rules are in [doc/spec/captions.md](../../doc/spec/captions.md); this code is an executable reading of them and produces the shared fixtures that both apps test against. Nothing here ships in an app.

## Setup

Use a throwaway virtual environment outside the repository:

```sh
python3 -m venv /tmp/voxclip-captions-venv
/tmp/voxclip-captions-venv/bin/pip install -r tools/captions/requirements.txt
```

Run every script with `-I` (isolated mode). The scripts put their own folder on `sys.path`, so they work from any directory.

## Scripts

| Script | What it does | Needs |
|---|---|---|
| `check_styles.py` | Validates every `shared/caption-styles/styles/*.json` against `schema.json` and the semantic rules of spec section 2.5, plus the emoji lexicon | `jsonschema` |
| `build_font_manifest.py` | Reads every TTF and emoji PNG in `shared/fonts` and writes `shared/fonts/fonts.json` (metrics, coverage, licence, provenance from `font-sources.json`, sha256) | `fonttools` |
| `build_casemap.py <UnicodeData.txt>` | Writes `shared/caption-styles/casemap.json` from the Unicode 16.0.0 UnicodeData.txt | none |
| `gen_fixtures.py` | Builds every case of `cases.json` (plus the style × aspect matrix) and writes `shared/fixtures/captions/` | `fonttools`, `uharfbuzz`, `regex`, `jsonschema` |
| `gen_cards.py` | Builds the caption card cases of `card-cases.json` (doc/design.md section 5.4.2), validates each project against the project schema and writes `shared/fixtures/captions/cards.json`. The scope's caption copy comes from the editing fixture generator's reference planner, run through `card_plans.mjs`. Every card and fit drop is laid out with the reference engine and refused unless its drawn moment shows the key word | `regex`, `jsonschema`, `fonttools`, `uharfbuzz`, Node.js 22 |
| `gen_gallery.py` | Builds the gallery tile cases of `gallery-cases.json` (spec 15.3) with the card rules of `captionref.card` and writes `shared/fixtures/captions/gallery-samples.json`. Caption copies come from `card_plans.mjs`, as for `gen_cards.py`. It takes only words the style's primary font covers whole, and checks that the page at the tile time contains the drawn word, including when the tile timing splits the sample. With `jsonschema` installed it also validates each project | Node.js 22 (standard library otherwise) |
| `gen_card_colors.py` | Writes `shared/fixtures/captions/card-colors.json`, the design.md section 5.4.3 sidebar key-word colour vectors | none (standard library) |
| `gen_box_text_colors.py` | Writes `box-text-colors.json` version 2: 74 final-paint vectors, including emphasis, palette, wipe and whole-gradient contrast on word/line/page boxes and unboxed controls (spec 2.3, 10.2, 10.4) | none (standard library) |
| `check_drift.py` | Checks regenerated caption JSON against HEAD; only `box-text-colors.json` permits the existing Voice Lab comparator's libm tolerance (relative 1e-10, absolute 1e-12), restoring committed bytes after a tolerant match | none (standard library) |
| `compare_overlays.py` | The image comparison of spec section 16.5, for two PNGs or two folders of goldens | `numpy` |
| `parity.sh` | Renders every golden sample with the Swift and the C# CLI and compares them (spec 16.6) | Xcode, .NET 10 SDK, `numpy` |

```sh
P=/tmp/voxclip-captions-venv/bin/python
$P -I tools/captions/check_styles.py
$P -I tools/captions/build_font_manifest.py          # after adding or updating a font
curl -o /tmp/voxclip-ucd/UnicodeData.txt https://www.unicode.org/Public/16.0.0/ucd/UnicodeData.txt
$P -I tools/captions/build_casemap.py /tmp/voxclip-ucd/UnicodeData.txt
$P -I tools/captions/gen_fixtures.py
$P -I tools/captions/gen_cards.py                   # caption card fixtures
python3 -I tools/captions/gen_gallery.py              # gallery tile samples; no venv needed
python3 -I tools/captions/gen_card_colors.py          # sidebar key-word colour vectors
python3 -I tools/captions/gen_box_text_colors.py      # text on a caption box
python3 -I tools/captions/check_drift.py              # after committing intentional fixture changes
git diff --stat shared/                               # review: a fixture diff is a behaviour change
```

`gen_fixtures.py`, `gen_cards.py`, `gen_gallery.py`, `gen_card_colors.py` and `gen_box_text_colors.py` are deterministic: running any of them twice gives byte-identical files. `gen_fixtures.py` deletes and rewrites `shared/fixtures/captions/layout/`. It also builds Box highlight's preview words in portrait and landscape for every swatch, plus five final-paint cases (`box-final-emphasis-fill`, `box-final-palette`, `box-final-wipe`, `box-final-gradient-kept`, `box-final-gradient-replaced`). Each final-paint case samples six 30fps frames from frame 3, with pixel goldens at frames 3 and 8. The layout snapshot's optional `boxContrast` and `wipeFromBoxContrast` flags distinguish a final contrast fallback without losing `fillSource` precedence provenance. The 38 default gallery tiles are unchanged.

## Package `captionref`

| Module | Spec sections |
|---|---|
| `util.py` | 1.3 rounding, JSON output |
| `style.py` | 2.2 defaults, 2.4 resolution (aspect overrides, RFC 7396 patch, positions), 2.3 colours, 5.1 aspect class |
| `contrast.py` | 2.3 WCAG box text contrast and the six accent swatches |
| `text.py` | 3 normalisation, case map, punctuation, sentence and clause ends, matching keys, grapheme clusters (only these need `regex`) |
| `fontdb.py` | 4.1 manifest, 4.3 HarfBuzz shaping at `unitsPerEm` scale, 4.4 nearest-weight fallback |
| `layout.py` | 4.4 to 4.6 measurement, 5 frame, 6 paging and line breaking, 7 placement, 8.1 page timing, 9 emphasis and emoji selection, 10.2 fill precedence |
| `timeline.py` | 8.2 states, 10.3 to 10.5 reveal and cursor, 11 animation, jitter and mulberry32 |
| `mathref.py` | 10.4 gradient end points, 12.1 rounded rectangles, 13.2 blur |
| `card.py` | doc/design.md 5.4.2 caption card words, key word and drawn moment, with 6.1 paging and the 4.4 font cascade by coverage |
| `takes.py` | Projects for the card and gallery cases (stored, patched or synthetic takes), their schema check, and caption copies through `card_plans.mjs` |

It does not rasterise. Pixel goldens come from the macOS renderer (`voxclip-cli render-caption`), spec section 16.4.

## Reviewing macOS golden output

Regenerate through the CLI's shared `CaptionRenderHarness` (spec 16.7):

```sh
cd apps/macos
nice swift build --jobs 4 --product voxclip-cli
export VOXCLIP_SHARED_DIR="$PWD/../../shared"
for fixture in ../../shared/fixtures/captions/layout/*.json; do
  nice swift run --skip-build --jobs 4 voxclip-cli render-caption --case "$fixture" --out /tmp/voxclip-reviewed-goldens
done
nice swift run --skip-build --jobs 4 voxclip-cli render-caption --tiles ../../shared/fixtures/captions/preview-tiles.json --out /tmp/voxclip-reviewed-goldens
```

Use a fresh output directory outside `shared/`. Generation refuses the configured shared directory and its descendants, the committed golden root, and symlink aliases into either. Generation does not compare against stored goldens; normal tests always check cache parity and tile states, and require the stored root for pixel comparisons. `VOXCLIP_SKIP_CAPTION_GOLDENS` does not disable these checks.

Review the generated PNGs and indexes before explicitly copying accepted output into the repository:

```sh
diff -rq ../../shared/fixtures/captions/golden /tmp/voxclip-reviewed-goldens
cp -R /tmp/voxclip-reviewed-goldens/. ../../shared/fixtures/captions/golden/
git diff --stat -- ../../shared/fixtures/captions/golden
```

The test hook `VOXCLIP_GOLDEN_OUT=/tmp/voxclip-reviewed-goldens swift test --filter goldenRenders` uses the same harness. Normal tests compare stored references; generation never silently replaces them.

## Adding a style

1. Add `shared/caption-styles/styles/<id>.json` (copy a similar style; the gallery position comes from `order`).
2. If it needs a font that is not bundled, add the font first (`shared/fonts/README.md`).
3. Run `check_styles.py`, then `gen_fixtures.py`. The style × aspect matrix adds three layout cases automatically; add a targeted case to `cases.json` when the style uses a feature no case covers yet.
4. Update the catalogue table in doc/spec/captions.md section 17 in the same change.

## Files

- `cases.json`: fixture inputs (word sets, cases, the style × aspect matrix).
- `font-sources.json`: where every file in `shared/fonts` came from, pinned to a commit.
