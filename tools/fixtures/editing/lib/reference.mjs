// Loads the VoxConvo TypeScript reference without any npm dependency: Node's built-in
// type stripping turns each file into plain JavaScript, which is then imported from a
// data: URL. The .ts files themselves are never modified; the only in-memory patches are
// listed below and asserted.
//
// Where the files come from, first match wins:
//   1. VOXCONVO_WEB_DIR set: <VOXCONVO_WEB_DIR>/src/utils/<file> (a VoxConvo vox-web checkout).
//   2. The vendored copies in ../reference/<file>, when present.
// Either way every file must match the sha1 pinned in reference/manifest.json.
// Without either source the generator cannot run; `npm run check` reports that clearly and
// CI then only validates the committed fixtures (doc/architecture.md section 12).
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { stripTypeScriptTypes } from 'node:module'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const DIR = new URL('../reference/', import.meta.url)
const manifest = JSON.parse(readFileSync(new URL('manifest.json', DIR), 'utf8'))

/** Absolute path of a reference file, or null when no source has it. */
export function referencePath(file) {
  const web = process.env.VOXCONVO_WEB_DIR
  if (web) {
    const p = join(web, 'src', 'utils', file)
    if (!existsSync(p)) throw new Error(`VOXCONVO_WEB_DIR is set but ${p} does not exist`)
    return p
  }
  const vendored = fileURLToPath(new URL(file, DIR))
  return existsSync(vendored) ? vendored : null
}

/** True when every file in the manifest can be loaded. */
export function referenceAvailable() {
  return manifest.files.every(f => referencePath(f.file) !== null)
}

function source(file) {
  const entry = manifest.files.find(f => f.file === file)
  if (!entry) throw new Error(`${file} is not in reference/manifest.json`)
  const path = referencePath(file)
  if (!path) throw new Error(`${file}: no VoxConvo reference found. Set VOXCONVO_WEB_DIR to a vox-web checkout, or restore tools/fixtures/editing/reference/${file}.`)
  const text = readFileSync(path, 'utf8')
  const sha1 = createHash('sha1').update(text).digest('hex')
  if (sha1 !== entry.sha1) throw new Error(`${file}: sha1 ${sha1} does not match manifest ${entry.sha1}. The reference must stay byte-identical to the pinned version.`)
  return stripTypeScriptTypes(text)
}

function patch(code, from, to) {
  if (!code.includes(from)) throw new Error(`reference patch target not found: ${from}`)
  return code.replace(from, to)
}

const url = code => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')

// mediaTimeline.ts keeps cutRange private; export it so segmentCuts can show pre-rounding values.
function timelineCode({ wordReach, pauseKeep } = {}) {
  let code = source('mediaTimeline.ts') + '\nexport { cutRange }\n'
  if (wordReach !== undefined) code = patch(code, 'const WORD_REACH = 0.1', `const WORD_REACH = ${wordReach}`)
  if (pauseKeep !== undefined) {
    code = patch(code, 'const PAUSE_KEEP_AFTER_WORD = 0.15', `const PAUSE_KEEP_AFTER_WORD = ${pauseKeep}`)
    code = patch(code, 'const PAUSE_KEEP_BEFORE_WORD = 0.15', `const PAUSE_KEEP_BEFORE_WORD = ${pauseKeep}`)
  }
  return code
}

const timelineSource = timelineCode()
export const timeline = await import(url(timelineSource))

const variants = new Map()
/** The same reference with VoxClip's tunable constants changed (only used for parameter fixtures). */
export async function timelineWith(options) {
  const key = JSON.stringify(options)
  if (!variants.has(key)) variants.set(key, await import(url(timelineCode(options))))
  return variants.get(key)
}

export const timing = await import(url(source('transcriptionTiming.ts')))
export const clips = await import(url(patch(source('clips.ts'), "import { API_BASE_URL } from './videoJob'", "const API_BASE_URL = 'about:invalid'")))
export const boundaries = await import(url(source('wordBoundaries.ts')))

// audioEditor.ts renders through Web Audio. A minimal AudioContext stub is enough: the
// function only creates a buffer, copies samples, applies the fades and encodes a WAV blob.
class StubAudioBuffer {
  constructor(numberOfChannels, length, sampleRate) {
    this.numberOfChannels = numberOfChannels
    this.length = length
    this.sampleRate = sampleRate
    this.channels = Array.from({ length: numberOfChannels }, () => new Float32Array(length))
  }
  getChannelData(channel) { return this.channels[channel] }
}
globalThis.AudioContext ??= class {
  constructor(options) { this.sampleRate = options?.sampleRate }
  createBuffer(channels, length, sampleRate) { return new StubAudioBuffer(channels, length, sampleRate) }
  async close() {}
}
export const audioEditor = await import(url(patch(source('audioEditor.ts'), "from './mediaTimeline'", `from '${url(timelineSource)}'`)))
export { StubAudioBuffer }
