import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, stat, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { build, site, releaseData, tokenProperties } from './build.mjs';

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
    const video = tags.find(tag => tag.name === 'video').attrs;
    assert.equal(video.preload, 'none');
    assert.ok(!('autoplay' in video));
    assert.equal(tags.filter(tag => tag.name === 'article' && tag.attrs.class === 'feature-row').length, 4);
    for (const file of ['style.css', 'tokens.css', 'assets/placeholder.svg']) {
      const text = await readFile(join(out, file), 'utf8');
      assert.doesNotMatch(text, /@import|https?:\/\/(?!www\.w3\.org)/);
      for (const match of text.matchAll(/url\("?([^"\)]+)"?\)/g)) assert.ok((await stat(join(out, match[1]))).isFile());
    }
    const css = await readFile(join(out, 'tokens.css'), 'utf8');
    const tokens = JSON.parse(await readFile(join(site, '../shared/design/tokens.json'), 'utf8'));
    const [light, dark] = css.split('@media (prefers-color-scheme: dark)');
    const checkColor = (node, path = []) => {
      if (node.$type === 'color') for (const [mode, section] of [['light', light], ['dark', dark]]) {
        const value = node.$value[mode];
        if (!value.startsWith('system:')) assert.ok(section.includes(`--${path.join('-')}: ${value};`), `token drift ${path.join('.')}`);
      }
      else for (const [key, child] of Object.entries(node)) if (!key.startsWith('$') && child && typeof child === 'object') checkColor(child, [...path, key]);
    };
    checkColor(tokens.color, ['color']);
    const stylesheet = await readFile(join(site, 'style.css'), 'utf8');
    const used = new Set([...stylesheet.matchAll(/var\(\s*(--[\w-]+)/g)].map(match => match[1]));
    assert.ok(used.size > 0);
    for (const [mode, section] of [['light', light], ['dark', dark]]) {
      const defined = new Set([...section.matchAll(/(--[\w-]+)\s*:/g)].map(match => match[1]));
      for (const name of used) assert.ok(defined.has(name), `undefined ${mode} variable ${name}`);
    }
    assert.equal(await readFile(join(out, 'CNAME'), 'utf8'), 'clip.voxconvo.com\n');
    assert.match(html, /This software uses libraries from the FFmpeg project under the LGPL/);
    assert.match(html, /AI tighten \(coming\)/);
    assert.match(html, /Voice Lab \(beta, coming\)/);
    assert.match(html, /voice recordings, the words to speak and a little surrounding transcript for context to ElevenLabs/);
    assert.match(html, /lip sync the selected video and its audio to the provider you choose/);
    assert.match(html, /its Rewrite will send the selected passage to your AI connector/);
    // All page text/focus combinations: WCAG AA body text and 3:1 focus boundaries.
    const luminance = hex => {
      const rgb = hex.slice(1).match(/../g).slice(0, 3).map(v => parseInt(v, 16) / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
      return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
    };
    const color = (group, key, mode) => tokens.color[group][key].$value[mode];
    for (const mode of ['light', 'dark']) for (const [fg, bg, minimum] of [
      [['text', 'primary'], ['bg', 'surface'], 4.5], [['text', 'secondary'], ['bg', 'surface'], 4.5],
      [['text', 'secondary'], ['bg', 'sunken'], 4.5], [['accent', 'text'], ['bg', 'surface'], 4.5],
      [['focus', 'ring'], ['bg', 'surface'], 3]
    ]) {
      const a = luminance(color(...fg, mode)), b = luminance(color(...bg, mode));
      assert.ok((Math.max(a, b) + .05) / (Math.min(a, b) + .05) >= minimum, `contrast ${mode} ${fg}`);
    }
    for (const mode of ['light', 'dark']) {
      const props = tokenProperties(tokens, mode);
      const roles = mode === 'dark'
        ? ['accent-text', 'word-playingForeground', 'word-playingBackground']
        : ['accent-default', 'accent-on', 'accent-pressed'];
      for (const [i, role] of ['fill', 'label', 'hover'].entries()) {
        assert.equal(props[`--button-${role}`], props[`--color-${roles[i]}`]);
        assert.ok((mode === 'light' ? light : dark).includes(`--button-${role}: ${props[`--button-${role}`]};`));
      }
      for (const fill of ['fill', 'hover']) {
        const a = luminance(props['--button-label']), b = luminance(props[`--button-${fill}`]);
        assert.ok((Math.max(a, b) + .05) / (Math.min(a, b) + .05) >= 4.5, `${mode} capsule contrast`);
      }
    }
    assert.match(stylesheet, /\.capsule, \.download-button \{[^}]*border-radius: 9999px/);
    assert.match(stylesheet, /\.capsule \{ color: var\(--button-label\); background: var\(--button-fill\); \}/);
    assert.match(stylesheet, /\.capsule:hover \{ background: var\(--button-hover\); \}/);
    // Download buttons are outlined: body text on the page, accent.soft on hover.
    assert.match(stylesheet, /\.download-button \{ display: flex; color: var\(--color-text-primary\); background: transparent; border: 1px solid var\(--color-line-strong\); \}/);
    assert.match(stylesheet, /\.download-button:hover \{ background: var\(--color-accent-soft\); \}/);
    for (const mode of ['light', 'dark']) for (const bg of [['bg', 'surface'], ['accent', 'soft']]) {
      const a = luminance(color('text', 'primary', mode)), b = luminance(color(...bg, mode));
      assert.ok((Math.max(a, b) + .05) / (Math.min(a, b) + .05) >= 4.5, `${mode} download button on ${bg.join('.')}`);
    }
    assert.match(html, /class="capsule hero-button"/);
    assert.match(html, /section-heading"><div><p class="eyebrow">A quieter way to edit/);
    assert.match(html, /class="ffmpeg-notice"/);
    assert.match(stylesheet, /\.ffmpeg-notice \{ margin-top: 40px/);
    const poster = await readFile(join(out, 'assets/video-placeholder.svg'), 'utf8');
    assert.match(poster, /viewBox="0 0 1440 810"/);
    assert.doesNotMatch(poster, /<path|stroke[=:]/);
    assert.match(html, /poster="assets\/video-placeholder.svg"/);
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
    // Null approval pins always use placeholders, even when a media directory is supplied.
    await build({ releasePath: join(site, 'fixtures/latest.json'), out, mediaDir, configPath: unapprovedPath });
    assert.doesNotMatch(await readFile(join(out, 'index.html'), 'utf8'), /<source|<track/);
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
    for (const video of published.match(/<video[^>]*>[\s\S]*?<\/video>/g)) if (video.includes('<source')) assert.doesNotMatch(video, /video-placeholder\.svg/);
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
