#!/usr/bin/env python3
"""Offline, isolated, standard-library-only build-policy regression tests."""

import importlib.util
import hashlib
import json
from pathlib import Path
import shlex
import struct
import tempfile
import io
import os
import tarfile
import unittest
from unittest.mock import patch
import zipfile


DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("ffmpeg_build", DIRECTORY / "build.py")
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
LOCK = json.loads((DIRECTORY / "sources.json").read_text())


def fixture_dll(machine, text):
    data = bytearray(2048)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, machine, 1)
    struct.pack_into("<H", data, 0x94, 0xF0)
    struct.pack_into("<H", data, 0x98, 0x20B)
    struct.pack_into("<I", data, 0x108, 0x1000)
    struct.pack_into("<IIII", data, 0x190, 0x600, 0x1000, 0x600, 0x200)
    struct.pack_into("<IIIII", data, 0x214, 1, 1, 0x1040, 0x1044, 0x1048)
    struct.pack_into("<IIH", data, 0x240, 0x1100, 0x1060, 0)
    name = b"avcodec_configuration\0"
    data[0x260:0x260 + len(name)] = name
    if machine == 0x8664:
        code = b"\x48\x8d\x05" + struct.pack("<i", 0x1200 - 0x1107) + b"\xc3"
    else:
        code = struct.pack("<III", 0x90000000, 0x91000000 | (0x200 << 10), 0xD65F03C0)
    data[0x300:0x300 + len(code)] = code
    encoded = text.encode() + b"\0"
    data[0x400:0x400 + len(encoded)] = encoded
    return bytes(data)


class ComponentTests(unittest.TestCase):
    def test_component_arguments_match_audited_set(self):
        for rid in build.TARGETS:
            flags = build.configure_arguments(rid, LOCK)
            for kind, names in build.components(rid).items():
                if names:
                    self.assertIn("--enable-" + kind + "=" + ",".join(names), flags)
            self.assertIn("--disable-network", flags)
            self.assertIn("--disable-autodetect", flags)
            self.assertIn("--disable-everything", flags)
            build.validate_source_mapping(shlex.join(flags), LOCK)

    def test_assembly_and_arm_crc_policy(self):
        x64 = build.configure_arguments("win-x64", LOCK)
        arm64 = build.configure_arguments("win-arm64", LOCK)
        self.assertNotIn("--disable-x86asm", x64)
        for flag in ("--disable-arm-crc", "--disable-pmull", "--disable-eor3"):
            self.assertIn(flag, arm64)

    def test_caller_environment_never_enters_build(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(
                os.environ, {"VOXCLIP_FAKE_SECRET": "sentinel-never-copy",
                             "CPPFLAGS": "-I/nonexistent", "CFLAGS": "-unsafe",
                             "PKG_CONFIG_PATH": "/untrusted", "HOME": "/caller-home"}):
            root = Path(temporary)
            first = build.build_environment(root / "first", root / "toolchain", [], LOCK,
                                            "win-x64")
            second = build.build_environment(root / "second", root / "toolchain", [], LOCK,
                                             "win-x64")
            for result in (first, second):
                self.assertFalse(set(result).intersection(
                    {"VOXCLIP_FAKE_SECRET", "CPPFLAGS", "CFLAGS", "PKG_CONFIG_PATH",
                     "HOME"}))
                self.assertNotIn("sentinel-never-copy", repr(result))
                self.assertNotIn("/nonexistent", repr(result))
            self.assertEqual(first["PATH"], second["PATH"])
            fetched = build.fetch_environment(root)
            self.assertNotIn("HOME", fetched)
            self.assertNotIn("sentinel-never-copy", repr(fetched))
            self.assertEqual(os.environ["HOME"], "/caller-home")
            with patch.dict(os.environ, {}, clear=True):
                self.assertNotIn("HOME", os.environ)
                self.assertNotIn("HOME", build.fetch_environment(root))
                self.assertNotIn("HOME", build.build_environment(
                    root / "unset", root / "toolchain", [], LOCK, "win-x64"))
                self.assertNotIn("HOME", os.environ)

    def test_fetch_ignores_caller_curl_config(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(
                os.environ, {"HOME": "/caller-home", "VOXCLIP_FAKE_SECRET": "sentinel-fetch"}):
            root = Path(temporary)
            seen = []
            def fake_run(arguments, directory, environment, **kwargs):
                seen.append((arguments, environment))
                Path(arguments[-1]).write_bytes(b"pin")
            asset = {"url": "https://ffmpeg.org/fixture", "name": "fixture.tar.gz",
                     "size": 3, "sha256": hashlib.sha256(b"pin").hexdigest()}
            with patch.object(build, "run", side_effect=fake_run):
                self.assertTrue(build.download(asset, root).exists())
            self.assertEqual(seen[0][0][:2], ["curl", "-q"])
            self.assertNotIn("HOME", seen[0][1])
            self.assertNotIn("sentinel-fetch", repr(seen[0]))
            self.assertEqual(os.environ["HOME"], "/caller-home")

    def test_unknown_archive_and_gpl_runtime_source_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            downloads = root / "downloads"
            downloads.mkdir()
            assets = []
            for component in ("mingw-w64", "llvm-project"):
                name = component + ".tar.gz"
                assets.append({"component": component, "name": name})
                with tarfile.open(downloads / name, "w:gz") as archive:
                    if component == "mingw-w64":
                        files = {"mingw-w64-crt/crt/crtdll.c": "/* MIT License */\n",
                                 "mingw-w64-crt/crt/crtbegin.c": "/* MIT License */\n",
                                 "mingw-w64-crt/crt/crtend.c": "/* MIT License */\n",
                                 "mingw-w64-libraries/winpthreads/src/misc.c":
                                 "/* GNU General Public License version 2 */\n"}
                        for path, content in files.items():
                            data = content.encode()
                            entry = tarfile.TarInfo("pin/" + path)
                            entry.size = len(data)
                            archive.addfile(entry, io.BytesIO(data))
            startup = "\n".join("ld.lld: Reading /crt/" + name + ".o"
                                for name in ("dllcrt2", "crtbegin", "crtend")) + "\n"
            lock = {"sourceAssets": assets}
            with self.assertRaisesRegex(build.licences.LicenceError, "Unknown loaded static archive"):
                build.licences.audit_dependency_objects(
                    {}, downloads, lock,
                    {"avcodec": startup +
                     "ld.lld: Loaded libunexpected.a(forbidden.c.o) for symbol\n"})
            with self.assertRaisesRegex(build.licences.LicenceError, "Unknown loaded static archive"):
                build.licences.audit_dependency_objects(
                    {}, downloads, lock,
                    {"avcodec": startup +
                     "ld.lld: Loaded libunexpected.lib(forbidden.c.obj) for symbol\n"})
            with self.assertRaisesRegex(build.licences.LicenceError, "Unknown loaded linker member"):
                build.licences.audit_dependency_objects(
                    {}, downloads, lock,
                    {"avcodec": startup + "ld.lld: Loaded forbidden.obj for symbol\n"})
            with self.assertRaisesRegex(build.licences.LicenceError, "GPL-only dependency object"):
                build.licences.audit_dependency_objects(
                    {}, downloads, lock,
                    {"avcodec": startup +
                     "ld.lld: Loaded libwinpthread.a(libwinpthread_la-misc.o) for symbol\n"})
            imported = "ld.lld: Loaded libmsvcrt.a(api-ms-win-crt-stdio-l1-1-0.dll) for symbol\n"
            with self.assertRaisesRegex(build.licences.LicenceError, "Unknown direct linked object"):
                build.licences.audit_dependency_objects(
                    {}, downloads, lock,
                    {"avcodec": startup + "ld.lld: Reading /crt/unexpected.o\n" + imported})
            result = build.licences.audit_dependency_objects(
                {}, downloads, lock, {"avcodec": startup + imported})
            self.assertEqual(result["loadedMembers"], 1)
            self.assertEqual(len(result["systemImports"]), 1)
            dav1d = root / "src/libdav1d"
            for relative in ("src/msac.c", "tests/checkasm/msac.c"):
                source = dav1d / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("/* MIT License */\n")
            mapped = build.licences.audit_dependency_objects(
                {"libdav1d": dav1d}, downloads, lock,
                {"avcodec": startup + "ld.lld: Loaded libdav1d.a(msac.c.obj) for symbol\n"})
            self.assertIn("libdav1d:src/msac.c", mapped["checkedSources"])
            self.assertNotIn("libdav1d:tests/checkasm/msac.c", mapped["checkedSources"])

    def test_linked_gpl_source_fails_and_notice_is_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "libavutil/aarch64/crc.S"
            source.parent.mkdir(parents=True)
            source.write_text("/* GNU General Public License version 2 */\n")
            map_text = "00001000 00000010 4 libavutil/aarch64/crc.o:(.text)\n"
            with self.assertRaisesRegex(build.licences.LicenceError, "GPL-only"):
                build.licences.audit_maps({"avutil": map_text}, root, "win-arm64")
            source.write_text("/* Permission is hereby granted to use this code. */\n")
            with self.assertRaisesRegex(build.licences.LicenceError, "crc.o contributes"):
                build.licences.audit_maps({"avutil": map_text}, root, "win-arm64")
            audit = build.licences.audit_maps(
                {"avutil": map_text.replace(".text", ".rdata")}, root, "win-arm64")
            self.assertIn("libavutil/aarch64/crc.S", audit["notices"])
            with self.assertRaisesRegex(build.licences.LicenceError, "Missing linked-file notice"):
                build.licences.validate_notice_coverage(audit, {}, "")
            other = root / "libavutil/base.c"
            other.write_text("/* GNU Lesser General Public License */\n")
            zero_crc = ("00001000 00000000 4 libavutil/aarch64/crc.o:(.text)\n"
                        "00001000 00000010 4 libavutil/base.o:(.text)\n")
            self.assertEqual(build.licences.audit_maps({"avutil": zero_crc}, root,
                                                       "win-arm64")["objects"], 1)

    def test_arm64_only_omits_intel_encoder(self):
        first, second = build.components("win-x64"), build.components("win-arm64")
        self.assertEqual(set(first["encoder"]) - set(second["encoder"]), {"h264_qsv"})
        for kind in first.keys() - {"encoder"}:
            self.assertEqual(first[kind], second[kind])

    def test_native_d3d11_pixel_format_uses_v2_hwaccels(self):
        for codec in ("h264", "hevc", "vp9"):
            self.assertIn(codec + "_d3d11va2", build.COMPONENTS["hwaccel"])
            self.assertIn(codec + "_d3d11va", build.COMPONENTS["hwaccel"])

    def test_atempo_and_unconditional_filters_are_exactly_registered(self):
        self.assertEqual(build.components("win-x64")["filter"], ["atempo"])
        self.assertEqual(build.components("win-arm64")["filter"], ["atempo"])
        self.assertEqual(set(build.FILTER_SYMBOLS),
                         {"af_atempo", "asrc_abuffer", "asink_abuffer",
                          "vsrc_buffer", "vsink_buffer"})
        header = "\n".join("#define CONFIG_" + name.upper() + "_" + kind.upper() + " 1"
                           for kind, names in build.components("win-x64").items() for name in names)
        registration = "\n".join("&ff_" + name + "," for name in build.FILTER_SYMBOLS)
        actual = build.validate_components(header, "win-x64", registration)
        self.assertEqual(set(actual["filter"]),
                         {"atempo", "abuffer", "abuffersink", "buffer", "buffersink"})
        with self.assertRaisesRegex(build.PinError, "component mismatch"):
            build.validate_components(header.replace("#define CONFIG_ATEMPO_FILTER 1", ""),
                                      "win-x64", registration)
        with self.assertRaisesRegex(build.PinError, "registered filters"):
            build.validate_components(header, "win-x64",
                                      registration.replace("&ff_af_atempo,", ""))
        with self.assertRaisesRegex(build.PinError, "registered filters"):
            build.validate_components(header, "win-x64", registration + "\n&ff_vf_drawtext,")

    def test_unapproved_optional_hdr_and_unused_av1_wrapper_are_absent(self):
        self.assertNotIn("libzimg", {asset["component"] for asset in LOCK["sourceAssets"]})
        self.assertNotIn("automake", {asset["component"] for asset in LOCK["sourceAssets"]})
        for rid in build.TARGETS:
            self.assertIn("--disable-libzimg", build.configure_arguments(rid, LOCK))
            self.assertEqual(build.components(rid)["filter"], ["atempo"])
            self.assertIn("libdav1d", build.components(rid)["decoder"])
            self.assertNotIn("av1", build.components(rid)["decoder"])
            self.assertNotIn("av1_d3d11va2", build.components(rid)["hwaccel"])
        with self.assertRaisesRegex(build.PinError, "source"):
            build.validate_source_mapping("--enable-libzimg", LOCK)

    def test_unknown_or_missing_external_sources_fail(self):
        with self.assertRaisesRegex(build.PinError, "source"):
            build.validate_source_mapping("--enable-libunknown", LOCK)
        empty = {"sourceAssets": []}
        for flag in build.EXTERNAL_SOURCES:
            with self.subTest(flag=flag), self.assertRaisesRegex(build.PinError, "source"):
                build.validate_source_mapping("--enable-" + flag, empty)

    def test_resolved_components_fail_on_missing_or_extra(self):
        header = "\n".join("#define CONFIG_" + name.upper() + "_" + kind.upper() + " 1"
                           for kind, names in build.components("win-x64").items() for name in names)
        self.assertEqual(set(build.validate_components(header, "win-x64")), set(build.COMPONENTS))
        for changed in (header + "\n#define CONFIG_HTTP_PROTOCOL 1", header.replace("CONFIG_HEVC_DECODER 1", "CONFIG_HEVC_DECODER 0")):
            with self.assertRaisesRegex(build.PinError, "component mismatch"):
                build.validate_components(changed, "win-x64")


class StringTests(unittest.TestCase):
    def test_export_return_is_decoded_on_both_machines(self):
        for machine in build.MACHINES.values():
            image = build.PE(fixture_dll(machine, "--enable-shared"))
            self.assertEqual(image.returned_string("avcodec_configuration"), "--enable-shared")

    def test_unsupported_function_fails_closed(self):
        data = bytearray(fixture_dll(0x8664, "wrong"))
        data[0x300] = 0xCC
        with self.assertRaisesRegex(build.PinError, "Unsupported"):
            build.PE(data).returned_string("avcodec_configuration")

    def test_missing_export_fails(self):
        with self.assertRaisesRegex(build.PinError, "Missing DLL export"):
            build.PE(fixture_dll(0x8664, "text")).returned_string("avcodec_license")

    def test_license_and_configure_gates(self):
        build.validate_configuration("--enable-shared --disable-gpl", "LGPL version 2.1 or later")
        for configuration, license_text in (
                ("--enable-shared --enable-gpl", "LGPL version 2.1 or later"),
                ("--enable-shared --enable-nonfree", "LGPL version 2.1 or later"),
                ("--enable-shared", "GPL version 3 or later"),
                ("--disable-shared", "LGPL version 2.1 or later")):
            with self.assertRaises(build.PinError):
                build.validate_configuration(configuration, license_text)


class BinaryTests(unittest.TestCase):
    def test_runtime_inventory_uses_extracted_not_merely_opened_members(self):
        text = "\n".join([
            "ld.lld: Reading /compiler/lib/dllcrt2.o",
            "ld.lld: Reading /compiler/lib/crtbegin.o",
            "ld.lld: Reading /compiler/lib/crtend.o",
            "ld.lld: Reading libunwind.a(unused.obj)",
            "ld.lld: Loaded libmingw32.a(startup.o) for _CRT_INIT",
            "ld.lld: Loaded libclang_rt.builtins.a(chkstk.obj) for __chkstk"])
        result = build.runtime_inventory(text)
        self.assertEqual(result["archiveMembers"], ["libclang_rt.builtins.a(chkstk.obj)", "libmingw32.a(startup.o)"])
        self.assertEqual(result["startupObjects"], ["crtbegin.o", "crtend.o", "dllcrt2.o"])
        with self.assertRaisesRegex(build.PinError, "No static runtime"):
            build.runtime_inventory("ld.lld: Reading libunwind.a(unused.obj)")

    def test_every_forbidden_marker_and_its_offset(self):
        for marker in build.GPL_MARKERS:
            with self.subTest(marker=marker):
                self.assertIn({"offset": 7, "marker": marker.decode()}, build.binary_evidence(b"padding" + marker + b"\0"))

    def test_h264_encoder_identification_text_is_not_linked_x264(self):
        self.assertEqual(build.binary_evidence(b"x264 - core %d\0h264\0"), [])

    def test_inspector_rejects_wrong_dll_set(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(build.PinError, "DLL set/ABI mismatch"):
                build.inspect_dlls(Path(temporary), "win-x64")

    def test_archive_inspector_rejects_unexpected_payloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("bin/unexpected.dll", b"not a DLL")
            with self.assertRaisesRegex(build.PinError, "ZIP entries"):
                build.inspect_archive(path, "win-x64")

    def test_inspector_checks_every_dll_not_just_avcodec(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for library, major in build.MAJORS.items():
                (directory / f"{library}-{major}.dll").write_bytes(fixture_dll(0x8664, "text"))
            with (directory / "swscale-10.dll").open("ab") as output:
                output.write(b"fftw-3.3.11 fftw_wisdom")
            with self.assertRaisesRegex(build.PinError, "swscale-10.dll"):
                build.inspect_dlls(directory, "win-x64")


class ReproducibilityTests(unittest.TestCase):
    def test_zip_metadata_and_hash_are_stable(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "avcodec-63.dll").write_bytes(b"identical DLL")
            first, second = directory / "first.zip", directory / "second.zip"
            build.deterministic_zip(directory, first)
            build.deterministic_zip(directory, second)
            self.assertTrue(build.compare_builds(first, second)["identical"])
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(archive.infolist()[0].date_time, (1980, 1, 1, 0, 0, 0))

    def test_exact_changed_bytes_and_length_are_reported(self):
        self.assertEqual(build.byte_differences(b"abcde", b"aXXdeZ"), [
            {"start": 1, "end": 3, "first": "6263", "second": "5858"},
            {"start": 5, "end": 6, "first": "", "second": "5a"}])

    def test_different_dlls_fail_reproducibility(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "sample.dll").write_bytes(b"first")
            build.deterministic_zip(directory, directory / "first.zip")
            (directory / "sample.dll").write_bytes(b"second")
            build.deterministic_zip(directory, directory / "second.zip")
            result = build.compare_builds(directory / "first.zip", directory / "second.zip")
            self.assertFalse(result["identical"])
            self.assertIn("bin/sample.dll", result["differences"])


class WriterTests(unittest.TestCase):
    def evidence(self):
        reports = {rid: {"configure": shlex.join(build.configure_arguments(rid, LOCK)),
                         "sourceCommit": LOCK["sourceCommit"],
                         "buildInputsSha256": build.build_inputs_digest(LOCK),
                         "license": "LGPL version 2.1 or later", "sha256": "a" * 64,
                         "archive": rid + ".zip", "size": 1024} for rid in build.TARGETS}
        reproducibility = {rid: {"identical": True, "firstSha256": "a" * 64,
                                 "secondSha256": "a" * 64, "differences": {}}
                           for rid in build.TARGETS}
        return reports, reproducibility

    def test_writer_is_atomic_deterministic_and_retains_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "ffmpeg.json"
            reports, reproducibility = self.evidence()
            build.write_pin(path, LOCK, reports, reproducibility)
            original = path.read_bytes()
            build.write_pin(path, LOCK, reports, reproducibility)
            self.assertEqual(path.read_bytes(), original)
            self.assertTrue(original.endswith(b"\n"))
            manifest = json.loads(original)
            self.assertEqual(manifest["recipeCommit"], "BUILD_COMMIT")
            self.assertNotIn("btbnCommit", manifest)
            self.assertNotIn("url", manifest["builds"]["win-x64"])
            self.assertIn("llvm-project", {item["component"] for item in manifest["sourceAssets"]})
            self.assertEqual(manifest["buildInputsSha256"], build.build_inputs_digest(LOCK))

    def test_writer_rejects_stale_recipe_or_source_inputs(self):
        reports, reproducibility = self.evidence()
        for field in ("sourceCommit", "buildInputsSha256"):
            invalid = {rid: {**report, field: "stale"} for rid, report in reports.items()}
            with self.subTest(field=field), self.assertRaisesRegex(build.PinError, "build inputs"):
                build.write_pin(Path("unused.json"), LOCK, invalid, reproducibility)

    def test_build_input_digest_covers_pinned_dependency_sources(self):
        changed = json.loads(json.dumps(LOCK))
        changed["sourceAssets"][0]["sha256"] = "0" * 64
        self.assertNotEqual(build.build_inputs_digest(changed), build.build_inputs_digest(LOCK))

    def test_writer_requires_both_reproducible_rids(self):
        reports, reproducibility = self.evidence()
        for invalid in ({}, {**reproducibility, "win-x64": {"identical": False}}):
            with self.assertRaises(build.PinError):
                build.write_pin(Path("unused.json"), LOCK, reports, invalid)

    def test_writer_rejects_unrelated_archive_evidence(self):
        reports, reproducibility = self.evidence()
        reports["win-x64"]["sha256"] = "b" * 64
        with self.assertRaisesRegex(build.PinError, "does not match"):
            build.write_pin(Path("unused.json"), LOCK, reports, reproducibility)


class DiskAndDownloadTests(unittest.TestCase):
    def test_digest_keyed_extraction_replaces_partial_or_stale_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                payload = b"pinned"
                member = tarfile.TarInfo("root/bin/compiler")
                member.size = len(payload)
                output.addfile(member, io.BytesIO(payload))
            destination = base / "toolchains" / "pin-sha"
            destination.mkdir(parents=True)
            (destination / "incomplete").write_text("stale")
            with patch.object(build, "disk_guard"):
                root = build.pinned_tree(archive, destination, "pin-sha", base)
                self.assertEqual((root / "bin/compiler").read_bytes(), b"pinned")
                (destination / ".complete").write_text("wrong")
                (root / "bin/compiler").write_bytes(b"tampered")
                root = build.pinned_tree(archive, destination, "pin-sha", base)
                self.assertEqual((root / "bin/compiler").read_bytes(), b"pinned")

    def test_amf_extraction_excludes_unrelated_prebuilt_binaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / "amf.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                for name in ("root/amf/public/include/test.h", "root/LICENSE.txt", "root/Thirdparty/gpl.dll"):
                    member = tarfile.TarInfo(name)
                    member.size = 4
                    output.addfile(member, io.BytesIO(b"test"))
            extracted = build.unpack(archive, directory / "extracted", headers_only=True)
            self.assertTrue((extracted / "amf/public/include/test.h").exists())
            self.assertTrue((extracted / "LICENSE.txt").exists())
            self.assertFalse((extracted / "Thirdparty").exists())

    def test_low_disk_stops_before_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(build.subprocess, "run"), patch.object(build.shutil, "disk_usage") as usage:
                usage.return_value.free = build.MINIMUM_FREE - 1
                with self.assertRaisesRegex(build.PinError, "below 15"):
                    build.disk_guard(Path(temporary))

    def test_cached_download_is_always_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            (cache / "downloads").mkdir()
            (cache / "downloads/source.tar.gz").write_bytes(b"wrong")
            asset = {"name": "source.tar.gz", "url": "https://ffmpeg.org/source.tar.gz",
                     "sha256": "0" * 64, "size": 5}
            with self.assertRaisesRegex(build.PinError, "mismatch"):
                build.download(asset, cache)

    def test_unpinned_host_and_plaintext_fail_offline(self):
        for url in ("http://ffmpeg.org/archive", "https://unknown.invalid/archive"):
            with self.assertRaisesRegex(build.PinError, "pinned HTTPS host"):
                build.download({"url": url}, Path("unused"))


if __name__ == "__main__":
    unittest.main()
