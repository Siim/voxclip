# CLI output parity fixtures

Both native CLI test suites read `find-clips.json`. `result.expected` is the complete
successful JSON object, with a fixed run ID and timestamp supplied to the production
result serializer. `dryRun` invokes the real command on the shared project without
provider calls and checks the complete top-level key set, prompt count and string
field types. Neither form permits a `result` wrapper.

`version` is the build's own version string, so no expected object pins it (release.md
§1 keeps the version in Info.plist and Directory.Build.props only). `result.expected`
is the complete object without `version`; both suites check that `version` is present
as a non-empty string.

These expected values are hand-authored, not generator output. They may be edited by
hand when the CLI contract changes, with the reason recorded here and in AI §10.4.
The initial cases pin architecture §9's flattened object convention, including
explicit null instructions/language, an empty clip list, and rendered dry-run prompts.
The canonical media E2E fixtures and their ten-report comparison remain unchanged.
