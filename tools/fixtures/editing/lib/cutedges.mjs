// Cut edges seated in the quiet (doc/spec/editing.md §5.10), written in JavaScript so the generator can produce
// expectations for them. Every number follows editing §2.6: binary64 in the written order, Float32 levels read as
// doubles, frame choices in integers. Words are one recording's, in that recording's local seconds, with clock ids.

export const CUT_EDGE_REACH = 0.15
export const CUT_EDGE_MAX_GAP = 0.2
export const CUT_EDGE_MIN_RUN = 2

const speechKind = word => (word.kind ?? 'word') === 'word' || word.kind === 'unlabeledSpeech'

/** The import level analysis (EditingImport LevelAnalysis) over an envelope: frame length, speech level S, threshold T. */
export function analysis(words, envelope) {
  const levels = envelope.levels, count = levels.length
  if (!words.length || count < 10) return null
  const fl = Math.max(1, Math.round(envelope.sampleRate * 0.01)) / envelope.sampleRate
  const frame = t => Math.min(count - 1, Math.max(0, Math.floor(t / fl)))
  const speech = []
  for (const word of words) for (let f = frame(word.start), last = frame(word.end); f <= last; f++) speech.push(levels[f])
  speech.sort((a, b) => a - b)
  const S = speech.length ? speech[Math.floor(speech.length / 2)] : 0
  const quietest = Array.from(levels).sort((a, b) => a - b)[Math.floor(count * 0.1)]
  const T = Math.max(quietest * 2, S * 0.08)
  return T > 0 ? { levels, count, fl, S, T } : null
}

/** §3.1 qualifying boundary between A = words[i-1] and B = words[i], without the "no key yet" condition. */
export function qualifies(A, B, cut) {
  if (!speechKind(A) || !speechKind(B) || cut.has(A.id) === cut.has(B.id)) return false
  const gap = B.start - A.end
  return gap >= 0 && gap < CUT_EDGE_MAX_GAP
}

/** Steps 1-8 of §3.1 for one boundary: the quiet point and its window, or null when the edge stays. */
export function quietPoint(A, B, a, sampleRate) {
  const b = (A.end + B.start) / 2
  const fb = Math.min(a.count - 1, Math.max(0, Math.floor(b / a.fl)))
  const lb = a.levels[fb]
  if (lb <= Math.max(a.T, 0.35 * a.S)) return null
  const q = Math.max(a.T, Math.min(0.5 * lb, 0.35 * a.S))
  const loT = Math.max(b - CUT_EDGE_REACH, A.start + Math.max(0.04, 0.5 * (A.end - A.start)))
  const hiT = Math.min(b + CUT_EDGE_REACH, B.end - Math.max(0.04, 0.5 * (B.end - B.start)))
  const lo = Math.max(0, Math.ceil(loT / a.fl)), hi = Math.min(a.count - 1, Math.floor(hiT / a.fl) - 1)
  if (lo > hi) return null
  let best = null
  for (let first = lo; first <= hi;) {
    if (!(a.levels[first] <= q)) { first++; continue }
    let last = first, min = a.levels[first]
    while (last + 1 <= hi && a.levels[last + 1] <= q) { last++; min = Math.min(min, a.levels[last]) }
    if (last - first + 1 >= CUT_EDGE_MIN_RUN) {
      const distance = first > fb ? first - fb : fb - last
      if (!best || distance < best.distance || (distance === best.distance && min < best.min)) best = { first, last, distance, min }
    }
    first = last + 1
  }
  if (!best) return null
  const t = (best.first + best.last + 1) / 2 * a.fl
  return { value: Math.round(t * sampleRate) / sampleRate, window: [loT, hiT] }
}

/**
 * §3.2: a Voice Lab replace range overlaps the window, or the boundary touches a paid scope (a key counts in its inputs when
 * word i-1 or word i lies in it). Frozen when the kept word is inside and the cut word outside (rule b), and otherwise unless a
 * word at this boundary whose kept/cut state the commit changed (`changed`) lies inside the scope.
 */
function frozen(A, B, cut, window, freeze, index, changed) {
  const [loT, hiT] = window
  if ((freeze.voiceRanges ?? []).some(([start, end]) => start < hiT && loT < end)) return true
  const [kept, removed] = cut.has(A.id) ? [B, A] : [A, B]
  return (freeze.paidScopes ?? []).some(([first, last]) => {
    const lo = index.get(first), hi = index.get(last)
    if (lo === undefined || hi === undefined) return false
    const inside = word => index.get(word.id) >= lo && index.get(word.id) <= hi
    if (!inside(kept) && !inside(removed)) return false
    if (inside(kept) && !inside(removed)) return true
    return !((inside(kept) && changed.has(kept.id)) || (inside(removed) && changed.has(removed.id)))
  })
}

/**
 * §3.1 over one recording: new keys for qualifying boundaries without one (only those in `only` when given). `changed` holds the
 * words whose kept/cut state the commit changed; empty for Fix cut edges and the offer, where nothing is cut.
 */
export function seat({ words, cut, envelope, sampleRate, freeze = {}, existing = {}, only = null, changed = new Set() }) {
  const edges = {}
  let kept = 0
  const a = analysis(words, envelope)
  if (!a) return { edges, frozen: kept }
  const index = new Map(words.map((word, i) => [word.id, i]))
  for (let i = 1; i < words.length; i++) {
    const A = words[i - 1], B = words[i]
    if (!qualifies(A, B, cut) || Object.hasOwn(existing, B.id) || (only && !only.has(B.id))) continue
    const point = quietPoint(A, B, a, sampleRate)
    if (!point) continue
    if (frozen(A, B, cut, point.window, freeze, index, changed)) kept++
    else edges[B.id] = point.value
  }
  return { edges, frozen: kept }
}

/** §3.4: keep only keys at a qualifying kept/cut boundary, in word order. */
export function normalize(words, cut, edges) {
  const result = {}
  for (let i = 1; i < words.length; i++) {
    if (Object.hasOwn(edges, words[i].id) && qualifies(words[i - 1], words[i], cut)) result[words[i].id] = edges[words[i].id]
  }
  return result
}

/** The boundaries whose kept/cut state differs between two cut sets (§3.3), named by the later word. */
export function changed(words, before, after) {
  const ids = new Set()
  for (let i = 1; i < words.length; i++) {
    const A = words[i - 1].id, B = words[i].id
    if (before.has(A) !== after.has(A) || before.has(B) !== after.has(B)) ids.add(B)
  }
  return ids
}

/** §4 buildSegments for one recording: cutStart on a cut word after a kept one, cutEnd on a cut word before a kept one. */
export function segments(words, cut, edges) {
  const result = words.map(word => ({ id: word.id, kind: 'word', wordKind: word.kind ?? 'word', text: word.id, start: word.start, end: word.end, cut: cut.has(word.id) }))
  for (let i = 1; i < words.length; i++) {
    const edge = edges[words[i].id]
    if (edge === undefined) continue
    if (result[i].cut && !result[i - 1].cut) result[i].cutStart = edge
    if (!result[i].cut && result[i - 1].cut) result[i - 1].cutEnd = edge
  }
  return result
}

/** Each recording's words in local seconds with clock ids, in clock order (editing §10.1, ProjectClock). */
export function recordings(project) {
  const rate = project.media.source.audio?.sampleRate ?? 48000
  const list = [{ offsetSamples: 0, words: project.transcript?.words ?? [] }]
  for (const source of project.media.spokenSources ?? []) {
    list.push({ offsetSamples: Math.round(source.offsetSeconds * rate), words: source.transcript.words.map(word => ({ ...word, id: source.wordIdPrefix + word.id })) })
  }
  return { rate, list }
}

/** §5 validation of edits.cutEdges: a reason string when refused, otherwise null. */
export function invalidReason(project) {
  const edges = project.edits.cutEdges
  if (edges === undefined) return null
  if (project.schemaVersion < 8) return 'cut edges need schema v8'
  const { rate, list } = recordings(project)
  for (const [id, value] of Object.entries(edges)) {
    const recording = list.find(r => r.words.some(word => word.id === id))
    if (!recording) return `no word ${id}`
    const i = recording.words.findIndex(word => word.id === id)
    if (i < 1) return `${id} is the first word of its recording`
    const A = recording.words[i - 1], B = recording.words[i], gap = B.start - A.end
    if (!(gap >= 0 && gap < CUT_EDGE_MAX_GAP)) return `${id} is not at a touching boundary`
    const b = (A.end + B.start) / 2
    if (!Number.isFinite(value) || Math.abs(value - b) > CUT_EDGE_REACH + 1 / rate || !(value > A.start && value < B.end)) return `${id} is outside its window`
  }
  return null
}

/** editing §10.1: the version a project is written at from the fields present. */
export function writtenVersion(project) {
  const required = project.agentThread || Object.keys(project.edits.cutEdges ?? {}).length ? 8 : project.media.spokenSources ? 7 : 1
  const version = project.schemaVersion
  if (version >= 1 && version < required) return required
  if (version >= 7 && version > required) return Math.max(required, 6)
  return version
}

/** Clock samples of every stored edge at a kept/cut boundary, sorted: where the full-take plan's cuts start or end. */
export function edgeSamples(project) {
  const { rate, list } = recordings(project)
  const cut = new Set(project.edits.cutWordIds)
  const samples = []
  for (const recording of list) {
    const kept = normalize(recording.words, cut, project.edits.cutEdges ?? {})
    for (const value of Object.values(kept)) samples.push(recording.offsetSamples + Math.round(value * rate))
  }
  return samples.sort((a, b) => a - b)
}
