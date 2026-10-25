import assert from 'node:assert/strict'

const whitespace = '[\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]'
const trimPattern = new RegExp(`^${whitespace}+|${whitespace}+$`, 'g')
const splitPattern = new RegExp(`${whitespace}+`, 'u')
const sentenceEnd = /[.!?。！？]["'”’)]*$/u

export const jsTrim = text => text.replace(trimPattern, '')

export function truncateUTF16(text, limit) {
  if (text.length <= limit) return text
  const last = text.charCodeAt(limit - 1)
  const next = text.charCodeAt(limit)
  return text.slice(0, last >= 0xD800 && last <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF ? limit - 1 : limit)
}

export const instructionsText = (text, limit) => truncateUTF16(jsTrim(text), limit)

export function toFixed1(value) {
  assert(Number.isFinite(value) && value >= 0, 'toFixed1 requires a finite non-negative binary64')
  if (value >= 1e21) return String(value)
  const buffer = new ArrayBuffer(8)
  const view = new DataView(buffer)
  view.setFloat64(0, value, false)
  const bits = view.getBigUint64(0, false)
  const exponentBits = Number((bits >> 52n) & 0x7FFn)
  const mantissa = (bits & ((1n << 52n) - 1n)) + (exponentBits === 0 ? 0n : 1n << 52n)
  const exponent = exponentBits === 0 ? -1074 : exponentBits - 1023 - 52
  let tenths
  if (exponent >= 0) tenths = mantissa * 10n * (1n << BigInt(exponent))
  else if (-exponent > 60) tenths = 0n
  else {
    const shift = BigInt(-exponent)
    tenths = (10n * mantissa + (1n << (shift - 1n))) >> shift
  }
  return `${tenths / 10n}.${tenths % 10n}`
}

export function formatTime(seconds) {
  assert(Number.isFinite(seconds) && seconds >= 0, 'formatTime requires finite non-negative seconds')
  return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`
}

export function formatTranscript(entries) {
  const lines = []
  let firstPos = 0
  for (let position = 0; position < entries.length; position += 1) {
    const current = entries[position]
    const next = entries[position + 1]
    const gap = next ? next.start - current.end : 0
    if (!next || sentenceEnd.test(current.text) || gap >= 1.2 || position - firstPos >= 40) {
      const first = entries[firstPos]
      lines.push({
        firstPos, lastPos: position, firstIndex: first.index, lastIndex: current.index,
        start: first.start, end: current.end,
        text: `[${first.index}-${current.index}] ${formatTime(first.start)} ${entries.slice(firstPos, position + 1).map(entry => entry.text).join(' ')}`,
        pauseAfter: next && gap >= 1.5 ? `(pause ${toFixed1(gap)}s)` : null
      })
      firstPos = position + 1
    }
  }
  return { lines, rendered: renderLines(lines) }
}

export const renderLines = lines => lines.flatMap(line => line.pauseAfter === null ? [line.text] : [line.text, line.pauseAfter]).join('\n')
export const cachedTranscript = (lines, prompt) => prompt.transcriptBlock.prefix + renderLines(lines) + prompt.transcriptBlock.suffix

export function prepareEntries(items, { feature = 'clipFinder', cutWordIds = [], scope = null, maxWordTextLength = 100 } = {}) {
  const cuts = new Set(cutWordIds)
  return items.flatMap((item, index) => {
    if (feature === 'aiTighten' && (cuts.has(item.id) || item.kind === 'unlabeledSpeech' || (scope && (index < scope[0] || index > scope[1])))) return []
    const text = item.kind === 'unlabeledSpeech' ? '…' : item.kind === 'event' ? item.text : (item.correction ?? item.text)
    return [{ id: item.id, index, text: truncateUTF16(text, maxWordTextLength), start: item.start, end: item.end }]
  })
}

export function snapPair(startWord, endWord, lines, radius = 3) {
  const nearest = (original, values, preferLarger) => {
    let chosen = original
    let distance = Infinity
    for (const value of values) {
      const candidateDistance = Math.abs(value - original)
      if (candidateDistance <= radius && (candidateDistance < distance || (candidateDistance === distance && (preferLarger ? value > chosen : value < chosen)))) {
        chosen = value
        distance = candidateDistance
      }
    }
    return chosen
  }
  const snappedStart = nearest(startWord, lines.map(line => line.firstIndex), false)
  const snappedEnd = nearest(endWord, lines.map(line => line.lastIndex), true)
  return snappedStart > snappedEnd ? [startWord, endWord] : [snappedStart, snappedEnd]
}

export function finalizeClips({ candidates, words, preset, lines = [], cutWordIds = [], windowCount = 1, snap = false }, limits) {
  const cuts = new Set(cutWordIds)
  const ranked = []
  for (const [arrival, candidate] of candidates.entries()) {
    let startWord = candidate.start_word
    let endWord = candidate.end_word
    if (!Number.isInteger(startWord) || !Number.isInteger(endWord) || startWord < 0 || endWord < startWord || endWord >= words.length || !Number.isFinite(candidate.score)) continue
    const title = truncateUTF16(jsTrim(candidate.title), limits.titleMaxLength)
    const reason = truncateUTF16(jsTrim(candidate.reason), limits.reasonMaxLength)
    const floor = Math.floor(candidate.score)
    const rounded = floor + (candidate.score - floor >= 0.5 ? 1 : 0)
    const score = Math.min(limits.scoreMax, Math.max(limits.scoreMin, rounded))
    if (snap) [startWord, endWord] = snapPair(startWord, endWord, lines, limits.snapRadiusWords)
    const length = words[endWord].end - words[startWord].start
    if (!(length >= Math.max(limits.minLengthFloorSeconds, preset.minSeconds * limits.minLengthFactor) && length <= preset.maxSeconds * limits.maxLengthFactor)) continue
    let cutCount = 0
    for (let index = startWord; index <= endWord; index += 1) if (cuts.has(words[index].id)) cutCount += 1
    if (cutCount / (endWord - startWord + 1) > limits.mostlyCutFraction) continue
    ranked.push({ title, reason, score, startWord, endWord, arrival })
  }
  ranked.sort((left, right) => right.score - left.score || left.arrival - right.arrival)
  const selected = []
  for (const candidate of ranked) {
    if (selected.length >= preset.maxClips) break
    const duplicate = selected.some(chosen => {
      if (chosen.startWord === candidate.startWord && chosen.endWord === candidate.endWord) return true
      const intersection = Math.max(0, Math.min(chosen.endWord, candidate.endWord) - Math.max(chosen.startWord, candidate.startWord) + 1)
      const union = Math.max(chosen.endWord, candidate.endWord) - Math.min(chosen.startWord, candidate.startWord) + 1
      return (windowCount > 1 && intersection / union >= limits.nearDuplicateOverlap) || (preset.noOverlap && intersection > 0)
    })
    if (!duplicate) selected.push({ ...candidate, selection: selected.length })
  }
  return selected.sort((left, right) => left.startWord - right.startWord || left.selection - right.selection)
    .map(({ title, reason, score, startWord, endWord }) => ({ title, reason, score, startWord, endWord }))
}

export const estimateTokens = text => Math.ceil(Buffer.byteLength(text ?? '', 'utf8') / 2.2)

export function packWindows(lines, { budget, maxWords, overlapSeconds = 0 }) {
  assert(budget >= 600, 'contextTooLong: transcript budget is below 600 tokens')
  const windows = []
  let firstLine = 0
  while (firstLine < lines.length) {
    let lastLine = firstLine - 1
    let estimatedCost = 0
    let entryCount = 0
    while (lastLine + 1 < lines.length) {
      const line = lines[lastLine + 1]
      const cost = estimateTokens(line.text + '\n') + (line.pauseAfter === null ? 0 : estimateTokens(line.pauseAfter + '\n'))
      const count = line.lastPos - line.firstPos + 1
      if (lastLine >= firstLine && (estimatedCost + cost > budget || entryCount + count > maxWords)) break
      estimatedCost += cost
      entryCount += count
      lastLine += 1
    }
    windows.push({ firstLine, lastLine, firstIndex: lines[firstLine].firstIndex, lastIndex: lines[lastLine].lastIndex, entryCount, estimatedCost })
    if (lastLine === lines.length - 1) break
    if (overlapSeconds === 0) firstLine = lastLine + 1
    else {
      const boundary = lines[lastLine].end - overlapSeconds
      const next = lines.findIndex(line => line.start >= boundary)
      firstLine = Math.max(firstLine + 1, next < 0 ? lastLine + 1 : next)
    }
  }
  return windows
}

export function verifyTighten({ entries, edits }, prompt) {
  const { lines } = formatTranscript(entries)
  const labels = new Map(lines.map(line => [line.text.split(' ')[0], line]))
  const visited = new Set()
  const strip = new Set([...prompt.normalization.stripEdgeCharacters])
  const normalize = text => text.split(splitPattern).flatMap(part => {
    const scalars = [...part.normalize('NFC').toLowerCase()]
    while (scalars.length && strip.has(scalars[0])) scalars.shift()
    while (scalars.length && strip.has(scalars.at(-1))) scalars.pop()
    return scalars.length ? [scalars.join('')] : []
  })
  const kinds = new Set(prompt.kinds.map(kind => kind.id))
  const proposals = []
  const rejected = []
  for (const [editIndex, edit] of edits.entries()) {
    const label = jsTrim(edit.line)
    const line = labels.get(label)
    let rejection = !line ? 'unknownLine' : visited.has(label) ? 'duplicate' : null
    if (line) visited.add(label)
    if (!rejection && !kinds.has(edit.kind)) rejection = 'badKind'
    if (rejection) {
      rejected.push({ editIndex, reason: rejection })
      continue
    }
    const lineEntries = entries.slice(line.firstPos, line.lastPos + 1)
    const entryTokens = lineEntries.map(entry => normalize(entry.text))
    const tokens = entryTokens.flatMap((parts, entryPosition) => parts.map(text => ({ text, entryPosition })))
    const keepTokens = normalize(edit.keep)
    const matched = new Set()
    let cursor = tokens.length - 1
    for (let keepPosition = keepTokens.length - 1; keepPosition >= 0; keepPosition -= 1) {
      while (cursor >= 0 && tokens[cursor].text !== keepTokens[keepPosition]) cursor -= 1
      if (cursor < 0) {
        rejection = 'notSubsequence'
        break
      }
      matched.add(cursor)
      cursor -= 1
    }
    const fates = entryTokens.map((parts, entryPosition) => {
      if (!parts.length) return null
      const matchCount = tokens.reduce((count, token, tokenIndex) => count + (token.entryPosition === entryPosition && matched.has(tokenIndex) ? 1 : 0), 0)
      if (matchCount > 0 && matchCount < parts.length) rejection ??= 'splitWord'
      return matchCount === parts.length
    })
    if (rejection) {
      rejected.push({ editIndex, reason: rejection })
      continue
    }
    for (let position = 0; position < fates.length; position += 1) {
      if (fates[position] !== null) continue
      let nearest = position - 1
      while (nearest >= 0 && !entryTokens[nearest].length) nearest -= 1
      if (nearest < 0) {
        nearest = position + 1
        while (nearest < fates.length && !entryTokens[nearest].length) nearest += 1
      }
      fates[position] = nearest < fates.length && nearest >= 0 ? fates[nearest] : keepTokens.length > 0
    }
    const cutWordIds = lineEntries.filter((entry, position) => !fates[position]).map(entry => entry.id)
    if (!cutWordIds.length) continue
    const review = keepTokens.length > 0
      ? cutWordIds.length > prompt.limits.reviewCutFraction * lineEntries.length
      : lineEntries.length > prompt.limits.wholeLinePreselectMaxWords
    proposals.push({ lineLabel: label, kind: edit.kind, cutWordIds, preselected: !review })
  }
  return { proposals, rejectedCount: rejected.length, rejected }
}

export function validateSchema(schema, path = '$') {
  const allowed = new Set(['type', 'properties', 'required', 'additionalProperties', 'items', 'enum'])
  assert(schema && typeof schema === 'object' && !Array.isArray(schema), `${path}: schema must be an object`)
  for (const keyword of Object.keys(schema)) assert(allowed.has(keyword), `${path}: unsupported keyword ${keyword}`)
  assert(['object', 'array', 'string', 'integer', 'number', 'boolean'].includes(schema.type), `${path}: unsupported type`)
  if (schema.type === 'object') {
    assert.equal(schema.additionalProperties, false, `${path}: additionalProperties`)
    assert.deepEqual([...schema.required].sort(), Object.keys(schema.properties).sort(), `${path}: every property must be required`)
    assert.equal(new Set(schema.required).size, schema.required.length, `${path}: duplicate required property`)
    for (const [name, child] of Object.entries(schema.properties)) validateSchema(child, `${path}.${name}`)
  } else assert(!('properties' in schema || 'required' in schema || 'additionalProperties' in schema), `${path}: object-only keywords`)
  if (schema.type === 'array') validateSchema(schema.items, `${path}[]`)
  else assert(!('items' in schema), `${path}: items on non-array`)
  if ('enum' in schema) assert(schema.type === 'string' && schema.enum.length > 0 && schema.enum.every(value => typeof value === 'string'), `${path}: enum must contain strings`)
}
