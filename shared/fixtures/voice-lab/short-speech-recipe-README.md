# Short-speech recipe evidence

`short-speech-recipe-cases.json` is a hand-authored, synthetic reader/render corpus
with schema id `voxclip-voice-lab-short-speech-recipe-cases/1`. It does not add keys
or cases to any existing twin fixture. Changes to these vectors require review as
wire or validation behavior changes; update `caseCount` with the cases.

For each case, load `baseProject` from this directory, set `schemaVersion` to 3
and then 4 in separate replays, merge `qa` into the first segment's first
candidate's `recipe.qa`, and copy that recipe's `speakerScore` into the segment's
`qa.speakerScore`. Leave every other value unchanged. `error: null` means read,
validate, serialize/read again and prepare the full render successfully. Otherwise
the project reader must refuse it. Windows reports the named Core error; Swift
keeps its native project-unreadable, QA-rejected or invalid-segment taxonomy. `schemaValid` separately
records JSON Schema acceptance: cross-record identity and render policy require
runtime checks and cannot be inferred from schema acceptance alone.

Pooled evidence keeps measured QA. Unmeasured evidence has no score and explicitly
sets `speakerPassed: false`; both consent methods and the 48,000-frame boundary
are covered. Explicit null, malformed keys/enums/counts, mismatched records and
invented measurements are refused. Legacy QA still omits `shortSpeech` entirely.
The base project deliberately has a deleted voice reference: stored consent
evidence must remain renderable without a live provider or active clone.

Windows `VoiceLabShortSpeechRecipeTests` replays all 27 cases for both project
versions and adds typed-input shape/render guards. Python
`tools/schemas/test_short_speech_recipe_schema.py` checks the same 54 schema
outcomes. Swift `VoiceLabShortSpeechRecipeTests` replays the same 54 accept/refuse outcomes,
accepted round trips, render preflight and disclosure after ADR-R37 integration.

These vectors do not change Windows take generation, native speaker verification,
provider requests, disclosure writing or native audio/video rendering capability.
