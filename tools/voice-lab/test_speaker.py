import math
import unittest
from calibration import choose_threshold
from check import check


class SpeakerCalibrationTests(unittest.TestCase):
    def test_requires_counts(self):
        with self.assertRaises(ValueError):
            choose_threshold([0.1] * 199, [0.9] * 50)
        with self.assertRaises(ValueError):
            choose_threshold([0.1] * 200, [0.9] * 49)

    def test_rejects_nonfinite(self):
        with self.assertRaises(ValueError):
            choose_threshold([math.nan] * 200, [0.9] * 50)

    def test_ties_are_not_false_passes(self):
        chosen, curve = choose_threshold([0.8] * 200, [0.9] * 50)
        self.assertGreater(chosen[0], 0.8)
        self.assertEqual(chosen[1:], [0, 1])
        self.assertTrue(curve)

    def test_never_manufactures_failed_threshold(self):
        chosen, curve = choose_threshold([0.9] * 200, [0.8] * 50)
        self.assertIsNone(chosen)
        self.assertTrue(curve)

    def test_accepts_boundary_rates(self):
        chosen, _ = choose_threshold([0.2] * 198 + [0.8] * 2, [0.9] * 48 + [0.1] * 2)
        self.assertLessEqual(chosen[1], 0.01)
        self.assertGreaterEqual(chosen[2], 0.95)

    def test_committed_fixture_drift(self):
        check()


if __name__ == "__main__":
    unittest.main()
