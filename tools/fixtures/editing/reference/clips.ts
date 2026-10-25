import { API_BASE_URL } from './videoJob'

export type ClipPreset = 'best' | 'hooks' | 'topics' | 'quotes' | 'custom'

export interface ClipWord {
  word: string
  start: number
  end: number
}

export interface ClipChoice {
  id: string
  title: string
  reason: string
  score: number
  startWord: number
  endWord: number
}

export const CLIP_PRESETS: { value: ClipPreset; label: string }[] = [
  { value: 'best', label: 'Best moments' },
  { value: 'hooks', label: 'Hooks' },
  { value: 'topics', label: 'One per topic' },
  { value: 'quotes', label: 'Quotes' },
  { value: 'custom', label: 'Custom' }
]

/**
 * Source-time range for a clip. Cuts sit in the silence next to the first and last
 * word, never closer to a neighbouring word than half the gap, so no syllable is lost.
 */
export function clipTimes(words: readonly ClipWord[], startWord: number, endWord: number) {
  const first = words[startWord]
  const last = words[endWord]
  const previous = words[startWord - 1]
  const next = words[endWord + 1]
  const start = Math.max(0, first.start - Math.min(0.12, previous ? Math.max(0, first.start - previous.end) / 2 : 0.12))
  const end = last.end + Math.min(0.25, next ? Math.max(0, next.start - last.end) / 2 : 0.25)
  return { start, end }
}

/** Clips are in early access; the server decides who sees them. */
export async function fetchClipAccess(signal?: AbortSignal): Promise<boolean> {
  try {
    const response = await fetch(`${API_BASE_URL}/clips/access`, { credentials: 'include', signal })
    return response.ok && (await response.json()).enabled === true
  } catch {
    return false
  }
}

export async function fetchClipSuggestions(words: readonly ClipWord[], preset: ClipPreset, instructions: string, signal?: AbortSignal): Promise<ClipChoice[]> {
  const response = await fetch(`${API_BASE_URL}/clips/suggest`, {
    method: 'POST',
    credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ words: words.map(({ word, start, end }) => ({ word, start, end })), preset, instructions }),
    signal
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(data.error || 'Could not find clips right now. Please try again.')
  return (data.clips as Omit<ClipChoice, 'id'>[]).map((clip, index) => ({ ...clip, id: `clip-${Date.now()}-${index}` }))
}
