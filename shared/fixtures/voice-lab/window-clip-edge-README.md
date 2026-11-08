# Voice Lab clip-edge window vectors

`window-clip-edge-cases.json` uses schema `voxclip-voice-lab-window-clip-edge-cases/1`, with exactly `schema`, `caseCount`,
`cases` and `fuzz` at the root. Regenerate it with `python3 -I tools/fixtures/voice-lab/generate_window_clip_edges.py`. The
standard-library generator loads only definitions from `generate_window.py` (as `generate_window_all.py` does), never its
case generation or output, and regenerates byte for byte with no float tolerance.

The cases pin voice-lab §8.4 step 1, a clip's own edges. A clip that starts or ends mid-take usually touches the word outside
it, because Whisper word ends are back to back (transcription.md §5.5), so `clipTimes` leaves no silence at its edge. In a clip
scope a window whose passage lies in the clip, with no kept or replaced item of the clip before it (or after it), opens (or
closes) the clip's output: its seam keeps its kind and fade, moves to the clip's own edge when the clip's kept source cannot
hold the fade's outer half, and is checked in the full take by prepare's rule. Prepare plays such a seam as a take edge in
the clip.

Each case is a window case as in [window-README.md](window-README.md) (`input`, `expected`, `roomTone`) plus
`clipOutputEdges`: `{incoming, outgoing}`, whether the accepted window opens or closes the clip's output (a fade seam with
nothing rendered beside it in the clip), or null for a refusal. The 19 named cases cover a clip opening on a touching word
(its first word and its first sentence), one closing on one, both (the whole clip, its first and its last word), the
44.1 kHz odd hard fade (529, outgoing half 265), a 65 ms silence leaving a 2.5 ms sliver beside each seam (the seam moves
to the clip's edge), cut fillers at the clip's edges (absorbed up to the edge), the word before the clip cut in the project
(the full take holds the fade across that cut), every item before the clip cut with the take opening on them (refused
with the full take's numbers), a replacement already opening the clip, a passage outside the clip and a window whose
absorbed word runs past the clip's end (both refused as before).

The fuzz (`fuzz`: seed 20261108, Knuth's MMIX LCG) builds 4,000 takes of 4 to 9 words, mostly touching, at 44.1 and 48 kHz,
with a clip starting or ending mid-take, up to two cut words and a passage at or inside the clip's edges. Every placement is
refused with one of the legacy window refusals or validates and prepares in its clip and in the full take; `fuzz` records the
counts and every 40th take is committed after the named cases. Both Cores replay every case exactly (Swift
`VoiceLabWindowTests.clipEdgeVectors`, C# `VoiceLabWindowTests.ClipEdgeVectors`): each accepted window validates and
prepares in its clip and in the full take as a one-word passage recipe with the case's room tone, and the clip's plan starts
or ends on the generated piece exactly where `clipOutputEdges` says.
