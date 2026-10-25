interface TimestampedWord {
  word: string
  start: number
  end: number
  conf?: number
}

const normalize = (text: string) => text.toLocaleLowerCase().replace(/[^\p{L}\p{N}]/gu, '')

/** Text correction must never move a different spoken word onto somebody else's time. */
export function alignTranscriptWords(words: TimestampedWord[], finalText: string): TimestampedWord[] {
  const tokens = finalText.trim().split(/\s+/).filter(Boolean)
  const sameSequence = tokens.length === words.length && words.every((word, index) => typeof word.word === 'string' && normalize(word.word) === normalize(tokens[index]))
  return words
    .map((word, index) => ({ ...word, word: sameSequence ? tokens[index] : word.word }))
    .filter(word => typeof word.word === 'string' && word.word.trim().length > 0 && Number.isFinite(word.start) && Number.isFinite(word.end) && word.start >= 0 && word.end > word.start)
}

/** Fallback estimates remain within the actual captured segment; they cannot add time. */
export function estimateTranscriptWords(text: string, start: number, end: number): TimestampedWord[] {
  const tokens = text.trim().split(/\s+/).filter(Boolean)
  if (!tokens.length || !Number.isFinite(start) || !Number.isFinite(end) || end <= start) return []
  const length = tokens.reduce((sum, token) => sum + token.length, 0)
  let consumed = 0
  return tokens.map(word => {
    const wordStart = start + consumed / length * (end - start)
    consumed += word.length
    return { word, start: wordStart, end: start + consumed / length * (end - start), conf: 0 }
  })
}
