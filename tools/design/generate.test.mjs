import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, readdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { buildOutputs, rgbaToArgb } from './generate.mjs';

const source = JSON.parse(await readFile(new URL('../../shared/design/tokens.json', import.meta.url), 'utf8'));

test('Mac generation omits ADR-R29 deprecated layout symbols without changing Windows', () => {
  const output = buildOutputs(source);
  assert.ok(!output.swift.includes('WelcomeWindow'));
  assert.ok(!output.swift.includes('TransportPill'));
  assert.ok(output.xaml.includes('WelcomeWindow'));
});

test('generation is byte deterministic and names every colour in all themes', () => {
  const first = buildOutputs(source);
  assert.deepEqual(first, buildOutputs(structuredClone(source)));
  assert.equal((first.swift.match(/static let vc\w+ = Color/g) ?? []).length, first.colorCount);
  for (const name of first.swift.matchAll(/static let (vc\w+) = Color/g)) {
    const key = `Vc${name[1].slice(2)}Brush`;
    assert.equal(first.xaml.split(`x:Key="${key}"`).length - 1, 3, key);
  }
  for (const theme of ['Default', 'Light', 'HighContrast']) assert.ok(first.xaml.includes(`x:Key="${theme}"`));
});

test('colours preserve straight alpha and use platform resources without hex substitutes', () => {
  assert.equal(rgbaToArgb('#F38F83B3'), '#B3F38F83');
  assert.equal(rgbaToArgb('#ffffff'), '#FFFFFF');
  assert.throws(() => rgbaToArgb('#bad'));
  const output = buildOutputs(source);
  assert.ok(output.swift.includes('NSColor.selectedTextBackgroundColor'));
  assert.ok(output.xaml.includes('x:Key="VcSelectionTextBrush" Color="{ThemeResource SystemAccentColor}" Opacity="0.4"'));
  const brush = structuredClone(source);
  brush.color.status.success.$value = { dark: 'system:green', light: 'system:green' };
  brush.color.status.success.$extensions['com.voxconvo.voxclip'] = { macos: 'NSColor.systemGreen', windows: 'SystemFillColorSuccessBrush', windowsHighContrast: 'SystemColorWindowTextColor' };
  const aliased = buildOutputs(brush);
  assert.ok(aliased.swift.includes('NSColor.systemGreen'));
  assert.ok(aliased.xaml.includes('x:Key="VcStatusSuccessBrush" ResourceKey="SystemFillColorSuccessBrush"'));
});

test('numeric, typography and colour values come only from the source tokens', () => {
  const changed = structuredClone(source);
  changed.color.text.primary.$value.dark = '#12345678';
  changed.spacing.panePaddingWindows.$value = 37;
  changed.typography.body.$value.macos.fontSize = 19;
  const output = buildOutputs(changed);
  assert.ok(output.swift.includes('NSColor(srgbRed: 18.0 / 255, green: 52.0 / 255, blue: 86.0 / 255, alpha: 120.0 / 255)'));
  assert.ok(output.xaml.includes('x:Key="VcTextPrimaryBrush" Color="#78123456"'));
  assert.ok(output.xaml.includes('x:Key="VcSpacingPanePaddingWindows">37</x:Double>'));
  assert.ok(output.swift.includes('typographyBodyFontSize: CGFloat = 19'));
});

test('font URLs, missing-file fallbacks and dimensional resources are generated', () => {
  const output = buildOutputs(source);
  assert.ok(output.swift.includes('SharedResources.locate()'));
  assert.ok(output.swift.includes('CTFontManagerRegisterFontsForURL(url as CFURL'));
  assert.ok(output.swift.includes('500: "dm-sans/DMSans-Medium.ttf"'));
  assert.ok(!output.swift.includes('"geist-mono/GeistMono-Regular.ttf"'));
  // The video-only families stay on the Mac (Font.vcDmSans and vcGeistMono); Windows renders them from the font files.
  assert.ok(output.swift.includes('static func vcGeistMono(size: CGFloat'));
  assert.ok(!/VcFont(DmSans|GeistMono)|<FontFamily |ms-appx:\/\/\/shared\/fonts/.test(output.xaml));
  assert.ok(output.xaml.includes('<CornerRadius x:Key="VcRadiusLgCornerRadius">12</CornerRadius>'));
  assert.ok(output.xaml.includes('<Thickness x:Key="VcSpacingPanePaddingWindowsThickness">16</Thickness>'));
  assert.ok(output.swift.includes('static let sizeCaptionTileAspect: CGFloat = 0.45'));
  assert.ok(output.xaml.includes('<x:Double x:Key="VcSizeCaptionTileAspect">0.45</x:Double>'));
});

test('a windows extension replaces a dimension in Tokens.xaml only', () => {
  const output = buildOutputs(source);
  assert.ok(output.swift.includes('static let spacingTranscriptGutter: CGFloat = 84'));
  assert.ok(output.xaml.includes('<x:Double x:Key="VcSpacingTranscriptGutter">76</x:Double>'));
  assert.ok(output.xaml.includes('<Thickness x:Key="VcSpacingTranscriptGutterThickness">76</Thickness>'));
  assert.ok(output.swift.includes('static let sizeSidebarIdeal: CGFloat = 252'));
  assert.ok(output.xaml.includes('<x:Double x:Key="VcSizeSidebar">264</x:Double>'));
  assert.ok(!output.xaml.includes('VcSizeSidebarIdeal'));
  assert.ok(output.xaml.includes('<x:Double x:Key="VcSizeRightColumnIdeal">388</x:Double>'));
  const changed = structuredClone(source);
  changed.size.timelineHeight.$extensions = { 'com.voxconvo.voxclip': { windows: 80 } };
  const overridden = buildOutputs(changed);
  assert.ok(overridden.swift.includes('static let sizeTimelineHeight: CGFloat = 72'));
  assert.ok(overridden.xaml.includes('<x:Double x:Key="VcSizeTimelineHeight">80</x:Double>'));
  changed.size.timelineHeight.$extensions['com.voxconvo.voxclip'].windows = [Number.NaN];
  assert.throws(() => buildOutputs(changed), /Non-finite token/);
});

test('system typography uses the system font, and SF Mono its monospaced design', () => {
  const output = buildOutputs(source);
  assert.ok(output.swift.includes('static func vcTranscript(size: CGFloat = VCTokens.typographyTranscriptFontSize) -> Font {\n        Font.system(size: size, weight: .regular)\n'));
  assert.ok(output.swift.includes('static func vcTimecode(size: CGFloat = VCTokens.typographyTimecodeFontSize) -> Font {\n        Font.system(size: size, weight: .medium, design: .monospaced).monospacedDigit()'));
  const brand = structuredClone(source);
  brand.typography.timecode.$value.macos.fontFamily = 'Geist Mono';
  assert.ok(buildOutputs(brand).swift.includes('VoxClipTokenFonts.geistMono(size: size, weight: 500).monospacedDigit()'));
  brand.typography.timecode.$value.macos.fontFamily = 'SF Pro Rounded';
  assert.throws(() => buildOutputs(brand), /Unknown font family SF Pro Rounded/);
});

test('the macOS AccentColor asset comes from the flagged token in both appearances', () => {
  const output = buildOutputs(source);
  assert.deepEqual(output.assets.map(([relative]) => relative), ['apps/macos/Resources/Assets.xcassets/AccentColor.colorset/Contents.json']);
  const components = value => ({ alpha: '1.000', blue: `0x${value.slice(5, 7)}`, green: `0x${value.slice(3, 5)}`, red: `0x${value.slice(1, 3)}` });
  const [any, dark] = JSON.parse(output.assets[0][1]).colors;
  assert.equal(any.appearances, undefined);
  assert.deepEqual(any.color.components, components(source.color.accent.default.$value.light));
  assert.deepEqual(dark.appearances, [{ appearance: 'luminosity', value: 'dark' }]);
  assert.deepEqual(dark.color.components, components(source.color.accent.default.$value.dark));
  const translucent = structuredClone(source);
  translucent.color.accent.default.$value.dark = '#6D6F7380';
  assert.equal(JSON.parse(buildOutputs(translucent).assets[0][1]).colors[1].color.components.alpha, '0.502');
  const system = structuredClone(source);
  system.color.accent.default.$value.light = 'system:green';
  Object.assign(system.color.accent.default.$extensions['com.voxconvo.voxclip'], { macos: 'NSColor.systemGreen', windows: 'SystemAccentColor' });
  assert.throws(() => buildOutputs(system), /macOS asset colours must be hex/);
  const named = structuredClone(source);
  named.color.accent.default.$extensions['com.voxconvo.voxclip'].macosAsset = '../Accent';
  assert.throws(() => buildOutputs(named), /Invalid macOS asset name/);
});

test('unknown formats, missing system mappings and unsafe font paths fail clearly', () => {
  const changed = structuredClone(source);
  changed.$extensions['com.voxconvo.voxclip'].format = 'future';
  assert.throws(() => buildOutputs(changed), /Expected voxclip-tokens\/1/);
  const system = structuredClone(source);
  delete system.color.selection.text.$extensions['com.voxconvo.voxclip'].macos;
  assert.throws(() => buildOutputs(system), /Missing macOS system colour/);
  const fonts = structuredClone(source);
  fonts.fontFiles.dmSans.$extensions['com.voxconvo.voxclip'].files['../unsafe.ttf'] = { weight: 400, present: true };
  assert.throws(() => buildOutputs(fonts), /Invalid font path/);
});

test('CLI detects drift and missing files through symlinked paths without writing', async () => {
  const temporary = await mkdtemp(path.join(tmpdir(), 'voxclip-token-check-'));
  try {
    const copied = path.join(temporary, 'repository');
    const linked = path.join(temporary, 'linked');
    const swiftPath = 'apps/macos/Sources/VoxClip/Design/Tokens.swift';
    const xamlPath = 'apps/windows/src/VoxClip.App/Themes/Tokens.xaml';
    const assetPath = 'apps/macos/Resources/Assets.xcassets/AccentColor.colorset/Contents.json';
    for (const relative of ['tools/design/generate.mjs', 'shared/design/tokens.json', swiftPath, xamlPath, assetPath]) {
      const destination = path.join(copied, relative);
      await mkdir(path.dirname(destination), { recursive: true });
      await copyFile(new URL(`../../${relative}`, import.meta.url), destination);
    }
    await symlink(copied, linked, 'dir');
    const generator = path.join(linked, 'tools/design/generate.mjs');
    const run = (arguments_, status) => {
      const result = spawnSync(process.execPath, [generator, ...arguments_], { encoding: 'utf8' });
      assert.equal(result.status, status, result.stdout + result.stderr);
      return result;
    };
    run(['--check'], 0);
    const swift = path.join(copied, swiftPath);
    const drifted = await readFile(swift, 'utf8') + '\n';
    await writeFile(swift, drifted);
    assert.match(run(['--check'], 1).stderr, /drift:/);
    assert.equal(await readFile(swift, 'utf8'), drifted);
    run([], 0);
    run(['--check'], 0);
    await rm(path.join(copied, xamlPath));
    run(['--check'], 1);
    await assert.rejects(readFile(path.join(copied, xamlPath)), { code: 'ENOENT' });
    run([], 0);
    run(['--check'], 0);
    await rm(path.join(copied, 'apps/macos/Resources'), { recursive: true });
    assert.match(run(['--check'], 1).stderr, /drift: apps\/macos\/Resources\/Assets\.xcassets\/AccentColor\.colorset/);
    run([], 0);
    run(['--check'], 0);
    const stale = path.join(copied, 'apps/macos/Resources/Assets.xcassets/OldAccent.colorset/Contents.json');
    await mkdir(path.dirname(stale), { recursive: true });
    await writeFile(stale, '{}\n');
    await writeFile(path.join(copied, 'apps/macos/Resources/Assets.xcassets/.DS_Store'), '');
    assert.match(run(['--check'], 1).stderr, /drift: apps\/macos\/Resources\/Assets\.xcassets\/OldAccent\.colorset\/Contents\.json is not generated/);
    assert.equal(await readFile(stale, 'utf8'), '{}\n');
    assert.match(run([], 0).stdout, /removed apps\/macos\/Resources\/Assets\.xcassets\/OldAccent\.colorset\/Contents\.json/);
    await assert.rejects(readdir(path.dirname(stale)), { code: 'ENOENT' });
    run(['--check'], 0);
    run(['--unknown'], 1);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
