# win-ui contract notes

## Round 5 — synchronous history, canonical exports and exact copy (2026-10-27)

- Merged origin/main (`5d6a295a5b0c4a9c63701a3f72255cd487d1dcc6`) first and preserved both Windows contract histories. The merge's second parent, not a later moving remote-tracking ref, identifies the integrated source. Step 15 remains unstarted; scheduling that work is lead-owned.
- A1: `HistoryCancelsCaptionDragBeforeRestoringPosition` (Undo/Redo), `ReloadAndReopenBoundaryRejectsAStaleCaptionRelease` and `TranscriptAndCaptionReplacementCancelCaptionDrags` exercise the production synchronous cancellation boundaries. Save As cancels before its save/reopen boundary. Stale release writes nothing and adds no history.
- A2: `IntervalQueryRetainsUnsortedIdentitiesAndSkipsEmptyAndTouchingSpans` and `NestedIntervalQueryIsOutputSensitiveForNineThousandWords` cover the centred index, stable start/tie order, original identities and half-open edges. The nested 9,000-word probe reports k=2, visited=14, bound=30 (k + 2 ceil(log2 n)); randomized queries also match a brute-force oracle. Round-four kept/cut/filler overlap probes remain in the suite.
- A3: `ZoomTicksAndTrimMovesHaveAFixedSmallAllocationBound` now measures the production `TimelineFrame.Compute` used by animation/playhead and trim movement, including retained transforms, badge iteration, trim ranges, playhead and pointer conversion. Across 4,096 changing zoom/scroll/playhead/trim ticks it measures 0 bytes against the fixed 1,024-byte bound. Spoken strings are prepared at plan changes. This does not measure native COM/automation allocations.
- A4/A5: `FingerprintUsesEffectiveQualityEncodingAndOnlyTheActiveAnchor`, `CanonicalFingerprintRetainsAllRenderSensitivityProbes`, the prior overlap/property-order/scoped-edit ledger tests and `DialogRoutingMapsEveryControlChoiceAndFreezesTheSnapshot` cover canonical output settings, metadata invariance, per-aspect positions, control indexes, immutable scope and snapshot routing. Both dialog and current equivalence harness use `ExportDialogRouting.JobAsync`; the hosted comparison retains exact baseline `05105bae02f9199d47728143794b1d285b92357b`, four aspects and all three scopes, 16 renders per revision. Its run IDs and inspected artifact counts are reported at handoff, not inferred from portable compilation.
- A6/A7: exact tests cover found counts 0/1/3, actual non-round transcription percentages, Play/Pause plus separate Space hints on XAML/dynamic icons, known/unknown-size disk recovery copy and both sidebar badge geometries. In the 32-pixel column the right-aligned 27-pixel tile begins at x=5; badge x=1 yields the approved -4 offset in both axes. The 1-pixel page ring and 18-pixel timeline badges remain.
- Local acceptance: Release cross-platform, UI and App typecheck builds have zero warnings/errors; direct Core: 1,871 passed / 28 skipped (1,899 total); UI: 352 passed / 3 native prerequisites skipped (355 total). XAML has zero problems, generated design files are unchanged and all 16 design tests pass. The exact CI secret pattern and changed-PowerShell ASCII checks pass. Builds run sequentially under nice with more than 15 GiB free.
- The VM at 192.168.64.3 did not answer its SSH-port probes; no VM lock was acquired. Owed native gates: pixel probes; actual spoken Narrator and exact Play/Pause names on live controls; F6's two rings/no black rectangle; 9,000-word/hour-long zoom/scroll timing; caption drag with aspect switch, Undo, Redo, reload and stale release; full-control allocation regression; High Contrast Black/White; light/dark/compact mockup overlays within ±4 epx on x64 and ARM64; extended integrated interaction flow. Hosted builds/render comparisons do not close these interactive gates. Rewrite and its DEBUG captures remain deferred with step 15.

## Round 4 — review fixes, accessibility and capture contract (2026-10-27)

- Local final checks: zero-warning cross-platform and UI builds, zero-warning Debug/Release App typechecks, Core 1,859 passed / 28 skipped, UI 336 passed / 3 skipped, static XAML zero problems, design 16 passed, generated-token drift check and quantitative contrast check passed. The allocation case measures zero bytes against its 1,024-byte bound. Removed-control search returns nothing; exact CI secret-pattern and changed-PowerShell ASCII scans pass.
- Hosted Windows run `40577491247` at `8990038c5709ac6ec3168606f23584d9f25c8e54` passes both WinUI builds, strict native media tests, capture-script parsing and A6. The actual comparison reports 16 matching before/after exports: names, folders/order, SRT bytes, stream fields and durations, with all MP4 bytes also equal. Retained artifact: `windows-dialog-export-equivalence`. The final handoff records any subsequent run and exact final head; these hosted renderer checks do not close interactive native gates.

- A1-A5: overlap-aware timeline index; scoped real-plan fingerprints; starting-aspect caption drag sessions; cached viewport/accessibility state (0 measured bytes over 4,096 ticks/moves, fixed 1,024-byte UI-model bound); exact generic export failure sentence and Try again. `RoundFourTests` covers these regressions, motion/contrast policy, notifications, mapped strike/badge/selection brushes and capture-route source checks.
- A6 uses `export-equivalence.py` and `ExportEquivalenceTests.cs`: separate builds of pre-export parent `05105bae02f9199d47728143794b1d285b92357b` and current source, 16 real MP4/SRT exports each, all aspects and scopes, collision suffixes, matching stream parameters and durations. Comparison results must come from the Windows job, never inferred from portable harness compilation.
- Run `run-screenshots.ps1 -Root <checkout> -RuntimeIdentifier win-arm64 -Screen all -Exercise` from the interactive, locked VM slot; repeat with win-x64. Builds must already exist. Each launch uses the requested size rather than relying on the VM compositor after an external resize. Debug-only capture flags set light appearance and ensure two fixture clips without saving demo edits. Dark selects clip 2. Output is partitioned by runtime under screenshots; the catalog lists every required state and keeps visual review pending.
- To capture an additional real state without starting a provider or fabricating success, prepare it in the owned interactive app, then run `run-screenshots.ps1 -Root <checkout> -RuntimeIdentifier <runtime> -ManualState <state> -RequiredName <exact-visible-UIA-name>`. States include home-empty (fresh explicitly accepted data root; never clear user recents), home-dragover, finding, suggested, exported, export-edited, exporting, export-failed, transcribing, focus, opaque-flyout, splitter, high-contrast-black and high-contrast-white. Use synthetic source and deterministic/fake service fixtures for transient states, not live providers. The script records the witness and focused bounds, preserves the pointer/app, and never calls the result a Narrator/contrast pass.
- Capture dimensions follow the supplied PNGs: editor light/dark 1440x900, Home and editor-1280 1280x800, compact editor 1024x700. The states board is 1440x960. The 900x720 pane-breakpoint stress probe is separate from the compact mockup; external resize diagnostics never masquerade as the fresh-launch compact capture.
- `native-accessibility-walk.ps1` takes RuntimeIdentifier, captures each F6 region and writes `f6-visual-evidence.json`. Inspect those actual pixels for Fluent two rings and no black rectangle, and separately record spoken Narrator. `run-native-flow.ps1` uses the selected runtime's pinned test-only FFmpeg hash. `NativeIntegratedFlowTests` checks actual Full video/This clip export names, Original/9:16 dimensions, scope persistence, and Exported -> Edited -> undo -> Exported plus ledger reload.
- Native execution is still owed because 192.168.64.3:22 did not answer. This includes pixel probes, Narrator, focus-ring visuals, 9,000-word/hour-long native scroll/zoom timing, caption drag/aspect interaction, Black/White contrast captures and light/dark/compact mockup overlays within 4 epx on both architectures. Portable source and allocation tests do not replace these gates. The Ink palette supersedes the older Petrol mockups (ADR-R31); unmeasured geometry differences are not accepted implicitly.
- Checklist step 15, take-ready notification and DEBUG Rewrite capture remain deferred for VoiceLabWordDiff. The lead owns the design.md delta, ADR-R29 row and Voice Lab docs; this track does not edit those files. Final local/hosted results are in the task handoff.

Date: 2026-10-27. The newest integration record is first; older VM connectivity
and blank-window entries below are retained as history, not current status.
This track does not change other tracks' declarations. The lead owns the root
`apps/windows/CONTRACTS.md` ledger; these notes are in the permitted track folder.

## Redirected activation native acceptance (2026-10-26, bounded R4)

- Started from clean `a083a704f365e2ea31d72e30e2c6a38f0532b1fa` on `track/win-ui`. This round changed only the committed native walk and this track ledger; the R3 App selector and other production code are unchanged. No main or other track merge, rebase, push, package, install, live provider, model download, transcription, export, signing, or updater run occurred. The final walk source is `8b6b785adf48cabe87c430af1de064a82e2f8bc2` before this ledger commit.
- The exact R3 App source built natively as Debug ARM64 with at most two compile jobs and zero warnings/errors. A final no-restore App rebuild after the harness-only changes also had zero warnings/errors. The native ARM64 UI companion built with zero warnings/errors and its direct DLL runner passed 58, skipped one existing opt-in synthetic media prerequisite, and failed zero. A first runner attempt used the wrong output folder (`Release` rather than `ARM64/Release`) and executed no tests; the corrected direct run is the recorded result. The CLI built with zero warnings/errors to accept the displayed pinned Windows runtime terms hash `2d225eaff1555fab8ea01bc3c4799587da51bd167560a37d2e3d1a6364495f09` into this run's isolated data root. Six existing pinned LGPL ARM64 FFmpeg DLLs were copied from the win-release cache; their source hashes are recorded with the evidence.
- The final committed normal native walk passed Home rendered self-check; actual editor UIA and owned-window screenshot; ordinary redirected project open; transcript selection, manual clip, correction-field shortcut isolation, F6/Shift+F6 descendants, Preview Enter/Escape focus, selected-clip Export dialog and cancel, Find connector setup without dispatch, compact inspector return, Home and named Recent reopen in the same PID/HWND; a no-argument second launch; and a subsequent real file activation. The no-argument assertion waited three seconds after the redirected process exited, then checked the original executable/PID/start/HWND, visible editor clip count, no new notice, and unchanged project timestamp and SHA-256 both before and after an owned-window capture. In the accepted run the original was PID 8128/HWND 9241096 and the no-argument redirect was PID 1548. File activation then reopened the editor and disk readback retained the `jklc` correction and one selected manual clip. `editorRenderedSelfCheck=false` in the result is expected for this normal path: the self-check covered the initial Home; actual editor UIA and screenshot assertions are separate and true.
- Earlier R4 walks are retained as failures, not acceptance: `normal1` demanded a hidden `Clip 1` row after the compact inspector closed; `normal2` demanded the selected-clip footer label after file activation opened outside the Clips inspector; `normal3` demanded that same label after foreground activation dismissed the compact overlay; `normal4` used literal non-ASCII UIA labels that Windows PowerShell 5 read through its host code page. No production defect was confirmed in those attempts. The harness now uses a visible clip-count label built from ASCII plus its Unicode code point and checks the persisted selected clip. `normal4` console failure was observed but its scratch files were removed during owned cleanup; the other failed walks and the accepted `normal5` are archived locally.
- Actual captures, UIA dumps, result JSON, project readback, build and companion logs, and FFmpeg provenance are in `/tmp/voxclip-win-ui-r4-20261026/evidence.zip` (3,845,817 bytes; SHA-256 `8cc2fcf09eed2add34115224f77a7f1673d4676b918568557d64328eaeb533f4`). The final owned screenshots include `normal5/home.png`, `editor.png`, `recent-reopened.png`, `no-argument.png`, and `file-after-no-argument.png`. Spoken Narrator announcements and exhaustive Settings/name-field shortcut coverage remain open; no UIA report is a Narrator speech pass. This run did not change High Contrast state. The exact owned scheduled task and App process ended, `C:\voxclip-build\win-ui-r4-c1a245c0` and the exact-owner `vm.lock` were removed, C: returned to 8.07 GiB free and the Mac had about 17 GiB free. The VM slot was explicitly released to the parent before this local ledger edit.

## Redirected launch selection follow-up (2026-10-26, bounded R3)

- Continued from clean `9a175a3cb47987ac1b8b315ad9365487b1639059` on `track/win-ui`; no main or other track merge. The R2 parser still uses Windows `CommandLineToArgvW` and frees its allocation with `LocalFree`. The narrow production token selector now rejects executable-only, empty, option-only and ambiguous redirected launches; one project or video path remains selectable with or without the executable token. This prevents a no-file second launch from reaching media import. The first-instance argument path and global single-instance key are unchanged.
- The portable UI companion links this production selector and covers paths with spaces, executable-only, executable plus project/video, file-only, whitespace, options and multiple-file ambiguity. The Release companion build has zero warnings/errors; its direct runner passed 58, skipped one existing native-media prerequisite, and failed zero. The normal native walk now records Home's rendered self-check separately from editor UIA and its owned screenshot; historical R2 results are unchanged. Its added no-argument second launch asserts the original PID/start/path/HWND, editor and clip, unchanged project file timestamp, and no new visible notice, then reopens the project by real file activation from Home. Native acceptance awaits a parent VM slot; no native success is claimed here.

## Native clipping accessibility follow-up (2026-10-26, bounded R2)

- Continued from clean `207bc90abd713a534f830f809f97b5b51a4fce10` on `track/win-ui`; no merge, push, package, install, provider, model download, signing, or real updater. The `native-accessibility-walk.ps1` harness now claims only the launched exact executable and PID/start time, verifies its rendered self-check PID/HWND and foreground window before every screen capture, records separate assertions, and preserves failures. The isolated `VOXCLIP_DATA_DIR` explicitly accepted the bundled pinned Windows terms; live and download test flags were zero.
- The R1 normal-open failure was a real App activation defect. Redirected `ILaunchActivatedEventArgs.Arguments` held the quoted executable and quoted project path (191 characters, four quotes). Trimming the whole string sent an invalid combined path into project loading (`projectUnreadable`, inner `IOException`, `0x8007007B`). The Windows CLI loaded the same synthetic project. App now parses the redirected command line with `CommandLineToArgvW` and accepts one file argument. The diagnostic log records only action, error type, and HRESULT, not the path. A real small synthetic `fillers-chirp.mp4` source and project then opened from Home and reopened from the named Recent row in the same process/HWND, retaining a saved clip and `jklc` correction. Native `ProjectStore.LoadAsync` independently confirmed `resolved=present`, `readOnly=False`, and the expected content key. The isolated Debug output initially lacked FFmpeg DLLs; copying the existing pinned LGPL ARM64 DLLs into this run's output enabled native preview. No Media source or other track files were changed. The App also retains the probe-failure notice instead of falsely saying a present source file is missing.
- The exact source walk verified transcript Shift+Right selection and Ctrl+K, F6/Shift+F6 from a preview aspect control and clip checkbox, inline J/K/L/C/Space/arrow/Delete typing and Ctrl+K isolation, Tab/Shift+Tab around Preview, Preview Enter transport focus and Escape return, selected-clip Export with Escape cancel, Find connector setup without dispatch, and compact inspector Escape returning transcript focus. F6 now identifies whole pane regions. The compact pane's native close event restores focus, while clip preview keeps transport focus. Alt+Left reaches Home after editor keys ignore Alt combinations. Recent list items expose their visible project name to UIA. The focused portable UI companion passed 54, skipped one native-media prerequisite, failed zero. Native ARM64 Debug App built with zero warnings and errors.
- Owned captures, UIA dumps, self-checks, failure reports, and build logs are retained under `/tmp/voxclip-win-ui-r2-20261026/`; the accepted normal walk is `normal10` and the accepted synthetic demo walk is `demo7`. R1 High Contrast had already passed and this round did not change colours or system contrast settings. Spoken Narrator output, exhaustive Settings/name-field shortcut routes, and full installed or Voice Lab media acceptance remain pending; UIA data is not a spoken Narrator pass.

## Native clipping accessibility focus pass (2026-10-26, bounded R1)

- Merged only exact main `e5970d50beb20c220126ec758fd38c2d3ed9c146` into clean `aaff3ba64ea54d607ad5aae9549b79ea1ca1e824`; the merge result was `c50d548a737b1d8fb6ef359e4df9cccf28b61149`. The root contract conflict kept main's reviewed updater account. No later main merge, push, provider call, real export, update or install occurred.
- The native ARM64 Debug app built with zero warnings and errors. A fresh isolated data root displayed the bundled runtime terms and accepted them explicitly. Home controls appeared in UIA, but its early screen capture was rejected because it preceded composition. Opening an isolated synthetic project through the normal activation path returned to Home with a generic open warning; the same project passed `ProjectStore.LoadAsync` directly on Windows. Same-window normal open therefore remains unaccepted in this round. The Debug synthetic editor did render through its real WinUI tree and native preview, with a loaded/rendered self-check before screen capture.
- Keyboard Home, Shift+Right and Ctrl+K selected six transcript words and created a selected clip. UIA exposed the transcript document and word state in its paragraph text, the checked `Clip 1` checkbox, preview action, collapsed edit action, enabled selected-clip Export and toolbar states. The first F6 walk landed on unnamed timeline and inspector containers. Enter on Preview then moved focus to Find clips with AI; Escape could not return. The source now focuses the slider and selected tab for F6, moves focus into preview on Enter, returns to the clip checkbox on Escape and retains checkbox focus when results rebuild. A second native walk observed `Playhead` then `Clips` on F6, `Play or pause (Space)` after Enter and `Clip 1` after Escape. Tab reached `Export 1 clip`, Enter opened `Selected clips (1)`, Escape cancelled, then Tab reached Find Clips and Enter exposed Connector without provider dispatch. At 900 physical pixels, the overlay opened from its button and Escape closed it. The repeatable keyboard and screenshot harness is `native-accessibility-walk.ps1` and requires an explicitly accepted isolated terms data root.
- Actual owned captures and focus/UIA reports are under `/tmp/voxclip-win-ui-r1-20261026/`: `baseline-editor-verified.png`, `baseline-selected.png`, `baseline-clip.png`, `selected-clip-export.png`, `find-clips-setup.png`, `compact-find.png`, `compact-return.png`, `high-contrast-selected.png`, `high-contrast-clip.png`, `normal-dark-clip.png`, `baseline-uia-clip.txt`, `f6-before-preview.txt`, `focus-after-fix.txt`, and `native-debug-build.log`. An early screen capture was rejected because WinUI composition had not finished. The final captures waited for the app's loaded/rendered self-check. High Contrast was read as off, temporarily enabled on this VM and restored in `finally`; flags were `126 → 127 → 126`. Normal light and dark captures were made after restoration. The direct portable UI companion passed 53, skipped one native media prerequisite, failed zero.
- This is a focused keyboard and UIA check, not full keyboard-only or spoken Narrator acceptance. Inline correction typing, global shortcut suppression inside every text field, all Tab/Shift+Tab routes, actual Narrator speech and full normal Home/import workflow still need native acceptance. No spoken Narrator pass is claimed from UIA data. The VM ended with no owned app or scheduled task, no owned scratch or lock, High Contrast off, C: at 8.1 GiB free, and Mac free space at 26 GiB. Full Voice Lab media acceptance remains separate.

## Native updater repeat (2026-10-26, R7)

- Started from clean `4dffcff8a4939c0c447668f3476e7bee10624c18` on `track/win-ui`; no main or other track merge was taken. Debug-only probe commits `11e45ae`, `fcd9729` and `cc7fcf6edc4eaa8b299f822f824e7d98d2b70488` retain the fake-dispatch assertion error, returned result and invocation count, release delayed save/flush gates on failure, and make the repeated Settings text setup deterministic. No production updater or settings behavior changed.
- `SettingsStore.SaveAsync` accepts a snapshot but debounces its disk write for 500 ms. The first R7 repeat found the previous `et` language on disk after setting the synthetic baseline to `auto`; it failed before restart preparation. The probe now explicitly flushes that baseline before opening Settings, waits for the selected pane to settle, then asserts that the active `et` text remains off disk before preparation. The failed R7 repeat reports are retained under `/tmp/voxclip-win-ui-r7-20261026/`; the R6 failure remains separately under `/tmp/voxclip-win-ui-r6-20261026/`.
- On the Windows ARM64 VM, final source `cc7fcf6` built as Debug with zero warnings and errors. The CLI also built with zero warnings and errors for explicit acceptance of the bundled runtime terms into a fresh isolated data root. The app ran in logged-in desktop session 1; an SSH session 0 launch failed in `Microsoft.UI.Input.dll` before app startup and produced no probe report. Both final interactive runs, first on fresh data and then on the same owned data root, passed all 11 probe checks with `Dispatched` exactly once and no Velopack call. At fake dispatch, disk readback found the accepted clip, word correction and `pauseKeepSeconds = 0.05` in each project, and `transcription.language = et` plus `editing.pauseBreath = tight` in Settings. The report records `auto` on disk before the active language edit. Delayed save, drain and flush, rejected late project/settings writes, native close and new/open/Home/Settings gates, and busy, transition, invalid text, save, flush, cancellation and fake-updater failure recovery all passed. Reports, project readbacks, final settings and build log are under `/tmp/voxclip-win-ui-r7-20261026/` (`probe-v3-one/`, `probe-v3-two/`, `final-settings.json`, `app-build.log`). This is synthetic Debug acceptance; installed Velopack termination remains a separate release check.

## Native updater preparation acceptance (2026-10-26, R6)

- Merged only exact main `5d75d7fdf505d095bfda9f06bee84cc72685c44f` into clean R5 `4b3ef73beb2500bbbe13999e092dc61b81c6b60c`. Both contract histories, ADR-R23/R24/R25/030, runtime agreement gate, Voice Lab source guards, notices and colour/caption tests remain present. No later main commit or other track was merged.
- ARM64 Debug WinUI and the focused UI companion built natively with zero warnings and errors. The UI companion's test DLL ran directly after `dotnet test` reported the .NET 10 Microsoft.Testing.Platform/VSTest incompatibility: 53 passed, one native-media fixture skip, zero failures. A rendered Debug synthetic editor window was captured under `/tmp/voxclip-win-ui-r6-20261026/editor-window.jpg` using this run's isolated data root and explicit Windows runtime-terms acceptance.
- A `#if DEBUG` local `--restart-probe` path opens two actual WinUI project windows and Settings on the dispatcher thread. It uses the production coordinator, settings queue, editor leave and project save boundaries with deterministic delayed settings save/flush and a fake updater callback. At dispatch, it reads back both project files and settings from disk. An initial native pass found both accepted clips and word corrections, active Settings language text, and the delayed `editing.pauseBreath` change applied to both project saves. Native `WM_CLOSE`, new/open/Home/Settings entry and late settings writes cannot bypass preparation; project and settings edits are refused while final flush is paused. Busy work, owned navigation, invalid Settings text, project save failure, settings flush failure and cancellation veto dispatch and restore editing; a fake updater failure also restores it. A stricter final rerun checked that the language text was still off disk before preparation and found the pause setting already `tight` from an earlier run in the same isolated data root. Both final project files remained at 0.15 s while settings on disk read `tight`; the editor had initialized its settings cache at `tight`. `SettingsWriteQueue` did invoke `Changed` after the successful write; `EditorSettingsChanged` skipped the same value, so it did not change the existing project value. Commit `4dffcff` resets `editing.pauseBreath` to `natural` before opening projects; R7 above records the passing repeat. The retained failed report and project/settings readbacks are under `/tmp/voxclip-win-ui-r6-20261026/`. This is synthetic, isolated Debug evidence; it does not execute Velopack or prove installed updater termination.
- As ancillary no-provider Windows smoke, `VoiceLabAssetTests` passed 5/5 and `VoiceLabRenderingBoundaryTests` passed 3/3. The asset symlink test ran successfully without an additional privilege change. No signing, packaging, install, provider, download, network or real update was used.

## Settings restart write boundary (2026-10-26)

- This local follow-up starts from clean `94766d4273e8558832b300451ef6a8c2f55b8a35`. No main or other track merge was made. The prior coordinator could release its settings semaphore after `FlushAsync`, then dispatch the immediate-exit updater ahead of a Settings Save queued during that flush. A sequential project save could also freeze before an accepted `editing.pauseBreath` change reached the editor.
- `SettingsWriteQueue` now owns the AppServices save serialization, settings snapshot, freeze and drain. Restart commits active Settings text fields and disables its controls before freezing the queue; the coordinator drains accepted writes before any project leave boundary, then flushes after every final project save. Settings entry, close, key writes, model changes and other active Settings actions are guarded during preparation. A rejected late write faults its caller instead of appearing accepted. Cancellation, failed flush and failed dispatch resume Settings and all prepared editors.
- The portable companion links this production queue and uses a real `SettingsStore` behind delayed save and flush gates. It reads both the settings file and final project file at fake dispatch, checks a late write during flush is rejected, and checks queue recovery after cancellation, flush failure and an earlier failed setting followed by a different successful write. Release result: 53 passed, one native media skip, zero failures; the portable Release solution build has zero warnings and errors. Native WinUI compilation, rendered interaction and Velopack termination remain for the assigned VM slot. No VM, provider, update, install, restart, network, signing or push action was used in this follow-up.

## Update restart preparation (2026-10-26)

- Merged only exact local main `23a51d4` into clean `b60ec71`; this retains both contract ledgers, ADR-R23/R24/030 and the reviewed UI source. No later main or other track was merged.
- Restart now uses `UpdateRestartCoordinator` on the UI thread. Its synchronous gate blocks new windows, open/replace/Home and native close. Each window takes its navigation slot without waiting for another transition, then reuses the editor's leave boundary and final save. All current project files and settings are flushed before the separate Velopack dispatch. A failed save, busy editor, transition, cancellation or thrown updater returns to open, editable documents with inline error copy. The download and unattended exit-update strategy is unchanged.
- Offline companion tests use the real `EditorViewModel`, `ProjectLeaveBoundary` and `ProjectStore` with distinct files and a fake dispatcher: two pending autosaves, a delayed save with rejected late edits, later-window save failure, busy/owned transition, cancellation, settings-flush failure, and updater failure. Release companion result: 49 passed, one Windows-only media skip, zero failures; build zero warnings/errors. Native WinUI compile, exact UI-thread interaction and actual Velopack process termination remain unverified pending an explicit VM slot. No real updater/install/restart/network action occurred.

## Final native leave and Voice Lab guard check (2026-10-26)

- Merged only main `068816de116deedecfa2adcb3840458001e8f03a` as the second parent of `266934a`; both platform contract ledgers, ADR-R23/R24/030, the Windows snapshot guard and the CLI plan/error boundary remain present. A narrow follow-up routes Ctrl+W through the same final save as window closing, disables export while leaving, shows the paused state, and clears that state after a failed replacement open.
- The final Debug ARM64 WinUI app built with zero warnings and errors, one compile job. The focused UI companion passed 41 tests with its native media pipeline test skipped on both macOS and native ARM64 (the native test DLL was launched directly after `dotnet test` reported a runner handshake error). Its delayed-save test persisted the pre-transition manual clip, rejected late mutations, and restored editing after a failed save/open. The native companion also covered the Voice Lab full-scope rejection, excluded source-only clip, and disabled replacement; this was Core/view-model execution, not a WinUI media render.
- With an isolated data root, explicit runtime-terms acceptance and no live provider, a native Debug demo opened the schema-v2 passage fixture in a rendered editor window. Its visible InfoBar said this build cannot preview or export generated voice segments and that the video and edits remain. A separate normal v2 open with missing synthetic source stayed savable: a forced save failure vetoed Home and retained the manual clip; restoring the path let Home save and reopen in the same HWND. A corrupt replacement activation kept the prior editor and showed both the file error and “This project is still open. You can keep editing.”
- The first immediate Ctrl+W probe left two clips on disk after the editor had shown three, and its rejected screenshot/error were retained. The old shortcut called `Close()` directly. After routing it through `RequestCloseAsync`, a repeat using the same duplicate selection saved all three clips. A distinct end-of-transcript clip then gave the controlled pending-autosave check: UI showed three clips, disk still held two immediately before Ctrl+W, and after process exit disk held three, with the v2 segment still enabled. The accepted clip is therefore read back from the actual project file, not inferred from an on-screen count alone. This check did not stall the native disk writer or exercise updater restart.
- Exact owned-window evidence is under `/tmp/voxclip-win-ui-final-20261026/`: `voice-lab-guard-window.jpg`, `v2-save-failure-veto.jpg`, `v2-reopened.jpg`, `v2-open-failure-retained.jpg`, `normal-v2.json`, and the rejected earlier-run images/error. No transcription, generated media, provider, real preview/export, or installer behavior was claimed. Earlier R1 synthetic UX screenshots remain under `/tmp/voxclip-win-ui-ux-20261026/` for their original revision.

## Project leave boundary correction (2026-10-26)

- Controlled inspection found a post-save edit window in the prior Home/open/close guard: the save received `ViewModel.Project` before replacement load/probe, while the old editor remained interactive. A later edit could be cancelled with its debounced autosave in `CloseAsync`. `ProjectStore.SaveAsync` takes a project argument before its writer wait and atomic disk write, so a later view-model change is not included in that save.
- The view model now refuses project mutations from UI and async completions during the final save and replacement preparation. Busy transcription, clip search, and export veto leaving; Save As observes the same boundary. A failed save resumes editing immediately, and a failed replacement load or editor open restores the previous page, path, title, and editing state. The old editor is disposed only after the new editor opens.
- The cross-platform UI companion's delayed-save test reads the saved project back: the pre-transition manual clip persists, attempted late clip/transcription/cut mutations are refused, and a failed replacement resume accepts the next clip. A forced save failure also restores editing. This is source/fake persistence evidence; native Windows compilation and interaction for this correction await the VM slot. The earlier synthetic screenshots and ARM64 Debug pass at `f55f6e0` remain evidence for that revision only.

## Windows shell correction and native review (2026-10-26)

- This continues the single authorized merge of main `d1121611527b32e9d0378dbe33f22fccbf686b5a` into the `ca5c022` baseline. No later main or track merge was taken. The Windows app retains one Home/editor shell with a trailing title-bar Settings command and a visible Clips location. The unfinished AI tab and duplicate wide Clips/Captions links were removed. Find Clips expands the connector and explicit action without starting a provider. At compact width the Clips and captions button opens a reachable overlay; Escape returns focus to the unobscured transcript. Home distinguishes Import video from Open project and explains local versus ElevenLabs transcription.
- Make Clip from Selection in the toolbar, Ctrl+K, and the transcript context menu now use one action that reveals the created clip. Text highlights use rendered UTF-16 character offsets while pointer hit testing retains TextPointer positions, so Unicode corrections, pauses, and hidden cuts do not displace the selection. A clip row uses the scoped edit-plan duration (including boundary padding and cuts), the same duration used by preview and export. The fixture's six selected words span 3.0 seconds; its clip edit plan is 3.2 seconds, and both the row and bounded clip clock now display `00:03.2`. The synthetic preview follows the plan and stops at its end.
- Home, open/recent, file activation, drag-and-drop replacement, and window close check a final project save before disposing of an editor. Navigation serializes these transitions. A failed save keeps the current editor, its unsaved manual clip, and the same window visible with an actionable error and Save project as route. `CloseAsync` disposes only after this guard. A native forced failure (temporarily replacing the owned fixture project path with a directory) confirmed Home was vetoed; the fixture was restored afterward. The guard is also used by open/drop and close, but those failure paths were not each independently driven in the VM.
- The ARM64 Debug build at the actual `bin/ARM64/Debug` launch path passed with zero warnings/errors. The local UI companion had 39 total, 38 passed and one Windows-only synthetic media test skipped. On native Windows, an isolated synthetic color-bars import showed the explicit local model choice, no automatic transcription or provider call, an empty editor in the same HWND, a recent project on Home, and reopening in that same HWND. The native refusal path exited without an acceptance receipt. Earlier receipt tests (5 passed) and the existing native acceptance capture remain the agreement baseline; the legal gate was not changed. The settings exercise traversed its panes and onboarding, selected Dark, and captured desktop and compact editor states. The editor exercise confirmed selected-clip export scope, clip-bounded synthetic playback, compact overlay return, and caption gallery access. No real provider, transcription, export success, Narrator, or High Contrast acceptance is claimed.
- Inspected owned-window JPEGs and interaction reports are retained outside VM scratch at `/tmp/voxclip-win-ui-ux-20261026/`: `home-window.jpg`, `editor-find-clips-window.jpg`, `editor-manual-clip-window.jpg`, `editor-preview-end-window.jpg`, `export-selected-clip-window.jpg`, `editor-compact-clips-window.jpg`, `editor-compact-return-window.jpg`, `editor-compact-dark-window.jpg`, `normal-transcription-window.jpg`, `normal-home-recents-window.jpg`, `normal-reopened-editor-window.jpg`, and `save-failure-veto-window.jpg`. All media shown in these checks is synthetic. The normal import probe's UI Automation report records same-window navigation; its early rejected capture and the terms-host image obscured by a foreign terminal are not visual evidence. Owner scratch stayed below 1 GiB and C: free above 6 GiB; final lock release is recorded in the handoff.

## Windows clipping workspace correction (2026-10-26)

Historical layout, superseded by ADR-R29 and rounds 2-4. The Clips pane, secondary caption tab, compact inspector overlay and footer export described here are not the current shell. Preserve the original verification below only as revision-specific evidence.

- This branch normally merged only the authorized main `d1121611527b32e9d0378dbe33f22fccbf686b5a`
  into clean `ca5c0225fb41bfe963ad1041d3288619d0d71092`. The merge changed
  two macOS test files. The Windows app changes stay in the track's owned files;
  neither the root contract ledger nor ADR-030, runtime notices, package pins,
  Core, CLI or media code was edited.
- Home and Editor remain pages in one WinUI main window, with the native title
  bar showing the project. A dropped video now opens in that shell. The editor
  gives Make Clip from Selection and Find Clips a persistent top-level route.
  The Clips pane is the default at desktop width, with clip results before the
  contextual, collapsed connector form. Find Clips opens that form and focuses
  its connector; a provider never runs merely because the pane opens. Caption
  styling remains the existing renderer-backed gallery in a secondary tab.
  The disabled M2 AI tab is retained per the root contract note.
- Imports present an explicit transcription dialog. A compatible local model
  no longer starts transcription on dialog opening. The dialog shows the
  local/cloud data flow, installed-model prerequisite, inline ElevenLabs key
  entry, and a clear per-take upload checkbox. Neither route starts until
  Transcribe is chosen; cloud still checks its key and consent first.
- The editor shows the active clip in its context line and keeps playback and
  Export visible. Its clip-footer export opens with Selected clips chosen,
  while the top Export opens with Full edit; the existing `ExportSelection.Scope`
  remains the single plan/caption scope for either choice. The clip range list,
  timeline, transcript edits, undo, autosave and renderer are reused. At compact
  widths the inspector overlays, the preview stacks above the transcript, and
  optional aspect controls yield space while clipping actions stay available.
- Local checks before the native pass: UI companion 32 passed, 1 Windows-only
  integration skip; focused agreement receipt tests 5 passed; edited XAML
  parsed and `git diff --check` passed. Native WinUI compilation, owned-window
  captures and keyboard/resize acceptance are recorded in a follow-up entry.

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
