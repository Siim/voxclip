# Shared prompts

The macOS and Windows apps send the same prompts to every LLM connector. The prompt text, presets, limits and output schemas live only in this folder. Neither app may keep a copy of prompt text in source code.

| File | Feature | Milestone |
| --- | --- | --- |
| `clip-finder.json` | AI clip finding: system prompt, request templates, presets (Best moments, Hooks, One per topic, Quotes, Custom), limits, output schema `clips` | M1 |
| `ai-tighten.json` | AI tighten: system prompt, strength levels, verification limits, output schema `tighten_edits` | M2 |
| `voice-rewrite.json` | Voice Lab passage/full-take proposal, output schema `voice_rewrite_proposal` | Mac Core service foundation; Windows handoff pending |

The connector catalog, including the connection-test request, is `../catalog/llm-providers.json`. The normative behaviour (how requests are built, windowed, validated and finalised) is in [`doc/spec/ai.md`](../../doc/spec/ai.md).

`apps/macos/Sources/VoxClipCore/Services/VoiceLab/VoiceRewriteService.swift` is the current consumer of `voice-rewrite.json`. Windows Core must load the same file and match its review-only validation and offline connector tests before parity can be claimed.

## How the apps load these files

Both apps ship these files unchanged, copied at build time. They never download prompts.

- **macOS.** `bundle.sh` copies `shared/` into `VoxClip.app/Contents/Resources/shared/` (architecture §2.4). There are no SwiftPM `resources:`.
- **Windows.** The `Content` item in architecture §2.4 copies `shared/**` (except fixtures) to `<output>\shared\`.
- **At runtime** both apps read `prompts/*.json` and `catalog/llm-providers.json` from `SharedResources.root`. If a file is missing or has an unknown `schemaVersion`, launch fails with `sharedResourcesMissing`.
- **Tests and `voxclip-cli` during development** resolve the same root through `VOXCLIP_SHARED_DIR` or the walk-up rule, so they read this folder directly.

## Parity tests (must fail on drift)

1. **Rendered-request parity.** Both test suites (`VoxClipCoreTests`, `VoxClip.Core.Tests`) render the clip-finder request for the golden transcript in `doc/spec/ai.md` §13.2: every preset, with and without instructions, one window and several. They compare `system`, `cachedBlock` and `instruction` byte for byte with `shared/fixtures/llm/clip-finder-requests.json`. A change to prompt text, templates or either app's rendering code fails both suites until the fixture is regenerated with `npm --prefix tools/fixtures/llm run generate` (an independent producer, not either app) and reviewed. `voxclip-cli find-clips --dry-run` prints the same three strings for manual comparison. AI tighten gets the same test with `ai-tighten-requests.json` in M2.
2. **Behaviour parity.** Both suites run every golden vector in `doc/spec/ai.md` §13: transcript formatting, `toFixed(1)`, `finalizeClips`, the VoxClip extensions, windowing, the AI tighten verifier, and request bodies per connector. They must reproduce the expected values exactly. The vectors live in `shared/fixtures/llm/`, transcribed from the spec.
3. **Bundle parity.** `bundle.sh` (macOS, `diff -r` of every copied `shared/` folder, release.md section 2.3) and a Windows build test (SHA-256 of every file under the output's `shared\prompts\` and `shared\catalog\`) compare the built app's copies with this folder. A stale copy fails the build.
4. **Schema subset.** A test checks every schema in these files and in the catalog against the canonical subset in spec §2.2.
5. **No prompt text in code.** Code review rule, backed by test 1: every string sent to a model is rendered from these files.

## Changing a prompt

1. Edit the JSON here and bump `promptVersion`.
2. Regenerate the request fixtures with `npm --prefix tools/fixtures/llm run generate`, review the diff, and update any affected golden vectors in `doc/spec/ai.md` §13 in the same change.
3. Run both test suites.
4. Keep the canonical schema subset: every object has `additionalProperties: false`, every property is required, and the only keywords are `type`, `properties`, `required`, `additionalProperties`, `items` and string `enum`.

## Relation to VoxConvo

`clip-finder.json` is the VoxConvo clip finder (`vox-api/src/services/clipService.ts`) with one change: the first sentence of the system prompt no longer names VoxConvo. Presets, limits and the output schema are unchanged. `provenance.upstreamSystemPromptSha256` is the SHA-256 of the unmodified upstream prompt. VoxConvo and VoxClip have the same owner, Haugas Development OU, which publishes this prompt here under the repository's MIT License (`provenance.license`).

Because the VoxConvo API source is not public, the drift check against it is a manual maintainer step. Extract `SYSTEM_PROMPT` and `CLIP_PRESETS` from a VoxConvo checkout, apply the documented substitution, and compare the result with this file.
