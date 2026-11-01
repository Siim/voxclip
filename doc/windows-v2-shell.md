# Windows v2 shell

WV1–WV3 use native WinUI controls: `TitleBar`, `TabView`, a virtualizing `ListView`
Explorer, `CommandBar`, and an inline command palette. The existing transcript,
timeline, preview, caption and Rewrite controls remain mounted. This source patch
has static validation only; compilation and native acceptance remain required.

## Layout and navigation

- The Explorer is a solid 224 epx column, not a NavigationView or a floating pane.
  Its source/project, Clips, Suggested, transcript Outline and Recent rows keep
  identity across updates. Outline entries use the existing paragraph projection;
  they do not introduce a second paragraph or WC1 implementation.
- The window extends into the native `TitleBar`. Its `Content` hosts the native
  tab strip; `RightHeader` holds Commands and Settings. Native TitleBar owns
  caption insets and interactive passthrough regions. There is deliberately no
  competing manual nonclient rectangle map. Verify drag, double-click maximize,
  system menu, caption buttons and interactive exclusions on Windows.
- The right column defaults to `404 + (windowWidth - 1280) * 0.25`, clamped to the
  existing 300–560 epx limits. The current splitter preference and forced-viewer
  fit/source-video guards remain in force. No settings schema changes.
- The clip bar has a 34 epx minimum, not a fixed clipping height. Native controls
  grow for their font and text scale. The timeline host reserves 216 epx; its
  existing child is retained pending the timeline owner's integration. Status is
  a full-width, minimum 24 epx row. Hiding the timeline retains viewer transport.
- Below 1000 epx, a wide-to-compact resize hides Explorer; Ctrl+B restores it.
  The existing viewer collapse/forced-show policy protects transcript space.
  Native command overflow and the palette retain access to commands.

One click opens a replaceable preview clip tab. Double-click or a real edit pins
it. Full take is permanent. Closing a clip tab changes only view state, never the
clip or its edits. Ctrl+W on Full take retains the existing document/window leave
boundary. Ctrl+Tab and Ctrl+Shift+Tab cycle open tabs.

`EditorViewModel.SetScope` changes `activeClipId` in memory without changing
`ModifiedAt`, consuming Undo/Redo, or requesting a save. Dirty identity ignores
only `activeClipId`. The next genuine save includes the current scope. Read-only
projects can navigate; edits and export retain their original guards. The page
recognizes `IsScopeChange` and does not schedule autosave for that notification.
An already-pending real save captures the latest scope immediately before its
flush, without turning scope-only or read-only navigation into a new write.

## Commands and input

Ctrl+K opens commands, including current unavailable commands with their reasons.
The command's predicate runs again immediately before execution. Make clip moves
to Ctrl+Alt+K. It cannot mutate the project hidden behind Home. Ctrl+Alt+C toggles
Show cuts, Ctrl+J toggles timeline, and Ctrl+B toggles Explorer. The legacy
Ctrl+Shift+H alias remains for existing users. F1 / Ctrl+/ show keyboard help
inside the same inline palette rather than opening a dialog.

The palette disables underlying workspace, title-bar commands and status buttons,
keeps Tab within its input/results, and restores the initiating control. If that
control was removed, it falls back to the transcript or Home's Commands launcher.
Refreshing results preserves the selected command ID and keyboard region. F6
cycles Explorer, tabs, clip actions, transcript, viewer, right job, timeline and
status, skipping unavailable regions; Shift+F6 reverses the cycle.

IME composition owns Enter, Escape and region accelerators until its terminating
key releases. The palette, Ask and inline Rename have their own composition
guards. Correction fields keep their existing native behavior. Escape in the
palette dismisses it, not the active clip. Rename is inline, validates the existing
120-code-point limit, and refuses a stale or no-longer-editable row.

Tighten invokes the existing scoped Cut Fillers and Tighten Pauses operations as
one Undo step. No connector is called by Tighten, palette opening or filtering.
No production Insert Words route is registered. This patch adds no confirmation,
export, transcription, consent or paid-action popups; inherited workflow surfaces
are not copied or replaced in this lane.

## Integration interfaces

`EditorPage.ConfigureShellJobs(ShellJobBindings?)` replaces the legacy job adapter
without remounting any child view. Bindings have:

- `Available(ShellJobRequest)`: pure, synchronous current capability check; never
  perform a provider call, probe, consent or payment here.
- `OpenAsync(ShellJobRequest)`: open the existing single panel job. It is not
  approval to send text, media or payment. The owning job retains all quote,
  request-lifetime, consent, speaker, fitting, source-video and payment checks.
- Optional `Status()`: current real job status, subordinate to an editor notice.

Requests carry `Job`, the exact in-memory `Snapshot`, `ClipId`, source `WordIds`
and `Instruction`. Rewrite prefers selected words, then the active clip, then
Full take. Hook and Find Clips always request the full take. Export row/retry
routes pass their explicit target, even when another clip is active. Call
`RefreshShellPresentation()` after changing job capabilities/status. Availability
does not bypass read-only, busy, transcript or native `ExportBlocked` guards.
Use these interfaces on the window's UI thread. Snapshot identity remains exact;
use the explicit `ClipId` to build a scope rather than assuming its stored
`Snapshot.Edits.ActiveClipId` is the requested inactive Export/Hook target.

Without bindings, the existing selection Rewrite, Find Clips and Export APIs
remain functional. Scoped Ask selects the requested words and populates the
existing Rewrite panel's `FocusTarget` TextBox; that panel remains responsible for
preparing and approving requests. The legacy adapter retains the existing Voice
Lab gate. The integrated free-text Rewrite owner must supply its actual
availability through bindings. Hook stays truthfully disabled until the real
Hooks job is bound; it is not mislabeled generic Find Clips or an invented send.

`ConfigureTimelineShell(Action<bool>?)` connects the sole shell Show cuts state to
the timeline owner's axis API. It immediately publishes the current value and
updates after either keyboard or clip-bar changes. Without it the existing
timeline's own Edited/Source behavior is preserved; this lane does not alter
TimelineView/Scene/Layout/Viewport/Thumbnails. Paragraph and transcript decoration
ownership similarly stays with WC1/transcript. Child owners also need to update
the inherited `SelectionFlyout.cs` and `OnboardingDialog.cs` Make clip hints from
Ctrl+K to Ctrl+Alt+K; their paths are intentionally untouched here.

## Validation to run after integration

No local build, test, restore, native launch, VM, provider, credential, download or
CI action was run for this patch. Do not publish it as validated from static
checks. Use isolated data with live providers/downloads disabled. From the repo
root, the parent should run these when its single build slot is available:

```sh
export VOXCLIP_SHARED_DIR="$PWD/shared"
export VOXCLIP_DATA_DIR=/tmp/voxclip-windows-shell-validation
export VOXCLIP_NO_KEYCHAIN=1
export VOXCLIP_LIVE_TESTS=0
export VOXCLIP_TEST_DOWNLOAD=0
cd apps/windows
dotnet test --project tests/VoxClip.Core.Tests/Tracks/win-ui/VoxClip.Ui.Tests.csproj -c Release
dotnet test --project tests/VoxClip.Core.Tests -c Release
dotnet test --project tests/VoxClip.Media.Tests -c Release --filter "Category!=RequiresFFmpeg&Category!=RequiresWindows"
dotnet build tests/VoxClip.App.TypeCheck -c Release -m:1
```

On the appropriate Windows hosts, both native builds are mandatory:

```powershell
cd apps\windows
dotnet build src\VoxClip.App -c Release -r win-x64 -p:Platform=x64 -m:1
dotnet build src\VoxClip.App -c Release -r win-arm64 -p:Platform=ARM64 -m:1
```

Run the existing shell/native fit harness after both child integrations; retain
all bounds, clipping, required-peer, transport and source guards. The shell probe
now checks the clip bar against its native desired height and its timeline host
against 216 epx, with the existing 4 epx tolerance; it does not assert that the
old timeline child has been ported. No screenshot or native success is implied.

Required manual acceptance on x64 and ARM64:

1. Light/dark and High Contrast at 100/150/200% display scale, enlarged text and
   monitor-DPI changes. No clipped commands, caption-button overlap or invisible
   focus indicator. Verify custom title-bar exclusion and drag behavior.
2. Keyboard-only F6/Shift+F6, Tab/Shift+Tab, Explorer arrows across section headers,
   row context keys, preview/pinned/close/cycle tabs, and all remapped shortcuts.
   Background Home must not accept editor mutations. Missing media stays read-only.
3. Narrator: Explorer list/section names, current tab and preview/pinned state,
   disabled-command reasons, inline Rename errors, command focus restoration and
   real job status. Playback time must not flood live announcements.
4. Japanese/Chinese/Korean IME: Enter accepts a candidate before submitting Ask or
   a command; Escape closes the candidate before the palette. F6/Ctrl+K must not
   steal composition. Test keyboard/pointer commit and an initiator removed while
   the palette is open.
5. Switch full/kept/suggested/read-only tabs without dirtying or changing Undo/Redo;
   edit, pin, close and reopen without losing cuts. Undo Tighten restores both cut
   types. Remove/rename a clip while the palette is open and recheck availability.
6. Export the inactive row and retry its exact target; test full take, removed
   targets, read-only/missing/source-video failures, consent cancellation, stale
   quotes and pending paid work. Voice speaker/fit/payment gates must remain owned
   and enforced by the real child jobs. Do not enable Insert Words.

`WindowsShellV2Tests` adds portable tab, scope/history, Outline, Tighten,
availability and IME regressions. For negative controls, reverting SetScope to an
edit/history operation must fail the dirty/history tests; allowing disabled
`ShellCommand.TryExecute` must fail its execution test; ignoring composition must
fail the IME test; retaining multiple preview tabs must fail replacement tests.
These negative controls and the tests themselves are authored, not locally run.
