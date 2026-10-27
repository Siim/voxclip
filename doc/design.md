# VoxClip design specification

Status: normative for 0.1.0 (M1), with M2/M3 surfaces marked. Date: 2026-10-26.

This spec covers information architecture, the single-window layouts for macOS and Windows, the transcript editor, the viewer and timeline, the clip list, captions, Voice Lab in context, Home, export and share, onboarding, settings, keyboard shortcuts, states and their exact copy, materials, accessibility, the token system and the design skills used to build it. Tokens live in [`shared/design/tokens.json`](../shared/design/tokens.json); this document explains how to use them. Module placement and threading are in [architecture.md](architecture.md).

Provenance: VoxConvo's web clipper (`vox-web` VoiceRecorder, ClipsPanel, SubtitleOverlay, WordChip, theme), Superscribe's native apps, Apple HIG and WWDC25/26 Liquid Glass sessions, Microsoft Learn WinUI 3 guidance and the skills in section 18, as collected in the planning research (`design.md`).

### Clips-first single-window workspace (2026-10-26; ADR-R29)

This section and the rewritten sections 0, 2, 3, 5, 6 and 7 replace the "Mac workspace correction (ADR-R25)" and "Windows clipping workspace correction" notes, which are withdrawn. The editing contract (editing.md), the document-save and leave boundaries (architecture.md §2.6, editing §10), the export contract (§8 and architecture.md §4), the caption contract (captions.md) and the Voice Lab render contract (voice-lab.md §10) do not change. Everything below is presentation, routing and app-local state.

**Why.** Feedback from the 2026-10-26 review: making clips sat behind a tab or mode that was not active; the start window was a separate window; the interface should follow the platform guidelines. The builds also showed three transport readouts, two different controls labelled "Source", two competing accents, a preview column that was 60% empty, a crowded toolbar, a generic Home with no drop target, a window titled "Untitled", a dense Windows editor and a timeline in which cuts were hard to see.

**The workspace.** Each platform has one window laid out like a music app:

- On the left, a persistent sidebar holds the library (Home) and the open project's clips.
- In the centre, the transcript page is the editor.
- On the right, the viewer and the caption styles share one column.
- Along the bottom, the timeline spans the centre and right columns.
- Export is the one prominent button. It acts on the sidebar row that is selected.

There are no Transcript and Clips modes and no inspector tabs.

**Task walkthrough.**

1. Launch. The window is titled "VoxClip" and shows Home: a drop bar, an AI callout only when one is useful, and recent projects as thumbnails.
2. Drop or import a video. The project opens in the same window. The sidebar shows the project's section with **Full take** selected. The video plays at once, and the transcript shows a skeleton until the words arrive.
3. Cut by words. Select words and press ⌫ / Delete, or use Cut Fillers and Tighten Pauses in the toolbar.
4. Make a clip. Select words. A small action bar appears beside the selection. Choose **Make Clip** (⌘K / Ctrl+K). The new clip appears in the sidebar and is selected.
5. Find clips. Choose **Find Clips** (⇧⌘K / Ctrl+Shift+K) and pick a preset. The results appear in the sidebar under **Suggested**, each with Keep and Dismiss.
6. Shape a clip. Select its row. The transcript marks it, the viewer plays only that clip, and the timeline zooms to it. Choose a Frame (9:16) and a caption style.
7. Export. **Export Clip…** (⌘E / Ctrl+E) opens the export sheet with that clip already chosen.
8. Optional, with Voice Lab on: choose **Rewrite…** on a selection. A panel replaces Captions in the right column. Pick a take and choose **Use Take 1**. The new words show inline in the transcript with an AI marker.
9. Choose Home (⌘1 / Ctrl+1) to see the library. The open project stays in the sidebar. Opening another project saves the open one and replaces it in place.

**What stays the same.**

- Word editing: §4.2, the selection rules and undo per command.
- The keyboard model: §11.1.
- The import sheet and the untranscribed state: §7.1.
- Export, the share helpers and the file name pattern: §8.
- Settings: §10.
- The copy rules: §13.
- Project files, autosave, Save As, Move and Rename, and the dirty-close prompts.
- Clip storage: `ClipRange`, `activeClipId` and the AI results cache.
- The burned-in AI MODIFIED label and the disclosure rules.
- The Mac tour stays opt-in (Help → Welcome Tour).
- The Windows runtime-terms gate (§9).

**Platform differences kept on purpose.**

- **Windows.** Ctrl+N still opens a second main window with the same shell. On macOS there is exactly one main window.
- **Selection bar.** Glass overlay on macOS; `CommandBarFlyout` on Windows.
- **Keeping and dismissing suggestions.** Return and ⌫ on macOS; Ctrl+Enter and Delete on Windows. Plain Enter already invokes a `NavigationViewItem`.
- **Viewer bar.** On macOS the time is on the leading side and the transport on the trailing side. On Windows the transport leads and the time trails.
- **Fine tune.** On macOS it is the disclosure label under the style name. On Windows it is the header of an `Expander`.
- **Sizes.** The sizes that follow each platform's type ramp and minimum targets are given per platform.

**Mockups.** The maintainer keeps the reference mockups outside the repository, each as a PNG with the HTML it was rendered from:

- macOS: `mac/editor-dark`, `mac/editor-light`, `mac/voicelab-dark`, `mac/home-dark`, `mac/editor-1280-light-blue`, `mac/editor-compact-dark` and `mac/states-dark`.
- Windows: `windows/editor-light`, `windows/editor-dark`, `windows/voicelab-light`, `windows/home-light`, `windows/home-empty-light`, `windows/home-dragover-light`, `windows/editor-1280-light`, `windows/editor-compact-light` and `windows/states-light`.

Where a mockup and this specification disagree, the specification wins. Some mockups still show options that were not chosen below.

**Choices made where the mockups disagreed:**

- The current style reads **Box highlight · Edited** with the summary **Paper · As said · 3 words** on both platforms.
- **Frame order** is 9:16 · 1:1 · 16:9 · Original on both platforms.
- **The Rewrite diff** sits in the panel on both platforms. The transcript only marks the passage being rewritten.
- **Provider lines in Rewrite.** Each "Sends…" line sits under its own action.
- **The 9:16 stage** keeps its 180×320 cap on both platforms, and the gallery scrolls below it.
- **The Windows transcript selection** uses a Petrol-tinted `selection.transcript` fill with `text.primary`, not solid Petrol. A selected word and the playing word must not look the same.
- **The gallery check badge** is a white check on a 62% black disc on both platforms.

---

## 0. Design stance

1. **The transcript is the editor.** It gets the widest, tallest region and keyboard focus by default. Everything else supports it.
2. **One window, no modes** apart from recording (M2). The library, cutting, clips, captions, Voice Lab and export all happen in the main window. Clips are always visible in the sidebar; they are never behind a tab.
3. **System controls, system chrome, system fonts.**
   - **macOS 26 and later:** `NavigationSplitView` with a Liquid Glass sidebar and toolbar, sheets, popovers and menus.
   - **Windows 11:** Mica, `TitleBar`, `NavigationView`, `CommandBar`, `InfoBar`.
   - **Type:** SF Pro and SF Mono on macOS; Segoe UI Variable and Cascadia Mono on Windows. Bundled fonts appear only inside rendered video (captions and the AI MODIFIED label).
   - **Identity:** VoxConvo's identity shows through the paper-and-ink palette with its Petrol accent, the 19/32 transcript page and the voice of the copy. There are no custom chrome materials, gradients or glows, and no card nested inside another card.
4. **Every primary action has a key** (Space, J/K/L, Delete, ⌘K, ⌘E, ⌘Z). Single-letter keys work only when focus is not in a text field.
5. **A cut is instant.** The preview skips a new cut on the next frame. There is no "prepare preview" step.
6. **Local-first.** Import, on-device transcription, cutting, captions, export and manual clips work with no key, no account and no network.
7. **Say what leaves the machine.** Every provider action states what it sends, next to the control that sends it ("Sends transcript text only. No audio or video.").
8. **Nothing is lost.** Every error says the media and edits are still here.
9. **One accent, Petrol, spent on state.** Petrol marks what is active: the Export button, the playing word, the selected clip, the switch that is on, the playhead and focus. Clip identity is neutral: numbers, brackets and outlines. The only other hues are vermilion for cuts and recording and amber for fillers and warnings. On macOS a user-chosen system accent replaces Petrol everywhere it is used (§14).
10. **Not in v1:** multitrack timelines, keyframes, B-roll libraries, templates, splash animations, onboarding carousels, account walls, telemetry.

---

## 1. Platform baselines

| | macOS | Windows |
|---|---|---|
| Minimum | macOS 26, Apple silicon (arm64) | Windows 10 19041+; designed and tested on Windows 11 |
| UI stack | SwiftUI views in AppKit windows: one app-owned main window with an `NSDocument` per project (§2), and a Settings window; AppKit for native menus, text and video (`NSTextView` TextKit 2, `AVPlayerLayer`) | WinUI 3, Windows App SDK latest stable (pinned), unpackaged, self-contained |
| Materials | Liquid Glass on chrome only, **no fallbacks** (macOS 26 is the floor). `visibilityPriority` requires the Xcode 27 / Swift 6.4 SDK declaration and macOS 26.1+ at runtime; earlier toolchains keep the same toolbar items without that modifier | Mica on the main and Settings windows; Acrylic only for transient surfaces |
| System font | SF Pro (UI), SF Mono (numbers) | Segoe UI Variable (UI), Cascadia Mono (numbers) |
| Fonts | System only: SF Pro (UI and transcript), SF Mono (timecodes, durations, badges). Bundled fonts (DM Sans, Geist Mono, caption fonts) are used only inside rendered video: captions and the AI MODIFIED label | System only: Segoe UI Variable Text and Display, Cascadia Mono. Bundled fonts only inside rendered video |
| Appearance | follows the system; dark is the hero look for screenshots and the README | follows the system; plus High Contrast |

The release build must carry the current SDK in `LC_BUILD_VERSION` (release.md section 2.3). A binary stamped with an old SDK is drawn with pre-Liquid-Glass controls.

---

## 2. Information architecture

```text
Main window (macOS: exactly one. Windows: one per process window; Ctrl+N opens another)
├─ Sidebar (always visible down to the narrow breakpoints, §3.7)
│  ├─ Home ............................................... ⌘1 / Ctrl+1
│  ├─ {Project name}  (only while a project is open, also while Home is selected)
│  │  ├─ Full take ........................................ ⌘2 / Ctrl+2
│  │  ├─ 1 … n   kept clips, in transcript order .......... [ / ]
│  │  ├─ Suggested                                   [Keep All]
│  │  │  └─ n+1 … m   AI suggestions, each with Keep and Dismiss
│  │  └─ actions (editor only): New Clip from Selection ⌘K · Find Clips with AI ⇧⌘K
│  └─ Recent  (Home only: up to 12 recent projects, excluding the open one)
├─ Detail
│  ├─ Home: drop bar · AI callout (when useful) · Recent projects grid  (§7)
│  └─ Editor (Full take, a clip or a suggestion selected)
│     ├─ Toolbar (macOS) / command row (Windows): title + edit summary · Cut Fillers ·
│     │     Tighten Pauses · Restore Cuts · Find Clips · Export Video… / Export Clip… · viewer toggle
│     ├─ Transcript page (centre) + selection bar: Make Clip · Cut · Restore · Rewrite…
│     ├─ Right column: Viewer (stage, viewer bar, Frame) over Captions, or the Rewrite panel
│     └─ Timeline strip (bottom, under the centre and right columns)
├─ Transient: Find Clips popover/flyout · Import sheet (§7.1) · Export sheet (§8) ·
│     Voice Lab consent and cost confirmations · Keyboard shortcuts
└─ Settings window (⌘, / Ctrl+,): General · Transcription · AI · Export · Accounts (M2) ·
      Voice Lab (M3 beta) · About
```

**Sidebar selection model.** Selection is one value: `SidebarItem = home | fullTake | clip(ClipRange.id)`.

- **Full take** sets `edits.activeClipId = null`. **A clip or suggestion row** sets `activeClipId` to that clip. Both use the existing `setActiveClip` command, so a row change is one undo step that pauses playback (editing §6.3, unchanged). The transcript highlight, the viewer, the timeline, the toolbar summary, Cut Fillers, Tighten Pauses, Restore Cuts and Export all follow `activeClipId`, as they already do.
- **Home** does not change `activeClipId`. It pauses playback and shows Home in the detail area. Leaving Home goes back to the project's current scope.
- **Opening a project.** The selection becomes Full take, unless the project was saved with an `activeClipId`; then that clip row is selected.
- **When the selected clip goes away** through Remove or Undo, the selection becomes Full take.

**Clip list model** (presentation over the unchanged `ClipRange` layer):

- **Kept clips** are every clip with `origin == manual`, plus AI clips with `selected == true`. **Suggestions** are AI clips with `selected == false`. The `selected` field no longer has a checkbox. It now means "kept", and "Export all clips" exports the kept clips.
- **Find Clips** appends its AI result and applies `addAIClips` as it does today. Then it applies `setClipSelected(id, false)` to each newly added clip. The whole run is one undo step named "Find clips". The editing reducer is unchanged; the app composes the commands before one project replacement.
- **Keep** applies `setClipSelected(id, true)` ("Keep clip"). **Keep All** applies it to every suggestion as one undo step ("Keep all suggestions"). **Dismiss** applies `removeClip(id)` ("Dismiss suggestion"). The AI result stays cached.
- **Older projects:** an AI clip left unchecked in the old Clips list now appears as a suggestion. A manual clip left unchecked is still a kept clip. No data migrates.
- **Numbers** are display labels, never stored:
  - kept clips are numbered 1…n in transcript order (start word, then creation order);
  - suggestions continue from n+1 in the same order;
  - numbers are recomputed after every change;
  - accessible names lead with the title, not the number.

**One project at a time per window.**

- **Opening a project** from Recent, File > Open, Open Recent, Finder or Explorer, the Dock, or a drop: the open project goes through the existing leave boundary first. Edits freeze, pending autosaves finish and the final save runs. On macOS an untitled project shows the system keep/delete prompt. The new project then replaces it in place. If the save or the open fails, the old project stays open, editable, with an inline explanation (unchanged from architecture.md §2.6 and the Windows leave rules below).
- **Closing.** Closing a project or its window (⌘W / Ctrl+W or the window's close button) runs the same leave boundary. On macOS, ⌘W then shows Home (§11.2).
- **Busy work.** An export, a transcription or a clip search must finish or be cancelled before the project is replaced or closed. No export can start while a project is leaving, and late results cannot change it.
- **Home** never runs the leave boundary.
- **Windows.** Opening a project that is already open in another Windows main window activates that window.
- **Restart to update (Windows).** **Restart now** (§13) blocks new Settings entry, commits the active Settings text fields, pauses Settings controls and new settings writes, and drains the writes already accepted. Only then does it prepare every open project window on the UI thread: edits freeze, pending autosaves and final writes finish, settings flush and Velopack is invoked once. Busy work, a project transition already in progress, an invalid Settings field, a failed save or cancellation vetoes the restart. A failed updater call restores editing and Settings in every prepared window (architecture.md §13.2).
  - Portable tests cover the settings and project persistence boundaries. A native ARM64 Debug WinUI-thread fake-dispatch probe passed twice with fresh and repeated isolated Settings data, including dispatch-time disk readback of both projects and Settings and restored editability after failures. Native installed-updater termination is still untested.

**Window title.** The project title on macOS: `Project.title`, or the file name without its extension. "VoxClip" while Home is selected. Never "Untitled": an untitled imported project shows the video's file name until it is saved. On Windows the `TitleBar` title is always "VoxClip", and the project title is the command row heading (§3.3).

**Launch.** The main window opens on Home with no project. Windows still honours Settings → General → "Open last project on launch". A launch carrying a project or video opens it as above.

**macOS document model.** `VoxClipDocument` (`NSDocument`) keeps every save responsibility: autosave in place, versions, Save, Save As, Duplicate, Move, Rename, Revert, per-document undo, the keep/delete prompt for untitled projects, and `NSDocumentController` Open Recent.

- **Window ownership.** The document no longer owns a window. One app-owned main window controller hosts the shell, and whichever document is open is attached to it as its window controller's document. It is detached before that document closes.
- **No empty document.** Home is shell state, not an empty document.
- **File > New Project from Video… (⌘N)** opens a movie picker and imports into the main window.

**Windows window model.**

- One process, single instance through `AppInstance`, as before. Launching the app again without a file activates the current window and leaves its project and edits in place.
- Each main window hosts the `NavigationView` shell, and a `Frame` holds the cached Home and Editor pages. Selecting Home keeps the editor page alive; it is not closed.
- Ctrl+N opens another main window on Home.
- The Settings window is unchanged.

---

## 3. Window layouts

### 3.1 Regions and sizes

| Region | macOS (pt) | Windows (epx) | Notes |
|---|---|---|---|
| Window | default 1280×800, min 960×600 | default 1280×800, min 960×600 | Size and position restored per window, not per project |
| Sidebar | floating glass, inset 8, 252 wide (220–320), radius 16 | `NavigationView` pane, `OpenPaneLength` 264 | Holds Home, the project's clips and Recent |
| Toolbar / command row | unified toolbar, 52 high, trailing cluster 36 high | 56 high, padding 16 | §3.5 |
| Transcript page | flex | flex | Measure in §4.1. Gutter 84 (macOS), 76 plus 16 padding (Windows) |
| Right column | default 360 at 1440 and 320 at 1280 (`360 − (1440 − W) × 0.25`), range 300–560, collapsible | default 388 at 1440 and 348 at 1280 (`388 − (1440 − W) × 0.25`), range 300–560, collapsible | W = window width. A dragged width is remembered and wins over the default |
| Timeline strip | 72 high, track 30 | 72 high, track 30 | Spans the centre and right columns, not the sidebar |
| Pane padding | 16 | 16 | Right column, Home, Rewrite panel |
| Radii | controls 6, panes, stage and tiles 10, sheets and the drop overlay 14, sidebar 16 (system) | controls 6, panes, stage, tiles, flyouts and the drop bar 10, the drag overlay 14 | The window corner is the system's (22 on macOS 26) |

There is no Windows footer status row. The edit summary lives under the title.

### 3.2 macOS 26 main window

```text
╭─────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│╭──────────────────────╮  Five questions               (✂ Cut Fillers 4 │ ⇥ Tighten Pauses │ ↺ Restore Cuts) (✦ Find Clips) (Export Video…) (◨)│
││● ● ●              ◧  │  2:10 after cuts · 8 cuts                                                                 │
││ ⌂ Home               │ ─────────────────────────────────────────────────────────────┬──────────────────────────────│
││ Five questions       │   0:00.4   So, u̶m̶,̶ here's the thing nobody tells you…  ‖̶ 1̶.̶6̶s̶ │ ┌──────────────────────────┐│
││ ▭ Full Take    2:10  │                                                             │ │      stage 16:9 328×184  ││
││ 1 ▯ Think in sente…  │   0:16.6 │ [1] The trick is to stop thinking in videos…     │ └──────────────────────────┘│
││     0:17 · ✓ Exported│          │ said [cleanly,] with a clear start…  ‖ 0.9s      │ 0:22.3 / 2:10.1    ↺3  ▶  ↻3│
││ 2 ▯ It has to work…  │          │ …it isn't a clip yet. ]  ‖ 1.6s                  │ Frame      [9:16|1:1|16:9|Original]│
││ 3 ▯ And yeah, I mess…│   0:34.9   ┌[⌗ Make Clip ⌘K][✂ Cut ⌫][↺ Restore ⇧⌫]│[≋ Rewrite… ⇧⌘R]┐ │ ─────────────────────────── │
││ 4 ▯ The best thirty… │   0:39.5   ▓I write five questions on a card, the kind▓…   │ Captions [chip] Box highlight Edited (●)│
││ ✦ Suggested Keep All │                                                             │          › Paper · As said · 3 words│
││ 5 ▯ One habit for…   │                                                             │ Word by word                 │
││     0:16      [✓] ✕  │                                                             │ [ tile ][ tile ]  (2 columns)│
││ + New Clip from Selection ⌘K                                                       │ Phrase …                     │
││ ✦ Find Clips with AI ⇧⌘K                                                           │                              │
│╰──────────────────────╯ ├──────────────────────────────────────────────────────────┴──────────────────────────────│
│                         │ [Edited|Source]  ▕╱╱▏waveform ▕╱╱╱▏ waveform … brackets 1 2 3 4 ┄5┄, playhead ▼         │
╰─────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

Positions at 1440×900 (from `mac/editor-dark.png`):

- **Sidebar:** x 8–260. The traffic lights and the sidebar toggle sit in its top 50.
- **Toolbar title:** x 286.
- **Gutter:** timecodes right-aligned to x 322, clip rule at x 338.
- **Transcript text:** starts at x 352.
- **Right column:** x 1080–1440. The stage starts at y 62.
- **Timeline strip:** y 828–900.

How it is built:

- **Window.**
  - One `NSWindow` owned by an app-level main window controller: `.fullSizeContentView`, `toolbarStyle = .unified`, frame autosave name `VoxClip.main`, `tabbingMode = .disallowed`.
  - Its content is an `NSHostingController` with `WorkspaceView`: a `NavigationSplitView(columnVisibility:)` whose sidebar is a `List(selection:)` over `SidebarItem` with `.listStyle(.sidebar)`.
  - The window is not created per document. `VoxClipDocument.makeWindowControllers()` attaches the main window controller. Closing a project detaches it before `close()`, so the window stays open.
- **Title.** `.navigationTitle` is the project title, or "VoxClip" on Home. `.navigationSubtitle` is the edit summary (§3.5). Both are drawn by the system: 15/600 title, 11 subtitle in `text.secondary`.
- **Detail.** `VStack(spacing: 0) { EditorSplit(transcript | rightColumn); TimelineStrip().frame(height: 72) }`.
  - `EditorSplit` is an `NSSplitViewController` behind `NSViewControllerRepresentable`. It is not an `.inspector`.
  - The transcript item has `holdingPriority = .defaultLow`.
  - The right item has `minimumThickness = 300`, `maximumThickness = 560`, `canCollapse = true` and `holdingPriority = .defaultHigh`.
  - The divider is `.thin`. Autosave name `VoxClip.editor` (one per window, not per project).
- **Glass.** Glass is used only by the system on the sidebar and the toolbar, plus the selection bar (§4.3). It is never used on the transcript, the stage, the gallery, the timeline or sidebar rows. The transcript scroll view keeps `.scrollEdgeEffectStyle(.automatic)`.
- **Menus.** The menu bar mirrors every action (§11.3).

### 3.3 Windows 11 main window

```text
┌────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ≡  ▣ VoxClip                                              (TitleBar on Mica, 48)        ⚙    ─   ▢   ✕    │
├──────────────────────┬─────────────────────────────────────────────────────────────────────────────────────┤
│ ⌂ Home               │ First year at the café       ✂ Cut fillers (5)  ⇥ Tighten pauses  ↺ Restore cuts │ ✦ Find clips │ ◫ Viewer │ ⋯ [Export video…] │
│──────────────────────│ 2:26 after cuts · 11 cuts                                                         │
│ First year at the café│────────────────────────────────────────────────────┬──────────────────────────────│
│ cafe-year-one.mp4    │ 0:31.6 │ Like, u‥h, the first month we sold…          │ ┌ stage ───────────────────┐ │
│▌▭ Full take          │ 0:49.2 │ [2] What changed it was boring…  ]            │ └──────────────────────────┘ │
│   2:26 · AI modified │                                                    │ ↺  (▶)  ↻   [AI modified] 1:37.7 / 2:26.0│
│ ¹▯ Coffee is the easy part                                                 │ Frame   [9:16|1:1|16:9|Original]│
│    0:15 · ✓ Exported │ 1:47.3   ▓Half of what we sell right now…▓        │ Captions                    (●)│
│ ²▯ Opening at six    │          ┌[⌗ Make clip][✂][↺]│[✎ Rewrite…]┐       │ [chip] Box highlight · Edited  Fine tune ⌄│
│ Suggested            │                                                    │ Word by word  [tile][tile] …   │
│ ⁵▯ No second shop yet  ✓  ✕                                               │                               │
│──────────────────────│────────────────────────────────────────────────────┴──────────────────────────────│
│ + New clip from selection  Ctrl+K │ [Edited|Source]  ▕╱╱▏waveform … brackets 1 2 3 4 ┄5┄, playhead          │
│ ✦ Find clips with AI  Ctrl+Shift+K│                                                                        │
└──────────────────────┴─────────────────────────────────────────────────────────────────────────────────────┘
```

How it is built:

- **Window and backdrop.** `<Window.SystemBackdrop><MicaBackdrop/></Window.SystemBackdrop>`, applied once. The window and root grid set no `Background`.
- **`TitleBar`.**
  - Height 48. `Title="VoxClip"`, with the 16 px app icon.
  - `IsPaneToggleButtonVisible="True"`; its `PaneToggleRequested` toggles `NavigationView.IsPaneOpen`. It has no shortcut, because F6 cycles panes.
  - `IsBackButtonVisible="False"`.
  - `RightHeader` holds the Settings gear (`SubtleButtonStyle`, name and tooltip "Settings (Ctrl+,)").
- **`NavigationView`.**
  - `PaneDisplayMode="Left"` at a window width of 960 or more, and `LeftMinimal` below that (set from `SizeChanged`; do not rely on `Auto`). `OpenPaneLength="264"`.
  - `IsSettingsVisible="False"`, `IsBackButtonVisible="Collapsed"`, `IsPaneToggleButtonVisible="False"`: the toggle lives in the `TitleBar`.
  - The items come from the shell view model (§3.4). Clip items carry a `FontIcon` with their number, so a collapsed pane still identifies them.
- **Content layer.** The page paper (`bg.surface`) with `CornerRadius="10,0,0,0"` and a 1 px top and left stroke in `CardStrokeColorDefaultBrush`. Regions inside are split by hairlines (`line.default`), never by nested cards.
- **Content frame.** A `Frame` whose `Content` is set to cached `HomePage` and `EditorPage` instances. Pages are not navigated, so the editor survives Home.
- **`EditorPage` rows:** the command row (56), the work area (`*`) and the timeline (72).
  - The work area's columns are: the transcript (`*`, min 480 plus the gutter), then a splitter (12 epx hit area with a 4×28 grip in `line.strong`, focusable), then the right column (300–560).
  - Window-level notices (the project saved in VoxClip's folder, update ready) use the existing `WindowNotice` `InfoBar` above the content frame. Editor notices (transcription status, provider errors) use an `InfoBar` at the top of the transcript column. No custom banners.
- **Shortcuts.** A `KeyboardAccelerator` on every command. Tooltips show the shortcut.

### 3.4 Sidebar rows

**Shared order:**

1. Home.
2. A separator (Windows) or section gap (macOS).
3. The project header.
4. Full take.
5. The kept clips.
6. The "Suggested" sub-header and the suggestions (omitted when there are none).
7. The actions: New Clip from Selection and Find Clips with AI. These are shown only while the editor is showing.
8. On Home only, "Recent" and up to 12 recent projects, excluding the open one.

| Element | macOS | Windows |
|---|---|---|
| Nav row (Home, Recent items) | 30 high; Recent thumbnails 36×20 | 40 high; Recent thumbnails 32×18, two lines (title, then "2:36 · Today" in 12 `text.secondary`) |
| Project header | `Section` header: project title only, 11/600 `text.secondary` | `NavigationViewItemHeader`: title 14/20 semibold over the file name, 12 `text.secondary` |
| Full take row | 58 high; 16 badge column left empty; 36×20 landscape thumbnail centred in a 36 column; "Full Take" 13/500; meta | 44 high; 32×18 thumbnail; "Full take" 14; meta |
| Clip row | 58 high (74 with a second status line); 16 badge column; 26×46 thumbnail (9:16); title 13/500, one line, truncated at the tail; meta 11 | 60 high (76 with a second status line); 27×48 thumbnail in a 32 column with the 16×16 badge over its top-left corner (offset −4, 1 px page ring); title 14 at x 60; meta 12 |
| Selection | native `List` selection, radius 10. Unfocused: neutral system fill. Focused (`backgroundProminence == .increased`): system accent fill and white text; the badge becomes a 1 px white outline with a white numeral; meta and the Exported glyph are white at 88%; the thumbnail gets a 1 px white 55% ring | native `NavigationView` pill (Petrol through the accent override) with the subtle selected fill |
| Suggested sub-header | sparkles + "Suggested" 11/600 `text.secondary`, with a borderless **Keep All** on the right | `NavigationViewItemHeader` "Suggested", or "Suggested (N)" from 2 up, with a **Keep all** `HyperlinkButton` on the right |
| Suggestion row | as a clip row; on line 2, right-aligned, a bordered 24×24 ✓ (Keep, tooltip "Keep (Return)") and a borderless 24×24 ✕ (Dismiss, tooltip "Dismiss (⌫)") | as a clip row; two trailing 32×32 subtle icon buttons ✓ and ✕ (tooltips "Keep (Ctrl+Enter)" and "Dismiss (Delete)"). Their `Tapped` handler sets `e.Handled = true` |
| Actions | borderless `Button`s in the section footer (not rows, never selectable, never arrow-key stops): 28 high, label 13, glyph `text.secondary`, key hint SF Mono 11 `text.secondary`. Disabled: label and glyph `text.tertiary` at 55% | `NavigationViewItem`s with `SelectsOnInvoked="False"`, the shortcut as trailing 12 `text.secondary` text, `IsEnabled` bound |

**Meta line grammar.** The duration, a separator, then one status:

- The duration is the edited length of the clip or of the full take, from the same edit plan as the viewer and export, as `m:ss` in SF Mono 11 or Cascadia Mono 12, `text.secondary`.
- The separator is " · ".
- The status is one of:
  - **Exported:** `checkmark.circle.fill` or the Segoe Fluent Icons check-circle glyph (11 or 12, `text.secondary`) and "Exported".
  - **AI modified:** "AI modified", when the scope contains accepted AI speech. This shows on Full take too.
  - **Edited since export:** a warning glyph and "Edited since export" in `status.warning`, on its own second line.
  - **Exporting:** "Exporting 42%" with a 12 pt determinate ring.
  - **Export failed:** a warning glyph and "Export failed" in `status.warning`, with a trailing **Retry** text button.
  - **Suggested** (Windows only, in `text.secondary`; macOS shows it through the sub-header).
  - **Transcribing:** "Transcribing · 42%" with **Cancel** (Full take row, while transcribing).
  - **Not transcribed:** "Not transcribed" (Full take row, §7.1).
  - With no status, the duration stands alone.

Export statuses come from an app-local export ledger (§6.2), not from the project file.

**Badges.**

- **Neutral, the default:** 16×16 (macOS) or 16×16 overlaid (Windows). Radius 4. Numeral in SF Mono 11/600 or Cascadia Mono 11/600, `text.secondary`, on `clip.badgeBackground`.
- **Selected clip:** the accent fill (macOS `Color.accentColor`; Windows `AccentFillColorDefaultBrush`) with `accent.on` or `TextOnAccentFillColorPrimaryBrush`.
- **Suggestion:** a 1 px dashed `line.strong` outline with a `text.secondary` numeral.
- **Full take scope:** every badge is neutral.

**Thumbnails.**

- A clip shows the first kept frame of the clip (the start of its first uncut word), centre-cropped to 9:16. The full take shows the first kept frame of the edited video at its own aspect.
- Thumbnails are generated off the main thread and cached by `(media contentKey, source time rounded to 0.1 s, pixel size)`. They regenerate when the clip's first kept word changes.
- Border: a 1 px `line.default` hairline, radius 4.
- Frames come from VoxClip's own decoder, never from the system shell (§5.4.7).
- With no frame, the thumbnail is the caption card at sidebar size: a downscaled card with no plates (§5.4.3). Loading follows the §5.4.5 ladder, and the media states are in §5.4.4.

**Accessibility.**

- Row names:
  - "Clip 2, It has to work on mute, 20 seconds, exported".
  - "Suggested clip 5, One habit for a bad week, 16 seconds".
  - "Full take, 2 minutes 10 seconds after cuts".
- Keep and Dismiss: "Keep suggested clip 5" and "Dismiss suggested clip 5".
- After Keep or Dismiss, announce "Clip 5 kept" or "Suggestion dismissed" and move focus to the next row. If there is none, focus goes to Full take.
- Under Reduce Transparency or Increase Contrast, the sidebar is opaque `bg.elevated` with a 1 px `line.strong` edge. On macOS the system does this; the custom parts follow it.

### 3.5 Toolbar (macOS) and command row (Windows)

**Edit summary**, scoped to the selected row. It is the subtitle on macOS and the second line of the heading on Windows.

- **Full take:** "{edited} after cuts · {n} cuts", for example "2:10 after cuts · 8 cuts".
- **A clip or suggestion:** "Clip {k} · {edited} after cuts · {n} cuts", for example "Clip 2 · 0:20 after cuts · 2 cuts".
- **No cuts in scope:** "Clip {k} · {edited} · No cuts yet", or "{edited} · No cuts yet" for the full take.
- **Counting:** `n` is the number of maximal runs of consecutive cut words, plus the number of cut pauses, inside the scope. The app computes it; `EditSummary` is unchanged. Use "1 cut" for one.
- **Tooltip:** "{source} source · {w} words cut in {r} places · {p} pauses cut".
- **Busy states:** while a state from §13 holds ("Keep at least one word before exporting.", "Editing is not available in this build…"), the summary shows that text instead.

**macOS toolbar.** All leading space is the title and summary. The trailing cluster is 36 high:

1. A `ToolbarItemGroup`, drawn as one glass capsule, with `.labelStyle(.titleAndIcon)`:
   - **Cut Fillers** with the count as trailing `text.secondary` text (`scissors`, ⌥⌘U);
   - **Tighten Pauses** (⌥⌘P);
   - **Restore Cuts** (`arrow.uturn.backward`, ⌥⌘R).

   Each is disabled when its `EditSummary` flag is false for the scope.
2. `ToolbarSpacer(.fixed)`.
3. **Find Clips** (`sparkles`, ⇧⌘K). It opens the Find Clips popover (§6.2).
4. **Export Video…** or **Export Clip…** (⌘E), with `.buttonStyle(.glassProminent)` and `.visibilityPriority(.high)` on macOS 26.1 or later. This is the only prominent control. Disabled with the tooltip "Keep at least one word before exporting." when `!canExport`. With a suggestion selected it is disabled with "Keep this clip to export it."
5. **Hide Viewer / Show Viewer** (`sidebar.trailing`, ⌥⌘I).

There is no Play button in the toolbar.

At window widths below 1100 the capsule is icon-only: the scissors with the count, then tighten, then restore, with tooltips that carry the names and shortcuts. On Home the toolbar shows only the search field (§7).

**Windows command row.** 56 high, padding 16.

- **Heading:** the title in Segoe UI Variable Display 600 18/24, over the summary in 12/16 `text.secondary`. It truncates at the tail.
- **`CommandBar`** (`DefaultLabelPosition="Right"`, `IsDynamicOverflowEnabled="True"`):
  - **Cut fillers (N)** (Ctrl+Shift+U), **Tighten pauses** (Ctrl+Shift+P), **Restore cuts** (Ctrl+Shift+R). Each is disabled when there is nothing to act on in the scope.
  - `AppBarSeparator`.
  - **Find clips** (Ctrl+Shift+K).
  - **Viewer**, an `AppBarToggleButton` (Ctrl+Shift+I). Its checked state is restyled to the subtle fill, so it is not a second accent block.
  - **⋯** with: Rewrite… (Ctrl+R, Voice Lab on), Make clip (Ctrl+K), Show cut words (Ctrl+Shift+H), Show pauses, Find (Ctrl+F), Undo (Ctrl+Z), Redo (Ctrl+Y), Save project as…, Show project file, Transcribe again…, Keyboard shortcuts (F1).
- **Export** is a separate `AccentButtonStyle` button outside the `CommandBar`: 40 high, padding 0,16, radius 6. It reads "Export video…" or "Export clip…" (Ctrl+E). Its accessible name adds ", contains AI-modified speech" when the scope does. It is disabled with the tooltip "Keep at least one word before exporting." when nothing can be exported, and with "Keep this clip to export it." when a suggestion is selected.

### 3.6 Right column

From the top:

1. **The viewer** (§5.1): the stage, the viewer bar and the Frame row.
2. **A hairline.**
3. **Captions** (§6.1), which fills the rest of the column and scrolls. While Rewrite is open, the Rewrite panel (§6.3) replaces Captions.

The column background is the page (`bg.surface` on Windows). On macOS it is the window background behind the split, with no card and no inset. Pane padding is 16.

### 3.7 Narrow widths

| Width | macOS | Windows |
|---|---|---|
| ≥ 1440 | Sidebar, transcript measure 680, right column 360 | Pane, measure 680, right column 388 |
| 1280 (default) | measure about 580, right column 320. The Captions header wraps to two rows below a column width of 340 | measure 560, right column 348 |
| Transcript pane would drop below 596 (macOS) or 588 (Windows), about 1150 window width | The right column collapses first. "Show Viewer" (⌥⌘I) and View > Show Viewer bring it back; showing it at this width hides the sidebar to make room. The timeline gains the compact transport (§5.3). Below a window width of 1100 the toolbar capsule is icon-only (§3.5) | The right column collapses first. The Viewer toggle brings it back, and showing it hides the pane (`IsPaneOpen = false`). The timeline gains the compact transport. `CommandBar` overflow takes Tighten pauses and Restore cuts |
| < 960 | Only reachable in full screen or Split View. The sidebar collapses (`columnVisibility = .detailOnly`); the toolbar sidebar button brings it back as an overlay | `NavigationView` goes `LeftMinimal`; the `TitleBar` pane toggle opens it as an overlay |

The sidebar collapses last, because it holds the clips. While the viewer is collapsed, caption styling is unavailable until Show Viewer. The Export sheet still offers the caption style picker.

---

## 4. The transcript editor (primary surface)

### 4.1 Rendering

- **Flowing prose, not chips.** A new paragraph starts after a sentence end followed by a pause of ≥ 1.5 s, or at a speaker change when diarization exists.
- **Gutter.**
  - It shows the paragraph start as a timecode in `m:ss.d`, or `h:mm:ss.d` past one hour, in SF Mono 11 or Cascadia Mono 12, `text.tertiary` (5.23:1 light, 5.41:1 dark). Timecodes are right-aligned.
  - Each clip's rule is 2 wide, running from the clip's first line to its last.
  - Speaker labels sit under the timecode.
  - **macOS:** gutter 84; timecodes end 30 before the text; the rule sits 14 before the text.
  - **Windows:** the page padding (16) sits outside the gutter; timecodes occupy x 16–72, the rule is at x 82, and the text starts at x 92.
- **Type and measure.** The transcript is SF Pro or Segoe UI Variable Text, 19/32, with an 18 (macOS) or 20 (Windows) paragraph gap.
  - Zoom runs 13–28 with ⌘+/⌘−/⌘0 (Ctrl+=/Ctrl+−/Ctrl+0), and the line height scales at 32/19.
  - The measure is `min(680, pane − gutter − 32)` on macOS and `min(680, pane − 108)` on Windows, with a floor of 480. That gives 680 at 1440, about 580 at 1280, and 640 at 1024 with the viewer collapsed.
- **Never one view per word.**
  - **macOS:** one non-editable, selectable `NSTextView` using TextKit 2 (`NSTextLayoutManager`), wrapped in `NSViewRepresentable`. Keep a sorted map word index ↔ character range (binary search both ways). Word colours are applied as rendering attributes (no relayout). TextKit 2 does not draw strikethrough or underline from rendering attributes, so a custom `NSTextLayoutFragment` (via `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)`) draws them: the cut strike, the filler and low-confidence underlines, and the rounded backgrounds of the playing word (`radius.xs`) and cut pause tokens (`radius.sm`) behind the glyphs. A test checks the decorations by pixels on an offscreen render, not by reading attributes back. Selection snaps to whole words in `textView(_:willChangeSelectionFromCharacterRanges:toCharacterRanges:)`. Layout-changing operations (zoom, "Hide cut words") rebuild only the affected paragraphs' text storage. TextKit 2 lays out only the viewport, so hour-long takes stay smooth.
  - **Windows:** a virtualised list of paragraphs: `ItemsRepeater` (vertical `StackLayout`) in a `ScrollViewer`, one item per paragraph, each item a `RichTextBlock` with one `Paragraph` holding one `Run` per word (plus a trailing space) and one `Run` per pause token. Runs are text elements, not views. Word states use `Run.Foreground` and `RichTextBlock.TextHighlighters` (selection). Cut words get no `TextDecorations` strikethrough: the overlay below draws the strike, the underlines and the playing-word fill. Native `IsTextSelectionEnabled` is off; VoxClip keeps its own word-snapped selection model across paragraphs, hit-tests with `RichTextBlock.GetPositionFromPoint` and maps `TextPointer.Offset` to word indices. Inline correction uses a `Popup` with a `TextBox` placed at `TextPointer.GetCharacterRect`.

    Decorations that XAML text cannot draw come from one overlay per paragraph with `IsHitTestVisible="False"`: a Composition `ShapeVisual` layer positioned from `TextPointer.GetCharacterRect` for each `Run`. It draws the vermilion strike (over cut words and cut pause chips), the dotted and dashed underlines, the rounded background of the playing word, the Rewrite outline and the gutter rules. It rebuilds on `SizeChanged`, zoom and state changes. Clip badges, the AI chip and cut pause tokens are `InlineUIContainer`s: a `Border` with `CornerRadius` 4 or 6 around a Cascadia `TextBlock`, with `AutomationProperties.Name` set to "Clip 2 starts", "AI words" or "pause 1.6 seconds, cut". Offscreen pixel tests cover the overlay, as on macOS.
- Right-to-left scripts use natural writing direction, and the gutter moves to the trailing edge.

Word states (each shown by more than colour):

| State | Treatment |
|---|---|
| Normal | `text.primary` |
| Playing | Accent fill (macOS `word.playingBackground`, which follows `Color.accentColor`; Windows `AccentFillColorDefaultBrush`) and accent-on text (`word.playingForeground` / `TextOnAccentFillColorPrimaryBrush`). Radius 4, 2 inline padding |
| Selected | macOS: the system selection colour (`NSColor.selectedTextBackgroundColor`; Petrol-derived #C5D7D4 light, #1F4C4B dark with the Multicolor accent). Windows: `selection.transcript` (the same values) with `text.primary`. A selection never looks like the playing word |
| Cut | `word.cut` text with a 1.5 strike in `cut.stroke` on both platforms. The word stays readable and restorable. With "Hide cut words" (⇧⌘H / Ctrl+Shift+H) a run of cut words still collapses to an SF Mono or Cascadia Mono token `⋯ 5 cut` on `pause.background`, radius 6 |
| Pause (detected gap), uncut | inline token `‖ 1.8s` in SF Mono 13 or Cascadia Mono 12, `text.muted`, **no fill** (8.04:1 dark, 6.77:1 light). Shown for gaps ≥ the project's `pauseThresholdSeconds` (editing spec: 0.8 s with decoded audio, else 1.0 s, set at import; not a setting in 0.1.0) |
| Pause, cut | the same token on a `pause.background` chip, radius 6, `text.muted` (6.67:1 / 5.92:1), with the `cut.stroke` strike |
| Suggested filler | a dotted underline in `word.filler`, 1.5 (macOS) or 2 (Windows) wide; tooltip "Filler · Delete to cut" |
| Low confidence (if the engine reports it) | dashed underline `word.lowConfidence`; off by default (Settings → General) |
| Corrected | normal text with a 2 pt dot under the first letter (`word.correctionDot`); tooltip "Heard as: {original}" |
| Clip start | an inline badge before the clip's first word (§3.4 badge rules) and the gutter rule. Neutral unless the clip is selected; selected: an accent badge and an `accent.text` rule. Suggestions: a dashed badge and a dashed rule |
| Clip end | a `]` bracket glyph after the last word, `line.strong`, or `accent.text` when selected (dashed for suggestions) |
| Rewrite passage (Voice Lab open) | an `accent.soft` fill and a 1 px `accent.text` outline, radius 4 |
| AI words (accepted) | an "AI" chip at the start (§6.3) and a 1 px dashed `accent.text` underline. Description adds ", AI modified" |
| Outside the selected clip | `text.secondary` (7.34:1 dark, 6.56:1 light), **no opacity**. Cut words there keep `word.cut` and the strike; timecodes stay `text.tertiary`; other clips stay neutral |

Live transcript while recording (M2): partial words in `text.muted` italic; a "Jump to live ↓" pill appears when the user scrolls up.

### 4.2 Interaction

| Gesture | Result |
|---|---|
| Click a word | Caret and selection on that word. When paused, the playhead moves to the word's start so the frame updates |
| Drag / ⇧-click / ⇧← → | Extend the selection by whole words |
| Double-click a word | **Correct** in place: an inline field sized to the word, text selected. Return saves, Esc cancels, Tab saves and moves to the next word. Correcting changes caption text only; the audio stays the same |
| Triple-click | Select the sentence |
| ⌫ / Delete on a selection | **Cut.** If the whole selection is already cut, **restore** it (toggle, like VoxConvo's tap to cut, tap again to restore) |
| ⇧⌫ / Shift+Backspace | Restore the selection |
| ⌥-click / Alt-click | Play from that word |
| Right-click | Context menu: Make Clip (⌘K) · Cut · Restore · Rewrite… (Voice Lab on) · Correct Spelling… · Play from Here · Preview This Cut (P) · Copy Text. With a caret between words and Voice Lab on: Insert Words… |
| Drop a file on the window | The whole-window overlay (§7). With a project open, it is saved first, then the new video opens in its place |

After every cut the edit summary updates (§3.5) and VoiceOver or Narrator announces "Cut 'um'". Undo groups by command: one Cut Fillers is one undo step.

- **Cut fillers** cuts every item for which the editing spec's `isFiller` is true (section 6.2): VoxConvo's `um+, uh+, erm+, hmm+` with one optional trailing `, . ! ?`, plus every `…` (unlabeled speech) item. The rule is not editable in 0.1.0 (per-language lists are deferred, editing spec section 12). The label carries the count (§3.5); disabled at N = 0.
- **Tighten pauses** cuts every detected pause in the current scope and keeps a breath next to each kept word. The breath is a named choice in Settings → General (`editing.pauseBreath`) that sets the editing spec's `pauseKeepSeconds`: **Tight** 0.05 s · **Natural** 0.15 s (default, the editing spec default) · **Relaxed** 0.30 s. New projects take it at import; changing it applies to every open project (one undo step each).
- **Restore cuts** restores the word and pause cuts in the current scope (the active clip, or the whole take) and keeps spelling corrections and clips.
- **Find** (⌘F / Ctrl+F) opens a find bar above the transcript; matches highlight, ⌘G / ⇧⌘G (F3 / Shift+F3) step, and **Cut all N** cuts every match.

### 4.3 Selection bar

When the user selects one or more whole words with the pointer or the keyboard and stops, a small bar appears next to the selection.

**Contents.**

| | macOS | Windows |
|---|---|---|
| Control | custom glass bar: an overlay in the `NSScrollView` document view's coordinates with `.glassEffect(.regular, in: .rect(cornerRadius: 10))`, 36 high | `CommandBarFlyout` on Acrylic, radius 10, 40 high |
| Items | **Make Clip** ⌘K (default, highlighted with the neutral fill of an unfocused sidebar selection) · **Cut** ⌫ · **Restore** ⇧⌫ · divider · **Rewrite…** ⇧⌘R (Voice Lab on). Labels 13 with SF Mono 11 key hints in `text.secondary` | **Make clip** (labelled) · **Cut** and **Restore** (icon only, tooltips "Cut (Delete)" and "Restore (Shift+Backspace)") · separator · **Rewrite…** (labelled, Ctrl+R; Voice Lab on). The flyout is restyled so the two primary commands keep their labels |

Restore is disabled when nothing in the selection is cut. When the selection already equals a clip, Make Clip's tooltip reads "Clip 2 already covers these words", and choosing it selects that clip (§6.2).

**Placement.**

- The bar sits 8 above the first selected line, starting at the selection's leading x − 4.
- It may cover the line above while it shows, but never the selected words.
- If the line above is under the toolbar or the window edge, the bar flips to 8 below the last selected line.
- On Windows, the flyout also prefers the side that covers only unclipped text when the line above is inside a clip and the line below is not.

**Behaviour.**

- The bar hides while the user drags or scrolls. It reappears 150 ms after mouse-up or after scrolling stops.
- Esc dismisses it.
- It does not appear during inline correction or while the find bar has focus.

**Keyboard.**

- **macOS:** Tab or ⌃F6 from the transcript moves focus into the bar, and Esc returns focus to the selection.
- **Windows:** Shift+F10 or the Menu key opens the flyout in Standard mode with focus on Make clip, and Esc returns to the words.
- All commands are also in the transcript context menu and in the Edit and Clip menus (macOS) or ⋯ (Windows). On macOS they are also VoiceOver custom actions on the selected range.

**Materials.** Under Reduce Transparency or Increase Contrast (macOS), and with Transparency effects off or a contrast theme (Windows), the bar is opaque `bg.elevated` with a 1 px `line.strong` edge (3.41:1 / 3.35:1).

**Motion.** It appears with a crossfade of 150 ms or less and no scale or slide. Under Reduce Motion it appears without animating.

---

## 5. Viewer, transport and timeline

### 5.1 Viewer

**Stage.**

- Black (`stage`), radius 10. On macOS it is concentric with the column (`.rect(corners: .concentric)`, with 10 as the design value).
- It sits at the top of the right column with 16 padding. On macOS it starts at y 62.
- Content: the edited result of the current scope. A new cut shows on the next frame (architecture.md §5 and §6).
- **Frames:**
  - 16:9 and Original-landscape fill the column's inner width: 328×184 at 360, and 355×200 on Windows at 388.
  - 9:16 and 1:1 are centred, at most 320 high and never wider than the inner width (180×320 for 9:16). A 9:16 or 1:1 frame is a centre crop of the source with no pillar bars, as in export.
  - While Rewrite is open and the column is shorter than 760, the stage drops to 220×124 (16:9; other frames fit inside a 124-high box). On Windows the time, the AI tag and the transport stack beside it. On macOS the viewer row stays under it.
- There is no transport pill and no overlay on the stage except the caption overlay and the compositor's AI MODIFIED chip. The one exception: with no video, the stage shows the §5.4.6 overlays (the message, the word rhythm, the audiogram and the status chip). None of them is interactive; Locate… stays in the transcript InfoBar.
- **Caption position.** The caption block on the stage is draggable and snaps to the centre line and the thirds. While dragging, safe-zone guides for the frame appear (9:16: bands over the top 12% and the bottom 22%). This is unchanged.

**Viewer bar.**

- **macOS**, one row 34 high:
  - leading, the edited time in SF Mono 12: "0:22.3 / 2:10.1", with the total in `text.secondary`;
  - when the rate is not 1×, " · 1.5×" in `text.secondary`;
  - when the scope contains accepted AI speech, an **AI modified** tag before the time: 11 pt, 1 px `accent.text` outline, radius 4, `accent.text` text;
  - trailing: **Back 3 seconds** (28 pt, `gobackward.3`, tooltip "Back 3 Seconds (J)"), **Play/Pause** (34 pt round neutral button, Space), **Forward 3 seconds** (28 pt, `goforward.3`, tooltip "Forward 3 Seconds", no key; L is shuttle).
  - `gobackward.3` and `goforward.3` are custom symbols exported from the `gobackward` template and bundled with the app.
- **Windows**, row 1 is 40 high:
  - leading: Back 3 seconds (32 subtle icon button, name "Back 3 seconds (J)"), Play (40 round, `ControlFillColorDefaultBrush` fill, 1 px `ControlStrokeColorDefaultBrush`, ink glyph), Forward 3 seconds (32, name "Forward 3 seconds");
  - trailing: the AI modified tag (12, 1 px `accent.text`, 5.94:1), then the time in Cascadia Mono 13.
- **Frame row:** 24 high on macOS, 32 on Windows. The label "Frame" (13 or 14 `text.secondary`) leads.
  - The control: macOS `Picker(.segmented)` with `.labelsHidden()`; Windows `CommunityToolkit.WinUI.Controls.Segmented`.
  - The options, in this order: **9:16 · 1:1 · 16:9 · Original**. The selected label is semibold, as a cue that does not depend on colour. On Windows the selected segment has a white knob with a 1 px `line.strong` stroke.
  - The control reads and writes `export.aspect`, whose persisted values (`portrait`, `square`, `landscape`, `source`) and file suffixes (§8) do not change. Only the label "Source" becomes "Original".
  - Face-tracked reframe (M2) adds a "Follow face" toggle to this row.
- A hairline follows.

**Accessibility.**

- The stage's accessible name: "Video preview, clip 2", or "Video preview, full take". It adds ", contains AI-modified speech" when the scope does. With no video it also adds the media state: "Video preview, full take, video not found", "…, video can't be read", "…, audio only" or "…, demo project" (§5.4.6).
- The time is a live region, updated at most once a second for screen readers.

### 5.2 Timeline strip (72)

Layout, left to right:

- the compact transport, only while the viewer is collapsed (§5.3);
- the **Edited | Source** toggle: native segmented, 24 high on macOS, 32 on Windows, Source selected by default;
- the track, which fills the rest.

There is no time readout and no "after cuts · source" label; the viewer bar owns the time and the toolbar owns the summary.

| Element | Spec |
|---|---|
| Track | 30 high, radius 6, `timeline.track`. In Source mode it covers the whole take (Full take scope) or the clip ± padding (clip scope). In Edited mode cuts collapse into 1 px `cut.stroke` seams |
| Kept speech | `timeline.keptBackground`, with RMS waveform bars (50 ms buckets) in `timeline.waveform`, centred, 2 px wide on a 3 px pitch. With no envelope, one capsule per kept word (§5.4.10) |
| Cut word range | 16% `cut.stroke` fill, plus a 45° hatch in full `cut.stroke`, 2 px stripes every 6 |
| Cut pause range | 10% `cut.stroke` fill, plus the same hatch with 2 px stripes every 9. Stripe spacing tells pause cuts from word cuts, not opacity |
| Uncut pause | the track shows through |
| Remaining fillers | a 2 px `word.filler` bar along the base, inside the track |
| Clip brackets | above the track: a 2 px line with 6 px end ticks and a badge at the start, in `line.strong` with the neutral badge (§3.4). The selected clip uses `accent.text` with the accent badge. A suggestion is dashed. Badges: 16 (macOS) or 18 (Windows), radius 4 |
| Word selection | a band in the platform selection colour with 1.5 px `accent.text` edges |
| Rewrite passage | an `accent.soft` band with a 1 px `accent.text` outline |
| Playhead | a 2 px `timeline.playhead` line with a 12×7 head above the track. Edited playback jumps over cuts |
| Clip scope | zooms the track to the clip ± `clamp(0.1 × clip length, 1.5 s, 3 s)` and dims outside the clip with `timeline.scopeDim`. The zoom animates over 240 ms and switches without animating under Reduce Motion |
| Trim handles (clip scope) | 7×36 in `accent.text` at the clip edges, with invisible 24-wide hit regions. Dragging snaps to word boundaries and applies `updateClip` (one undo step, "Trim clip") |
| Interaction | Click or drag anywhere on the 30 px track to scrub. ⇧-drag snaps to word starts. The hover tooltip names the word under the pointer ("cadence · 0:12.4"). Double-clicking a cut region restores it |

No other zoom in v1. Full take always fits.

**Accessibility.**

- The strip is one slider (macOS: `Canvas` with `.accessibilityRepresentation { Slider }`; Windows: a `RangeValue` automation peer). Its name is "Playhead", and its value reads like "22 seconds of 2 minutes 10 after cuts, 8 cuts". ← and → step by one word, ⇧← and ⇧→ by one sentence, Home and End go to the ends.
- The trim handles are separate adjustable elements, "Clip 2 start" and "Clip 2 end", that step by one word.
- Edited | Source is a two-option picker named "Timeline time".

### 5.3 Compact transport (viewer collapsed)

At the strip's leading edge:

- a round Play: 28 pt (macOS) or 32 epx (Windows), neutral;
- the edited time in SF Mono 12 or Cascadia Mono 13, with the total in `text.secondary`;
- then Edited | Source.

Space, J, K and L work as always. The track takes the remaining width.

### 5.4 Media stand-ins

When VoxClip has no frame to show, it shows **the project's own words in the project's own caption style**. This stand-in is the **caption card**. It is used wherever media stands in: Home tiles, sidebar thumbnails, the caption header chip and gallery (§6.1) and the stage (§5.1).

**Mockups.** The maintainer keeps the placeholder mockups outside the repository, each a PNG rendered by a script kept beside it: `before-after.png`, `windows-home-light.png`, `windows-home-dark.png`, `mac-home-light.png`, `mac-home-dark.png`, `windows-editor-light.png`, `windows-editor-light-frames.png`, `mac-editor-dark.png`, `mac-editor-dark-frames.png`, `surfaces-light.png` and `surfaces-dark.png`. Where a mockup and this section disagree, this section wins.

#### 5.4.1 Principle

**Precedence.** Each surface uses the first source that is available:

1. **A real frame.** This is the first kept frame of the scope (§3.4), cached. It always wins: there is no stand-in while transcribing if a frame exists, and none for a video whose first frame is black (§5.4.7).
2. **The caption card.** It needs only the project file and the bundled caption resources, so it works on any computer and after the cache is cleared.
3. **Stage black** with a status chip, when there are no words either (never transcribed, or every word of the scope cut).

Each Core decides this precedence once, with `MediaStandIn.resolve` (Windows: `Resolve`). It takes the scope's `MediaStatus` (the states of §5.4.4), whether a frame is ready, the card, and whether the first 300 ms hold of §5.4.5 is still running. Views draw the result, overlay the status's chip and copy, and never decide precedence themselves. A card without words draws only the style's backdrop, as while transcribing with no frame yet. The shared cases are the `standIns` of `shared/fixtures/captions/cards.json`.

The card replaces every earlier stand-in, and the apps remove them: the shell's file-type icon and the `SymbolIcon Video` fallback on Windows Home, "Your video will appear here." and the DEBUG person-icon "Synthetic preview" frame on the macOS stage, and "Preview unavailable. Your video and edits are still here." on the Windows stage.

#### 5.4.2 The card's words

The words are the **opening caption page of the scope**. They come from the scope's export captions, the caption copy over the edit plan (editing spec §7.6), so cut words and cut pauses are left out and corrections apply.

- **Scope.** Home tiles and the Full take row use the edited take; a clip row uses the clip's own first kept words. The header chip follows the selected row's scope: the edited take or the selected clip. The stage and the gallery never draw the opening card. They draw the caption at the playhead over the card backdrop (§5.4.4, §6.1).
- **Style.** The project's caption style with `captions.overrides`, resolved at the project's export frame (`export.aspect`), so case, punctuation and words per page are what export would draw. An override patch the style rejects is ignored (captions spec §2.4). With captions off, the card uses `captions.defaultStyleId`, or Highlight (`vox-highlight`) when that is off too.
- **Text.** Each word is normalised as the caption renderer normalises it (captions spec §3.1). Characters that no bundled font covers are dropped (captions spec §4.4), and a word left with nothing is skipped.
- **Pages.** Words are paged as captions spec §6.1 pages them, with `layout.maxWords` capped at **4**. The fit waits until the card is drawn (§5.4.3). One-word styles (Bold, Highlight, Bold+, One word) give one word.
- **Weak words** are fillers (the editing filler rule, editing spec §4.11) and the stopwords of the transcript language (`shared/caption-styles/stopwords.json`). A language with no stopword list has no weak words, so its card is its first page as it is.
- **Skipping.**
  - Skip leading fillers, unless every word is one.
  - Use the first page that has a word that is not weak, or the first page when none has.
  - Trim trailing weak words, keeping at least one word.
- **Key word.** The first word with a digit, otherwise the first word that is not weak, otherwise the first word. It gets the style's active-word or emphasis treatment:
  - Karaoke fills up to and including it;
  - Pop and Two-tone colour it;
  - Box highlight boxes it;
  - Editorial uses its gold;
  - Neon dims the words after it.
- **The drawn moment.** A card is one caption frame at a fixed moment, as a gallery tile is (captions spec §15.3). Word *i* runs from 0.4·*i* to 0.4·*i* + 0.35 s, and only the key word carries emphasis.
  - The frame is taken 0.35 × 0.98 s into the key word *k*, at 0.4·*k* + 0.343 s, as a gallery tile's is. A page shows only until its last word ends plus the style's `holdGapSec`, and Bold and Highlight hold nothing, so a frame at the word's end would be empty.
  - Styles that reveal by word or by character (Typewriter, Bounce) are drawn in their last word instead, so every word on the card shows: at its end while the style holds the page after it, otherwise 0.343 s into it.
  - A card never animates.
- **No words.** There is no card when `transcript == null`, when every word of the scope is cut, or when no word survives the rules above (states c and d in §5.4.4).
- **Words hidden.** Settings → General → **"Show transcript words on placeholders"** (`general.showPlaceholderWords`) is **on** by default. When it is off, the card sets the **project title** instead of transcript words, with the same style, skipping and key rules and with no timing breaks. The title already shows under the tile, so nothing new is exposed when sharing a screen. The switch changes only the text: a project with no card still has none, and an untitled project has none.

Each Core implements these rules once, as `CaptionCardText` (VoxClipCore and VoxClip.Core). Both test suites check them against `shared/fixtures/captions/cards.json`, which `tools/captions/gen_cards.py` generates. The generator and both suites also lay out every card and its fit drops, and fail unless the drawn moment shows the key word as the active word, or every word of a reveal style.

#### 5.4.3 Typesetting and backdrop

**Renderer.**

- Cards are always drawn into a bitmap by the **export caption renderer**: CoreText on macOS (`CaptionHandoff`), Skia and HarfBuzz on Windows (`SkiaCaptionRasterizer`).
- They are never drawn as UI text, so bundled fonts still appear only in rendered media (§16).
- Cards are decorative images with no accessible name. The surfaces carry the names (§5.4.9).

**Backdrop.**

- The default backdrop is **stage black** (`stage`, #000000).
- If the style's `preview.background` is dark (relative luminance below 0.10), the backdrop is that colour as a radial (a 78%×92% ellipse) vignetted to stage black: Bold and Highlight `#3A3C45`, Neon `#16171D`, VHS `#21232B`.
- If the style's look is a near-black plate with no preview background (Subtitle, Lower third, Typewriter), the backdrop is `#3A3C45`, vignetted the same way. Otherwise the plate would vanish on black.
- A light preview background is not used (Bold+ `#C9CBD0` would read as a spotlight). Its white text is legible on black.
- Strokes and shadows whose colour is near black (luminance below 0.012) are **not drawn** on a stage-black backdrop. They would only paint black on black, and any mismatch in black level shows as a lumpy plate.
- A 1 px white 10% inner rim separates the card from dark pages. It is decorative.

**Fit.**

| Surface | Size (Windows / macOS) | Text box | Size range | Lines, at most | Plates |
|---|---|---|---|---|---|
| Home tile | 226×127 / 225×126 | centred 176×71 (macOS 175×70) | 24 → 13 px | 2 | yes |
| Header chip | 64×36 | 58×24 | 8 → 5 px | 1 | yes |
| Gallery tile | 173×78 / 160×72 | inset 9, 12 | 13 px × sizeSh / 0.062, at least 9 (macOS: 12 px base) | 2 | yes |
| Full take, Recent | 32×18 / 36×20 | inset 2, centred | 10 (macOS 11) → 4 px | 2 | **no** |
| Clip row | 27×48 / 26×46 | full width minus 4, 15 high, centred on the style's 9:16 caption y, clamped to 0.60–0.78 | 9 → 4 px | 2 | **no** |
| Stage | the stage | the style's position and real size (sizeSh × short edge, with overrides), as export | n/a | the style's | yes |

- **Lines.** A card never takes more lines than the style's `layout.maxLines`, so a one-line style stays one line on every surface.
- **Fitting.** Use the largest size that fits within the line limit. If nothing fits at the smallest size, drop the last word together with any weak words before it, keeping one word. Never use an ellipsis.
- **Sidebar sizes are a downscaled card**, not a bar mark. At 1x they read as the texture of a title card in the project's colours, as a downscaled frame would. The title beside them carries the meaning.
- **No plates at sidebar sizes.** At 18 px high, a boxed word reads as a tag control. The boxed key word takes the box colour as its text colour (Paper `#F3F0E7`, violet `#B79CFF`), and Pill text becomes white.

#### 5.4.4 States

States, per surface. Copy is exact.

| State | Home tile | Sidebar 32×18 / 36×20 | Clip row 27×48 / 26×46 | Stage | Caption previews |
|---|---|---|---|---|---|
| **a · normal** | the first kept frame, with the duration chip (§7) | frame | frame | video | the frame band dimmed 35% (unchanged) |
| **b · loading** | the loading ladder (§5.4.5) | the ladder | the ladder | the caption at the playhead over black at once; a 20 px ring after 500 ms | stage black until the band exists |
| **c · video missing** | card and the **missing chip**; meta "⚠ Video not found." **Locate…** | card; Windows meta "⚠ Video not found", macOS trailing "⚠ Not found" | card (in the editor the InfoBar carries the state; rows don't repeat it) | the caption at its real place over black, still draggable; centred glyph, **"Video not found"** and the file name in mono; transport disabled | samples over the card backdrop, not dimmed |
| **c · never transcribed** | stage black and the missing chip | stage black | n/a (no clips without words) | the glyph, "Video not found" and the file name only | as c |
| **d · transcribing** | frame, the **"Transcribing · 42%"** chip and a 2 px progress line; meta "Transcribing on this {Mac/PC}" **Cancel** | frame and the 2 px line; meta "Transcribing · 42%" **Cancel** | none (clips need words) | the video plays, with no captions | the frame band; sample "Your story" |
| **d · no frame yet** | the style's backdrop, three dots (no accent: white 100%, 55% and 28%), the chip and the line | three dots | n/a | caption-free black, with the ring rule of b | as b |
| **e · demo** | card and the **"Demo"** chip | card | card | the **"Demo · no video"** chip; the take's word rhythm (§5.4.6); captions at their real place on the synthetic clock | samples on the card backdrop |
| **f · audio only** (`video == null`) | card and the **"Audio only"** chip | card | card | the **"Audio only"** chip; the live audiogram (§5.4.6); captions | samples on the card backdrop |
| **f · corrupt file** | card and the **warning chip**; meta "⚠ Can't read video." **Locate…** | card; meta "⚠ Can't read video" | card | warning glyph, **"Can't read this video"** and the file name; transport disabled | as c |
| **f · black first frame** | the next usable frame (§5.4.7), with no chip | frame | frame | the real (black) video: black is content | the frame band |

**Notes.**

- **Home (e)** appears only for a project that carries a demo or sample marker. The DEBUG fixtures never enter Recent, so (e) on Home ships only with a sample project.
- **Locate…** sits in the meta line on Home and in the transcript InfoBar in the editor (§13 "Media missing"). It is never on the stage.
- **Export** is disabled in the missing (c), corrupt (f) and demo (e) states, with its reason as the tooltip and the accessible description:
  - c and corrupt f: "Locate the video to export.";
  - e: "Demo projects have no video to export."

#### 5.4.5 Loading ladder

This ladder applies to every frame-backed surface.

1. **0–300 ms: hold.** Stage black and the rim, nothing else. A frame that arrives now cuts in with no fade, so cached frames never flash.
2. **After 300 ms, if the project file is still unread** (Home only): one neutral sheen sweeps the tile. It is a white 7.5% band at 105° and 40% of the width, sweeping in 2.4 s ease-in-out with a 0.6 s rest. The meta reads "Loading…". The sheen stops when the tile scrolls off or the data arrives.
3. **After 300 ms, words ready, frame pending:** the card, with no chip.
4. **Frame decoded:** a 150 ms crossfade over the card (`motion.standard`, ease-out).

Home's metadata cache (§7) keeps, for each project, the card inputs or both cards (the transcript card and the title card), whether it has video and whether it is missing. It records the `general.showPlaceholderWords` value and the resolved style id the cards were made with, and re-derives them when either changes, for example when `captions.defaultStyleId` changes while captions are off. Step 2 therefore happens only the first time Home sees a project. Rendered cards stay in memory only, in an LRU capped at 8 MB and keyed by project path, modification date, scope, style id, overrides hash, pixel size and the switch. They are never written to disk.

**Stage.** The caption at the playhead is drawn at once, at its real position. A 20 px ring (a white 20% track and a white 80% arc) appears only after 500 ms. When the video arrives it fades in under the caption, and the caption does not move.

#### 5.4.6 Stage overlays with no video

These overlays are the one exception to §5.1's rule of no overlay on the stage. They are non-interactive: **there is no button on the stage**. Locate… lives only in the transcript InfoBar, so there is one tab stop and one name.

**Message cluster** (states c and corrupt f):

- centred at 36% of the stage height (9:16: 38%);
- a 20 px glyph in `status.warning` dark, `#E3B25C`;
- line 1 in 14/20 semibold (Windows) or 13/17 semibold (macOS), `overlay.foreground`;
- line 2, the file name, in Cascadia Mono 12 or SF Mono 11, white 66%.

**Word rhythm** (state e):

- one capsule per kept word, its width set by the spoken duration and its height 6 px;
- centred at 42% of the height over a 6 s span (9:16: 5 s) around a fixed centre playhead (1 px, white 55%, 30 high);
- played words white 62%, the word at the playhead white 100% at 12 px, upcoming words white 26%;
- no accent and no glow.

**Audiogram** (state f, audio only):

- the cached 10 ms envelope (architecture.md §8.2);
- 2 px bars on a 3.5 px pitch over 14 s (9:16: 9 s) around a fixed centre playhead, a 1 px white line with a 5 px dot;
- bars reach ±12% of the stage height (9:16: ±7.5%), centred at 40%;
- played bars white 72%, upcoming bars white 26%;
- no accent, no glow and no bloom;
- with no envelope, the word rhythm instead.

**Chips** (§5.4.8) sit top-leading, inset 8 (Windows) or 6 (macOS).

**Accessible names** (added to §5.1):

- "Video preview, full take, video not found";
- "…, video can't be read";
- "…, audio only";
- "…, demo project".

#### 5.4.7 Choosing frames

- **Thumbnail time.** Thumbnails come from VoxClip's own decoder at the first kept word's source time, never from the system shell.
- **Black frames.** Decode at 32×18 first. If the mean luma is below 0.06 and its standard deviation below 0.02, retry at +1 s, +3 s and 10% into the scope. If all of these are black, use the card with no chip.
- **Frame cache.** Frames are cached by `(contentKey, time rounded to 0.1 s, pixel size)`. A persisted poster sits in the source's cache entry, under `thumbs/` (architecture.md §8.2).

#### 5.4.8 Chips and progress line

**Chips.**

| Token | Value |
|---|---|
| `chip.mediaBackground` | `#0000009E` (black 62%) |
| `chip.mediaStroke` | `#FFFFFF2E` (1 px, inside) |
| `chip.mediaBackgroundOpaque` | `#1A1A1C`, stroke `#FFFFFF66` (Reduce Transparency, transparency effects off) |
| `chip.mediaForeground` | `#FFFFFF` |
| `chip.warningGlyph` | `#E3B25C` (`status.warning` dark, used on media in both themes) |
| Size, Windows | 24 high, padding 0 8, radius 4, Segoe UI Variable 12/16 semibold; icon-only 24×24 with a 16 px glyph |
| Size, macOS | 20 high, padding 0 7, radius 4, SF 11/14 semibold; icon-only 22×22 with a 14 px glyph |
| Numbers | Cascadia Mono or SF Mono with tabular figures, so "42%" never jitters |

- **Glyphs.** Missing uses `video.slash` (SF Symbols) or the Segoe Fluent Icons video-off glyph. Corrupt uses `exclamationmark.triangle` or the Fluent warning glyph. Audio only uses `waveform` or the Fluent audio glyph.
- **Chip copy:** "Transcribing · {p}%", "Transcribing" (no fraction), "Extracting audio…", "Reading video…", "Aligning words…" (the §13 stages), "Demo", "Demo · no video" (stage) and "Audio only".
- The missing and corrupt chips are icon-only. The meta text beside them carries the words.

**Progress line.**

- 2 px along the bottom edge of the tile or thumbnail;
- a fill of `overlay.foreground` (#F5F4F0) on a track of black 55%;
- a contrast of 4.3:1 or more over any frame, and 19:1 over black;
- it spends no accent and needs no runtime accent derivation;
- **indeterminate** (the engine reports no fraction): a 30% segment slides across in 1.6 s. Under Reduce Motion the line is hidden and the chip reads "Transcribing".

#### 5.4.9 Accessibility

**Names.**

- Tiles and rows with a media state are named "{title}, {state}", with no "·" in names:
  - "Latte art for beginners, video not found";
  - "Grinder shootout, transcribing 42 percent";
  - "…, loading";
  - "…, demo project, no video";
  - "…, audio only";
  - "…, video can't be read".
- Chips have no accessible name of their own, so nothing is announced twice. Cards are decorative.
- Recent rows keep "{title}, video not found", and Return opens Locate… (§7).

**Reduce Motion** (macOS `accessibilityReduceMotion`, Windows `UISettings.AnimationsEnabled == false`):

- no sheen (static black);
- no crossfade (a cut);
- static dots;
- the text "Loading video…" instead of the stage ring;
- the word rhythm and the audiogram page every 6 s or 14 s instead of scrolling;
- the indeterminate segment is hidden.

**Reduce Transparency, Increase Contrast, transparency effects off:**

- chips use the opaque tokens;
- the progress track becomes opaque `#000000` and the fill pure white;
- Increase Contrast raises the chip stroke to white 100%.

**Windows High Contrast:**

- the stage and cards stay black: they are media, and media is never recoloured (§14);
- chips use `SystemColorWindowColor` with `SystemColorWindowTextColor` text, glyph and 1 px border;
- the progress line uses `SystemColorWindowTextColor` on `SystemColorWindowColor` (a 4 px track).

**Contrast.**

| Element | Ratio |
|---|---|
| chip text on black | 21:1 |
| chip text over the worst frame pixel | 6.2:1 |
| amber glyph on black | 10.8:1 |
| stage line 1 | 21:1 |
| stage file name (white 66%) | 8.8:1 |
| progress fill against its track | 4.3:1 or more |
| played rhythm (white 62%) | 7.5:1 |
| played audiogram (white 72%) | 10:1 |

- Decorative and carrying no state: the upcoming rhythm and audiogram (white 26%), the rim and the sheen. State is always in a chip, in text or in the accessible name.
- A black tile on a dark page is 1.2:1. It is an image, not a control boundary, and the rim helps as it does for frames.

#### 5.4.10 Timeline without an envelope

When the envelope is missing (state e, or c on another computer):

- each kept word draws its `timeline.keptBackground` bed with one 8 px capsule in `timeline.waveform`, inset 2 at each end;
- cut words and cut pauses keep their hatching;
- the brackets, the scope dimming and the playhead are unchanged.

#### 5.4.11 Copy

The stand-in copy is in §13: the corrupt Recent project, the corrupt file, the two Export tooltips, the demo project, the stage lines and the Settings switch.

---

## 6. Clips, captions and Voice Lab

The inspector and its Captions, Clips and AI tabs are gone. The commands ⌘1–⌘3 and Ctrl+1–Ctrl+3 no longer switch tabs.

- **Clips** live in the sidebar (§3.4, §6.2).
- **Captions** live in the right column (§6.1).
- **Voice Lab** opens in context, in the right column (§6.3).
- **M2 AI commands** live in the toolbar and the menus (§6.4).

### 6.1 Captions (right column)

**Header.** It has two forms.

- **One row, 36 high**, used on macOS when the column is 340 or wider:
  - "Captions" 13/600;
  - a 64×36 live chip of the current style on the current frame, or the one-line caption card when there is no frame (§5.4.3);
  - the style name, 13/600, followed by "Edited" in 11 `text.secondary` when overrides exist;
  - under the name, the Fine Tune disclosure label "› {summary}" in 11 `text.secondary`;
  - on the trailing side, a regular switch (38×22).
- **Two rows**, used on macOS below 340 and always on Windows:
  - the header (36): "Captions" on the leading side, a switch on the trailing side;
  - the style row: the chip, the name and "Edited", and the summary under them. On Windows the trailing "Fine tune ⌄" makes this whole row the `Expander` header (`ExpandDirection="Down"`); its tooltip lists the size, case, words, colour and position.

**The switch.**

- **macOS:** `Toggle("Captions", isOn:).toggleStyle(.switch)`, so the label is part of its hit area.
- **Windows:** `ToggleSwitch` with empty `OnContent` and `OffContent`, named "Show captions".
- **Turning it off** sets `captions.styleId = "off"`. The editor remembers the previous style for this session.
- **Turning it on** restores that style, or `captions.defaultStyleId` when there is none.
- **While off:** the chip shows "Off" and the gallery stays visible. Choosing a tile turns captions on with that style. With accepted AI speech, Off keeps the mandatory AI MODIFIED chip, as before.

**Summary grammar.** "{colour} · {case} · {n} words", for example "Paper · As said · 3 words".

- **Colour** is the active-word colour's name (Yellow, Green, Cyan, Pink, Paper, White). It appears only for styles that have an accent.
- **Case** is "As said" or "ALL CAPS".
- **Words** is the resolved words on screen: "1 word", "{n} words", or "Line".
- **"Edited"** shows when `captions.overrides` is not empty or a stored position exists for the current frame.
- Both the style name and the summary come from the current style and its overrides. The sample (Box highlight with Paper) is the correction of the Windows mockup's "Highlight · Edited": Highlight (`vox-highlight`) is one word on a fixed box and has no active-word colour.

**Fine Tune.** A `DisclosureGroup` on macOS and an `Expander` on Windows, collapsed by default. Each control maps to a `CaptionStyle` override defined in the captions spec:

- **Size:** `S · M · L · XL` (segmented).
- **Case:** `As said · ALL CAPS`.
- **Words on screen:** `1 · Phrase · Line`.
- **Keep punctuation** (switch).
- **Colour**, only for styles with an active-word colour. Swatches: Yellow `#FFE14D`, Green `#4BE38A`, Cyan `#5CE1FF`, Pink `#FF6FAE`, Paper `#F3F0E7`, White `#FFFFFF`.
- **Position:** `Top · Middle · Bottom`, with the hint "Drag captions on the video to move them."
- **"Reset to Style"**, a link button.

There is no separate Fine Tune row and no "Off" tile.

**Gallery.**

- **Control:** macOS `LazyVGrid` of `Button`s with `.accessibilityRepresentation` as a `Picker` named "Caption style". Windows `GridView` with `SelectionMode="Single"` over a grouped `CollectionViewSource`.
- **Layout:** two columns with an 8 gap. Tile width is (inner width − 8) / 2; tile height is round(width × 0.45). That gives 160×72 at a 360 column, 140×63 at 320 and 173×78 at 388. Radius 10. The name sits under the tile with a 4 gap, and rows are 10 apart.
- **Groups**, each with a section header (11/600 `text.secondary`), from the style's tags. A style goes to the first group it matches; within a group, styles sort by `order`:

  | Group | Tag | Styles |
  |---|---|---|
  | Word by word | `one-word` | Bold, Highlight, Bold+, One word |
  | Phrase | `phrase` | Karaoke, Pop, Box highlight, Bounce, Two-tone, Outline, Pill, Gradient, Neon, Emoji, VHS |
  | Sentence | `sentence` | Subtitle, Lower third, Typewriter, Editorial |

  A style with none of these tags goes into an "Other" group at the end. A test asserts that the bundled styles produce no "Other" group.
- **Tile content.** Each tile renders the real style with the export renderer: the current phrase at the playhead (fallback "Your story"), with that style's word count and casing. It is drawn over the band of the current frame behind the style's caption position, dimmed 35%. With no frame, samples sit on the card backdrop (§5.4.3), not dimmed. In clip scope the playhead is inside the clip. The selected tile is drawn with the active overrides.
- **Selected tile:** a 2 px `accent.text` outline at offset 2, a check badge (a white check on a 62% black disc, 18, top-right, inset 6), and the name "Box highlight · Edited" in 600 `text.primary`. Other names are 11 (macOS) or 12 (Windows) `text.secondary`.
- **Scrolling.** The grid scrolls the selected tile into view when the scope changes. The scroll view ends 8 above the strip with a 24 (macOS) or 12 (Windows) fade to the column background.
- **Accessibility.** Options are named "{name}: {description}" ("Box highlight: a box behind the spoken word, a few words at a time").
- **Motion.** Under Reduce Motion, tiles are static; animated styles show their resting frame.
- Captions follow edited time, and phrase grouping does not break at cut seams (captions spec D9). Under Reduce Motion the preview shows animated styles without animation; export keeps them.

### 6.2 Clips (sidebar)

The sidebar list is the clip range layer (editing §2.5 and §10.6), presented as in §2 and §3.4.

**Making a clip.**

- **Ways in:** the selection bar's Make Clip, ⌘K or Ctrl+K, the transcript context menu, the sidebar's New Clip from Selection, and Clip > Make Clip from Selection.
- **Result:** one `addClip` undo step ("Make clip from selection"). The title is the first seven words of the selection, which the user can rename.
- **After making it:** the new row is selected and scrolled into view. The transcript keeps its scroll position and the selection. The timeline zooms to the clip. Announce "Clip 3 made".
- **When the selection already equals a clip:** select that row and announce "Clip 2 already covers these words".
- **With no words selected,** the command is disabled.

**Row actions.**

- **Kept clip context menu** (macOS `.contextMenu`, Windows `ContextFlyout`):
  - Export Clip…;
  - Rename… (macOS: Return on the focused row edits the title inline; Windows: F2);
  - Copy Text;
  - Remove Clip (⌫ or Delete on the focused row; one undo step; announce "Clip 2 removed").
- **Suggestion menu:** Keep Clip, Dismiss.
- **macOS:** `.onDeleteCommand` and `accessibilityCustomActions` mirror these.
- **Reason and score:** a suggestion's reason and score ("8/10 · Strong hook, one idea") are its tooltip and its accessible description.

**Clip keyboard.**

| Key | Action |
|---|---|
| [ and ] | Select the previous or next kept clip, in transcript order. From Full take, ] selects clip 1 |
| Esc in the transcript (no selection bar, no correction field) | Select Full take |
| I and O | Set the selected clip's start or end at the caret (`updateClip`) |
| Return on a focused suggestion (macOS) / Ctrl+Enter (Windows) | Keep |
| ⌫ on a focused suggestion (macOS) / Delete (Windows) | Dismiss |

**Find Clips.**

- **Ways in:** the toolbar button, the sidebar action, ⇧⌘K or Ctrl+Shift+K, and Clip > Find Clips…. They all open one popover on macOS (`.popover`, anchored to the toolbar button, or to the sidebar action when that was used) or a `Flyout` on Windows. It holds:
  - the title "Find clips in this take";
  - **Connector**: a read-only line, for example "Claude Code · Ready", from the selected `llm.connector` and its status ("● Ready", "● Key missing", "● Not running", "● Not found", "● Not signed in", "● Too old"), with **Change…**, which opens Settings → AI. The status refreshes after a key or server setting changes. It is advisory: Find Clips runs the connector's preflight when pressed;
  - **Preset**: a single choice of Best moments · Hooks · One per topic · Quotes · Custom;
  - **Instructions**: a field reading "Anything specific? (optional)", or "Describe the clips you want" for Custom (at most 500 characters, Return runs it);
  - the footnote "Sends transcript text with word numbers. No audio or video." For local connectors it reads "Runs on this {Mac/PC}. Nothing leaves it.";
  - **[Find Clips]** as the default button.
- **Consent.** The first cloud use runs the existing consent alert (ai.md §4.8).
- **While it runs:** the popover closes. The sidebar shows a "Finding clips…" row under the Suggested header, with a spinner (Windows: a fixed-width `ProgressRing`), **Cancel**, and the connector line "{connector} · reading {duration} of transcript" in 11 `text.secondary`.
- **Results:** the new suggestions appear under Suggested and the first is focused (not selected). Announce "Found 3 clips".
- **No connector:** the popover is replaced by an inline callout under the sidebar actions. Copy is in §13, with **Set Up AI…** and the line "You can also select words and press ⌘K to make a clip yourself."
- **Failures** show in the same place with **Retry** (§13).

**Export ledger** (app-local, not in the project).

- **Location:** `<app data>/exports.json`, keyed by project id and target ("full" or a clip id).
- **Record:** `{exportedAt, planFingerprint, styleId, aspect, outputPath}`, written after each successful export.
- **Statuses:**
  - **Exported:** a record exists and `planFingerprint` (a SHA-256 of the scoped edit state, caption settings and aspect) matches the current one.
  - **Edited since export:** a record exists and the fingerprints differ.
  - **Exporting / Export failed:** taken from the live export queue.
- Clearing app data removes the statuses, never the project.

### 6.3 Voice Lab in context (M3 beta)

Voice Lab appears only when Settings → Voice Lab → Show Voice Lab (beta) is on (voice-lab.md §5).

- **When it is off:**
  - the selection bar has no Rewrite… and no divider;
  - Edit > Rewrite… (macOS) and ⋯ > Rewrite… (Windows) still exist, and open the one-time "Turn on Voice Lab" sheet from voice-lab.md §5.
- **When it is on:**
  - the selection bar shows **Rewrite…** (⇧⌘R / Ctrl+R);
  - the transcript context menu adds Rewrite… and, with a caret between words, **Insert Words…**.
  - Both open the Rewrite panel. Rewrite combines voice-lab.md §8.1 entry points 1 (re-voice the selection) and 3 (fix with AI); Insert Words is entry point 2.

**Rewrite panel.** It replaces Captions in the right column. It is flush, with no card, no inset and no radius. A hairline sits above it and above its footer. Sections are separated by 12 of spacing and their labels, not by hairlines. The column scrolls when it has to. While it is open:

- the passage being rewritten shows in the transcript with an `accent.soft` fill and a 1 px `accent.text` outline (radius 4);
- the timeline shows the same as a band;
- the stage may compact (§5.1).

From the top:

1. **Header**, one row: a `waveform` glyph, "Rewrite" 13/600, a "Beta" tag (11, `text.secondary`, 1 px `line.strong` outline), "{n} words at {m:ss.d}" in 11 `text.secondary`, and a close button named "Close Rewrite" (Esc).
2. **What should change?** A one-line field, focused when the panel opens, with a bordered **Rewrite · {cost}** button, for example "Rewrite · < $0.01". It sends the passage and the instruction to the selected LLM connector (`VoiceRewriteService`, voice-lab.md §2.6) and fills New words with the proposal. Under it, the line for that send in 11 `text.secondary`:
   - API key: "Sends these {n} words to {connector} with your key."
   - CLI: "Sends these {n} words to {CLI} with your sign-in. Counts toward your {plan}."
   - Local: "Runs on this {Mac/PC}. Nothing leaves it."
3. **New words.**
   - The label, with the summary on the trailing side: "{i} new, {r} removed · about {s} s".
   - An editable plain-text field holding only the new text, prefilled with the passage.
   - Under it, a read-only diff line from the voice-lab.md §8.2 LCS:
     - removed words in `text.secondary` with a 1.5 px `cut.stroke` strike;
     - inserted words in `accent.text` with a 1.5 px solid underline;
     - re-voiced bridge words in `text.primary` with a 1 px dashed `accent.text` underline.
   - Its accessible description reads "one becomes on Sunday, seven becomes five, …".
   - Under the diff, one fit meter line per voice hunk in 11 `text.secondary`: "about 4.3 s for a 4.1 s gap: fits" or "about 4.3 s for a 4.1 s gap: will change length" (voice-lab.md §8.9.1). With more than one hunk, each line starts with that hunk's new words in quotes, for example "“on Sunday” · about 1.2 s for a 1.1 s gap: fits". It updates as the user types, and nothing is sent.
   - The transcript does not render proposed words; only accepted replacements appear there.
4. **Voice.** A pop-up (macOS) or `ComboBox` (Windows) reading "My voice · consent Oct 12", with the date in `text.secondary`. With no active consented voice, it reads "No voice yet" with **Create Your Voice… (2 min)**, which opens the voice-lab.md §6 flow, and Generate is disabled.
5. **Takes.**
   - **Header:** "Takes", with a text button **Generate Takes · ≈ $0.02** before any takes exist, or **Generate Again · ≈ $0.02** after. Its tooltip and accessible name are "Generate up to 3 new takes, about $0.02". Under it, in 11 `text.secondary`: "Sends the new words and a short audio check to ElevenLabs with your key. No video." The QA re-transcription in voice-lab.md §8.11 sends audio.
   - **The list:** single choice (macOS `List` with selection; Windows `ListView` with `SelectionMode="Single"`). The best take is preselected and plays once.
   - **Rows:** 36 high on macOS, 40 on Windows: a 24 or 32 neutral play/pause button, "Take 1", the duration in mono, a "Best match" outline tag or a pause-fit note such as "pauses +0.4 s" in `text.secondary` (voiced speech is never time-stretched; only silences are fitted), and a 24 or 32 ✕ (Reject, named "Reject take 2"). Rows fill only while selected or playing.
   - **A failed take** gets its own row: a warning glyph, "Take 3 didn't pass the speech check." and **Try Another · ≈ $0.01**.
6. **Footer** (above a hairline):
   - the disclosure in 11 `text.secondary` with an info glyph: "Exports show AI MODIFIED on the video and in the post.";
   - one default button, **Use Take 1** (Return). It stays disabled until a take passes QA and any required video choice has been made.
   - Accepting is one undo step (voice-lab.md §8.12). The panel closes, Captions comes back, and focus returns to the words.

**After accepting.**

- The passage shows inline in the transcript with an "AI" chip at its start: SF Mono 10/600 or Cascadia Mono 10/600, `accent.text` on `accent.soft`, 1 px `accent.text` outline, radius 4. The replacement words have a 1 px dashed `accent.text` underline, and their accessible description adds ", AI modified".
- The sidebar meta of every scope that contains the passage reads "AI modified".
- The viewer bar shows the AI modified tag.
- The stage and Export accessible names add ", contains AI-modified speech".

**Rewrite states** (copy in §13):

- **Generating.** "Generating take 2 of 3…" with a spinner and **Cancel** in place of the remaining rows. Announce "Take 1 ready." as each take arrives. At the end of a run in which no take fits, announce "Three takes ready." or, only when some failed, "Three takes ready, one failed the speech check."
- **Take fits** (voice-lab.md §8.6). When a take passes the speech check and fits its gap, generation stops: the spinner row reads "Take 2 fits." and it is announced. No further take is generated. Only when an earlier take failed does it add "One failed the speech check."
- **Provider error.** A callout on `status.dangerBackground`: "ElevenLabs rejected the key (401). Your edits are saved." [Open Settings] [Retry]. Windows uses `InfoBar Severity="Error"`.
- **No take passed.** "These takes didn't sound right. Try different wording or re-record." [Generate Again · ≈ $0.02].
- **Length changed** (ADR-R28). "Take 1 runs 1.4 s longer than the words it replaces. Choose how the video keeps up." For a take that is too short: "Take 1 runs 0.6 s shorter than the words it replaces. Choose how the video keeps up." The seconds are what remains after the silence fit (voice-lab.md §8.9). It offers a required radio choice:
  - **Lip sync:** "Sends 9 s of video around the change to {provider} with your key. About $0.60, confirmed before it runs."
  - **Retimed source video:** "Slows these 9 s of video to 0.86× and crops in slightly around your face. Nothing is sent." For a shorter take: "Speeds these 9 s of video up to 1.07× and crops in slightly around your face. Nothing is sent."

  Neither is preselected. An unavailable option shows why. Use Take stays disabled until one is chosen. The choice is never remembered.
- **Cut-only or text-only diff** (voice-lab.md §8.2 classes cut and textOnly). Voice and Takes hide, and the footer button reads **Apply Cuts** or **Apply Correction**. No AI is used and nothing is sent.
- **Patch budget exceeded.** "That's a lot to re-voice. Re-record these sentences instead." Generate is disabled.
- **No room tone** (voice-lab.md §8.7). "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in." [Clean Audio…] opens the Clean audio panel. Generate is disabled.
- **Too close to the take edge** (voice-lab.md §8.4). "This change is too close to the {start/end} of the take to blend in. Re-record this sentence instead." Generate is disabled.
- **Cost of $0.50 or more, or unknown.** The cost confirmation from voice-lab.md §3.1 appears before the action runs.

Keyboard: opening the panel focuses "What should change?". Esc closes it and returns focus to the selected words. F6 order is in §15.

### 6.4 Other AI features (M2) and Voice Lab rows

| Feature | Where |
|---|---|
| Tighten with AI (M2) | Edit > Tighten with AI… and the toolbar capsule's menu, macOS overflow or Windows ⋯. Suggestions show as filler-style dotted underlines. The edit summary area offers **Cut All Suggestions** |
| Clean audio (M2) | Edit > Clean Audio… and ⋯. It opens a right-column panel shaped like Rewrite: what it sends, the cost button "Clean Audio · ≈ $0.36", progress and Use |
| Voice changer (M3) | Edit > Change Voice… (scope: the selected clip or the full take). It opens a right-column panel: Voice, Takes, disclosure, Use |
| My voice (consent and clone) | Settings → Voice Lab → My voices, and the Rewrite panel's **Create Your Voice…** |
| Lip sync | only as the length-changed choice in Rewrite |

When rewritten speech requires a different video duration, show Lip sync and Retimed source video together and let the user choose for that rewrite (ADR-R28, Voice Lab §8.9), as specified above. The current capability guards for unsupported video remain until those paths are implemented and verified.

For already reviewed, saved v3 recipes with unity audio fit and equal-length source video, the editor uses the existing viewer, timeline and Export controls:

- **Playback.** Preview duration and scrubbing follow the prepared Voice Lab timeline. Source cuts beneath an enabled replacement stay dormant.
- **Export scope.** The Full video export ignores a selected clip row.
- **Captions.** They show the replacement words. Captions Off keeps the mandatory AI MODIFIED chip and the export provenance.
- **Missing or changed asset.** A missing or changed generated asset clears the preview and explains how to restore it.
- **Unsupported cases.** Unsupported video treatments, duration fit and unreviewed recipes stop with an inline explanation, keeping the video and edits.

---

## 7. Home

Home is the sidebar's first row, in the main window. It is never a separate window. While Home is selected the window title is "VoxClip" (macOS) and the open project, if any, keeps its sidebar section (rows only, no action footer).

```text
┌ sidebar ──────────────┐  VoxClip                                                        (⌕ Search projects)
│ ⌂ Home   (selected)   │ ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
│ Five questions        │   ⇩  Drop a talking-head video, or  (Import Video…)  (Open Project…)    🔒 MOV, MP4, M4V · stays on this Mac
│   Full Take  2:10     │ └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
│   1 Think in sentences│ ✦ Find Clips with AI isn't set up yet. You can still make clips by hand.   [Set Up AI…]
│   …                   │
│ Recent                │ Recent projects                                                    Last Opened ⌄
│   Studio tour         │ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│   Podcast intro ⚠ Not found │ 2:24 │ │  4:05  │ │  0:58  │ │ 12:40  │
│   …                   │ Five questions  Studio tour  Launch notes  Q&A, October
└───────────────────────┘ 4 clips · Open now  6 clips · Yesterday …
```

**Search.**

- **macOS:** `.searchable(text:placement: .toolbar, prompt: "Search projects")` (glass toolbar field).
- **Windows:** an `AutoSuggestBox` "Search projects" on the trailing side of the "Recent projects" header row.
- It filters by title. With no results: "No projects match “{query}”."

**Drop bar** (shown once any project exists).

- **Box:** 64 high, on `bg.sunken`, with a 1.5 px dashed `line.strong` border (6 on, 4 off; 3.41:1). Radius 14 (macOS) or 10 (Windows).
- **Contents:** an import glyph, then "Drop a talking-head video, or", then **Import Video…** and **Open Project…**.
  - **Import Video…** is the screen's one accent control: macOS `.borderedProminent` with `.controlSize(.large)` in a capsule, ⌘O; Windows `AccentButtonStyle`, 40 high, Ctrl+O.
  - **Open Project…** is macOS `.bordered` large, or a standard Windows button.
  - On the trailing side, in 11 or 12 `text.secondary`: a lock glyph and "MOV, MP4, M4V · stays on this Mac" (Windows: "MP4, MOV, M4V, MKV, WEBM · stays on this PC").

**Whole-window drop target.**

- Dragging a file over the window anywhere, Home or editor, shows an `overlay.drop` fill with a 2 px dashed `overlay.dropBorder` border, radius 14, inset 12. Inside: a download glyph, "Drop to transcribe" (17/600 or 20/28), and a line in `text.secondary`:
  - macOS: "One video at a time · MOV, MP4, M4V";
  - Windows: "{file name} · VoxClip makes a new project next to the video".
- With a project open, the line reads "{project} is saved first."
- Unsupported types show "VoxClip can't open {ext} files on {Mac/PC} yet…" (§13) on drop.

**First run (empty library).** The drop bar becomes a 212-high hero (232 on Windows), dashed the same way, holding:

- a glyph;
- "Drop a talking-head video" (22 Title1, or Windows 20/28 semibold);
- "VoxClip transcribes it so you can cut by words, make clips and add captions." in `text.secondary`;
- **Import Video…** and **Open Project…**;
- the footnote "🔒 {types} · Media and edits stay on this {Mac/PC}.".

There is no Recent header and no grid.

**AI callout.** One line, shown only when it gives a next step.

- **macOS:** a custom callout row on `status.infoBackground`, radius 10, with a sparkles glyph.
- **Windows:** `InfoBar Severity="Informational" IsClosable="False"` with an `ActionButton`.
- **Copy by readiness of `llm.connector`:**
  - none chosen: "Find Clips with AI isn't set up yet. You can still make clips by hand." [Set Up AI…];
  - a CLI not signed in: "{CLI} isn't signed in, so Find Clips with AI can't run. You can still make clips by hand." [Sign-in Help];
  - a key missing: "Add your {provider} key to use Find Clips with AI. You can still make clips by hand." [Set Up AI…];
  - a local server not running: "{Ollama/LM Studio} isn't running, so Find Clips with AI can't run." [Check Again].
- **Hidden** when the connector is ready.
- **No transcription-model line on Home:** model readiness moved to Settings → Transcription and the import sheet (§7.1).
- **Updates:** on macOS, "VoxClip {version} is available." [Download] uses the same callout slot, above the AI callout. On Windows, "VoxClip {version} is ready. Restart to update." [Restart now] stays in the window-level `InfoBar` (§3.3), which sits above Home.

**Recent projects grid.**

- **Header:** "Recent projects" (15/600 or 20/28), with a sort menu on the trailing side: Last Opened ⌄, Name.
- **Layout:** an adaptive grid with a 200–280 card width and a 16 gap. That gives 4 columns of 225×126 (macOS) or 226×127 (Windows) at 1280. Every recent project appears, including the open one.
- **Card thumbnail:** 16:9, radius 10, the first kept frame, or the caption card when there is none (§5.4). The duration sits as a mono 11/600 chip at the bottom trailing corner, on black at 62% with white text.
- **Card text:** the title (13/600 or 14/20 semibold), then a meta line in `text.secondary`: "{n} clips · {relative date}" (macOS), or "{duration} · {date} · {n} clips" (Windows). "No clips yet" when there are none, and "Open now" for the open project.
- **Missing video:** the caption card (§5.4) with the icon-only missing chip. The meta line becomes "⚠ Video not found." in `status.warning` with **Locate…** (a link button, 32 high on Windows).
  - Locate… opens the project in place and immediately runs the existing relink flow (§13 "Media missing"). Cancelling leaves the project open in its missing-media state.
  - In the sidebar, the same project's Recent row shows the card, with a trailing "⚠ Not found" in `status.warning` on macOS or the meta line "⚠ Video not found" on Windows. Its accessible name is "{title}, video not found", and Return opens Locate….
- **Unreadable video:** the caption card with the icon-only warning chip. The meta line becomes "⚠ Can't read video." in `status.warning` with **Locate…**, and the Recent row shows "⚠ Can't read video".
- **Transcribing:** the thumbnail keeps its frame and gains the chip "Transcribing · 42%" and a 2 px progress line (§5.4.8). Neither is interactive. The meta line reads "Transcribing on this {Mac/PC}" with **Cancel** (a 32-high `HyperlinkButton` on Windows, a link on macOS), where Locate… sits for a missing video.
- **Card actions:**
  - click or Return opens the project in place (§2);
  - the context menu offers Open, Show in Finder or Show in Explorer, and Remove from List.
- **Accessibility:** the card's name is the project title, followed by its media state when it has one ("Latte art for beginners, video not found"; §5.4.9). Its description is "{duration}, {n} clips, opened {date}".
- **Metadata loading:** thumbnail, duration, clip count and missing state are read lazily from each project file and its media, off the main thread, and cached by the project file's modification date. The cache also keeps the card inputs, or both cards, with the switch value and resolved style id they were made with, and re-derives them when either changes (§5.4.5). Reading metadata never saves a project, because saving changes the date Home shows.

**Sidebar on Home.**

- Home is selected.
- The open project's section (rows, no actions) follows, if there is one.
- Then "Recent", with the other projects (36×20 thumbnails on macOS, 32×18 with two lines on Windows), up to 12.
- Arrow keys move through all rows. Return on a Recent row opens it.

Recording (M2) adds **Record…** (`⌥⌘N` / `Ctrl+Shift+N`) next to Import Video… in the drop bar.

### 7.1 Import sheet and the untranscribed state

Opening a video makes it playable at once (section 13, "Importing"). Transcription then starts **immediately** with the routed plan (transcription.md section 11.2) unless one of these holds, in which case the import sheet appears first (macOS sheet on the main window, Windows `ContentDialog`):

- Settings → Transcription → Engine is **Ask each time** (`transcription.engineMode = ask`);
- the language is Auto and cannot be detected locally (no multilingual whisper model installed, or detection below 0.5);
- the routed plan needs a download, a key or Apple speech assets;
- the user chose **Transcribe…** (from the untranscribed state) or **Transcribe Again…**.

```text
┌ Transcribe interview-take-3 ─────────────────────────────────────────┐
│ Language   [ Estonian ▾ ]   [x] Remember for new imports              │
│ Engine     (•) On this Mac · TalTech Estonian (874 MB download)       │
│            ( ) ElevenLabs Scribe · ≈ $0.04 · sends the audio track    │
│ ▸ Advanced (ElevenLabs only)                                          │
│     Speakers [ Off ▾ ]  (Off · Auto · 1 … 32)                         │
│     Keyterms [ VoxClip, TalTech …                         ]          │
│                                        [ Not now ]   [ Transcribe ]   │
└───────────────────────────────────────────────────────────────────────┘
```

- **Language:** list with the most recent first (`transcription.recentLanguages`), then all languages alphabetically; Auto is offered only when detection can run. "Remember for new imports" writes `transcription.language`.
- **Engine:** the routed choice first and selected, then the alternatives, each with its size line (transcription.md section 12.3) or cost line (section 8.5). ElevenLabs is listed only with a key; Apple only on macOS for supported locales.
- **Advanced** (shown only when ElevenLabs is selected): Speakers (`Off` → `diarize=false`; `Auto` → `diarize=true`; a number → `diarize=true, num_speakers`), Keyterms (one per line or comma-separated, validated per transcription.md section 8.1; the offending term is named inline).
- **Transcribe** runs the choice; choosing ElevenLabs for the first time shows its consent sheet (transcription.md section 8.5) before any upload. **Not now** closes the sheet and leaves the project untranscribed.
- **Untranscribed state** (`transcript == null`: after Not now, cancel, `noSpeech` or a failure): the transcript page shows "This video isn't transcribed yet." with **Transcribe…** (opens the sheet). The Full take row's meta reads "Not transcribed", and the sidebar actions are disabled with the tooltip "Transcribe the video to select words." The video plays, and Export works with no captions and no cuts.
- **Transcribe Again…** (macOS Edit menu, Windows CommandBar ⋯) confirms first: "Transcribe again? This replaces the transcript and removes {n} cuts, {m} corrections, {k} clips and the AI suggestions." [Transcribe Again] [Cancel] (editing spec section 10.5), then opens the sheet with the current engine and language selected.

---

## 8. Export and share

macOS: a sheet on the main window. Windows: a `ContentDialog` (`DefaultButton="Primary"`). It opens from **Export Video…** or **Export Clip…** (⌘E / Ctrl+E), the sidebar row menu (Export Clip…) and, on macOS, File > Export…. Disabled with the reason "Keep at least one word before exporting." when everything is cut (`!summary.canExport`), and with the reasons in §5.4.4 while the video is missing or unreadable and for demo projects.

The sheet edits the project: **Aspect**, **Quality**, **Also save .srt** and **Save to** read and write the project's `export` object (`aspect`, `quality`, `srt`, `folder`), and the **Captions** picker reads and writes `captions.styleId`, the same value as Captions in the right column (§6.1); the picker keeps "Off" (`"off"`). New projects start from the Settings → Export defaults. Output size, bitrate and frame rate are derived from architecture.md section 4.1 and never stored.

```text
┌ Export ───────────────────────────────────────────────────────────────┐
│ ┌──────────────┐  What      (•) This clip · Clip 2 · 0:20              │
│ │  first-frame │            ( ) All clips · All 4 clips                │
│ │  thumbnail   │            ( ) Full video · 2:10                      │
│ │  with the    │  Aspect    [9:16]  1:1  16:9  Original                │
│ │  captions    │  Captions  Highlight ▾          [x] Also save .srt    │
│ └──────────────┘  Quality   [Standard]  High                           │
│                   Save to   ~/Movies/VoxClip ▾                         │
│                                                                        │
│                                             [ Cancel ]   [ Export ]    │
└────────────────────────────────────────────────────────────────────────┘

after export (same sheet / dialog content replaced):
┌ Export ───────────────────────────────────────────────────────────────┐
│ ✓ Saved 2 videos to Movies/VoxClip                                     │
│   interview-take-3-galley-9x16.mp4   0:42                              │
│   interview-take-3-hooks-9x16.mp4    0:31                              │
│                                                                        │
│ Share   [ Show in Finder ]  [ Copy caption ]  [ Open X ]  [ Open LinkedIn ] │
│ Caption ┌──────────────────────────────────────────────────┐ 212/280 X │
│         │ Clip title + first sentence (editable)           │           │
│         └──────────────────────────────────────────────────┘           │
│                                                         [ Done ]       │
└────────────────────────────────────────────────────────────────────────┘
```

- Single-choice options are segmented choice rows, not dropdowns (except the caption style, which has many values). Named levels, not numbers.
- **What** is a single choice of **This clip** ("Clip 2 · It has to work on mute · 0:20"; only when a clip row is selected), **All clips** ("All 4 clips", the kept clips in transcript order, disabled when there are none) and **Full video** ("Full video · 2:10"). It defaults to the selected sidebar row. The `ExportTarget` lists are unchanged: `.fullEdit`, or one `.clip(id)` per clip.
- **Aspect** offers `9:16 · 1:1 · 16:9 · Original`. The stored values and the file name suffixes (`9x16`, `1x1`, `16x9`, `source`) are unchanged. Windows must map options by value, not by index.
- Progress replaces the form: "Rendering 1 of 2 · 42% · about 1 min left" with a fixed-width bar (Windows: fixed width, the Fluent `ProgressBar` minimum width otherwise pushes text) and **Cancel**. Closing the sheet keeps the export running. Progress shows on the sidebar row of the target being rendered ("Exporting 42%") instead of the toolbar subtitle or the Windows footer.
- **Ledger.** A finished export writes the ledger record (§6.2).
- **AI speech.** When the export target contains accepted AI speech, the sheet shows the disclosure line "This video contains AI-modified speech. It will show AI MODIFIED." above the buttons.
- File name pattern: `{project}-{clip}-{aspect}.mp4` (`{clip}` is `full` for the full edit; aspect as `16x9`, `9x16`, `1x1`, `source`), de-duplicated with ` 2`, ` 3`.
- **Share helpers (M1)**, behaviour in publishing.md section 2: Show in Finder / Show in Explorer, Copy caption (also offers the file for drag-out from the row), Open X (web intent with the caption), Open LinkedIn (composer with the caption). The caption field shows a per-destination count (X 280, LinkedIn 3,000).
- M2 adds "Also post to VoxConvo @handle" (checkbox, only when connected, otherwise "Connect…") and the primary becomes **Export & post**. Posting follows publishing.md section 3: the button disables on press, the final post call is never retried automatically, "Try again" reuses the render.

---

## 9. Onboarding (first launch, skippable)

On Windows, before this optional onboarding or any project, media, model, provider or key access, a native blocking dialog titled **Windows component terms** explains: “VoxClip includes Microsoft Windows components. Review and accept their terms to use this Windows build. VoxClip itself remains open source under MIT.” It displays the full bundled Windows App SDK 2.5.1 and Windows ML Runtime 2.1.74 terms offline in a scrollable read-only field that stays usable with keyboard scrolling and display scaling. **Accept and continue** records the exact current terms hash for this user; **Quit**, Escape and closing the dialog or its host window leave normal app features unavailable. The default button is Quit. No checkbox is preselected. The prompt reappears only when the terms hash changes or the receipt is absent or invalid; an accepted receipt opens the normal window directly. About → Licences continues to show the complete root notices. This dialog may initialize WinUI before the decision; it does not start normal application services.

A 560×480 sheet over Home in the main window (macOS: opt-in from Help → Welcome Tour; ADR-R29 keeps this part of ADR-R25) or a centred `ContentDialog`-sized page over Home (Windows). Three steps with a dot indicator; **Skip** is always in the top-trailing corner and lands on Home with local defaults. Reopen from Help → Welcome Tour.

```text
Step 1 of 3   Cut video by its words.
              How should VoxClip transcribe?
              (•) On this {Mac/PC}       Private and free. Downloads a model once ({size}).
                  Language  [ English ▾ ]   (Estonian picks TalTech's model)
              ( ) ElevenLabs Scribe      Your key. Sends the audio track to ElevenLabs, which keeps it under its terms.
                  [ API key ………………… ] [ Test ]   Get a key at elevenlabs.io
              ( ) Apple on-device        (macOS, supported languages only)
              [ Download model now ]   or later, when you import              [ Continue ]

Step 2 of 3   Find clips with AI (optional)
              ( ) API key                Provider [Anthropic ▾]  [ API key ……… ] [ Test ]
              ( ) On this computer       Apple Intelligence · Ollama · LM Studio
              ( ) Installed CLI          ( ) Claude Code ● Ready   ( ) Codex ● Not found
              Sends transcript text only. No audio or video.
              You can always make clips yourself: select words, press ⌘K.   [[ Not now ]] [ Continue ]

Step 3 of 3   Five keys to know
              Space play · ⌫ cut · ⌘K clip · ⌘Z undo · ⌘E export
              [ Open a video… ]                                                     [ Done ]
```

- Step 2 preselects **nothing** (AI spec section 7.1 rule 8, `llm.connector` starts empty). **Not now** is the default button; **Continue** is disabled until an option is chosen. Choosing Installed CLI also requires picking Claude Code or Codex explicitly, and then shows the AI spec section 4.8 consent text inline (for example "…counts toward your Claude plan's usage"); Continue stores `llm.cloudConsent.<id>`.
- Keys go straight to the Keychain / DPAPI (architecture.md section 11.4). Once saved, a key is never shown again; the field shows "Saved in the Keychain; paste to replace".
- **Test** makes one minimal call through the normal path and shows the result in `status.success` or `status.warning`: AI connectors as AI spec section 10.2 ("Works · {model} · {seconds} s" / "Failed: {message}"), ElevenLabs as the transcription spec's key test. CLI rows show the local detection and sign-in status first (AI spec section 6.10).
- If the user skips step 1, the first import asks inline: "Transcribe on this {Mac/PC} (download {model}, {size})" or "Use ElevenLabs (add key)".
- Step 3 on Windows reads "Space play · Delete cut · Ctrl+K clip · Ctrl+Z undo · Ctrl+E export".
- No telemetry question: there is no telemetry.

---

## 10. Settings

macOS: one retained native Settings window hosting a toolbar-style SwiftUI `TabView` with `.formStyle(.grouped)`, minimum 600×480, resizable. The Settings command reopens that window after close; appearance updates while it is open and follows System when selected. Closing it preserves app-owned model downloads and text-field drafts. Windows: a separate Settings window on Mica with a left `NavigationView` (inside the Settings window only) and `SettingsCard` / `SettingsExpander` rows (Windows Community Toolkit); default 760×600, min 560×480.

```text
macOS                                                    Windows
┌ General  Transcription  AI  Export  About ┐            ┌ Settings ──────────────────────────────── ─ ▢ ✕ ┐
│ ┌ Appearance ───────── System ▾ ┐          │            │ ◧ General       │ Transcription                   │
│ │ Transcript text size  19 ─●── │          │            │ ◧ Transcription │ ┌ Engine ───── On this PC ▾ ┐   │
│ │ Pause breath   Natural ▾      │          │            │ ◧ AI            │ ├ ElevenLabs key  ●Ready      │   │
│ │ Default caption style  Highlight ▾│      │            │ ◧ Export        │ │  [ •••••• ] Save Test Forget │   │
│ └───────────────────────────────┘          │            │ ◧ About         │ ├ Models ─────────────────── ▾ │   │
│                                            │            │                 │ │  TalTech Estonian · 574 MB ✓ │   │
│                                            │            │                 │ └──────────────────────────────┘   │
└────────────────────────────────────────────┘            └────────────────────────────────────────────────────┘
```

| Pane | Rows |
|---|---|
| **General** | Appearance: System · Light · Dark (`general.appearance`). Transcript text size (`general.transcriptTextSize`). Pause breath: Tight 0.05 s · Natural 0.15 s · Relaxed 0.30 s (`editing.pauseBreath`). Show low-confidence words (`general.showLowConfidence`). Default caption style (`captions.defaultStyleId`). Open last project on launch (Windows only, `general.openLastProject`). Check for updates automatically (`update.autoCheck`). Show transcript words on placeholders, on by default (`general.showPlaceholderWords`; help "When off, placeholders show the project title instead of its first words."; §5.4.2). Cache size limit 2 · 5 · 10 · 20 GB (`cache.limitGB`) + Clear cache, which keeps each video's waveform envelope and its saved transcription results, and Clear everything, which removes those too (architecture.md §8.2). The filler rule and the pause threshold are not settings in 0.1.0 (editing spec sections 5.0 and 12). |
| **Transcription** | Engine: On this {Mac/PC} · ElevenLabs Scribe · Apple on-device (macOS) · Ask each time (`transcription.engineMode`). Language: Auto or a list (`transcription.language`). ElevenLabs key row (SecureField / PasswordBox → Save · Test · Forget); footnote "Sends the audio track to ElevenLabs, which keeps it under its terms. You confirm before the first upload."; Advanced → Region (`transcription.elevenlabs.region`). Models list (row pattern below). Footer: "Models download on first use and never ship inside the app. Each runs entirely on this {Mac/PC}." Storage location and total size, Reveal in Finder/Explorer. |
| **AI** | Normative content in AI spec section 10.1: connector picker grouped as *Your API key* / *On this computer* / *Installed CLI (your own sign-in)*; model picker `{name} ({tier})` + **Custom…** + **Refresh models**; per kind: key row, local server URL and status line, Apple availability and supported languages, CLI status line ("Found claude 2.1.309 at ~/.local/bin/claude · Signed in") with **Choose…** and **Sign-in help**; **Test**; "Snap clip edges to sentence boundaries". Footnote per group on what is sent. Layout follows this document (grouped form rows, no cards). |
| **Export** | Defaults for new projects: aspect (`export.defaultAspect`), Quality: Standard · High (`export.quality`), Captions: Burn in · Burn in + .srt (`export.srt`). File name pattern (`export.fileNamePattern`). Default folder (`export.folder`). Open folder after export (`export.openFolderAfter`). Windows: Encoder (read-only, from the probe) + "Re-check encoders". |
| **Accounts** (M2) | VoxConvo: "Not connected" / "@handle" with **Connect** (device flow, publishing.md) / Disconnect. Footnote: "Posting is optional. VoxClip never posts without your click." |
| **Voice Lab** (M3, beta) | Show Voice Lab. ElevenLabs and lip-sync provider keys. Consent records. |
| **About** | Version, Check for updates, licences (the bundled `THIRD_PARTY_NOTICES.md`: models, fonts OFL, Unicode data, libraries), GitHub link, "What leaves this device", Reset onboarding, Reveal logs. Windows also shows "This software uses libraries from the FFmpeg project under the LGPL" with a link to the `VoxClip-win-ffmpeg-source.tar.xz` asset of the running version (release.md section 1.1). |

Every row's settings key, type and default are in `shared/schemas/settings.schema.json`.

Windows 0.1 import accepts the container list only with the codecs in `tools/ffmpeg-build/components.md`. ProRes, DNxHD/HR, MJPEG, MP3, AC-3/E-AC-3, ALAC and FLAC tracks can occur inside MP4/MOV/MKV but currently produce `decodeFailed` on Windows. The import error uses the normal recoverable media-error treatment; it does not imply the file was changed.

Key row (both platforms): label, secure field with placeholder = key hint or "Saved in the Keychain; paste to replace" / "Saved for your Windows account; paste to replace"; buttons **Save key** (disabled when empty), **Test** / **Testing…**, **Forget key** (only when a key exists); result line from the owning spec's Test (green "Works …" / orange "Failed: …"). Footnote: AI keys "The key stays in the macOS Keychain and is used only for AI features."; the ElevenLabs key "The key stays in the macOS Keychain and is used only for transcription." (Windows: "…encrypted for your Windows account…").

Model row: name; "languages · size · licence"; third-party note with a Source link; state `Installed ✓` + Remove | progress % + Cancel | Download. Third-party models show a confirmation before download: "Download {name} from {host}? This model is not published by VoxClip. It downloads from the publisher ({size}) and runs on this {Mac/PC}. Licence: {licence}." [Download] [Cancel] [Open source page].

---

## 11. Keyboard shortcuts

### 11.1 Scope rule

Single-letter keys (J K L I O P C [ ]) and bare Space, ⌫ and arrows act on the editor only when keyboard focus is in the transcript, the viewer or the timeline **and** no inline correction field is open **and** no IME composition is in progress (`NSTextInputClient.hasMarkedText()` false; WinUI: focus is not a `TextBox`, `PasswordBox`, `AutoSuggestBox`, `RichEditBox` or `NumberBox`). In any text field they type text. Single-letter keys do not act in the sidebar list either, except [ and ]. macOS implements them in the `NSTextView` subclass's `keyDown` and in `.onKeyPress` on the viewer and timeline; Windows uses `KeyboardAccelerator`s scoped with `ScopeOwner` to the editor root plus a focus check.

On Windows avoid **Ctrl+Alt+letter** (AltGr on many layouts types characters). Use Ctrl+Shift.

### 11.2 Map

| Action | macOS | Windows | Notes |
|---|---|---|---|
| Play / pause | Space | Space | |
| Play from caret | ⇧Space | Shift+Space | |
| Preview this cut | P | P | From 2.0 s before to 2.0 s after the selection, cuts applied |
| Shuttle back / stop / forward | J / K / L | J / K / L | L again: 1× → 1.5× → 2×. J jumps back 3 s per press. K stops and resets the rate |
| Back 3 seconds | J | J | J also shuttles back on repeat, as before |
| Forward 3 seconds | — | — | Viewer bar button only. L is shuttle |
| Previous / next word | ← / → | ← / → | Moves the caret; the playhead follows when paused |
| Extend selection by word | ⇧← / ⇧→ | Shift+← / → | |
| Previous / next sentence | ⌥← / ⌥→ | Ctrl+← / → | |
| Go to start / end | ⌘↑ / ⌘↓ (Home / End) | Ctrl+Home / Ctrl+End | |
| Cut selection | ⌫ or ⌦ | Backspace or Delete | Restores if the whole selection is already cut |
| Restore selection | ⇧⌫ | Shift+Backspace | |
| Correct word | Return, C, or double-click | Enter, C, or double-click | Esc cancels; Tab saves and moves on |
| Undo / redo | ⌘Z / ⇧⌘Z | Ctrl+Z / Ctrl+Y (and Ctrl+Shift+Z) | One step per command |
| Select all / copy text | ⌘A / ⌘C | Ctrl+A / Ctrl+C | Copy takes the selection's transcript text |
| Cut fillers | ⌥⌘U | Ctrl+Shift+U | |
| Tighten pauses | ⌥⌘P | Ctrl+Shift+P | |
| Restore all cuts | ⌥⌘R | Ctrl+Shift+R | Keeps corrections |
| Show / hide cut words | ⇧⌘H | Ctrl+Shift+H | |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G | Ctrl+F / F3 / Shift+F3 | "Cut all N" in the find bar |
| Make clip from selection | ⌘K | Ctrl+K | Also the selection bar's default |
| Find clips | ⇧⌘K | Ctrl+Shift+K | Opens the Find Clips popover or flyout |
| Rewrite… (Voice Lab on) | ⇧⌘R | Ctrl+R | |
| Keep / dismiss suggestion | Return / ⌫ on the focused suggestion row | Ctrl+Enter / Delete on the focused row | Plain Enter on Windows selects and previews |
| Rename clip | Return on a focused kept clip row | F2 | |
| Remove clip | ⌫ on a focused kept clip row | Delete | One undo step |
| Set clip start / end at caret | I / O | I / O | |
| Previous / next clip | [ / ] | [ / ] | Kept clips, transcript order |
| Back to Full take | Esc (transcript, nothing else open) | Esc | Replaces "Preview clip / back to full take" |
| Home / Full take | ⌘1 / ⌘2 | Ctrl+1 / Ctrl+2 (Alt+Left also selects Home) | Replaces "Inspector tabs" |
| Show / hide viewer | ⌥⌘I | Ctrl+Shift+I | Replaces "Toggle inspector" |
| Show / hide sidebar | ⌃⌘S | — (TitleBar pane toggle) | |
| Selection bar focus | Tab or ⌃F6 | Shift+F10 or Menu key | |
| Move focus to the next pane | ⌃F6 | F6 (Shift+F6 goes back) | Order in §15 |
| Transcript text bigger / smaller / reset | ⌘+ / ⌘− / ⌘0 | Ctrl+= / Ctrl+− / Ctrl+0 | |
| Export… | ⌘E | Ctrl+E | |
| Import / open | ⌘O | Ctrl+O | |
| New project | ⌘N (New Project from Video…, movie picker, main window) | Ctrl+N (new main window on Home) | Replaces "New window" |
| New recording (M2) | ⌥⌘N | Ctrl+Shift+N | |
| Settings | ⌘, | Ctrl+, | |
| Keyboard shortcuts overlay | ⌘/ | Ctrl+/ (also F1) | |
| Close project | ⌘W closes the project and shows Home; on Home ⌘W closes the window | Ctrl+W as before | |
| Full screen | ⌃⌘F | F11 | |

### 11.3 macOS menu map

- **VoxClip:** About VoxClip, Check for Updates…, Settings…, Hide, Quit.
- **File:** New Project from Video… (⌘N), New Recording (M2, ⌥⌘N), Open… (⌘O; projects and movies, opening in the main window), Open Recent, Close Project (⌘W), Save (⌘S), Save As… (⇧⌘S), Duplicate, Rename…, Move To…, Revert to Saved…, Export… (⌘E), Reveal Media in Finder.
- **Edit:** Undo, Redo, Cut Selection, Restore Selection, Correct Word, Rewrite… (⇧⌘R), Insert Words…, Select All, Copy Text, Find…, Find Next, Find Previous, Cut Fillers, Tighten Pauses, Restore All Cuts, Transcribe Again…; M2: Tighten with AI…, Clean Audio…; M3: Change Voice….
- **View:** Show/Hide Sidebar (⌃⌘S), Show/Hide Viewer (⌥⌘I), Home (⌘1), Full Take (⌘2), Show/Hide Cut Words (⇧⌘H), Show/Hide Pauses, Source/Edited Timeline, Bigger/Smaller/Actual Size, Enter Full Screen. Each Show/Hide title describes the current action.
- **Playback:** Play/Pause, Play from Selection, Preview Cut, Back 3 Seconds (J), Forward 3 Seconds, Shuttle Back/Stop/Forward, Go to Start/End.
- **Clip:** Make Clip from Selection (⌘K), Find Clips… (⇧⌘K), Keep Suggestion, Dismiss Suggestion, Keep All Suggestions, Rename Clip…, Remove Clip, Set Start (I), Set End (O), Previous Clip ([), Next Clip (]), Export Clip….
- **Window:** standard items, plus "VoxClip" (brings back the main window).
- **Help:** Keyboard Shortcuts, Welcome Tour, What Leaves This Mac, Reveal Logs, Copy Diagnostics.

---

## 12. Recording (M2)

The record view opens in the main window as a new project (the open project is saved first). Camera preview at its own aspect (radius 12, mirrored by default with a toggle), a top-left REC pill (`overlay.scrim`, SF Mono or Cascadia Mono 600 12, blinking `record.live` dot at 1.2 s steps), a 3 px progress line, a 3-second centre countdown and the hint "Recording starts after a 3-second countdown." Toolbar: Camera ▾, Microphone ▾ (with level meter), Mirror, **Record** (●). Space starts and stops; Esc cancels the countdown. On Stop the window becomes the editor with no extra click. No time limit; a soft notice at 60 minutes. Permission errors are inline with a deep link (`x-apple.systempreferences:com.apple.preference.security?Privacy_Camera` / `…Privacy_Microphone`; `ms-settings:privacy-webcam` / `ms-settings:privacy-microphone`).

---

## 13. States and exact copy

Voice: short, factual, calm, always reassuring about the media. No exclamation marks, no emoji. `{Mac/PC}` is "Mac" on macOS and "PC" on Windows. macOS shows these in inline callout rows; Windows uses `InfoBar` with the severity given.

| Situation | Where | Copy / UI |
|---|---|---|
| No project (empty library) | Home | Hero "Drop a talking-head video". Sub "VoxClip transcribes it so you can cut by words, make clips and add captions." Buttons "Import Video…", "Open Project…". Footnote "{types} · Media and edits stay on this {Mac/PC}." |
| Home search, no results | Home | "No projects match “{query}”." |
| AI callout | Home | four variants by readiness (§7) |
| Recent project missing | Home card; sidebar Recent row | Card: "Video not found." [Locate…]; row: "⚠ Not found" (macOS) or "⚠ Video not found" (Windows) |
| Recent project, corrupt file | Home card; sidebar Recent row | Card: "Can't read video." [Locate…]; row: "⚠ Can't read video" |
| Drag over | whole window | "Drop to transcribe" on `overlay.drop`, 2 dashed `overlay.dropBorder`, radius 14. Line: macOS "One video at a time · MOV, MP4, M4V"; Windows "{file} · VoxClip makes a new project next to the video". With a project open: "{project} is saved first." Not allowed (M2 while recording): "Finish or close the recording first" |
| Unsupported file (macOS WebM/MKV) | Home / drop | "VoxClip can't open {ext} files on Mac yet. Export the video as MP4 or MOV and try again." (Informational) |
| Not transcribed | Editor (transcript page) | "This video isn't transcribed yet." [Transcribe…] (shown while `transcript == null`; section 7.1) |
| Importing | Editor | The video is playable immediately. The transcript page shows 6 skeleton lines (static under Reduce Motion) and the stages "Reading video… → Extracting audio… → Transcribing on this {Mac/PC} · 42% → Aligning words…" (ElevenLabs: "Transcribing with ElevenLabs · 42%") with **Cancel**. Announcements every 10%. |
| Transcribing | Home card; Full take row; editor | Card: chip "Transcribing · {p}%" and progress line; meta "Transcribing on this {Mac/PC}" [Cancel]. Row: "Transcribing · {p}%" [Cancel]. Editor: unchanged (6 skeleton lines and stages) |
| Transcribed | Editor | "Transcribed on this {Mac/PC} · 1,842 words" (Success, auto-dismiss after 6 s). |
| Model missing | Editor | "Download the {model} model ({size}) to transcribe on this {Mac/PC}." [Download] [Use ElevenLabs instead] (Informational) |
| Model downloading | Editor / Settings | "Downloading {model} · 37% · {done} of {total}" [Cancel] |
| Model checksum failed | Settings | "{file} did not match its checksum. Try the download again." (Error) [Retry] |
| Key rejected | Editor | "{provider} rejected the key ({status}). Your video is still here." [Open Settings] [Transcribe on this {Mac/PC}] [Retry] (Error) |
| Offline | where a provider is used | "You're offline. On-device transcription and editing still work." Provider rows show "Offline". (Warning) |
| No speech | Editor | "We didn't hear any words. Check the audio track or choose the language." [Language ▾] [Retry] (Warning) |
| No audio track | Editor | "This video has no audio track, so there is nothing to transcribe." You can still export. (Informational) |
| No audio output device (Windows) | Editor, when preview plays | "No audio output device. Playing without sound." (Informational) Shown when the PC has no default output device, or the device is removed during playback and no other device can take over. Video, captions and the playing word keep moving, and pause and seek still work. Each later Play, or resuming after a seek or edit, tries again; the notice clears when sound plays. When headphones are unplugged and speakers remain, sound moves to the speakers and no notice appears. Export is unaffected. |
| Audio output in use (Windows) | Editor, when preview plays | "Another app is using the audio output. Playing without sound." (Informational) Shown when another app holds the output device in exclusive mode, at Play or during playback. Otherwise the same as "No audio output device": playback continues without sound, each later Play or resume tries again, and the notice clears when sound plays. |
| Media missing | Editor | "Can't find {file}. Edits are saved." [Locate…] (Warning) |
| Corrupt file | Editor | "Can't read {file}. Edits are saved." [Locate…] (Warning) |
| Media missing or corrupt, Export | Export tooltip | "Locate the video to export." |
| Demo project | Editor InfoBar or callout (Informational) | "Demo project with no video. Changes aren't saved to the fixture." |
| Demo project, Export | Export tooltip | "Demo projects have no video to export." |
| Stage, missing | stage (non-interactive) | "Video not found" and the file name |
| Stage, corrupt | stage (non-interactive) | "Can't read this video" and the file name |
| Stage, loading under Reduce Motion | stage | "Loading video…" |
| Placeholder words | Settings → General | "Show transcript words on placeholders" (on); help "When off, placeholders show the project title instead of its first words." |
| Relinked file differs | Editor | "This file looks different. Use it anyway?" [Use it] [Choose another] |
| Clips: no connector | callout under the sidebar actions | "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI." [Set Up AI…], plus "You can also select words and press ⌘K to make a clip yourself." (Windows: Ctrl+K) |
| Clips: CLI not found | callout under the sidebar actions | "{Claude Code/Codex} isn't installed. {installHint}" (hint from the catalogue) |
| Clips: CLI not signed in | callout under the sidebar actions | "{cli} isn't signed in. {signInHint}" [Sign-in help] |
| Clips: Apple model locale | callout under the sidebar actions | "Apple's on-device model doesn't support {language}. Use an API key, a CLI or a local model for this project." |
| Clips: local server down | callout under the sidebar actions | "Ollama isn't running at {url}. Start Ollama and try again." / "LM Studio's server isn't running at {url}. Start it from LM Studio's Developer tab." |
| Clips: Custom with no text | Find Clips popover or flyout | the prompt file's `messages` text (VoxConvo: "Describe the clips you want.") |
| Clips: finding | sidebar, under Suggested | "Finding clips…" [Cancel], with "{connector} · reading {m:ss} of transcript". Announce "Finding clips", then "Found {n} clips" |
| Clips: none found | sidebar, under Suggested | the prompt file's `messages` text (VoxConvo: "No clips matched. Try another style or describe what you want.") [Find Clips…] |
| Clips: any other AI failure | callout under the sidebar actions | the AI spec section 5 message for the error, followed by "Your edits are saved." [Retry] |
| Project with no clips | sidebar, under Full take | "No clips yet. Select words and press ⌘K." (Windows: Ctrl+K), 11 `text.secondary` |
| Clip already exists | announcement, selection bar tooltip | "Clip {k} already covers these words." |
| Clip made / kept / dismissed / removed | announcement | "Clip {k} made." / "Clip {k} kept." / "Suggestion dismissed." / "Clip {k} removed." |
| Everything cut | Editor, Export | Export disabled; status "Keep at least one word before exporting." |
| Suggestion selected, Export pressed | Export tooltip | "Keep this clip to export it." |
| Edit summary | toolbar subtitle / command row | §3.5 grammar: "{edited} after cuts · {n} cuts", "Clip {k} · {edited} after cuts · {n} cuts", "Clip {k} · {edited} · No cuts yet" |
| Export progress | Export sheet; sidebar row | sheet: "Rendering {i} of {n} · {p}% · about {t} left" [Cancel]; row: "Exporting {p}%" with a ring |
| Export done | Export sheet | "Saved {n} video(s) to {folder}" + share buttons |
| Export failure | Export sheet; sidebar row | sheet: "Export stopped: {reason}. Your edits are saved." [Try again]; row: "⚠ Export failed" [Retry] |
| Exported, then edited | sidebar row, second line | "⚠ Edited since export" in `status.warning` |
| No encoder (Windows) | Export | "No H.264 encoder is available on this PC. Install the Media Feature Pack or update your graphics driver." (Error) |
| HDR source (Windows) | Export | "This video is HDR. Colours are converted to standard range and may look flatter." (Informational) |
| Disk full | Export, download | "There isn't enough free space on {volume}. Free up {size} and try again." |
| Caption copied | Export | "Caption copied." (transient, 2 s) |
| Update available (macOS) | Home callout, app menu | "VoxClip {version} is available." [Download] |
| Update ready (Windows) | InfoBar | "VoxClip {version} is ready. Restart to update." [Restart now]; during transcription, clip search or export the button is disabled with "Finish the current task first." |
| Up to date | manual check | "VoxClip {version} is the latest version." |
| Update check offline | manual check | "Couldn't check for updates. You're offline." |
| Post failure (M2) | Export sheet | "Saved to {folder}. Posting to VoxConvo failed: {reason}." [Try again] (render reused, never auto-retried) |
| Camera or mic denied (M2) | Record view | "Camera access is off. Turn it on in System Settings → Privacy & Security → Camera." [Open Settings] |
| Unsaved changes | — | Projects autosave. macOS: an untitled project (never saved under a name) gets the system keep/delete prompt on close; named projects close silently. Windows: projects always have a file (architecture.md §2.6), so closing never prompts. |
| Transcribe again | confirmation | "Transcribe again? This replaces the transcript and removes {n} cuts, {m} corrections, {k} clips and the AI suggestions." [Transcribe Again] [Cancel] |
| ElevenLabs first upload | sheet / ContentDialog | Title "Transcribe with ElevenLabs?" Body "ElevenLabs Scribe uploads this take's audio track with your key. ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. No video is sent." [Continue] [Cancel] (transcription.md section 8.5) |
| Project saved outside the video folder (Windows) | InfoBar (Informational) | "Saved in VoxClip's folder. Use Save project as… to keep it with the video." |
| Rewrite: fit meter | Rewrite panel, New words | One line per voice hunk: "about {s} s for a {g} s gap: fits" or "about {s} s for a {g} s gap: will change length". With more than one hunk, each line starts with the hunk's new words in quotes |
| Rewrite: generating | Rewrite panel | "Generating take {i} of {n}…" [Cancel]; announcements "Take {i} ready." and, after a run in which no take fits, "{n} takes ready." or, only when some failed, "{n} takes ready, {k} failed the speech check." |
| Rewrite: take fits | Rewrite panel | "Take {i} fits." Generation stops. Only when an earlier take failed does it add "{k} failed the speech check." |
| Rewrite: provider error | Rewrite panel | "{provider} rejected the key ({status}). Your edits are saved." [Open Settings] [Retry] (Error) |
| Rewrite: no take passed | Rewrite panel | "These takes didn't sound right. Try different wording or re-record." [Generate Again · ≈ {cost}] |
| Rewrite: failed take | Rewrite panel row | "Take {i} didn't pass the speech check." [Try Another · ≈ {cost}] |
| Rewrite: length changed | Rewrite panel | "Take {i} runs {s} s longer than the words it replaces. Choose how the video keeps up." For a shorter take: "Take {i} runs {s} s shorter than the words it replaces. Choose how the video keeps up." Options as §6.3 |
| Rewrite: no voice | Rewrite panel, Voice row | "No voice yet" [Create Your Voice… (2 min)] |
| Rewrite: too much | Rewrite panel | "That's a lot to re-voice. Re-record these sentences instead." |
| Rewrite: no room tone | Rewrite panel | "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in." [Clean Audio…]; Generate is disabled |
| Rewrite: too close to the take edge | Rewrite panel | "This change is too close to the {start/end} of the take to blend in. Re-record this sentence instead." Generate is disabled |
| Rewrite: disclosure | Rewrite footer | "Exports show AI MODIFIED on the video and in the post." |
| Voice Lab off, Rewrite chosen | sheet | voice-lab.md §5 one-time sheet |

---

## 14. Appearance and materials

- **Light and dark** follow the system. Dark is the hero look for screenshots. The video stage stays black in both and in High Contrast, and so do caption cards (§5.4).
- **macOS Liquid Glass is chrome only:** the sidebar, toolbar, sheets, menus and popovers (system), plus one custom glass element, the transcript selection bar (§4.3). Content surfaces are opaque tokens (`bg.surface` for the transcript, `stage` for video, `timeline.*` for the strip). Never glass on glass. Custom surfaces check `accessibilityReduceTransparency` and switch to opaque fills with `line.strong` borders; system glass handles Reduce Transparency and Increase Contrast itself. Tint glass only to convey meaning (only Export, and Import Video… on Home, are prominent).
- **Windows:** Mica on the main window and the Settings window, applied once. `LayerOnMicaBaseAltFillColorDefaultBrush` behind the CommandBar. Acrylic only for transient surfaces: menus, flyouts, the selection `CommandBarFlyout` and the Find Clips flyout. Cards and panes use theme `Layer*` / `Card*` brushes. `TitleBar` for chrome, `CommandBar` for grouped commands, `NavigationView` for the sidebar, `CommunityToolkit` `Segmented` for Frame and Edited/Source, `InfoBar` for status, `ContentDialog` for Export, `TeachingTip` for first-run hints.
- **Accent: Petrol**, in two tones. `accent.default` (`#1C6B69` light, `#237D7A` dark) is the fill that carries text: prominent buttons, the selected choice, the playing word. `accent.text` (`#1C6B69` light, `#63BDB6` dark) is for marks, rings, links, clip badges and the playhead. Both tones pass with each platform's own text on the accent.
  - **macOS:** the `AccentColor` asset (generated from `accent.default`, compiled into the bundle by `bundle.sh`) and `NSAccentColorName` make Petrol the app accent, so standard controls draw the system's white on it. Users who chose a system accent colour see theirs on standard controls, which is correct. `DesignValues.accentText` uses `accent.text` only while the accent is the asset. A bare `swift run` has no asset, so DEBUG builds tint their SwiftUI roots with `accent.default`; AppKit focus rings and text selection stay system blue there, and accent evidence for those must come from a bundled app.
    - Every VoxClip accent mark is drawn from `Color.accentColor`, which is Petrol when the system accent is Multicolor, or from `DesignValues.accentText`.
    - When the user picks another accent, `accentText` and `accentSoft` are derived at runtime: mix `NSColor.controlAccentColor` toward `text.primary` until it reaches 4.5:1 on `bg.surface`. For Blue in light mode that gives `accentText` #046CDD (4.76:1) and `accentSoft` #DCE7F7 (14% over the page).
    - Export uses `.glassProminent` and therefore follows the accent. It is never hard-tinted with `accent.default`.
  - **Windows:** `App.xaml` overrides the accent ramp in its `Light` and `Default` theme dictionaries, so Petrol replaces the user's accent. `SystemAccentColor` is `#237D7A` in both, so text selection and `SystemControlHighlightAccentBrush` never fall back to the user's accent. Light: `SystemAccentColorDark1/2/3` `#1C6B69` / `#155755` / `#0F4544`. Dark: `SystemAccentColorLight1/2/3` `#3F9E98` / `#63BDB6` / `#8FD3CD`. `TextOnAccentFillColorPrimary` is `#FAF9F6` / `#141517`, never pure black. High Contrast keeps the system colours. WinUI builds `TextOnAccentFillColorPrimaryBrush` from its own colour with `StaticResource`, so framework controls may keep `#FFFFFF` / `#000000` on the accent (6.3:1 / 9.5:1).
    - The transcript draws its own selection with `selection.transcript` (`text.primary` on it 11.5:1 light, 7.96:1 dark). Text boxes keep the system selection, which is Petrol through the overridden `SystemAccentColor`.
- **Accent budget:**
  - Petrol solids per screen are at most four: Export, the playing word, the switch that is on, and the selected clip's badge. Home has one: Import Video….
  - System focus fills (the focused sidebar selection on macOS) do not count.
  - Clip identity uses neutral badges on `clip.badgeBackground` and `line.strong` rules. The gallery check is neutral. Toolbar glyphs are monochrome. Only the Home sidebar glyph keeps the system's accent tint.
  - Media stand-ins spend no Petrol: their chips, progress lines, word rhythm and audiogram are neutral (§5.4). Near media, the only accent marks remain the selection ring and the playhead.
- **Colour rules:** one accent, Petrol; red only for cuts and recording; amber only for warnings and suggestions; no pure black except the stage; no gradients on native surfaces.
- **High Contrast (Windows):** the `HighContrast` theme dictionary maps every token to its `windowsHighContrast` system colour (tokens.json). Strikethrough survives High Contrast, so cut state stays visible.

---

## 15. Accessibility

- **Screen readers.** The transcript is text (NSTextView / RichTextBlock), so VoiceOver and Narrator read it by word, line and paragraph. Each word's accessible description adds its state: "um, cut", "pause 1.4 seconds", "pause 1.6 seconds, cut", "cadence, playing", "it isn't a clip yet, AI modified". macOS: custom rotors (`accessibilityCustomRotors`) for Cuts, Pauses, Suggested fillers, Clips and AI words, and custom actions on the focused word (Cut, Restore, Correct, Play from here). Every command posts an announcement ("Cut 3 words", "Restored all cuts, corrections kept") via `NSAccessibility.post(element:notification: .announcementRequested, …)` or UIA `RaiseNotificationEvent`.
- **Timeline** is a slider: "Playhead, 42 seconds of 2 minutes 15 after cuts, 12 cuts". Arrow keys step by word.
- **Caption gallery** is a single-choice picker named "Caption style"; each option is named "{name}: {description}".
- **Keyboard.** The whole loop (import → cut → captions → clips → export → share) works without a pointer. Focus and F6 / ⌃F6 order: sidebar → toolbar or `CommandBar` → transcript → viewer → Captions or Rewrite panel → timeline. On macOS the selection bar, while it shows, comes right after the transcript (§4.3). On Windows Shift+F6 goes back, from any focused descendant. On macOS, Full Keyboard Access reaches every control with Tab. Icon-only buttons have explicit names: Back 3 seconds, Play, Forward 3 seconds, Close Rewrite, Reject take 2, Keep suggested clip 5, Dismiss suggested clip 5, Hide Viewer. The Windows splitter is focusable: ← and → resize by 16 within 300–560, and Enter collapses or expands the column. It is named "Resize viewer". The macOS divider relies on View > Show/Hide Viewer and the `AXSplitter` increment and decrement actions. System focus rings / focus visuals; custom rings are 2 `focus.ring`, offset 2.
- **Sidebar and panel focus.** Choosing a sidebar row keeps focus on the row; Enter on Windows invokes it. F6 from the pane lands on the `CommandBar`. After Keep, Dismiss or Remove, focus moves to the next row, or to Full take. Opening Rewrite focuses "What should change?", and Esc returns to the words. Alt+Left from the editor selects Home. A recent project's accessible name is its visible title. A missing one adds ", video not found", and the other media states add theirs (§5.4.9).
- **Colour independence.** Cut = strike + dimming; timeline cuts = hatching; clips = brackets and numbers; fillers = dotted underline + tooltip. No state depends on red versus green. The selected clip is shown by an accent badge plus the row selection, and the selected Frame by a semibold label; suggestions by dashes and the Suggested header; AI words by the AI chip and a dashed underline; exported state by a glyph and a word.
- **Contrast** (WCAG 2.x, Petrol palette): every text pair is at least 4.5:1 and every UI boundary at least 3:1, in light and dark, on macOS and Windows, including on-accent text. `npm --prefix tools/design test` enforces this through `tools/design/contrast.mjs`, which prints the measured table and fails on any colour token that is neither checked nor exempted; see §16 for the values. Cut words stay at least 4.5:1 because they are still content, and pause-token text uses `text.muted`, struck through in `cut.stroke` when cut. Re-check when a surface token changes.
- **Motion.** Under Reduce Motion (macOS `accessibilityDisplayShouldReduceMotion`, Windows `UISettings.AnimationsEnabled`): sidebar selection jump-scrolls the transcript; the timeline zoom switches without animating; the selection bar and the Rewrite panel appear without slide or scale (a crossfade of 150 ms or less); gallery tiles are static; the strike draw-in, the playing-word slide and the M2 countdown scaling are off. Media stand-ins drop their sheen, crossfade, moving dots and stage ring, and the word rhythm and audiogram page instead of scrolling (§5.4.9).
- **Reduced transparency.** Under Reduce Transparency or Increase Contrast (Windows: Transparency effects off or a contrast theme), the sidebar's custom parts and the selection bar become opaque `bg.elevated` with a 1 px `line.strong` edge. Media chips switch to their opaque tokens (§5.4.8).
- **Targets.** macOS controls are at least 24 pt in the sidebar and selection bar and 22 pt elsewhere; words get 2 pt vertical hit slop. Windows targets are at least 32×32 epx. The timeline track's whole 30 high band is the scrub target. Trim handles have 24 wide hit regions.
- **Text size.** Transcript zoom 13–28. Windows honours the system text-size setting through the Fluent type ramp.
- **Captions as accessibility.** `.srt` sidecar export; default styles are readable on any frame (the bold styles have a stroke).
- **Localization.** Strings in String Catalogs (`.xcstrings`) and `.resw`. Layouts tolerate 30% text growth and right-to-left languages. M1 ships English UI; Estonian UI may follow.

---

## 16. Design tokens

`shared/design/tokens.json` (format `voxclip-tokens/1`) is the only source of colours, type, spacing, radii, strokes, motion and fixed sizes. `tools/design` generates:

- `apps/macos/Sources/VoxClip/Design/Tokens.swift`: `extension Color { static let vcTextPrimary = Color(nsColor: NSColor(name: "vcTextPrimary") { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }) }`, plus `CGFloat` constants and `Font` helpers. Typography helpers use the system font (`SF Mono` means its monospaced design); `fontFiles` adds file-URL loaders for the bundled DM Sans and Geist Mono, which only rendered video uses. `system:` values map to the named `NSColor`.
- `apps/windows/src/VoxClip.App/Themes/Tokens.xaml`: a `ResourceDictionary` with `ThemeDictionaries` keyed `Default` (dark), `Light` and `HighContrast` (from `windowsHighContrast`), `SolidColorBrush` per colour token named `Vc<Group><Name>Brush`, `x:Double` and `Thickness`/`CornerRadius` resources for dimensions. A dimension's `$value` is the macOS value; its `windows` extension replaces it here, for example the transcript gutter (84 on macOS, 76 on Windows).
- `apps/macos/Resources/Assets.xcassets/AccentColor.colorset`: `accent.default` (marked `macosAsset`), light for Any and dark for Dark, compiled by `bundle.sh`. The generator owns the catalog: `check` fails on any file there it does not produce.

Naming: token path `color.text.primary` → Swift `vcTextPrimary`, XAML `VcTextPrimaryBrush`. Generated files carry `GENERATED from shared/design/tokens.json - do not edit`. CI regenerates and fails on drift.

Contrast is a test, not a note: `npm --prefix tools/design test` computes WCAG 2.x contrast for every text-on-surface pair the apps draw (4.5:1), every text or glyph on the accent (4.5:1, including the macOS system white and the Windows `App.xaml` ramp, whose ten values are pinned) and every UI boundary and mark (3:1), in light and dark. It fails when a colour token is neither checked nor exempt with a reason, and when the text hierarchy stops falling from `text.primary` through `text.secondary` to `text.muted` and `text.tertiary` on any surface. System glass the apps never paint is approximated from the ADR-R29 mockups (`glass.sidebar` in `contrast.mjs`). `npm --prefix tools/design run contrast` prints the table. Lowest pairs: text 4.58:1 (dark `text.secondary` on `clip.badgeBackground` over the sidebar glass), on-accent 4.65:1 (dark `accent.on` on `accent.default`), boundaries 3.12:1 (light `line.strong` on `bg.sunken`); on Windows, on-accent 4.90:1 (white on `SystemAccentColor` `#237D7A`).

The palette is the Document direction from the October 2026 design study: paper and ink neutrals and one accent, Petrol. Each colour token's `source` extension names the study token its value comes from (for example `bg.elevated` is the study's raised), or the ADR-R29 mockup token. `line.subtle` was removed because the study has two separators. `text.disabled`, `record.*`, `overlay.scrim` and `overlay.transportOpaque` keep values the study does not define. `stage` stays `#000000` rather than the study's `#0B0B0C`, because letterboxed video wants true black (§14). It is also the caption card's backdrop (§5.4.3). Three values step away from their sources so every pair passes: `text.muted` sits between `text.secondary` and `text.tertiary` (the study's pause label was brighter than `text.secondary`), `word.cut` is one step past the study's cutText so cut words pass on `pause.background`, and the dark `clip.badgeBackground` is 10% rather than the ADR-R29 delta's 13% so badge numerals pass on the sidebar glass.

ADR-R29 adds `clip.badgeBackground`, `timeline.keptBackground`, `timeline.scopeDim` and `selection.transcript`, and retunes `timeline.waveform`. `timeline.clipBracket` marks the selected clip only; unselected brackets use `line.strong`. `timeline.clipBand`, `size.inspector`, `size.welcomeWindow`, `size.transportPillHeight`, `size.footerStatusHeightWindows` and `size.breakpointThreeColumn` are deprecated and removed with the old layout.

The media stand-ins (§5.4) add `chip.mediaBackground`, `chip.mediaStroke`, `chip.mediaBackgroundOpaque`, `chip.mediaForeground` and `chip.warningGlyph` (§5.4.8). They have one value in both themes because they sit on media. They join tokens.json, with their pairs in `tools/design/contrast.mjs`, when the first chip is built.

Summary (full values in tokens.json):

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg.window` / `bg.surface` / `bg.sunken` | `#141517` / `#1B1C1F` / `#141517` | `#F0EFEA` / `#FAF9F6` / `#F0EFEA` | window and sheets, transcript page, dock and timeline bed |
| `bg.elevated` / `bg.muted` / `bg.input` | `#25262A` / `#2A2B2F` / `#25262A` | `#FEFDFB` / `#ECEAE4` / `#FEFDFB` | tiles and cards, hover rows, custom inputs |
| `line.default` / `.strong` | `#2E2F33` / `#6C6E75` | `#E3E1DB` / `#85878E` | hairlines, 3:1 control boundaries and unselected clip rules |
| `text.primary` / `.secondary` / `.muted` / `.tertiary` / `.disabled` | `#ECEAE4` / `#A8AAB0` / `#9C9EA4` / `#8F9198` / `#777C8D` | `#1A1B1F` / `#575A61` / `#5E6168` / `#66696F` / `#9396A4` | text, in falling contrast; timecodes are `text.tertiary` |
| `accent.default` / `.pressed` | `#237D7A` / `#1C6764` | `#1C6B69` / `#155755` | Petrol fill that carries text, its pressed state |
| `accent.text` / `.on` / `.soft` | `#63BDB6` / `#FAF9F6` / `#1F3F3D` | `#1C6B69` / `#FAF9F6` / `#D3E6E3` | links, marks, playhead; text on the fill; selection tint |
| `selection.transcript` | `#1F4C4B` | `#C5D7D4` | Windows transcript selection |
| `word.playingBackground` / `Foreground` | `#237D7A` / `#FAF9F6` | `#1C6B69` / `#FAF9F6` | playing word |
| `word.cut` / `.filler` / `.lowConfidence` / `.correctionDot` | `#93959C` / `#E0AE55` / `#7C7E85` / `#8F9198` | `#66686F` / `#9A5B00` / `#7E8087` / `#66696F` | cut text, suggested fillers, word marks |
| `cut.stroke` / `cut.fill` / `cut.pauseFill` | `#EE7F6E` / `#EE7F6E` / `#84878E` | `#C2402F` / `#C2402F` / `#6F7278` | strike, timeline hatches |
| `pause.background` | `#2A2B2F` | `#ECEAE4` | pause tokens (`text.muted` on it) |
| `clip.badgeBackground` | `#ECEAE41A` (paper 10%) | `#1A1B1F17` (ink 9%) | neutral clip badges on the sidebar glass, page and sunken |
| `status.warning` / `.warningBackground` | `#E3B25C` / `#2D2616` | `#8A5200` / `#FAF0DC` | warnings |
| `status.dangerForeground` / `.dangerBackground` | `#F2A196` / `#33201D` | `#B3261E` / `#FBECE9` | errors |
| `status.success` / `.successBackground` / `.infoBackground` | `#7CCB93` / `#1B2A20` / `#232428` | `#1E6E3A` / `#E7F2E9` / `#F0EFEA` | success and info callouts |
| `timeline.track` / `.kept` / `.playhead` | `#26272B` / `#7A7D85` / `#63BDB6` | `#E4E2DC` / `#74777E` / `#1C6B69` | strip |
| `timeline.keptBackground` / `.waveform` / `.scopeDim` | `#ECEAE417` / `#ECEAE494` / `#1415179E` | `#1A1B1F12` / `#1A1B1F85` / `#F0EFEAA8` | kept-speech bed, waveform bars, dim outside the selected clip |
| `overlay.foreground` | `#F5F4F0` | `#F5F4F0` | text over video |
| `stage` | `#000000` | `#000000` | video surround and caption-card backdrop |

Typography uses the system font: the transcript at 19/32 (SF Pro; Segoe UI Variable Text on Windows; zoom 13–28 with the line height at 32/19) and SF Mono / Cascadia Mono for timecodes, status labels and pause tokens. DM Sans and Geist Mono appear only in rendered video. Spacing is a 4-point grid with pane padding 16 on both platforms, a transcript gutter of 84 / 76 and a paragraph gap of 18 / 20 (macOS / Windows). Radii are 4 for badges, chips and the playing word, the aliases `control` 6, `pane` 10 and `sheet` 14, and 8, 12, 16 and capsule. Motion is 120 / 150 / 240 ms, ease-out `cubic-bezier(.23,1,.32,1)`, spring 0.32 / 0.82, instant under Reduce Motion. Fixed sizes include the sidebar (220–320, ideal 252; Windows 264), the right column (300–560, ideal 360 / 388), the timeline (72, with a 30 track), the selection bar (36 / 40), the largest 9:16 stage (180 × 320) and caption tiles at 0.45 of their width high.

---

## 17. Control mapping

| Concept | macOS (SwiftUI / AppKit, macOS 26) | Windows (WinUI 3) |
|---|---|---|
| Window | one app-owned `NSWindow` hosting `NavigationSplitView`; `NSDocument` per project attached to its controller | `MicaBackdrop` + `TitleBar` (pane toggle, Settings) + `NavigationView` |
| Sidebar | `List(selection:)`, `.listStyle(.sidebar)`, `Section`; footer actions as borderless `Button`s; `backgroundProminence` for focused rows | `NavigationViewItem`, `NavigationViewItemHeader`, `NavigationViewItemSeparator`, custom item content; actions with `SelectsOnInvoked="False"` |
| Title and summary | `.navigationTitle`, `.navigationSubtitle` | heading `TextBlock`s in the command row |
| Commands | `ToolbarItemGroup`, `ToolbarSpacer(.fixed)`, `visibilityPriority` (macOS 26.1+) | `CommandBar` (`DefaultLabelPosition="Right"`, dynamic overflow) |
| Primary action | `.buttonStyle(.glassProminent)` | `AccentButtonStyle` |
| Transcript | `NSTextView` (TextKit 2) in `NSViewRepresentable`; `NSTextLayoutFragment` decorations | `ItemsRepeater` of paragraph `RichTextBlock`s; Composition overlay; `InlineUIContainer` badges |
| Selection bar | custom overlay with `.glassEffect(.regular, in: .rect(cornerRadius: 10))` | restyled `CommandBarFlyout` |
| Columns | `NSSplitViewController` via `NSViewControllerRepresentable` (right item collapsible) | `Grid` + a focusable splitter (`CommunityToolkit.WinUI.Controls.Sizers` `GridSplitter`) |
| Viewer | `AVPlayerLayer` in an `NSView` + composition | `Image` + `WriteableBitmap` from the FFmpeg engine |
| Frame, Edited/Source | `Picker(.segmented)` | `CommunityToolkit.WinUI.Controls.Segmented` |
| Captions switch | `Toggle(.switch)` | `ToggleSwitch` |
| Fine Tune | `DisclosureGroup` | `Expander` |
| Gallery | `LazyVGrid` with a `Picker` accessibility representation | `GridView` over a grouped `CollectionViewSource` |
| Timeline | `Canvas` + `Slider` accessibility representation | `Canvas` shapes or Composition visuals with a `RangeValue` peer |
| Find Clips | `.popover` | `Flyout` |
| Rewrite takes | `List` with single selection | `ListView` (`SelectionMode="Single"`) |
| Status / errors | inline callout row | `InfoBar` |
| Home | `.dropDestination(for: URL.self)`, `.searchable(placement: .toolbar)`, `LazyVGrid(.adaptive)` | `AllowDrop`, `AutoSuggestBox`, `GridView` |
| Export | `.sheet` | `ContentDialog` |
| Settings | `Settings`-style window with `TabView`, `.formStyle(.grouped)` | Settings window + `NavigationView` + `SettingsCard` / `SettingsExpander` |
| Key field / storage | `SecureField` / Keychain | `PasswordBox` / DPAPI |
| Shortcuts | `.keyboardShortcut`, menus, `onKeyPress` | `KeyboardAccelerator` |
| Progress | `ProgressView` (fixed width) | fixed-width `ProgressBar` / `ProgressRing` |

Custom drawing is budgeted and pixel-tested on both platforms: the transcript decorations, the timeline, the trim handles and the selection bar.

---

## 18. Design skills

Searched on 2026-10-25 with `npx --yes skills find "<query>"` (queries: swiftui macos, liquid glass, winui, fluent design windows, macos app design, windows app sdk, apple human interface guidelines, appkit textkit, video editor ui) and read with `npx --yes skills use <pkg>@<skill>` (nothing installed by `use`). Licences were checked on GitHub before vendoring.

### 18.1 Installed project-locally (vendored in this repo)

Installed from the repo root with `npx --yes skills add <repo> --skill <name> -y` (no `-g`). Files live in `.agents/skills/<name>/` (the canonical copy, read by Codex, Cursor, Gemini CLI, OpenCode and other agents) with symlinks in `.claude/skills/<name>` for Claude Code. `skills-lock.json` at the repo root records source, path and content hash; restore with `npx skills experimental_install`, update with `npx skills update -p`. Licence texts and copyright lines are in `.agents/THIRD_PARTY_NOTICES.md`.

| Skill | Source (path in repo) | Upstream commit | Licence | Use it for |
|---|---|---|---|---|
| `swiftui-expert-skill` | `avdlee/swiftui-agent-skill` (`skills/swiftui-expert-skill`) | `204dba7c6725` | MIT | SwiftUI on macOS 26/27: scenes, Settings, `.inspector`, toolbars (`ToolbarSpacer`, `visibilityPriority`, overflow), Liquid Glass rules, document apps, AppKit interop, performance and Instruments traces |
| `macos-design-guidelines` | `ehmo/platform-design-skills` (`skills/macos`) | `dc2be825d8b4` | MIT | HIG rules as checkable items: full menu bar, shortcuts, resizable windows, dark mode, Reduce Transparency, accessibility, anti-patterns |
| `winui-app` | `openai/skills` (`skills/.curated/winui-app`) | `49f948faa925` | Apache-2.0 (LICENSE.txt in the skill folder) | WinUI 3 app structure, Mica / Acrylic, `TitleBar`, `CommandBar`, theming incl. High Contrast, accessibility, launch verification |
| `winui-design` | `microsoft/winappcli` (`plugins/winui/agent-plugin/skills/winui-design`, needs `--full-depth`) | `6564e7adba6d` | MIT | Official Microsoft WinUI 3 XAML guidance: control choice, app-shape anchors (media/canvas app: no `NavigationView`), window sizing, `x:Bind` pitfalls, brushes and theme checks. Uses WinApp CLI 0.7+ (`winapp find-ui`, `winapp find-api`) when available |

### 18.2 Evaluated, not vendored

| Skill | Why not vendored | Install locally if wanted (do not commit) |
|---|---|---|
| `petekp/agent-skills@macos-app-design` | No licence file and the repository is archived, so it cannot be redistributed in a public MIT repo. Useful for planning reviews (command map, undo model, Liquid Glass do/don't) | `npx skills add petekp/agent-skills --skill macos-app-design -g` |
| `dimillian/skills@swiftui-liquid-glass` | MIT, but overlaps `swiftui-expert-skill` | `npx skills add dimillian/skills --skill swiftui-liquid-glass` |
| `microsoft/winappcli@winui-code-review` | MIT, review-time only; add when WinUI code exists | `npx skills add microsoft/winappcli --skill winui-code-review --full-depth` |
| `dpearson2699/swift-ios-skills@ios-accessibility` | Licence "Other" (not verified as redistributable); iOS-centred | `npx skills add dpearson2699/swift-ios-skills --skill ios-accessibility -g` |
| `getopenscreen/openscreen@openscreen-design`, `kunchenguid/rough-cut-axi@rough-cut-design` | Brand-specific references; their rules (choice rows, named levels, free rows not cards, manuscript prose) are already folded into this spec | `npx skills use getopenscreen/openscreen@openscreen-design` (read only) |
| `affaan-m/ecc@liquid-glass-design`, `yetone/native-feel-skill`, local `frontend-design`, `design-taste-frontend`, `web-design-guidelines`, `mobile-ios-design` | iOS/web focus, or they push against system chrome and "not a fancy interface" | — |

Agents working on UI should load `swiftui-expert-skill` + `macos-design-guidelines` for macOS work and `winui-design` + `winui-app` for Windows work, and treat this spec as overriding any skill advice that conflicts with it (for example, skills that put the editor in a hero surface without a navigation pane: ADR-R29 chose a `NavigationView` shell so clips stay visible).
