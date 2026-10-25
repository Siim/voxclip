# LLM golden-fixture generator

Independent, dependency-free Node >=20 ESM implementation of `doc/spec/ai.md`
§2.2, §6, §11 and §12, under the repository's MIT licence. No app code or
VoxConvo/VoxConvo API implementation is imported or copied. Nothing calls a
provider, reads credentials, or spawns an installed LLM CLI.

From the repository root:

```sh
npm --prefix tools/fixtures/llm run generate
npm --prefix tools/fixtures/llm run check
```

`generate` writes `shared/fixtures/llm/*.json` and removes stale JSON there.
`check` regenerates into an OS temporary directory, compares filenames and exact
bytes, reports the first differing line, and cleans up even on failure. Neither
mode writes outside its output directory, apart from `check`'s temporary files.

- `reference.mjs`: exact integer `toFixed1`, transcript/string helpers, entry
  preparation, snapping, clip finalisation, window packing, schema validation,
  and the M2 cut-only verifier.
- `requests.mjs`: data-driven request text and all nine connector renderers,
  token budgets, Apple logical schema mapping and Codex TOML escaping.
- `vectors.mjs`: independently transcribed §13.2–§13.6 expectations, synthetic
  transcript recipes and the specified deterministic PRNG.
- `gen.mjs`: fixture cases, self-checks, serialization and byte-diff checks.

Inputs are the worktree's `shared/prompts/{clip-finder,ai-tighten}.json`,
`shared/catalog/llm-providers.json`, and the existing editing fixture
`shared/fixtures/editing/pauses/label-to-fixed.json`. Prompt/catalog SHA-256s are
recorded in every output after normalizing source-file CRLF to LF; there are no
absolute checkout paths or timestamps. Scoped `.gitattributes` files pin both
generator sources and golden outputs to LF on Windows checkouts as well.
During initial implementation these inputs and the specs were checked against
the current main checkout; later runs always use their own checkout.

Both modes fail before writing if any normative F1, rounding/time, C1–C3,
S1/M1/N1/W1, or T1–T8 vector differs. Integer rounding is additionally checked
against Node's `toFixed(1)` for the stored 100,000-value corpus and 200,000
wide-exponent binary64 bit patterns. The implementation never calls `toFixed`;
only this independent test oracle does. Shared schemas are validated and CLI
flags, token caps, caching and TOML escaping have additional self-checks.

See `shared/fixtures/llm/README.md` for the wire format, app-test loading rules,
synthetic input recipes and documented resolutions of underspecified edges.
Change the generator, never the golden JSON by hand; review regenerated diffs.
