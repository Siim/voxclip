# Voice Lab render contract fixtures

`tools/fixtures/voice-lab/generate_render.py` creates the additive `*-render-v3.voxclip` projects and `render-cases.json` from the source-preserving v2 project fixtures. Run it from any directory with Python 3. Both Core suites consume these generated files; no provider response, paid asset or binary media is included. The original provider-service `README.md`, `contract.json` and rewrite prompt are frozen separately.

`passage` is equal-duration source video with a selected aligned TTS candidate, a required patch room-tone run and two candidates with distinct trims, seeds and word timing. `full-take` is an equal-duration, two-chunk group with explicit request IDs and assembled frame spans. `voice-changer-half` tests the 50% persistence boundary without TTS QA fields. `disclosure-at-30` and `disclosure-above-30` test the strict all-AI threshold.

`touching` contains two selected passages meeting at one shared 20-sample synth seam. `one-sample-gap` retains one source sample between them and requires preparation to reject overlapping windows; that sample must never be swallowed. `clipped-seam` begins its clip at the internal synth seam and requires a typed handle refusal. `render-cases.json` also records a half-sample JS rounding vector and a planner-only 1100-for-1000 mapping case that source-video render capability rejects. These are synthetic clock and validation vectors, not accepted render outputs.

Validate with `/tmp/voxclip-r4-schema-venv/bin/python tools/schemas/validate.py shared/fixtures/voice-lab/*-render-v3.voxclip`. Core tests add malformed public input, candidate transition, stale request, enum, immutability and invalid policy checks around these shared values.
