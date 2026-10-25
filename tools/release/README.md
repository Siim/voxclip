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
`CFBundleVersion` once, and changes `<Version>` in `Directory.Build.props`.
Both files are validated and staged before replacement; XML formatting and
unrelated values are preserved. Binary plists are also supported. Versions are
`X.Y.Z` or `X.Y.Z-beta.N`, without leading zeroes in numeric components. The
checker exits 1 on mismatched or invalid versions and never changes either file.

Test the setter only in a temporary directory containing copies of these tools
and the two version files in their original relative locations. Do not bump the
real version files just to test this tooling.
