import { readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
export const appXamlPath = 'apps/windows/src/VoxClip.App/App.xaml';
// exception: text kept under 4.5:1 on purpose, with the reason in its label, that must still
// reach 3:1 and reaches its full minimum under Increase Contrast (impl-plan item 6).
export const minimums = { text: 4.5, accent: 4.5, ui: 3, exception: 3 };

// WCAG 2.x pairs the apps draw. A colour is a token path, a #hex literal, or a token path with
// an opacity (`ai.tint@0.16`). A background may be a list composited top first (an overlay over
// what sits under it). Foregrounds with alpha are composited over the background.
const surfaces = ['bg.surface', 'bg.sunken', 'bg.window', 'bg.elevated'];
// System materials the apps never paint, approximated per mode. glass.sidebar is the macOS
// sidebar's Liquid Glass as the ADR-R29 mockups draw it over the page: light
// rgba(237,236,231,0.80), dark rgba(46,47,51,0.78).
export const materials = { 'glass.sidebar': { light: '#EDECE7CC', dark: '#2E2F33C7' } };
const tokenPairs = [
  ['accent', 'word.playingForeground', 'accent.text', 'macOS dark Export capsule'],
  ...[...surfaces, 'bg.input', 'bg.muted', 'pause.background', 'accent.soft',
    'status.dangerBackground', 'status.warningBackground', 'status.successBackground', 'status.infoBackground']
    .map(background => ['text', 'text.primary', background]),
  ...['text.secondary', 'text.muted', 'accent.text', 'status.dangerForeground', 'status.warning', 'status.success']
    .flatMap(foreground => surfaces.map(background => ['text', foreground, background])),
  // v2 t3 is meta text on chrome and the editor; it is under 4.5:1 on bg.elevated, bg.input and editor.band.
  ...['bg.surface', 'bg.sunken', 'bg.window'].map(background => ['text', 'text.tertiary', background]),
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
  ...['focus.ring', 'accent.text', 'accent.default'].flatMap(foreground => ['bg.surface', 'bg.sunken', 'bg.window'].map(background => ['ui', foreground, background])),
  ['ui', 'accent.text', 'bg.elevated'],
  ['ui', 'focus.ring', 'bg.elevated'],
  ...['timeline.kept', 'cut.fill', 'cut.pauseFill', 'timeline.playhead', 'timeline.clipBracket'].map(foreground => ['ui', foreground, 'timeline.track']),
  // The Mac draws its playhead, clip brackets and clip numbers in DesignValues.accentText,
  // which is accent.text while the system accent is Ink; the timeline.* marks are Windows'.
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
  // The v2 editor (notes.md sections 3 and 5). The band sits behind the open clip's lines.
  ...['text.primary', 'text.secondary'].map(foreground => ['text', foreground, 'editor.band']),
  ...['word.text', 'word.outside', 'word.gone'].flatMap(foreground => ['bg.surface', 'editor.band'].map(background => ['text', foreground, background])),
  ...['text.primary', 'word.text'].flatMap(foreground => ['bg.surface', 'editor.band'].map(background => ['text', foreground, ['tint.selection', background], 'transcript selection'])),
  ['text', 'text.primary', ['ai.tint@0.16', 'editor.band'], 'AI-voiced words'],
  ['text', 'text.primary', ['change.add@0.19', 'editor.band'], 'new words in a proposed change'],
  ['text', 'text.primary', 'bg.selectedRow'],
  ['text', 'text.secondary', 'bg.selectedRow'],
  ['exception', 'gutter.text', 'editor.band', 'gutter timecodes in the open clip: they duplicate the paragraph time VoiceOver reads'],
  ['exception', 'gutter.text', 'bg.surface', 'gutter timecodes in the open clip: they duplicate the paragraph time VoiceOver reads'],
  ['accent', 'tint.on', 'tint.default', 'primary button label'],
  ['accent', 'tint.on', 'tint.pressed', 'pressed primary button label'],
  ...['bg.surface', 'editor.band'].map(background => ['text', 'tint.text', background, 'transcript caret and selection edges, text-safe']),
  ...['timeline.lane', 'bg.window', 'timeline.rulerOut'].map(background => ['ui', 'tint.default', background, 'playhead line, head and ruler selection bar']),
  ...['editor.band', 'bg.window', 'timeline.rulerOut'].map(background => ['ui', 'clip.label', background, 'clip range bar and In/Out brackets']),
  ...['editor.band', 'bg.surface', 'bg.window'].map(background => ['ui', 'ai.tint', background, 'AI voice waveform glyph']),
  ...['editor.band', 'bg.surface', 'bg.window'].map(background => ['ui', 'change.add', background, 'change bar, ruler mark and Outline dot']),
  ['ui', 'ai.wave', ['ai.tint@0.10', 'timeline.lane'], 'AI patch waveform on A1'],
];

// Colours kept below their minimum on purpose (impl-plan item 6), with the reason. Their
// default appearance is not measured; increaseContrastPairs measure their Increase Contrast value.
export const belowMinimum = {
  'line.strong': 'v2 line2: input outlines and the timeline top edge; an input is identified by its bg.input fill and label',
  'text.disabled': 'v2 t4: disabled labels, keyboard hints and leading zero groups, which repeat a menu shortcut or a value read in full',
  'gutter.textOut': 'decorative: the paragraph time outside the open clip, which VoiceOver reads from the paragraph',
  'fold.dot': 'decorative: the fold reads "1 cut: uh, pause 1.4 seconds" and the Cuts rotor lands on it',
};

// Pairs measured with each colour's increaseContrast value where it has one (macOS Increase
// Contrast). Every colour with an increaseContrast value must appear here, at its full minimum.
const increaseContrastPairs = [
  ...['bg.surface', 'bg.sunken', 'bg.window'].map(background => ['ui', 'line.strong', background]),
  ['ui', 'line.strong', ['overlay.transportOpaque', 'stage'], 'transport pill border under Reduce Transparency'],
  ['text', 'text.disabled', 'bg.window', 'keyboard hints and disabled labels'],
  ...['editor.band', 'bg.surface'].map(background => ['text', 'gutter.text', background]),
  ['text', 'gutter.textOut', 'bg.surface'],
  ['ui', 'fold.dot', 'editor.band'],
];

// Colour tokens no pair checks, with the reason. Every other colour token must appear in a pair.
export const exempt = {
  'line.default': 'decorative hairline',
  'selection.text': 'platform selection colour',
  'record.button': 'M2 recording UI, not drawn yet',
  'record.live': 'M2 recording UI, not drawn yet',
  'timeline.scopeDim': 'dims the track outside the selected clip on purpose; brackets and trim handles mark the scope',
  'overlay.dropZoneBorder': 'decorative; the zone icon and label identify it',
  'chip.mediaStroke': 'decorative inner line of a translucent chip; its fill and text carry it',
  'media.rim': 'decorative 1 px rim on media; the tile title and accessible name identify it',
  'media.sheen': 'loading shimmer; the Loading meta text and the accessible name carry the state',
  'tint.wash': 'selection wash over the timeline tracks; the ruler selection bar and the transcript selection carry it',
  'timeline.piece': 'decorative 1 pt outline of a clip piece; its fill, filmstrip or waveform identify it',
  'timeline.seam': 'decorative 1 pt cut seam; cuts are also folds in the transcript, the Cuts rotor and the status summary',
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

// `token@0.16` is the token at 16% of its own alpha.
function withOpacity(value, opacity) {
  if (opacity === undefined) return value;
  const { rgb, alpha } = channels(value);
  return hex(rgb) + Math.round(alpha * Number(opacity) * 255).toString(16).padStart(2, '0').toUpperCase();
}

function tokenNode(source, tokenPath) {
  let node = source.color;
  for (const part of tokenPath.split('.')) node = node?.[part];
  return node?.$type === 'color' ? node : undefined;
}

// A token's hex colour in a mode; with increaseContrast, its macOS Increase Contrast value where it has one.
function tokenColor(source, reference, mode, increaseContrast = false) {
  const [tokenPath, opacity] = reference.split('@');
  const node = tokenNode(source, tokenPath);
  const raised = increaseContrast ? node?.$extensions?.['com.voxconvo.voxclip']?.increaseContrast?.[mode] : undefined;
  const value = raised ?? node?.$value[mode];
  if (typeof value !== 'string' || !value.startsWith('#')) throw new Error(`No hex ${mode} colour for color.${tokenPath}`);
  return withOpacity(value, opacity);
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
    for (const [appearance, pairs] of [['default', tokenPairs], ['increaseContrast', increaseContrastPairs]]) {
      const lookup = value => value.startsWith('#') ? value : materials[value]?.[mode] ?? tokenColor(source, value, mode, appearance === 'increaseContrast');
      for (const [category, foreground, background, label] of pairs) measure(category, foreground, background, lookup, { platform: 'tokens', mode, appearance, label: label ?? '' });
    }
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
    for (const [category, foreground, background, label] of pairs) measure(category, foreground, background, lookup, { platform: 'windows', mode, appearance: 'default', label });
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
  const names = pairs => new Set(pairs.flatMap(([, foreground, background]) => [foreground, background].flat()).map(name => name.split('@')[0]));
  const used = names([...tokenPairs, ...increaseContrastPairs]);
  const measuredByDefault = new Set(tokenPairs.map(([, foreground]) => foreground));
  const restored = new Set(increaseContrastPairs.map(([, foreground]) => foreground));
  const raised = tokens.filter(token => tokenNode(source, token).$extensions?.['com.voxconvo.voxclip']?.increaseContrast);
  // A colour below its minimum is recorded with a reason, carries an increaseContrast value and is measured under Increase Contrast.
  const unrestored = [...new Set([...Object.keys(belowMinimum), ...raised])]
    .filter(token => !tokens.includes(token) || !restored.has(token) || !raised.includes(token) || (belowMinimum[token] !== undefined) === measuredByDefault.has(token));
  return {
    missing: tokens.filter(token => !used.has(token) && !exempt[token]),
    staleExemptions: Object.keys(exempt).filter(token => !tokens.includes(token) || used.has(token)),
    unrestored,
  };
}

async function main() {
  const source = JSON.parse(await readFile(path.join(root, 'shared/design/tokens.json'), 'utf8'));
  const rows = contrastRows(source, await readFile(path.join(root, appXamlPath), 'utf8'));
  for (const row of rows) {
    console.log(`${row.passed ? 'ok  ' : 'FAIL'} ${row.ratio.toFixed(2).padStart(5)}:1 (min ${row.minimum}) ${row.category.padEnd(9)} ${row.platform} ${row.mode.padEnd(5)}${row.appearance === 'increaseContrast' ? ' increase contrast' : ''} ${row.foreground} on ${row.background} ${row.colors}${row.label ? ` - ${row.label}` : ''}`);
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
