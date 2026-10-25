import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile


specification = importlib.util.spec_from_file_location("release_assets", Path(__file__).with_name("release-assets.py"))
assets = importlib.util.module_from_spec(specification)
specification.loader.exec_module(assets)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_tar(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, body, kind in entries:
            info = tarfile.TarInfo(name)
            if kind == "file":
                info.size = len(body)
                archive.addfile(info, io.BytesIO(body))
            elif kind == "link":
                info.type = tarfile.SYMTYPE
                info.linkname = body.decode()
                archive.addfile(info)
    return output.getvalue()


def pe(machine):
    data = bytearray(128)
    data[:2] = b"MZ"
    data[60:64] = (64).to_bytes(4, "little")
    data[64:68] = b"PE\0\0"
    data[68:70] = machine.to_bytes(2, "little")
    return bytes(data)


class ReleaseAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.recipe = self.repository / "tools/ffmpeg-build"
        self.recipe.mkdir(parents=True)
        self.cache = self.root / "cache"
        (self.cache / "downloads").mkdir(parents=True)
        self.pin_path = self.repository / "apps/windows/build/ffmpeg.json"
        self.pin_path.parent.mkdir(parents=True)
        self.source_assets = []
        for component, name in (("ffmpeg", "ffmpeg.tar.gz"), ("llvm-mingw", "llvm-mingw.tar.gz"),
                                ("mingw-w64", "mingw.tar.gz"), ("llvm-project", "llvm.tar.gz"),
                                ("amf", "amf.tar.gz")):
            body = source_tar([("root/LICENSE.txt", b"MIT license", "file"),
                               ("root/COPYING.LGPLv2.1", b"LGPL 2.1 complete fixture text\n", "file"),
                               ("root/LICENSE.md", b"FFmpeg license fixture text\n", "file"),
                               ("root/amf/public/include/header.h", b"header", "file")])
            path = self.cache / "downloads" / name
            path.write_bytes(body)
            asset = {"component": component, "name": name, "url": "https://example.invalid/" + name,
                     "sha256": digest(path), "size": path.stat().st_size}
            if component == "amf":
                asset["includePaths"] = ["amf/public/include", "LICENSE.txt"]
            self.source_assets.append(asset)
        tool = self.cache / "downloads/meson.tar.gz"
        tool.write_bytes(source_tar([("root/meson.py", b"pinned build tool source", "file")]))
        self.build_tools = [{"component": "meson", "name": tool.name, "url": "https://example.invalid/meson",
                             "sha256": digest(tool), "size": tool.stat().st_size}]
        toolchain = {"component": "llvm-mingw-host", "name": "host.tar.xz", "url": "https://example.invalid/host",
                     "sha256": "1" * 64, "size": 123}
        self.lock = {"sourceCommit": "a" * 40, "sourceAssets": self.source_assets + self.build_tools,
                     "toolchains": {"Darwin-arm64": toolchain}}
        (self.recipe / "sources.json").write_text(json.dumps(self.lock))
        for name in assets.RECIPE_FILES:
            (self.recipe / name).write_text("fixture recipe " + name)
        inputs = {"sources": self.lock, "recipe": {name: digest(self.recipe / name) for name in assets.RECIPE_FILES}}
        inputs_digest = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
        self.pin = {"schema": "voxclip-ffmpeg/2", "version": "n9.0.2", "sourceCommit": "a" * 40,
                    "recipe": "tools/ffmpeg-build", "recipeCommit": "BUILD_COMMIT",
                    "buildInputsSha256": inputs_digest,
                    "configure": {"win-x64": "--arch=x86_64 --enable-shared --enable-amf",
                                  "win-arm64": "--arch=aarch64 --enable-shared --enable-amf"},
                    "license": "LGPL version 2.1 or later", "sourceAssets": self.source_assets,
                    "buildTools": self.build_tools, "toolchains": self.lock["toolchains"],
                    "libraryMajors": {"avcodec": 63, "avformat": 63, "avutil": 61, "avfilter": 12,
                                      "swresample": 7, "swscale": 10},
                    "dlls": ["avcodec", "avformat", "avutil", "avfilter", "swresample", "swscale"],
                    "builds": {}, "reproducibility": {}}
        for rid, machine in (("win-x64", 0x8664), ("win-arm64", 0xAA64)):
            archive_name = "voxclip-ffmpeg-" + rid + ".zip"
            report_dir = self.cache / "reports" / (rid + "-1")
            report_dir.mkdir(parents=True)
            archive = report_dir / archive_name
            dlls = {}
            with zipfile.ZipFile(archive, "w") as zipped:
                for library, major in self.pin["libraryMajors"].items():
                    name = f"{library}-{major}.dll"
                    body = pe(machine)
                    zipped.writestr("bin/" + name, body)
                    dlls[name] = {"sha256": hashlib.sha256(body).hexdigest(), "size": len(body), "imports": []}
            build = {"name": archive_name, "sha256": digest(archive), "size": archive.stat().st_size}
            self.pin["builds"][rid] = build
            self.pin["reproducibility"][rid] = {"identical": True, "firstSha256": build["sha256"],
                                                  "secondSha256": build["sha256"], "differences": {}}
            notice = "Notices for " + rid + "\n"
            for attempt in (1, 2):
                current = self.cache / "reports" / f"{rid}-{attempt}"
                current.mkdir(parents=True, exist_ok=True)
                if attempt == 2:
                    shutil.copyfile(archive, current / archive_name)
                (current / "report.json").write_text(json.dumps({"rid": rid, "archive": archive_name,
                    "size": build["size"], "sha256": build["sha256"], "sourceCommit": self.pin["sourceCommit"],
                    "buildInputsSha256": inputs_digest, "configure": self.pin["configure"][rid],
                    "license": self.pin["license"], "dlls": dlls,
                    "runtimeObjects": {"avcodec": {"archiveMembers": ["fixture-runtime.o"]}},
                    "components": {"decoder": ["h264"]},
                    "licenceAudit": {"noticeSha256": hashlib.sha256(notice.encode()).hexdigest()}}))
                (current / "FFmpeg-NOTICES.txt").write_text(notice)
                (current / "FFmpeg-LICENSE.txt").write_text("LGPL 2.1 complete fixture text\n")
                (current / "FFmpeg-LICENSE.md").write_text("FFmpeg license fixture text\n")
        self.save_pin()
        subprocess.run(["git", "init", "--quiet", str(self.repository)], check=True)
        subprocess.run(["git", "-C", str(self.repository), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repository), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "fixture"], check=True)
        self.commit = subprocess.check_output(["git", "-C", str(self.repository), "rev-parse", "HEAD"], text=True).strip()
        self.stage_dir = self.root / "staged"

    def save_pin(self):
        self.pin_path.write_text(json.dumps(self.pin))

    def stage(self):
        assets.stage(self.pin_path, self.repository, self.cache, self.stage_dir, self.commit)

    def test_schema2_local_stage_and_exact_source_archive(self):
        self.stage()
        output = self.root / "VoxClip-win-ffmpeg-source.tar.xz"
        assets.source_archive(self.stage_dir, output)
        with tarfile.open(output) as archive:
            names = set(archive.getnames())
            for name in ("ffmpeg-source/BUILD.txt", "ffmpeg-source/ffmpeg.json",
                         "ffmpeg-source/SOURCE-ASSETS.json", "ffmpeg-source/FFmpeg-LICENSE.txt",
                         "ffmpeg-source/win-x64-audit.json",
                         "ffmpeg-source/win-x64-FFmpeg-NOTICES.txt",
                         "ffmpeg-source/sources/ffmpeg.tar.gz", "ffmpeg-source/sources/meson.tar.gz",
                         "ffmpeg-source/sources/amf-selected.tar.gz",
                         "ffmpeg-source/tools/ffmpeg-build/sources.json"):
                self.assertIn(name, names)
            self.assertNotIn("ffmpeg-source/sources/amf.tar.gz", names)
            selection = json.loads(archive.extractfile("ffmpeg-source/SOURCE-ASSETS.json").read())
            self.assertEqual(next(item for item in selection if item["component"] == "amf")["originalSha256"],
                             self.source_assets[-1]["sha256"])
            self.assertFalse(any(any(term in name for term in ("config.log", "build.log", ".map", "private"))
                                 for name in names))
            build = archive.extractfile("ffmpeg-source/BUILD.txt").read().decode()
            self.assertIn(self.commit, build)
            self.assertIn(self.pin["builds"]["win-x64"]["sha256"], build)
            self.assertNotIn("BtbN", build)
            selected = archive.extractfile("ffmpeg-source/sources/amf-selected.tar.gz").read()
            with tarfile.open(fileobj=io.BytesIO(selected)) as subset:
                self.assertEqual(set(subset.getnames()), {"LICENSE.txt", "amf/public/include/header.h"})
        self.assertEqual(digest(output), digest(self.stage_dir / "source.tar.xz"))

    def test_shipping_builds_need_no_zip_urls_and_reject_test_tools(self):
        self.pin["testTools"] = {"win-x64": {"url": "https://example.invalid/test.zip", "purpose": "TEST ONLY; never ship"}}
        self.save_pin()
        self.stage()
        self.assertEqual({p.name for p in self.stage_dir.glob("*.zip")},
                         {self.pin["builds"][rid]["name"] for rid in assets.RIDS})
        self.assertNotIn("test.zip", {p.name for p in self.stage_dir.iterdir()})
        self.pin["testTools"]["win-x64"]["sha256"] = self.pin["builds"]["win-x64"]["sha256"]
        self.save_pin()
        with self.assertRaisesRegex(ValueError, "Test-only"):
            assets.source_pin(self.pin_path)
        self.pin["testTools"]["win-x64"]["sha256"] = "0" * 64
        self.pin["builds"]["win-x64"]["url"] = "https://example.invalid/shipping.zip"
        self.save_pin()
        with self.assertRaisesRegex(ValueError, "Invalid local"):
            assets.source_pin(self.pin_path)

    def test_wrong_zip_hash_size_and_unexpected_dll_fail(self):
        rid = "win-x64"
        archive = self.cache / "reports" / (rid + "-1") / self.pin["builds"][rid]["name"]
        for mutation in (lambda: archive.write_bytes(archive.read_bytes() + b"x"),
                         lambda: archive.write_bytes(b"wrong")):
            with self.subTest(mutation=mutation):
                original = archive.read_bytes()
                mutation()
                with self.assertRaisesRegex(ValueError, "size/SHA-256"):
                    self.stage()
                archive.write_bytes(original)
        self.pin["builds"][rid]["size"] += 1
        self.save_pin()
        with self.assertRaisesRegex(ValueError, "evidence"):
            self.stage()
        self.pin["builds"][rid]["size"] -= 1
        self.save_pin()
        # Even when a fixture's pin and report are relabelled to fit, a seventh DLL is refused.
        with zipfile.ZipFile(archive, "a") as zipped:
            zipped.writestr("bin/ffmpeg.exe", b"test-only")
        new_hash = digest(archive)
        self.pin["builds"][rid].update(sha256=new_hash, size=archive.stat().st_size)
        self.pin["reproducibility"][rid].update(firstSha256=new_hash, secondSha256=new_hash)
        self.save_pin()
        for attempt in (1, 2):
            current = self.cache / "reports" / f"{rid}-{attempt}"
            if attempt == 2:
                shutil.copyfile(archive, current / archive.name)
            report = json.loads((current / "report.json").read_text())
            report.update(sha256=new_hash, size=archive.stat().st_size)
            (current / "report.json").write_text(json.dumps(report))
        with self.assertRaisesRegex(ValueError, "Unexpected DLL/test artifact"):
            self.stage()

    def test_wrong_build_inputs_and_missing_evidence_fail(self):
        self.pin["buildInputsSha256"] = "0" * 64
        self.save_pin()
        with self.assertRaisesRegex(ValueError, "buildInputsSha256"):
            self.stage()
        self.pin["buildInputsSha256"] = json.loads((self.cache / "reports/win-x64-1/report.json").read_text())["buildInputsSha256"]
        self.save_pin()
        (self.cache / "reports/win-arm64-2/report.json").unlink()
        with self.assertRaises(FileNotFoundError):
            self.stage()

    def test_wrong_report_configuration_and_notice_digest_fail(self):
        report_path = self.cache / "reports/win-x64-1/report.json"
        report = json.loads(report_path.read_text())
        report["configure"] += " --enable-gpl"
        report_path.write_text(json.dumps(report))
        with self.assertRaisesRegex(ValueError, "Wrong FFmpeg build evidence"):
            self.stage()
        report["configure"] = self.pin["configure"]["win-x64"]
        report["licenceAudit"]["noticeSha256"] = "0" * 64
        report_path.write_text(json.dumps(report))
        second_path = self.cache / "reports/win-x64-2/report.json"
        second_path.write_text(json.dumps(report))
        with self.assertRaisesRegex(ValueError, "Wrong FFmpeg notice evidence"):
            self.stage()

    def test_missing_source_license_and_wrong_source_hash_size_fail(self):
        original = self.cache / "downloads/ffmpeg.tar.gz"
        original_bytes = original.read_bytes()
        original.unlink()
        with self.assertRaisesRegex(ValueError, "size/SHA-256"):
            self.stage()
        original.write_bytes(original_bytes)
        notice = self.cache / "reports/win-x64-1/FFmpeg-NOTICES.txt"
        notice.unlink()
        with self.assertRaisesRegex(ValueError, "notice evidence"):
            self.stage()
        notice.write_text("Notices for win-x64\n")
        license_file = self.cache / "reports/win-x64-1/FFmpeg-LICENSE.txt"
        license_file.write_text("wrong licence evidence\n")
        with self.assertRaisesRegex(ValueError, "license/notice evidence"):
            self.stage()
        other_license = self.cache / "reports/win-arm64-1/FFmpeg-LICENSE.txt"
        other_license.write_text("wrong licence evidence\n")
        with self.assertRaisesRegex(ValueError, "differs from pinned source"):
            self.stage()
        license_file.write_text("LGPL 2.1 complete fixture text\n")
        other_license.write_text("LGPL 2.1 complete fixture text\n")
        original.write_bytes(original.read_bytes() + b"wrong")
        with self.assertRaisesRegex(ValueError, "size/SHA-256"):
            self.stage()

    def test_selected_archive_rejects_traversal_link_duplicate_and_missing(self):
        asset = self.source_assets[-1]
        for entries in ([ ("root/../secret", b"bad", "file") ],
                        [ ("root/LINK", b"../../secret", "link") ],
                        [ ("root/LICENSE.txt", b"a", "file"), ("root/LICENSE.txt", b"b", "file") ],
                        [ ("root/LICENSE.txt", b"only", "file") ]):
            with self.subTest(entries=entries):
                original = self.root / "bad.tar.gz"
                original.write_bytes(source_tar(entries))
                with self.assertRaisesRegex(ValueError, "Unsafe|duplicate|Missing"):
                    assets.selected_source(original, asset, self.root / "selected.tar.gz")

    def test_original_archives_reject_traversal_link_and_duplicate_entries(self):
        for entries in ([("root/../escape", b"bad", "file")],
                        [("root/link", b"../escape", "link")],
                        [("root/source.c", b"a", "file"), ("root/source.c", b"b", "file")]):
            with self.subTest(entries=entries):
                archive = self.root / "bad-original.tar.gz"
                archive.write_bytes(source_tar(entries))
                with self.assertRaisesRegex(ValueError, "Unsafe|duplicate"):
                    assets.validate_original_archive(archive)

    def test_schema2_requires_all_components_and_rejects_old_pin(self):
        self.pin["sourceAssets"] = [a for a in self.source_assets if a["component"] != "amf"]
        self.save_pin()
        with self.assertRaisesRegex(ValueError, "amf"):
            assets.source_pin(self.pin_path)
        self.pin["sourceAssets"] = self.source_assets
        self.pin["btbnCommit"] = "b" * 40
        self.save_pin()
        with self.assertRaisesRegex(ValueError, "voxclip-ffmpeg/2"):
            assets.source_pin(self.pin_path)

    def test_missing_source_and_build_tool_metadata_fail_closed(self):
        for field in ("sourceAssets", "buildTools", "buildInputsSha256", "recipeCommit"):
            with self.subTest(field=field):
                original = self.pin.pop(field)
                self.save_pin()
                with self.assertRaisesRegex(ValueError, field):
                    assets.source_pin(self.pin_path)
                self.pin[field] = original

    def test_source_copy_rechecks_stage_hash(self):
        self.stage()
        archive = self.stage_dir / "source.tar.xz"
        archive.write_bytes(archive.read_bytes() + b"wrong")
        with self.assertRaisesRegex(ValueError, "size/SHA-256"):
            assets.source_archive(self.stage_dir, self.root / "release.tar.xz")

    def make_manifest(self, test_build=False):
        evidence = self.root / "evidence"
        evidence.mkdir()
        (evidence / "verification.json").write_text(json.dumps({
            "verified": True, "version": "0.1.0", "commit": "abc", "testBuild": test_build,
        }))
        (self.root / "VoxClip-win-ffmpeg-source.tar.xz").write_bytes(b"source")
        for rid in ("win-x64", "win-arm64"):
            (self.root / f"VoxClip-{rid}-Setup.exe").write_bytes(b"installer")
            package = f"VoxClip-0.1.0-{rid}-full.nupkg"
            (self.root / package).write_bytes(b"package")
            (self.root / f"releases.{rid}.json").write_text(json.dumps({"Assets": [
                {"Version": "0.1.0", "FileName": package, "Type": "Full"},
            ]}))
        assets.manifest(self.root, evidence, "0.1.0", "abc")
        return evidence

    def test_manifest_contains_only_release_assets(self):
        evidence = self.make_manifest()
        manifest = json.loads((evidence / "upload-manifest.json").read_text())
        self.assertEqual(len(manifest["assets"]), 8)
        self.assertEqual(len((self.root / "SHA256SUMS-windows.txt").read_text().splitlines()), 7)

    def test_manifest_rejects_wrong_commit(self):
        evidence = self.make_manifest()
        with self.assertRaisesRegex(ValueError, "receipt"):
            assets.manifest(self.root, evidence, "0.1.0", "different")

    def test_upload_rejects_skeleton_test(self):
        evidence = self.make_manifest(test_build=True)
        with patch("sys.argv", ["release-assets.py", "upload-list", str(evidence), "0.1.0", "abc"]):
            with self.assertRaisesRegex(ValueError, "clean, tagged"):
                assets.main()

    def test_upload_rejects_unexpected_asset(self):
        evidence = self.make_manifest()
        path = evidence / "upload-manifest.json"
        record = json.loads(path.read_text())
        record["assets"] = ["signing.env"]
        path.write_text(json.dumps(record))
        with patch("sys.argv", ["release-assets.py", "upload-list", str(evidence), "0.1.0", "abc"]):
            with self.assertRaisesRegex(ValueError, "Unexpected upload asset"):
                assets.main()

    def test_version_comes_from_project(self):
        props = self.root / "apps/windows/Directory.Build.props"
        props.parent.mkdir(parents=True)
        props.write_text("<Project><PropertyGroup><Version>1.2.3-beta.1</Version></PropertyGroup></Project>")
        self.assertEqual(assets.version(self.root), "1.2.3-beta.1")


if __name__ == "__main__":
    unittest.main()
