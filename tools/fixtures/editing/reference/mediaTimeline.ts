export interface TimedSegment {
  start: number
  end: number
  isStrikethrough?: boolean
  isPause?: boolean
  id?: string
}

export interface MediaInterval {
  start: number
  end: number
  startSample: number
  endSample: number
}

// Cuts sit in the silence around speech. A removed word also takes up to WORD_REACH of the
// silence on each side (never more than half a gap), so no onset or tail of it is left
// behind while its neighbours keep theirs. A shortened pause keeps a natural breath next
// to each word that stays.
const WORD_REACH = 0.1
const PAUSE_KEEP_AFTER_WORD = 0.15
const PAUSE_KEEP_BEFORE_WORD = 0.15

const isRangeCut = (segment: TimedSegment) => !!segment.isPause || !!segment.id?.startsWith('pause-') || !!segment.id?.startsWith('clip-')
const isValid = (segment: TimedSegment) => Number.isFinite(segment.start) && Number.isFinite(segment.end) && segment.end > segment.start

/** The source time range a removed segment takes out, before sample rounding. */
function cutRange(segment: TimedSegment, speech: readonly TimedSegment[], duration: number): [number, number] {
  if (segment.isPause || segment.id?.startsWith('pause-')) {
    const before = speech.filter(word => word.end <= segment.start + 1e-6).reduce<TimedSegment | undefined>((latest, word) => !latest || word.end > latest.end ? word : latest, undefined)
    const after = speech.find(word => word.start >= segment.end - 1e-6)
    return [
      segment.start + (before && !before.isStrikethrough ? PAUSE_KEEP_AFTER_WORD : 0),
      segment.end - (after && !after.isStrikethrough ? PAUSE_KEEP_BEFORE_WORD : 0)
    ]
  }
  if (segment.id?.startsWith('clip-')) return [segment.start, segment.end]
  // Speech is sorted by start: everything earlier bounds the silence before, the next word the silence after.
  const index = speech.indexOf(segment)
  const earlierEnd = speech.slice(0, index).reduce((latest, word) => Math.max(latest, word.end), 0)
  if (earlierEnd >= segment.end) return [segment.start, segment.end]
  const nextStart = speech[index + 1]?.start ?? duration
  const reach = (gap: number) => Math.min(WORD_REACH, Math.max(0, gap) / 2)
  return [segment.start - reach(segment.start - earlierEnd), segment.end + reach(nextStart - segment.end)]
}

/** One source timeline, with every cut quantized to the samples actually removed. */
export function buildMediaEditPlan(
  words: readonly TimedSegment[],
  duration: number,
  sampleRate = 48000
) {
  if (!Number.isFinite(duration) || duration < 0 || !Number.isFinite(sampleRate) || sampleRate <= 0) {
    throw new Error('Invalid media duration or sample rate')
  }
  const totalSamples = Math.max(0, Math.round(duration * sampleRate))
  const clampSample = (time: number) => Math.max(0, Math.min(totalSamples, Math.round(time * sampleRate)))
  const interval = (startSample: number, endSample: number): MediaInterval => ({
    start: startSample / sampleRate,
    end: endSample / sampleRate,
    startSample,
    endSample
  })

  const speech = words.filter(word => isValid(word) && !isRangeCut(word)).sort((a, b) => a.start - b.start)
  const selected = words
    .filter(word => word.isStrikethrough && isValid(word))
    .map(word => {
      const [start, end] = cutRange(word, speech, duration)
      return interval(clampSample(start), clampSample(end))
    })
    .filter(cut => cut.endSample > cut.startSample)
    .sort((a, b) => a.startSample - b.startSample)

  const cuts: MediaInterval[] = []
  for (const cut of selected) {
    const previous = cuts[cuts.length - 1]
    if (previous && cut.startSample <= previous.endSample) {
      cuts[cuts.length - 1] = interval(previous.startSample, Math.max(previous.endSample, cut.endSample))
    } else {
      cuts.push(cut)
    }
  }

  const kept: MediaInterval[] = []
  let cursor = 0
  for (const cut of cuts) {
    if (cut.startSample > cursor) kept.push(interval(cursor, cut.startSample))
    cursor = cut.endSample
  }
  if (cursor < totalSamples) kept.push(interval(cursor, totalSamples))
  const outputSamples = kept.reduce((sum, part) => sum + part.endSample - part.startSample, 0)

  const mapTime = (sourceTime: number) => {
    const sourceSample = clampSample(Number.isFinite(sourceTime) ? sourceTime : 0)
    let removed = 0
    for (const cut of cuts) {
      if (cut.startSample >= sourceSample) break
      removed += Math.min(sourceSample, cut.endSample) - cut.startSample
    }
    return Math.max(0, Math.min(outputSamples, sourceSample - removed)) / sampleRate
  }

  const sourceTime = (editedTime: number) => {
    let remaining = Math.max(0, Math.round((Number.isFinite(editedTime) ? editedTime : 0) * sampleRate))
    for (const part of kept) {
      const length = part.endSample - part.startSample
      if (remaining < length) return (part.startSample + remaining) / sampleRate
      remaining -= length
    }
    return totalSamples / sampleRate
  }

  return { cuts, kept, totalSamples, outputSamples, duration: outputSamples / sampleRate, mapTime, sourceTime }
}

/** Map each boundary independently, including words overlapping a removed interval. */
export function mapWordsToEditedTimeline<T extends TimedSegment>(
  words: readonly T[],
  plan: ReturnType<typeof buildMediaEditPlan>
): T[] {
  return words
    .filter(word => !word.isStrikethrough && !word.isPause && !word.id?.startsWith('pause-') && Number.isFinite(word.start) && Number.isFinite(word.end) && word.end > word.start)
    .map(word => ({ ...word, start: plan.mapTime(word.start), end: plan.mapTime(word.end) }))
    .filter(word => word.end > word.start)
}
