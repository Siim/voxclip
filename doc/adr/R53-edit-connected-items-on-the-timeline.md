# ADR-R53: Edit connected items on the timeline

Accepted 2026-11-25 · [Issue 28](https://github.com/Siim/voxclip/issues/28)

## Decision

Keep speech as the primary, rippling storyline. Store connected items at a take-source anchor so they follow their
word when speech changes or story parts are reordered. Moving an item changes its anchor. Picture effects cover
source ranges, shrink around cuts, and stay hidden at the seam when all their words are cut. They stay inside one
story part. Sound effects and music segments instead keep their length on the edited clock. If their anchor is cut,
they play from the seam, and they can play across a story join. Trimming a clip can hide an item without moving or
deleting it. B-roll covers a source range but plays continuously at 1× for the remaining edited length, ending early
if the recording runs out.

Keep one [music track](../spec/music.md#2-project-contract) per scope; a track without segments is still a whole-scope
bed. Store fades and gain points on the item, not the asset. A gain point is `{t, db}`: finite seconds from the item's
start, `t ≥ 0`, and relative gain `−60…+12 dB`. An item has at most 64 points, with strictly increasing times. Gain
interpolates linearly in dB, holds outside the first and last point, and the fades multiply after the envelope.
The Core reducer applies a range dip as one edit: it replaces points inside the range with four sample-aligned points,
keeping the original envelope at both ends and lowering the inner points by the requested depth (up to 60 dB).
Each ramp is the shorter of 50 ms or one third of the range, rounded to the sample grid. A valid 0 dB dip changes nothing.
An illustration split reuses the image; timeline edits do not delete asset files. Motion cues need no new fields.

The first write of a new field (or a sound length the older format cannot represent) promotes the document to schema v6.
Unset fields are absent, so an untouched document keeps its version and encoding. A v5 reader refuses v6 rather than
silently losing edits. Both Cores reject unknown keys and replay the same wire vectors.

The timeline has eight lanes. Route item edits through one Core reducer, and have preview, export, FCPXML and the
self-check use the same edits. Land Core and its contract first on both platforms; the reducer, rendering and interface
follow separately. Use hosted Windows CI for implementation checks and defer native Narrator checks until the VM is back.
