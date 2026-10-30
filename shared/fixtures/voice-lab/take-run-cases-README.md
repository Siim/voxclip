# Take run and QA vectors

`take-run-cases.json` is synthetic, hand-authored platform-neutral input for
Voice Lab §§2.6, 8.6 and 8.11. It contains no recorded audio or provider replies.
Both ports can replay it without network access or model weights.

Ranking uses the original window duration, not the expanded borrowed window.
A zero residual represents an exact plan. Other residuals represent changed
duration plans. Scores are the stated formula's hand-calculated results.

For QA, generate 16,000 mono samples at 16 kHz of a 220 Hz sine with the stated
amplitude. If `afterAmplitude` exists, use it from sample 8,000 and measure the
seam at 8,000; otherwise there are no seams. Use the supplied recognised tokens,
speaker score and English catalogue threshold 0.45. Compare failure names in
check order: transcript, clipping, loudness, speaker.

The run record pins the bound, strict unapproved expiry boundary, conservative
Scribe duration cap, UInt32 seed wrap and early-stop dispatch accounting.
Swift's mocked HTTP suite additionally covers approval/replay, failures,
cancellation, changed inputs, consent and model estimates. The Windows port
must add its own orchestration replay when it implements S14's run lease; R0's
Windows change only restores settings defaults.

Expected values may be edited by hand only with the formula and reason stated
in the change. These vectors do not claim live-provider, listening or runtime
calibration acceptance.
