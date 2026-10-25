# Windows editing verification

Run from `apps/windows` with the .NET 10 SDK and the repository shared assets.
Python 3 with `jsonschema` and `referencing` is a required test prerequisite,
not a Core dependency. Install those existing schema-tool prerequisites into
your test environment before running the suite.

```sh
VOXCLIP_SHARED_DIR=/path/to/voxclip/shared timeout 1200 dotnet test --project tests/VoxClip.Core.Tests -c Release
VOXCLIP_SHARED_DIR=/path/to/voxclip/shared timeout 1200 dotnet test --project tests/VoxClip.Core.Tests -c Debug
timeout 1200 dotnet build VoxClip.CrossPlatform.slnf -c Release
```

The default suite always runs the real Draft 2020-12 writer validation, with
no extra filter or opt-in. It uses `python3` on macOS and `python` on Windows.
Set `VOXCLIP_SCHEMA_PYTHON` only to select another prepared interpreter. A
missing interpreter or missing validator dependency fails the test; it never
silently skips schema conformance. Validator subprocesses have a 60-second
deadline and are terminated on cancellation.

All 85 editing fixtures are discovered: 84 normative vectors run and the
informative caption-transform vector is explicitly skipped, per editing
§11.1. Four other-track placeholders remain outside this track. The real
Windows file-sharing test runs only on Windows; injected Win32 replacement
faults run on every host.

Regression coverage includes strict UTF-8 and optional static-warning callbacks,
sparse settings and per-key recovery, first-write retry/backoff, under-limit
orphan retention, parent-relative media links, platform-independent Windows
probe allow-list checks, no-op/500-step undo, AI-reference validation and silent
derived-plan normalization on construction, copies and decoding in Debug and
Release. The generated
`fades/one-sample-zero-fade` vector covers the empty edge-join list.

`dotnet build -c Release` selects the full Windows solution. On macOS use
the cross-platform solution filter because WinUI requires Windows.

## Native Windows verification

For remote builds, set `VOXCLIP_WIN_HOST` to `<vm-user>@<vm-host>` and
`VOXCLIP_WIN_BUILD_DIR` to `<track-checkout>`. Connect using that host variable
and run from the track checkout on Windows, with .NET 10 and the same Python
schema prerequisites. Follow the maintainer's shared VM locking procedure;
never run concurrently with another track's native build.

```powershell
Set-Location "$env:VOXCLIP_WIN_BUILD_DIR\apps\windows"
dotnet test --project tests\VoxClip.Core.Tests -c Release --filter FullyQualifiedName~AtomicFileTests
```

Recovery-write failures use injected file operations on every host: valid
preferences remain pending, repeated loads create no further damaged copies,
and flush or a later save retries safely. Real NTFS sharing tests require Windows.
