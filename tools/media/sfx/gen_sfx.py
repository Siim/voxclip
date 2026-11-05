#!/usr/bin/env python3
"""Synthesize VoxClip's bundled sound effects (doc/spec/ai.md section 18.5): shared/data/sfx/{whoosh,pop,ding}.wav.

Made from nothing but arithmetic in this file (no samples, no recordings), so they are VoxClip's own work, dedicated to
the public domain under CC0 1.0 (shared/data/sfx/LICENSE.txt). 48 kHz mono 16-bit PCM, peak -6 dBFS, 5 ms edge fades.
The lengths must match AskClaudeValidator.soundSeconds in the Swift Core. Deterministic: a fixed-seed LCG drives the
noise, and the WAV header carries no date. Run from anywhere; `--check` exits 1 when a committed file differs.
"""
import math
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/data/sfx'
RATE = 48_000
PEAK = 10 ** (-6 / 20)
LENGTHS = {'whoosh': 0.45, 'pop': 0.12, 'ding': 0.8}


def lcg(seed):
    state = seed
    while True:
        state = (1103515245 * state + 12345) % (1 << 31)
        yield state / (1 << 30) - 1.0


def whoosh(frames):
    noise, low, out = lcg(7), 0.0, []
    for index in range(frames):
        t = index / frames
        cutoff = 0.02 + 0.25 * math.sin(math.pi * t) ** 2  # A one-pole low-pass swept up and down.
        low += cutoff * (next(noise) - low)
        out.append(low * math.sin(math.pi * t) ** 1.5)
    return out


def pop(frames):
    out = []
    for index in range(frames):
        t = index / RATE
        frequency = 900 * math.exp(-t * 30) + 180
        out.append(math.sin(2 * math.pi * frequency * t) * math.exp(-t * 45))
    return out


def ding(frames):
    out = []
    for index in range(frames):
        t = index / RATE
        tone = math.sin(2 * math.pi * 1318.5 * t) + 0.35 * math.sin(2 * math.pi * 2637 * t) + 0.12 * math.sin(2 * math.pi * 3955.5 * t)
        out.append(tone * math.exp(-t * 5.5))
    return out


def render(name):
    frames = round(LENGTHS[name] * RATE)
    samples = {'whoosh': whoosh, 'pop': pop, 'ding': ding}[name](frames)
    fade = round(0.005 * RATE)
    for index in range(fade):
        gain = index / fade
        samples[index] *= gain
        samples[frames - 1 - index] *= gain
    peak = max(abs(value) for value in samples) or 1
    pcm = b''.join(struct.pack('<h', max(-32768, min(32767, round(value / peak * PEAK * 32767)))) for value in samples)
    header = b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, RATE, RATE * 2, 2, 16)
    return header + b'data' + struct.pack('<I', len(pcm)) + pcm


def main():
    check = '--check' in sys.argv[1:]
    DESTINATION.mkdir(parents=True, exist_ok=True)
    stale = []
    for name in LENGTHS:
        data, path = render(name), DESTINATION / f'{name}.wav'
        if check:
            if not path.exists() or path.read_bytes() != data:
                stale.append(path.name)
        else:
            path.write_bytes(data)
    if stale:
        print('Stale bundled sounds: ' + ', '.join(stale))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
