# Media tool provenance

The author authorized adapting their private A10 tooling into this MIT repository.
Only generic code authored for that pipeline is reused. Inspected files contain no
third-party code headers, imports of borrowed renderers or upstream attribution in
the selected portions. No game assets, audio, footage, scripts, keys or personal
paths are included. The source files themselves are not redistributed wholesale.

Source snapshots: A10 trailer tooling last changed at `c06d527` (2026-10-21),
`tools/trailer/` in the author's `Siim/a10-canary` repository. The tutorial's
`tools/tutorial/edit.py` is the rendered `010ce4d` revision (2026-10-23).

| VoxClip file | Adapted source and source lines reviewed | Adaptation |
| --- | --- | --- |
| `tools/media/edit/art.py` | trailer `poster.py` 57–79, 150–197; `contact.py` 28–48 | Cover crop, rounded shadow, headline/footer, contact layout; no numpy, CRT, retro renderer or external fonts |
| `tools/media/shots.py` | poster helpers above | New deterministic export wrapper; native/synthetic shadow rules, 1600/2400 WebP and bounded social PNG |
| `tools/media/edit/model.py` | tutorial `edit.py` 9–14, 265–335 | Word/event beat alignment rewritten for UI events, explicit validation, no game log parser |
| `tools/media/edit/overlays.py` | tutorial `edit.py` 400–440, 501–620; trailer `animatic_v2.py` 102–145 | Keycaps, box/ring, loupe, title/chapter/end geometry rewritten for dimensions/tokens; cursor/ripples are new |
| `tools/media/edit/render.py` | trailer `animatic_v2.py` 450–511 | Crop, concat and overlay graph; FFmpeg on PATH, portable codec, frame-count validation and bounded-memory loupe sampling |
| `tools/media/edit/audio.py` | trailer `animatic_v2.py` 557–566 | Two-pass measured loudnorm, changed −14 to −16 LUFS / −1 dBTP; aligned audio placement is new |
| `tools/media/edit/subtitles.py` | tutorial `edit.py` 1039–1048 | SRT clock/output model; added VTT, ordering, escaping and millisecond validation |

These are adaptations with substantial rewrites, not literal line-for-line ports.
The implementation report records final destination line counts. The CLI wrappers,
tests, budget gate, ScreenCaptureKit recorder and static page are new.

Left out: game capture (`capture.ts`, `director.js`, `probe.ts`, shots, autopilot),
offline WebAudio/game/radio DSP, SFX, retro/CRT art, music analysis (would require
numpy/librosa), hard-coded private paths, system fonts, Poppins, provider helpers,
credit ledgers and upload/deploy scripts. Provider calls are unnecessary for this
offline track; no ElevenLabs/Scribe code or credentials are carried over.

DM Sans and JetBrains Mono were already bundled in `shared/fonts`; their OFL
files and existing root notices cover unmodified use in rendered media. The page
uses the system monospace stack and DM Sans headings. Geist Mono is not added.

Pillow **13.0.0**, matching `tools/brand/requirements.txt`, is a pinned development
runtime only. It is installed from PyPI and is not bundled or linked into either
app. Its HPND licence and the exact wheel's dependency notices are available in
`pillow-13.0.0.dist-info/licenses/LICENSE` after installation (project source:
<https://github.com/python-pillow/Pillow/tree/13.0.0>). These dev-tool licences do
not belong in the root `THIRD_PARTY_NOTICES.md`, which ships in the apps. Node and
Swift tooling add no new packaged runtime dependencies.
