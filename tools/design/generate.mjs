import { mkdir, readdir, readFile, realpath, rm, rmdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const header = 'GENERATED from shared/design/tokens.json - do not edit';
const namespace = 'com.voxconvo.voxclip';
const swiftTarget = 'apps/macos/Sources/VoxClip/Design/Tokens.swift';
const xamlTarget = 'apps/windows/src/VoxClip.App/Themes/Tokens.xaml';
const assetCatalog = 'apps/macos/Resources/Assets.xcassets';
// macOS typography families that are the system font rather than a fontFiles token.
const systemDesigns = { system: '', 'SF Mono': ', design: .monospaced' };
const capitalize = value => value[0].toUpperCase() + value.slice(1);
const suffix = parts => parts.map(capitalize).join('');
const swiftName = parts => parts[0] + suffix(parts.slice(1));
const extensions = token => token.$extensions?.[namespace] ?? {};
const quote = value => JSON.stringify(value);
const xml = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

function collect(value, parts = []) {
  if (Object.hasOwn(value, '$value')) return [{ path: parts, ...value }];
  return Object.entries(value).filter(([key]) => !key.startsWith('$'))
    .flatMap(([key, child]) => collect(child, [...parts, key]));
}

export function rgbaToArgb(value) {
  if (!/^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/i.test(value)) throw new Error(`Invalid colour ${value}`);
  return (value.length === 9 ? `#${value.slice(7)}${value.slice(1, 7)}` : value).toUpperCase();
}

function swiftColor(value, token) {
  if (value.startsWith('system:')) {
    const native = extensions(token).macos;
    if (!/^NSColor\.[A-Za-z][A-Za-z0-9]*$/.test(native ?? '')) throw new Error(`Missing macOS system colour: ${token.path.join('.')}`);
    return native;
  }
  rgbaToArgb(value);
  const bytes = value.slice(1).match(/../g).map(byte => Number.parseInt(byte, 16));
  if (bytes.length === 3) bytes.push(255);
  return `NSColor(srgbRed: ${bytes[0]}.0 / 255, green: ${bytes[1]}.0 / 255, blue: ${bytes[2]}.0 / 255, alpha: ${bytes[3]}.0 / 255)`;
}

function assetColor(value, token) {
  if (!/^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/i.test(value ?? '')) throw new Error(`macOS asset colours must be hex: ${token.path.join('.')}`);
  const [red, green, blue, alpha = 'FF'] = value.slice(1).toUpperCase().match(/../g);
  return { 'color-space': 'srgb', components: { alpha: (Number.parseInt(alpha, 16) / 255).toFixed(3), blue: `0x${blue}`, green: `0x${green}`, red: `0x${red}` } };
}

function xamlColor(token, theme) {
  const name = `Vc${suffix(token.path.slice(1))}Brush`;
  const value = theme === 'HighContrast' ? extensions(token).windowsHighContrast : token.$value[theme === 'Light' ? 'light' : 'dark'];
  if (typeof value !== 'string') throw new Error(`Missing ${theme} colour: ${token.path.join('.')}`);
  if (value.startsWith('#')) return `<SolidColorBrush x:Key="${name}" Color="${rgbaToArgb(value)}" />`;
  const native = value.startsWith('system:') ? extensions(token).windows : value;
  const mapping = /^([A-Za-z][A-Za-z0-9]*)(?: at ([0-9]+(?:\.[0-9]+)?)% opacity)?$/.exec(native ?? '');
  if (!mapping || Number(mapping[2] ?? 100) > 100) throw new Error(`Invalid Windows system resource: ${token.path.join('.')}`);
  const resource = mapping[1];
  if (resource.endsWith('Brush')) {
    if (mapping[2]) throw new Error(`Brush aliases cannot override opacity: ${token.path.join('.')}`);
    return `<StaticResource x:Key="${name}" ResourceKey="${resource}" />`;
  }
  const opacity = mapping[2] ? ` Opacity="${Number(mapping[2]) / 100}"` : '';
  return `<SolidColorBrush x:Key="${name}" Color="{ThemeResource ${resource}}"${opacity} />`;
}

function flatten(value, parts, labels = []) {
  if (Array.isArray(value)) return value.flatMap((entry, index) => flatten(entry, [...parts, labels[index] ?? `item${index}`]));
  if (value !== null && typeof value === 'object') return Object.entries(value).flatMap(([key, entry]) => flatten(entry, [...parts, key]));
  if (typeof value !== 'number' && typeof value !== 'string') throw new Error(`Unsupported token value: ${parts.join('.')}`);
  if (typeof value === 'number' && !Number.isFinite(value)) throw new Error(`Non-finite token: ${parts.join('.')}`);
  return [{ path: parts, value }];
}

function fontWeight(weight) {
  const names = { 100: 'ultraLight', 200: 'thin', 300: 'light', 400: 'regular', 500: 'medium', 600: 'semibold', 700: 'bold', 800: 'heavy', 900: 'black' };
  if (!names[weight]) throw new Error(`Unsupported font weight ${weight}`);
  return names[weight];
}

function fontDetails(token) {
  const details = extensions(token);
  const files = Object.entries(details.files ?? {});
  for (const [file, metadata] of files) {
    if (path.posix.isAbsolute(file) || file.split('/').includes('..')) throw new Error(`Invalid font path ${file}`);
    fontWeight(metadata.weight);
  }
  return { details, files, monospaced: details.fallbackMacos === 'SF Mono' };
}

export function buildOutputs(source) {
  if (source.$extensions?.[namespace]?.format !== 'voxclip-tokens/1') throw new Error('Expected voxclip-tokens/1');
  const tokens = collect(source);
  const colors = tokens.filter(token => token.$type === 'color');
  const families = tokens.filter(token => token.$type === 'fontFamily');
  const typography = tokens.filter(token => token.$type === 'typography');
  const constants = [];
  const swiftValues = [];
  const xamlValues = [];
  const swiftFonts = [];
  const fontLoaders = [];
  const names = new Set();
  const addResource = (name, markup) => {
    if (names.has(name)) throw new Error(`Duplicate generated resource ${name}`);
    names.add(name);
    xamlValues.push(markup);
  };
  const addConstant = (parts, value) => {
    const name = `Vc${suffix(parts)}`;
    addResource(name, `    <x:${typeof value === 'number' ? 'Double' : 'String'} x:Key="${name}">${xml(value)}</x:${typeof value === 'number' ? 'Double' : 'String'}>`);
  };

  for (const token of tokens) {
    if (['color', 'typography', 'fontFamily'].includes(token.$type)) continue;
    if (!['dimension', 'number', 'duration', 'cubicBezier', 'spring', 'string'].includes(token.$type)) throw new Error(`Unsupported token type ${token.$type}`);
    const labels = token.$type === 'dimension' ? ['width', 'height'] : ['x1', 'y1', 'x2', 'y2'];
    const values = flatten(token.$value, token.path, labels);
    constants.push(...values);
    if (!token.$description?.startsWith('deprecated by ADR-R29')) {
      for (const item of values) swiftValues.push(`    static let ${swiftName(item.path)}: ${typeof item.value === 'number' ? 'CGFloat' : 'String'} = ${typeof item.value === 'number' ? item.value : quote(item.value)}`);
    }
    // $value is the macOS value; a `windows` extension replaces it in Tokens.xaml only.
    const windows = extensions(token).windows;
    for (const item of windows === undefined ? values : flatten(windows, token.path, labels)) {
      addConstant(item.path, item.value);
      if (typeof item.value === 'number' && ['spacing', 'stroke', 'radius'].includes(item.path[0])) {
        const type = item.path[0] === 'radius' ? 'CornerRadius' : 'Thickness';
        const name = `Vc${suffix(item.path)}${type}`;
        addResource(name, `    <${type} x:Key="${name}">${item.value}</${type}>`);
      }
    }
  }

  for (const token of families) {
    const { files, monospaced } = fontDetails(token);
    const family = token.path.at(-1);
    const present = files.filter(([, metadata]) => metadata.present);
    const swiftFiles = present.map(([file, metadata]) => `${metadata.weight}: ${quote(file)}`).join(', ');
    const defaultWeight = Math.min(...files.map(([, metadata]) => metadata.weight));
    if (!Number.isFinite(defaultWeight)) throw new Error(`Missing font files: ${family}`);
    fontLoaders.push(`    static func ${family}(size: CGFloat, weight: Int) -> Font {\n        let files: [Int: String] = ${present.length ? `[${swiftFiles}]` : '[:]'}\n        return load(file: files[weight], size: size, weight: weight, monospaced: ${monospaced})\n    }`);
    swiftFonts.push(`    @MainActor static func vc${capitalize(family)}(size: CGFloat, weight: Int = ${defaultWeight}) -> Font {\n        VoxClipTokenFonts.${family}(size: size, weight: weight)\n    }`);
    // Tokens.xaml has no FontFamily for these: DM Sans and Geist Mono appear only in rendered video (design section 16),
    // and the Windows caption renderer reads the shared font files itself.
    swiftValues.push(`    static let font${capitalize(family)}: String = ${quote(token.$value)}`);
  }

  for (const token of typography) {
    const kind = token.path.at(-1);
    const macos = token.$value.macos;
    const windows = token.$value.windows;
    for (const item of flatten(macos, token.path)) {
      swiftValues.push(`    static let ${swiftName(item.path)}: ${typeof item.value === 'number' ? 'CGFloat' : 'String'} = ${typeof item.value === 'number' ? item.value : quote(item.value)}`);
    }
    for (const item of flatten(windows, [kind])) {
      const name = `Vc${suffix(item.path)}`;
      const type = typeof item.value === 'number' ? 'x:Double' : 'x:String';
      addResource(name, `    <${type} x:Key="${name}">${xml(item.value)}</${type}>`);
    }
    const family = families.find(candidate => candidate.$value === macos.fontFamily);
    if (!family && !Object.hasOwn(systemDesigns, macos.fontFamily)) throw new Error(`Unknown font family ${macos.fontFamily}`);
    const call = family ? `VoxClipTokenFonts.${family.path.at(-1)}(size: size, weight: ${macos.fontWeight})`
      : `Font.system(size: size, weight: .${fontWeight(macos.fontWeight)}${systemDesigns[macos.fontFamily]})`;
    swiftFonts.push(`    @MainActor static func vc${capitalize(kind)}(size: CGFloat = VCTokens.${swiftName(token.path)}FontSize) -> Font {\n        ${call}${macos.features?.includes('tnum') ? '.monospacedDigit()' : ''}\n    }`);
  }

  const colorDeclarations = colors.map(token => {
    const name = `vc${suffix(token.path.slice(1))}`;
    return `    static let ${name} = Color(nsColor: NSColor(name: NSColor.Name(${quote(name)})) { appearance in\n        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua\n            ? ${swiftColor(token.$value.dark, token)}\n            : ${swiftColor(token.$value.light, token)}\n    })`;
  });
  const swift = `// ${header}
import AppKit
import CoreText
import SwiftUI
import VoxClipCore

extension Color {
${colorDeclarations.join('\n\n')}
}

enum VCTokens {
${swiftValues.join('\n')}
}

extension Font {
${swiftFonts.join('\n\n')}
}

@MainActor private enum VoxClipTokenFonts {
    private static var descriptors: [String: CTFontDescriptor] = [:]

    private static func load(file: String?, size: CGFloat, weight: Int, monospaced: Bool) -> Font {
        let fallback = Font.system(size: size, weight: fontWeight(weight), design: monospaced ? .monospaced : .default)
        guard let file, let shared = try? SharedResources.locate() else { return fallback }
        if descriptors[file] == nil {
            let url = shared.root.appendingPathComponent("fonts", isDirectory: true).appendingPathComponent(file)
            guard let available = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = available.first else { return fallback }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            descriptors[file] = descriptor
        }
        guard let descriptor = descriptors[file] else { return fallback }
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    private static func fontWeight(_ weight: Int) -> Font.Weight {
        switch weight {
${[100, 200, 300, 400, 500, 600, 700, 800, 900].map(weight => `        case ${weight}: .${fontWeight(weight)}`).join('\n')}
        default: .regular
        }
    }

${fontLoaders.join('\n\n')}
}
`;
  const assets = colors.filter(token => extensions(token).macosAsset !== undefined).map(token => {
    const name = extensions(token).macosAsset;
    if (!/^[A-Za-z][A-Za-z0-9]*$/.test(name)) throw new Error(`Invalid macOS asset name: ${token.path.join('.')}`);
    const contents = {
      colors: [
        { color: assetColor(token.$value.light, token), idiom: 'universal' },
        { appearances: [{ appearance: 'luminosity', value: 'dark' }], color: assetColor(token.$value.dark, token), idiom: 'universal' },
      ],
      info: { author: header, version: 1 },
    };
    return [`${assetCatalog}/${name}.colorset/Contents.json`, `${JSON.stringify(contents, null, 2)}\n`];
  });
  if (new Set(assets.map(([relative]) => relative)).size !== assets.length) throw new Error('Duplicate macOS asset name');
  const themes = ['Default', 'Light', 'HighContrast'].map(theme => `        <ResourceDictionary x:Key="${theme}">\n${colors.map(token => `            ${xamlColor(token, theme)}`).join('\n')}\n        </ResourceDictionary>`);
  const xaml = `<!-- ${header} -->
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <ResourceDictionary.ThemeDictionaries>
${themes.join('\n')}
    </ResourceDictionary.ThemeDictionaries>
${xamlValues.join('\n')}
</ResourceDictionary>
`;
  return { swift, xaml, assets, colorCount: colors.length, constantCount: constants.length };
}

// Every file under the asset catalog, relative to the repository, except Finder metadata.
async function catalogFiles(directory = path.join(root, assetCatalog)) {
  let entries;
  try { entries = await readdir(directory, { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  const files = await Promise.all(entries.filter(entry => entry.name !== '.DS_Store').map(entry => entry.isDirectory()
    ? catalogFiles(path.join(directory, entry.name))
    : [path.relative(root, path.join(directory, entry.name)).split(path.sep).join('/')]));
  return files.flat().sort();
}

async function main() {
  const arguments_ = process.argv.slice(2);
  if (arguments_.length > 1 || (arguments_.length === 1 && arguments_[0] !== '--check')) throw new Error('Usage: node generate.mjs [--check]');
  const check = arguments_[0] === '--check';
  const source = JSON.parse(await readFile(path.join(root, 'shared/design/tokens.json'), 'utf8'));
  const output = buildOutputs(source);
  let drift = false;
  // The generator owns the asset catalog, which bundle.sh compiles whole: a file it does not
  // produce is drift in --check and removed by generate, so a stale colorset cannot ship.
  const produced = new Set(output.assets.map(([relative]) => relative));
  for (const relative of await catalogFiles()) {
    if (produced.has(relative)) continue;
    if (check) { drift = true; console.error(`drift: ${relative} is not generated from tokens.json`); continue; }
    await rm(path.join(root, relative));
    for (let directory = path.dirname(relative); directory !== assetCatalog && directory.startsWith(`${assetCatalog}/`); directory = path.dirname(directory)) {
      if ((await readdir(path.join(root, directory))).length > 0) break;
      await rmdir(path.join(root, directory));
    }
    console.log(`removed ${relative}`);
  }
  for (const [relative, text] of [[swiftTarget, output.swift], [xamlTarget, output.xaml], ...output.assets]) {
    const destination = path.join(root, relative);
    if (check) {
      let existing;
      try { existing = await readFile(destination, 'utf8'); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (existing !== text) { drift = true; console.error(`drift: ${relative}`); }
      else console.log(`ok ${relative}`);
    } else {
      await mkdir(path.dirname(destination), { recursive: true });
      await writeFile(destination, text);
      console.log(`wrote ${relative}`);
    }
  }
  if (drift) process.exitCode = 1;
}

if (process.argv[1] && await realpath(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(`design tokens: ${error.message}`); process.exitCode = 1; });
}
