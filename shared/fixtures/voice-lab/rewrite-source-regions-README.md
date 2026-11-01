# Rewrite source region vectors

`rewrite-source-regions.json` is synthetic, hand-authored input for the pure
part of the long-recording Rewrite source read (voice-lab.md §8.7–8.9). A take
run decodes only the source frames it reads; these vectors pin which frames
those are. They contain no audio. Both Media suites replay every case without
decoding: `VoiceLabSourceAudio.nearWindow`, `aligned`, `merged` and
`decodeChunkFrames` (Swift) and `NearWindow`, `Aligned`, `Merged` and
`DecodeChunkFrames` (C#).

Ranges are half-open source frames `[start, end)` at the case's `rate`.

- `nearWindow` builds a window from `startSample`, `endSample` and the two seam
  kinds (`none`, `gap`, `hard`). Only a gap seam lends its silence: the
  seconds, capped at 290, times the rate, rounded up. The range reaches 6 s past
  the window plus that silence on each side, covers the 10 s speaker-check span
  that starts 5 s before the window's centre, and is then `aligned`.
- `aligned` clamps both ends to `[0, totalFrames]` and moves the start back to
  a frame on the 24 kHz take grid, a multiple of `rate / gcd(rate, 24000)`. An
  end before the start becomes an empty range at the start.
- `merged` sorts by start and joins overlapping or touching ranges.
- `decodeChunkFrames` is the envelope pass's chunk: 280 s of frames, or fewer
  where PCM16 would reach the 50,000,000-byte upload limit, less the 20 ms
  remainder a chunk can absorb. The crossover lies between 89,279 and 89,280 Hz.

Expected values may be edited by hand only with the formula and reason stated
in the change.
