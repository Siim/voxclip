#!/usr/bin/env python3
"""Generate shared/fixtures/voice-lab/tilt-cases.json: the tone-match vectors (voice-lab.md section 8.7 item 2b).

An independent pure-Python reference of VoiceLabTilt (Mac Core): the band measurement over voiced Hann frames, the slope
and the clamped, stepped tilt, and the three-shelf filter cascade pivoted at 1 kHz with its magnitude and its outputs.
Inputs are integer LCG noise scaled by powers of two, so every input sample is exact in Float32 on every platform. The
coefficients and FFT twiddles use libm (tan, pow, cos, sin, log10), so check_drift.py compares this file within its float
tolerance. Two runs give byte-identical output. Run from anywhere: python3 tools/fixtures/voice-lab/generate_tilt.py
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/tilt-cases.json'

MAXIMUM = 2.0
STEP = 0.1
PIVOT = 1000.0
SHELVES = [250.0, 1000.0, 4000.0]
BANDS = list(range(-10, 10))
VOICED = 10 ** (-45.0 / 20)
MINIMUM_BANDS = 4
NEIGHBOURHOOD = 3.0


def js_round(value):
    return math.floor(value + 0.5)


# Signals: integer LCG noise, exact in Float32.

def noise(seed, count, shift=0):
    """x(n+1) = (1664525 x(n) + 1013904223) mod 2^32; sample n is (x(n+1) >> 16) / 2^15 - 1, times 2^-shift."""
    state = seed
    result = []
    for _ in range(count):
        state = (1664525 * state + 1013904223) % 2 ** 32
        result.append(((state >> 16) / 32768.0 - 1.0) * 2.0 ** -shift)
    return result


def render(signal):
    """A signal is {"seed", "samples", "shape", "shift", "quiet"}: white noise, its first difference halved ("bright"),
    (x[n] + x[n-1] / 2) / 2 ("warm") or the mean of four consecutive samples ("dark"); "quiet" ranges are scaled by
    2^-12, below the voiced floor."""
    base = noise(signal['seed'], signal['samples'] + 3, signal.get('shift', 0))
    shape = signal.get('shape', 'white')
    if shape == 'white':
        values = base[3:]
    elif shape == 'bright':
        values = [(base[n + 3] - base[n + 2]) / 2 for n in range(signal['samples'])]
    elif shape == 'warm':
        values = [(base[n + 3] + base[n + 2] / 2) / 2 for n in range(signal['samples'])]
    elif shape == 'dark':
        values = [(base[n] + base[n + 1] + base[n + 2] + base[n + 3]) / 4 for n in range(signal['samples'])]
    else:
        raise ValueError(shape)
    for start, end in signal.get('quiet', []):
        for n in range(start, end):
            values[n] *= 2.0 ** -12
    return values


# Measurement.

def frame_size(rate):
    size = 1
    while size < rate * 0.04:
        size *= 2
    return size


def bins(index, rate, size):
    centre = PIVOT * 2 ** (index / 3)
    lower, upper = centre * 2 ** (-1 / 6), centre * 2 ** (1 / 6)
    if upper > rate / 2:
        return range(0)
    spacing = rate / size
    first = 1
    while first < size // 2 and first * spacing < lower:
        first += 1
    end = first
    while end < size // 2 and end * spacing < upper:
        end += 1
    return range(first, end)


def fft(real, imaginary):
    count = len(real)
    j = 0
    for i in range(1, count):
        bit = count >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            real[i], real[j] = real[j], real[i]
            imaginary[i], imaginary[j] = imaginary[j], imaginary[i]
    length = 2
    while length <= count:
        half = length // 2
        for offset in range(half):
            angle = -2 * math.pi * offset / length
            wr, wi = math.cos(angle), math.sin(angle)
            for start in range(0, count, length):
                a, b = start + offset, start + offset + half
                tr = wr * real[b] - wi * imaginary[b]
                ti = wr * imaginary[b] + wi * real[b]
                real[b], imaginary[b] = real[a] - tr, imaginary[a] - ti
                real[a], imaginary[a] = real[a] + tr, imaginary[a] + ti
        length *= 2


def bands(sides, rate):
    size = frame_size(rate)
    ranges = [bins(index, rate, size) for index in BANDS]
    power = [None if len(r) == 0 else 0.0 for r in ranges]
    frames = 0
    window = [0.5 - 0.5 * math.cos(2 * math.pi * n / size) for n in range(size)]
    for side in sides:
        start = 0
        while len(side) - start >= size:
            energy = 0.0
            for n in range(size):
                energy += side[start + n] * side[start + n]
            if math.sqrt(energy / size) > VOICED:
                real = [side[start + n] * window[n] for n in range(size)]
                imaginary = [0.0] * size
                fft(real, imaginary)
                for band, r in enumerate(ranges):
                    if len(r) == 0:
                        continue
                    total = 0.0
                    for k in r:
                        total += real[k] * real[k] + imaginary[k] * imaginary[k]
                    power[band] += total
                frames += 1
            start += size // 2
    return {'sampleRate': rate, 'frameSize': size, 'power': power, 'frames': frames}


def levels(measured):
    """Each band's mean power per bin and frame in dB, or None."""
    result = []
    for band, index in enumerate(BANDS):
        power = measured['power'][band]
        count = len(bins(index, measured['sampleRate'], measured['frameSize']))
        result.append(None if power is None or power <= 0 or measured['frames'] == 0
                      else 10 * math.log10(power / (count * measured['frames'])))
    return result


def slope(measured, other):
    if measured['frames'] == 0:
        return None
    points = []
    for band, index in enumerate(BANDS):
        power, theirs = measured['power'][band], other['power'][band]
        if power is None or theirs is None or power <= 0 or theirs <= 0:
            continue
        count = len(bins(index, measured['sampleRate'], measured['frameSize']))
        points.append((index / 3, 10 * math.log10(power / (count * measured['frames']))))
    if len(points) < MINIMUM_BANDS:
        return None
    mean_x = sum(p[0] for p in points) / len(points)
    mean_y = sum(p[1] for p in points) / len(points)
    covariance = variance = 0.0
    for x, y in points:
        covariance += (x - mean_x) * (y - mean_y)
        variance += (x - mean_x) * (x - mean_x)
    return covariance / variance if variance > 0 else None


def match(source, take):
    target, current = slope(source, take), slope(take, source)
    if target is None or current is None:
        return None, target, current
    clamped = min(max(target - current, -MAXIMUM), MAXIMUM)
    ratio = clamped / STEP
    # Round half away from zero; no case lies within 0.01 of a half step.
    stepped = math.copysign(math.floor(abs(ratio) + 0.5), ratio) * STEP
    assert abs(abs(ratio) - math.floor(abs(ratio)) - 0.5) > 0.01, ratio
    value = round(stepped * 10) / 10
    return (None if value == 0 else value), target, current


# The filter.

def sections(tilt, rate):
    if not math.isfinite(tilt) or tilt == 0:
        return []
    clamped = min(max(tilt, -MAXIMUM), MAXIMUM)
    result = []
    for frequency in SHELVES:
        if frequency >= 0.45 * rate:
            continue
        gain = 10 ** (2 * clamped / 20)
        root = math.sqrt(gain)
        k = math.tan(math.pi * frequency / rate)
        a0 = 1 + k * root
        result.append([gain * (1 + k / root) / a0, gain * (k / root - 1) / a0, (k * root - 1) / a0])
    if not result:
        return []
    pivot = magnitude(result, PIVOT, rate)
    result[0] = [result[0][0] / pivot, result[0][1] / pivot, result[0][2]]
    return result


def magnitude(cascade, hertz, rate):
    omega = 2 * math.pi * hertz / rate
    c = math.cos(omega)
    value = 1.0
    for b0, b1, a1 in cascade:
        numerator = b0 * b0 + b1 * b1 + 2 * b0 * b1 * c
        denominator = 1 + a1 * a1 + 2 * a1 * c
        value *= math.sqrt(numerator / denominator)
    return value


def run(cascade, samples):
    inputs = [0.0] * len(cascade)
    outputs = [0.0] * len(cascade)
    result = []
    for sample in samples:
        value = sample
        for index, (b0, b1, a1) in enumerate(cascade):
            y = b0 * value + b1 * inputs[index] - a1 * outputs[index]
            inputs[index], outputs[index] = value, y
            value = y
        result.append(value)
    return result


def main():
    cases = []
    for rate in [8000, 16000, 22050, 24000, 44100, 48000, 96000]:
        cases.append({'kind': 'frameSize', 'name': f'frame-size-{rate}', 'sampleRate': rate,
                      'expected': {'frameSize': frame_size(rate),
                                   'bins': [[r.start, r.stop] if len(r) else None for r in
                                            (bins(index, rate, frame_size(rate)) for index in BANDS)]}})
    probe = [100, 250, 500, 1000, 2000, 4000, 8000, 11000]
    for tilt, rate in [(2.0, 24000), (-2.0, 24000), (1.0, 48000), (-0.3, 44100), (0.1, 16000), (1.5, 8000), (2.5, 24000), (-7.0, 48000)]:
        cascade = sections(tilt, rate)
        cases.append({'kind': 'sections', 'name': f'sections-{tilt:+g}-{rate}', 'tiltDbPerOctave': tilt, 'sampleRate': rate,
                      'expected': {'sections': cascade,
                                   'magnitudeDb': [[hz, 20 * math.log10(magnitude(cascade, hz, rate))] for hz in probe if hz < rate / 2]}})
    cases.append({'kind': 'sections', 'name': 'sections-zero-24000', 'tiltDbPerOctave': 0.0, 'sampleRate': 24000,
                  'expected': {'sections': [], 'magnitudeDb': []}})
    impulse = [1.0] + [0.0] * 31
    for tilt, rate in [(1.5, 24000), (-2.0, 48000)]:
        cases.append({'kind': 'filter', 'name': f'impulse-{tilt:+g}-{rate}', 'tiltDbPerOctave': tilt, 'sampleRate': rate,
                      'input': {'impulse': len(impulse)}, 'expected': {'output': run(sections(tilt, rate), impulse)}})
    signal = {'seed': 7, 'samples': 480, 'shape': 'white', 'shift': 2}
    for tilt, rate in [(1.0, 24000), (-1.2, 24000)]:
        cases.append({'kind': 'filter', 'name': f'noise-{tilt:+g}-{rate}', 'tiltDbPerOctave': tilt, 'sampleRate': rate,
                      'input': {'signal': signal}, 'expected': {'output': run(sections(tilt, rate), render(signal))}})
    measured = [
        ('white-48000', {'seed': 1, 'samples': 24000, 'shape': 'white', 'shift': 2}, 48000),
        ('bright-48000', {'seed': 2, 'samples': 24000, 'shape': 'bright', 'shift': 2}, 48000),
        ('dark-24000', {'seed': 3, 'samples': 12000, 'shape': 'dark', 'shift': 2}, 24000),
        ('warm-24000', {'seed': 6, 'samples': 12000, 'shape': 'warm', 'shift': 2}, 24000),
        ('quiet-gated-16000', {'seed': 4, 'samples': 16000, 'shape': 'white', 'shift': 2, 'quiet': [[0, 8000]]}, 16000),
        ('all-quiet-16000', {'seed': 5, 'samples': 8000, 'shape': 'white', 'shift': 2, 'quiet': [[0, 8000]]}, 16000),
    ]
    rendered = {}
    for name, signal, rate in measured:
        result = bands([render(signal)], rate)
        rendered[name] = result
        cases.append({'kind': 'bands', 'name': f'bands-{name}', 'sampleRate': rate, 'input': {'signal': signal},
                      'expected': {'frames': result['frames'], 'levelsDb': levels(result), 'slopeDbPerOctave': slope(result, result)}})
    for source, take in [('white-48000', 'warm-24000'), ('warm-24000', 'white-48000'), ('white-48000', 'dark-24000'), ('dark-24000', 'white-48000'), ('white-48000', 'bright-48000'),
                         ('bright-48000', 'white-48000'), ('white-48000', 'quiet-gated-16000'), ('white-48000', 'all-quiet-16000')]:
        tilt, target, current = match(rendered[source], rendered[take])
        cases.append({'kind': 'match', 'name': f'match-{source}-to-{take}', 'source': f'bands-{source}', 'take': f'bands-{take}',
                      'expected': {'tiltDbPerOctave': tilt, 'sourceSlope': target, 'takeSlope': current}})
    # The speech beside a window: up to 3 s each side, framed on its own grid, the window excluded.
    neighbour = {'seed': 9, 'samples': 16000 * 8, 'shape': 'white', 'shift': 2, 'quiet': [[16000 * 3, 16000 * 5]]}
    samples = render(neighbour)
    window = [16000 * 4, 16000 * 5]
    reach = min(js_round(NEIGHBOURHOOD * 16000), len(samples))
    sides = [samples[max(0, window[0] - reach):window[0]], samples[window[1]:min(len(samples), window[1] + reach)]]
    result = bands(sides, 16000)
    cases.append({'kind': 'neighbourhood', 'name': 'neighbourhood-16000', 'sampleRate': 16000, 'input': {'signal': neighbour, 'window': window},
                  'expected': {'frames': result['frames'], 'levelsDb': levels(result)}})
    document = {
        'schema': 'voxclip-voice-lab-tilt/1',
        'description': 'The tone match (doc/spec/voice-lab.md section 8.7 item 2b): band levels over voiced Hann frames, the slope, '
                       'the clamped tilt in 0.1 dB/octave steps, and the three-shelf cascade pivoted at 1 kHz. '
                       'Generated by tools/fixtures/voice-lab/generate_tilt.py; see tilt-README.md.',
        'constants': {'maximumDbPerOctave': MAXIMUM, 'stepDbPerOctave': STEP, 'pivotHz': PIVOT, 'shelfHz': SHELVES,
                      'bandIndices': BANDS, 'voicedRmsDb': -45.0, 'minimumBands': MINIMUM_BANDS, 'neighbourhoodSeconds': NEIGHBOURHOOD},
        'tolerances': {'coefficient': 1e-12, 'magnitudeDb': 1e-9, 'output': 1e-12, 'levelDb': 1e-9, 'slope': 1e-9},
        'caseCount': len(cases),
        'cases': cases,
    }
    OUT.write_text(json.dumps(document, indent=1) + '\n')


if __name__ == '__main__':
    main()
