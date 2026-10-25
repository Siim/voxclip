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
| `compare_overlays.py` | The image comparison of spec section 16.5, for two PNGs or two folders of goldens | `numpy` |
| `parity.sh` | Renders every golden sample with the Swift and the C# CLI and compares them (spec 16.6) | Xcode, .NET 10 SDK, `numpy` |

```sh
P=/tmp/voxclip-captions-venv/bin/python
$P -I tools/captions/check_styles.py
$P -I tools/captions/build_font_manifest.py          # after adding or updating a font
curl -o /tmp/voxclip-ucd/UnicodeData.txt https://www.unicode.org/Public/16.0.0/ucd/UnicodeData.txt
$P -I tools/captions/build_casemap.py /tmp/voxclip-ucd/UnicodeData.txt
$P -I tools/captions/gen_fixtures.py
git diff --stat shared/                               # review: a fixture diff is a behaviour change
```

`gen_fixtures.py` is deterministic: running it twice gives byte-identical files. It deletes and rewrites `shared/fixtures/captions/layout/`.

## Package `captionref`

| Module | Spec sections |
|---|---|
| `util.py` | 1.3 rounding, JSON output |
| `style.py` | 2.2 defaults, 2.4 resolution (aspect overrides, RFC 7396 patch, positions), 2.3 colours, 5.1 aspect class |
| `text.py` | 3 normalisation, case map, punctuation, sentence and clause ends, matching keys, grapheme clusters |
| `fontdb.py` | 4.1 manifest, 4.3 HarfBuzz shaping at `unitsPerEm` scale, 4.4 nearest-weight fallback |
| `layout.py` | 4.4 to 4.6 measurement, 5 frame, 6 paging and line breaking, 7 placement, 8.1 page timing, 9 emphasis and emoji selection, 10.2 fill precedence |
| `timeline.py` | 8.2 states, 10.3 to 10.5 reveal and cursor, 11 animation, jitter and mulberry32 |
| `mathref.py` | 10.4 gradient end points, 12.1 rounded rectangles, 13.2 blur |

It does not rasterise. Pixel goldens come from the macOS renderer (`voxclip-cli render-caption`), spec section 16.4.

## Adding a style

1. Add `shared/caption-styles/styles/<id>.json` (copy a similar style; the gallery position comes from `order`).
2. If it needs a font that is not bundled, add the font first (`shared/fonts/README.md`).
3. Run `check_styles.py`, then `gen_fixtures.py`. The style × aspect matrix adds three layout cases automatically; add a targeted case to `cases.json` when the style uses a feature no case covers yet.
4. Update the catalogue table in doc/spec/captions.md section 17 in the same change.

## Files

- `cases.json`: fixture inputs (word sets, cases, the style × aspect matrix).
- `font-sources.json`: where every file in `shared/fonts` came from, pinned to a commit.
