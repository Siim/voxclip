#!/usr/bin/env python3
"""Make shared/looks/test-card.png: the synthetic picture looks are shown on before a clip's own frame is ready, or when its
source is offline (looks spec 2026-11-28, section 7 item 7). Goldens, mockups and screenshots use it too, so the
maintainer's footage is never a fixture.

The card is 256 x 256 RGB, 8 bits a channel, top to bottom:
- rows 0-79: a sky, deep blue at the top to pale at the horizon;
- rows 80-143: a skin ramp from light through the spec's mid, deep and very deep swatches (section 4.3);
- rows 144-191: sixteen neutral greys from black to white;
- rows 192-223: a saturated row of eight hues;
- rows 224-255: a dark corner (near-black ramp) on the left and the clip-grade vectors' swatches on the right.

Every value is integer arithmetic, so the pixels are the same everywhere. zlib's compressed bytes can differ between zlib
builds, so the file is rewritten only when its decoded pixels differ, and `--check` compares decoded pixels (check_drift.py
runs it). Run from anywhere.
"""
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / 'shared/looks/test-card.png'
SIZE = 256

SKY = [(52, 104, 178), (196, 222, 242)]
SKIN = [(246, 214, 192), (217, 158, 128), (168, 112, 86), (120, 78, 58), (72, 46, 34)]
HUES = [(230, 26, 26), (240, 140, 20), (240, 220, 30), (40, 180, 60), (30, 200, 210), (26, 51, 230), (130, 40, 200), (220, 40, 160)]
DARK = [(4, 4, 6), (40, 38, 36)]
# tools/fixtures/clip-render/generate_clip_grade.py SWATCHES: grey, skin, highlight, white, shadow, dull blue, deep and very deep skin.
SWATCHES = [(128, 128, 128), (217, 158, 128), (235, 235, 235), (255, 255, 255), (13, 13, 13), (102, 115, 140), (120, 78, 58), (72, 46, 34)]


def mix(a, b, numerator, denominator):
    """a + (b - a) * numerator / denominator, rounded half up, in integers."""
    return tuple((2 * (x * (denominator - numerator) + y * numerator) + denominator) // (2 * denominator) for x, y in zip(a, b))


def pixel(x, y):
    if y < 80:
        return mix(SKY[0], SKY[1], y, 79)
    if y < 144:
        span = SIZE - 1
        position = x * (len(SKIN) - 1)
        index = min(len(SKIN) - 2, position // span)
        return mix(SKIN[index], SKIN[index + 1], position - index * span, span)
    if y < 192:
        step = x // 16
        value = (2 * step * 255 + 15) // 30
        return (value, value, value)
    if y < 224:
        return HUES[x // 32]
    if x < 128:
        return mix(DARK[0], DARK[1], x, 127)
    return SWATCHES[(x - 128) // 16]


def rows():
    return [b''.join(bytes(pixel(x, y)) for x in range(SIZE)) for y in range(SIZE)]


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)


def encode(lines):
    header = struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0)
    raw = b''.join(b'\x00' + line for line in lines)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')


def decode(data):
    """The rows of an unfiltered 8-bit RGB PNG this script wrote, or None for anything else."""
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        return None
    offset, header, idat = 8, None, b''
    while offset < len(data):
        length, kind = struct.unpack('>I4s', data[offset:offset + 8])
        body = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
    if header != (SIZE, SIZE, 8, 2, 0, 0, 0):
        return None
    raw = zlib.decompress(idat)
    stride = 1 + 3 * SIZE
    lines = [raw[i * stride:(i + 1) * stride] for i in range(SIZE)]
    if len(raw) != stride * SIZE or any(line[0] != 0 for line in lines):
        return None
    return [line[1:] for line in lines]


def main(arguments):
    expected = rows()
    current = decode(DESTINATION.read_bytes()) if DESTINATION.exists() else None
    if '--check' in arguments:
        if current != expected:
            print(f'::error::{DESTINATION.relative_to(ROOT)} differs from tools/looks/make_test_card.py; run it and commit the file')
            return 1
        print(f'{DESTINATION.relative_to(ROOT)}: pixels identical')
        return 0
    if current != expected:
        DESTINATION.write_bytes(encode(expected))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
