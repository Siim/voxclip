# Release version tools

These tools implement `doc/release.md` section 4, steps 1–2. Both shell entry
points run with bash 3.2 on macOS and bash on Linux; their only helper needs
Python 3.9 or newer from `PATH`, using standard-library plistlib and XML parsing.
Neither script uses PlistBuddy or edits a file outside this checkout.

```sh
bash tools/release/check-version.sh
tools/release/set-version.sh 0.1.1
tools/release/check-version.sh
```

The setter changes `CFBundleShortVersionString`, increments the integer-string
`CFBundleVersion` once when the version changes, and changes `<Version>` in
`Directory.Build.props`. Setting the version already in Info.plist keeps the
build number, so 0.1.0 stays build 1 and rerunning a release step never bumps
it twice.
Both files are validated and staged before replacement; XML formatting and
unrelated values are preserved. Binary plists are also supported. Versions are
`X.Y.Z` or `X.Y.Z-beta.N`, without leading zeroes in numeric components. The
checker exits 1 on mismatched or invalid versions, or production string literals
containing the current release version (release section 1), and never changes
either version file.

Run the regression suite with `python3 -m unittest discover -s tools/release -p
'test_*.py'`. It uses isolated copies under `/tmp/voxclip-sol-followups-3`.

Test the setter only in a temporary directory containing copies of these tools
and the two version files in their original relative locations. Do not bump the
real version files just to test this tooling.
