#!/usr/bin/env python3
"""Regenerate the two synthetic Windows story fixtures with macOS VideoToolbox."""
from pathlib import Path
import subprocess


DIGITS = ('abcedf', 'bc', 'abged', 'abgcd', 'fgbc', 'afgcd', 'afgecd', 'abc', 'abcdefg', 'abfgcd')
SEGMENTS = dict(zip('abcdefg', ((0, 0, 18, 3), (15, 0, 3, 16), (15, 15, 3, 17),
                                (0, 29, 18, 3), (0, 15, 3, 17), (0, 0, 3, 16), (0, 14, 18, 3))))
ROOT = Path(__file__).resolve().parents[3]


def recording(label, width, height, background, tone, rate):
    output = ROOT / f'shared/fixtures/media/t4-recording-{label}.mp4'
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
               '-s', f'{width}x{height}', '-r', '30', '-i', '-', '-f', 'lavfi', '-i',
               f'sine=frequency={tone}:sample_rate={rate}:duration=4', '-c:v', 'h264_videotoolbox',
               '-b:v', '180k', '-c:a', 'aac', '-movflags', '+faststart', str(output)]
    with subprocess.Popen(command, stdin=subprocess.PIPE) as encoder:
        for frame in range(120):
            pixels = bytearray(background * (width * height))
            for digit, value in enumerate(f'{frame:03}'):
                for segment in DIGITS[int(value)]:
                    left, top, length, rows = SEGMENTS[segment]
                    for row in range(top + 16, top + 16 + rows):
                        start = (row * width + left + 16 + digit * 24) * 3
                        pixels[start:start + length * 3] = b'\xff' * (length * 3)
            encoder.stdin.write(pixels)
        encoder.stdin.close()
        if encoder.wait():
            raise RuntimeError(f'Could not encode {output.name}')


recording('A', 320, 180, bytes.fromhex('204069'), 397, 48000)
recording('B', 240, 320, bytes.fromhex('ca7336'), 811, 44100)
