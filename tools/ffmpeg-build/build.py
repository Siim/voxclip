#!/usr/bin/env python3
"""Pinned, disk-bounded Windows FFmpeg cross-build and offline PE inspection."""

import argparse
import contextlib
import fcntl
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tarfile
import time
import zipfile
import tempfile


DIRECTORY = Path(__file__).resolve().parent
LICENCE_SPEC = importlib.util.spec_from_file_location("ffmpeg_licences", DIRECTORY / "licences.py")
licences = importlib.util.module_from_spec(LICENCE_SPEC)
LICENCE_SPEC.loader.exec_module(licences)
ROOT = DIRECTORY.parents[1]
LOCK = DIRECTORY / "sources.json"
MANIFEST = ROOT / "apps/windows/build/ffmpeg.json"
CACHE = Path.home() / "Library/Caches/voxclip-ffmpeg-build"
MINIMUM_FREE = 15 * 1024 ** 3
MAXIMUM_CACHE = 6 * 1024 ** 3
MAJORS = {"avcodec": 63, "avformat": 63, "avutil": 61, "avfilter": 12,
          "swresample": 7, "swscale": 10}
TARGETS = {"win-x64": "x86_64-w64-mingw32", "win-arm64": "aarch64-w64-mingw32"}
MACHINES = {"win-x64": 0x8664, "win-arm64": 0xAA64}
TEST_TOOLS = {
    "win-x64": {"url": "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-24-13-02/ffmpeg-n9.0.2-35-g9a9b70bb8c-win64-lgpl-shared-9.0.zip",
                "sha256": "fb771d872989dba5d96621a840194362202426e882814a0d5e7eddd8387908d3"},
    "win-arm64": {"url": "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-24-13-02/ffmpeg-n9.0.2-35-g9a9b70bb8c-winarm64-lgpl-shared-9.0.zip",
                  "sha256": "4bf8f5ff4ec2ec462c50d0c65f77793c2e18303cb343ef376c8c020c7028d248"},
}
COMPONENTS = {
    "decoder": "h264 hevc vp8 vp9 libdav1d aac opus vorbis mpeg4 h263 ffv1 "
               "pcm_u8 pcm_s8 pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le "
               "pcm_s32be pcm_f32le pcm_f32be pcm_f64le pcm_f64be".split(),
    "encoder": "h264_nvenc h264_qsv h264_amf h264_mf aac pcm_s16le".split(),
    "parser": "h264 hevc vp8 vp9 av1 aac opus vorbis mpeg4video ac3".split(),
    "bsf": "aac_adtstoasc h264_mp4toannexb hevc_mp4toannexb extract_extradata "
           "av1_frame_split vp9_superframe_split vp9_superframe".split(),
    "demuxer": "mov matroska wav".split(),
    "muxer": "mp4 mov".split(),
    "filter": [],
    "hwaccel": "h264_d3d11va h264_d3d11va2 hevc_d3d11va hevc_d3d11va2 "
               "vp9_d3d11va vp9_d3d11va2".split(),
    "protocol": ["file"],
}
EXTERNAL_SOURCES = {"ffnvcodec": "ffnvcodec", "amf": "amf", "libvpl": "libvpl",
                    "libdav1d": "libdav1d"}
GPL_MARKERS = (b"fftw-", b"fftw_wisdom", b"fftw_plan_", b"fftwf_plan_",
               b"x264_encoder_", b"x265_encoder_", b"x265_api_get", b"libpostproc",
               b"postproc_license", b"chromaprint_", b"rsvg_handle_", b"rav1e_context_")
FILTER_SYMBOLS = {"asrc_abuffer": "abuffer", "vsrc_buffer": "buffer",
                  "asink_abuffer": "abuffersink", "vsink_buffer": "buffersink"}


class PinError(Exception):
    pass


def digest_file(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def build_inputs_digest(lock):
    paths = [DIRECTORY / name for name in ("build.py", "dependencies.sh", "linker.py", "licences.py")]
    paths.extend(sorted((DIRECTORY / "patches").glob("*")))
    inputs = {"sources": lock, "recipe": {str(path.relative_to(DIRECTORY)): digest_file(path)
                                         for path in paths if path.is_file()}}
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def validate_report_inputs(report, rid, lock):
    if (report.get("sourceCommit") != lock["sourceCommit"] or
            report.get("buildInputsSha256") != build_inputs_digest(lock) or
            shlex.split(report["configure"]) != configure_arguments(rid, lock)):
        raise PinError("Cached build inputs differ from the current recipe: " + rid)


def disk_guard(cache):
    volume = "/System/Volumes/Data" if sys.platform == "darwin" else str(cache)
    subprocess.run(["/bin/df", "-h", volume], check=True,
                   env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"})
    if shutil.disk_usage(volume).free < MINIMUM_FREE:
        raise PinError("STOP: free space is below 15 GiB")
    size = sum(path.stat().st_size for path in cache.rglob("*")
               if path.is_file() and not path.is_symlink())
    if size >= MAXIMUM_CACHE:
        raise PinError("STOP: FFmpeg build cache is at or above 6 GiB")


def run(arguments, directory, environment, log=None, seconds=900):
    timeout = next((path for path in ("/opt/homebrew/bin/gtimeout",
                                    "/opt/homebrew/bin/timeout", "/usr/bin/timeout")
                    if Path(path).is_file()), None)
    if not timeout:
        raise PinError("GNU timeout (or gtimeout) is required")
    if environment is None or not {"PATH", "LC_ALL", "TZ"} <= set(environment):
        raise PinError("Subprocess requires an explicit sanitized environment")
    command = [timeout, "--kill-after=10", str(seconds), *map(str, arguments)]
    if log:
        log.write(("$ " + shlex.join(map(str, arguments)) + "\n").encode())
        log.flush()
    subprocess.run(command, cwd=directory, env=environment, check=True,
                   stdout=log, stderr=subprocess.STDOUT if log else None)


def download(asset, cache):
    from urllib.parse import urlsplit
    parsed = urlsplit(asset["url"])
    if parsed.scheme != "https" or parsed.hostname not in {
            "github.com", "codeload.github.com", "ffmpeg.org", "ftp.gnu.org",
            "www.nasm.us", "downloads.videolan.org"}:
        raise PinError("Source is not an allowed pinned HTTPS host")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise PinError("Credentials, queries and fragments are not source pins")
    if not re.fullmatch(r"[a-zA-Z0-9_.-]+", asset["name"]):
        raise PinError("Unsafe source filename")
    if not re.fullmatch(r"[0-9a-f]{64}", asset["sha256"]):
        raise PinError("Missing SHA-256 pin")
    path = cache / "downloads" / asset["name"]
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        disk_guard(cache)
        temporary = path.with_suffix(path.suffix + ".part")
        try:
            run(["curl", "-q", "--fail", "--location", "--silent", "--show-error",
                 "--proto", "=https", "--proto-redir", "=https", "--max-time", "580",
                 asset["url"], "-o", temporary], cache, fetch_environment(cache), seconds=600)
            if digest_file(temporary) != asset["sha256"]:
                raise PinError("Downloaded source SHA-256 mismatch: " + asset["name"])
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    if path.stat().st_size != asset["size"] or digest_file(path) != asset["sha256"]:
        raise PinError("Cached source size/SHA-256 mismatch: " + asset["name"])
    return path


def fetch_environment(cache):
    scratch = cache / "fetch-config"
    scratch.mkdir(parents=True, exist_ok=True)
    return {"PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
            "XDG_CONFIG_HOME": str(scratch), "XDG_CACHE_HOME": str(scratch),
            "TMPDIR": str(scratch), "LANG": "C", "LC_ALL": "C", "TZ": "UTC"}


def unpack(archive, destination, headers_only=False):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        members = source.getmembers()
        if headers_only:
            members = [member for member in members if "/amf/public/include/" in member.name
                       or member.name.endswith(("/LICENSE.txt", "/LICENSE"))]
        source.extractall(destination, members=members, filter="data")
    roots = list(destination.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise PinError("Source archive must contain one root directory")
    return roots[0]


def pinned_tree(archive, destination, sha256, cache):
    """Reuse only a complete extraction of the exact verified archive."""
    marker = destination / ".complete"
    if destination.exists() and (not marker.is_file() or
                                 marker.read_text().strip() != sha256 or
                                 len([p for p in destination.iterdir() if p.name != ".complete"]) != 1):
        shutil.rmtree(destination)
    if not destination.exists():
        disk_guard(cache)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = Path(tempfile.mkdtemp(prefix=destination.name + ".", dir=destination.parent))
        try:
            unpack(archive, temporary)
            (temporary / ".complete").write_text(sha256 + "\n")
            temporary.replace(destination)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    return next(p for p in destination.iterdir() if p.is_dir())


@contextlib.contextmanager
def cache_lock(cache):
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".lock").open("w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def components(rid):
    if rid not in TARGETS:
        raise PinError("Unsupported RID: " + rid)
    result = {kind: list(names) for kind, names in COMPONENTS.items()}
    if rid == "win-arm64":
        result["encoder"].remove("h264_qsv")
    return result


def configure_arguments(rid, lock):
    architecture = "x86_64" if rid == "win-x64" else "aarch64"
    target = TARGETS[rid]
    flags = ["--disable-everything", "--disable-autodetect", "--disable-programs",
             "--disable-doc", "--disable-avdevice", "--enable-shared", "--disable-static", "--disable-gpl",
             "--disable-nonfree", "--disable-version3", "--disable-network",
             "--disable-debug", "--disable-pthreads",
             "--enable-w32threads", "--disable-dxva2", "--enable-cross-compile",
             "--target-os=mingw32", "--arch=" + architecture, "--prefix=/voxclip",
             "--cross-prefix=" + target + "-", "--cc=" + target + "-clang",
             "--cxx=" + target + "-clang++", "--ld=voxclip-link",
             "--pkg-config=pkg-config", "--pkg-config-flags=--static",
             "--extra-version=" + lock["extraVersion"],
             "--extra-cflags=-I../prefix/include -O2 -g0 -fno-ident "
             "-ffile-prefix-map=../../=/build/",
             "--extra-ldflags=-L../prefix/lib -static -Wl,--no-insert-timestamp",
             "--extra-libs=-lc++ -lc++abi -lunwind -lwinpthread",
             "--enable-avcodec", "--enable-avformat", "--enable-avutil",
             "--enable-avfilter", "--enable-swscale", "--enable-swresample",
             "--enable-mediafoundation", "--enable-d3d11va", "--enable-ffnvcodec",
             "--enable-nvenc", "--enable-amf", "--enable-libdav1d", "--disable-libzimg"]
    flags.append("--enable-libvpl" if rid == "win-x64" else "--disable-libvpl")
    if rid == "win-arm64":
        flags.extend(("--disable-arm-crc", "--disable-pmull", "--disable-eor3"))
    for kind, names in components(rid).items():
        if names:
            flags.append("--enable-" + kind + "=" + ",".join(names))
    return flags


def validate_source_mapping(configuration, lock):
    source_components = {asset["component"] for asset in lock["sourceAssets"]}
    internal = {"shared", "cross-compile", "w32threads", "avcodec", "avformat", "avutil",
                "avfilter", "swscale", "swresample", "mediafoundation", "d3d11va", "nvenc"}
    for argument in shlex.split(configuration):
        if not argument.startswith("--enable-"):
            continue
        name = argument.removeprefix("--enable-").split("=", 1)[0]
        if name in internal or name in COMPONENTS:
            continue
        if name not in EXTERNAL_SOURCES or EXTERNAL_SOURCES[name] not in source_components:
            raise PinError("Missing or unaudited external source: " + name)


def validate_configuration(configuration, license_text):
    if any(flag in configuration.lower() for flag in ("--enable-gpl", "--enable-nonfree")):
        raise PinError("Forbidden GPL/nonfree configuration")
    if "--enable-shared" not in configuration or license_text != "LGPL version 2.1 or later":
        raise PinError("Expected LGPL-2.1-or-later shared libraries")


class PE:
    def __init__(self, data):
        self.data = data
        if data[:2] != b"MZ":
            raise PinError("Not a PE DLL")
        header = self.integer(0x3C)
        if data[header:header + 4] != b"PE\0\0":
            raise PinError("Invalid PE header")
        self.machine = self.integer(header + 4, "H")
        optional = header + 24
        if self.integer(optional, "H") != 0x20B:
            raise PinError("Expected PE32+ DLL")
        self.exports = self.integer(optional + 112)
        self.imports = self.integer(optional + 120)
        self.sections = []
        section_start = optional + self.integer(header + 20, "H")
        for index in range(self.integer(header + 6, "H")):
            section = section_start + index * 40
            virtual_size, address, size, offset = struct.unpack_from("<IIII", data, section + 8)
            self.sections.append((address, max(size, virtual_size), offset, size))

    def integer(self, offset, kind="I"):
        try:
            return struct.unpack_from("<" + kind, self.data, offset)[0]
        except struct.error as error:
            raise PinError("Truncated PE header") from error

    def offset(self, address):
        for virtual, length, offset, size in self.sections:
            if virtual <= address < virtual + length and address - virtual < size:
                return offset + address - virtual
        raise PinError(f"Unmapped PE RVA: {address:#x}")

    def string(self, address):
        offset = self.offset(address)
        end = self.data.find(b"\0", offset, offset + 32768)
        if end < 0:
            raise PinError("Unterminated compiled-in string")
        return self.data[offset:end].decode("ascii")

    def export_rva(self, name):
        export = self.offset(self.exports)
        functions = self.offset(self.integer(export + 28))
        names = self.offset(self.integer(export + 32))
        ordinals = self.offset(self.integer(export + 36))
        for index in range(self.integer(export + 24)):
            if self.string(self.integer(names + index * 4)) == name:
                ordinal = self.integer(ordinals + index * 2, "H")
                return self.integer(functions + ordinal * 4)
        raise PinError("Missing DLL export: " + name)

    def returned_string(self, name):
        address = self.export_rva(name)
        offset = self.offset(address)
        code = self.data[offset:offset + 16]
        if self.machine == 0x8664 and code[:3] == b"\x48\x8d\x05" and code[7] == 0xC3:
            return self.string(address + 7 + struct.unpack_from("<i", code, 3)[0])
        if self.machine == 0xAA64:
            page, addition, returned = struct.unpack_from("<III", code)
            if (page & 0x9F00001F == 0x90000000 and
                    addition & 0xFFC003FF == 0x91000000 and returned == 0xD65F03C0):
                immediate = ((page >> 29) & 3) | (((page >> 5) & 0x7FFFF) << 2)
                if immediate & (1 << 20):
                    immediate -= 1 << 21
                return self.string((address & ~4095) + immediate * 4096 +
                                   ((addition >> 10) & 4095))
        raise PinError(f"Unsupported {name} implementation: {code.hex()}; do not guess")

    def imported_dlls(self):
        if not self.imports:
            return []
        offset = self.offset(self.imports)
        result = []
        while any(self.data[offset:offset + 20]):
            result.append(self.string(self.integer(offset + 12)).lower())
            offset += 20
        return sorted(set(result))


def binary_evidence(data):
    lowered = data.lower()
    evidence = []
    for marker in GPL_MARKERS:
        offset = lowered.find(marker)
        if offset >= 0:
            evidence.append({"offset": offset, "marker": marker.decode("ascii")})
    return evidence


def runtime_inventory(map_text):
    members = sorted(set(re.findall(r"^ld\.lld: Loaded ([^\n]+\.a\([^\n()]+\)) for ",
                                    map_text, re.MULTILINE)))
    if not members:
        raise PinError("No static runtime archive members recorded")
    startup = sorted({Path(name).name for name in re.findall(
        r"^ld\.lld: Reading ([^\n]+/(?:dllcrt2|crtbegin|crtend)\.o)$", map_text, re.MULTILINE)})
    if startup != ["crtbegin.o", "crtend.o", "dllcrt2.o"]:
        raise PinError("Missing direct CRT startup object provenance")
    return {"archiveMembers": members, "startupObjects": startup}


def inspect_dlls(directory, rid):
    return inspect_images({path.name: path.read_bytes() for path in directory.glob("*.dll")}, rid)


def inspect_images(images, rid):
    records = {}
    expected = {f"{name}-{major}.dll" for name, major in MAJORS.items()}
    actual = set(images)
    if actual != expected:
        raise PinError(f"DLL set/ABI mismatch: {sorted(actual ^ expected)}")
    for name in sorted(expected):
        data = images[name]
        image = PE(data)
        if image.machine != MACHINES[rid]:
            raise PinError("DLL architecture mismatch: " + name)
        evidence = binary_evidence(data)
        if evidence:
            raise PinError(f"Forbidden binary markers in {name}: {evidence}")
        records[name] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                         "imports": image.imported_dlls(), "gplMarkers": evidence}
    codec = PE(images[f"avcodec-{MAJORS['avcodec']}.dll"])
    configuration = codec.returned_string("avcodec_configuration")
    license_text = codec.returned_string("avcodec_license")
    validate_configuration(configuration, license_text)
    return {"configure": configuration, "license": license_text, "dlls": records}


def inspect_archive(path, rid):
    with zipfile.ZipFile(path) as archive:
        expected = {f"bin/{name}-{major}.dll" for name, major in MAJORS.items()}
        if len(archive.namelist()) != len(expected) or set(archive.namelist()) != expected:
            raise PinError("Unexpected or duplicate DLL ZIP entries")
        return inspect_images({Path(name).name: archive.read(name) for name in expected}, rid)


def validate_components(header, rid, filter_registration=None):
    resolved = {kind: [] for kind in COMPONENTS}
    expression = r"^#define CONFIG_(\w+)_(DECODER|ENCODER|PARSER|BSF|DEMUXER|MUXER|FILTER|HWACCEL|PROTOCOL) 1$"
    for name, kind in re.findall(expression, header, re.MULTILINE):
        resolved[kind.lower()].append(name.lower())
    wanted = components(rid)
    if any(set(resolved[kind]) != set(wanted[kind]) for kind in wanted):
        details = {kind: {"unexpected": sorted(set(resolved[kind]) - set(wanted[kind])),
                          "missing": sorted(set(wanted[kind]) - set(resolved[kind]))}
                   for kind in wanted if set(resolved[kind]) != set(wanted[kind])}
        raise PinError("Resolved component mismatch: " + json.dumps(details))
    if filter_registration is not None:
        symbols = set(re.findall(r"&ff_(\w+)\s*,", filter_registration))
        if symbols != set(FILTER_SYMBOLS):
            raise PinError("Unexpected registered filters: " + str(sorted(symbols ^ set(FILTER_SYMBOLS))))
        resolved["filter"] = list(FILTER_SYMBOLS.values())
    return {kind: sorted(names) for kind, names in resolved.items()}


def deterministic_zip(directory, output):
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for path in sorted(directory.glob("*.dll")):
            info = zipfile.ZipInfo("bin/" + path.name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100755 << 16
            archive.writestr(info, path.read_bytes())


def byte_differences(first, second):
    changes = []
    start = None
    for offset in range(max(len(first), len(second))):
        different = first[offset:offset + 1] != second[offset:offset + 1]
        if different and start is None:
            start = offset
        if start is not None and (not different or offset == max(len(first), len(second)) - 1):
            end = offset if not different else offset + 1
            changes.append({"start": start, "end": end,
                            "first": first[start:end].hex(), "second": second[start:end].hex()})
            start = None
    return changes


def compare_builds(first, second):
    with zipfile.ZipFile(first) as left, zipfile.ZipFile(second) as right:
        if sorted(left.namelist()) != sorted(right.namelist()):
            raise PinError("Reproducibility: archive file sets differ")
        differences = {name: byte_differences(left.read(name), right.read(name))
                       for name in left.namelist() if left.read(name) != right.read(name)}
    return {"identical": not differences and digest_file(first) == digest_file(second),
            "firstSha256": digest_file(first), "secondSha256": digest_file(second),
            "differences": differences}


def prepare_host(lock, cache):
    key = platform.system() + "-" + platform.machine()
    if key not in lock["toolchains"]:
        raise PinError("Host must be Apple-silicon macOS or Linux x86_64")
    asset = lock["toolchains"][key]
    archive = download(asset, cache)
    destination = cache / "toolchains" / asset["sha256"]
    toolchain = pinned_tree(archive, destination, asset["sha256"], cache)
    return toolchain, asset


def prepare_host_tools(lock, cache, environment, log):
    assets = {item["component"]: item for item in lock["sourceAssets"]}
    bins = []
    for name in ("ninja", "nasm"):
        asset = assets[name]
        prefix = cache / "host-tools" / asset["sha256"]
        executable = prefix / "bin" / name
        marker = prefix / ".complete"
        if prefix.exists() and (not executable.is_file() or not marker.is_file() or
                                marker.read_text().strip() != asset["sha256"]):
            shutil.rmtree(prefix)
        if not prefix.exists():
            disk_guard(cache)
            prefix.parent.mkdir(parents=True, exist_ok=True)
            temporary = Path(tempfile.mkdtemp(prefix=name + ".", dir=prefix.parent))
            source_dir = Path(tempfile.mkdtemp(prefix=name + "-source.", dir=cache))
            try:
                source = unpack(download(asset, cache), source_dir)
                if name == "ninja":
                    run([sys.executable, source / "configure.py", "--bootstrap"], source,
                        environment, log)
                    (temporary / "bin").mkdir()
                    shutil.copyfile(source / "ninja", temporary / "bin/ninja")
                else:
                    run([source / "configure", "--prefix=" + str(temporary)], source,
                        environment, log)
                    run(["make", "-j2"], source, environment, log)
                    run(["make", "install"], source, environment, log)
                (temporary / "bin" / name).chmod(0o755)
                (temporary / ".complete").write_text(asset["sha256"] + "\n")
                temporary.replace(prefix)
            finally:
                shutil.rmtree(source_dir, ignore_errors=True)
                if temporary.exists():
                    shutil.rmtree(temporary)
        bins.append(str(prefix / "bin"))
    return bins


def build_environment(work, toolchain, host_bins, lock, rid):
    work.mkdir(parents=True, exist_ok=True)
    scratch = work / "config"
    scratch.mkdir()
    temporary = work / "tmp"
    temporary.mkdir()
    # Host prerequisites are explicit; no caller variable reaches configure or a compiler.
    host_paths = [path for path in ("/opt/homebrew/bin", "/usr/local/bin") if Path(path).exists()]
    return {"PATH": os.pathsep.join([str(toolchain / "bin"), *host_bins,
                                      "/usr/bin", "/bin", *host_paths]),
            "XDG_CONFIG_HOME": str(scratch), "XDG_CACHE_HOME": str(scratch),
            "TMPDIR": str(temporary), "LANG": "C", "LC_ALL": "C",
            "TZ": "UTC", "SOURCE_DATE_EPOCH": str(lock["sourceDateEpoch"]),
            "ZERO_AR_DATE": "1", "PYTHONHASHSEED": "0",
            "CPU_FAMILY": "x86_64" if rid == "win-x64" else "aarch64"}


def host_tool_versions(environment, work):
    result = {"python": platform.python_version()}
    for tool, argument in (("cmake", "--version"), ("make", "--version"),
                           ("pkg-config", "--version"), ("perl", "-v")):
        output = subprocess.check_output([tool, argument], cwd=work, env=environment,
                                         stderr=subprocess.STDOUT, timeout=15).decode(
                                             "utf-8", errors="replace")
        result[tool] = next((line.strip() for line in output.splitlines() if line.strip()), "")
        if not result[tool]:
            raise PinError("Missing host tool version: " + tool)
    return result


def build_once(rid, attempt, lock, cache, jobs):
    cache.mkdir(parents=True, exist_ok=True)
    disk_guard(cache)
    report_directory = cache / "reports" / f"{rid}-{attempt}"
    if report_directory.exists():
        shutil.rmtree(report_directory)
    report_directory.mkdir(parents=True, exist_ok=True)
    work = cache / "work" / f"{rid}-{attempt}"
    if work.exists():
        raise PinError("Previous work tree remains; inspect it before resuming: " + str(work))
    work.mkdir(parents=True)
    started = time.monotonic()
    with (report_directory / "build.log").open("wb") as log:
        try:
            toolchain, host_asset = prepare_host(lock, cache)
            environment = build_environment(work, toolchain, [], lock, rid)
            host_bins = prepare_host_tools(lock, cache, environment, log)
            environment["PATH"] = os.pathsep.join([str(toolchain / "bin"), *host_bins,
                                                   *environment["PATH"].split(os.pathsep)[1:]])
            tool_versions = host_tool_versions(environment, work)
            sources = {}
            for asset in lock["sourceAssets"]:
                if asset["component"] not in {"ffmpeg", "amf", "ffnvcodec", "libvpl",
                                               "libdav1d", "meson"}:
                    continue
                archive = download(asset, cache)
                disk_guard(cache)
                sources[asset["component"]] = unpack(archive, work / "src" / asset["component"],
                                                      asset["component"] == "amf")
            for variable, component in {"AMF_SOURCE": "amf", "NV_SOURCE": "ffnvcodec",
                                        "VPL_SOURCE": "libvpl", "DAV1D_SOURCE": "libdav1d",
                                        "MESON_SOURCE": "meson"}.items():
                environment[variable] = str(sources[component])
            disk_guard(cache)
            run(["sh", DIRECTORY / "dependencies.sh", work, TARGETS[rid], str(jobs)],
                work, environment, log)
            binary_directory = work / "bin"
            binary_directory.mkdir()
            linker = binary_directory / "voxclip-link"
            shutil.copyfile(DIRECTORY / "linker.py", linker)
            linker.chmod(0o755)
            environment["PATH"] = str(binary_directory) + os.pathsep + environment["PATH"]
            environment["VOXCLIP_LINKER"] = str(toolchain / "bin" / (TARGETS[rid] + "-clang"))
            environment["PKG_CONFIG_LIBDIR"] = str(work / "prefix/lib/pkgconfig")
            environment["PKG_CONFIG_PATH"] = ""
            output = work / "ffmpeg"
            output.mkdir()
            arguments = configure_arguments(rid, lock)
            validate_source_mapping(shlex.join(arguments), lock)
            run(["sh", sources["ffmpeg"] / "configure", *arguments], output, environment, log)
            resolved = validate_components((output / "config_components.h").read_text(), rid,
                                           (output / "libavfilter/filter_list.c").read_text())
            disk_guard(cache)
            run(["make", "-j" + str(jobs)], output, environment, log)
            dll_directory = report_directory / "dlls"
            if dll_directory.exists():
                shutil.rmtree(dll_directory)
            dll_directory.mkdir()
            maps = {}
            map_texts = {}
            for library, major in MAJORS.items():
                matches = list(output.rglob(f"{library}-{major}.dll"))
                if len(matches) != 1:
                    raise PinError("Missing or ambiguous DLL: " + library)
                source = matches[0]
                destination = dll_directory / source.name
                shutil.copyfile(source, destination)
                run([toolchain / "bin/llvm-strip", "--strip-all", destination], output, environment, log)
                map_path = source.with_suffix(source.suffix + ".map")
                if not map_path.exists():
                    raise PinError("Missing runtime link map for " + library)
                map_text = map_path.read_text(errors="replace")
                shutil.copyfile(map_path, report_directory / (library + ".map"))
                maps[library] = runtime_inventory(map_text)
                map_texts[library] = map_text
            audit = licences.audit_maps(map_texts, sources["ffmpeg"], rid)
            dependency_audit = licences.audit_dependency_objects(
                sources, cache / "downloads", lock, map_texts)
            notices, notice_hash = licences.render_notices(
                audit, sources["ffmpeg"], licences.dependency_notices(
                    sources, cache / "downloads", lock, rid, map_texts))
            (report_directory / "FFmpeg-NOTICES.txt").write_text(notices)
            shutil.copyfile(sources["ffmpeg"] / "LICENSE.md", report_directory / "FFmpeg-LICENSE.md")
            shutil.copyfile(sources["ffmpeg"] / "COPYING.LGPLv2.1",
                            report_directory / "FFmpeg-LICENSE.txt")
            evidence = inspect_dlls(dll_directory, rid)
            expected_configuration = " ".join(shlex.quote(argument) if " " in argument else argument
                                              for argument in arguments)
            if shlex.split(evidence["configure"]) != shlex.split(expected_configuration):
                raise PinError("DLL configure string differs from the requested recipe")
            archive = report_directory / f"voxclip-ffmpeg-{lock['version']}-{rid}.zip"
            deterministic_zip(dll_directory, archive)
            if inspect_archive(archive, rid) != evidence:
                raise PinError("Packaged DLLs differ from inspected build outputs")
            evidence.update(rid=rid, sourceCommit=lock["sourceCommit"],
                            buildInputsSha256=build_inputs_digest(lock), components=resolved,
                            toolchain=host_asset, hostTools=tool_versions, runtimeObjects=maps,
                            licenceAudit={"objects": audit["objects"], "sources": audit["sources"],
                                          "notices": sorted(audit["notices"]),
                                          "armCrcText": audit["armCrcText"],
                                          "dependencySources": dependency_audit["checkedSources"],
                                          "unresolvedDependencyMembers": dependency_audit["unresolvedMembers"],
                                          "loadedDependencyMembers": dependency_audit["loadedMembers"],
                                          "systemImportMembers": dependency_audit["systemImports"],
                                          "noticeSha256": notice_hash}, elapsedSeconds=
                            round(time.monotonic() - started, 3), archive=archive.name,
                            sha256=digest_file(archive), size=archive.stat().st_size)
            write_json(report_directory / "report.json", evidence)
            print(f"{rid} attempt {attempt}: {evidence['sha256']} ({evidence['elapsedSeconds']}s)", flush=True)
            return report_directory / "report.json"
        finally:
            for name in ("config.h", "config_components.h"):
                source = work / "ffmpeg" / name
                if source.exists():
                    shutil.copyfile(source, report_directory / name)
            for relative in ("libavfilter/filter_list.c",):
                source = work / "ffmpeg" / relative
                if source.exists():
                    shutil.copyfile(source, report_directory / source.name)
            for source in (work / "ffmpeg").rglob("*.dll.map"):
                shutil.copyfile(source, report_directory / source.name)
            shutil.rmtree(work)


def write_pin(path, lock, reports, reproducibility):
    if set(reports) != set(TARGETS) or set(reproducibility) != set(TARGETS):
        raise PinError("Both RIDs require build and reproducibility evidence")
    builds = {}
    configurations = {}
    for rid, report in reports.items():
        validate_report_inputs(report, rid, lock)
        validate_configuration(report["configure"], report["license"])
        validate_source_mapping(report["configure"], lock)
        if not reproducibility[rid]["identical"]:
            raise PinError("Refusing a nonreproducible pin")
        if (report["sha256"] != reproducibility[rid]["firstSha256"] or
                report["sha256"] != reproducibility[rid]["secondSha256"] or
                reproducibility[rid]["differences"]):
            raise PinError("Reproducibility evidence does not match the archive")
        configurations[rid] = report["configure"]
        builds[rid] = {"name": report["archive"], "sha256": report["sha256"], "size": report["size"]}
    manifest = {"schema": "voxclip-ffmpeg/2", "version": lock["version"],
                "sourceCommit": lock["sourceCommit"], "recipe": "tools/ffmpeg-build",
                "buildInputsSha256": build_inputs_digest(lock),
                "recipeCommit": "BUILD_COMMIT", "configure": configurations,
                "license": "LGPL version 2.1 or later", "builds": builds,
                "sourceAssets": [item for item in lock["sourceAssets"]
                                 if item["component"] not in {"meson", "ninja", "nasm"}],
                "buildTools": [item for item in lock["sourceAssets"]
                               if item["component"] in {"meson", "ninja", "nasm"}],
                "toolchains": lock["toolchains"], "dlls": list(MAJORS),
                "libraryMajors": MAJORS, "reproducibility": reproducibility,
                "testTools": {rid: {**item, "purpose": "TEST ONLY; never ship"}
                              for rid, item in TEST_TOOLS.items()}}
    write_json(path, manifest)


def check_pin(lock, reports, reproducibility):
    pin = json.loads(MANIFEST.read_text())
    if pin.get("buildInputsSha256") != build_inputs_digest(lock):
        raise PinError("Committed FFmpeg build-input pin differs")
    for rid in TARGETS:
        report = reports[rid]
        if (pin["builds"][rid] != {key: report[key] for key in ("sha256", "size")}
                | {"name": report["archive"]}):
            raise PinError("Committed FFmpeg archive pin differs: " + rid)
        if shlex.split(pin["configure"][rid]) != shlex.split(report["configure"]):
            raise PinError("Committed FFmpeg configure pin differs: " + rid)
        if pin["reproducibility"][rid] != reproducibility[rid]:
            raise PinError("Committed FFmpeg reproducibility pin differs: " + rid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "verify", "write-pin", "fetch"))
    parser.add_argument("--rid", choices=tuple(TARGETS))
    parser.add_argument("--attempt", type=int, choices=(1, 2), default=1)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--cache", type=Path, default=CACHE)
    arguments = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    cache = arguments.cache.expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)
    with cache_lock(cache):
        execute(arguments, lock, cache, parser)


def execute(arguments, lock, cache, parser):
    if arguments.command == "fetch":
        for asset in [*lock["sourceAssets"], *lock["toolchains"].values()]:
            download(asset, cache)
        disk_guard(cache)
    elif arguments.command == "build":
        if not arguments.rid or not 1 <= arguments.jobs <= 2:
            parser.error("build requires --rid and 1 or 2 compile jobs")
        build_once(arguments.rid, arguments.attempt, lock, cache, arguments.jobs)
    else:
        reports, reproducibility = {}, {}
        for rid in TARGETS:
            paths = [cache / "reports" / f"{rid}-{attempt}" for attempt in (1, 2)]
            reports[rid] = json.loads((paths[0] / "report.json").read_text())
            for directory in paths:
                expected = json.loads((directory / "report.json").read_text())
                validate_report_inputs(expected, rid, lock)
                actual = inspect_dlls(directory / "dlls", rid)
                if any(actual[key] != expected[key] for key in ("configure", "license", "dlls")):
                    raise PinError("Cached evidence changed: " + str(directory))
                archived = inspect_archive(directory / expected["archive"], rid)
                if any(archived[key] != expected[key] for key in ("configure", "license", "dlls")):
                    raise PinError("Cached ZIP differs from inspected DLLs: " + str(directory))
            archives = [directory / reports[rid]["archive"] for directory in paths]
            reproducibility[rid] = compare_builds(*archives)
            write_json(cache / "reports" / f"{rid}-reproducibility.json", reproducibility[rid])
            print(rid + ": " + json.dumps(reproducibility[rid]))
            if not reproducibility[rid]["identical"]:
                raise PinError("Non-identical clean builds; see exact byte differences in report")
        if arguments.command == "write-pin":
            write_pin(MANIFEST, lock, reports, reproducibility)
        else:
            check_pin(lock, reports, reproducibility)


if __name__ == "__main__":
    try:
        main()
    except (PinError, licences.LicenceError, subprocess.CalledProcessError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
