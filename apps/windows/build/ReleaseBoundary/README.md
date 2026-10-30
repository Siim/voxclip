# Release boundary checker

A dependency-free .NET console tool that inspects shipping Release assemblies and
fails on anything that is not explicitly approved: test fakes, stand-ins,
harnesses, probes, seams and hooks under any name, DEBUG-only members, and
`VOXCLIP_DEBUG_*` or other switch-like strings. It reads PE metadata, IL and the
portable PDB only; it never loads or runs the inspected code.

## Where it runs

- **Windows CI, the guarantee.** `Inspect shipping Release assemblies (win-x64)`
  and `(win-arm64)` run immediately after `Build WinUI app (win-x64)` and
  `(win-arm64)`. `build/Test-ReleaseBoundary.ps1 -RuntimeIdentifier <rid>` asks
  MSBuild for that build's exact `TargetPath`, then runs
  `ReleaseBoundary check <rid> <VoxClip.dll>`. The check inspects `VoxClip.dll`
  and the `VoxClip.Core.dll` and `VoxClip.Media.dll` beside it. It requires
  Release, optimized code, matching PDBs and the RID's architecture for the App.
  `Upload shipping Release inspection inventories` keeps every inventory, the
  exact candidate allowlists and a summary as `windows-release-boundary-inventories`,
  even when the check fails.
- **macOS, a fast precheck only.** The Release UI tests run
  `ReleaseBoundary precheck` on the typecheck surrogate
  (`VoxClip.WinCheck.dll`, built with `UseWinUI=false`). It must match the
  allowlists exactly, stale lines included. It cannot satisfy the shipping check,
  which rejects any assembly not named `VoxClip`.

## What is inventoried

Every type, method (with access and parameter types), field, custom attribute
on types and members, assembly attribute and string literal (user strings, string
constants, attribute arguments). Each record is classified by origin:

- **Hand-written** code has a PDB document in the repository outside `obj/` and
  `bin/`. Every hand-written type, member, attribute-tagged member and
  `InternalsVisibleTo` grant must appear in `allowlist/<Assembly>.txt`. So must
  every switch-like literal: environment-variable shaped (`UPPER_SNAKE`),
  command-line shaped (`-x`, `--name`) or containing `VOXCLIP_`.
- **Toolchain output** (WinUI XAML compiler `.g.cs`, CsWinRT and other source
  generators, Windows App SDK auto-initializer sources) is recorded as evidence
  and needs no entry. Its classification comes from PDB documents, from
  `GeneratedCode` on members the XAML compiler emits without bodies, from fields
  that only toolchain code uses, and from body-less nested interfaces implemented
  only by toolchain types. Without a matching PDB nothing counts as toolchain
  output, so the check fails closed.
- **Forbidden** content can never be approved, even if an allowlist names it:
  any `VOXCLIP_DEBUG` string and any `[Conditional("DEBUG")]` member.

Compiler-generated closures, state machines and anonymous types are not listed
separately. Their literals are attributed to the method they came from.

Known shipping diagnostics are explicitly listed rather than exempt: the
`--transcript-frame-probe` Release frame-time diagnostic (`TranscriptFrameProbe`),
`--self-check`, the caption `MediaStandIn` domain type and the Core and Media
`InternalsVisibleTo` grants for their own test projects.

## Updating an allowlist

When a check fails, its output lists every `UNAPPROVED` line with the source
file it came from and names the allowlist file. If the change is an intended
product change, add exactly those lines (keep the file sorted) or regenerate the
file and review the diff. From the repository root:

```text
dotnet run --project apps/windows/build/ReleaseBoundary -c Release -- update <Release assembly> apps/windows/build/ReleaseBoundary/allowlist/<Name>.txt
```

On macOS, build the Release UI tests (or the Release typecheck project) and use
`apps/windows/tests/VoxClip.App.TypeCheck/bin/Release/net10.0-windows10.0.26100.0/`
`VoxClip.WinCheck.dll` for `VoxClip.txt`, and the `VoxClip.Core.dll` and
`VoxClip.Media.dll` beside it for the other two files. `update` refuses Debug
builds and forbidden content. Delete `STALE` lines for code that no longer ships.
A fake, harness, probe, seam or test hook must instead move under `#if DEBUG` or
into a test project; never allowlist it.

`describe <assembly>` prints every record with its origin and evidence.

## Tests

`ReleaseAssemblyInspectionTests` (UI test project, window-free) builds real
compilations of `tests/ReleaseBoundaryFixture` before compiling. The `Clean`
variant must pass its checked-in allowlist exactly and its simulated XAML and
Windows App SDK output must need no entries. Each other variant must fail:
`StandIn` adds a `RewriteBackendStandIn` fake, `Hook` adds an internal test hook
field and method to an approved type, `DebugLiteral` adds a `VOXCLIP_DEBUG_*`
read, `Seams` adds a constructor seam, switch-like strings, a friend assembly and
a `[Conditional("DEBUG")]` member, and `DebugBuild` is a Debug compilation.
