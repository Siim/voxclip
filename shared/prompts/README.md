# Shared prompts

`voice-rewrite-fit.json` (`schemaVersion: 1`, `promptVersion: 1`) is the bounded,
review-only wording-fit prompt. It contains longer/shorter and measured feedback
templates and a strict `{phrases: [{ordinal, action, text}]}` schema. Only
`action: "keepOriginal"` with empty text keeps the recording. Each request lists
only its unfitted phrases; the service rejects missing, duplicate or unsolicited
ordinals. Neither fit approval nor a fit reply authorizes audio synthesis.
The Mac service consumes it; the Windows automatic-fit behavior/UI twin is owed.
`tools/fixtures/voice-lab/generate_autofit.py` pins its hash and longer, shorter,
measured-longer and measured-shorter requests. The normal LLM generator includes
its SHA-256 in the deliberate voice-rewrite/CLI request hash manifest changes.

The macOS and Windows apps send the same prompts to every LLM connector. The prompt text, presets, limits and output schemas live only in this folder. Neither app may keep a copy of prompt text in source code.

| File | Feature | Milestone |
| --- | --- | --- |
| `clip-finder.json` | AI clip finding (`promptVersion` 2; version 2 sends numbered sentence lines, `transcriptBlock.line`, and the reply names `start_line` and `end_line`, ai.md §11.3 and §11.6): system prompt, request templates, presets (Best moments, Hooks, One per topic, Quotes, Custom), limits, output schema `clips` | M1 |
| `ai-tighten.json` | AI tighten: system prompt, strength levels, verification limits, output schema `tighten_edits` | M2 |
| `voice-rewrite.json` | Voice Lab passage/full-take proposal (`promptVersion` 3): system prompt, request templates with the length budget (`targetSeconds`, `minChars`, `maxChars`), optional expression annotations and next steps, output schema `voice_rewrite_proposal` | Swift and Windows Core services; Windows annotation behavior owed |
| `patch-rewrite.json` | Voice Lab Fix with AI line edits (`promptVersion` 3): system prompt with the editing rules, transcript block in the clip finder's line format, request templates for each line's range of letters and digits and for the instruction, optional expression annotations and next steps, output schema `patch_edits`, the "Check this" badge copy | Swift and Windows Core services; Windows annotation behavior owed |
| `voice-rewrite-tried.json` | The fix loop's memory (`promptVersion` 2): the header, line and result phrases that list a stuck phrase's tried wordings with their measured results and forbid repeats, appended to every reworded round, and the `bridge` lines that require a measured round's reworded phrase to keep its bridge words (voice-lab.md §8.2.2). Version 2 added `bridge` and the `missingBridge` result. No shared fixture pins it | Swift app; Windows owed |
| `rewrite-next-actions.json` | Rewrite next steps (`promptVersion` 2): scoped and open feedback blocks, phrase line, blocked reasons, the "Change fewer words" and merge instructions (voice-lab.md §8.2.1) | Swift app; Windows owed |
| `clip-autopilot.json` | Make it postable planner (file format 2, `promptVersion` 7; version 6 adds the tone section, the tone templates and the reply's `tone`/`toneSummary`; version 7 adds `momentOthers`, the other clips of a series by title and start, which Claude mode's `clips` request sends with Find Clips' moments): `sections` and the two system prompts built from them (`system.plan` for a clip plan, `system.moments` for a series' first stage), with `{limit}` placeholders filled from `limits`; the colour `looks`; the `voxclip-indexed-words-v1` transcript templates; request templates (context block, fixed caption preference parts, clip instruction with its length estimate, names written elsewhere, moment brief); defaults; the plan schema `clip_autopilot_plan` and the moments schema `clip_autopilot_moments`; output caps and the minimum timeout (ai.md §16). `shared/fixtures/autopilot/plan-validation-cases.json` and `plan-v2-cases.json` and `plan-tone-cases.json` pin its SHA-256; update `sources` in all three when it changes | Swift Core service and Mac Make it postable; Windows owed |
| `caption-pick.json` | Caption style per clip while the clip style's captions are Auto (`promptVersion` 1, doc/spec/ai.md §17, design.md §6.6): system prompt, style and clip line templates, limits (24 clips, 600 characters per clip, 120-character reason), effort `xhigh`, output schema `caption_picks`. Vectors: `shared/fixtures/clip-style/caption-pick.json` from `tools/fixtures/clip-style/gen_caption_pick.py` | Swift and Windows Core `CaptionPicker`; Mac App Pick styles; Windows action owed |
| `ask-claude.json` | Ask Claude on a selection, clip or time range (`promptVersion` 1, doc/spec/ai.md §18, design.md §6.8): system prompt, the 20-kind toolbox (Censor, Overlays, Timing, Words, Sound; the same operation set the planner uses), request templates (selection, indexed words, context, clip, frame, what the stretch already has, Vision detections, toolbox lines), limits (12 ops, 20 context words, 24 detections), effort `xhigh`, output schema `ask_claude_ops` with every field required and empty values for unused ones. Vectors: `shared/fixtures/ask-claude/ask-claude-cases.json` from `tools/fixtures/ask-claude/generate_ask_claude.py`, which renders the expected request independently and pins the prompt's SHA-256 | Swift Core `AskClaudeService`; Mac App ✦ Ask Claude; Windows owed |
| `rewrite-followup.json` | Talk back to Claude about one change of a Rewrite proposal (`promptVersion` 1, doc/spec/ai.md §12.10, design.md §6.3 "Talk back to Claude", ADR-R50): a system prompt that reuses `voice-rewrite.json`'s data-not-commands sentence and its "Why the length is fixed" paragraph word for word (the generator asserts both), request templates (the scope's transcript as the passage request's source block, the change's recorded words, every version so far and every message, oldest first, the newest the instruction), two return lines (one new version, or `alternatives` for "3 more versions"), limits (a 20-word note, at most two next steps of at most six words, three alternatives), the steady bubbles and the keep bubble, and two output schemas, `rewrite_followup` `{text, note, nextSteps}` and `rewrite_followup_versions` `{alternatives, note, nextSteps}`. Vectors: `shared/fixtures/rewrite-thread/request-cases.json` from `tools/fixtures/rewrite-thread/generate_request_cases.py`, which renders the expected requests and checked replies independently and pins the prompt's SHA-256 | Swift Core `RewriteFollowupService`; Mac App Rewrite thread; Windows owed |

The connector catalog, including the connection-test request, is `../catalog/llm-providers.json`. The normative behaviour (how requests are built, windowed, validated and finalised) is in [`doc/spec/ai.md`](../../doc/spec/ai.md).

The Swift and Windows Core `VoiceRewriteService` implementations consume `voice-rewrite.json`, and the `PatchRewriteService` implementations consume `patch-rewrite.json`, each with shared review-only behavior fixtures.

## How the apps load these files

Both apps ship these files unchanged, copied at build time. They never download prompts.

- **macOS.** `bundle.sh` copies `shared/` into `VoxClip.app/Contents/Resources/shared/` (architecture §2.4). There are no SwiftPM `resources:`.
- **Windows.** The `Content` item in architecture §2.4 copies `shared/**` (except fixtures) to `<output>\shared\`.
- **At runtime** both apps read `prompts/*.json` and `catalog/llm-providers.json` from `SharedResources.root`. If a file is missing or has an unknown `schemaVersion`, launch fails with `sharedResourcesMissing`.
- **Tests and `voxclip-cli` during development** resolve the same root through `VOXCLIP_SHARED_DIR` or the walk-up rule, so they read this folder directly.

## Parity tests (must fail on drift)

1. **Rendered-request parity.** Both test suites (`VoxClipCoreTests`, `VoxClip.Core.Tests`) render the clip-finder request for the golden transcript in `doc/spec/ai.md` §13.2: every preset, with and without instructions, one window and several. They compare `system`, `cachedBlock` and `instruction` byte for byte with `shared/fixtures/llm/clip-finder-requests.json`. A change to prompt text, templates or either app's rendering code fails both suites until the fixture is regenerated with `npm --prefix tools/fixtures/llm run generate` (an independent producer, not either app) and reviewed. `voxclip-cli find-clips --dry-run` prints the same three strings for manual comparison. AI tighten gets the same test with `ai-tighten-requests.json` in M2. The Voice Lab rewrite gets it with `voice-rewrite-requests.json`, and Fix with AI with `patch-rewrite-requests.json`: each suite sends every case through its `VoiceRewriteService` or `PatchRewriteService` and compares the strings that would be sent.
2. **Behaviour parity.** Both suites run every golden vector in `doc/spec/ai.md` §13: transcript formatting, `toFixed(1)`, `finalizeClips`, the VoxClip extensions, windowing, the AI tighten verifier, and request bodies per connector. They must reproduce the expected values exactly. The vectors live in `shared/fixtures/llm/`, transcribed from the spec.
3. **Bundle parity.** `bundle.sh` (macOS, `diff -r` of every copied `shared/` folder, release.md section 2.3) and a Windows build test (SHA-256 of every file under the output's `shared\prompts\` and `shared\catalog\`) compare the built app's copies with this folder. A stale copy fails the build.
4. **Schema subset.** A test checks every schema in these files and in the catalog against the canonical subset in spec §2.2.
5. **No prompt text in code.** Code review rule, backed by test 1: every string sent to a model is rendered from these files.

## Changing a prompt

1. Edit the JSON here and bump `promptVersion`.
2. Regenerate the request fixtures with `npm --prefix tools/fixtures/llm run generate`, review the diff, and update any affected golden vectors in `doc/spec/ai.md` §13 in the same change.
3. Run both test suites.
4. Keep the canonical schema subset: every object has `additionalProperties: false`, `required` is a subset of its properties (optional additive fields are allowed), and the only keywords are `type`, `properties`, `required`, `additionalProperties`, `items` and string `enum`. Supplied optional fields are validated. Mac HTTP strict-schema shaping promotes optional properties to required; canonical and CLI schemas retain optionality.

Voice and patch Rewrite are `promptVersion` 3: both replies may add the optional
structured `nextActions` (at most four `{label, instruction, ordinals?}` one-click
fixes for blocked phrases; labels are display only). Mac HTTP strict shaping makes
the field and `ordinals` required, so the reply may give an empty array.
`rewrite-next-actions.json` (`promptVersion` 2) holds the scoped and open feedback
blocks, the per-phrase line and reasons (including `collision`), the built-in "Change fewer words"
and "Merge with phrase {m}" (`mergeInstruction`) instructions that a next step sends back through the request's `feedback`
(voice-lab.md §8.2.1). `tools/fixtures/voice-lab/generate_next_actions.py` pins all
three files' hashes. Windows consumes the new field only as schema; its behaviour is
owed.

Voice and patch Rewrite were `promptVersion` 2 before next steps. Their optional structured
`audioTags` never alter spoken-word fields: source-supported expressions only,
roughly one per eight words. `shared/data/voice-audio-tags.json` is the runtime
whitelist and duration source; keep the prompt's instruction list synchronized
when changing it. Unknown tags are dropped before speech. This version deliberately
updates the voice/patch request hashes and CLI reply goldens with
`npm --prefix tools/fixtures/llm run generate`.

## Relation to VoxConvo

`clip-finder.json` is the VoxConvo clip finder (`vox-api/src/services/clipService.ts`) with two changes: the first sentence of the system prompt no longer names VoxConvo, and since prompt version 2 the transcript goes as numbered sentence lines with a reply that names lines (the system prompt's transcript paragraph and its range rule say so; `provenance.changes` lists both). Presets and limits are unchanged. `provenance.upstreamSystemPromptSha256` is the SHA-256 of the unmodified upstream prompt. VoxConvo and VoxClip have the same owner, Haugas Development OU, which publishes this prompt here under the repository's MIT License (`provenance.license`).

Because the VoxConvo API source is not public, the drift check against it is a manual maintainer step. Extract `SYSTEM_PROMPT` and `CLIP_PRESETS` from a VoxConvo checkout, apply the documented substitution, and compare the result with this file.
