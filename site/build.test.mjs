import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, stat, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { build, site, releaseData } from './build.mjs';

const voids = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr']);

// Strict structural check for this plain HTML scaffold; no browser or network needed.
function inspectHTML(html) {
  assert.match(html, /^<!doctype html>/i);
  const tags = [], stack = [], ids = new Set();
  let remainder = html.replace(/<!--[\s\S]*?-->/g, '').replace(/^<!doctype html>/i, '');
  const token = /<\/?([a-z][\w-]*)([^<>]*?)>/gi;
  let match, offset = 0;
  while ((match = token.exec(remainder))) {
    assert.ok(!remainder.slice(offset, match.index).includes('<'), 'malformed markup');
    offset = token.lastIndex;
    const name = match[1].toLowerCase();
    if (match[0].startsWith('</')) {
      assert.equal(match[2], '', 'closing tag has attributes');
      assert.equal(stack.pop(), name, `unbalanced ${name}`);
      continue;
    }
    const attrs = {};
    const attribute = /([\w-]+)(?:="([^"]*)")?/g;
    let attr, end = 0;
    while ((attr = attribute.exec(match[2]))) {
      assert.equal(match[2].slice(end, attr.index).trim(), '', 'invalid attribute');
      assert.ok(!(attr[1] in attrs), 'duplicate attribute');
      attrs[attr[1]] = attr[2] ?? '';
      end = attribute.lastIndex;
    }
    assert.equal(match[2].slice(end).trim(), '', 'invalid trailing markup');
    if (attrs.id) { assert.ok(!ids.has(attrs.id), `duplicate id ${attrs.id}`); ids.add(attrs.id); }
    if (name === 'img') assert.ok(attrs.alt, 'image needs meaningful alt text');
    assert.ok(!Object.keys(attrs).some(key => key.startsWith('on')), 'no inline handlers');
    assert.notEqual(name, 'script', 'no runtime scripts');
    tags.push({ name, attrs });
    if (!voids.has(name)) stack.push(name);
  }
  assert.equal(stack.length, 0, 'unclosed tags');
  assert.ok(!remainder.slice(offset).includes('<'));
  return { tags, ids };
}

async function hashes(directory) {
  const files = {};
  for (const name of (await readdir(directory)).sort()) {
    const path = join(directory, name);
    files[name] = (await stat(path)).isDirectory() ? await hashes(path) : createHash('sha256').update(await readFile(path)).digest('hex');
  }
  return files;
}

test('launch page describes the current workflow with the approved README artwork', async () => {
  const scratch = await mkdtemp('/tmp/voxclip-launch-copy-');
  try {
    await build({ releasePath: join(site, 'fixtures/latest.json'), out: scratch });
    const html = await readFile(join(scratch, 'index.html'), 'utf8');
    for (const phrase of [/Claude does it all/, /in your own voice/i, /revoice the whole clip/i, /lip sync/i,
      /captions/i, /music/i, /looks/i, /automatic effects/i, /−14 LUFS/, /your own keys/i, /macOS/, /Windows/]) {
      assert.match(html, phrase);
    }
    assert.doesNotMatch(html, /placeholder|AI tighten \(coming\)|Voice Lab \(beta, coming\)/i);
    const { tags } = inspectHTML(html);
    const images = tags.filter(tag => tag.name === 'img');
    assert.deepEqual(images.map(({ attrs }) => attrs.src), ['assets/hero.jpg', 'assets/claude-sees.jpg', 'assets/self-check.jpg']);
    for (const { attrs } of images) {
      assert.ok(attrs.alt);
      assert.deepEqual(await readFile(join(scratch, attrs.src)), await readFile(join(site, '../doc/media/readme', attrs.src.split('/').at(-1))));
    }
  } finally { await rm(scratch, { recursive: true, force: true }); }
});

test('fixture build: valid structure, local resources, links, token parity and determinism', async () => {
  await mkdir('/tmp/voxclip-sol-launch-tooling', { recursive: true });
  const scratch = await mkdtemp('/tmp/voxclip-sol-launch-tooling/site-tests-');
  try {
    const out = join(scratch, 'dist');
    await build({ releasePath: join(site, 'fixtures/latest.json'), out });
    const html = await readFile(join(out, 'index.html'), 'utf8');
    const { tags, ids } = inspectHTML(html);
    for (const { name, attrs } of tags) {
      for (const key of ['href', 'src', 'poster']) {
        if (!attrs[key]) continue;
        const value = attrs[key];
        if (value.startsWith('#')) { assert.ok(ids.has(value.slice(1)), `broken ${value}`); continue; }
        if (/^https:/.test(value)) {
          assert.equal(name, 'a', 'no external resource requests');
          assert.ok(value === 'https://voxconvo.com' || value.startsWith('https://github.com/Siim/voxclip'), 'unexpected external navigation');
        } else {
          assert.ok(!value.includes(':') && !value.startsWith('//') && !value.includes('..'));
          assert.ok((await stat(join(out, value))).isFile(), `missing local asset ${value}`);
        }
      }
      for (const key of ['aria-labelledby', 'aria-describedby']) if (attrs[key]) {
        for (const id of attrs[key].split(' ')) assert.ok(ids.has(id), `missing accessible reference ${id}`);
      }
    }
    assert.equal(tags.filter(tag => tag.name === 'h1').length, 1);
    for (const landmark of ['header', 'nav', 'main', 'footer']) assert.ok(tags.some(tag => tag.name === landmark));
    assert.match(html, /fixture data/);
    assert.match(html, /100.0 MiB/);
    assert.match(html, /0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/);
    assert.match(html, /SHA-256 not listed/);
    assert.ok(!tags.some(tag => tag.name === 'video'));
    assert.doesNotMatch(html, /available yet/);
    assert.ok(!html.includes('id="showreel"') && !html.includes('id="tutorials"'));
    for (const file of ['style.css', 'tokens.css']) {
      const text = await readFile(join(out, file), 'utf8');
      assert.doesNotMatch(text, /@import|https?:\/\/(?!www\.w3\.org)/);
      for (const match of text.matchAll(/url\("?([^"\)]+)"?\)/g)) assert.ok((await stat(join(out, match[1]))).isFile());
    }
    const css = await readFile(join(out, 'tokens.css'), 'utf8');
    const tokens = JSON.parse(await readFile(join(site, '../shared/design/tokens.json'), 'utf8'));
    assert.match(css, /color-scheme: dark;/);
    assert.doesNotMatch(css, /prefers-color-scheme/);
    const checkColor = (node, path = []) => {
      if (node.$type === 'color') {
        const value = node.$value.dark;
        if (!value.startsWith('system:')) assert.ok(css.includes(`--${path.join('-')}: ${value};`), `token drift ${path.join('.')}`);
      }
      else for (const [key, child] of Object.entries(node)) if (!key.startsWith('$') && child && typeof child === 'object') checkColor(child, [...path, key]);
    };
    checkColor(tokens.color, ['color']);
    const stylesheet = await readFile(join(site, 'style.css'), 'utf8');
    const used = new Set([...stylesheet.matchAll(/var\(\s*(--[\w-]+)/g)].map(match => match[1]));
    assert.ok(used.size > 0);
    const defined = new Set([...css.matchAll(/(--[\w-]+)\s*:/g)].map(match => match[1]));
    for (const name of used) assert.ok(defined.has(name), `undefined variable ${name}`);
    assert.equal(await readFile(join(out, 'CNAME'), 'utf8'), 'clip.voxconvo.com\n');
    assert.match(html, /This software uses libraries from the FFmpeg project under the LGPL/);
    assert.match(html, /Cloud AI receives the transcript and, for plans that use the picture, sampled frames/);
    assert.match(html, /Voice cloning sends approved voice samples to ElevenLabs/);
    assert.match(html, /Lip sync sends the selected video and audio to fal\.ai/);
    const luminance = hex => {
      const rgb = hex.slice(1).match(/../g).slice(0, 3).map(v => parseInt(v, 16) / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
      return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
    };
    const color = (group, key) => tokens.color[group][key].$value.dark;
    for (const [fg, bg, minimum] of [
      [['text', 'primary'], ['bg', 'surface'], 4.5], [['text', 'secondary'], ['bg', 'surface'], 4.5],
      [['text', 'secondary'], ['bg', 'window'], 4.5], [['text', 'secondary'], ['bg', 'input'], 4.5],
      [['accent', 'text'], ['bg', 'surface'], 4.5], [['tint', 'text'], ['bg', 'window'], 4.5],
      [['focus', 'ring'], ['bg', 'surface'], 3], [['text', 'primary'], ['accent', 'soft'], 4.5],
      [['word', 'playingForeground'], ['accent', 'text'], 4.5], [['word', 'playingForeground'], ['word', 'playingBackground'], 4.5]
    ]) {
      const a = luminance(color(...fg)), b = luminance(color(...bg));
      assert.ok((Math.max(a, b) + .05) / (Math.min(a, b) + .05) >= minimum, `contrast ${fg} on ${bg}`);
    }
    const before = await hashes(out);
    await build({ releasePath: join(site, 'fixtures/latest.json'), out });
    assert.deepEqual(await hashes(out), before);
    const mediaDir = join(scratch, 'media-source');
    await mkdir(mediaDir, { recursive: true });
    const media = JSON.parse(await readFile(join(site, 'media.json'), 'utf8'));
    // Derive both approval states so these offline tests also pass after real captures are approved.
    const unapproved = structuredClone(media);
    for (const name of Object.keys(unapproved.integrity)) unapproved.integrity[name] = { size: null, sha256: null };
    const unapprovedPath = join(scratch, 'unapproved-media.json');
    await writeFile(unapprovedPath, JSON.stringify(unapproved));
    await build({ releasePath: join(site, 'fixtures/latest.json'), out, mediaDir, configPath: unapprovedPath });
    assert.doesNotMatch(await readFile(join(out, 'index.html'), 'utf8'), /<video|<source|<track/);
    for (const item of media.videos) for (const name of [item.video, item.captions]) {
      const bytes = Buffer.from('synthetic ' + name);
      await writeFile(join(mediaDir, name), bytes);
      media.integrity[name] = { size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
    }
    const configPath = join(scratch, 'approved-media.json');
    await writeFile(configPath, JSON.stringify(media));
    await build({ releasePath: join(site, 'fixtures/latest.json'), out, mediaDir, configPath });
    const published = await readFile(join(out, 'index.html'), 'utf8');
    const { tags: mediaTags } = inspectHTML(published);
    assert.equal(mediaTags.filter(tag => tag.name === 'source').length, media.videos.length);
    assert.equal(mediaTags.filter(tag => tag.name === 'track').length, media.videos.length);
    for (const { attrs } of mediaTags.filter(tag => tag.name === 'video')) {
      assert.equal(attrs.preload, 'none');
      assert.ok('controls' in attrs);
      assert.ok(!('autoplay' in attrs));
    }
    assert.doesNotMatch(published, /isn’t available yet|aren’t available yet/);
    for (const item of media.videos) for (const name of [item.video, item.captions]) {
      assert.match(published, new RegExp(`media/${name.replaceAll('.', '\\.')}`));
      assert.equal(await readFile(join(out, 'media', name), 'utf8'), 'synthetic ' + name);
    }
    const withMedia = await hashes(out);
    await build({ releasePath: join(site, 'fixtures/latest.json'), out, mediaDir, configPath });
    assert.deepEqual(await hashes(out), withMedia);
    await writeFile(join(mediaDir, media.videos[0].video), 'substituted');
    await assert.rejects(build({ releasePath: join(site, 'fixtures/latest.json'), out, mediaDir, configPath }), /integrity/);
  } finally { await rm(scratch, { recursive: true, force: true }); }
});

test('Mac-only/missing assets, unsafe metadata and structural validation', async () => {
  const fixture = JSON.parse(await readFile(join(site, 'fixtures/latest.json'), 'utf8'));
  const macOnly = { ...fixture, assets: fixture.assets.slice(0, 1) };
  assert.match(releaseData(macOnly).DOWNLOADS, /Windows x64 · not in this release/);
  assert.doesNotMatch(releaseData(macOnly).DOWNLOADS, /href="[^"]+Setup.exe/);
  for (const invalid of [
    { ...fixture, draft: true }, { ...fixture, prerelease: true },
    { ...fixture, assets: fixture.assets.slice(0, 3) },
    { ...fixture, assets: [fixture.assets[0], fixture.assets[0]] },
    { ...fixture, assets: [{ ...fixture.assets[0], browser_download_url: 'javascript:alert(1)' }] },
    { ...fixture, assets: [{ ...fixture.assets[0], digest: 'sha256:fake' }] }
  ]) assert.throws(() => releaseData(invalid));
  assert.throws(() => inspectHTML('<!doctype html><html><main></html>'));
  assert.throws(() => inspectHTML('<!doctype html><html><img src="x"></html>'));
});
