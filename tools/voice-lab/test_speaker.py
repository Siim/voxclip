import math
import unittest
from calibration import choose_threshold, conditions_pass, MARGIN_FLOOR
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
        self.assertEqual(chosen[0], 0.8 + MARGIN_FLOOR)
        self.assertEqual(chosen[1:], [0, 1])
        self.assertTrue(curve)

    def test_never_manufactures_failed_threshold(self):
        chosen, curve = choose_threshold([0.9] * 200, [0.8] * 50)
        self.assertIsNone(chosen)
        self.assertTrue(curve)

    def test_accepts_boundary_rates(self):
        chosen, _ = choose_threshold([0.2] * 198 + [0.8] * 2, [0.9] * 48 + [0.1] * 2)
        self.assertLessEqual(chosen[1], 0.005)
        self.assertGreaterEqual(chosen[2], 0.95)

    def test_measured_drift_is_added_above_the_maximum_impostor(self):
        chosen, _ = choose_threshold([0.8] * 200, [0.9] * 50, runtime_drift=0.02)
        self.assertEqual(chosen[0], 0.8 + 0.02)
        self.assertEqual(chosen[1], 0)

    def test_rejects_invalid_drift_and_overflow_threshold(self):
        for drift in [-1, math.nan, math.inf]:
            with self.assertRaises(ValueError):
                choose_threshold([0.1] * 200, [0.9] * 50, drift)
        chosen, _ = choose_threshold([1.0] * 200, [1.0] * 50)
        self.assertIsNone(chosen)

    def test_negative_impostors_do_not_produce_a_negative_threshold(self):
        chosen, _ = choose_threshold([-0.1] * 200, [0.9] * 50)
        self.assertEqual(chosen, [0, 0, 1])

    def test_half_percent_and_each_condition_are_binding(self):
        good = {"impostorPairs": 200, "sameSpeakerPairs": 50, "falseAcceptRate": 0.005, "sameSpeakerPassRate": 0.95}
        self.assertTrue(conditions_pass([good]))
        for bad in [{"falseAcceptRate": 0.006, "sameSpeakerPassRate": 1},
                    {"falseAcceptRate": 0, "sameSpeakerPassRate": 0.949},
                    {"falseAcceptRate": math.nan, "sameSpeakerPassRate": 1}]:
            self.assertFalse(conditions_pass([good, dict(good, **bad)]))
        self.assertFalse(conditions_pass([]))
        self.assertFalse(conditions_pass([dict(good, impostorPairs=199)]))
        self.assertFalse(conditions_pass([dict(good, sameSpeakerPairs=49)]))

    def test_committed_fixture_drift(self):
        check()


if __name__ == "__main__":
    unittest.main()
