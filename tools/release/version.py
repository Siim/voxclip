#!/usr/bin/env python3
"""Read and update the two release version files without platform-only tools."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-beta\.(?:0|[1-9][0-9]*))?")


def require_version(value):
    if not isinstance(value, str) or VERSION.fullmatch(value) is None:
        raise ValueError(f"invalid version {value!r}; expected X.Y.Z or X.Y.Z-beta.N")
    return value


def replace_one(pattern, value, text, label):
    updated, count = re.subn(pattern, lambda match: match[1] + value + match[2], text)
    if count != 1:
        raise ValueError(f"expected exactly one {label}, found {count}")
    return updated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    commands.add_parser("set").add_argument("version")
    arguments = parser.parse_args()
    if arguments.command == "set":
        require_version(arguments.version)

    plist_path = ROOT / "apps/macos/Sources/VoxClip/Info.plist"
    props_path = ROOT / "apps/windows/Directory.Build.props"
    plist_bytes = plist_path.read_bytes()
    plist = plistlib.loads(plist_bytes)
    macos_version = require_version(plist.get("CFBundleShortVersionString"))
    props_text = props_path.read_bytes().decode("utf-8")
    versions = ET.fromstring(props_text).findall("./{*}PropertyGroup/{*}Version")
    if len(versions) != 1:
        raise ValueError("Directory.Build.props must contain exactly one Version")
    windows_version = require_version(versions[0].text)

    if arguments.command == "check":
        if macos_version != windows_version:
            raise ValueError(f"version mismatch: macOS {macos_version}, Windows {windows_version}")
        print(f"ok version {macos_version} (macOS and Windows)")
        return

    build = plist.get("CFBundleVersion")
    if not isinstance(build, str) or re.fullmatch(r"[0-9]+", build) is None:
        raise ValueError("CFBundleVersion must be a non-negative integer string")
    updated_plist = dict(plist, CFBundleShortVersionString=arguments.version, CFBundleVersion=str(int(build) + 1))
    if plist_bytes.startswith(b"bplist"):
        updated_bytes = plistlib.dumps(updated_plist, fmt=plistlib.FMT_BINARY, sort_keys=False)
    else:
        text = plist_bytes.decode("utf-8")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            text = replace_one(r"(<key>\s*" + key + r"\s*</key>\s*<string>)[^<]*(</string>)",
                               updated_plist[key], text, key)
        updated_bytes = text.encode("utf-8")
        if plistlib.loads(updated_bytes) != updated_plist:
            raise ValueError("updated plist failed round-trip validation")
    updated_props = replace_one(r"(<Version(?:\s[^>]*)?>)[^<]*(</Version>)", arguments.version,
                                props_text, "Version element").encode("utf-8")
    ET.fromstring(updated_props)

    staged = []
    try:
        for path, data in ((plist_path, updated_bytes), (props_path, updated_props)):
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".version-", delete=False) as output:
                temporary = Path(output.name)
                staged.append((temporary, path))
                output.write(data)
            temporary.chmod(stat.S_IMODE(path.stat().st_mode))
        for temporary, path in staged:
            os.replace(temporary, path)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)
    print(f"set version {arguments.version}, macOS build {updated_plist['CFBundleVersion']}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, plistlib.InvalidFileException, ET.ParseError) as error:
        print(f"version: {error}", file=sys.stderr)
        sys.exit(1)
