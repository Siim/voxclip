# Design token generation

Node 22, no dependencies and no install step. `shared/design/tokens.json` is the
only source of token values. This implements `doc/design.md` section 16.

```sh
npm --prefix tools/design run generate
npm --prefix tools/design run check
npm --prefix tools/design test
npm --prefix tools/design run contrast   # print every contrast pair
```

`generate` writes exactly the two app `Tokens` files and the macOS colour
assets. `check` generates the same strings in memory, never writes, and exits 1
if any output is missing or has drifted. There are no timestamps or
host-dependent paths in the outputs.

- Colour `color.text.primary` becomes `Color.vcTextPrimary` and
  `VcTextPrimaryBrush`. Swift colours use dynamic NSColor providers; XAML has
  `Default`, `Light` and `HighContrast` dictionaries. Straight RGBA is converted
  to XAML ARGB. System colours use the declared platform resources, never a hex
  approximation; system brush tokens use resource aliases.
- A colour token whose extensions name a `macosAsset` also becomes
  `apps/macos/Resources/Assets.xcassets/<name>.colorset/Contents.json`, with the
  light value for Any and the dark value for Dark. `accent.default` is the
  `AccentColor` asset; `bundle.sh` compiles the catalog with actool and
  `Info.plist` names it in `NSAccentColorName`.
- Dimensions and unitless `number` tokens are `CGFloat` constants on
  `VCTokens`, for example `spacingPanePaddingWindows` and
  `sizeWindowDefaultWidth`. XAML numeric keys are `VcSpacingPanePaddingWindows`
  and `VcSizeWindowDefaultWidth`. Spacing and stroke tokens also expose uniform
  `Thickness` resources; radii expose `CornerRadius` resources with that type
  name as a suffix.
- A dimension's `$value` is the macOS value. A `windows` value in its
  extensions replaces it in `Tokens.xaml` only, so both apps use one name:
  `spacing.transcriptGutter` is `spacingTranscriptGutter` 84 in Swift and
  `VcSpacingTranscriptGutter` 76 in XAML.
- Durations remain milliseconds. Bezier points flatten to `X1/Y1/X2/Y2`;
  compound sizes flatten to width/height or min/ideal/max. Typography constants
  keep each platform's own size, line height, weight, tracking and features.
- `Font.vcTranscript()`, `vcStatus()`, `vcTimecode()` and the other typography
  helpers use their macOS token values. A macOS `fontFamily` of `system` is the
  system font and `SF Mono` its monospaced design; any other family must be a
  `fontFiles` token. `Font.vcDmSans(size:weight:)` and
  `vcGeistMono(size:weight:)` load present files by URL through `SharedResources`.
  Metadata marked `present: false`, a missing exact font weight, or missing
  shared resources use the declared system fallback. Successful file descriptors
  are cached on the main actor. No fonts are copied into an app source tree.

`contrast.mjs` computes WCAG 2.x contrast for the pairs the apps draw, in light
and dark: text on surfaces (4.5:1), text and glyphs on the accent (4.5:1), and
UI boundaries and marks (3:1). Windows on-accent pairs read the accent ramp
from `App.xaml`; translucent colours are composited over what they sit on.
System materials the apps never paint are approximated per mode in
`materials`: `glass.sidebar` is the macOS sidebar glass as the ADR-R29 mockups
draw it over the page.
`npm test` fails on any pair below its minimum, on a colour token that no pair
checks and that is not listed as exempt with a reason, and on an `App.xaml`
ramp that differs from the accent tokens.

Edit the shared tokens, regenerate, and review both output diffs as a design
change. Never edit a generated file by hand. Consumer-specific aliases
are not generated; use the canonical resource keys above.
