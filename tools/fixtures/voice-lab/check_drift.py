#!/usr/bin/env python3
"""Compare regenerated Voice Lab fixtures with exact or explicitly tolerant expectations.

The audio-math generator calls libm (log10, tan, pow) and NumPy reductions whose last bits differ between
platforms: a hosted Ubuntu runner and an Apple silicon Mac disagree by 1 ULP on some coefficients and by up to
~1e-13 on accumulated loudness values. Such a file passes when its structure, strings, booleans and integers are
identical and every float agrees within REL_TOL / ABS_TOL; the committed bytes are then restored so the
byte-exact `git diff --exit-code` that follows checks only the other generators. Acceptance-set vectors also
contain computed duration/trim floats and use the same tolerance. Window, several-window, continuity, scope rewrite plan
and diff, LLM send cost, training span, enrollment and take batch vectors have an explicit byte-exact expectation, never float
tolerance. Both Cores replay enrollment (including local retries and bounded/corrupt recovery journals),
the corrected acceptance set and its empty-set review file.
Run from the repository root, after the generators."""
import json
import math
import subprocess
import sys
from pathlib import Path

TOLERANT = ['shared/fixtures/voice-lab/audio-math-cases.json',
            'shared/fixtures/voice-lab/accept-all-cases.json',
            # The tone match (voice-lab section 8.7 item 2b): libm tan/pow/cos/sin/log10 in its coefficients and FFT.
            'shared/fixtures/voice-lab/tilt-cases.json']
EXACT = ['shared/fixtures/voice-lab/pace-cases.json', 'shared/fixtures/voice-lab/dialogue-cases.json', 'shared/fixtures/voice-lab/continuity-cases.json', 'shared/fixtures/voice-lab/scope-rewrite-plan-cases.json',
         'shared/fixtures/voice-lab/autofit-cases.json',
         'shared/fixtures/voice-lab/lipsync-window-cases.json',
         'shared/fixtures/voice-lab/lipsync-project-cases.json',
         'shared/fixtures/voice-lab/homophone-word-check-cases.json',
         'shared/fixtures/voice-lab/rewrite-next-actions-cases.json',
         'shared/fixtures/voice-lab/hard-join-cases.json',
         'shared/fixtures/voice-lab/audio-tag-cases.json',
         'shared/fixtures/voice-lab/v4-timing-cases.json',
         'shared/fixtures/voice-lab/recorded-take-cases.json',
         'shared/fixtures/voice-lab/hard-join-review-cases.json',
         'shared/fixtures/voice-lab/phrase-timing-cases.json',
         'shared/fixtures/voice-lab/tts-estimator-cases.json',
         'shared/fixtures/voice-lab/rewrite-slot-cases.json',
         'shared/fixtures/voice-lab/pace-matching-cases.json',
         'shared/fixtures/voice-lab/natural-pacing-cases.json',
         'shared/fixtures/voice-lab/video-framing-cases.json',
         'shared/fixtures/voice-lab/natural-pacing-review-cases.json',
         'shared/fixtures/voice-lab/scope-rewrite-diff-cases.json', 'shared/fixtures/voice-lab/llm-send-cost-cases.json',
         'shared/fixtures/voice-lab/training-spans.json', 'shared/fixtures/voice-lab/take-batch-cases.json',
         'shared/fixtures/voice-lab/enrollment-cases.json',
         'shared/fixtures/voice-lab/voice-references-cases.json',
         'shared/fixtures/voice-lab/voice-rebuild-cases.json',
         'shared/fixtures/voice-lab/whole-clip-revoice-project.voxclip',
         'shared/fixtures/voice-lab/whole-clip-revoice-wire-cases.json',
         'shared/fixtures/voice-lab/whole-clip-revoice-cases.json',
         'shared/fixtures/voice-lab/accept-all-review-cases.json',
         'shared/fixtures/voice-lab/window-cases.json', 'shared/fixtures/voice-lab/window-all-cases.json',
         'shared/fixtures/v2/paragraphs.json', 'shared/fixtures/v2/timeline-cases.json',
         'shared/fixtures/music/music-project.voxclip', 'shared/fixtures/music/music-wire-cases.json',
         'shared/fixtures/music/music-mix-cases.json',
         'shared/fixtures/loudness/social-loudness-cases.json',
         'shared/fixtures/loudness/social-limiter-cases.json',
         'shared/fixtures/clip-effects/effects-project.voxclip', 'shared/fixtures/clip-effects/effects-wire-cases.json',
         'shared/fixtures/ask-claude/ask-claude-cases.json',
         'shared/fixtures/clip-controls/clip-controls-project.voxclip', 'shared/fixtures/clip-controls/clip-controls-wire-cases.json',
         'shared/fixtures/clip-frames/clip-frames-project.voxclip', 'shared/fixtures/clip-frames/clip-frames-wire-cases.json',
         'shared/fixtures/autopilot/plan-frames-cases.json', 'shared/fixtures/autopilot/plan-validation-cases.json',
         'shared/fixtures/autopilot/plan-v2-cases.json', 'shared/fixtures/autopilot/plan-tone-cases.json',
         'shared/fixtures/clip-render/clip-render-cases.json',
         'shared/fixtures/clips-mode/clips-mode-settings-cases.json',
         'shared/fixtures/clip-style/caption-look-cases.json',
         'shared/fixtures/caption-translations/caption-translation-cases.json',
         'shared/data/rewrite-tones.json',
         'shared/schemas/project.schema.json']
REL_TOL = 1e-10
ABS_TOL = 1e-12


def differences(committed, regenerated, where='$'):
    if isinstance(committed, float) and isinstance(regenerated, float):
        close = math.isclose(committed, regenerated, rel_tol=REL_TOL, abs_tol=ABS_TOL)
        return [] if close else [f'{where}: {committed!r} -> {regenerated!r}']
    if type(committed) is not type(regenerated):
        return [f'{where}: {committed!r} -> {regenerated!r}']
    if isinstance(committed, dict):
        if list(committed) != list(regenerated):
            return [f'{where}: keys {list(committed)} -> {list(regenerated)}']
        return [line for key in committed for line in differences(committed[key], regenerated[key], f'{where}.{key}')]
    if isinstance(committed, list):
        if len(committed) != len(regenerated):
            return [f'{where}: {len(committed)} items -> {len(regenerated)}']
        return [line for index, pair in enumerate(zip(committed, regenerated))
                for line in differences(*pair, f'{where}[{index}]')]
    return [] if committed == regenerated else [f'{where}: {committed!r} -> {regenerated!r}']


def main():
    # CI enumerates the older voice-lab generator directory; include the independent WC1 generator here.
    root = Path(__file__).resolve().parents[3]
    subprocess.run([sys.executable, str(root / "tools/fixtures/v2/generate_v2.py")], check=True)
    # The background-music schema field and its shared vectors (doc/spec/music.md section 2).
    subprocess.run([sys.executable, str(root / "tools/schemas/generate_music_schema.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/music/generate_music.py")], check=True)
    # The music bed's levels and timing (doc/spec/music.md section 4), replayed by Windows; the Mac replay is owed.
    subprocess.run([sys.executable, str(root / "tools/fixtures/music/generate_music_mix.py")], check=True)
    # Social loudness at export and its true-peak limiter (ADR-R47), replayed by both Cores; rounded to 6 decimals, so byte-exact.
    subprocess.run([sys.executable, str(root / "tools/fixtures/loudness/generate_social_loudness.py")], check=True)
    # The clip-effects schema field and its shared vectors (doc/spec/ai.md section 18.2), after the music field.
    subprocess.run([sys.executable, str(root / "tools/schemas/generate_clip_effects_schema.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/clip-effects/generate_clip_effects.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/ask-claude/generate_ask_claude.py")], check=True)
    # The clip-controls schema field and its shared vectors (doc/design.md section 6.9).
    subprocess.run([sys.executable, str(root / "tools/schemas/generate_clip_controls_schema.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/clip-controls/generate_clip_controls.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/schemas/generate_clip_frames_schema.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/clip-frames/generate_clip_frames.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/autopilot/generate_plan_frames.py")], check=True)
    # The clip style's tone (doc/design.md section 6.6) and the Rewrite tone catalog (section 6.3.1).
    subprocess.run([sys.executable, str(root / "tools/schemas/generate_clip_style_tone_schema.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/voice-lab/generate_rewrite_tones.py")], check=True)
    # Each clip's caption look (doc/design.md section 6.6): the pick's optional keys and the resolution vectors.
    subprocess.run([sys.executable, str(root / "tools/schemas/generate_caption_pick_schema.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/clip-style/generate_caption_looks.py")], check=True)
    # Ask Claude's translated captions (doc/spec/ai.md section 18.2): the schema field and its vectors.
    subprocess.run([sys.executable, str(root / "tools/schemas/generate_caption_translations_schema.py")], check=True)
    subprocess.run([sys.executable, str(root / "tools/fixtures/caption-translations/generate_caption_translations.py")], check=True)
    # The tone match's optional audio.tiltDbPerOctave (voice-lab section 8.7 item 2b), after the other schema fields.
    subprocess.run([sys.executable, str(root / "tools/schemas/generate_tone_match_schema.py")], check=True)
    # The renderer decisions both platforms reproduce for clip controls and effects (design.md sections 6.8, 6.9).
    subprocess.run([sys.executable, str(root / "tools/fixtures/clip-render/generate_clip_render.py")], check=True)
    # Claude mode's settings vectors (doc/design.md section 6.6), replayed by both Cores.
    subprocess.run([sys.executable, str(root / "tools/fixtures/clips-mode/generate_clips_mode.py")], check=True)
    # The bundled sound effects (doc/spec/ai.md section 18.5): the committed WAVs must be the generator's bytes.
    sounds = subprocess.run([sys.executable, str(root / "tools/media/sfx/gen_sfx.py"), "--check"])
    failed = sounds.returncode != 0
    if failed:
        print('::error::shared/data/sfx differs from tools/media/sfx/gen_sfx.py; run it and commit the files')
    for path in EXACT:
        committed_bytes = subprocess.run(['git', 'show', f'HEAD:{path}'], check=True, capture_output=True).stdout
        with open(path, 'rb') as file:
            regenerated_bytes = file.read()
        if committed_bytes != regenerated_bytes:
            failed = True
            print(f'::error::{path} must match byte for byte')
        else:
            print(f'{path}: identical')
    for path in TOLERANT:
        committed_bytes = subprocess.run(['git', 'show', f'HEAD:{path}'], check=True, capture_output=True).stdout
        with open(path, 'rb') as file:
            regenerated_bytes = file.read()
        if regenerated_bytes == committed_bytes:
            print(f'{path}: identical')
            continue
        found = differences(json.loads(committed_bytes), json.loads(regenerated_bytes))
        if found:
            failed = True
            print(f'::error::{path} drifted beyond the float tolerance ({len(found)} values):')
            for line in found[:40]:
                print(f'  {line}')
            continue
        with open(path, 'wb') as file:
            file.write(committed_bytes)
        print(f'{path}: equal within rel {REL_TOL:g} / abs {ABS_TOL:g}; committed bytes restored')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
