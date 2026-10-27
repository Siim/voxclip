import { readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
export const appXamlPath = 'apps/windows/src/VoxClip.App/App.xaml';
export const minimums = { text: 4.5, accent: 4.5, ui: 3 };

// WCAG 2.x pairs the apps draw. A background is a token path, a #hex literal, or a list
// composited top first (an overlay over what sits under it). Foregrounds with alpha are
// composited over the background.
const surfaces = ['bg.surface', 'bg.sunken', 'bg.window', 'bg.elevated'];
// System materials the apps never paint, approximated per mode. glass.sidebar is the macOS
// sidebar's Liquid Glass as the ADR-R29 mockups draw it over the page: light
// rgba(237,236,231,0.80), dark rgba(46,47,51,0.78).
export const materials = { 'glass.sidebar': { light: '#EDECE7CC', dark: '#2E2F33C7' } };
const tokenPairs = [
  ...[...surfaces, 'bg.input', 'bg.muted', 'pause.background', 'accent.soft',
    'status.dangerBackground', 'status.warningBackground', 'status.successBackground', 'status.infoBackground']
    .map(background => ['text', 'text.primary', background]),
  ...['text.secondary', 'text.muted', 'text.tertiary', 'accent.text', 'status.dangerForeground', 'status.warning', 'status.success']
    .flatMap(foreground => surfaces.map(background => ['text', foreground, background])),
  ['text', 'text.muted', 'pause.background'],
  ['text', 'text.secondary', ['clip.badgeBackground', 'bg.surface'], 'neutral clip badge'],
  ['text', 'text.secondary', ['clip.badgeBackground', 'bg.sunken'], 'neutral clip badge'],
  ['text', 'text.secondary', ['clip.badgeBackground', 'glass.sidebar', 'bg.surface'], 'neutral clip badge on the sidebar glass'],
  ['text', 'text.primary', 'selection.transcript', 'Windows transcript selection'],
  ['text', 'word.cut', 'bg.surface'],
  ['text', 'word.cut', 'pause.background', 'cut word that matches a search'],
  ['text', 'word.filler', 'bg.surface'],
  ['text', 'text.primary', ['overlay.drop', 'text.primary']],
  ['text', 'overlay.foreground', 'stage'],
  ['text', 'overlay.foreground', ['overlay.transportOpaque', '#FFFFFF']],
  ['text', 'overlay.foreground', ['overlay.scrim', '#FFFFFF']],
  ['accent', 'accent.on', 'accent.default'],
  ['accent', 'accent.on', 'accent.pressed'],
  ['accent', 'word.playingForeground', 'word.playingBackground'],
  ['accent', '#FFFFFF', 'accent.default', 'macOS system glyph on the AccentColor asset'],
  ...['line.strong', 'focus.ring', 'accent.text', 'accent.default'].flatMap(foreground => ['bg.surface', 'bg.sunken', 'bg.window'].map(background => ['ui', foreground, background])),
  ['ui', 'accent.text', 'bg.elevated'],
  ['ui', 'focus.ring', 'bg.elevated'],
  ['ui', 'line.strong', ['overlay.transportOpaque', 'stage']],
  ...['timeline.kept', 'cut.fill', 'cut.pauseFill', 'timeline.playhead', 'timeline.clipBracket'].map(foreground => ['ui', foreground, 'timeline.track']),
  // The Mac draws its playhead, clip brackets and clip numbers in DesignValues.accentText,
  // which is accent.text while the system accent is Petrol; the timeline.* marks are Windows'.
  ['ui', 'accent.text', 'timeline.track', 'Mac playhead line on the track'],
  ['ui', 'accent.text', ['timeline.clipBand', 'timeline.track'], 'Mac playhead line in the active clip band'],
  ['text', 'accent.text', 'bg.surface', 'Mac 9 pt clip numbers on the timeline strip'],
  ['ui', 'timeline.waveform', ['timeline.keptBackground', 'timeline.track'], 'waveform bars on the kept-speech bed'],
  ['ui', 'timeline.playhead', ['timeline.keptBackground', 'timeline.track']],
  ['ui', 'timeline.playhead', 'bg.sunken'],
  ['ui', 'timeline.clipBracket', 'bg.sunken'],
  ['ui', 'timeline.clipBracket', 'bg.surface'],
  ['ui', 'cut.stroke', 'bg.surface'],
  ['ui', 'cut.stroke', 'pause.background'],
  ['ui', 'word.lowConfidence', 'bg.surface'],
  ['ui', 'word.correctionDot', 'bg.surface'],
  ['ui', 'status.dangerForeground', 'status.dangerBackground'],
  ['ui', 'status.warning', 'status.warningBackground'],
  ['ui', 'status.success', 'status.successBackground'],
  ['ui', 'accent.text', 'status.infoBackground'],
  ['ui', 'overlay.dropBorder', ['overlay.drop', 'bg.surface']],
  // Media chips and the progress line sit on any frame (design 5.4.8): checked over white, the worst frame, and over black.
  ['text', 'chip.mediaForeground', ['chip.mediaBackground', '#FFFFFF'], 'media chip over a white frame'],
  ['text', 'chip.mediaForeground', ['chip.mediaBackground', 'stage'], 'media chip over black'],
  ['text', 'chip.mediaForeground', 'chip.mediaBackgroundOpaque', 'media chip with transparency off'],
  ['ui', 'chip.warningGlyph', ['chip.mediaBackground', '#FFFFFF'], 'corrupt-file chip glyph over a white frame'],
  ['ui', 'chip.warningGlyph', 'chip.mediaBackgroundOpaque', 'corrupt-file chip glyph with transparency off'],
  ['ui', 'chip.mediaStrokeOpaque', 'chip.mediaBackgroundOpaque', 'opaque chip outline'],
  ['ui', 'overlay.foreground', ['media.progressTrack', '#FFFFFF'], 'progress line over a white frame'],
  ['ui', 'overlay.foreground', ['media.progressTrack', 'stage'], 'progress line over black'],
];

// Colour tokens no pair checks, with the reason. Every other colour token must appear in a pair.
export const exempt = {
  'text.disabled': 'disabled labels are exempt from WCAG minimums',
  'line.default': 'decorative hairline',
  'selection.text': 'platform selection colour',
  'record.button': 'M2 recording UI, not drawn yet',
  'record.live': 'M2 recording UI, not drawn yet',
  'timeline.scopeDim': 'dims the track outside the selected clip on purpose; brackets and trim handles mark the scope',
  'overlay.dropZoneBorder': 'decorative; the zone icon and label identify it',
  'chip.mediaStroke': 'decorative inner line of a translucent chip; its fill and text carry it',
  'media.rim': 'decorative 1 px rim on media; the tile title and accessible name identify it',
  'media.sheen': 'loading shimmer; the Loading meta text and the accessible name carry the state',
};

// Windows draws accent text and on-accent text from the App.xaml ramp, not from tokens. The
// labels name the WinUI 2.3.9 brushes that use each ramp colour.
const windowsPairs = {
  Light: [
    ['accent', 'TextOnAccentFillColorPrimary', 'SystemAccentColorDark1', 'AccentButton rest'],
    ['accent', 'TextOnAccentFillColorPrimary', ['SystemAccentColorDark1@0.9', 'bg.window'], 'AccentButton pointer over'],
    ['accent', '#FFFFFF', 'SystemAccentColorDark1', 'WinUI default on-accent text, AccentAAFillColorDefault'],
    ['accent', '#FFFFFF', 'SystemAccentColorDark2', 'AccentAAFillColorSecondary'],
    ['accent', '#FFFFFF', 'SystemAccentColor', 'selected text, SystemControlHighlightAccentBrush, AccentAAFillColorTertiary'],
    ...['bg.window', 'bg.surface'].flatMap(background => [
      ['text', 'SystemAccentColorDark2', background, 'AccentTextFillColorPrimary'],
      ['text', 'SystemAccentColorDark3', background, 'AccentTextFillColorSecondary'],
      ['text', 'SystemAccentColorDark1', background, 'AccentTextFillColorTertiary'],
    ]),
    ['ui', 'SystemAccentColorDark1', 'bg.surface', 'checked or on state fill'],
  ],
  Default: [
    ['accent', 'TextOnAccentFillColorPrimary', 'SystemAccentColorLight2', 'AccentButton rest'],
    ['accent', 'TextOnAccentFillColorPrimary', ['SystemAccentColorLight2@0.9', 'bg.window'], 'AccentButton pointer over'],
    ['accent', '#000000', 'SystemAccentColorLight2', 'WinUI default on-accent text, AccentAAFillColorDefault'],
    ['accent', '#000000', 'SystemAccentColorLight3', 'AccentAAFillColorSecondary'],
    ['accent', '#000000', 'SystemAccentColorLight1', 'AccentAAFillColorTertiary'],
    ['accent', '#FFFFFF', 'SystemAccentColor', 'selected text, SystemControlHighlightAccentBrush'],
    ...['bg.window', 'bg.surface'].flatMap(background => [
      ['text', 'SystemAccentColorLight3', background, 'AccentTextFillColorPrimary and Secondary'],
      ['text', 'SystemAccentColorLight2', background, 'AccentTextFillColorTertiary'],
    ]),
    ['ui', 'SystemAccentColorLight2', 'bg.surface', 'checked or on state fill'],
  ],
};

export function channels(value) {
  if (!/^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/i.test(value)) throw new Error(`Not a hex colour: ${value}`);
  const bytes = value.slice(1).match(/../g).map(byte => Number.parseInt(byte, 16));
  return { rgb: bytes.slice(0, 3), alpha: bytes.length === 4 ? bytes[3] / 255 : 1 };
}

export function composite(top, bottom) {
  return top.rgb.map((channel, index) => channel * top.alpha + bottom[index] * (1 - top.alpha));
}

export function luminance(rgb) {
  const linear = rgb.map(channel => channel / 255).map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

export function contrast(foreground, background) {
  const [lighter, darker] = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (lighter + 0.05) / (darker + 0.05);
}

const hex = rgb => `#${rgb.map(channel => Math.round(channel).toString(16).padStart(2, '0')).join('').toUpperCase()}`;

function tokenColor(source, tokenPath, mode) {
  let node = source.color;
  for (const part of tokenPath.split('.')) node = node?.[part];
  const value = node?.$type === 'color' ? node.$value[mode] : undefined;
  if (typeof value !== 'string' || !value.startsWith('#')) throw new Error(`No hex ${mode} colour for color.${tokenPath}`);
  return value;
}

export function windowsRamp(xaml) {
  const themes = {};
  for (const [, theme, body] of xaml.matchAll(/<ResourceDictionary x:Key="(\w+)">([\s\S]*?)<\/ResourceDictionary>/g)) {
    themes[theme] = Object.fromEntries([...body.matchAll(/<Color x:Key="(\w+)">(#[0-9A-Fa-f]{6,8})<\/Color>/g)].map(([, key, value]) => [key, value.toUpperCase()]));
  }
  return themes;
}

export function contrastRows(source, xaml) {
  const rows = [];
  const measure = (category, foreground, background, lookup, context) => {
    const layers = [background].flat();
    let base = channels(lookup(layers.at(-1))).rgb;
    for (const layer of layers.slice(0, -1).reverse()) base = composite(channels(lookup(layer)), base);
    const top = composite(channels(lookup(foreground)), base);
    const ratio = contrast(top, base);
    rows.push({ category, ...context, foreground, background: layers.join(' over '), colors: `${hex(top)} on ${hex(base)}`, ratio, minimum: minimums[category], passed: ratio >= minimums[category] });
  };
  for (const mode of ['light', 'dark']) {
    const lookup = value => value.startsWith('#') ? value : materials[value]?.[mode] ?? tokenColor(source, value, mode);
    for (const [category, foreground, background, label] of tokenPairs) measure(category, foreground, background, lookup, { platform: 'tokens', mode, label: label ?? '' });
  }
  const ramp = windowsRamp(xaml);
  for (const [theme, pairs] of Object.entries(windowsPairs)) {
    const mode = theme === 'Light' ? 'light' : 'dark';
    const lookup = value => {
      if (value.startsWith('#')) return value;
      const [key, opacity] = value.split('@');
      if (key.startsWith('bg.')) return tokenColor(source, key, mode);
      const color = ramp[theme]?.[key];
      if (!color) throw new Error(`App.xaml ${theme} theme has no ${key}`);
      return opacity ? `${color}${Math.round(Number(opacity) * 255).toString(16).padStart(2, '0').toUpperCase()}` : color;
    };
    for (const [category, foreground, background, label] of pairs) measure(category, foreground, background, lookup, { platform: 'windows', mode, label });
  }
  return rows;
}

export function coverage(source) {
  const tokens = [];
  const walk = (node, parts) => {
    if (node?.$type === 'color') return tokens.push(parts.join('.'));
    for (const [key, child] of Object.entries(node ?? {})) if (!key.startsWith('$')) walk(child, [...parts, key]);
  };
  walk(source.color, []);
  const used = new Set(tokenPairs.flatMap(([, foreground, background]) => [foreground, background].flat()));
  return { missing: tokens.filter(token => !used.has(token) && !exempt[token]), staleExemptions: Object.keys(exempt).filter(token => !tokens.includes(token) || used.has(token)) };
}

async function main() {
  const source = JSON.parse(await readFile(path.join(root, 'shared/design/tokens.json'), 'utf8'));
  const rows = contrastRows(source, await readFile(path.join(root, appXamlPath), 'utf8'));
  for (const row of rows) {
    console.log(`${row.passed ? 'ok  ' : 'FAIL'} ${row.ratio.toFixed(2).padStart(5)}:1 (min ${row.minimum}) ${row.category.padEnd(6)} ${row.platform} ${row.mode.padEnd(5)} ${row.foreground} on ${row.background} ${row.colors}${row.label ? ` - ${row.label}` : ''}`);
  }
  for (const category of Object.keys(minimums)) {
    const lowest = rows.filter(row => row.category === category).sort((a, b) => a.ratio - b.ratio)[0];
    console.log(`lowest ${category}: ${lowest.ratio.toFixed(2)}:1 ${lowest.platform} ${lowest.mode} ${lowest.foreground} on ${lowest.background}`);
  }
  if (rows.some(row => !row.passed)) process.exitCode = 1;
}

if (process.argv[1] && await realpath(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(`design contrast: ${error.message}`); process.exitCode = 1; });
}
