# AGENTS.md

Guidance for everyone who changes this repository, people and coding agents alike. Read it before your first change.

VoxClip is an open-source (MIT) desktop clipper for talking-head video on macOS and Windows: import a video, transcribe it with word timestamps, cut by editing words, find clips with your own LLM, burn captions, export 16:9 / 9:16 / 1:1, and share. Two native apps (Swift/SwiftUI and C#/WinUI 3) share specs, data and golden fixtures, not code.

## Read first

1. [doc/architecture.md](doc/architecture.md): layout, module boundaries, media pipelines, concurrency, CLI, caching, errors, logging, updates.
2. [doc/design.md](doc/design.md) and [shared/design/tokens.json](shared/design/tokens.json): layouts, interaction, exact UI copy, tokens.
3. [doc/decisions.md](doc/decisions.md): locked decisions. Do not reopen them in code; propose a superseding ADR instead.
4. The topic spec for what you are touching (editing, captions, transcription, LLM connectors, Voice Lab) in `doc/spec/`, plus [doc/release.md](doc/release.md) and [doc/publishing.md](doc/publishing.md) when relevant.
5. [doc/plan.md](doc/plan.md): the M1 work tracks, which paths each track owns, and the API contracts between them.

## Layout

```text
apps/macos/     SwiftPM package: VoxClipCore, VoxClipMedia, VoxClip (app), voxclip-cli, tests; bundle.sh
apps/windows/   VoxClip.slnx: src/VoxClip.Core, VoxClip.Media, VoxClip.App (WinUI 3), VoxClip.Cli; tests/; build/
shared/         source of truth: design tokens, fonts, caption styles, prompts, schemas, model catalogue, fixtures
tools/          generators and checks (fixtures, fonts, tokens, version); nothing here ships
doc/            specifications
.agents/skills/ vendored design skills (see doc/design.md section 18); .claude/skills/ links to them
```

## Rules

1. **`shared/` is the source of truth.** Caption styles, prompts, schemas, fonts, tokens, the model catalogue and fixtures live only there. Never copy them into an app folder. Generated files (`Tokens.swift`, `Tokens.xaml`) are regenerated with `npm --prefix tools/design run generate`, never edited by hand.
2. **Fixtures must pass on both platforms.** A behaviour shared by both apps (edit plan, pauses, fillers, caption paging and layout, clip validation, redaction, version comparison) is tested against the same JSON fixtures in Swift and C#. Do not merge a change that passes on one platform only. Regenerate fixtures only with their generator (`npm --prefix tools/fixtures/editing run generate`) and review the diff as a behaviour change; hand edits to expected values are allowed only where the fixture's README says so, with the reason recorded there.
3. **No secrets, ever.** Never write API keys, tokens, passwords, signing credentials or the contents of any `.env` / signing env file into the repo, a log, a test, a fixture, an issue or a commit message. Refer to secrets by variable name and file location only. Apps store keys in the Keychain / DPAPI; the CLI and tests read them from VoxClip-specific env vars (`VOXCLIP_ELEVENLABS_API_KEY`, `VOXCLIP_ANTHROPIC_API_KEY`, `VOXCLIP_OPENAI_API_KEY`, `VOXCLIP_XAI_API_KEY`, `VOXCLIP_GEMINI_API_KEY`), never from the names the Claude Code and Codex CLIs read. Every log line goes through the redactor. Gemini keys go in the `x-goog-api-key` header, never in a URL.
4. **No GPL or proprietary code or assets.** Forbidden: x264, x265, GPL or non-free FFmpeg builds (`--enable-gpl`, `--enable-nonfree`), sherpa-onnx prebuilt binaries and espeak-ng, Arial Black or any proprietary or system font, models with non-commercial or unstated licences, code copied from GPL projects. Allowed: MIT, BSD, Apache-2.0, ISC, Zlib, MPL-2.0 (file-level), SIL OFL for fonts, CC-BY for models with attribution, and LGPL only as the dynamically linked FFmpeg on Windows. ADR-029 also permits only the pinned MinGW runtime's ZPL-2.1, David M. Gay/Lucent, getopt, Sun libm, musl and winpthreads terms with their required notices; this is not a general dependency licence allowance. Every new dependency, font, data file or model goes into the root `THIRD_PARTY_NOTICES.md` (the single notices file both apps ship) and About → Licences in the same change, with the exact licence text from the pinned package. Builds have licence gates (macOS `nm` check, Windows `avcodec_configuration()` check); keep them.
5. **Keep platform-native idioms.** macOS: Swift 6 language mode with strict concurrency, `@Observable` models on the main actor, actors for services, swift-testing, SwiftUI with AppKit where text or video need it, Liquid Glass on chrome only. Windows: async/await with `CancellationToken`, CommunityToolkit.Mvvm view models on the UI thread, `x:Bind`, WinUI controls (TitleBar, CommandBar, SelectorBar, InfoBar, ContentDialog), Mica. Do not imitate one platform on the other, and do not add a cross-platform UI layer or a shared native library. Share behaviour through specs and fixtures.
6. **Respect the module boundaries.** Core (Swift `VoxClipCore`, C# `VoxClip.Core`) is media-free and UI-free and has no third-party dependencies; `Domain/` is pure. Media depends on Core; UI and CLI depend on both. Never the other way round.
7. **Preview equals export.** Each platform has exactly one per-frame compose path (macOS `FrameCompositor`, Windows compose function) used by both preview and export. Never add a second caption renderer.
8. **Source word timings never change.** Edits are cut sets, corrections and the clip range layer. Segment kinds are explicit; never infer a kind from an id prefix.
9. **Use the copy in design.md exactly**, including the reassurance that media and edits are safe. Errors are inline, cancellation is silent, publishing calls are never retried automatically.
10. **Local never silently becomes cloud.** Nothing leaves the machine unless the user picked a cloud engine or connector. No telemetry of any kind.
11. **Specs change with the code.** If you change behaviour, a constant or a file format, update the spec in `doc/` in the same commit. Docs live in `doc/`; keep prose plain and direct.
12. **Reference code.** Porting from VoxConvo and Superscribe (same owner) is allowed, but never copy secrets, never copy Superscribe's Windows Python signing helpers, and keep everything MIT-compatible. Treat those repositories as read-only.

## Build and test

macOS app and Swift core (Xcode with the macOS 26 SDK or newer, Apple silicon):

```sh
cd apps/macos
swift build
swift test
swift run voxclip-cli version
./bundle.sh                 # ad-hoc signed VoxClip.app in dist/ (anyone)
./bundle.sh --sign-only     # maintainers: Developer ID signed, keeps camera/mic and Keychain grants
```

.NET core and caption renderer on macOS (.NET 10 SDK):

```sh
cd apps/windows                      # global.json here selects the SDK and the Microsoft.Testing.Platform runner
dotnet build VoxClip.CrossPlatform.slnf -c Release
dotnet test --project tests/VoxClip.Core.Tests -c Release
dotnet test --project tests/VoxClip.Media.Tests -c Release --filter "Category!=RequiresFFmpeg&Category!=RequiresWindows"
```

Windows (Windows 11, .NET 10 SDK, Windows SDK):

```powershell
cd apps\windows
dotnet test --project tests\VoxClip.Core.Tests -c Release
dotnet test --project tests\VoxClip.Media.Tests -c Release
dotnet build src\VoxClip.App -c Release -r win-x64 -p:Platform=x64 -m:1
dotnet build src\VoxClip.App -c Release -r win-arm64 -p:Platform=ARM64 -m:1
dotnet build src\VoxClip.Cli -c Release
```

Shared data and generators (Node 22):

```sh
npm --prefix tools/fixtures/editing run generate && git diff --exit-code   # fixtures must be unchanged (needs the VoxConvo reference, see its README)
python3 tools/captions/check_styles.py                         # caption styles valid (needs jsonschema)
python3 tools/schemas/validate.py                              # example projects (and settings files) match shared/schemas
npm --prefix tools/design run generate                         # tokens -> Tokens.swift / Tokens.xaml
tools/release/check-version.sh                                 # Info.plist and Directory.Build.props agree
```

End-to-end through the CLI (same flags on both platforms; see architecture.md section 9):

```sh
voxclip-cli --open shared/fixtures/media/fillers-chirp.mp4 --transcript shared/fixtures/media/fillers-chirp.transcript.json \
            --cut-fillers --export /tmp/out.mp4 --style vox-highlight --aspect 9:16 --json
```

Test environment variables: `VOXCLIP_DATA_DIR` (isolated settings, models, cache, logs), `VOXCLIP_SHARED_DIR` (path to `shared/`; fixture loaders take its parent as the repository root), `VOXCLIP_LOG_LEVEL`, and for the end-to-end suites `VOXCLIP_CLI` (absolute path of the CLI under test) and `VOXCLIP_E2E_OUT` (report directory; architecture.md section 9.5). Tests that call real providers or download models are opt-in (`VOXCLIP_LIVE_TESTS=1`, or the narrower switches a topic spec defines, such as `VOXCLIP_TEST_DOWNLOAD=1` in the transcription spec) and need the key env vars; otherwise they skip. Tests never read the Keychain or DPAPI.

Schema tests use `VOXCLIP_SCHEMA_PYTHON` to select a Python interpreter with `jsonschema>=4.18,<5`; Windows Store aliases do not count as an interpreter. Both Core CI jobs set `VOXCLIP_REQUIRE_SCHEMA_PYTHON=1`, so a missing validator fails the job. Local runs without that flag report an explicit prerequisite skip.

Caption timing and allocation checks are opt-in: `VOXCLIP_PERF_TESTS=1` and, for the C# renderer, `VOXCLIP_ALLOCATION_TESTS=1`. Timing acceptance requires an optimized build on a quiet host; a diagnostic run with `VOXCLIP_PERF_FORCE=1` is not acceptance evidence. See [captions.md section 16.8](doc/spec/captions.md#168-test-environment) for interpreter selection, golden output and the exact timing conditions. Keep live-provider and model-download switches disabled during these checks.

## Commits and pull requests

- One logical change per commit. Subject in the imperative, at most 72 characters ("Add join-fade tap to the composition builder"); the body says why, and names the spec or ADR it follows.
- Follow the repository owner's attribution rule in [CLAUDE.md](CLAUDE.md): commit messages and pull request descriptions carry no AI attribution (no `Co-Authored-By` trailer for any agent, no "Generated with" line).
- Never commit release artifacts (`.app`, `.dmg`, `.zip`, `Setup.exe`, `.nupkg`), models, caches, or media other than small synthetic fixtures (at most 2 MB each) under `shared/fixtures/`.
- CI (`.github/workflows/ci.yml`) must be green: the macOS job (Swift build and tests, .NET core tests on macOS, caption parity), the Windows job (.NET tests, WinUI builds for x64 and arm64) and the fixtures job (editing fixtures, caption styles, tokens, version, JSON validity, secret scan).

## Releases

Only maintainers release, locally: macOS with `apps/macos/bundle.sh --release`, Windows with `apps/windows/build/release-windows.sh` on the signing VM. Both upload to a draft GitHub Release that a human publishes. See [doc/release.md](doc/release.md). Never add signing secrets to CI or to this repo.

## Design skills

Project-local skills in `.agents/skills/` (licences in `.agents/THIRD_PARTY_NOTICES.md`, pinned in `skills-lock.json`, restore with `npx skills experimental_install`). For macOS UI work load `swiftui-expert-skill` and `macos-design-guidelines`; for WinUI work load `winui-design` and `winui-app`. Where a skill conflicts with `doc/design.md`, the spec wins.
