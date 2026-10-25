# Transcription fixtures

These fixtures are hand-written from `doc/spec/transcription.md` sections 16.1
and 16.2. They are small synthetic cases, not captures of customer audio or
live provider calls. No generator, API key or model download is required.

## Layout

- Word-assembly cases use `{name, rule, timelineStart, tokens, expect}`.
- Pipeline cases use `{name, derivation, audio, timing, verbatim, expectWords}`;
  existing audio-generator cases also live in `../editing/pipeline`,
  `../editing/tighten` and `../editing/gaps`.
- Every case has a `derivation` explaining the expected result from the spec.
- `elevenlabs/<name>.json` is the unwrapped recorded/synthetic HTTP 200 response
  body. Do not add test metadata to the provider body.
- `elevenlabs/<name>.expected.json` is its machine-readable outcome, with schema
  `voxclip-transcription-expected/1`, `derivation`, mapping option `diarize`,
  normalized `language`, and exact `rawTokens` using transcription section 3.2.
  Word tokens have `kind: null`; events have `kind: "event"`. Nullable token
  fields are explicit null, `joinsPrevious` defaults to false, and `group` to 0.
- An adapter expectation may provide `importError` (a stable `VoxClipErrorCode`)
  when mapped tokens must be rejected on import. `expectedUploads` counts
  uploads across one fresh import followed by one cached import.

| Response | Expected outcome | Derivation |
| --- | --- | --- |
| `elevenlabs/events-only.json` | `elevenlabs/events-only.expected.json`: one event, language `en`, import error `noSpeech`, one upload | Sections 3.2, 3.4 and 8.2: keep `(music)` as an event, normalize `eng` to `en`, but do not count events as words. Section 14.3 retains the paid response for reuse. |

## Updating a fixture

Hand edits are allowed. Change the response and its expected sidecar together,
derive every token/field and error code from the cited spec, and update the
sidecar's `derivation` plus this table with the reason. Never regenerate expected
values from the adapter under test or record credentials, personal media or
provider account data. Both the Swift recorded-response suite and the Windows
`VoxClip.Core.Tests` suite must consume the same response and expectation before
claiming cross-platform parity. A missing fixture is a reported skip, not a pass.
