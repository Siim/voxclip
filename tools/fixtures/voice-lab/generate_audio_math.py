#!/usr/bin/env python3
"""Write shared/fixtures/voice-lab/audio-math-cases.json, the shared Voice Lab audio math vectors.

This is an independent NumPy reference of voice-lab.md §4.4, §7.3, §8.6, §8.7 item 2 and §8.11 items 2 and 3,
with the rules that shared/fixtures/voice-lab/audio-math-README.md records. Signals are stored as parameters,
never as samples, and every case records what the reference measured. The app tests read the JSON and never run
this script.
"""
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/audio-math-cases.json'

VOICED_FRAME_DBFS = -45.0
GAIN_CLAMP_DB = 12.0
LOUDNESS_NEIGHBOURHOOD_SECONDS = 3.0
TRUE_PEAK_LIMIT_DBTP = -1.0
MOMENTARY_SECONDS = 0.4
MINIMUM_SEAM_WINDOW_SECONDS = 0.1
SILENCE_GATE_LUFS = -70.0
FLATNESS_STEP_SECONDS = 0.1
FLATNESS_STDEV_SCALE = 6.0
CONFORM_TOLERANCE_SECONDS = 0.020
CORRELATION_FLOOR = 0.5
# K-weighting follows libebur128's derivation (MIT); no code is copied. With this exponent on Vh and the high-pass
# numerator left unnormalised, the bilinear transform reproduces the published 48 kHz coefficients.
SHELF_MID_BAND_EXPONENT = 0.4996667741545416
HIGH_PASS_NUMERATOR = [1.0, -2.0, 1.0]

# ITU-R BS.1770-4 (10/2015), Annex 2, the 48-tap 4-phase FIR interpolating filter.
TRUE_PEAK_PHASES = [
    [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
     0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
    [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
     0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
    [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
     0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
    [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
     0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
]


class MeasurementError(Exception):
    pass


def js_round(value):
    lower = math.floor(value)
    return int(lower + 1 if value - lower >= 0.5 else lower)


def samples(seconds, rate):
    return js_round(seconds * rate)


def frame_length(rate):
    return js_round(rate * 0.01)


def amplitude_db(value):
    return 20.0 * math.log10(value) if value > 0 else None


def sequential_sum(values):
    return float(np.cumsum(values)[-1]) if len(values) else 0.0


# Signals --------------------------------------------------------------------------------------------------------

def sine(frequency, peak_dbfs, count, phase=0.0):
    return {'type': 'sine', 'samples': count, 'frequency': frequency, 'peakDbfs': peak_dbfs, 'phase': phase}


def silence(count):
    return {'type': 'silence', 'samples': count}


def noise(seed, peak_dbfs, count):
    return {'type': 'noise', 'samples': count, 'seed': seed, 'peakDbfs': peak_dbfs}


def signal(rate, parts, gain_db=0.0):
    value = {'rate': rate, 'parts': parts}
    if gain_db:
        value['gainDb'] = gain_db
    return value


def lcg(seed, count):
    values = np.empty(count, dtype=np.float64)
    state = seed
    for index in range(count):
        state = (1664525 * state + 1013904223) % 4294967296
        values[index] = state / 2147483648.0 - 1.0
    return values


def render(value):
    rate = value['rate']
    gain = 10.0 ** (value.get('gainDb', 0.0) / 20.0)
    pieces = []
    for part in value['parts']:
        count = part['samples']
        if part['type'] == 'silence':
            piece = np.zeros(count, dtype=np.float64)
        elif part['type'] == 'sine':
            amplitude = 10.0 ** (part['peakDbfs'] / 20.0)
            index = np.arange(count, dtype=np.float64)
            piece = amplitude * np.sin(2.0 * math.pi * part['frequency'] * index / rate + part['phase'])
        elif part['type'] == 'noise':
            piece = 10.0 ** (part['peakDbfs'] / 20.0) * lcg(part['seed'], count)
        else:
            raise ValueError(part['type'])
        pieces.append(piece * gain)
    return np.concatenate(pieces).astype(np.float32) if pieces else np.zeros(0, dtype=np.float32)


# Decision 1 and 2: voiced frames and the static level gain -------------------------------------------------------

def voiced_frame_sums(x, rate):
    """The sum of squares of each voiced frame of x, framed from its first sample."""
    size = frame_length(rate)
    frames = len(x) // size
    wide = x[:frames * size].astype(np.float64)
    sums = np.cumsum((wide * wide).reshape(frames, size), axis=1)[:, -1]
    return sums[np.sqrt(sums / size) > 10.0 ** (VOICED_FRAME_DBFS / 20.0)]


def voiced_level_db(sums, rate):
    if len(sums) == 0:
        return None
    return 20.0 * math.log10(math.sqrt(sequential_sum(sums) / (len(sums) * frame_length(rate))))


def voiced_rms_db(x, rate):
    return voiced_level_db(voiced_frame_sums(x, rate), rate)


def neighbourhood_voiced_rms_db(x, rate, start, end):
    """§8.7 item 2: the voiced frames within LOUDNESS_NEIGHBOURHOOD before and after the window, which is excluded.
    Each side is clamped to the take and framed on its own grid; the voiced frames of both pool into one mean square."""
    reach = samples(LOUDNESS_NEIGHBOURHOOD_SECONDS, rate)
    before = voiced_frame_sums(x[max(0, start - reach):start], rate)
    after = voiced_frame_sums(x[end:min(len(x), end + reach)], rate)
    level = voiced_level_db(np.concatenate([before, after]), rate)
    if level is None:
        raise MeasurementError('noVoicedAudio')
    return level


def level_gain_db(source_db, candidate_db, candidate_true_peak):
    if source_db is None or candidate_db is None:
        raise MeasurementError('noVoicedAudio')
    gain = min(max(source_db - candidate_db, -GAIN_CLAMP_DB), GAIN_CLAMP_DB)
    return min(gain, TRUE_PEAK_LIMIT_DBTP - candidate_true_peak)


# Decision 3: sample and true peak --------------------------------------------------------------------------------

def sample_peak_dbfs(x):
    return amplitude_db(float(np.max(np.abs(x)))) if len(x) else None


def oversampling(rate):
    return 4 if rate < 96000 else 2 if rate < 192000 else 1


def true_peak_dbtp(x, rate):
    factor = oversampling(rate)
    wide = x.astype(np.float64)
    if factor == 1 or len(x) == 0:
        return amplitude_db(float(np.max(np.abs(wide)))) if len(x) else None
    # Annex 2 publishes only the 4× filter, so 2× takes its even phases. The buffer is silent outside its bounds, so
    # every output of the full convolution counts, edge ringing included. No phase lands on an input sample, so the
    # true peak is the larger of the interpolated and the sample peak. Each choice can only lower the gain cap.
    padded = np.concatenate([np.zeros(11), wide, np.zeros(11)])
    count = len(x) + 11
    peak = float(np.max(np.abs(wide)))
    for phase in ([0, 1, 2, 3] if factor == 4 else [0, 2]):
        output = np.zeros(count)
        for tap, coefficient in enumerate(TRUE_PEAK_PHASES[phase]):
            output = output + coefficient * padded[11 - tap:11 - tap + count]
        peak = max(peak, float(np.max(np.abs(output))))
    return amplitude_db(peak)


# Decision 4: K-weighting and momentary loudness ------------------------------------------------------------------

def k_weighting(rate):
    f0, gain_db, q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    k = math.tan(math.pi * f0 / rate)
    vh = 10.0 ** (gain_db / 20.0)
    vb = vh ** SHELF_MID_BAND_EXPONENT
    a0 = 1.0 + k / q + k * k
    shelf = [(vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
             2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0]
    f0, q = 38.13547087602444, 0.5003270373238773
    k = math.tan(math.pi * f0 / rate)
    a0 = 1.0 + k / q + k * k
    high_pass = HIGH_PASS_NUMERATOR + [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0]
    return shelf, high_pass


def biquad(values, coefficients):
    b0, b1, b2, a1, a2 = coefficients
    x1 = x2 = y1 = y2 = 0.0
    output = [0.0] * len(values)
    for index, x in enumerate(values):
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x, y1, y
        output[index] = y
    return output


def k_weighted(x, rate):
    shelf, high_pass = k_weighting(rate)
    return np.array(biquad(biquad(x.astype(np.float64).tolist(), shelf), high_pass), dtype=np.float64)


def loudness(weighted, start, end):
    mean_square = sequential_sum(weighted[start:end] * weighted[start:end]) / (end - start)
    return -0.691 + 10.0 * math.log10(mean_square) if mean_square > 0 else -math.inf


def momentary_lufs(x, rate, window_start):
    window = samples(MOMENTARY_SECONDS, rate)
    if window_start < 0 or window_start + window > len(x):
        raise MeasurementError('invalidInput')
    return loudness(k_weighted(x[:window_start + window], rate), window_start, window_start + window)


# Decision 5: seam jump --------------------------------------------------------------------------------------------

def seam_jumps(x, rate, seams):
    weighted = k_weighted(x, rate)
    window = samples(MOMENTARY_SECONDS, rate)
    minimum = samples(MINIMUM_SEAM_WINDOW_SECONDS, rate)
    jumps = []
    for seam in seams:
        if seam < 0 or seam > len(x):
            raise MeasurementError('invalidInput')
        before_start, after_end = max(0, seam - window), min(len(x), seam + window)
        if seam - before_start < minimum or after_end - seam < minimum:
            raise MeasurementError('insufficientContext')
        before, after = loudness(weighted, before_start, seam), loudness(weighted, seam, after_end)
        # Lead decision: each window is floored at the -70 LUFS gate, so the jump is always finite.
        jumps.append(abs(max(after, SILENCE_GATE_LUFS) - max(before, SILENCE_GATE_LUFS)))
    return jumps


# Decision 6: flatness ---------------------------------------------------------------------------------------------

def flatness(x, rate):
    weighted = k_weighted(x, rate)
    window, step = samples(MOMENTARY_SECONDS, rate), samples(FLATNESS_STEP_SECONDS, rate)
    values = []
    start = 0
    while start + window <= len(x):
        value = loudness(weighted, start, start + window)
        if value >= SILENCE_GATE_LUFS:
            values.append(value)
        start += step
    if len(values) < 2:
        return len(values), 0.0, 1.0
    levels = np.array(values)
    mean = sequential_sum(levels) / len(values)
    stdev = math.sqrt(sequential_sum((levels - mean) * (levels - mean)) / len(values))
    return len(values), stdev, 1.0 - min(1.0, stdev / FLATNESS_STDEV_SCALE)


# Decision 7: conform ----------------------------------------------------------------------------------------------

def envelope(x, rate):
    size = frame_length(rate)
    frames = len(x) // size
    if frames == 0:
        return np.zeros(0, dtype=np.float32)
    wide = x[:frames * size].astype(np.float64)
    sums = np.cumsum((wide * wide).reshape(frames, size), axis=1)[:, -1]
    return np.sqrt(sums / size).astype(np.float32)


def correlation(a, b, lag):
    start, end = max(0, -lag), min(len(a), len(b) - lag)
    count = end - start
    # Lead decision: an overlap shorter than half the shorter envelope scores 0, because two frames correlate ±1 by
    # construction, and no score exceeds 1.
    if count <= 0 or count < (min(len(a), len(b)) + 1) // 2:
        return 0.0
    left = a[start:end].astype(np.float64)
    right = b[start + lag:end + lag].astype(np.float64)
    left = left - sequential_sum(left) / count
    right = right - sequential_sum(right) / count
    cross, left_energy, right_energy = (sequential_sum(left * right), sequential_sum(left * left),
                                        sequential_sum(right * right))
    if not (left_energy > 0 and right_energy > 0):
        return 0.0
    return min(1.0, cross / math.sqrt(left_energy * right_energy))


def conform(input_levels, output_levels, input_samples, output_samples, rate, search_seconds):
    size = frame_length(rate)
    if len(input_levels) != input_samples // size or len(output_levels) != output_samples // size:
        raise MeasurementError('invalidInput')
    tolerance = samples(CONFORM_TOLERANCE_SECONDS, rate)
    delta = output_samples - input_samples
    if abs(delta) <= tolerance:
        return {'kind': 'trimOrPad', 'delta': delta}
    reach = samples(search_seconds, rate) // size
    best_lag, best = 0, correlation(input_levels, output_levels, 0)
    for distance in range(1, reach + 1):
        for lag in (-distance, distance):
            value = correlation(input_levels, output_levels, lag)
            if value > best:
                best_lag, best = lag, value
    lag = best_lag * size
    if best < CORRELATION_FLOOR or abs(delta - lag) > tolerance:
        return {'kind': 'outOfSync', 'peak': best, 'lag': lag}
    return {'kind': 'shift', 'lag': lag, 'peak': best}


# Cases ------------------------------------------------------------------------------------------------------------

cases = []


def add(case_id, kind, **fields):
    cases.append({'id': case_id, 'kind': kind, **fields})


def sine_rms(rms_dbfs):
    return rms_dbfs + 20.0 * math.log10(math.sqrt(2.0))


for rate in (16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 192000):
    shelf, high_pass = k_weighting(rate)
    add(f'k-weighting-{rate}', 'kWeighting', rate=rate, expected={'shelf': shelf, 'highPass': high_pass})


def voiced_case(case_id, value):
    x = render(value)
    add(case_id, 'voiced', signal=value, expected={'voicedRmsDb': voiced_rms_db(x, value['rate'])})


R48, R44, R24 = 48000, 44100, 24000
# 1 kHz fills each 10 ms frame with whole cycles at 48, 44.1 and 24 kHz, so every frame has the sine's RMS.
voiced_case('voiced-edge-48k', signal(R48, [sine(1000.0, sine_rms(-44.95), 24000), sine(1000.0, sine_rms(-45.05), 24000)]))
voiced_case('voiced-below-edge-44k', signal(R44, [sine(1000.0, sine_rms(-45.05), 44100)]))
voiced_case('voiced-partial-frame-24k', signal(R24, [noise(3, -30.0, 4920), silence(2400), noise(4, 0.0, 100)]))
voiced_case('voiced-silent-48k', signal(R48, [silence(48000)]))
assert cases[-4]['expected']['voicedRmsDb'] is not None and abs(cases[-4]['expected']['voicedRmsDb'] + 44.95) < 1e-3
assert cases[-3]['expected']['voicedRmsDb'] is None and cases[-1]['expected']['voicedRmsDb'] is None
# A gain step through the signal's gainDb: -10 dB leaves only the louder half voiced, at -40 dBFS.
voiced_case('voiced-gain-step-48k', signal(R48, [sine(1000.0, sine_rms(-40.0), 24000), sine(1000.0, sine_rms(-30.0), 24000)], -10.0))
assert abs(cases[-1]['expected']['voicedRmsDb'] + 40.0) < 1e-6


def peaks_case(case_id, value):
    x = render(value)
    rate = value['rate']
    add(case_id, 'peaks', signal=value, expected={
        'oversampling': oversampling(rate), 'samplePeakDbfs': sample_peak_dbfs(x), 'truePeakDbtp': true_peak_dbtp(x, rate)})
    return cases[-1]['expected']


for rate in (R48, R44, R24, 96000, 192000):
    expected = peaks_case(f'inter-sample-peak-{rate}', signal(rate, [sine(rate / 4.0, 0.0, samples(0.1, rate), math.pi / 4.0)]))
    assert expected['samplePeakDbfs'] < expected['truePeakDbtp'] or rate >= 192000
peaks_case('peaks-997hz-48k', signal(R48, [sine(997.0, 0.0, R48)]))
peaks_case('peaks-noise-24k', signal(R24, [noise(5, -6.0, R24)]))
# A short asymmetric burst reads 1.34 dB lower through the odd phases, so this 2× value pins phases 0 and 2.
peaks_case('peaks-burst-96k', signal(96000, [silence(20), noise(17, -6.0, 3), silence(20)]))
peaks_case('peaks-silent-44k', signal(R44, [silence(R44)]))
# A 1 kHz tone that stops on its crest rings about 1 dB above its sample peak at the abrupt end, through both the
# 4× and the 2× path; the same tone stopping at a zero crossing reads within 0.02 dB of it.
for rate in (R48, 96000):
    expected = peaks_case(f'peaks-crest-end-{rate // 1000}k', signal(rate, [sine(1000.0, -6.0, rate // 2 + rate // 4000 + 1)]))
    assert expected['truePeakDbtp'] - expected['samplePeakDbfs'] > 0.9
smooth = peaks_case('peaks-zero-end-96k', signal(96000, [sine(1000.0, -6.0, 48001)]))
assert smooth['truePeakDbtp'] - smooth['samplePeakDbfs'] < 0.02
# A full-scale click: no Annex 2 phase lands on the sample, so the filter alone peaks at its 0.97216796875 tap
# (-0.245 dB). The true peak is the larger value, the click's 0 dBFS, through the 4× and the 2× path.
for rate in (R48, 96000):
    expected = peaks_case(f'peaks-click-{rate // 1000}k', signal(rate, [silence(20), sine(1000.0, 0.0, 1, math.pi / 2.0), silence(20)]))
    assert expected['truePeakDbtp'] == expected['samplePeakDbfs'] == 0.0


def neighbourhood_level(x, rate, window):
    try:
        return neighbourhood_voiced_rms_db(x, rate, *window)
    except MeasurementError:
        return None


def neighbourhood_case(case_id, value, window):
    level = neighbourhood_level(render(value), value['rate'], window)
    expected = {'error': 'noVoicedAudio'} if level is None else {'voicedRmsDb': level}
    add(case_id, 'neighbourhood', signal=value, window=window, expected=expected)
    return level


# At the take start only 0.5 s precede the window, against 3 s after it: the pooled level weighs 50 frames of
# -20 dBFS noise against 300 of -30, and neither the window nor the louder audio past 3 s counts.
start = neighbourhood_case('neighbourhood-take-start-48k', signal(R48, [
    noise(41, -20.0, 24005), noise(42, -6.0, 48005), noise(43, -30.0, 144000), noise(44, -10.0, 24000)]), [24005, 72010])
assert -34.8 < start < -29.8
# Noise at -60 dBFS has no voiced frame, so the level is the voiced side's alone; that side ends at the take end.
one_side = signal(R44, [noise(45, -60.0, 132300), noise(46, -10.0, 22050), noise(47, -24.0, 88200)])
assert neighbourhood_case('neighbourhood-one-voiced-side-44k', one_side, [132300, 154350]) == \
    voiced_rms_db(render(one_side)[154350:], R44)
# Each side has its own grid. The 77 samples before the window are the before side's partial frame and are ignored;
# the 43 after it fall in the after side's first frame, which a grid from the take start would cut.
grid = signal(R24, [silence(2400), noise(48, -10.0, 77), noise(49, -6.0, 2400), noise(50, -10.0, 43), silence(24000)])
assert neighbourhood_case('neighbourhood-own-grid-24k', grid, [2477, 4877]) == voiced_rms_db(render(grid)[4877:5117], R24)
assert neighbourhood_case('neighbourhood-silent-sides-48k', signal(R48, [silence(R48), noise(51, -10.0, R48), silence(R48)]),
                          [R48, 2 * R48]) is None


def gain_case(case_id, source, candidate, error=None):
    # The window being replaced runs from 0.4 s to 0.6 s of the source.
    window = [samples(0.4, source['rate']), samples(0.6, source['rate'])]
    src, cand = render(source), render(candidate)
    src_db, cand_db = neighbourhood_level(src, source['rate'], window), voiced_rms_db(cand, candidate['rate'])
    cand_tp = true_peak_dbtp(cand, candidate['rate'])
    expected = {'sourceVoicedRmsDb': src_db, 'candidateVoicedRmsDb': cand_db, 'candidateTruePeakDbtp': cand_tp}
    try:
        expected['gainDb'] = level_gain_db(src_db, cand_db, cand_tp)
        assert error is None
    except MeasurementError as failure:
        assert str(failure) == error
        expected['error'] = error
    add(case_id, 'levelGain', source=source, window=window, candidate=candidate, expected=expected)
    return expected


plain = gain_case('gain-plain-48k-to-24k', signal(R48, [noise(11, -20.0, R48)]), signal(R24, [noise(12, -26.0, R24)]))
assert abs(plain['gainDb'] - 6.0) < 0.1
assert gain_case('gain-clamp-plus-48k', signal(R48, [noise(13, -10.0, R48)]),
                 signal(R48, [noise(14, -35.0, R48)]))['gainDb'] == GAIN_CLAMP_DB
assert gain_case('gain-clamp-minus-44k', signal(R44, [noise(15, -40.0, R44)]),
                 signal(R44, [noise(16, -10.0, R44)]))['gainDb'] == -GAIN_CLAMP_DB
capped = gain_case('gain-true-peak-cap-48k-to-24k', signal(R48, [sine(997.0, 0.0, R48)]),
                   signal(R24, [sine(6000.0, -10.0, R24, math.pi / 4.0)]))
assert capped['gainDb'] == TRUE_PEAK_LIMIT_DBTP - capped['candidateTruePeakDbtp']
assert capped['gainDb'] < capped['sourceVoicedRmsDb'] - capped['candidateVoicedRmsDb'] < GAIN_CLAMP_DB
# The abrupt end's ringing raises the candidate's true peak, so the cap lowers the gain by about 1 dB.
ringing = gain_case('gain-edge-ringing-cap-48k', signal(R48, [sine(997.0, 0.0, R48)]),
                    signal(R48, [sine(1000.0, -6.0, 24013)]))
assert ringing['gainDb'] == TRUE_PEAK_LIMIT_DBTP - ringing['candidateTruePeakDbtp'] < 4.1
gain_case('gain-silent-source-48k', signal(R48, [silence(R48)]), signal(R24, [noise(17, -20.0, R24)]), 'noVoicedAudio')
gain_case('gain-silent-candidate-44k', signal(R44, [noise(18, -20.0, R44)]), signal(R24, [silence(R24)]), 'noVoicedAudio')


def momentary_case(case_id, value, window_start=None):
    x = render(value)
    rate = value['rate']
    start = len(x) - samples(MOMENTARY_SECONDS, rate) if window_start is None else window_start
    lufs = momentary_lufs(x, rate, start)
    add(case_id, 'momentary', signal=value, windowStart=start, expected={'lufs': None if lufs == -math.inf else lufs})
    return lufs


for rate, name in ((R48, '48k'), (R44, '44k')):
    assert abs(momentary_case(f'anchor-997hz-0dbfs-{name}', signal(rate, [sine(997.0, 0.0, rate)])) + 3.01) <= 0.05
    assert abs(momentary_case(f'anchor-997hz-minus20dbfs-{name}', signal(rate, [sine(997.0, -20.0, rate)])) + 23.01) <= 0.05
momentary_case('momentary-997hz-0dbfs-24k', signal(R24, [sine(997.0, 0.0, R24)]))
# The derivation keeps the 997 Hz anchor within 0.05 LU from 16 to 192 kHz.
for rate in (16000, 96000, 192000):
    assert abs(momentary_case(f'momentary-997hz-0dbfs-{rate // 1000}k', signal(rate, [sine(997.0, 0.0, rate)])) + 3.01) <= 0.05
momentary_case('momentary-noise-48k', signal(R48, [noise(19, -20.0, R48)]), 4800)
momentary_case('momentary-silent-44k', signal(R44, [silence(R44)]))


def click():
    return sine(1000.0, 0.0, 1, math.pi / 2.0)


# A full-scale click pins the window to the sample. Just before the window only its K-weighted ringing counts, so the
# filter must run over the samples before the window; at the window's first and last sample the click is inside it.
# Each reading moves by more than the tolerance when the window starts one sample later.
before = momentary_case('momentary-click-before-window-48k', signal(R48, [silence(4799), click(), silence(19680)]), 4800)
at_start = momentary_case('momentary-click-window-start-48k', signal(R48, [silence(4800), click(), silence(19679)]), 4800)
at_end = momentary_case('momentary-click-window-end-48k', signal(R48, [silence(23999), click(), silence(480)]), 4800)
assert -60.0 < before < -50.0 and abs(at_start - at_end) > 0.1


def seam_case(case_id, value, seams, error=None):
    x = render(value)
    expected = {}
    try:
        jumps = seam_jumps(x, value['rate'], seams)
        assert error is None
        expected = {'jumps': jumps, 'lufsJumpLu': max(jumps, default=0.0)}
    except MeasurementError as failure:
        assert str(failure) == error
        expected = {'error': error}
    add(case_id, 'seamJump', signal=value, seams=seams, expected=expected)
    return expected


# 1 kHz makes whole cycles in 0.6 s, so the level step keeps the sine's phase.
steady = seam_case('seam-steady-48k', signal(R48, [sine(1000.0, -20.0, 57600)]), [28800])
assert steady['lufsJumpLu'] < 0.01
passing = seam_case('seam-1.9lu-44k', signal(R44, [sine(1000.0, -20.0, 26460), sine(1000.0, -18.1, 26460)]), [26460])
assert 1.85 < passing['lufsJumpLu'] <= 2.0
failing = seam_case('seam-2.1lu-24k', signal(R24, [sine(1000.0, -20.0, 14400), sine(1000.0, -17.9, 14400)]), [14400])
assert 2.0 < failing['lufsJumpLu'] < 2.15
assert seam_case('seam-both-quiet-48k', signal(R48, [sine(1000.0, -75.0, R48)]), [24000])['lufsJumpLu'] == 0.0
shortened = seam_case('seam-edge-shortened-48k', signal(R48, [sine(1000.0, -20.0, 12000), sine(1000.0, -21.0, 36000)]), [12000])
assert 0.9 < shortened['lufsJumpLu'] < 1.1
seam_case('seam-under-100ms-44k', signal(R44, [sine(1000.0, -20.0, R44)]), [2205], 'insufficientContext')
recipe = seam_case('seam-recipe-max-48k', signal(R48, [noise(21, -20.0, 28800), noise(22, -21.0, 28800), noise(23, -24.0, 14400)]),
                   [28800, 57600])
assert recipe['lufsJumpLu'] == max(recipe['jumps']) and recipe['jumps'][1] > recipe['jumps'][0]
assert seam_case('seam-none-24k', signal(R24, [noise(24, -20.0, R24)]), [])['lufsJumpLu'] == 0.0
# A click on the seam's last sample before: the before window holds it, and the after window only its ringing, which
# needs the filter state carried across the seam.
assert 16.0 < seam_case('seam-click-before-48k', signal(R48, [silence(23999), click(), silence(R48 // 2)]), [24000])['lufsJumpLu'] < 16.2
# Each window is floored at -70 LUFS, so a cut to or from digital silence reads a finite jump that QA can judge.
# Room tone at -60 dBFS cut to silence reads 8.3 LU; unfloored it was 59.3 against ringing that decays to -121 LUFS.
assert 8.0 < seam_case('seam-room-tone-to-silence-48k', signal(R48, [noise(61, -60.0, 24000), silence(24000)]), [24000])['lufsJumpLu'] < 8.7
assert 48.0 < seam_case('seam-speech-to-silence-24k', signal(R24, [noise(63, -20.0, 12000), silence(12000)]), [12000])['lufsJumpLu'] < 48.4
# A digitally silent side, -∞ unfloored, reads as -70 LUFS against speech or against a click on the seam.
assert 48.0 < seam_case('seam-silence-to-speech-48k', signal(R48, [silence(24000), noise(64, -20.0, 24000)]), [24000])['lufsJumpLu'] < 48.8
assert 30.0 < seam_case('seam-click-at-48k', signal(R48, [silence(24000), click(), silence(23999)]), [24000])['lufsJumpLu'] < 30.6
# A side at -79.6 LUFS counts as -70 against one at -51.6: 18.4 LU, not 27.9.
assert 18.0 < seam_case('seam-below-floor-against-above-48k', signal(R48, [noise(65, -78.0, 24000), noise(66, -50.0, 24000)]),
                        [24000])['lufsJumpLu'] < 18.7


def flatness_case(case_id, value):
    x = render(value)
    windows, stdev, value_flatness = flatness(x, value['rate'])
    add(case_id, 'flatness', signal=value, expected={'windows': windows, 'stdev': stdev, 'flatness': value_flatness})
    return windows, stdev, value_flatness


assert flatness_case('flatness-steady-48k', signal(R48, [sine(1000.0, -20.0, 96000)]))[2] > 0.999
steps = flatness_case('flatness-steps-44k', signal(R44, [noise(31, -20.0, 22050), noise(32, -23.0, 22050),
                                                         noise(33, -26.0, 22050), noise(34, -20.0, 22050)]))
assert 0.2 < steps[2] < 0.9
assert flatness_case('flatness-wide-24k', signal(R24, [noise(35, -10.0, 12000), noise(36, -30.0, 12000),
                                                       noise(37, -10.0, 12000), noise(38, -30.0, 12000)]))[2] == 0.0
assert flatness_case('flatness-one-window-48k', signal(R48, [noise(39, -20.0, 21600)]))[:1] == (1,)
padded = flatness_case('flatness-silence-padded-48k', signal(R48, [silence(24000), noise(40, -20.0, 48000), silence(24000)]))
assert 2 <= padded[0] < 17
assert flatness_case('flatness-silent-44k', signal(R44, [silence(R44)])) == (0, 0.0, 1.0)


def bursts(rate, base):
    durations = [0.23, 0.11, 0.37, 0.07, 0.19, 0.21, 0.41, 0.13, 0.29, 0.17]
    levels = [-18.0, None, -24.0, None, -15.0, None, -21.0, None, -27.0, None]
    parts = []
    for index, (seconds, level) in enumerate(zip(durations, levels)):
        count = samples(seconds, rate)
        parts.append(silence(count) if level is None else noise(base + index, level, count))
    return parts


def conform_case(case_id, input_signal, output_signal, search_seconds, kind):
    rate = input_signal['rate']
    assert output_signal['rate'] == rate
    a, b = render(input_signal), render(output_signal)
    result = conform(envelope(a, rate), envelope(b, rate), len(a), len(b), rate, search_seconds)
    assert result['kind'] == kind, (case_id, result)
    add(case_id, 'conform', input=input_signal, output=output_signal, searchSeconds=search_seconds, expected=result)
    return result


def shortened_tail(parts, count):
    last = dict(parts[-1])
    last['samples'] -= count
    return parts[:-1] + [last]


VOICE_CHANGER, CLEAN_AUDIO = 0.3, 0.5
speech48, speech44, speech24 = bursts(R48, 100), bursts(R44, 200), bursts(R24, 300)
assert conform_case('conform-trim-20ms-48k', signal(R48, speech48), signal(R48, speech48 + [silence(960)]),
                    CLEAN_AUDIO, 'trimOrPad')['delta'] == 960
assert conform_case('conform-pad-20ms-44k', signal(R44, speech44), signal(R44, shortened_tail(speech44, 882)),
                    VOICE_CHANGER, 'trimOrPad')['delta'] == -882
late = conform_case('conform-21ms-24k', signal(R24, speech24), signal(R24, [silence(504)] + speech24), VOICE_CHANGER, 'shift')
assert late['lag'] == 480 and late['peak'] >= CORRELATION_FLOOR
assert conform_case('conform-shift-120ms-48k', signal(R48, speech48), signal(R48, [silence(5760)] + speech48),
                    CLEAN_AUDIO, 'shift')['lag'] == 5760
early = conform_case('conform-shift-negative-44k', signal(R44, [silence(8820)] + speech44),
                     signal(R44, [silence(2205)] + speech44), VOICE_CHANGER, 'shift')
assert early['lag'] == -6615
unrelated = conform_case('conform-out-of-sync-peak-24k', signal(R24, speech24),
                         signal(R24, [noise(399, -20.0, sum(part['samples'] for part in speech24) + 2400)]),
                         VOICE_CHANGER, 'outOfSync')
assert unrelated['peak'] < 0.4
offset = conform_case('conform-out-of-sync-offset-48k', signal(R48, speech48), signal(R48, speech48 + [silence(4800)]),
                      CLEAN_AUDIO, 'outOfSync')
assert offset['lag'] == 0 and offset['peak'] >= CORRELATION_FLOOR
conform_case('conform-search-300ms-44k', signal(R44, speech44), signal(R44, [silence(17640)] + speech44),
             VOICE_CHANGER, 'outOfSync')
assert conform_case('conform-search-500ms-44k', signal(R44, speech44), signal(R44, [silence(17640)] + speech44),
                    CLEAN_AUDIO, 'shift')['lag'] == 17640
assert conform_case('conform-silent-48k', signal(R48, [silence(R48)]), signal(R48, [silence(52800)]),
                    CLEAN_AUDIO, 'outOfSync') == {'kind': 'outOfSync', 'peak': 0.0, 'lag': 0}


def short_chunk(seed, edge):
    return [noise(seed, -60.0, edge), noise(seed + 1, -18.0, 5760), noise(seed + 2, -60.0, edge)]


# One-word chunks, the output 30 ms late at 0.9 of the level over a -60 dBFS floor. Before the minimum overlap, a
# 2-frame overlap at the edge of the search correlated 1 and beat the true lag (0.99999...): the 0.25 s chunk gave
# outOfSync at lag 12480, and the 0.32 s chunk, reach + 2 frames long, outOfSync at lag -14400.
for case_id, seed, edge in (('conform-short-chunk-48k', 600, 3120), ('conform-reach-plus-two-frames-48k', 602, 4800)):
    late = signal(R48, [noise(seed + 50, -60.0, 1440)] + short_chunk(seed, edge), 20.0 * math.log10(0.9))
    assert conform_case(case_id, signal(R48, short_chunk(seed, edge)), late, VOICE_CHANGER, 'shift')['lag'] == 1440
assert len(render(signal(R48, short_chunk(602, 4800)))) // frame_length(R48) == samples(VOICE_CHANGER, R48) // 480 + 2
# |Δ − L| at exactly T (960 samples) is accepted and at T + 1 is not.
assert conform_case('conform-offset-at-tolerance-48k', signal(R48, speech48), signal(R48, [silence(1920)] + speech48 + [silence(960)]),
                    VOICE_CHANGER, 'shift')['lag'] == 1920
assert conform_case('conform-offset-over-tolerance-48k', signal(R48, speech48),
                    signal(R48, [silence(1920)] + speech48 + [silence(961)]), VOICE_CHANGER, 'outOfSync')['lag'] == 1920
# At 22.05 kHz a frame is 221 samples, so the ±0.3 s reach is floor(6615 / 221) = 29 frames, where rounding would give
# 30. The output is 30 frames late, so the search stops one frame short and settles on 29.
speech22 = bursts(22050, 400)
assert conform_case('conform-reach-floor-22k', signal(22050, speech22), signal(22050, [silence(6630)] + speech22), VOICE_CHANGER,
                    'shift')['lag'] == 29 * 221


def envelope_case(case_id, input_levels, output_levels, rate, search_seconds):
    size = frame_length(rate)
    a, b = np.array(input_levels, dtype=np.float32), np.array(output_levels, dtype=np.float32)
    result = conform(a, b, len(a) * size, len(b) * size, rate, search_seconds)
    add(case_id, 'conformEnvelope', rate=rate, inputLevels=input_levels, outputLevels=output_levels,
        inputSamples=len(a) * size, outputSamples=len(b) * size, searchSeconds=search_seconds, expected=result)
    return result


# Exact ties: the smallest |lag| wins, then the negative lag.
assert envelope_case('conform-tie-zero-48k', [1.0, 0.0] * 5, [1.0, 0.0] * 6 + [1.0], R48, VOICE_CHANGER) == \
    {'kind': 'outOfSync', 'peak': 1.0, 'lag': 0}
assert envelope_case('conform-tie-negative-48k', [1.0, 0.0] * 5, [0.0, 1.0] * 7, R48, VOICE_CHANGER) == \
    {'kind': 'outOfSync', 'peak': 1.0, 'lag': -480}
# The correlation floor: [0, 3, 0] against [0, 2, 2] at lag 4 frames correlates exactly 0.5, which passes; raising
# the first input level by 0.001 drops it to 0.49975, which does not.
assert envelope_case('conform-floor-at-half-48k', [0.0, 3.0, 0.0, 2.0], [1.0, 1.0, 4.0, 4.0, 0.0, 2.0, 2.0], R48, 0.1) == \
    {'kind': 'shift', 'lag': 1920, 'peak': 0.5}
below = envelope_case('conform-floor-below-half-48k', [0.001, 3.0, 0.0, 2.0], [1.0, 1.0, 4.0, 4.0, 0.0, 2.0, 2.0], R48, 0.1)
assert below['kind'] == 'outOfSync' and below['lag'] == 1920 and 0.4997 < below['peak'] < 0.5
# Pearson over each lag's overlap, the lead's reading of §4.4: three loud frames before the output's speech leave the
# overlap at lag 3 identical to the input. Means taken over the whole envelopes would give outOfSync at 0.47.
levels = [0.2, 0.8, 0.3, 0.9, 0.1, 0.7, 0.4, 0.6, 0.2, 0.5, 0.3, 0.8]
assert envelope_case('conform-pearson-loud-lead-in-48k', levels, [4.0, 4.0, 4.0] + levels, R48, VOICE_CHANGER) == \
    {'kind': 'shift', 'lag': 1440, 'peak': 1.0}

document = {
    'version': 1,
    'generator': 'tools/fixtures/voice-lab/generate_audio_math.py',
    'tolerances': {'db': 0.01, 'truePeakDb': 0.05, 'flatness': 0.001, 'correlation': 1e-9, 'coefficient': 1e-12},
    'publishedKWeighting48k': {
        'shelf': [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585],
        'highPass': [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]},
    'cases': cases,
}
OUT.write_text(json.dumps(document, indent=2, allow_nan=False) + '\n')
kinds = {}
for case in cases:
    kinds[case['kind']] = kinds.get(case['kind'], 0) + 1
print(f'{len(cases)} cases: ' + ', '.join(f'{kind} {count}' for kind, count in kinds.items()))
