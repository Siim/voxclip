import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { appXamlPath, channels, composite, contrast, contrastRows, coverage, materials, minimums, windowsRamp } from './contrast.mjs';

const source = JSON.parse(await readFile(new URL('../../shared/design/tokens.json', import.meta.url), 'utf8'));
const xaml = await readFile(new URL(`../../${appXamlPath}`, import.meta.url), 'utf8');
const value = (path, mode) => path.split('.').reduce((node, part) => node[part], source.color).$value[mode];

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
    ['text', 'text.secondary', 'clip.badgeBackground over bg.surface'],
    ['text', 'text.secondary', 'clip.badgeBackground over bg.sunken'],
    ['text', 'text.secondary', 'clip.badgeBackground over glass.sidebar over bg.surface'],
    ['text', 'text.primary', 'selection.transcript'],
    ['ui', 'line.strong', 'bg.sunken'],
  ];
  for (const mode of ['light', 'dark']) {
    for (const [category, foreground, background] of required) {
      const row = rows.find(candidate => candidate.platform === 'tokens' && candidate.mode === mode && candidate.foreground === foreground && candidate.background === background);
      assert.ok(row?.category === category && row.minimum === minimums[category] && row.passed, `${mode} ${foreground} on ${background}`);
    }
  }
  assert.deepEqual(Object.keys(materials['glass.sidebar']).sort(), ['dark', 'light']);
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
  assert.deepEqual(coverage(source), { missing: [], staleExemptions: [] });
});

test('the Windows accent ramp in App.xaml matches the tokens and leaves High Contrast alone', () => {
  const ramp = windowsRamp(xaml);
  assert.deepEqual(Object.keys(ramp).sort(), ['Default', 'Light']);
  assert.deepEqual(Object.keys(ramp.Light).sort(), ['SystemAccentColorDark1', 'SystemAccentColorDark2', 'SystemAccentColorDark3', 'TextOnAccentFillColorPrimary']);
  assert.deepEqual(Object.keys(ramp.Default).sort(), ['SystemAccentColor', 'SystemAccentColorLight1', 'SystemAccentColorLight2', 'SystemAccentColorLight3', 'TextOnAccentFillColorPrimary']);
  assert.equal(ramp.Light.SystemAccentColorDark1, value('accent.default', 'light'));
  assert.equal(ramp.Light.SystemAccentColorDark2, value('accent.pressed', 'light'));
  assert.equal(ramp.Light.TextOnAccentFillColorPrimary, value('accent.on', 'light'));
  assert.equal(ramp.Default.SystemAccentColor, value('accent.default', 'dark'));
  assert.equal(ramp.Default.SystemAccentColorLight2, value('accent.text', 'dark'));
  assert.notEqual(ramp.Default.TextOnAccentFillColorPrimary, '#000000');
});
