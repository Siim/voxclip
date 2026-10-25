/**
 * Transcripts time a word by its clearest part: soft starts ("s", "wh", a breath) begin
 * before the timestamp, and endings fade out after it. Moving each boundary out to where
 * the sound actually starts and stops keeps every cut in the silence between words.
 */

interface TimedWord {
  start: number
  end: number
}

interface AudioLike {
  numberOfChannels: number
  sampleRate: number
  length: number
  getChannelData(channel: number): Float32Array
}

const FRAME_SECONDS = 0.01
const MAX_LEAD = 0.35 // a soft start can begin this long before its timestamp
const MAX_TAIL = 0.3 // and a word can keep fading this long after it
const BRIDGE_FRAMES = 2 // short dips inside a soft sound do not end it
const TOUCHING = 0.03 // words closer than this run together
const VALLEY_REACH = 0.07 // how far a shared edge may move to the quietest point
const MIN_WORD = 0.04

export function refineWordBoundaries<T extends TimedWord>(words: readonly T[], audio: AudioLike): T[] {
  const frameSize = Math.max(1, Math.round(audio.sampleRate * FRAME_SECONDS))
  const frameLength = frameSize / audio.sampleRate
  const frames = Math.floor(audio.length / frameSize)
  if (!words.length || frames < 10 || !audio.numberOfChannels) return words.slice()

  // Loudness of every 10 ms frame, all channels together.
  const channels = Array.from({ length: audio.numberOfChannels }, (_, channel) => audio.getChannelData(channel))
  const level = new Float32Array(frames)
  for (let frame = 0; frame < frames; frame++) {
    let sum = 0
    for (const data of channels) {
      for (let i = frame * frameSize, end = i + frameSize; i < end; i++) sum += data[i] * data[i]
    }
    level[frame] = Math.sqrt(sum / (frameSize * channels.length))
  }
  const frameAt = (time: number) => Math.min(frames - 1, Math.max(0, Math.floor(time / frameLength)))
  const quietest = Array.from(level).sort((a, b) => a - b)[Math.floor(frames * 0.1)]
  const speech = words.flatMap(word => Array.from(level.subarray(frameAt(word.start), frameAt(word.end) + 1))).sort((a, b) => a - b)
  const speechLevel = speech[Math.floor(speech.length / 2)] ?? 0
  // Sound counts as part of a word when it is clearly above the room and not far below speech.
  const threshold = Math.max(quietest * 2, speechLevel * 0.08)
  if (!(threshold > 0)) return words.slice()
  const audible = (frame: number) => level[frame] >= threshold

  const total = audio.length / audio.sampleRate
  const refined = words.map((word, index) => {
    // Neighbours share the silence between them: each side may only claim its half.
    const previousEnd = index > 0 ? words[index - 1].end : null
    const nextStart = index < words.length - 1 ? words[index + 1].start : null
    const earliest = Math.max(0, word.start - MAX_LEAD, previousEnd === null ? 0 : (previousEnd + word.start) / 2)
    const latest = Math.min(total, word.end + MAX_TAIL, nextStart === null ? total : (word.end + nextStart) / 2)

    // Walk outwards from the timestamp while the sound continues.
    const edge = (from: number, step: 1 | -1, inside: (frame: number) => boolean) => {
      let found = -1
      for (let frame = from, quiet = 0; frame >= 0 && frame < frames && inside(frame); frame += step) {
        if (audible(frame)) { found = frame; quiet = 0 } else if (++quiet > BRIDGE_FRAMES) break
      }
      return found
    }
    const first = edge(frameAt(word.start), -1, frame => frame * frameLength >= earliest)
    const last = edge(frameAt(word.end), 1, frame => (frame + 1) * frameLength <= latest)
    const start = first < 0 ? word.start : Math.min(word.start, first * frameLength)
    const end = last < 0 ? word.end : Math.max(word.end, (last + 1) * frameLength)
    return start < word.start || end > word.end ? { ...word, start, end } : word
  })

  // Words that run together have no silence between them. Put their shared edge at the
  // quietest moment nearby, so removing either word cuts between sounds, not through one.
  for (let index = 1; index < refined.length; index++) {
    const previous = refined[index - 1]
    const next = refined[index]
    if (next.start - previous.end > TOUCHING) continue
    const middle = (previous.end + next.start) / 2
    const from = Math.ceil(Math.max(middle - VALLEY_REACH, previous.start + MIN_WORD) / frameLength)
    const to = Math.floor(Math.min(middle + VALLEY_REACH, next.end - MIN_WORD) / frameLength) - 1
    if (from > to || to >= frames) continue
    let valley = from
    for (let frame = from + 1; frame <= to; frame++) if (level[frame] < level[valley]) valley = frame
    // Inside one continuous sound there is no better place; leave the edge alone.
    if (level[valley] > level[frameAt(middle)] * 0.5) continue
    const edge = (valley + 0.5) * frameLength
    refined[index - 1] = { ...previous, end: edge }
    refined[index] = { ...next, start: edge }
  }
  return refined
}
