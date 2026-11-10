"""Tests for test-watchdog.py: a normal command passes through unchanged; a silent, idle one is sampled and ended.

    python3 apps/macos/scripts/test_watchdog.py

The hang cases use a deliberately silent command (a sleeping process), never a real suite. They never attach a
debugger or use sudo (VOXCLIP_WATCHDOG_NO_ATTACH / VOXCLIP_WATCHDOG_NO_SUDO), so they can't pop up an
authorization dialog.
"""

import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parent / "test-watchdog.py"
_spec = importlib.util.spec_from_file_location("test_watchdog_script", SCRIPT)
watchdog = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(watchdog)

NOISY = (
    "import sys\n"
    "sys.stdout.write('out one\\n'); sys.stdout.flush()\n"
    "sys.stderr.write('err one\\n'); sys.stderr.flush()\n"
    "sys.stdout.buffer.write(b'\\xe2\\x9c\\x94 bytes \\x00 and no newline')\n"
    "sys.exit(3)\n"
)

SLEEPER_C = "#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n"


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="voxclip-watchdog-tests-")
        self.root = Path(self.temporary.name)
        self.env = dict(os.environ, VOXCLIP_WATCHDOG_NO_ATTACH="1", VOXCLIP_WATCHDOG_NO_SUDO="1")
        self.env.pop("GITHUB_ACTIONS", None)

    def tearDown(self):
        self.temporary.cleanup()

    def run_watchdog(self, flags, command, timeout=60):
        return subprocess.run(
            [sys.executable, str(SCRIPT)] + flags + ["--"] + command,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, timeout=timeout, check=False,
        )

    def test_a_normal_command_reports_exactly_as_without_it(self):
        command = [sys.executable, "-c", NOISY]
        direct = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, check=False)
        watched = self.run_watchdog(["--stacks-dir", str(self.root / "stacks")], command)
        self.assertEqual(watched.returncode, 3)
        self.assertEqual(watched.returncode, direct.returncode)
        self.assertEqual(watched.stdout, direct.stdout)
        self.assertEqual(watched.stderr, direct.stderr)
        self.assertFalse((self.root / "stacks").exists(), "a normal run leaves no stacks")

    def test_a_passing_command_exits_zero(self):
        watched = self.run_watchdog([], ["/usr/bin/true"])
        self.assertEqual(watched.returncode, 0)
        self.assertEqual(watched.stdout, b"")
        self.assertEqual(watched.stderr, b"")

    def test_a_signal_death_exits_like_the_shell_reports_it(self):
        watched = self.run_watchdog([], ["/bin/sh", "-c", "kill -TERM $$"])
        self.assertEqual(watched.returncode, 128 + 15)

    def test_steady_output_keeps_a_long_run_alive(self):
        ticker = "import time\nfor i in range(8):\n    print(i, flush=True)\n    time.sleep(0.5)\n"
        watched = self.run_watchdog(
            ["--idle-seconds", "2", "--silent-seconds", "2", "--poll-seconds", "0.25",
             "--stacks-dir", str(self.root / "stacks")],
            [sys.executable, "-c", ticker])
        self.assertEqual(watched.returncode, 0, watched.stderr)
        self.assertEqual(watched.stdout, b"".join(b"%d\n" % i for i in range(8)))
        self.assertFalse((self.root / "stacks").exists())

    def test_a_silent_idle_command_is_sampled_and_ended(self):
        compiler = shutil.which("cc")
        if compiler is None:
            self.skipTest("no C compiler to build a sampleable sleeper")
        source = self.root / "sleeper.c"
        source.write_text(SLEEPER_C)
        sleeper = self.root / "sleeper"
        subprocess.run([compiler, "-o", str(sleeper), str(source)], check=True)
        stacks = self.root / "stacks"

        started = time.monotonic()
        watched = self.run_watchdog(
            ["--idle-seconds", "2", "--poll-seconds", "0.5", "--sample-seconds", "1", "--stacks-dir", str(stacks)],
            [str(sleeper)], timeout=110)
        elapsed = time.monotonic() - started

        self.assertEqual(watched.returncode, watchdog.HUNG_EXIT)
        self.assertLess(elapsed, 60, "ended well before the sleeper's 120 s")
        self.assertIn(b"test-watchdog: no output and under", watched.stderr)
        self.assertIn(b"ended the hung run", watched.stderr)
        self.assertIn(str(stacks).encode(), watched.stderr)
        tree = (stacks / "process-tree.txt").read_text()
        self.assertIn(str(sleeper), tree)
        samples = sorted(stacks.glob("sample-*-sleeper.txt"))
        self.assertEqual(len(samples), 1, sorted(p.name for p in stacks.iterdir()))
        self.assertIn("Call graph", samples[0].read_text(errors="replace"))
        self.assertIn("lldb fflush skipped", (stacks / "SUMMARY.txt").read_text())
        pid = int(samples[0].name.split("-")[1])
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_a_process_that_cannot_be_sampled_still_gets_a_stacks_file(self):
        # /bin/sleep is a platform binary: sample can't attach without root, so the file says what was tried.
        stacks = self.root / "stacks"
        watched = self.run_watchdog(
            ["--idle-seconds", "1", "--poll-seconds", "0.5", "--sample-seconds", "1", "--stacks-dir", str(stacks)],
            ["/bin/sleep", "120"], timeout=110)
        self.assertEqual(watched.returncode, watchdog.HUNG_EXIT)
        samples = sorted(stacks.glob("sample-*-sleep.txt"))
        self.assertEqual(len(samples), 1)
        self.assertTrue(samples[0].read_text().strip())

    def test_silence_alone_fires_only_after_the_longer_limit(self):
        args = argparse.Namespace(idle_seconds=360, silent_seconds=1200, idle_cpu_share=0.05)
        # A caption golden renders 519 s with no output while busy: not hung.
        self.assertIsNone(watchdog.verdict(519, 0, args))
        # Busy but silent past the hard limit: hung.
        self.assertIn("still using CPU", watchdog.verdict(1200, 0, args))
        # Silent and idle for six minutes: hung.
        self.assertIn("no output and under", watchdog.verdict(360, 360, args))
        # Idle but printing (an output-only wait): not hung.
        self.assertIsNone(watchdog.verdict(10, 400, args))

    def test_cpu_accounting(self):
        self.assertTrue(watchdog.is_busy({1: 5.0}, {1: 5.0, 2: 0.0}, 0.75), "a new process counts as activity")
        self.assertFalse(watchdog.is_busy({1: 5.0, 2: 1.0}, {1: 5.2, 2: 1.1}, 0.75))
        self.assertTrue(watchdog.is_busy({1: 5.0, 2: 1.0}, {1: 5.5, 2: 1.5}, 0.75))
        self.assertFalse(watchdog.is_busy({1: 5.0, 2: 1.0}, {1: 5.0}, 0.75), "an exited process isn't activity")
        self.assertEqual(watchdog.parse_cpu("1777:19.65"), 1777 * 60 + 19.65)
        self.assertEqual(watchdog.parse_cpu("1-02:03:04.50"), 86400 + 2 * 3600 + 3 * 60 + 4.5)

    def test_descendants_lists_the_tree_parents_first(self):
        table = {10: (1, 0.0, "swift-test"), 11: (10, 0.0, "helper"), 12: (11, 0.0, "python3"), 20: (1, 0.0, "x")}
        self.assertEqual(watchdog.descendants(10, table), [10, 11, 12])


if __name__ == "__main__":
    unittest.main()
