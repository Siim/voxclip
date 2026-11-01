# Training span vectors

`training-spans.json` is synthetic, hand-authored input for Voice Lab §6.5.1,
the pure Core selection of project audio for an own-voice clone. It contains
no recorded audio, transcript text or provider replies. Both Core suites replay
every case through `VoiceTrainingSpans.select` (Swift) and
`VoiceTrainingSpans.Select` (C#) without decoding media or loading a model.

`python3 tools/fixtures/voice-lab/generate_training_spans.py` writes the file.
It holds every case's inputs and computes `expected` with its own
standard-library reference of §6.5.1, written from the spec rather than from
either Core. Two runs give identical bytes, and `check_drift.py` requires the
committed bytes to match exactly. The reference reproduces the twelve original
hand-calculated cases unchanged; they gained only `preferredMs` 0.

Each case gives `duration` in seconds, `items` in stored transcript order (only
the fields the selection reads: `kind`, `start`, `end`, `conf`, `speaker` and
`synthetic`), `excluded` source ranges `[start, end]` in seconds, an optional
`preferRange` `[start, end]` in source seconds (absent means no preference),
and `frames` as run-length pairs `[count, dBFS]`. Expand the pairs in order into one 10 ms
level per frame; frame `i` covers `[i / 100, (i + 1) / 100)` seconds. Word
lengths of several seconds are deliberate: the selection only reads times, and
long words keep the vectors small.

`expected` is compared exactly: `status`, `availableMs`, `selectedMs`,
`preferredMs`, and the `selected`, `qualifying` and `rejected` lists in source
order. Times are whole
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
| `prefer-fills-cap` | The preferred spans alone fill 120 s, so the 50 dB span outside the range is skipped; a fifth preferred 30 s span does not fit. |
| `prefer-below-cap-filled-from-other` | 35 s of preferred spans come first, then the other spans by SNR; a 30 s span that would pass 120 s is skipped and a later 10 s one fits. |
| `prefer-partial-overlap` | A span crossing the range start counts only its overlap; a span starting exactly at the range end is not preferred; the range is converted with `ms(t)` (19.9996 and 96.0004 s are 20,000 and 96,000 ms). |
| `prefer-overlap-at-end` | A selected span crossing the range end counts only the part before the end (15 of its 30 s); with no range the selection differs. |
| `prefer-no-qualifying-span` | The range holds only a `lowSnr` and a `short` piece, and qualifying spans touch both its edges: the unpreferred selection with `preferredMs` 0. |
| `prefer-ties-across-groups` | Every span is 40 dB: preferred spans go first even when a span outside the range is as loud, as long and earlier; an outside 10 s span then fits. |
| `prefer-below-minimum` | A range over the whole take with 20 s available: `belowMinimum`, nothing selected and `preferredMs` 0. |

Hand calculation, for example `low-snr-rejected`: 7,000 frames, of which 1,500
are −55 dBFS, so sorted index 700 is −55. The first run covers frames 100 to
2,099, all −20, so its SNR is −20 − (−55) = 35. The second covers frames 2,400
to 4,299 at −36, giving 19, below 20. The third covers frames 4,600 to 5,599 at
−35, giving exactly 20. Qualifying total: 20,000 + 10,000 = 30,000 ms.

`cap-120-seconds` ranks 28 s (50 dB), 20 s (50 dB), 30 s (45 dB), 26 s (42 dB),
25 s (40 dB), 16 s (35 dB) and 6 s (35 dB). The running total is 28, 48, 78 and
104 s; 25 s would make 129 s and is skipped; 16 s makes 120 s; 6 s would make
126 s and is skipped.

`preferRange` (§6.5.1 Preferred range and step 6): the qualifying spans with
`startMs < preferEnd` and `endMs > preferStart` are ranked first, each group by
SNR, then duration, then start, and the walk fills up to 120 s across both.
`preferredMs` sums each selected span's overlap with the range; it is 0 without
a range and when nothing is selected. Every `prefer-` case has a −70 dBFS
floor, so a span's SNR is its level plus 70, and speaks each span as words of
at most 10 s with 0.5 s pauses.

`prefer-fills-cap` ranks the preferred 30 s spans 46, 44, 42, 40 and 38 dB:
30, 60, 90 and 120 s, then 38 dB would make 150 s and the outside 25 s span at
50 dB would make 145 s, so both are skipped. Without the range the 50 dB span
is picked first and the selection is 115 s.

`prefer-partial-overlap` picks the preferred 35, 30 and 28 dB spans (30, 24 and
30 s: 84 s), then the outside 50 dB span (114 s); the outside 45 and 26 dB spans
would pass 120 s. `preferredMs` is 5,000 (25,000 − 20,000) + 30,000 + 30,000 =
65,000.

`prefer-overlap-at-end` (range 50 to 110 s) picks the preferred 35 and 30 dB
spans (55 to 85 s and 95 to 125 s: 60 s), then the outside 50 and 45 dB spans
(100 s); the outside 42 and 40 dB spans would pass 120 s. `preferredMs` is
30,000 + 15,000 (110,000 − 95,000) = 45,000; counting the 95 to 125 s span
past the range end would give 60,000. Without the range the pick is 50, 45, 42
and 40 dB: 95 s.

Change a case by editing its inputs in the generator; the expected values follow.
A change to the reference itself must state the rule and the reason, and the
twelve original cases must stay identical.

These vectors do not claim anything about real recordings, speaker match or
clone quality.
