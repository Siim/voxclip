# Hard-join smoothing vectors

`hard-join-cases.json` (`voxclip-hard-join/1`) contains 42 independent synthetic
cases: 14 fade points, 11 word-gain points, 10 optional-field/validation cases,
one reserve/pace case, room-tone matching, pause-excluding join measurement,
bounded acoustic refinement, and three post-micro-pause gain-gating cases.
It contains no recordings or measurements from a person's audio.

Regenerate with `python3 tools/fixtures/voice-lab/generate_hard_join.py`; use
`--check` for a read-only byte comparison. The generator uses explicit analytic
values and the standard library only. Do not hand-edit expected values. This
file is byte-exact in `check_drift.py`; it does not replace or modify any legacy
fixture or pinned case count.

Both `VoiceLabHardJoinTests` suites replay curves on 24 and 48 kHz sample grids,
decode/omit optional metadata, reject invalid metadata, and check the reserved
fit/pace result. Both Media `VoiceLabHardJoinStagingTests` suites consume the
gating rows through the actual fit/QA mix path: no gain for a passing seam,
capped gain for a failing seam, and advisory rather than hard failure when
6 dB is insufficient. They also check hard transcript/speaker failures and
unchanged fitted bytes. Full-project round trips and 48 kHz renderer tests
verify timing, gain/fade sample points, untouched source outside 20 ms and exact
output length. Legacy fitted-asset hashes and legacy render tests stay intact.

The shared coordinates are output seconds relative to the join: positive for
the incoming edge word and negative for the outgoing edge word. The synthetic
room-tone target needs +40 dB, deliberately above the old +12 dB ceiling; the
equal-level speech check covers both 140 and 240 ms pauses. Exhaustive native
pace tests evaluate all 51 provider steps over 60 geometries in each of legacy
and smoothing modes.
