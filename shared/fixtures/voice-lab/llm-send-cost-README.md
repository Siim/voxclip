# LLM send cost cases

`llm-send-cost-cases.json` pins how an LLM send (`voiceRewrite`, `patchRewrite`) presents its cost: voice-lab.md §3.1, as amended by the user's decision of 2026-10-31 (design delta §13.2). The Mac suite `apps/macos/Tests/VoxClipCoreTests/VoiceLab/VoiceLabLLMSendCostTests.swift` replays every case through `VoiceLabCostPresentation.kind(forLLMSendTo:signIn:providerName:)`. The Windows suite `apps/windows/tests/VoxClip.Core.Tests/Tracks/voice-lab/VoiceLabLlmSendCostTests.cs` replays them through `VoiceLabCostPresentation.KindForLlmSend`.

Regenerate only with `python3 tools/fixtures/voice-lab/generate_llm_send_cost.py` and review the diff as a behaviour change. The generator uses only the Python standard library and gives identical bytes on every run. `check_drift.py` requires these bytes to match exactly. Expected values are never edited by hand.

## Cases

There is one case for every connector in `shared/catalog/llm-providers.json` and every sign-in state: `"plan"`, `"apiKey"` and `null`. `null` means the sign-in is unknown: the CLI is signed out, its sign-in check has not run, or it reported a method the app does not recognise. Both suites also check that the cases cover every connector id of their Core, so a new connector can't go unclassified.

The generator derives each answer from the catalog's `group`, not from either Core's code:

| `group` | Sign-in | Expected |
|---|---|---|
| `local` (Ollama and LM Studio on this computer or another host, Apple on-device) | any | `inline` with empty text: no amount, and the send starts at once |
| `cli` (Claude Code, Codex) | `"plan"` | `inline` with empty text |
| `cli` | `"apiKey"` or `null` | `confirm` |
| `apiKey` (Anthropic, OpenAI, xAI, Google Gemini) | any | `confirm` |

A confirmation reads "VoxClip can't tell what this costs. Check {providerName}'s pricing." on every send. An LLM send never has a known price (§3.1), so no case carries an estimate. `providerName` is the caller's: the catalog `label` for an API-key or local connector, and the vendor whose API the key pays for, "Anthropic" for Claude Code and "OpenAI" for Codex, as in the ai.md §4.8 consent copy.

The sign-in comes from the app's existing parsing of Claude Code's `authMethod` (ai.md §6.8) and of `codex login status` (§6.9). A method outside the app's known plan and API-key values is `null`, so it confirms and is never treated as a plan.
