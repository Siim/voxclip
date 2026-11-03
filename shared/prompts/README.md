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
| `clip-finder.json` | AI clip finding: system prompt, request templates, presets (Best moments, Hooks, One per topic, Quotes, Custom), limits, output schema `clips` | M1 |
| `ai-tighten.json` | AI tighten: system prompt, strength levels, verification limits, output schema `tighten_edits` | M2 |
| `voice-rewrite.json` | Voice Lab passage/full-take proposal (`promptVersion` 2): system prompt, request templates with the length budget (`targetSeconds`, `minChars`, `maxChars`), optional expression annotations, output schema `voice_rewrite_proposal` | Swift and Windows Core services; Windows annotation behavior owed |
| `patch-rewrite.json` | Voice Lab Fix with AI line edits (`promptVersion` 2): system prompt with the editing rules, transcript block in the clip finder's line format, request templates for each line's range of letters and digits and for the instruction, optional expression annotations, output schema `patch_edits`, the "Check this" badge copy | Swift and Windows Core services; Windows annotation behavior owed |

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

Voice and patch Rewrite are now `promptVersion` 2. Their optional structured
`audioTags` never alter spoken-word fields: source-supported expressions only,
roughly one per eight words. `shared/data/voice-audio-tags.json` is the runtime
whitelist and duration source; keep the prompt's instruction list synchronized
when changing it. Unknown tags are dropped before speech. This version deliberately
updates the voice/patch request hashes and CLI reply goldens with
`npm --prefix tools/fixtures/llm run generate`.

## Relation to VoxConvo

`clip-finder.json` is the VoxConvo clip finder (`vox-api/src/services/clipService.ts`) with one change: the first sentence of the system prompt no longer names VoxConvo. Presets, limits and the output schema are unchanged. `provenance.upstreamSystemPromptSha256` is the SHA-256 of the unmodified upstream prompt. VoxConvo and VoxClip have the same owner, Haugas Development OU, which publishes this prompt here under the repository's MIT License (`provenance.license`).

Because the VoxConvo API source is not public, the drift check against it is a manual maintainer step. Extract `SYSTEM_PROMPT` and `CLIP_PRESETS` from a VoxConvo checkout, apply the documented substitution, and compare the result with this file.
