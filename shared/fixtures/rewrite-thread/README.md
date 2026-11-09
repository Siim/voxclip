# Rewrite thread vectors

`request-cases.json` (`voxclip-rewrite-thread-cases/1`) pins "Talk back to Claude" (doc/design.md §6.3, doc/spec/ai.md
§12.12, ADR-R50): request cases whose expected system, cached block and instruction
`tools/fixtures/rewrite-thread/generate_request_cases.py` renders on its own from `shared/prompts/rewrite-followup.json`,
and stub replies with their checked result (the new versions, the note cut to 20 words, at most two next steps of at
most six words, and the refusals). Strings only. `promptSha256` pins the prompt file; regenerate after any prompt change
(check_drift.py runs the generator, byte-exact). Do not hand-edit. Swift `RewriteFollowupReplayTests` replays every case
and checks the case counts; the Windows replay is owed. Every reply is synthetic; no provider was called.
