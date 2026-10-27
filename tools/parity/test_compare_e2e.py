import json
import tempfile
import unittest
from pathlib import Path

from compare_e2e import CASE_IDS, FIELDS, compare


def reports(directory, platform):
    for case in CASE_IDS:
        result = {"ok": True, "command": "export", "width": 1920, "height": 1080,
                  "fps": 30, "frames": 60, "audioSampleRate": 48000,
                  "audioSamples": 96000, "aspect": "source", "captionStyle": "off",
                  "durationSeconds": 2.0}
        exit_code = 0
        if case == "e2e-5-everything-cut" or (case == "e2e-9-tiny-webm" and platform == "macos"):
            exit_code = 5 if case.startswith("e2e-5") else 3
            result = {"ok": False, "command": "export", "error": {
                "code": "everythingCut" if exit_code == 5 else "unsupportedContainer"}}
        (directory / (case + ".json")).write_text(json.dumps({"caseId": case, "platform": platform,
            "exitCode": exit_code, "result": dict(result, version="9.8.7")}), encoding="utf-8")


class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.mac = root / "mac"
        self.win = root / "win"
        self.mac.mkdir()
        self.win.mkdir()
        reports(self.mac, "macos")
        reports(self.win, "windows")

    def tearDown(self):
        self.temp.cleanup()

    def mutate(self, directory, case, change):
        path = directory / (case + ".json")
        value = json.loads(path.read_text())
        change(value)
        path.write_text(json.dumps(value))

    def test_positive_and_documented_exception(self):
        self.assertEqual([], compare(self.mac, self.win))
        self.mutate(self.win, CASE_IDS[0], lambda report: report["result"].update(durationSeconds=2.001))
        self.assertEqual([], compare(self.mac, self.win))

    def test_every_compared_field_and_duration(self):
        for key in FIELDS:
            with self.subTest(key=key):
                path = self.win / (CASE_IDS[0] + ".json")
                original = path.read_text()
                self.mutate(self.win, CASE_IDS[0], lambda report: report["result"].__setitem__(
                    key, "changed" if key in ("aspect", "captionStyle") else 29))
                self.assertTrue(any(key in error for error in compare(self.mac, self.win)))
                path.write_text(original)
        self.mutate(self.win, CASE_IDS[0], lambda report: report["result"].update(durationSeconds=2.0011))
        self.assertTrue(any("durationSeconds" in error for error in compare(self.mac, self.win)))

    def test_failure_code_and_webm_exception_are_exact(self):
        self.mutate(self.win, "e2e-5-everything-cut", lambda report: report["result"]["error"].update(code="exportFailed"))
        self.assertTrue(any("error.code" in error for error in compare(self.mac, self.win)))
        self.mutate(self.mac, "e2e-9-tiny-webm", lambda report: report["result"]["error"].update(code="decodeFailed"))
        self.assertTrue(any("unsupportedContainer" in error for error in compare(self.mac, self.win)))

    def test_version_matches_on_success_failure_and_webm(self):
        for case in (CASE_IDS[0], "e2e-5-everything-cut", "e2e-9-tiny-webm"):
            with self.subTest(case=case):
                path = self.win / (case + ".json")
                original = path.read_text()
                self.mutate(self.win, case, lambda report: report["result"].update(version="9.8.8"))
                self.assertTrue(any(f"{case}: version" in error for error in compare(self.mac, self.win)))
                path.write_text(original)

    def test_missing_and_empty_versions_fail(self):
        self.mutate(self.win, CASE_IDS[0], lambda report: report["result"].pop("version"))
        self.assertTrue(any("result.version" in error for error in compare(self.mac, self.win)))
        self.mutate(self.win, CASE_IDS[0], lambda report: report["result"].update(version=""))
        self.assertTrue(any("result.version" in error for error in compare(self.mac, self.win)))

    def test_missing_duplicate_malformed_and_wrong_platform(self):
        path = self.win / (CASE_IDS[0] + ".json")
        original = path.read_text()
        path.unlink()
        self.assertTrue(any("missing" in error for error in compare(self.mac, self.win)))
        path.write_text(original)
        (self.win / "duplicate.json").write_text(original)
        self.assertTrue(compare(self.mac, self.win))
        (self.win / "duplicate.json").unlink()
        path.write_text("{")
        self.assertTrue(compare(self.mac, self.win))
        path.write_text(original)
        self.mutate(self.win, CASE_IDS[0], lambda report: report.update(platform="macos"))
        self.assertTrue(any("platform" in error for error in compare(self.mac, self.win)))


if __name__ == "__main__":
    unittest.main()
