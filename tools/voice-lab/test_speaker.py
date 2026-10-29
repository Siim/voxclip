import math
import unittest
from calibration import choose_threshold, conditions_pass, calibration_percentile
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
        self.assertEqual(chosen[0], 0.81)
        self.assertEqual(chosen[1:], [0, 1])
        self.assertTrue(curve)

    def test_never_manufactures_failed_threshold(self):
        chosen, curve = choose_threshold([0.9] * 200, [0.8] * 50)
        self.assertIsNone(chosen)
        self.assertTrue(curve)

    def test_accepts_boundary_rates(self):
        chosen, _ = choose_threshold([0.2] * 199 + [0.8], [0.9] * 95 + [0.1] * 5)
        self.assertEqual(chosen[1:], [0.005, 0.95])

    def test_measured_drift_is_added_above_the_percentile(self):
        chosen, _ = choose_threshold([0.8] * 200, [0.9] * 50, runtime_drift=0.02)
        self.assertEqual(chosen[0], 0.82)
        self.assertEqual(chosen[1], 0)

    def test_percentile_is_linear_and_not_the_maximum(self):
        impostor = [0.2] * 999 + [0.8]
        self.assertAlmostEqual(calibration_percentile(impostor), 0.2006)
        chosen, _ = choose_threshold(impostor, [0.9] * 50)
        self.assertEqual(chosen, [0.21, 0.001, 1])

    def test_rounds_up_without_advancing_an_exact_decimal_boundary(self):
        for score, drift, expected in [(0.438, 0, 0.44), (0.4380000001, 0, 0.45),
                                       (0.438, 0.001, 0.44), (0.438, 0.012, 0.45)]:
            chosen, _ = choose_threshold([score] * 200, [0.9] * 50, drift)
            self.assertEqual(chosen[0], expected)

    def test_disjoint_failure_does_not_refit_the_clean_candidate(self):
        chosen, _ = choose_threshold([0.438] * 200, [0.9] * 50)
        condition = {"impostorPairs": 200, "sameSpeakerPairs": 50,
                     "falseAcceptRate": 0, "sameSpeakerPassRate": 0.94}
        self.assertFalse(conditions_pass([condition]))
        self.assertEqual(chosen[0], 0.44)

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
