// Capture approval lives in the reviewed manifest, independently of release metadata.
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

export async function readMedia(path) {
  const config = JSON.parse(await readFile(path, 'utf8'));
  if (!/^media-v[\w.-]+$/.test(config.tag) || !Array.isArray(config.videos) || config.videos.length !== 5) throw new Error('Invalid media manifest');
  const names = config.videos.flatMap(item => [item.video, item.captions]);
  if (new Set(names).size !== names.length) throw new Error('Duplicate media filename');
  const assets = names.map(name => {
    const pin = config.integrity?.[name];
    if (!/^[\w-]+\.(mp4|vtt)$/.test(name) || !pin) throw new Error(`Missing media approval entry: ${name}`);
    if (pin.size === null && pin.sha256 === null) return { name, size: null, sha256: null };
    if (!Number.isSafeInteger(pin.size) || pin.size <= 0 || pin.size > 100_000_000 || !/^[a-f0-9]{64}$/.test(pin.sha256 ?? '')) throw new Error(`Invalid media approval: ${name}`);
    return { name, size: pin.size, sha256: pin.sha256 };
  });
  const approved = assets.every(asset => asset.size !== null);
  if (!approved && assets.some(asset => asset.size !== null)) throw new Error('Media approval must cover every video and caption');
  if (approved && assets.reduce((total, asset) => total + asset.size, 0) > 900_000_000) throw new Error('Media exceeds the Pages artifact budget');
  return { config, assets, approved };
}

export function verifyMedia(bytes, pin) {
  if (bytes.length !== pin.size || createHash('sha256').update(bytes).digest('hex') !== pin.sha256) throw new Error(`Media integrity check failed: ${pin.name}`);
}
