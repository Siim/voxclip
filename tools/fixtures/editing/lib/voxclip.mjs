// VoxClip-defined editing algorithms, written in JavaScript so the generator can produce
// expectations for them. Normative text: doc/spec/editing.md. Everything here either calls the
// vendored VoxConvo reference (./reference.mjs) or implements a rule the spec defines.
import { timeline, clips, boundaries } from './reference.mjs'

const { buildMediaEditPlan, mapWordsToEditedTimeline } = timeline // VoxConvo session only; VoxClip paths take a module
const { clipTimes } = clips
export const { refineWordBoundaries } = boundaries

// ---------- constants (spec section "Constants") ----------
export const PAUSE_THRESHOLD_REFINED = 0.8
export const PAUSE_THRESHOLD_UNREFINED = 1.0
export const FRAME_SECONDS = 0.01
export const MIN_WORD = 0.04
export const BRIDGE_FRAMES = 2
export const TIGHTEN_MIN_SILENT_FRAMES = 7
export const TIGHTEN_SPLIT_FRAMES = 15
export const UNLABELED_MIN_GAP = 0.25
export const UNLABELED_MIN_FRAMES = 10
export const UNLABELED_PEAK_FACTOR = 0.25
export const UNLABELED_TEXT = '…'
export const GAPLESS_TIMING = new Set(['runGrouped', 'tokenGrouped', 'dtw'])

// ---------- text primitives ----------
export const jsTrim = s => s.trim()
export const splitWords = s => s.trim().split(/\s+/).filter(Boolean)
export const FILLER = /^(um+|uh+|erm+|hmm+)[,.!?]?$/i
export const isFillerText = text => FILLER.test(text)
export const isFiller = (item, text) => item.kind === 'unlabeledSpeech' || ((item.kind ?? 'word') === 'word' && isFillerText(text))

/** JS Number.prototype.toFixed(1) re-derived exactly with integers (spec: toFixed1). */
export function toFixed1Exact(x) {
  if (!(x >= 0) || !Number.isFinite(x)) throw new Error('toFixed1Exact domain')
  const view = new DataView(new ArrayBuffer(8)); view.setFloat64(0, x)
  const bits = view.getBigUint64(0)
  const exp = Number((bits >> 52n) & 0x7ffn), frac = bits & ((1n << 52n) - 1n)
  const m = exp === 0 ? frac : frac | (1n << 52n)
  const e = (exp === 0 ? 1 : exp) - 1075
  let n
  if (e >= 0) n = m * 10n * (1n << BigInt(e))
  else { const k = BigInt(-e); n = (m * 10n + (1n << (k - 1n))) >> k }
  return `${n / 10n}.${n % 10n}`
}

export const pauseLabel = duration => `pause ${duration.toFixed(1)}s`

// ---------- pauses (VoiceRecorder.tsx:784-802) ----------
export function detectPauses(items, threshold) {
  const out = []
  for (let i = 0; i < items.length - 1; i++) {
    const gap = items[i + 1].start - items[i].end
    if (gap >= threshold) out.push({ id: `pause-after-${items[i].id}`, start: items[i].end, end: items[i + 1].start, duration: gap, label: pauseLabel(gap) })
  }
  return out
}

// ---------- audio analysis shared by tighten, refine and unlabeled-speech detection ----------
// Mirrors wordBoundaries.ts:28-50 exactly (Float32 levels, double threshold).
export function analyze(words, audio) {
  const frameSize = Math.max(1, Math.round(audio.sampleRate * FRAME_SECONDS))
  const frameLength = frameSize / audio.sampleRate
  const frames = Math.floor(audio.length / frameSize)
  if (!words.length || frames < 10 || !audio.numberOfChannels) return null
  const channels = Array.from({ length: audio.numberOfChannels }, (_, c) => audio.getChannelData(c))
  const level = new Float32Array(frames)
  for (let frame = 0; frame < frames; frame++) {
    let sum = 0
    for (const data of channels) for (let i = frame * frameSize, end = i + frameSize; i < end; i++) sum += data[i] * data[i]
    level[frame] = Math.sqrt(sum / (frameSize * channels.length))
  }
  const frameAt = t => Math.min(frames - 1, Math.max(0, Math.floor(t / frameLength)))
  const quietest = Array.from(level).sort((a, b) => a - b)[Math.floor(frames * 0.1)]
  const speech = words.flatMap(w => Array.from(level.subarray(frameAt(w.start), frameAt(w.end) + 1))).sort((a, b) => a - b)
  const speechLevel = speech[Math.floor(speech.length / 2)] ?? 0
  const threshold = Math.max(quietest * 2, speechLevel * 0.08)
  if (!(threshold > 0)) return null
  return { frameSize, frameLength, frames, level, frameAt, speechLevel, threshold, audible: f => level[f] >= threshold, total: audio.length / audio.sampleRate }
}

/** Audible runs in frames [from, to]: a run continues across at most BRIDGE_FRAMES quiet frames. */
function audibleRuns(a, from, to) {
  const runs = []
  let f = from
  while (f <= to) {
    if (!a.audible(f)) { f++; continue }
    let last = f, quiet = 0
    for (let g = f + 1; g <= to; g++) {
      if (a.audible(g)) { last = g; quiet = 0 } else if (++quiet > BRIDGE_FRAMES) break
    }
    runs.push([f, last])
    f = last + 1
  }
  return runs
}

/**
 * Shrink gapless engine ranges to the sound inside them (spec: tightenIntoSound).
 * runGrouped ranges (Apple) absorb the silence before a word, so the word keeps its last sound
 * island; tokenGrouped/dtw ranges (whisper) absorb the silence after it, so it keeps its first.
 */
export function tightenIntoSound(words, audio, timingSource) {
  const keepLast = timingSource === 'runGrouped'
  const a = analyze(words, audio)
  if (!a) return words.slice()
  return words.map(w => {
    const first = a.frameAt(w.start)
    const last = Math.min(a.frames - 1, Math.max(0, Math.ceil(w.end / a.frameLength) - 1))
    if (first > last) return w
    const islands = []
    for (const run of audibleRuns(a, first, last)) {
      const prev = islands[islands.length - 1]
      if (prev && run[0] - prev[1] - 1 < TIGHTEN_SPLIT_FRAMES) prev[1] = run[1]
      else islands.push([...run])
    }
    if (!islands.length) return w
    const [fa, fb] = keepLast ? islands[islands.length - 1] : islands[0]
    let start = w.start, end = w.end
    if (fa - first >= TIGHTEN_MIN_SILENT_FRAMES) start = Math.max(w.start, fa * a.frameLength)
    if (last - fb >= TIGHTEN_MIN_SILENT_FRAMES) end = Math.min(w.end, (fb + 1) * a.frameLength)
    if (end - start < MIN_WORD) {
      start = Math.max(w.start, end - MIN_WORD)
      end = Math.min(w.end, start + MIN_WORD)
    }
    return start === w.start && end === w.end ? w : { ...w, start, end }
  })
}

/** Audible runs in the gaps of a non-verbatim transcript (spec: findUnlabeledSpeech). Items sorted by start. */
export function findUnlabeledSpeech(items, audio) {
  const a = analyze(items, audio)
  if (!a) return []
  const found = []
  let reached = 0
  for (let k = 0; k <= items.length; k++) {
    const gapStart = reached
    const gapEnd = k < items.length ? items[k].start : a.total
    if (k < items.length) reached = Math.max(reached, items[k].end)
    if (!(gapEnd - gapStart >= UNLABELED_MIN_GAP)) continue
    const f0 = Math.max(0, Math.ceil(gapStart / a.frameLength))
    const f1 = Math.min(a.frames - 1, Math.floor(gapEnd / a.frameLength) - 1)
    for (const [first, last] of audibleRuns(a, f0, f1)) {
      let peak = 0
      for (let g = first; g <= last; g++) if (a.level[g] > peak) peak = a.level[g]
      if (last - first + 1 >= UNLABELED_MIN_FRAMES && peak >= a.speechLevel * UNLABELED_PEAK_FACTOR) {
        found.push({ start: first * a.frameLength, end: (last + 1) * a.frameLength })
      }
    }
  }
  return found
}

// ---------- ingest (spec: cleanWords) ----------
const PUNCT_ONLY = /^\p{P}+$/u
const OPENING_ONLY = /^[\p{Ps}\p{Pi}¿¡]+$/u
const stableByStart = xs => xs.map((x, i) => [x, i]).sort((a, b) => a[0].start - b[0].start || a[1] - b[1]).map(([x]) => x)
export { stableByStart }

export function cleanWords(raw) {
  const out = []
  let prefix = ''
  for (const r of raw) {
    const kind = r.kind === 'event' ? 'event' : 'word'
    const text = String(r.text ?? '').normalize('NFC').trim()
    if (!text) continue
    if (kind === 'word' && PUNCT_ONLY.test(text)) {
      if (OPENING_ONLY.test(text)) prefix += text
      else if (out.length && out[out.length - 1].kind === 'word') out[out.length - 1].text += text
      continue
    }
    const { start, end } = r
    if (!(Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end > start)) continue
    const conf = Number.isFinite(r.conf) && r.conf >= 0 && r.conf <= 1 ? r.conf : null
    out.push({ text: kind === 'word' ? prefix + text : text, start, end, conf, kind, speaker: r.speaker ?? null })
    if (kind === 'word') prefix = ''
  }
  return stableByStart(out)
}

/** The whole import post-process (spec: import pipeline). audio may be null. */
export function importPipeline({ rawWords, audio, timing, verbatim }) {
  let words = cleanWords(rawWords).map(w => ({ ...w, rawStart: w.start, rawEnd: w.end, timing }))
  if (audio) {
    if (GAPLESS_TIMING.has(timing)) words = tightenIntoSound(words, audio, timing)
    words = refineWordBoundaries(words, audio)
    if (!verbatim) {
      const extra = findUnlabeledSpeech(words, audio).map(s => ({ text: UNLABELED_TEXT, start: s.start, end: s.end, conf: null, kind: 'unlabeledSpeech', speaker: null, rawStart: null, rawEnd: null, timing: 'detected' }))
      words = stableByStart([...words, ...extra])
    }
  }
  words = words.map((w, i) => ({ id: `w${i + 1}`, text: w.text, kind: w.kind, start: w.start, end: w.end, rawStart: w.rawStart, rawEnd: w.rawEnd, conf: w.conf, speaker: w.speaker, timing: w.timing }))
  const pauseThresholdSeconds = audio ? PAUSE_THRESHOLD_REFINED : PAUSE_THRESHOLD_UNREFINED
  return { words, pauseThresholdSeconds, pauses: detectPauses(words, pauseThresholdSeconds) }
}

// ---------- planning helpers ----------
/** Segments for the reference planner from VoxClip segments (kind-driven, never id-driven). */
export function toReferenceSegments(segments) {
  // The reference infers type from ids ("pause-", "clip-"). VoxClip carries kind explicitly, so ids
  // are rewritten here to make the reference see exactly the kind the segment declares.
  return segments.map(s => {
    const base = { start: s.start, end: s.end, conf: 1, voxclip: s }
    if (s.kind === 'word') return { ...base, id: /^(pause-|clip-)/.test(s.id) ? `word:${s.id}` : s.id, word: s.text ?? s.id, isStrikethrough: !!s.cut }
    if (s.kind === 'pause') return { ...base, id: s.id, word: '', isPause: true, isStrikethrough: !!s.cut }
    if (s.kind === 'range') return { ...base, id: s.id.startsWith('clip-') ? s.id : `clip-${s.id}`, word: '', isStrikethrough: true }
    throw new Error('segment kind ' + s.kind)
  })
}

export function captionsFor(refSegments, plan) {
  return mapWordsToEditedTimeline(refSegments.filter(s => s.voxclip.kind !== 'range' && (s.voxclip.wordKind ?? 'word') === 'word'), plan)
}

// ---------- edit session (spec: session operations) ----------
function summary({ items, texts, isCut, pauses, isPauseCut, inScope, pauseInScope }) {
  const scoped = items.filter((_, i) => inScope(i))
  const fillers = scoped.filter(x => !isCut(x.id) && isFiller(x, texts[x.id]))
  const removed = scoped.filter(x => isCut(x.id)).length
  const scopedPauses = pauses.filter(pauseInScope)
  const cutPauseCount = scopedPauses.filter(p => isPauseCut(p.id)).length
  return {
    cutFillersLabel: fillers.length ? `Cut fillers · ${fillers.length}` : 'Cut fillers',
    cutFillersEnabled: fillers.length > 0,
    tightenPausesEnabled: scopedPauses.length > 0 && cutPauseCount !== scopedPauses.length,
    restoreCutsVisible: removed > 0 || cutPauseCount > 0,
    status: removed > 0 || cutPauseCount > 0 ? `${removed} ${removed === 1 ? 'word' : 'words'} and ${cutPauseCount} ${cutPauseCount === 1 ? 'pause' : 'pauses'} cut. Preview before publishing.` : null,
    publishEnabled: !(scoped.length > 0 && scoped.every(x => isCut(x.id)))
  }
}

function sessionPlan({ items, texts, effectiveCut, pauses, cutPauses, activeClip, duration, sampleRate, mod = timeline }) {
  const segs = [
    ...items.map(x => ({ id: x.id, kind: 'word', wordKind: x.kind ?? 'word', text: texts[x.id], start: x.start, end: x.end, cut: effectiveCut(x) })),
    ...pauses.filter(p => cutPauses.has(p.id)).map(p => ({ id: p.id, kind: 'pause', start: p.start, end: p.end, cut: true }))
  ]
  if (activeClip) {
    const { start, end } = clipTimes(items.map(x => ({ word: texts[x.id], start: x.start, end: x.end })), activeClip[0], activeClip[1])
    segs.push({ id: 'clip-head', kind: 'range', start: 0, end: start, cut: true })
    segs.push({ id: 'clip-tail', kind: 'range', start: end, end: Math.max(end, items[items.length - 1].end) + 3600, cut: true })
  }
  const ordered = stableByStart(segs.filter(s => s.kind !== 'range' || s.end > s.start))
  const ref = toReferenceSegments(ordered)
  const plan = mod.buildMediaEditPlan(ref, duration, sampleRate)
  return { plan, captions: captionsFor(ref, plan).map(x => ({ id: x.voxclip.id, text: x.word, start: x.start, end: x.end })) }
}

// ---------- project files (spec: project file) ----------
/** Plans for the full take and for every stored clip of a .voxclip project. */
export async function projectPlans(project, timelineFor) {
  const words = project.transcript.words
  const index = new Map(words.map((x, i) => [x.id, i]))
  const e = project.edits
  const pauses = detectPauses(words, e.pauseThresholdSeconds)
  const pauseIds = new Set(pauses.map(p => p.id))
  const texts = Object.fromEntries(words.map(x => [x.id, e.corrections[x.id] ?? x.text]))
  const cutWords = new Set(e.cutWordIds.filter(id => index.has(id)))
  const cutPauses = new Set(e.cutPauseIds.filter(id => pauseIds.has(id)))
  const sampleRate = project.media.source.audio?.sampleRate ?? 48000
  const duration = project.media.source.durationSeconds
  const mod = e.pauseKeepSeconds === 0.15 ? timeline : await timelineFor({ pauseKeep: e.pauseKeepSeconds })
  const planFor = activeClip => {
    const inScope = i => !activeClip || (i >= activeClip[0] && i <= activeClip[1])
    const { plan, captions } = sessionPlan({ items: words, texts, effectiveCut: x => cutWords.has(x.id) || !inScope(index.get(x.id)), pauses, cutPauses, activeClip, duration, sampleRate, mod })
    return { outputSamples: plan.outputSamples, durationSeconds: plan.duration, kept: plan.kept.map(k => [k.startSample, k.endSample]), captions }
  }
  return {
    sampleRate,
    sourceDurationSeconds: duration,
    pauses: pauses.map(p => ({ id: p.id, start: p.start, end: p.end, label: p.label })),
    take: planFor(null),
    clips: e.clips.map(c => {
      const range = [index.get(c.startWordId), index.get(c.endWordId)]
      const source = clipTimes(words.map(x => ({ word: texts[x.id], start: x.start, end: x.end })), range[0], range[1])
      return { id: c.id, startWord: range[0], endWord: range[1], sourceStart: source.start, sourceEnd: source.end, ...planFor(range) }
    })
  }
}

/** VoxClip semantics: the clip is a range layer; cuts and corrections are never rewritten by it. */
export function voxclipSession({ words, durationSeconds, sampleRate, hasDecodedAudio, ops }) {
  const items = words.map(w => ({ kind: 'word', ...w }))
  const index = new Map(items.map((x, i) => [x.id, i]))
  const pauses = detectPauses(items, hasDecodedAudio ? PAUSE_THRESHOLD_REFINED : PAUSE_THRESHOLD_UNREFINED)
  const pauseIds = new Set(pauses.map(p => p.id))
  const pauseAfter = new Map(pauses.map(p => [p.id, index.get(p.id.slice('pause-after-'.length))]))
  let cutWords = new Set(), cutPauses = new Set(), corrections = new Map(), activeClip = null
  const textOf = id => corrections.get(id) ?? items[index.get(id)].text
  const inScope = i => !activeClip || (i >= activeClip[0] && i <= activeClip[1])
  const pauseInScope = p => inScope(pauseAfter.get(p.id)) && inScope(pauseAfter.get(p.id) + 1)
  const snapshot = after => {
    const texts = Object.fromEntries(items.map(x => [x.id, textOf(x.id)]))
    const { plan, captions } = sessionPlan({ items, texts, effectiveCut: x => cutWords.has(x.id) || !inScope(index.get(x.id)), pauses, cutPauses, activeClip, duration: durationSeconds, sampleRate })
    return {
      after,
      cutWords: items.filter(x => cutWords.has(x.id)).map(x => x.id),
      cutPauses: pauses.filter(p => cutPauses.has(p.id)).map(p => p.id),
      texts,
      activeClip: activeClip ? [...activeClip] : null,
      ui: summary({ items, texts, isCut: id => cutWords.has(id), pauses, isPauseCut: id => cutPauses.has(id), inScope, pauseInScope }),
      durationSeconds: plan.duration,
      captions: captions.map(({ text, start, end }) => ({ text, start, end }))
    }
  }
  const flip = (set, id) => { const next = new Set(set); next.has(id) ? next.delete(id) : next.add(id); return next }
  const steps = [snapshot({ op: 'initial' })]
  for (const op of ops) {
    if (op.op === 'toggle') {
      if (pauseIds.has(op.id)) cutPauses = flip(cutPauses, op.id)
      else if (index.has(op.id)) cutWords = flip(cutWords, op.id)
      else throw new Error('unknown id ' + op.id)
    } else if (op.op === 'cutSelection') {
      const all = op.ids.every(id => pauseIds.has(id) ? cutPauses.has(id) : cutWords.has(id))
      const words2 = new Set(cutWords), pauses2 = new Set(cutPauses)
      for (const id of op.ids) {
        const target = pauseIds.has(id) ? pauses2 : words2
        if (all) target.delete(id); else target.add(id)
      }
      cutWords = words2; cutPauses = pauses2
    } else if (op.op === 'cutFillers') {
      const next = new Set(cutWords)
      items.forEach((x, i) => { if (inScope(i) && !cutWords.has(x.id) && isFiller(x, textOf(x.id))) next.add(x.id) })
      cutWords = next
    } else if (op.op === 'tightenPauses') {
      cutPauses = new Set([...cutPauses, ...pauses.filter(pauseInScope).map(p => p.id)])
    } else if (op.op === 'restoreCuts') {
      cutWords = new Set([...cutWords].filter(id => !inScope(index.get(id))))
      cutPauses = new Set([...cutPauses].filter(id => !pauseInScope(pauses.find(p => p.id === id))))
    } else if (op.op === 'correct') {
      const t = op.text.normalize('NFC').trim(), i = index.get(op.id)
      if (t && i !== undefined && (items[i].kind ?? 'word') === 'word' && t !== textOf(op.id)) {
        corrections = new Map(corrections)
        if (t === items[i].text) corrections.delete(op.id); else corrections.set(op.id, t)
      }
    } else if (op.op === 'previewClip') {
      if (op.clip && !(op.clip[0] >= 0 && op.clip[0] <= op.clip[1] && op.clip[1] < items.length)) throw new Error('bad clip')
      activeClip = op.clip ? [op.clip[0], op.clip[1]] : null
    } else throw new Error(op.op)
    steps.push(snapshot(op))
  }
  return steps
}

/** VoxConvo semantics, re-implemented from VoiceRecorder.tsx (clip preview rewrites cut flags). */
export function voxconvoSession({ words: sourceWords, durationSeconds, sampleRate, hasDecodedAudio, ops }) {
  const pauses = detectPauses(sourceWords, hasDecodedAudio ? PAUSE_THRESHOLD_REFINED : PAUSE_THRESHOLD_UNREFINED)
  let words = sourceWords.map(x => ({ ...x, cut: false }))
  let cutPauses = new Set()
  let activeClip = null, clipBase = null
  const snapshot = after => {
    const segs = [
      ...words.map(x => ({ id: x.id, word: x.text, start: x.start, end: x.end, isStrikethrough: x.cut })),
      ...pauses.filter(p => cutPauses.has(p.id)).map(p => ({ id: p.id, word: '', start: p.start, end: p.end, isPause: true, isStrikethrough: true }))
    ]
    if (activeClip) {
      const { start, end } = clipTimes(sourceWords.map(x => ({ word: x.text, start: x.start, end: x.end })), activeClip[0], activeClip[1])
      segs.push({ id: 'clip-head', word: '', start: 0, end: start, isStrikethrough: true })
      segs.push({ id: 'clip-tail', word: '', start: end, end: Math.max(end, sourceWords[sourceWords.length - 1].end) + 3600, isStrikethrough: true })
    }
    const ordered = segs.filter(s => !s.id.startsWith('clip-') || s.end > s.start).sort((a, b) => a.start - b.start)
    const plan = buildMediaEditPlan(ordered, durationSeconds, sampleRate)
    const fillers = words.filter(x => !x.cut && isFillerText(x.text))
    const removed = words.filter(x => x.cut).length
    return {
      after,
      cutWords: words.filter(x => x.cut).map(x => x.id),
      cutPauses: pauses.filter(p => cutPauses.has(p.id)).map(p => p.id),
      texts: Object.fromEntries(words.map(x => [x.id, x.text])),
      activeClip: activeClip ? [...activeClip] : null,
      ui: {
        cutFillersLabel: fillers.length ? `Cut fillers · ${fillers.length}` : 'Cut fillers',
        cutFillersEnabled: fillers.length > 0,
        tightenPausesEnabled: pauses.length > 0 && cutPauses.size !== pauses.length,
        restoreCutsVisible: removed > 0 || cutPauses.size > 0,
        status: removed > 0 || cutPauses.size > 0 ? `${removed} ${removed === 1 ? 'word' : 'words'} and ${cutPauses.size} ${cutPauses.size === 1 ? 'pause' : 'pauses'} cut. Preview before publishing.` : null,
        publishEnabled: !(words.length > 0 && words.every(x => x.cut))
      },
      durationSeconds: plan.duration,
      captions: mapWordsToEditedTimeline(ordered, plan).map(x => ({ text: x.word, start: x.start, end: x.end }))
    }
  }
  const steps = [snapshot({ op: 'initial' })]
  for (const op of ops) {
    if (op.op === 'toggle') {
      if (op.id.startsWith('pause-')) { cutPauses = new Set(cutPauses); cutPauses.has(op.id) ? cutPauses.delete(op.id) : cutPauses.add(op.id) }
      else words = words.map(x => x.id === op.id ? { ...x, cut: !x.cut } : x)
    } else if (op.op === 'cutFillers') {
      words = words.map(x => !x.cut && isFillerText(x.text) ? { ...x, cut: true } : x)
    } else if (op.op === 'tightenPauses') {
      cutPauses = new Set(pauses.map(p => p.id))
    } else if (op.op === 'restoreCuts') {
      const outside = new Set(activeClip ? sourceWords.filter((_, i) => i < activeClip[0] || i > activeClip[1]).map(x => x.id) : [])
      words = words.map(x => ({ ...x, cut: outside.has(x.id) }))
      cutPauses = new Set()
    } else if (op.op === 'correct') {
      const t = op.text.trim(); const cur = words.find(x => x.id === op.id)
      if (t && cur && t !== cur.text) words = words.map(x => x.id === op.id ? { ...x, text: t } : x)
    } else if (op.op === 'previewClip') {
      if (op.clip) {
        const base = clipBase ?? words.map(x => ({ ...x })); clipBase = base
        const inside = new Set(sourceWords.slice(op.clip[0], op.clip[1] + 1).map(x => x.id))
        words = base.map(x => inside.has(x.id) ? x : { ...x, cut: true })
        activeClip = [op.clip[0], op.clip[1]]
      } else {
        if (clipBase) { words = clipBase; clipBase = null }
        activeClip = null
      }
    } else throw new Error('VoxConvo has no op ' + op.op)
    steps.push(snapshot(op))
  }
  return steps
}
