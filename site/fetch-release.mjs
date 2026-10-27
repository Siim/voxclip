// Build-time public GitHub release reads only. No API calls run in the page.
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readMedia, verifyMedia } from './media.mjs';
import { site, repository, releaseData } from './build.mjs';

export async function fetchRelease({ directory, fetchImpl = fetch, token = process.env.GITHUB_TOKEN, configPath = join(site, 'media.json') } = {}) {
  const { config, assets: pins, approved } = await readMedia(configPath);
  const api = 'https://api.github.com/repos/Siim/voxclip/releases';
  async function metadata(url) {
    const response = await fetchImpl(url, { headers: { Accept: 'application/vnd.github+json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, signal: AbortSignal.timeout(30_000) });
    if (!response.ok) throw new Error(`GitHub release metadata failed: HTTP ${response.status}`);
    return response.json();
  }
  const latest = await metadata(`${api}/latest`);
  releaseData(latest);
  for (const name of ['VoxClip-macOS.dmg', 'VoxClip-win-x64-Setup.exe', 'VoxClip-win-arm64-Setup.exe']) {
    if (!latest.assets.some(asset => asset.name === name)) throw new Error(`Joint launch requires ${name}`);
  }
  await mkdir(directory, { recursive: true });
  if (!approved) {
    // No approved captures: do not request the media release or any media bytes.
    await writeFile(join(directory, 'latest.json'), JSON.stringify(latest, null, 2) + '\n');
    return;
  }
  const media = await metadata(`${api}/tags/${encodeURIComponent(config.tag)}`);
  if (media.draft !== false || media.tag_name !== config.tag) throw new Error('Media release must be published and match media.json');
  const assets = new Map();
  for (const asset of media.assets) {
    if (assets.has(asset.name)) throw new Error('Duplicate media release asset');
    assets.set(asset.name, asset);
  }
  await mkdir(join(directory, 'media'), { recursive: true });
  for (const pin of pins) {
    const { name } = pin;
    const asset = assets.get(name);
    if (!asset || asset.browser_download_url !== `${repository}/releases/download/${config.tag}/${name}` ||
        asset.size !== pin.size || asset.digest !== `sha256:${pin.sha256}`) throw new Error(`Missing or invalid media release asset: ${name}`);
    // Public download: never send the API credential to the asset host or a redirect.
    const response = await fetchImpl(asset.browser_download_url, { signal: AbortSignal.timeout(120_000) });
    if (!response.ok) throw new Error(`Media download failed: ${name}, HTTP ${response.status}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    verifyMedia(bytes, pin);
    await writeFile(join(directory, 'media', name), bytes);
  }
  await writeFile(join(directory, 'latest.json'), JSON.stringify(latest, null, 2) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error('Usage: node site/fetch-release.mjs <staging-directory>');
  await fetchRelease({ directory: resolve(process.argv[2]) });
}
