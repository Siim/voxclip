#!/usr/bin/env python3
"""Flatten the separately pinned, test-only FFmpeg tools for native tests."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
from urllib.request import urlopen
import zipfile


ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / "apps/windows/build/ffmpeg.json"
CACHE = Path.home() / "Library/Caches/voxclip-ffmpeg-build/test-tools"
MINIMUM_FREE = 15 * 1024 ** 3
TOOLS = ("avdevice-63.dll", "ffmpeg.exe", "ffprobe.exe")


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def disk_guard(path):
    path.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(path).free < MINIMUM_FREE:
        raise RuntimeError("STOP: fewer than 15 GiB free")


def fetch(archive, pin):
    if archive.exists():
        if sha256(archive) != pin["sha256"]:
            raise RuntimeError("Existing test-only archive fails its SHA-256 pin")
        return
    with tempfile.NamedTemporaryFile(dir=archive.parent, delete=False) as temporary:
        pending = Path(temporary.name)
        try:
            with urlopen(pin["url"], timeout=60) as source:
                shutil.copyfileobj(source, temporary)
            temporary.flush()
            if sha256(pending) != pin["sha256"]:
                raise RuntimeError("Downloaded test-only archive fails its SHA-256 pin")
            disk_guard(archive.parent)
            pending.replace(archive)
        finally:
            pending.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rid", choices=("win-x64", "win-arm64"), required=True)
    parser.add_argument("--archive", type=Path, help="existing original BtbN ZIP")
    parser.add_argument("--cache", type=Path, default=CACHE)
    args = parser.parse_args()
    manifest = json.loads(PIN.read_text())
    pin = manifest["testTools"][args.rid]
    if pin["purpose"] != "TEST ONLY; never ship":
        raise RuntimeError("Test-only purpose marker is missing")
    disk_guard(args.cache)
    archive = args.archive or args.cache / (args.rid + "-original.zip")
    if args.archive:
        if sha256(archive) != pin["sha256"]:
            raise RuntimeError("Supplied test-only archive fails its SHA-256 pin")
    else:
        fetch(archive, pin)
    disk_guard(args.cache)
    names = tuple(f"{library}-{major}.dll" for library, major in
                  manifest["libraryMajors"].items()) + TOOLS
    output = args.cache / f"voxclip-ffmpeg-test-only-{args.rid}.zip"
    with zipfile.ZipFile(archive) as original:
        members = {}
        for name in names:
            matches = [entry for entry in original.infolist()
                       if entry.filename.endswith("/bin/" + name)]
            if len(matches) != 1 or matches[0].file_size > 100 * 1024 ** 2:
                raise RuntimeError("Missing, duplicate or oversized test component: " + name)
            members[name] = matches[0]
        with tempfile.NamedTemporaryFile(dir=args.cache, delete=False) as temporary:
            pending = Path(temporary.name)
        try:
            with zipfile.ZipFile(pending, "w", compression=zipfile.ZIP_STORED) as flattened:
                for name in sorted(members):
                    entry = zipfile.ZipInfo("bin/" + name, (1980, 1, 1, 0, 0, 0))
                    entry.external_attr = 0o100644 << 16
                    with original.open(members[name]) as source, flattened.open(entry, "w") as destination:
                        shutil.copyfileobj(source, destination)
            disk_guard(args.cache)
            pending.replace(output)
        finally:
            pending.unlink(missing_ok=True)
    print("TEST ONLY; never ship")
    print("Original SHA-256:", pin["sha256"])
    print("Flat ZIP:", output)
    print("Flat ZIP SHA-256:", sha256(output))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, KeyError, zipfile.BadZipFile) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
