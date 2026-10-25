# Editing fixture generator

This generator writes `shared/fixtures/editing/<group>/<name>.json`, the golden vectors for [`doc/spec/editing.md`](../../../doc/spec/editing.md). It needs only Node 22.13 or newer. There is nothing to install: Node's built-in TypeScript type stripping (`module.stripTypeScriptTypes`) loads the VoxConvo reference.

The reference comes from `VOXCONVO_WEB_DIR` when that variable points at a vox-web checkout (`$VOXCONVO_WEB_DIR/src/utils/*.ts`), otherwise from the vendored copies in `reference/`. Either way each file must match the sha1 in `reference/manifest.json`. The vendored copies are published under the MIT licence by their author (`reference/LICENSE`); if they are ever removed from the repository, only `VOXCONVO_WEB_DIR` works, and CI then validates the committed fixtures without regenerating them (doc/architecture.md section 12).

```sh
cd tools/fixtures/editing
npm run generate   # write every fixture and delete stale ones
npm run check      # regenerate in memory; exit 1 if any committed file differs (for CI)
```

The generator refuses to run under a Turkish, Azeri or Lithuanian default locale, because the reference lower-cases with the host locale. It also runs self-checks before writing: `toFixed1` against JavaScript `toFixed` on 200,000 values, the EditPlan invariants on 300 random plans, VoxClip and VoxConvo session agreement when no clip is involved, and the fade gains against the reference renderer.

## Layout

| Path | Contents |
|---|---|
| `gen.mjs` | Every fixture definition and the write/check logic |
| `reference/*.ts` | Verbatim copies of VoxConvo's editing code (same author, vendored unmodified, MIT; see `reference/LICENSE`) |
| `reference/manifest.json` | Source path and sha1 of each vendored file; the loader refuses a mismatch |
| `lib/reference.mjs` | Loads the reference (from `VOXCONVO_WEB_DIR` or `reference/`): strips types, imports from `data:` URLs, applies the in-memory patches it asserts (exporting `cutRange`, stubbing `./videoJob`, a stub `AudioContext`, and changed constants for parameter fixtures) |
| `lib/voxclip.mjs` | The VoxClip-defined rules in JavaScript: range-layer session reducer, `cleanWords`, `tightenIntoSound`, `findUnlabeledSpeech`, the import pipeline, project plans, and the VoxConvo session reducer used for comparison |
| `lib/audio.mjs` | The `vox-take-v1` synthetic audio generator |
| `lib/format.mjs` | Deterministic JSON formatting (two-space indent; short arrays and objects inline) |

## Changing behaviour

1. Change the spec first.
2. For a VoxClip rule, change `lib/voxclip.mjs` or the fixture inputs in `gen.mjs`. For a VoxConvo update, copy the new file from a committed VoxConvo revision into `reference/`, update its sha1 in `manifest.json`, and record that commit in `copiedFrom`.
3. Run `npm run generate`, review the fixture diff as a behaviour change, and update both core libraries in the same change.

Never edit files in `shared/fixtures/editing` by hand.
