# Ask Claude vectors

`ask-claude-cases.json` (`voxclip-ask-claude/1`) holds a synthetic v4 project (the "invoice" recording of the approved
mockup), request cases whose expected instruction `tools/fixtures/ask-claude/generate_ask_claude.py` renders on its own
from `shared/prompts/ask-claude.json`, and stub replies with hand-derived expected operations and repair counts
(doc/spec/ai.md §18.4). `promptSha256` pins the prompt file; regenerate after any prompt change (check_drift.py runs the
generator). Do not hand-edit. Swift `AskClaudeTests` replays every case. No provider replies: every reply is synthetic.
