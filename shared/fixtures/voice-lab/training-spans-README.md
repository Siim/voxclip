# Training span vectors

`training-spans.json` is synthetic, hand-authored input for Voice Lab §6.5.1,
the pure Core selection of project audio for an own-voice clone. It contains
no recorded audio, transcript text or provider replies. Both Core suites replay
every case through `VoiceTrainingSpans.select` (Swift) and
`VoiceTrainingSpans.Select` (C#) without decoding media or loading a model.

Each case gives `duration` in seconds, `items` in stored transcript order (only
the fields the selection reads: `kind`, `start`, `end`, `conf`, `speaker` and
`synthetic`), `excluded` source ranges `[start, end]` in seconds, and `frames`
as run-length pairs `[count, dBFS]`. Expand the pairs in order into one 10 ms
level per frame; frame `i` covers `[i / 100, (i + 1) / 100)` seconds. Word
lengths of several seconds are deliberate: the selection only reads times, and
long words keep the vectors small.

`expected` is compared exactly: `status`, `availableMs`, `selectedMs`, and the
`selected`, `qualifying` and `rejected` lists in source order. Times are whole
milliseconds. `snrDb` is a binary64 difference of two listed levels, so it is
compared with `==`; it is null for `short` and `unsplittable` pieces and for a
`lowSnr` piece without voiced frames.

| Case | What it pins |
|---|---|
| `happy-path` | Null and inclusive 0.8 confidence; a 3 s gap ends a run. |
| `low-confidence-split` | A 0.79 word and a 0.5 word end runs; a 3.5 s run is `short`. |
| `event-inside` | `event` and `unlabeledSpeech` items end runs that would otherwise form one 33.6 s run. |
| `two-speakers` | A speaker change ends a run with no gap; null is a different label. |
| `synthetic-excluded` | Synthetic words, a word overlapping an excluded range, and an excluded range inside a gap each end a run. |
| `low-snr-rejected` | Take floor −55 dBFS: 19 dB is rejected, exactly 20 dB passes, a piece of −50 dBFS frames has no voiced frame, and exactly 30 s available is `ok`. |
| `long-run-split-at-pauses` | A 2.0 s gap still joins; the longest valid gap wins over a longer gap that would leave 4 s; a tie of two 1.0 s gaps goes to the one nearer the piece's middle. |
| `unsplittable-run-and-30-second-span` | A 31.5 s run whose only boundary leaves 3.4 s is `unsplittable`; exactly 30 s is one span. |
| `cap-120-seconds` | Ranking by SNR, then duration, then start; a span that would exceed 120 s is skipped and a later one still fits, ending at exactly 120 s. |
| `below-minimum` | A 2.001 s gap ends a run, a 4.999 s run is `short`, an exact 5 s run qualifies, and 29.99 s available is `belowMinimum` with nothing selected. |
| `snr-percentiles` | The floor is sorted index `floor(n / 10)` (−60, not −62) and the voiced level is index `floor(m / 2)` of an even count (−22, not −30). |
| `empty-transcript` | No items gives `belowMinimum` with zero totals. |

Hand calculation, for example `low-snr-rejected`: 7,000 frames, of which 1,500
are −55 dBFS, so sorted index 700 is −55. The first run covers frames 100 to
2,099, all −20, so its SNR is −20 − (−55) = 35. The second covers frames 2,400
to 4,299 at −36, giving 19, below 20. The third covers frames 4,600 to 5,599 at
−35, giving exactly 20. Qualifying total: 20,000 + 10,000 = 30,000 ms.

`cap-120-seconds` ranks 28 s (50 dB), 20 s (50 dB), 30 s (45 dB), 26 s (42 dB),
25 s (40 dB), 16 s (35 dB) and 6 s (35 dB). The running total is 28, 48, 78 and
104 s; 25 s would make 129 s and is skipped; 16 s makes 120 s; 6 s would make
126 s and is skipped.

Expected values may be edited by hand only with the rule and the reason stated
in the change, and checked against a second calculation before committing.
These vectors do not claim anything about real recordings, speaker match or
clone quality.
