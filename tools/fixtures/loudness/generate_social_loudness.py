#!/usr/bin/env python3
"""Generate the shared social-loudness vectors (ADR-R47, doc/publishing.md "Loudness").

Writes shared/fixtures/loudness/social-loudness-cases.json (format voxclip-social-loudness-cases/1), replayed by Mac Core
SocialLoudnessReplayTests and Windows Core SocialLoudnessReplayTests. Two categories:

- rule: the static gain from a measured integrated loudness and true peak alone: target -14 LUFS, at most +12 dB and at
  least -20 dB, then lowered until the true peak sits at -1 dBTP; an undefined (silent) loudness gets 0 dB.
- signal: synthetic stereo Float32 signals (tones and noise bursts with gaps), measured as ITU-R BS.1770-4 integrated
  loudness with EBU R128 gating (400 ms blocks every 100 ms, the -70 LUFS absolute gate, the -10 LU relative gate) and
  the BS.1770-4 Annex 2 true peak, then the rule, and the loudness and true peak after the gain.

The K-weighting and true-peak filter are the ones generate_audio_math.py uses for Voice Lab (libebur128's derivation,
no code copied; the Annex 2 48-tap filter). Floats are rounded to 6 decimals, so libm's and NumPy's last-bit differences
between platforms never change the bytes; replays compare within 1e-6. Deterministic; run from anywhere.
"""
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/loudness/social-loudness-cases.json'

RATE = 48000
TARGET_LUFS = -14.0
CEILING_DBTP = -1.0
MAXIMUM_BOOST_DB = 12.0
MAXIMUM_CUT_DB = -20.0
ABSOLUTE_GATE_LUFS = -70.0
RELATIVE_GATE_LU = -10.0
BLOCK_STEPS = 4
STEP_SECONDS = 0.1

SHELF_MID_BAND_EXPONENT = 0.4996667741545416
HIGH_PASS_NUMERATOR = [1.0, -2.0, 1.0]
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


def r6(value):
    return None if value is None else round(value, 6) + 0.0


def js_round(value):
    lower = math.floor(value)
    return int(lower + 1 if value - lower >= 0.5 else lower)


# The rule ------------------------------------------------------------------------------------------------------------

def decide(measured, true_peak):
    """(gainDb, limit): limit is none, gainLimit, truePeak or silent."""
    if measured is None:
        return 0.0, 'silent'
    wanted = TARGET_LUFS - measured
    clamped = min(max(wanted, MAXIMUM_CUT_DB), MAXIMUM_BOOST_DB)
    if true_peak is not None and CEILING_DBTP - true_peak < clamped:
        return CEILING_DBTP - true_peak, 'truePeak'
    return clamped, 'none' if clamped == wanted else 'gainLimit'


# Signals -------------------------------------------------------------------------------------------------------------

def sine(frequency, peak_dbfs, count):
    return {'type': 'sine', 'samples': count, 'frequency': frequency, 'peakDbfs': peak_dbfs}


def silence(count):
    return {'type': 'silence', 'samples': count}


def noise(seed, peak_dbfs, count, envelope='flat'):
    return {'type': 'noise', 'samples': count, 'seed': seed, 'peakDbfs': peak_dbfs, 'envelope': envelope}


def lcg(seed, count):
    values = np.empty(count, dtype=np.float64)
    state = seed
    for index in range(count):
        state = (1664525 * state + 1013904223) % 4294967296
        values[index] = state / 2147483648.0 - 1.0
    return values


def render_channel(parts):
    pieces = []
    for part in parts:
        count = part['samples']
        index = np.arange(count, dtype=np.float64)
        if part['type'] == 'silence':
            piece = np.zeros(count, dtype=np.float64)
        elif part['type'] == 'sine':
            amplitude = 10.0 ** (part['peakDbfs'] / 20.0)
            piece = amplitude * np.sin(2.0 * math.pi * part['frequency'] * index / RATE)
        elif part['type'] == 'noise':
            piece = 10.0 ** (part['peakDbfs'] / 20.0) * lcg(part['seed'], count)
            if part['envelope'] == 'hann':
                piece = piece * (0.5 - 0.5 * np.cos(2.0 * math.pi * index / count))
        else:
            raise ValueError(part['type'])
        pieces.append(piece)
    return np.concatenate(pieces).astype(np.float32) if pieces else np.zeros(0, dtype=np.float32)


def bursts(seed, peak_dbfs, count, on, off, envelope='hann'):
    parts = []
    for index in range(count):
        parts.append(noise(seed + index, peak_dbfs, on, envelope))
        parts.append(silence(off))
    return parts


# Measurement ---------------------------------------------------------------------------------------------------------

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


def k_weighted(x):
    shelf, high_pass = k_weighting(RATE)
    output = [0.0] * len(x)
    x1 = x2 = m1 = m2 = y1 = y2 = 0.0
    for index, value in enumerate(x.astype(np.float64).tolist()):
        m = shelf[0] * value + shelf[1] * x1 + shelf[2] * x2 - shelf[3] * m1 - shelf[4] * m2
        y = high_pass[0] * m + high_pass[1] * m1 + high_pass[2] * m2 - high_pass[3] * y1 - high_pass[4] * y2
        x2, x1, m2, m1, y2, y1 = x1, value, m1, m, y1, y
        output[index] = y
    return np.array(output, dtype=np.float64)


def true_peak(channel):
    """The Annex 2 4x true peak (linear) of one channel, silent outside its bounds, never below its sample peak."""
    if len(channel) == 0:
        return 0.0
    wide = channel.astype(np.float64)
    padded = np.concatenate([np.zeros(11), wide, np.zeros(11)])
    count = len(channel) + 11
    peak = float(np.max(np.abs(wide)))
    for phase in range(4):
        output = np.zeros(count)
        for tap, coefficient in enumerate(TRUE_PEAK_PHASES[phase]):
            output = output + coefficient * padded[11 - tap:11 - tap + count]
        peak = max(peak, float(np.max(np.abs(output))))
    return peak


def step_energies(channels):
    """Per 100 ms step: the K-weighted sum of squares over every channel; a trailing partial step is dropped."""
    step = js_round(STEP_SECONDS * RATE)
    weighted = [k_weighted(channel) for channel in channels]
    steps = len(channels[0]) // step
    energies = []
    for index in range(steps):
        total = 0.0
        for frame in range(index * step, (index + 1) * step):
            for channel in weighted:
                total += channel[frame] * channel[frame]
        energies.append(total)
    return energies, step


def integrated(energies, step, gain_db=0.0):
    """BS.1770-4 gated integrated loudness of the step energies scaled by gain_db, or None when no block passes."""
    scale = 10.0 ** (gain_db / 10.0)
    blocks = []
    for index in range(len(energies) - BLOCK_STEPS + 1):
        blocks.append(sum(energies[index:index + BLOCK_STEPS]) * scale / (BLOCK_STEPS * step))

    def lufs(mean_square):
        return -0.691 + 10.0 * math.log10(mean_square) if mean_square > 0 else -math.inf

    absolute = [block for block in blocks if lufs(block) > ABSOLUTE_GATE_LUFS]
    if not absolute:
        return None
    relative = lufs(sum(absolute) / len(absolute)) + RELATIVE_GATE_LU
    gated = [block for block in absolute if lufs(block) > relative]
    return lufs(sum(gated) / len(gated))


def amplitude_db(value):
    return 20.0 * math.log10(value) if value > 0 else None


CASES = []


def rule_case(case_id, measured, true_peak_dbtp, expected_limit):
    gain, limit = decide(measured, true_peak_dbtp)
    assert limit == expected_limit, (case_id, limit)
    CASES.append({'id': case_id, 'kind': 'rule', 'measuredLufs': r6(measured), 'truePeakDbtp': r6(true_peak_dbtp),
                  'expected': {'gainDb': r6(gain), 'limit': limit, 'capped': limit == 'truePeak'}})


def signal_case(case_id, left, right, expected_limit, check=None):
    channels = [render_channel(left), render_channel(right)]
    assert len(channels[0]) == len(channels[1])
    energies, step = step_energies(channels)
    measured = integrated(energies, step)
    peak = amplitude_db(max(true_peak(channel) for channel in channels))
    gain, limit = decide(measured, peak)
    assert limit == expected_limit, (case_id, measured, peak, gain, limit)
    output = integrated(energies, step, gain)
    if check:
        check(measured, peak, gain, output)
    CASES.append({'id': case_id, 'kind': 'signal', 'rate': RATE, 'frames': len(channels[0]),
                  'channels': [left, right],
                  'expected': {'measuredLufs': r6(measured), 'truePeakDbtp': r6(peak), 'gainDb': r6(gain),
                               'limit': limit, 'capped': limit == 'truePeak', 'outputLufs': r6(output),
                               'outputTruePeakDbtp': r6(None if peak is None else peak + gain)}})


# The rule's edges.
rule_case('rule-at-target', -14.0, -6.0, 'none')
rule_case('rule-quiet-boost', -20.7, -9.0, 'none')
rule_case('rule-boost-limit', -30.0, -20.0, 'gainLimit')
rule_case('rule-boost-limit-edge', -26.0, -13.0, 'none')
rule_case('rule-cut', -8.5, -0.2, 'none')
rule_case('rule-cut-limit', 10.0, 12.0, 'gainLimit')
rule_case('rule-peak-cap', -20.0, -3.0, 'truePeak')
rule_case('rule-peak-cap-edge', -20.0, -7.0, 'none')
rule_case('rule-peak-cap-below-boost-limit', -40.0, -5.0, 'truePeak')
rule_case('rule-peak-cap-negative', -16.0, 2.0, 'truePeak')
rule_case('rule-silent', None, None, 'silent')
rule_case('rule-silent-with-peak', None, -75.0, 'silent')


def near(expected, tolerance):
    def check(measured, peak, gain, output):
        assert abs(measured - expected) < tolerance, measured
    return check


def reaches_target(measured, peak, gain, output):
    assert abs(output - TARGET_LUFS) < 1e-9, output


def tone_anchor(measured, peak, gain, output):
    near(-23.0, 0.1)(measured, peak, gain, output)
    reaches_target(measured, peak, gain, output)


def boost_limited(measured, peak, gain, output):
    assert gain == MAXIMUM_BOOST_DB and output < TARGET_LUFS - 1.0, (gain, output)


def peak_capped(measured, peak, gain, output):
    assert abs(peak + gain - CEILING_DBTP) < 1e-12 and output < TARGET_LUFS - 1.0, (peak, gain, output)


def cut_limited(measured, peak, gain, output):
    assert gain == MAXIMUM_CUT_DB and output > TARGET_LUFS + 1.0, (gain, output)


LOUD_SECOND = ([noise(801, -6.0, RATE)], [noise(901, -6.0, RATE)])


def relative_gate(measured, peak, gain, output):
    # Within 1 LU of the loud second alone (blocks straddling the drop count), and far above the ungated mean.
    loud = integrated(*step_energies([render_channel(LOUD_SECOND[0]), render_channel(LOUD_SECOND[1])]))
    assert abs(measured - loud) < 1.0, (measured, loud)
    energies, step = step_energies([render_channel(LOUD_SECOND[0] + [noise(802, -36.0, 4 * RATE)]),
                                    render_channel(LOUD_SECOND[1] + [noise(902, -36.0, 4 * RATE)])])
    ungated = -0.691 + 10.0 * math.log10(sum(energies) / (len(energies) * step))
    assert measured - ungated > 5.0, (measured, ungated)


# A 1 kHz sine at -23 dBFS peak in both channels reads -23 LUFS (EBU Tech 3341 case 1 at 48 kHz).
signal_case('tone-1k-both-minus23', [sine(1000.0, -23.0, 5 * RATE)], [sine(1000.0, -23.0, 5 * RATE)], 'none', tone_anchor)
# The same tone in one channel only is 3 LU quieter: channel weights are 1 and the power sums.
signal_case('tone-1k-left-only', [sine(1000.0, -20.0, 4 * RATE)], [silence(4 * RATE)], 'none', near(-23.0, 0.1))
# Speech-like Hann noise bursts with gaps at a typical talking-head level.
signal_case('speech-bursts-typical', bursts(101, -10.0, 16, 14400, 9600), bursts(201, -10.0, 16, 14400, 9600), 'none',
            reaches_target)
# The same bursts 22 dB down want about +26 dB; the boost stops at +12 and the clip lands quieter than -14.
signal_case('speech-bursts-quiet-boost-limit', bursts(101, -32.0, 16, 14400, 9600), bursts(201, -32.0, 16, 14400, 9600),
            'gainLimit', boost_limited)
# Quiet speech with sharp clicks: the true peak, not the boost limit, sets the gain.
CLICKY = []
for index in range(8):
    CLICKY += [noise(301 + index, -24.0, 14400, 'hann'), silence(4800), noise(401 + index, -2.0, 96), silence(4704)]
signal_case('speech-clicks-peak-cap', CLICKY, bursts(501, -24.0, 8, 14400, 9600), 'truePeak', peak_capped)
# A float mix above full scale (+12 dBFS peak tone) wants about -26 dB; the cut stops at -20.
signal_case('hot-float-mix-cut-limit', [sine(997.0, 12.0, 3 * RATE)], [sine(997.0, 12.0, 3 * RATE)], 'gainLimit',
            cut_limited)
# Loud speech is turned down to -14, never limited.
signal_case('speech-bursts-loud-cut', bursts(601, 0.0, 12, 14400, 4800, 'flat'), bursts(701, 0.0, 12, 14400, 4800, 'flat'),
            'none', reaches_target)
# A loud second followed by four seconds 30 LU down: the relative gate leaves the quiet part out.
signal_case('relative-gate-drops-quiet-tail', LOUD_SECOND[0] + [noise(802, -36.0, 4 * RATE)],
            LOUD_SECOND[1] + [noise(902, -36.0, 4 * RATE)], 'none', relative_gate)
# Digital silence, noise below the absolute gate, and a clip shorter than one 400 ms block are all silent: 0 dB.
signal_case('digital-silence', [silence(3 * RATE)], [silence(3 * RATE)], 'silent')
signal_case('below-absolute-gate', [noise(1001, -85.0, 3 * RATE)], [noise(1002, -85.0, 3 * RATE)], 'silent')
signal_case('shorter-than-a-block', [sine(1000.0, -20.0, 18000)], [sine(1000.0, -20.0, 18000)], 'silent')
# A length that is not a whole number of 100 ms steps: the trailing 37.5 ms is in no block.
signal_case('trailing-partial-step', [sine(440.0, -18.0, 2 * RATE + 1800)], [sine(440.0, -18.0, 2 * RATE + 1800)], 'none')

counts = {}
for case in CASES:
    counts[case['kind']] = counts.get(case['kind'], 0) + 1
document = {
    'format': 'voxclip-social-loudness-cases/1',
    'description': 'Social loudness (ADR-R47): BS.1770-4 integrated loudness with EBU R128 gating and the Annex 2 '
                   'true peak of stereo Float32 signals, and the static export gain: -14 LUFS, true peak at most -1 '
                   'dBTP, the gain within -20...+12 dB, 0 dB when the loudness is undefined. Floats rounded to 6 '
                   'decimals; replays compare within 1e-6.',
    'constants': {'targetLufs': TARGET_LUFS, 'ceilingDbtp': CEILING_DBTP, 'maximumBoostDb': MAXIMUM_BOOST_DB,
                  'maximumCutDb': MAXIMUM_CUT_DB, 'absoluteGateLufs': ABSOLUTE_GATE_LUFS,
                  'relativeGateLu': RELATIVE_GATE_LU, 'blockSeconds': 0.4, 'stepSeconds': STEP_SECONDS},
    'caseCount': len(CASES),
    'counts': counts,
    'cases': CASES,
}
DESTINATION.parent.mkdir(parents=True, exist_ok=True)
DESTINATION.write_text(json.dumps(document, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
