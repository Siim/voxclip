# ADR-R54: Spoken recordings on one project clock

Accepted 2026-11-27 · [Issue 31](https://github.com/Siim/voxclip/issues/31)

## Decision

Store additional spoken recordings as `media.spokenSources` in clock order. Each of the one to five entries names an
existing companion by `contentKey`. It keeps its own transcript, engine, language and raw cache key. It may also keep
a display label and up to ±12 dB of level adjustment. The root transcript and primary media do not change.

Assign each companion an integer offset at least one second past the rounded-up end of the preceding recording.
Offsets stay fixed: removing a recording leaves a gap rather than moving surviving edits. The first companion uses
`r2.`, and each new companion gets a higher prefix. The prefix high-water mark after a removal lives in the project's
`extensions` so a removed ID cannot alias a different word, even after saving back to v6. The file and companion
entry remain available for relinking, B-roll and stacks.

Core derives `ProjectClock`, a view that qualifies companion word IDs and shifts their times onto the primary sample
grid. The same cut sets, corrections and clip parts work with these IDs. Times resolve to a recording and local sample,
or no recording in a guard gap. A one-recording clock returns the original transcript unchanged. An ordinary clip or a
part cannot cross regions. A story can use parts from any number of regions in any play order.

A part edit that would drop paid lip sync or a whole-clip revoice edits a copy and selects it instead. The original
and its paid assets remain in the project. Copies remember the clip protecting the paid window so later edits to the
copy do not make another one for that window.

Write v7 only with spoken sources; do not promote a legacy project when it loads or saves. A v6 reader refuses v7.
Swift and C# replay the same clock vectors. Planning the region edges and fades, decoding recordings, rendering seams
and offering the controls are separate steps. Voice changes on words outside the primary are not part of this version.

## Why

Adding a recording key to every cut, style, effect, caption and part would repeat the same distinction throughout the
editor. Joining the clocks instead leaves the originals untouched and makes the recording boundary explicit where it
matters: in range validation, planning and media lookup.
