"""The calibration's fit is pure and deterministic (W7): a fixed synthetic paired set (numbers only, no images) gives the same
constants every time, recovers the maps it was built from, and agrees with itself through the shared decisions.

  python3 -I -m unittest discover -s tools/frames/calibrate -p "test_*.py"
"""
import importlib.util
import json
import math
import pathlib
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('calibrate', pathlib.Path(__file__).resolve().parent / 'calibrate.py')
calibrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibrate)

# The maps the synthetic Mac numbers are made with.
EYE, YAW, PITCH = (0.70, 0.06), (1.10, -0.01), (-1.40, 0.02)
W0, W1, W2, PITCH0 = 0.15, 0.40, 0.03, 0.05


def synthetic_rows():
    """Two subjects, 60 frames each at 10 fps: eyes opening and closing, the head turning and nodding, sharpness varying. The Mac's
    numbers are exact functions of the Windows raw numbers, so the fit has one right answer."""
    rows = []
    for subject in ('a', 'b'):
        for index in range(60):
            phase = index / 60 * 2 * math.pi + (0.5 if subject == 'b' else 0)
            raw_eye = 0.12 + 0.25 * (0.5 + 0.5 * math.sin(3 * phase))
            mesh_yaw = 0.3 * math.sin(phase)
            mesh_pitch = -0.1 + 0.15 * math.cos(2 * phase)
            variance = 20 + 500 * (0.5 + 0.5 * math.cos(5 * phase))
            eyes = EYE[0] * raw_eye + EYE[1]
            yaw = YAW[0] * mesh_yaw + YAW[1]
            pitch = PITCH[0] * mesh_pitch + PITCH[1]
            eyes_open = min(1, max(0, (eyes - 0.12) / 0.14))
            facing = min(1, max(0, 1 - max(abs(yaw), abs(pitch - PITCH0)) / 0.6))
            sharp = min(1, max(0, (math.log(variance) - math.log(30)) / (math.log(400) - math.log(30))))
            quality = W0 + W1 * eyes_open * facing + W2 * sharp
            rect = {'x': 0.4, 'y': 0.3, 'width': 0.2, 'height': 0.35}
            rows.append({
                'sha256': f'{subject}{index:03d}', 'time': round(index / 10, 3), 'video': f'video-{subject}', 'segment': 0, 'subject': subject,
                'mac': {'faceCount': 1, 'face': {'rect': rect, 'captureQuality': quality, 'leftEyeAspect': eyes, 'rightEyeAspect': eyes,
                                                 'yaw': yaw, 'pitch': pitch}},
                'windows': {'faceCount': 1, 'face': {'rect': rect, 'rawLeftEye': raw_eye, 'rawRightEye': raw_eye, 'meshYaw': mesh_yaw,
                                                     'meshPitch': mesh_pitch, 'sharpnessVariance': variance, 'meanLuma': 120.0,
                                                     'clippedFraction': 0.01, 'faceWidthPixels': 200.0}},
            })
    return rows


class FitTests(unittest.TestCase):
    def test_the_fit_is_deterministic(self):
        first = calibrate.fit_constants(synthetic_rows())
        second = calibrate.fit_constants(synthetic_rows())
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(second, sort_keys=True))

    def test_the_fit_recovers_the_maps_and_weights(self):
        constants = calibrate.fit_constants(synthetic_rows())
        self.assertEqual(constants['eyeAspect'], {'a': EYE[0], 'b': EYE[1]})
        self.assertEqual(constants['yaw'], {'a': YAW[0], 'b': YAW[1]})
        self.assertEqual(constants['pitch'], {'a': PITCH[0], 'b': PITCH[1]})
        quality = constants['quality']
        self.assertEqual((quality['w0'], quality['w1'], quality['w2'], quality['pitch0']), (W0, W1, W2, PITCH0))
        # No face is past a fixed gate, so every gate stays the study's.
        self.assertEqual(quality['gates'], calibrate.FIXED_GATES)
        self.assertTrue(all(note.startswith('kept fixed') for note in constants['gateNotes'].values()))
        # The Windows score already is Vision's, so the quantile map is the identity at p10..p90.
        self.assertEqual(len(quality['quantileMap']), 5)
        for windows, vision in quality['quantileMap']:
            self.assertAlmostEqual(windows, vision, places=3)

    def test_a_perfect_calibration_agrees_everywhere(self):
        rows = synthetic_rows()
        numbers = calibrate.evaluate(rows, calibrate.calibration_from(calibrate.fit_constants(rows)))
        for name in ('facePresence', 'eyes', 'facing', 'quality025', 'quality040', 'opening'):
            self.assertEqual(numbers[name]['share'], 1.0, name)
        self.assertEqual(numbers['opening']['of'], 2 * (60 - 12))
        self.assertLess(numbers['coverRegretP90'], 1e-9)
        self.assertEqual(calibrate.passes(numbers), [])

    def test_a_gate_is_fitted_only_with_evidence(self):
        rows = synthetic_rows()
        for row in rows[:40]:
            row['windows']['face']['meanLuma'] = 20.0
            row['mac']['face']['captureQuality'] = 0.02
        constants = calibrate.fit_constants(rows)
        self.assertTrue(constants['gateNotes']['lumaLow'].startswith('fitted'))
        self.assertGreater(constants['quality']['gates']['luma'][0], 20.0)
        self.assertTrue(constants['gateNotes']['minimumFaceWidth'].startswith('kept fixed'))


if __name__ == '__main__':
    unittest.main()
