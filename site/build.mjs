// Static and offline: tokens + a saved GitHub latest-release response, no API calls.
import { readFile, mkdir, writeFile, copyFile } from 'node:fs/promises';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readMedia, verifyMedia } from './media.mjs';

export const site = dirname(fileURLToPath(import.meta.url));
const root = resolve(site, '..');
export const repository = 'https://github.com/Siim/voxclip';
export const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));

function tokenProperties(tokens) {
  const properties = {};
  function visit(node, path = []) {
    if (node.$type === 'color') {
      const value = node.$value.dark;
      // Native system values stay native; the site does not use these tokens.
      if (value.startsWith('system:')) return;
      if (!/^#[\da-f]{6}([\da-f]{2})?$/i.test(value)) throw new Error(`Invalid color ${path.join('.')}`);
      properties[`--${path.join('-')}`] = value;
    } else if (['dimension', 'duration'].includes(node.$type) && typeof node.$value === 'number') {
      properties[`--${path.join('-')}`] = `${node.$value}${node.$type === 'duration' ? 'ms' : 'px'}`;
    } else if (!node.$type) {
      for (const [key, child] of Object.entries(node)) if (!key.startsWith('$') && typeof child === 'object' && child) visit(child, [...path, key]);
    }
  }
  visit(tokens);
  return properties;
}

function tokenCSS(tokens) {
  const properties = Object.entries(tokenProperties(tokens)).map(([key, value]) => `  ${key}: ${value};`).join('\n');
  return `/* Built from shared/design/tokens.json. */\n:root {\n  color-scheme: dark;\n${properties}\n}\n`;
}

function safeURL(value, prefix) {
  if (typeof value !== 'string' || !value.startsWith(prefix) || /[\s<>"']/.test(value)) throw new Error('Unexpected release URL');
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.hostname !== 'github.com' || url.search || url.hash || url.username || url.password) throw new Error('Unexpected release URL');
  return escapeHTML(value);
}

export function releaseData(release) {
  if (release.draft !== false || release.prerelease !== false || !/^v\d+\.\d+\.\d+$/.test(release.tag_name) || !Array.isArray(release.assets)) throw new Error('Use a published stable latest-release response');
  const tag = release.tag_name;
  const page = safeURL(release.html_url, `${repository}/releases/tag/${tag}`);
  if (release.html_url !== `${repository}/releases/tag/${tag}`) throw new Error('Release tag URL mismatch');
  const assets = new Map();
  for (const asset of release.assets) {
    if (assets.has(asset.name)) throw new Error('Duplicate release asset');
    const expected = `${repository}/releases/download/${tag}/${encodeURIComponent(asset.name)}`;
    safeURL(asset.browser_download_url, `${repository}/releases/download/`);
    if (asset.browser_download_url !== expected || !Number.isSafeInteger(asset.size) || asset.size <= 0) throw new Error('Invalid release asset metadata');
    if (asset.digest != null && !/^sha256:[\da-f]{64}$/i.test(asset.digest)) throw new Error('Invalid SHA-256 digest');
    assets.set(asset.name, asset);
  }
  const downloads = [
    ['Mac', 'VoxClip-macOS.dmg', 'Apple silicon · macOS 26 or later'],
    ['Windows x64', 'VoxClip-win-x64-Setup.exe', 'Windows 10 (2004+) or 11 · x64'],
    ['Windows Arm', 'VoxClip-win-arm64-Setup.exe', 'Windows 10 (2004+) or 11 · Arm64']
  ].map(([label, name, requirements], index) => {
    const asset = assets.get(name);
    const button = asset ? `<a class="download-button" href="${escapeHTML(asset.browser_download_url)}" aria-describedby="requirements-${index}">Download for ${label}<span aria-hidden="true">↓</span></a>` : `<span class="download-button unavailable" aria-disabled="true">${label} · not in this release</span>`;
    const size = asset ? `${(asset.size / 1048576).toFixed(1)} MiB` : 'Unavailable';
    const digest = asset?.digest?.slice(7);
    return `<article class="download-option"><h3>${label}</h3>${button}<p id="requirements-${index}">${requirements}</p><p class="release-meta">${escapeHTML(tag)} / ${size}</p>${digest ? `<details><summary>SHA-256</summary><code>${escapeHTML(digest)}</code></details>` : '<p class="checksum-note">SHA-256 not listed in release metadata.</p>'}</article>`;
  }).join('\n');
  const windows = assets.has('VoxClip-win-x64-Setup.exe') || assets.has('VoxClip-win-arm64-Setup.exe');
  const source = assets.get('VoxClip-win-ffmpeg-source.tar.xz');
  if (windows && !source) throw new Error('Windows downloads require the corresponding FFmpeg source asset');
  const ffmpegNotice = windows ? `This software uses libraries from the FFmpeg project under the LGPL. Source: <a href="${escapeHTML(source.browser_download_url)}">FFmpeg LGPL corresponding source</a>.` : '';
  return { FFMPEG_NOTICE: ffmpegNotice, DOWNLOADS: downloads, RELEASE_URL: page, VERSION: escapeHTML(tag) };
}

export async function build({ releasePath = join(site, 'latest.json'), out = join(site, 'dist'), mediaDir, configPath = join(site, 'media.json') } = {}) {
  const [tokens, release, template, css] = await Promise.all([
    readFile(join(root, 'shared/design/tokens.json'), 'utf8').then(JSON.parse),
    readFile(releasePath, 'utf8').then(JSON.parse),
    readFile(join(site, 'index.html'), 'utf8'), readFile(join(site, 'style.css'), 'utf8')
  ]);
  const data = releaseData(release);
  const { config, assets: pins, approved } = await readMedia(configPath);
  const hasMedia = Boolean(mediaDir && approved);
  const videoHTML = item => `<video controls preload="none" playsinline aria-label="${escapeHTML(item.title)}"><source src="media/${item.video}" type="video/mp4"><track kind="captions" src="media/${item.captions}" srclang="en" label="English" default><p><a href="media/${item.video}">Download ${escapeHTML(item.title)}</a></p></video>`;
  data.SHOWREEL = hasMedia ? videoHTML(config.videos[0]) : '<p>The showreel isn’t available yet.</p>';
  data.TUTORIALS = hasMedia ? `<ul class="tutorials">${config.videos.slice(1).map(item => `<li><h3>${escapeHTML(item.title)}</h3>${videoHTML(item)}</li>`).join('')}</ul>` : '<p>Video guides aren’t available yet.</p>';
  if (hasMedia) {
    await mkdir(join(out, 'media'), { recursive: true });
    for (const pin of pins) {
      const bytes = await readFile(join(mediaDir, pin.name));
      verifyMedia(bytes, pin);
      await writeFile(join(out, 'media', pin.name), bytes);
    }
  }
  data.FIXTURE_NOTICE = resolve(releasePath) === join(site, 'fixtures/latest.json') ? '<p class="preview-notice" role="note">Local preview · Release details are fixture data.</p>' : '';
  const html = template.replace(/\{\{([A-Z_]+)\}\}/g, (_, key) => {
    if (!(key in data)) throw new Error(`Unknown template key ${key}`);
    return data[key];
  });
  await mkdir(join(out, 'assets'), { recursive: true });
  await Promise.all([
    writeFile(join(out, 'index.html'), html), writeFile(join(out, 'style.css'), css),
    writeFile(join(out, 'tokens.css'), tokenCSS(tokens)),
    ...['hero.jpg', 'claude-sees.jpg', 'self-check.jpg'].map(name => copyFile(join(root, 'doc/media/readme', name), join(out, 'assets', name))),
    copyFile(join(root, 'shared/fonts/dm-sans/DMSans-Medium.ttf'), join(out, 'assets/DMSans-Medium.ttf')),
    copyFile(join(root, 'shared/fonts/dm-sans/DMSans-Bold.ttf'), join(out, 'assets/DMSans-Bold.ttf')),
    copyFile(join(root, 'shared/fonts/dm-sans/OFL.txt'), join(out, 'assets/OFL.txt')),
    copyFile(join(root, 'LICENSE'), join(out, 'LICENSE.txt')),
    copyFile(join(site, 'CNAME'), join(out, 'CNAME'))
  ]);
  return out;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length % 2 || args.some((arg, i) => i % 2 === 0 && !['--release', '--media'].includes(arg))) throw new Error('Usage: node site/build.mjs [--release latest.json] [--media directory]');
  const options = {};
  for (let i = 0; i < args.length; i += 2) options[args[i] === '--release' ? 'releasePath' : 'mediaDir'] = resolve(args[i + 1]);
  console.log(await build(options));
}
