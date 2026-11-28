// Synthetic take "vox-take-v1" (from vox-web/test/word-boundaries.test.mjs:12-25).
// Mono Float32 at 16 kHz. Spec: doc/spec/editing.md, section "Synthetic audio".
export const TAKE_RATE = 16000

export function makeTake(seconds, sections, rate = TAKE_RATE) {
  const data = new Float32Array(seconds * rate)
  let seed = 7
  const noise = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) * 2 - 1
  for (let i = 0; i < data.length; i++) data[i] = 0.002 * noise()
  for (const [from, to, kind] of sections) {
    for (let i = Math.round(from * rate); i < Math.round(to * rate); i++) {
      data[i] = kind === 'vowel' ? 0.5 * Math.sin(2 * Math.PI * 180 * i / rate) : 0.1 * noise()
    }
  }
  return { numberOfChannels: 1, sampleRate: rate, length: data.length, getChannelData: () => data }
}

export const takeInput = (seconds, sections) => ({ generator: 'vox-take-v1', sampleRate: TAKE_RATE, seconds, sections })

// Envelope "levels-v1" (editing §5.10, cut edges): the 10 ms RMS envelope itself, built from exact binary32 levels so
// that no decoder or noise drift enters. Every frame starts at `base`; each run [fromFrame, toFrame, level] then sets
// frames fromFrame..toFrame inclusive, in order, so a later run overrides an earlier one.
export const LEVELS_RATE = 16000

export function makeLevels({ frames, sampleRate, base, runs }) {
  const levels = new Float32Array(frames).fill(base)
  for (const [from, to, level] of runs) for (let frame = from; frame <= to; frame++) levels[frame] = level
  return { sampleRate, levels }
}

export const levelsInput = (frames, base, runs) => ({ generator: 'levels-v1', frames, sampleRate: LEVELS_RATE, base, runs })
