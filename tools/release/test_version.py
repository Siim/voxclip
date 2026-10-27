import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]


class VersionTests(unittest.TestCase):
    def setUp(self):
        scratch = Path("/tmp/voxclip-sol-followups-3")
        scratch.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="version-", dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for relative in ("tools/release/version.py", "apps/macos/Sources/VoxClip/Info.plist", "apps/windows/Directory.Build.props"):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        self.version = plistlib.loads((self.root / "apps/macos/Sources/VoxClip/Info.plist").read_bytes())["CFBundleShortVersionString"]

    def source(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def check(self):
        return subprocess.run([sys.executable, str(self.root / "tools/release/version.py"), "check"],
                              capture_output=True, text=True, check=False)

    def test_matching_versions_pass(self):
        self.assertEqual(self.check().returncode, 0)

    def test_planted_production_literals_fail(self):
        for relative in ("apps/macos/Sources/voxclip-cli/Planted.swift", "apps/windows/src/VoxClip.Cli/Planted.cs"):
            for value in (self.version, f"VoxClip/{self.version}"):
                with self.subTest(path=relative, value=value):
                    self.source(relative, f'let version = "{value}"\n')
                    result = self.check()
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(f"{relative}:1", result.stderr)
                    self.assertIn("hard-codes release version", result.stderr)
                    (self.root / relative).unlink()

    def test_tests_fixtures_and_build_outputs_are_excluded(self):
        for relative in ("apps/macos/Sources/Tests/Input.swift", "apps/macos/Sources/Fixtures/Input.swift",
                         "apps/windows/src/VoxClip.Core/obj/Input.cs", "apps/windows/src/VoxClip.Core/bin/Input.cs",
                         "apps/macos/Sources/VoxClipCore/.build/Input.swift"):
            self.source(relative, f'let version = "{self.version}"\n')
        self.assertEqual(self.check().returncode, 0)

    def test_only_explicit_generated_paths_and_name_patterns_are_excluded(self):
        for relative in ("apps/macos/Sources/VoxClip/Design/Tokens.swift",
                         "apps/windows/src/VoxClip.App/Themes/Tokens.xaml",
                         "apps/windows/src/VoxClip.Core/Input.g.cs", "apps/windows/src/VoxClip.Core/Input.g.i.cs",
                         "apps/windows/src/VoxClip.Core/Input.designer.cs",
                         "apps/macos/Sources/VoxClipCore/Input.generated.swift"):
            self.source(relative, f'let version = "{self.version}"\n')
        self.assertEqual(self.check().returncode, 0)
        for relative in ("apps/windows/src/Generated/Input.cs", "apps/macos/Sources/VoxClipCore/Tokens.swift",
                         "apps/windows/src/VoxClip.App/Design/Tokens.xaml"):
            with self.subTest(path=relative):
                self.source(relative, f'let version = "{self.version}"\n')
                self.assertEqual(self.check().returncode, 1)
                (self.root / relative).unlink()

    def test_version_bump_checks_new_version_not_old_version(self):
        result = subprocess.run([sys.executable, str(self.root / "tools/release/version.py"), "set", "9.8.7-beta.2"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.source("apps/macos/Sources/voxclip-cli/Old.swift", f'let old = "{self.version}"\n')
        self.assertEqual(self.check().returncode, 0)
        self.source("apps/windows/src/VoxClip.Cli/New.cs", 'const string Version = "9.8.7-beta.2";\n')
        self.assertEqual(self.check().returncode, 1)

    def test_embedded_raw_and_multiline_string_literals_fail(self):
        for filename, content in (
                ("Planted.swift", f'let version = #"a " // {self.version}"#'),
                ("Planted.swift", f'let version = ##"a " /* {self.version} */ "##'),
                ("Planted.swift", f'let version = """\n{self.version}\n"""'),
                ("Planted.cs", f'var version = @"a "" // {self.version}";'),
                ("Planted.cs", f'var version = """\n{self.version}\n""";'),
                ("Planted.cs", f'var agent = $"VoxClip/{self.version} (Windows)";'),
                ("Planted.xaml", f'<TextBlock Text="{self.version}"/>')):
            with self.subTest(content=content):
                relative = "apps/macos/Sources/voxclip-cli/" + filename
                self.source(relative, content)
                self.assertEqual(self.check().returncode, 1)
                (self.root / relative).unlink()

    def test_comments_are_checked_even_with_generated_looking_headers(self):
        for content in (f'// since {self.version}\n', f'/* since {self.version} */\n',
                        f'// Generated report data follows\nlet version = "{self.version}"\n',
                        f'// <auto-generated>\nlet version = "{self.version}"\n'):
            with self.subTest(content=content):
                self.source("apps/macos/Sources/voxclip-cli/Planted.swift", content)
                self.assertEqual(self.check().returncode, 1)

    def test_complete_version_token_boundaries(self):
        result = subprocess.run([sys.executable, str(self.root / "tools/release/version.py"), "set", "0.1.0"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        for value in ("0.1.0-beta.2", "10.1.0", "0.1.0.1", "10.0.1.0", "0.1.01", "a0.1.0", "0.1.0a",
                      "0.1.0-beta.02", "0.1.0-beta", "0.1." + '" + "0'):
            with self.subTest(value=value):
                self.source("apps/macos/Sources/voxclip-cli/Planted.swift", f'let other = "{value}"\n')
                self.assertEqual(self.check().returncode, 0)

    def test_same_line_allow_comment_prints_every_allowed_line(self):
        relative = "apps/macos/Sources/voxclip-cli/Planted.swift"
        self.source(relative, f'let dependency = "{self.version}" // version-check: allow dependency version\n'
                    f'// since {self.version}; // version-check: allow compatibility example\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        for line, reason in ((1, "dependency version"), (2, "compatibility example")):
            self.assertIn(f"{relative}:{line}:", result.stdout)
            self.assertIn(reason, result.stdout)

    def test_allow_comment_requires_same_line_and_nonempty_reason(self):
        for content in (f'let version = "{self.version}" // version-check: allow\n',
                        f'let version = "{self.version}"\n// version-check: allow dependency\n',
                        f'let version = "{self.version} version-check: allow dependency"\n',
                        f'let version = "{self.version}" /* version-check: allow */  \n',
                        f'let version = "// version-check: allow reason" + "{self.version}"\n',
                        f'let version = #"// version-check: allow reason"# + "{self.version}"\n',
                        f'var version = @"// version-check: allow reason" + "{self.version}";\n',
                        f'let version = "{self.version}" + "// version-check: allow reason"\n'):
            with self.subTest(content=content):
                self.source("apps/macos/Sources/voxclip-cli/Planted.swift", content)
                self.assertEqual(self.check().returncode, 1)

    def test_shared_writer_cases_are_generated(self):
        sys.path.insert(0, str(ROOT / "tools/fixtures/projects"))
        try:
            import generate_writer_versions
        finally:
            sys.path.pop(0)
        committed = (ROOT / "shared/fixtures/projects/writer-versions.json").read_text(encoding="utf-8")
        self.assertEqual(committed, generate_writer_versions.render())

    def test_shared_writer_cases_match_the_release_grammar(self):
        cases = json.loads((ROOT / "shared/fixtures/projects/writer-versions.json").read_text(encoding="utf-8"))
        for entry in cases:
            with self.subTest(runtime=entry["runtime"]):
                result = subprocess.run([sys.executable, str(self.root / "tools/release/version.py"), "set", entry["runtime"] or ""],
                                        capture_output=True, text=True, check=False)
                writer = entry["runtime"] if result.returncode == 0 else "0.0.0"
                self.assertEqual(writer, entry["writer"])

    def test_do_not_edit_comment_does_not_make_source_generated(self):
        self.source("apps/windows/src/VoxClip.Core/Input.cs", f'// Do not edit user data.\nvar version = "{self.version}";\n')
        self.assertEqual(self.check().returncode, 1)

    def test_mismatched_versions_fail(self):
        path = self.root / "apps/windows/Directory.Build.props"
        document = ET.parse(path)
        document.find("./PropertyGroup/Version").text = "9.8.7"
        document.write(path, encoding="utf-8")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("version mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
