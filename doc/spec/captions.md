# Captions: styles, layout, rendering and parity

Status: normative for VoxClip 0.1.0 (M1). Owner of `shared/caption-styles/`, `shared/fonts/`, `shared/fixtures/captions/` and `tools/captions/`.

This spec defines how both apps turn the edited transcript into burned-in captions: the CaptionStyle v1 data format, text normalisation, measurement, paging and line breaking, placement, timing, animation, the drawing algorithm, and the tests that keep the macOS renderer (CoreText + Core Graphics) and the Windows renderer (HarfBuzzSharp + SkiaSharp) in agreement. An implementer needs this document, the files it names and nothing else.

"Must" is a requirement. Every number in this document is exact. Where a rule exists only to make the two platforms agree, it says so; do not "improve" it on one platform.

Provenance (informative): VoxConvo's caption code (`vox-api/src/services/videoSubtitleService.ts`, `vox-web/src/components/VoiceRecorder/SubtitleOverlay.tsx`), the planning research reports on captions, native video and design, and parity measurements made on the same font files with CoreText and HarfBuzz (identical glyph positions for Latin text, max delta 0.001 px; glyph-path rasters differ by a mean of 0.5 to 1.7 levels on ink pixels, native text drawing by 4 to 5 levels). Section 18 lists the decisions taken where sources disagreed.

---

## 0. Files

| Path | What it is |
|---|---|
| `shared/caption-styles/schema.json` | CaptionStyle v1, JSON Schema 2020-12 |
| `shared/caption-styles/styles/<id>.json` | The 19 built-in styles (section 17) |
| `shared/caption-styles/casemap.json` | Simple case mappings from Unicode 16.0 plus the explicit rules of section 3.4 |
| `shared/caption-styles/stopwords.json` | Stopwords for rule-based emphasis (section 9.1) |
| `shared/caption-styles/emoji-keywords.json` | Keywords for rule-based emoji (section 9.2) |
| `shared/fonts/<family>/*.ttf`, `OFL.txt` | Bundled static fonts, one folder per family, unmodified |
| `shared/fonts/noto-emoji/png128/*.png`, `LICENSE` | Noto Emoji images, 128×128, Apache-2.0 |
| `shared/fonts/fonts.json` | Font manifest: metrics, coverage, licence, provenance, sha256 (generated) |
| `shared/fixtures/captions/` | Layout, text, math and gallery fixtures (generated), later the pixel goldens |
| `tools/captions/` | Reference implementation (Python) and generators; nothing here ships |

Both apps read these files at run time from the app bundle (macOS `Contents/Resources/shared/`) or the install folder (Windows `shared\`), copied unchanged by the build. Never copy them into an app source folder.

---

## 1. Architecture and global rules

### 1.1 Components

| Component | macOS | Windows | Pure? |
|---|---|---|---|
| Text normaliser, style resolver, paging, line breaking, placement, timing, emphasis/emoji selection, animation math | `VoxClipCore` (Domain) | `VoxClip.Core` (Domain) | yes, fixture-tested |
| `GlyphShaper` (injected into layout): shapes one run, returns glyph ids, advances, offsets, clusters in font units | CoreText, `VoxClipMedia` | HarfBuzzSharp, `VoxClip.Media` | no |
| `CaptionRasterizer`: draws a laid-out page at time `t` | Core Graphics, `VoxClipMedia` | SkiaSharp, `VoxClip.Media` | no |

The output of layout is a `CaptionTrack`: the resolved style, the frame size, and the list of pages with lines, word rectangles, boxes, emphasis and emoji (the `expected` part of a layout fixture, section 16.2, is exactly this structure).

### 1.2 The single-renderer rule

1. Each platform has exactly one caption rasterizer. Preview frames, export frames, gallery tiles, golden renders (`voxclip-cli render-caption`) and any thumbnail use it. On macOS it runs inside the one `AVVideoCompositing` compositor used by both `AVPlayerItem.videoComposition` and the `AVAssetReader` export. On Windows it runs inside the one compose function used by the preview engine and the exporter.
2. Captions are never drawn with SwiftUI `Text`, `CATextLayer`, `AVVideoCompositionCoreAnimationTool`, `CTLineDraw`, `CTFontDrawGlyphs`, XAML `TextBlock`, DirectWrite, Win2D text, `SKCanvas.DrawText`, `SKTextBlob` or FFmpeg `drawtext`/libass.
3. Layout (paging, line breaks, shrink, placement) is computed once per output frame size, the size of the file being exported for the current aspect. The preview draws that same layout under a uniform scale `k = previewWidth / W` (section 7.6). The preview never lays out at its own size.
4. The rendered frame is a pure function of `(CaptionTrack, t)`. No state is carried between frames. Seeking, scrubbing, preview and export therefore cannot diverge.
5. The only sanctioned difference between preview and export is Reduce Motion (section 11.5), which the export ignores.
6. The UI drag handle draws only an outline from the page's visual rectangle (section 7.1); it never draws text.

### 1.3 Numeric rules

- All non-integer quantities are IEEE 754 binary64 (`Double` / `double`). Compute expressions in the order written here. Do not enable fused multiply-add contraction or fast-math.
- `roundHalfUp(x) = floor(x) + (x − floor(x) ≥ 0.5 ? 1 : 0)`. Do not use `floor(x + 0.5)` (wrong for 0.49999999999999994) and do not use C# `Math.Round(x)` (banker's rounding). Swift `x.rounded()` and C# `Math.Round(x, MidpointRounding.AwayFromZero)` match for `x ≥ 0` only; use the formula for negative values.
- Integer quantities (font units, `F64`, `limit64`) are `Int64`.
- Sorting is stable: sort by `(key, original index)`.
- Comparisons of times use the doubles as parsed; intervals are half-open `[start, end)`.

---

## 2. Caption styles

### 2.1 Files and identity

- A style is one JSON file `shared/caption-styles/styles/<id>.json` that validates against `schema.json`. `id` equals the file name without `.json`, matches `^[a-z0-9][a-z0-9-]{1,39}$`, and is stable (project files store it). The id `off` is reserved: a project with `captions.styleId == "off"` burns no captions; cuts still apply.
- `schemaVersion` is `1`. Readers reject any other value and any unknown property (`additionalProperties: false` throughout).
- Style files may contain `"$schema": "../schema.json"`; readers ignore it.

### 2.2 Defaults and absent objects

Every `default` in `schema.json` is normative: a reader behaves as if the default were written in the file. Both apps hand-code these defaults in their typed CaptionStyle model, and both test suites load `schema.json` and assert that every `default` equals the hand-coded value, so the two cannot drift (architecture.md section 2.1 rule 8). Optional objects that are absent mean:

| Absent | Meaning |
|---|---|
| `stroke` | no stroke |
| `box` | no page, line or word box |
| `shadows` | `[]` |
| `words` | no state-specific appearance (all words use `fill`, opacity 1, scale 1) |
| `reveal` | `{"unit": "page", "maxCharsPerSec": 30}` |
| `animation`, or any of its members | no animation of that kind |
| `emphasis` | `{"source": "none"}` |
| `emoji` | `{"enabled": false}` |
| `effects` | no effects |
| `aspects` | no per-aspect overrides |
| `accent` | no `$accent` token; the Colour control is hidden |

`text` is not optional: `schema.json` requires it in every style, so a reader rejects a style without it, and an overrides patch that deletes it is rejected like any other invalid patch (2.4 step 3). Its members keep their schema defaults (`transform: "none"`, `punctuation: "keep"`, `userOverridable: true`).

### 2.3 Colours

- Colours are sRGB, gamma-encoded, 8 bits per channel, straight (non-premultiplied) alpha: `#RRGGBB` (alpha FF) or `#RRGGBBAA`.
- `$accent` is the style's `accent` (opaque). `$accent/AA` is the accent's RGB with alpha byte `AA`. A style that uses `$accent` must define `accent`.
- Gradient stops must be opaque (`#RRGGBB`, `#RRGGBBFF` or `$accent`).
- Colours are premultiplied only at draw time: `(r·a/255, g·a/255, b·a/255, a)`.
- Text drawn on a box keeps its resolved text colour T (the word state's own fill when set, otherwise `fill.color`) only when its WCAG sRGB relative-luminance contrast against the resolved box RGB is at least **4.5:1**. Otherwise use whichever of `#000000` and `#FFFFFF` has higher contrast, with ties going to `#000000`. Resolve this once in Core style resolution, after aspect and project overrides, for both `box` and `words.active.box`; `hideStroke` is unchanged. No bundled style defines a backdrop-compositing rule for its translucent box, so evaluate those boxes as opaque RGB, not against the video, gallery backdrop or `preview.background`.

### 2.4 Resolution: aspect, project patch, defaults, position

The project file stores, per project (see `shared/schemas/project.schema.json`, `captions`):

```text
captions {
  styleId: string                    // a style id or "off"
  overrides: object                  // RFC 7396 JSON merge patch over the style file
  position: {x, y} | null            // dragged position for every aspect
  positionByAspect: { "16:9"|"9:16"|"1:1": {x, y} }   // wins over position
}
```

The effective style for an output frame `W×H` is built in this order:

1. Load the style file `S0`.
2. Aspect class `c` (section 5.1). If `S0.aspects[c]` exists, copy its fields into `S1`: `sizeSh` → `font.sizeSh`, `x`/`y` → `position.x`/`position.y`, `maxLineWidthW` and `maxWords` → `layout`.
3. Apply `overrides` as an RFC 7396 merge patch to `S1`, giving `S2`. Rules:
   - The patch must not contain `$schema`, `schemaVersion`, `id`, `name`, `description`, `order`, `tags`, `aspects` or `preview`; such a patch is invalid.
   - If `S0.text.userOverridable` is false, `text.transform` and `text.punctuation` in the patch are ignored.
   - `S2` must pass strict typed decoding against the CaptionStyle model (the runtime form of `schema.json`: unknown keys, wrong types, out-of-range values and bad enum values are errors; architecture.md section 2.1 rule 8) and the rules of 2.5. If it does not, the app shows the style unpatched and reports "These caption settings could not be applied." in the inspector; it never crashes. The built-in styles themselves are validated with a real JSON Schema validator by `tools/captions/check_styles.py` in CI.
4. Apply defaults (2.2) to `S2`, giving `S3`.
5. Position: `preset` is `"9:16"` if `16·W = 9·H`, `"16:9"` if `9·W = 16·H`, `"1:1"` if `W = H`, otherwise none (a source-aspect export). If `preset` exists and `positionByAspect[preset]` exists, use it; otherwise use `position` if it is not null; otherwise keep `S3.position.x/y`. A stored position is ignored when `S3.position.userDraggable` is false.

The Fine tune controls (design.md section 6.1) set or delete these keys in the stored `overrides` object and nothing else. "Delete" removes the key from `overrides` (and any object left empty); the controls never write `null`, because a `null` in a merge patch deletes the style's own value.

| Control | Keys in `overrides` |
|---|---|
| Size S · M · L · XL | S, L, XL: `font.sizeScale` = 0.8, 1.2, 1.45; M: delete `font.sizeScale` |
| Case As said · ALL CAPS | `text.transform` = `"none"` or `"uppercase"` |
| Words on screen 1 · Phrase · Line | 1: `layout.maxWords` = 1 and `layout.maxLines` = 1; Phrase: delete both; Line: `layout.maxWords` = 16 and `layout.maxLines` = 1 |
| Keep punctuation (toggle, shows the effective value) | on: `text.punctuation` = `"keep"`; off: `text.punctuation` = `"strip-keep-numeric"` |
| Colour swatch (only when the style has `accent`) | `accent` = `"#FFE14D"` (Yellow), `"#4BE38A"` (Green), `"#5CE1FF"` (Cyan), `"#FF6FAE"` (Pink), `"#F3F0E7"` (Paper) or `"#FFFFFF"` (White) |
| Position Top · Middle · Bottom | not in `overrides`: `positionByAspect[current preset]` (or `position` for a source aspect) = `{x: 0.5, y: 0.2}`, `{x: 0.5, y: 0.5}`, or delete the entry (Bottom = the style's own position) |
| Drag on the video | not in `overrides`: same target as Position; `x`, `y` are the dragged anchor point clamped to [0, 1] |
| Reset to style | `overrides = {}`, `position = null`, `positionByAspect = {}` |

The Case and Keep punctuation controls are disabled when `text.userOverridable` is false. Choosing another style keeps `overrides`, `position` and `positionByAspect`; the merged result is validated again (step 3).

All six accent swatches use the text-on-box contrast rule in section 2.3; Box highlight therefore draws black active text on Yellow, Green, Cyan, Pink, Paper and White, while retaining white on its default violet box.

### 2.5 Semantic rules (checked by `tools/captions/check_styles.py`)

- `font.file`, `font.fallbackFiles[]` and `emphasis.fontFile` exist in `fonts.json`; `font.family`, `font.weight` and `font.italic` equal the manifest values for `font.file`.
- `$accent` is used only when `accent` exists.
- Gradient stop offsets are ascending.
- `borderWidthEm > 0` requires `borderColor`.
- Only `words.active` may have a `box`.
- `reveal.cursor` requires `reveal.unit == "char"`.
- An emphasis with a source other than `none` has a visible effect (`fill`, `palette`, `fontFile` or `scale ≠ 1`).
- `preview.activeWord` is less than the number of words in `preview.text`.
- Every keyword in `emoji-keywords.json` names a bundled PNG.
- There are at least 17 styles, ids are unique and none is `off`.

---

## 3. Text

### 3.1 Input contract and normalisation steps

The caption engine consumes the edit model's caption copy (editing spec, section 7.6) for the output being rendered (the full edit or one clip), on the output timeline:

```text
CaptionInput {
  words:    [CaptionWord]        // kept words, sorted stably by start
  language: string               // BCP-47 tag of the transcript, e.g. "et", "en-US"
  duration: double               // output timeline duration in seconds
  width, height: int             // output frame size in pixels (after crop/scale)
}
CaptionWord {
  id: string
  text: string                   // corrected text if corrected, else the transcribed text; no transform
  start, end: double             // output seconds, end > start
  emphasis: bool | null          // manual emphasis (section 9.1); null = automatic
  emoji: string | null           // manual emoji code points (section 9.2)
}
```

`lang` below is the primary language subtag of `language`, lower-cased (`"en-US"` → `"en"`). Shaping receives the full tag.

For each word, the display text is computed by these steps, in order:

1. Normalise to NFC.
2. Collapse whitespace (3.2).
3. If `text.punctuation` is `strip-keep-numeric`, strip punctuation (3.3).
4. Apply `text.transform` with the case map (3.4).
5. Normalise to NFC again.
6. Collapse whitespace again.

A word whose display text is empty is not captioned. It stays in the edit and the timeline; it only has no caption page slot. The source text after steps 1 and 2 (the "raw text") is kept for the sentence and clause tests (3.5).

### 3.2 Whitespace

Whitespace is the Unicode White_Space set: U+0009–U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000. Collapsing removes leading and trailing whitespace and replaces every inner run of whitespace by one U+0020. A corrected word that contains spaces ("New York") stays one caption word and is never broken across lines.

### 3.3 Punctuation: `strip-keep-numeric`

`keep` leaves the text unchanged. `strip-keep-numeric` works on the Unicode scalars `c[0..n)` of the text:

- If the whole text matches `^(\p{L}\.){2,}$` (a dotted abbreviation such as `U.S.`, `e.g.`, `a.m.`), it is left unchanged.
- Otherwise each scalar `c[i]` whose General Category is P* (Pc, Pd, Ps, Pe, Pi, Pf, Po) is removed unless one of these holds, where `prev = c[i−1]` and `next = c[i+1]` in the original text (absent at the ends):
  1. `c[i]` is one of `% # @ &`.
  2. `c[i]` is one of `' ’ - ‐ ‑ – — . / ·` (U+0027, U+2019, U+002D, U+2010, U+2011, U+2013, U+2014, U+002E, U+002F, U+00B7) and both `prev` and `next` have category L* or N*.
  3. `c[i]` is `,` or `:` and both `prev` and `next` have category Nd.
  4. `c[i]` is `-` or `–` (U+002D, U+2013), `i = 0`, and `next` has category Nd (a sign).
- Scalars of any other category (letters, digits, symbols such as `$ € + ° ²`, emoji) are never removed.

Examples (all in `text-normalization.json`): `don't` → `don't`, `03:15.` → `03:15`, `$3.50,` → `$3.50`, `1,000` → `1,000`, `100%.` → `100%`, `“Hello,”` → `Hello`, `'cause` → `cause`, `U.S.` → `U.S.`, `10:30–11:00` → `10:30–11:00`, `-5` → `-5`, `well—` → `well`, `—` → (empty), `foo_bar` → `foobar`.

General Category comes from the platform (Swift `Unicode.Scalar.Properties.generalCategory`, C# `Rune.GetUnicodeCategory`). Both follow the UCD; the fixtures cover the characters that matter.

### 3.4 Case mapping

Do not call `String.uppercased()`, `lowercased()`, `ToUpper*` or `ToLower*`: they apply different mapping sets. Use `shared/caption-styles/casemap.json`:

- `upper` and `lower` are arrays of `[codePoint, mappedCodePoint]` pairs: the simple (1:1) mappings of UnicodeData.txt fields 12 and 13, Unicode 16.0.0. A code point not listed maps to itself.
- `rules` are applied before the table, per scalar:
  - uppercase, all languages: `ß` (U+00DF) → `SS`.
  - uppercase, `lang` ∈ {`tr`, `az`}: `i` (U+0069) → `İ` (U+0130).
  - lowercase, `lang` ∈ {`tr`, `az`}: `I` (U+0049) → `ı` (U+0131); `İ` (U+0130) → `i` (U+0069).
- `none` leaves the text unchanged.

### 3.5 Sentence and clause ends

Tested on the raw text (after steps 1 and 2 of 3.1, before stripping):

- Sentence end: the text matches `[.!?…。！？]["'”’)\]»]*$` and is not a dotted abbreviation (3.3).
- Clause end: the text matches `[,;:—–]["'”’)\]»]*$`.

### 3.6 Matching keys

Stopwords and emoji keywords are looked up by a matching key: the display text lower-cased with the case map (3.4, with `lang`), then with every scalar of category P* and every whitespace scalar removed. `Don't` → `dont`, `100%` → `100`, `“Väga` → `väga`.

### 3.7 Known limitations (v1)

- Greek all-caps keeps tonos (`σοφός` → `ΣΟΦΌΣ`); final sigma is not restored when lower-casing.
- Compatibility ligatures (`ﬁ`) are not decomposed.
- `Mr.` and similar abbreviations count as sentence ends.
- Right-to-left and complex scripts (Arabic, Hebrew, Indic, Thai, CJK) are not supported; their clusters are not covered by any bundled font and are dropped (4.4).

---

## 4. Fonts, shaping and measurement

### 4.1 Bundled fonts and the manifest

- Only the static TTFs in `shared/fonts` are used. They are SIL OFL 1.1 (fonts) and Apache-2.0 (emoji PNGs). Never load a system font, never fall back to the OS, never subset, rename or modify a font (several have Reserved Font Names: Righteous, Paytone One, DM Serif Display's "Source").
- `shared/fonts/fonts.json` is generated by `tools/captions/build_font_manifest.py`. Per font it records: `file` (unique across the folder), `path`, `family`, `style`, `weight` (nominal, from the style name), `usWeightClass` (raw), `italic`, `version`, `license`, `licenseFile`, `copyright`, `source` (repository, commit, URL), `bytes`, `sha256`, `unitsPerEm`, `hhea` and `os2` vertical metrics, `capHeight` (OS/2 `sCapHeight`, or the `H` glyph's `yMax` when absent), `xHeight`, `spaceAdvance` (advance of U+0020), `glyphCount`, `tables`, OpenType `features`, and `coverage` (the cmap as inclusive code point ranges).
- The builder rejects fonts with `fvar` (variable) or `trak` tables. Both apps verify `sha256` of each font at first use in debug builds and in tests.
- Apps read vertical metrics (`unitsPerEm`, `capHeight`) and `spaceAdvance` from the manifest, never from `CTFont` or `SKFontMetrics`.
- Loading: macOS `CGDataProvider(url:)` → `CGFont` → `CTFontCreateWithGraphicsFont(cgFont, size, nil, attributes)`; Windows `SKTypeface.FromFile` for outlines and HarfBuzzSharp `Blob.FromFile` → `Face` → `Font` for shaping.

### 4.2 Layout units

All fit and line-break decisions use integers. The layout unit (LU) is one design unit of the style's primary font (`font.file`), whose `unitsPerEm` is `U`. Widths are converted to pixels only for drawing: `px(u) = u · Fp / U`, with `Fp` the page's font size in pixels (5.3, 6.4).

### 4.3 Shaping

Each word is split into runs (4.4); each run is shaped on its own with these settings:

- Size: the font's `unitsPerEm` (advances come out in integer design units). HarfBuzz: `font.SetScale(upem, upem)` and the OpenType functions (`SetFunctionsOpenType()`). CoreText: create the `CTFont` at size `upem` with no matrix.
- Direction left-to-right. Script from the text (HarfBuzz `GuessSegmentProperties()`; CoreText decides itself). Language: the transcript's BCP-47 tag (HarfBuzz `buffer.Language`; CoreText `kCTLanguageAttribute`).
- Features: `kern`, `liga`, `calt` as `font.features` says (default on). Other default features stay at their defaults. HarfBuzz: pass `kern=0|1`, `liga=0|1`, `calt=0|1`. CoreText: `kCTFontFeatureSettingsAttribute` with `kCTFontOpenTypeFeatureTag` / `kCTFontOpenTypeFeatureValue` entries for the three tags; when `kern` is false, also set `kCTKernAttributeName` to `0.0`.
- Input: HarfBuzz `buffer.AddUtf32` (cluster values are scalar indices). CoreText reports UTF-16 string indices; convert them to scalar indices.
- CoreText: shape one run per `CTLine` built from an attributed string carrying exactly that font, with `kCTFontCascadeListAttribute` set to an empty array. Every resulting `CTRun` must use the requested font; anything else is a bug.
- Output per glyph: glyph id, x advance (integer; round CoreText advances with `roundHalfUp`), x and y offset, and the cluster (the index of the grapheme cluster it belongs to within the word, see 4.4).
- Never use `SKShaper` (SkiaSharp.HarfBuzz): it shapes at a fixed internal scale and rounds differently. Never use `SKFont.MeasureText` or any unshaped measurement (measured: up to 4.8% width error).

### 4.4 Font cascade (no system fallback)

For a word drawn with file `P` (the style font, or `emphasis.fontFile` for an emphasised word), the cascade is:

1. `P`
2. `font.fallbackFiles` in order
3. the Noto Sans file whose nominal weight is nearest to `P`'s nominal weight; ties choose the heavier file (`NotoSans-Regular` 400, `SemiBold` 600, `Bold` 700, `Black` 900; so 500 → SemiBold, 800 → Black). Italic primaries use the upright file.

Split the display text into extended grapheme clusters (UAX #29: Swift `Character`, C# `StringInfo.GetTextElementEnumerator`). For each cluster, ignoring U+200C, U+200D and U+FE00–U+FE0F ("ignorables"):

- If only ignorables remain, drop the cluster.
- Choose the first cascade font whose `coverage` contains every remaining scalar; if none does, the first that contains the first remaining scalar; if none does, drop the cluster.
- Remove from the cluster any non-ignorable scalar the chosen font does not cover.

Consecutive clusters with the same chosen font form a run. Each run is shaped separately; there is no kerning across run boundaries. If every cluster of a word is dropped, the word is not captioned. The app shows the inspector note "Some characters can't be shown in this caption style." when any cluster was dropped in the current output.

### 4.5 Word width

For a word with runs `r` and `g` glyphs in total:

```text
runLU(r)  = Σ advances of r                                   if upem(r) == U
          = floor((2 · Σadv · U + upem(r)) / (2 · upem(r)))   otherwise (integer round half up)
ls        = roundHalfUp(font.letterSpacingEm · U)
base      = Σ runLU + (g − 1) · ls
width(w)  = base                          for a normal word
          = roundHalfUp(base · emphasis.scale)   for an emphasised word (section 9.1)
```

Letter spacing is added after every glyph of the word except the last.

### 4.6 Word gap

```text
gap = roundHalfUp(font.wordSpacingEm · U)        if wordSpacingEm is present
    = spaceAdvance(font.file) + ls               otherwise
```

The gap is never scaled by emphasis.

### 4.7 Vertical metrics

`cap = capHeight(font.file) / U · Fp` px. Line height `L = font.lineHeightEm · Fp`. Baselines are placed by cap-height centring (7.4), independent of ascender, descender and line gap.

---

## 5. Frame

### 5.1 Aspect class

With integer arithmetic: `portrait` if `10·W < 9·H`; `landscape` if `9·W > 10·H`; otherwise `square`. (4:5 is portrait, 4:3 is landscape.)

### 5.2 Safe area

Captions are clamped into the safe rectangle `[W·left, W·(1−right)] × [H·top, H·(1−bottom)]`:

| Class | left | right | top | bottom |
|---|---|---|---|---|
| portrait | 0.06 | 0.06 | 0.06 | 0.10 |
| square | 0.05 | 0.05 | 0.05 | 0.07 |
| landscape | 0.05 | 0.05 | 0.05 | 0.07 |

Platform UI guides are shown in the preview only while dragging; they do not clamp: portrait top 0.12, bottom 0.22, right 0.12 (Reels, TikTok and Shorts controls); square bottom 0.12; landscape bottom 0.10 (player controls).

### 5.3 Font size

```text
R   = min(W, H)  if font.sizeRef == "shortEdge" (default)
    = H          if "height"
    = W          if "width"
F64 = max(1, roundHalfUp(font.sizeSh · R · font.sizeScale · 64))     // 1/64 px, Int64
F   = F64 / 64
```

All lengths in a style are in em (multiples of the page's `Fp`) or fractions of `W` and `H`. Captions never depend on the preview or window size.

### 5.4 Line width limit and the fit test

```text
padX0   = box.paddingXEm · F    if box.scope ∈ {page, line}, else 0
limitPx = min(layout.maxLineWidthW · W, (W·(1−right) − W·left) − 2 · padX0)
limit64 = floor(limitPx · 64)                                     // Int64
fits(u) ⇔ u · F64 ≤ limit64 · U                                   // Int64 comparison
```

Example (`karaoke-portrait-en`): `F64 = roundHalfUp(0.062·1080·1·64) = roundHalfUp(4285.44) = 4285`, `limitPx = min(907.2, 950.4) = 907.2`, `limit64 = 58060`; the first line "SO HERE'S THE" is 7345 LU and fits because 7345·4285 ≤ 58060·1000.

---

## 6. Pages and lines

A page is the group of words shown together. Paging and line breaking run on the normalised, measured words (empty and uncoverable words removed), in input order.

### 6.1 Paging

```text
pages = []; cur = []
for each word w (index i):
  if cur is not empty:
    prev = last word of cur; first = first word of cur
    newPage = len(cur) ≥ layout.maxWords
           or (layout.breakOnSentence and sentenceEnd(prev.raw))
           or (layout.breakOnComma and len(cur) ≥ 2 and clauseEnd(prev.raw))
           or (layout.breakOnGapSec ≠ null and w.start − prev.end ≥ layout.breakOnGapSec)
           or (layout.maxPageSec ≠ null and w.end − first.start > layout.maxPageSec)
           or not pageFits(cur + [w])
    if newPage: pages.append(cur); cur = []
  cur.append(w)
if cur is not empty: pages.append(cur)
```

Cut seams do not force a page break (section 18, D9).

### 6.2 Page fit

`pageFits(ws)`: break `ws` into lines (6.3) using paging widths; it fits when the number of lines is at most `layout.maxLines` and either `ws` has exactly one word or every line fits (5.4). A single word that is wider than the limit is therefore always alone on its page (it is shrunk, 6.4).

The paging width of a word that may be emphasised (an emphasis candidate, 9.1) is `max(width as normal, width as emphasised)`; otherwise it is its normal width. This makes paging independent of which candidates the page finally emphasises.

### 6.3 Line breaking

Input: widths `w[0..n)` (LU) and `gap`. `units(line) = Σ w + gap · (count − 1)`.

1. Greedy: put word 0 on line 0; for each next word, if `fits(units(current line) + gap + w[i])` append it, else start a new line.
2. Balanced: if `layout.balance == "balanced"`, the greedy result has 2 or 3 lines, and every greedy line fits, then consider every split of the words into the same number `m` of consecutive non-empty lines in which every line fits; choose the split with the smallest maximum line width; ties go to the lexicographically smallest list of break indices (earlier breaks, so the top line is the shorter one).
3. Otherwise keep the greedy result.

The final layout of a page breaks lines again with the actual widths (emphasised words at their emphasised width).

### 6.4 Shrinking a single overlong word

If a page has exactly one word and `fits(width)` is false:

```text
Fp64 = max(ceil(F64 · layout.minShrink), min(F64, floor(limit64 · U / width)))   // integer division
```

Otherwise `Fp64 = F64`. `Fp = Fp64 / 64` is the page's font size: every em quantity of that page (line height, padding, radius, stroke, shadows, emoji, cursor) uses `Fp`. If the word still does not fit at `minShrink`, it is drawn wider than the safe area and centred in it (7.3); it is never broken.

---

## 7. Placement

All coordinates are output pixels, origin top-left, y down.

### 7.1 Block and visual rectangle

```text
lineW[i] = px(units(line i))          blockW = max lineW
L        = font.lineHeightEm · Fp      pitch  = L + layout.lineGapEm · Fp
blockH   = L + (lines − 1) · pitch
padX, padY = box.paddingXEm · Fp, box.paddingYEm · Fp   if box.scope ∈ {page, line}, else 0
visual   = blockW + 2·padX  by  blockH + 2·padY
```

The visual rectangle is what is anchored, clamped and used for hit-testing the drag handle.

### 7.2 Anchor

`P = (position.x · W, position.y · H)`.

```text
vx = P.x − vw/2 (anchorX center) | P.x (left) | P.x − vw (right)
vy = P.y − vh/2 (anchorY center) | P.y (top)  | P.y − vh (bottom)
```

The default anchor is the block centre (`center`, `center`), the VoxConvo web preview convention.

### 7.3 Clamping

If the page has an emoji (9.2), `E = roundHalfUp(emoji.sizeEm · Fp)` and the provisional emoji rectangle is `x = vx + vw/2 − E/2`, `y = vy − emoji.gapEm · Fp − E`, size `E×E`. The clamp rectangle `C` is the visual rectangle, united with the emoji rectangle when present. The emoji takes part in clamping but not in anchoring, so pages with and without an emoji share the anchor.

For each axis, with `[lo, hi]` the extent of `C` and `[s0, s1]` that of the safe area:

```text
shift = (s0 + s1)/2 − (lo + hi)/2   if hi − lo > s1 − s0
      = s0 − lo                     if lo < s0
      = s1 − hi                     if hi > s1
      = 0                           otherwise
```

### 7.4 Snapping, lines and words

```text
bx = roundHalfUp(vx + shiftX + padX)          by = roundHalfUp(vy + shiftY + padY)   // block origin
visual = (bx − padX, by − padY, vw, vh)
line i:  top = by + i · pitch
         baseline = top + L/2 + cap/2
         lineX = bx + (blockW − lineW[i])/2   (align center)
               = bx                           (left)
               = bx + blockW − lineW[i]       (right)
word j on line i: x = lineX + px(Σ_{k<j} (w[k] + gap)),  width = px(w[j])
         rect = (x, top, width, L);  centre = (x + width/2, baseline − cap/2)
emoji:   x = roundHalfUp(bx − padX + vw/2 − E/2),  y = roundHalfUp(by − padY − emoji.gapEm·Fp − E)
```

Only the block origin and the emoji origin are snapped. Glyph positions stay fractional.

Glyphs of a word are placed from its origin `(x, baseline)` with a pen that starts at 0: glyph `k` is drawn at `(x + s·(pen + dx_k·Fp/u_k), baseline − s·dy_k·Fp/u_k)`, then `pen += adv_k·Fp/u_k`, plus `ls·Fp/U` if `k` is not the last glyph. `u_k` is the `unitsPerEm` of the glyph's font and `s` is `emphasis.scale` for an emphasised word, else 1. Layout always uses the integer width of 4.5, so the drawn width may differ from it by less than one LU.

Layout is computed with every word of the page present, also for reveal styles, so words never move as they appear.

### 7.5 Boxes

| Scope | Rectangle | Transform (11.3) |
|---|---|---|
| `page` | the visual rectangle | page |
| `line` | `(lineX − padX, top − padY, lineW + 2·padX, L + 2·padY)` per line | page |
| `word` | `(x − pX, top − pY, width + 2·pX, L + 2·pY)` per visible word, `pX/pY` from `box` | page × word |
| active word (`words.active.box`) | as `word`, with that box's padding | page × word |

Radius: `h/2` if `pill`, otherwise `min(radiusEm · Fp, w/2, h/2)`. Boxes are rounded rectangles built from Béziers (12.1). Line boxes are added to one path and filled once with the nonzero rule; so are word boxes. Overlapping line boxes (for example `clean-subtitle`, where boxes overlap by `2·paddingY − lineGap`) therefore never double their alpha. A border (`borderWidthEm > 0`) strokes the rectangle inset by `bw/2` on every side, radius `max(0, r − bw/2)`, line width `bw = borderWidthEm · Fp`, in `borderColor`, right after that box's fill.

### 7.6 Output size and preview scaling

A `CaptionTrack` is built for the output frame size `W×H` of the current aspect and quality (the size written to the file). The preview renders at `w'×h'` with the same aspect, and draws the track under the uniform scale `k = w'/W` applied as the outermost transform. Pixel quantities computed at draw time (blur sigma, emoji size) are computed in preview pixels: `σ' = σ·k`, `E' = roundHalfUp(E·k·pageScale)`.

---

## 8. Timing

### 8.1 Page intervals

```text
start = first word.start
end   = last word.end + layout.holdGapSec
if there is a next page: end = min(end, next page start)
if end − start < layout.minPageSec:
    end = start + layout.minPageSec
    if there is a next page: end = min(end, next page start)
end = min(end, duration)
```

A page is visible on `[start, end)`. Pages never overlap. A page with `end ≤ start` is never visible. With `maxWords 1`, `holdGapSec 0` and `minPageSec 0` (the VoxConvo styles) each word shows exactly while it is spoken.

### 8.2 Visible page, active word, states

- At time `t` the visible page is the one with `start ≤ t < end`, if any (binary search). Nothing is drawn otherwise.
- The active word is the last word of the page with `start ≤ t`. It stays active through gaps inside the page and through the hold after the last word.
- Words before the active one (in page order) are `past`, words after it are `future`.
- Word progress: `p = clamp((t − start) / max(0.001, end − start), 0, 1)`.

### 8.3 Frame times

- Export: constant frame rate `fpsNum/fpsDen`; frame `i` is drawn at `t = Double(i · fpsDen) / Double(fpsNum)` (the integer product first). On macOS the composition's `frameDuration` is `CMTime(value: fpsDen, timescale: fpsNum)`, so `request.compositionTime.seconds` gives the same double.
- Preview: the player's current output time in seconds (`compositionTime` on macOS, the edited presentation time on Windows).

---

## 9. Emphasis and emoji

### 9.1 Emphasis

Points of a word (integers), from its display text:

```text
letters = number of scalars with category L* or N*
points  = 300 · (any scalar is Nd) + 100 · (letters ≥ 6) + 100 · (matching key is not a stopword of lang) + min(letters, 99)
```

`stopwords.json` holds lists for `en` and `et`; a language without a list has no stopwords. `minPoints = roundHalfUp(emphasis.minScore · 100)`.

A word is a candidate if `emphasis.source ≠ none` and either its manual flag is true, or its manual flag is null, `source` is `rule` or `llm` (v1 treats `llm` as `rule`), and `points ≥ minPoints`. A manual flag of false excludes the word.

Per page, after paging: the emphasised words are all manually emphasised words of the page, plus the remaining rule candidates sorted by `(points descending, index ascending)`, up to `maxPerPage` in total. When `emphasis.palette` exists, emphasised words take palette colours in caption order (pages in order, words in order within a page), cycling over the whole track.

An emphasised word is measured and drawn with `emphasis.fontFile` (if set) and scaled by `emphasis.scale` (4.5, 7.4). Its fill is the palette colour, else `emphasis.fill` (10.2).

M1 has no UI for manual emphasis; the input field exists for fixtures and a later project version.

### 9.2 Emoji

Only when `emoji.enabled`. Per page, in page order, with `prev` the emoji of the previous page (or none):

1. The first word of the page with a manual emoji gets it.
2. Otherwise, if `emoji.maxPerPage ≥ 1` and `emoji.source` is `rule` or `llm`: the first word whose matching key maps to an emoji other than `prev` gets it.
3. `prev` becomes this page's emoji, or none.

Lookup in `emoji-keywords.json` for `lang`: an exact key wins; otherwise keys ending in `*` match any key that starts with the part before `*` (at least 3 characters); the longest such prefix wins, ties by the smaller prefix string. Values name `shared/fonts/noto-emoji/png128/emoji_u<value>.png`. A language without a table has no rule emoji.

Emoji are images, never text: they are drawn only through this layer (13.7). An emoji typed into a word is dropped by the font cascade (no bundled font covers it).

---

## 10. Word appearance

### 10.1 State properties

`words.past`, `words.active` and `words.future` may set:

| Property | Effect |
|---|---|
| `fill` | the word's paint (10.2) |
| `opacity` | multiplies the word's opacity |
| `scale` | drawn about the word centre (11.3); never changes layout |
| `strokeColor` | replaces `stroke.color` for the word |
| `hideStroke` | no stroke for the word |
| `box` (active only) | the active word box (7.5) |

### 10.2 Fill precedence

The paint of a word is, in increasing priority: `fill`; the state's `fill`; for an emphasised word the palette colour, else `emphasis.fill`.

### 10.3 Reveal units

| `reveal.unit` | Visible words | Active word |
|---|---|---|
| `page` | all | drawn normally |
| `word` | past and active; future words are not drawn | drawn normally |
| `char` | past (all clusters) and active (revealed clusters, 10.5); future not drawn | partially drawn, cursor |
| `wipe` | all | 10.4 wipe |

A word that is not drawn has no box, shadow, stroke or fill. Boxes of page and line scope are always drawn in full.

### 10.4 Wipe and gradients

Wipe (karaoke): the active word is drawn in two passes, after its stroke. First its fill in the paint it would have as `future`; then, clipped to the rectangle `[x − Fp, x + p·width] × [top − Fp, top + L + Fp]` in page coordinates before the word transform, its fill in its `active` paint. When `p = 1` the second pass is unclipped. Past words use their `past` paint.

Linear gradients (`paint.type == "linear"`): the gradient rectangle is the word rectangle (`space: word`), the line rectangle `(lineX, top, lineW, L)` (`line`) or the block rectangle (`page`), in page coordinates; it is drawn under the same transforms as the glyphs. With `θ = angleDeg` in radians, direction `d = (cos θ, sin θ)` (0° left to right, 90° top to bottom), centre `c`, `half = (w/2)·|cos θ| + (h/2)·|sin θ|`: the gradient runs from `c − d·half` (offset 0) to `c + d·half` (offset 1), interpolates the gamma-encoded colours linearly, and pads beyond the ends (CG `drawsBeforeStartLocation | drawsAfterEndLocation`, Skia `SKShaderTileMode.Clamp`). Vectors in `math.json`.

### 10.5 Typewriter (`reveal.unit == "char"`)

For the active word with `n` grapheme clusters (after the cascade, 4.4):

```text
dur       = min(end − start, n / reveal.maxCharsPerSec)
cluster k (0-based) is visible when t ≥ start + (k / n) · dur
```

Only glyphs of visible clusters are drawn. The cursor (`reveal.cursor`), drawn after all fills with the page transform in `cursor.color`:

```text
pen    = advance in px (scaled by s) from the word origin to the end of the last glyph whose cluster is visible,
         including letter spacing between those glyphs and not after the last; 0 if none is visible
x      = word.x + pen + 0.05·Fp           width  = cursor.widthEm · Fp
y      = baseline − cap − 0.1·Fp          height = cap + 0.2·Fp
shown  = t < start + dur  or  blinkHz == 0  or  floor((t − (start + dur)) · blinkHz · 2) mod 2 == 0
```

---

## 11. Animation

### 11.1 Progress

`progress(t, t0, d) = 1 if d ≤ 0, else clamp((t − t0)/d, 0, 1)`.

### 11.2 Easing and kinds

Polynomials only, identical on both platforms. Each function is evaluated on `p` clamped to [0, 1] and returns exactly 0 at `p = 0` and exactly 1 at `p = 1`; the formulas apply strictly between:

```text
linear(p)          = p
easeOutCubic(p)    = 1 − (1 − p)^3
easeInOutCubic(p)  = p < 0.5 ? 4p^3 : 1 − (−2p + 2)^3 / 2
easeOutBack(p; c)  = 1 + (c + 1)(p − 1)^3 + c (p − 1)^2      // c = anim.overshoot
```

For an entrance (`pageIn` with `t0 = page.start`, `wordIn` and `activeIn` with `t0 = word.start`), `e = ease(progress(t, t0, durationSec))` and `target` is 1 (for `activeIn`: `words.active.scale`, default 1):

| type | scale | alpha | dy |
|---|---|---|---|
| `none` | target | 1 | 0 |
| `fade` | target | clamp(e, 0, 1) | 0 |
| `pop` | fromScale + (target − fromScale)·e | 1 | 0 |
| `zoom` | fromScale + (target − fromScale)·e | clamp(e, 0, 1) | 0 |
| `slide-up` | target | clamp(e, 0, 1) | fromOffsetEm·Fp·(1 − e) |

For `pageOut`, `e = ease(progress(t, page.end − d, d))`:

| type | scale | alpha | dy |
|---|---|---|---|
| `fade` | 1 | clamp(1 − e, 0, 1) | 0 |
| `pop` | 1 + (fromScale − 1)·e | 1 | 0 |
| `zoom` | 1 + (fromScale − 1)·e | clamp(1 − e, 0, 1) | 0 |
| `slide-up` | 1 | clamp(1 − e, 0, 1) | −fromOffsetEm·Fp·e |

`easeOutBack` overshoots, so `pop` scales pass the target and come back. Vectors in `math.json`.

### 11.3 Transforms and opacity

```text
pageScale = in.scale · out.scale        pageAlpha = in.alpha · out.alpha        pageDy = in.dy + out.dy
T_page = translate(jitter.dx, jitter.dy + pageDy) · translate(c) · scale(pageScale) · translate(−c)
         c = block centre (bx + blockW/2, by + blockH/2)

per word:
  stateScale = state.scale (default 1); for the active word activeIn's target is stateScale
  (wS, wA, wDy) = wordIn entrance for past and active words; (1, 1, 0) for future words
  (aS, aA, aDy) = activeIn entrance for the active word; (stateScale, 1, 0) otherwise
  scale   = aS · wS          opacity = state.opacity (default 1) · wA · aA          dy = wDy + aDy
  T_word = translate(0, dy) · translate(wc) · scale(scale) · translate(−wc)      wc = word centre (7.4)
```

Glyphs, strokes, word boxes and the wipe clip use `T_page · T_word`; page and line boxes, the cursor and the emoji use `T_page`. Stroke widths and blur radii are given in page coordinates and scale with the transforms (σ by `pageScale`, not by the word scale). `pageAlpha` is applied to the whole caption overlay as a group (13.3); word `opacity` multiplies each drawing operation of that word.

### 11.4 Jitter

When `effects.jitter` exists:

```text
k  = floor(t · rateHz + 1e-6)
r  = mulberry32((seed XOR k) mod 2^32)
dx = (r() · 2 − 1) · amplitudeEm · Fp
dy = (r() · 2 − 1) · amplitudeEm · Fp       // second draw
```

mulberry32 with explicit unsigned 32-bit arithmetic:

```swift
struct Mulberry32 {
    var state: UInt32
    mutating func next() -> Double {
        state &+= 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}
```

```csharp
struct Mulberry32 {
    uint state;
    public Mulberry32(uint seed) { state = seed; }
    public double Next() { unchecked {
        state += 0x6D2B79F5;
        uint t = state;
        t = (t ^ (t >> 15)) * (t | 1);
        t = (t + ((t ^ (t >> 7)) * (t | 61))) ^ t;
        return (t ^ (t >> 14)) / 4294967296.0;
    } }
}
```

These match the JavaScript original bit for bit (verified; vectors in `math.json`: seed 1 gives 0.6270739405881613, 0.002735721180215478, ...).

### 11.5 Reduce Motion

When the OS Reduce Motion setting is on, the preview and gallery tiles use: every entrance at `p = 1`, no `pageOut`, no jitter, and a cursor that is always shown. Reveal timing (`word`, `char`, `wipe`) is unchanged because it follows speech. Export always renders full motion.

---

## 12. Geometry

### 12.1 Rounded rectangles

Built from explicit path commands on both platforms (never `CGPath(roundedRect:)`, `addRoundedRect`, `SKRoundRect` or `SKPath.AddRoundRect`, which use different curve types). With `r = min(r, w/2, h/2)`, `k = 0.5522847498 · r`, clockwise in y-down coordinates:

```text
r ≤ 0: M(x, y) L(x+w, y) L(x+w, y+h) L(x, y+h) Z
r > 0: M(x+r, y)
       L(x+w−r, y)      C(x+w−r+k, y,      x+w, y+r−k,      x+w, y+r)
       L(x+w, y+h−r)    C(x+w, y+h−r+k,    x+w−r+k, y+h,    x+w−r, y+h)
       L(x+r, y+h)      C(x+r−k, y+h,      x, y+h−r+k,      x, y+h−r)
       L(x, y+r)        C(x, y+r−k,        x+r−k, y,        x+r, y)  Z
```

Zero-length line segments are kept. Vectors in `math.json`.

### 12.2 Glyph outlines

Get each glyph's outline in design units (macOS `CTFontCreatePathForGlyph` on a font created at size `unitsPerEm`, which is y-up; Windows `SKFont(typeface, unitsPerEm).GetGlyphPath`, y-down, with `Hinting = None`, `Subpixel = true`, `LinearMetrics = true`, `Embolden = false`, `ForceAutoHinting = false`). Scale by `s·Fp / unitsPerEm` (flipping y on macOS) and translate to the glyph position (7.4). Fill with the nonzero rule. No hinting, no font smoothing, no LCD antialiasing. Outlines may be cached per `(font file, glyph id)`.

---

## 13. Rendering

### 13.1 Surfaces and colour

- The caption overlay is an 8-bit premultiplied RGBA (or BGRA) image in gamma-encoded sRGB. Blending is source-over on gamma-encoded values; nothing is linearised and nothing is colour-managed.
- macOS: `CGContext` with `CGColorSpace(name: CGColorSpace.sRGB)`, `premultipliedFirst | byteOrder32Little`, antialiasing on; colours created in the same colour space (no conversion happens). When drawing directly into the compositor's BGRA output buffer, wrap it the same way. If Core Image is involved, its working colour space is non-linear sRGB or `NSNull`.
- Windows: `SKSurface` over `SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul)` with no colour space (legacy, non-linear blending); `SKPaint.IsAntialias = true`.
- Caption colours are written into the frame's R′G′B′ values unchanged; the frame is converted to Y′CbCr with the BT.709 matrix, limited range (export spec). A white `#FFFFFF` caption therefore encodes as Y′ 235.
- The overlay covers the full frame or a band around the page's bounding box; the result must be identical either way.

### 13.2 Blur

Shadows and glows use our own blur on an 8-bit alpha mask. Never use `CGContext.setShadow`, `CIGaussianBlur`, `SKImageFilter.CreateBlur` or `SKMaskFilter`. Separable: horizontal pass over every row, then vertical pass over every column, same algorithm, values outside the buffer are 0. The mask buffer extends `ceil(3σ) + 3` px beyond the geometry on every side so nothing is clipped. `σ` is in pixels (`sigmaEm · Fp · pageScale`, times `k` in the preview).

- `σ = 0`: no blur.
- `0 < σ < 2`: exact Gaussian. `r = ceil(3σ)`, weights `w_j = exp(−j²/(2σ²))` for `j = −r..r`, divided by their sum. `out[x] = clamp(roundHalfUp(Σ_j w_j · in[x+j]), 0, 255)`, computed in doubles, stored as 8 bits after each pass.
- `σ ≥ 2`: three box passes per axis (SVG 1.1 feGaussianBlur). `d = floor(σ · 3 · sqrt(2π) / 4 + 0.5)`. A box pass over the window `[x+lo, x+hi]`, `n = hi − lo + 1`, is `out[x] = floor((2·S + n) / (2·n))` with `S` the integer sum of the window. If `d` is odd, the three windows are `[−(d−1)/2, (d−1)/2]` each. If `d` is even, they are `[−d/2, d/2 − 1]`, `[−d/2 + 1, d/2]` and `[−d/2, d/2]` (the last has width `d + 1`). All integer arithmetic.

Kernels, box sizes and blurred rows are in `math.json`. The box path costs the same for any σ, which keeps wide glows (neon) cheap.

### 13.3 Draw order

For the visible page at time `t`, in this order (all geometry under its transform, 11.3; hidden words and hidden clusters skipped, 10.3):

1. Page box.
2. Line boxes (one path, nonzero fill).
3. Word boxes of `box.scope == "word"` (one path, nonzero fill), then borders.
4. Active word box (`words.active.box`).
5. Shadows, in array order (13.5).
6. RGB split (13.6).
7. Strokes of all visible words except the active one.
8. Fills of all visible words except the active one.
9. Stroke of the active word.
10. Fill of the active word (with the wipe, 10.4).
11. Cursor (10.5).
12. Emoji (13.7).

The whole overlay is then composited onto the video frame with `pageAlpha` as group opacity: macOS `beginTransparencyLayer` after `setAlpha(pageAlpha)`, Windows `SaveLayer` with an alpha paint, or an equivalent offscreen layer multiplied by `pageAlpha`. When `pageAlpha == 1` the overlay may be drawn straight into the frame.

Drawing the active word last puts it above its neighbours when its scale makes it overlap them.

### 13.4 Strokes, fills and clips

- Stroke: the glyph outlines stroked with line width `stroke.widthEm · Fp` (full width, centred on the outline, so `widthEm/2` shows outside the glyph because the fill covers the inner half), round joins, round caps, colour `strokeColor` or `stroke.color`, alpha multiplied by the word opacity.
- Fill: nonzero rule, the word's paint (10.2), alpha multiplied by the word opacity.
- Clips (wipe) are antialiased: macOS `clip(to:)`, Windows `ClipRect(rect, SKClipOperation.Intersect, antialias: true)`.

### 13.5 Shadows

For each entry of `shadows`:

1. Render an alpha mask on the overlay's pixel grid: for every visible word, its fill outlines and, unless the word hides its stroke, its stroke outlines, drawn with source-over at alpha `word opacity`, under `T_page · translate(dxEm·Fp, dyEm·Fp) · T_word` (the offset is in page coordinates, so it scales with `pageScale`; fractional offsets are handled by the rasterizer, bitmaps are never shifted).
2. Blur the mask (13.2) with `σ = sigmaEm · Fp · pageScale`.
3. Composite the shadow colour, premultiplied and multiplied by `mask/255`, source-over onto the overlay.

Windows x64 draws the Alpha8 mask with its colour paint directly. Its native Skia source-over path fuses tint and blending; precolouring a separate BGRA image changes overlapping shadow channels by up to two levels. Other renderer architectures may precolour a retained shadow image when their pixels match the direct path. Both paths reuse their buffers and retain the same output contract.

### 13.6 RGB split

When `effects.rgbSplit` exists, for every visible word draw its fill outlines in `leftColor` translated by `(−offsetEm·Fp, 0)` and then in `rightColor` translated by `(+offsetEm·Fp, 0)` (page coordinates), source-over, alpha multiplied by the word opacity.

### 13.7 Emoji images

The 128×128 PNG is decoded to straight RGBA and premultiplied. Target size `E' = roundHalfUp(E · pageScale · k)`; the target centre is `T_page` applied to the emoji rectangle's centre, and the target origin is `roundHalfUp(centre − E'/2)` on each axis. Resample with our own filter into an `E'×E'` premultiplied image, then copy it source-over at the integer origin without any further filtering:

- `E' ≤ 128`: area average. Target pixel `(i, j)` covers source `[i·128/E', (i+1)·128/E') × [j·128/E', (j+1)·128/E')`; its value is the area-weighted mean of the premultiplied source pixels it overlaps, `roundHalfUp` per channel.
- `E' > 128`: bilinear on premultiplied values with pixel-centre alignment: source coordinate `(i + 0.5)·128/E' − 0.5`, clamped to `[0, 127]`.

The emoji is drawn with the page's group alpha (13.3).

### 13.8 Platform notes

macOS (`VoxClipMedia`): the compositor draws captions after Core Image has written the cropped, scaled video into the output pixel buffer, by wrapping that buffer in a `CGContext` (13.1) with a y-flip (`translateBy(0, H)`, `scaleBy(1, −1)`) so that all coordinates in this spec apply unchanged. Text is never drawn with Core Text drawing calls; Core Text only shapes and supplies outlines.

Windows (`VoxClip.Media`): the compose function draws into an `SKSurface` that wraps the BGRA frame buffer (13.1). The renderer, the shaper and the tests also run on macOS (`SkiaSharp.NativeAssets.macOS`, `HarfBuzzSharp.NativeAssets.macOS`) so CI can compare the two platforms directly (16.6).

### 13.9 Caching and performance

- Layout is computed once per `(CaptionInput, resolved style, W, H)` and kept until one of them changes.
- A page's rendered overlay may be cached when nothing time-dependent is in progress: no entrance or exit animation running, no jitter, no wipe in progress, no cursor, and the same active word and visible cluster counts. Cache key: `(page index, style hash, W×H, k, active word, visible cluster counts)`. LRU, at most 64 MiB per window. A cached frame must be pixel-identical to an uncached one.
- The Windows renderer retains glyph paths for at most eight recent pages per live track. Repeated draws on those pages reuse the paths and their LRU nodes. Revisiting an evicted page rebuilds its paths.
- A stable frame (one the cache could hold) is always flattened into a transparent band and composited onto the target with one source-over, whether or not the cache holds that band. A cached frame is therefore pixel-identical to an uncached one on any target, transparent or video. Animated frames are drawn directly.
- Reused render state (scratch buffers, masks, canvases, the cache) must stay consistent when a render throws or is cancelled: a later frame never shows another frame's pixels and never fails because of the earlier error.
- Memory: the band cache is at most 64 MiB per window, and scratch memory is bounded by the largest frame drawn, never by the number of pages or tracks drawn. Across aspect switches, a retained scratch bitmap's pixel count must not exceed that of the largest frame drawn.
- The Windows shadow views and opacity band grow to the largest required width and height while the output dimensions stay fixed, then reuse those dimensions for smaller frames. On an output size change, shadow views are reset and the opacity band starts at the new required size so two aspects cannot combine into an oversized retained bitmap.
- Budget, at 1080×1920 with the box blur on an M1 or a 2022 mid-range Windows laptop: every frame after a page's first renders in under 4 ms, with or without the band cache; the first frame of a page, which builds that page's outlines and shadow masks, renders in under 10 ms. A renderer loads and parses its fonts and style resources once, and that one-time setup is not part of either budget. Animated frames are rendered directly.
- Acceptance runs on a quiet machine (one-minute load average below 2) and takes the best p95 of three passes per style and mode. On the M3 Max development machine the gates are 3.0 ms and 7.5 ms. The page-first pass reuses one renderer whose resources are already loaded, so it times page geometry, not setup.

---

## 14. App integration

`CaptionLine.words` holds indices into the track's full list of captioned words, not offsets within the page. SRT output uses that same list across pages. A compatibility track without a usable full list falls back to the page's own words instead of indexing outside the list.

- Off: `styleId == "off"` (the first gallery tile, "Just the video"). No caption pass; cuts and every other export setting still apply.
- Captions are drawn while paused and while scrubbing, at the playhead's output time.
- Dragging: the handle is the visual rectangle of the page visible at the playhead; when no page is visible, the next page's (or the previous page's, at the end) layout is used and drawn as an outline only. The dragged anchor point is written as in 2.4. Snapping to `x = 0.5` and `y ∈ {1/3, 2/3}` is a UI aid (design.md); the stored value is the snapped value. Rendering always clamps to the safe area (7.3), so a stored position outside it renders inside it.
- Size, case, words, punctuation, colour and position controls: 2.4.
- SRT sidecar (when "Burn in + .srt" is chosen): one cue per page with `end > start`, on the output timeline, `HH:MM:SS,mmm --> HH:MM:SS,mmm` with times rounded half up to milliseconds, numbered from 1, UTF-8 without BOM, LF line endings. Cue text is the page's words built with `transform: none` and `punctuation: keep` from the same pages (same grouping), joined with U+0020 within a line and LF between the page's lines.

---

## 15. Style gallery

### 15.1 Contents

The gallery shows Off first, then every style in `shared/caption-styles/styles/` sorted by `order`, ties by id. The tile label is `name`; the accessibility label is `"<name>: <description>"`.

### 15.2 Tile rendering

A tile renders the real style through the real rasterizer at the current export aspect's output size, scaled down (7.6). The tile's size, the backdrop under the caption and its dimming are design.md's (section 6.1): the band of the current frame behind the style's caption position, dimmed 35%, or with no frame the caption card backdrop (design.md section 5.4.3), not dimmed. A tile that cannot render draws exactly the backdrop it would have had: the band of the current frame dimmed 35%, or the card backdrop (design.md section 5.4.3) when there is no frame, and stage black in the loading states (design.md section 5.4.4). It never draws text.

The sample words are the caption page at the playhead, with the text as stored (transform none), or the style's `preview.text` when the scope has no caption words or Settings hides transcript words (15.3). A tile never shows the project title.

### 15.3 Tile state

The tile is the caption state at a fixed moment. Each Core decides it once, as `CaptionGallerySample` (VoxClipCore and VoxClip.Core), from the project, the scope (the edited take or a clip), the playhead in the scope's edited time, the library style and the caption resources.

- **Sample.** Page words keep their caption-copy ids; preview words have ids `preview-{i}`, starting at `preview-0`. The `n` sample words are timed `[0.4·i, 0.4·i + 0.35]` seconds and carry no emphasis or emoji hints, so the style's own rules apply as in export. The track duration is `0.4·n + 0.5`. The state is evaluated with Reduce Motion rules (11.5), so animations are at rest.
- **Page.** The scope's export captions (the caption copy, editing spec 7.6) are normalised and covered as in 3.1 and 4.4, and a word left with nothing is skipped. They are paged by 6.1 in the style resolved at the project's export frame. Only the selected tile (`style.id == project.captions.styleId`) uses the project's `captions.overrides` (2.4; a rejected patch is ignored); every other tile uses empty overrides. Captions off matches no tile. Paging runs without the fit test of 6.2, which needs glyph widths. Pages are visible on their 8.1 intervals over the scope's edited duration. The sample is the page visible at the playhead (8.2); in a gap between pages or before the first page it is the next page, and after the last page the last page. A playhead that is not finite counts as 0. The renderer pages the sample again at the tile's timing. Even without the 6.2 fit, the renderer splits an overlong page at that timing (for example with the Line override); the fit can split it further. The tile shows the part containing the drawn word. In the key-word case this may be the key word's part rather than the playhead's part. This is a known, accepted limit.
- **Moment on a page.** When the page is visible and the playhead is inside its active word `a` (8.2: the last word that has started, until that word ends), `t = 0.4·a + 0.35·0.98`. Otherwise `t` is the caption card's drawn moment for the page (design.md section 5.4.2): 0.35 × 0.98 s into its key word, or, when the style's reveal unit is `word` or `char`, in its last word, at that word's end if `layout.holdGapSec > 0`.
- **`preview.text`.** It stands in when the scope has no caption words (no transcript, every word cut, or none left after 3.1 and 4.4), when the scope cannot be planned or its style cannot be resolved, and when Settings → General → "Show transcript words on placeholders" is off. The words are `preview.text` split at spaces, and `t = 0.4·a + 0.35·min(progress, 0.98)` with `a = min(preview.activeWord, n − 1)` and `progress = preview.progress`. A style without `progress` uses 1, the schema default that `tools/captions/gen_fixtures.py` applies, so it is drawn 0.343 s into its active word.
- **Layout inputs.** Lay the sample out at the project's export frame in the tile's library style, with the overrides selected by the Page rule above for both page and preview samples. Page samples use the transcript's BCP-47 language tag (`und` if absent); preview samples use `en`, the language of the bundled preview texts. Use the project's `captions.positionByAspect` and `captions.position` with the precedence in 2.4, falling back to the style's position. Evaluate at `t` with Reduce Motion.

`shared/fixtures/captions/preview-tiles.json` gives the expected page and state of every style's `preview.text` at 1080×1920 and 1920×1080, using `en`, empty overrides and the style's default position. It is the uncustomised preview baseline: it records no word ids (gen_fixtures.py lays it out with ids `p{i}`), and its times are rounded to six decimal places for the layout fixture format; gallery sample ids and times follow the rules above. Selected-tile overrides and project positions can change that baseline. `shared/fixtures/captions/gallery-samples.json`, generated by `tools/captions/gen_gallery.py`, gives the expected sample (source, words, duration and time) for each case, and both Core suites replay every case.

---

## 16. Tests

### 16.1 Fixture files

All in `shared/fixtures/captions/`, generated by `tools/captions/gen_fixtures.py` from `tools/captions/cases.json` and the files in section 0, except `cards.json`, which `tools/captions/gen_cards.py` generates from `tools/captions/card-cases.json`, `gallery-samples.json`, which `tools/captions/gen_gallery.py` generates from `tools/captions/gallery-cases.json`, and `card-colors.json`, which `tools/captions/gen_card_colors.py` generates:

| File | Contents |
|---|---|
| `layout/<case>.json` | 84 cases: every style × {9:16, 1:1, 16:9} with the English set, plus Estonian, Cyrillic/Greek fallback, dropped words and clusters, overlong words, overlapping and touching times, typing, frame-time animation, emoji, emphasis palettes, merge-patch overrides, positions, clamping, a 4:3 source and a 720p output |
| `text-normalization.json` | inputs × {keep, strip-keep-numeric} × {none, uppercase, lowercase}, matching keys, sentence and clause flags |
| `math.json` | `roundHalfUp`, easing, mulberry32, jitter keys, blur kernels, box sizes and blurred rows, rounded-rect paths, gradient end points |
| `preview-tiles.json` | gallery tile state per style (15.3) |
| `gallery-samples.json` | gallery tile samples (15.3): per case the project, scope, style, playhead and words-hidden switch, and the expected source, words, duration and time |
| `cards.json` | caption card text for media stand-ins (design.md section 5.4.2): per case the project, scope, style and words-hidden switch, and the expected words, key word, line limit per surface, drawn moment and the fit's word drops |
| `card-colors.json` | `voxclip-caption-card-colors/1`: the design.md section 5.4.3 sidebar key-word colour rule; per case the box colour, the backdrop colour and the expected opaque key-text colour |
| `box-text-colors.json` | `voxclip-caption-box-text-colors/1`: 54 box text colour vectors (section 2.3): six boxed styles × six swatches, defaults, threshold and override cases |
| `index.json` | list of the files above that `gen_fixtures.py` writes |
| `golden/` | pixel goldens (16.4), added when the renderers exist |

### 16.2 Layout fixture format (`voxclip-caption-layout/1`)

```text
{
  "fixture": "voxclip-caption-layout/1", "id", "note"?,
  "input": {
    "style": id, "frame": {width, height}, "language", "duration",
    "captions": {"overrides", "position", "positionByAspect"},        // as stored in the project
    "words": [{id, text, start, end, emphasis?, emoji?}],
    "frameSamples"?: {fpsNum, fpsDen, first, count}                   // samples are frame times (8.3)
  },
  "expected": {
    "aspect", "preset", "resolved" {sizeSh, sizeScale, x, y, anchorX, anchorY, maxLineWidthW, maxWords, transform, punctuation, accent},
    "fontPx64", "fontPx", "safeRect", "safeInsets", "limitPx", "limitPx64", "unitsPerEm", "gapUnits",
    "words": [{sourceIndex, id, raw, text, start, end, units, clusters,
               runs: [{file, text, units, glyphs, advances, offsets, clusters}],
               emphasisPoints, emphasisCandidate, emphasisUnits?, emphasisRuns?, droppedClusters?}],
    "dropped": [{sourceIndex, text, reason: "empty" | "no-glyphs"}],
    "pages": [{index, words, start, end, fontPx64, fontPx, shrunk,
               lines: [{words, units, x, top, baseline, width}],
               wordRects: [{word, line, x, y, w, h, baseline, cx, cy}],
               block, visual, boxes: [{kind, word?, x, y, w, h, r}],
               emphasised: [{word, paletteColor}], emoji: {word, codepoints, x, y, size} | null, clampShift}],
    "samples": [{t, page | null, activeWord, progress, pageAlpha, pageScale, pageDy, jitter: [dx, dy],
                 words: [{word, state, visible, opacity, scale, dy, fill, fillSource, wipe?, wipeFrom?, visibleClusters?}],
                 cursor: {visible, word, x, y, w, h} | null, golden?: true}]
  }
}
```

Word indices refer to `expected.words` (captioned words only). A sample at a time with no visible page is `{t, page: null}` and has no other keys. `fill` is the resolved solid colour `#RRGGBBAA`, or `"linear"`. `droppedClusters` lists the grapheme clusters of a word that no font in the cascade covers (4.4); `dropped` lists the input words removed entirely. `boxes` holds the page, line and word-scope boxes; the active word box (`words.active.box`) is derived at draw time from the active word's rectangle and that box's padding (7.5).

### 16.3 Layout assertions

Both platforms run every layout fixture through their own normaliser, shaper and layout code and assert:

- Exact: `aspect`, `preset`, `fontPx64`, `limitPx64`, `gapUnits`, every word's `text`, `units`, `clusters`, run files, glyph ids, advances and offsets (this is the shaping parity check), `dropped`, every page's `words`, `fontPx64`, `shrunk`, line word lists and `units`, `emphasised`, emoji `codepoints` and `size`, and in every sample `page`, `activeWord`, each word's `state`, `visible`, `fill`, `visibleClusters`, and `cursor.visible`.
- Within 0.5 px: every pixel coordinate and size (lines, word rectangles, block, visual, boxes and radii, emoji origin, cursor, `pageDy`, `dy`, `jitter`).
- Within 1e-9: page `start` and `end`.
- Within 2e-6: `progress`, `pageAlpha`, `pageScale`, word `opacity`, `scale` and `wipe` (fixtures round them to 6 decimals).

Also: every case of `text-normalization.json` exactly, and every vector of `math.json` (rounding, mulberry32 and box blur exactly; Gaussian kernels and easing within 1e-9; paths and gradient points within 1e-6).

### 16.4 Pixel goldens

- Samples marked `"golden": true` are rendered as goldens: the first visible sample, the middle of the page-in animation, the first sample whose active word is on the second line, and a steady-state sample of the last page; in frame-sample cases, every fifth visible frame. The current fixture set has 292 samples over 98 cases, plus the 38 gallery tiles of `preview-tiles.json`: 330 images in total. The 12 Box highlight swatch cases use the gallery preview words at portrait and landscape output sizes; all 300 original images remain byte-identical.
- A golden is the caption overlay alone, rendered on a transparent canvas at the case's frame size, including `pageAlpha`. It is stored as a straight-alpha RGBA PNG cropped to the bounding box of `alpha > 0` grown by 8 px and clamped to the frame, at `golden/<case>/s<sample-index>.png`. A fully transparent render is stored as a 1×1 transparent PNG with crop `{0, 0, 1, 1}`.
- Gallery tile goldens are the tile state of `preview-tiles.json` rendered the same way (overlay only, no background), at `golden/tiles/<style>-<W>x<H>.png`.
- Each folder has an index next to it (`golden/<case>.json`, `golden/tiles.json`): `{"images": [{"file": "s12.png", "sample": 12 | null, "style": id | null, "t": seconds, "frame": {"width", "height"}, "crop": {"x", "y", "w", "h"}, "sha256"}]}`. The index `t` is the fixture's sample or tile time written unchanged (no arithmetic), and comparators match `t` within 1e-9 seconds.
- Goldens are produced by the macOS renderer. CLI contract, identical on both platforms (also architecture.md section 9.2):
  - `voxclip-cli render-caption --case <layout fixture> --out <dir>` renders every golden sample of the case into `<dir>/<case>/s<index>.png` and writes `<dir>/<case>.json`.
  - `voxclip-cli render-caption --case <layout fixture> --sample <index> --out <file.png>` renders one sample (any sample, golden or not).
  - `voxclip-cli render-caption --tiles <preview-tiles.json> --out <dir>` renders every tile into `<dir>/tiles/`.
  - The renderer takes the case's `input` and builds the track itself; it never reads `expected`.
- Goldens are reviewed visually and committed. The Windows renderer must match them.

### 16.5 Image comparison

Both images are placed back into a transparent full frame and converted to premultiplied 8-bit RGBA (`c·a/255`, rounded half up). Let `R` be the set of pixels where either image has `alpha > 0`.

| Metric | Pass |
|---|---|
| Mean channel difference: `Σ_{p∈R} Σ_{c∈RGBA} |A−B| / (4·|R|)` | ≤ 4.5 (of 255) |
| Pixels in `R` whose largest channel difference exceeds 32 | ≤ max(2% of `|R|`, 96) |
| Largest channel difference anywhere | ≤ 128 |
| SSIM of the alpha channel | ≥ 0.98, not checked when the largest channel difference is ≤ 2 |

SSIM: over the bounding box of `R` grown by 8 px (clamped), on the alpha channels as doubles, Gaussian window 11×11 with σ = 1.5 (normalised), `C1 = (0.01·255)²`, `C2 = (0.03·255)²`, mean of the SSIM map over window positions that lie fully inside the box. A box narrower or shorter than 11 px (only possible at a frame corner) is padded with zeros on the right or bottom to 11 px first. If `R` is empty in both images the comparison passes; if it is empty in one, it fails. `tools/captions/compare_overlays.py` is the executable definition; on failure the suites write a diff PNG (absolute difference ×4, alpha forced to 255) next to the failing output.

These tolerances are calibrated on the first full Swift and C# renders: the macOS goldens of track/mac-captions acd68cb against the Windows goldens of track/win-captions b488813 (2026-10-25), 292 shared images, 275 of them with ink. Outside `vox-bold`, every pair stays within mean 2.22, 0.93% of pixels above 32, largest difference 102 and alpha SSIM 0.9936. Ten `vox-bold` pairs failed the first limits (mean ≤ 3.0, at most 2% above 32). They are plain 48 px text with no outline, where CoreGraphics and Skia antialias every glyph edge differently: mean 2.54 to 3.98, up to 3.36% (71 px) above 32, largest difference 57, SSIM at least 0.9932, ink centroids within 0.09 px. One fade frame (`lower-third-portrait-frames` s6) has a largest difference of 1 but SSIM 0.911, because ±1 rounding dominates the alpha statistics near zero opacity. On the 241 macOS golden samples, the current limits catch exactly the same synthetic faults as the first ones: erasing the last 10% of a page fails 240 samples, a whole-pixel shift 240, a 0.5 px shift 230 and a 0.3 px shift 224. The only sample that passes them all is that near-transparent fade frame. A missing or extra glyph, box, word or emoji breaks the max and SSIM limits. The renderers must still place geometry exactly as computed: the layout fixtures hold coordinates to 0.5 px, and the image comparison catches most sub-pixel shifts on top of that. A threshold may be loosened only by a change to this section that records the measured differences that justify it.

### 16.6 CI

- `fixtures` job: `python3 tools/captions/check_styles.py` (needs `jsonschema`); the fixtures must be unchanged after `gen_fixtures.py` when the job has the reference venv (16.7).
- `macos` job: `swift test` runs the layout, text and math fixtures and compares renders with the goldens; `dotnet test` of the .NET caption tests on macOS does the same with the C# renderer; `tools/captions/parity.sh` renders every golden sample and tile with both CLIs and compares Swift against C# directly, and both against the goldens, with the same metrics (needs `numpy`).
- `windows` job: the C# fixture and golden tests again on Windows (x64), proving the Windows native SkiaSharp and HarfBuzzSharp builds agree with the macOS ones.

### 16.7 Regenerating

- Any change to a style, the schema, `casemap.json`, the lexicons, a font, or a rule in this spec regenerates the fixtures (`tools/captions/README.md`) in the same change. The diff is a behaviour change and is reviewed as one. Never hand-edit expected values.
- Pixel goldens are regenerated only with `voxclip-cli render-caption` after a reviewed rendering change, with before/after images attached to the pull request.
- A font update also regenerates `fonts.json` and `THIRD_PARTY_NOTICES.md` and is re-verified for licence and coverage.

### 16.8 Test environment

Default caption tests exercise layout, rendering, cache equivalence and recovery without calling providers or downloading models. Additional checks use these variables:

| Variable | Purpose |
|---|---|
| `VOXCLIP_PERF_TESTS=1` | Enable frame timing checks in the Swift and C# suites. Use `swift test -c release` or `dotnet test -c Release`, with the performance suite selected. |
| `VOXCLIP_ALLOCATION_TESTS=1` | Enable the C# renderer's allocation checks, including animated frames and rotating output targets. |
| `VOXCLIP_PERF_FORCE=1` | C# diagnostic override when the one-minute load check fails or is unavailable. Results with this override do not satisfy performance acceptance. |
| `VOXCLIP_CAPTION_PYTHON` | Select Python for the Swift and C# image-comparison cross-checks and `tools/captions/parity.sh`. It must import `numpy` under `-I`. |
| `VOXCLIP_REQUIRE_CAPTION_PYTHON=1` | Make the C# cross-check fail when the selected interpreter or `numpy` is missing. Both macOS and Windows Media CI jobs set this flag. |
| `VOXCLIP_GOLDEN_OUT` | Generate candidate images from renderer tests into a scratch directory outside `shared/`, including after symlink resolution. This does not update the committed goldens. Final golden generation uses the CLI procedure in 16.7. |

Timing acceptance follows 13.9: an optimized build, one-minute load below 2, resources warmed before measurement, and the best p95 of three passes for every style and mode. On the M3 Max development host the steady-frame gate is 3.0 ms and the page-first gate is 7.5 ms. A skipped timing test, a debug build or a forced diagnostic run leaves acceptance pending. Run timing tests after other builds and test processes have stopped; do not create artificial CPU load.

---

## 17. Style catalogue

Sizes assume a 1080 px short edge (`sizeSh 0.062` ≈ 67 px). All styles use `strip-keep-numeric` with ALL CAPS unless noted, `center`/`center` anchors and the default timing (hold 0.5 s, gap break 0.6 s, sentence breaks) unless noted. Landscape positions are lowered to `y 0.8` for most phrase styles through `aspects.landscape`.

| order | id | Name | Font (file) | sizeSh | Words / lines | Look | Motion |
|---|---|---|---|---|---|---|---|
| 10 | `vox-bold` | Bold | DM Sans Black | 0.0444 | 1 / 1 | VoxConvo Bold: white, no outline, word visible only while spoken, y 0.80 | none |
| 20 | `vox-highlight` | Highlight | DM Sans Black | 0.0333 | 1 / 1 | VoxConvo Highlight: white on a `#000000B3` box, padding 0.667/0.444 em, radius 0.556 em, line height 1.6 | none |
| 30 | `vox-bold-plus` | Bold+ | DM Sans Black | 0.0444 | 1 / 1 | Bold with a 0.12 em `#000000D9` stroke and soft shadow; 0.3 s hold | none |
| 40 | `karaoke` | Karaoke | Poppins ExtraBold | 0.062 | 6 / 2 balanced | white caps, 0.16 em black stroke; spoken words fill with the accent `#FFE14D` left to right | fade in 0.08 s |
| 50 | `active-pop` | Pop | Montserrat Black | 0.07 | 3 / 2 | active word in accent `#22E06B`, scale 1.08 | activeIn pop 0.12 s easeOutBack |
| 60 | `box-highlight` | Box highlight | Montserrat ExtraBold | 0.062 | 4 / 2 | violet `#7C3AED` (accent) box behind the active word | activeIn pop 0.1 s |
| 70 | `one-word` | One word | Montserrat Black | 0.11 | 1 / 1 | huge word, 0.16 em stroke; digits and long content words in a yellow/green/red palette; minShrink 0.35 | pageIn pop 0.1 s |
| 80 | `bounce` | Bounce | Paytone One | 0.072 | 4 / 2 | words appear as spoken, hard shadow | wordIn pop 0.22 s from 0.4, overshoot 2.4 |
| 90 | `two-tone` | Two-tone | Poppins Bold / Black | 0.062 | 4 / 2 | strongest word per page in accent `#FFC400`, Poppins Black, ×1.08 | none |
| 100 | `outline` | Outline | Anton | 0.085 | 3 / 2 | condensed caps, 0.22 em black stroke, hard drop shadow | none |
| 110 | `pill` | Pill | DM Sans Bold | 0.05 | 7 / 2 | as said, dark text on a white pill per line | pageIn pop 0.12 s |
| 120 | `clean-subtitle` | Subtitle | Noto Sans SemiBold | 0.042 | 12 / 2 balanced | as said, punctuation kept, 70% black band per line, bottom anchor at y 0.90 | none |
| 130 | `lower-third` | Lower third | DM Sans Medium | 0.04 | 10 / 2 | as said, left-aligned on a dark panel, anchored bottom-left at (0.06, 0.90) | slide-up in 0.18 s, fade out 0.12 s |
| 140 | `typewriter` | Typewriter | JetBrains Mono SemiBold | 0.046 | 8 / 2 greedy | as said, left-aligned on a dark panel, ligatures off | char reveal 28/s, blinking cursor |
| 150 | `editorial` | Editorial | DM Serif Display Italic | 0.06 | 7 / 2 balanced | as said, soft shadow, one key word in accent `#F2D7A0` | fade in and out 0.2 s |
| 160 | `gradient` | Gradient | Sora ExtraBold | 0.068 | 3 / 2 | orange → pink → violet gradient per line, dark stroke | zoom in 0.14 s |
| 170 | `neon` | Neon | Righteous | 0.064 | 4 / 2 | accent `#FF4FD8` tube stroke and three glows; future words at 55% | fade in 0.15 s |
| 180 | `emoji-accent` | Emoji | Montserrat ExtraBold | 0.064 | 4 / 2 | emoji above the phrase on keywords (en, et) | pageIn pop 0.16 s |
| 190 | `vhs` | VHS | VT323 | 0.085 | 4 / 2 | punctuation kept, red/cyan split, 15 Hz jitter, kerning off | jitter |

Coverage: every bundled family covers Estonian (õ ä ö ü š ž). Cyrillic is covered by Montserrat, JetBrains Mono and Noto Sans; Greek by JetBrains Mono and Noto Sans; other styles fall back to Noto Sans at the nearest weight (4.4). `clean-subtitle` uses Noto Sans directly for the widest coverage.

---

## 18. Decisions and provenance

| # | Decision | Why / source |
|---|---|---|
| D1 | The two VoxConvo styles use DM Sans Black (`DMSans-Black.ttf`, default optical size), not Arial Black (proprietary) or Archivo Black | Locked decision; DM Sans 900 is what the VoxConvo web preview showed (`theme.ts`, `dm-sans.woff2` has no opsz axis, so the default instance matches) |
| D2 | VoxConvo sizes become fractions of the short edge: Bold 24/540 = 0.0444, Highlight 18/540 = 0.0333; both centre-anchored at (0.5, 0.8); Highlight line height 1.6 and padding 12/8/10 px at 18 px → 0.667/0.444/0.556 em | VoxConvo sized by the browser preview width and anchored the burn at the top; the web preview was centred. The new rule is resolution-independent |
| D3 | Font size reference is the short edge by default (`sizeRef: shortEdge`), which equals the output height for the 16:9 and 1:1 presets; `height` and `width` are available per style | Captions and design research define size on the short side; ADR-026 says output height. They agree for landscape and square; for portrait the short edge keeps the same pixel size as 16:9. Recorded as ADR-R16 (refines ADR-026), pending the lead's confirmation |
| D4 | Fit decisions in integer layout units against an integer limit in 1/64 px | Bit-identical line breaks; refines the research proposal of rounding the font size to whole pixels |
| D5 | Baselines by cap-height centring from the manifest | Deterministic and visually centred for caps; avoids hhea/typo ambiguity |
| D6 | `stroke.widthEm` is the full SVG stroke width under the fill | Research reports disagreed (full width vs. half); the full width is the common convention |
| D7 | Own blur: exact Gaussian below 2 px, SVG triple box above | Platform blurs differ; the box path keeps large glows fast |
| D8 | Rounded rectangles from explicit cubics (κ = 0.5522847498) | `CGPath(roundedRect:)` and Skia round rects use different curves |
| D9 | Cut seams do not force a page break | Breaking at every seam would split phrases at each removed filler; retakes usually end a sentence, which already breaks. design.md section 6.1 says the same |
| D10 | Punctuation modes are `keep` and `strip-keep-numeric` only | VoxConvo's strip turned `03:15` into `0315` and `don't` into `dont`; there is no reason to offer it |
| D11 | Case mapping from `casemap.json` with `ß → SS` and Turkish/Azerbaijani dotted i | Swift `uppercased()` and .NET `ToUpperInvariant()` disagree (`ß`) |
| D12 | Safe-area insets are edge margins (6/6/6/10% portrait); platform UI zones are drag guides only | The native-video research table (bottom 22% clamp) would move VoxConvo's default y 0.80 |
| D13 | Emphasis candidates use their emphasised width while paging | Emphasis is chosen per page but changes widths; this breaks the circularity deterministically |
| D14 | Noto Emoji PNGs come from googlefonts/noto-emoji commit 41e31b11 (2024-02-15) | The repository's root LICENSE changed from Apache-2.0 to OFL-1.1 on 2024-07-29; the PNG folder has no own licence file. At 41e31b11 the README states images are Apache-2.0 under the root LICENSE |
| D15 | Paytone One replaces Rubik; DM Serif Display Italic replaces Playfair Display; DM Sans Bold/Medium and Noto Sans SemiBold replace Inter; Archivo Black is not bundled | Rubik, Playfair Display and Inter publish no static TTFs in google/fonts or a repository folder; Lilita One lacked Latin Extended coverage; DM Serif Display is the DM Sans sibling |
| D16 | Project overrides are an RFC 7396 merge patch; `font.sizeScale` exists so the Size control is a patch | Matches `project.schema.json` (`captions.overrides`, `position`, `positionByAspect`) |
