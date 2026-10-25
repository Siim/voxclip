import assert from 'node:assert/strict'
import { readFile, writeFile, mkdir, readdir, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as reference from './reference.mjs'
import { appleSchema, canonicalRequest, clipInstruction, renderConnector, sha256, tomlBasicString, windowBudget, tightenWindowBudget } from './requests.mjs'
import { candidate, f1Words, f1Rendered, fixedVectors, timeVectors, finalizeVectors, snapVectors, w1Bounds, tightenVectors, t1Entries, u100Words, syntheticWords, randomValues } from './vectors.mjs'

assert(Number(process.versions.node.split('.')[0]) >= 20, 'Node >=20 is required')
assert(process.argv.slice(2).every(argument => argument === '--check'), 'usage: node gen.mjs [--check]')
const root = fileURLToPath(new URL('../../../', import.meta.url))
const output = join(root, 'shared/fixtures/llm')
const inputPaths = ['shared/prompts/clip-finder.json', 'shared/prompts/ai-tighten.json', 'shared/catalog/llm-providers.json']
const sourceBytes = await Promise.all(inputPaths.map(path => readFile(join(root, path), 'utf8')))
const [clipFinder, aiTighten, catalog] = sourceBytes.map(text => JSON.parse(text))
const prompts = { clipFinder, aiTighten }
const sourceHashes = Object.fromEntries(inputPaths.map((path, index) => [path, sha256(sourceBytes[index].replace(/\r\n/g, '\n'))]))
for (const source of [clipFinder, aiTighten, catalog]) assert.equal(source.schemaVersion, 1, 'unsupported shared input schemaVersion')
for (const schema of [clipFinder.output.schema, aiTighten.output.schema, catalog.testRequest.schema]) reference.validateSchema(schema)
const presets = Object.fromEntries(clipFinder.presets.map(preset => [preset.id, preset]))
const connectors = Object.fromEntries(catalog.connectors.map(connector => [connector.id, connector]))
assert.deepEqual(Object.keys(connectors), ['anthropic', 'openai', 'xai', 'gemini', 'ollama', 'lmstudio', 'apple-foundation', 'claude-code', 'codex'], 'connector coverage changed')
const datasets = new Map()
const add = (file, id, kind, input, expected, source = 'doc/spec/ai.md', notes) => {
  if (!datasets.has(file)) datasets.set(file, [])
  const cases = datasets.get(file)
  assert(!cases.some(test => test.id === id), `duplicate case ${file}/${id}`)
  cases.push({ id, kind, origin: 'voxclip', source, ...(notes ? { notes } : {}), input, expected })
}
const equal = (actual, expected, label) => assert.deepEqual(actual, expected, `self-check failed: ${label}`)
const decodeNumber = value => ({ NaN: NaN, Infinity: Infinity, '-Infinity': -Infinity, '-0': -0 })[value] ?? value
const decodeCandidates = candidates => candidates.map(item => ({ ...item, start_word: decodeNumber(item.start_word), end_word: decodeNumber(item.end_word), score: decodeNumber(item.score) }))
const finalize = input => reference.finalizeClips({ ...input, words: Array.isArray(input.words) ? input.words : syntheticWords(input.words), candidates: decodeCandidates(input.candidates), preset: presets[input.preset] }, clipFinder.limits)
const formattedF1 = reference.formatTranscript(f1Words)
equal(formattedF1.rendered, f1Rendered, 'F1 exact transcript')
equal(formattedF1.lines.map(line => [line.firstIndex, line.lastIndex]), [[0, 5], [6, 10], [11, 12], [13, 15], [16, 16], [17, 18], [19, 59], [60, 65], [66, 66]], 'F1 line bounds')
equal(clipInstruction({ words: f1Words, preset: presets.best }, clipFinder), 'The recording is 3:20 long.\nFind the 3 to 5 strongest moments. Each clip should be 20 to 60 seconds long.', 'F1 best instruction')
equal(clipInstruction({ words: f1Words, preset: presets.custom, instructions: '  Funny bits  ' }, clipFinder), 'The recording is 3:20 long.\nFunny bits', 'F1 custom instruction')

const entries = (texts, indices = null) => texts.map((text, position) => ({ id: `w${indices?.[position] ?? position}`, index: indices?.[position] ?? position, text, start: position * 0.3, end: position * 0.3 + 0.25 }))
const transcriptCases = [
  ['F1', f1Words, 'doc/spec/ai.md §13.2'],
  ['empty', [], 'doc/spec/ai.md §11.3'],
  ['sparse-indices-41-entries', entries(Array.from({ length: 42 }, (_, index) => `word${index}`), Array.from({ length: 42 }, (_, index) => 40 + index * 3)), 'doc/spec/ai.md §11.3'],
  ['sentence-closers', entries(['one.”', 'two!)', "three?'", 'four。', 'five！', 'six？', 'not.」', 'joined', 'trailing. ', 'still', 'last']), 'doc/spec/ai.md §11.3'],
  ['gap-thresholds', [{ id: 'w0', index: 0, text: 'a', start: 0, end: 0 }, { id: 'w1', index: 1, text: 'b', start: 1.2, end: 2 }, { id: 'w2', index: 2, text: 'c', start: 3.5, end: 4 }], 'doc/spec/ai.md §11.3'],
  ['binary-gap-subtraction', [{ id: 'w0', index: 0, text: 'a', start: 0, end: 2.5 }, { id: 'w1', index: 1, text: 'b', start: 4.55, end: 5 }], 'doc/spec/ai.md §11.3'],
  ['minutes-do-not-wrap', [{ id: 'w7', index: 7, text: 'late.', start: 4523.7, end: 4524 }], 'doc/spec/ai.md §13.3'],
  ['literal-regex-terminal-newline', entries(['end.\n', 'next']), 'doc/spec/ai.md §11.3']
]
for (const [id, words, source] of transcriptCases) add('format-transcript', id, 'format-transcript', { entries: words }, reference.formatTranscript(words), source)
equal(reference.formatTranscript(transcriptCases[2][1]).lines.map(line => [line.firstIndex, line.lastIndex]), [[40, 160], [163, 163]], '41 entry positions, not source indices')
equal(reference.formatTranscript(transcriptCases[4][1]).rendered, '[0-0] 0:00 a\n[1-1] 0:01 b\n(pause 1.5s)\n[2-2] 0:03 c', 'gap boundary breaks and pauses')
equal(reference.formatTranscript(transcriptCases[7][1]).lines.length, 1, 'ECMAScript sentence end does not match before a terminal newline')

for (const [index, [value, expected]] of fixedVectors.entries()) {
  equal(reference.toFixed1(value), expected, `§13.3 rounding vector ${index + 1}`)
  add('to-fixed', `fixed-${index + 1}`, 'to-fixed-1', { value }, expected, 'doc/spec/ai.md §13.3')
}
for (const [index, [value, expected]] of timeVectors.entries()) {
  equal(reference.formatTime(value), expected, `§13.3 time vector ${index + 1}`)
  add('to-fixed', `time-${index + 1}`, 'format-time', { seconds: value }, expected, 'doc/spec/ai.md §13.3')
}
const boundaries = [0, Number.MIN_VALUE, 2 ** -10, 0.85, 3.35 - 2.5, 59.95, 2 ** 52, 999999999999999900000, 1e21, Number.MAX_VALUE]
for (const [index, value] of boundaries.entries()) {
  equal(reference.toFixed1(value), value.toFixed(1), `rounding boundary ${index}`)
  add('to-fixed', `boundary-${index + 1}`, 'to-fixed-1', { value }, value.toFixed(1), 'doc/spec/editing.md §4.4; ECMAScript Number.toFixed')
}
add('to-fixed', 'negative-zero', 'to-fixed-1', { value: '-0' }, '0.0', 'doc/spec/editing.md §4.4')
equal(reference.toFixed1(-0), '0.0', 'negative zero')
const editingLabels = JSON.parse(await readFile(join(root, 'shared/fixtures/editing/pauses/label-to-fixed.json'), 'utf8'))
for (const [index, value] of editingLabels.input.durations.entries()) {
  const expected = editingLabels.expected.labels[index].slice(6, -1)
  equal(reference.toFixed1(value), expected, `editing label ${index}`)
  add('to-fixed', `editing-label-${index + 1}`, 'to-fixed-1', { value }, expected, 'shared/fixtures/editing/pauses/label-to-fixed.json')
}
const randomInput = { generator: 'lcg32-scaled-binary64-v1', seed: 0x564F5843, count: 100000, scale: 128 }
const randomExpected = randomValues(randomInput).map((value, index) => {
  const expected = value.toFixed(1)
  equal(reference.toFixed1(value), expected, `100000-value rounding corpus index ${index}`)
  return expected
})
add('to-fixed', 'randomized-100000', 'to-fixed-random', randomInput, randomExpected, 'doc/spec/ai.md §13.3')
const bitBuffer = new ArrayBuffer(8)
const bitView = new DataView(bitBuffer)
let bitState = 0x564F5843
for (let index = 0; index < 200000; index += 1) {
  bitState = (Math.imul(1664525, bitState) + 1013904223) >>> 0
  const upper = bitState & 0x7FFFFFFF
  bitState = (Math.imul(1664525, bitState) + 1013904223) >>> 0
  bitView.setUint32(0, upper, false)
  bitView.setUint32(4, bitState, false)
  const value = bitView.getFloat64(0, false)
  if (Number.isFinite(value)) equal(reference.toFixed1(value), value.toFixed(1), `wide-exponent binary64 rounding ${index}`)
}

for (const vector of finalizeVectors) {
  const input = { words: { generator: 'U100' }, preset: vector.preset, candidates: vector.candidates, snap: false, cutWordIds: [], windowCount: 1 }
  equal(finalize(input), vector.expected, vector.id)
  add('finalize-clips', vector.id, 'finalize-clips', input, vector.expected, 'doc/spec/ai.md §13.4')
}
const finalizeCases = [
  ['invalid-numbers', 'best', [candidate('negative', -1, 20), candidate('NaN index', 'NaN', 30), candidate('infinite index', 0, 'Infinity'), candidate('NaN score', 0, 20, 'NaN'), candidate('infinite score', 0, 20, 'Infinity'), candidate('negative infinite', 0, 20, '-Infinity'), candidate('valid', 0, 20)]],
  ['trim-utf16-surrogate', 'best', [candidate('\uFEFF' + 'T'.repeat(119) + '😀' + 'tail\uFEFF', 0, 20, 8, '\uFEFF' + 'R'.repeat(299) + '😀' + 'tail\uFEFF')]],
  ['score-rounding-and-clamps', 'custom', [-3.5, 1.5, 2.49, 2.5, 9.5, 12].map((score, index) => candidate(`score${index}`, index * 10, index * 10 + 5, score))],
  ['empty-after-trim-is-not-title-fallback', 'best', [candidate('\uFEFF  ', 0, 20, 8, '\u00A0')]],
  ['inclusive-overlap-one-word', 'topics', [candidate('first', 0, 20), candidate('touches', 20, 40, 7), candidate('after', 21, 41, 6)]]
]
for (const [id, preset, candidates] of finalizeCases) {
  const input = { words: { generator: 'U100' }, preset, candidates, snap: false, cutWordIds: [], windowCount: 1 }
  add('finalize-clips', id, 'finalize-clips', input, finalize(input), 'doc/spec/ai.md §11.7–§11.9')
}
const sameStartInput = { words: { generator: 'U100' }, preset: 'custom', candidates: [candidate('lower score', 20, 25, 7), candidate('higher score', 20, 30, 8)], snap: false, cutWordIds: [], windowCount: 1 }
equal(finalize(sameStartInput).map(clip => clip.title), ['higher score', 'lower score'], 'same-start clips retain selection order')
add('finalize-clips', 'same-start-selection-order', 'finalize-clips', sameStartInput, finalize(sameStartInput), 'doc/spec/ai.md §11.7 step 8')
equal(datasets.get('finalize-clips').find(test => test.id === 'invalid-numbers').expected.map(clip => clip.title), ['valid'], 'non-finite values rejected individually')
equal(datasets.get('finalize-clips').find(test => test.id === 'trim-utf16-surrogate').expected[0].title, 'T'.repeat(119), 'surrogate-safe title truncation')
for (const preset of clipFinder.presets) {
  const minimum = Math.max(clipFinder.limits.minLengthFloorSeconds, preset.minSeconds * clipFinder.limits.minLengthFactor)
  const maximum = preset.maxSeconds * clipFinder.limits.maxLengthFactor
  for (const [edge, duration] of [['minimum', minimum], ['maximum', maximum], ['below-minimum', minimum - 0.000001], ['above-maximum', maximum + 0.000001]]) {
    const input = { words: [{ id: 'w0', index: 0, text: 'one', start: 0, end: duration }], preset: preset.id, candidates: [candidate('edge', 0, 0)], snap: false, cutWordIds: [], windowCount: 1 }
    const expected = finalize(input)
    equal(expected.length, edge.startsWith('below') || edge.startsWith('above') ? 0 : 1, `${preset.id} ${edge} inclusive duration`)
    add('finalize-clips', `${preset.id}-${edge}`, 'finalize-clips', input, expected, 'doc/spec/ai.md §11.7 step 4')
  }
}

for (const [index, [pair, expected]] of snapVectors.entries()) {
  equal(reference.snapPair(...pair, formattedF1.lines), expected, `S1-${index + 1}`)
  add('extensions', `S1-${index + 1}`, 'snap-pair', { pair, lines: formattedF1.lines, radius: 3 }, expected, 'doc/spec/ai.md §13.5 S1')
}
const extensionClip = (id, candidates, cutWordIds, windowCount, expectedTitles) => {
  const input = { words: { generator: 'U100' }, preset: 'best', candidates, cutWordIds, snap: false, windowCount }
  const expected = finalize(input)
  equal(expected.map(clip => clip.title), expectedTitles, id)
  add('extensions', id, 'finalize-clips', input, expected, 'doc/spec/ai.md §13.5')
}
extensionClip('M1-majority', [candidate('mostly cut', 0, 20)], Array.from({ length: 11 }, (_, index) => `w${index}`), 1, [])
extensionClip('M1-minority', [candidate('mostly kept', 30, 50)], Array.from({ length: 10 }, (_, index) => `w${30 + index}`), 1, ['mostly kept'])
extensionClip('mostly-cut-exact-half', [candidate('half kept', 0, 19)], Array.from({ length: 10 }, (_, index) => `w${index}`), 1, ['half kept'])
const nearCandidates = [candidate('A', 10, 30, 8), candidate('B', 12, 32, 8), candidate('C', 40, 60, 7)]
extensionClip('N1-multiple-windows', nearCandidates, [], 2, ['A', 'C'])
extensionClip('N1-single-window', nearCandidates, [], 1, ['A', 'B', 'C'])
extensionClip('near-duplicate-exact-threshold', [candidate('first', 0, 19), candidate('threshold', 5, 24, 7)], [], 2, ['first'])
const snappedInput = { words: f1Words, preset: 'quotes', lines: formattedF1.lines, candidates: [candidate('snapped', 7, 14)], cutWordIds: [], snap: true, windowCount: 1 }
equal(finalize(snappedInput).map(clip => [clip.startWord, clip.endWord]), [[6, 15]], 'integrated snapping before length and cut filtering')
add('extensions', 'snap-finalize-integration', 'finalize-clips', snappedInput, finalize(snappedInput), 'doc/spec/ai.md §11.7')
const cutIdsInput = { words: u100Words.map(word => ({ ...word, id: `source-${word.index}` })), preset: 'best', candidates: [candidate('cut by id', 0, 20)], cutWordIds: Array.from({ length: 11 }, (_, index) => `source-${index}`), snap: false, windowCount: 1 }
equal(finalize(cutIdsInput), [], 'mostly-cut resolves source ids, not numeric word positions')
add('extensions', 'cut-set-is-source-ids', 'finalize-clips', cutIdsInput, [], 'doc/spec/ai.md §11.7 step 5')
const w1Words = syntheticWords({ generator: 'W1' })
const w1Lines = reference.formatTranscript(w1Words).lines
const windowCase = (id, context, cap, maxWords = clipFinder.limits.maxWordsPerRequest, overlapSeconds = 60, feature = 'clipFinder') => {
  const budgeting = feature === 'clipFinder'
    ? windowBudget({ words: w1Words, lines: w1Lines, preset: presets.best, context, maxOutputTokensCap: cap }, clipFinder)
    : tightenWindowBudget({ lines: w1Lines, context, maxOutputTokensCap: cap }, aiTighten)
  const windows = reference.packWindows(w1Lines, { budget: budgeting.budget, maxWords, overlapSeconds })
  const maxClips = feature === 'clipFinder' ? Math.max(clipFinder.limits.windowMinClips, Math.ceil(presets.best.maxClips * clipFinder.limits.windowClipFactor / windows.length)) : null
  const expected = { ...budgeting, maxClips, windows: windows.map(window => ({ ...window, lineLabels: w1Lines.slice(window.firstLine, window.lastLine + 1).map(line => line.text.split(' ')[0]) })) }
  add('extensions', id, 'windows', { words: { generator: 'W1' }, feature, choice: feature === 'clipFinder' ? 'best' : 'normal', context, maxOutputTokensCap: cap, maxWords, overlapSeconds }, expected, feature === 'clipFinder' ? 'doc/spec/ai.md §13.5 W1' : 'doc/spec/ai.md §12.3')
  return expected
}
const cloudWindows = windowCase('W1-cloud', 128000, null)
equal(cloudWindows.windows.map(window => [window.firstIndex, window.lastIndex, window.entryCount]), w1Bounds, 'W1 exact three window bounds')
equal(cloudWindows.maxClips, 3, 'W1 per-window clip budget')
for (let index = 1; index < cloudWindows.windows.length; index += 1) {
  const previous = cloudWindows.windows[index - 1]
  equal(cloudWindows.windows[index].firstLine, w1Lines.findIndex(line => line.start >= w1Lines[previous.lastLine].end - 60), 'W1 overlap boundary')
}
const appleWindows = windowCase('W1-apple', 8192, 1500)
assert(appleWindows.windows.every(window => window.estimatedCost <= appleWindows.budget), 'W1 Apple budget exceeded')
const noOverlapWindows = windowCase('tighten-no-overlap-packing', 128000, null, aiTighten.limits.maxWordsPerRequest, 0, 'aiTighten')
for (let index = 1; index < noOverlapWindows.windows.length; index += 1) equal(noOverlapWindows.windows[index].firstLine, noOverlapWindows.windows[index - 1].lastLine + 1, 'tighten windows never overlap')
const oversizedLines = reference.formatTranscript(entries(Array.from({ length: 41 }, () => 'long'.repeat(100)))).lines
const oversized = reference.packWindows(oversizedLines, { budget: 600, maxWords: 10 })
equal(oversized[0].entryCount, 41, 'always pack at least one line')
add('extensions', 'oversized-first-line', 'pack-lines', { lines: oversizedLines, budget: 600, maxWords: 10, overlapSeconds: 0 }, oversized, 'doc/spec/ai.md §11.5')
assert.throws(() => reference.packWindows(formattedF1.lines, { budget: 599, maxWords: 8000 }), /contextTooLong/)
add('extensions', 'context-too-small', 'pack-lines', { lines: formattedF1.lines, budget: 599, maxWords: 8000, overlapSeconds: 0 }, { error: 'contextTooLong' }, 'doc/spec/ai.md §11.5')

const preparationItems = [
  { id: 'word', kind: 'word', text: 'wrong', correction: 'Corrected words', start: 0, end: 1 },
  { id: 'event', kind: 'event', text: '(laughs)', correction: 'ignored', start: 1, end: 2 },
  { id: 'gap', kind: 'unlabeledSpeech', text: 'ignored', start: 2, end: 3 },
  { id: 'cut', kind: 'word', text: 'cut text', start: 3, end: 4 },
  { id: 'long', kind: 'word', text: 'a'.repeat(99) + '😀tail', start: 4, end: 5 }
]
for (const feature of ['clipFinder', 'aiTighten']) {
  const options = { feature, cutWordIds: ['cut'], scope: feature === 'aiTighten' ? [0, 3] : null, maxWordTextLength: clipFinder.limits.maxWordTextLength }
  const expected = reference.prepareEntries(preparationItems, options)
  equal(expected.map(entry => entry.index), feature === 'clipFinder' ? [0, 1, 2, 3, 4] : [0, 1], `${feature} preparation`)
  add('extensions', `prepare-${feature}`, 'prepare-entries', { items: preparationItems, options }, expected, 'doc/spec/ai.md §11.2, §12.2')
}
const whitespace = '\u0009\u000A\u000B\u000C\u000D\u0020\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF'
equal(reference.jsTrim(whitespace + 'inside' + whitespace), 'inside', 'explicit JS whitespace')
equal(reference.jsTrim('\u0085\u180E\u200Binside\u0085'), '\u0085\u180E\u200Binside\u0085', 'non-JS whitespace retained')
add('extensions', 'js-trim', 'string-helpers', { text: whitespace + 'inside' + whitespace, maxLength: 500 }, 'inside', 'doc/spec/ai.md §11.9')
add('extensions', 'non-js-whitespace', 'string-helpers', { text: '\u0085\u180E\u200Binside\u0085', maxLength: 500 }, '\u0085\u180E\u200Binside\u0085', 'doc/spec/ai.md §11.9')
add('extensions', 'instructions-surrogate-boundary', 'string-helpers', { text: ' '.repeat(3) + 'a'.repeat(499) + '😀tail ', maxLength: 500 }, 'a'.repeat(499), 'doc/spec/ai.md §11.1, §11.9')

for (const vector of tightenVectors) {
  const input = { entries: vector.entries, edits: vector.edits }
  equal(reference.verifyTighten(input, aiTighten), vector.expected, vector.id)
  add('tighten-verifier', vector.id, 'tighten-verifier', input, vector.expected, 'doc/spec/ai.md §13.6')
}
const verifierCases = [
  ['duplicate', t1Entries, [{ line: '[40-49]', keep: 'So we went to the store', kind: 'filler' }, { line: '[40-49]', keep: '', kind: 'repetition' }]],
  ['bad-kind', t1Entries, [{ line: '[40-49]', keep: '', kind: 'rewrite' }]],
  ['no-op', t1Entries, [{ line: '[40-49]', keep: 'So um we we went to the uh the store', kind: 'filler' }]],
  ['unicode-nfc-and-case', entries(['E\u0301LAN', 'um', 'İ.', 'ΣΟΣ.']), [{ line: '[0-2]', keep: 'élan i\u0307', kind: 'filler' }]],
  ['whole-line-review', entries(Array.from({ length: 13 }, (_, index) => `word${index}`)), [{ line: '[0-12]', keep: '', kind: 'false_start' }]],
  ['leading-punctuation', entries(['—', 'um', 'yes.']), [{ line: '[0-2]', keep: 'yes', kind: 'filler' }]],
  ['punctuation-only-whole-line', entries(['—', '…']), [{ line: '[0-1]', keep: '', kind: 'false_start' }]],
  ['unicode-whitespace', entries(['So,', 'um', 'yes.']), [{ line: '[0-2]', keep: '\uFEFFso\u00A0yes\uFEFF', kind: 'filler' }]]
]
for (const [id, lineEntries, edits] of verifierCases) {
  const input = { entries: lineEntries, edits }
  add('tighten-verifier', id, 'tighten-verifier', input, reference.verifyTighten(input, aiTighten), 'doc/spec/ai.md §12.5')
}

const baselineOptions = (connector, clipBudget = null) => {
  if (connector.id === 'ollama') return { model: 'gemma4:12b', modelContext: 32768, capabilities: ['completion', 'thinking'] }
  if (connector.id === 'lmstudio') return { model: 'local-model' }
  if (connector.id === 'apple-foundation') return { macOSMajor: 27, clipBudget }
  if (connector.cli) return {
    supportedFlags: [...connector.cli.detect.help.requiredFlags, ...connector.cli.detect.help.optionalFlags],
    ...(connector.id === 'codex' ? { features: connector.cli.disableFeatures } : {})
  }
  return {}
}
const wireSet = (request, clipBudget = null) => Object.fromEntries(catalog.connectors.map(connector => [connector.id, renderConnector(request, connector, catalog, baselineOptions(connector, clipBudget))]))
const renderCase = (file, id, feature, words, lines, choice, instructions, window = null, extra = {}) => {
  const input = { transcript: 'F1', choice, instructions, window, language: 'en', ...extra }
  const request = canonicalRequest({ feature, words, lines, choice, instructions, window }, prompts)
  if (request.error) {
    add(file, id, 'render-request', input, request, 'doc/spec/ai.md §11.1')
    return
  }
  const clipBudget = feature === 'clipFinder' ? window?.maxClips ?? Math.max(clipFinder.limits.windowMinClips, Math.ceil(presets[choice].maxClips * clipFinder.limits.windowClipFactor)) : null
  input.connectorOptions = Object.fromEntries(catalog.connectors.map(connector => [connector.id, baselineOptions(connector, clipBudget)]))
  add(file, id, 'render-request', input, { request, connectors: wireSet(request, clipBudget) }, `doc/spec/ai.md §${feature === 'clipFinder' ? '11.4' : '12.4'}; §6`)
}
for (const preset of clipFinder.presets) {
  const overlapSeconds = Math.min(preset.maxSeconds, clipFinder.limits.windowOverlapMaxSeconds)
  const windows = reference.packWindows(formattedF1.lines, { budget: 1000000, maxWords: 66, overlapSeconds })
  equal(windows.length, 2, `F1 multi-window rendering ${preset.id}`)
  const maxClips = Math.max(clipFinder.limits.windowMinClips, Math.ceil(preset.maxClips * clipFinder.limits.windowClipFactor / windows.length))
  for (const [variant, instructions] of [['plain', ''], ['instructions', '  Funny bits  ']]) {
    renderCase('clip-finder-requests', `${preset.id}-${variant}-single`, 'clipFinder', f1Words, formattedF1.lines, preset.id, instructions)
    if (preset.requiresInstructions && !instructions) {
      renderCase('clip-finder-requests', `${preset.id}-${variant}-multiple`, 'clipFinder', f1Words, formattedF1.lines, preset.id, instructions, { index: 0, count: 2, start: 0, end: 85.55, maxClips, lastEnd: null })
      continue
    }
    for (const [index, packed] of windows.entries()) {
      const lines = formattedF1.lines.slice(packed.firstLine, packed.lastLine + 1)
      const window = { index, count: windows.length, firstLine: packed.firstLine, lastLine: packed.lastLine, start: lines[0].start, end: lines.at(-1).end, maxClips, lastEnd: preset.id === 'topics' && index > 0 ? 18 : null }
      renderCase('clip-finder-requests', `${preset.id}-${variant}-part-${index + 1}`, 'clipFinder', f1Words, lines, preset.id, instructions, window)
    }
  }
}
for (const strength of aiTighten.request.strengths) {
  for (const [variant, instructions] of [['plain', ''], ['instructions', '  Keep names and numbers.  ']]) {
    renderCase('ai-tighten-requests', `${strength.id}-${variant}-single`, 'aiTighten', f1Words, formattedF1.lines, strength.id, instructions)
    for (const [index, [firstLine, lastLine]] of [[0, 7], [8, 8]].entries()) {
      const lines = formattedF1.lines.slice(firstLine, lastLine + 1)
      const window = { index, count: 2, firstLine, lastLine, start: lines[0].start, end: lines.at(-1).end }
      renderCase('ai-tighten-requests', `${strength.id}-${variant}-part-${index + 1}`, 'aiTighten', f1Words, lines, strength.id, instructions, window)
    }
  }
}
const sparseEntries = reference.prepareEntries(preparationItems, { feature: 'aiTighten', cutWordIds: ['cut'] })
const sparseLines = reference.formatTranscript(sparseEntries).lines
renderCase('ai-tighten-requests', 'sparse-absolute-indices', 'aiTighten', sparseEntries, sparseLines, 'normal', '', null, { transcript: null, entries: sparseEntries })
for (const [feature, limit, choice, filename] of [['clipFinder', 500, 'custom', 'clip-finder-requests'], ['aiTighten', 200, 'normal', 'ai-tighten-requests']]) {
  renderCase(filename, 'utf16-user-instruction-limit', feature, f1Words, formattedF1.lines, choice, '\uFEFF' + 'x'.repeat(limit - 1) + '😀ignored\uFEFF')
}

const bestRequest = canonicalRequest({ feature: 'clipFinder', words: f1Words, lines: formattedF1.lines, choice: 'best' }, prompts)
const testRequest = { feature: 'test', system: catalog.testRequest.system, cachedBlock: null, instruction: catalog.testRequest.instruction, schemaName: catalog.testRequest.schemaName, schema: catalog.testRequest.schema, maxOutputTokens: catalog.testRequest.maxOutputTokens, effort: catalog.testRequest.effort, language: 'en' }
for (const connector of catalog.connectors) {
  const options = baselineOptions(connector)
  add('connector-requests', `connection-test-${connector.id}`, 'connector-request', { request: testRequest, connector: connector.id, options }, renderConnector(testRequest, connector, catalog, options), 'doc/spec/ai.md §10.2; §6')
}
const variants = [
  ['anthropic-no-fallback-beta', 'anthropic', { serverSideFallback: false }],
  ['anthropic-haiku', 'anthropic', { model: 'claude-haiku-5-5' }],
  ['anthropic-legacy-no-effort', 'anthropic', { model: 'legacy-model' }],
  ['anthropic-custom-schema-instruction', 'anthropic', { model: 'custom-model', structuredOutputsSupported: false }],
  ['anthropic-custom-five-effort', 'anthropic', { model: 'claude-fable-5-custom' }],
  ['anthropic-discovered-effort', 'anthropic', { model: 'discovered-model', effortSupported: true }],
  ['openai-legacy-no-effort', 'openai', { model: 'gpt-4.1' }],
  ['openai-custom-reasoning', 'openai', { model: 'o3-custom' }],
  ['gemini-model-path-escaping', 'gemini', { model: 'models/custom/model with space?#' }],
  ['ollama-no-thinking', 'ollama', { capabilities: ['completion'] }],
  ['ollama-context-cap', 'ollama', { modelContext: 8192 }],
  ['lmstudio-custom-base', 'lmstudio', { baseUrl: 'http://127.0.0.1:2345/' }],
  ['apple-macos-26', 'apple-foundation', { macOSMajor: 26, clipBudget: 5 }],
  ['claude-cli-default-required-flags-only', 'claude-code', { model: 'default', supportedFlags: connectors['claude-code'].cli.detect.help.requiredFlags }],
  ['codex-model-supported-effort', 'codex', { model: 'gpt-6.1-sol', supportedEfforts: ['low', 'medium', 'high'] }],
  ['codex-model-unsupported-effort', 'codex', { model: 'custom-model', supportedEfforts: ['low'] }],
  ['codex-removed-and-unknown-features', 'codex', { supportedFlags: connectors.codex.cli.detect.help.requiredFlags, features: [{ name: 'shell_tool', stage: 'stable' }, { name: 'plugins', stage: 'removed' }, { name: 'unknown-feature', stage: 'experimental' }] }]
]
for (const [id, connector, overrides] of variants) {
  const options = { ...baselineOptions(connectors[connector], 8), ...overrides }
  add('connector-requests', id, 'connector-request', { request: bestRequest, connector, options }, renderConnector(bestRequest, connectors[connector], catalog, options), 'doc/spec/ai.md §6')
}
const specialSystem = 'Quote " slash \\ backspace\b tab\t line\n form\f return\r control\u0001 del\u007F 😀 e\u0301'
const specialRequest = { ...testRequest, system: specialSystem }
const specialExpected = '"Quote \\" slash \\\\ backspace\\b tab\\t line\\n form\\f return\\r control\\u0001 del\\u007F 😀 e\u0301"'
equal(tomlBasicString(specialSystem), specialExpected, 'Codex TOML escaping every control class')
add('connector-requests', 'codex-toml-scalar-escaping', 'connector-request', { request: specialRequest, connector: 'codex', options: {} }, renderConnector(specialRequest, connectors.codex, catalog), 'doc/spec/ai.md §6.9')
const maxSchema = { type: 'object', additionalProperties: false, required: ['name', 'fraction'], properties: { name: { type: 'string', enum: ['yes', 'no'] }, fraction: { type: 'number' } } }
reference.validateSchema(maxSchema)
const schemaRequest = { ...testRequest, schemaName: 'primitive_mapping', schema: maxSchema }
const appleMapping = renderConnector(schemaRequest, connectors['apple-foundation'], catalog)
equal(appleMapping.schema.root.properties[0].schema, { name: 'primitive_mapping_name', anyOf: ['yes', 'no'] }, 'Apple string enum mapping')
equal(appleMapping.schema.root.properties[1].schema, { type: 'Double' }, 'Apple number mapping')
const nestedAppleMapping = appleSchema({
  type: 'object', properties: {
    detail: { type: 'object', properties: { kind: { type: 'string', enum: ['yes', 'no'] } } },
    clips: { type: 'array', items: { type: 'object', properties: {
      detail: { type: 'object', properties: { kind: { type: 'string', enum: ['yes', 'no'] } } }
    } } },
    values: { type: 'array', items: { type: 'array', items: { type: 'string', enum: ['yes', 'no'] } } }
  }
}, 'nested_mapping', 5)
equal(nestedAppleMapping, {
  name: 'nested_mapping', properties: [
    { name: 'detail', isOptional: false, schema: {
      name: 'nested_mapping_detail', properties: [
        { name: 'kind', isOptional: false, schema: { name: 'nested_mapping_detail_kind', anyOf: ['yes', 'no'] } }
      ]
    } },
    { name: 'clips', isOptional: false, schema: { maximumElements: 5, arrayOf: {
      name: 'nested_mapping_clips_item', properties: [
        { name: 'detail', isOptional: false, schema: {
          name: 'nested_mapping_clips_item_detail', properties: [
            { name: 'kind', isOptional: false, schema: { name: 'nested_mapping_clips_item_detail_kind', anyOf: ['yes', 'no'] } }
          ]
        } }
      ]
    } } },
    { name: 'values', isOptional: false, schema: { maximumElements: null, arrayOf: {
      maximumElements: null, arrayOf: { name: 'nested_mapping_values_item_item', anyOf: ['yes', 'no'] }
    } } }
  ]
}, 'Apple recursive full-path schema names and array budgets')
const tightenAppleMapping = appleSchema(aiTighten.output.schema, aiTighten.output.name)
equal(tightenAppleMapping.name, 'tighten_edits', 'Apple tighten root name')
equal(tightenAppleMapping.properties[0].schema.arrayOf.name, 'tighten_edits_edits_item', 'Apple tighten item name')
equal(tightenAppleMapping.properties[0].schema.arrayOf.properties[2].schema.name, 'tighten_edits_edits_item_kind', 'Apple tighten enum name')
add('connector-requests', 'apple-enum-and-number-mapping', 'connector-request', { request: schemaRequest, connector: 'apple-foundation', options: { macOSMajor: 27, clipBudget: null } }, appleMapping, 'doc/spec/ai.md §6.7')
for (const connector of catalog.connectors) {
  const request = { ...testRequest, effort: null }
  const options = baselineOptions(connector)
  add('connector-requests', `null-effort-${connector.id}`, 'connector-request', { request, connector: connector.id, options }, renderConnector(request, connector, catalog, options), 'doc/spec/ai.md §2.1; §6')
}

const wire = wireSet(bestRequest, 5)
equal(wire.anthropic.body.messages[0].content[0].cache_control, { type: 'ephemeral' }, 'Anthropic cache block')
equal(wire.anthropic.body.fallbacks, 'default', 'Anthropic fallback body')
equal(wire.openai.body.prompt_cache_key, 'voxclip-' + sha256(bestRequest.cachedBlock).slice(0, 16), 'OpenAI cache hash')
equal(wire.openai.body.store, false, 'OpenAI store false')
equal(wire.xai.body.messages[1].content, bestRequest.cachedBlock + '\n\n' + bestRequest.instruction, 'joined user content')
equal(wire.gemini.body.contents[0].parts.length, 2, 'Gemini separate user parts')
equal(wire.ollama.body.options.num_predict, 4096, 'Ollama output cap')
const ollamaNeeded = reference.estimateTokens(bestRequest.system) + reference.estimateTokens(bestRequest.cachedBlock) + reference.estimateTokens(bestRequest.instruction) + reference.estimateTokens(JSON.stringify(bestRequest.schema)) + 4096 + 256
equal(wire.ollama.body.options.num_ctx, Math.min(32768, Math.max(8192, Math.ceil(ollamaNeeded / 1024) * 1024)), 'Ollama num_ctx computation')
equal(wire.lmstudio.body.max_tokens, 4096, 'LM Studio output cap')
equal(wire['apple-foundation'].options.maximumResponseTokens, 1500, 'Apple output cap')
equal(wire['apple-foundation'].schema.root.name, 'clips', 'Apple clip root name')
equal(wire['apple-foundation'].schema.root.properties[0].schema.arrayOf.name, 'clips_clips_item', 'Apple clip item name')
equal(wire['claude-code'].argv.slice(0, 4), ['-p', '--output-format', 'json', '--json-schema'], 'Claude argv prefix')
equal(wire['claude-code'].argv[wire['claude-code'].argv.indexOf('--fallback-model') + 1], 'haiku', 'Claude fallback excludes selected model')
assert(!wire.codex.argv.includes('--model'), 'Codex default must omit model')
for (const [id, rendered] of Object.entries(wire)) {
  if (rendered.kind !== 'http') continue
  for (const forbidden of ['temperature', 'top_p', 'top_k', 'thinking', 'thinkingConfig', 'responseSchema', 'reasoning_effort']) {
    if (!['ollama', 'lmstudio'].includes(id)) assert(!JSON.stringify(rendered.body).includes(`"${forbidden}":`), `${id} sent forbidden ${forbidden}`)
  }
}
for (const invalid of [
  { type: 'object', properties: { item: { type: 'string' } }, required: [], additionalProperties: false },
  { type: 'string', minLength: 1 }, { type: 'integer', enum: [1] }, { type: ['null', 'string'] },
  { type: 'object', properties: {}, required: [], additionalProperties: true }, { type: 'array', items: { type: 'null' } }
]) assert.throws(() => reference.validateSchema(invalid), undefined, 'schema subset must reject invalid schema')

const assertAppleSchema = (schema, names = new Set()) => {
  assert.notEqual(schema.$ref, '#', 'Apple schema must not reference its root')
  if (schema.name !== undefined) {
    assert(!names.has(schema.name), `duplicate Apple schema name: ${schema.name}`)
    names.add(schema.name)
  }
  for (const property of schema.properties ?? []) assertAppleSchema(property.schema, names)
  if (schema.arrayOf) assertAppleSchema(schema.arrayOf, names)
}
assert.throws(() => assertAppleSchema({ name: 'duplicate', properties: [
  { name: 'items', schema: { arrayOf: { name: 'duplicate', properties: [] } } }
] }), /duplicate Apple schema name/, 'Apple duplicate-name guard')
assert.throws(() => assertAppleSchema({ arrayOf: { $ref: '#' } }), /must not reference its root/, 'Apple root self-reference guard')
for (const cases of datasets.values()) {
  for (const test of cases) {
    const apple = test.input.connector === 'apple-foundation' ? test.expected : test.expected.connectors?.['apple-foundation']
    if (apple) assertAppleSchema(apple.schema.root)
  }
}

const json = value => JSON.stringify(value, null, 2) + '\n'
const writeFixtures = async directory => {
  await mkdir(directory, { recursive: true })
  for (const [name, cases] of datasets) {
    const data = json({ schema: 'voxclip-llm-fixtures/1', id: name, origin: 'voxclip', sources: sourceHashes, cases })
    assert(Buffer.byteLength(data) <= 2 * 1024 * 1024, `${name}.json exceeds the 2 MiB synthetic fixture limit`)
    JSON.parse(data)
    await writeFile(join(directory, `${name}.json`), data, 'utf8')
  }
}
const names = [...datasets.keys()].map(name => `${name}.json`).sort()
if (process.argv.includes('--check')) {
  const temporary = await mkdtemp(join(tmpdir(), 'voxclip-llm-fixtures-'))
  try {
    await writeFixtures(temporary)
    const actualNames = (await readdir(output)).filter(name => name.endsWith('.json')).sort()
    equal(actualNames, names, 'fixture filenames (missing or stale JSON)')
    for (const name of names) {
      const actual = await readFile(join(output, name))
      const expected = await readFile(join(temporary, name))
      if (!actual.equals(expected)) {
        const actualLines = actual.toString('utf8').split('\n')
        const expectedLines = expected.toString('utf8').split('\n')
        let line = 0
        while (line < Math.max(actualLines.length, expectedLines.length) && actualLines[line] === expectedLines[line]) line += 1
        throw new Error(`${relative(root, join(output, name))}:${line + 1} differs from regenerated fixture; run npm --prefix tools/fixtures/llm run generate\n- ${actualLines[line] ?? '<missing>'}\n+ ${expectedLines[line] ?? '<missing>'}`)
      }
    }
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
} else {
  await writeFixtures(output)
  for (const name of await readdir(output)) if (name.endsWith('.json') && !names.includes(name)) await rm(join(output, name))
}
for (const [name, cases] of datasets) {
  const requestCount = cases.reduce((count, test) => count + (test.expected.connectors ? Object.keys(test.expected.connectors).length : test.kind === 'connector-request' ? 1 : 0), 0)
  console.log(`${name}.json: ${cases.length} cases${requestCount ? `, ${requestCount} connector renderings` : ''}`)
}
console.log(`${process.argv.includes('--check') ? 'Checked' : 'Generated'} ${names.length} files; all §13.2–§13.6 vectors and 100000 randomized rounding values passed.`)
