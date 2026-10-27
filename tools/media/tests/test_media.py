"""Synthetic-only verification. Scratch stays in /tmp/voxclip-sol-launch-tooling."""
import hashlib
import json
from pathlib import Path
import shutil
import stat
import tempfile
import sys
import subprocess
from unittest.mock import patch
import unittest

from PIL import Image, ImageChops, ImageDraw, ImageStat

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_budget import check
from shots import export, normalize
from edit.art import contact_sheet, cover, palette
from edit.audio import executable, loudnorm, mix_narration, probe, run
from edit.model import events_by_step, resolve_beats, timeline_events
from edit.overlays import KINDS, render_overlay
from edit.render import clip_filter, render
from edit.subtitles import subtitles, timestamp

SCRATCH_ROOT = Path('/tmp/voxclip-sol-launch-tooling')


class MediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global SCRATCH
        SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
        SCRATCH = Path(tempfile.mkdtemp(prefix="python-tests-", dir=SCRATCH_ROOT))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(SCRATCH)

    def test_stills_and_determinism(self):
        image = Image.new('RGBA', (3000, 1900))
        ImageDraw.Draw(image).rounded_rectangle((150, 100, 2850, 1750), 12, fill='#dddddd')
        self.assertEqual(normalize(image, 'macos').tobytes(), image.tobytes())
        windows = normalize(image.crop((30, 20, 570, 350)), 'windows')
        self.assertGreater(windows.width, 540)
        self.assertGreater(windows.getpixel((windows.width // 2, windows.height - 10))[3], 0)
        for name in ['a', 'b']:
            export(image, SCRATCH / name, 'macos')
        for path in (SCRATCH / 'a').iterdir():
            self.assertEqual(path.read_bytes(), (SCRATCH / 'b' / path.name).read_bytes())
        for name, size in [('readme.webp', (1600, 1013)), ('site.webp', (2400, 1520)), ('social.png', (1280, 640))]:
            with Image.open(SCRATCH / 'a' / name) as exported:
                self.assertEqual(exported.size, size)
        for platform in ['macos', 'windows']:
            small = Image.new('RGBA', (600, 380), '#dddddd')
            export(small, SCRATCH / platform, platform)
            for name in ['readme', 'site']:
                with Image.open(SCRATCH / platform / f'{name}.webp') as still:
                    self.assertLessEqual(still.width, small.width)
        with self.assertRaisesRegex(ValueError, 'upscale'):
            cover(image, 3200, 2000)
        self.assertLess((SCRATCH / 'a/social.png').stat().st_size, 1_000_000)
        self.assertEqual(cover(image, 128, 128).size, (128, 128))
        self.assertGreater(contact_sheet([image, image], columns=2).width, 640)

    def test_cursor_click_and_loupe_geometry(self):
        base = Image.new('RGB', (320, 180), '#888888')
        ImageDraw.Draw(base).rectangle((20, 20, 60, 60), fill='#ee2222')
        events = [{'step': 'click', 'timestamp': 0, 'targetFrame': [80, 80, 20, 20], 'click': True}]
        pointer = render_overlay(base, .1, [], events)
        self.assertGreater(pointer.getpixel((92, 94))[3], 0)
        self.assertGreater(pointer.getpixel((98, 90))[3], 0)  # expanding click ripple
        loupe = render_overlay(base, .5, [{'kind': 'loupe', 'start': 0, 'end': 1, 'rect': [20, 20, 40, 40],
                                          'position': [250, 80], 'radius': 30, 'zoom': 2}], [])
        self.assertEqual(loupe.getpixel((250, 80)), (238, 34, 34, 255))

    def test_every_overlay_draws_and_cards_hide_pointer(self):
        base = Image.new('RGB', (320, 180), '#888888')
        ImageDraw.Draw(base).rectangle((20, 20, 60, 60), fill='#ee2222')
        probes = {'keycap': (30, 40), 'box': (20, 40), 'ring': (20, 40),
                  'loupe': (250, 80), 'title': (10, 10), 'chapter': (10, 10), 'end': (10, 10)}
        for kind, point in probes.items():
            with self.subTest(kind=kind):
                spec = {'kind': kind, 'start': 0, 'end': 1, 'text': 'Cut', 'rect': [20, 20, 40, 40],
                        'position': [250, 80], 'radius': 30, 'zoom': 2}
                layer = render_overlay(base, .25, [spec], [])
                self.assertEqual(layer.getpixel(point)[3], 255)
                self.assertNotEqual(layer.getpixel(point)[:3], base.getpixel(point))
        for kind in ['title', 'chapter', 'end']:
            for timestamp in [0, .1, .4]:  # parked pointer, interpolation and live ripples
                events = [{'step': 'before', 'timestamp': timestamp, 'targetFrame': [5, 130, 10, 10], 'click': True},
                          {'step': 'after', 'timestamp': 2, 'targetFrame': [30, 140, 10, 10], 'click': True}]
                card = {'kind': kind, 'start': .2, 'end': 1, 'text': 'Title'}
                with_events = render_overlay(base, .4, [card], events)
                without = render_overlay(base, .4, [card], [])
                self.assertEqual(with_events.tobytes(), without.tobytes())
                expected = Image.new('RGBA', (70, 50), palette()['ink'])
                self.assertEqual(with_events.crop((0, 125, 70, 175)).tobytes(), expected.tobytes())

    def test_keycap_contrast(self):
        colors = palette()
        def luminance(hex_color):
            rgb = [v / 255 for v in bytes.fromhex(hex_color.lstrip('#'))]
            linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in rgb]
            return sum(a * b for a, b in zip(linear, [.2126, .7152, .0722]))
        def contrast(a, b):
            values = sorted([luminance(a), luminance(b)])
            return (values[1] + .05) / (values[0] + .05)
        self.assertGreaterEqual(contrast(colors['accent'], colors['raised']), 3)
        self.assertGreaterEqual(contrast(colors['pressedLabel'], colors['accent']), 4.5)
        self.assertGreaterEqual(contrast(colors['paper'], colors['raised']), 4.5)
        base = Image.new('RGB', (320, 180))
        spec = {'kind': 'keycap', 'start': 0, 'end': 1, 'text': 'Cut', 'rect': [20, 20, 80, 40]}
        for pressed, fill, label in [(False, colors['raised'], colors['paper']),
                                     (True, colors['accent'], colors['pressedLabel'])]:
            layer = render_overlay(base, .25, [{**spec, 'pressed': pressed}], [])
            self.assertEqual(layer.getpixel((30, 30))[:3], tuple(bytes.fromhex(fill[1:])))
            self.assertIn(tuple(bytes.fromhex(label[1:])) + (255,), set(layer.crop((25, 25, 95, 55)).get_flattened_data()))

    def test_crop_focus_validation(self):
        self.assertIn(':(ih-oh)*0.5,', clip_filter(0, 1, 320, 180))
        for key in ['focus', 'focusY']:
            for value in [-.1, 1.1, float('nan'), True, '0.5']:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    clip_filter(0, 1, 320, 180, **{key: value})

    def test_alignment_and_subtitles(self):
        events = [{'step': 'clip', 'timestamp': 2, 'targetFrame': [1, 2, 3, 4]}]
        beats = [{'source': 'capture.mp4', 'duration': 3, 'align': {'word': 0, 'step': 'clip', 'lead': .1}}]
        planned = resolve_beats(beats, [{'start': .5, 'end': .8}], events)
        self.assertAlmostEqual(planned[0]['narrationStart'] + .5, 1.9)
        mapped = timeline_events([{'sourceStart': 1, 'duration': 2, 'outputStart': 0},
                                  {'sourceStart': 1, 'duration': 2, 'outputStart': 2}], events)
        self.assertEqual([event['timestamp'] for event in mapped], [1, 3])
        with self.assertRaises(ValueError):
            events_by_step(events + events)
        with self.assertRaises(ValueError):
            resolve_beats(beats, [{'start': 3, 'end': 4}], events)
        cues = [{'start': 0, 'end': 1.2, 'text': 'Don\'t cut "<words>" & keep.' }]
        self.assertIn('00:00:00,000 --> 00:00:01,200', subtitles(cues))
        self.assertIn('WEBVTT\n\n', subtitles(cues, True))
        self.assertIn('Don\'t cut "words" & keep.', subtitles(cues))
        self.assertIn('Don\'t cut "&lt;words&gt;" &amp; keep.', subtitles(cues, True))
        for vtt in [False, True]:
            self.assertNotIn('&#x27;', subtitles(cues, vtt))
            self.assertNotIn('&quot;', subtitles(cues, vtt))
        self.assertEqual(timestamp(3599.9996), '01:00:00,000')
        with self.assertRaises(ValueError):
            subtitles([{'start': 1, 'end': .5, 'text': 'bad'}])

    def test_budget_failures(self):
        repo = SCRATCH / 'budget'
        root = repo / 'doc/media'
        (root / 'teaser').mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        def track():
            subprocess.run(['git', '-C', str(repo), 'add', 'doc/media'], check=True)
        (root / 'still.png').write_bytes(b'0' * 300_001)
        track()
        self.assertTrue(check(root)[0])
        (root / 'still.png').unlink()
        # Minimal animated WebP header; enough to exercise the standard-library budget gate.
        (root / 'teaser/animated.webp').write_bytes(b'RIFF' + (0).to_bytes(4, 'little') + b'WEBPANIM' + (0).to_bytes(4, 'little') + b'0' * 2_900_000)
        track()
        self.assertFalse(check(root)[0])
        (root / '.DS_Store').write_bytes(b'finder')
        (root / 'master.mov').write_bytes(b'0' * 6_000_001)
        self.assertFalse(check(root)[0])
        (root / '.DS_Store').unlink()
        (root / 'master.mov').unlink()
        (root / 'video.mp4').write_bytes(b'video')
        track()
        self.assertTrue(check(root)[0])
        (root / 'video.mp4').unlink()
        (root / 'teaser/b.webp').write_bytes((root / 'teaser/animated.webp').read_bytes())
        (root / 'teaser/c.webp').write_bytes((root / 'teaser/animated.webp').read_bytes())
        track()
        self.assertIn('total', '\n'.join(check(root)[0]))

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'local render test requires FFmpeg and FFprobe; hosted CI skips it')
    def test_three_second_edit(self):
        ffmpeg = executable('ffmpeg')
        source = SCRATCH / 'synthetic.mkv'
        run([ffmpeg, '-v', 'error', '-nostdin', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=30:duration=3',
             '-threads', '1', '-c:v', 'ffv1', str(source)])
        audio = SCRATCH / 'tone.wav'
        run([ffmpeg, '-v', 'error', '-nostdin', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3:sample_rate=48000', str(audio)])
        normalized = SCRATCH / 'normalized.wav'
        loudnorm(audio, normalized)
        mixed = mix_narration([{'narration': str(audio), 'narrationStart': .5, 'sourceStart': 0, 'outputStart': 0, 'duration': 3.5}], 3.5, SCRATCH)
        with self.assertRaisesRegex(ValueError, 'narration does not fit its beat'):
            mix_narration([{'narration': str(audio), 'narrationStart': .5, 'sourceStart': 0,
                            'outputStart': 0, 'duration': 3}], 3, SCRATCH)
        with self.assertRaisesRegex(RuntimeError, 'ffmpeg failed.*') as error:
            run([ffmpeg, '-v', 'error', '-i', str(SCRATCH / 'missing.mp4'), '-f', 'null', '-'])
        self.assertIn('No such file', str(error.exception))
        import array
        import subprocess
        raw = subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-i', str(mixed), '-f', 'f32le', '-ac', '1', '-ar', '48000', '-'], check=True, capture_output=True).stdout
        samples = array.array('f', raw)
        self.assertEqual(max(abs(v) for v in samples[:20000]), 0)
        self.assertGreater(max(abs(v) for v in samples[26000:30000]), .01)
        measurement = run([ffmpeg, '-hide_banner', '-nostdin', '-i', str(normalized), '-af', 'loudnorm=I=-16:TP=-1:print_format=json', '-f', 'null', '-'])
        data = json.loads(measurement.stderr[measurement.stderr.rindex('{'):measurement.stderr.rindex('}') + 1])
        self.assertAlmostEqual(float(data['input_i']), -16, delta=.3)
        self.assertLessEqual(float(data['input_tp']), -1)
        kinds = ['title', 'chapter', 'keycap', 'box', 'ring', 'loupe', 'end']
        overlays = [{'kind': kind, 'start': index * .4, 'end': (index + 1) * .4,
                     'text': 'Cut words', 'rect': [24, 60, 80, 32]} for index, kind in enumerate(kinds)]
        self.assertEqual(set(kinds), KINDS)
        events = [{'step': 'select', 'timestamp': .8, 'targetFrame': [130, 110, 20, 16], 'click': True},
                  {'step': 'export', 'timestamp': 2.4, 'targetFrame': [270, 140, 20, 16], 'click': True}]
        spec = {'size': [320, 180], 'fps': 30, 'audio': str(audio),
                'clips': [{'source': str(source), 'duration': 1.5}, {'source': str(source), 'sourceStart': 1.5, 'duration': 1.5}],
                'overlays': overlays, 'cues': [{'start': 0, 'end': 2.8, 'text': 'Keep the words.'}]}
        (SCRATCH / 'second.mp4').write_bytes(b'previous output')
        (SCRATCH / 'second.mp4').chmod(0o640)
        for name in ['first', 'second']:
            result = render(spec, SCRATCH / f'{name}.mp4', SCRATCH / name, events)
            stream = next(s for s in result['streams'] if s['codec_type'] == 'video')
            self.assertEqual((stream['width'], stream['height']), (320, 180))
            self.assertEqual(int(stream['nb_frames']), 90)
            self.assertAlmostEqual(float(result['format']['duration']), 3, delta=.05)
        self.assertEqual(stat.S_IMODE((SCRATCH / 'first.mp4').stat().st_mode),
                         stat.S_IMODE((SCRATCH / 'first.srt').stat().st_mode))
        self.assertEqual(stat.S_IMODE((SCRATCH / 'second.mp4').stat().st_mode), 0o640)
        for suffix in ['.mp4', '.contact.png', '.srt', '.vtt']:
            self.assertEqual(hashlib.sha256((SCRATCH / ('first' + suffix)).read_bytes()).digest(),
                             hashlib.sha256((SCRATCH / ('second' + suffix)).read_bytes()).digest(), suffix)
        self.assertEqual((SCRATCH / 'first/timeline.json').read_bytes(), (SCRATCH / 'second/timeline.json').read_bytes())
        for index, kind in enumerate(kinds):
            time = index * .4 + .2
            paths = [SCRATCH / 'decoded.png', SCRATCH / 'base.png']
            for input_path, output_path in zip([SCRATCH / 'first.mp4', source], paths):
                run([ffmpeg, '-v', 'error', '-nostdin', '-y', '-ss', str(time), '-i', str(input_path), '-frames:v', '1', str(output_path)])
            with Image.open(paths[0]) as actual, Image.open(paths[1]) as base:
                expected = Image.alpha_composite(base.convert('RGBA'), render_overlay(base, time, overlays, events)).convert('RGB')
                difference = sum(ImageStat.Stat(ImageChops.difference(actual.convert('RGB'), expected)).mean) / 3
                self.assertLess(difference, 5, kind)
                roi = (215, 35, 280, 105) if kind == 'loupe' else (24, 60, 104, 92)
                absent = Image.alpha_composite(base.convert('RGBA'), render_overlay(base, time, [], events)).convert('RGB')
                mean_diff = lambda a, b: sum(ImageStat.Stat(ImageChops.difference(a.crop(roi), b.crop(roi))).mean) / 3
                error = mean_diff(actual.convert('RGB'), expected)
                self.assertGreater(mean_diff(actual.convert('RGB'), absent), max(3, 2 * error + 3), kind)
        with self.assertRaisesRegex(ValueError, 'upscale'):
            render({**spec, 'size': [640, 360]}, SCRATCH / 'upscaled.mp4', SCRATCH / 'upscaled')
        failed_output = SCRATCH / 'failed.mp4'
        failed_output.write_bytes(b'previous output')
        with self.assertRaisesRegex(RuntimeError, 'ffmpeg failed'):
            render(spec, failed_output, SCRATCH / 'failed-encode', encoder='encoder_does_not_exist')
        self.assertEqual(failed_output.read_bytes(), b'previous output')
        self.assertFalse(list(SCRATCH.glob('.failed-*.mp4')))
        invalid = {**spec, 'clips': [{'source': str(source), 'duration': 3, 'focus': 0.5}]}
        with patch('edit.render.clip_filter', return_value='[0:v]missing_filter[v0]'):
            with self.assertRaisesRegex(RuntimeError, 'No such filter'):
                render(invalid, SCRATCH / 'decode-failure.mp4', SCRATCH / 'decode-failure')
        # A taller-than-target source exercises default, top and bottom vertical focus.
        tall = Image.new('RGB', (320, 240), '#ee2222')
        ImageDraw.Draw(tall).rectangle((0, 200, 319, 239), fill='#2222ee')
        tall.save(SCRATCH / 'tall.png')
        for focusY, blue_rows in [(0, 0), (.5, 10), (1, 40)]:
            graph = clip_filter(0, 1 / 30, 320, 180, 30, focusY=focusY)
            raw = subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-i', str(SCRATCH / 'tall.png'),
                                  '-filter_complex', graph, '-map', '[v0]', '-frames:v', '1',
                                  '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-threads', '1', '-'],
                                 check=True, capture_output=True).stdout
            cropped = Image.frombytes('RGB', (320, 180), raw)
            self.assertEqual(sum(cropped.getpixel((160, y))[2] > 200 for y in range(180)), blue_rows)
        # Same filter handles the vertical cut. Verify an actual 9:16 output, not just its string.
        graph = clip_filter(0, 3, 90, 160, 30) + ';[v0]format=yuv420p[out]'
        run([ffmpeg, '-v', 'error', '-nostdin', '-y', '-i', str(source), '-filter_complex', graph, '-map', '[out]', '-c:v', 'mpeg4', '-threads', '1', str(SCRATCH / 'portrait.mp4')])
        stream = probe(SCRATCH / 'portrait.mp4')['streams'][0]
        self.assertEqual((stream['width'], stream['height']), (90, 160))


if __name__ == '__main__':
    unittest.main()
