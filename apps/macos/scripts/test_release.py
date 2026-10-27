import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import subprocess
import tempfile
import unittest


PACKAGE = Path(__file__).resolve().parents[1]
SHARED = PACKAGE.parents[1] / "shared"
SUBMISSION_ID = "01234567-89ab-cdef-0123-456789abcdef"


def bundle_shared_directories():
    """bundle.sh's SHARED_DIRS: the shared/ folders a release copies."""
    for line in (PACKAGE / "bundle.sh").read_text().splitlines():
        if line.startswith("SHARED_DIRS=(") and line.endswith(")"):
            return tuple(line[len("SHARED_DIRS=("):-1].split())
    raise AssertionError("bundle.sh declares no SHARED_DIRS")


class ReleaseSafetyTests(unittest.TestCase):
    def setUp(self):
        (PACKAGE / ".build").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="release-tests-", dir=PACKAGE / ".build")
        self.root = Path(self.temporary.name)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.dist = self.root / "dist"
        (self.dist / "notarization").mkdir(parents=True)
        self.calls = self.root / "calls"
        self.environment = {
            **os.environ,
            "PATH": f"{self.commands}:/usr/bin:/bin:/usr/sbin:/sbin",
            "DIST": str(self.dist),
            "WORK_DIR": str(self.root),
            "NOTARIZE_PROFILE": "test-profile",
            "MOCK_CALLS": str(self.calls),
            "MOCK_JSON": json.dumps({"id": SUBMISSION_ID, "status": "Accepted"}),
            "MOCK_EXIT": "0",
            "MOCK_ERROR": "",
            "MOCK_LOCKED": "false",
            "SDK_VERSION": "27.0",
            "MIN_MACOS": "26.0",
            "GITHUB_REPO": "Siim/voxclip",
        }
        self.write_command("ioreg", '''#!/bin/bash
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>IOConsoleUsers</key><array><dict><key>CGSSessionScreenIsLocked</key><%s/></dict></array></dict></plist>\n' "$MOCK_LOCKED"
exit "${MOCK_IOREG_EXIT:-0}"
''')
        self.write_command("xcrun", '''#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_CALLS"
if [ "$2" = submit ]; then
    printf '%s\n' "$MOCK_JSON"
    printf '%s' "$MOCK_ERROR" >&2
    exit "$MOCK_EXIT"
fi
printf '%s\n' '{"issues":[{"message":"test failure detail"}]}'
''')

    def tearDown(self):
        self.temporary.cleanup()

    def write_command(self, name, content):
        destination = self.commands / name
        destination.write_text(content)
        destination.chmod(0o755)
        return destination

    def run_function(self, command):
        return subprocess.run(
            ["/bin/bash", "-eo", "pipefail", "-c", 'source "$1"; ' + command,
             "test", str(PACKAGE / "scripts/release-common.sh")],
            env=self.environment, text=True, capture_output=True, cwd=PACKAGE,
        )

    def assert_failed(self, result, expected):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(expected, result.stderr)

    def test_notary_acceptance_requires_status_and_id(self):
        result = self.run_function('notarize "$DIST/input.zip" app')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(SUBMISSION_ID, result.stdout)
        self.assertIn("--wait --output-format json", self.calls.read_text())
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_invalid_status_fetches_log(self):
        self.environment["MOCK_JSON"] = json.dumps({"id": SUBMISSION_ID, "status": "Invalid"})
        result = self.run_function('notarize "$DIST/input.zip" app')
        self.assert_failed(result, "Notarization did not succeed")
        self.assertIn("test failure detail", result.stderr)
        self.assertIn(f"notarytool log {SUBMISSION_ID}", self.calls.read_text())

    def test_failed_command_cannot_be_accepted(self):
        self.environment["MOCK_EXIT"] = "1"
        self.assert_failed(self.run_function('notarize "$DIST/input.zip" app'), "Notarization did not succeed")

    def test_missing_id_is_not_accepted(self):
        self.environment["MOCK_JSON"] = '{"status":"Accepted"}'
        self.assert_failed(self.run_function('notarize "$DIST/input.zip" app'), "id=missing")
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_malformed_json_is_not_accepted(self):
        self.environment["MOCK_JSON"] = "not JSON"
        self.assert_failed(self.run_function('notarize "$DIST/input.zip" app'), "status=missing")
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_expired_agreement_stops_without_retry(self):
        self.environment.update({"MOCK_EXIT": "1", "MOCK_JSON": "", "MOCK_ERROR":
            "Error: HTTP status code: 403. A required agreement is missing or has expired."})
        self.assert_failed(self.run_function('notarize "$DIST/input.zip" app'), "Account Holder")
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_locked_screen_prevents_notarization(self):
        self.environment["MOCK_LOCKED"] = "true"
        result = self.run_function('notarize "$DIST/input.zip" app')
        self.assert_failed(result, "The Mac screen is locked (doc/release.md §5); unlock it and re-run. Do not re-create the notary profile.")
        self.assertFalse(self.calls.exists())

    def test_missing_keychain_profile_reports_locked_screen_without_retry(self):
        self.environment.update({"MOCK_EXIT": "1", "MOCK_JSON": "", "MOCK_ERROR":
            "Error: No Keychain password item found for profile: test-profile"})
        result = self.run_function('notarize "$DIST/input.zip" app')
        self.assert_failed(result, "The Mac screen is locked (doc/release.md §5); unlock it and re-run. Do not re-create the notary profile.")
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_unreadable_screen_lock_state_fails_before_submission(self):
        self.environment["MOCK_IOREG_EXIT"] = "1"
        self.assert_failed(self.run_function('notarize "$DIST/input.zip" app'), "Cannot check the Mac screen lock state")
        self.assertFalse(self.calls.exists())

    def test_locked_screen_release_preflight_runs_before_build(self):
        script = self.prepare_release()
        self.environment["MOCK_LOCKED"] = "true"
        for arguments in (("--release", "--no-upload", "--allow-dirty"), ("--release",)):
            with self.subTest(arguments=arguments):
                result = self.run_bundle(script, *arguments)
                self.assert_failed(result, "The Mac screen is locked (doc/release.md §5)")
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("swift ", self.calls.read_text())
                self.assertNotIn("notarytool", self.calls.read_text())
                self.assertNotIn("security ", self.calls.read_text())

    def test_symbol_scan_is_fail_closed_and_rejects_gpl(self):
        self.environment["NM"] = str(self.write_command("mock-nm", '#!/bin/bash\nprintf "%s\\n" "$MOCK_SYMBOLS"\nexit "${MOCK_NM_EXIT:-0}"\n'))
        self.environment["OTOOL"] = str(self.write_command("mock-otool", '#!/bin/bash\nprintf "%s\\n" "$MOCK_DEPENDENCIES"\n'))
        for symbol in ("_espeak_Initialize", "_espeak_ng_Initialize", "_x264_encoder_open_164", "_x265_encoder_open",
                       "_avcodec_open2", "_avformat_open_input", "_avfilter_init_str", "_avutil_version",
                       "_swresample_version", "_swscale_version", "00000000 T _avcodec_open2"):
            with self.subTest(symbol=symbol):
                self.environment["MOCK_SYMBOLS"] = symbol
                self.assert_failed(self.run_function('license_gate fake-binary'), "Licence gate")
        self.environment.update({"MOCK_SYMBOLS": "_allowed_symbol\n_$sactiveSpeaker\n_activeSpeaker\n_ESPEAK_test\n_wrapped_x264_open",
                                 "MOCK_DEPENDENCIES": "/tmp/libavcodec.fixture:\n\t/usr/lib/libSystem.B.dylib"})
        self.assertEqual(self.run_function('license_gate fake-binary').returncode, 0)
        for library in ("espeak", "espeak-ng", "x264", "x265", "avcodec", "avformat", "avfilter", "avutil", "swresample", "swscale"):
            with self.subTest(library=library):
                self.environment["MOCK_DEPENDENCIES"] = f"fake-binary:\n\t@rpath/lib{library}.dylib"
                self.assert_failed(self.run_function('license_gate fake-binary'), "Licence gate")
        self.environment["MOCK_NM_EXIT"] = "1"
        self.assert_failed(self.run_function('license_gate fake-binary'), "Cannot inspect symbols")

    def test_grep_errors_fail_closed_for_each_licence_scan(self):
        self.environment["NM"] = str(self.write_command("mock-nm", '#!/bin/bash\nprintf "%s\\n" "$MOCK_SYMBOLS"\n'))
        self.environment["OTOOL"] = str(self.write_command("mock-otool", '#!/bin/bash\nprintf "%s\\n" "$MOCK_DEPENDENCIES"\n'))
        self.write_command("grep", '''#!/bin/bash
if [ "${!#}" = "$MOCK_GREP_ERROR_FILE" ]; then
    printf 'grep: simulated read error\\n' >&2
    exit 2
fi
exec /usr/bin/grep "$@"
''')
        for scan, output_file, expected in (
            ("symbols", "nm.stdout", "Cannot scan symbols in fake-binary."),
            ("libraries", "otool.dependencies", "Cannot scan linked libraries in fake-binary."),
        ):
            with self.subTest(scan=scan):
                self.environment.update({
                    "MOCK_SYMBOLS": "00000000 T _x264_encoder_open_164" if scan == "symbols" else "_allowed_symbol",
                    "MOCK_DEPENDENCIES": "fake-binary:\n\t@rpath/libavcodec.dylib",
                    "MOCK_GREP_ERROR_FILE": str(self.root / output_file),
                })
                result = self.run_function("license_gate fake-binary")
                self.assert_failed(result, expected)
                self.assertIn("grep: simulated read error", result.stderr)
                self.assertNotIn("Licence gate passed", result.stdout)

    def test_large_symbol_and_dependency_scans_do_not_miss_forbidden_code(self):
        self.write_command("grep", '''#!/bin/bash
printf '%s\\n' "${!#}" >> "$MOCK_CALLS"
exec /usr/bin/grep -m1 "$@"
''')
        symbols = self.root / "symbols.txt"
        dependencies = self.root / "dependencies.txt"
        self.environment.update({
            "MOCK_SYMBOL_FILE": str(symbols), "MOCK_DEPENDENCY_FILE": str(dependencies),
            "NM": str(self.write_command("mock-nm", '#!/bin/bash\ncat "$MOCK_SYMBOL_FILE"\n')),
            "OTOOL": str(self.write_command("mock-otool", '#!/bin/bash\ncat "$MOCK_DEPENDENCY_FILE"\n')),
        })
        allowed_symbols = "00000000 T _allowed_symbol\n" * 160000
        allowed_dependencies = "\t/usr/lib/libSystem.B.dylib\n" * 160000
        for position in ("first", "last"):
            with self.subTest(position=position, scan="symbols"):
                forbidden = "00000000 T _x264_encoder_open_164\n"
                symbols.write_text(forbidden + allowed_symbols if position == "first" else allowed_symbols + forbidden)
                dependencies.write_text("fake-binary:\n" + allowed_dependencies)
                self.assert_failed(self.run_function("license_gate fake-binary"), "Licence gate")
            with self.subTest(position=position, scan="dependencies"):
                symbols.write_text(allowed_symbols)
                forbidden = "\t@rpath/libavcodec.dylib\n"
                dependencies.write_text("fake-binary:\n" + (forbidden + allowed_dependencies if position == "first"
                                                         else allowed_dependencies + forbidden))
                self.assert_failed(self.run_function("license_gate fake-binary"), "Licence gate")
        dependencies.write_text("fake-binary:\n" + allowed_dependencies)
        self.assertEqual(self.run_function("license_gate fake-binary").returncode, 0)
        self.assertEqual(set(self.calls.read_text().splitlines()),
                         {str(self.root / "nm.stdout"), str(self.root / "otool.dependencies")})

    def test_failed_dependency_scan_cannot_pass_with_partial_output(self):
        self.environment["NM"] = str(self.write_command("mock-nm", '#!/bin/bash\necho _allowed_symbol\n'))
        self.environment["OTOOL"] = str(self.write_command("mock-otool", '''#!/bin/bash
printf 'fake-binary:\n\t/usr/lib/libSystem.B.dylib\n'
exit 23
'''))
        result = self.run_function("license_gate fake-binary")
        self.assert_failed(result, "Cannot inspect linked libraries in fake-binary.")
        self.assertNotIn("Licence gate passed", result.stdout)

    def test_sdk_pin_rejects_stale_stamp(self):
        self.write_command("lipo", '#!/bin/bash\necho arm64\n')
        self.environment["OTOOL"] = str(self.write_command("mock-otool", '#!/bin/bash\nprintf "cmd LC_BUILD_VERSION\\nminos 26.0\\nsdk %s\\n" "$MOCK_SDK"\n'))
        self.environment["MOCK_SDK"] = "27.0"
        (self.root / "binary").touch()
        self.assertEqual(self.run_function('verify_sdk "$WORK_DIR/binary"').returncode, 0)
        self.environment["MOCK_SDK"] = "13.0"
        self.assert_failed(self.run_function('verify_sdk "$WORK_DIR/binary"'), "SDK stamp")

    def test_invalid_option_combinations_never_submit(self):
        cases = (
            (("--unknown",), "Unknown option: --unknown"),
            (("--universal",), "--universal is reserved"),
            (("--upload-only", "--allow-dirty"), "--allow-dirty requires --release --no-upload"),
            (("--release", "--sign-only"), "Choose only one build/upload mode"),
            (("--dry-run",), "--dry-run requires --upload-only"),
            (("--no-upload",), "--no-upload requires --release"),
            (("--release", "--allow-dirty"), "--allow-dirty requires --release --no-upload"),
        )
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(PACKAGE / "bundle.sh"), *arguments],
                    env=self.environment, text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(expected, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_hdiutil_fallback_preserves_installer_layout(self):
        app = self.root / "VoxClip.app"
        app.mkdir()
        (app / "marker").write_text("stapled app fixture")
        self.environment.update({"APP_BUNDLE": str(app), "DMG": str(self.dist / "VoxClip-macOS.dmg")})
        self.write_command("create-dmg", '#!/bin/bash\nexit 1\n')
        self.write_command("hdiutil", '''#!/bin/bash
while [ "$1" != -srcfolder ]; do shift; done
stage="$2"
test -f "$stage/VoxClip.app/marker" && test -f "$stage/.background/dmg-background.png" && test "$(readlink "$stage/Applications")" = /Applications
''')
        result = self.run_function("create_disk_image")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hdiutil", result.stdout)

    def test_missing_create_dmg_fails_without_fallback(self):
        self.assert_failed(self.run_function("create_disk_image"), "create-dmg missing: brew install create-dmg")

    def prepare_upload(self, draft="true", test_build=False, version=None):
        package = self.root / "repo/apps/macos"
        (package / "scripts").mkdir(parents=True)
        (package / "Sources/VoxClip").mkdir(parents=True)
        shutil.copy(PACKAGE / "bundle.sh", package / "bundle.sh")
        shutil.copy(PACKAGE / "scripts/release-common.sh", package / "scripts/release-common.sh")
        shutil.copy(PACKAGE / "Sources/VoxClip/Info.plist", package / "Sources/VoxClip/Info.plist")
        if version is not None:
            info_path = package / "Sources/VoxClip/Info.plist"
            app_info = plistlib.loads(info_path.read_bytes())
            app_info["CFBundleShortVersionString"] = version
            info_path.write_bytes(plistlib.dumps(app_info))
        version_helper = self.root / "repo/tools/release/check-version.sh"
        version_helper.parent.mkdir(parents=True)
        version_helper.write_text("#!/bin/bash\nexit 0\n")
        version_helper.chmod(0o755)
        self.version = version or plistlib.loads((package / "Sources/VoxClip/Info.plist").read_bytes())["CFBundleShortVersionString"]
        (self.root / "repo/CHANGELOG.md").write_text(
            "# Changelog\n\n## 0.1.00 - Other version\n\n- Not this release.\n\n"
            f"## {self.version} - Unreleased\n\n- Release fixture.\n\n## 0.0.9 - Earlier\n\n- Old entry.\n")
        output = package / "dist"
        (output / "VoxClip.app/Contents").mkdir(parents=True)
        shutil.copy(package / "Sources/VoxClip/Info.plist", output / "VoxClip.app/Contents/Info.plist")
        checksums = []
        for name in ("VoxClip-macOS.dmg", "VoxClip-macOS.zip"):
            payload = name.encode()
            (output / name).write_bytes(payload)
            checksums.append(f"{hashlib.sha256(payload).hexdigest()}  {name}\n")
        (output / "SHA256SUMS-macOS.txt").write_text("".join(checksums))
        app_info = plistlib.loads((package / "Sources/VoxClip/Info.plist").read_bytes())
        self.version = app_info["CFBundleShortVersionString"]
        metadata = {"Version": self.version, "BuildNumber": app_info["CFBundleVersion"],
                    "GitCommit": "test-commit", "TestBuild": test_build}
        (output / "release-metadata.plist").write_bytes(plistlib.dumps(metadata))
        self.write_command("git", '''#!/bin/bash
case "$3" in
    status) printf '%s' "$MOCK_DIRTY" ;;
    ls-files) printf '%b' "$MOCK_IGNORED"; exit "${MOCK_LS_FILES_EXIT:-0}" ;;
    cat-file) echo "${MOCK_TAG_TYPE:-tag}" ;;
    rev-parse)
        case "$4" in
            HEAD) echo "${MOCK_HEAD:-test-commit}" ;;
            *'^{commit}') echo test-commit ;;
            *) echo tag-object ;;
        esac ;;
    *) exit 1 ;;
esac
''')
        self.write_command("codesign", "#!/bin/bash\nexit 0\n")
        self.write_command("spctl", "#!/bin/bash\nexit 0\n")
        self.environment.update({"MOCK_DRAFT": draft, "MOCK_RELEASE_TAG": f"v{self.version}",
                                 "MOCK_PRERELEASE": str("-beta." in self.version).lower(),
                                 "REPO_ROOT": str(package.parents[1]), "VERSION": self.version,
                                 "TAG": f"v{self.version}", "DRY_RUN": "true",
                                 "ALLOW_DIRTY": "false", "NO_UPLOAD": "false",
                                 "MOCK_CREATED": str(self.root / "created"),
                                 "MOCK_NOTES": str(self.root / "created-notes")})
        self.write_command("gh", '''#!/bin/bash
printf 'gh %s\n' "$*" >> "$MOCK_CALLS"
case "$1 $2" in
    'auth status') exit "${MOCK_AUTH_EXIT:-0}" ;;
    'api '*)
        [ "$MOCK_REMOTE_TAG" != missing ] || exit 1
        echo "${MOCK_REMOTE_TAG:-tag-object}" ;;
    'release view')
        if [ -n "$MOCK_VIEW_ERROR" ]; then
            printf '%s\n' "$MOCK_VIEW_ERROR" >&2
            exit 1
        fi
        if [ "$MOCK_DRAFT" = missing ]; then
            if [ ! -f "$MOCK_CREATED" ]; then
                echo 'release not found' >&2
                exit 1
            fi
            printf 'true\t%s\t%s\n' "$MOCK_RELEASE_TAG" "$MOCK_PRERELEASE"
        else
            printf '%s\t%s\t%s\n' "$MOCK_DRAFT" "$MOCK_RELEASE_TAG" "$MOCK_PRERELEASE"
        fi ;;
    'release create')
        touch "$MOCK_CREATED"
        while [ "$1" != --notes-file ]; do shift; done
        cp "$2" "$MOCK_NOTES" ;;
    'release upload') exit 0 ;;
    *) exit 1 ;;
esac
''')
        return package / "bundle.sh"

    def prepare_release(self):
        script = self.prepare_upload()
        shutil.copy(PACKAGE / "Package.swift", script.parent / "Package.swift")
        sdk = self.root / "sdk"
        sdk.mkdir()
        (sdk / "SDKSettings.json").write_text(json.dumps({"Version": "27.0"}))
        self.environment.update({"SDKROOT": str(sdk), "BUILD_COMMIT": "uncaptured",
                                 "SIGNING_IDENTITY": "Developer ID Application: Test (TESTTEAM)",
                                 "TEAM_ID": "TESTTEAM"})
        self.write_command("security", '''#!/bin/bash
printf 'security %s\n' "$*" >> "$MOCK_CALLS"
printf '1) fixture "%s"\n' "$SIGNING_IDENTITY"
''')
        self.write_command("swift", '''#!/bin/bash
printf 'swift %s BUILD_COMMIT=%s\n' "$*" "$BUILD_COMMIT" >> "$MOCK_CALLS"
echo 'Mock swift build stopped' >&2
exit 74
''')
        self.write_command("create-dmg", '#!/bin/bash\nprintf "create-dmg %s\\n" "$*" >> "$MOCK_CALLS"\nexit 1\n')
        for name in ("git", "ioreg"):
            command = (self.commands / name).read_text()
            self.write_command(name, command.replace("#!/bin/bash\n",
                f'#!/bin/bash\nprintf "{name} %s\\n" "$*" >> "$MOCK_CALLS"\n', 1))
        return script

    def run_bundle(self, script, *arguments):
        if "--upload-only" in arguments and "--dry-run" not in arguments:
            arguments = (*arguments, "--dry-run")
        return subprocess.run([str(script), *arguments], env=self.environment, text=True, capture_output=True, timeout=15)

    def test_bundle_lock_rejects_second_invocation_without_dist_changes(self):
        script = self.prepare_release()
        lock = script.parent / ".build/bundle.lock"
        output = script.parent / "dist"
        before = {str(item.relative_to(output)): item.read_bytes() for item in output.rglob("*") if item.is_file()}
        ready_read, ready_write = os.pipe()
        self.environment["MOCK_READY_FD"] = str(ready_write)
        self.write_command("spctl", '''#!/bin/bash
if [[ "$*" == *'--type execute'* ]]; then
    printf ready >&"$MOCK_READY_FD"
    IFS= read -r resume
fi
''')
        try:
            with subprocess.Popen([str(script), "--upload-only", "--dry-run"], env=self.environment,
                    text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    pass_fds=(ready_write,)) as first:
                os.close(ready_write)
                ready_write = None
                try:
                    self.assertTrue(select.select([ready_read], [], [], 5)[0], "First invocation did not reach Gatekeeper")
                    self.assertEqual(os.read(ready_read, 5), b"ready")
                    self.assertEqual(lock.read_text().strip(), str(first.pid))
                    invocations = self.calls.read_text()
                    for arguments in (("--sign-only",), ("--upload-only", "--dry-run")):
                        with self.subTest(arguments=arguments):
                            result = self.run_bundle(script, *arguments)
                            self.assert_failed(result, "Another bundle.sh is running in this checkout.")
                            self.assertEqual(result.returncode, 1)
                            self.assertEqual(lock.read_text().strip(), str(first.pid))
                            self.assertEqual(self.calls.read_text(), invocations)
                            self.assertEqual(before, {str(item.relative_to(output)): item.read_bytes()
                                                     for item in output.rglob("*") if item.is_file()})
                finally:
                    stdout, stderr = first.communicate("continue\n", timeout=10)
                self.assertEqual(first.returncode, 0, stdout + stderr)
        finally:
            os.close(ready_read)
            if ready_write is not None:
                os.close(ready_write)
        self.assertFalse(lock.exists())
        self.assertEqual(list((script.parent / ".build").glob("voxclip-release.*")), [])

    def test_operational_tool_failures_exit_one_and_release_lock(self):
        script = self.prepare_upload()
        for tool, exit_code in (("codesign", 3), ("spctl", 3), ("xcrun", 65)):
            with self.subTest(tool=tool):
                command = (self.commands / tool).read_text()
                self.write_command(tool, f'#!/bin/bash\necho "Mock {tool} failure" >&2\nexit {exit_code}\n')
                result = self.run_bundle(script, "--upload-only", "--dry-run")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"Mock {tool} failure", result.stderr)
                self.assertFalse((script.parent / ".build/bundle.lock").exists())
                self.assertEqual(list((script.parent / ".build").glob("voxclip-release.*")), [])
                self.write_command(tool, command)

    def test_upload_dry_run_never_uploads_or_creates_release(self):
        script = self.prepare_upload()
        result = subprocess.run([str(script), "--upload-only", "--dry-run"],
            env=self.environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry run; would execute:", result.stdout)
        invocations = self.calls.read_text()
        self.assertIn("gh auth status --hostname github.com --active\n", invocations)
        self.assertIn(f"gh release view v{self.version}", invocations)
        self.assertNotIn("gh release upload", invocations)
        self.assertNotIn("gh release create", invocations)

    def test_upload_refuses_published_release(self):
        script = self.prepare_upload(draft="false")
        result = self.run_bundle(script, "--upload-only")
        self.assert_failed(result, "already published; refusing to replace assets")
        self.assertNotIn("gh release upload", self.calls.read_text())
        self.assertNotIn("gh release create", self.calls.read_text())

    def test_upload_creates_missing_draft_with_exact_changelog_section(self):
        self.prepare_upload(draft="missing")
        result = self.run_function("DRY_RUN=false; prepare_draft")
        self.assertEqual(result.returncode, 0, result.stderr)
        invocations = self.calls.read_text()
        self.assertIn(f"gh release create v{self.version} --repo Siim/voxclip --draft --verify-tag --title VoxClip {self.version} --notes-file", invocations)
        self.assertNotIn("--prerelease", invocations)
        self.assertEqual((self.root / "created-notes").read_text().strip(), "- Release fixture.")

    def test_upload_missing_draft_dry_run_prints_create_without_mutations(self):
        script = self.prepare_upload(draft="missing")
        result = self.run_bundle(script, "--upload-only", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"gh release create v{self.version}", result.stdout)
        self.assertIn(f"gh release upload v{self.version}", result.stdout)
        self.assertNotIn("gh release create", self.calls.read_text())
        self.assertNotIn("gh release upload", self.calls.read_text())

    def test_beta_draft_creation_and_dry_run_use_prerelease(self):
        script = self.prepare_upload(draft="missing", version="0.1.0-beta.2")
        result = self.run_bundle(script, "--upload-only", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--prerelease", result.stdout)
        self.assertNotIn("gh release create", self.calls.read_text())
        result = self.run_function("DRY_RUN=false; prepare_draft")
        self.assertEqual(result.returncode, 0, result.stderr)
        creation = next(line for line in self.calls.read_text().splitlines() if line.startswith("gh release create"))
        self.assertIn("--prerelease", creation)

    def test_release_prerelease_flag_must_match_version(self):
        script = self.prepare_upload()
        self.environment["MOCK_PRERELEASE"] = "true"
        self.assert_failed(self.run_bundle(script, "--upload-only", "--dry-run"),
                           "Release isPrerelease disagrees with version")
        self.assertNotIn("gh release create", self.calls.read_text())

    def test_beta_release_refuses_stable_draft(self):
        script = self.prepare_upload(version="0.1.0-beta.2")
        self.environment["MOCK_PRERELEASE"] = "false"
        self.assert_failed(self.run_bundle(script, "--upload-only", "--dry-run"),
                           "Release isPrerelease disagrees with version")

    def test_version_accepts_only_stable_or_numbered_beta(self):
        script = self.prepare_upload()
        info_path = script.parent / "Sources/VoxClip/Info.plist"
        app_info = plistlib.loads(info_path.read_bytes())
        for version in ("0.1.0-rc.1", "0.1.0-beta", "0.1.0-beta.x", "0.1.0-beta.1.2", "0.1.0+build", "0.1"):
            with self.subTest(version=version):
                app_info["CFBundleShortVersionString"] = version
                info_path.write_bytes(plistlib.dumps(app_info))
                self.assert_failed(self.run_bundle(script, "--upload-only", "--dry-run"), "Invalid app version")
        self.assertFalse(self.calls.exists())

    def test_release_query_errors_never_create_draft(self):
        script = self.prepare_upload(draft="missing")
        for error in ("HTTP 502: Bad Gateway", "API rate limit exceeded", "GraphQL: Something went wrong"):
            with self.subTest(error=error):
                self.environment["MOCK_VIEW_ERROR"] = error
                result = self.run_bundle(script, "--upload-only", "--dry-run")
                self.assert_failed(result, f"Cannot query release v{self.version}; not creating a draft")
                self.assertIn(error, result.stderr)
                self.assertNotIn("gh release create", self.calls.read_text())
                self.assertNotIn("gh release upload", self.calls.read_text())

    def test_upload_refuses_empty_missing_or_wrong_changelog_section(self):
        script = self.prepare_upload(draft="missing")
        changelog = self.root / "repo/CHANGELOG.md"
        for contents in ("## 0.1.0 - Unreleased\n\n \n## 0.0.9\n- Old entry.\n",
                         "## 0.1.00\n- Wrong version.\n", "# Changelog\n"):
            with self.subTest(contents=contents):
                changelog.write_text(contents)
                result = self.run_bundle(script, "--upload-only")
                self.assert_failed(result, f"no nonempty ## {self.version} release section")
        changelog.unlink()
        self.assert_failed(self.run_bundle(script, "--upload-only"), "Missing CHANGELOG.md")
        self.assertNotIn("gh release create", self.calls.read_text())
        self.assertNotIn("gh release upload", self.calls.read_text())

    def test_upload_refuses_tag_mismatch_missing_tag_and_untagged_head(self):
        script = self.prepare_upload()
        cases = (
            ("MOCK_RELEASE_TAG", "v9.9.9", "Release tagName v9.9.9 differs"),
            ("MOCK_REMOTE_TAG", "other-object", "does not match the local annotated tag object"),
            ("MOCK_REMOTE_TAG", "missing", f"Remote tag v{self.version} is missing"),
            ("MOCK_TAG_TYPE", "missing", f"requires the annotated tag v{self.version}"),
            ("MOCK_TAG_TYPE", "commit", f"requires the annotated tag v{self.version}"),
            ("MOCK_HEAD", "other-commit", f"HEAD is not tagged v{self.version}"),
        )
        for name, value, expected in cases:
            with self.subTest(name=name, value=value):
                previous = self.environment.get(name)
                self.environment[name] = value
                self.assert_failed(self.run_bundle(script, "--upload-only"), expected)
                if previous is None:
                    self.environment.pop(name)
                else:
                    self.environment[name] = previous
                self.assertNotIn("gh release upload", self.calls.read_text())
                self.assertNotIn("gh release create", self.calls.read_text())

    def test_release_checks_github_before_build_or_notarization(self):
        script = self.prepare_release()
        for name, value, expected in (
            ("MOCK_AUTH_EXIT", "1", "GitHub CLI authentication for github.com failed; run gh auth login -h github.com."),
            ("MOCK_REMOTE_TAG", "missing", "is missing or inaccessible"),
            ("MOCK_DRAFT", "false", "already published"),
        ):
            with self.subTest(name=name):
                previous = self.environment.get(name)
                self.environment[name] = value
                self.assert_failed(self.run_bundle(script, "--release"), expected)
                if previous is None:
                    self.environment.pop(name)
                else:
                    self.environment[name] = previous
        (self.commands / "gh").unlink()
        self.assert_failed(self.run_bundle(script, "--release"), "Install the GitHub CLI (gh)")
        self.assertNotIn("swift ", self.calls.read_text())
        self.assertNotIn("notarytool", self.calls.read_text())

    def test_release_requires_create_dmg_before_notarization(self):
        script = self.prepare_release()
        (self.commands / "create-dmg").unlink()
        for arguments in (("--release", "--no-upload", "--allow-dirty"), ("--release",)):
            with self.subTest(arguments=arguments):
                self.assert_failed(self.run_bundle(script, *arguments), "create-dmg missing: brew install create-dmg")
                self.assertNotIn("swift ", self.calls.read_text())
                self.assertNotIn("notarytool", self.calls.read_text())

    def test_release_captures_commit_and_completes_preflight_before_swift_build(self):
        script = self.prepare_release()
        for arguments in (("--release", "--no-upload", "--allow-dirty"), ("--release",)):
            with self.subTest(arguments=arguments):
                self.calls.unlink(missing_ok=True)
                result = self.run_bundle(script, *arguments)
                self.assert_failed(result, "Mock swift build stopped")
                self.assertEqual(result.returncode, 1)
                invocations = self.calls.read_text()
                build = next(line for line in invocations.splitlines() if line.startswith("swift build "))
                self.assertIn("swift build --jobs 2 -c release ", build)
                self.assertIn('BIN_DIR=$(swift build --jobs 2 -c "$CONFIG"', script.read_text())
                self.assertIn("BUILD_COMMIT=test-commit", build)
                self.assertLess(invocations.index("rev-parse HEAD"), invocations.index("swift build "))
                self.assertLess(invocations.index("ioreg "), invocations.index("swift build "))
                if "--no-upload" not in arguments:
                    self.assertLess(invocations.index("gh auth status --hostname github.com --active"),
                                    invocations.index("swift build "))
                self.assertNotIn("notarytool", invocations)
                self.assertNotIn("create-dmg ", invocations)

    def test_release_rejects_ignored_resources_even_with_allow_dirty(self):
        self.prepare_upload()
        self.environment["MOCK_IGNORED"] = "shared/catalog/maintainer.p12\\0"
        for allow_dirty in ("false", "true"):
            with self.subTest(allow_dirty=allow_dirty):
                result = self.run_function(f"SHARED_DIRS=(catalog); ALLOW_DIRTY={allow_dirty}; check_release_tree")
                self.assert_failed(result, "Ignored files exist in shipped shared directories")
                self.assertIn("shared/catalog/maintainer.p12", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_ignored_ds_store_is_not_a_release_blocker(self):
        self.prepare_upload()
        self.environment["MOCK_IGNORED"] = ".DS_Store\\0shared/catalog/.DS_Store\\0shared/fonts/nested/.DS_Store\\0"
        result = self.run_function("SHARED_DIRS=(catalog fonts); check_release_tree")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.environment["MOCK_IGNORED"] += "shared/catalog/private.p12\\0"
        result = self.run_function("SHARED_DIRS=(catalog fonts); check_release_tree")
        self.assert_failed(result, "shared/catalog/private.p12")
        self.assertNotIn(".DS_Store", result.stderr)

    def test_ignored_file_listing_errors_fail_closed(self):
        self.prepare_upload()
        self.environment.update({"MOCK_LS_FILES_EXIT": "17", "MOCK_IGNORED": "shared/catalog/.DS_Store\\0"})
        self.assert_failed(self.run_function("SHARED_DIRS=(catalog); check_ignored_resources"),
                           "Cannot list ignored files in shipped shared directories.")

    def test_ignored_resources_use_raw_paths_and_exempt_ds_store_everywhere(self):
        self.prepare_shared_resources()
        repository = Path(self.environment["REPO_ROOT"])
        (repository / "shared/catalog/maintainer.p12").unlink()
        with (repository / ".gitignore").open("a") as ignore:
            ignore.write(".DS_Store\n")
        subprocess.run(["/usr/bin/git", "-C", str(repository), "config", "core.quotePath", "true"], check=True)
        for directory in ("café", 'quoted "folder"', "line\nbreak"):
            location = repository / "shared/catalog" / directory
            location.mkdir()
            (location / ".DS_Store").touch()
        result = self.run_function("SHARED_DIRS=(catalog fonts); check_ignored_resources")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        forbidden = repository / 'shared/catalog/café/private "file"\nkey.p12'
        forbidden.touch()
        result = self.run_function("SHARED_DIRS=(catalog fonts); check_ignored_resources")
        self.assert_failed(result, str(forbidden.relative_to(repository)))
        self.assertNotIn(".DS_Store", result.stderr)

    def test_dylib_notice_gate_rejects_unknown_names_and_missing_notice(self):
        app = self.root / "VoxClip.app"
        frameworks = app / "Contents/Frameworks"
        frameworks.mkdir(parents=True)
        resources = app / "Contents/Resources"
        resources.mkdir()
        notices = resources / "THIRD_PARTY_NOTICES.md"
        notices.write_text("MIT License\n")
        self.environment["APP_BUNDLE"] = str(app)
        (frameworks / "libwhisper.dylib").touch()
        self.assert_failed(self.run_function("framework_notice_gate"), "Missing library licence notice for libwhisper.dylib")
        shutil.copy(PACKAGE.parents[1] / "THIRD_PARTY_NOTICES.md", notices)
        self.assertEqual(self.run_function("framework_notice_gate").returncode, 0)
        (frameworks / "unknown.dylib").touch()
        self.assert_failed(self.run_function("framework_notice_gate"), "No known licence notice for library: unknown.dylib")

    def test_build_commit_recheck_rejects_changed_head_or_dirty_tree(self):
        self.prepare_upload()
        for mutation, expected in (("export MOCK_HEAD=later-commit", "HEAD changed since the build started"),
                                   ("export MOCK_DIRTY=' M source.swift'", "Working tree is dirty")):
            with self.subTest(mutation=mutation):
                result = self.run_function("SHARED_DIRS=(catalog); check_release_tree; " + mutation + "; verify_build_commit")
                self.assert_failed(result, expected)
        self.assertFalse(self.calls.exists())

    def test_allow_dirty_keeps_captured_commit_in_metadata(self):
        self.prepare_upload()
        self.environment.update({"METADATA": str(self.dist / "captured-metadata.plist"),
                                 "BUILD_NUMBER": "1"})
        source = (PACKAGE / "bundle.sh").read_text()
        metadata = source[source.index("verify_build_commit\nplutil -create"):source.index('cat "$SUMS"')]
        result = self.run_function("SHARED_DIRS=(catalog); ALLOW_DIRTY=true; check_release_tree; "
                                   "export MOCK_HEAD=later-commit MOCK_DIRTY=' M source.swift'; " + metadata)
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = plistlib.loads(Path(self.environment["METADATA"]).read_bytes())
        self.assertEqual(saved["GitCommit"], "test-commit")
        self.assertTrue(saved["TestBuild"])

    def test_commit_rechecks_precede_signing_and_metadata(self):
        source = (PACKAGE / "bundle.sh").read_text()
        before_signing = source.index('[ "$MODE" != release ] || verify_build_commit')
        before_metadata = source.index("verify_build_commit\nplutil -create")
        self.assertLess(source.index('license_gate "$binary"'), before_signing)
        self.assertLess(before_signing, source.index("SIGN=(codesign"))
        self.assertLess(source.index('notarize "$DMG" dmg'), before_metadata)
        self.assertLess(before_metadata, source.index("plutil -insert GitCommit"))

    def prepare_shared_resources(self):
        repository = self.root / "resource-repo"
        repository.mkdir()
        self.shared_directories = bundle_shared_directories()
        for directory in (*self.shared_directories, "ingest"):
            source = repository / "shared" / directory
            source.mkdir(parents=True)
            (source / "tracked file\nwith newline.txt").write_text(directory)
            (source / "fixtures").mkdir()
            (source / "fixtures/omit.json").write_text("fixture")
        (repository / ".gitignore").write_text("*.p12\n")
        for arguments in (("init", "-q"), ("add", ".")):
            subprocess.run(["/usr/bin/git", "-C", str(repository), *arguments], check=True, capture_output=True)
        (repository / "shared/catalog/maintainer.p12").write_text("ignored fixture; not a credential")
        (repository / "shared/catalog/untracked.txt").write_text("untracked")
        app = self.root / "VoxClip.app"
        (app / "Contents/Resources").mkdir(parents=True)
        self.environment.update({"REPO_ROOT": str(repository), "APP_BUNDLE": str(app)})
        return app / "Contents/Resources/shared"

    def copy_resources(self):
        return self.run_function(f"SHARED_DIRS=({' '.join(self.shared_directories)}); copy_shared_resources")

    def test_bundled_shared_resources_cover_every_folder_the_code_reads(self):
        # Each shared/ folder a shipped target opens through the shared root. Fixtures never ship; only debug code reads them.
        read = set()
        for source in (PACKAGE / "Sources").rglob("*.swift"):
            read.update(re.findall(r'appendingPathComponent\("([a-z-]+)/', source.read_text()))
        read = {folder for folder in read if (SHARED / folder).is_dir()} - {"fixtures"}
        self.assertLessEqual({"caption-styles", "catalog", "data", "design", "fonts", "prompts"}, read)
        self.assertLessEqual(read, set(bundle_shared_directories()))

    def test_only_tracked_resources_ship_without_fixtures_or_ingest(self):
        resources = self.prepare_shared_resources()
        result = self.copy_resources()
        self.assertEqual(result.returncode, 0, result.stderr)
        shipped = {str(path.relative_to(resources)) for path in resources.rglob("*") if path.is_file()}
        self.assertEqual(shipped, {f"{directory}/tracked file\nwith newline.txt" for directory in self.shared_directories})
        for directory in self.shared_directories:
            self.assertEqual((resources / directory / "tracked file\nwith newline.txt").read_text(), directory)
        self.assert_failed(self.run_function("SHARED_DIRS=(catalog); check_ignored_resources"), "Ignored files exist")

    def test_resource_parity_uses_tracked_manifest(self):
        self.prepare_shared_resources()
        self.write_command("rsync", '''#!/bin/bash
/usr/bin/rsync "$@"
if [ "$1" = -a ]; then
    find "$APP_BUNDLE/Contents/Resources/shared" -type f -exec sh -c 'echo corrupted > "$1"' test {} \\;
fi
''')
        self.assert_failed(self.copy_resources(), "differs from its tracked source files")

    def test_asset_catalog_must_compile_the_info_plist_accent_colour(self):
        app = self.root / "VoxClip.app"
        (app / "Contents/Resources").mkdir(parents=True)
        self.write_command("xcrun", '#!/bin/bash\nexec /usr/bin/xcrun "$@"\n')
        self.environment.update({"APP_BUNDLE": str(app), "INFO_PLIST": "Sources/VoxClip/Info.plist",
                                 "ASSET_CATALOG": "Resources/Assets.xcassets"})
        result = self.run_function("compile_asset_catalog")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((app / "Contents/Resources/Assets.car").is_file())
        catalog = subprocess.run(["/usr/bin/xcrun", "assetutil", "--info", str(app / "Contents/Resources/Assets.car")], text=True, capture_output=True, check=True)
        names = {entry.get("Name") for entry in json.loads(catalog.stdout)}
        self.assertTrue({"gobackward.3", "goforward.3"}.issubset(names), names)
        info = plistlib.loads((PACKAGE / "Sources/VoxClip/Info.plist").read_bytes())
        self.assertEqual(info["NSAccentColorName"], "AccentColor")
        missing = self.root / "Info.plist"
        missing.write_bytes(plistlib.dumps({**info, "NSAccentColorName": "Missing"}))
        self.environment["INFO_PLIST"] = str(missing)
        self.assert_failed(self.run_function("compile_asset_catalog"), "has no Missing colour")
        del info["NSAccentColorName"]
        missing.write_bytes(plistlib.dumps(info))
        self.assert_failed(self.run_function("compile_asset_catalog"), "Info.plist has no NSAccentColorName")

    def test_framework_notice_gate_requires_known_copyright(self):
        app = self.root / "VoxClip.app"
        frameworks = app / "Contents/Frameworks"
        (frameworks / "whisper.framework").mkdir(parents=True)
        resources = app / "Contents/Resources"
        resources.mkdir()
        notices = resources / "THIRD_PARTY_NOTICES.md"
        notices.write_text("MIT License\n")
        self.environment["APP_BUNDLE"] = str(app)
        self.assert_failed(self.run_function("framework_notice_gate"), "Missing framework licence notice for whisper.framework")
        shutil.copy(PACKAGE.parents[1] / "THIRD_PARTY_NOTICES.md", notices)
        self.assertEqual(self.run_function("framework_notice_gate").returncode, 0)
        (frameworks / "unknown.framework").mkdir()
        self.assert_failed(self.run_function("framework_notice_gate"), "No known licence notice for framework: unknown.framework")

    def test_cli_identity_requires_distinct_designated_requirement(self):
        self.environment.update({"APP_BUNDLE": str(self.root / "VoxClip.app"), "CLI": "voxclip-cli",
                                 "BUNDLE_ID": "com.voxconvo.voxclip"})
        self.write_command("codesign", '''#!/bin/bash
if [ "$2" = --verbose=4 ]; then
    echo "Identifier=${MOCK_CLI_ID:-com.voxconvo.voxclip.cli}" >&2
elif [[ "$*" == *voxclip-cli ]]; then
    echo "${MOCK_REQUIREMENT_PREFIX}designated => identifier \\"com.voxconvo.voxclip.cli\\""
else
    echo "${MOCK_REQUIREMENT_PREFIX}designated => ${MOCK_APP_REQUIREMENT:-app requirement}"
fi
''')
        self.assertEqual(self.run_function("verify_cli_identity").returncode, 0)
        self.environment["MOCK_REQUIREMENT_PREFIX"] = "# "
        self.assertEqual(self.run_function("verify_cli_identity").returncode, 0)
        self.environment["MOCK_APP_REQUIREMENT"] = 'identifier "com.voxconvo.voxclip.cli"'
        self.assert_failed(self.run_function("verify_cli_identity"), "must have distinct designated requirements")
        self.environment["MOCK_CLI_ID"] = "com.voxconvo.voxclip"
        self.assert_failed(self.run_function("verify_cli_identity"), "CLI signing identifier differs")

    def test_test_artifacts_cannot_be_uploaded_later(self):
        script = self.prepare_upload(test_build=True)
        result = subprocess.run([str(script), "--upload-only", "--dry-run"],
            env=self.environment, text=True, capture_output=True)
        self.assert_failed(result, "Test-build artifacts cannot be uploaded")
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
