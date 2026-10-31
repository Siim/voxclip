# Release boundary checker

A dependency-free .NET console tool that inspects shipping Release assemblies and
fails on anything that is not explicitly approved: test fakes, stand-ins,
harnesses, probes, seams and hooks declared as types or members under any name,
DEBUG-only members, and `VOXCLIP_DEBUG_*` or other switch-like strings. It reads
PE metadata, IL and the portable PDB only; it never loads or runs the inspected
code.

## Where it runs

- **Windows CI, the guarantee.** `Inspect shipping Release assemblies (win-x64)`
  and `(win-arm64)` run immediately after `Build WinUI app (win-x64)` and
  `(win-arm64)`. `build/Test-ReleaseBoundary.ps1 -RuntimeIdentifier <rid>` asks
  MSBuild for that build's exact `TargetPath`, builds the Release CLI for the
  same RID (`voxclip-cli.dll` ships in the same installer payload), then runs
  `ReleaseBoundary check <rid> <VoxClip.dll> <voxclip-cli.dll>`. The check
  inspects `VoxClip.dll`, the `VoxClip.Core.dll` and `VoxClip.Media.dll` beside
  it, and the CLI. It requires Release, optimized code, matching PDBs and the
  RID's architecture for the App. Every allowlist must match exactly: unapproved,
  forbidden and stale lines all fail. Any other managed DLL in either folder
  whose PDB names repository sources fails as `UNLISTED`, so a new first-party
  reference cannot ship unchecked. `Upload shipping Release inspection
  inventories` keeps every inventory, the exact candidate allowlists and a
  summary as `windows-release-boundary-inventories`, even when the check fails.
- **macOS, a fast precheck only.** The Release UI tests run
  `ReleaseBoundary precheck` on the typecheck surrogate
  (`VoxClip.WinCheck.dll`, built with `UseWinUI=false`), the Core and Media
  assemblies beside it and the portable Release CLI. It must match the
  allowlists exactly. It cannot satisfy the shipping check, which rejects any
  App assembly not named `VoxClip`.
- **Not covered:** the release VM's own `dotnet publish` tree
  (`vm-release.ps1`) is not inspected. The CI builds above compile the same
  sources with the same settings.

## What is inventoried

Every type, method (with access and parameter types), field, custom attribute
on types and members, assembly attribute and string literal (user strings, string
constants, attribute arguments). C# `file` types are inventoried under a
canonical name, `<File>F#__Name`: the checksum Roslyn embeds depends on the
checkout path. Each record is classified by where it is declared:

- **Hand-written** code has a PDB document in the repository outside `obj/` and
  `bin/`. Every hand-written type, member, attribute-tagged member and
  `InternalsVisibleTo` grant must appear in `allowlist/<Assembly>.txt`. So must
  every switch-like literal: environment-variable shaped (`SNAKE_CASE` in any
  case), command-line shaped (`-x`, `--name`, `/name`), containing `VOXCLIP_` in
  any case, or passed to `Environment.GetEnvironmentVariable` or
  `SetEnvironmentVariable` whatever its shape.
- **Source generators that implement hand-written declarations.** Members that
  CommunityToolkit.Mvvm (`[ObservableProperty]`, `[RelayCommand]`),
  `[GeneratedRegex]`, `[LibraryImport]` or any other generator adds to a
  hand-written type need approval, like the hand-written field or attribute that
  drives them. Types such a generator declares entirely by itself (for example
  the MVVM argument caches and the Regex runner types) are toolchain output.
- **Toolchain output** is recognised positively and needs no entry: repository
  `obj/` and `bin/` documents outside a source generator folder (the WinUI XAML
  compiler and MSBuild), System.Text.Json and CsWinRT generator documents, and
  NuGet package sources (the Windows App SDK auto-initializers). A
  `GeneratedCode` tag counts only when the XAML compiler wrote it on a field or
  body-less nested type of a type that has `obj/` XAML output. A field of a
  hand-written type is toolchain output only when System.Text.Json or CsWinRT
  generated code alone uses it. Body-less nested interfaces implemented only by
  toolchain types are toolchain output too. Code whose every sequence point is
  `#line`-mapped to a non-C# file (such as a `.xaml` file) counts as XAML output
  only in a type that has `obj/` XAML output; elsewhere it is unrecognised.
- **Unrecognised documents** (outside `--repo-root` and the NuGet root, for
  example after `-p:PathMap` or with a symlink spelling of the root) are treated
  as hand-written and fail the identity check, as does an assembly with no
  hand-written type. Without a matching PDB nothing counts as toolchain output.
  The check fails closed in every case.
- **Forbidden** content can never be approved, even if an allowlist names it:
  any `VOXCLIP_DEBUG` string in any case and any `[Conditional("DEBUG")]` member.

Compiler-generated closures, state machines, lambdas, local functions and
anonymous types are not listed separately. Their literals are attributed to the
method they came from. A change inside the body of an approved member is caught
only through what it introduces: switch-like or environment-name literals,
forbidden strings, and new types, members or attributes. Compiler bookkeeping
attributes (`Rules.BookkeepingAttributes`, such as nullability and state-machine
tags) are skipped.

Known shipping diagnostics and test seams are explicitly listed rather than
exempt. They are reviewed and grandfathered:

- the `--transcript-frame-probe` Release frame-time diagnostic
  (`TranscriptFrameProbe`), `--self-check`, and the caption `MediaStandIn`
  domain type;
- the `InternalsVisibleTo` grants from Core and Media to their test projects,
  from Media to `voxclip-cli`, and from the CLI to `VoxClip.Media.Tests`;
- Media test seams that the Release Media tests need: `FfmpegLoader.RootOverride`
  (the native tests point it at the pinned test FFmpeg), the internal
  `PreviewEngine` constructor's `clockOverride` (preview liveness and Voice Lab
  mixer tests), and the internal `SkiaCaptionRasterizer.TestCheckpoint` and
  `TestOpacityBandReady` callbacks (caption opacity and render-state tests);
- the CLI's fixture options that the cross-platform CLI parity and E2E tests
  share with the macOS CLI: `--transcript`, `--audio-out`, `caption --case`,
  `--tiles` and `--sample`, and `transcribe --raw-out`.

New seams of this kind must not be added; they belong under `#if DEBUG` or in a
test project.

## Updating an allowlist

When a check fails, its output lists every `UNAPPROVED` line with the source
file it came from and names the allowlist file. If the change is an intended
product change, add exactly those lines (keep the file sorted) or regenerate the
file and review the diff. From the repository root:

```text
dotnet run --project apps/windows/build/ReleaseBoundary -c Release -- update <Release assembly> apps/windows/build/ReleaseBoundary/allowlist/<Name>.txt
```

On macOS, build the Release UI tests (or the Release typecheck project and the
Release CLI) and use
`apps/windows/tests/VoxClip.App.TypeCheck/bin/Release/net10.0-windows10.0.26100.0/`
`VoxClip.WinCheck.dll` for `VoxClip.txt`, the `VoxClip.Core.dll` and
`VoxClip.Media.dll` beside it for those two files, and
`apps/windows/src/VoxClip.Cli/bin/Release/net10.0/voxclip-cli.dll` for
`voxclip-cli.txt`. `update` refuses Debug builds, forbidden content and
unrecognised PDB documents. Delete `STALE` lines for code that no longer ships.
A fake, harness, probe, seam or test hook must instead move under `#if DEBUG` or
into a test project; never allowlist it.

`describe <assembly>` prints every record with its origin and evidence.

## Tests

`ReleaseAssemblyInspectionTests` (UI test project, window-free) builds real
compilations of `tests/ReleaseBoundaryFixture` before compiling. The `Clean`
variant must pass its checked-in allowlist exactly and its simulated XAML and
Windows App SDK output must need no entries. Each other variant must fail:
`StandIn` adds a `RewriteBackendStandIn` fake, `FileLocal` declares it as a C#
`file` type, `Hook` adds an internal test hook field and method to an approved
type, `Observable` adds one with CommunityToolkit.Mvvm's `[ObservableProperty]`,
`GeneratedTag` adds hooks tagged `GeneratedCode`, `DebugLiteral` adds a
`VOXCLIP_DEBUG_*` read, `LowerCase` reads debug and stand-in names in other cases
and checks a `/switch`, `Mapped` adds `#line`-mapped code outside XAML output,
`Seams` adds a constructor seam, switch-like strings, a
friend assembly and a `[Conditional("DEBUG")]` member, and `DebugBuild` is a
Debug compilation. `App` and `AppPathMap` compile the clean sources as an x64
`VoxClip.dll`: the shipping check must pass `App` with the real root and fail it
with another root spelling, fail the `-p:PathMap` build, fail stale lines and a
missing CLI, and fail an unlisted first-party DLL in the payload folder.
