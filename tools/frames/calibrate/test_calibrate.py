"""The calibration's fit is pure and deterministic (W7, W8): a fixed synthetic paired set (numbers only, no images) gives the same
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
        self.assertEqual(quality['sharpness'], [30, 400])
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


def box(width, score, measured=True, x=0.4):
    rect = {'x': x, 'y': 0.3, 'width': width, 'height': width * 1.6}
    face = {'rect': rect, 'faceWidthPixels': width * 1280} if measured else None
    return {'rect': rect, 'detectorScore': score, 'widthAt1280': width * 1280, 'measured': face}


class SpeakerTests(unittest.TestCase):
    """W8: the twin of SpeakerFace (no screens) and the fit of its score."""

    def test_a_weak_larger_box_gives_way_to_a_confident_one_and_is_not_counted(self):
        row = {'windows': {'candidates': [box(0.43, 0.77), box(0.15, 0.94, x=0.66)]}}
        count, face = calibrate.speaker_face(row, 0.85)
        self.assertEqual((count, face['rect']['x']), (1, 0.66))
        # With no speaker score every box is confident: the largest, as W7 read them, and both are counted.
        count, face = calibrate.speaker_face(row, 0.0)
        self.assertEqual((count, face['rect']['x']), (2, 0.4))

    def test_a_box_the_mesh_rejects_is_skipped_and_not_counted(self):
        row = {'windows': {'candidates': [box(0.3, 0.95, measured=False), box(0.2, 0.92), box(0.1, 0.9)]}}
        self.assertEqual(calibrate.speaker_face(row, 0.85)[0], 2)
        self.assertEqual(calibrate.speaker_face({'windows': {'candidates': [box(0.3, 0.9, measured=False)]}}, 0.85), (0, None))

    def test_the_speaker_score_is_the_lowest_speaker_rounded_down(self):
        mac = {'faceCount': 1, 'face': {'rect': {'x': 0.66, 'y': 0.3, 'width': 0.15, 'height': 0.24}}}
        rows = [{'mac': mac, 'windows': {'candidates': [box(0.43, 0.77), box(0.15, score, x=0.66)]}} for score in (0.95, 0.8636, 0.91)]
        cut, evidence = calibrate.fit_speaker_score(rows)
        self.assertEqual(cut, 0.85)
        self.assertEqual(evidence, {'speakers': 3, 'lowestSpeaker': 0.8636, 'others': 3, 'othersFromCut': 0})


class SmallFaceTests(unittest.TestCase):
    def test_the_cut_is_the_top_of_the_highest_band_below_the_overall_agreement(self):
        rows = []
        for index, (width, agree) in enumerate([(50, False)] * 15 + [(50, True)] * 25 + [(170, True)] * 200 + [(170, False)] * 4):
            mac_eyes, raw = 0.30, (0.30 - EYE[1]) / EYE[0] if agree else (0.10 - EYE[1]) / EYE[0]
            rect = {'x': 0.4, 'y': 0.3, 'width': 0.2, 'height': 0.3}
            rows.append({'mac': {'face': {'rect': rect, 'leftEyeAspect': mac_eyes, 'rightEyeAspect': mac_eyes}},
                         'windows': {'face': {'rect': rect, 'rawLeftEye': raw, 'rawRightEye': raw, 'faceWidthPixels': float(width)}}})
        cut, report = calibrate.fit_eyes_from_width(rows, {'eyeAspect': {'a': EYE[0], 'b': EYE[1]}})
        self.assertEqual(cut, 60)
        self.assertEqual([band['faces'] for band in report['bands'] if band['faces']], [40, 204])

    def test_a_small_face_reports_its_eyes_unknown_and_keeps_its_quality(self):
        rows = synthetic_rows()
        calibration = calibrate.calibration_from(calibrate.fit_constants(rows))
        whole = calibrate.windows_observation(rows[0], calibration)['face']
        small = calibrate.windows_observation(rows[0], calibration | {'eyesFromWidth': 201})['face']
        self.assertEqual((whole['eyes'], small['eyes']), ('open', 'unknown'))
        self.assertNotIn('leftEyeAspect', small)
        self.assertEqual(whole['captureQuality'], small['captureQuality'])
        numbers = calibrate.evaluate(rows, calibration | {'eyesFromWidth': 201})
        self.assertEqual((numbers['eyes']['of'], numbers['eyesUnknown']), (0, 120))
        # Counted the way the decisions read an unknown (not an open look), every open Vision frame disagrees.
        self.assertEqual(numbers['eyesStrict']['agree'], sum(1 for row in rows if row['mac']['face']['leftEyeAspect'] < 0.2))


class RecordingOffsetTests(unittest.TestCase):
    """W8: the per-recording quality offset is deterministic and reads only the recording's own frames."""

    def test_the_offset_uses_only_the_recordings_own_frames(self):
        rows = synthetic_rows()
        calibration = calibrate.calibration_from(calibrate.fit_constants(rows))
        first = calibrate.recording_offset(rows, calibration, 0.5, 0.52)
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(calibrate.recording_offset(rows, calibration, 0.5, 0.52), sort_keys=True))
        # Changing recording b's frames moves none of recording a's qualities.
        changed = [dict(row, windows=dict(row['windows'], face=dict(row['windows']['face'], sharpnessVariance=5.0)))
                   if row['subject'] == 'b' else row for row in rows]
        second = calibrate.recording_offset(changed, calibration, 0.5, 0.52)
        for key, observation in first.items():
            if key.startswith('a'):
                self.assertEqual(observation, second[key])
        self.assertNotEqual([first[k] for k in first if k.startswith('b')], [second[k] for k in second if k.startswith('b')])

    def test_strength_zero_is_the_plain_observation_and_the_fit_is_deterministic(self):
        rows = synthetic_rows()
        calibration = calibrate.calibration_from(calibrate.fit_constants(rows))
        plain = {row['sha256'] + str(row['time']): calibrate.windows_observation(row, calibration) for row in rows}
        self.assertEqual(calibrate.recording_offset(rows, calibration, 0.0, 0.52), plain)
        self.assertEqual(calibrate.fit_recording_offset(rows, calibration), calibrate.fit_recording_offset(rows, calibration))
        # A perfect calibration needs no offset.
        self.assertEqual(calibrate.fit_recording_offset(rows, calibration)[0], 0.0)


if __name__ == '__main__':
    unittest.main()
