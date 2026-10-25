"""Audit linked FFmpeg sources and derive notices from the same link maps."""

import hashlib
from pathlib import Path
import re
import tarfile


class LicenceError(Exception):
    pass


OBJECT = re.compile(r"^[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s+\d+\s+"
                    r"(lib(?:avcodec|avformat|avutil|avfilter|swresample|swscale)/[\w./+-]+?\.o):\(([^)]+)\)",
                    re.MULTILINE)
GPL = re.compile(r"GNU (?:General Public License|GPL)", re.I)
LGPL = re.compile(r"(?:Lesser|Library) General Public License", re.I)
PERMISSIVE = re.compile(r"permission is hereby granted|redistribution and use|Independent JPEG Group|IJG|ISC License|MIT License", re.I)


def source_for_object(root, name):
    if name.endswith("res.o"):
        return None  # generated Windows resource object, no FFmpeg source
    if name.endswith(".gen.o"):
        candidate = root / "libswscale/aarch64/ops_asmgen.c"
        if name.startswith("libswscale/aarch64/") and candidate.is_file():
            return candidate
    for suffix in (".c", ".S", ".asm"):
        candidate = root / (name[:-2] + suffix)
        if candidate.is_file():
            return candidate
    raise LicenceError("No pinned source for linked object: " + name)


def header(path):
    return header_text(path.read_text(encoding="utf-8", errors="replace"))


def header_text(content):
    beginning = content.lstrip()
    if beginning.startswith("/*"):
        end = beginning.find("*/")
        return beginning[:end + 2] if end >= 0 else beginning[:6000]
    lines = []
    for line in beginning.splitlines():
        if line.startswith((";", "#", "//", "@")) or not line.strip():
            lines.append(line)
        else:
            break
    return "\n".join(lines)


def audit_maps(maps, ffmpeg_root, rid):
    linked = set()
    sections = {}
    for map_text in maps.values():
        for size, name, section in OBJECT.findall(map_text):
            if int(size, 16) == 0:
                continue
            linked.add(name)
            sections.setdefault(name, set()).add(section)
    if not linked:
        raise LicenceError("No FFmpeg source objects found in link maps")
    notices = {}
    sources = set()
    for name in sorted(linked):
        path = source_for_object(ffmpeg_root, name)
        if path is None:
            continue
        relative = str(path.relative_to(ffmpeg_root))
        sources.add(relative)
        text = header(path)
        if GPL.search(text) and not LGPL.search(text):
            raise LicenceError("GPL-only linked source: " + relative)
        if PERMISSIVE.search(text) and not LGPL.search(text):
            notices[relative] = text
    crc = "libavutil/aarch64/crc.o"
    if rid == "win-arm64" and any(section.startswith(".text") for section in sections.get(crc, ())):
        raise LicenceError("ARM64 GPL-headed crc.o contributes .text")
    return {"objects": len(linked), "sources": sorted(sources), "notices": notices,
            "armCrcText": False if rid == "win-arm64" else None}


def render_notices(audit, ffmpeg_root, dependency_notices):
    licence = (ffmpeg_root / "LICENSE.md").read_text(encoding="utf-8")
    if "IJG" not in licence:
        raise LicenceError("FFmpeg IJG attribution missing from pinned LICENSE.md")
    lines = ["FFmpeg linked-source notices", "", "Source: " + ffmpeg_root.name,
             "The following files were selected from the actual DLL link maps.", "",
             "FFmpeg LICENSE.md (complete):", licence.rstrip(), ""]
    for name, header_text in sorted(audit["notices"].items()):
        lines += ["Source: " + name, header_text.rstrip(), ""]
    for name, notice in sorted(dependency_notices.items()):
        if not notice.strip():
            raise LicenceError("Empty pinned dependency notice: " + name)
        lines += ["Dependency: " + name, notice.rstrip(), ""]
    output = "\n".join(lines).rstrip() + "\n"
    validate_notice_coverage(audit, dependency_notices, output)
    return output, hashlib.sha256(output.encode()).hexdigest()


def validate_notice_coverage(audit, dependency_notices, output):
    for name in audit["notices"]:
        if "Source: " + name + "\n" not in output:
            raise LicenceError("Missing linked-file notice: " + name)
    for name in dependency_notices:
        if "Dependency: " + name + "\n" not in output:
            raise LicenceError("Missing dependency notice: " + name)


def archive_notice(archive, suffix):
    with tarfile.open(archive) as source:
        matches = [member for member in source.getmembers()
                   if member.isfile() and member.name.endswith("/" + suffix)]
        if len(matches) != 1:
            raise LicenceError("Pinned notice missing or ambiguous: " + suffix)
        return source.extractfile(matches[0]).read().decode("utf-8", errors="replace")


def dependency_notices(sources, downloads, lock, rid, maps):
    assets = {asset["component"]: asset for asset in lock["sourceAssets"]}
    notices = {"dav1d/COPYING": (sources["libdav1d"] / "COPYING").read_text(),
               "AMF/LICENSE.txt": (sources["amf"] / "LICENSE.txt").read_text(),
               "mingw-w64/COPYING.MinGW-w64-runtime.txt": archive_notice(
                   downloads / assets["mingw-w64"]["name"],
                   "COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt")}
    if rid == "win-x64":
        notices["libvpl/LICENSE"] = (sources["libvpl"] / "LICENSE").read_text()
    combined = "\n".join(maps.values())
    llvm_source = downloads / assets["llvm-project"]["name"]
    for archive_name, project in (("libclang_rt.builtins-", "compiler-rt"),
                                  ("libc++.a", "libcxx"),
                                  ("libc++.a", "libcxxabi"),
                                  ("libunwind.a", "libunwind")):
        if archive_name in combined:
            notices[project + "/LICENSE.TXT"] = archive_notice(
                llvm_source, project + "/LICENSE.TXT")
    if "libwinpthread.a" in combined:
        notices["winpthreads/COPYING"] = archive_notice(
            downloads / assets["mingw-w64"]["name"],
            "mingw-w64-libraries/winpthreads/COPYING")
    for component, directory in (("AMF", sources["amf"] / "amf/public/include"),
                                 ("ffnvcodec", sources["ffnvcodec"] / "include/ffnvcodec")):
        for path in sorted(directory.rglob("*.h")):
            text = header(path)
            if GPL.search(text) and not LGPL.search(text):
                raise LicenceError("GPL-only dependency header: " + str(path))
            if PERMISSIVE.search(text):
                notices[component + "/" + str(path.relative_to(directory))] = text
    if "mingw" not in combined.lower():
        raise LicenceError("No MinGW runtime provenance in maps")
    if "dav1d" not in combined.lower():
        raise LicenceError("No dav1d static archive in maps")
    if rid == "win-x64" and "vpl" not in combined.lower():
        raise LicenceError("No libvpl static archive in x64 maps")
    return notices


def audit_dependency_objects(sources, downloads, lock, maps):
    """Resolve every loaded archive member to one pinned source or a Windows import."""
    members = set(re.findall(r"^ld\.lld: Loaded ([^\n]+?) for ",
                             "\n".join(maps.values()), re.MULTILINE))
    if not members:
        raise LicenceError("No loaded static archive members in link maps")
    malformed = sorted(member for member in members if not
                       re.fullmatch(r"\S+\.(?:a|lib)\([^\n()]+\)", member))
    if malformed:
        raise LicenceError("Unknown loaded linker member: " + ", ".join(malformed))
    direct = set(re.findall(r"^ld\.lld: Reading ([^\n]+\.(?:o|obj))$",
                            "\n".join(maps.values()), re.MULTILINE))
    unexpected = sorted(path for path in direct if not
                        (re.fullmatch(r"lib(?:avcodec|avformat|avutil|avfilter|swresample|swscale)/[\w./+-]+\.o", path)
                         or Path(path).name in {"dllcrt2.o", "crtbegin.o", "crtend.o"}))
    if unexpected:
        raise LicenceError("Unknown direct linked object: " + ", ".join(unexpected))
    assets = {asset["component"]: asset for asset in lock["sourceAssets"]}
    source_files = {component: [path for path in root.rglob("*") if path.is_file()
                                and path.suffix.lower() in (".c", ".cc", ".cpp", ".s", ".asm")]
                    for component, root in sources.items() if component in ("libdav1d", "libvpl")}
    with tarfile.open(downloads / assets["mingw-w64"]["name"]) as mingw, \
            tarfile.open(downloads / assets["llvm-project"]["name"]) as llvm:
        archives = {"mingw-w64": mingw, "llvm-project": llvm}
        indexed = {}
        for component, source in archives.items():
            indexed[component] = [entry for entry in source.getmembers() if entry.isfile()
                                  and Path(entry.name).suffix.lower() in
                                  (".c", ".cc", ".cpp", ".s", ".asm")]
        checked = set()
        imports = set()
        for member in sorted(members):
            archive_name, object_name = member.rsplit("(", 1)
            object_name = object_name[:-1]
            name = Path(archive_name).name
            if name == "libdav1d.a":
                component, root = "libdav1d", ""
            elif name == "libvpl.a":
                component, root = "libvpl", ""
            elif name == "libc++.a":
                component, root = "llvm-project", "libcxx"
            elif name == "libunwind.a":
                component, root = "llvm-project", "libunwind/src"
            elif re.fullmatch(r"libclang_rt\.builtins-(?:x86_64|aarch64)\.a", name):
                component, root = "llvm-project", "compiler-rt/lib/builtins"
            elif name in {"libmingw32.a", "libmingwex.a", "libmsvcrt.a",
                          "libstrmiids.a", "libuuid.a"}:
                component, root = "mingw-w64", "mingw-w64-crt"
            elif name == "libwinpthread.a":
                component, root = "mingw-w64", "mingw-w64-libraries/winpthreads"
            else:
                raise LicenceError("Unknown loaded static archive: " + member)
            if name == "libmsvcrt.a" and re.fullmatch(r"api-ms-win-crt-[\w-]+\.dll", object_name):
                imports.add(member + ": Windows UCRT import; no DLL redistributed")
                continue
            if object_name.endswith(".dll"):
                raise LicenceError("Unknown Windows import member: " + member)
            source_name = object_name.removesuffix(".obj")
            if source_name == object_name:
                source_name = re.sub(r"^lib(?:32|64|arm64)_[^-]+-", "", object_name.removesuffix(".o"))
                source_name = re.sub(r"^libwinpthread_la-", "", source_name)
            if component == "libdav1d":
                source_name = source_name.removeprefix("arm_64_")
                if source_name.endswith(("_cpu.c", "_thread.c")):
                    source_name = re.sub(r"^(?:win32|x86|arm)_", "", source_name)
            if component in sources:
                candidates = [path for path in source_files[component]
                              if (path.name.lower() == source_name.lower() or
                                   path.stem.lower() == source_name.lower())]
                if component == "libvpl":
                    candidates = [path for path in candidates if
                                  path.relative_to(sources[component]).as_posix().startswith("libvpl/src/")]
                if component == "libdav1d":
                    if object_name.startswith("arm_") and source_name in {"cpu.c", "thread.c"}:
                        candidates = [path for path in candidates if
                                      path.relative_to(sources[component]).as_posix().startswith("src/arm/")]
                    elif object_name.startswith("arm_64_"):
                        candidates = [path for path in candidates if
                                      path.relative_to(sources[component]).as_posix().startswith("src/arm/64/")]
                    elif re.search(r"(?:avx|sse|ssse|x86)", object_name):
                        candidates = [path for path in candidates if
                                      path.relative_to(sources[component]).as_posix().startswith("src/x86/")]
                    elif object_name in {"msac.obj", "pal.obj", "refmvs.obj"}:
                        candidates = [path for path in candidates if
                                      path.relative_to(sources[component]).as_posix().startswith("src/x86/")]
                    else:
                        candidates = [path for path in candidates if
                                      path.relative_to(sources[component]).as_posix().startswith("src/") and not
                                      ({"loongarch", "riscv", "ppc", "32", "64"} &
                                       set(path.relative_to(sources[component]).parts))]
                        if object_name in {"cpu.c.obj", "thread.c.obj"}:
                            candidates = [path for path in candidates if
                                          path.relative_to(sources[component]).parent.as_posix() == "src"]
            else:
                candidates = [entry for entry in indexed[component]
                              if (name == "libc++.a" or ("/" + root + "/") in entry.name) and
                              (entry.name.lower().endswith("/" + source_name.lower()) or
                               Path(entry.name).stem.lower() == source_name.lower())]
                if name == "libc++.a":
                    candidates = [entry for entry in candidates if
                                  "/libcxx/src/" in entry.name or "/libcxxabi/src/" in entry.name]
                if name.startswith("libclang_rt.builtins-") and source_name == "chkstk.S":
                    arch = "x86_64" if "x86_64" in name else "aarch64"
                    candidates = [entry for entry in candidates if
                                  "/compiler-rt/lib/builtins/" + arch + "/" in entry.name]
                if name == "libmingwex.a" and source_name == "scalbn":
                    arch = "x86" if "lib64_" in object_name else "arm-common"
                    candidates = [entry for entry in candidates if "/math/" + arch + "/" in entry.name]
                if source_name == "strtof" and name in {"libmingwex.a", "libmsvcrt.a"}:
                    directory = "gdtoa" if name == "libmingwex.a" else "stdio"
                    candidates = [entry for entry in candidates if "/" + directory + "/" in entry.name]
            if len(candidates) != 1:
                raise LicenceError("Unresolved or ambiguous dependency source: " + member +
                                   " -> " + ", ".join(str(p) for p in candidates[:5]))
            candidate = candidates[0]
            content = (archives[component].extractfile(candidate).read(6000).decode(
                "utf-8", errors="replace") if component in archives else
                candidate.read_text(encoding="utf-8", errors="replace"))
            if GPL.search(header_text(content)) and not LGPL.search(header_text(content)):
                raise LicenceError("GPL-only dependency object: " + member + " -> " + str(candidate))
            checked.add(component + ":" + (candidate.name.split("/", 1)[-1]
                        if component in archives else str(candidate.relative_to(sources[component]))))
        startup = set(re.findall(r"^ld\.lld: Reading [^\n]+/(dllcrt2|crtbegin|crtend)\.o$",
                                 "\n".join(maps.values()), re.MULTILINE))
        if startup != {"dllcrt2", "crtbegin", "crtend"}:
            raise LicenceError("Missing direct MinGW CRT startup provenance")
        for object_name, source_name in (("dllcrt2", "crtdll.c"),
                                         ("crtbegin", "crtbegin.c"),
                                         ("crtend", "crtend.c")):
            candidates = [entry for entry in indexed["mingw-w64"] if entry.name.endswith(
                "/mingw-w64-crt/crt/" + source_name)]
            if len(candidates) != 1:
                raise LicenceError("Ambiguous MinGW startup source: " + object_name)
            text = header_text(mingw.extractfile(candidates[0]).read(6000).decode(
                "utf-8", errors="replace"))
            if GPL.search(text) and not LGPL.search(text):
                raise LicenceError("GPL-only MinGW startup source: " + source_name)
            checked.add("mingw-w64:" + source_name)
        return {"checkedSources": sorted(checked), "unresolvedMembers": [],
                "systemImports": sorted(imports), "loadedMembers": len(members)}
