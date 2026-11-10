# Voice Lab window vectors off the source sample grid

`window-grid-cases.json` uses schema `voxclip-voice-lab-window-grid-cases/1`, with exactly `schema`, `caseCount`, `windows`
and `grid` at the root. Regenerate it with `python3 -I tools/fixtures/voice-lab/generate_window_grid.py`. The
standard-library generator loads only definitions from `generate_window.py` (as `generate_window_clip_edges.py` does), never
its case generation or output, and regenerates byte for byte with no float tolerance.

The cases pin voice-lab §10.1 (2026-11-10): a word meets a replace range on the source sample grid. Its boundaries are rounded
with the fit's JavaScript half-up rule, because the fit plan and the recipe store each window edge as its sample over the
source rate (§8.9.2). A stored edge therefore meets a touching word boundary that rounds to the same sample. Before this rule,
validation and the output planner compared in exact seconds: a seam at a cut on a touching boundary off the grid was refused
in `place` with `windowCrossesWord`, and a hard seam at a touching kept word placed but its stored range failed validation at
Use (`invalidRange`).

`windows` holds window cases as in [window-README.md](window-README.md) (`input`, `expected`, `roomTone`) plus `stored`:
`{start, end}`, the accepted window's edges as the fit stores them (`startSample / rate`, `endSample / rate`), or null for
a refusal. The 8 cases:
- a cut word touching the phrase at 15.655000000000001 s, one ulp past 15.655, the user's shape (MVP48);
- the same seam at a cut exactly half a sample off the 48 kHz grid (534 480.5 rounds half up to the seam's 534 481);
- hard seams at touching kept words on both sides, every boundary off the grid, at 44.1 and 48 kHz;
- touching kept words exactly half a sample off the grid on both sides;
- a window closing on a take end half a sample off the grid, which the fit stores a sample past `durationSeconds`;
- a clip opening mid-take on a touching word off the 44.1 kHz grid;
- a kept word that really crosses the passage's start, by 2.5 samples, still refused with `windowCrossesWord`.

`grid` pins the rule itself: each case gives a `sampleRate`, an `item` and a `range` (`start`, `end` in seconds), and whether
the item lies `inside` the range and whether it `crossesStart` or `crossesEnd` (the edge's sample lies strictly between the
item's rounded boundaries).

Both Cores replay every case exactly (Swift `VoiceLabWindowTests.sampleGridVectors`, C# `VoiceLabWindowTests.SampleGridVectors`):
each accepted window validates and prepares in its scope and in the full take, as `place` returns it and as stored, as a
one-word passage recipe with the case's room tone; the grid cases go through `VoiceLabSampleGrid`.
