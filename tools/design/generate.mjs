import { mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const header = 'GENERATED from shared/design/tokens.json - do not edit';
const namespace = 'com.voxconvo.voxclip';
const swiftTarget = 'apps/macos/Sources/VoxClip/Design/Tokens.swift';
const xamlTarget = 'apps/windows/src/VoxClip.App/Themes/Tokens.xaml';
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
  const addConstant = (parts, value, resourceParts = parts) => {
    const name = `Vc${suffix(resourceParts)}`;
    swiftValues.push(`    static let ${swiftName(parts)}: ${typeof value === 'number' ? 'CGFloat' : 'String'} = ${typeof value === 'number' ? value : quote(value)}`);
    addResource(name, `    <x:${typeof value === 'number' ? 'Double' : 'String'} x:Key="${name}">${xml(value)}</x:${typeof value === 'number' ? 'Double' : 'String'}>`);
  };

  for (const token of tokens) {
    if (['color', 'typography', 'fontFamily'].includes(token.$type)) continue;
    if (!['dimension', 'duration', 'cubicBezier', 'spring', 'string'].includes(token.$type)) throw new Error(`Unsupported token type ${token.$type}`);
    const labels = token.$type === 'dimension' ? ['width', 'height'] : ['x1', 'y1', 'x2', 'y2'];
    const values = flatten(token.$value, token.path, labels);
    constants.push(...values);
    for (const item of values) {
      addConstant(item.path, item.value);
      if (typeof item.value === 'number' && ['spacing', 'stroke', 'radius'].includes(item.path[0])) {
        const type = item.path[0] === 'radius' ? 'CornerRadius' : 'Thickness';
        const name = `Vc${suffix(item.path)}${type}`;
        addResource(name, `    <${type} x:Key="${name}">${item.value}</${type}>`);
      }
    }
  }

  for (const token of families) {
    const { details, files, monospaced } = fontDetails(token);
    const family = token.path.at(-1);
    const present = files.filter(([, metadata]) => metadata.present);
    const swiftFiles = present.map(([file, metadata]) => `${metadata.weight}: ${quote(file)}`).join(', ');
    const defaultWeight = Math.min(...files.map(([, metadata]) => metadata.weight));
    if (!Number.isFinite(defaultWeight)) throw new Error(`Missing font files: ${family}`);
    fontLoaders.push(`    static func ${family}(size: CGFloat, weight: Int) -> Font {\n        let files: [Int: String] = ${present.length ? `[${swiftFiles}]` : '[:]'}\n        return load(file: files[weight], size: size, weight: weight, monospaced: ${monospaced})\n    }`);
    swiftFonts.push(`    @MainActor static func vc${capitalize(family)}(size: CGFloat, weight: Int = ${defaultWeight}) -> Font {\n        VoxClipTokenFonts.${family}(size: size, weight: weight)\n    }`);
    const windowsFamily = [...present.map(([file]) => `ms-appx:///shared/fonts/${file}#${token.$value}`), details.fallbackWindows].join(', ');
    const name = `VcFont${capitalize(family)}`;
    addResource(name, `    <FontFamily x:Key="${name}">${xml(windowsFamily)}</FontFamily>`);
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
    if (!family && macos.fontFamily !== 'system') throw new Error(`Unknown font family ${macos.fontFamily}`);
    const call = family ? `VoxClipTokenFonts.${family.path.at(-1)}(size: size, weight: ${macos.fontWeight})`
      : `Font.system(size: size, weight: .${fontWeight(macos.fontWeight)})`;
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
  const themes = ['Default', 'Light', 'HighContrast'].map(theme => `        <ResourceDictionary x:Key="${theme}">\n${colors.map(token => `            ${xamlColor(token, theme)}`).join('\n')}\n        </ResourceDictionary>`);
  const xaml = `<!-- ${header} -->
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <ResourceDictionary.ThemeDictionaries>
${themes.join('\n')}
    </ResourceDictionary.ThemeDictionaries>
${xamlValues.join('\n')}
</ResourceDictionary>
`;
  return { swift, xaml, colorCount: colors.length, constantCount: constants.length };
}

async function main() {
  const arguments_ = process.argv.slice(2);
  if (arguments_.length > 1 || (arguments_.length === 1 && arguments_[0] !== '--check')) throw new Error('Usage: node generate.mjs [--check]');
  const check = arguments_[0] === '--check';
  const source = JSON.parse(await readFile(path.join(root, 'shared/design/tokens.json'), 'utf8'));
  const output = buildOutputs(source);
  let drift = false;
  for (const [relative, text] of [[swiftTarget, output.swift], [xamlTarget, output.xaml]]) {
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
