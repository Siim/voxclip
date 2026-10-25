# win-ui contract notes

Date: 2026-10-25. The newest integration record is first; older VM connectivity
and blank-window entries below are retained as history, not current status.
This track does not change other tracks' declarations. The lead owns the root
`apps/windows/CONTRACTS.md` ledger; these notes are in the permitted track folder.

## Final native UI and publish check at `f357e32` (2026-10-25)

- A committed-HEAD archive built the app on Windows ARM64 in Debug and Release,
  and for x64 in Release. Both Release architectures also published. The three
  builds and two publishes completed with zero warnings and errors. No installer
  was built. The ARM64 companion's earlier native synthetic import/edit/save/
  reopen/full-and-clip-export flow remains 33/33 passed; these final capture and
  publish commands did not rerun that test or call a provider.
- At the final ledger update, the Mac portable Release solution built with
  zero warnings/errors and the focused UI companion passed 32/32, excluding its
  Windows-only native flow. These checks ran against `f357e32` plus this note.
- The latest exact-process, matching-window capture set is
  `/tmp/win-ui-shot-7703257C-675D-41AD-B5A8-D148D560686D/`. Its compact
  JPEGs were individually inspected for Home, editor caption gallery, Clips,
  export, Settings General/Providers and Keys/Local Models/Export/Accounts/
  About, all three onboarding steps, dark Settings/editor and Release Home.
  Both editor and Settings UI Automation exercises exited successfully. Step 2
  shows “Choose a connector…” with Continue disabled; the harness asserts that
  state before advancing with “Not now.” These are synthetic fixture UI captures,
  with no speech or provider success implied.
- The same evidence folder retains `win-arm64.json` and `win-x64.json` complete
  SHA-256 publish manifests and `selected-runtime.tsv`, which matches selected
  Windows App SDK, Windows ML and WebView2 files to their NuGet source packages.
  `payload-summary.md` gives the concise file counts, representative hashes and
  licence classes: ARM64 has 738 published files (416,332,275 bytes), including
  144 exact package matches (132,769,128 bytes); x64 has 742 (399,971,196
  bytes), including 148 matches (126,690,101 bytes). Selected files include
  `DirectML.dll`, `onnxruntime.dll`, Windows AI/Search/Widgets binaries and
  `WebView2Loader.dll`. Windows ML terms and third-party notices include Intel
  MKL, although no published filename contains `mkl`. The app already loads
  bundled root notices in About; this track did not edit those notices.
- `Microsoft.WindowsAppSDK` 2.5.1 directly depends on AI/ML/Search/Widgets.
  The ML targets copy RID native files for self-contained builds;
  `DisableWindowsAppSDKMLAutoInitialize` does not prune the dependency, and
  passthrough ONNX mode conflicts with `WindowsAppSDKSelfContained=true`. No
  documented safe property to omit just the unused AI/ML payload was found.
  Package selection and native-runtime licence decisions remain with the lead;
  no package pins or selected runtime binaries were changed.
- The run's owner-tagged VM scratch peaked at 0.85 GiB, with free C: no lower
  than 7.57 GiB. It removed only its own scratch and owner lock; the final
  check found neither remaining. This satisfies the VM's 2 GiB scratch budget
  and 6 GiB free floor. The 15 GiB floor applies to the Mac FFmpeg cross-build.

## M1 integration after the reviewed merges (2026-10-25)

- Exact merge pins on this branch: main `e3d4548` (`dc84907` merge), media
  `813b3d209304a4f1ba0b0570b0ce84cecda0b455` (`eabbd11` merge), and
  captions `86418be2949bc43a63c3c675de16205b8c427436` (`9fcfa7d` merge).
  The root ledger kept the editing, media and caption entries, including the
  caption `WordHints` public API. No renderer fork, production friend grant,
  colour threshold or encoder tuning was added.
- App composition uses `SecretStore` through the landed `ClipFinder` and
  `TranscriptionService` constructors. Provider status, key save and explicit
  connection tests use catalogue connector IDs. Home recents read project
  duration/date and request Windows thumbnails, with a working context menu.
  The Clips pane groups connectors, shows status, offers inline DPAPI key entry,
  and has Custom instructions, progress and cancellation. No real provider
  success is fabricated.
- Gallery tiles build each style's `preview.text` in English at its specified
  active time via public `CaptionEngine.BuildAsync` and the shared
  `SkiaCaptionRasterizer`; the first preview frame supplies the background.
  Ordinary project preview/export still use the project transcript language.
  The optional `CaptionLayoutRequest.WordHints` API is available for manual
  source-word emphasis/emoji, but M1 has no manual word-choice control to
  populate it. Export captions and SRT share the same scoped `CaptionTrack`.
- The three-step onboarding now configures local or ElevenLabs routing and
  language, lists local models with their licence and explicit install action,
  and offers optional grouped AI connector choice, secure key save, status,
  connection test and data-flow consent. New imports enter the transcription
  sheet and start local transcription when a compatible verified local model
  is installed. Cloud transcription remains an explicit per-take action with
  key and audio-upload confirmation; its checkbox starts clear for every take.
  Changing the ElevenLabs residency region recomposes the speech service for
  subsequent takes while keeping an in-flight transcriber alive until shutdown.
  No model was downloaded in verification.
- `ExportSelection.Scope` clears an active clip for Full edit and selects the
  requested clip for clip jobs before planning captions and SRT. The companion
  test protects this against an active-clip leak. The real native synthetic
  service-flow test probes and keys a committed 2-second video, injects a
  synthetic transcript without speech/provider calls, cuts a word, makes a
  manual clip, saves and reopens, then exports full and clip MP4+SRT through
  the shared caption renderer. ARM64 result: 33/33 companion tests passed,
  zero skips/failures; full 1.59 s, 3 caption words, 48,030-byte MP4;
  clip 1.07 s, 2 caption words, 25,156-byte MP4. The reopened project
  retained one cut. Evidence:
  `/tmp/win-ui-flow-BC3AB240-5BDE-4456-A212-8341C6342235/native-integrated-flow.json`.
  The test-only FFmpeg ZIP matched the requested SHA-256 and was unpacked
  solely beside the native test executable in owner-tagged VM scratch; that
  scratch and lock were removed after the run.
- Mac portable Release solution build passed with zero warnings/errors.
  The UI companion passed 32/32 locally with the native-only test filtered.
  From committed `8a9f22a`, native Debug ARM64 and Release ARM64/x64 app builds
  each passed with zero warnings/errors. Exact-window Debug captures of Home,
  editor with renderer-backed caption tiles, Clips, the export sheet, Settings
  General/Providers/Local Models/Export/Accounts/About, all three onboarding
  steps, and dark Settings/editor were individually inspected. Release ARM64
  Home was also inspected. UI Automation confirmed the gallery radio semantics,
  export opening, Clips presence, Settings pane selection, onboarding step
  advancement/Skip and appearance change; both exercises completed without
  error. The matching process/window self-checks and compact JPEGs are under
  `/tmp/win-ui-shot-29B034D2-E02F-4553-891A-2C570395F0B1/`. These are
  fixture UI captures, not proof of a real provider call or speech recognition.
  The owner-tagged VM scratch peaked at about 0.47 GiB, free C: remained above
  7.9 GiB, and the run removed its own scratch and lock.
- Full Narrator announcements, keyboard-only end-to-end operation, High
  Contrast, RTL, 100%/150% text and desktop scaling, light/dark comparison,
  preview latency and memory budgets, local model transcription quality, real
  provider calls and rebuilt shipping-runtime validation remain hardware or
  external-service acceptance work. The win-media `e2e-8-bars` blue-channel
  tolerance failure remains parent-owned and unchanged.

## VM round-two handoff (2026-10-25)

Status: **partial verification; VM connectivity failed before completion**.

- Native ARM64 and x64 Release builds passed with zero warnings/errors after
  `91ef4ae` corrected the PRI guard. ARM64 Debug also passed after `710675e`
  added exact-window readiness metadata. The subsequent caption-radio and token
  surface fixes (`bfd10c4`, `c0c71b7`) still need a native rebuild and capture.
- Home and editor were individually inspected as JPEGs: neither is blank.
  All three baseline probes returned `ready`, `rootLoaded=true`, `rendered=true`,
  at a 640×400 probe target (Home reported height 401). A ready Settings root
  did not prove the image was correct: its first capture was the inactive editor.
  That image is explicitly rejected, not evidence of Settings verification.
- Evidence is in `/tmp/voxclip-win-ui-r2/`: `home-window.jpg`,
  `editor-window.jpg`, `rejected-settings-wrong-window.jpg`, the three
  `*-self-check.json` reports, `startup.log`, build logs and Mac validation logs.
  All retained JPEGs were opened with the image-reading tool. The directory is
  about 304 KB before the final handoff logs; no local source tarballs remain.
- The expanded capture pass completed its editor/export-shortcut/Clips stage
  and Home stage, then stopped answering SSH during Settings at 10:25 UTC.
  New dialog/pane images and interaction reports could not be fetched or
  inspected. Do not claim their visual verification or infer why the VM failed.
- At 10:39:08 UTC SSH reported `No route to host`; the owner-checked cleanup
  attempt at 10:39:26 UTC reported `Host is down` (exit 255). The capture SSH
  command reached its 510-second timeout (exit 124). VM task/process cleanup and
  **lock release could not be confirmed**. The lock was created by this round:
  `C:\voxclip-build\vm.lock`, owner
  `win-ui-r2-20261025-5344ec10-1d18-42ca-b880-15beb3353b26`.
  The lead must restore connectivity and reconcile this owner before reuse.
  No foreign lock was removed or taken over.

### Gap-list disposition

1. **Home recents/model status:** thumbnails, duration/relative-date metadata,
   row context menu and richer model readiness remain unfinished. The inspected
   Home capture has the correct empty state, not populated-recents coverage.
   This round cannot verify additional changes while the VM is down.
2. **Captions:** clipped selection labels were replaced with wrapping native
   radio choices and an explicit Caption style group. The UIA exercise now
   checks radio roles and fixture selection, but needs rerunning with the new
   UI. Actual thumbnails still depend on the shared caption renderer; no second
   rendering path was added.
3. **Clips/export:** Ctrl+E and Clips navigation completed in the expanded
   interactive pass, but their images were not recovered. Full grouped
   connector/status/inline-key UX, exact Custom/loading copy and renderer-backed
   export thumbnails remain unfinished. Live provider/engine seams remain
   producer-owned; no credential or network operation was tested.
4. **Onboarding:** all three current copy steps and Skip have bounded UIA
   exercises, but their VM run/images remain unverified. The full engine,
   language/model and optional connector controls from design §9 remain absent.
5. **Accessibility/appearance:** opaque editor surfaces now consume the
   canonical theme brushes, and caption selection has native radio semantics.
   Their final light/dark captures remain pending. High Contrast, RTL, explicit
   100%/150% desktop/text scaling, spoken Narrator states/announcements, pane
   focus, transport shortcuts, correction placement and keyboard-only end-to-end
   flow were not verified. The harness records rasterization scale but does not
   change the VM's system scaling or contrast settings.
6. **Fixed contracts:** playback-rate cycling, preview buffer lifetime and app
   key injection remain the existing cross-track proposals below. No producer
   declaration or persisted schema was changed by this round.

### Local verification and recovery

- Mac cross-platform Release build: zero warnings/errors. Filtered solution
  tests: 24 passed, 4 existing placeholders skipped, zero failed. UI companion:
  31 passed, zero skipped/failed, including exact-window metadata serialization.
  The WinUI build fails with the expected macOS `NETSDK1100` limitation.
- `bash -n` passes for the VM wrapper. Three fake-SSH checks passed: owned lock
  cleanup, refusal to clean another owner's lock, and reconciliation of an
  uncertain successful acquisition reply. Test scratch was deleted.
- After the lead reconciles the outstanding lock, rerun
  `verify-windows.sh All win-arm64 shots`, then a separate
  `verify-windows.sh Release win-arm64 shots` for the non-demo Release smoke
  probe. Preserve the first pass's evidence before the second clears old shots.
  Inspect every new JPEG before accepting it. The wrapper uses unique owner
  markers, bounded commands and committed-source streaming, and copies compact
  JPEG/report/log evidence rather than desktop PNGs or source tarballs.

## Startup investigation (second resume, 2026-10-25)

The three previous `*-window.png` files in `/tmp/clipper-planning/win-ui-shots`
were inspected individually. All show a white client area and native caption
buttons, with no Home, editor, custom title bar or Settings content. The previous
`error.txt` reports unchanged navigation. This is not successful UI verification.
Until Windows can be inspected, candidates are ranked, not confirmed causes:

1. **Missing compiled XAML/PRI payload.** `VoxClip.App.csproj` specified
   unpackaged, self-contained deployment and SDK BuildTools but omitted
   `EnableMsixTooling`. There was no output check for `resources.pri` and no
   assertion that `InitializeComponent` actually assigned MainWindow's content
   and named controls. Enable the tooling explicitly, keep packaging disabled,
   fail the build if PRI is absent, and fail startup if the root is missing.
   Inspect the rebuilt output and probe on Windows to confirm or reject this.
2. **Unreported resource/XAML/startup exception.** `Program.Main` had no exception
   logging; App constructed resources without an UnhandledException handler;
   settings initialization and `NewWindow` were outside OnLaunched's try block.
   Tokens and HelperText depend on merged resources. The new process and XAML
   handlers log exception types/HRESULTs and XAML/resource detail through the
   existing redactor and flush on failure. They do not suppress fatal exceptions
   or log arbitrary engine/provider exception messages or file contents.
3. **Capture before a valid first frame, or the wrong screen.** The prior capture
   waited 45 seconds but only tested process responsiveness, which does not
   prove XAML loaded. A normal native window can exist before any root renders.
   `--self-check [report.json]` now checks loaded root, nonzero layout, a rendering
   callback and nonuniform BGRA RenderTargetBitmap content; requested Home/editor
   identity must match the actual Frame. It atomically reports process ID,
   screen and readiness metadata only. No path writes to a project or fixture.
4. **Theme resolution or content/activation ordering.** App.xaml already loads
   XamlControlsResources before Tokens; MainWindow sets content in
   InitializeComponent and populates Home before Activate. There is no code
   evidence that moving content assignment after activation is necessary.
   Do not reorder it speculatively. Light/dark/high-contrast rendering still
   requires Windows verification.

The screenshot harness runs with an isolated `capture-data` root, requires the
matching process/screen self-check, samples the captured client interior for
blankness before saving, and discards duplicate navigation captures. Both
interactive task failures and parent-runner failures write `error.txt` and fail.
The VM archive includes the redacted `startup.log` and self-check JSON. The
normal app log remains `<data>/Logs/voxclip.log`; no telemetry is added.

New contract proposals: none. Lead-owned documentation should incorporate this
diagnostic switch and findings after Windows verification; this track cannot
edit `doc/`. The Windows SDK/XAML changes cannot be runtime-tested on macOS.

## Mac verification (second resume, 2026-10-25)

### VM verification round (2026-10-25)

The native ARM64 Release build produced compiled XBF files and `VoxClip.pri`,
but the new output guard incorrectly required `resources.pri`. The restored
WinUI targets use `TargetName` as the PRI index for an unpackaged managed app.
Check `$(TargetName).pri` instead; keep the missing-resource failure in place.
This build-time correction does not yet establish that the window renders.

The first Debug editor probe passed with a rendered 640×400 XAML root. Home's
probe failed because demo startup called the `async void` navigation handler
and immediately checked the still-open editor while preview teardown awaited.
Expose an awaitable Home transition and await it in demo startup; event handlers
retain their existing entry point. This is a readiness race, not a blank editor.

Visual inspection caught a false-positive Settings capture: title/z-order
selection saved the main editor even though the Settings root passed its probe.
Readiness reports now include the exact native window handle and rasterization
scale. Capture validates process ownership and raises only that window before
copying pixels. The metadata round-trip test covers 64-bit handles and 150% scale;
this is not a claim that the desktop itself has been tested at 150%.

The first visible editor capture also exposed clipped gallery selection labels
and system content fills in place of the design's opaque transcript/inspector
surfaces. Native wrapping radio choices now provide the named Caption style
group and selected-state semantics. The editor's content window and surfaces
consume the existing generated background brushes; native Mica/command chrome
and Fluent controls are retained. Renderer-backed thumbnails remain deferred.

From `apps/windows`, all commands were bounded with `timeout`:

- `timeout 240 dotnet build VoxClip.CrossPlatform.slnf -c Release -m:1`:
  passed, 0 warnings, 0 errors (Core, Media, CLI and both test projects).
- `timeout 180 dotnet test --solution VoxClip.CrossPlatform.slnf -c Release
  --no-build -- --filter 'Category!=RequiresFFmpeg&Category!=RequiresWindows'`:
  24 passed, 4 skipped existing non-UI track placeholders, 0 failed.
- `timeout 180 dotnet test --project
  tests/VoxClip.Core.Tests/Tracks/win-ui/VoxClip.Ui.Tests.csproj -c Release`:
  31 passed, 0 skipped, 0 failed, including four new startup probe regressions.
- `timeout 120 dotnet build src/VoxClip.App -c Release -r win-arm64
  -p:Platform=ARM64`: expected NETSDK1100 on macOS, 0 warnings; no Windows
  compilation or runtime success is inferred from the cross-platform checks.
- `bash -n .../verify-windows.sh` and `git diff --check`: passed.

Total executed tests: 59, with 55 passed and 4 existing skips. Logs are under
`/tmp/clipper-planning/win-ui-resume2/`. PowerShell is not installed on this Mac;
PowerShell parsing and WinUI compilation still need Windows.

## Remaining brief reconciliation (second resume, 2026-10-25)

Re-read the current main-checkout design sections for Windows layout,
transcript interaction, Home, inspector, export, onboarding, settings,
shortcuts, states, appearance and accessibility in bounded selections. No
main/shared/other-track files were changed and main was not merged.

Existing implementation retained, in the brief's order:

1. Home has Import/Open, recent-project navigation and drop handling. MainWindow
   uses Mica, TitleBar, back-to-Home and Settings, with explicit DPI-aware sizing.
2. Editor uses paragraph-virtualized ItemsRepeater/RichTextBlock/Run content,
   word-snapped selection, pause/cut/correction states, undo/redo and scoped
   shortcuts. View-model tests cover selection, manual clips without keys,
   source timing immutability, corrections, pauses, text focus and AltGr.
3. Preview consumes IPreviewEngine frames through a bounded presenter and
   WriteableBitmap, with timeline cuts, clip brackets and playhead. Demo fixtures
   use synthetic preview, do not autosave, and cannot export. Real engines remain
   owned by other tracks; their unavailability is not replaced with fake success.
4. Inspector contains caption style selection and clip presets/results/nudging;
   the future AI tab is disabled. Export has aspect/style/destination, clips,
   cancellation and post-export Explorer/copy/X/LinkedIn helpers.
5. Onboarding is a skippable three-step local-first tour. Settings has all six
   requested panes, DPAPI Save/Test/Forget, provider data-flow lines and CLI
   detection, model licence/download/remove controls, export defaults, the
   VoxConvo account placeholder, and notices/licences in About.
6. Secrets remain under the per-user Secrets root; logging uses redaction and
   rotating Logs; Velopack checks are non-blocking. No WebView2, WPF or WinForms
   references were introduced. The executable/window icon matches main's Windows
   icon byte-for-byte (SHA-256 starts `b3a5f92f244e9551`).
7. Claude Code and Codex are enabled in both this worktree's and main's shared
   provider catalogue. UI consumes those flags, so there is no disable gate to
   remove. CLI names remain plain provider labels/data-flow wording, not feature
   brands or logos. Preserve the amended ADR-R20 decision.

Deferred UI completion/verification, not claimed as finished:

- Home recent thumbnails, duration/relative-date metadata and row context menu;
  model status currently uses a generic missing-model notice.
- Actual caption thumbnails/radio-group narration (the gallery currently lists
  all available names and explicitly defers live previews to the shared renderer).
- Fully grouped connector/status/inline-key rows in Clips, exact Custom/loading
  copy, and renderer-backed export thumbnails; the existing controls are simpler
  than the complete design. Provider/engine integration needs the seams below.
- The tour does not yet contain the full engine/language/model and optional
  connector configuration from design section 9. Keep its local-first, skippable
  behavior; verify/finish the richer controls on an interactive Windows desktop.
- Theme/high-contrast and RTL/text-scaling review, word-level Narrator states and
  notification announcements, caption narration, pane focus, transport shortcuts,
  inline correction placement and keyboard-only end-to-end flow require GUI QA.
- Playback-rate cycling, preview buffer ownership and app key injection remain
  fixed-contract proposals, not unilateral changes to other tracks.

Per the second-resume instruction, GUI-dependent work is held for the Windows
verification step rather than changed without a working desktop. macOS app
notarization remains pending its locked-screen preflight; it was not retried and
is outside this Windows worktree's scope.

## Previously recorded integration proposals

| Boundary | Existing contract / limitation | Proposal and affected consumers | Evidence / migration |
| --- | --- | --- | --- |
| Preview frame lifetime | `PreviewFrame` contains a BGRA `PixelBuffer` but has no release callback or lease. | win-media and UI agree whether bytes remain immutable and valid after the next `ReadFramesAsync` iteration, or introduce a disposable frame lease. | Architecture §6.3 bounds the handoff queue. Current UI queues at most six frames, drops stale generations, copies rows into a `WriteableBitmap`, and never assumes it owns a native buffer. Add queue-drop/dispose tests when ownership is agreed. No JSON change. |
| Playback rate | `IPreviewEngine` has play/pause/seek, but no rate setter. | win-media: add a cancellable rate setter, with position/rate reporting. | Design §11 requires L cycling 1×, 1.5×, 2× and K resetting speed. UI currently plays at 1×; J seeks back three seconds. No persisted change. |
| Preview sizing | Snapshot render settings contain export dimensions; the engine accepts no display-size hint. | win-media: define bounded preview sizing without changing export geometry or caption layout. | Architecture §6.3. Current UI displays the engine's buffers at aspect-fit size. No alternate compositor. |
| Initial edit state | UI has transcript/project edits but no shared pause/state factory. | win-editing: expose state creation with canonical pause IDs and pruning. | Editing §2.4 and design §4.1. UI currently projects gaps using the documented threshold and `pause-after-<previousWordId>` IDs. Replace this projection when the owner provides the factory; source timings remain immutable. |
| App key injection | `LlmRunner` accepts `IKeyProvider`; the default `ClipFinder` / `TranscriptionService` composition exposes no app key-injection seam. | win-ai and win-speech: agree explicit constructors/factories accepting the app key provider and settings/configuration. | Architecture §2.1/§2.5, AI §8, transcription §8. App Test uses `LlmRunner` with DPAPI keys. Do not work around the missing seam with environment variables or plaintext settings. No JSON or credential format change. |
| Speech key test | There is no subscription-test boundary on `ITranscriptionService`. | win-speech: own a no-audio subscription check with regional endpoint configuration. | Transcription §8.5. Current Settings uses a bounded, app-owned GET of `/v1/user/subscription`, does not read/log the response body, and never sends audio. |
| Share caption measurement | No frozen publishing formatter/weighted-X-length boundary exists. | Lead: assign publishing helpers and expose weighted length/truncation with shared fixtures. | Publishing §2. Current UI counts Unicode scalars for LinkedIn, copies full captions, reveals the selected file and opens the approved browser composers. X currently defers length validation to its browser composer; this is explicitly not weighted-X conformance. |

## Compatible additions in owned services

- `Log(string? directory = null, TextWriter? standardError = null)` retains
  parameterless source calls. Explicit stderr is for CLI hosts; the app uses only
  the per-user rotating file sink and redacted 200-line memory ring. Existing
  `ILog` methods and `LogEntry`/`LogLevel` declarations are unchanged.
- `UpdateChecker(IUpdateChecker? backend = null)` retains parameterless source
  calls and the unchanged `IUpdateChecker` interface. Core stays platform-free;
  the App supplies its Velopack adapter. An omitted backend is a development host
  with no available update, not a fabricated successful update.
- Review these additive constructor seams when copying this note into the
  lead-owned inventory. No added public serialized types or schema changes.

## Design/build ambiguities

- `tools/design` is absent in both the task worktree and the main checkout.
  `Themes/Tokens.xaml` was hand-derived from the current canonical
  `shared/design/tokens.json`, with Default/Light/HighContrast dictionaries and
  the required generated-file header. A future canonical generator must replace
  this manual derivation. No shared assets were copied except the explicitly
  requested Windows icon.
- The task's General / Providers & Keys / Local Models / Export / Accounts /
  About pane names override the older Transcription / AI pane split in design
  §10. AI (M2) is shown disabled in the inspector as requested, rather than named
  as a CLI-branded feature.
- Brand regular font files are not all bundled yet, so transcript and numbers
  use the specified Windows fallback families. The icon is byte-identical to
  main's `shared/brand/windows/app.ico` and is used by the executable and windows.
- `--demo-project <fixture>` and the QA-only companion
  `--demo-screen editor|home|settings` are compiled only in Debug. Their synthetic
  preview and limited UI-test reducer are not production editing/media engines;
  fixture writes and export are disabled. The companion exists because VM
  input injection did not navigate reliably in unattended interactive tasks.
