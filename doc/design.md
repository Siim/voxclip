# VoxClip design specification

Status: normative for 0.1.0 (M1), with M2/M3 surfaces marked. Date: 2026-10-25.

This spec covers information architecture, window layouts for macOS and Windows, the transcript editor, preview and timeline, the inspector (Captions, Clips, AI), the Welcome window, export and share, onboarding, settings, keyboard shortcuts, states and their exact copy, materials, accessibility, the token system and the design skills used to build it. Tokens live in [`shared/design/tokens.json`](../shared/design/tokens.json); this document explains how to use them. Module placement and threading are in [architecture.md](architecture.md).

Provenance: VoxConvo's web clipper (`vox-web` VoiceRecorder, ClipsPanel, SubtitleOverlay, WordChip, theme), Superscribe's native apps, Apple HIG and WWDC25/26 Liquid Glass sessions, Microsoft Learn WinUI 3 guidance and the skills in section 18, as collected in the planning research (`design.md`).

### Mac workspace correction (2026-10-26; ADR-R25)

This section supersedes the Mac Welcome scene, automatic first-run tour, and the Captions/Clips inspector navigation described below. The Windows design and the media, project, caption, and export contracts are unchanged.

**Task walkthrough.** A fresh launch opens one ordinary, resizable untitled document window in its Home state. Home shows Import Video and recent projects. Importing into this empty document turns that same window into the project editor; choosing a saved project opens it through the system document controller. File > New Project opens another empty document window deliberately. Finder and Open Recent continue to open documents, and a video opened while editing creates a separate project; an existing dirty project is never replaced. Closing and saving use the document system's prompts and per-window undo. No onboarding appears automatically. Help can show the tour on request.

**Layout reasoning.** The Mac window uses a native sidebar with Home under Library and Transcript and Clips under the current project. The selected location is visible and keyboard reachable. Transcript and Clips share a persistent preview, playback and timeline. Transcript is the editing surface; Clips is a full working surface with Find Clips, provider readiness, manual Make Clip from Selection, and the clip list. A toolbar Find Clips action goes to Clips, while Make Clip from Selection is visible beside the transcript selection and in the Clip menu. The Clips surface offers a direct route to select words when none are selected; once clips exist, their rows precede collapsible AI setup so they remain visible at laptop sizes. Connector readiness refreshes after a key or server setting changes; an inline Check Again action lets users retry after starting a local service or signing in. The displayed status is advisory: Find Clips performs its current connector preflight when pressed. Clip preview explicitly says which clip is active and offers Preview Full Video. The toolbar has one stable Export action, and its sheet names the full-video or clip scope before rendering. Caption styling lives in a contextual inspector opened by the Captions toolbar/menu command. Secondary cut tools stay in menus and the transcript surface. Home, missing transcript, missing connector, and results each state the next useful action inline.

This follows Apple's official macOS HIG for fewer nested levels, visible sidebars, main-task toolbar actions, native document windows, menu equivalents, and resizing. The desktop and UX skills support recognition over recall, visible system status, and keyboard operation. Spotify informs only the stable navigation and persistent playback, not visual branding or a card dashboard. Narrow widths keep Home and the main task usable; the inspector can be hidden. Light and dark appearances retain system controls and accessible labels.

### Windows clipping workspace correction (2026-10-26)

Home, recents, import and the editor share the main window. Make Clip from Selection and Find Clips are visible primary actions. The Clips pane opens by default; toolbar, keyboard and transcript context-menu clip creation all reveal the result. Caption styling is secondary. Find Clips expands its connector form in place, and transcription presents an explicit local or cloud choice with the ElevenLabs key and consent controls when needed. Settings stays in the title bar. Compact widths stack transcript and preview and offer a reachable Clips overlay; Escape returns to the transcript.

Clip rows, preview clocks and export use the same edit plan. Playback stops at the selected clip's end, and the selected-clips footer opens that export scope. Home, project replacement, native window close and Ctrl+W freeze edits before the final save. Save or replacement-open failure retains the old editor and restores editing with an inline explanation. Export cannot begin while leaving. On Windows, Restart now blocks new Settings entry, commits the active Settings text fields, pauses Settings controls and new writes, and drains accepted settings writes before preparing every open project window on the UI thread. It then freezes edits, waits for pending autosaves and final writes, flushes settings and invokes Velopack once. Busy work, an owned navigation transition, an invalid Settings field, save failure or cancellation vetoes dispatch; a failed updater call restores editing and Settings in all prepared windows. Portable tests cover the settings and project persistence boundaries. A native ARM64 Debug WinUI-thread fake-dispatch probe passed twice with fresh and repeated isolated Settings data, including dispatch-time disk readback of both projects and Settings and restored editability after failures. The owned evidence is under `/tmp/voxclip-win-ui-r7-20261026/`. Native installed-updater termination remains untested.

---

## 0. Design stance

1. **The transcript is the editor.** It gets the widest, tallest region and keyboard focus by default. Everything else supports it.
2. **One editing window per project**, no modes apart from recording (M2). Cutting, correcting, captions, clips and export happen in that window.
3. **System controls and system chrome.** macOS 26+: Liquid Glass toolbar, inspector, sheets, menus. Windows 11: Mica, `TitleBar`, `CommandBar`, `SelectorBar`, `InfoBar`. VoxConvo's identity shows through the titanium palette, the type pairing (DM Sans transcript, Geist Mono numbers) and the voice of the copy. The web app's raised skeuomorphic keys are not ported.
4. **Every primary action has a key** (Space, J/K/L, Delete, ⌘Z). Single-letter keys work only when focus is not in a text field.
5. **A cut is instant.** The preview skips a new cut on the next frame. There is no "prepare preview" step.
6. **Local-first.** Import, on-device transcription, cutting, captions, export and manual clips work with no key, no account and no network.
7. **Say what leaves the machine.** Every provider row states what it sends ("Sends the audio track to ElevenLabs." / "Sends transcript text only. No audio or video.").
8. **Nothing is lost.** Every error says the media and edits are still here.
9. **One accent, rationed.** Neutral titanium handles selection, focus and the primary choice. The only hues are red (cuts, recording) and amber (warnings, suggested fillers).
10. **Not in v1:** multitrack timelines, keyframes, B-roll libraries, templates, splash animations, onboarding carousels, account walls, telemetry.

---

## 1. Platform baselines

| | macOS | Windows |
|---|---|---|
| Minimum | macOS 26, Apple silicon (arm64) | Windows 10 19041+; designed and tested on Windows 11 |
| UI stack | SwiftUI editor and settings views in AppKit `NSDocument` windows; AppKit for native menus, text and video (`NSTextView` TextKit 2, `AVPlayerLayer`) | WinUI 3, Windows App SDK latest stable (pinned), unpackaged, self-contained |
| Materials | Liquid Glass on chrome only, **no fallbacks** (macOS 26 is the floor). `visibilityPriority` requires the Xcode 27 / Swift 6.4 SDK declaration and macOS 26.1+ at runtime; earlier toolchains keep the same toolbar items without that modifier | Mica on the main and Settings windows; Acrylic only for transient surfaces |
| System font | SF Pro (UI), SF Mono (fallback) | Segoe UI Variable (UI), Cascadia Mono (fallback) |
| Brand fonts | DM Sans 400 (transcript), Geist Mono 400/500/600 (numbers), both OFL, loaded by file from `shared/fonts` (tokens.json `fontFiles`; until a file is bundled, the platform fallback is used) | same |
| Appearance | follows the system; dark is the hero look for screenshots and the README | follows the system; plus High Contrast |

The release build must carry the current SDK in `LC_BUILD_VERSION` (release.md section 2.3). A binary stamped with an old SDK is drawn with pre-Liquid-Glass controls.

---

## 2. Information architecture

```text
Welcome (macOS window) / Home (Windows page) ──► Import (drop, ⌘O / Ctrl+O) ─┐
        │                                                                      ├─► Project editor (one window per project)
        └──────────────► Record (M2: ⌥⌘N / Ctrl+Shift+N) ─────────────────────┘        │
                                                                                         ├── Transcript (primary): cut, restore, correct
                                                                                         ├── Preview + transport: play, J K L, aspect crop
                                                                                         ├── Timeline strip: scrub, cuts, clip brackets
                                                                                         └── Inspector: Captions │ Clips │ AI (M2)
                                                                                                  │
                                                                                                  └─► Export (⌘E / Ctrl+E) ─► files on disk
                                                                                                                 └─► Share: copy caption · reveal ·
                                                                                                                     X · LinkedIn (M1); VoxConvo (M2)
Settings (⌘, / Ctrl+,): General · Transcription · AI · Export · Accounts (M2) · Voice Lab (M3 beta) · About
First run: Onboarding (3 steps, each skippable) → Welcome / Home
```

- **macOS:** a document-based app. `NSApplication` and `NSDocumentController` provide Open Recent, ⌘N/⌘O/⌘W, one window per project, autosave, native titles and a per-document undo manager. `VoxClipDocument` accepts `com.voxconvo.voxclip.project` only, so a video cannot become the document file. File > Open…, drop, Finder and Dock route projects to the document controller; a movie imports into an empty Home workspace or opens another untitled project. The empty Home is the regular document window, with no separate Welcome scene. Save As and cross-folder Move write the media path for the destination immediately; a same-folder Rename preserves the already-correct relative path (architecture 2.6, editing 10.2).
- **Windows:** one process (single instance through `AppInstance`), one main window per project, each with two pages in a `Frame`: **Home** and **Editor**. The TitleBar back button goes from Editor to Home. Ctrl+N opens a new main window in the same process. Opening a project that is already open activates its window. Launching the app again without a file activates the current window and leaves its project and edits in place. A launch with one project or video path opens that file in the existing process. Settings opens in its own window. `NavigationView` is not used in the main window: navigation is shallow and the user stays in one workflow (Microsoft: media/canvas apps use a hero surface with no `NavigationView`). Project files: section 3.3.

---

## 3. Window layouts

### 3.1 Regions and sizes (both platforms)

| Region | Default | Min / max | Notes |
|---|---|---|---|
| Window | 1280×800 | min 960×600 | Size and position restored per project |
| Transcript column | flex (≥ 440) | text measure capped at 680 (about 72 characters) | 64 left gutter for paragraph timecodes and clip brackets |
| Preview column | 380 | 300–560, user-resizable divider | Aspect-fit video on a black stage, radius 12; aspect chips below |
| Inspector | 300 | 260–380 | macOS `.inspector(…).inspectorColumnWidth(min: 260, ideal: 300, max: 380)`; Windows right pane with a splitter |
| Timeline strip | 56 high | — | Spans transcript and preview, not the inspector |
| Footer status | 32 high (Windows only) | — | macOS shows status in the toolbar subtitle |

Breakpoints (window width):

- **≥ 1200:** three columns, as in the wireframes.
- **960–1199:** the inspector is hidden by default and its toggle shows it. macOS overlays it on the content column; Windows shows it as a light-dismiss pane with in-app Acrylic.
- **< 960** (only reachable in full screen or split view): the preview stacks above the transcript (preview at most 40% of the window height), and the inspector opens as a sheet (macOS) or pane (Windows).

### 3.2 macOS 26 main window (SwiftUI, Liquid Glass chrome)

```text
╭──────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ ● ● ●  interview-take-3        (✂ Cut fillers · 12 │ ⇥ Tighten pauses │ ↺ Restore)   (▶ 00:42.3)  (Export…)(◧)│
│        02:15 after cuts · 5 words, 47 pauses cut              └─ toolbar: Liquid Glass groups (ToolbarSpacer) ─┘│
├────────────────────────────────────────────────────────┬──────────────────────────┬──────────────────────────┤
│ TRANSCRIPT · EDIT BY WORDS                     Find ⌘F │ ┌──────────────────────┐ │ (Captions │ Clips )      │
│                                                        │ │                      │ │                          │
│ 00:00.4  The thing nobody admits about editing on      │ │                      │ │ STYLE                    │
│          a timeline is that you stop reading the       │ │        video         │ │ ┌──────────┐┌──────────┐ │
│          film. u̶m̶,̶ ‖ 1.4s And the moment you            │ │     (aspect-fit,     │ │ │   Off    ││   BOLD   │ │
│          cut by transcript, you remember the [cadence].│ │      black stage)    │ │ └──────────┘└──────────┘ │
│                         playing word (paper fill) ─┘   │ │                      │ │ ┌──────────┐┌──────────┐ │
│ 00:16.0 ⟦1 Like reading a galley before a press        │ │     SAMPLE TEXT      │ │ │Highlight ││ Karaoke  │ │
│          run. Exactly, the transcript is the           │ │ ╭──────────────────╮ │ │ └──────────┘└──────────┘ │
│          manuscript. ⟧ I mean, basically …             │ │ │ ▶  00:42.3/2:15  │ │ │   … (all styles)         │
│                                                        │ │ ╰──────────────────╯ │ │ ▸ Fine tune              │
│ 00:31.2  Uh, so here is the second point …             │ └──────────────────────┘ │   Size   S  M [L] XL     │
│          ‥‥ (dotted amber = suggested filler)          │  Source · 16:9 · 9:16 · 1:1│   Case   As said |CAPS| │
│                                                        │                          │   Words  1 |Phrase| Line │
├────────────────────────────────────────────────────────┴──────────────────────────┤                          │
│ 00:42.3 ▕████░░██████▓▓▓█████░███│████████░░░██████████▓▓▓▓▓███████▏ 02:15.0 after cuts · 03:01.6 source [Source|Edited] │
│           └── 1 ─────────┘         └── 2 ───────┘                                  │                          │
╰───────────────────────────────────────────────────────────────────────────────────┴──────────────────────────╯
  █ kept   ▓ cut word (red hatch)   ░ cut pause (grey hatch)   │ playhead   └n┘ clip bracket
```

How it is built:

- Window: `NSDocumentController` → `VoxClipDocument` → `NSHostingController` with `EditorView()`. A native sidebar shows Home, Transcript and Clips. The title and proxy reflect AppKit's untitled or saved file location; `.navigationSubtitle("02:15 after cuts · 5 words, 47 pauses cut")` carries editing status.
- Body: a horizontal split of `TranscriptView | PreviewColumn` with `TimelineStrip` as a fixed 56 pt bottom row, then `.inspector(isPresented: $showInspector) { InspectorView() }`. Inspectors are edge-to-edge glass beside the content; never give the inspector its own opaque background.
- Toolbar:

```swift
.toolbar {
    ToolbarItemGroup(placement: .principal) {
        Button("Cut fillers · \(summary.fillerCount)", systemImage: "scissors", action: cutFillers)
            .disabled(!summary.canCutFillers)
        Button("Tighten pauses", systemImage: "arrow.left.and.right", action: tightenPauses)
            .disabled(!summary.canTighten)
        Button("Restore cuts", systemImage: "arrow.uturn.backward", action: restoreCuts)
            .disabled(!summary.hasEdits)
    }
    ToolbarSpacer(.fixed)
    ToolbarItem { PlayPauseButton() }                    // monochrome icon + Geist Mono time
    ToolbarSpacer(.flexible)
    ToolbarItem(placement: .primaryAction) {
        Button("Export…", action: export).buttonStyle(.glassProminent)
            .disabled(!summary.canExport)
    }
    ToolbarItem { Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() } }
}
```

  `summary` is the editing spec's `EditSummary` (section 6.4) for the current scope. With Xcode 27 / Swift 6.4 and macOS 26.1 or later (`#if compiler(>=6.4)` and `if #available(macOS 26.1, *)`), apply `.visibilityPriority(.high)` to Play and Export so they survive narrow windows; earlier toolchains use the same Play and Export items without the modifier. Icons are monochrome. Only Export is prominent; it uses the app accent (titanium).
- Transport pill over the video is the only custom glass element: `GlassEffectContainer { TransportPill().glassEffect(.regular.interactive(), in: .capsule) }`. Always `.regular`, never `.clear` (video frames can be pure white; test over a white frame). Under Reduce Transparency: opaque `overlay.transportOpaque` with a 1 pt `line.strong` border.
- **No glass on content:** not on the transcript, the timeline, caption tiles or clip rows. No darkening backgrounds behind the toolbar (they break the automatic scroll-edge effect). The transcript scroll view keeps `.scrollEdgeEffectStyle(.automatic)`.
- Inspector header: segmented `Picker` (Captions | Clips, plus AI from M2) at `.controlSize(.large)`; inspector body at `.controlSize(.small)`.
- Shapes touching the window edge use `.rect(corners: .concentric)` (or `ConcentricRectangle()`); `radius.lg` is the design value.
- The menu bar is complete (section 11.3).

### 3.3 Windows 11 main window (WinUI 3, Fluent)

```text
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ←  [◉] VoxClip   interview-take-3                                (TitleBar on Mica)        ⚙   ─   ▢   ✕     │
├──────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ ✂ Cut fillers (12)  ⇥ Tighten pauses  ↺ Restore cuts │ ▶ Play  00:42.3 / 02:15 │ ◧ Inspector │ ⋯   [ Export ]  │
│  └─ CommandBar on LayerOnMicaBaseAltFillColorDefaultBrush, DefaultLabelPosition=Right          AccentButton   │
├────────────────────────────────────────────────────────┬──────────────────────────┬──────────────────────────┤
│ ⓘ Transcribed on this PC · 1,842 words            ✕   │ ┌──────────────────────┐ │ Captions  Clips          │
│   (InfoBar)                                            │ │                      │ │ ‾‾‾‾‾‾‾‾ (SelectorBar)   │
│ 00:00.4  The thing nobody admits about editing         │ │        video         │ │ Find clips in this take  │
│          on a timeline is that you stop reading        │ │                      │ │ AI  Claude Code ▾        │
│          the film. u̶m̶,̶ ‖ 1.4s And the moment             │ │     SAMPLE TEXT      │ │ [Best moments] Hooks     │
│          you cut by transcript, you remember the       │ │ ┌──────────────────┐ │ │ One per topic  Quotes    │
│          [cadence].                                    │ │ │ ▶  00:42.3/2:15  │ │ │ Custom                   │
│                                                        │ │ └──────────────────┘ │ │ ┌──────────────────────┐ │
│ 00:16.0 ⟦1 Like reading a galley before a              │ └──────────────────────┘ │ │ Anything specific?   │ │
│          press run. ⟧                                  │  Source  16:9  9:16  1:1 │ └──────────────────────┘ │
│                                                        │                          │            [Find clips]  │
│                                                        │                          │ ☑ Galley, not timeline   │
│                                                        │                          │   0:42 · 8/10            │
│                                                        │                          │   Preview · start‹› end‹›│
├────────────────────────────────────────────────────────┴──────────────────────────┤                          │
│ 00:42.3 ▕████░░█████▓▓▓████░███│████████░░░█████████▓▓▓▓▓██████▏ 02:15.0 after cuts · 03:01.6 source       │
│           └── 1 ────────┘        └── 2 ──────┘                                     │                          │
├────────────────────────────────────────────────────────────────────────────────────┤                          │
│ Ready · 5 words and 47 pauses cut                                                  │       [Export 2 clips]   │
└────────────────────────────────────────────────────────────────────────────────────┴──────────────────────────┘
```

How it is built:

- `<Window.SystemBackdrop><MicaBackdrop/></Window.SystemBackdrop>`, applied once. The window, root grid and pages set **no Background**.
- `TitleBar` control with `ExtendsContentIntoTitleBar = true; SetTitleBar(AppTitleBar)`. `Title="VoxClip"`, `Subtitle=<project name>`, `IsBackButtonVisible` on the Editor page (back to Home). Right side: a Settings gear button (Ctrl+,). M2 adds the VoxConvo avatar when connected.
- `CommandBar` row (`DefaultLabelPosition="Right"`) on `LayerOnMicaBaseAltFillColorDefaultBrush`. Primary commands: Cut fillers (count in the label), Tighten pauses, Restore cuts │ Play/Pause (`AppBarToggleButton`) and a Geist Mono time `TextBlock` │ Inspector toggle. Enable states follow `EditSummary` exactly as on macOS. Secondary (⋯): Show cut words, Show pauses, Find, Make clip from selection, Save project as…, Show project file, Transcribe again…, Keyboard shortcuts. **Export** is a separate `Button Style="{StaticResource AccentButtonStyle}"` at the right end, outside the CommandBar.
- Content grid: transcript on `LayerFillColorDefaultBrush` (top-left `OverlayCornerRadius` 8), a splitter, the preview column (stage always solid `stage` black), a splitter, the inspector pane on `LayerFillColorDefaultBrush`. Inspector tabs: `SelectorBar` (Captions / Clips, AI from M2).
- `InfoBar` at the top of the transcript column for transcription status, provider errors, update readiness and notices. No custom banners.
- Footer status row (32): the edit summary on the left; the context primary action on the right ("Export 2 clips" when the Clips tab is active, otherwise "Export…").
- `KeyboardAccelerator` on every command. Tooltips show the shortcut (Windows' equivalent of menu-bar discoverability).
- No "double-card" borders: cards and panes use theme `Layer*`/`Card*` brushes, never custom hex fills over Mica. Corner radii: 4 (controls), 8 (overlays, cards).
- **Project files** (architecture.md section 2.6): importing a video creates `<video name>.voxclip` next to the video (" 2", " 3" when taken) and autosaves it there. When the video's folder is not writable, the project lives in VoxClip's data folder and an InfoBar (Informational) says "Saved in VoxClip's folder. Use Save project as… to keep it with the video." **Save project as…** uses a `FileSavePicker` and moves the project; **Show project file** reveals it in Explorer. Double-clicking a `.voxclip` that is already open activates its window.
- **Leaving an editor:** Home, replacing the open project, and window close hold project edits still before the final save. The old editor stays available until a replacement project and editor have opened successfully. A failed save or open restores editing in the old editor with its current edits. An active transcription, clip search, or export must finish or be cancelled before leaving; late results cannot change a project that is leaving.

---

## 4. The transcript editor (primary surface)

### 4.1 Rendering

- **Flowing prose, not chips.** A new paragraph starts after a sentence end followed by a pause of ≥ 1.5 s, or at a speaker change when diarization exists. The 64 gutter shows the paragraph start as a Geist Mono timecode `00:16.0` (`mm:ss.d`, `hh:mm:ss.d` past one hour), clip brackets `⟦n … ⟧` and speaker labels.
- Transcript font: `typography.transcript` (DM Sans 400, 17/28 pt macOS, 16/26 epx Windows), zoom 13–28 with ⌘+/⌘−/⌘0 (Ctrl+=/Ctrl+−/Ctrl+0). UI text uses the system font.
- **Never one view per word.**
  - **macOS:** one non-editable, selectable `NSTextView` using TextKit 2 (`NSTextLayoutManager`), wrapped in `NSViewRepresentable`. Keep a sorted map word index ↔ character range (binary search both ways). Word colours are applied as rendering attributes (no relayout). TextKit 2 does not draw strikethrough or underline from rendering attributes, so a custom `NSTextLayoutFragment` (via `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)`) draws them: the cut strike, the filler and low-confidence underlines, and the rounded backgrounds of the playing word (`radius.xs`) and pause tokens (`radius.sm`) behind the glyphs. A test checks the decorations by pixels on an offscreen render, not by reading attributes back. Selection snaps to whole words in `textView(_:willChangeSelectionFromCharacterRanges:toCharacterRanges:)`. Layout-changing operations (zoom, "Hide cut words") rebuild only the affected paragraphs' text storage. TextKit 2 lays out only the viewport, so hour-long takes stay smooth.
  - **Windows:** a virtualised list of paragraphs: `ItemsRepeater` (vertical `StackLayout`) in a `ScrollViewer`, one item per paragraph, each item a `RichTextBlock` with one `Paragraph` holding one `Run` per word (plus a trailing space) and one `Run` per pause token. Runs are text elements, not views. Word states use `Run.Foreground`, `Run.TextDecorations` (strikethrough) and `RichTextBlock.TextHighlighters` (playing word, selection, clip-outside dimming is foreground opacity). Native `IsTextSelectionEnabled` is off; VoxClip keeps its own word-snapped selection model across paragraphs, hit-tests with `RichTextBlock.GetPositionFromPoint` and maps `TextPointer.Offset` to word indices. Inline correction uses a `Popup` with a `TextBox` placed at `TextPointer.GetCharacterRect`.
  - Windows deviation: XAML strikethrough uses the run's foreground, so cut words are struck in `word.cut` rather than a red line. The red cut colour still appears on the timeline.
- Right-to-left scripts use natural writing direction, and the gutter moves to the trailing edge.

Word states (each shown by more than colour):

| State | Treatment |
|---|---|
| Normal | `text.primary` |
| Playing | fill `word.playingBackground`, text `word.playingForeground`, radius 4, 2 pt inline padding (VoxConvo playing chip) |
| Selected | platform selection colour (`selection.text`) |
| Cut | text `word.cut` + strikethrough 1.5 pt in `cut.stroke` (Windows: in `word.cut`). The word stays readable and restorable. With "Hide cut words" (⇧⌘H / Ctrl+Shift+H) a run of cut words collapses to a Geist Mono token `⋯ 5 cut` on `pause.background`, radius 6 |
| Pause (detected gap) | inline token `‖ 1.4s` in `typography.pauseToken`, fill `pause.background`, text `text.muted`, radius 6. Shown for gaps ≥ the project's `pauseThresholdSeconds` (editing spec: 0.8 s with decoded audio, else 1.0 s, set at import; not a setting in 0.1.0). A cut pause gets the strike too |
| Suggested filler | dotted underline in `status.warning`; tooltip "Filler · Delete to cut". These are the words "Cut fillers" will cut |
| Low confidence (if the engine reports it) | dashed underline `word.lowConfidence`; off by default (Settings → General) |
| Corrected | normal text with a 2 pt dot under the first letter (`word.correctionDot`); tooltip "Heard as: {original}" |
| Outside the previewed clip | 35% opacity, **not** struck; clip brackets in the gutter |

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
| Right-click | Context menu: Cut · Restore · Correct spelling… · Play from here · Preview this cut (P) · Make clip from selection (⌘K) · Copy text |
| Drop a file on the window | Overlay "Drop to transcribe". On a non-empty project: "Open as a new project" |

After every cut the summary updates ("5 words and 47 pauses cut") and VoiceOver/Narrator announces "Cut 'um'". Undo groups by command: one "Cut fillers" is one undo step.

- **Cut fillers** cuts every item for which the editing spec's `isFiller` is true (section 6.2): VoxConvo's `um+, uh+, erm+, hmm+` with one optional trailing `, . ! ?`, plus every `…` (unlabeled speech) item. The rule is not editable in 0.1.0 (per-language lists are deferred, editing spec section 12). Label `Cut fillers · N`; disabled at N = 0.
- **Tighten pauses** cuts every detected pause in the current scope and keeps a breath next to each kept word. The breath is a named choice in Settings → General (`editing.pauseBreath`) that sets the editing spec's `pauseKeepSeconds`: **Tight** 0.05 s · **Natural** 0.15 s (default, the editing spec default) · **Relaxed** 0.30 s. New projects take it at import; changing it applies to every open project (one undo step each).
- **Restore cuts** restores the word and pause cuts in the current scope (the active clip, or the whole take) and keeps spelling corrections and clips.
- **Find** (⌘F / Ctrl+F) opens a find bar above the transcript; matches highlight, ⌘G / ⇧⌘G (F3 / Shift+F3) step, and **Cut all N** cuts every match.

---

## 5. Preview, transport and timeline

### 5.1 Preview

- Aspect-fit video on a black `stage` with `radius.lg` (concentric on macOS). The preview plays the **edited** result (architecture.md sections 5 and 6); a new cut shows up on the next frame.
- The live caption overlay is drawn by the export renderer. The caption block is draggable with snapping to the centre line and the thirds. While dragging, safe-zone guides for the chosen aspect appear (9:16: bands over the top 12% and bottom 22%, where platform UI covers video; values from the captions spec).
- Aspect chips under the preview: `Source · 16:9 · 9:16 · 1:1` (single choice). A non-source aspect shows the centre-crop frame (M1). Face-tracked reframe arrives in M2 as a toggle "Follow face".
- Transport pill on the video, bottom centre, 36 high: ▶/❚❚, Geist Mono `00:42.3 / 02:15.0`, and a speed label when not 1× ("1.5×"). It fades after 2 s of playback while the pointer is off the video; under Reduce Motion it stays visible.

### 5.2 Timeline strip (56)

Source time by default, so cuts are visible. A `[Source | Edited]` toggle at the right end switches to edited time, where cuts collapse into thin red seams.

```text
00:42.3 ▕████░░██████▓▓▓█████░███│████████░░░██████████▓▓▓▓▓███████▏ 02:15.0 after cuts · 03:01.6 source  [Source|Edited]
          └── 1 ─────────┘         └── 2 ───────┘
```

| Element | Spec |
|---|---|
| Track | 24 high, `radius.xs`, `timeline.track` |
| Kept speech | `timeline.kept`, optional RMS waveform (50 ms buckets) in `timeline.waveform` |
| Cut word range | 45° hatch, 2 wide every 6, `cut.fill` |
| Cut pause range | same hatch in `cut.pauseFill` |
| Uncut pause | track shows through |
| Clip ranges | 2 bracket line above the track in `timeline.clipBracket`, a Geist Mono number badge (radius 6, `accent.default` fill, `accent.on` text); the active clip gets a `timeline.clipBand` band |
| Playhead | 2 line in `timeline.playhead` with a 7 triangle head; edited playback jumps over cuts |
| Labels | left: current time (`typography.timecode`); right: `02:15.0 after cuts · 03:01.6 source` |
| Interaction | click or drag to scrub; ⇧-drag snaps to word starts; hover tooltip with the word under the pointer ("cadence · 00:12.4"); double-click a cut region restores it |
| Keyboard | it is a slider: ← → one word, ⇧← → one sentence, Home / End |

No zoom in v1; the whole take always fits.

---

## 6. Inspector

Tabs: **Captions** (⌘1 / Ctrl+1), **Clips** (⌘2 / Ctrl+2), **AI** (⌘3 / Ctrl+3, from M2). Settings in the inspector are free rows under sentence-case section labels, never cards. Small control size.

### 6.1 Captions: style gallery

- Two-column grid of tiles, 128×80, gap 8, `radius.lg`. Each tile renders the real style (same renderer as export) over a still from the user's video at the playhead (dimmed 15%), using the current phrase as sample text (fallback "Your story"). The style name sits under the tile in `typography.caption`. Selected: 2 `accent.default` border and a check badge. Semantics: a radio group named "Caption style". The first tile is **Off** ("Just the video"). All built-in styles from `shared/caption-styles/styles/` appear (19 in M1, at least 17 by decision), sorted by each style's `order` field; the tile label is the style's `name` (for example `vox-highlight` shows "Highlight").
- **Fine tune** disclosure (collapsed by default). Each control maps to a CaptionStyle override defined by the captions spec:
  - Size: `S · M · L · XL` (segmented)
  - Case: `As said · ALL CAPS`
  - Words on screen: `1 · Phrase · Line`
  - Keep punctuation (toggle)
  - Colour (only for styles with an active-word colour): swatches Yellow `#FFE14D`, Green `#4BE38A`, Cyan `#5CE1FF`, Pink `#FF6FAE`, Paper `#F3F0E7`, White `#FFFFFF`
  - Position: `Top · Middle · Bottom`, with the hint "Drag captions on the video to move them."
  - "Reset to style" link
- Captions follow edited time. Phrase grouping does not break at cut seams (captions spec, decision D9).
- Under Reduce Motion, the **preview** shows animated styles without animation; the **export** keeps them (that is content, not UI).

### 6.2 Clips

```text
Find clips in this take
AI   [ Claude Code (installed CLI) ▾ ]          ● Ready
     (Best moments) Hooks  One per topic  Quotes  Custom
┌───────────────────────────────────────────────┐
│ Anything specific? (optional)                 │      Custom: "Describe the clips you want" (max 500)
└───────────────────────────────────────────────┘
                                   [ Find clips ]
────────────────────────────────────────────────
☑  Galley, not timeline                 0:42 · 8/10
   The transcript as manuscript (reason, footnote, muted)
   "Like reading a galley before a press run…" (two lines)
   Preview · start ‹ › · end ‹ › · ⋯
────────────────────────────────────────────────
☐  …
────────────────────────────────────────────────
Back to full take                [ Export 2 clips ]
```

- Header "Find clips in this take". Connector picker (`Picker` / `ComboBox`) with the catalogue groups and plain-text labels from `shared/catalog/llm-providers.json` (AI spec section 10.1): **Your API key** (Anthropic, OpenAI, xAI, Google Gemini), **On this computer** (Apple Intelligence on macOS, Ollama, LM Studio), **Installed CLI (your own sign-in)** (Claude Code, Codex). Each entry shows a status dot with text: `● Ready`, `● Key missing`, `● Not running`, `● Not found`, `● Not signed in`, `● Too old`. A footnote under the picker states what is sent: "Sends transcript text with word numbers. No audio or video." (local connectors: "Runs on this {Mac/PC}. Nothing leaves it.").
- Presets (single choice chips): **Best moments · Hooks · One per topic · Quotes · Custom**. The instruction field reads "Anything specific? (optional)", and "Describe the clips you want" for Custom (max 500 characters). Return runs **Find clips**.
- With no usable connector, the tab shows the inline key row for the selected API provider (same component as Settings) and the line **"You can also select words and press ⌘K to make a clip yourself."** (Windows: Ctrl+K). Manual clips always work.
- **The list is the clip range layer** (editing spec sections 2.5 and 10.6): every `ClipRange`, manual (⌘K / Ctrl+K) and AI, sorted by start word, then creation order. A successful **Find clips** run appends its result and adds one row per suggestion in one undo step ("Find clips"), all checked; a suggestion whose start and end words equal an existing clip's is not added again. A new run never removes rows. Manual clips appear in the same list, also checked, with no score.
- Result rows (hairline divider, padding 12, not cards): checkbox (`ClipRange.selected`), title (`typography.bodyStrong`), `m:ss · score/10` (Geist Mono; AI clips only, from the linked result), reason (`typography.footnote`, `text.muted`; AI clips only), two-line excerpt (expands while previewing), then Preview (toggle, sets the active clip) · start ‹ › · end ‹ › · ⋯ (Export this clip, Copy text, Rename, Remove). ‹ › nudge by one word and keep at least one word. Remove deletes only the row (the AI result stays cached). Keyboard: [ and ] move between clips, Return previews, Esc goes back to the full take, I / O set start / end at the caret.
- While a clip is previewed: words outside it dim to 35%, the timeline shows its band, and Restore cuts leaves the clip range alone (the clip is a range layer, not cut flags).
- Footer: "Back to full take" (ghost button, only while previewing) and the primary **"Export N clips"**, which exports the checked clips in list order ("Choose clips to export" when none is checked, disabled).
- Loading: "Finding clips…" with a Cancel button and an indeterminate progress ring (Windows: fixed-width `ProgressRing`, not a `ProgressBar`).

### 6.3 AI (M2, M3)

Hidden in M1. M2 rows: **Tighten with AI** (the LLM suggests pure cuts; shown as suggested-filler style underlines with "Cut all suggestions"), **Clean audio** (ElevenLabs Voice Isolator, voice-lab.md section 4; cost line "Uses your ElevenLabs credits"). M3 "Voice Lab (beta)" rows appear only when Settings → Voice Lab is on: Clone my voice (consent-guarded), Voice changer, Re-voice a phrase (patch mode), Lip sync; every row shows its cost line, what it sends, and the disclosure label that export will add. None of these may block the core loop.

When rewritten speech requires a different video duration, show **Lip sync** and **Retimed source video** together and let the user choose for that rewrite (ADR-R28; Voice Lab §8.9). Explain the lip-sync provider and cost, and the retimed option's speed change and slight crop. Show why an option is unavailable. Require a fresh choice for each rewrite; a previous selection or a failed option must not silently select the other. This is the intended workflow; current unsupported-video capability guards remain until those paths are implemented and verified.

For already reviewed, saved v3 recipes with unity audio fit and equal-length source video, the Mac editor uses the existing preview, timeline and Export controls. Preview duration and scrubbing follow the prepared Voice Lab timeline; source cuts beneath an enabled replacement stay dormant. Full Video export ignores a selected preview clip. Captions show the replacement words, and Captions Off retains the mandatory AI MODIFIED chip and export provenance. A missing or changed generated asset clears the preview and explains how to restore it. Unsupported video treatments, duration fit and unreviewed recipes stop with an inline explanation while preserving the video and edits. This does not expose generation, consent, candidate acceptance or changed-duration video choices before those workflows are implemented.

---

## 7. Welcome window (macOS) and Home page (Windows)

```text
macOS  Window(id: "welcome"), 720×480, opens at launch when no project is restored
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   Cut video by its words.                                (typography.title)
│   Drop a talking-head video. VoxClip transcribes it so you can cut text. │
│                                                                          │
│   ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐       │
│                         Drop a video here                                │
│   │                     .mov  .mp4  .m4v                           │      │
│                  [ Choose file…  ⌘O ]                                    │
│   └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘       │
│                                                                          │
│   Recent                                                                 │
│   ▣ interview-take-3        2:15 · today                                 │
│   ▣ launch-notes            0:58 · Tuesday                               │
│                                                                          │
│   Transcribes on this Mac · Estonian model ✓          VoxClip 0.2.0 is available. [Download] │
└──────────────────────────────────────────────────────────────────────────┘

Windows  Home page in the main window (same content), Mica, no back button
┌──────────────────────────────────────────────────────────────────────────┐
│ [◉] VoxClip                                              ⚙   ─   ▢   ✕   │
├──────────────────────────────────────────────────────────────────────────┤
│   Cut video by its words.                                                │
│   Drop a talking-head video. VoxClip transcribes it so you can cut text. │
│   ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐      │
│                 Drop a video here   .mov .mp4 .m4v .mkv .webm            │
│                 [ Choose file…  Ctrl+O ]                                 │
│   └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘      │
│   Recent   (ListView: thumbnail, name, "2:15 · today")                   │
│ ⓘ InfoBar: Transcribes on this PC · English model ✓                      │
└──────────────────────────────────────────────────────────────────────────┘
```

- Drop zone: 2 dashed `overlay.dropZoneBorder`, `radius.xl`. File types listed are the ones the platform opens (macOS: no `.mkv`/`.webm`).
- Recent: thumbnail (first frame, 160 px), project name, duration and relative date in Geist Mono. Context menu: Show in Finder/Explorer, Remove from list.
- Engine status line: "Transcribes on this Mac · English model ✓", "Transcribes with ElevenLabs", or "No model yet · Download ({size})".
- M2 adds **Record** (`⌥⌘N` / `Ctrl+Shift+N`) next to Choose file.

### 7.1 Import sheet and the untranscribed state

Opening a video makes it playable at once (section 13, "Importing"). Transcription then starts **immediately** with the routed plan (transcription.md section 11.2) unless one of these holds, in which case the import sheet appears first (macOS sheet on the new project window, Windows `ContentDialog`):

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
- **Untranscribed state** (`transcript == null`: after Not now, cancel, `noSpeech` or a failure): the transcript column shows "This video isn't transcribed yet." with **Transcribe…** (opens the sheet). The video plays, and Export works with no captions and no cuts.
- **Transcribe Again…** (macOS Edit menu, Windows CommandBar ⋯) confirms first: "Transcribe again? This replaces the transcript and removes {n} cuts, {m} corrections, {k} clips and the AI suggestions." [Transcribe Again] [Cancel] (editing spec section 10.5), then opens the sheet with the current engine and language selected.

---

## 8. Export and share

macOS: a sheet on the project window. Windows: a `ContentDialog` (`DefaultButton="Primary"`). Shortcut ⌘E / Ctrl+E. Disabled with the reason "Keep at least one word before exporting." when everything is cut (`!summary.canExport`).

The sheet edits the project: **Aspect**, **Quality**, **Also save .srt** and **Save to** read and write the project's `export` object (`aspect`, `quality`, `srt`, `folder`), and the **Captions** picker reads and writes `captions.styleId`, the same value as the inspector gallery ("Off" = `"off"`). New projects start from the Settings → Export defaults. Output size, bitrate and frame rate are derived from architecture.md section 4.1 and never stored.

```text
┌ Export ───────────────────────────────────────────────────────────────┐
│ ┌──────────────┐  What      (•) Full edit · 02:15                      │
│ │  first-frame │            ( ) 2 selected clips · 0:42, 0:31          │
│ │  thumbnail   │  Aspect    [Source] 16:9  9:16  1:1                   │
│ │  with the    │  Captions  Highlight ▾          [x] Also save .srt    │
│ │  captions    │  Quality   [Standard]  High                           │
│ └──────────────┘  Save to   ~/Movies/VoxClip ▾                         │
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
- Progress replaces the form: "Rendering 1 of 2 · 42% · about 1 min left" with a fixed-width bar (Windows: fixed width, the Fluent `ProgressBar` minimum width otherwise pushes text) and **Cancel**. Closing the sheet keeps the export running; the toolbar subtitle (macOS) or footer (Windows) shows the progress.
- File name pattern: `{project}-{clip}-{aspect}.mp4` (`{clip}` is `full` for the full edit; aspect as `16x9`, `9x16`, `1x1`, `source`), de-duplicated with ` 2`, ` 3`.
- **Share helpers (M1)**, behaviour in publishing.md section 2: Show in Finder / Show in Explorer, Copy caption (also offers the file for drag-out from the row), Open X (web intent with the caption), Open LinkedIn (composer with the caption). The caption field shows a per-destination count (X 280, LinkedIn 3,000).
- M2 adds "Also post to VoxConvo @handle" (checkbox, only when connected, otherwise "Connect…") and the primary becomes **Export & post**. Posting follows publishing.md section 3: the button disables on press, the final post call is never retried automatically, "Try again" reuses the render.

---

## 9. Onboarding (first launch, skippable)

On Windows, before this optional onboarding or any project, media, model, provider or key access, a native blocking dialog titled **Windows component terms** explains: “VoxClip includes Microsoft Windows components. Review and accept their terms to use this Windows build. VoxClip itself remains open source under MIT.” It displays the full bundled Windows App SDK 2.5.1 and Windows ML Runtime 2.1.74 terms offline in a scrollable read-only field that stays usable with keyboard scrolling and display scaling. **Accept and continue** records the exact current terms hash for this user; **Quit**, Escape and closing the dialog or its host window leave normal app features unavailable. The default button is Quit. No checkbox is preselected. The prompt reappears only when the terms hash changes or the receipt is absent or invalid; an accepted receipt opens the normal window directly. About → Licences continues to show the complete root notices. This dialog may initialize WinUI before the decision; it does not start normal application services.

A 560×480 sheet over the Welcome window (macOS) or a centred `ContentDialog`-sized page over Home (Windows). Three steps with a dot indicator; **Skip** is always in the top-trailing corner and lands on Welcome/Home with local defaults. Reopen from Help → Welcome Tour.

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
              Space play · ⌫ cut · ⌘Z undo · J K L shuttle · ⌘E export
              [ Open a video… ]                                                     [ Done ]
```

- Step 2 preselects **nothing** (AI spec section 7.1 rule 8, `llm.connector` starts empty). **Not now** is the default button; **Continue** is disabled until an option is chosen. Choosing Installed CLI also requires picking Claude Code or Codex explicitly, and then shows the AI spec section 4.8 consent text inline (for example "…counts toward your Claude plan's usage"); Continue stores `llm.cloudConsent.<id>`.
- Keys go straight to the Keychain / DPAPI (architecture.md section 11.4). Once saved, a key is never shown again; the field shows "Saved in the Keychain; paste to replace".
- **Test** makes one minimal call through the normal path and shows the result in `status.success` or `status.warning`: AI connectors as AI spec section 10.2 ("Works · {model} · {seconds} s" / "Failed: {message}"), ElevenLabs as the transcription spec's key test. CLI rows show the local detection and sign-in status first (AI spec section 6.10).
- If the user skips step 1, the first import asks inline: "Transcribe on this {Mac/PC} (download {model}, {size})" or "Use ElevenLabs (add key)".
- No telemetry question: there is no telemetry.

---

## 10. Settings

macOS: one retained native Settings window hosting a toolbar-style SwiftUI `TabView` with `.formStyle(.grouped)`, minimum 600×480, resizable. The Settings command reopens that window after close; appearance updates while it is open and follows System when selected. Closing it preserves app-owned model downloads and text-field drafts. Windows: a separate Settings window on Mica with a left `NavigationView` (inside the Settings window only) and `SettingsCard` / `SettingsExpander` rows (Windows Community Toolkit); default 760×600, min 560×480.

```text
macOS                                                    Windows
┌ General  Transcription  AI  Export  About ┐            ┌ Settings ──────────────────────────────── ─ ▢ ✕ ┐
│ ┌ Appearance ───────── System ▾ ┐          │            │ ◧ General       │ Transcription                   │
│ │ Transcript text size  17 ─●── │          │            │ ◧ Transcription │ ┌ Engine ───── On this PC ▾ ┐   │
│ │ Pause breath   Natural ▾      │          │            │ ◧ AI            │ ├ ElevenLabs key  ●Ready      │   │
│ │ Default caption style  Highlight ▾│      │            │ ◧ Export        │ │  [ •••••• ] Save Test Forget │   │
│ └───────────────────────────────┘          │            │ ◧ About         │ ├ Models ─────────────────── ▾ │   │
│                                            │            │                 │ │  TalTech Estonian · 574 MB ✓ │   │
│                                            │            │                 │ └──────────────────────────────┘   │
└────────────────────────────────────────────┘            └────────────────────────────────────────────────────┘
```

| Pane | Rows |
|---|---|
| **General** | Appearance: System · Light · Dark (`general.appearance`). Transcript text size (`general.transcriptTextSize`). Pause breath: Tight 0.05 s · Natural 0.15 s · Relaxed 0.30 s (`editing.pauseBreath`). Show low-confidence words (`general.showLowConfidence`). Default caption style (`captions.defaultStyleId`). Open last project on launch (Windows only, `general.openLastProject`). Check for updates automatically (`update.autoCheck`). Cache size limit 2 · 5 · 10 · 20 GB (`cache.limitGB`) + Clear cache. The filler rule and the pause threshold are not settings in 0.1.0 (editing spec sections 5.0 and 12). |
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

Single-letter keys (J K L I O P C [ ]) and bare Space, ⌫ and arrows act on the editor only when keyboard focus is in the transcript, the preview or the timeline **and** no inline correction field is open **and** no IME composition is in progress (`NSTextInputClient.hasMarkedText()` false; WinUI: focus is not a `TextBox`, `PasswordBox`, `AutoSuggestBox`, `RichEditBox` or `NumberBox`). In any text field they type text. macOS implements them in the `NSTextView` subclass's `keyDown` and in `.onKeyPress` on the preview and timeline; Windows uses `KeyboardAccelerator`s scoped with `ScopeOwner` to the editor root plus a focus check.

On Windows avoid **Ctrl+Alt+letter** (AltGr on many layouts types characters). Use Ctrl+Shift.

### 11.2 Map

| Action | macOS | Windows | Notes |
|---|---|---|---|
| Play / pause | Space | Space | |
| Play from caret | ⇧Space | Shift+Space | |
| Preview this cut | P | P | From 2.0 s before to 2.0 s after the selection, cuts applied |
| Shuttle back / stop / forward | J / K / L | J / K / L | L again: 1× → 1.5× → 2×. J jumps back 3 s per press. K stops and resets the rate |
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
| Make clip from selection | ⌘K | Ctrl+K | |
| Set clip start / end at caret | I / O | I / O | |
| Previous / next clip | [ / ] | [ / ] | |
| Preview clip / back to full take | Return / Esc (in the Clips list) | Enter / Esc | |
| Toggle inspector | ⌥⌘I | Ctrl+Shift+I | |
| Inspector tabs | ⌘1 / ⌘2 / ⌘3 | Ctrl+1 / 2 / 3 | ⌘3 from M2 |
| Transcript text bigger / smaller / reset | ⌘+ / ⌘− / ⌘0 | Ctrl+= / Ctrl+− / Ctrl+0 | |
| Export… | ⌘E | Ctrl+E | |
| Import / open | ⌘O | Ctrl+O | |
| New window | ⌘N (new untitled project via Welcome) | Ctrl+N | |
| New recording (M2) | ⌥⌘N | Ctrl+Shift+N | |
| Settings | ⌘, | Ctrl+, | |
| Keyboard shortcuts overlay | ⌘/ | Ctrl+/ (also F1) | |
| Close project | ⌘W | Ctrl+W | |
| Full screen | ⌃⌘F | F11 | |

### 11.3 macOS menu map

- **VoxClip:** About VoxClip, Check for Updates…, Settings…, Hide, Quit.
- **File:** New Recording (M2), Open… (projects and movies; a movie opens as a new untitled project), Open Recent, Close, Save, Duplicate, Rename…, Move To…, Export…, Reveal Media in Finder.
- **Edit:** Undo, Redo, Cut Selection, Restore Selection, Correct Word, Select All, Copy Text, Find…, Find Next, Find Previous, Cut Fillers, Tighten Pauses, Restore All Cuts, Transcribe Again… (section 7.1).
- **View:** Show/Hide Cut Words, Show/Hide Pauses, Show/Hide Caption Inspector, Show/Hide Sidebar, Home / Transcript / Clips, Source / Edited Timeline, Bigger / Smaller / Actual Size, Enter Full Screen. Each Show/Hide title describes the current action.
- **Playback:** Play/Pause, Play from Selection, Preview Cut, Shuttle Back / Stop / Forward, Go to Start / End.
- **Clip:** Make Clip from Selection, Set Start, Set End, Previous / Next Clip, Find Clips…
- **Window**, **Help:** Keyboard Shortcuts, Welcome Tour, What Leaves This Mac, Reveal Logs, Copy Diagnostics.

---

## 12. Recording (M2)

The record view opens in a new project window. Camera preview at its own aspect (radius 12, mirrored by default with a toggle), a top-left REC pill (`overlay.scrim`, Geist Mono 600 12, blinking `record.live` dot at 1.2 s steps), a 3 px progress line, a 3-second centre countdown and the hint "Recording starts after a 3-second countdown." Toolbar: Camera ▾, Microphone ▾ (with level meter), Mirror, **Record** (●). Space starts and stops; Esc cancels the countdown. On Stop the window becomes the editor with no extra click. No time limit; a soft notice at 60 minutes. Permission errors are inline with a deep link (`x-apple.systempreferences:com.apple.preference.security?Privacy_Camera` / `…Privacy_Microphone`; `ms-settings:privacy-webcam` / `ms-settings:privacy-microphone`).

---

## 13. States and exact copy

Voice: short, factual, calm, always reassuring about the media. No exclamation marks, no emoji. `{Mac/PC}` is "Mac" on macOS and "PC" on Windows. macOS shows these in inline callout rows; Windows uses `InfoBar` with the severity given.

| Situation | Where | Copy / UI |
|---|---|---|
| No project | Welcome / Home | Title "Cut video by its words." Sub "Drop a talking-head video. VoxClip transcribes it so you can cut text." Drop zone "Drop a video here". Button "Choose file…". |
| Drag over | any window | Overlay "Drop to transcribe" on `overlay.drop`, 2 dashed `overlay.dropBorder`, radius 14. On a non-empty project: "Open as a new project". Not allowed (M2 during recording): "Finish or close the recording first". |
| Unsupported file (macOS WebM/MKV) | Welcome / drop | "VoxClip can't open {ext} files on Mac yet. Export the video as MP4 or MOV and try again." (Informational) |
| Not transcribed | Editor (transcript column) | "This video isn't transcribed yet." [Transcribe…] (shown while `transcript == null`; section 7.1) |
| Importing | Editor | The video is playable immediately. The transcript column shows 6 skeleton lines (static under Reduce Motion) and the stages "Reading video… → Extracting audio… → Transcribing on this {Mac/PC} · 42% → Aligning words…" (ElevenLabs: "Transcribing with ElevenLabs · 42%") with **Cancel**. Announcements every 10%. |
| Transcribed | Editor | "Transcribed on this {Mac/PC} · 1,842 words" (Success, auto-dismiss after 6 s). |
| Model missing | Editor | "Download the {model} model ({size}) to transcribe on this {Mac/PC}." [Download] [Use ElevenLabs instead] (Informational) |
| Model downloading | Editor / Settings | "Downloading {model} · 37% · {done} of {total}" [Cancel] |
| Model checksum failed | Settings | "{file} did not match its checksum. Try the download again." (Error) [Retry] |
| Key rejected | Editor | "{provider} rejected the key ({status}). Your video is still here." [Open Settings] [Transcribe on this {Mac/PC}] [Retry] (Error) |
| Offline | where a provider is used | "You're offline. On-device transcription and editing still work." Provider rows show "Offline". (Warning) |
| No speech | Editor | "We didn't hear any words. Check the audio track or choose the language." [Language ▾] [Retry] (Warning) |
| No audio track | Editor | "This video has no audio track, so there is nothing to transcribe." You can still export. (Informational) |
| Media missing | Editor | "Can't find {file}. Edits are saved." [Locate…] (Warning) |
| Relinked file differs | Editor | "This file looks different. Use it anyway?" [Use it] [Choose another] |
| Clips: no connector | Clips tab | "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI." [Open AI settings], plus "You can also select words and press ⌘K to make a clip yourself." |
| Clips: CLI not found | Clips tab | "{Claude Code/Codex} isn't installed. {installHint}" (hint from the catalogue) |
| Clips: CLI not signed in | Clips tab | "{cli} isn't signed in. {signInHint}" [Sign-in help] |
| Clips: Apple model locale | Clips tab | "Apple's on-device model doesn't support {language}. Use an API key, a CLI or a local model for this project." |
| Clips: local server down | Clips tab | "Ollama isn't running at {url}. Start Ollama and try again." / "LM Studio's server isn't running at {url}. Start it from LM Studio's Developer tab." |
| Clips: Custom with no text | Clips tab | the prompt file's `messages` text (VoxConvo: "Describe the clips you want.") |
| Clips: finding | Clips tab | "Finding clips…" [Cancel] |
| Clips: none found | Clips tab | the prompt file's `messages` text (VoxConvo: "No clips matched. Try another style or describe what you want.") |
| Clips: any other AI failure | Clips tab | the AI spec section 5 message for the error, followed by "Your edits are saved." [Retry] |
| Everything cut | Editor, Export | Export disabled; status "Keep at least one word before exporting." |
| Edit summary | toolbar subtitle / footer | "{n} word(s) and {m} pause(s) cut." / no cuts: "No cuts yet." Duration "{edited} after cuts" / "{total} total". |
| Export progress | Export sheet | "Rendering {i} of {n} · {p}% · about {t} left" [Cancel] |
| Export done | Export sheet | "Saved {n} video(s) to {folder}" + share buttons |
| Export failure | Export sheet | "Export stopped: {reason}. Your edits are saved." [Try again] |
| No encoder (Windows) | Export | "No H.264 encoder is available on this PC. Install the Media Feature Pack or update your graphics driver." (Error) |
| HDR source (Windows) | Export | "This video is HDR. Colours are converted to standard range and may look flatter." (Informational) |
| Disk full | Export, download | "There isn't enough free space on {volume}. Free up {size} and try again." |
| Caption copied | Export | "Caption copied." (transient, 2 s) |
| Update available (macOS) | Welcome, app menu | "VoxClip {version} is available." [Download] |
| Update ready (Windows) | InfoBar | "VoxClip {version} is ready. Restart to update." [Restart now]; during transcription, clip search or export the button is disabled with "Finish the current task first." |
| Up to date | manual check | "VoxClip {version} is the latest version." |
| Update check offline | manual check | "Couldn't check for updates. You're offline." |
| Post failure (M2) | Export sheet | "Saved to {folder}. Posting to VoxConvo failed: {reason}." [Try again] (render reused, never auto-retried) |
| Camera or mic denied (M2) | Record view | "Camera access is off. Turn it on in System Settings → Privacy & Security → Camera." [Open Settings] |
| Unsaved changes | — | Projects autosave. macOS: an untitled project (never saved under a name) gets the system keep/delete prompt on close; named projects close silently. Windows: projects always have a file (section 3.3), so closing never prompts. |
| Transcribe again | confirmation | "Transcribe again? This replaces the transcript and removes {n} cuts, {m} corrections, {k} clips and the AI suggestions." [Transcribe Again] [Cancel] |
| ElevenLabs first upload | sheet / ContentDialog | Title "Transcribe with ElevenLabs?" Body "ElevenLabs Scribe uploads this take's audio track with your key. ElevenLabs stores it under its terms and may use it to improve its services unless you opt out in your ElevenLabs account. No video is sent." [Continue] [Cancel] (transcription.md section 8.5) |
| Project saved outside the video folder (Windows) | InfoBar (Informational) | "Saved in VoxClip's folder. Use Save project as… to keep it with the video." |

---

## 14. Appearance and materials

- **Light and dark** follow the system. Dark is the hero look for screenshots. The video stage stays black in both and in High Contrast.
- **macOS Liquid Glass is chrome only:** toolbar, inspector, sheets, menus, popovers, and the transport pill over the video. Content surfaces are opaque tokens (`bg.surface` for the transcript, `stage` for video, `timeline.*` for the strip). Never glass on glass. Custom surfaces check `accessibilityReduceTransparency` and switch to opaque fills with `line.strong` borders; system glass handles Reduce Transparency and Increase Contrast itself. Tint glass only to convey meaning (only Export is prominent).
- **Windows:** Mica on the main window and the Settings window, applied once. `LayerOnMicaBaseAltFillColorDefaultBrush` behind the CommandBar. Acrylic only for transient surfaces: menus, flyouts, the light-dismiss inspector below 1200. Cards and panes use theme `Layer*` / `Card*` brushes. `TitleBar` for chrome, `CommandBar` for grouped commands, `SelectorBar` for the inspector tabs, `InfoBar` for status, `ContentDialog` for Export, `TeachingTip` for first-run hints.
- **Accent: Petrol**, in two tones. `accent.default` (`#1C6B69` light, `#237D7A` dark) is the fill that carries text: prominent buttons, the selected choice, the playing word. `accent.text` (`#1C6B69` light, `#63BDB6` dark) is for marks, rings, links, clip badges and the playhead. Both tones pass with each platform's own text on the accent.
  - **macOS:** the `AccentColor` asset (generated from `accent.default`, compiled into the bundle by `bundle.sh`) and `NSAccentColorName` make Petrol the app accent, so standard controls draw the system's white on it. Users who chose a system accent colour see theirs on standard controls, which is correct, and `DesignValues.accentText` then follows `controlAccentColor`; it uses `accent.text` only while the accent is the asset. A bare `swift run` has no asset, so DEBUG builds tint their SwiftUI roots with `accent.default`; AppKit focus rings and text selection stay system blue there, and accent evidence for those must come from a bundled app.
  - **Windows** keeps the system accent for `AccentButtonStyle`, focus visuals and selection; VoxClip's own surfaces use the tokens.
- **Colour rules:** one accent, Petrol; red only for cuts and recording; amber only for warnings and suggestions; no pure black except the stage; no gradients on native surfaces.
- **High Contrast (Windows):** the `HighContrast` theme dictionary maps every token to its `windowsHighContrast` system colour (tokens.json). Strikethrough survives High Contrast, so cut state stays visible.

---

## 15. Accessibility

- **Screen readers.** The transcript is text (NSTextView / RichTextBlock), so VoiceOver and Narrator read it by word, line and paragraph. Each word's accessible description adds its state: "um, cut", "pause 1.4 seconds", "cadence, playing". macOS: custom rotors (`accessibilityCustomRotors`) for Cuts, Pauses, Suggested fillers and Clips, and custom actions on the focused word (Cut, Restore, Correct, Play from here). Every command posts an announcement ("Cut 3 words", "Restored all cuts, corrections kept") via `NSAccessibility.post(element:notification: .announcementRequested, …)` or UIA `RaiseNotificationEvent`.
- **Timeline** is a slider: "Playhead, 42 seconds of 2 minutes 15 after cuts, 12 cuts". Arrow keys step by word.
- **Caption gallery** is a radio group; each option is named ("Highlight: white words on a dark box, one word at a time").
- **Keyboard.** The whole loop (import → cut → captions → clips → export → share) works without a pointer. Focus order: toolbar/CommandBar → transcript → preview → timeline → inspector. F6 / Shift+F6 cycles panes on Windows; Tab with Full Keyboard Access on macOS. System focus rings / focus visuals; custom rings are 2 `focus.ring`, offset 2.
- **Windows clip preview focus.** Enter on a clip's Preview action focuses the preview transport. Escape returns to that clip's checkbox. Rebuilding clip results after a checkbox change keeps focus on the same checkbox. F6 and Shift+F6 cycle by pane from any focused descendant, landing on the timeline slider and selected inspector tab with native focus visuals and names. Closing the compact inspector returns focus to the transcript; previewing from it focuses the transport. Alt+Left from the editor returns Home, and a recent project's accessible item name is its visible project name.
- **Colour independence.** Cut = strike + dimming; timeline cuts = hatching; clips = brackets and numbers; fillers = dotted underline + tooltip. No state depends on red versus green.
- **Contrast** (measured, WCAG 2.x): dark `text.primary` 16.3:1, `text.muted` 8.9:1, `word.cut` 6.5:1 on `bg.surface`; light 17.6:1, 7.2:1, 4.65:1. Cut words stay ≥ 4.5:1 because they are still content. Re-check when a surface token changes.
- **Motion.** Strike draw-in, countdown scaling, playing-word slide and the transport fade are off under Reduce Motion (macOS `accessibilityDisplayShouldReduceMotion`, Windows `UISettings.AnimationsEnabled`).
- **Targets.** macOS controls ≥ 22 pt (small in the inspector, regular elsewhere); words get 2 pt vertical hit slop. Windows targets ≥ 32×32 epx.
- **Text size.** Transcript zoom 13–28. Windows honours the system text-size setting through the Fluent type ramp.
- **Captions as accessibility.** `.srt` sidecar export; default styles are readable on any frame (the bold styles have a stroke).
- **Localization.** Strings in String Catalogs (`.xcstrings`) and `.resw`. Layouts tolerate 30% text growth and right-to-left languages. M1 ships English UI; Estonian UI may follow.

---

## 16. Design tokens

`shared/design/tokens.json` (format `voxclip-tokens/1`) is the only source of colours, type, spacing, radii, strokes, motion and fixed sizes. `tools/design` generates:

- `apps/macos/Sources/VoxClip/Design/Tokens.swift`: `extension Color { static let vcTextPrimary = Color(nsColor: NSColor(name: "vcTextPrimary") { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }) }`, plus `CGFloat` constants and `Font` helpers that load the bundled DM Sans and Geist Mono by file URL. `system:` values map to the named `NSColor`.
- `apps/windows/src/VoxClip.App/Themes/Tokens.xaml`: a `ResourceDictionary` with `ThemeDictionaries` keyed `Default` (dark), `Light` and `HighContrast` (from `windowsHighContrast`), `SolidColorBrush` per colour token named `Vc<Group><Name>Brush`, `x:Double` and `Thickness`/`CornerRadius` resources for dimensions.
- `apps/macos/Resources/Assets.xcassets/AccentColor.colorset`: `accent.default` (marked `macosAsset`), light for Any and dark for Dark, compiled by `bundle.sh`.

Naming: token path `color.text.primary` → Swift `vcTextPrimary`, XAML `VcTextPrimaryBrush`. Generated files carry `GENERATED from shared/design/tokens.json - do not edit`. CI regenerates and fails on drift.

The palette is the Document direction from the October 2026 design study: paper and ink neutrals and one accent, Petrol. Each colour token's `source` extension names the study token its value comes from; for example `bg.elevated` is the study's raised and `text.muted` its pause label. `line.subtle` was removed because the study has two separators. `text.disabled`, `record.*`, `stage`, `overlay.scrim` and `overlay.transportOpaque` keep values the study does not define.

Summary (full values in tokens.json):

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg.window` / `bg.surface` / `bg.sunken` | `#141517` / `#1B1C1F` / `#141517` | `#F0EFEA` / `#FAF9F6` / `#F0EFEA` | window and sheets, transcript page, dock and timeline bed |
| `bg.elevated` / `bg.muted` / `bg.input` | `#25262A` / `#2A2B2F` / `#25262A` | `#FEFDFB` / `#ECEAE4` / `#FEFDFB` | tiles and cards, hover rows, custom inputs |
| `line.default` / `.strong` | `#2E2F33` / `#6C6E75` | `#E3E1DB` / `#85878E` | hairlines, 3:1 control boundaries |
| `text.primary` / `.secondary` / `.muted` / `.tertiary` / `.disabled` | `#ECEAE4` / `#A8AAB0` / `#B0B2B8` / `#8F9198` / `#777C8D` | `#1A1B1F` / `#575A61` / `#55585F` / `#66696F` / `#9396A4` | text |
| `accent.default` / `.pressed` | `#237D7A` / `#1C6764` | `#1C6B69` / `#155755` | Petrol fill that carries text, its pressed state |
| `accent.text` / `.on` / `.soft` | `#63BDB6` / `#FAF9F6` / `#1F3F3D` | `#1C6B69` / `#FAF9F6` / `#D3E6E3` | links, marks, playhead; text on the fill; selection tint |
| `word.playingBackground` / `Foreground` | `#237D7A` / `#FAF9F6` | `#1C6B69` / `#FAF9F6` | playing word |
| `word.cut` / `.filler` / `.lowConfidence` / `.correctionDot` | `#8E9097` / `#E0AE55` / `#7C7E85` / `#8F9198` | `#6F7178` / `#9A5B00` / `#7E8087` / `#66696F` | cut text, suggested fillers, word marks |
| `cut.stroke` / `cut.fill` / `cut.pauseFill` | `#EE7F6E` / `#EE7F6E` / `#84878E` | `#C2402F` / `#C2402F` / `#6F7278` | strike, timeline hatches |
| `pause.background` | `#2A2B2F` | `#ECEAE4` | pause tokens |
| `status.warning` / `.warningBackground` | `#E3B25C` / `#2D2616` | `#8A5200` / `#FAF0DC` | warnings |
| `status.dangerForeground` / `.dangerBackground` | `#F2A196` / `#33201D` | `#B3261E` / `#FBECE9` | errors |
| `status.success` / `.successBackground` / `.infoBackground` | `#7CCB93` / `#1B2A20` / `#232428` | `#1E6E3A` / `#E7F2E9` / `#F0EFEA` | success and info callouts |
| `timeline.track` / `.kept` / `.playhead` | `#26272B` / `#7A7D85` / `#63BDB6` | `#E4E2DC` / `#74777E` / `#1C6B69` | strip |
| `overlay.foreground` | `#F5F4F0` | `#F5F4F0` | text over video |
| `stage` | `#000000` | `#000000` | video surround |

Typography, spacing (4-point grid, macOS pane padding 20, Windows 24), radii (4, 6, 8, 12, 16, capsule), motion (120 / 150 / 240 ms, ease-out `cubic-bezier(.23,1,.32,1)`, spring 0.32 / 0.82, instant under Reduce Motion) and fixed sizes are in tokens.json.

---

## 17. Control mapping

| Concept | macOS (SwiftUI / AppKit, macOS 26) | Windows (WinUI 3) |
|---|---|---|
| Window chrome | `.windowToolbarStyle(.unified)`, `.navigationSubtitle` | `MicaBackdrop` + `TitleBar` |
| Command surface | `.toolbar` + `ToolbarSpacer`, `visibilityPriority` (macOS 26.1+) | `CommandBar` (primary / secondary) |
| Primary action | `.buttonStyle(.glassProminent)` | `AccentButtonStyle` |
| Transcript | `NSTextView` (TextKit 2) in `NSViewRepresentable` | `ItemsRepeater` of paragraph `RichTextBlock`s with `Run`s and `TextHighlighters` |
| Preview | `AVPlayerLayer` in an `NSView` + composition | `Image` + `WriteableBitmap` fed by the FFmpeg engine |
| Panes | split view + `.inspector` | `Grid` + splitters (`CommunityToolkit.WinUI.Controls.Sizers`) |
| Inspector tabs | segmented `Picker` | `SelectorBar` |
| Status / errors | inline callout row | `InfoBar` |
| Export | `.sheet` | `ContentDialog` |
| Settings | `Settings { TabView }`, `.formStyle(.grouped)` | Settings window + `NavigationView` + `SettingsCard` / `SettingsExpander` |
| Key field | `SecureField` | `PasswordBox` (reveal button) |
| Key storage | Keychain | DPAPI |
| Shortcuts | `.keyboardShortcut`, `CommandMenu`, `onKeyPress` | `KeyboardAccelerator` |
| First-run hints | `.popoverTip` (TipKit) | `TeachingTip` |
| Progress | `ProgressView` (fixed width) | fixed-width `ProgressBar` / `ProgressRing` |

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

Agents working on UI should load `swiftui-expert-skill` + `macos-design-guidelines` for macOS work and `winui-design` + `winui-app` for Windows work, and treat this spec as overriding any skill advice that conflicts with it (for example, skills that suggest a `NavigationView` shell for the editor).
