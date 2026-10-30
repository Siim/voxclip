import hashlib
import json
import math
import struct
from pathlib import Path


def header(pcm, rate, channels, bits, floating):
    stride = channels * bits // 8
    return struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 36 + len(pcm) + len(pcm) % 2,
                       b'WAVE', b'fmt ', 16, 3 if floating else 1, channels, rate,
                       rate * stride, stride, bits, b'data', len(pcm))


def encode(value, bits, floating):
    if floating:
        return struct.pack('<f' if bits == 32 else '<d', value)
    scale = 2 ** (bits - 1)
    sample = max(-scale, min(scale - 1, round(value * scale)))
    return sample.to_bytes(bits // 8, 'little', signed=True)


def vector(name, kind, bits=16, channels=1, floating=False):
    rate = 24000
    values = []
    for frame in range(21600):
        row = []
        for channel in range(channels):
            base = (frame * 17 + channel * 13) % 127 - 63
            if any(start <= frame < end for start, end in [(2300, 2600), (4800, 6000), (14400, 15600), (19000, 19300)]):
                base += 18000
            row.append(base / 32768)
        values.append(row)
    edits = []
    incoming = outgoing = 0
    residual = 0
    if kind == 'pads-remove':
        edits = [{'kind': 'remove', 'start': 9000, 'count': 480}]
        incoming = outgoing = 240
    elif kind == 'balanced':
        edits = [{'kind': 'remove', 'start': 9000, 'count': 480}, {'kind': 'insert', 'start': 11400, 'count': 480}]
    elif kind == 'changed':
        edits = [{'kind': 'insert', 'start': 9000, 'count': 1200}]
        residual = 0.05
    elif kind == 'pads':
        incoming = outgoing = 240
        residual = 0.02
    elif kind == 'borrowed':
        incoming = 480
    paid_pcm = b''.join(encode(value, bits, floating) for row in values for value in row)
    paid = header(paid_pcm, rate, channels, bits, floating) + paid_pcm + b'\0' * (len(paid_pcm) % 2)
    derived = bool(edits or incoming or outgoing)
    handle = 240
    output = [[0] * channels for _ in range(handle if incoming else 0)] if incoming else values[2400 - handle:2400]
    output = list(output) + [[0] * channels for _ in range(incoming)]
    cursor = 2400
    joins = []
    for edit in edits:
        start, count = edit['start'], edit['count']
        end = start + count
        output += values[cursor:start]
        if edit['kind'] == 'insert':
            output += values[start:end]
            joins.append((len(output), end, start))
            output += values[start:end]
        else:
            joins.append((len(output), start, end))
        cursor = end
    output += values[cursor:19200]
    output += [[0] * channels for _ in range(outgoing)]
    body_frames = len(output) - handle
    output += [[0] * channels for _ in range(handle)] if outgoing else values[19200:19200 + handle]
    for position, left, right in joins:
        for offset in range(480):
            local = offset - 240
            phase = offset / 479
            row = []
            for channel in range(channels):
                left_sample = values[left + local][channel] * math.cos(math.pi * phase / 2)
                right_sample = values[right + local][channel] * math.sin(math.pi * phase / 2)
                row.append(left_sample + right_sample)
            output[position + local] = row
    fitted_pcm = b''.join(encode(value, bits, floating) for row in output for value in row)
    fitted = header(fitted_pcm, rate, channels, bits, floating) + fitted_pcm + b'\0' * (len(fitted_pcm) % 2)
    return dict(name=name, rate=rate, channels=channels, bits=bits, floating=floating, kind=kind,
                incomingPadFrames=incoming, outgoingPadFrames=outgoing, edits=edits, residualSeconds=residual,
                windowStart=2.48 if kind == 'borrowed' else 2.5, windowEnd=3.2,
                expected=dict(paidSHA256=hashlib.sha256(paid).hexdigest(),
                              fittedSHA256=hashlib.sha256(fitted if derived else paid).hexdigest(),
                              outputFrames=body_frames, trimStartFrame=handle if derived else 2400,
                              trimEndFrame=handle + body_frames if derived else 19200))


def vectors():
    cases = [vector('pads-and-removal', 'pads-remove'), vector('balanced-edits', 'balanced'),
             vector('unchanged-paid', 'none'), vector('partial-insertion', 'changed'),
             vector('pads-only', 'pads'), vector('stereo-pcm24', 'balanced', 24, 2),
             vector('borrowed-window', 'borrowed'),
             vector('stereo-pcm32', 'balanced', 32, 2), vector('stereo-float32', 'balanced', 32, 2, True),
             vector('mono-float64', 'pads', 64, 1, True)]
    return dict(schema='voxclip-fitted-asset-cases/1', cases=cases)


def main():
    root = Path(__file__).resolve().parents[2]
    target = root / 'shared/fixtures/voice-lab/fitted-asset-cases.json'
    target.write_text(json.dumps(vectors(), indent=2) + '\n')


if __name__ == '__main__':
    main()
