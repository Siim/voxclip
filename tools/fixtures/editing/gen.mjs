// Generates the editing-engine golden fixtures in shared/fixtures/editing/<group>/<name>.json.
//
//   npm run generate   write every fixture and delete stale ones
//   npm run check      regenerate in memory and fail if any committed file differs
//
// Expectations come from three origins, recorded in each fixture's "origin":
//   voxconvo                 the vendored VoxConvo TypeScript in ./reference, run as is
//   voxconvo-reimplemented   VoxConvo UI semantics re-implemented here (VoiceRecorder.tsx is not vendored)
//   voxclip                  rules VoxClip defines (doc/spec/editing.md), implemented in ./lib/voxclip.mjs
import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync, existsSync } from 'node:fs'
import { isDeepStrictEqual } from 'node:util'
import { timeline, timelineWith, timing, clips, boundaries, audioEditor, StubAudioBuffer } from './lib/reference.mjs'
import { formatJson } from './lib/format.mjs'
import { makeTake, takeInput } from './lib/audio.mjs'
import * as vc from './lib/voxclip.mjs'

const CHECK = process.argv.includes('--check')
const ROOT = new URL('../../../', import.meta.url)
const OUT = new URL('shared/fixtures/editing/', ROOT)
const SCHEMA = 'voxclip-editing-fixture/1'

// The reference lower-cases with the host locale (transcriptionTiming.ts:8). Turkish, Azeri and
// Lithuanian locales change the result, so refuse to generate under them.
const hostLocale = Intl.DateTimeFormat().resolvedOptions().locale
if (/^(tr|az|lt)\b/i.test(hostLocale)) throw new Error(`run the generator under a non tr/az/lt locale (host is ${hostLocale}), e.g. LC_ALL=en_US.UTF-8`)

const { buildMediaEditPlan } = timeline
const { alignTranscriptWords, estimateTranscriptWords } = timing
const { clipTimes } = clips
const { refineWordBoundaries } = boundaries

const enc = x => Number.isNaN(x) ? 'NaN' : x === Infinity ? 'Infinity' : x === -Infinity ? '-Infinity' : x
const fromJson = v => v === 'NaN' ? NaN : v === 'Infinity' ? Infinity : v === '-Infinity' ? -Infinity : v
const uniq = xs => [...new Set(xs.map(x => typeof x === 'number' ? x : String(x)))].map(x => x === 'NaN' ? NaN : x)
const assert = (ok, message) => { if (!ok) throw new Error('self-check failed: ' + message) }

const fixtures = []
function add({ id, kind, origin, source, description, notes, input, expected, informative }) {
  assert(/^[a-z0-9-]+\/[a-z0-9.-]+$/.test(id), 'fixture id ' + id)
  assert(!fixtures.some(f => f.id === id), 'duplicate id ' + id)
  fixtures.push({ schema: SCHEMA, id, kind, origin, source, description, notes, input, expected, informative })
}

// ---------- edit-plan ----------
const w = (id, start, end, cut = false, text) => ({ id, kind: 'word', text: text ?? id, start, end, cut })
const p = (id, start, end, cut = true) => ({ id, kind: 'pause', start, end, cut })
const r = (id, start, end) => ({ id, kind: 'range', start, end, cut: true })

async function plan({ id, origin = 'voxconvo', source, description, notes, duration, sampleRate = 48000, segments, pauseKeepSeconds, mapProbes = [], sourceProbes = [] }) {
  const mod = pauseKeepSeconds === undefined ? timeline : await timelineWith({ pauseKeep: pauseKeepSeconds })
  const refSegs = vc.toReferenceSegments(segments.map(s => ({ ...s, start: fromJson(s.start), end: fromJson(s.end) })))
  const built = mod.buildMediaEditPlan(refSegs, duration, sampleRate)
  const isValid = s => Number.isFinite(s.start) && Number.isFinite(s.end) && s.end > s.start
  const isRangeCut = s => !!s.isPause || !!s.id?.startsWith('pause-') || !!s.id?.startsWith('clip-')
  const speech = refSegs.filter(x => isValid(x) && !isRangeCut(x)).sort((a, b) => a.start - b.start)
  const total = built.totalSamples
  const clampSample = t => Math.max(0, Math.min(total, Math.round(t * sampleRate)))
  const segmentCuts = refSegs.filter(s => s.isStrikethrough && isValid(s)).map(s => {
    const [rawStart, rawEnd] = mod.cutRange(s, speech, duration)
    const startSample = clampSample(rawStart), endSample = clampSample(rawEnd)
    return { id: s.voxclip.id, rawStart, rawEnd, startSample, endSample, empty: !(endSample > startSample) }
  })
  const mapIn = uniq([0, -1, NaN, duration, duration + 1, ...built.cuts.flatMap(c => [c.start, c.end, (c.start + c.end) / 2]), ...built.kept.map(k => (k.start + k.end) / 2), ...mapProbes.map(fromJson)])
  const editedEdges = []; let acc = 0
  for (const k of built.kept) { editedEdges.push(acc / sampleRate); acc += k.endSample - k.startSample; editedEdges.push(acc / sampleRate) }
  const srcIn = uniq([0, -1, NaN, built.duration, built.duration + 1, ...editedEdges, ...sourceProbes.map(fromJson)])
  const skipIn = uniq([0, ...built.cuts.flatMap(c => [c.start, (c.start + c.end) / 2, c.end])])
  add({
    id, kind: 'edit-plan', origin, source, description, notes,
    input: { durationSeconds: duration, sampleRate, ...(pauseKeepSeconds === undefined ? {} : { pauseKeepSeconds }), segments },
    expected: {
      totalSamples: built.totalSamples,
      outputSamples: built.outputSamples,
      durationSeconds: built.duration,
      segmentCuts,
      cuts: built.cuts.map(c => [c.startSample, c.endSample]),
      kept: built.kept.map(k => [k.startSample, k.endSample]),
      captions: vc.captionsFor(refSegs, built).map(x => ({ id: x.voxclip.id, start: x.start, end: x.end })),
      mapTime: mapIn.map(t => [enc(t), built.mapTime(t)]),
      sourceTime: srcIn.map(t => [enc(t), built.sourceTime(t)]),
      previewSkip: skipIn.map(t => { const c = built.cuts.find(q => t >= q.start && t < q.end); return [t, c ? c.end : null] })
    }
  })
}

const T = 'vox-web/test/caption-timing.test.mjs'
const A = 'vox-api/test/video-timeline.test.cjs'

await plan({ id: 'plan/no-cuts-identity', source: 'synthetic', description: 'No cuts: intro, outro and gaps are kept; every caption keeps its source time.', duration: 5, sampleRate: 1000,
  segments: [w('hello', 0.5, 1.0), w('world', 2.0, 2.6)] })
await plan({ id: 'plan/word-reach-capped', source: 'synthetic', description: 'A removed word takes WORD_REACH (0.1 s) of silence on each side when gaps are wide.', duration: 6, sampleRate: 1000,
  segments: [w('so', 1.0, 1.4), w('um', 2.0, 2.3, true), w('then', 3.0, 3.5)] })
await plan({ id: 'plan/word-reach-half-gap', source: 'synthetic', description: 'Narrow gaps: reach is half the gap (0.05 before, 0.03 after).', duration: 4, sampleRate: 1000,
  segments: [w('a', 1.0, 1.5), w('b', 1.6, 2.0, true), w('c', 2.06, 2.5)] })
await plan({ id: 'plan/touching-words-no-reach', source: 'synthetic', description: 'Words that touch have no silence to take; the cut is exactly the word.', duration: 3, sampleRate: 1000,
  segments: [w('a', 0.5, 1.0), w('b', 1.0, 1.4, true), w('c', 1.4, 2.0)] })
await plan({ id: 'plan/adjacent-cuts-merge', source: 'synthetic', description: 'Two neighbouring removed words merge into one cut that includes the gap between them.', duration: 5, sampleRate: 1000,
  segments: [w('keep', 0.5, 1.0), w('you', 1.5, 1.7, true), w('know', 1.75, 2.0, true), w('right', 2.6, 3.0)] })
await plan({ id: 'plan/first-word-at-start', source: 'synthetic', description: 'First word: the silence before it is measured from 0 (reach = min(0.1, start/2)).', duration: 3, sampleRate: 1000,
  segments: [w('um', 0.05, 0.4, true), w('hello', 1.0, 1.5)] })
await plan({ id: 'plan/last-word-to-end', source: 'synthetic', description: 'Last word: the silence after it runs to the media duration.', duration: 3, sampleRate: 1000,
  segments: [w('hello', 0.5, 1.0), w('bye', 2.8, 2.95, true)] })
await plan({ id: 'plan/pause-both-neighbours-kept', source: 'synthetic', description: 'A tightened pause keeps 0.15 s after the word before and 0.15 s before the word after.', duration: 5, sampleRate: 1000,
  segments: [w('so', 0.5, 1.0), p('pause-after-so', 1.0, 2.5), w('right', 2.5, 3.0)] })
await plan({ id: 'plan/pause-word-before-cut', source: 'synthetic', description: 'If the word before the pause is cut, the pause cut starts at the pause start and merges with the word cut.', duration: 5, sampleRate: 1000,
  segments: [w('so', 0.5, 1.0), w('um', 1.2, 1.5, true), p('pause-after-um', 1.5, 3.0), w('right', 3.0, 3.5)] })
await plan({ id: 'plan/pause-word-after-cut', source: 'synthetic', description: 'If the word after the pause is cut, no breath is kept on that side.', duration: 5, sampleRate: 1000,
  segments: [w('so', 0.5, 1.0), p('pause-after-so', 1.0, 2.2), w('uh', 2.2, 2.5, true), w('right', 2.9, 3.4)] })
await plan({ id: 'plan/pause-too-short-to-cut', source: 'synthetic', description: 'A pause shorter than the two breaths (0.3 s) produces an empty cut, which is dropped.', duration: 3, sampleRate: 1000,
  segments: [w('a', 0.5, 1.0), p('pause-after-a', 1.0, 1.25), w('b', 1.25, 1.6)] })
await plan({ id: 'plan/pause-not-cut-ignored', source: 'synthetic', description: 'A pause that is not cut never affects the plan.', duration: 4, sampleRate: 1000,
  segments: [w('a', 0.5, 1.0), p('pause-after-a', 1.0, 2.5, false), w('b', 2.5, 3.0)] })
await plan({ id: 'plan/overlapping-fillers-and-pause', source: `${T}:43`, description: 'Overlapping fillers and an adjacent pause cut remove each source sample once.', duration: 10, sampleRate: 1000,
  segments: [w('um', 1, 2, true), w('uh', 1.5, 2.5, true), p('pause-after-uh', 2.5, 4), w('hello', 4, 4.5)] })
await plan({ id: 'plan/invalid-and-out-of-bounds', source: `${T}:52`, description: 'Invalid (NaN, backwards) segments are ignored; out-of-range cuts clamp to [0, duration].', duration: 10, sampleRate: 1000,
  segments: [w('early', -3, 0.1, true), w('late', 9.9, 20, true), w('bad', 'NaN', 5, true), w('backwards', 7, 6, true), w('kept', 0, 0.2), w('invalid-active', 'NaN', 1)] })
await plan({ id: 'plan/kept-word-overlapping-cut', source: `${T}:61`, description: 'Both caption boundaries map independently when a kept word overlaps a cut.', duration: 5, sampleRate: 1000,
  segments: [w('kept', 1, 3), w('cut', 2, 2.5, true)] })
await plan({ id: 'plan/pause-breath-and-filler', source: `${T}:137`, description: 'A shortened pause keeps a natural breath; a removed word leaves none of itself behind.', duration: 6, sampleRate: 1000,
  segments: [w('so', 1, 1.4), p('pause-after-so', 1.4, 3.4), w('right', 3.4, 3.9), w('um', 4.2, 4.5, true), w('then', 4.8, 5.2)] })
await plan({ id: 'plan/inverse-scrub', source: `${T}:108`, description: 'Scrub positions use the inverse of the same merged cut plan.', duration: 5, sampleRate: 1000,
  segments: [w('first', 1, 2, true), w('second', 3, 4, true)], sourceProbes: [0.5, 1, 1.75, 2, 2.5] })
await plan({ id: 'plan/repeated-edit-from-source', source: `${T}:93`, description: 'Every edit derives from the original timeline: cutting hello+um leaves world at 0.6-1.6.', duration: 5, sampleRate: 1000,
  segments: [w('hello', 0.2, 1, true), w('um', 1, 1.4, true), w('world', 2, 3)] })
await plan({ id: 'plan/complete-removal', source: `${T}:115`, description: 'Removing everything yields no kept media and no captions (exporters must refuse).', duration: 1, sampleRate: 1000,
  segments: [w('all', -1, 9, true)] })
await plan({ id: 'plan/clip-head-tail', source: `${A}:147`, description: 'A clip keeps only its own range, including the gaps between its words.', duration: 4, sampleRate: 48000,
  segments: [w('before', 0.2, 0.6, true), w('clip', 1.0, 1.4), w('words', 1.7, 2.1), w('after', 2.6, 3.0, true), r('clip-head', 0, 0.88), r('clip-tail', 2.35, 3603)] })
await plan({ id: 'plan/clip-long-take-with-filler', source: `${A}:184`, description: 'A clip from a long take with a filler cut inside it.', duration: 20, sampleRate: 48000,
  segments: [r('clip-head', 0, 8), w('one', 8.2, 9), w('um', 9.4, 9.9, true), w('two', 10.2, 11.6), r('clip-tail', 12, 3612)] })
await plan({ id: 'plan/nested-word', source: 'synthetic', description: 'A word inside an earlier word is cut exactly (no reach); the outer caption is shortened.', duration: 3, sampleRate: 1000,
  segments: [w('outer', 1.0, 2.0), w('inner', 1.2, 1.4, true), w('next', 2.5, 2.8)] })
await plan({ id: 'plan/overlapping-next-word', source: 'synthetic', description: 'When the next word starts before this one ends, reach after is 0.', duration: 3, sampleRate: 1000,
  segments: [w('a', 0.5, 0.9), w('b', 1.0, 1.5, true), w('c', 1.4, 1.9)] })
await plan({ id: 'plan/stable-sort-tie-a', source: 'synthetic', description: 'Equal start times keep input order (stable sort). Here the kept word comes first, so b has no reach before.', duration: 3, sampleRate: 1000,
  segments: [w('a', 1.0, 1.2), w('b', 1.0, 1.5, true), w('c', 2.0, 2.4)] })
await plan({ id: 'plan/stable-sort-tie-b', source: 'synthetic', description: 'Same words, reversed input order: b now sorts first and takes 0.1 s before itself.', duration: 3, sampleRate: 1000,
  segments: [w('b', 1.0, 1.5, true), w('a', 1.0, 1.2), w('c', 2.0, 2.4)] })
await plan({ id: 'plan/rounding-half-up', source: 'synthetic', description: 'Sample rounding is JS Math.round (ties toward +infinity), not banker\'s rounding: 62.5 -> 63, 1062.5 -> 1063.', duration: 2, sampleRate: 1000,
  segments: [w('x', 0.5, 0.6), r('clip-a', 0.0625, 0.25), r('clip-b', 1.0, 1.0625)], sourceProbes: [0.0005, 0.0015] })
await plan({ id: 'plan/rounding-unit-rate', source: 'synthetic', description: 'Rounding edge cases at sampleRate 1: 0.49999999999999994 rounds to 0 (floor(x+0.5) is wrong), 2.5 -> 3.', duration: 10, sampleRate: 1,
  segments: [w('x', 1, 2)], mapProbes: [0.49999999999999994, 2.5, 3.5], sourceProbes: [0.49999999999999994, 2.5, 3.5] })
await plan({ id: 'plan/zero-duration', source: 'synthetic', description: 'Zero-length media: no samples, everything maps to 0.', duration: 0, sampleRate: 48000,
  segments: [w('a', 0, 0.5), w('b', 0.6, 0.9, true)] })
{
  const segs = []
  for (let i = 0; i < 6; i++) { segs.push(w(`filler-${i}`, i * 0.2 + 0.02001, i * 0.2 + 0.09003, true)); segs.push(w(`speech-${i}`, i * 0.2 + 0.1, i * 0.2 + 0.18)) }
  await plan({ id: 'plan/many-fractional-cuts-44100', source: `${T}:66 (first 6 of 35 pairs)`, description: 'Fractional cuts at 44.1 kHz: captions and samples use the same rounding.', duration: 2, sampleRate: 44100, segments: segs })
}
await plan({ id: 'plan/many-fillers-48k', source: `${A}:29`, description: '17 filler cuts on an 8 s take at 48 kHz (server test shape).', duration: 8, sampleRate: 48000,
  segments: [...Array.from({ length: 17 }, (_, i) => w(`um-${i}`, 0.41 + i * 0.39, 0.523 + i * 0.39, true, 'um')), w('last', 7.3, 7.7)] })
await plan({ id: 'plan/captions-off-pause-and-filler', source: `${A}:76`, description: 'Pause and filler cuts apply regardless of caption style.', duration: 8, sampleRate: 48000,
  segments: [w('hello', 0.2, 0.7), p('pause-after-hello', 1, 2), w('um', 3, 3.3, true), w('world', 4, 4.7)] })
// VoxClip additions
await plan({ id: 'plan/kinds-not-id-prefixes', origin: 'voxclip', source: 'doc/spec/editing.md (explicit segment kinds)', duration: 6, sampleRate: 48000,
  description: 'Segment type comes from kind only. A word whose id starts with "pause-" or "clip-" is still a word (it gets word reach and a caption); a range and a pause with neutral ids behave as range and pause.',
  notes: 'VoxConvo infers type from id prefixes and its upload payload drops ids, so the server planned clip head/tail as words (research section 9.1). VoxClip never looks at ids.',
  segments: [w('pause-like-word', 0.5, 0.9, true, 'um'), w('so', 1.5, 1.9), p('gap-1', 1.9, 3.4), w('clip-like-word', 3.4, 3.8, false, 'right'), r('head', 0, 0.2), r('tail', 5.5, 3605.5)] })
await plan({ id: 'plan/non-caption-items', origin: 'voxclip', source: 'doc/spec/editing.md (word kinds)', duration: 5, sampleRate: 1000,
  description: 'Kept event and unlabeledSpeech items bound the silence like words (a cut neighbour only reaches half the gap) but never become captions.',
  segments: [w('hello', 0.5, 1.0), { ...w('laugh', 1.2, 1.6, false, '(laughs)'), wordKind: 'event' }, w('um', 1.7, 1.9, true), { ...w('mumble', 2.0, 2.3, false, '…'), wordKind: 'unlabeledSpeech' }, w('world', 3.0, 3.5)] })
await plan({ id: 'plan/pause-breath-tight', origin: 'voxclip', source: 'doc/spec/editing.md (pauseKeepSeconds)', duration: 5, sampleRate: 1000, pauseKeepSeconds: 0.05,
  description: 'The pause breath is a project parameter. With pauseKeepSeconds 0.05 the same pause as plan/pause-both-neighbours-kept keeps 0.05 s on each side.',
  segments: [w('so', 0.5, 1.0), p('pause-after-so', 1.0, 2.5), w('right', 2.5, 3.0)] })

// ---------- pause detection ----------
for (const [id, hasAudio, words, description] of [
  ['pauses/refined-0.8', true, [{ id: 'a', start: 0, end: 0.5 }, { id: 'b', start: 1.3, end: 1.6 }, { id: 'c', start: 2.39, end: 2.7 }, { id: 'd', start: 4.0, end: 4.2 }], 'With decoded audio (refined boundaries) the threshold is 0.8 s, inclusive.'],
  ['pauses/raw-1.0', false, [{ id: 'a', start: 0, end: 0.5 }, { id: 'b', start: 1.3, end: 1.6 }, { id: 'c', start: 2.6, end: 2.7 }, { id: 'd', start: 4.0, end: 4.2 }], 'Without decoded audio the threshold is 1.0 s.'],
  ['pauses/label-rounding', true, [{ id: 'a', start: 0, end: 1.0 }, { id: 'b', start: 2.25, end: 2.5 }, { id: 'c', start: 3.35, end: 3.5 }, { id: 'd', start: 4.35, end: 5 }, { id: 'e', start: 7.25, end: 7.5 }], 'Labels use JS toFixed(1): exact ties round up (1.25 -> "1.3", 2.25 -> "2.3"); printf-style %.1f gives "1.2".'],
  ['pauses/overlap-and-order', true, [{ id: 'a', start: 0, end: 1.0 }, { id: 'b', start: 0.9, end: 1.2 }, { id: 'c', start: 3.0, end: 3.4 }], 'Only consecutive words in transcript order are compared; overlaps (negative gaps) are not pauses; no leading/trailing silence pause.'],
]) add({ id, kind: 'pause-detection', origin: 'voxconvo-reimplemented', source: 'vox-web/src/components/VoiceRecorder/VoiceRecorder.tsx:784-802', description, input: { hasDecodedAudio: hasAudio, words }, expected: { pauses: vc.detectPauses(words, hasAudio ? vc.PAUSE_THRESHOLD_REFINED : vc.PAUSE_THRESHOLD_UNREFINED) } })
{
  let seed = 4242
  const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647
  const gaps = [0.8, 0.85, 0.95, 1, 1.05, 1.15, 1.25, 1.35, 1.45, 2.25, 9.95, 10.05, 59.95, 3.35 - 2.5, 4.35 - 3.5, 123.45]
  for (let i = 0; i < 64; i++) { const a = Math.round(rnd() * 60000) / 100; const b = a + Math.round(80 + rnd() * 900) / 100; gaps.push(b - a) }
  add({ id: 'pauses/label-to-fixed', kind: 'pause-label', origin: 'voxconvo-reimplemented', source: 'vox-web/src/components/VoiceRecorder/WordChip.tsx:37 (JS Number.prototype.toFixed(1))',
    description: 'Pause chip labels for many durations, including gaps computed as differences of two decimal times. Implement toFixed1 exactly (spec section 4.4); platform formatting APIs disagree on ties.',
    input: { durations: gaps }, expected: { labels: gaps.map(vc.pauseLabel) } })
}

// ---------- filler detection ----------
const fillerInputs = ['um', 'Um', 'UMM', 'ummmm', 'uh', 'Uh,', 'uhh.', 'erm', 'Erm?', 'ermm!', 'hmm', 'Hmmm,', 'hm', 'uhm', 'er', 'ah', 'mm', 'eh', 'like', 'um...', 'um,,', '"um"', 'um-', ' um', 'um ', 'umbrella', 'hum', 'Ümm', 'um;', 'uh?']
add({ id: 'fillers/regex', kind: 'filler-detection', origin: 'voxconvo-reimplemented', source: 'vox-web/src/components/VoiceRecorder/VoiceRecorder.tsx:1054', description: 'Exact reference filler rule: /^(um+|uh+|erm+|hmm+)[,.!?]?$/i on the current (corrected) word text; already-cut words are not counted.', input: { pattern: vc.FILLER.source, flags: 'i', words: fillerInputs }, expected: { matches: fillerInputs.map(x => vc.isFillerText(x)) } })
{
  const more = ['um\n', 'um\r\n', 'UM\n', 'uM', 'hMM!', 'HmMmM.', 'ermmm?', 'Uhhh.', 'um ', 'umm…', 'u m', 'hmm?!', 'ＵＭ', 'úm', 'um​', 'erm.', 'ERRM', 'uhh,', 'mmm', 'UH!']
  add({ id: 'fillers/anchors-and-case', kind: 'filler-detection', origin: 'voxconvo-reimplemented', source: 'vox-web/src/components/VoiceRecorder/VoiceRecorder.tsx:1054',
    description: 'The same rule on inputs where regex engines differ: JS "$" (no m flag) matches only at the very end, so "um\\n" is not a filler (.NET and ICU "$" also match before a final newline); /i folds ASCII only here, so full-width or accented letters never match.',
    input: { pattern: vc.FILLER.source, flags: 'i', words: more }, expected: { matches: more.map(x => vc.isFillerText(x)) } })
}

// ---------- transcript alignment ----------
const spoken = [{ word: 'hello', start: 0, end: 0.3 }, { word: 'um', start: 0.3, end: 0.5 }, { word: 'world', start: 0.5, end: 1 }]
for (const [id, words, finalText, description] of [
  ['align/deletion-keeps-originals', spoken, 'Hello world!', 'Token count differs: keep provider word texts, never shift timings.'],
  ['align/punctuation-applied', spoken, 'Hello, um, world!', 'Same words after normalisation: take punctuation/capitalisation from the final text.'],
  ['align/replacement-keeps-originals', spoken, 'Hello brave world!', 'Different word at same count: keep originals.'],
  ['align/unicode-normalise', [{ word: 'Ära', start: 0, end: 0.4 }, { word: '100', start: 0.5, end: 0.9 }], '“ära” 100%.', 'Normalisation: locale lower-case, drop everything that is not a Unicode letter or number.'],
  ['align/drops-invalid', [{ word: 'ok', start: 0, end: 0.2 }, { word: ' ', start: 0.2, end: 0.3 }, { word: 'neg', start: -0.1, end: 0.1 }, { word: 'zero', start: 0.5, end: 0.5 }, { word: 'fine', start: 0.6, end: 0.9 }], 'ok fine', 'Blank text, negative start, or end <= start are dropped after alignment (count differs here, so originals are kept).'],
  ['align/dotted-capital-i', [{ word: 'İstanbul', start: 0, end: 0.6 }, { word: 'ŠOKOLAAD', start: 0.7, end: 1.2 }, { word: 'Õun', start: 1.3, end: 1.6 }], 'istanbul, šokolaad õun.', 'Lower-casing for matching: U+0130 must compare equal to "i" (JS gives i + U+0307, and U+0307 is stripped as a non-letter); Estonian letters keep their diacritics.'],
  ['align/whitespace-tokens', [{ word: 'one', start: 0, end: 0.3 }, { word: 'two', start: 0.4, end: 0.7 }, { word: 'three', start: 0.8, end: 1.1 }], ' One, two　three!\n', 'Final text is trimmed and split on the JS whitespace set (no-break space, em space and ideographic space included).'],
]) add({ id, kind: 'transcript-alignment', origin: 'voxconvo', source: 'vox-web/src/utils/transcriptionTiming.ts:11', description, input: { words, finalText }, expected: { words: alignTranscriptWords(words, finalText) } })

// ---------- estimated words ----------
for (const [id, text, start, end] of [['estimate/fast-speech', 'one two three four five', 0.5, 0.7], ['estimate/char-weighted', 'a bb cccc', 10, 17], ['estimate/empty', '   ', 0, 1], ['estimate/backwards', 'x y', 2, 1]]) {
  add({ id, kind: 'estimated-words', origin: 'voxconvo', source: 'vox-web/src/utils/transcriptionTiming.ts:20', description: 'Fallback when a provider returns no word times: split the segment by character count (UTF-16 length), conf 0.', input: { text, start, end }, expected: { words: estimateTranscriptWords(text, start, end) } })
}
add({ id: 'estimate/utf16-length', kind: 'estimated-words', origin: 'voxconvo', source: 'vox-web/src/utils/transcriptionTiming.ts:20',
  description: 'Lengths are UTF-16 code units: the emoji counts 2, "õun" (NFC) counts 3. Counting grapheme clusters or scalars gives different times.',
  input: { text: 'ok \u{1F600} õun', start: 0, end: 7 }, expected: { words: estimateTranscriptWords('ok \u{1F600} õun', 0, 7) } })

// ---------- clip range ----------
{
  const cw = [{ word: 'zero', start: 0.05, end: 0.4 }, { word: 'one', start: 1.0, end: 1.4 }, { word: 'two', start: 1.5, end: 1.9 }, { word: 'three', start: 3.0, end: 3.5 }, { word: 'four', start: 3.52, end: 3.9 }]
  const ranges = [[0, 0], [1, 2], [1, 3], [3, 4], [2, 2]]
  add({ id: 'clip-range/lead-and-tail', kind: 'clip-range', origin: 'voxconvo', source: 'vox-web/src/utils/clips.ts:32', description: 'Clip source range: up to 0.12 s before the first word and 0.25 s after the last, never more than half the gap to a neighbour; start clamped at 0, end not clamped.',
    input: { words: cw, ranges }, expected: { ranges: ranges.map(([a, b]) => ({ startWord: a, endWord: b, ...clipTimes(cw, a, b) })) } })
  const ow = [{ word: 'a', start: 0, end: 0.5 }, { word: 'b', start: 0.4, end: 1.0 }, { word: 'c', start: 1.0, end: 1.5 }, { word: 'd', start: 2.0, end: 2.6 }]
  const oranges = [[0, 0], [1, 1], [2, 2], [3, 3], [1, 2], [0, 3]]
  add({ id: 'clip-range/overlaps-and-edges', kind: 'clip-range', origin: 'voxconvo', source: 'vox-web/src/utils/clips.ts:32', description: 'Overlapping or touching neighbours give zero padding on that side; a clip at time 0 starts at 0; the last word always gets the full 0.25 s.',
    input: { words: ow, ranges: oranges }, expected: { ranges: oranges.map(([a, b]) => ({ startWord: a, endWord: b, ...clipTimes(ow, a, b) })) } })
}

// ---------- edit sessions ----------
const take = [
  { id: 'w0', text: 'So', start: 0.3, end: 0.6 },
  { id: 'w1', text: 'um,', start: 0.7, end: 1.0 },
  { id: 'w2', text: 'today', start: 1.1, end: 1.5 },
  { id: 'w3', text: 'we', start: 2.6, end: 2.75 },
  { id: 'w4', text: 'ship', start: 2.8, end: 3.1 },
  { id: 'w5', text: 'uh', start: 3.2, end: 3.4 },
  { id: 'w6', text: 'the', start: 3.5, end: 3.6 },
  { id: 'w7', text: 'clipper.', start: 3.65, end: 4.2 },
  { id: 'w8', text: 'Thanks', start: 5.5, end: 5.9 }
]
const sessionInput = ops => ({ durationSeconds: 7, sampleRate: 1000, hasDecodedAudio: true, words: take.map(x => ({ ...x })), ops })
{
  const ops = [{ op: 'cutFillers' }, { op: 'tightenPauses' }, { op: 'toggle', id: 'pause-after-w7' }, { op: 'correct', id: 'w4', text: ' shipped ' }, { op: 'toggle', id: 'w6' }, { op: 'restoreCuts' }]
  const steps = vc.voxclipSession(sessionInput(ops))
  assert(isDeepStrictEqual(steps, vc.voxconvoSession(sessionInput(ops))), 'without a clip, VoxClip and VoxConvo sessions must agree')
  add({ id: 'session/fillers-pauses-restore', kind: 'edit-session', origin: 'voxconvo-reimplemented', source: 'vox-web/src/components/VoiceRecorder/VoiceRecorder.tsx:1027-1088 (re-implemented)', description: 'Cut fillers, tighten pauses, restore one pause, correct a word, then Restore cuts: corrections survive, cuts do not.',
    input: sessionInput(ops), expected: { steps } })
}
{
  const ops = [{ op: 'toggle', id: 'w0' }, { op: 'previewClip', clip: [2, 7] }, { op: 'toggle', id: 'w5' }, { op: 'restoreCuts' }, { op: 'correct', id: 'w2', text: 'Today' }, { op: 'previewClip', clip: null }]
  const steps = vc.voxclipSession(sessionInput(ops))
  const voxconvoSteps = vc.voxconvoSession(sessionInput(ops))
  steps.slice(0, -1).forEach((s, i) => assert(isDeepStrictEqual([s.durationSeconds, s.captions], [voxconvoSteps[i].durationSeconds, voxconvoSteps[i].captions]), 'clip plans must match VoxConvo until the clip is left'))
  add({ id: 'session/clip-preview', kind: 'edit-session', origin: 'voxclip', source: 'doc/spec/editing.md (clip range layer); VoxConvo behaviour: VoiceRecorder.tsx:610-627,1077-1084',
    description: 'Previewing a clip adds head/tail ranges and treats words outside it as cut when planning, without touching the stored cut set. Counts and Restore cuts are scoped to the clip. Leaving the clip keeps every edit made during the preview (here the correction "Today").',
    notes: 'Deliberately changed from the VoxConvo expectation, which is kept under informative.voxconvoSteps. VoxConvo rewrites cut flags while a clip is previewed and restores a snapshot when it ends, so its cutWords include the outside words, its counts cover the whole take, and its final step loses the correction. Plans (durationSeconds, captions) are identical to VoxConvo until the clip is left.',
    input: sessionInput(ops), expected: { steps }, informative: { voxconvoSteps } })
}
{
  const ops = [
    { op: 'tightenPauses' },
    { op: 'previewClip', clip: [2, 7] },
    { op: 'cutFillers' },
    { op: 'correct', id: 'w4', text: 'shipped' },
    { op: 'cutSelection', ids: ['w6', 'w7'] },
    { op: 'cutSelection', ids: ['w6', 'w7'] },
    { op: 'cutSelection', ids: ['w5', 'w6'] },
    { op: 'previewClip', clip: [3, 7] },
    { op: 'restoreCuts' },
    { op: 'previewClip', clip: null },
    { op: 'correct', id: 'w4', text: 'ship' },
    { op: 'restoreCuts' }
  ]
  add({ id: 'session/clip-range-layer', kind: 'edit-session', origin: 'voxclip', source: 'doc/spec/editing.md (session operations, clip scope)',
    description: 'Range-layer semantics end to end: bulk operations act on the clip scope only, a selection toggles as a group, nudging the clip keeps edits, a pause cut outside the clip still shortens its edge, and correcting a word back to its original text removes the correction.',
    input: sessionInput(ops), expected: { steps: vc.voxclipSession(sessionInput(ops)) } })
}

// ---------- word boundaries (synthetic audio) ----------
for (const [id, seconds, sections, words, description] of [
  ['boundaries/soft-start-fading-end', 4, [[1.0, 1.2, 'hiss'], [1.2, 1.6, 'vowel'], [1.6, 1.75, 'hiss'], [2.5, 2.9, 'vowel']], [['so', 1.2, 1.6], ['then', 2.5, 2.9]], 'A soft start and fading end move out to where the sound is.'],
  ['boundaries/half-gap-limit', 4, [[1.0, 1.4, 'vowel'], [1.5, 1.8, 'hiss'], [1.8, 2.2, 'vowel']], [['a', 1.0, 1.4], ['b', 1.8, 2.2]], 'A word may only claim its half of the gap.'],
  ['boundaries/max-lead', 4, [[0.5, 1.5, 'hiss'], [1.5, 1.9, 'vowel']], [['c', 1.5, 1.9]], 'A start moves at most 0.35 s.'],
  ['boundaries/silence-unchanged', 3, [[0.5, 0.9, 'vowel'], [1.5, 1.9, 'vowel']], [['one', 0.5, 0.9], ['two', 1.5, 1.9]], 'Words already at their sound edges keep their timestamps.'],
  ['boundaries/all-silent', 3, [], [['one', 0.5, 0.9], ['two', 1.5, 1.9]], 'No speech above the room level: unchanged.'],
  ['boundaries/too-short', 0, [], [['one', 0.5, 0.9], ['two', 1.5, 1.9]], 'Fewer than 10 frames of audio: unchanged.'],
  ['boundaries/valley-join', 3, [[1.0, 1.43, 'vowel'], [1.46, 1.9, 'vowel']], [['in', 1.0, 1.4], ['there', 1.4, 1.9]], 'Touching words share an edge at the quietest frame between them.'],
  ['boundaries/no-valley', 3, [[1.0, 1.9, 'vowel']], [['in', 1.0, 1.4], ['there', 1.4, 1.9]], 'Inside one continuous sound the shared edge stays.'],
]) {
  const audio = makeTake(seconds, sections)
  const input = words.map(([word, start, end]) => ({ id: word, word, start, end }))
  add({ id, kind: 'word-boundaries', origin: 'voxconvo', source: 'vox-web/test/word-boundaries.test.mjs', description,
    input: { audio: takeInput(seconds, sections), words: input },
    expected: { words: refineWordBoundaries(input, audio).map(x => ({ id: x.id, start: x.start, end: x.end })), tolerance: 1e-6 } })
}

// ---------- VoxClip import post-processing ----------
for (const [id, timingSource, seconds, sections, words, description] of [
  ['tighten/leading-absorbed', 'runGrouped', 5, [[0.4, 0.8, 'vowel'], [1.3, 1.6, 'vowel'], [2.0, 2.4, 'vowel'], [3.6, 4.2, 'vowel']], [['so', 0.3, 0.8], ['today', 0.8, 2.4], ['ship', 2.4, 4.2]],
    'Apple-style gapless ranges absorb the silence before a word. The word keeps its last sound island (an untranscribed sound at 1.3-1.6 is left in the gap) and leading silence is trimmed.'],
  ['tighten/trailing-absorbed', 'dtw', 5, [[0.4, 0.8, 'vowel'], [1.3, 1.6, 'vowel'], [2.0, 2.4, 'vowel']], [['so', 0.4, 2.0], ['today', 2.0, 2.9]],
    'Whisper-style ranges end at the next word\'s start, absorbing the silence after a word. The word keeps its first sound island and trailing silence is trimmed.'],
  ['tighten/short-sound-floor', 'runGrouped', 3, [[1.5, 1.52, 'vowel']], [['blip', 1.0, 2.0]],
    'A range that contains only a very short sound keeps at least MIN_WORD (0.04 s).'],
  ['tighten/small-edges-kept', 'runGrouped', 3, [[1.04, 1.5, 'vowel'], [1.56, 1.95, 'vowel']], [['word', 1.0, 2.0]],
    'Fewer than 7 silent frames at an edge, and an inner dip shorter than 15 frames, change nothing.'],
]) {
  const audio = makeTake(seconds, sections)
  const input = words.map(([wid, start, end]) => ({ id: wid, start, end }))
  add({ id, kind: 'word-tightening', origin: 'voxclip', source: 'doc/spec/editing.md (tightenIntoSound)', description,
    input: { audio: takeInput(seconds, sections), timing: timingSource, words: input },
    expected: { words: vc.tightenIntoSound(input, audio, timingSource).map(x => ({ id: x.id, start: x.start, end: x.end })), tolerance: 1e-6 } })
}
for (const [id, seconds, sections, words, description] of [
  ['gaps/dropped-filler', 4, [[0.5, 0.9, 'vowel'], [1.3, 1.6, 'vowel'], [2.2, 2.8, 'vowel']], [['so', 0.5, 0.9], ['today', 2.2, 2.8]],
    'A voiced sound in a gap between words (a filler the engine dropped) becomes an unlabeledSpeech item covering the sound\'s frames.'],
  ['gaps/breath-and-blip-ignored', 4, [[0.1, 0.3, 'vowel'], [0.5, 0.9, 'vowel'], [1.3, 1.6, 'hiss'], [1.9, 1.95, 'vowel'], [2.2, 2.8, 'vowel'], [3.5, 3.8, 'vowel']], [['so', 0.5, 0.9], ['today', 2.2, 2.8]],
    'Leading and trailing gaps are searched too. A hiss (breath) is audible but below the peak factor, and a 5-frame blip is shorter than 10 frames, so neither is reported.'],
]) {
  const audio = makeTake(seconds, sections)
  const input = words.map(([wid, start, end]) => ({ id: wid, start, end }))
  add({ id, kind: 'unlabeled-speech', origin: 'voxclip', source: 'doc/spec/editing.md (findUnlabeledSpeech)', description,
    input: { audio: takeInput(seconds, sections), words: input },
    expected: { items: vc.findUnlabeledSpeech(input, audio), tolerance: 1e-6 } })
}
{
  const raw = [
    { text: ' ¿', start: 0.1, end: 0.1 },
    { text: 'Qué', start: 0.2, end: 0.5, conf: 0.93 },
    { text: '?', start: 0.5, end: 0.5 },
    { text: '(laughs)', start: 0.6, end: 1.1, kind: 'event' },
    { text: ',', start: 1.1, end: 1.1 },
    { text: 'café', start: 1.2, end: 1.6, conf: 1.2 },
    { text: '   ', start: 1.6, end: 1.7 },
    { text: 'bad', start: 2.0, end: 1.9 },
    { text: 'neg', start: -0.2, end: 0.1 },
    { text: 'late', start: 3.0, end: 3.4, speaker: 'speaker_1' },
    { text: 'early', start: 2.5, end: 2.9, conf: 0.5 },
    { text: 'tie', start: 2.5, end: 2.6 },
    { text: '“', start: 3.5, end: 3.5 },
    { text: 'quoted”.', start: 3.6, end: 4.0 },
    { text: 'nan', start: 'NaN', end: 4.5 },
    { text: '»', start: 4.6, end: 4.6 }
  ]
  add({ id: 'ingest/clean-words', kind: 'word-cleanup', origin: 'voxclip', source: 'doc/spec/editing.md (cleanWords)',
    description: 'Engine words to clean items: NFC, JS-whitespace trim, opening punctuation joins the next word, other punctuation-only tokens join the previous item only if it is a word, invalid times are dropped, conf outside [0,1] becomes null, and the result is stably sorted by start.',
    input: { rawWords: raw }, expected: { words: vc.cleanWords(raw.map(x => ({ ...x, start: fromJson(x.start), end: fromJson(x.end) }))) } })
}
{
  const sections = [[0.4, 0.8, 'vowel'], [1.3, 1.6, 'vowel'], [2.0, 2.4, 'vowel'], [2.45, 2.7, 'vowel'], [3.6, 4.2, 'vowel']]
  const rawWords = [
    { text: 'So', start: 0.3, end: 0.8, conf: 0.9 }, { text: ',', start: 0.8, end: 0.8 },
    { text: 'today', start: 0.8, end: 2.4, conf: 0.8 }, { text: 'we', start: 2.4, end: 2.7, conf: 0.95 },
    { text: 'ship', start: 2.7, end: 4.2, conf: 0.7 }, { text: '.', start: 4.2, end: 4.2 }
  ]
  add({ id: 'pipeline/gapless-non-verbatim', kind: 'import-pipeline', origin: 'voxclip', source: 'doc/spec/editing.md (import pipeline)',
    description: 'Apple-style run-grouped words with decoded audio: clean, tighten into sound, refine, find the dropped filler, assign ids, detect pauses at 0.8 s.',
    input: { audio: takeInput(5, sections), timing: 'runGrouped', verbatim: false, rawWords },
    expected: { ...vc.importPipeline({ rawWords, audio: makeTake(5, sections), timing: 'runGrouped', verbatim: false }), tolerance: 1e-6 } })
  const scribe = [
    { text: 'Tere', start: 0.12, end: 0.48, conf: 0.99 }, { text: 'tulemast!', start: 0.52, end: 1.1, conf: 0.97 },
    { text: '(naerab)', start: 1.2, end: 2.0, kind: 'event' }, { text: 'Ee,', start: 3.4, end: 3.6, conf: 0.6 },
    { text: 'alustame.', start: 3.7, end: 4.3, conf: 0.98 }
  ]
  add({ id: 'pipeline/native-verbatim-no-audio', kind: 'import-pipeline', origin: 'voxclip', source: 'doc/spec/editing.md (import pipeline)',
    description: 'ElevenLabs-style native word times without decoded audio: no tightening, refinement or gap search; the event stays an item; pauses use the 1.0 s threshold.',
    input: { audio: null, timing: 'native', verbatim: true, rawWords: scribe },
    expected: { ...vc.importPipeline({ rawWords: scribe, audio: null, timing: 'native', verbatim: true }), tolerance: 1e-6 } })
}

// ---------- join fades (audioEditor.ts) ----------
async function fades({ id, description, duration, sampleRate, segments }) {
  const refSegs = vc.toReferenceSegments(segments)
  const built = buildMediaEditPlan(refSegs, duration, sampleRate)
  const total = built.totalSamples
  assert(total === duration * sampleRate && built.outputSamples > 0, id + ' needs integer samples and kept media')
  const buffer = new StubAudioBuffer(1, total, sampleRate)
  buffer.channels[0].fill(1)
  const out = (await audioEditor.removeWordSegments(buffer, refSegs)).buffer.getChannelData(0)
  const fadeLength = Math.round(0.005 * sampleRate)
  let offset = 0
  const parts = built.kept.map(k => {
    const length = k.endSample - k.startSample
    const fade = Math.min(fadeLength, Math.floor(length / 2))
    const part = { outputStart: offset, length, fadeIn: k.startSample > 0 ? fade : 0, fadeOut: k.endSample < total ? fade : 0 }
    offset += length
    return part
  })
  const specGain = s => {
    const part = parts.find(q => s >= q.outputStart && s < q.outputStart + q.length)
    const i = s - part.outputStart, j = part.length - 1 - i
    let g = 1
    if (i < part.fadeIn) g *= i / part.fadeIn
    if (j < part.fadeOut) g *= j / part.fadeOut
    return Math.fround(g)
  }
  for (let s = 0; s < out.length; s++) assert(specGain(s) === out[s], `${id}: fade gain at ${s}`)
  const nonUnity = []
  for (let s = 0; s < out.length; s++) if (out[s] !== 1) nonUnity.push(s)
  let probe = nonUnity
  if (nonUnity.length > 64) {
    const picks = new Set()
    for (const q of parts) {
      if (q.fadeIn) for (const i of [0, 1, q.fadeIn >> 1, q.fadeIn - 1, q.fadeIn]) picks.add(q.outputStart + i)
      if (q.fadeOut) for (const j of [0, 1, q.fadeOut >> 1, q.fadeOut - 1, q.fadeOut]) picks.add(q.outputStart + q.length - 1 - j)
    }
    probe = [...picks].sort((a, b) => a - b)
  }
  add({ id, kind: 'join-fades', origin: 'voxconvo', source: 'vox-web/src/utils/audioEditor.ts:19-29 (run on a constant 1.0 buffer)', description,
    input: { durationSeconds: duration, sampleRate, segments },
    expected: { kept: built.kept.map(k => [k.startSample, k.endSample]), outputSamples: built.outputSamples, parts, gains: probe.map(s => [s, out[s]]), tolerance: 1e-7 } })
}
await fades({ id: 'fades/one-cut-1k', duration: 3, sampleRate: 1000, description: 'One cut: the part before it fades out, the part after it fades in, and the file start and end are never faded. 5 samples at 1 kHz.',
  segments: [w('a', 0.5, 1.0), w('b', 1.2, 1.5, true), w('c', 2.0, 2.5)] })
await fades({ id: 'fades/short-parts-1k', duration: 2, sampleRate: 1000, description: 'Parts shorter than two fades get floor(length/2) samples per side; a 1-sample part gets none.',
  segments: [w('x', 1.2, 1.5), r('r1', 0.1, 0.5), r('r2', 0.503, 0.8), r('r3', 0.801, 1.0)] })
await fades({ id: 'fades/clip-edges-48k', duration: 4, sampleRate: 48000, description: 'A clip export fades in at its first sample and out at its last, because its kept parts start after 0 and end before the source end. 240 samples at 48 kHz.',
  segments: [w('before', 0.2, 0.6, true), w('clip', 1.0, 1.4), w('um', 1.5, 1.6, true), w('words', 1.7, 2.1), w('after', 2.6, 3.0, true), r('clip-head', 0, 0.88), r('clip-tail', 2.35, 3603)] })
await fades({ id: 'fades/no-cuts', duration: 1, sampleRate: 1000, description: 'No cuts: one part covering the whole file, no fades.', segments: [w('a', 0.2, 0.8)] })

// ---------- text primitives ----------
{
  const strings = [' a ', ' a ', ' a　', '﻿a', 'a\u0085', 'a᠎', 'a​', '\t\n\u000b\f\ra\r\n', ' a ', 'one  two three four five', ' x y z', '', '   ', 'no-change']
  add({ id: 'text/js-whitespace', kind: 'text-whitespace', origin: 'voxconvo', source: 'JS String.prototype.trim and split(/\\s+/) as used by transcriptionTiming.ts and WordChip.tsx',
    description: 'The whitespace set for trim and token splitting is JavaScript\'s: U+0085 (NEL), U+180E and U+200B are not whitespace; U+FEFF is. Platform trim functions disagree, so implement the set explicitly.',
    input: { strings }, expected: { trim: strings.map(vc.jsTrim), split: strings.map(vc.splitWords) } })
}

// ---------- caption text transform (server burner) ----------
{
  const capIn = ['Hello,', "don't", '100%', '03:15', '"Quote"', 'Wait...', '—', 'naïve', 'straße', '¿Qué?']
  add({ id: 'caption-text/punctuation-uppercase', kind: 'caption-text', origin: 'voxconvo-reimplemented', source: 'vox-api/src/services/videoSubtitleService.ts:193-207', description: 'Server caption transform: removePunctuation strips [.,!?;:\'"] then trims; uppercase uses JS toUpperCase (full Unicode, ß -> SS). Words that become empty are dropped from captions.',
    notes: 'Informative. Documents the VoxConvo burner and the ß trap. VoxClip\'s caption text transform is owned by the captions spec; editing test suites skip this kind.',
    input: { words: capIn },
    expected: {
      removePunctuation: capIn.map(x => x.replace(/[.,!?;:'"]/g, '').trim()),
      uppercase: capIn.map(x => x.toUpperCase()),
      both: capIn.map(x => x.replace(/[.,!?;:'"]/g, '').trim().toUpperCase())
    } })
}

// ---------- source media hash (spec 10.3) ----------
{
  const MiB = 1048576
  const contentKey = size => {
    const bytes = Buffer.alloc(size)
    for (let i = 0; i < size; i++) bytes[i] = (i * 31 + 7) % 251
    const h = createHash('sha256').update(Buffer.from(`voxclip-source-v1\n${size}\n`, 'utf8'))
    if (size < 2 * MiB) h.update(bytes)
    else h.update(bytes.subarray(0, MiB)).update(bytes.subarray(size - MiB))
    return h.digest('hex')
  }
  const sizes = [0, 1, 1000000, 2 * MiB - 1, 2 * MiB, 3000000]
  add({ id: 'media/content-key', kind: 'content-key', origin: 'voxclip', source: 'doc/spec/editing.md (contentKey); doc/architecture.md section 8.1',
    description: 'contentKey of synthetic files whose byte i is (i * 31 + 7) mod 251. Files smaller than 2 MiB are hashed whole; from 2 MiB on, only the first and last MiB are hashed.',
    input: { bytes: 'byte[i] = (i * 31 + 7) mod 251', sizes }, expected: { contentKeys: sizes.map(contentKey) } })
}

// ---------- example projects (shared/fixtures/projects) ----------
for (const name of ['interview-take', 'clip-from-long-take']) {
  const rel = `shared/fixtures/projects/${name}.voxclip`
  const project = JSON.parse(readFileSync(new URL(rel, ROOT), 'utf8'))
  add({ id: `projects/${name}`, kind: 'project-plan', origin: 'voxclip', source: rel,
    description: `Load ${rel}, rebuild the edit state, and plan the full take and every stored clip.`,
    input: { projectPath: rel }, expected: await vc.projectPlans(project, timelineWith) })
}

// ---------- self-checks ----------
{
  let seed = 99
  const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647
  for (let i = 0; i < 200000; i++) {
    const x = i < 100000 ? Math.round(rnd() * 1e6) / 1e3 - Math.round(rnd() * 1e5) / 1e3 : rnd() * 10 ** Math.floor(rnd() * 8)
    if (x >= 0) assert(vc.toFixed1Exact(x) === x.toFixed(1), `toFixed1Exact(${x})`)
  }
  for (const x of [0, 0.05, 0.15, 0.25, 0.35, 0.45, 1.25, 2.25, 0.95, 1e20, 5e-324]) assert(vc.toFixed1Exact(x) === x.toFixed(1), `toFixed1Exact(${x})`)
}
{
  // EditPlan invariants (spec 7.5) on random plans: inverse mapping, monotonic mapTime, a kept sample between cuts.
  let seed = 12345
  const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647
  for (let trial = 0; trial < 300; trial++) {
    const rate = [1000, 16000, 44100, 48000][trial % 4]
    const words = []; let t = rnd() * 0.5
    for (let i = 0; i < 30; i++) { const len = 0.05 + rnd() * 0.5; words.push({ id: 'w' + i, word: 'x', start: t, end: t + len, isStrikethrough: rnd() < 0.3 }); t += len + rnd() * 1.5 }
    for (let i = 0; i < 29; i++) { const gap = words[i + 1].start - words[i].end; if (gap >= 0.8 && rnd() < 0.5) words.push({ id: 'pause-after-w' + i, word: '', start: words[i].end, end: words[i + 1].start, isPause: true, isStrikethrough: true }) }
    const duration = t + rnd()
    const built = buildMediaEditPlan(words.sort((a, b) => a.start - b.start), duration, rate)
    for (let k = 1; k < built.cuts.length; k++) assert(built.cuts[k].startSample > built.cuts[k - 1].endSample, 'cuts separated by a kept sample')
    let prev = -1
    for (let i = 0; i < 200; i++) {
      const e = Math.floor(rnd() * built.outputSamples) / rate
      assert(built.mapTime(built.sourceTime(e)) === e, 'mapTime(sourceTime(e)) == e')
      const s = rnd() * duration, sample = Math.round(s * rate)
      if (!built.cuts.some(c => sample >= c.startSample && sample < c.endSample)) assert(Math.abs(built.sourceTime(built.mapTime(s)) - sample / rate) <= 1e-12, 'sourceTime(mapTime(s)) == round(s)')
    }
    for (let i = 0; i <= 500; i++) { const m = built.mapTime(duration * i / 500); assert(m >= prev, 'mapTime non-decreasing'); prev = m }
  }
}

// ---------- write or check ----------
fixtures.sort((a, b) => a.id < b.id ? -1 : 1)
const expectedFiles = new Map(fixtures.map(f => [`${f.id}.json`, formatJson(f)]))
const existing = []
if (existsSync(OUT)) for (const group of readdirSync(OUT, { withFileTypes: true })) {
  if (!group.isDirectory()) continue
  for (const file of readdirSync(new URL(group.name + '/', OUT))) if (file.endsWith('.json')) existing.push(`${group.name}/${file}`)
}
if (CHECK) {
  const problems = []
  for (const [file, text] of expectedFiles) {
    const url = new URL(file, OUT)
    if (!existsSync(url)) problems.push(`missing ${file}`)
    else if (readFileSync(url, 'utf8') !== text) problems.push(`differs ${file}`)
  }
  for (const file of existing) if (!expectedFiles.has(file)) problems.push(`stale ${file}`)
  if (problems.length) { console.error(problems.join('\n')); console.error(`${problems.length} fixture file(s) out of date; run npm run generate and review the diff`); process.exit(1) }
  console.log(`ok: ${fixtures.length} fixtures match`)
} else {
  for (const file of existing) if (!expectedFiles.has(file)) rmSync(new URL(file, OUT))
  for (const [file, text] of expectedFiles) {
    const url = new URL(file, OUT)
    mkdirSync(new URL('./', url), { recursive: true })
    writeFileSync(url, text)
  }
  console.log(`wrote ${fixtures.length} fixtures to shared/fixtures/editing`)
}
