#!/usr/bin/env python3
"""Enforce doc/media budgets without Pillow or other third-party dependencies."""
from pathlib import Path
import sys
import subprocess

STILL_LIMIT = 300_000
TEASER_LIMIT = 3_000_000
TOTAL_LIMIT = 6_000_000
ALLOWED = {'.md', '.webp', '.png', '.jpg', '.jpeg', '.svg'}


def animated_webp(path):
    with path.open('rb') as stream:
        header = stream.read(12)
        if header[:4] != b'RIFF' or header[8:] != b'WEBP':
            return False
        while chunk := stream.read(8):
            if len(chunk) < 8:
                return False
            size = int.from_bytes(chunk[4:], 'little')
            if chunk[:4] in {b'ANIM', b'ANMF'}:
                return True
            stream.seek(size + size % 2, 1)
    return False


def check(root):
    errors, total = [], 0
    root = Path(root).resolve()
    # The index is the release boundary; local masters and Finder files are irrelevant.
    tracked = subprocess.run(['git', '-C', str(root), 'ls-files', '-z', '--', '.'],
                             check=True, capture_output=True).stdout
    for path in sorted(root / name.decode('utf-8') for name in tracked.split(b'\0') if name):
        relative = path.relative_to(root)
        if path.is_symlink():
            errors.append(f'{relative}: symlinks are not allowed')
            continue
        if not path.is_file():
            continue
        size = path.stat().st_size
        total += size
        animated = path.suffix.lower() == '.webp' and animated_webp(path)
        teaser = relative.parts[0] == 'teaser' and animated
        limit = TEASER_LIMIT if teaser else STILL_LIMIT
        if path.suffix.lower() not in ALLOWED:
            errors.append(f'{relative}: masters/videos or unsupported file type')
        if animated and not teaser:
            errors.append(f'{relative}: animated WebP belongs in teaser/')
        if size > limit:
            errors.append(f'{relative}: {size} bytes exceeds {limit}')
    if total > TOTAL_LIMIT:
        errors.append(f'doc/media total {total} bytes exceeds {TOTAL_LIMIT}')
    return errors, total


if __name__ == '__main__':
    errors, total = check(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / 'doc/media')
    for error in errors:
        print(error, file=sys.stderr)
    print(f'doc/media: {total:,} / {TOTAL_LIMIT:,} bytes')
    raise SystemExit(bool(errors))
