import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { appXamlPath, belowMinimum, channels, composite, contrast, contrastRows, coverage, materials, minimums, windowsRamp } from './contrast.mjs';

const source = JSON.parse(await readFile(new URL('../../shared/design/tokens.json', import.meta.url), 'utf8'));
const xaml = await readFile(new URL(`../../${appXamlPath}`, import.meta.url), 'utf8');
const token = path => path.split('.').reduce((node, part) => node[part], source.color);
const value = (path, mode) => token(path).$value[mode];

test('WCAG ratios and alpha compositing match reference values', () => {
  assert.equal(contrast([255, 255, 255], [0, 0, 0]), 21);
  assert.equal(contrast([0, 0, 0], [255, 255, 255]), 21);
  assert.equal(contrast([119, 119, 119], [255, 255, 255]).toFixed(2), '4.48');
  assert.deepEqual(composite(channels('#00000080'), [255, 255, 255]).map(Math.round), [127, 127, 127]);
  assert.throws(() => channels('system:green'), /Not a hex colour/);
});

test('every text, on-accent and boundary pair meets its minimum in both modes and on both platforms', () => {
  const rows = contrastRows(source, xaml);
  for (const category of Object.keys(minimums)) {
    for (const mode of ['light', 'dark']) assert.ok(rows.some(row => row.category === category && row.mode === mode), `${category} ${mode}`);
  }
  assert.ok(rows.some(row => row.platform === 'windows' && row.category === 'accent' && row.mode === 'light'));
  assert.ok(rows.some(row => row.platform === 'windows' && row.category === 'accent' && row.mode === 'dark'));
  for (const row of rows) {
    assert.ok(row.passed, `${row.platform} ${row.mode} ${row.foreground} on ${row.background}: ${row.colors} ${row.ratio.toFixed(2)}:1 < ${row.minimum}:1`);
  }
});

test('the ADR-R29 badge, selection and boundary pairs are checked in both modes', () => {
  const rows = contrastRows(source, xaml);
  const required = [
    ['text', 'text.secondary', 'clip.badgeBackground over bg.surface', 'default'],
    ['text', 'text.secondary', 'clip.badgeBackground over bg.sunken', 'default'],
    ['text', 'text.secondary', 'clip.badgeBackground over glass.sidebar over bg.surface', 'default'],
    ['text', 'text.primary', 'selection.transcript', 'default'],
    // line.strong is the 3:1 boundary in every appearance; the quiet v2 line2 is line.edge, raised under Increase Contrast.
    ['ui', 'line.strong', 'bg.sunken', 'default'],
    ['ui', 'line.edge', 'bg.sunken', 'increaseContrast'],
  ];
  for (const mode of ['light', 'dark']) {
    for (const [category, foreground, background, appearance] of required) {
      const row = rows.find(candidate => candidate.platform === 'tokens' && candidate.mode === mode && candidate.appearance === appearance && candidate.foreground === foreground && candidate.background === background);
      assert.ok(row?.category === category && row.minimum === minimums[category] && row.passed, `${mode} ${appearance} ${foreground} on ${background}`);
    }
  }
  assert.deepEqual(Object.keys(materials['glass.sidebar']).sort(), ['dark', 'light']);
});

test('the text hierarchy is monotonic on every surface in both modes', () => {
  for (const mode of ['light', 'dark']) {
    for (const surface of ['bg.surface', 'bg.sunken', 'bg.window', 'bg.elevated', 'pause.background']) {
      const ratio = token => contrast(channels(value(token, mode)).rgb, channels(value(surface, mode)).rgb);
      const where = `${mode} on ${surface}`;
      assert.ok(ratio('text.primary') > ratio('text.secondary'), `primary > secondary ${where}`);
      assert.ok(ratio('text.secondary') > ratio('text.muted'), `secondary > muted ${where}`);
      assert.ok(ratio('text.secondary') > ratio('text.tertiary'), `secondary > tertiary ${where}`);
    }
  }
});

test('the gate fails a pair below its minimum', () => {
  const changed = structuredClone(source);
  changed.color.text.tertiary.$value.light = '#9396A4';
  changed.color.timeline.kept.$value.dark = '#3A3C45';
  const failing = contrastRows(changed, xaml).filter(row => !row.passed).map(row => `${row.mode} ${row.foreground} on ${row.background}`);
  assert.ok(failing.includes('light text.tertiary on bg.surface'));
  assert.ok(failing.includes('dark timeline.kept on timeline.track'));
});

test('every colour token is checked or explicitly exempt', () => {
  assert.deepEqual(coverage(source), { missing: [], staleExemptions: [], unrestored: [] });
  const changed = structuredClone(source);
  delete changed.color.gutter.textOut.$extensions['com.voxconvo.voxclip'].increaseContrast;
  assert.deepEqual(coverage(changed).unrestored, ['gutter.textOut']);
});

test('the v2 palette (notes.md section 3) is the dark appearance, with the item 6 lifts', () => {
  const v2 = {
    'bg.window': '#17181A', 'bg.sunken': '#17181A', 'bg.surface': '#1C1D20', 'bg.input': '#212225', 'bg.selectedRow': '#2B2C30',
    'editor.band': '#222327', 'timeline.lane': '#111214', 'timeline.rulerOut': '#131416', 'timeline.piece': '#2E3035', 'timeline.seam': '#0B0C0D',
    'line.default': '#28292D', 'line.edge': '#34353A',
    'text.primary': '#ECECEA', 'text.secondary': '#A4A6AB', 'text.disabled': '#4E5056',
    'word.text': '#DCDCD9', 'gutter.text': '#6A6D73', 'gutter.textOut': '#55585E', 'fold.dot': '#5B5E64', 'clip.label': '#C9CAC6',
    'tint.default': '#F26B3A', 'tint.on': '#1A0F0A', 'tint.selection': '#F26B3A29', 'tint.wash': '#F26B3A12',
    'ai.tint': '#6AA6FF', 'ai.wave': '#8FB3E8D9', 'change.add': '#4FC28B',
    // Lifted to 4.5:1: t3 on chrome and the editor, out and gone on the band.
    'text.tertiary': '#82858B', 'word.outside': '#878A90', 'word.gone': '#878A90',
  };
  for (const [path, hex] of Object.entries(v2)) assert.equal(value(path, 'dark'), hex, path);
  const rows = contrastRows(source, xaml).filter(row => row.platform === 'tokens' && row.mode === 'dark' && row.appearance === 'default');
  const ratio = (foreground, background) => rows.find(row => row.foreground === foreground && row.background === background)?.ratio;
  assert.ok(ratio('text.tertiary', 'bg.window') >= 4.5 && ratio('text.tertiary', 'bg.surface') >= 4.5);
  assert.ok(ratio('word.outside', 'editor.band') >= 4.5 && ratio('word.gone', 'editor.band') >= 4.5);
  // The three meanings never share a hue: orange, blue and green.
  assert.equal(new Set(['tint.default', 'ai.tint', 'change.add'].map(path => value(path, 'dark'))).size, 3);
});

test('the orange is the app tint, never the system accent', async () => {
  // accent.* stays Ink: it generates the macOS AccentColor asset and pins the Windows accent ramp,
  // so system controls stay neutral (impl-plan item 10).
  assert.deepEqual(token('accent.default').$value, { dark: '#6D6F73', light: '#2C2E35' });
  const asset = JSON.parse(await readFile(new URL('../../apps/macos/Resources/Assets.xcassets/AccentColor.colorset/Contents.json', import.meta.url), 'utf8'));
  const components = hex => ({ alpha: '1.000', blue: `0x${hex.slice(5, 7)}`, green: `0x${hex.slice(3, 5)}`, red: `0x${hex.slice(1, 3)}` });
  assert.deepEqual(asset.colors.map(entry => entry.color.components), [components(value('accent.default', 'light')), components(value('accent.default', 'dark'))]);
  const assets = [];
  const walk = (node, parts) => {
    if (node?.$type === 'color') { if (node.$extensions?.['com.voxconvo.voxclip']?.macosAsset) assets.push(parts.join('.')); return; }
    for (const [key, child] of Object.entries(node ?? {})) if (!key.startsWith('$')) walk(child, [...parts, key]);
  };
  walk(source.color, []);
  assert.deepEqual(assets, ['accent.default']);
  const ramp = Object.values(windowsRamp(xaml)).flatMap(theme => Object.values(theme));
  for (const mode of ['light', 'dark']) {
    for (const name of ['default', 'pressed', 'text']) {
      const orange = value(`tint.${name}`, mode);
      assert.ok(!['default', 'pressed', 'text', 'on', 'soft'].some(accent => value(`accent.${accent}`, mode) === orange), `tint.${name} ${mode} is not an accent value`);
      assert.ok(!ramp.includes(orange), `tint.${name} ${mode} is not in the App.xaml accent ramp`);
    }
  }
});

test('colours below a minimum are recorded with a reason and meet it under Increase Contrast', () => {
  const rows = contrastRows(source, xaml).filter(row => row.platform === 'tokens');
  for (const [path, reason] of Object.entries(belowMinimum)) {
    assert.ok(reason.length > 20, path);
    assert.ok(!rows.some(row => row.appearance === 'default' && row.foreground === path), `${path} is not measured by default`);
    for (const mode of ['light', 'dark']) {
      const raised = rows.filter(row => row.appearance === 'increaseContrast' && row.mode === mode && row.foreground === path);
      assert.ok(raised.length > 0 && raised.every(row => row.passed && row.minimum >= minimums.ui), `${mode} ${path} under Increase Contrast`);
    }
  }
  for (const row of rows.filter(row => row.category === 'exception')) {
    assert.ok(row.label.length > 20 && row.passed, `${row.mode} ${row.foreground} on ${row.background} is a recorded exception`);
    const raised = rows.find(candidate => candidate.appearance === 'increaseContrast' && candidate.mode === row.mode && candidate.foreground === row.foreground && candidate.background === row.background);
    assert.ok(raised?.category === 'text' && raised.passed, `${row.mode} ${row.foreground} on ${row.background} reaches 4.5:1 under Increase Contrast`);
  }
  // An Increase Contrast value only changes what Increase Contrast measures.
  const changed = structuredClone(source);
  changed.color.gutter.text.$extensions['com.voxconvo.voxclip'].increaseContrast.dark = '#55585E';
  const failing = contrastRows(changed, xaml).filter(row => !row.passed).map(row => `${row.mode} ${row.appearance} ${row.foreground} on ${row.background}`);
  assert.deepEqual(failing, ['dark increaseContrast gutter.text on editor.band', 'dark increaseContrast gutter.text on bg.surface']);
});

test('line.strong stays the 3:1 boundary in the default appearance, which Reduce Transparency keeps', () => {
  // Clip rules and brackets, suggestion outlines, drop zones and the opaque edges under Reduce
  // Transparency all draw line.strong; Reduce Transparency alone is not an Increase Contrast appearance.
  assert.equal(belowMinimum['line.strong'], undefined);
  assert.equal(token('line.strong').$extensions['com.voxconvo.voxclip'].increaseContrast, undefined);
  assert.deepEqual(token('line.strong').$value, { dark: '#6C6E75', light: '#85878E' });
  assert.notEqual(value('line.edge', 'dark'), value('line.strong', 'dark'));
  const rows = contrastRows(source, xaml).filter(row => row.platform === 'tokens');
  for (const mode of ['light', 'dark']) {
    for (const background of ['bg.surface', 'bg.sunken', 'bg.window', 'overlay.transportOpaque over stage']) {
      const row = rows.find(candidate => candidate.mode === mode && candidate.appearance === 'default' && candidate.foreground === 'line.strong' && candidate.background === background);
      assert.ok(row?.category === 'ui' && row.passed, `${mode} line.strong on ${background}`);
    }
  }
  const transparency = rows.filter(row => /transparency/i.test(row.label));
  assert.ok(transparency.some(row => row.foreground === 'line.strong'));
  for (const row of transparency) assert.equal(row.appearance, 'default', `${row.mode} ${row.foreground} on ${row.background} (${row.label})`);
  // The gate catches the regression: the quiet line2 value as line.strong fails its boundary pairs.
  const quiet = structuredClone(source);
  quiet.color.line.strong.$value.dark = value('line.edge', 'dark');
  const failing = contrastRows(quiet, xaml).filter(row => !row.passed).map(row => `${row.mode} ${row.appearance} ${row.foreground} on ${row.background}`);
  assert.deepEqual(failing, ['bg.surface', 'bg.sunken', 'bg.window', 'overlay.transportOpaque over stage'].map(background => `dark default line.strong on ${background}`));
});

test('the ratios design.md and tokens.json quote are the measured ones', async () => {
  const design = (await readFile(new URL('../../doc/design.md', import.meta.url), 'utf8')).split('\n');
  const measured = (foreground, background, mode) => {
    const base = channels(value(background, mode)).rgb;
    return contrast(composite(channels(value(foreground, mode)), base), base);
  };
  // [where: a phrase of the design.md line, or a token whose description quotes it; the quote; foreground, background, mode]
  const quotes = [
    ['Timecodes are right-aligned', '5.23:1 light', 'text.tertiary', 'bg.surface', 'light'],
    ['Timecodes are right-aligned', '4.56:1 dark', 'text.tertiary', 'bg.surface', 'dark'],
    ['| Pause (detected gap), uncut |', '6.29:1 dark', 'text.muted', 'bg.surface', 'dark'],
    ['| Pause (detected gap), uncut |', '5.89:1 light', 'text.muted', 'bg.surface', 'light'],
    ['| Pause, cut |', '5.28:1 dark', 'text.muted', 'pause.background', 'dark'],
    ['| Pause, cut |', '5.16:1 light', 'text.muted', 'pause.background', 'light'],
    ['| Outside the selected clip |', '6.92:1 dark', 'text.secondary', 'bg.surface', 'dark'],
    ['| Outside the selected clip |', '6.56:1 light', 'text.secondary', 'bg.surface', 'light'],
    ['**Materials.** Under Reduce Transparency', '3.31:1 dark', 'line.strong', 'bg.surface', 'dark'],
    ['**Materials.** Under Reduce Transparency', '3.41:1 light', 'line.strong', 'bg.surface', 'light'],
    ['the AI modified tag (12, 1 px', '16.34:1 light', 'accent.text', 'bg.surface', 'light'],
    ['the AI modified tag (12, 1 px', '14.01:1 dark', 'accent.text', 'bg.surface', 'dark'],
    ['- **Box:** 64 high, on `bg.sunken`', '3.49:1 dark', 'line.strong', 'bg.sunken', 'dark'],
    ['- **Box:** 64 high, on `bg.sunken`', '3.12:1 light', 'line.strong', 'bg.sunken', 'light'],
    ['The transcript draws its own selection', '9.55:1 light', 'text.primary', 'selection.transcript', 'light'],
    ['The transcript draws its own selection', '5.33:1 dark', 'text.primary', 'selection.transcript', 'dark'],
    ['Below a minimum on purpose', 'dark 3.03:1 on `editor.band`', 'gutter.text', 'editor.band', 'dark'],
    ['Below a minimum on purpose', 'dark 1.38:1 on `bg.surface`', 'line.edge', 'bg.surface', 'dark'],
    ['Below a minimum on purpose', 'dark 3.31:1 on `bg.surface`', 'line.strong', 'bg.surface', 'dark'],
    ['re-values the dark neutrals', '4.80:1 on chrome', 'text.tertiary', 'bg.window', 'dark'],
    ['re-values the dark neutrals', '4.56:1 on the editor', 'text.tertiary', 'bg.surface', 'dark'],
    ['re-values the dark neutrals', '4.54:1 on `editor.band`', 'word.outside', 'editor.band', 'dark'],
    ['text.primary', 'dark 14.25:1', 'text.primary', 'bg.surface', 'dark'],
    ['text.primary', 'light 16.3:1', 'text.primary', 'bg.surface', 'light'],
    ['text.tertiary', 'dark 4.80:1 on bg.window', 'text.tertiary', 'bg.window', 'dark'],
    ['text.tertiary', '4.56:1 on bg.surface', 'text.tertiary', 'bg.surface', 'dark'],
    ['bg.selectedRow', 'dark 11.79:1', 'text.primary', 'bg.selectedRow', 'dark'],
    ['line.strong', 'dark 3.31:1 on bg.surface', 'line.strong', 'bg.surface', 'dark'],
    ['line.edge', '1.38:1 on bg.surface', 'line.edge', 'bg.surface', 'dark'],
    ['accent.soft', 'light 12.80:1', 'text.primary', 'accent.soft', 'light'],
    ['accent.soft', 'dark 10.38:1', 'text.primary', 'accent.soft', 'dark'],
    ['selection.transcript', 'light 9.55:1', 'text.primary', 'selection.transcript', 'light'],
    ['selection.transcript', 'dark 5.33:1', 'text.primary', 'selection.transcript', 'dark'],
    ['tint.default', 'Dark 5.57:1 on bg.surface', 'tint.default', 'bg.surface', 'dark'],
    ['tint.default', '6.19:1 on timeline.lane', 'tint.default', 'timeline.lane', 'dark'],
    ['word.outside', 'dark 4.87:1 on bg.surface', 'word.outside', 'bg.surface', 'dark'],
    ['word.cut', 'dark 5.6:1 on bg.surface', 'word.cut', 'bg.surface', 'dark'],
    ['word.cut', '4.73:1 on pause.background', 'word.cut', 'pause.background', 'dark'],
    ['word.filler', 'dark 8.3:1', 'word.filler', 'bg.surface', 'dark'],
    ['word.filler', 'light 5.2:1', 'word.filler', 'bg.surface', 'light'],
    ['cut.stroke', 'dark 6.3:1', 'cut.stroke', 'bg.surface', 'dark'],
    ['cut.stroke', 'light 4.9:1', 'cut.stroke', 'bg.surface', 'light'],
  ];
  for (const [where, quote, foreground, background, mode] of quotes) {
    const text = /^[a-z]+\.[A-Za-z]+$/.test(where) ? token(where).$description : design.find(line => line.includes(where));
    assert.ok(text?.includes(quote), `${where} quotes "${quote}"`);
    const quoted = quote.match(/(\d+\.(\d+)):1/);
    assert.equal(measured(foreground, background, mode).toFixed(quoted[2].length), quoted[1], `${where}: ${mode} ${foreground} on ${background}`);
  }
});

test('a token with an opacity is composited at that fraction of its alpha', () => {
  const rows = contrastRows(source, xaml).filter(row => row.platform === 'tokens' && row.mode === 'dark' && row.appearance === 'default');
  const ai = rows.find(row => row.foreground === 'text.primary' && row.background === 'ai.tint@0.16 over editor.band');
  const expected = composite(channels('#6AA6FF29'), channels(value('editor.band', 'dark')).rgb).map(channel => Math.round(channel).toString(16).padStart(2, '0')).join('').toUpperCase();
  assert.equal(ai.colors, `${value('text.primary', 'dark')} on #${expected}`);
});

test('the Windows accent ramp in App.xaml is the pinned Ink ramp and leaves High Contrast alone', () => {
  const ramp = windowsRamp(xaml);
  assert.deepEqual(ramp, {
    Light: { SystemAccentColor: '#6D6F73', SystemAccentColorDark1: '#2C2E35', SystemAccentColorDark2: '#1A1B1F', SystemAccentColorDark3: '#0F1013', TextOnAccentFillColorPrimary: '#FAF9F6' },
    Default: { SystemAccentColor: '#6D6F73', SystemAccentColorLight1: '#D2D1CC', SystemAccentColorLight2: '#ECEAE4', SystemAccentColorLight3: '#FAF9F6', TextOnAccentFillColorPrimary: '#141517' },
  });
  assert.equal(ramp.Light.SystemAccentColor, value('accent.default', 'dark'));
  assert.equal(ramp.Light.SystemAccentColorDark1, value('accent.default', 'light'));
  assert.equal(ramp.Light.SystemAccentColorDark2, value('accent.pressed', 'light'));
  assert.equal(ramp.Light.TextOnAccentFillColorPrimary, value('accent.on', 'light'));
  assert.equal(ramp.Default.SystemAccentColor, value('accent.default', 'dark'));
  assert.equal(ramp.Default.SystemAccentColorLight2, value('accent.text', 'dark'));
  const rows = contrastRows(source, xaml).filter(row => row.platform === 'windows');
  for (const [mode, keys] of [['light', Object.keys(ramp.Light)], ['dark', Object.keys(ramp.Default)]]) {
    for (const key of keys) assert.ok(rows.some(row => row.mode === mode && [row.foreground, ...row.background.split(' over ')].some(layer => layer.split('@')[0] === key)), `${mode} ${key} is measured`);
  }
});
