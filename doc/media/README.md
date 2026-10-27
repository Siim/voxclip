# Launch media and static page

These are offline tools for the final native interface. This track adds no app
capture flags and records no tutorials. Run all commands below from the repo root
unless shown otherwise. Use `nice` for encoding and builds; keep at least 15 GB
free (`df -h /System/Volumes/Data`).

## Storage and rights

Keep consented lossless masters, recorded movies, audio, working projects and edit
outputs outside Git, for example in `~/Desktop/Projects/voxclip-media/`. Tests and
disposable work use only `/tmp/voxclip-sol-launch-tooling/`. Never commit launch masters
or videos. The existing small synthetic fixtures under `shared/fixtures/` remain
exempt per AGENTS.md. Uploads and go-live actions need the user's approval.
Complete [CREDITS.md](CREDITS.md) before using real media. Capture real projects,
not synthetic demo chrome. Wait for the redesign and final accent before capture.
Use a fixed solid desktop backdrop, an unlocked console and window-only capture.

Committed derivatives belong in:

- `doc/media/screenshots/macos/` and `doc/media/screenshots/windows/`: WebP stills.
- `doc/media/teaser/`: the optional animated WebP teaser.

All git-tracked files in this folder, including these docs, total at most **6,000,000 bytes**.
Each file is at most **300,000 bytes**; an animated WebP in `teaser/` may be at most
**3,000,000 bytes**. Animation outside that folder is rejected. Videos, masters,
symlinks and unsupported file types are rejected by the budget check. Review image
quality and reduce complexity if q82 exceeds the budget; do not quietly reduce it
in the exporter. Replace images at releases to limit permanent Git history growth.

## Setup

Python 3.11+ and Pillow 13.0.0 are the media tools' only Python runtime dependency.
FFmpeg and ffprobe must be on PATH. No provider SDK or live API is used. DM Sans
and JetBrains Mono are read from `shared/fonts`; the bundled OFL files permit their
unmodified web embedding. Provenance is in [provenance.md](provenance.md).

```sh
mkdir -p /tmp/voxclip-sol-launch-tooling
python3 -m venv /tmp/voxclip-sol-launch-tooling/venv
/tmp/voxclip-sol-launch-tooling/venv/bin/pip install -r tools/media/requirements.txt
```

## Stills

```sh
nice /tmp/voxclip-sol-launch-tooling/venv/bin/python tools/media/shots.py \
  ~/Desktop/Projects/voxclip-media/editor-mac.png --platform macos \
  --out /tmp/voxclip-sol-launch-tooling/editor-mac
```

`macos` preserves the source's alpha and native window shadow, without adding a
second one. Capture with `screencapture -x -l <window-id>`; avoid `-o` which removes
the shadow. `windows` expects a window tightly cropped to DWM visible frame bounds
and adds a proportional rounded shadow. Output is `readme.webp` (1600 px, q82),
`site.webp` (2400 px, q82), `social.png` (1280×640, deterministic palette, <1 MB)
and `contact.png`. WebP widths are maxima: they never exceed the original capture
width, including Windows shadow padding. A 600 px capture stays at most 600 px.
Use at least 2400 px source width for a full-size site image. Social/contact
canvases add text and margins; their source thumbnails are never enlarged. PNG social/contact previews remain outside Git unless they
also meet the 300 KB repository limit. Identical input and pinned tool versions
give identical bytes; cross-version Pillow/FFmpeg output is not promised.

## Window recording

`tools/media/sckrec` is an independent Swift 6 package targeting macOS 26. It
records one exact app/name + title substring match, at 60 fps, without the cursor,
microphone or system audio. It supports HEVC (default) and H.264 in MP4 or MOV.
Ambiguous matches and existing output/sidecar files fail. Grant Screen Recording
permission to the executable/launching terminal; it never requests a permission
dialog automatically. The screen must be unlocked.

```sh
nice swift build --package-path tools/media/sckrec --jobs 2
tools/media/sckrec/.build/debug/sckrec --list --app Finder
nice tools/media/sckrec/.build/debug/sckrec --app Finder --title Desktop \
  --out /tmp/voxclip-sol-launch-tooling/finder.mp4 --codec h264 --seconds 3
```

Omit `--seconds` for a take ending on SIGINT (Ctrl+C). SIGTERM also finalizes it.
`finder.mp4.json` records the SDK recording-start callback's UTC time and monotonic
uptime, selected window, pixel dimensions, frame rate and codec. It is first written
when recording starts, then atomically updated with the finalized asset duration.
`startedAtUnixSeconds` preserves fractional UTC seconds for alignment. Event
drivers should log timestamps relative to that start; callback scheduling is not a
frame-exact synchronization guarantee. ScreenCaptureKit may deliver fewer frames
under load; inspect the result with ffprobe before editing.

## Edit lists and overlays

Run the module with `PYTHONPATH=tools/media`. `events.json` is an ordered array:

```json
[{"step":"make-clip","timestamp":1.5,"targetFrame":[600,300,120,40],"click":true}]
```

`targetFrame` is `[x,y,width,height]` in **output pixels**; transform logged native
coordinates when cropping or scaling. Steps are unique. Cursor movement interpolates
between event centres; click events add half-second ripples. Capture timestamps are
remapped through the resolved cuts into output time, including repeated ranges.
Word alignment uses original capture timestamps. Use one event log per source take;
edits combining independent takes need a log normalized to a common capture clock.

An edit JSON (paths relative to the JSON file):

```json
{
  "size":[1920,1080], "fps":60,
  "words":[{"start":0.3,"end":0.6}],
  "clips":[{"source":"capture.mp4","duration":3,"sourceStart":0,
    "narration":"narration.wav","align":{"word":0,"step":"make-clip","lead":0.1}}],
  "overlays":[
    {"kind":"keycap","text":"Cmd+K","start":1,"end":2,"rect":[100,180,200,72]},
    {"kind":"box","text":"A new clip","start":1.4,"end":2.8,"rect":[600,300,120,40]}
  ],
  "cues":[{"start":0,"end":2.8,"text":"Keep the words that matter."}]
}
```

```sh
PYTHONPATH=tools/media /tmp/voxclip-sol-launch-tooling/venv/bin/python -m edit plan \
  ~/Desktop/Projects/voxclip-media/edit.json --events ~/Desktop/Projects/voxclip-media/events.json
PYTHONPATH=tools/media nice /tmp/voxclip-sol-launch-tooling/venv/bin/python -m edit render \
  ~/Desktop/Projects/voxclip-media/edit.json --events ~/Desktop/Projects/voxclip-media/events.json \
  --out /tmp/voxclip-sol-launch-tooling/showreel.mp4 --work /tmp/voxclip-sol-launch-tooling/edit-work
```

The model aligns a narration word's start to an event minus `lead`. Narration is
delayed into that beat and mixed with optional top-level `audio` (a pre-edited bed).
The resolved plan is written to `work/timeline.json`. Out-of-beat alignment fails. The full narration duration plus its delay must fit
the beat; otherwise rendering fails with a clear error instead of cutting speech.
Each duration must be a whole number of output frames. Source audio is deliberately
excluded; use `audio`/`narration` for consented tracks. The full mix gets two-pass
loudnorm to **−16 LUFS / −1 dBTP**, then AAC; remeasure the delivered AAC because
lossy encoding can raise peaks slightly. Silent/unmeasurable tracks fail explicitly.

Overlays: `keycap` (`pressed` optional), `ring`, `box`, `loupe` (`zoom`, `radius`,
`position` optional), `title`, `chapter`, `end` (optional `kicker`). Intervals are
half-open output seconds. In dark Ink, an unpressed keycap uses the raised `bg.elevated` surface and `text.primary` label. A pressed keycap uses the Export-capsule pair: `accent.text` fill and `word.playingForeground` label. Both pairs are read from tokens. Cards fill the frame and suppress the pointer and every click ripple while active.
The loupe samples the current edited frame, with a masked crop and leader. The
concat-plus-overlay graph produces the MP4, SRT, VTT and first/middle/last contact
sheet. SRT preserves quotes and ampersands and strips angle brackets; VTT escapes
only `&`, `<`, `>`. FFmpeg failures include the stderr tail; decode logs stay in
the work folder, and failed encoding cannot replace a previous final MP4.
Work directories must be empty; one per render prevents stale-frame reuse.
The renderer uses bounded-memory frame decoding but writes one alpha PNG per frame;
allow several GB for a 1080p showreel and delete work frames after acceptance.

The built-in `mpeg4` encoder is portable and used for deterministic tests. For a
delivery H.264 on Mac add `--encoder h264_videotoolbox`; Windows hosts with that
encoder can choose `h264_mf`. No x264/x265, radio chain or game capture code is used.
Outputs never upscale source frames; a target larger than any source dimension
fails. The cover/poster helper also rejects upscaling. For portrait use `[1080,1920]`
only with a source at least that tall and wide (otherwise choose a smaller target); each clip's `focus` (horizontal) and `focusY` (vertical) position the crop. Both are validated from 0…1 and default to .5 (centred): 0 anchors the left/top, 1 the right/bottom. The crop is `W:H:(iw-ow)*focus:(ih-oh)*focusY`. Regenerate events in the portrait output's coordinate space.

Other helpers:

```sh
PYTHONPATH=tools/media /tmp/voxclip-sol-launch-tooling/venv/bin/python -m edit audio narration.wav --out /tmp/voxclip-sol-launch-tooling/voice.wav
PYTHONPATH=tools/media /tmp/voxclip-sol-launch-tooling/venv/bin/python -m edit poster editor.png --out /tmp/voxclip-sol-launch-tooling/poster.png
PYTHONPATH=tools/media /tmp/voxclip-sol-launch-tooling/venv/bin/python -m edit contact editor.png home.png --out /tmp/voxclip-sol-launch-tooling/contact.png
```

## Static site scaffold

`site/` contains HTML, CSS and a dependency-free Node 22 builder. It reads tokens
directly, emits light/dark CSS variables, copies unmodified DM Sans and its OFL
licence, and resolves release download sizes and optional GitHub `digest` SHA-256.
No browser API calls, analytics, external fonts, runtime scripts or dependencies.
The offline builder reads saved release JSON. The Pages workflow fetches it at build time.

```sh
node site/build.mjs --release site/fixtures/latest.json
npm --prefix site test
# For real saved metadata (ignored by Git), optionally with staged release videos:
node site/build.mjs --release site/latest.json --media /tmp/voxclip-sol-launch-tooling/release-media
```

`site/dist/` is ignored. Fixture builds carry a visible warning. Missing platform
assets produce an unavailable label, never a guessed download. A Windows asset
requires its matching release's FFmpeg source archive and the architecture §6.1
LGPL notice. The builder refuses drafts, prereleases, duplicate/unsafe URLs and
malformed digests. Production fetching requires both platforms' installers.

The scaffold retains explicit screenshot placeholders. Voice Lab remains labelled
**Voice Lab (beta, coming)** with its voice recordings / words-to-ElevenLabs and
video/audio-to-lip-sync-provider disclosure (voice-lab §2.5). It is not a shipped-feature claim.

### GitHub Pages and release media

The address is **clip.voxconvo.com**, hosted by GitHub Pages from this public repo.
`site/CNAME` is copied into the artifact. `.github/workflows/pages.yml` runs on
**manual dispatch and release publication only**, never on push. A read-only
Pages API check skips deployment while Pages is disabled or uses another source;
no step enables it or changes settings. Action versions follow ci.yml's tag pins.

`site/media.json` is the single place naming the media release tag and filenames.
Approved MP4s and matching English VTTs for the showreel and four tutorials are
release assets, never committed. `node site/fetch-release.mjs <staging-directory>`
fetches the latest stable app metadata and the configured media release, validates
public-repo URLs, requires the API size/digest and downloaded bytes to match the reviewed size and SHA-256 pins in `media.json`, and writes staging files for the
offline builder. Asset downloads never receive the API credential. Commit the expected size and SHA-256 for every MP4 and VTT alongside the user's capture approval. Until all files are approved, every size and SHA-256 entry stays null: no media release or media bytes are requested, and the builder uses placeholders even if a media directory is supplied. A missing,
corrupt or incorrectly named media asset fails publication. Each asset is capped
at 100 MB and combined media at 900 MB. The media release must be **not latest**,
so it cannot displace the stable app release in `/releases/latest`. Its tag must
include this workflow. Videos use local artifact paths, native controls,
`preload="none"`, captions and no autoplay. Five tutorial rows include Voice Lab's
coming status; only the four shipped flows receive videos.

### Go live — user's approval required

Prepare final UI captures, rights/consent records, the complete media release and
both platforms' accepted installers first. Both platforms launch together; there
is no Mac-only 0.1.0 (ADR-R33, user decision 2026-10-27). Each action below needs
the user's approval; this task performs none of them:

1. **Approval required:** verify `voxconvo.com` for the **Siim account** in GitHub account settings → Pages → verified domains. Add GitHub's supplied `_github-pages-challenge-…` TXT record at GoDaddy and complete verification.
2. **Approval required:** enable Pages with **GitHub Actions** as the source and set this repository's custom domain to `clip.voxconvo.com`. In Settings → Environments → `github-pages` → Deployment branches and tags, keep `main` and add tag rules `v*` and `media-v*`.
3. **Approval required:** only after account verification and repository custom-domain assignment, add the GoDaddy CNAME `clip` → `siim.github.io`.
4. **Approval required:** wait for the certificate, then turn on **Enforce HTTPS**.
5. **Approval required:** publish the release, or dispatch **Launch page** from `main`.

Never point DNS at GitHub before steps 1–2 are complete. Keep the verification TXT record permanently. If Pages is disabled again, remove the CNAME so it no longer points at GitHub. Until the environment tag rules exist, a release run only builds: its tag-ref deploy is rejected by `github-pages`. A `workflow_dispatch` from `main` publishes the same page: every run, whatever its trigger, builds `site/` and `site/media.json` from `main`.

After publication, check all three installer links and the matching FFmpeg source,
version/sizes/checksums, video playback/captions and light/dark layout. See
[release.md §4.1](../release.md#41-launch-page-go-live--users-approval-required).
The voxconvo.com/download page and redirects are dropped (ADR-R32).

Rendered MP4s keep an existing destination’s permissions; new outputs use the normal file mode under the process umask. Test runs use unique scratch folders under `/tmp/voxclip-sol-launch-tooling` and remove only their own folder.

## Verification

```sh
nice /tmp/voxclip-sol-launch-tooling/venv/bin/python -m unittest discover -s tools/media/tests -v
nice swift test --package-path tools/media/sckrec --jobs 2
npm --prefix site test
python3 tools/media/check_budget.py
npm --prefix tools/design run check
```

FFmpeg-dependent tests use `skipUnless(ffmpeg and ffprobe are on PATH)`. The
3-second render test runs only locally; hosted CI skips it and does not install
FFmpeg. Other media tests still run in CI. Local tests use synthetic images, each overlay type, frame samples,
subtitle ordering, event alignment, a real 9:16 crop, measured loudness and byte
repeatability. Site tests check markup structure, local resources, internal links,
accessible references, both token modes, every `style.css` variable reference, release-media integrity, AA color pairs and deterministic rebuilds.
They are structural checks, not a full HTML Living Standard validator or an assistive
technology audit. Native recording and permission behavior require a real console.
