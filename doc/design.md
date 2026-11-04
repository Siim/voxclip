# VoxClip design specification

### Inline wording fit (Mac, 2026-11-04)

Rewrite makes new voice phrases with the fixed label **Eleven v4 · audio tags**.
There is no new-phrase model picker. Previously saved takes retain their models.
All fit work stays in the existing right panel, with no new modal surfaces.

- Running: **Fitting wording to the video · round {r} of 3**, a thin progress
  bar and Stop. Each requested row says **Phrase {n} · ≈ {e} s, slot {s} s ·
  asking for about {k} more/fewer words**. Show **Uses {connector} on your plan;
  nothing is paid until Get Price.** Local connectors omit “on your plan”; an
  API-key connector states that fit requests are billed to its key.
- Send consent, when required: **Fit wording automatically · up to 3 requests
  · ≈ {send cost}**, with **Fit** and **Skip** inline. Unknown cost is explicit,
  never represented as free. This consent belongs to this reply only.
- Fitted: **reworded to fit · was ≈ {a} s, now ≈ {b} s · slot {s} s**.
  A structured keep decision says **kept your original words · {s} s is too
  short to re-voice**. The footer says **{n} phrases fit · {m} kept as recorded**
  with the existing Get Price action for included voice phrases.
- Still outside the slot: retain the existing recovery row. A short phrase
  now offers **Ask for longer**, alongside surrounding sentence, original
  words and the explicit price override. Stop retains the latest words.
- After a take: **Take {n} · {m} s · slot {s} s · too short/too long**, then
  **Reworded with the measured length: “…”**, the existing priced **Make Take**
  action and **Keep Take {n}**. A key-billed rewording shows its own one-request
  Fit/Skip consent. Preparing a new price never makes a take.

The proposal is visible but not editable during fit work. Ask again, a user
edit, changed inputs or close cancel remaining rounds. Buttons have keyboard
focus and accessibility labels. Feedback and consent copy wrap at narrow panel
widths; the headless right-column layout gate covers the surrounding panel.

### Inline voice expressions (Mac and Windows, 2026-11-03)

The speech model popup labels are **Eleven v3 · audio tags** and **Eleven v4 · audio
tags**. Review and voice rows wrap quoted words with small expression chips and a
remove control; transcript text and captions never include chips. Each phrase has
an inline **+ Expression** toggle revealing the shared whitelist. Selection appends
at the end of the rewritten words (before trailing unchanged bridge/context words
in a full take phrase), not at a caret. Removal preserves the remaining anchors.
Controls are keyboard buttons with VoiceOver / Narrator names such as “Add laughs
to phrase 1” and “Remove laughs from phrase 1”. No new sheet, alert, ContentDialog
or dialog-like flyout is used. Windows uses wrapping quoted-word/chip runs above
the take choices; chips have bounded widths, not a fixed-width horizontal row.

Under the rows: “Rewrite suggests tags where your original had a laugh, sigh or
pause. Tags aren't spoken words and don't count in the word check.” For v2:
“Multilingual v2 leaves tags out.” Suggestions remain available for every model;
other incapable models show that tags are left out. The fit-line shape stays
`≈ 4.6 s at natural pace · slot 5.4 s · fits`, including tag allowances. Measured
takes remain authoritative. Before payment, a tag edit retires the exact old quote
and prepares another without synthesis; after payment/in-flight it first uses the
existing inline discard confirmation, and cancelling changes nothing. The new
quote still requires its own explicit paid action. Narrow wrapping and native
VoiceOver / Narrator and listening acceptance require the usual real-window gate.

Status: normative for 0.1.0 (M1), with M2/M3 surfaces marked. Date: 2026-10-26.

This spec covers information architecture, the single-window layouts for macOS and Windows, the transcript editor, the viewer and timeline, the clip list, captions, Rewrite and Voice Lab in context, Home, export and share, onboarding, settings, keyboard shortcuts, states and their exact copy, materials, accessibility, the token system and the design skills used to build it. Tokens live in [`shared/design/tokens.json`](../shared/design/tokens.json); this document explains how to use them. Module placement and threading are in [architecture.md](architecture.md).

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
4. Make a clip. Select words. A small action bar appears beside the selection. Choose **Make Clip** (⌥⌘K / Ctrl+K). The new clip appears in the sidebar and is selected.
5. Find clips. Choose **Find Clips** (⇧⌘K / Ctrl+Shift+K) and pick a preset. The results appear in the sidebar under **Suggested**, each with Keep and Dismiss.
6. Shape a clip. Select its row. The transcript marks it, the viewer plays only that clip, and the timeline zooms to it. Choose a Frame (9:16) and a caption style.
7. Export. **Export Clip…** (⌘E / Ctrl+E) opens the Mac right-panel Export job with that clip already chosen. Windows opens its Export dialog.
8. Rewrite a clip. Select its row and choose **Rewrite** (⇧⌘R / Ctrl+R), with or without an instruction in the bar above the transcript. The proposed changes show in the transcript and in a panel that replaces Captions. Apply the cuts and fixes at once, or, with Voice Lab on, make your voice from the clip and use takes for the new phrases (§6.3). The new words show inline in the transcript with an AI marker.
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
- **The Rewrite diff** sat in the panel on both platforms. Superseded on 2026-10-31: the transcript shows the proposal as tracked changes and the panel lists them (§6.3).
- **Provider lines in Rewrite.** Each "Sends…" line sits under its own action.
- **The 9:16 stage** keeps its 180×320 cap on both platforms, and the gallery scrolls below it.
- **The Windows transcript selection** uses the grey `selection.transcript` wash (the colour macOS derives from the Ink accent) with `text.primary`, never the ink or paper of the playing word. A selected word and the playing word must not look the same.
- **The gallery check badge** is a white check on a 62% black disc on both platforms.

---

## 0. Design stance

1. **The transcript is the editor.** It gets the widest, tallest region and keyboard focus by default. Everything else supports it.
2. **One window, no modes** apart from recording (M2). The library, cutting, clips, captions, Voice Lab and export all happen in the main window. Clips are always visible in the sidebar; they are never behind a tab.
3. **System controls, system chrome, system fonts.**
   - **macOS 26 and later:** `NavigationSplitView` with a Liquid Glass sidebar and toolbar, sheets, popovers and menus.
   - **Windows 11:** Mica, `TitleBar`, `NavigationView`, `CommandBar`, `InfoBar`.
   - **Type:** SF Pro and SF Mono on macOS; Segoe UI Variable and Cascadia Mono on Windows. Bundled fonts appear only inside rendered video (captions and the AI MODIFIED label).
   - **Identity:** VoxConvo's identity shows through the paper-and-ink palette, whose accent is the ink itself, with the icon's coral as the only hue, kept for cuts, the 19/32 transcript page and the voice of the copy. There are no custom chrome materials, gradients or glows, and no card nested inside another card.
4. **Every primary action has a key** (Space, J/K/L, Delete, ⌥⌘K, ⌘E, ⌘Z). Single-letter keys work only when focus is not in a text field.
5. **A cut is instant.** The preview skips a new cut on the next frame. There is no "prepare preview" step.
6. **Local-first.** Import, on-device transcription, cutting, captions, export and manual clips work with no key, no account and no network.
7. **Say what leaves the machine.** Every provider action states what it sends, next to the control that sends it ("Sends transcript text only. No audio or video.").
8. **Nothing is lost.** Every error says the media and edits are still here.
9. **One accent, Ink, spent on state.** Ink marks what is active: the Export button, the playing word, the selected clip, the switch that is on, the playhead and focus. Clip identity is neutral: numbers, brackets and outlines. The only other hues are vermilion for cuts and recording and amber for fillers and warnings. On macOS a user-chosen system accent replaces Ink on standard controls (§14).
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
│  │  └─ actions (editor only): New Clip from Selection ⌥⌘K · Find Clips with AI ⇧⌘K
│  └─ Recent  (Home only: up to 12 recent projects, excluding the open one)
├─ Detail
│  ├─ Home: drop bar · AI callout (when useful) · Recent projects grid  (§7)
│  └─ Editor (Full take, a clip or a suggestion selected)
│     ├─ Toolbar (macOS) / command row (Windows): title + edit summary · Cut Fillers ·
│     │     Tighten Pauses · Restore Cuts · Find Clips · Export Video… / Export Clip… · viewer toggle
│     ├─ Scope bar (above the transcript): scope label · instruction field · Rewrite · AI picker  (§6.3.1)
│     ├─ Transcript page (centre) + selection bar: Make Clip · Cut · Restore · Rewrite
│     ├─ Right column: Viewer over Captions, Rewrite (§6.3.4), or the Mac Export job (§8)
│     └─ Timeline strip (bottom, under the centre and right columns)
├─ Transient: Find Clips popover/flyout · Import sheet (§7.1) · Windows Export dialog (§8) ·
│     Voice Lab consent and cost confirmations · Keyboard shortcuts
└─ Settings window (⌘, / Ctrl+,): General · Transcription · AI · Export · Accounts (M2) ·
      Voice Lab (M3 beta) · About
```

**Sidebar selection model.** Selection is one value: `SidebarItem = home | fullTake | clip(ClipRange.id)`. On macOS a Recent row is a fourth case, `recent(URL)`: the arrow keys and Return can select it, and it shows Home like the Home row.

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

**Window title.** The project title on macOS: `Project.title`, or the file name without its extension. "VoxClip" while Home is selected. Never "Untitled": an untitled imported project shows the video's file name until it is saved. A saved project's title follows Save As, Rename and Move while it is still the default: unset, the video's file name or the previous file name. On Windows the `TitleBar` title is always "VoxClip", and the project title is the command row heading (§3.3).

**Launch.** The main window opens on Home with no project. Windows still honours Settings → General → "Open last project on launch". A launch carrying a project or video opens it as above. On macOS, after a crash, force quit or power loss, a project that was never saved reopens from its autosave in the main window; saved projects don't reopen.

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
││ 3 ▯ And yeah, I mess…│   0:34.9   ┌[⌗ Make Clip ⌥⌘K][✂ Cut ⌫][↺ Restore ⇧⌫]│[≋ Rewrite… ⇧⌘R]┐ │ ─────────────────────────── │
││ 4 ▯ The best thirty… │   0:39.5   ▓I write five questions on a card, the kind▓…   │ Captions [chip] Box highlight Edited (●)│
││ ✦ Suggested Keep All │                                                             │          › Paper · As said · 3 words│
││ 5 ▯ One habit for…   │                                                             │ Word by word                 │
││     0:16      [✓] ✕  │                                                             │ [ tile ][ tile ]  (2 columns)│
││ + New Clip from Selection ⌥⌘K                                                       │ Phrase …                     │
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
  - The right item has `minimumThickness = 300`, `maximumThickness = 560`, `canCollapse = true` and `holdingPriority = .defaultLow + 1` (251). One above the transcript is enough for the transcript to give way first when the window resizes, while `.defaultHigh` would stop the divider from being dragged.
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

**macOS v2 Explorer.** The flat pane keeps a native plain `List` and its system selection highlight (the accepted deviation from the mockup's `selrow`). In the editor its sections are Take, Clips, Outline, Suggested, Voices and Exports. Voices is hidden entirely when Voice Lab is off, in every build. Each disclosure has an uppercase 11 pt semibold heading and a spoken name such as "Clips, 2 items". The take heading is the project title with no visible count; VoiceOver reads "{title}, 1 item". Clips and Suggested show counts, while Outline shows the open tab’s `scopeName` as trailing context when it fits. Expanded state persists under `ui.explorer.take`, `.clips`, `.outline`, `.suggested`, `.voices`, `.exports` and `.recent`; this never edits the project. Starting Find Clips or Hook, or focusing a suggestion, expands Suggested. Moving selection to a hidden clip row expands its owning Clips or Suggested section. Home shows Home and Recent.

**Voices and Exports (macOS V2b).** These sections stay at the Explorer bottom, collapsed by default, with counts and the same 28 pt uppercase disclosure headers. Expanded library rows are 40 pt per f14 and the V2b review decision (one-line navigation rows remain 28 pt); their two lines are a 13 pt title and 11 pt metadata, each truncated at the tail. Help and VoiceOver carry the complete text. A long expanded library scrolls within a bounded area. The section's VoiceOver group name is “Voices, {n} items” or “Exports, {n} items” (singular “1 item”).

Voices projects `voiceLabSession.visibleRecords` only while `voiceLab.enabled` is on. Each row has a person glyph, voice name, “made {date} from {source}”, and Ready or Needs attention (warning text for the latter, also spoken). Consent records identify video audio or a read-aloud, rather than retaining a project name. **Manage in Settings** opens Settings › Voice Lab; management stays there.

Exports projects the open project's ledger, newest first, one row per target and aspect, retaining the last successful output when a later attempt fails. A row has a 36×20 thumbnail from the exported file, “Clip {n} · {aspect}” (or Full Take), and “{m:ss} · {resolution} · {size} · {time}”. Only the duration uses SF Mono 11; resolution, size and wall-clock time use system 11 pt. Actual duration, dimensions and byte size are saved with new successful outputs. Older records remain readable; missing output facts display “—”. Failed attempts persist with their retry folder and appear even after reopening the app. Only Edited since export and Export failed show a trailing 11 pt `exclamationmark.triangle` in `status.warning`; Exported stays quiet. Clip rows have no export warning glyph. All states remain in help and VoiceOver. A 24 pt reveal button and **Show in Finder** / **Open** context actions use the exported file (disabled if unavailable). **Export again** opens the right-panel Export job with that row's target and aspect; failed rows also offer **Retry** with their saved folder. Neither action starts a render. Removed targets stay visible with their saved name, with export actions disabled. A running export retains its captured target.

A single click previews a clip or suggestion in the one temporary tab. Double-click keeps that tab open; selecting an already pinned tab leaves it pinned. Opening a Rewrite session from any entry point or marking a tab dirty also pins its preview immediately. Preview replacement preserves any remaining session or pending review work before opening the next clip. Return still keeps a suggestion or renames a kept clip, and Delete dismisses or removes it. The Outline uses the take's `TranscriptParagraphs`, filtered by overlap with the open tab, with take time in mono `m:ss` and the first six words. A click scrolls through the transcript's scope-scroll path without moving scope, playhead or word selection. A green dot means pending changes (wired when V14 and V2 are both merged); a blue dot means enabled AI speech in that paragraph. Both states are spoken. Outline Return/Delete do not rename or remove the open clip; ⇧⌘↩ still keeps its suggestion.

**Windows order:**

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
| Nav row (Home, Recent items) | 28 high; Recent thumbnails 36×20 | 40 high; Recent thumbnails 32×18, two lines (title, then "2:36 · Today" in 12 `text.secondary`) |
| Project header | disclosure, 11/600 uppercase `text.tertiary`, count trailing; project title in the take heading tooltip | `NavigationViewItemHeader`: title 14/20 semibold over the file name, 12 `text.secondary` |
| Full take row | 28 high; 36×20 landscape thumbnail, "Full Take" 13, edited duration in SF Mono 11; progress and Cancel while transcribing | 44 high; 32×18 thumbnail; "Full take" 14; meta |
| Clip row | 28 high; plain 10 pt mono number, 36×20 thumbnail; title 13, one line truncated at the tail; SF Mono 11 edited duration. Selection, pointer hover or row keyboard focus replaces the duration with two trailing 22×20 borderless icon buttons: **✦** Rewrite and **⋯** More. The blue AI-voice waveform stays | v2 kept row: at least 32 high (52 with export detail), including while idle so the controls do not shift row heights; 24×24 thumbnail with a 16×16 numbered badge; title 14, truncated at the tail; meta 12. Selection or pointer-over replaces the duration with two trailing 32×32 subtle icon buttons: **✦** Rewrite and **⋯** More |
| Selection | native plain `List` selection; system focused/unfocused fill and readable selected text; no badge capsule; thumbnail gets a 1 px white 55% ring | native `NavigationView` pill (Ink through the accent override: ink in light, paper in dark) with the subtle selected fill |
| Suggested sub-header | uppercase disclosure and count, with borderless **Keep All** on the right | `NavigationViewItemHeader` "Suggested", or "Suggested (N)" from 2 up, with a **Keep all** `HyperlinkButton` on the right |
| Suggestion row | 28 high, with a dashed range bar; Keep and Dismiss in the clip bar, context menu and accessibility actions; Return/⌫ retained | as a clip row; two trailing 32×32 subtle icon buttons ✓ and ✕ (tooltips "Keep (Ctrl+Enter)" and "Dismiss (Delete)"). Their `Tapped` handler sets `e.Handled = true` |
| Actions | borderless `Button`s in the section footer (not rows, never selectable, never arrow-key stops): 28 high, label 13, glyph `text.secondary`, key hint SF Mono 11 `text.secondary`. Disabled: label and glyph `text.tertiary` at 55% | `NavigationViewItem`s with `SelectsOnInvoked="False"`, the shortcut as trailing 12 `text.secondary` text, `IsEnabled` bound |

**Kept clip row actions.** **✦** runs the row menu's **Rewrite Clip {n}** action on that clip, not an existing word selection, and pins its tab. It appears only when that clip can be rewritten; text Rewrite needs no Voice Lab. Its help is "Rewrite Clip {n} (⇧⌘R)" on macOS and "Rewrite Clip {n} (Ctrl+R)" on Windows. **⋯** is named "More" and opens the same menu definition as right-click, with the same items and enabled states. On macOS these are Rewrite Clip {n}, Export Clip…, Retry export when failed, Rename…, Copy Text and Remove Clip. Windows retains its existing Export clip…, Rename…, Copy text and Remove clip items and adds the same Rewrite Clip {n} entry. Windows buttons use the suggestion buttons' `Tapped` handling (`e.Handled = true`) so opening More never selects the row. Both platforms keep the buttons out of the List's keyboard tab order. The macOS row stays one combined accessibility element, with named **Rewrite Clip {n}** (when available) and **Export Clip** actions alongside Rename, Remove and Retry export. Windows UIA button names are "Rewrite Clip {n}" and "More". Suggested rows gain no Rewrite or More buttons: their existing Keep/Dismiss design stays unchanged.

**Windows meta line grammar.** On macOS v2 the idle row shows duration, with AI speech as a blue waveform glyph. Export warnings live in the EXPORTS rows (§7), with the same status in help and VoiceOver. Clip rows show no export glyph.

The duration, a separator, then one status:

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

**Rewrite on a row** (§6.3). On macOS v2 the kept row's context menu offers **Rewrite Clip {n}**, shown while the clip keeps a word. It opens the clip's tab, lets go of the word selection and runs Rewrite on the clip with the scope bar's field text (§6.3.6 "Start"); the clip's tab is pinned so the session cannot disappear on the next preview. The hover-button rules below describe Windows.

- The selected kept clip's row shows a **Rewrite** button after its meta line. Other kept rows, suggestion rows and Full take show it while the pointer is over them. No row shows it while a task is open. Its target is at least 24 pt (§15), and its accessible name is "Rewrite clip {n}" ("Rewrite full take" on Full take).
- Clicking it selects the row if needed, then runs Rewrite with the scope bar's field text, or with Fix mistakes when the field is empty.
- On a suggestion row, Rewrite first keeps the clip, as its own undo step (Keep, §2), and announces "Clip {n} kept".
- A kept clip's context menu starts with **Rewrite Clip {n}** (⇧⌘R) and a separator (§6.2).
- After an accepted rewrite with voice changes, the meta reads "{m:ss} · AI modified" (the AI modified status above). After cuts and fixes only, the meta is unchanged.
- Windows: a hover `Button` in the `SidebarItems` template, and the `ContextFlyout` item "Rewrite clip {n}".

**Windows badges.** macOS v2 uses a plain number, with no capsule.

- **Neutral, the default:** 16×16 (macOS) or 16×16 overlaid (Windows). Radius 4. Numeral in SF Mono 11/600 or Cascadia Mono 11/600, `text.secondary`, on `clip.badgeBackground`.
- **Selected clip:** the accent fill (macOS `Color.accentColor`; Windows `AccentFillColorDefaultBrush`) with `accent.on` or `TextOnAccentFillColorPrimaryBrush`.
- **Suggestion:** a 1 px dashed `line.strong` outline with a `text.secondary` numeral.
- **Full take scope:** every badge is neutral.

**Thumbnails.**

- A clip shows the first kept frame of the clip (the start of its first uncut word), centre-cropped to 36×20 on macOS and 9:16 on Windows. The full take shows the first kept frame of the edited video at its own aspect.
- Thumbnails are generated off the main thread and cached by `(media contentKey, source time rounded to 0.1 s, pixel size)`. They regenerate when the clip's first kept word changes.
- Border: a 1 px `line.default` hairline, radius 3 on macOS and 4 on Windows.
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

**v2 Mac status bar (V11a, 2026-11-01).** The v2 shell carries this information in a full-width, 24 pt row on `bg.statusBar`, with a `line.default` hairline above it. This replaces the Mac subtitle and toolbar summary described below. Items use 11 pt system text; only durations use SF Mono. The bar has 8 pt outer padding, 7 pt item padding, 2 pt between items and 6 pt between a dot or icon and its text.

- Leading: the chosen AI's dot, short name and model; its billing only after detection has run in this app session; then the running task. Before detection the dot is a neutral ring and there is no billing claim. A CLI detected on its plan reads "No extra cost on your plan", a local AI "No extra cost", and an API-key AI "Billed to your key". Rendering the bar never starts detection.
- Running work reads the Director task's own headline and start time, or "Finding clips… 0:12" for Hook and Find Clips. Transcription retains its progress text. A spinner accompanies running work unless Reduce Motion is on.
- Trailing: "Clip 1 · 0:43 · 8 cuts · 5 changes to review", "16:9 · 1080p30", then the export state. Full Take names itself. Cuts retain the counting rule below. The review count appears only when Rewrite supplies proposal data for this tab, excluding items already left out; V14/V15 will supply the pending-hunk lifecycle. The summary's tooltip and accessibility help retain `summaryDetail`.
- Frame opens the same choices as View › Frame (9:16, 1:1, 16:9, Original), checks the current aspect and changes it through `setAspect` as one undo step. It only reads in a Versions window or while media is unavailable. The resolution and frame rate describe the export output; audio-only projects show the aspect alone.
- The row is one VoiceOver group, "Status", with named items and spoken values; billing belongs to the AI's value. Home has no status items. At narrow widths the bar drops billing, Frame, export, AI and task in that order, retaining the summary and truncating it last. F6 still reaches the status group.

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
4. **Export Video…** or **Export Clip…** (⌘E), with a painted capsule and `.visibilityPriority(.high)` on macOS 26.1 or later. Light uses `accent.default` with `accent.on`; dark uses `accent.text` with `word.playingForeground`, matching the Windows `AccentButtonStyle` pair. This is the only prominent control. Disabled with the tooltip "Keep at least one word before exporting." when `!canExport`. With a suggestion selected it is disabled with "Keep this clip to export it."
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
  - **⋯** with: Rewrite {scope} (Ctrl+R; "Rewrite selection", "Rewrite clip {n}" or "Rewrite full take", with "…" when the send asks first; §6.3), Make clip (Ctrl+K), Show cut words (Ctrl+Shift+H), Show pauses, Find (Ctrl+F), Undo (Ctrl+Z), Redo (Ctrl+Y), Save project as…, Show project file, Transcribe again…, Keyboard shortcuts (F1).
- **Export** is a separate `AccentButtonStyle` button outside the `CommandBar`: 40 high, padding 0,16, radius 6. It reads "Export video…" or "Export clip…" (Ctrl+E). Its accessible name adds ", contains AI-modified speech" when the scope does. It is disabled with the tooltip "Keep at least one word before exporting." when nothing can be exported, and with "Keep this clip to export it." when a suggestion is selected.

### 3.6 Right column

From the top:

1. **The viewer** (§5.1): the stage, the viewer bar and the Frame row.
2. **A hairline.**
3. **Captions** (§6.1), which fills the rest of the column and scrolls. While a task is open, the Rewrite panel (§6.3.4) replaces Captions, and Captions return when it closes.

The column background is the page (`bg.surface` on Windows). On macOS it is the window background behind the split, with no card and no inset. Pane padding is 16.

**Fit.** The column lays its content out at exactly its own width, anywhere from 300 to 560. Nothing in it may run past the column or the window edge, and nothing is clipped to make it fit. A row that doesn't fit switches to its stacked form: the viewer bar and the Frame row (§5.1), the Captions header and the Fine Tune rows (§6.1), and the Rewrite panel's rows (§6.3.4). The switch is chosen from the content's measured width, not from a fixed breakpoint.

### 3.7 Narrow widths

| Width | macOS | Windows |
|---|---|---|
| ≥ 1440 | Sidebar, transcript measure 680, right column 360 | Pane, measure 680, right column 388 |
| 1280 (default) | measure about 580, right column 320. The Captions header wraps to two rows when one row doesn't fit (§6.1), and the Frame row stacks (§5.1) | measure 560, right column 348 |
| Transcript pane would drop below 596 (macOS) or 588 (Windows), about 1150 window width | The right column collapses first. "Show Viewer" (⌥⌘I) and View > Show Viewer bring it back; showing it at this width hides the sidebar to make room. The timeline gains the compact transport (§5.3). Below a window width of 1100 the toolbar capsule is icon-only (§3.5) | The right column collapses first. The Viewer toggle brings it back, and showing it hides the pane (`IsPaneOpen = false`). The timeline gains the compact transport. `CommandBar` overflow takes Tighten pauses and Restore cuts |
| < 960 | Only reachable in full screen or Split View. The sidebar collapses (`columnVisibility = .detailOnly`); the toolbar sidebar button brings it back as an overlay | `NavigationView` goes `LeftMinimal`; the `TitleBar` pane toggle opens it as an overlay |

The sidebar collapses last, because it holds the clips. While the viewer is collapsed, caption styling is unavailable until Show Viewer. Opening the Mac Export job reveals the right panel and its caption style picker. The Windows Export dialog also offers caption style.

---

## 4. The transcript editor (primary surface)

### 4.1 Rendering

- **Flowing prose, not chips.** A new paragraph starts after a sentence end followed by a pause of ≥ 1.5 s, or at a speaker change when diarization exists.
- **Gutter.**
  - It shows the paragraph start as a timecode in `m:ss.d`, or `h:mm:ss.d` past one hour, in SF Mono 11 or Cascadia Mono 12, `text.tertiary` (5.23:1 light, 4.56:1 dark). Timecodes are right-aligned.
  - Each clip's rule is 2 wide, running from the clip's first line to its last.
  - Speaker labels sit under the timecode.
  - **macOS:** gutter 84; timecodes end 30 before the text; the rule sits 14 before the text.
  - **Windows v2:** an 80-epx gutter holds the 2-epx clip rule at x 8, take-time `m:ss` (or `h:mm:ss`) ending at x 42, the line's one kind glyph at x 49–63 and its 3-epx pending-change bar at x 66. The text starts at x 80, with 44 epx of right padding. Paragraphs use the shared display-only split in editing §11.5, independently of clip scope.
- **Type and measure.** The transcript is SF Pro or Segoe UI Variable Text, 19/32, with an 18 (macOS) or 20 (Windows) paragraph gap.
  - Zoom runs 13–28 with ⌘+/⌘−/⌘0 (Ctrl+=/Ctrl+−/Ctrl+0), and the line height scales at 32/19.
  - The measure is `min(680, pane − gutter − 32)` on macOS and `min(680, pane − 108)` on Windows, with a floor of 480. That gives 680 at 1440, about 580 at 1280, and 640 at 1024 with the viewer collapsed.
- **Never one view per word.**
  - **macOS:** one non-editable, selectable `NSTextView` using TextKit 2 (`NSTextLayoutManager`), wrapped in `NSViewRepresentable`. Keep a sorted map word index ↔ character range (binary search both ways). Word colours are applied as rendering attributes (no relayout). TextKit 2 does not draw strikethrough or underline from rendering attributes, so a custom `NSTextLayoutFragment` (via `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)`) draws them: the cut strike under Show cuts, the low-confidence underline and the fold dots, each fold a zero-ink kerned span. The selection (`tint.selection`, at text height) and the playhead caret are layers above the page; the platform selection does not draw. A test checks the decorations by pixels on an offscreen render, not by reading attributes back. Selection snaps to whole words in `textView(_:willChangeSelectionFromCharacterRanges:toCharacterRanges:)`. A cut, restore or correction rewrites only the affected paragraphs' text storage; zoom and Show cuts rewrite it once. TextKit 2 lays out only the viewport, so hour-long takes stay smooth.
  - **Windows v2:** retain the virtualised `ItemsRepeater`/`StackLayout` inside one `ScrollViewer`, with one `RichTextBlock` per take paragraph. The body is Segoe UI Variable 16/26 by default, with a 14-epx paragraph gap; saved text-size preferences and zoom remain effective. Source words and display-only proposals are `Run`s, never one control per word. Native selection stays off. A paragraph-local native `TextPointer` span table distinguishes source ranges, display-only text and attachment gaps; inserted words never acquire source IDs or fall back to the preceding word when hit-tested. Selection foreground is set on the source run, including HighlightText in High Contrast, rather than by per-word `TextHighlighter`s. Correction uses a `TextBox` in the paragraph's inline row, not a popup; IME composition owns its confirmation keys.

    One cached Composition overlay per paragraph draws the open clip's line band, gutter range rule, grey removal strike, text-height selection tint, pending-insertion tint, change bars and 2-epx playhead caret. Playback does not restyle the playing word or override selection. Width/zoom/text changes invalidate geometry; frame updates visit only realised paragraphs. Fold dots are sparse 13-epx `InlineUIContainer`s, glued to the preceding word with U+2060 and followed by a break opportunity. Clicking expands only that fold; its inline Restore action restores word and pause IDs in one existing history step. Show cuts reveals grey struck words and unstruck mono pause lengths. Outside-clip text has no fold, pause or proposal markers. The old badges, brackets, AI chips, cut-count tokens, pause chips, playing pill and correction popup are replaced. Native offscreen pixel, frame-budget and bounds acceptance must use this v2 grammar without relaxing the retained probes' limits.
- Right-to-left scripts use natural writing direction, and the gutter moves to the trailing edge.

Word states (each shown by more than colour):

| State | Treatment |
|---|---|
| Normal | `text.primary` |
| Playing | V2 uses a 2-epx playhead caret and no playing-word fill or foreground override. Windows draws it from cached native glyph geometry, including the preceding word's end during a source pause. A simultaneous selection retains its own fill and native High Contrast foreground |
| Selected | A `tint.selection` layer at text height (ascender to descender), radius 2; the platform selection does not draw. Windows uses `text.primary` over the 16% accent tint, and Highlight/HighlightText in native High Contrast, including selected cut or accepted AI words. Playback never overrides the selection |
| Cut | In the open clip each run of removals folds to one 5-epx `fold.dot` in a 13-epx gap glued to the preceding word; a paragraph's leading fold has no preceding word. A filler-only comma folds with it ("include • source"). Show cuts and local expansion show `word.gone` words with a 1-epx grey strike; pauses and the folded comma stay unstruck. Windows expands only the clicked fold and exposes Restore in the same paragraph flow, as one history step. Selected cut words remain visible even when their paragraph is newly realised. Outside-clip words read as said |
| Pause (detected gap), uncut | When Show Pauses is enabled, use an unfilled mono `1.8 s` duration with a nonbreaking space; Windows maps the 11-pt label to 12 epx. No `‖` marker. The project's `pauseThresholdSeconds` remains unchanged (editing spec: 0.8 s with decoded audio, else 1.0 s, set at import) |
| Pause, cut | Part of its fold; when expanded, an unstruck mono duration in `word.gone`, without a chip (4.54:1 dark, 4.97:1 light on `editor.band`) |
| Suggested filler | No inline underline in v2; Cut Fillers and the existing accessible actions still find them. Windows retains the "Filler · Delete to cut" tooltip |
| Low confidence (if the engine reports it) | dashed underline `word.lowConfidence`; off by default (Settings → General) |
| Corrected | normal text with a 2 pt dot under the first letter (`word.correctionDot`); tooltip "Heard as: {original}" |
| Clip start | macOS: an inline badge before the clip's first word (§3.4 badge rules) and the gutter rule. Neutral unless the clip is selected; selected: an accent badge and an `accent.text` rule. Suggestions: a dashed badge and a dashed rule. Windows: The open clip's line band and 2-epx gutter rule; a suggested clip's rule is dashed. No inline badge |
| Clip end | macOS: a `]` bracket glyph after the last word, `line.strong`, or `accent.text` when selected (dashed for suggestions). Windows: The last covered line ends the band/rule; no `]` text marker |
| Rewrite passage (Voice Lab open) | macOS: an `accent.soft` fill and a 1 px `accent.text` outline, radius 4 Windows: Pending inline changes and per-line change bars (§6.3.5); no outlined passage box |
| AI words (accepted) | macOS: an "AI" chip at the start (§6.3) and a 1 px dashed `accent.text` underline. Description adds ", AI modified" Windows: AI tint plus the line's waveform glyph, without a chip or underline. While changes are pending, only the glyph remains outside the hunks. Selection and High Contrast keep native text colours |
| Outside the selected clip | macOS: hidden by default in kept and suggested clip scopes. **Show surrounding context**, beside Show cuts, restores the outside words in `text.secondary` (6.92:1 dark, 6.56:1 light), **no opacity**. Cut words there keep their outside-context treatment; timecodes stay `text.tertiary`; other clips stay neutral. Windows: `word.outside` (4.87:1 dark, 5.23:1 light on `bg.surface`), without folding, strikes, pauses or change markers; gutter timecodes use the outside brush. No opacity reduction |

Rewrite (§6.3) adds tracked changes to the transcript; §6.3.5 fixes their treatment and original review ordinals. Windows uses the same v2 grammar on its existing native paragraph architecture. The shell consumes the transcript callbacks before the complete Rewrite flow is accepted; native validation remains a separate gate.

Live transcript while recording (M2): partial words in `text.muted` italic; a "Jump to live ↓" pill appears when the user scrolls up.

### 4.2 Interaction

| Gesture | Result |
|---|---|
| Click a word | Caret and selection on that word. When paused, the playhead moves to the word's start so the frame updates |
| Drag / ⇧-click / ⇧← → | Extend the selection by whole words. macOS (v2): a selection across a fold holds the words and pauses the fold removed, so ⇧⌫ restores them, and a fold opens while the selection starts or ends in it (after a cut, or when an arrow key or Find Next lands there) |
| Double-click a word | **Correct** in place: an inline field sized to the word, text selected. Return saves, Esc cancels, Tab saves and opens the correction field on the next word. Correcting changes caption text only; the audio stays the same |
| Triple-click | Select the sentence |
| ⌫ / Delete on a selection | **Cut.** If the whole selection is already cut, **restore** it (toggle, like VoxConvo's tap to cut, tap again to restore) |
| ⇧⌫ / Shift+Backspace | Restore the selection |
| ⌥-click / Alt-click | Play from that word |
| Right-click | Context menu: Rewrite (⇧⌘R) · Type New Words… · Make Clip (⌥⌘K) · Cut · Restore · Correct Spelling… · Play from Here · Preview This Cut (P) · Copy Text. With a caret between words and Voice Lab on: Insert Words… (§6.3.6) |
| Drop a file on the window | The whole-window overlay (§7). With a project open, it is saved first, then the new video opens in its place |

On both platforms, an inline correction ends when focus leaves its field, on a click elsewhere, when the selection changes, and before any transport action. Save valid typed text on the word the field opened for; drop empty text, text containing a line break, or text beyond the project's correction limit, keeping the word unchanged. Esc cancels. Return and Tab with an unsavable draft keep the field open with its text, on both platforms. Return with valid text saves and closes; Tab with valid text saves and opens the next word's correction field, or closes at the last word. Play/Pause uses the playing state before saving: Space or Pause during playback saves and stays paused, including when the save refreshes the preview.

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
| Items | **Make Clip** ⌥⌘K (default, highlighted with the neutral fill of an unfocused sidebar selection) · **Cut** ⌫ · **Restore** ⇧⌫ · divider · **Rewrite** ⇧⌘R. Labels 13 with SF Mono 11 key hints in `text.secondary` | **Make clip** (labelled) · **Cut** and **Restore** (icon only, tooltips "Cut (Delete)" and "Restore (Shift+Backspace)") · separator · **Rewrite** (labelled, Ctrl+R). The flyout is restyled so the two primary commands keep their labels |

Rewrite shows whenever the editor allows AI actions (`capabilities.ai`, the same gate as Find Clips), with Voice Lab on or off; it rewrites the selection (§6.3). Restore is disabled when nothing in the selection is cut. When the selection already equals a clip, Make Clip's tooltip reads "Clip 2 already covers these words", and choosing it selects that clip (§6.2).

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

**Materials.** Under Reduce Transparency or Increase Contrast (macOS), and with Transparency effects off or a contrast theme (Windows), the bar is opaque `bg.elevated` with a 1 px `line.strong` edge (3.31:1 dark, 3.41:1 light on the transcript).

**Motion.** It appears with a crossfade of 150 ms or less and no scale or slide. Under Reduce Motion it appears without animating.

---

## 5. Viewer, transport and timeline

### 5.1 Viewer

**macOS v2 transport.** With the timeline hidden, the viewer's hover/focus transport uses `TimelineReadout` in its compact SF Mono style: current / length, for example `0:12 / 0:43`. Edited shows the open scope's output playhead and duration; Source follows the timeline's take time and source duration. The timeline toolbar keeps its SMPTE readout. At narrow widths the speed yields before the time and axis switch.

**Stage.**

- Black (`stage`), radius 10. On macOS it is concentric with the column (`.rect(corners: .concentric)`, with 10 as the design value).
- It sits at the top of the right column with 16 padding. On macOS it starts at y 62.
- Content: the edited result of the current scope. A new cut shows on the next frame (architecture.md §5 and §6).
- **Frames:**
  - 16:9 and Original-landscape fill the column's inner width: 328×184 at 360, 288×162 at 320, and 355×200 on Windows at 388.
  - 9:16 and 1:1 are centred, at most 320 high and never wider than the inner width (180×320 for 9:16). A 9:16 or 1:1 frame is a centre crop of the source with no pillar bars, as in export.
  - On macOS the stage keeps these sizes while the column is at least the stage height plus 320 (every frame at 1280×800 and larger). That 320 holds everything below the stage: the viewer bar, the Frame row, their spacing and padding, the hairline and the Captions panel. In a shorter column only the stage height yields, keeping its aspect and centring, so the area below it keeps that budget.
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
  - When the row doesn't fit (the AI modified tag, a rate and long times together), the AI modified tag and then the rate ("1.5×", 11 `text.secondary`) move to a caption line 6 above the row. The row keeps the time and the three buttons at their sizes. The time is never truncated or scaled, and the rate stays out of the accessibility tree as before.
- **Windows**, row 1 is 40 high:
  - leading: Back 3 seconds (32 subtle icon button, name "Back 3 seconds (J)"), Play (40 round, `ControlFillColorDefaultBrush` fill, 1 px `ControlStrokeColorDefaultBrush`, ink glyph), Forward 3 seconds (32, name "Forward 3 seconds");
  - trailing: the AI modified tag (12, 1 px `accent.text`, 16.34:1 light, 14.01:1 dark), then the time in Cascadia Mono 13.
- **Frame row:** 24 high on macOS, 32 on Windows. The label "Frame" (13 or 14 `text.secondary`) leads.
  - The control: macOS `Picker(.segmented)` with `.labelsHidden()`; Windows `CommunityToolkit.WinUI.Controls.Segmented`.
  - When the row doesn't fit, macOS first uses the small control size in the same 24-high row, then puts "Frame" on its own line, 6 above a small picker at the leading edge. Inline rows also start at the leading inner edge. At 1280 (column 320) it stacks; at 360 the small control fits in one row. No label is truncated or dropped.
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
| Clip scope | macOS: hide outside media by default in Source and show only the active clip in the overview. The shared **Show surrounding context** toggle restores the whole-take overview and outside Source media; Edited remains the existing clip output. Full Take stays full. Reset context off when entering a different kept or suggested clip; reselecting the same scope or trimming it keeps the current choice. The toggle is independent of Show cuts and changes no project, Undo, source timing, playback plan or export scope. Windows retains its clip zoom and outside dimming with `timeline.scopeDim` until the preference is ported |
| Trim handles (clip scope) | 7×36 in `accent.text` at the clip edges, with invisible 24-wide hit regions. Dragging snaps to word boundaries and applies `updateClip` (one undo step, "Trim clip") |
| Interaction | Click or drag anywhere on the 30 px track to scrub. ⇧-drag snaps to word starts. The hover tooltip names the word under the pointer ("cadence · 0:12.4"). Double-clicking a cut region restores it |

No other zoom in v1. Full take always fits.

**Accessibility.**

- The strip is one slider (macOS: `Canvas` with `.accessibilityRepresentation { Slider }`; Windows: a `RangeValue` automation peer). Its name is "Playhead", and its value reads like "22 seconds of 2 minutes 10 after cuts, 8 cuts". ← and → step by one word, ⇧← and ⇧→ by one sentence, Home and End go to the ends.
- Escape during a mouse trim cancels its preview without an edit or undo step. The trim handles are separate adjustable elements, "Clip 2 start" and "Clip 2 end", that step by one word.
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
- **No plates at sidebar sizes.** At 18 px high, a boxed word reads as a tag control. The boxed key word takes the box colour as its text colour if its WCAG 2.x contrast against the card backdrop colour (stage black, or the dark preview or plate colour at the centre of its vignette, §5.4.3 Backdrop) is at least 4.5:1; otherwise mix the box colour once 45% toward white in sRGB (`c′ = c + (255 − c) × 0.45` per channel, rounded half-up), so Paper `#F3F0E7` stays unchanged and Box highlight `#7C3AED` becomes `#B793F5`. The box colour's alpha is ignored: the key word is drawn opaque, because translucent text at this size is unreadable. Pill text becomes white.

#### 5.4.4 States

States, per surface. Copy is exact.

| State | Home tile | Sidebar 32×18 / 36×20 | Clip row 27×48 / 26×46 | Stage | Caption previews |
|---|---|---|---|---|---|
| **a · normal** | the first kept frame, with the duration chip (§7) | frame | frame | video | the frame band dimmed 35% (unchanged) |
| **b · loading** | the loading ladder (§5.4.5) | the ladder | the ladder | the caption at the playhead over black at once; a 20 px ring after 500 ms | stage black until the band exists |
| **c · video missing** | card and the **missing chip**; meta "⚠ Video not found." **Locate…** | card; Windows meta "⚠ Video not found", macOS trailing "⚠ Not found" | card (in the editor the InfoBar carries the state; rows don't repeat it) | the caption at its real place over black, still draggable; centred glyph, **"Video not found"** and the file name in mono; transport disabled | samples over the card backdrop, not dimmed |
| **c · never transcribed** | stage black and the missing chip | stage black | n/a (no clips without words) | the glyph, "Video not found" and the file name only | as c |
| **d · transcribing** | frame, the **"Transcribing · 42%"** chip and a 2 px progress line; meta "Transcribing on this {Mac/PC}" **Cancel** | frame and the 2 px line; meta "Transcribing · 42%" **Cancel** | none (clips need words) | the video plays, with no captions | the frame band; each style's own `preview.text` (captions spec §15.3) |
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
- the stage message cluster (§5.4.6) sits on the same plate, radius 4 and padded 12 by 8 on Windows, and its file name drops the 66% opacity;
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
- **Rewrite**, and the Voice Lab steps inside it, open in context: the scope bar above the transcript and the Rewrite panel in the right column (§6.3).
- **M2 AI commands** live in the toolbar and the menus (§6.4).

### 6.1 Captions (right column)

**Header.** It has two forms.

- **One row, 36 high**, used on macOS when the heading, chip, full style name and summary, and switch fit on one line (about 340 and wider for a short summary):
  - "Captions" 13/600;
  - a 64×36 live chip of the current style on the current frame, or the one-line caption card when there is no frame (§5.4.3);
  - the style name, 13/600, followed by "Edited" in 11 `text.secondary` when overrides exist;
  - under the name, the Fine Tune disclosure label "› {summary}" in 11 `text.secondary`;
  - on the trailing side, a regular switch (38×22).
- **Two rows**, used on macOS when one row doesn't fit, and always on Windows:
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

On macOS each segmented control's label leads it on one line; when they don't fit, the label moves 6 above the control. The hint and caption errors wrap rather than truncate.

There is no separate Fine Tune row and no "Off" tile.

The gallery scrolls inside the column and clips at its own viewport, which always ends above the column's bottom padding, so every style can be scrolled into view at any window height. The Captions header and caption errors stay fixed; Fine Tune scrolls with the gallery. Neither automatic reveal nor manual scrolling may hide a caption error. On macOS the small, fixed catalogue uses eager two-column rows, so every row is laid out before a selection is revealed.

**Gallery.**

- **Control:** macOS eager two-tile `HStack` rows in a `VStack`, with `Button`s and `.accessibilityRepresentation` as a `Picker` named "Caption style". Windows `GridView` with `SelectionMode="Single"` over a grouped `CollectionViewSource`.
- **Layout:** two columns with an 8 gap. Tile width is (inner width − 8) / 2; tile height is round(width × 0.45). That gives 160×72 at a 360 column, 140×63 at 320 and 173×78 at 388. Radius 10. The name sits under the tile with a 4 gap, and rows are 10 apart.
- **Groups**, each with a section header (11/600 `text.secondary`), from the style's tags. A style goes to the first group it matches; within a group, styles sort by `order`:

  | Group | Tag | Styles |
  |---|---|---|
  | Word by word | `one-word` | Bold, Highlight, Bold+, One word |
  | Phrase | `phrase` | Karaoke, Pop, Box highlight, Bounce, Two-tone, Outline, Pill, Gradient, Neon, Emoji, VHS |
  | Sentence | `sentence` | Subtitle, Lower third, Typewriter, Editorial |

  A style with none of these tags goes into an "Other" group at the end. A test asserts that the bundled styles produce no "Other" group.
- **Tile content.** Each tile renders the real style with the export renderer: the current phrase at the playhead, with that style's word count and casing (captions spec §15.3; fallback: the style's `preview.text`). It is drawn over the band of the current frame behind the style's caption position, dimmed 35%. With no frame, samples sit on the card backdrop (§5.4.3), not dimmed. A tile that cannot render draws exactly the backdrop it would have had: the band of the current frame dimmed 35%, or the card backdrop (design.md section 5.4.3) when there is no frame, and stage black in the loading states (design.md section 5.4.4). It never draws text. In clip scope the playhead is inside the clip. The selected tile is drawn with the active overrides.
- **Selected tile:** a 2 px `accent.text` outline at offset 2, a check badge (a white check on a 62% black disc, 18, top-right, inset 6), and the name "Box highlight · Edited" in 600 `text.primary`. Other names are 11 (macOS) or 12 (Windows) `text.secondary`.
- **Scrolling.** The grid scrolls the selected tile into view when the scope changes, including while Fine Tune is expanded. An external style change, Undo, or closing Fine Tune also reveals it. Clicking a visible tile never moves the gallery. Resizing alone never resumes a reveal interrupted by user scrolling. The scroll view ends 16 above the strip (the pane padding) with a 24 (macOS) or 12 (Windows) fade to the column background.
- **Accessibility.** Options are named "{name}: {description}" ("Box highlight: a box behind the spoken word, a few words at a time").
- **Motion.** Under Reduce Motion, tiles are static; animated styles show their resting frame.
- Captions follow edited time, and phrase grouping does not break at cut seams (captions spec D9). Under Reduce Motion the preview shows animated styles without animation; export keeps them.

### 6.2 Clips (sidebar)

The sidebar list is the clip range layer (editing §2.5 and §10.6), presented as in §2 and §3.4.

**Making a clip.**

- **Ways in:** the selection bar's Make Clip, ⌥⌘K or Ctrl+K, the transcript context menu, the sidebar's New Clip from Selection, and Clip > Make Clip from Selection.
- **Result:** one `addClip` undo step ("Make clip from selection"). The title is the first seven words of the selection, which the user can rename.
- **After making it:** the new row is selected and scrolled into view. The transcript keeps its scroll position and the selection. The timeline zooms to the clip. Announce "Clip 3 made".
- **When the selection already equals a clip:** select that row and announce "Clip 2 already covers these words".
- **With no words selected,** the command is disabled.

**Row actions.**

- **Kept clip context menu** (macOS `.contextMenu`, Windows `ContextFlyout`):
  - Rewrite Clip {n} (⇧⌘R; §6.3), then a separator;
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
  - the footnote "Sends transcript text with word numbers. No audio or video." For loopback local connectors it reads "Runs on this {Mac/PC}. Nothing leaves it."; for a configured remote local-server connector it reads "Sends these {count} words to {host}.";
  - **[Find Clips]** as the default button.
- **Consent.** The first cloud use runs the existing consent alert (ai.md §4.8). A send on an API key, or on a CLI signed in with one, then asks on every send; every other send starts at once (ai.md §4.8).
- **While it runs:** the popover closes. The sidebar shows a "Finding clips…" row under the Suggested header, with a spinner (Windows: a fixed-width `ProgressRing`), **Cancel**, and the connector line "{connector} · reading {duration} of transcript" in 11 `text.secondary`. On macOS, Clip > Cancel Finding Clips (⌘.) and Esc in the sidebar also cancel; cancelling is silent.
- **Results:** the new suggestions appear under Suggested and the first is focused (not selected). Announce "Found 3 clips".
- **No connector:** the popover is replaced by an inline callout under the sidebar actions. Copy is in §13, with **Set Up AI…** and the line "You can also select words and press ⌥⌘K to make a clip yourself."
- **Failures** show in the same place with **Retry** (§13).

**Export ledger** (app-local, not in the project).

- **Location:** `<app data>/exports.json`, keyed by project id and target ("full" or a clip id). macOS also keys it by aspect, so a row shows the status for the project's current Frame. Windows keeps one record per target.
- **Record:** `{exportedAt, planFingerprint, styleId, aspect, outputPath}`, written after each successful export. macOS V2b adds optional `targetName`, `durationSeconds`, `width`, `height`, `byteSize`, `failed` and `retryFolder`; failures (including cancellation) also replace the latest attempt. Old successful records still decode.
- **Fingerprint:** `planFingerprint` is a SHA-256 over the render inputs both platforms share (`apps/windows/CONTRACTS.md`): the source's content key, duration, oriented size, rotation, frame rate, sample rate and channels; the scoped edit plan; quality and the resolved output encoding; the effective caption style and, when captions are on, the scoped caption words (including their timings), language, overrides and position for the aspect; and the Voice Lab output plan, disclosure and selected assets. SRT intent, titles, share text, the folder, word confidence, speakers, project bookkeeping timestamps and recipe provenance are left out.
- **Statuses:**
  - **Exported:** a successful record exists and its `planFingerprint` matches the current one.
  - **Edited since export:** a successful record exists and the fingerprints differ.
  - **Exporting:** taken from the live export queue.
  - **Export failed:** the live failed attempt, or on macOS a persisted failed ledger entry. Windows keeps its live-queue status.
- Clearing app data removes the statuses, never the project.

### 6.3 Rewrite (clip-first) and your voice

0.1.0 ships text Rewrite. Voice Lab is a beta behind its setting: Mac can create your voice, re-voice rewritten words and change the voice of a passage or full take; Windows re-voice is not available until voice creation is. Lip sync is later (M3+).

The 0.1.0 entry points are **Rewrite…** on selections and in the Edit menu (the Windows editor's ⋯ menu), and **Create Your Voice…** in Settings → Voice Lab and Rewrite. Windows marks voice creation unavailable at both entry points. **Insert Words…** is also later (M3+). Unsupported video choices stay disabled and cannot be accepted or exported. Settings shows only ElevenLabs keys and monthly caps; the stored fal.ai/sync.so keys and caps remain intact for M3+.

The clip-first interface below is planned work specified on 2026-10-31. It does not expand the 0.1.0 release scope above. It replaces the passage Rewrite panel and the separate Create Your Voice sheet as its packages land; each package records its step in `apps/macos/CONTRACTS.md` or `apps/windows/CONTRACTS.md`. This section sets behaviour, copy, keys and accessibility for that interface. The sizes, type, colours and drawing of the scope bar, the panel, the transcript marks and the timeline marks come with the visual redesign, which is merged separately. Until then §3, §4.1 and §5.2 keep today's metrics and marks.

**The clip is the unit of work.** Rewrite acts on a *scope*: a kept clip, a suggested clip, Full take, or a word selection. The selected sidebar row sets the scope (§2), and a word selection inside it narrows it. No text selection is needed.

- **One composer per scope.** The scope bar (§6.3.1) holds the scope's name, one instruction field, one verb (**Rewrite**) and the AI picker. An empty field means the default task, Fix mistakes. A kept sidebar row repeats **Rewrite** as **✦**, beside **⋯** More, while selected or hovered (also while keyboard-focused on macOS), replacing its duration (§3.4). Suggested rows retain Keep and Dismiss instead.
- **One result surface.** While a task is open, the Rewrite panel replaces Captions in the right column (§3.6). Captions return when it closes. The panel only shows work and results.
- **The text change is the hero.** The result shows as tracked changes in the transcript and as a checklist in the panel, with the same ordinals. Each change can be edited before anything is paid for.
- **The voice comes from the clip.** When a change needs a voice and none exists, the panel continues into "Make your voice from this clip" (§6.3.7). There is no separate sheet and no Settings detour. Settings → Voice Lab only manages voices.
- **One primary action per state.** Each state has a headline, at most one note, at most one secondary link and exactly one primary button. A control that cannot act is not shown. A hint appears once. The send line sits next to the button that sends. AI MODIFIED is stated once, at Use.
- **Free work is not beta.** Cuts and text fixes from Rewrite need no voice and work with Voice Lab off. Only phrases in your voice, making your voice and takes carry the Beta tag and need Voice Lab (voice-lab.md §5).
- **No outlines in the transcript.** A clip, a selection and a proposed change are never drawn as boxes.

**Vocabulary.**

- **AI**: the selected connector (`llm.connector`) and its model. Names are plain text, never logos (ai.md §7.1 rule 6). Menus keep "Claude Code (installed CLI)" and "Codex (installed CLI)"; the bar and the panel use the short name.
- **Change kinds** (voice-lab.md §8.2 classes): *cut* (`cut`, free); *fix* (`textOnly`, text only and free); *voice* (`voice`: it needs your voice and takes, so it is paid).
- **Proposal**: the result before anything changes the project, a `ChangeSet` of `ProposalItem`s (§6.5).

**Scope words.** The copy in this section is written for a clip. The other scopes substitute their own words:

| Scope | Title and undo name | "clip {n}" in a sentence | "the {w} words of clip {n}" | "this clip" |
|---|---|---|---|---|
| Kept or suggested clip | "Rewrite clip {n}" | clip {n} | the {w} words of clip {n} | this clip |
| Full take | "Rewrite full take" | the full take | the {w} words of this video | this video |
| Selection | "Rewrite {w} words" | these words | these {w} words | this clip when the selection lies in a clip, otherwise this video |

The V1 speech row and its strip (§6.3.7) are the exception. They describe where the training speech came from, so they name the clip that set `preferRange` (voice-lab.md §6.5.2): for a selection, the clip that contains it. Full take, and a selection outside every clip, have no `preferRange` and use the row's "From this video." variant.

`{AI}` is the AI's short name, `{CLI}` is "Claude Code" or "Codex", `{provider}` is the API-key provider's name and `{host}` is a remote local server's host. `{Mac/PC}` is "Mac" on macOS and "PC" on Windows, as in §13.

#### 6.3.1 Scope bar

A row pinned above the transcript. It replaces nothing: the toolbar keeps its commands.

| Part | Content |
|---|---|
| Label | Kept clip: its badge (§3.4), "Clip {n}" and its edited length `{m:ss}`. Suggested clip: its badge and "Suggested clip {n}". Full take: "Full take" and `{m:ss}`. Selection: "Selection" and "{w} words" |
| Field | Placeholders: a clip "What should change in clip {n}?" (a suggested clip the same); Full take "What should change in this video?"; a selection "What should change in these words?". Return runs Rewrite. A trailing chevron opens the suggestions |
| Verb | **Rewrite** (⇧⌘R / Ctrl+R). With an API-key connector, or a CLI signed in with an API key, it reads **Rewrite…**, because that send asks first (voice-lab.md §3.1) |
| AI picker | A status dot, the AI's short name ("Claude Code", "Codex", "Ollama", "LM Studio", "Apple on-device", "Anthropic", "OpenAI"…) and a chevron. The dot has three states: ready; asks before each send; unavailable (signed out or not running). The accessible name carries the state in words (§15). With no connector set, it reads "Choose AI" |

**Suggestions.** They appear when the field is focused and empty, or from its chevron. Choosing one fills the field and does not send.

| Suggestion | Instruction sent |
|---|---|
| Fix mistakes (the default for an empty field) | "Fix slips and repeats. Keep my words and my voice; change as little as possible." |
| Make it clearer | "Make it clearer. Keep my words where they work; change as little as possible." |
| Make it shorter | "Make it shorter, mostly by cutting. Keep my words and my voice." |
| Fix grammar and punctuation only | "Fix grammar, punctuation and capitals only. Don't add or change words unless a word is wrong." |
| Recent: "{text}" | The project's last three distinct instructions, most recent first. They are app-local state, never written to the project file |

The instruction is bound into the quote like any instruction (`PatchRewriteRequest.instruction`, at most 1,000 UTF-8 bytes; voice-lab.md §8.1).

**States.**

- *Idle*: as above.
- *Running*: the field is read-only and shows what was asked. The verb is replaced by a spinner and "Rewriting…", which is status, not a button. An indeterminate progress line runs along the bar, static under Reduce Motion. Stop lives in the panel.
- *Failed* (macOS): the open Rewrite stays available, the verb reads **Rewrite failed** with a warning triangle (also in the narrow icon-only bar), and its accessible label and tooltip name the failure and **Try Again**. The Ask field becomes editable again. The status bar keeps a short warning such as "Rewrite stopped: couldn't reach Claude Code" until retry, replacement or dismissal; clicking it, or pressing it with VoiceOver, opens the session's tab and selects the Rewrite job, showing the right column if hidden.
- *Proposal open*: the field keeps the asked text and stays editable. **Rewrite** sends again and replaces the proposal. When any change was edited, or takes exist, it first asks "Discard these {c} changes?" with **Keep Working** (the default) and **Discard Changes**, inline in the Rewrite job's footer rather than in an alert (Mac; the job comes to the panel to ask and the keyboard moves to Keep Working, wherever it was, with its focus ring and the question as its VoiceOver hint; Return, Space and Esc keep working, and Discard Changes takes a click or VoiceOver; once answered, the keyboard goes back where the question found it, such as the transcript or the Ask field).
- *Another AI run holds the lease* (Find Clips, AI tighten; ai.md §4.7): the verb is replaced by the status "Finding clips…" or "Tightening…".
- *Untranscribed project, or no editable scope*: the bar is hidden.

Narrow-width rules for the bar come with the visual redesign (§3.7).

**Windows.** A `Grid` row in `EditorPage.xaml`:

- the label is a `TextBlock`;
- the field is an `AutoSuggestBox` with `QueryIcon` hidden, its suggestions in `ItemsSource`, and `QuerySubmitted` running Rewrite;
- the verb is a `Button` with `AccentButtonStyle`, with Ctrl+R in its tooltip;
- the picker is a `DropDownButton` with a `MenuFlyout` of `RadioMenuFlyoutItem`s, `MenuFlyoutSeparator`s, and group headers as disabled `MenuFlyoutItem`s.

#### 6.3.2 AI picker menu

Each entry shows its billing on the trailing side. Choosing an entry writes `llm.connector`, the same value Settings → AI shows (ai.md §10.1). It also changes the AI for Find Clips and Tighten with AI, so the menu's header reads "Used for Rewrite, Find Clips and Tighten with AI."

```text
Installed apps · your own sign-in
  ✓ Claude Code (installed CLI)          {model} · no extra cost      (API-key sign-in: "{model} · billed to its API key")
    Codex (installed CLI)                {model} · no extra cost      (signed out: "Not signed in")
On this {Mac/PC}
    Ollama                               {model} · free               (not running: "Not running")
    Apple on-device                      free · English               (macOS only)
Your API key
    Anthropic                            asks before each send        (no key: "Add Key…")
    OpenAI                               Add Key…
─────
    Model                                {model} ▸
    AI Settings…                         ⌘, / Ctrl+,
```

- A remote local server, one that is not loopback (ai.md §8.2), shows "on {host} · free".
- Detection runs only when the menu opens (ai.md §7.1 rule 5).
- Choosing a signed-out CLI, a stopped local server or a key-less provider selects it. The next Rewrite then shows the fix inline in the panel (R1x).

#### 6.3.3 Sidebar

The sidebar's Rewrite button, its hover rule and the row menus are in §3.4 and §6.2.

#### 6.3.4 Rewrite panel

The panel replaces Captions in the right column while a task is open, and Captions return when it closes (§3.6). If the right column is collapsed, opening a task shows it, as Show Viewer does.

From the top:

1. **Header.**
   - The title: "Rewrite clip {n}", "Rewrite {w} words" or "Rewrite full take". In voice steps, a back button named "Back to rewrite" and the title "Your voice" instead.
   - A "Beta" tag, only in voice steps, on takes, and in any state that shows voice rows while Voice Lab is on.
   - In voice steps only, the step counter "Step {i} of 3" ("Step {i} of 4" when a read-aloud is needed).
   - A close button named "Close Rewrite" (Esc).
2. **Context line.** The AI's short name, " · {model}", then " · {state}". The state is one of:
   - "no extra cost": a CLI signed in on a plan, a local server (loopback or remote), or Apple on-device;
   - "billed to your key": an API key, or a CLI signed in with an API key;
   - "answered in {t} s", after a reply.

   The line is read-only; the picker lives in the bar.
3. **Headline**, with an optional sub-line. Every state has one.
4. **Body**: the state's content.
5. **Footer**, pinned: at most one note, at most one secondary link, and exactly one primary button (the default button; §11.2 says when plain Return runs it). The note sits above the button row, with the link at the leading end and the primary at the trailing end.

Rules:

- No disabled buttons.
- Spinner rows keep a fixed width.
- The body scrolls; the footer never scrolls.
- Rows wrap rather than truncate. The exception is a change row's second line, which may truncate and carries its full text as its accessible description.
- The panel is built on the Director task model (§6.5): a `DirectorTask` with `ActivityStep`s, a `ChangeSet` of `ProposalItem`s, and `PanelCard`s for the steps that need the user. Rewrite has no view model of its own.

Windows: `Controls/DirectorPanel.cs`, hosted by `RightColumn` and built from `Grid`, `InfoBar`, `ListView`, `ProgressRing` and `ProgressBar`. The primary is a `Button` with `AccentButtonStyle`.

#### 6.3.5 The proposal in the transcript

The transcript shows a proposal as tracked changes. The panel's change list and the transcript use the same ordinal for each change ("Change 1 of 6"), so they can be matched without sight. The transcript must show, each by more than colour:

| State | What it shows |
|---|---|
| Proposed change | The removed words, marked as removed. Words already cut inside the change are shown as removed too: they are silent in the result either way. The new words follow them as display-only text. Re-voiced neighbours (bridges) are marked as re-voiced. Pause tokens inside keep their own mark |
| Focused change | A mark beside the change's lines, a shape and not only a tint |
| Excluded change (its row unchecked) | The original words. The change's slot keeps a mark, so it can still be focused and included again |
| Voiced, not yet used (takes exist) | The new words only, marked as voiced |
| AI words (accepted) | Unchanged from §4.1 |

The treatments of these states, and of the selected clip and a selection, come with the visual redesign. Their contrast pairs join `tools/design/contrast.mjs` then, and every text pair keeps at least 4.5:1 (§15).

macOS (v2) draws them as a code diff. New words read in `text.primary` on `change.add` at 19 %, at the text's height with radius 2; removed words keep their place in `word.gone` with a 1 pt strike, as under Show cuts; words a change keeps (bridges) stay plain, and words already cut inside it fold like any cut. A 3 pt `change.add` bar at x 66 runs beside every line a pending change touches, at 100 % for the focused change and 50 % for the others; the line's glyph column shows the change's kind (waveform for voice, pencil for a fix, scissors for a cut, in `text.tertiary`), above the AI voice waveform. The focused change shows **Keep ⌘↩** and **Undo ⌘⌫**, 20 pt buttons over a blank the text keeps after its last word, or after the next word or two when they end its clause. An excluded change shows its original words with a dotted `text.tertiary` underline. A fix that only moves punctuation is not drawn; Keep All still applies it. While changes wait for review, AI words outside them lose their marker and underline and keep the gutter glyph. Pending changes are also marks on the overview ruler. **Keep** on a cut or fix applies it as one undo step, "Keep change {i}", whose undo also takes the change back to waiting, or to left out; on a voice change it includes it for takes, with no project change. A kept change is gone like a commit: restoring or correcting its words later never brings it back, and Keep All never applies it again. **Undo** leaves the change out (unchecked in the list) with no project change and no undo step. **Keep All** keeps every change still waiting: the cuts and fixes as one undo step named for the scope ("Rewrite clip {n}"), whose undo also takes the voice changes back to waiting. That undo acts only on its own proposal: after a new Rewrite it undoes the project alone. After Keep or Undo the focus moves to the next waiting change. The proposal belongs to its tab and shows only while that tab is open. VoiceOver reaches Keep, Undo and Edit through the transcript's custom actions and the **Proposed changes** rotor; the buttons themselves are not elements.

**Inserted words** are display-only runs that map to no word ID.

- macOS: an inserted-range table beside the word-to-character map, rebuilt per affected paragraph.
- Windows: extra `Run`s with no word ID.

Selection snapping skips them. Hit-testing an inserted run focuses its change.

**Change editor.** Click a change, or press Return on a focused change or change row. On Windows, F2 opens the paragraph's existing inline correction row. The 1 November 2026 inline-action decision supersedes the older Windows popup wording; it does not create a new editor window or popup.

- Windows places it under the affected paragraph, in the transcript's scroll flow. The shell owns the proposal's Keep, Undo, rediff/fit/cost and history operations; the transcript publishes ordinal-based callbacks and renders the returned real review snapshot. No rendering callback authorizes a provider request or synthesis.
- Content:
  - a label, "New words for change {i}";
  - a field prefilled with the new words;
  - the fit meter line (voice-lab.md §8.9.1): "about {s} s for a {g} s gap: fits", or "about {s} s for a {g} s gap: will change length";
  - "Return saves · Esc cancels";
  - **Reject Change**.
- Saving reruns the local diff, the fit meter and the cost; nothing is sent. Emptying the field turns a voice change into a cut.

**Timeline.** Proposed voice windows and accepted AI spans are marked on the timeline strip. Their marks come with the visual redesign (§5.2).

#### 6.3.6 Rewrite flow

**Pre-pay phrase fit (3 November 2026, approved f12 grammar).** Every voice-change row adds a
muted mono duration line: `≈ {estimate} s · slot {slot} s`, then `· fits` only when at least
one video-duration option would be usable. A blocked row has a warning bar and the line
“Too long for its slot. A take won't fit the video.” Below it, inline **Ask for shorter**
and **Keep original words**; the quiet **Price it anyway** text action overrides only that
phrase's estimate. No dialog, provider call, or audio charge happens on an override.
If wording instead falls below the same gate's minimum usable length, say “Too short
for its slot. A take won't fit the video.” and offer **Use surrounding sentence** rather than asking
for fewer words. That footer reads “{n} phrase(s) need(s) wording that fits.”

**Natural pacing (3 November 2026, ADR-R38).** Before pricing, prefer 1.00× speech.
Automatic pace stays on the 0.01 grid in 0.90×–1.10× and moves only for an exact
Keep-source fit. Grow natural generated pauses within the speaker's measured limits,
then offer a safe source-video jump cut; never slow a phrase just to fill its slot.
The muted line reads `≈ 3.1 s · slot 3.9 s · fits` or
`≈ 3.1 s · slot 4.9 s · fits with a video cut`. Only non-default pace adds
`at 1.05× pace`. The complete phrase input and
fresh paid approval bind that pace, and the inline send/price disclosure repeats it.
For dialogue/v4, only 1.0× is supported. If pace cannot fit, the same too-long/too-short
wording recovery applies. Use surrounding sentence reviews the whole replacement and
source range inline, preserving excluded changes and paid takes; it does not approve a
charge. A changed-duration take's **Try another** repeats natural-first exact-fit matching from
its measured pre-fit trimmed length and the selected take's receipt pace, not the original
text estimate. A fresh quote and priced click are still required, including after another
retry quote or a speech-model change.

Duration choices are inline rows, with none preselected for each passage and take:

- **Keep source video duration** — “Adds {s} s of natural pauses in your room's sound. Speech keeps its pace.” Keep the existing verified-fit copy when no pauses are added; disable with the actual reason if natural pause capacity is insufficient.
- **Cut the video to this take** — “Removes {s} s of video at a pause, like a vlog jump cut. Speech keeps its pace.” Show only for a verified safe cut; the rest of the source window gets a 1.06× punch-in after the first jump.
- **Match video to this take's duration** — retain the retime factor and 1.12× crop disclosure. Acceptance prepares the actual composition for both changed-duration routes.

If no eligible boundary pair exists, the cut planner's reason is “No pair of quiet source boundaries can make this video cut clear of the window edges.” Quiet endpoints may surround source speech because the take replaces that audio; each stays in a wordless quiet run of at least 40 ms. Cut uses the take as spoken, without growing pauses to reduce the removed video.

Take detail reads `Take 1 · 3.1 s · 0.8 s shorter · natural pace 1.00×`.
Keep ADR-R36 footer blockers. Windows reports that video cuts cannot render yet,
preserving the saved audio, cut spans and edits without silently retiming them.

The footer counts unresolved included phrases: “1 phrase needs a shorter wording.” or
“{n} phrases need a shorter wording.” **Get Price · {k} phrase(s)** prices only included
phrases that fit or were explicitly overridden; hide the priced action at zero. When all
included phrases fit, the footer reads “Nothing paid yet.” The existing audio-price
approval remains a separate, explicitly priced click.

**Ask for shorter** sends a new text Rewrite of this scope with the shared feedback block
and fresh connector consent/approval checks. Its reply replaces the proposal, resetting
overrides as Ask again does. **Keep original words** excludes the existing change. After
payment, a selected take whose two video-duration choices are disabled also shows both
recovery actions. A new first take is **Make take · ≈ $x**, never **Try another**. Paid
audio remains retained under the normal discard confirmation; no recovery action buys
another take implicitly.

"Announce" means an accessibility announcement: macOS `.announcementRequested`, Windows `RaiseNotificationEvent`.

**Start.**

| Trigger | Result |
|---|---|
| **Rewrite** in the scope bar, Return in its field, ⇧⌘R / Ctrl+R, the sidebar row's **Rewrite**, or "Rewrite Clip {n}" in a menu | Runs Rewrite on the current scope with the field's text, or Fix mistakes when it is empty. The panel opens in R1 |
| The selection bar's **Rewrite** (⇧⌘R / Ctrl+R) or the transcript context menu's Rewrite | The same, with the selection as the scope |
| **Type New Words…** (transcript context menu, a selection) | Opens the edit popover over the selection with its words. No AI. Saving opens the panel in R2 with one change |
| **Insert Words…** (a caret between words, Voice Lab on) | The same as Type New Words, with an empty field anchored at the caret. Hidden until Core can place an insertion (§13) |

- The connector consent (ai.md §4.8) appears before the first send per connector, worded for Rewrite. It is unchanged.
- A send on an API key, or on a CLI signed in with an API key, asks every time (R0b). Every other send starts at once (voice-lab.md §3.1).
- On Mac, a Rewrite on another scope keeps the open session until the new one opens. If the selection, the project or the AI choice changed while Rewrite got ready, nothing opens and nothing is sent, the open session stays, and the status bar says why until the next press: "Rewrite didn't start because the selection changed. Nothing was sent. Press Rewrite again." (or "…the project changed…", "…the AI choice changed…"); VoiceOver hears the same sentence. A close or a send of the open session in that moment says nothing.
- On Mac, opening and accepting a Rewrite use the same scoped input projection. Autosave or Save As (timestamp, writer, title and relative media path), tab choice, Motion/Demo commits, schema/extensions and Voice Lab asset catalogs do not refuse or discard unchanged text. The source transcript/media, pause settings, replacement segments and scoped cuts/corrections/clip bounds remain inputs; a selection also includes the pauses immediately before and after it. Edits outside the scope can finish while the request is in flight. An unavailable stale-connector retry closes the old session and says "Rewrite isn't available right now. Nothing was sent." instead of silently doing nothing.

**R0. No AI chosen** (`llm.connector` is unset)

- Headline: "Who should rewrite clip {n}?"
- A radio list of the connectors detected now, each with a status line:
  - "Claude Code (installed CLI)": "Signed in · Claude plan · no extra cost", or "Signed in · billed to the API key Claude Code uses", or "Not signed in. Run `claude` in Terminal and sign in."
  - "Codex (installed CLI)": "Signed in · ChatGPT plan · no extra cost", or "Not signed in. Run `codex login` in Terminal."
  - "Ollama": "{model} on this {Mac/PC} · free", or, on macOS v2, "Ollama isn't answering at {url}. Start it, then choose Check Again."
  - "Apple on-device" (macOS): "free · English"
  - "Anthropic": "your API key · asks before each send". With no key, a secure field "Paste your Anthropic API key" and **Save Key** appear under the row.
- Note: "Change it any time from the menu above the transcript."
- Link: **Check Again**, which runs detection again. Primary: **Use {name}**.
- With nothing detected: headline "No AI is set up yet". Body: "Rewrite needs an AI: an installed Claude Code or Codex, a local model, Apple on-device, or an API key." Link **AI Settings…**. Primary: **Check Again**.

**R0b. A send that asks first** (an API-key connector, or a CLI signed in with an API key; every send)

- On Mac v2, an inline approval row sits in the slot below the clip bar and pushes the transcript down (v5 f22–f22c). The right panel stays as it was until Send.
- Line 1: “Rewrite sends the {w} words of clip {n} to {provider} with your key.” A CLI on an API key names the CLI and says it is billed to the API key it is signed in with.
- Detail: “No audio or video. {model}. Asks before each send.” Note: “VoxClip can't tell what this costs. Check {provider}'s pricing.” The provider's pricing is linked; no price is invented.
- **Send** (accent), **Cancel**. On first use, one row combines the connector consent and the send: **Allow and Send**, **Not now**. A plan's first-use **Allow and Rewrite** stays neutral (ai.md §4.8).
- A missing key is entered and saved inline; saving makes no request and reveals Send. Return ignores repeat, a keydown before the row, and the first 0.5 s after opening or rewording. ⌘Return sends; Esc cancels and preserves the Ask text. Space plays. A billed button never receives focus automatically.
- Failures after Send appear in the Rewrite job's steps. **Try Again…** reopens this row; a rejected key offers an inline key field and **Save Key and Try Again…**. The Director thread job stays hidden until P1-09.
- Windows retains its native R0b confirmation until its v2 port.

**R1. Running**

- On macOS, a failed proposal keeps the Rewrite job with its existing R1x copy and recovery actions, including **Open Local Network Settings** and **Try Again** for an unreachable CLI. It selects Rewrite automatically only from Rewrite or Captions (including the default job); Voice, Context Demo, Motion, Export and other selected jobs remain untouched. A failure must never discard a recording, cancel a demonstration or clear a cue draft. The status item navigates back to Rewrite on an explicit user press, with the usual leave-job behavior. A connector returning cancellation without a user Stop is a failure: "The rewrite stopped before a reply was received. Try Again. Your edits are saved." Error reporting is bound to the still-open run's revision, including after asynchronous error formatting, not to whether its project or connector snapshot still matches. Try Again and the failed clip-bar action reopen with the current AI/model when the old connector is stale, using a fresh quote and consent route. The clip bar shows failure copy, glyph and accessibility state only for its current Rewrite scope; another scope has its normal new-Rewrite action. Declining consent retains the existing silent restore/close behavior. Successful replies compare the scope's actual inputs, not save timestamps, writer versions, relative media paths or the active tab. A successful reply that no longer fits an open run shows R3 instead of silently closing or restoring an older result. Explicit **Stop** still closes the session silently; a late reply or failure cannot reopen it or replace a newer Rewrite.

- Header "Rewrite clip {n}". Context line "{AI} · {model} · no extra cost" (or "· billed to your key").
- A quote line: "Asked: **Fix mistakes**, fix slips and repeats, keep my words, change as little as possible." For a typed instruction: "Asked: “{instruction}”".
- Headline: a spinner, "Rewriting clip {n}…", the elapsed `m:ss`, then **Stop**.
- Steps, each done, running or waiting, with a detail under each:
  1. "Read clip {n}" · "{w} words · {m:ss}"
  2. "Sent to {AI}" · "Text only. No audio or video." On a loopback local server or Apple: "Running on this {Mac/PC}" · "Nothing leaves it."
  3. "Waiting for {AI}…" · "Changes appear in the transcript when it answers."
  4. "Check that each change fits"
- Footer note by connector:
  - a CLI with a plan: "Sends the {w} words of clip {n} to {CLI} with your sign-in. Counts toward your {Claude plan | ChatGPT plan}."
  - a CLI with an API key: "Sends the {w} words of clip {n} to {CLI}, billed to the API key it is signed in with."
  - an API key: "Sends the {w} words of clip {n} to {provider} with your key."
  - a loopback local server or Apple: "Runs on this {Mac/PC}. Nothing leaves it."
  - a remote local server: "Sends the {w} words of clip {n} to {host}."
- **Stop**, ⌘. or Esc (Windows: Stop or Esc) cancels without changing anything and closes the panel. Cancelling is silent.
- Announce "Rewriting clip {n}" at the start.

The current connectors return one answer, so nothing streams: R1 waits until the reply arrives.

**R1x. Errors.** Headline "Couldn't rewrite clip {n}".

- Body: the `LLMError` user message (ai.md §5), then "Your edits are saved." Primary: **Try Again**, or **Try Again…** when the send asks first.
- Fixes that replace the body:
  - Signed out: "{CLI} isn't signed in. Run `claude` (or `codex login`) in Terminal and sign in, then choose Try Again."
  - CLI server unreachable: “{CLI} couldn't reach its server from VoxClip.” On Mac, a second line says “If it uses a server on your network, allow VoxClip in System Settings › Privacy & Security › Local Network, then try again.” Show the redacted first-line detail as secondary text, with **Open Local Network Settings** inline beside the existing **Try Again**. On Windows, continue with “Check your network or proxy, then try again.” and keep retry, without a settings action. AI spec §6.8 owns classification and timeout rules.
  - No key: a secure field "{provider} API key" with **Save Key and Try Again**.
  - Not running on macOS v2: "{server} isn't answering at {url}. Start it, then choose Try Again." The URL is the address attempted by the connector (Ollama or LM Studio). The clip bar and harness picker retain that same address; no send or edit occurs. Windows retains "Ollama isn't running. Start it, then choose Try Again." (LM Studio likewise.)
- Refused: "The model declined to rewrite this recording." Primary: **Ask for Something Else**, which focuses the field.
- Too large (voice-lab.md §8.1): headline "{Full take | Clip {n}} is too long to rewrite at once". Primary on Full take: **Find Clips**; otherwise none, and the close button closes. The body names the limit that was reached:
  - more than 3,000 entries: "Rewrite works on up to 3,000 words at a time. This {video | clip} has {n}. Choose a clip or select a passage.";
  - more than 20,000 bytes of text in 3,000 entries or fewer: "This {video | clip} has more text than Rewrite can send at once. Choose a clip or select a passage." No count is shown, because the word count is within its limit.

**R2. Proposal**

- Context line "{AI} · {model} · answered in {t} s".
- Headline "{c} changes" ("1 change"). Sub-line "{x} cuts · {y} fixes · {z} phrases in your voice". Zero parts are left out, and singulars are used where needed.
- The change list, in transcript order, one row per change. A row has a checkbox (checked means included), a kind glyph (waveform, pencil or scissors) and two lines:

  | Kind | Line 1 | Line 2 |
  |---|---|---|
  | voice | "“{new words}”" | "Your voice · replaces “{removed words}”"; an insertion reads "Your voice · new words" |
  | fix | "{Commas \| Spelling \| Capitals \| Punctuation} in “{text}”" | "Fix · text only, free" |
  | cut | "Cut “{removed words}”" | "Cut · free" |
  | voice, `checkThis` | as voice | "Check this: it adds something you didn't say.", as a warning with a warning glyph |
  | voice, refused by placement | as voice; no checkbox; excluded | The refusal copy (§13). Too close to a take edge reads "Too close to the {start/end} of the take to blend in. Re-record this sentence instead." |
  | voice, colliding with the change before it | as voice; no checkbox; excluded | "Too close to the change before it to voice separately. Edit them together or leave one out." |
  | voice, Voice Lab off or language uncalibrated | as voice; no checkbox; excluded | "Needs Voice Lab (beta)", or "Your voice works in English projects only for now.", as a warning |

- Unchecking a row restores the original words in the transcript (§6.3.5). Checking it applies the change again.
- Meta line: "AI voice: {v} of {limit} words · about {s} s", with "Takes ≈ ${x}" on the trailing side when Voice Lab is on and the price is known. The limit is min(60, 15% of the take's words), as in voice-lab.md §8.2.
- Voice row, when a consented voice exists: "Your voice is ready" · "{name} · made {date}", plus " from clip {n}" when it was made from this project. With more than one consented voice for the project's language, it is a pop-up, "Voice: {name}".
- Hint, once per app run and only while the edit popover is closed: "Click a change in the transcript to edit it. Nothing is paid for yet."
- Footer:

  | Case | Note | Secondary link | Primary |
  |---|---|---|---|
  | Voice changes included, no voice yet | "Next: make your voice from this clip. Once." | Apply free changes only | **Make Your Voice** |
  | Voice changes included, voice ready | "Sends the {z} new phrases and a short audio check to ElevenLabs with your key. No video." | Apply free changes only | **Make Takes · ≈ ${x}**, or **Make Takes…** when it confirms (at least $0.50, an unknown price, or crossing the monthly cap; voice-lab.md §3.1) |
  | Voice changes, Voice Lab off | "{z} phrases need your voice. Voice Lab (beta) makes it from this clip." | Turn On Voice Lab… | **Apply {k} Free Changes** |
  | Over the voice budget (advisory) | A warning callout: "These changes re-voice {v} words, a lot for a {n}-word {clip \| video}. Long stretches in your voice can sound stitched." Next steps: [Re-voice all {v}] [Change fewer words] [✦ AI suggestions] [Keep text fixes only], and the free-text field. Note: "Nothing paid yet. Make Takes appears once you choose." Re-voice all goes on as if in the budget. | — | none; the chips act |
  | Only cuts and fixes included | "No AI voice needed. Nothing is sent." | — | **Apply {c} Changes** |
  | Nothing included | "Check a change to apply it." | — | none; the close button closes |
  | No changes | Headline "No changes needed"; body "{AI} found nothing to change in clip {n}." | — | **Ask for Something Else** (focuses the field) |

- **Apply…** is one undo step named "Rewrite clip {n}". It announces "Applied {c} changes", closes the panel and moves focus to the first changed word.
- **Next steps** (voice-lab.md §8.2.1). No stuck state is a dead end: each shows a row of chips under the list, then "Tell the AI what to do instead…".
  - Over the voice budget: as in the table above.
  - A phrase that still does not fit after the automatic rounds: its row keeps Ask for shorter/longer, Keep original words, Use surrounding sentence and Price it anyway; the chips row adds the ✦ suggestions for the blocked phrases.
  - A phrase whose takes all failed the checks: "Phrase {n}: no take passed the checks." [Try another] [Keep original words] [✦ …].
  - A refused surrounding sentence: [Keep original words] [Price it anyway] (while the phrase is blocked) [✦ …].
  - A failed Rewrite (R1x with a message): [Back to the changes] when a proposal was replaced, and the field.
  - R3, and a re-ask whose reply came too late: the field; a late or stopped re-ask also shows its line and [Ask again].
  - Chips are bordered capsules that wrap at any column width. An AI suggestion starts with ✦, and VoiceOver reads "Suggested by the AI: {label}". Its label is display text only; clicking sends its instruction.
  - An AI chip or the field re-asks in this session, scoped to its phrases. The headline reads "Asking {AI}: “{label}”" with Stop, and the list waits. Only those phrases can change: every other change, edit, quote and take stays. Afterwards a line says what happened ("{AI} reworded phrase 2.", "Kept your original words for phrase 3.", "Stopped. Nothing changed.").
  - A chip that would discard paid takes asks first with the inline Discard Changes / Keep Working question. No chip is a pop-up.
- **Turn On Voice Lab…** opens the inline Voice job on Mac (voice-lab.md §5). Turning it on approves the own-voice model download with the licence visible; voice rows become available after setup. Windows retains its platform first-use presentation until its inline job lands.
- Announce "{c} changes proposed. {z} need your voice." when R2 appears, and move focus to the first change row.

**R3. The scope changed while the panel was open**

- An edit to any word inside the scope moves the panel to:
  - the headline "Clip {n} changed";
  - the body "You edited clip {n}, so these changes may no longer fit. Nothing was applied, and no takes were paid for." When takes exist, it adds "Your takes are kept until you close this.";
  - the link **Close**;
  - the primary **Rewrite Again**, with the send line as the note.
- Undoing back to the proposal's revision returns the panel to R2 with every inclusion and take intact.
- Edits outside the scope don't affect the proposal.
- On Mac, a successful reply rejected because the connector or model changed uses the same R3 actions with headline "AI changed" and body "You changed the AI, so these changes may no longer fit. Nothing was applied, and no takes were paid for." It does not claim the user edited the words.

**Request shapes** (detail in voice-lab.md §8.1):

- A clip or Full take uses `PatchRewriteService`:
  - the entries are the scope's kept items in the ai.md §11.2 item format, with corrections applied; unlike §11.2, which includes every item, cut items are left out;
  - the lines come from `formatTranscript`;
  - each line's character range comes from `VoiceLabLengthBudget`, with the whole line as one replace hunk.
- A selection uses `VoiceRewriteService`, as before.
- Both end in per-change hunks, `placeAll` (voice-lab.md §8.4) and the R2 list.

#### 6.3.7 Your voice, from this clip

**2026-11-02, ADR-R34:** for the project-audio choice, V1 uses the explicit checkbox "I confirm this is my own voice and I consent to creating a voice clone.", plus the existing adult and own-video boxes. **Use Clip Audio** prepares the selected speech locally without a microphone statement. The ready state shows checkbox consent and the training duration, then the separate priced **Create My Voice** action. It uploads selected speech only. Genuine ElevenLabs verification remains a separate possible next step. The statement/Scribe V2–V3 copy below remains for the read-aloud route only; it must not be shown as a mandatory step when using project audio. A failed project consistency check offers the read-aloud, and changed consent/audio invalidates the ready quote. Mac support is implemented first; Windows keeps its current refusal and recorded flow until parity work is validated.

**Mac inline job (V16, v3 f10 and v5 f23).** Rewrite's Turn On Voice Lab / Make Your Voice opens the right panel's Voice job, preserving the proposal. First use contains the beta notice, an inline ElevenLabs key field when needed, and the publisher, exact catalogue download size and licence immediately beside Turn On Voice Lab. That click enables the setting and approves that model download; installed models skip it. Progress, Cancel and Retry stay in the job. Nothing is uploaded. After setup, this Mac finds clear speech, shows the three explicit attestations and display name, and prepares the read-aloud statement before recording starts. The statement and recorder live in the job. Back to Rewrite keeps local work. Settings reuses the inline first-use card and is otherwise management (voices, deletion, storage, spend and turn off); it has no Create Your Voice entry or enrollment sheet. The speaker model's Settings row also places its licence and download action inline. The Mac enrollment flow supersedes the old opt-in and CreateVoiceSheet presentations.


The steps run inside the panel, and the proposal stays in the transcript. On Mac, Beta · Step 1 of 2 covers setup, agreements and recording; Beta · Step 2 of 2 covers the locally prepared quote, creation and result (v3 f10/f11). Back to Rewrite preserves enrollment work. The older three-step numbering below remains a Windows reference until its inline job lands.

The project-audio analysis (`VoiceTrainingSpans.select` with `preferRange` set to the scope's clip; on device and free; voice-lab.md §6.5.1) starts when R2 appears with voice changes and no voice. V1 therefore usually knows the result already.

**V0. No ElevenLabs key** (replaces V1's body)

- Headline "Add your ElevenLabs key". Text: "Your voice is made and spoken by ElevenLabs, with your own key. Create a key just for VoxClip with a monthly credit limit."
- A secure field, "ElevenLabs API key".
- Link **Make a restricted key** opens ElevenLabs key settings; permission guidance is voice-lab.md §2.2.
- Primary **Save Key**.
- Note:
  - macOS: "Saved in the macOS Keychain and used only by VoxClip for Voice Lab. Never passed to Claude Code, Codex or any other AI app. Saving makes no request."
  - Windows: "Saved for your Windows account and used only by VoxClip for Voice Lab. Never passed to Claude Code, Codex or any other AI app. Saving makes no request."

**V1. Agree** (Mac Step 1 of 2; Windows Step 1 of 3)

- Headline "Make your voice from this clip". Sub-line: "Your new words are spoken in your own voice. You do this once."
- The speech row, by the state of the analysis:
  - running: a spinner and "Finding your clear speech in this video…";
  - ok: "{t} of your clear speech found", with the detail "{c} from clip {n}, the rest from this video. Picked on this {Mac/PC}. English only for now." Clip {n} is the clip that set `preferRange`, which for a selection is the clip containing it. Variants of the first sentence: "All from clip {n}." when everything came from the clip; "From the rest of this video; clip {n} has none clear enough." when `preferredMs` is 0; "From this video." when `preferRange` is absent (Full take, or a selection outside every clip). Below it, a strip of the whole take shows the selected spans and, when `preferRange` is set, the clip's range;
  - below 30 s: a callout, "This video has only {n} s of your clear speech, so you'll read a short passage instead.", or "This video has no clear speech to use, so you'll read a short passage instead.";
  - unreadable: "VoxClip can't read this video's audio, so you'll read a short passage instead.";
  - labelled AI modified: "This video is labelled AI modified, so it can't train your voice. You'll read a short passage instead."
- When `voiceLab.providerConsent.elevenlabs` is not stored yet, the voice-lab.md §2.5 provider copy comes first, exactly.
- Then the voice-lab.md §6.1 notice, exactly, with the links **Terms** and **Use policy**.
- Three checkboxes, exactly: "This is my own voice." · "I am 18 or older." · "I will use it only on videos of myself."
- A field, "Your name, as you'll say it". It is prefilled from the account's full name and validated by voice-lab.md §6.1. Its error reads "Use 1 to 60 characters, with no line breaks."
- Rows that appear only when a requirement is unmet:
  - The own-voice check is missing: "Download the own-voice check (27 MB)" · "Runs on this {Mac/PC}. Licence CC BY 4.0." with **Download**. The third-party download confirmation (§10) comes first, then "Downloading… {p}%" with **Cancel**.
  - Plan: "Instant voice cloning needs an ElevenLabs Starter plan or higher." or "Your ElevenLabs account has no free voice slots.", with the link **Open ElevenLabs**.
- Mac primary **Read the Statement** prepares the statement locally after the three agreements; recording starts only on **Record**. No provider request is made here. The plan check belongs to the later priced Create My Voice action.
- Windows legacy presentation, until its inline job lands: "Checks your ElevenLabs plan. Free; no audio is sent." Primary **Continue** stores provider consent and runs the plan check (`GET /v1/user/subscription`, voice-lab.md §2.3). With an unticked box, Continue focuses it and says "Tick all three to continue."
- **Windows, until its speaker check is enabled** (voice-lab.md §6.6): an informational `InfoBar`, "Making a voice isn't available on Windows yet: the on-device check that it's your voice isn't ready. Your free changes still work." The only primary is **Apply {k} Free Changes**.

**V2. Read aloud** (Mac Step 1 of 2; Windows Step 2 of 3)

- Rows:
  - the speech row, done, as in V1;
  - "You agreed: my own voice · 18 or older · only my videos", done, with **Change**, which returns to V1.
- Headline "Read this aloud, in one take".
- The teleprompter shows the voice-lab.md §6.2 statement, generated per attempt, with the four nonce words emphasised.
- The recorder:
  - idle: **Record**;
  - recording: "Recording {m:ss}", a level meter and **Stop**.
  - Space outside a text field plays or pauses the video. ⌘Return activates the current primary. A priced action never receives focus automatically, ignores repeats, and ignores ordinary Return during its first 0.5 s.
  - With VoiceOver or Narrator running, a note reads: "Using a screen reader? Wear headphones so it isn't recorded."
- Note: "Stop after the last word (5 to 30 s). Nothing leaves this {Mac/PC} until you choose Create My Voice."
- Errors show inline while the recorder stays:
  - under 5 s: "That was under 5 seconds. Read the whole statement, then stop.";
  - the 30 s cap: "Recording stopped at 30 seconds. Read a little faster and record again.";
  - silent input, a lost device or an unavailable microphone: the recorder copy in §13;
  - permission denied: "VoxClip needs the microphone to record your statement." with **Open Privacy Settings** (Windows: **Open Microphone Settings**).

**V3. Checking it's you** (on device and free; it runs right after Stop)

- Headline: a spinner and "Checking it's you…". Note: "Comparing {k} stretches of this video with your statement. On this {Mac/PC}; nothing is sent." A determinate bar with "{i} of {k} · about {s} s left".
- **Mismatch**, when fewer than 30 s remain after voice-lab.md §6.6:
  - a callout, "Some of this video's audio doesn't sound like the voice in your consent statement. Record a read-aloud instead.";
  - a done row, "Statement recorded and kept" · "You won't need to read it again.";
  - primary **Record a Read-Aloud**;
  - note "Nothing was sent. The check ran on this {Mac/PC}."
- **Read-aloud** (too little speech, or a mismatch), Step 3 of 4: the headline "Read this aloud, about 90 s", the `scripts-en.txt` text and the same recorder, validated at 60 to 90 s on Mac (the existing bounded recorder); the Windows design range remains 60 to 120 s. Then V3 runs again against the read-aloud, with the voice-lab.md §6.6 floor of 10 s. Below that floor: "Some of these recordings don't sound like the voice in your consent statement.", nothing is sent, and the primary is **Record a Read-Aloud** again.

**V4. Ready to create** (Mac Step 2 of 2; Windows Step 3 of 3)

- Headline "Ready to create your voice". A done row: "It's you" · "{m} of this video matches your statement." For a read-aloud: "Your read-aloud matches your statement."
- Body: "Checks your plan, then sends your statement and {m} of your speech to ElevenLabs to create your voice. No video is sent."
- Primary **Create My Voice · {quote price}**, computed from `preparePlan → plan.quote.estimate`; no hard-coded amount. One click approves plan check, statement verification and creation (voice-lab.md §6.4). Until that click, the statement and training audio stay local. A local mismatch makes no request. Monthly soft-cap warnings appear beside the action without another dialog; an unknown estimate explicitly names ElevenLabs pricing.
- A recorded statement has **Play Statement**. The plan, statement and creation rows show what the click does. A failed verification returns to recording and creates no voice; there are no separate Verify and Create approval steps.
- A durable verified enrollment offers **Resume Creation**, which prepares and displays a creation-only quote. It never automatically executes or repeats the statement transcription. Wrong key, changed region, expired or ambiguous journals retain Core C7's guards.

**V5. Creating**

- Headline: a spinner and "Creating your voice…". Steps:
  - done: "Statement recorded" · "{m:ss} · kept on this {Mac/PC}";
  - done: "It's you" · "{m} matches your statement, checked on this {Mac/PC}. {d} short stretches didn't match and were left out.", with the strip showing the left-out spans;
  - done or running: "Statement read correctly" · "Checked by ElevenLabs";
  - running: "Creating “{name} (VoxClip)” in your ElevenLabs account", with an indeterminate bar;
  - waiting: "Back to clip {n}" · "{z} phrases to voice".
- Footer note: "Sending your statement and {m} of your speech to ElevenLabs with your key. No video. < $0.01". On Mac, **Stop** requests cancellation; it cannot undo a dispatched request. The journal owns reconciliation and recovery (voice-lab.md §6.8).
- The statement doesn't match (WER or nonce): "That didn't match the statement. Read it again, clearly, in one take." The panel returns to V2 with a new statement, and nothing is created. After three tries in 10 minutes: "That's three tries in 10 minutes. Try again at {time}."
- `requires_verification`: "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back.", with **Open elevenlabs.io** and **Check Again**.
- A local save failure, and recovery: the existing copy and actions (voice-lab.md §6.8), including **Remove This Voice**.

**V6. Done.**

- The job shows "Your voice is ready." with **Back to Rewrite**. Returning shows R2; V18 supplies its priced Make Takes action. Takes never start by themselves.
- Announce "Your voice is ready."

#### 6.3.8 Takes and Use

**T1. Approval.** It is the R2 primary.

- On Mac, discovering a consented voice opens the Voice job in the existing panel host. Voice/model pickers, phrase rows and Review Changes share that job. After a run the Speech model stays changeable while nothing runs: a new model drops the held retry price and applies to the next Try another, and every take already made keeps the model it was made with. The Voice picker stays locked while paid takes are kept; Review Takes returns without another host. Preparing a price sends no synthesis or QA. The priced Make Takes click approves the displayed complete-set quote, not a later replacement. High or unknown estimates ask inline, with Keep Working as the safe primary and the confirmed action labelled as billed to the key. ElevenLabs' first-use privacy consent is inline too and cannot start paid takes.
- One approval covers every included phrase's bounded take set (one candidate per phrase on the first run; at most three visible slots after separately approved retries) and its Scribe QA, as one summed cap (voice-lab.md §8.6).
- The use-time guard (voice-lab.md §6.9) runs first, on device, and is cached per (contentKey, recordId).
- If the guard fails:
  - a danger callout, "This doesn't sound like the voice owner. Voice Lab is only for your own videos.";
  - the note "Checked on this {Mac/PC} against 10 s of speech near each change. Nothing was sent or charged.";
  - primary **Apply {k} Free Changes**. There is no override.

**T2. Generating.**

- Headline: a spinner and "Making takes… phrase {i} of {z}", with **Stop**.
- Rows fill as takes arrive. The first run makes one take per phrase. Short takes say “waiting for the voice check” until the completed run or Stop finishes the pooled check; waiting rows cannot be selected.
- Mac rows retain every failed take and the engine's status, including “Phrase 2 of 3…” and “Take N stopped.” Stop cancels and drains price preparation or generation, retains completed takes, and never starts a replacement quote. A stopped phrase is retried independently; finished phrases are not regenerated.
- Announce "Phrase {i} fits."

Once per phrase, passing short takes use the inline f12 grammar: `Short phrase · words checked · voice checked across 3 takes`, using the actual pooled count. An under-length pool says `voice couldn't be measured (under 3 s of speech)` and explains that selection is allowed for the user's own clone. This is an unavailable measurement, never a failed speech comparison. Wrong words and measured speaker mismatches retain their distinct failure reasons, without the passing-voice summary. A measured mismatch blocks the own-clone unmeasured exception for that record until a later approved run passes a measured check. Unmeasured takes require the user's explicit click; automatic selection prefers measured passing takes and preserves valid explicit selections. Finalizing voice checks preserves specific fatal-error text and names consent/provider failures truthfully. `Use surrounding sentence` remains an optional inline review, available from the advisory estimate before payment as well as after an unmeasured take. No expansion or extra synthesis happens automatically. See [ADR-R37](adr/R37-short-phrase-voice-check.md).

**T3. Ready.**

- Voice line: "Voice: {name} · made {date}", plus " from clip {n}" when it was made from this project.
- Headline "{z} phrases in your voice". Sub-line "Listen, pick a take, then use them."
- One row per phrase:
  - a play button and the quoted new words;
  - then "Take {k} · {d} s · fits", or "· pauses +{x} s".
  - With more than one take: a 1·2·3 segmented control, the duration and a "Best match" tag. The focused row adds the link **Try Another · {amount}**: {amount} is that phrase's own take-set estimate, written by voice-lab.md §3.1 `format`. It reads **Try Another…** with no amount when that estimate confirms (voice-lab.md §3.1).
- Below the list: **Play Clip {n} with New Voice**, which previews the clip with the selected takes, and the line "Made {t} takes · ≈ ${x} on your ElevenLabs account."
- Mac retries first prepare that phrase's quote with **Try Another…** (or **Try Again…** for an empty row). Its separately priced **Try Another · {amount}** action then appears beside the phrase-only send line. The engine holds one quote; no estimate is invented for another row. A retry requests one candidate for that phrase only. The 1/2/3 keys select a QA-passing slot in the focused phrase; failed slots remain visible but cannot be selected. A failed take with audio has a play button at the start of its reason line ("Take {k}: … Left out."), so the user can hear what the checks refused; playing it does not select it. A take that failed before the checks has no checked mix: its line reads "Take {k} · not checked: … Left out." and its play button plays the paid audio as ElevenLabs returned it. Selection, Stop, price preparation, acceptance, leaving the rows and invalidation stop audition. Nothing autoplays.
- Footer: "Exports show AI MODIFIED on the video. The post disclosure is optional.", and the primary **Use Takes**. The post-caption disclosure remains opt-in and OFF by default; the burned-in export label is unchanged.

**Passed with join advisory (3 November 2026).** A take that passes every hard check but exceeds the join-loudness threshold stays visible and playable. Its inline callout-size row reads **Take {n} · {dur} · The join may sound uneven ({side} side). Listen before using.**, with **Play** and **Use anyway**. `{dur}` is the existing one-decimal seconds display; `{side}` is `left`, `right`, or `either` for both joins. The accessibility labels name the phrase, take and join advisory. No alert or sheet is added. Play does not select it; Use anyway records acceptance for that take and selects it, then the normal video-duration choice and Use Takes flow apply. Clean takes win Best match; advisory-only phrases remain unselected. Numeric shortcuts, Keep-all, Use-all and automatic selection cannot choose an unaccepted advisory. The warning stays visible after acceptance and across retries of other takes. Words, speaker/pooled voice, clipping and consent failures remain failed rows, without an override.

**Edge cases.**

- **A phrase with no passing take.** The row's sub-line reads "These takes didn't sound right. Edit the words or try again.", with **Try Again · {amount}** (or **Try Again…**), priced like Try Another, and **Edit Words**.
  - The phrase is left out of Use: the primary reads "Use {z−1} Takes", and the row says "Left out until a take fits."
- **Length changed.** Retime and lip sync are not rendered in the planned interface. The row says "Take {k} runs {s} s longer than the words it replaces. Shorten the words or try another take." For a shorter take: "Take {k} runs {s} s shorter than the words it replaces. Edit the words or try another take."
  - When rendering lands, the length choice (ADR-R28, voice-lab.md §8.9) returns as an info callout with two radio rows, neither preselected and never remembered: **Lip sync**, "Sends {s} s of video around the change to {provider} with your key. About ${x}, confirmed before it runs."; and **Retimed source video**, "Slows these {s} s of video to {r}× and crops in slightly around your face. Nothing is sent." (a shorter take: "Speeds these {s} s of video up to {r}× and crops in slightly around your face. Nothing is sent.").
  - The Lip sync sheet: "Lip sync this change?" / "This will cost about ${x} on your {provider} account." / "Sends {s} s of video around the change to {provider} with your key." with **Cancel** and **Continue**.
- **Provider error.** A callout: "ElevenLabs rejected the key (401). Your edits are saved." It comes with an inline key field, **Save Key** and **Retry**. There is no Settings detour.
- **Rewriting with unused paid takes.** The existing inline discard question protects paid engine takes too. Keep Working is the safe primary; Discard Changes explicitly retires the proposal and takes. No takes approval or discard sheet is added on Mac.

**T4. Use and done.**

- **Use Takes** applies the selected fitting phrases and every included pending cut/fix as one scoped undo step, "Rewrite clip {n}" (or the selection/full-take name). It uses `RewriteSession.acceptTakes` → C4 `acceptAll` once; stopped, failed and changed-duration phrases are never described as accepted. The review closes and transcript focus moves to the first changed source word. In the same panel host, Voice shows the in-use phrase rows (v3's done frame), with **Play phrase in clip**, the chosen take and fitting duration. Captions remain available in the switcher.
- A toast for 6 s: "Clip {n} rewritten: {z} phrases in your voice, {x} cuts, {y} fix." with **Undo** (⌘Z / Ctrl+Z). The same sentence is announced.
- The in-use footer says **Spent {actual amount} on ElevenLabs for {t} takes. Exports carry an AI MODIFIED label.** with **Undo Voice**. Unknown spend says "Spend unavailable", never a guessed price. Both Undo buttons reverse the entire review, not one phrase; provider spend is not refunded. The feedback is session-only and disappears after a project/revision change. Its Undo never reverses an intervening edit. A stale publication or refused nonfitting set shows no success toast or undo entry.
- The accepted words show as AI words (§4.1). The sidebar meta reads "AI modified", the viewer bar shows the AI modified tag, and the stage shows the preview label at the configured position. Export's accessible name adds ", contains AI-modified speech". The share disclosure is unchanged (voice-lab.md §11.3).

#### 6.3.9 Edge states

Leaving Voice via Back, the job switcher, a tab/scope change, Home, hidden right column or window/owner exit stops and discards an ongoing statement/read-aloud before hiding its controls. Already completed local draft audio survives temporary navigation. Automatic stop is session-owned and handled once even without a mounted view; canceled or late results cannot restore a discarded recording. No background/invisible recording is supported.

Done/Back after successful creation and successful cancellation are terminal: they reset the transient enrollment step, price/plan, recovery presentation and agreement/recording draft. Reopening starts at actual prerequisites/agreement, never stale success. Saved voices and their consent audio survive. An unsaved remote creation must still be saved or explicitly removed; Done cannot silently drop it.

Returning after creation refreshes the existing Rewrite review's voice choices under its current provider consent and selects the new active voice. Pending ElevenLabs verification is not a usable voice: the review explains verification/refresh, without sending takes or rebuilding the proposal. Once takes are paid, voice/model choices are locked; changing inputs by another route invalidates the plan but preserves its paid-review discard guard. A late discovery or generation response cannot revive a stale choice or take.

The priced take plan pins pending cuts/corrections and proposal change content/states too, including corrected bridge speech. Leaving out a pending correction without editing the project invalidates old approval and Use Takes. Unpaid work needs a fresh quote and explicit click; paid work keeps its discard guard. An explicit take selection survives failed/better retries, Stop and slot eviction. Row Play pauses source playback, and source Play/Space stops take audition, including pending startup. Plain paid Return is timed from the actual key event, not delayed delivery; repeat and Space never spend.

Accepted take charges update the local monthly total while review remains open, including stopped/late/unpriced responses. Daily transcription and monthly Voice Lab amounts share one status slot with separate labels, never a combined ledger; pending paid transcription suppresses the harness billing claim. These updates do not refresh a provider account.

| State | Where | Copy and action |
|---|---|---|
| No ElevenLabs key | V0 | §6.3.7 V0 |
| No AI chosen | R0 | §6.3.6 R0 |
| Not enough clean speech | V1, then the read-aloud | §6.3.7 V1, below 30 s |
| Speaker mismatch | V3 | §6.3.7 V3, mismatch |
| A paid step of $0.50 or more, an unknown price, or crossing the monthly cap | inline panel question on Mac; existing presentation on Windows | voice-lab.md §3.1 copy |
| AI on an API key | inline approval row R0b (Mac v2) | §6.3.6 R0b |
| Too much to re-voice | R2 | the over-budget footer in §6.3.6 R2 |
| Not the voice owner | T1 | §6.3.8 T1 |
| Voice Lab off (release) | R2 | the §6.3.6 R2 footer |
| The scope edited meanwhile | R3 | §6.3.6 R3 |
| Scope too large | R1x | §6.3.6 R1x |
| Windows before speaker-check parity | V1 | §6.3.7 V1, Windows |

#### 6.3.10 Removed

Each item goes in the same change that replaces it, on both platforms:

1. The right column's Voice block: "Voice", "No voice yet", **Create Your Voice…** and **Refresh voices**.
2. The disabled **Generate Takes** button, and the send line shown before takes are possible.
3. "Rewrite one passage at a time. Keep one changed passage, then generate takes.", shown twice, and the code path that refuses more than one voice hunk.
4. **Open Settings**, the disabled **Retry** under the connector status, and "Choose a connector in Settings → AI.". Fixes are inline, and Retry appears only in an error state.
5. The disabled **Use Take 1** and the duplicated AI MODIFIED note.
6. **Choose Voice…** and the separate "Use ElevenLabs?" alert before voice discovery, which fold into V1.
7. The panel's "What should change?" field, the plain-text **New words** field and the read-only diff line. The scope bar's field and the edit popover replace them.
8. The separate voice-creation sheet: `CreateVoiceSheet` (macOS), `CreateVoicePage` and `VoiceCreationDialog` (Windows). Their session logic moves into the panel steps; the views are deleted, not kept beside the new ones.
9. On Mac, the separate **Verify statement · < $0.01** and enrollment **Check ElevenLabs account** buttons, merged into the one priced **Create My Voice** action. Settings retains its account-management check.
10. The training-source radio group. Project audio is automatic, and the read-aloud appears only when needed.
11. "Download the own-voice check model in Settings → Voice Lab before creating a voice." The download is inline in V1.
12. Outlined boxes per line for selections, Rewrite passages and changes in the transcript.
13. **Create Your Voice…** in Settings → Voice Lab.

### 6.4 Other AI features (M2) and Voice Lab rows

| Feature | Where |
|---|---|
| Tighten with AI (M2) | Edit > Tighten with AI… and the toolbar capsule's menu, macOS overflow or Windows ⋯. Suggestions show as filler-style dotted underlines. The edit summary area offers **Cut All Suggestions** |
| Clean audio (M2) | Edit > Clean Audio… and ⋯. It opens a right-column panel shaped like Rewrite (§6.3.4): what it sends, the cost button "Clean Audio · ≈ $0.36", progress and Use |
| Voice changer (later, M3+) | Edit > Change Voice… (scope: the selected clip or the full take). It opens a right-column panel: Voice, Takes, disclosure, Use |
| My voice (consent and clone) | 0.1.0: Mac creates voices from Settings → Voice Lab and Rewrite (**Create Your Voice…**); Windows marks creation unavailable. The planned interface moves creation inside Rewrite (**Make Your Voice**, §6.3.7) |
| Lip sync (later, M3+) | only as the length-changed choice in Rewrite, once rendering lands (§6.3.8) |

When rewritten speech requires a different video duration, show Lip sync and Retimed source video together and let the user choose for that rewrite (ADR-R28, Voice Lab §8.9), as specified in §6.3.8. The current capability guards for unsupported video remain until those paths are implemented and verified.

For already reviewed, saved v3 recipes with unity audio fit and equal-length source video, the editor uses the existing viewer, timeline and Export controls:

- **Playback.** Preview duration and scrubbing follow the prepared Voice Lab timeline. Source cuts beneath an enabled replacement stay dormant.
- **Export scope.** The Full video export ignores a selected clip row.
- **Captions.** They show the replacement words. Captions Off keeps the mandatory AI MODIFIED chip and the export provenance.
- **Missing or changed asset.** A missing or changed generated asset clears the preview and explains how to restore it.
- **Unsupported cases.** Unsupported video treatments, duration fit and unreviewed recipes stop with an inline explanation, keeping the video and edits.

### 6.5 Director (Phases 1–2, reserved)

The Director will run an AI session that proposes cuts, clips, rewrites and captions with VoxClip's own tools. Its behaviour, copy and the rules for agentic use are specified with `doc/spec/harness.md` in Phase 1, not here. Phase 0 fixes only the shapes that the Director reuses, so the Rewrite surfaces don't need rebuilding:

- **Composer.** The scope bar's field (§6.3.1) becomes the Director's composer, and the AI picker becomes its picker. There is no second field and no second picker.
- **Task model.** The Rewrite panel (§6.3.4) is a one-turn task on the shared model:
  - `DirectorTask` holds the scope; its state (choosing an AI, running with `ActivityStep`s, a proposal, voice steps, takes, changed, or an error); the context line; and the footer (note, link, primary);
  - a proposal is a `ChangeSet` of `ProposalItem`s;
  - a step that needs the user is a `PanelCard`.

  Phase 1 feeds session events into the same model. Phase 0 adds no Rewrite-only view model.

---

## 7. Home

**macOS v2 export state.** The Explorer’s Exports section (§3.4) owns the trailing 11 pt `exclamationmark.triangle` in `status.warning` for Edited since export and Export failed. Exported has no glyph; a target with no ledger record has no Exports row. Clip rows have no export warning glyph. Export state remains in help and VoiceOver, and failed exports retain Retry in the Exports context menu (and Retry export in the clip context menu).

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

- **Box:** 64 high, on `bg.sunken`, with a 1.5 px dashed `line.strong` border (6 on, 4 off; 3.49:1 dark, 3.12:1 light). Radius 14 (macOS) or 10 (Windows).
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

### 7.1 Inline Transcribe and the untranscribed state

Opening a video makes it playable at once. On Mac v2, Transcribe is part of the transcript buffer (v5 f20–f21/f25), with no sheet, fill, ring or radius. Its text starts on the transcript's x 80 text column; glyphs sit in the gutter. The block pushes existing words down for Transcribe Again. Windows retains its current import dialog until this flow is ported.

- A free installed engine starts on open with no choice block. English on this Mac defaults to Apple Speech, listed first; it needs no third-party model download. Settings' **On this Mac** routes English to Apple Speech and other languages to Whisper. A Whisper model explicitly chosen in the block remains the choice for that run.
- Show the choice block when a model or Apple speech assets need downloading, the engine is paid, Settings says **Ask each time**, or the language cannot be detected locally. Auto with an installed multilingual Whisper model can run its local detection; without it, ask which language is spoken.
- **Language:** recent languages, then the full alphabetic list, plus Auto for local detection. **Remember for new imports** writes only `transcription.language`; the engine for future imports comes from Settings.
- **Engine:** Apple Speech first, On this Mac with the Whisper model picker, then ElevenLabs Scribe. Keep ElevenLabs discoverable without a key: show a secure field, **Save Key**, the restricted-key link, and the priced transcription primary. **Save Key** stays visible and disabled while the field is empty or saving. The transcription primary stays visible and disabled until a key is saved and the existing media, readiness and price checks pass; say “Paste your ElevenLabs key above, then choose Save Key.” Saving makes no request and never approves an upload.
- **Speakers and key terms:** ElevenLabs' folded advanced controls keep Off, Auto and 1–32 speakers, plus comma/newline separated keyterms (at most 100, each at most 50 characters). Keyterms multiply the catalogue estimate by 1.2.
- Before a third-party model download, show its publisher, size, licence, source page and “By downloading you accept the publisher's terms.” **Download and Transcribe** is approval; there is no second confirmation. While downloading, language, engine and model remain editable. Completion starts the currently selected ready free engine. Selecting ElevenLabs pauses automatic continuation; the downloaded model stays installed.
- Downloads show byte progress and Cancel. Failure replaces the download line, with retained bytes and **Retry** / **Not now**. Cancel preserves resumable partial files. **Not now** folds the block to “This video isn't transcribed yet. [Transcribe…]”. The video keeps playing and exports remain available without captions.
- **Every ElevenLabs run requires a priced click**, including after `transcription.cloudConsent.elevenlabs` is stored: **Upload and Transcribe · ≈ $X**, calculated from duration × catalogue rate, plus the keyterms surcharge. No audio goes before this click. First use combines privacy and approval: “Uploads this video's audio to ElevenLabs with your key.” and “{duration} of sound, no video frames. ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. Asked once.” Later runs omit the terms but keep the priced primary.
- A paid primary never focuses itself. Space plays; a Return must be fresh, not repeat, postdate the row and arrive at least 0.5 s after it appears or changes. ⌘Return approves from the block. Saving a key resets the guard. Esc in the block or ⌘. cancels the current download/run.
- Running steps cover reading, extraction, upload, transcription and alignment, with progress and six skeleton lines. Before upload: “Nothing has been sent yet. Cancel now and nothing is billed.” After upload starts: “If you cancel now, ElevenLabs may still bill audio it already received.” Cancel discards partial results and keeps the video. The status bar suppresses the harness's cost item during a paid transcription and shows ElevenLabs' daily estimate plus pending spend; canceled/failed uploads remain an upper bound. These are estimates, not invoices.
- **Transcribe Again…** opens the block above the existing transcript: “This replaces the transcript and removes {n} cuts, {m} corrections, {k} clips and the AI suggestions.” The neutral **Transcribe Again** action starts with focus on **Cancel** and has no default or ⌘Return shortcut. Cancel keeps every edit. For ElevenLabs it reads **Transcribe Again · ≈ $X**, stays neutral, and the explicit click approves the upload and replacement. Successful replacement clears the named edits and suggestions in one undo step, “Transcribe video”; failure or cancellation keeps them. Existing exports stay.

---

## 8. Export and share

macOS: Export is a job in the right panel, below the existing reframed viewer (v3 f14). The header reads **Export · Clip 1** (or the captured full-edit/batch target) and keeps the panel switcher. The title-row **Export Video…** / **Export Clip…**, File > Export… (⌘E) and Explorer Export/Retry open that job with their requested target. There is no Export window or sheet. Windows retains its `ContentDialog` until its inline-actions lane migrates it. Existing export capability reasons still apply: keep at least one word, resolve missing/unreadable video, and leave demo projects before exporting.

Setup uses the Captions job's flat spacing, 16 pt inset, 24 pt property rows, 12 pt labels, 11 pt metadata and hairlines. Settings scroll; the footer stays visible.

- **What:** This clip (number, title, duration), All N kept clips in transcript order, or Full video. The requested target is captured when the job opens. Export still uses `.fullEdit` or one `.clip(id)` per target.
- **Aspect:** segmented **9:16 · 1:1 · 16:9 · Original**, with “Reframed on your face, preview above”. Values and suffixes remain `9x16`, `1x1`, `16x9`, `source`.
- **Captions:** burn-in switch, the existing style picker including Off, and **Also save .srt**. Switching captions off preserves the last non-Off style for switching back on.
- **Quality:** **Standard / High**, the engine's real option. f14's resolution/frame-rate rows map to read-only derived output size and fps. No new encoding options or persisted size/fps fields are introduced.
- **Save to:** current folder and **Choose…** using the permitted system directory picker.
- **File name:** editable job-specific pattern, initialized from Settings. `{project}-{clip}-{aspect}` uses the existing base-name sanitization, 100-character cap, fallback, safe folder containment and collision suffixes (` 2`, ` 3`). `{clip}` is `full` for a full edit.
- Aspect, quality, SRT, folder and caption style edit the existing project settings. The file-name pattern and requested target belong to the job. Panel/tab switches preserve setup state and share drafts. Calling Export again while idle re-targets to the active tab when it differs and clears the old result; a running export resumes its captured target. Choosing This clip captures the active clip for both the header and render.
- **AI speech:** when an export includes AI voice, the read-aloud notice remains “This video contains AI-modified speech. It will show AI MODIFIED.” The mandatory burned-in video label and provenance are unchanged. The post line is optional, separately controlled below.
- Footer: **0:38 · about 24 MB · H.264**, estimated from target edited duration and the resolved video/audio bitrates. The primary reads **Export Clip 1**, **Export 4 Clips** or **Export Full Edit**; after failure it reads **Try again**.

While running, inline progress reads “Rendering 1 of 2 · 42% · about 1 min left” and exposes **Cancel**. The status bar continues showing its export progress. Switching panel or tab leaves the editor-owned export task running. Errors appear inline, and Retry in the Explorer opens setup for the failed target and folder. A successful target still records the export ledger (§6.2).

After export the result is **Exported · file name · Show in Finder · Done**. **Done** returns to the previous available panel job, falling back to Captions. A new Rewrite session or turn brings Rewrite forward while Export remains available in the switcher. Sharing is optional: **Share to X or LinkedIn…** starts collapsed, and its open/closed state is remembered in `ui.export.shareExpanded`. Done never prompts about sharing.

Inside that section, the editable caption retains the X weight (`/280`) and LinkedIn scalar (`/3,000`) counters, **Copy caption**, **Open X**, **Open LinkedIn**, drag-out files, and “VoxClip copies the caption and reveals the file. Add the video in the browser; nothing is posted automatically.” For targets with a generated AI-voice disclosure line, the plain toggle **Add 'AI MODIFIED' line to the post** is **OFF by default always**, including AI-voiced exports. Turning it on adds the exact line from the rendered export after a blank paragraph, with an uncut fallback if share-text rules are unavailable; turning it off removes it with no interstitial or warning. Only an export with AI-voiced phrases shows “Your video still shows the AI MODIFIED label.” A target without AI voice has no generated post-line control or hint. The burned-in video label remains unchanged. “Caption copied.” resets after two seconds. Browser opening accepts only HTTPS URLs at X or LinkedIn. Optional post text and truncation rules are in voice-lab.md §11.3 and publishing.md §2.1.

Missing-media relinking uses an inline work-area banner: “This file looks different. Use it anyway?” and the candidate file name, **Use It**, **Choose Another…**, and **Cancel**. Only Use It confirms different media. Cancel or cancelling the system picker leaves the project unchanged. Duration mismatches beyond 0.05 seconds still refuse; a successful relink is one undo step. VoiceOver announces the banner and candidate name when it appears. Use It relinks the current project, preserving any intervening edits or tab scope changes. Cancel or Choose Another retires the candidate; a closing/closed project cannot relink, and a refused confirmation keeps its banner with an inline explanation. Until the video is found and confirmed the Mac editor only reads (editing.md §10.3, v5 f24c and f24): the transcript, selection, Explorer, timeline and caption position work; the clip bar keeps Rewrite, Tighten, Hook and the Ask field in place, dimmed, with the reason as their tooltip; an open Rewrite closes and none starts; Export and its entries are refused ("Locate the video to export.", "Confirm the video to export."); and the status bar shows "Read-only until you locate the video" or "Read-only until you confirm the video" with an alert glyph where a running task shows. A video is missing only once its check answers: as a project opens or reverts, Locate… and the read-only note wait for that check, so a slow or external volume shows neither.

M2's future Export & post remains scoped by publishing.md §3; its final post call is never retried automatically.

---

## 9. Onboarding (first launch, skippable)

On Windows, before this optional onboarding or any project, media, model, provider or key access, a native blocking dialog titled **Windows component terms** explains: “VoxClip includes Microsoft Windows components. Review and accept their terms to use this Windows build. VoxClip itself remains open source under MIT.” It displays the full bundled Windows App SDK 2.5.1 terms offline in a scrollable read-only field that stays usable with keyboard scrolling and display scaling. **Accept and continue** records the exact current terms hash for this user; **Quit**, Escape and closing the dialog or its host window leave normal app features unavailable. The default button is Quit. No checkbox is preselected. The prompt reappears only when the terms hash changes or the receipt is absent or invalid; an accepted receipt opens the normal window directly. About → Licences continues to show the complete root notices. This dialog may initialize WinUI before the decision; it does not start normal application services.

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
              You can always make clips yourself: select words, press ⌥⌘K.   [[ Not now ]] [ Continue ]

Step 3 of 3   Five keys to know
              Space play · ⌫ cut · ⌥⌘K clip · ⌘Z undo · ⌘E export
              [ Open a video… ]                                                     [ Done ]
```

- Step 2 preselects **nothing** (AI spec section 7.1 rule 8, `llm.connector` starts empty). **Not now** is the default button; **Continue** is disabled until an option is chosen. Choosing Installed CLI also requires picking Claude Code or Codex explicitly. Continue stores only `llm.connector`; onboarding grants no consent. The AI spec section 4.8 sheet appears before the connector's first request (Find Clips, Rewrite or Settings → Test), once detection reports the connector ready, so a CLI sheet words its billing sentence from the detected sign-in. Windows, until its redesign merges: cloud and CLI connectors also show the checkbox "I understand what this connector sends and want to use it.", and Continue stores `llm.cloudConsent.<id>`. The redesign keeps the checkbox but stores only `llm.connector`.
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
| **AI** | Normative content in AI spec section 10.1: connector picker grouped as *Your API key* / *On this computer* / *Installed CLI (your own sign-in)*; model picker `{name} ({tier})` + **Custom…** + **Refresh models**; per kind: key row, local server URL and status line, Apple availability and supported languages, CLI status line ("Found claude 2.1.309 at ~/.local/bin/claude · Signed in") with **Choose…** and **Sign-in help**; **Test**; "Snap clip edges to sentence boundaries". Footnote per group on what is sent. Layout follows this document (grouped form rows, no cards). Under the connector picker, one line: "The AI menu above the transcript changes this too." (§6.3.2) |
| **Export** | Defaults for new projects: aspect (`export.defaultAspect`), Quality: Standard · High (`export.quality`), Captions: Burn in · Burn in + .srt (`export.srt`). File name pattern (`export.fileNamePattern`). Default folder (`export.folder`). Open folder after export (`export.openFolderAfter`). Windows: Encoder (read-only, from the probe) + "Re-check encoders". |
| **Accounts** (M2) | VoxConvo: "Not connected" / "@handle" with **Connect** (device flow, publishing.md) / Disconnect. Footnote: "Posting is optional. VoxClip never posts without your click." |
| **Voice Lab** (M3, beta) | Management only; voices are made inside Rewrite (§6.3.7). **Show Voice Lab (beta)**, with its one-time notice (voice-lab.md §5). **Keys**: the ElevenLabs, fal.ai and sync.so rows. **My voices**, one record each: its name; "Made {date} · consent {date} · English"; the ElevenLabs voice ID (selectable); **Delete Voice…** and **Remove from VoxClip Only**. Unfinished operations keep their state line and **Retry** (voice-lab.md §6.8). Empty state: "No voice yet. You make it from a clip the first time a rewrite needs your voice." **Own-voice check**: the model row with its installed state, size and licence, and **Download…** or **Remove**, so it can be fetched ahead of time. **Spending**: "Warn me above $__ a month" per provider. **Exports**: the label position and Content Credentials. **Storage**. There is no **Create Your Voice…** and no voice-creation sheet. |
| **About** | Version, Check for updates, licences (the bundled `THIRD_PARTY_NOTICES.md`: models, fonts OFL, Unicode data, libraries), GitHub link, "What leaves this device", Reset onboarding, Reveal logs. Windows also shows "This software uses libraries from the FFmpeg project under the LGPL" with a link to the `VoxClip-win-ffmpeg-source.tar.xz` asset of the running version (release.md section 1.1). |

Every row's settings key, type and default are in `shared/schemas/settings.schema.json`.

Windows 0.1 import accepts the container list only with the codecs in `tools/ffmpeg-build/components.md`. ProRes, DNxHD/HR, MJPEG, MP3, AC-3/E-AC-3, ALAC and FLAC tracks can occur inside MP4/MOV/MKV but currently produce `decodeFailed` on Windows. The import error uses the normal recoverable media-error treatment; it does not imply the file was changed.

Key row (both platforms): label, secure field with placeholder = key hint or "Saved in the Keychain; paste to replace" / "Saved for your Windows account; paste to replace"; buttons **Save key** (disabled when empty), **Test** / **Testing…**, **Forget key** (only when a key exists); result line from the owning spec's Test (green "Works …" / orange "Failed: …"). Footnote: AI keys "The key stays in the macOS Keychain and is used only for AI features."; the ElevenLabs key "The key stays in the macOS Keychain and is used only for transcription." (Windows: "…encrypted for your Windows account…").

Model row: name; "languages · size · licence"; third-party note with a Source link; state `Installed ✓` + Remove | progress % + Cancel | Download. Third-party models show a confirmation before download: "Download {name} from {host}? This model is not published by VoxClip. It downloads from the publisher ({size}) and runs on this {Mac/PC}. Licence: {licence}." [Download] [Cancel] [Open source page].

---

## 11. Keyboard shortcuts

### 11.1 Scope rule

Single-letter keys (J K L I O P C [ ]) and bare Space, ⌫ and arrows act on the editor only when keyboard focus is in the transcript, the viewer or the timeline **and** no inline correction field is open **and** no IME composition is in progress (`NSTextInputClient.hasMarkedText()` false; WinUI: focus is not a `TextBox`, `PasswordBox`, `AutoSuggestBox`, `RichEditBox` or `NumberBox`). In any text field they type text. Single-letter keys do not act in the sidebar list either, except [ and ]. A button, switch, segmented control or pop-up that has keyboard focus (Full Keyboard Access) keeps Space and the other bare keys for itself; on macOS the editor's bare-key menu commands are disabled for that key press. macOS implements them in the `NSTextView` subclass's `keyDown` and in `.onKeyPress` on the viewer and timeline; Windows uses `KeyboardAccelerator`s scoped with `ScopeOwner` to the editor root plus a focus check.

On Windows avoid **Ctrl+Alt+letter** (AltGr on many layouts types characters). Use Ctrl+Shift.

**Mac command field (V11b).** The right title row and Home have “Search or run a command ⌘K”. It opens an in-window combo box and a scrollable list of enabled native menu commands with their menu paths and key hints. Filtering matches words in the title, path or shortcut. Validation never runs a command; Return revalidates and runs the selection after restoring the original responder, and Esc closes and restores focus. Palette choices validate and run as explicit menu choices even while Return or ⌘K is the current event; bare Explorer keys retain their focus rules outside the palette. Repeating ⌘K, clicking the launcher or choosing Help › Keyboard Shortcuts refocuses an open field and keeps its query. Moving focus or clicking outside closes it without restoring the old focus. VoiceOver hears a debounced results count and the selected command on arrow moves; the field links to the results table. Help › Keyboard Shortcuts opens this field; the former Shortcuts sheet is removed. The Welcome Tour remains a sheet for now. In a Versions window commands belong to that window. With the right column hidden, ⌘K remains available from the keyboard and View menu.

**Mac monthly spend and sign-in (V11b).** When Voice Lab is on, the status bar and harness picker show the ElevenLabs estimate from the local ledger for **this month**, including the count of unpriced actions. It refreshes when Voice Lab work finishes, the app becomes active, the date changes, or the picker opens. It is an estimate, not a provider invoice. Home uses the same harness picker before a project is open. For a signed-out Claude Code or Codex it contains instructions, **Sign In…**, **Check Sign-In**, and the result in place. Sign In opens Terminal with the catalogue's existing sign-in command (`claude` or `codex login`); it makes no model request. The Home sign-in alert is removed. Home shows the picker row only while the selected CLI is signed out or has a result to show; the first-run hero retains no callouts. Returning from Sign In checks once. A ready result hides the sign-in actions immediately, clears on the following activation, and triggers no further probe. Announcements occur only when the result changes.

**Mac timeline EXPORTS (V11b).** The bottom panel has TIMELINE and EXPORTS tabs. EXPORTS reuses the Explorer's `ExportsListModel`, 40 pt two-line rows, metadata and actions (Show in Finder, Open, Export again, Retry). Empty copy: “No exports yet. Export a clip or the full edit to see it here.” Selecting EXPORTS hides the timeline transport; Hide Timeline still works. It adds no sheet.

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
| Show / hide cuts | ⌥⌘C | Ctrl+Shift+H | macOS: View › Show Cuts, the tab row's toggle, or the timeline's Edited / Source (one switch for both views); Windows: Show/Hide Cut Words |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G | Ctrl+F / F3 / Shift+F3 | "Cut all N" in the find bar |
| Search or run a command (Mac) | ⌘K | — | In-window field and menu results; Return runs, Esc closes |
| Make clip from selection | ⌥⌘K | Ctrl+K | Also the selection bar's default |
| Find clips | ⇧⌘K | Ctrl+Shift+K | Opens the Find Clips popover or flyout |
| Rewrite the scope | ⇧⌘R | Ctrl+R | The selection, else the selected clip, else Full take (§6.3). Needs no Voice Lab |
| Stop a running Rewrite | ⌘. or Esc | Esc | Also the panel's **Stop** |
| Close the Rewrite panel | Esc, when nothing runs | Esc | Focus returns to the scope's first word |
| Rewrite panel's primary action | ⌘Return anywhere in the panel; plain Return only when focus is on a footer button or plain panel text, never on a change or phrase row, a checkbox or a text field | Ctrl+Enter in the panel | Return on a focused change row edits it (next row) |
| Edit a proposed change | Return on a focused change or change row | Enter or F2 | Click also opens it (§6.3.5). macOS (v2): F2 too, and Return on a selection inside a change or over several changes; Return on a selection outside every change still corrects spelling. The change and its popover scroll into view |
| Keep / undo the focused change | ⌘Return / ⌘⌫ in the transcript (macOS v2) | Ctrl+Enter / Ctrl+Backspace (proposed) | Undo leaves it out; it never changes the project (§6.3.5) |
| Next / previous change | ⌥↓ / ⌥↑ in the transcript (macOS v2) | Alt+Down / Alt+Up (proposed) | Reads "Proposed change {i} of {c}: …". A selection outside the change it moves to is let go, so Return edits the change |
| Include or exclude a change | Space on its row | Space | |
| Compare takes | Space plays the focused phrase; ← → switch its take | Space; ← → | |
| Write a Rewrite instruction | Click the field, or ⌃F6 to the scope bar, then Tab | Click, or F6, then Tab | |
| Keep / dismiss suggestion | Return / ⌫ on the focused suggestion row | Ctrl+Enter / Delete on the focused row | Plain Enter on Windows selects and previews |
| Rename clip | Return on a focused kept clip row | F2 | |
| Remove clip | ⌫ on a focused kept clip row | Delete | One undo step |
| Set clip start / end at caret | I / O | I / O | |
| Previous / next clip | [ / ] | [ / ] | Kept clips, transcript order |
| Back to Full take | Esc (transcript, nothing else open) | Esc | Replaces "Preview clip / back to full take" |
| Home / Full take | ⌘1 / ⌘2 | Ctrl+1 / Ctrl+2 (Alt+Left also selects Home) | Replaces "Inspector tabs" |
| Show / hide viewer | ⌥⌘I | Ctrl+Shift+I | Replaces "Toggle inspector" |
| Show / hide sidebar | ⌃⌘S | — (TitleBar pane toggle) | |
| Show / hide timeline | ⌘J | Ctrl+J (planned) | The v2 bottom panel. It stays while the right column is hidden, until the viewer has its hover transport |
| Selection bar focus | Tab or ⌃F6 | Shift+F10 or Menu key | |
| Move focus to the next pane | ⌃F6 | F6 (Shift+F6 goes back) | Order in §15 |
| Timeline zoom / transcript text size | ⌘= / ⌘− (⌘+ also increases) | Ctrl+= / Ctrl+− / Ctrl+0 | Mac: both directions zoom the timeline when it has focus, and resize transcript text elsewhere. One visible View item per direction follows that focus. ⌘0 resets transcript text in the key editor, including Versions windows. The timeline toolbar exposes the single adjustable “Timeline zoom” slider; the canvas exposes playhead and edge controls. |
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
- **Edit:** Undo, Redo, Cut, Copy, Paste, Select All, Cut Selection, Restore Selection, Correct Word, Rewrite {scope} (⇧⌘R; the title follows the scope: "Rewrite Selection", "Rewrite Clip {n}" or "Rewrite Full Take", and gains "…" when the send asks first; §6.3), Type New Words…, Copy Text, Find…, Find Next, Find Previous, Cut Fillers, Tighten Pauses, Restore All Cuts, Transcribe Again…; Insert Words… (Voice Lab on; hidden until Core can place an insertion, §6.3); M2: Tighten with AI…, Clean Audio…; M3: Change Voice….
- **View:** Show Cuts (⌥⌘C, a checkmark item; it works in a Versions window too), Show/Hide Pauses, Show/Hide Viewer (⌥⌘I), Home (⌘1), Full Take (⌘2), Show/Hide Sidebar (⌃⌘S), Show/Hide Timeline (⌘J), Frame (9:16 · 1:1 · 16:9 · Original, a checkmark on the project's frame), Bigger/Smaller/Actual Size, Enter Full Screen. Each Show/Hide title describes the current action.
- **Playback:** Play/Pause, Play from Selection, Preview Cut, Back 3 Seconds (J), Forward 3 Seconds, Shuttle Back/Stop/Forward, Go to Start/End.
- **Clip:** Make Clip from Selection (⌥⌘K), Find Clips… (⇧⌘K), Cancel Finding Clips (⌘., only while finding), Keep Suggestion, Dismiss Suggestion, Keep All Suggestions, Rename Clip…, Remove Clip, Set Start (I), Set End (O), Previous Clip ([), Next Clip (]), Export Clip….
- **Window:** standard items, plus "VoxClip" (brings back the main window).
- **Help:** Keyboard Shortcuts opens the same command field; Welcome Tour, What Leaves This Mac, Reveal Logs, Copy Diagnostics.

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
| Clips: no connector | callout under the sidebar actions | "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI." [Set Up AI…], plus "You can also select words and press ⌥⌘K to make a clip yourself." (Windows: Ctrl+K) |
| Clips: CLI not found | callout under the sidebar actions | "{Claude Code/Codex} isn't installed. {installHint}" (hint from the catalogue) |
| Clips: CLI not signed in | callout under the sidebar actions | "{cli} isn't signed in. {signInHint}" [Sign-in help] |
| Clips: Apple model locale | callout under the sidebar actions | "Apple's on-device model doesn't support {language}. Use an API key, a CLI or a local model for this project." |
| Clips: local server down | callout under the sidebar actions | "Ollama isn't running at {url}. Start Ollama and try again." / "LM Studio's server isn't running at {url}. Start it from LM Studio's Developer tab." |
| Clips: Custom with no text | Find Clips popover or flyout | the prompt file's `messages` text (VoxConvo: "Describe the clips you want.") |
| Clips: finding | sidebar, under Suggested | "Finding clips…" [Cancel], with "{connector} · reading {m:ss} of transcript". Announce "Finding clips", then "Found 1 clip." or "Found {n} clips."; when none are found, announce the "Clips: none found" message |
| Clips: none found | sidebar, under Suggested | the prompt file's `messages` text (VoxConvo: "No clips matched. Try another style or describe what you want.") [Find Clips…] |
| Clips: any other AI failure | callout under the sidebar actions | the AI spec section 5 message for the error, followed by "Your edits are saved." [Retry] |
| Project with no clips | sidebar, under Full take | "No clips yet. Select words and press ⌥⌘K." (Windows: Ctrl+K), 11 `text.secondary` |
| Clip already exists | announcement, selection bar tooltip | "Clip {k} already covers these words." |
| Clip made / kept / dismissed / removed | announcement | "Clip {k} made." / "Clip {k} kept." / "Suggestion dismissed." / "Clip {k} removed." |
| Everything cut | Editor, Export | Export disabled; status "Keep at least one word before exporting." |
| Suggestion selected, Export pressed | Export tooltip | "Keep this clip to export it." |
| Edit summary | toolbar subtitle / command row | §3.5 grammar: "{edited} after cuts · {n} cuts", "Clip {k} · {edited} after cuts · {n} cuts", "Clip {k} · {edited} · No cuts yet" |
| Export progress | Mac Export job / Windows dialog; Explorer row | job/dialog: "Rendering {i} of {n} · {p}% · about {t} left" [Cancel]; row: "Exporting {p}%" with a ring. Announce "Exporting {n} video(s)", then "Rendering {i} of {n} · {p}%" at 25, 50 and 75% |
| Export done | Mac Export job / Windows dialog | Mac: "Exported" + file name, Show in Finder and Done; sharing is optional and collapsed by default. Windows: "Saved {n} video(s) to {folder}" + share buttons. Announce the saved result with the folder's name; Copy caption announces "Caption copied." |
| Export failure | Mac Export job / Windows dialog; Explorer row | job/dialog: "Export stopped: {reason}. Your edits are saved." [Try again]; row: "⚠ Export failed" [Retry]. Announce the inline error; a cancelled export is silent |
| Export destination conflict | Export failure reason | "A file named {name} appeared in the export folder. Export again to replace it, or choose another name." Never silently replace a file which appeared or changed after the export was approved. |
| Exported, then edited | sidebar row, second line | "⚠ Edited since export" in `status.warning` |
| No encoder (Windows) | Export | "No H.264 encoder is available on this PC. Install the Media Feature Pack or update your graphics driver." (Error) |
| HDR source (Windows) | Export | "This video is HDR. Colours are converted to standard range and may look flatter." (Informational) |
| Disk full | Export, download | "There isn't enough free space on {volume}. Free up {size} and try again." When the size needed is unknown: "There isn't enough free space on {volume}. Free up space and try again." |
| Caption copied | Export | "Caption copied." (transient, 2 s) |
| Update available (macOS) | Home callout, app menu | "VoxClip {version} is available." [Download] |
| Update ready (Windows) | InfoBar | "VoxClip {version} is ready. Restart to update." [Restart now]; during transcription, clip search or export the button is disabled with "Finish the current task first." |
| Up to date | manual check | "VoxClip {version} is the latest version." |
| Update check offline | manual check | "Couldn't check for updates. You're offline." |
| Post failure (M2) | Mac Export job / Windows dialog | "Saved to {folder}. Posting to VoxConvo failed: {reason}." [Try again] (render reused, never auto-retried) |
| Camera or mic denied (M2) | Record view | "Camera access is off. Turn it on in System Settings → Privacy & Security → Camera." [Open Settings] |
| Unsaved changes | — | Projects autosave. macOS: an untitled project (never saved under a name) gets the system keep/delete prompt on close; named projects close silently. Windows: projects always have a file (architecture.md §2.6), so closing never prompts. |
| Project can't be saved (Windows: leaving, closing or quitting) | Editor InfoBar (Error); navigation stays put | "Couldn't save this project. Your edits are still open. Check the folder or use Save project as…, then try again." (macOS shows the system save error) |
| Transcribe again | Mac v2 inline buffer; Windows confirmation until ported | "Transcribe again? This replaces the transcript and removes {n} cuts, {m} corrections, {k} clips and the AI suggestions." [Transcribe Again] [Cancel] |
| ElevenLabs first upload | Mac v2 inline buffer; Windows ContentDialog until ported | Mac: “Uploads this video's audio to ElevenLabs with your key.” Privacy detail and [Upload and Transcribe · ≈ $X] [Not now]; every run asks. Windows retains “Transcribe with ElevenLabs?” and [Continue] [Cancel] (transcription.md §8.5) |
| Project saved outside the video folder (Windows) | InfoBar (Informational) | "Saved in VoxClip's folder. Use Save project as… to keep it with the video." |
| Rewrite: scope bar | scope bar | Field placeholders: "What should change in clip {n}?" (a suggested clip the same), "What should change in this video?" (Full take), "What should change in these words?" (a selection). Suggestions: Fix mistakes · Make it clearer · Make it shorter · Fix grammar and punctuation only · Recent: "{text}" (instructions in §6.3.1). Verb **Rewrite**, or **Rewrite…** when the send asks first. Status instead of the verb: "Rewriting…", "Finding clips…", "Tightening…". With no connector the picker reads "Choose AI" |
| Rewrite: menu titles | Edit menu, ⋯, sidebar and selection menus | Edit > "Rewrite Selection", "Rewrite Clip {n}" or "Rewrite Full Take", with "…" when the send asks first; the kept clip's menu "Rewrite Clip {n}"; the transcript menu "Rewrite", "Type New Words…" and "Insert Words…". Windows: "Rewrite selection", "Rewrite clip {n}", "Rewrite full take", "Type new words…", "Insert words…" |
| Rewrite: send again over edits | Rewrite job footer, inline | "Discard these {c} changes?" [Keep Working] [Discard Changes] |
| Rewrite: AI picker | AI menu | Header "Used for Rewrite, Find Clips and Tighten with AI." Groups "Installed apps · your own sign-in", "On this {Mac/PC}", "Your API key". Trailing billing: "{model} · no extra cost", "{model} · billed to its API key", "Not signed in", "{model} · free", "on {host} · free", "Not running", "free · English", "asks before each send", "Add Key…". Then "Model" and "AI Settings…" |
| Rewrite: panel header and context line | Rewrite panel | Titles "Rewrite clip {n}", "Rewrite {w} words", "Rewrite full take"; in voice steps "Your voice" with "Step {i} of 3" ("Step {i} of 4" with a read-aloud), "Beta" and "Back to rewrite". Context line "{AI} · {model} · no extra cost", "{AI} · {model} · billed to your key" or "{AI} · {model} · answered in {t} s". Other scopes substitute their words (§6.3) |
| Rewrite: no AI chosen | Rewrite panel, R0 | "Who should rewrite clip {n}?" Rows: "Claude Code (installed CLI)" with "Signed in · Claude plan · no extra cost", "Signed in · billed to the API key Claude Code uses" or "Not signed in. Run `claude` in Terminal and sign in."; "Codex (installed CLI)" with "Signed in · ChatGPT plan · no extra cost" or "Not signed in. Run `codex login` in Terminal."; "Ollama" with "{model} on this {Mac/PC} · free" or, on macOS v2, "Ollama isn't answering at {url}. Start it, then choose Check Again."; "Apple on-device" with "free · English"; "Anthropic" with "your API key · asks before each send", and with no key the field "Paste your Anthropic API key" [Save Key]. Note "Change it any time from the menu above the transcript." [Check Again] [Use {name}] |
| Rewrite: no AI set up | Rewrite panel, R0 | "No AI is set up yet" / "Rewrite needs an AI: an installed Claude Code or Codex, a local model, Apple on-device, or an API key." [AI Settings…] [Check Again] |
| Rewrite: a send that asks first | inline approval row, R0b (Mac v2) | “Rewrite sends the {w} words of clip {n} to {provider} with your key.” “No audio or video. {model}. Asks before each send.” [Send] [Cancel]. First use: [Allow and Send], with the privacy detail. “VoxClip can't tell what this costs. Check {provider}'s pricing.” links to pricing. No invented price. |
| Rewrite: running | Rewrite panel, R1 | Quote "Asked: **Fix mistakes**, fix slips and repeats, keep my words, change as little as possible." or "Asked: “{instruction}”". Headline "Rewriting clip {n}…" with the elapsed time and [Stop]. Steps "Read clip {n}" · "{w} words · {m:ss}"; "Sent to {AI}" · "Text only. No audio or video." (a loopback server or Apple: "Running on this {Mac/PC}" · "Nothing leaves it."); "Waiting for {AI}…" · "Changes appear in the transcript when it answers."; "Check that each change fits". Announce "Rewriting clip {n}". Stop is silent |
| Rewrite: send line | Rewrite panel footer | A CLI on a plan: "Sends the {w} words of clip {n} to {CLI} with your sign-in. Counts toward your {Claude plan \| ChatGPT plan}." A CLI on an API key: "Sends the {w} words of clip {n} to {CLI}, billed to the API key it is signed in with." An API key: "Sends the {w} words of clip {n} to {provider} with your key." A loopback server or Apple: "Runs on this {Mac/PC}. Nothing leaves it." A remote local server: "Sends the {w} words of clip {n} to {host}." |
| Rewrite: couldn't rewrite | Rewrite panel, R1x | "Couldn't rewrite clip {n}", then the AI spec section 5 message and "Your edits are saved." [Try Again] ([Try Again…] when the send asks first). Signed out: "{CLI} isn't signed in. Run `claude` (or `codex login`) in Terminal and sign in, then choose Try Again." No key: the field "{provider} API key" [Save Key and Try Again]. Not running on macOS v2: "{server} isn't answering at {url}. Start it, then choose Try Again." Windows: "Ollama isn't running. Start it, then choose Try Again." Refused: "The model declined to rewrite this recording." [Ask for Something Else] |
| Rewrite: too large | Rewrite panel, R1x | "{Full take \| Clip {n}} is too long to rewrite at once" / over 3,000 words: "Rewrite works on up to 3,000 words at a time. This {video \| clip} has {n}. Choose a clip or select a passage."; over 20,000 bytes of text: "This {video \| clip} has more text than Rewrite can send at once. Choose a clip or select a passage." [Find Clips] on Full take |
| Rewrite: proposal | Rewrite panel, R2 | Context line "{AI} · {model} · answered in {t} s". Headline "{c} changes" ("1 change"), sub-line "{x} cuts · {y} fixes · {z} phrases in your voice". Announce "{c} changes proposed. {z} need your voice." |
| Rewrite: change rows | Rewrite panel, R2 | Voice: "“{new words}”" / "Your voice · replaces “{removed words}”", or "Your voice · new words". Fix: "{Commas \| Spelling \| Capitals \| Punctuation} in “{text}”" / "Fix · text only, free". Cut: "Cut “{removed words}”" / "Cut · free". `checkThis` (Warning): "Check this: it adds something you didn't say." Colliding, no checkbox: "Too close to the change before it to voice separately. Edit them together or leave one out." Voice Lab off, no checkbox (Warning): "Needs Voice Lab (beta)". Uncalibrated language, no checkbox (Warning): "Your voice works in English projects only for now." A row refused by placement shows its refusal copy below |
| Rewrite: meta, voice row and hint | Rewrite panel, R2 | "AI voice: {v} of {limit} words · about {s} s", with "Takes ≈ ${x}". "Your voice is ready" · "{name} · made {date}", plus " from clip {n}"; with several voices, the pop-up "Voice: {name}". Hint, once per app run: "Click a change in the transcript to edit it. Nothing is paid for yet." |
| Rewrite: proposal footers | Rewrite panel, R2 | No voice yet: "Next: make your voice from this clip. Once." [Apply free changes only] [Make Your Voice]. Before a price (voices not yet found, or no current quote): [Get Price], which finds the voices and prices the set and sends nothing. Voice ready: "Sends the {z} new phrases and a short audio check to ElevenLabs with your key. No video." [Apply free changes only] [Make Takes · ≈ ${x}] or [Make Takes…]. Voice Lab off: "{z} phrases need your voice. Voice Lab (beta) makes it from this clip." [Turn On Voice Lab…] [Apply {k} Free Changes]. Over the voice budget (Warning, advisory): "These changes re-voice {v} words, a lot for a {n}-word {clip \| video}. Long stretches in your voice can sound stitched." [Re-voice all {v}] [Change fewer words] [✦ …] [Keep text fixes only] and the note "Nothing paid yet. Make Takes appears once you choose.". Cuts and fixes only: "No AI voice needed. Nothing is sent." [Apply {c} Changes]. Nothing included: "Check a change to apply it." No changes: "No changes needed" / "{AI} found nothing to change in clip {n}." [Ask for Something Else] |
| Rewrite: applied | announcement; Edit > Undo | "Applied {c} changes". The undo step is "Rewrite clip {n}" ("Rewrite {w} words", "Rewrite full take") |
| Rewrite: scope changed | Rewrite panel, R3 | "Clip {n} changed" / "You edited clip {n}, so these changes may no longer fit. Nothing was applied, and no takes were paid for." With takes it adds "Your takes are kept until you close this." [Close] [Rewrite Again] |
| Rewrite: edit popover | transcript, under a change | "New words for change {i}", the field, the fit meter line ("about {s} s for a {g} s gap: fits" or "about {s} s for a {g} s gap: will change length"), "Return saves · Esc cancels" [Reject Change] |
| Rewrite: no speech rate | edit popover; change row | "There isn't enough timed speech to estimate this change. Your edits are saved." The fit meter and the amount are hidden |
| Rewrite: too close to the take edge | Rewrite panel, change row (no checkbox) | "Too close to the {start/end} of the take to blend in. Re-record this sentence instead." |
| Rewrite: no room tone | Rewrite panel, change row (no checkbox) | "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in. Clean audio is not available in this build. Re-record this sentence instead." [Clean Audio…] replaces the last two sentences once Clean audio (M2) ships |
| Rewrite: can't place | Rewrite panel, change row (no checkbox) | "This change can't be placed in this take. Your edits are saved." |
| Rewrite: video missing | Rewrite panel | "Find the original video before rewriting speech. Your edits are saved." [Locate…] |
| Rewrite: insertion not available | Rewrite panel | Insert Words… stays hidden while Core cannot place an insertion. Development builds that open it show "Inserting words isn't available yet. Your edits are saved." |
| Rewrite: Voice Lab off | Rewrite panel, R2 link | [Turn On Voice Lab…] opens the voice-lab.md §5 one-time sheet |
| Rewrite: disclosure | Rewrite footer, T3 | "Exports show AI MODIFIED on the video and in the post." |
| Your voice: no ElevenLabs key | Rewrite panel, V0 | "Add your ElevenLabs key" / "Your voice is made and spoken by ElevenLabs, with your own key. Create a key just for VoxClip with a monthly credit limit." Field "ElevenLabs API key". [Make a restricted key] [Save Key]. Note, macOS: "Saved in the macOS Keychain and used only by VoxClip for Voice Lab. Never passed to Claude Code, Codex or any other AI app. Saving makes no request." Windows: "Saved for your Windows account and used only by VoxClip for Voice Lab. Never passed to Claude Code, Codex or any other AI app. Saving makes no request." |
| Your voice: agree | Rewrite panel, V1 | "Make your voice from this clip" / "Your new words are spoken in your own voice. You do this once." Then the voice-lab.md §2.5 provider copy (first time only) and the §6.1 notice [Terms] [Use policy]. Checkboxes "This is my own voice." · "I am 18 or older." · "I will use it only on videos of myself." Field "Your name, as you'll say it", error "Use 1 to 60 characters, with no line breaks." Unticked: "Tick all three to continue." Note "Checks your ElevenLabs plan. Free; no audio is sent." [Continue] |
| Your voice: speech found | Rewrite panel, V1 | Running: "Finding your clear speech in this video…". Found: "{t} of your clear speech found" with "{c} from clip {n}, the rest from this video. Picked on this {Mac/PC}. English only for now.", "All from clip {n}.", "From the rest of this video; clip {n} has none clear enough." or "From this video." without `preferRange` (Full take, or a selection outside every clip). Clip {n} is the clip that set `preferRange` (§6.3.7) |
| Your voice: a read-aloud instead | Rewrite panel, V1 callout | "This video has only {n} s of your clear speech, so you'll read a short passage instead." With none: "This video has no clear speech to use, so you'll read a short passage instead." Unreadable: "VoxClip can't read this video's audio, so you'll read a short passage instead." Labelled: "This video is labelled AI modified, so it can't train your voice. You'll read a short passage instead." |
| Your voice: unmet requirements | Rewrite panel, V1 | "Download the own-voice check (27 MB)" · "Runs on this {Mac/PC}. Licence CC BY 4.0." [Download], then "Downloading… {p}%" [Cancel]. "Instant voice cloning needs an ElevenLabs Starter plan or higher." or "Your ElevenLabs account has no free voice slots." [Open ElevenLabs] |
| Your voice: Windows before speaker-check parity | Rewrite panel, V1 (Informational) | "Making a voice isn't available on Windows yet: the on-device check that it's your voice isn't ready. Your free changes still work." [Apply {k} Free Changes] |
| Your voice: read the statement | Rewrite panel, V2 | "You agreed: my own voice · 18 or older · only my videos" [Change]. "Read this aloud, in one take", the statement, [Record], then "Recording {m:ss}" [Stop]. Note "Stop after the last word (5 to 30 s). Nothing leaves this {Mac/PC} until you choose Create My Voice." With VoiceOver or Narrator running: "Using a screen reader? Wear headphones so it isn't recorded." Windows announces "Recording. Read the statement aloud." before capture starts, announces nothing during the take, and shows "Microphone: {device name}" (display only, never logged) |
| Your voice: statement length | Rewrite panel, V2 (Warning) | "That was under 5 seconds. Read the whole statement, then stop." / "Recording stopped at 30 seconds. Read a little faster and record again." |
| Your voice: microphone permission | Rewrite panel, V2 (Warning) | "VoxClip needs the microphone to record your statement." [Open Privacy Settings] (Windows: [Open Microphone Settings]) |
| Voice Lab: no microphone (Windows) | Rewrite panel, V2 (Warning) | "No microphone found. Connect one and try again." |
| Voice Lab: microphone unavailable | Rewrite panel, V2 (Warning) | "The microphone isn't available. Check your input device and try again." |
| Voice Lab: microphone lost | Rewrite panel, V2 (Warning) | "The microphone stopped sending audio. This take was discarded. Check your input device and record again." |
| Voice Lab: silent microphone | Rewrite panel, V2 (Warning) | macOS: "The microphone sent only silence. Check that it isn't muted, and that System Settings → Privacy & Security → Microphone allows VoxClip." Windows: "The microphone sent only silence. Check that it isn't muted, and that Settings → Privacy & security → Microphone lets desktop apps use it." [Open Settings] |
| Voice Lab: waiting for the microphone (Windows) | Rewrite panel, V2 | "Waiting for the microphone…" after 1 s, informational, with Cancel enabled and no timeout |
| Voice Lab: leaving while recording (Windows) | dialog | "Stop creating your voice? The recording is deleted from this PC." [Stop] [Keep going]; Keep going is the default and Esc keeps going |
| Your voice: checking it's you | Rewrite panel, V3 | "Checking it's you…" / "Comparing {k} stretches of this video with your statement. On this {Mac/PC}; nothing is sent." / "{i} of {k} · about {s} s left" |
| Your voice: speaker mismatch | Rewrite panel, V3 (Warning) | "Some of this video's audio doesn't sound like the voice in your consent statement. Record a read-aloud instead." Row "Statement recorded and kept" · "You won't need to read it again." [Record a Read-Aloud]. Note "Nothing was sent. The check ran on this {Mac/PC}." |
| Your voice: read-aloud | Rewrite panel, V3, Step 3 of 4 | "Read this aloud, about 90 s", the script and the recorder (60 to 120 s). Below the 10 s floor (Warning): "Some of these recordings don't sound like the voice in your consent statement." [Record a Read-Aloud] |
| Your voice: ready to create | Rewrite panel, V4 | "Ready to create your voice" / "It's you" · "{m} of this video matches your statement." (a read-aloud: "Your read-aloud matches your statement.") / "Checks your plan, then sends your statement and {m} of your speech to ElevenLabs to create your voice. No video is sent." [Create My Voice · < $0.01] |
| Your voice: creating | Rewrite panel, V5 | "Creating your voice…" Steps "Statement recorded" · "{m:ss} · kept on this {Mac/PC}"; "It's you" · "{m} matches your statement, checked on this {Mac/PC}. {d} short stretches didn't match and were left out."; "Statement read correctly" · "Checked by ElevenLabs"; "Creating “{name} (VoxClip)” in your ElevenLabs account"; "Back to clip {n}" · "{z} phrases to voice". Note "Sending your statement and {m} of your speech to ElevenLabs with your key. No video. < $0.01" |
| Your voice: statement doesn't match | Rewrite panel, V5, then V2 | "That didn't match the statement. Read it again, clearly, in one take." After three tries in 10 minutes: "That's three tries in 10 minutes. Try again at {time}." |
| Your voice: verification required | Rewrite panel, V5 | "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back." [Open elevenlabs.io] [Check Again] |
| Your voice: ready | announcement, V6 | "Your voice is ready." |
| Takes: not the voice owner | Rewrite panel, T1 (Error) | "This doesn't sound like the voice owner. Voice Lab is only for your own videos." Note "Checked on this {Mac/PC} against 10 s of speech near each change. Nothing was sent or charged." [Apply {k} Free Changes] |
| Takes: generating | Rewrite panel, T2 | "Making takes… phrase {i} of {z}" [Stop]. Announce "Phrase {i} fits." |
| Takes: ready | Rewrite panel, T3 | "Voice: {name} · made {date}", plus " from clip {n}". "{z} phrases in your voice" / "Listen, pick a take, then use them." Rows "Take {k} · {d} s · fits" or "Take {k} · {d} s · pauses +{x} s", "Best match", [Try Another · {amount}] or [Try Another…] (§6.3.8). [Play Clip {n} with New Voice]. "Made {t} takes · ≈ ${x} on your ElevenLabs account." [Use Takes] |
| Takes: no take passed | Rewrite panel, T3 row | "These takes didn't sound right. Edit the words or try again." [Try Again · {amount}] or [Try Again…] (§6.3.8) [Edit Words]. The row says "Left out until a take fits.", and the primary reads "Use {z−1} Takes" |
| Takes: duration not chosen | Rewrite panel, T3 footer | Selected takes stay unusable until each passage has a video duration: "Choose the video duration for phrase {n}." ("phrases {a} and {b}", "phrases {a}, {b} and {c}"), then the spend line; "Preparing the matched video…" while a Match video choice is prepared, or that preparation's failure copy. "Left out until a take fits." is reserved for a phrase with no passing take. No choice is preselected (ADR-R36) |
| Takes: length changed | Rewrite panel, T3 row | "Take {k} runs {s} s longer than the words it replaces. Shorten the words or try another take." For a shorter take: "Take {k} runs {s} s shorter than the words it replaces. Edit the words or try another take." |
| Takes: lip sync | sheet, once rendering lands | "Lip sync this change?" / "This will cost about ${x} on your {provider} account." / "Sends {s} s of video around the change to {provider} with your key." [Cancel] [Continue] |
| Takes: provider error | Rewrite panel (Error) | "ElevenLabs rejected the key (401). Your edits are saved." ({provider} and {status} vary), with a key field [Save Key] [Retry] |
| Takes: unused paid takes | sheet, on close | "Discard {t} takes?" / "You paid about ${x} for them. Your edits are saved." [Keep Working] [Discard Takes] |
| Takes: used | toast (6 s) and announcement | "Clip {n} rewritten: {z} phrases in your voice, {x} cuts, {y} fix." [Undo]. The sidebar meta then reads "AI modified", and Export's accessible name adds ", contains AI-modified speech" |
| Voice Lab: My voices | Settings → Voice Lab | "Made {date} · consent {date} · English" [Delete Voice…] [Remove from VoxClip Only]. Empty: "No voice yet. You make it from a clip the first time a rewrite needs your voice." |

---

## 14. Appearance and materials

- **Light and dark** follow the system. Dark is the hero look for screenshots. The video stage stays black in both and in High Contrast, and so do caption cards (§5.4).
- **macOS Liquid Glass is chrome only:** the sidebar, toolbar, sheets, menus and popovers (system), plus one custom glass element, the transcript selection bar (§4.3). Content surfaces are opaque tokens (`bg.surface` for the transcript, `stage` for video, `timeline.*` for the strip). Never glass on glass. Custom surfaces check `accessibilityReduceTransparency` and switch to opaque fills with `line.strong` borders; system glass handles Reduce Transparency and Increase Contrast itself. Tint glass only to convey meaning (only Export, and Import Video… on Home, are prominent).
- **Windows:** Mica on the main window and the Settings window, applied once. `LayerOnMicaBaseAltFillColorDefaultBrush` behind the CommandBar. Acrylic only for transient surfaces: menus, flyouts, the selection `CommandBarFlyout` and the Find Clips flyout. Cards and panes use theme `Layer*` / `Card*` brushes. `TitleBar` for chrome, `CommandBar` for grouped commands, `NavigationView` for the sidebar, `CommunityToolkit` `Segmented` for Frame and Edited/Source, `InfoBar` for status, `ContentDialog` for Export, `TeachingTip` for first-run hints.
- **Accent: Ink**, the icon tile's ink and paper. `accent.default` (`#2C2E35` light, `#6D6F73` dark) is the fill that carries text. Light is the icon tile's ink; dark is cool graphite because macOS draws white on the `AccentColor` asset and paper cannot carry white. `accent.text` (`#1A1B1F` light, `#ECEAE4` dark) is for marks, rings, links, clip badges and the playhead. In dark, everything the app paints for state (Export, playhead, brackets, focus and Windows accent fills) is paper, and the playing word is soft paper `#D2D1CC` with ink text. Links are underlined because `accent.text` equals `text.primary`.
  - **macOS:** the `AccentColor` asset (generated from `accent.default`, compiled into the bundle by `bundle.sh`) and `NSAccentColorName` make Ink the app accent, so standard controls draw the system's white on it. The dark switch, checkbox and sidebar selection are graphite, like the system Graphite accent. Users who chose a system accent colour see theirs on standard controls, which is correct. `DesignValues.accentText` uses `accent.text` only while the accent is the asset. A bare `swift run` has no asset, so DEBUG builds tint their SwiftUI roots with `accent.default`; AppKit focus rings and text selection stay system blue there, and accent evidence for those must come from a bundled app.
    - Every VoxClip accent mark is drawn from `DesignValues.accentText` or `Color.accentColor`, which is Ink when the system accent is Multicolor. Export and the playing word use their explicit token pairs below.
    - When the user picks another accent, `accentText` and `accentSoft` are derived at runtime: mix `NSColor.controlAccentColor` toward `text.primary` until it reaches 4.5:1 on `bg.surface`. For Blue in light mode that gives `accentText` #046CDD (4.76:1) and `accentSoft` #DCE7F7 (14% over the page).
    - Export is a painted capsule: light `accent.default` with `accent.on`, dark `accent.text` with `word.playingForeground` (15.19:1), matching the Windows `AccentButton` pair. One helper chooses the fill and label for both the button and `DebugToolbarPixels`. It does not use `.glassProminent` or follow a user-chosen system accent.
  - **Windows:** `App.xaml` overrides the accent ramp in its `Light` and `Default` theme dictionaries, so Ink replaces the user's accent. `SystemAccentColor` is cool graphite `#6D6F73` in both, so text selection and `SystemControlHighlightAccentBrush` never fall back to the user's accent. Light: `SystemAccentColorDark1/2/3` `#2C2E35` / `#1A1B1F` / `#0F1013`. Dark: `SystemAccentColorLight1/2/3` `#D2D1CC` / `#ECEAE4` / `#FAF9F6`. `TextOnAccentFillColorPrimary` is `#FAF9F6` / `#141517`, never pure black. High Contrast keeps the system colours. WinUI builds `TextOnAccentFillColorPrimaryBrush` from its own colour with `StaticResource`, so framework controls may keep `#FFFFFF` on Dark1 (13.55:1) / `#000000` on Light2 (17.46:1).
    - The transcript draws its own selection with `selection.transcript` (`text.primary` on it 9.55:1 light, 5.33:1 dark). Text boxes keep the system selection, which follows the graphite `SystemAccentColor` override. Every `HyperlinkButton` and inline link is underlined.
- **Accent budget:**
  - Ink solids per screen are at most four: Export, the playing word, the switch that is on, and the selected clip's badge. Home has one: Import Video….
  - System focus fills (the focused sidebar selection on macOS) do not count.
  - Clip identity uses neutral badges on `clip.badgeBackground` and `line.strong` rules. The gallery check is neutral. Toolbar glyphs are monochrome. Only the Home sidebar glyph keeps the system's accent tint.
  - Media stand-ins spend no Ink: their chips, progress lines, word rhythm and audiogram are neutral (§5.4). Near media, the only accent marks remain the selection ring and the playhead.
- **Colour rules:** one accent, Ink; red only for cuts and recording; amber only for warnings and suggestions; no pure black except the stage; no gradients on native surfaces.
- **High Contrast (Windows):** the `HighContrast` theme dictionary maps every token to its `windowsHighContrast` system colour (tokens.json). Strikethrough survives High Contrast, so cut state stays visible.

---

## 15. Accessibility

- **Screen readers.** The transcript is text (NSTextView / RichTextBlock), so VoiceOver and Narrator read it by word, line and paragraph. Each word's accessible description adds its state: "um, cut", "pause 1.4 seconds", "pause 1.6 seconds, cut", "cadence, playing", "it isn't a clip yet, AI modified". macOS: custom rotors (`accessibilityCustomRotors`) for Cuts, Pauses, Suggested fillers, Clips and AI words, plus Proposed changes while a Rewrite proposal is open (§6.3.5), and custom actions on the focused word (Cut, Restore, Correct, Play from here). Every command posts an announcement ("Cut 3 words", "Restored all cuts, corrections kept") via `NSAccessibility.post(element:notification: .announcementRequested, …)` or UIA `RaiseNotificationEvent`.
- **Timeline** is a slider: "Playhead, 42 seconds of 2 minutes 15 after cuts, 12 cuts" in Edited, or "Playhead, 42 seconds of 3 minutes 10 source, 12 cuts" in Source. Times are spoken whole seconds ("42 seconds", "1 minute 05", "2 minutes 15"), never `m:ss.d`. Arrow keys step by word.
- **Caption gallery** is a single-choice picker named "Caption style"; each option is named "{name}: {description}".
- **Keyboard.** The whole loop (import → cut → captions → clips → export → share) works without a pointer. Focus and F6 / ⌃F6 order: sidebar → toolbar or `CommandBar` → scope bar (§6.3.1) → transcript → viewer → Captions or Rewrite panel → timeline. On macOS the selection bar, while it shows, comes right after the transcript (§4.3). On Windows Shift+F6 goes back, from any focused descendant. On macOS, Full Keyboard Access reaches every control with Tab. Icon-only buttons have explicit names: Back 3 seconds, Play (Pause while playing; the Space shortcut goes in the tooltip, not the name), Forward 3 seconds, Close Rewrite, Stop rewriting, Back to rewrite, Play phrase 2, Keep suggested clip 5, Dismiss suggested clip 5, Hide Viewer. The Windows splitter is focusable: ← and → resize by 16 within 300–560, and Enter collapses or expands the column. It is named "Resize viewer". The macOS divider relies on View > Show/Hide Viewer and the `AXSplitter` increment and decrement actions. System focus rings / focus visuals; custom rings are 2 `focus.ring`, offset 2.
- **Sidebar and panel focus.** Choosing a sidebar row keeps focus on the row; Enter on Windows invokes it. F6 from the pane lands on the `CommandBar`. After Keep, Dismiss or Remove, focus moves to the next row, or to Full take. Starting a Rewrite keeps focus where it was and announces it. When the proposal arrives, focus moves to the first change row. Esc from the panel returns focus to the scope's first word, and after Apply or Use, focus moves to the first changed word (§6.3). Alt+Left from the editor selects Home. A recent project's accessible name is its visible title. A missing one adds ", video not found", and the other media states add theirs (§5.4.9).
- **Rewrite names** (VoiceOver label, or Narrator `AutomationProperties.Name`; §6.3):
  - **Scope bar:** the group "Clip 1 tools"; the label "Clip 1, 43 seconds"; the field "What should change in clip 1"; the button "Rewrite clip 1"; the picker "AI: Claude Code (installed CLI), Opus 5.5, ready", where "ready" becomes "asks before each send" or "not signed in".
  - **Sidebar:** the row button "Rewrite clip 1".
  - **Panel:** the heading "Rewrite clip 1", or "Your voice, step 2 of 3, beta"; "Close Rewrite", "Stop rewriting" and "Back to rewrite"; step rows "Done: Read clip 1, 118 words" and "In progress: Waiting for Claude Code", which update as they change (macOS `.updatesFrequently`, Windows `LiveSetting="Polite"`).
  - **Change rows:** a checkbox named "Change 1 of 6, your voice: ‘to, to the’ becomes ‘your source directory in the’. Included." Custom actions on macOS, or the context menu on Windows: "Edit words", "Show in transcript", "Play original".
  - **Transcript:** each proposed change's description, "Proposed change 1 of 6: removed to, to the; inserted your, in the". The focus mark is decorative.
  - **Voice steps:** "Statement to read: …"; "Record consent statement" and "Stop recording"; "Microphone level", with the value in dB; the strip, "Speech found: 1 minute 52 seconds, 38 seconds from clip 1", or "Speech found: 1 minute 52 seconds" without `preferRange`.
  - **Takes:** "Phrase 2 of 3, is an interesting way to. Take 2 of 3 selected, 1.4 seconds, best match"; the segmented control "Take for phrase 2"; "Play phrase 2"; "Try another take for phrase 2, about 2 cents", with that phrase's own estimate in words ("less than 1 cent" below $0.01; no amount when it confirms); "Play clip 1 with new voice"; "Use takes".
- **Rewrite announcements:** "Rewriting clip 1"; "6 changes proposed. 3 need your voice."; "Applied 3 changes"; "Clip 2 kept"; "Your voice is ready."; "Phrase 1 fits."; "Clip 1 rewritten: 3 phrases in your voice, 2 cuts, 1 fix."
- **Rewrite without a pointer** (macOS): ] selects clip 1 → ⇧⌘R → ↓ through the changes, Space to exclude, Return to edit → ⌘Return **Make Your Voice** → Tab through the three boxes, Space each → ⌘Return **Continue** → Space records, Space stops → ⌘Return **Create My Voice** → ⌘Return **Get Price** → ⌘Return **Make Takes · ≈ ${x}** → ↓ through the phrases, Space plays, ← → switch takes → ⌘Return **Use Takes**. On Windows the path is the same with Ctrl+R, Ctrl+Enter and F2.
- **Colour independence.** Cut = strike + dimming; timeline cuts = hatching; clips = brackets and numbers; fillers = dotted underline + tooltip. No state depends on red versus green. The selected clip is shown by an accent badge plus the row selection, and the selected Frame by a semibold label; suggestions by dashes and the Suggested header; AI words by the AI chip and a dashed underline; exported state by a glyph and a word. A proposed change's kind is a glyph plus a word, its inclusion a checkmark, and the focused change a shape, not only a tint (§6.3.5).
- **Contrast** (WCAG 2.x, Ink palette): every text pair is at least 4.5:1 and every UI boundary at least 3:1, in light and dark, on macOS and Windows, including on-accent text. `npm --prefix tools/design test` enforces this through `tools/design/contrast.mjs`, which prints the measured table and fails on any colour token that is neither checked nor exempted; see §16 for the values. Cut words stay at least 4.5:1 because they are still content, and pause-token text uses `text.muted`, struck through in `cut.stroke` when cut. Re-check when a surface token changes.
- **Motion.** Under Reduce Motion (macOS `accessibilityDisplayShouldReduceMotion`, Windows `UISettings.AnimationsEnabled`): sidebar selection jump-scrolls the transcript; the timeline zoom switches without animating; the selection bar and the Rewrite panel appear without slide or scale (a crossfade of 150 ms or less); indeterminate progress becomes the static text "Working…", and the scope bar's progress line is static; gallery tiles are static; the strike draw-in, the playing-word slide and the M2 countdown scaling are off. Media stand-ins drop their sheen, crossfade, moving dots and stage ring, and the word rhythm and audiogram page instead of scrolling (§5.4.9).
- **Reduced transparency.** Under Reduce Transparency or Increase Contrast (Windows: Transparency effects off or a contrast theme), the sidebar's custom parts and the selection bar become opaque `bg.elevated` with a 1 px `line.strong` edge. Media chips switch to their opaque tokens (§5.4.8).
- **Targets.** macOS controls are at least 24 pt in the sidebar, the selection bar and the scope bar, and 22 pt elsewhere; words get 2 pt vertical hit slop. Windows targets are at least 32×32 epx. The timeline track's whole 30 high band is the scrub target. Trim handles have 24 wide hit regions.
- **Text size.** Transcript zoom 13–28. Windows honours the system text-size setting through the Fluent type ramp.
- **Captions as accessibility.** `.srt` sidecar export; default styles are readable on any frame (the bold styles have a stroke).
- **Localization.** Strings in String Catalogs (`.xcstrings`) and `.resw`. Layouts tolerate 30% text growth and right-to-left languages. M1 ships English UI; Estonian UI may follow.

---

## 16. Design tokens

`shared/design/tokens.json` (format `voxclip-tokens/1`) is the only source of colours, type, spacing, radii, strokes, motion and fixed sizes. `tools/design` generates:

- `apps/macos/Sources/VoxClip/Design/Tokens.swift`: `extension Color { static let vcTextPrimary = Color(nsColor: NSColor(name: "vcTextPrimary") { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }) }`, plus `CGFloat` constants and `Font` helpers. A colour with an `increaseContrast` extension also matches the `accessibilityHighContrast` appearances and draws that value under Increase Contrast (`DesignValues.nsColor` reads tokens.json the same way). Typography helpers use the system font (`SF Mono` means its monospaced design); `fontFiles` adds file-URL loaders for the bundled DM Sans and Geist Mono, which only rendered video uses. `system:` values map to the named `NSColor`.
- `apps/windows/src/VoxClip.App/Themes/Tokens.xaml`: a `ResourceDictionary` with `ThemeDictionaries` keyed `Default` (dark), `Light` and `HighContrast` (from `windowsHighContrast`), `SolidColorBrush` per colour token named `Vc<Group><Name>Brush`, `x:Double` and `Thickness`/`CornerRadius` resources for dimensions. A dimension's `$value` is the macOS value; its `windows` extension replaces it here, for example the transcript gutter (84 on macOS, 76 on Windows).
- `apps/macos/Resources/Assets.xcassets/AccentColor.colorset`: `accent.default` (marked `macosAsset`), light for Any and dark for Dark, compiled by `bundle.sh`. The generator owns the catalog: `check` fails on any file there it does not produce.

Naming: token path `color.text.primary` → Swift `vcTextPrimary`, XAML `VcTextPrimaryBrush`. Generated files carry `GENERATED from shared/design/tokens.json - do not edit`. CI regenerates and fails on drift.

Contrast is a test, not a note: `npm --prefix tools/design test` computes WCAG 2.x contrast for every text-on-surface pair the apps draw (4.5:1), every text or glyph on the accent (4.5:1, including the macOS system white and the Windows `App.xaml` ramp, whose ten values are pinned) and every UI boundary and mark (3:1), in light and dark. It fails when a colour token is neither checked nor exempt with a reason, and when the text hierarchy stops falling from `text.primary` through `text.secondary` to `text.muted` and `text.tertiary` on any surface. System glass the apps never paint is approximated from the ADR-R29 mockups (`glass.sidebar` in `contrast.mjs`). A pair may name a token at an opacity (`ai.tint@0.16`). `npm --prefix tools/design run contrast` prints the table. Lowest pairs: text 4.51:1 (dark `text.secondary` on `clip.badgeBackground` over the sidebar glass), on-accent 4.65:1 (light `tint.on` on `tint.pressed`), boundaries 3.01:1 (light `tint.default` on `timeline.lane`); on Windows, on-accent 5.03:1 (white on `SystemAccentColor` `#6D6F73`).

Below a minimum on purpose (v2, impl-plan item 6). `gutter.text` (gutter timecodes in the open clip) is a recorded exception at 3:1 (dark 3.03:1 on `editor.band`), because the time repeats what VoiceOver reads from the paragraph. `line.edge` (v2 line2: input outlines, the timeline's top edge; dark 1.38:1 on `bg.surface`), `text.disabled` (t4: disabled labels, keyboard hints, leading zero groups), `gutter.textOut` and `fold.dot` are decorative or repeated and are not measured in the default appearance (`belowMinimum` in `contrast.mjs`, each with its reason). Each of these five carries an `increaseContrast` value, and under macOS Increase Contrast every one meets the full minimum of its kind: text 4.5:1, marks and boundaries 3:1. Windows uses its High Contrast theme instead. `line.strong` is never one of them: it is the 3:1 boundary in every appearance (dark 3.31:1 on `bg.surface`), because Reduce Transparency alone keeps the default appearance and the opaque edges it asks for are `line.strong`.

The palette is the Document direction from the October 2026 design study: paper and ink neutrals and one accent, Ink, the icon tile's ink. Each colour token's `source` extension names the study token its value comes from (for example `bg.elevated` is the study's raised), or the ADR-R29 mockup token. `line.subtle` was removed because the study has two separators. `text.disabled`, `record.*`, `overlay.scrim` and `overlay.transportOpaque` keep values the study does not define. `stage` stays `#000000` rather than the study's `#0B0B0C`, because letterboxed video wants true black (§14). It is also the caption card's backdrop (§5.4.3). Three values step away from their sources so every pair passes: `text.muted` sits between `text.secondary` and `text.tertiary` (the study's pause label was brighter than `text.secondary`), `word.cut` is one step past the study's cutText so cut words pass on `pause.background`, and the dark `clip.badgeBackground` is 9% rather than the ADR-R29 delta's 13% so badge numerals pass on the sidebar glass.

The v2 editor (October 2026, "a modern code editor, for video") re-values the dark neutrals and text to its palette and adds its own tokens; light values of the new tokens are provisional until the v2 light round. `bg.window` and `bg.sunken` are v2 chrome, `bg.surface` the editor, `bg.input` raised, `line.default` its hairline, the new `line.edge` its line2 (input outlines and the timeline's top edge) and `text.primary`, `.secondary`, `.tertiary` and `.disabled` its t1 to t4. Three greys are lifted to 4.5:1 where they are drawn: `text.tertiary` `#82858B` (v2 t3 `#717479`; 4.80:1 on chrome and 4.56:1 on the editor), `word.outside` `#878A90` (v2 out `#76797F`) and `word.gone` `#878A90` (v2 gone `#64676D`), both 4.54:1 on `editor.band`. The orange is `tint.*`, VoxClip's own tint: it marks the selection, the caret, the playhead and the one primary button per panel, always as an explicit tint. `accent.*` stays Ink, so the macOS `AccentColor` asset, the Windows accent ramp and every system control (switches, checkboxes, list selection, focus rings, default buttons) stay neutral. Exactly three hues carry meaning: `tint` (orange), `ai.tint` (blue, words spoken by your AI voice) and `change.add` (green, a proposed change not yet kept). No red.

ADR-R29 adds `clip.badgeBackground`, `timeline.keptBackground`, `timeline.scopeDim` and `selection.transcript`, and retunes `timeline.waveform`. `timeline.clipBracket` marks the selected clip only; unselected brackets use `line.strong`. `timeline.clipBand`, `size.inspector`, `size.welcomeWindow`, `size.transportPillHeight`, `size.footerStatusHeightWindows` and `size.breakpointThreeColumn` are deprecated and removed with the old layout. The generator already leaves them out of `Tokens.swift`; tokens.json and `Tokens.xaml` still carry them.

The media stand-ins (§5.4) add `chip.mediaBackground`, `chip.mediaStroke`, `chip.mediaBackgroundOpaque`, `chip.mediaForeground` and `chip.warningGlyph` (§5.4.8). They have one value in both themes because they sit on media. They join tokens.json, with their pairs in `tools/design/contrast.mjs`, when the first chip is built.

Summary (full values in tokens.json):

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg.window` / `bg.surface` / `bg.sunken` | `#17181A` / `#1C1D20` / `#17181A` | `#F0EFEA` / `#FAF9F6` / `#F0EFEA` | v2 chrome, the editor (transcript page), dock and timeline bed |
| `bg.elevated` / `bg.muted` / `bg.input` / `bg.selectedRow` | `#25262A` / `#2A2B2F` / `#212225` / `#2B2C30` | `#FEFDFB` / `#ECEAE4` / `#FEFDFB` / `#E3E1DB` | tiles and cards, hover rows, custom inputs, custom-drawn selected rows |
| `line.default` / `.strong` / `.edge` | `#28292D` / `#6C6E75` / `#34353A` (Increase Contrast `#6C6E75`) | `#E3E1DB` / `#85878E` / `#85878E` | hairlines; 3:1 boundaries and unselected clip rules; input outlines and the timeline top edge (v2 line2) |
| `text.primary` / `.secondary` / `.muted` / `.tertiary` / `.disabled` | `#ECECEA` / `#A4A6AB` / `#9C9EA4` / `#82858B` / `#4E5056` | `#1A1B1F` / `#575A61` / `#5E6168` / `#66696F` / `#9396A4` | text, in falling contrast (v2 t1–t4) |
| `tint.default` / `.pressed` / `.on` / `.text` | `#F26B3A` / `#DC5F33` / `#1A0F0A` / `#F26B3A` | `#D35D32` / `#CF5B31` / `#1A0F0A` / `#B5502B` | VoxClip's orange: playhead, primary button and its label, caret |
| `tint.selection` / `.wash` | `#F26B3A29` (16%) / `#F26B3A12` (7%) | `#D35D3229` / `#D35D3212` | transcript selection, timeline selection wash |
| `editor.band` | `#222327` | `#F3F2EE` | band behind the open clip's lines |
| `word.text` / `.outside` / `.gone` | `#DCDCD9` / `#878A90` / `#878A90` | `#26272B` / `#66696F` / `#66686F` | transcript body in the clip, outside it, removed words under Show cuts |
| `gutter.text` / `.textOut` | `#6A6D73` / `#55585E` (Increase Contrast `#878A90`) | `#7E8187` / `#A3A5AA` | gutter timecodes in and outside the clip |
| `fold.dot` | `#5B5E64` (Increase Contrast `#707379`) | `#A7A9AE` | fold dot for a run of cuts |
| `clip.label` | `#C9CAC6` | `#3A3C41` | clip range bar, In/Out brackets, overview blocks |
| `ai.tint` / `ai.wave` | `#6AA6FF` / `#8FB3E8D9` | `#2F6FD6` / `#2A5DB0D9` | AI-voiced words and glyphs, AI patch waveform |
| `change.add` | `#4FC28B` | `#1E8A57` | a proposed change not yet kept |
| `timeline.lane` / `.rulerOut` / `.piece` / `.seam` | `#111214` / `#131416` / `#2E3035` / `#0B0C0D` | `#E4E2DC` / `#E9E7E1` / `#C9C7C0` / `#FAF9F6` | v2 track lanes, ruler outside In/Out, piece outlines, cut seams |
| `accent.default` / `.pressed` | `#6D6F73` / `#5C5E62` | `#2C2E35` / `#1A1B1F` | Ink fill that carries text (graphite in dark for the macOS asset), its pressed state |
| `accent.text` / `.on` / `.soft` | `#ECEAE4` / `#FAF9F6` / `#343537` | `#1A1B1F` / `#FAF9F6` / `#DFDEDC` | underlined links, marks, playhead; text on the fill; selection tint |
| `selection.transcript` | `#5F6061` | `#C0C1C3` | transcript selection (macOS-derived, both platforms) |
| `word.playingBackground` / `Foreground` | `#D2D1CC` / `#141517` | `#2C2E35` / `#FAF9F6` | playing word |
| `word.cut` / `.filler` / `.lowConfidence` / `.correctionDot` | `#93959C` / `#E0AE55` / `#7C7E85` / `#8F9198` | `#66686F` / `#9A5B00` / `#7E8087` / `#66696F` | cut text, suggested fillers, word marks |
| `cut.stroke` / `cut.fill` / `cut.pauseFill` | `#EE7F6E` / `#EE7F6E` / `#84878E` | `#C2402F` / `#C2402F` / `#6F7278` | strike, timeline hatches |
| `pause.background` | `#2A2B2F` | `#ECEAE4` | pause tokens (`text.muted` on it) |
| `clip.badgeBackground` | `#ECEAE417` (paper 9%) | `#1A1B1F17` (ink 9%) | neutral clip badges on the sidebar glass, page and sunken |
| `status.warning` / `.warningBackground` | `#E3B25C` / `#2D2616` | `#8A5200` / `#FAF0DC` | warnings |
| `status.dangerForeground` / `.dangerBackground` | `#F2A196` / `#33201D` | `#B3261E` / `#FBECE9` | errors |
| `status.success` / `.successBackground` / `.infoBackground` | `#7CCB93` / `#1B2A20` / `#232428` | `#1E6E3A` / `#E7F2E9` / `#F0EFEA` | success and info callouts |
| `timeline.track` / `.kept` / `.playhead` | `#26272B` / `#7A7D85` / `#ECEAE4` | `#E4E2DC` / `#74777E` / `#1A1B1F` | strip |
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
| Primary action | painted capsule: light `accent.default` + `accent.on`; dark `accent.text` + `word.playingForeground` | `AccentButtonStyle` |
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
| Rewrite scope bar field | `TextField` with `textInputSuggestions` | `AutoSuggestBox` |
| AI picker | `Menu` | `DropDownButton` with a `MenuFlyout` of `RadioMenuFlyoutItem`s |
| Rewrite change list | rows with `Toggle(.checkbox)` | `ListView` with `CheckBox` templates |
| Rewrite takes per phrase | `Picker(.segmented)` | `Segmented` (CommunityToolkit) |
| Status / errors | inline callout row | `InfoBar` |
| Home | `.dropDestination(for: URL.self)`, `.searchable(placement: .toolbar)`, `LazyVGrid(.adaptive)` | `AllowDrop`, `AutoSuggestBox`, `GridView` |
| Export | right-panel `ExportJobView` | inline `InlineEditorJob` in `RightColumn`; the existing `ExportDialog` type name is a shell-call compatibility name, not a dialog |
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
