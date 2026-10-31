import base64
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest


BUILD = Path(__file__).resolve().parent
TIMEOUT = shutil.which("timeout") or "/opt/homebrew/bin/timeout"
GIT = shutil.which("git")
ALLOWED = {
    "AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET", "AZURE_SIGNING_KVT",
    "AZURE_SIGNING_KVI", "AZURE_SIGNING_KVS", "AZURE_SIGNING_ENDPOINT",
    "AZURE_SIGNING_ACCOUNT", "AZURE_SIGNING_PROFILE",
}
SIGNING_METADATA = {
    "AZURE_SIGNING_ACCOUNT": "fixture-account",
    "AZURE_SIGNING_PROFILE": "fixture-profile",
    "AZURE_SIGNING_ENDPOINT": "https://neu.codesigning.azure.net",
}


def signing_fixture_value(name):
    return SIGNING_METADATA.get(name, "fixture-" + name)


class ReleaseDriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release-driver-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.build = self.repository / "apps/windows/build"
        self.build.mkdir(parents=True)
        for source in BUILD.iterdir():
            if source.is_file() and (source.suffix in (".sh", ".py", ".ps1", ".cs", ".json") or source.name == ".gitignore"):
                shutil.copyfile(source, self.build / source.name)
        self.write_asset_stub()
        (self.repository / "apps/windows/Directory.Build.props").write_text(
            "<Project><PropertyGroup><Version>0.1.0</Version></PropertyGroup></Project>"
        )
        (self.repository / "shared").mkdir()
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            (self.repository / name).write_text("fixture")
        subprocess.run([GIT, "init", "--quiet", str(self.repository)], check=True, capture_output=True)
        subprocess.run([GIT, "-C", str(self.repository), "add", "."], check=True, capture_output=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.events = self.root / "events.jsonl"
        self.ready = self.root / "ready"
        self.signing = self.root / "fixture.env"
        self.signing.write_bytes((
            "\r\n".join(f" export {name} = {signing_fixture_value(name)}" for name in sorted(ALLOWED))
            + "\r\nUNRELATED_TOKEN=fixture-unrelated\r\nAZURE_CLIENT_SECRET_EXTRA=fixture-extra\r\n"
            + "# AZURE_CLIENT_SECRET=" + "fixture-comment\r\nnot AZURE_CLIENT_SECRET=" + "fixture-invalid\r\n"
        ).encode())
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        VOXCLIP_TIMEOUT=TIMEOUT, VOXCLIP_WIN_HOST="fixture@vm.invalid",
                        VOXCLIP_SIGNING_ENV=str(self.signing), VOXCLIP_WIN_BUILD_DIR=r"D:\build-fixture",
                        TEST_ROOT=str(self.root), PYTHONDONTWRITEBYTECODE="1")
        for name in ALLOWED | {"AZURE_SIGNING_KVC", "AZURE_SIGNING_KVU"}:
            self.env.pop(name, None)
        self.write_git_tool()
        self.write_tool("ssh", """
import base64, json, os, pathlib, re, signal, sys, time
root = pathlib.Path(os.environ['TEST_ROOT'])
command = base64.b64decode(sys.argv[-1]).decode('utf-16le')
kind = 'build' if 'vm-release.ps1' in command else ('taskkill' if 'taskkill.exe' in command else 'other')
for operation in ('Acquire', 'Release', 'Check', 'Describe'):
    if '-Operation ' + operation + ' -Path' in command:
        kind = operation
def event(value):
    with (root / 'events.jsonl').open('a') as output:
        output.write(json.dumps(value) + '\\n')
event({'kind': kind, 'argv': sys.argv[1:], 'command': command,
       'signing_path_exposed': 'VOXCLIP_SIGNING_ENV' in os.environ})
owner = root / 'lock-owner'
token = re.search(r"-RunId '([^']+)'", command)
token = token[1] if token else None
if kind in ('taskkill', 'Release'):
    counter = root / (kind + '-count')
    count = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count + 1))
    statuses = json.loads(os.environ.get('TEST_' + kind.upper() + '_RESULTS', '[0]'))
    status = statuses[min(count, len(statuses) - 1)]
    if status:
        sys.exit(status)
if kind == 'Acquire':
    counter = root / 'acquire-count'
    count = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count + 1))
    statuses = json.loads(os.environ.get('TEST_ACQUIRE_RESULTS', '[0]'))
    status = statuses[min(count, len(statuses) - 1)]
    if os.environ.get('TEST_FOREIGN_LOCK'):
        owner.write_text('foreign')
    elif status == 0 or os.environ.get('TEST_ACQUIRE_OWNS'):
        owner.write_text(token)
    if os.environ.get('TEST_LONG_ACQUIRE'):
        (root / 'ready').touch()
        def terminate_acquire(*args):
            event({'kind': 'acquire-terminated'})
            sys.exit(143)
        signal.signal(signal.SIGTERM, terminate_acquire)
        time.sleep(30)
    sys.exit(status)
if kind == 'Release':
    if os.environ.get('TEST_RELEASE_STATUS'):
        sys.exit(int(os.environ['TEST_RELEASE_STATUS']))
    if not owner.exists() or owner.read_text() != token:
        sys.exit(74)
    owner.unlink()
    if os.environ.get('TEST_RELEASE_LOST_REPLY_STATUS'):
        sys.exit(int(os.environ['TEST_RELEASE_LOST_REPLY_STATUS']))
if kind == 'Check':
    if os.environ.get('TEST_CHECK_RESULTS'):
        counter = root / 'check-count'
        count = int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(count + 1))
        statuses = json.loads(os.environ['TEST_CHECK_RESULTS'])
        status = statuses[min(count, len(statuses) - 1)]
        if status:
            sys.exit(status)
    if os.environ.get('TEST_CHECK_STATUS'):
        sys.exit(int(os.environ['TEST_CHECK_STATUS']))
    if not owner.exists() or owner.read_text() != token:
        sys.exit(74)
if kind == 'Check' and os.environ.get('TEST_FAIL_CHECK_AFTER_COPYBACK') and (root / 'copied-back').exists():
    sys.exit(255)
if kind == 'taskkill' and os.environ.get('TEST_CLEANUP_DELAY'):
    (root / 'cleanup-ready').touch()
    time.sleep(float(os.environ['TEST_CLEANUP_DELAY']))
    event({'kind': 'taskkill-done'})
if kind == 'build':
    (root / 'stdin').write_bytes(sys.stdin.buffer.read())
    (root / 'ready').touch()
    if os.environ.get('TEST_LONG_STEP'):
        def terminate(*args):
            event({'kind': 'step-terminated'})
            sys.exit(143)
        signal.signal(signal.SIGTERM, terminate)
        time.sleep(30)
    sys.exit(int(os.environ.get('TEST_BUILD_STATUS', '0')))
""")
        self.write_tool("scp", """
import hashlib, json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
with (root / 'events.jsonl').open('a') as output:
    output.write(json.dumps({'kind': 'scp', 'argv': sys.argv[1:]}) + '\\n')
if any('.env' in item.lower() for item in sys.argv[1:]):
    sys.exit(91)
for argument in sys.argv[1:-1]:
    if argument.endswith('/source.tar.gz') and pathlib.Path(argument).is_file():
        shutil.copyfile(argument, root / 'source.tar.gz')
    if argument.endswith('/config.json') and pathlib.Path(argument).is_file():
        shutil.copyfile(argument, root / 'config.json')
destination = pathlib.Path(sys.argv[-1])
if any('/out/upload/' in item for item in sys.argv):
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'fixture.txt').write_bytes(b'fixture')
    if os.environ.get('TEST_INSTALLER_FIXTURES'):
        for rid in ('win-x64', 'win-arm64'):
            (destination / ('VoxClip-' + rid + '-Setup.exe')).write_bytes(b'fixture-installer')
    (destination / 'SHA256SUMS-windows.txt').write_text(''.join(
        hashlib.sha256(asset.read_bytes()).hexdigest() + '  ' + asset.name + '\\n'
        for asset in destination.iterdir() if asset.name != 'SHA256SUMS-windows.txt'))
if any('/out/evidence/' in item for item in sys.argv):
    if os.environ.get('TEST_EVIDENCE_STATUS'):
        sys.exit(int(os.environ['TEST_EVIDENCE_STATUS']))
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'install-test.json').write_text('{"fixture":true}')
    (root / 'copied-back').touch()
""")

    def write_tool(self, name, code):
        path = self.bin / name
        path.write_text(f"#!{sys.executable} -I\n" + code)
        path.chmod(0o755)

    def records(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()]

    def write_git_tool(self, clean=False):
        self.write_tool("git", "import os, sys\n"
                        f"if 'ls-files' in sys.argv: os.execv({GIT!r}, [{GIT!r}, *sys.argv[1:]])\n"
                        f"if not {clean!r} or 'status' not in sys.argv: print('a' * 40)\n")

    def driver(self, *arguments, **options):
        return subprocess.run([TIMEOUT, "--kill-after=2", "45", "/bin/bash", str(self.build / "release-windows.sh"),
                               *arguments], env=self.env, capture_output=True, text=True, timeout=50, **options)

    def filter_credentials(self, *arguments, **options):
        script = f"""
source '{self.build / 'release-driver-common.sh'}'
TIMEOUT='{TIMEOUT}'; SIGNING_REAL='{self.signing}'
stream_signing_credentials "$@"
"""
        return subprocess.run(["/bin/bash", "-c", script, "filter", *arguments], env=self.env,
                              capture_output=True, timeout=5, **options)

    def write_asset_stub(self):
        assets = self.build / "release-assets.py"
        assets.write_text("""
import hashlib, json, os, pathlib, signal, sys, time
operation = sys.argv[1]
root = pathlib.Path(os.environ['TEST_ROOT'])
if operation == 'version':
    print('0.1.0')
else:
    with (root / 'events.jsonl').open('a') as output:
        output.write(json.dumps({'kind': operation}) + '\\n')
    if operation == 'stage':
        if os.environ.get('TEST_LONG_STAGE'):
            (root / 'stage-pid').write_text(str(os.getpid()))
            def terminate_stage(*args):
                with (root / 'events.jsonl').open('a') as output:
                    output.write(json.dumps({'kind': 'stage-terminated'}) + '\\n')
                sys.exit(143)
            signal.signal(signal.SIGTERM, terminate_stage)
            (root / 'stage-ready').touch()
            time.sleep(30)
        if os.environ.get('TEST_STAGE_STATUS'):
            sys.exit(int(os.environ['TEST_STAGE_STATUS']))
        directory = pathlib.Path(sys.argv[5])
        directory.mkdir(parents=True)
        for name in ('voxclip-ffmpeg-win-x64.zip', 'voxclip-ffmpeg-win-arm64.zip',
                     'FFmpeg-LICENSE.txt', 'FFmpeg-LICENSE.md', 'BUILD.txt',
                     'win-x64-FFmpeg-NOTICES.txt', 'win-arm64-FFmpeg-NOTICES.txt',
                     'win-x64-audit.json', 'win-arm64-audit.json',
                     'stage.json', 'source.tar.xz'):
            (directory / name).write_bytes(b'fixture-stage')
    elif operation == 'source':
        time.sleep(float(os.environ.get('TEST_SOURCE_DELAY', '0')))
        pathlib.Path(sys.argv[3]).write_bytes(b'fixture-source')
    elif operation == 'manifest':
        directory = pathlib.Path(sys.argv[2])
        (directory / 'SHA256SUMS-windows.txt').write_text(''.join(
            hashlib.sha256(asset.read_bytes()).hexdigest() + '  ' + asset.name + '\\n'
            for asset in directory.iterdir() if asset.name != 'SHA256SUMS-windows.txt'))
        if os.environ.get('TEST_FINAL_HASH_FAILURE'):
            (directory / 'fixture.txt').write_bytes(b'fixture-changed-after-manifest')
    elif operation == 'upload-list':
        print('fixture.txt')
""")

    def prepare_local_pipeline(self):
        self.write_git_tool(clean=True)
        plist = self.repository / "apps/macos/Sources/VoxClip/Info.plist"
        plist.parent.mkdir(parents=True)
        plist.write_text('<plist><dict><key>CFBundleShortVersionString</key><string>0.1.0</string></dict></plist>')
        icon = self.repository / "apps/windows/src/VoxClip.App/Assets/VoxClip.ico"
        icon.parent.mkdir(parents=True)
        icon.write_bytes(b"fixture")
        self.write_tool("gh", """
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
with (root / 'events.jsonl').open('a') as output:
    output.write(json.dumps({'kind': 'gh', 'argv': sys.argv[1:]}) + '\\n')
if sys.argv[2] == 'view':
    print('true')
""")

    def test_failed_build_copies_only_evidence_before_remote_cleanup(self):
        self.env['TEST_BUILD_STATUS'] = '17'
        result = self.driver('--skeleton-test', '--no-upload')
        self.assertEqual(result.returncode, 17, result.stderr)
        records = self.records()
        copies = [record for record in records if record['kind'] == 'scp'
                  and any('/out/' in argument for argument in record['argv'])]
        self.assertEqual(len(copies), 1)
        self.assertIn('/out/evidence/.', ' '.join(copies[0]['argv']))
        remote_sources = [argument for argument in copies[0]['argv'] if argument.startswith('fixture@')]
        self.assertEqual(len(remote_sources), 1)
        self.assertNotIn('/private', remote_sources[0])
        self.assertLess(records.index(copies[0]), next(index for index, record in enumerate(records)
                                                    if record['kind'] == 'taskkill'))
        self.assertEqual(len(list(self.build.glob('.release/*/evidence/install-test.json'))), 1)
        driver = (self.build / 'release-windows.sh').read_text()
        self.assertIn('"$TIMEOUT" --kill-after=15 60 scp', driver)

    def test_failed_evidence_copy_preserves_failure_and_still_releases_vm(self):
        self.env.update(TEST_BUILD_STATUS='17', TEST_EVIDENCE_STATUS='19')
        result = self.driver('--skeleton-test', '--no-upload')
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertIn('Bounded failure-evidence copy did not complete', result.stderr)
        self.assertEqual([record['kind'] for record in self.records()][-1], 'Release')

    def test_remote_cleanup_sweeps_only_this_runs_markers_after_taskkill(self):
        result = self.driver('--skeleton-test', '--no-upload')
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.records()
        cleanup = next(record for record in records if record['kind'] == 'taskkill')
        command = cleanup['command']
        self.assertLess(command.index('taskkill.exe'), command.index('Remove-ReleasePendingInstalls'))
        self.assertLess(command.index('Remove-ReleasePendingInstalls'), command.rindex('Remove-Item'))
        self.assertIn("-Filter 'install-root.json'", command)
        self.assertIn('\\out\\evidence', command)
        self.assertNotIn('voxclip-install-*', command)
        self.assertLess(records.index(cleanup), next(index for index, record in enumerate(records)
                                                   if record['kind'] == 'Release'))
        self.assertIn('" 600 || { RELEASE_FAILED=true;', (self.build / 'release-windows.sh').read_text())

    def test_vm_release_precedes_all_mac_source_manifest_and_upload_activity(self):
        self.prepare_local_pipeline()
        result = self.driver("--upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        kinds = [record["kind"] for record in self.records()]
        self.assertEqual(kinds.count("Release"), 1)
        for operation in ("source", "manifest", "upload-list", "gh"):
            self.assertLess(kinds.index("Release"), kinds.index(operation))
        self.assertNotIn("Check", kinds[kinds.index("Release") + 1:])

    def test_local_ffmpeg_stage_precedes_vm_lock_and_transfers_only_pinned_inputs(self):
        self.prepare_local_pipeline()
        result = self.driver('--no-upload')
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.records()
        kinds = [record['kind'] for record in records]
        self.assertLess(kinds.index('stage'), kinds.index('Acquire'))
        ffmpeg_copies = [record for record in records if record['kind'] == 'scp'
                         and any('voxclip-ffmpeg-win-x64.zip' in value for value in record['argv'])]
        self.assertEqual(len(ffmpeg_copies), 1)
        copied = ' '.join(ffmpeg_copies[0]['argv'])
        for expected in ('voxclip-ffmpeg-win-arm64.zip', 'FFmpeg-LICENSE.txt',
                         'win-x64-FFmpeg-NOTICES.txt', 'win-x64-audit.json', 'stage.json'):
            self.assertIn(expected, copied)
        self.assertNotIn('test-tools', copied)
        self.assertNotIn('source.tar.xz', copied)
        self.assertLess(kinds.index('Acquire'), records.index(ffmpeg_copies[0]))

    def test_failed_local_ffmpeg_stage_never_locks_or_contacts_vm(self):
        self.env['TEST_STAGE_STATUS'] = '31'
        result = self.driver('--skeleton-test', '--no-upload')
        self.assertEqual(result.returncode, 31, result.stderr)
        self.assertEqual([record['kind'] for record in self.records()], ['stage'])

    def test_term_and_int_cancel_local_stage_before_vm_contact(self):
        self.prepare_local_pipeline()
        for interrupt, expected in ((signal.SIGTERM, 143), (signal.SIGINT, 130)):
            with self.subTest(interrupt=interrupt):
                for marker in (self.root / 'stage-ready', self.root / 'stage-pid'):
                    marker.unlink(missing_ok=True)
                self.events.unlink(missing_ok=True)
                process = subprocess.Popen(["/bin/bash", str(self.build / "release-windows.sh"),
                                            "--skeleton-test", "--no-upload"],
                                           env=dict(self.env, TEST_LONG_STAGE="1"), stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True, start_new_session=True)
                stage_pid = None
                try:
                    ready = self.root / 'stage-ready'
                    deadline = time.monotonic() + 15
                    while not ready.exists() and time.monotonic() < deadline and process.poll() is None:
                        time.sleep(0.02)
                    self.assertTrue(ready.exists(), 'Local FFmpeg stage never started')
                    stage_pid = int((self.root / 'stage-pid').read_text())
                    started = time.monotonic()
                    process.send_signal(interrupt)
                    _, errors = process.communicate(timeout=8)
                    self.assertLess(time.monotonic() - started, 5)
                    self.assertEqual(process.returncode, expected, errors)
                    self.assertEqual([record['kind'] for record in self.records()],
                                     ['stage', 'stage-terminated'])
                    with self.assertRaises(ProcessLookupError):
                        os.kill(stage_pid, 0)
                    self.assertFalse((self.root / 'lock-owner').exists())
                finally:
                    if stage_pid is not None:
                        try:
                            os.kill(stage_pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
                    process.communicate(timeout=5)

    def test_unreachable_vm_after_copyback_cannot_abort_local_upload(self):
        self.prepare_local_pipeline()
        self.env.update(TEST_FAIL_CHECK_AFTER_COPYBACK="1", TEST_SOURCE_DELAY="1")
        driver = self.build / "release-windows.sh"
        driver.write_text(driver.read_text().replace("heartbeat_loop &", "heartbeat_loop 0.1 0.1 &"))
        result = self.driver("--upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Attached verified Windows assets", result.stdout)
        records = self.records()
        release = next(index for index, record in enumerate(records) if record["kind"] == "Release")
        self.assertTrue(any(record["kind"] == "gh" and record["argv"][1] == "upload"
                            for record in records[release + 1:]))
        self.assertFalse(any(record["kind"] in ("Check", "taskkill", "Release") for record in records[release + 1:]))

    def shorten_acquire_wait(self):
        self.write_tool("fixture-timeout", f"""
import os, sys, time
arguments = sys.argv[1:]
if len(arguments) == 4 and arguments[0] == '--kill-after=2' and arguments[-2] == 'sleep' and arguments[-1] in ('20', '40', '60'):
    time.sleep(0.01)
else:
    os.execv({TIMEOUT!r}, [{TIMEOUT!r}, *arguments])
""")
        self.env["VOXCLIP_TIMEOUT"] = str(self.bin / "fixture-timeout")

    def test_early_cleanup_retries_transient_failures_before_mac_release_steps(self):
        self.prepare_local_pipeline()
        self.shorten_acquire_wait()
        for operation in ("taskkill", "Release"):
            for statuses in ([255, 0], [124, 255, 0]):
                with self.subTest(operation=operation, statuses=statuses):
                    self.events.unlink(missing_ok=True)
                    for name in ("taskkill", "Release"):
                        (self.root / (name + "-count")).unlink(missing_ok=True)
                        self.env.pop("TEST_" + name.upper() + "_RESULTS", None)
                    self.env["TEST_" + operation.upper() + "_RESULTS"] = json.dumps(statuses)
                    result = self.driver("--upload")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn("CRITICAL", result.stderr)
                    kinds = [record["kind"] for record in self.records()]
                    self.assertEqual(kinds.count(operation), len(statuses))
                    self.assertLess(max(index for index, kind in enumerate(kinds) if kind == "Release"),
                                    kinds.index("source"))
                    self.assertIn("Attached verified Windows assets", result.stdout)
                    self.assertFalse((self.root / "lock-owner").exists())

    def test_retained_lock_does_not_prevent_mac_source_manifest_or_upload(self):
        self.prepare_local_pipeline()
        self.shorten_acquire_wait()
        for operation in ("taskkill", "Release"):
            with self.subTest(operation=operation):
                self.events.unlink(missing_ok=True)
                for name in ("taskkill", "Release"):
                    (self.root / (name + "-count")).unlink(missing_ok=True)
                    self.env.pop("TEST_" + name.upper() + "_RESULTS", None)
                self.env["TEST_" + operation.upper() + "_RESULTS"] = "[255, 124, 255]"
                result = self.driver("--upload")
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertIn("CRITICAL", result.stderr)
                self.assertIn("Release steps finished", result.stderr)
                self.assertIn("retained for a human", result.stderr)
                kinds = [record["kind"] for record in self.records()]
                self.assertEqual(kinds.count(operation), 3)
                self.assertEqual(kinds.count("Release"), 0 if operation == "taskkill" else 3)
                for activity in ("source", "manifest", "upload-list", "gh"):
                    self.assertIn(activity, kinds)
                self.assertIn("Attached verified Windows assets", result.stdout)
                self.assertTrue((self.root / "lock-owner").exists())

    def test_early_cleanup_does_not_retry_definite_ownership_loss(self):
        self.prepare_local_pipeline()
        self.env["TEST_RELEASE_RESULTS"] = "[74]"
        result = self.driver("--upload")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual([record["kind"] for record in self.records()].count("Release"), 1)
        self.assertIn("retained for a human", result.stderr)

    def test_lost_release_reply_does_not_report_a_retained_lock(self):
        self.prepare_local_pipeline()
        self.shorten_acquire_wait()
        for status in (124, 255):
            with self.subTest(status=status):
                self.events.unlink(missing_ok=True)
                self.env["TEST_RELEASE_LOST_REPLY_STATUS"] = str(status)
                result = self.driver("--no-upload")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("VM lock no longer owned by this invocation (an earlier release reply was lost)",
                              result.stdout)
                self.assertNotIn("retained", result.stdout + result.stderr)
                self.assertNotIn("CRITICAL", result.stderr)
                kinds = [record["kind"] for record in self.records()]
                self.assertEqual(kinds.count("Release"), 2)
                self.assertEqual(kinds.count("Describe"), 1)
                self.assertFalse((self.root / "lock-owner").exists())

    def prepare_signature_tool(self):
        self.prepare_local_pipeline()
        self.env["TEST_INSTALLER_FIXTURES"] = "1"
        self.write_tool("osslsigncode", """
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
latest = root / 'repository/apps/windows/build/.release/latest'
with (root / 'events.jsonl').open('a') as output:
    output.write(json.dumps({'kind': 'osslsigncode', 'argv': sys.argv[1:],
                             'latest': os.readlink(latest) if latest.is_symlink() else None}) + '\\n')
sys.exit(int(os.environ.get('TEST_SIGNATURE_STATUS', '0')))
""")

    def test_optional_mac_signature_check_verifies_both_installers_before_upload(self):
        self.prepare_signature_tool()
        result = self.driver("--upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.records()
        checks = [record for record in records if record["kind"] == "osslsigncode"]
        self.assertEqual({Path(record["argv"][-1]).name for record in checks},
                         {"VoxClip-win-x64-Setup.exe", "VoxClip-win-arm64-Setup.exe"})
        self.assertTrue(all(record["argv"][:2] == ["verify", "-in"] for record in checks))
        kinds = [record["kind"] for record in records]
        self.assertLess(kinds.index("Release"), kinds.index("osslsigncode"))
        self.assertLess(max(index for index, kind in enumerate(kinds) if kind == "osslsigncode"), kinds.index("gh"))
        self.assertTrue(all(record["latest"] is None for record in checks))
        self.assertTrue((self.build / ".release/latest").is_symlink())

    def test_failed_mac_signature_check_prevents_upload(self):
        self.prepare_signature_tool()
        self.env["TEST_SIGNATURE_STATUS"] = "1"
        result = self.driver("--upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Signature check failed", result.stderr)
        self.assertFalse(any(record["kind"] == "gh" for record in self.records()))
        self.assertFalse(os.path.lexists(self.build / ".release/latest"))

    def test_failed_final_mac_hash_check_cannot_promote_latest_or_upload(self):
        self.prepare_signature_tool()
        self.env["TEST_FINAL_HASH_FAILURE"] = "1"
        result = self.driver("--upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(os.path.lexists(self.build / ".release/latest"))
        kinds = [record["kind"] for record in self.records()]
        self.assertIn("manifest", kinds)
        self.assertFalse(set(kinds) & {"osslsigncode", "gh"})

    def test_failed_mac_signature_check_preserves_a_previous_verified_latest(self):
        self.prepare_signature_tool()
        built = self.driver("--no-upload")
        self.assertEqual(built.returncode, 0, built.stderr)
        latest = self.build / ".release/latest"
        previous = latest.readlink()
        self.env["TEST_SIGNATURE_STATUS"] = "1"
        self.events.unlink()
        failed = self.driver("--upload")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(latest.readlink(), previous)
        self.assertFalse(any(record["kind"] == "gh" for record in self.records()))

    def test_upload_only_verifies_retained_installers_without_vm_access(self):
        self.prepare_signature_tool()
        built = self.driver("--no-upload")
        self.assertEqual(built.returncode, 0, built.stderr)
        self.events.unlink()
        result = self.driver("--upload-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        kinds = [record["kind"] for record in self.records()]
        self.assertEqual(kinds.count("osslsigncode"), 2)
        self.assertLess(kinds.index("osslsigncode"), kinds.index("gh"))
        self.assertFalse(set(kinds) & {"Acquire", "Check", "Release", "scp", "build", "taskkill"})

    def test_missing_mac_signature_tool_is_skipped_with_a_notice(self):
        script = f"""
source '{self.build / 'release-driver-common.sh'}'
command() {{ if [ "$1:$2" = '-v:osslsigncode' ]; then return 1; fi; builtin command "$@"; }}
verify_release_signatures '{self.root}'
"""
        result = subprocess.run(["/bin/bash", "-c", script], env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipping optional Mac signature verification", result.stdout)

    def test_transient_acquire_results_retry_within_the_deadline(self):
        self.shorten_acquire_wait()
        self.env["TEST_ACQUIRE_RESULTS"] = "[124, 255, 0]"
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        kinds = [record["kind"] for record in self.records()]
        self.assertEqual(kinds.count("Acquire"), 3)
        self.assertEqual(kinds.count("Release"), 1)
        self.assertFalse((self.root / "lock-owner").exists())

    def test_lost_acquire_result_recovers_confirmed_ownership(self):
        self.env.update(TEST_ACQUIRE_RESULTS="[255]", TEST_ACQUIRE_OWNS="1")
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        kinds = [record["kind"] for record in self.records()]
        self.assertEqual(kinds.count("Acquire"), 1)
        self.assertEqual(kinds.count("Release"), 1)
        self.assertFalse((self.root / "lock-owner").exists())

    def test_lost_acquire_and_check_replies_recover_after_later_contention(self):
        self.shorten_acquire_wait()
        self.env.update(TEST_ACQUIRE_RESULTS="[255, 73]", TEST_ACQUIRE_OWNS="1",
                        TEST_CHECK_RESULTS="[255, 0]")
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        kinds = [record["kind"] for record in self.records()]
        self.assertEqual([kind for kind in kinds if kind != "stage"][:4], ["Acquire", "Check", "Acquire", "Check"])
        self.assertEqual(kinds.count("Release"), 1)
        self.assertFalse((self.root / "lock-owner").exists())

    def test_resume_never_adopts_or_removes_the_old_run_lock(self):
        run_id = "20261025T015300Z-37984"
        driver = self.build / "release-windows.sh"
        driver.write_text(driver.read_text().replace("lock_deadline=$((SECONDS + 2100))",
                                                     "lock_deadline=$((SECONDS + 1))"))
        for status in (73, 255, 124):
            with self.subTest(status=status):
                self.events.unlink(missing_ok=True)
                (self.root / "lock-owner").write_text(run_id)
                self.env["TEST_ACQUIRE_RESULTS"] = json.dumps([status])
                result = self.driver("--resume-skeleton", run_id, "--no-upload")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Timed out waiting", result.stderr)
                self.assertEqual((self.root / "lock-owner").read_text(), run_id)
                records = self.records()
                self.assertFalse(any(record["kind"] in ("build", "taskkill", "scp") for record in records))
                for record in records:
                    if record["kind"] in ("Acquire", "Check", "Release"):
                        token = re.search(r"-RunId '([^']+)'", record["command"])[1]
                        self.assertNotEqual(token, run_id)
                        self.assertIn(token, result.stdout)
                if status == 73:
                    self.assertFalse(any(record["kind"] == "Release" for record in records))

    def test_sigint_while_resume_waits_preserves_the_old_run_lock(self):
        run_id = "20261025T015300Z-37984"
        waiting = self.root / "wait-ready"
        self.write_tool("waiting-timeout", f"""
import os, pathlib, sys
arguments = sys.argv[1:]
if len(arguments) == 4 and arguments[0] == '--kill-after=2' and arguments[-2:] == ['sleep', '60']:
    pathlib.Path({str(waiting)!r}).touch()
os.execv({TIMEOUT!r}, [{TIMEOUT!r}, *arguments])
""")
        self.env["VOXCLIP_TIMEOUT"] = str(self.bin / "waiting-timeout")
        for status in (73, 255, 124):
            with self.subTest(status=status):
                waiting.unlink(missing_ok=True)
                self.events.unlink(missing_ok=True)
                (self.root / "acquire-count").unlink(missing_ok=True)
                (self.root / "lock-owner").write_text(run_id)
                process = subprocess.Popen(["/bin/bash", str(self.build / "release-windows.sh"),
                                            "--resume-skeleton", run_id, "--no-upload"],
                                           env=dict(self.env, TEST_ACQUIRE_RESULTS=json.dumps([status])),
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                           start_new_session=True)
                try:
                    deadline = time.monotonic() + 15
                    while not waiting.exists() and time.monotonic() < deadline and process.poll() is None:
                        time.sleep(0.02)
                    self.assertTrue(waiting.exists())
                    process.send_signal(signal.SIGINT)
                    _, errors = process.communicate(timeout=8)
                    self.assertEqual(process.returncode, 130, errors)
                    self.assertEqual((self.root / "lock-owner").read_text(), run_id)
                    kinds = [record["kind"] for record in self.records()]
                    self.assertFalse(set(kinds) & {"build", "taskkill", "scp"})
                    self.assertEqual(kinds.count("Release"), 0 if status == 73 else 1)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate(timeout=5)

    def test_uncertain_acquire_failure_attempts_owner_checked_release(self):
        self.shorten_acquire_wait()
        self.env.update(TEST_ACQUIRE_RESULTS="[255, 2]", TEST_ACQUIRE_OWNS="1", TEST_CHECK_STATUS="255")
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        kinds = [record["kind"] for record in self.records()]
        self.assertEqual(kinds[-1], "Release")
        self.assertNotIn("taskkill", kinds)
        self.assertFalse((self.root / "lock-owner").exists())

    def test_foreign_lock_is_never_removed_and_release_74_is_silent(self):
        self.shorten_acquire_wait()
        self.env.update(TEST_ACQUIRE_RESULTS="[73, 2]", TEST_FOREIGN_LOCK="1")
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.records()[-1]["kind"], "Release")
        self.assertEqual((self.root / "lock-owner").read_text(), "foreign")
        self.assertNotIn("CRITICAL", result.stderr)
        self.assertNotIn("cleanup unavailable", result.stderr)

    def test_acquire_deadline_still_releases_ambiguous_ownership(self):
        self.env.update(TEST_ACQUIRE_RESULTS="[124]", TEST_ACQUIRE_OWNS="1", TEST_CHECK_STATUS="255")
        driver = self.build / "release-windows.sh"
        driver.write_text(driver.read_text().replace("lock_deadline=$((SECONDS + 2100))",
                                                     "lock_deadline=$((SECONDS + 1))"))
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Timed out waiting", result.stderr)
        self.assertIn(r"D:\build-fixture\vm.lock", result.stderr)
        self.assertRegex(result.stderr, r"run \d{8}T\d{6}Z-\d+")
        kinds = [record["kind"] for record in self.records()]
        self.assertEqual(kinds[-2:], ["Describe", "Release"])
        self.assertFalse((self.root / "lock-owner").exists())

    def test_unavailable_ambiguous_release_identifies_the_run_and_lock(self):
        self.shorten_acquire_wait()
        self.env.update(TEST_ACQUIRE_RESULTS="[2]", TEST_ACQUIRE_OWNS="1", TEST_RELEASE_STATUS="255")
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ambiguous acquisition cleanup unavailable", result.stderr)
        self.assertIn(r"D:\build-fixture\vm.lock", result.stderr)
        self.assertRegex(result.stderr, r"run \d{8}T\d{6}Z-\d+")
        self.assertRegex((self.root / "lock-owner").read_text(), r"\d{8}T\d{6}Z-\d+\.\d+\.[0-9a-f]{16}")
        self.assertEqual([record["kind"] for record in self.records()].count("Release"), 3)

    def test_ambiguous_acquire_cleanup_retries_a_lost_release_reply(self):
        self.shorten_acquire_wait()
        self.env.update(TEST_ACQUIRE_RESULTS="[255]", TEST_ACQUIRE_OWNS="1",
                        TEST_CHECK_STATUS="255", TEST_RELEASE_RESULTS="[255, 0]")
        driver = self.build / "release-windows.sh"
        driver.write_text(driver.read_text().replace("lock_deadline=$((SECONDS + 2100))",
                                                     "lock_deadline=$((SECONDS + 1))"))
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Timed out waiting", result.stderr)
        self.assertNotIn("WARNING", result.stderr)
        self.assertEqual([record["kind"] for record in self.records()].count("Release"), 2)
        self.assertFalse((self.root / "lock-owner").exists())

    def test_interrupted_acquire_still_releases_its_own_lock(self):
        process = subprocess.Popen(["/bin/bash", str(self.build / "release-windows.sh"),
                                    "--skeleton-test", "--no-upload"],
                                   env=dict(self.env, TEST_LONG_ACQUIRE="1", TEST_ACQUIRE_OWNS="1"),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 15
            while not self.ready.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(self.ready.exists())
            process.send_signal(signal.SIGINT)
            _, errors = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 130, errors)
            kinds = [record["kind"] for record in self.records()]
            self.assertLess(kinds.index("acquire-terminated"), kinds.index("Release"))
            self.assertNotIn("taskkill", kinds)
            self.assertFalse((self.root / "lock-owner").exists())
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    def test_only_allowlisted_names_stream_to_ssh_stdin_and_never_argv(self):
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        stream = (self.root / "stdin").read_text()
        self.assertNotIn("\r", stream)
        names = {line.split("=", 1)[0] for line in stream.splitlines()}
        self.assertEqual(names, ALLOWED)
        self.assertNotIn("UNRELATED_TOKEN", stream)
        records = self.records()
        for record in records:
            arguments = json.dumps(record.get("argv", []))
            self.assertNotIn("fixture-AZURE", arguments)
            self.assertNotIn("fixture-unrelated", arguments)
            self.assertNotIn(str(self.signing), arguments)
            self.assertFalse(record.get("signing_path_exposed", False))
        self.assertTrue(any(record["kind"] == "scp" for record in records))
        self.assertNotIn("fixture-AZURE", result.stdout + result.stderr)
        self.assertTrue(any(r"D:\build-fixture\vm.lock" in record.get("command", "") for record in records))
        self.assertEqual([record["kind"] for record in records].count("Release"), 1)

    def test_grep_environment_cannot_expand_the_credential_allowlist(self):
        for options in ("-C1", "-v"):
            with self.subTest(options=options):
                self.env.update(GREP_OPTIONS=options, GREP_COLOR="fixture", GREP_COLORS="fixture")
                self.test_only_allowlisted_names_stream_to_ssh_stdin_and_never_argv()
                self.events.unlink()

    def test_carriage_returns_are_normalized_before_credential_filtering(self):
        with self.signing.open("ab") as fixture:
            fixture.write(b"AZURE_TENANT_ID=fixture-tenant\rUNRELATED_TOKEN=fixture-unrelated-cr\r"
                          b"AZURE_CLIENT_ID=fixture-client\n")
        self.test_only_allowlisted_names_stream_to_ssh_stdin_and_never_argv()
        self.assertNotIn("fixture-unrelated-cr", (self.root / "stdin").read_text())

    def test_unrelated_non_utf8_bytes_and_leading_bom_do_not_affect_filtering(self):
        self.signing.write_bytes(b"\xef\xbb\xbf" + self.signing.read_bytes()
                                + b"UNRELATED_TOKEN=fixture-latin1-\xff\r# fixture-comment-\xe9\n")
        self.test_only_allowlisted_names_stream_to_ssh_stdin_and_never_argv()
        self.assertNotIn("fixture-latin1", (self.root / "stdin").read_text())

    def test_invalid_utf8_in_allowed_line_reports_only_its_name_and_no_partial_set(self):
        with self.signing.open("ab") as fixture:
            fixture.write(b"AZURE_CLIENT_SECRET=" + b"fixture-invalid-\xff\n")
        for arguments in ((), ("--validate",)):
            with self.subTest(arguments=arguments):
                result = self.filter_credentials(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"Malformed signing variable: AZURE_CLIENT_SECRET\n")
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.events.exists())

    def test_forced_filter_failure_emits_no_partial_credentials_or_exception_text(self):
        common = self.build / "release-driver-common.sh"
        common.write_text(common.read_text().replace(
            "        values[match[1]] = match[2]",
            "        values[match[1]] = match[2]\n"
            "        if len(values) == 2:\n"
            "            raise RuntimeError(\"fixture-private-error-bytes\")"))
        result = self.filter_credentials()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"Signing env file could not be parsed.\n")

    def test_valid_utf8_output_is_encoded_completely_in_validate_and_stream_modes(self):
        with self.signing.open("ab") as fixture:
            fixture.write("AZURE_CLIENT_SECRET=\"fixture-\u20ac\"\n".encode("utf-8"))
        self.env["LC_ALL"] = "C"
        validated = self.filter_credentials("--validate")
        self.assertEqual(validated.returncode, 0, validated.stderr)
        self.assertEqual(validated.stdout, b"")
        result = self.filter_credentials()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("AZURE_CLIENT_SECRET=\"fixture-\u20ac\"\n".encode("utf-8"), result.stdout)

    def test_filter_io_errors_use_a_fixed_message_without_paths_or_tracebacks(self):
        self.signing.unlink()
        result = self.filter_credentials()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"Signing env file could not be parsed.\n")

    def test_malformed_allowed_values_fail_closed_without_disclosing_values(self):
        baseline = self.signing.read_bytes()
        for value in ("fixture; export OTHER_SECRET=fixture-payload", "fixture;OTHER_SECRET=fixture-payload",
                      "'fixture' trailing-payload", '"fixture" trailing-payload', "fixture trailing-payload",
                      "'fixture\nOTHER_SECRET=fixture-payload'", '"fixture\nOTHER_SECRET=fixture-payload"',
                      "'unterminated-fixture", '"unterminated-fixture'):
            with self.subTest(value=value):
                self.signing.write_bytes(baseline + ("AZURE_CLIENT_SECRET=" + value + "\n").encode())
                result = self.driver("--skeleton-test", "--no-upload")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("AZURE_CLIENT_SECRET", result.stderr)
                self.assertNotIn("fixture", result.stdout + result.stderr)
                self.assertFalse(self.events.exists())
                script = f"""
source '{self.build / 'release-driver-common.sh'}'
TIMEOUT='{TIMEOUT}'; SIGNING_REAL='{self.signing}'
stream_signing_credentials
"""
                filtered = subprocess.run(["/bin/bash", "-c", script], env=self.env,
                                          capture_output=True, text=True, timeout=5)
                self.assertNotEqual(filtered.returncode, 0)
                self.assertEqual(filtered.stdout, "")
                self.assertNotIn("fixture", filtered.stderr)

    def test_single_shell_word_values_accept_quotes_spaces_and_no_final_newline(self):
        self.signing.write_text("\n".join(
            f"export {name} = " + (repr(signing_fixture_value(name)) if name in SIGNING_METADATA
                                     else ("'fixture value'" if index % 2 else '"fixture value"'))
            for index, name in enumerate(sorted(ALLOWED))))
        self.test_only_allowlisted_names_stream_to_ssh_stdin_and_never_argv()

    def test_missing_signing_metadata_fails_before_ssh(self):
        for missing in ("AZURE_SIGNING_ACCOUNT", "AZURE_SIGNING_PROFILE"):
            with self.subTest(missing=missing):
                self.signing.write_text("\n".join(f"{name}={signing_fixture_value(name)}" for name in ALLOWED if name != missing))
                result = self.driver("--skeleton-test", "--no-upload")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing, result.stderr)
                self.assertFalse(self.events.exists())

    def assert_metadata_stays_in_stdin(self, expected):
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        stream = dict(line.split("=", 1) for line in (self.root / "stdin").read_text().splitlines())
        for name, value in expected.items():
            self.assertEqual(stream[name].strip("\x27\x22"), value)
            self.assertNotIn(value, result.stdout + result.stderr)
            for record in self.records():
                self.assertNotIn(value, json.dumps(record.get("argv", [])))
                self.assertNotIn(value, record.get("command", ""))
        return stream

    def test_signing_metadata_comes_from_environment_with_alias_only_file(self):
        aliases = ("AZURE_SIGNING_KVT", "AZURE_SIGNING_KVI", "AZURE_SIGNING_KVS")
        self.signing.write_text("\n".join(f"{name}=fixture-alias" for name in aliases)
                                + "\nAZURE_SIGNING_KVC=fixture-ignored-account\n"
                                  "AZURE_SIGNING_KVU=fixture-ignored-endpoint\n")
        self.env.update(SIGNING_METADATA)
        stream = self.assert_metadata_stays_in_stdin(SIGNING_METADATA)
        self.assertEqual(set(stream), set(aliases) | set(SIGNING_METADATA))
        self.assertNotIn("fixture-ignored", (self.root / "stdin").read_text())

    def test_signing_metadata_file_overrides_even_invalid_environment_values(self):
        self.env.update({name: "fixture-invalid-environment;value" for name in SIGNING_METADATA})
        self.assert_metadata_stays_in_stdin(SIGNING_METADATA)

    def test_alias_only_file_defaults_endpoint_with_account_and_profile_environment(self):
        aliases = ("AZURE_SIGNING_KVT", "AZURE_SIGNING_KVI", "AZURE_SIGNING_KVS")
        self.signing.write_text("\n".join(f"{name}=fixture-alias" for name in aliases))
        self.env.update({name: value for name, value in SIGNING_METADATA.items()
                         if name != "AZURE_SIGNING_ENDPOINT"})
        stream = self.assert_metadata_stays_in_stdin(SIGNING_METADATA)
        self.assertEqual(set(stream), set(aliases) | set(SIGNING_METADATA))

    def test_environment_endpoint_overrides_default(self):
        self.signing.write_text("\n".join(f"{name}={signing_fixture_value(name)}"
                                         for name in ALLOWED if name != "AZURE_SIGNING_ENDPOINT"))
        endpoint = "https://weu.codesigning.azure.net"
        self.env["AZURE_SIGNING_ENDPOINT"] = endpoint
        self.assert_metadata_stays_in_stdin(dict(SIGNING_METADATA, AZURE_SIGNING_ENDPOINT=endpoint))

    def test_invalid_signing_metadata_fails_with_name_only_before_lock(self):
        invalid_values = {
            "AZURE_SIGNING_ACCOUNT": ("", " ", "a", "-fixture", "fixture_name", "a" * 65, "fixture/account"),
            "AZURE_SIGNING_PROFILE": ("", " ", "a", "-fixture", "fixture_name", "a" * 65, "fixture/profile"),
            "AZURE_SIGNING_ENDPOINT": ("", "http://neu.codesigning.azure.net", "https://NEU.codesigning.azure.net",
                                       "https://n.codesigning.azure.net", "https://abcdefghi.codesigning.azure.net",
                                       "https://neu.codesigning.azure.net/", "https://neu.codesigning.azure.net.evil"),
        }
        baseline = self.signing.read_text()
        for name, invalid in invalid_values.items():
            for source in ("file", "environment"):
                for value in invalid:
                    with self.subTest(name=name, source=source, value=value):
                        self.env.update(SIGNING_METADATA)
                        lines = [line for line in baseline.splitlines()
                                 if not (source == "environment" and re.match(r"\s*export\s+" + name + r"\s*=", line))]
                        if source == "file":
                            lines.append(f'{name}="{value}"')
                        else:
                            self.env[name] = value
                        self.signing.write_text("\n".join(lines))
                        result = self.driver("--skeleton-test", "--no-upload")
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stderr, name + "\n")
                        self.assertEqual(result.stdout, "")
                        self.assertFalse(self.events.exists())
                        filtered = self.filter_credentials()
                        self.assertNotEqual(filtered.returncode, 0)
                        self.assertEqual(filtered.stderr, (name + "\n").encode())
                        self.assertEqual(filtered.stdout, b"")

    def test_environment_metadata_is_not_unquoted_as_shell_syntax(self):
        self.signing.write_text("\n".join(f"{name}=fixture" for name in ALLOWED if name not in SIGNING_METADATA))
        self.env.update(SIGNING_METADATA)
        self.env["AZURE_SIGNING_ACCOUNT"] = "'fixture-account'"
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "AZURE_SIGNING_ACCOUNT\n")
        self.assertFalse(self.events.exists())

    def test_signing_metadata_accepts_exact_pattern_boundaries(self):
        for region in ("aa", "abcdefgh"):
            self.signing.write_text("\n".join(f"{name}=fixture" for name in ALLOWED if name not in SIGNING_METADATA))
            self.env.update(AZURE_SIGNING_ACCOUNT="A1", AZURE_SIGNING_PROFILE="Z" * 64,
                            AZURE_SIGNING_ENDPOINT=f"https://{region}.codesigning.azure.net")
            result = self.filter_credentials("--validate")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"")

    def test_empty_identity_or_secret_pairs_fail_before_ssh(self):
        for required in (("AZURE_TENANT_ID", "AZURE_SIGNING_KVT"), ("AZURE_CLIENT_ID", "AZURE_SIGNING_KVI"),
                         ("AZURE_CLIENT_SECRET", "AZURE_SIGNING_KVS")):
            baseline = "\n".join(f"{name}={signing_fixture_value(name)}" for name in ALLOWED if name not in required)
            for name in required:
                for value in ('""', "''", '"   "'):
                    with self.subTest(required=required, name=name, value=value):
                        self.signing.write_text(baseline + f"\n{name}={value}\n")
                        result = self.driver("--skeleton-test", "--no-upload")
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(required[0], result.stderr)
                        self.assertIn(required[1], result.stderr)
                        self.assertNotIn("fixture", result.stderr)
                        self.assertFalse(self.events.exists())
                        filtered = self.filter_credentials()
                        self.assertNotEqual(filtered.returncode, 0)
                        self.assertEqual(filtered.stdout, b"")

    def test_nonempty_alias_can_supply_each_required_identity_or_secret(self):
        for canonical, alias in (("AZURE_TENANT_ID", "AZURE_SIGNING_KVT"), ("AZURE_CLIENT_ID", "AZURE_SIGNING_KVI"),
                                 ("AZURE_CLIENT_SECRET", "AZURE_SIGNING_KVS")):
            with self.subTest(canonical=canonical, alias=alias):
                self.signing.write_text("\n".join(f"{name}={signing_fixture_value(name)}" for name in ALLOWED if name != canonical)
                                        + f"\n{canonical}=\"\"\n")
                result = self.filter_credentials("--validate")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")

    def test_whitespace_canonical_value_cannot_fall_back_to_a_valid_alias(self):
        baseline = self.signing.read_text()
        for canonical in ("AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET"):
            with self.subTest(canonical=canonical):
                self.signing.write_text(baseline + f"\n{canonical}='   '\n")
                result = self.driver("--skeleton-test", "--no-upload")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(canonical, result.stderr)
                self.assertNotIn("fixture", result.stderr)
                self.assertFalse(self.events.exists())
                filtered = self.filter_credentials()
                self.assertNotEqual(filtered.returncode, 0)
                self.assertEqual(filtered.stdout, b"")

    def test_missing_host_fails_before_ssh(self):
        del self.env["VOXCLIP_WIN_HOST"]
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VOXCLIP_WIN_HOST", result.stderr)
        self.assertFalse(self.events.exists())

    def test_symlinked_checkout_rejects_internal_signing_fixture_before_ssh_or_tar(self):
        internal_fixture = self.repository / "apps/windows/credential-fixture.txt"
        shutil.copyfile(self.signing, internal_fixture)
        linked = self.root / "linked-checkout"
        linked.symlink_to(self.repository, target_is_directory=True)
        self.build = linked / "apps/windows/build"
        self.env["VOXCLIP_SIGNING_ENV"] = str(linked / "apps/windows/credential-fixture.txt")
        self.assert_internal_signing_fixture_rejected()

    def test_case_variant_internal_signing_fixture_is_rejected_by_identity(self):
        internal_fixture = self.repository / "apps/windows/credential-fixture.txt"
        shutil.copyfile(self.signing, internal_fixture)
        variant = self.root / "REPOSITORY/APPS/WINDOWS/CREDENTIAL-FIXTURE.TXT"
        if not variant.exists() or not variant.samefile(internal_fixture):
            self.skipTest("Case-insensitive filesystem required")
        self.env["VOXCLIP_SIGNING_ENV"] = str(variant)
        self.assert_internal_signing_fixture_rejected()

    def test_external_symlink_to_internal_signing_fixture_is_rejected_by_identity(self):
        internal_fixture = self.repository / "apps/windows/credential-fixture.txt"
        shutil.copyfile(self.signing, internal_fixture)
        linked = self.root / "linked-fixture.txt"
        linked.symlink_to(internal_fixture)
        self.env["VOXCLIP_SIGNING_ENV"] = str(linked)
        self.assert_internal_signing_fixture_rejected()

    def assert_internal_signing_fixture_rejected(self):
        self.write_tool("tar", "import os, pathlib\n"
                        "(pathlib.Path(os.environ['TEST_ROOT']) / 'tar-called').touch()\n")
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Signing env file must remain outside the repository", result.stderr)
        self.assertFalse(self.events.exists())
        self.assertFalse((self.root / "tar-called").exists())

    def test_external_hard_link_to_internal_signing_fixture_fails_before_staging(self):
        internal_fixture = self.repository / "apps/windows/credential-fixture.txt"
        os.link(self.signing, internal_fixture)
        self.write_tool("tar", "import os, pathlib\n"
                        "(pathlib.Path(os.environ['TEST_ROOT']) / 'tar-called').touch()\n")
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "Signing env file must not be hard-linked.\n")
        self.assertFalse(self.events.exists())
        self.assertFalse((self.root / "tar-called").exists())

    def test_dirty_archives_use_git_paths_and_never_include_ignored_or_outside_files(self):
        self.prepare_local_pipeline()
        windows = self.repository / "apps/windows"
        ignored = windows / "innocuous notes.txt"
        hard_link = windows / "unusual-linked-file.dat"
        private_bytes = b"fixture-private-bytes-" + os.urandom(32)
        ignored.write_bytes(private_bytes)
        os.link(ignored, hard_link)
        (windows / ".gitignore").write_text("innocuous notes.txt\nunusual-linked-file.dat\n")
        outside = self.repository / "outside-staged-paths.txt"
        outside.write_bytes(b"fixture-outside-bytes")
        included = windows / "source with spaces\nand newline.cs"
        included.write_text("fixture-source")
        for arguments in (("--allow-dirty", "--no-upload"), ("--skeleton-test", "--no-upload")):
            with self.subTest(arguments=arguments):
                result = self.driver(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                with tarfile.open(self.root / "source.tar.gz") as archive:
                    names = archive.getnames()
                    self.assertIn(str(included.relative_to(self.repository)), names)
                    self.assertIn("LICENSE", names)
                    for excluded in (ignored, hard_link, outside):
                        self.assertNotIn(str(excluded.relative_to(self.repository)), names)
                    self.assertFalse(any(".release/" in name or ".git/" in name for name in names))
                    self.assertFalse(any(private_bytes in archive.extractfile(member).read()
                                         for member in archive if member.isfile()))

    def test_secret_named_paths_fail_before_tar_with_real_ignore_rules(self):
        self.prepare_local_pipeline()
        for relative in (".gitignore", "apps/windows/.gitignore", "apps/windows/build/.gitignore"):
            shutil.copyfile(BUILD.parents[2] / relative, self.repository / relative)
        self.write_tool("tar", "import os, pathlib\n"
                        "(pathlib.Path(os.environ['TEST_ROOT']) / 'tar-called').touch()\n")
        for relative in ("azure-signing.env", ".env", "Assets/release.pfx", "key.p12",
                         "Release.ENV", ".ENV.local", "AZURE-SIGNING-config", "Assets/RELEASE.PFX",
                         "KEY.P12", "certificate.CER", "private.KEY", "private.PEM", "SiGnInG/key.txt"):
            for arguments in (("--allow-dirty", "--no-upload"), ("--skeleton-test", "--no-upload")):
                with self.subTest(relative=relative, arguments=arguments):
                    planted = self.repository / "apps/windows/src/VoxClip.App" / relative
                    planted.parent.mkdir(parents=True, exist_ok=True)
                    planted.write_text("fixture-only")
                    result = self.driver(*arguments)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(str(planted.relative_to(self.repository)), result.stderr)
                    self.assertFalse((self.root / "tar-called").exists())
                    self.assertFalse((self.root / "source.tar.gz").exists())
                    self.assertFalse(any(self.build.glob(".release/**/source.tar.gz")))
                    self.assertFalse(any(record['kind'] in ('Acquire', 'Check', 'scp', 'taskkill', 'Release')
                                         for record in self.records()),
                                     'Local rejection must precede all VM access')
                    planted.unlink()

    def test_force_added_secret_named_path_fails_before_tar(self):
        self.prepare_local_pipeline()
        planted = self.repository / "apps/windows/forced.PEM"
        planted.write_text("fixture-only")
        subprocess.run([GIT, "-C", str(self.repository), "add", "-f", str(planted)],
                       check=True, capture_output=True)
        result = self.driver("--skeleton-test", "--no-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(planted.relative_to(self.repository)), result.stderr)
        self.assertFalse((self.root / "source.tar.gz").exists())
        self.assertEqual([record['kind'] for record in self.records()], ['stage'],
                         'Forced secret names must fail before VM locking')

    def test_local_archive_failure_never_acquires_or_prepares_vm(self):
        self.write_tool('tar', 'import sys\nsys.exit(29)\n')
        result = self.driver('--skeleton-test', '--no-upload')
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assertEqual([record['kind'] for record in self.records()], ['stage'])
        self.assertFalse(list(self.build.glob('.release/*/staging.*')))

    def test_tar_secret_exclusions_work_without_first_layer_validation(self):
        names = ('Release.ENV', '.Env.local', 'AZURE-signing.txt', 'release.PFX',
                 'key.p12', 'certificate.Cer', 'private.KEY', 'private.pem',
                 'SiGnInG/inner.cs', 'nested/SiGnInG/inner.cs', 'x.KEY/inner.cs',
                 'nested/Release.ENV/inner.cs', 'safe source\nwith space.cs')
        for name in names:
            path = self.repository / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture-only')
        listing = self.root / 'tar-paths'
        listing.write_bytes(b''.join(os.fsencode(name) + b'\0' for name in names))
        output = self.root / 'second-layer.tar.gz'
        result = subprocess.run(['/bin/bash', '-c',
                                 'source "$1"; archive_release_paths "$2" "$3" "$4"',
                                 'tar-test', str(self.build / 'release-driver-common.sh'),
                                 str(self.repository), str(output), str(listing)],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(output) as archive:
            self.assertEqual(archive.getnames(), ['safe source\nwith space.cs'])

    def test_unstaged_tracked_deletions_do_not_break_dirty_or_skeleton_staging(self):
        self.prepare_local_pipeline()
        deleted = self.repository / "apps/windows/deleted-source.cs"
        deleted.write_text("fixture-source")
        subprocess.run([GIT, "-C", str(self.repository), "add", str(deleted)], check=True, capture_output=True)
        deleted.unlink()
        for arguments in (("--allow-dirty", "--no-upload"), ("--skeleton-test", "--no-upload")):
            with self.subTest(arguments=arguments):
                result = self.driver(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                with tarfile.open(self.root / "source.tar.gz") as archive:
                    self.assertNotIn(str(deleted.relative_to(self.repository)), archive.getnames())
                    self.assertIn("LICENSE", archive.getnames())

    def test_nested_untracked_repositories_are_never_recursively_archived(self):
        self.prepare_local_pipeline()
        nested = self.repository / "apps/windows/vendor/nested"
        nested.mkdir(parents=True)
        subprocess.run([GIT, "init", "--quiet", str(nested)], check=True, capture_output=True)
        private_bytes = b"fixture-nested-private-bytes-" + os.urandom(32)
        (nested / "nested-private.txt").write_bytes(private_bytes)
        for arguments in (("--allow-dirty", "--no-upload"), ("--skeleton-test", "--no-upload")):
            with self.subTest(arguments=arguments):
                result = self.driver(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                with tarfile.open(self.root / "source.tar.gz") as archive:
                    prefix = str(nested.relative_to(self.repository))
                    self.assertIn(prefix, archive.getnames())
                    self.assertFalse(any(name.startswith(prefix + "/") for name in archive.getnames()))
                    self.assertFalse(any(private_bytes in archive.extractfile(member).read()
                                         for member in archive if member.isfile()))

    def test_skeleton_upload_is_refused(self):
        result = self.driver("--skeleton-test", "--upload", "--dry-run")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.events.exists())

    def test_dry_run_modes_need_no_credentials_and_never_contact_remote_tools(self):
        self.env.pop("VOXCLIP_WIN_HOST", None)
        self.env["VOXCLIP_SIGNING_ENV"] = str(self.root / "missing-fixture.env")
        for arguments in (("--skeleton-test", "--no-upload", "--dry-run"),
                          ("--upload", "--dry-run"), ("--upload-only", "--dry-run")):
            with self.subTest(arguments=arguments):
                result = self.driver(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("no network or signing side effects", result.stdout)
                self.assertFalse(self.events.exists())
                self.assertFalse((self.build / ".release").exists())

    def test_planted_cwd_modules_never_execute_in_any_driver_python(self):
        planted = self.root / "planted-modules"
        planted.mkdir()
        marker = self.root / "planted-module-ran"
        for name in ("argparse", "fnmatch", "json", "re", "plistlib"):
            (planted / (name + ".py")).write_text(
                f"from pathlib import Path\nPath({str(marker)!r}).touch()\n"
                "raise RuntimeError('fixture planted module executed')\n")
        filtered = self.filter_credentials(cwd=planted)
        self.assertEqual(filtered.returncode, 0, filtered.stderr)
        self.assertEqual({line.split(b"=", 1)[0].decode("ascii") for line in filtered.stdout.splitlines()}, ALLOWED)
        self.env["PYTHONPATH"] = ":"
        result = self.driver("--skeleton-test", "--no-upload", "--dry-run", cwd=planted)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.prepare_local_pipeline()
        for pythonpath in (":", ".", ":/nonexistent"):
            self.env["PYTHONPATH"] = pythonpath
            for arguments in (("--skeleton-test", "--no-upload"), ("--upload",), ("--upload", "--dry-run")):
                with self.subTest(pythonpath=pythonpath, arguments=arguments):
                    result = self.driver(*arguments, cwd=planted)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(marker.exists())
                    self.assertNotIn("planted module", result.stdout + result.stderr)

    def test_every_driver_python_invocation_uses_isolated_mode(self):
        driver = (self.build / "release-windows.sh").read_text()
        heredocs = re.findall(r"python3 ([^\n]+)<<'PY'", driver)
        self.assertEqual(len(heredocs), 4)
        self.assertTrue(all(command.startswith("-I - ") for command in heredocs))
        for name, count in (("release-windows.sh", 11), ("release-driver-common.sh", 1)):
            source = (self.build / name).read_text()
            commands = [line.split("python3 ", 1)[1] for line in source.splitlines()
                        if "python3 " in line and not line.startswith("for command in ")]
            self.assertEqual(len(commands), count)
            self.assertTrue(all(command.startswith("-I ") for command in commands))

    def test_draft_creation_and_published_release_safety(self):
        self.write_tool("gh", """
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
with (root / 'events.jsonl').open('a') as output:
    output.write(json.dumps({'kind': 'gh', 'argv': sys.argv[1:]}) + '\\n')
if sys.argv[2] == 'create':
    (root / 'draft').touch()
elif os.environ['TEST_DRAFT_STATE'] == 'published':
    print('false')
elif os.environ['TEST_DRAFT_STATE'] == 'existing' or (root / 'draft').exists():
    print('true')
else:
    sys.exit(1)
""")
        for state, release_version, expected, creates in (
            ("missing", "0.1.0", 0, 1), ("existing", "0.1.0", 0, 0),
            ("published", "0.1.0", 1, 0), ("missing", "0.1.0-beta.1", 0, 1),
        ):
            with self.subTest(state=state, version=release_version):
                self.events.unlink(missing_ok=True)
                (self.root / "draft").unlink(missing_ok=True)
                script = f"""
set -euo pipefail
source '{BUILD / 'release-driver-common.sh'}'
TIMEOUT='{TIMEOUT}'
GITHUB_REPO='fixture/repository'; VERSION='{release_version}'; TAG='v{release_version}'
ensure_release_draft '{self.root / 'draft-status'}'
"""
                result = subprocess.run([TIMEOUT, "10", "/bin/bash", "-c", script],
                                        env=dict(self.env, TEST_DRAFT_STATE=state), capture_output=True,
                                        text=True, timeout=15)
                self.assertEqual(result.returncode, expected, result.stderr)
                creation = [record for record in self.records() if record["argv"][1] == "create"]
                self.assertEqual(len(creation), creates)
                if creation:
                    self.assertIn("--draft", creation[0]["argv"])
                    self.assertIn("--verify-tag", creation[0]["argv"])
                    self.assertEqual("--prerelease" in creation[0]["argv"], "-" in release_version)

    def test_signtool_configuration_preserves_override_or_requests_vm_discovery(self):
        self.prepare_local_pipeline()
        for override in (None, r"C:\fixture\signtool.exe"):
            with self.subTest(override=override):
                if override is None:
                    self.env.pop("VOXCLIP_VM_SIGNTOOL", None)
                else:
                    self.env["VOXCLIP_VM_SIGNTOOL"] = override
                result = self.driver("--skeleton-test", "--no-upload")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((self.root / "config.json").read_text())["SignTool"], override or "")

    def test_smoke_installs_are_temporary_and_receive_the_runtime(self):
        smoke = (BUILD / "Test-Install.ps1").read_text()
        self.assertIn("[IO.Path]::GetTempPath()", smoke)
        self.assertIn("--silent --installto", smoke)
        self.assertNotIn("$installRoot = Join-Path $env:LOCALAPPDATA", smoke)
        self.assertIn("Invoke-ReleaseInstallCleanup -InstallRoot $installRoot", smoke)
        self.assertIn("Remove-ReleaseInstallDirectory -InstallRoot $InstallRoot",
                      (BUILD / "Release-Common.ps1").read_text())
        self.assertIn("Remove-Item -LiteralPath $InstallRoot -Recurse -Force",
                      (BUILD / "Release-Common.ps1").read_text())
        self.assertIn("-RuntimeIdentifier $rid -ReportDirectory", (BUILD / "vm-release.ps1").read_text())

    def test_published_payloads_ship_only_the_pinned_onnx_runtime_before_signing(self):
        vm = (BUILD / "vm-release.ps1").read_text()
        check = "& (Join-Path $windows 'build\\Assert-OnnxRuntimePin.ps1') -AppDirectory $app -RuntimeIdentifier $rid"
        self.assertEqual(vm.count(check), 1)
        payload = vm.index("Assert-ReleaseWhisperRuntimes -AppDirectory $app -RuntimeIdentifier $rid")
        self.assertLess(payload, vm.index(check))
        self.assertLess(vm.index(check), vm.index("Copy-ReleaseFfmpeg -Rid $rid -AppDirectory $app -Pin $pin"))
        self.assertLess(vm.index(check), vm.index("Sign-Artifacts.ps1"))
        self.assertTrue((BUILD / "Assert-OnnxRuntimePin.ps1").is_file())

    def test_term_and_int_interrupt_long_step_before_remote_cleanup(self):
        for interrupt, expected in ((signal.SIGTERM, 143), (signal.SIGINT, 130)):
            with self.subTest(interrupt=interrupt):
                self.ready.unlink(missing_ok=True)
                self.events.unlink(missing_ok=True)
                process = subprocess.Popen(["/bin/bash", str(self.build / "release-windows.sh"),
                                            "--skeleton-test", "--no-upload"],
                                           env=dict(self.env, TEST_LONG_STEP="1"), stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 15
                    while not self.ready.exists() and time.monotonic() < deadline and process.poll() is None:
                        time.sleep(0.05)
                    self.assertTrue(self.ready.exists())
                    started = time.monotonic()
                    process.send_signal(interrupt)
                    process.communicate(timeout=8)
                    self.assertLess(time.monotonic() - started, 5)
                    self.assertEqual(process.returncode, expected)
                    kinds = [record["kind"] for record in self.records()]
                    self.assertLess(kinds.index("step-terminated"), kinds.index("taskkill"))
                    self.assertLess(kinds.index("taskkill"), kinds.index("Release"))
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=5)

    def test_double_sigint_cannot_interrupt_owner_checked_release(self):
        process = subprocess.Popen(["/bin/bash", str(self.build / "release-windows.sh"),
                                    "--skeleton-test", "--no-upload"],
                                   env=dict(self.env, TEST_LONG_STEP="1", TEST_CLEANUP_DELAY="1"),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        try:
            for marker in (self.ready, self.root / "cleanup-ready"):
                deadline = time.monotonic() + 15
                while not marker.exists() and time.monotonic() < deadline and process.poll() is None:
                    time.sleep(0.02)
                self.assertTrue(marker.exists())
                if marker == self.ready:
                    process.send_signal(signal.SIGINT)
                else:
                    os.killpg(process.pid, signal.SIGINT)
            _, errors = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 130, errors)
            kinds = [record["kind"] for record in self.records()]
            self.assertLess(kinds.index("step-terminated"), kinds.index("taskkill"))
            self.assertLess(kinds.index("taskkill-done"), kinds.index("Release"))
            self.assertEqual(kinds.count("Release"), 1)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    def test_ownership_heartbeat_retries_transients_but_not_owner_loss(self):
        for statuses, count in (([255, 255, 74], 3), ([74], 1), ([255, 255, 255], 3), ([255, 255, 0, 74], 4)):
            with self.subTest(statuses=statuses):
                state = self.root / "heartbeat-count"
                state.write_text("0")
                self.write_tool("heartbeat", "import pathlib, sys\n"
                                f"state=pathlib.Path({str(state)!r})\n"
                                "count=int(state.read_text()); state.write_text(str(count+1))\n"
                                f"sys.exit({statuses!r}[count])\n")
                script = f"""
set -euo pipefail
source '{BUILD / 'release-driver-common.sh'}'
TIMEOUT='{TIMEOUT}'
RELEASE_PID=$$
LOCK_SCRIPT=''; LOCK='fixture'; LOCK_OWNER='fixture'
remote_ps() {{ exec '{self.bin / 'heartbeat'}'; }}
trap 'exit 143' TERM
heartbeat_loop 0.1 0.1 &
worker=$!
wait "$worker"
"""
                result = subprocess.run([TIMEOUT, "5", "/bin/bash", "-c", script], capture_output=True,
                                        text=True, timeout=8)
                self.assertEqual(result.returncode, 143)
                self.assertEqual(int(state.read_text()), count)


if __name__ == "__main__":
    unittest.main()
