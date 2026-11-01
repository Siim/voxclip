# v2 Core display vectors

Generate from the repository root with `python3 tools/fixtures/v2/generate_v2.py`.
The generator is an independent Python reference of the rules in
[editing.md §11.5](../../../doc/spec/editing.md#115-v2-display-math-shared-vectors).
It uses no transcendentals or numerical reductions. Regeneration must reproduce
both files byte for byte on macOS and Linux; neither belongs on the drift
checker's tolerant list. `tools/fixtures/voice-lab/check_drift.py` regenerates
these files as part of the existing hosted fixture gate.

- `paragraphs.json`: `voxclip.v2.paragraphs.v1`, exactly 27 cases. Each word is
  `[text, startSeconds, endSeconds, speakerOrNull]`; expected ranges are half-open
  word indices. Includes the 10,000-word monologue, speaker and gap changes,
  sentence punctuation and the exact 80/150 thresholds, forced-window edges
  and later-gap ties. The reference scans candidate paragraph boundaries;
  production implementations stream over the source words.
- `timeline-cases.json`: `voxclip.v2.timeline.v1`, exactly 44 cases. Legacy raw
  intervals are sample pairs; voice pieces are `[sourceStart, sourceEnd,
  outputStart, outputEnd, "kept" | "ai"]`. Expected pieces and ranges are in
  seconds. Covers render construction, half-open visibility, seams, gaps,
  long takes, tick ladders, SMPTE frame flooring/saturation and caption hold
  boundaries on both axes. Reference visibility uses linear scans; production
  uses binary search. `"NaN"` and `"Infinity"` represent non-finite inputs.

Both replay suites pin exactly the top-level keys `schema`, `caseCount`, `cases`,
the schema and fixed counts. Unknown timeline kinds fail. Expected values use
exact comparison; no float tolerance or platform-specific expected values.
Add future categories in new files with new schema identifiers, then update
both replays and drift coverage in the same package. Do not expand these files
under an existing replay contract.
