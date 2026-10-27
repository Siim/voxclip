import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { fetchRelease } from './fetch-release.mjs';
import { site, repository } from './build.mjs';

test('release fetch is read-only, verifies media and requires both platforms', async () => {
  await mkdir('/tmp/voxclip-sol-launch-tooling', { recursive: true });
  const scratch = await mkdtemp('/tmp/voxclip-sol-launch-tooling/release-tests-');
  try {
    const config = JSON.parse(await readFile(join(site, 'media.json'), 'utf8'));
    const latest = JSON.parse(await readFile(join(site, 'fixtures/latest.json'), 'utf8'));
    const bytes = new Map();
    const assets = config.videos.flatMap(item => [item.video, item.captions]).map(name => {
      const content = Buffer.from('synthetic ' + name);
      const url = `${repository}/releases/download/${config.tag}/${name}`;
      bytes.set(url, content);
      return { name, browser_download_url: url, size: content.length, digest: `sha256:${createHash('sha256').update(content).digest('hex')}` };
    });
    for (const asset of assets) config.integrity[asset.name] = { size: asset.size, sha256: asset.digest.slice(7) };
    const configPath = join(scratch, 'approved-media.json');
    await writeFile(configPath, JSON.stringify(config));
    const media = { tag_name: config.tag, draft: false, assets };
    let corrupt = false, activeLatest = latest;
    const fetchImpl = async (url, options) => {
      assert.ok(!options.method || options.method === 'GET');
      if (url.startsWith('https://api.github.com/')) {
        assert.equal(options.headers.Authorization, 'Bearer synthetic-test-credential');
        return Response.json(url.endsWith('/latest') ? activeLatest : media);
      }
      assert.equal(options.headers, undefined, 'credential must never reach asset host');
      assert.ok(bytes.has(url));
      return new Response(corrupt ? Buffer.alloc(bytes.get(url).length, 120) : bytes.get(url));
    };
    await fetchRelease({ directory: scratch, configPath, fetchImpl, token: 'synthetic-test-credential' });
    assert.deepEqual(JSON.parse(await readFile(join(scratch, 'latest.json'), 'utf8')), latest);
    for (const asset of assets) assert.deepEqual(await readFile(join(scratch, 'media', asset.name)), bytes.get(asset.browser_download_url));
    corrupt = true;
    await assert.rejects(fetchRelease({ directory: scratch, configPath, fetchImpl, token: 'synthetic-test-credential' }), /integrity/);
    corrupt = false;
    activeLatest = { ...latest, assets: latest.assets.slice(0, 1) };
    await assert.rejects(fetchRelease({ directory: scratch, configPath, fetchImpl, token: 'synthetic-test-credential' }), /Joint launch requires/);
    activeLatest = latest;
    // Re-uploaded bytes with matching API metadata must still match the committed approval.
    const substituted = Buffer.alloc(assets[0].size, 120);
    bytes.set(assets[0].browser_download_url, substituted);
    media.assets = [{ ...assets[0], size: substituted.length, digest: `sha256:${createHash('sha256').update(substituted).digest('hex')}` }, ...assets.slice(1)];
    await assert.rejects(fetchRelease({ directory: scratch, configPath, fetchImpl, token: 'synthetic-test-credential' }), /Missing or invalid/);
    bytes.set(assets[0].browser_download_url, Buffer.from('synthetic ' + assets[0].name));
    media.assets = assets.slice(1);
    await assert.rejects(fetchRelease({ directory: scratch, configPath, fetchImpl, token: 'synthetic-test-credential' }), /Missing or invalid/);
    media.assets = [{ ...assets[0], browser_download_url: 'https://untrusted.invalid/video' }, ...assets.slice(1)];
    await assert.rejects(fetchRelease({ directory: scratch, configPath, fetchImpl, token: 'synthetic-test-credential' }), /Missing or invalid/);
    await assert.rejects(fetchRelease({ directory: scratch, configPath, fetchImpl: async () => new Response('', { status: 404 }) }), /HTTP 404/);
  } finally { await rm(scratch, { recursive: true, force: true }); }
});

test('unapproved media fetches only app metadata and builds placeholders', async () => {
  await mkdir('/tmp/voxclip-sol-launch-tooling', { recursive: true });
  const scratch = await mkdtemp('/tmp/voxclip-sol-launch-tooling/release-tests-');
  try {
    const latest = JSON.parse(await readFile(join(site, 'fixtures/latest.json'), 'utf8'));
    const calls = [];
    const config = JSON.parse(await readFile(join(site, 'media.json'), 'utf8'));
    for (const name of Object.keys(config.integrity)) config.integrity[name] = { size: null, sha256: null };
    const unapprovedPath = join(scratch, 'unapproved-media.json');
    await writeFile(unapprovedPath, JSON.stringify(config));
    await fetchRelease({ directory: scratch, configPath: unapprovedPath, fetchImpl: async url => {
      calls.push(url);
      assert.equal(url, 'https://api.github.com/repos/Siim/voxclip/releases/latest');
      return Response.json(latest);
    } });
    assert.equal(calls.length, 1);
    assert.deepEqual(JSON.parse(await readFile(join(scratch, 'latest.json'), 'utf8')), latest);
    await assert.rejects(readFile(join(scratch, 'media/showreel.mp4')), { code: 'ENOENT' });
    config.integrity[config.videos[0].video] = { size: 3, sha256: 'a'.repeat(64) };
    const configPath = join(scratch, 'partial.json');
    await writeFile(configPath, JSON.stringify(config));
    await assert.rejects(fetchRelease({ directory: scratch, configPath, fetchImpl: () => assert.fail('must reject before fetching') }), /every video and caption/);
  } finally { await rm(scratch, { recursive: true, force: true }); }
});
