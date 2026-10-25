#!/usr/bin/env python3
import argparse
import hashlib
import io
import gzip
import json
import posixpath
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
import xml.etree.ElementTree as ET


INTERNAL_FEATURES = frozenset((
    "asm", "avcodec", "avdevice", "avfilter", "avformat", "avutil", "bsf", "bsfs", "cuda-llvm",
    "cross-compile", "d3d11va", "d3d12va", "decoder", "decoders", "demuxer", "demuxers", "dxva2", "encoder", "encoders",
    "ffmpeg", "ffplay", "ffprobe", "filter", "filters", "hwaccel", "hwaccels", "mediafoundation",
    "muxer", "muxers", "neon", "network", "nvenc", "parser", "parsers", "pic", "protocol", "protocols",
    "runtime-cpudetect", "schannel", "shared", "small", "swresample", "swscale", "version3", "w32threads", "x86asm",
))
SOURCE_COMPONENT_ALIASES = {
    "ffnvcodec": {"nv-codec-headers"}, "amf": {"amf-headers"}, "vaapi": {"libva"},
    "pthreads": {"winpthreads", "mingw-w64"}, "vulkan": {"vulkan-loader"},
}


def version(repository):
    values = ET.parse(repository / "apps/windows/Directory.Build.props").findall(".//Version")
    if len(values) != 1 or not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", values[0].text or ""):
        raise ValueError("Expected one semver Version in Directory.Build.props")
    return values[0].text


RIDS = ("win-x64", "win-arm64")
RECIPE_FILES = ("build.py", "dependencies.sh", "linker.py", "licences.py")
MAX_CACHE_BYTES = 6 * 1024 ** 3


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def safe_name(name):
    return isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name) and name not in (".", "..")


def pinned_asset(asset, names):
    if not isinstance(asset, dict) or not safe_name(asset.get("name")) or asset["name"] in names:
        raise ValueError("Invalid or duplicate source asset name")
    names.add(asset["name"])
    if not isinstance(asset.get("component"), str) or not re.fullmatch(r"[a-z0-9][a-z0-9.+_-]*", asset["component"]):
        raise ValueError("Missing or invalid source component")
    if not isinstance(asset.get("url"), str) or not asset["url"].startswith("https://") or not re.fullmatch(r"[0-9a-f]{64}", str(asset.get("sha256"))):
        raise ValueError("Missing HTTPS URL/SHA256 for " + asset["name"])
    if type(asset.get("size")) is not int or asset["size"] <= 0:
        raise ValueError("Missing source size for " + asset["name"])
    paths = asset.get("includePaths", [])
    if not isinstance(paths, list) or any(not isinstance(p, str) or not p or p.startswith("/") or "\\" in p or any(c in ("", ".", "..") for c in p.split("/")) for p in paths) or len(paths) != len(set(paths)):
        raise ValueError("Unsafe source includePaths")


def source_pin(pin_path):
    pin = json.loads(pin_path.read_text())
    if pin.get("schema") != "voxclip-ffmpeg/2" or "btbnCommit" in pin:
        raise ValueError("Shipping requires voxclip-ffmpeg/2 without BtbN provenance")
    for field in ("sourceCommit", "recipe", "recipeCommit", "buildInputsSha256", "builds", "configure", "license", "sourceAssets", "buildTools", "toolchains", "libraryMajors", "reproducibility"):
        if not pin.get(field):
            raise ValueError(f"ffmpeg.json is missing {field}; no release without corresponding source")
    if not re.fullmatch(r"[0-9a-f]{40}", pin["sourceCommit"]) or pin["recipe"] != "tools/ffmpeg-build" or pin["recipeCommit"] != "BUILD_COMMIT" or not re.fullmatch(r"[0-9a-f]{64}", pin["buildInputsSha256"]):
        raise ValueError("Invalid FFmpeg source/recipe/build-input pin")
    configurations = pin["configure"]
    if not isinstance(configurations, dict) or set(configurations) != set(RIDS):
        raise ValueError("FFmpeg configure must cover both RIDs")
    for rid in RIDS:
        configuration = configurations.get(rid)
        if not isinstance(configuration, str) or not configuration.strip():
            raise ValueError(f"FFmpeg configure is missing {rid}")
        if "LGPL" not in pin["license"] or "--enable-shared" not in configuration or any(
            flag in shlex.split(configuration) for flag in ("--enable-gpl", "--enable-nonfree", "--enable-version3", "--enable-static")
        ):
            raise ValueError("Forbidden FFmpeg licence/configuration")
        build = pin["builds"].get(rid)
        if not isinstance(build, dict) or "url" in build or not safe_name(build.get("name")) or not re.fullmatch(r"[0-9a-f]{64}", str(build.get("sha256"))) or type(build.get("size")) is not int or build["size"] <= 0 or rid not in build["name"]:
            raise ValueError("Invalid local FFmpeg ZIP pin: " + rid)
        if build["sha256"] == pin.get("testTools", {}).get(rid, {}).get("sha256"):
            raise ValueError("Test-only FFmpeg archive cannot be shipped: " + rid)
        reproducibility = pin["reproducibility"].get(rid, {})
        if reproducibility.get("identical") is not True or reproducibility.get("firstSha256") != build["sha256"] or reproducibility.get("secondSha256") != build["sha256"] or reproducibility.get("differences") != {}:
            raise ValueError("Missing matching clean-build evidence: " + rid)
    names = set()
    components = set()
    for asset in [*pin["sourceAssets"], *pin["buildTools"], *pin["toolchains"].values()]:
        pinned_asset(asset, names)
        components.add(asset["component"])
    if "ffmpeg" not in {a["component"] for a in pin["sourceAssets"]} or not {"llvm-mingw", "mingw-w64", "llvm-project"}.issubset(components):
        raise ValueError("Missing corresponding-source/runtime components")
    if set(pin["libraryMajors"]) != {"avcodec", "avformat", "avutil", "avfilter", "swresample", "swscale"} or any(type(v) is not int or v <= 0 for v in pin["libraryMajors"].values()):
        raise ValueError("Expected exactly six ABI-named DLLs")
    if set(pin.get("dlls", [])) != set(pin["libraryMajors"]):
        raise ValueError("FFmpeg DLL inventory differs from ABI pin")
    missing = []
    for rid in RIDS:
        enabled = set()
        for argument in shlex.split(configurations[rid]):
            if argument.startswith("--enable-"):
                component = argument.removeprefix("--enable-").split("=", 1)[0]
                if component not in INTERNAL_FEATURES:
                    enabled.add(component)
        required = {"ffmpeg"} | enabled
        uncovered = {component for component in required if component not in components and not (
            component.startswith("lib") and component[3:] in components
        ) and not (SOURCE_COMPONENT_ALIASES.get(component, set()) & components)}
        if uncovered:
            missing.append(f"{rid}: {', '.join(sorted(uncovered))}")
    if missing:
        raise ValueError("Missing corresponding-source components: " + "; ".join(missing))
    return pin


def verified_file(path, size, digest):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != size or sha256(path) != digest:
        raise ValueError("Pinned size/SHA-256 mismatch: " + path.name)
    return path


def pe_machine(data):
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError("FFmpeg ZIP contains a non-PE DLL")
    offset = int.from_bytes(data[60:64], "little")
    if offset + 6 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise ValueError("FFmpeg ZIP contains a malformed PE DLL")
    return int.from_bytes(data[offset + 4:offset + 6], "little")


def recipe_at_commit(repository, commit, destination):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected full release BUILD_COMMIT")
    listing = subprocess.run(["git", "-C", str(repository), "ls-tree", "-r", "--name-only", commit, "--", "tools/ffmpeg-build"], check=True, capture_output=True).stdout.decode().splitlines()
    if not listing or any(not p.startswith("tools/ffmpeg-build/") or any(c in ("", ".", "..") for c in p.split("/")) for p in listing):
        raise ValueError("Missing or unsafe committed FFmpeg recipe")
    for relative in listing:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(subprocess.run(["git", "-C", str(repository), "show", f"{commit}:{relative}"], check=True, capture_output=True).stdout)
    return destination / "tools/ffmpeg-build"


def selected_source(original, asset, destination):
    # A selected source is repacked after checking every member. No archive link or path may escape.
    chosen = {}
    seen = set()
    selected_size = 0
    with tarfile.open(original, "r:*") as source:
        members = source.getmembers()
        roots = {m.name.split("/")[0] for m in members if m.name and not m.name.startswith("/")}
        if len(roots) != 1:
            raise ValueError("Source archive needs one component root")
        for member in members:
            parts = member.name.rstrip("/").split("/")
            normalized = member.name.rstrip("/")
            if member.name.startswith("/") or "\\" in member.name or any(p in ("", ".", "..") for p in parts) or normalized in seen or not (member.isfile() or member.isdir()):
                raise ValueError("Unsafe or duplicate source archive entry")
            seen.add(normalized)
            relative = "/".join(parts[1:])
            if member.isfile() and any(relative == p or relative.startswith(p + "/") for p in asset["includePaths"]):
                selected_size += member.size
                if member.size > 64 * 1024 * 1024 or selected_size > 256 * 1024 * 1024:
                    raise ValueError("Selected source entry exceeds size limit")
                chosen[relative] = source.extractfile(member).read()
    for include in asset["includePaths"]:
        if not any(p == include or p.startswith(include + "/") for p in chosen):
            raise ValueError("Missing selected source component: " + include)
    with destination.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as output:
            for relative, data in sorted(chosen.items()):
                info = tarfile.TarInfo(relative)
                info.size = len(data)
                info.mode = 0o644
                info.mtime = 0
                output.addfile(info, io.BytesIO(data))


def validate_original_archive(original):
    seen = {}
    roots = set()
    links = []
    with tarfile.open(original, "r:*") as archive:
        for member in archive:
            normalized = member.name.rstrip("/")
            parts = normalized.split("/")
            if member.name.startswith("/") or "\\" in member.name or any(p in ("", ".", "..") for p in parts) or normalized in seen or not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("Unsafe or duplicate source archive entry: " + original.name)
            seen[normalized] = member
            roots.add(parts[0])
            if member.issym() or member.islnk():
                links.append(member)
    if len(roots) != 1 or not seen:
        raise ValueError("Missing source archive component root: " + original.name)
    root = next(iter(roots))
    for member in links:
        target = member.linkname
        if not target or target.startswith("/") or "\\" in target:
            raise ValueError("Unsafe source archive symlink: " + original.name)
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), target) if member.issym() else target)
        if not resolved.startswith(root + "/") or resolved not in seen or not (seen[resolved].isfile() or seen[resolved].isdir()):
            raise ValueError("Unsafe source archive symlink: " + original.name)


def source_file(original, suffix):
    with tarfile.open(original, "r:*") as archive:
        matches = [member for member in archive if member.name.endswith("/" + suffix)]
        if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 1024 * 1024:
            raise ValueError("Missing or unsafe FFmpeg licence source: " + suffix)
        return archive.extractfile(matches[0]).read()


def stage(pin_path, repository, cache, output, commit):
    pin = source_pin(pin_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(output.parent).free < 15 * 1024 ** 3:
        raise ValueError("Need at least 15 GiB free for FFmpeg staging")
    if cache.exists() and sum(p.stat().st_size for p in cache.rglob("*") if p.is_file() and not p.is_symlink()) >= MAX_CACHE_BYTES:
        raise ValueError("FFmpeg download/build cache exceeds 6 GiB")
    with tempfile.TemporaryDirectory(prefix="ffmpeg-stage-", dir=output.parent) as temporary:
        work = Path(temporary)
        recipe = recipe_at_commit(repository, commit, work / "recipe")
        lock = json.loads((recipe / "sources.json").read_text())
        inputs = {"sources": lock, "recipe": {str(p.relative_to(recipe)): sha256(p) for p in [*(recipe / n for n in RECIPE_FILES), *sorted((recipe / "patches").glob("*"))] if p.is_file()}}
        digest = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
        if digest != pin["buildInputsSha256"] or pin["sourceCommit"] != lock["sourceCommit"]:
            raise ValueError("Committed recipe/buildInputsSha256 differs from shipping pin")
        if pin["sourceAssets"] != [a for a in lock["sourceAssets"] if a["component"] not in {"meson", "ninja", "nasm"}] or pin["buildTools"] != [a for a in lock["sourceAssets"] if a["component"] in {"meson", "ninja", "nasm"}] or pin["toolchains"] != lock["toolchains"]:
            raise ValueError("Source/build tool pins differ from committed recipe")
        stage_dir = work / "staged"
        stage_dir.mkdir()
        sources = work / "ffmpeg-source"
        (sources / "sources").mkdir(parents=True)
        shutil.copytree(recipe, sources / "tools/ffmpeg-build")
        records = []
        for asset in [*pin["sourceAssets"], *pin["buildTools"]]:
            original = verified_file(cache / "downloads" / asset["name"], asset["size"], asset["sha256"])
            if asset.get("includePaths"):
                selected_name = asset["component"] + "-selected.tar.gz"
                selected_source(original, asset, sources / "sources" / selected_name)
                records.append({"component": asset["component"], "original": asset["name"], "originalSha256": asset["sha256"], "originalSize": asset["size"], "included": asset["includePaths"], "archive": selected_name, "archiveSha256": sha256(sources / "sources" / selected_name)})
            else:
                validate_original_archive(original)
                shutil.copyfile(original, sources / "sources" / asset["name"])
                verified_file(sources / "sources" / asset["name"], asset["size"], asset["sha256"])
                records.append({"component": asset["component"], "archive": asset["name"], "sha256": asset["sha256"], "size": asset["size"]})
        (sources / "SOURCE-ASSETS.json").write_text(json.dumps(records, indent=2) + "\n")
        (sources / "ffmpeg.json").write_text(json.dumps(pin, indent=2) + "\n")
        build_lines = [f"FFmpeg {pin['sourceCommit']}", f"Recipe commit {commit}", f"Build inputs SHA-256 {digest}", f"License {pin['license']}"]
        expected_dlls = {f"{name}-{major}.dll" for name, major in pin["libraryMajors"].items()}
        for rid in RIDS:
            report_dir = cache / "reports" / f"{rid}-1"
            report = json.loads((report_dir / "report.json").read_text())
            build = pin["builds"][rid]
            if any((report.get("rid") != rid, report.get("archive") != build["name"], report.get("size") != build["size"], report.get("sha256") != build["sha256"], report.get("sourceCommit") != pin["sourceCommit"], report.get("buildInputsSha256") != digest, shlex.split(report.get("configure", "")) != shlex.split(pin["configure"][rid]), report.get("license") != pin["license"])):
                raise ValueError("Wrong FFmpeg build evidence: " + rid)
            second_dir = cache / "reports" / f"{rid}-2"
            second = json.loads((second_dir / "report.json").read_text())
            if any((second.get("rid") != rid, second.get("archive") != build["name"], second.get("size") != build["size"], second.get("sha256") != build["sha256"], second.get("sourceCommit") != pin["sourceCommit"], second.get("buildInputsSha256") != digest, shlex.split(second.get("configure", "")) != shlex.split(pin["configure"][rid]), second.get("license") != pin["license"])):
                raise ValueError("Wrong second clean-build evidence: " + rid)
            verified_file(second_dir / build["name"], build["size"], build["sha256"])
            archive = verified_file(report_dir / build["name"], build["size"], build["sha256"])
            with zipfile.ZipFile(archive) as zipped:
                names = zipped.namelist()
                if len(names) != 6 or set(names) != {"bin/" + n for n in expected_dlls} or set(report.get("dlls", {})) != expected_dlls:
                    raise ValueError("Unexpected DLL/test artifact in shipping ZIP: " + rid)
                for name in names:
                    info = zipped.getinfo(name)
                    data = zipped.read(info)
                    machine = 0x8664 if rid == "win-x64" else 0xAA64
                    if info.is_dir() or (info.external_attr >> 16) & 0o170000 == 0o120000 or pe_machine(data) != machine or len(data) != report["dlls"][Path(name).name]["size"] or hashlib.sha256(data).hexdigest() != report["dlls"][Path(name).name]["sha256"]:
                        raise ValueError("FFmpeg DLL evidence mismatch: " + name)
            audit_fields = ("dlls", "runtimeObjects", "licenceAudit", "components")
            if any(not isinstance(report.get(field), dict) or report[field] != second.get(field) for field in audit_fields):
                raise ValueError("Clean-build audit evidence differs: " + rid)
            audit = {"rid": rid, "sourceCommit": pin["sourceCommit"], "buildInputsSha256": digest,
                     "configure": report["configure"], "license": report["license"],
                     **{field: report[field] for field in audit_fields}}
            audit_text = json.dumps(audit, indent=2, sort_keys=True) + "\n"
            if any(marker in audit_text for marker in ("/Users/", "config.log", "build.log", ".map", "private/")):
                raise ValueError("Private/raw FFmpeg audit evidence cannot be staged")
            (stage_dir / f"{rid}-audit.json").write_text(audit_text)
            (sources / f"{rid}-audit.json").write_text(audit_text)
            shutil.copyfile(archive, stage_dir / build["name"])
            verified_file(stage_dir / build["name"], build["size"], build["sha256"])
            build_lines.extend((f"{rid} ZIP SHA-256 {build['sha256']} size {build['size']}", f"{rid} configure: {pin['configure'][rid]}"))
            for name in sorted(expected_dlls):
                dll = report["dlls"][name]
                build_lines.append(f"{rid} {name} SHA-256 {dll['sha256']} imports: {', '.join(dll['imports'])}")
        ffmpeg_source = next(a for a in pin["sourceAssets"] if a["component"] == "ffmpeg")
        original_ffmpeg = verified_file(cache / "downloads" / ffmpeg_source["name"], ffmpeg_source["size"], ffmpeg_source["sha256"])
        license_names = ("FFmpeg-LICENSE.txt", "FFmpeg-LICENSE.md")
        for name in license_names:
            first = cache / "reports/win-x64-1" / name
            second = cache / "reports/win-arm64-1" / name
            if not first.is_file() or not second.is_file() or sha256(first) != sha256(second) or first.stat().st_size == 0:
                raise ValueError("Missing or inconsistent FFmpeg license/notice evidence: " + name)
            source_name = "COPYING.LGPLv2.1" if name == "FFmpeg-LICENSE.txt" else "LICENSE.md"
            if first.read_bytes() != source_file(original_ffmpeg, source_name):
                raise ValueError("FFmpeg licence differs from pinned source: " + name)
            shutil.copyfile(first, stage_dir / name)
            shutil.copyfile(first, sources / name)
        for rid in RIDS:
            notice = cache / "reports" / f"{rid}-1" / "FFmpeg-NOTICES.txt"
            if not notice.is_file() or notice.stat().st_size == 0:
                raise ValueError("Missing FFmpeg notice evidence: " + rid)
            report = json.loads((cache / "reports" / f"{rid}-1" / "report.json").read_text())
            if report.get("licenceAudit", {}).get("noticeSha256") != sha256(notice):
                raise ValueError("Wrong FFmpeg notice evidence: " + rid)
            shutil.copyfile(notice, stage_dir / f"{rid}-FFmpeg-NOTICES.txt")
            shutil.copyfile(notice, sources / f"{rid}-FFmpeg-NOTICES.txt")
        build_text = "\n".join(build_lines) + "\n"
        (stage_dir / "BUILD.txt").write_text(build_text)
        (sources / "BUILD.txt").write_text(build_text)
        def normalize(info):
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o755 if info.isdir() else 0o644
            return info
        with tarfile.open(stage_dir / "source.tar.xz", "w:xz") as archive:
            archive.add(sources, arcname="ffmpeg-source", recursive=True, filter=normalize)
        receipt = {"schema": pin["schema"], "commit": commit, "buildInputsSha256": digest, "files": {p.name: {"size": p.stat().st_size, "sha256": sha256(p)} for p in stage_dir.iterdir() if p.is_file()}}
        (stage_dir / "stage.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if output.exists():
            raise ValueError("FFmpeg stage already exists")
        stage_dir.replace(output)


def source_archive(stage_dir, output):
    receipt = json.loads((stage_dir / "stage.json").read_text())
    pin = receipt["files"]["source.tar.xz"]
    verified_file(stage_dir / "source.tar.xz", pin["size"], pin["sha256"])
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    try:
        shutil.copyfile(stage_dir / "source.tar.xz", temporary)
        verified_file(temporary, pin["size"], pin["sha256"])
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def manifest(directory, evidence, release_version, commit):
    receipt = json.loads((evidence / "verification.json").read_text())
    if receipt.get("verified") is not True or receipt.get("version") != release_version or receipt.get("commit") != commit:
        raise ValueError("Missing matching VM verification receipt")
    names = {"VoxClip-win-ffmpeg-source.tar.xz"}
    for rid in ("win-x64", "win-arm64"):
        names.update((f"VoxClip-{rid}-Setup.exe", f"releases.{rid}.json"))
        feed = json.loads((directory / f"releases.{rid}.json").read_text())
        packages = feed["Assets"]
        full = False
        for asset in packages:
            if asset["Version"] != release_version:
                continue
            name = asset["FileName"]
            pattern = rf"VoxClip-{re.escape(release_version)}-{rid}-(full|delta)\.nupkg"
            if not re.fullmatch(pattern, name):
                raise ValueError(f"Unexpected package filename: {name}")
            full |= asset["Type"] == "Full"
            names.add(name)
        if not full:
            raise ValueError(f"No full {rid} package in the feed")
    sums = []
    for name in sorted(names):
        path = directory / name
        if not path.is_file():
            raise ValueError(f"Release asset missing: {name}")
        digest = hashlib.sha256()
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
        sums.append(f"{digest.hexdigest()}  {name}\n")
    (directory / "SHA256SUMS-windows.txt").write_text("".join(sums), encoding="ascii")
    names.add("SHA256SUMS-windows.txt")
    (evidence / "upload-manifest.json").write_text(json.dumps({
        "version": release_version, "commit": commit, "testBuild": receipt["testBuild"], "assets": sorted(names)
    }, indent=2) + "\n", encoding="ascii")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("version", "check-pin", "stage", "source", "manifest", "upload-list"))
    parser.add_argument("paths", nargs="+")
    arguments = parser.parse_args()
    if arguments.operation == "version":
        print(version(Path(arguments.paths[0])))
    elif arguments.operation == "check-pin":
        source_pin(Path(arguments.paths[0]))
    elif arguments.operation == "stage":
        stage(*(Path(path) for path in arguments.paths[:4]), arguments.paths[4])
    elif arguments.operation == "source":
        source_archive(*map(Path, arguments.paths))
    elif arguments.operation == "manifest":
        manifest(Path(arguments.paths[0]), Path(arguments.paths[1]), *arguments.paths[2:])
    else:
        evidence, release_version, commit = arguments.paths
        record = json.loads((Path(evidence) / "upload-manifest.json").read_text())
        if record["version"] != release_version or record["commit"] != commit or record["testBuild"]:
            raise ValueError("Only the verified, clean, tagged release build can be uploaded")
        for name in record["assets"]:
            if name not in {"VoxClip-win-ffmpeg-source.tar.xz", "SHA256SUMS-windows.txt"} and not re.fullmatch(
                rf"(?:VoxClip-win-(?:x64|arm64)-Setup\.exe|releases\.win-(?:x64|arm64)\.json|VoxClip-{re.escape(release_version)}-win-(?:x64|arm64)-(?:full|delta)\.nupkg)", name
            ):
                raise ValueError("Unexpected upload asset")
            print(name)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, tarfile.TarError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release assets: {error}") from None
