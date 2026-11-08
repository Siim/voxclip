#!/usr/bin/env python3
"""Generate the shared social-loudness vectors (ADR-R47, doc/publishing.md "Loudness").

Writes two files, replayed by Mac Core and Windows Core SocialLoudnessReplayTests and SocialLimiterReplayTests:

shared/fixtures/loudness/social-loudness-cases.json (format voxclip-social-loudness-cases/2), the meter and the plan:
- rule: the gain from a measured integrated loudness and true peak alone: target -14 LUFS, at most +12 dB and at least
  -20 dB, and lowered until the limiter would reduce at most 9 dB; whether the limiter has work; an undefined (silent)
  loudness gets 0 dB and no limiting.
- signal: synthetic stereo Float32 signals (tones and noise bursts with gaps), measured as ITU-R BS.1770-4 integrated
  loudness with EBU R128 gating (400 ms blocks every 100 ms, the -70 LUFS absolute gate, the -10 LU relative gate) and
  the BS.1770-4 Annex 2 true peak, then the plan, and the loudness and true peak after the plan's gain alone.

shared/fixtures/loudness/social-limiter-cases.json (format voxclip-social-limiter-cases/1), the true-peak limiter
(ADR-R47 amended 2026-11-08, doc/publishing.md "Loudness"):
- export: speech-like signals with plosives and clicks through the whole rule: measure, plan, the offline pre-passes
  that simulate the gain and the limiter and land the gain on target (one correction; a secant step from a second
  simulation when the limiter took more than 0.5 LU), then the export's own output: its loudness and true peak, the
  limiter's largest reduction, the limited frames, and probes of the output samples.
- envelope: one signal through the limiter at a fixed gain, probed densely, so the attack, hold and release are pinned.

The K-weighting and true-peak filter are the ones generate_audio_math.py uses for Voice Lab (libebur128's derivation,
no code copied; the Annex 2 48-tap filter). Floats are rounded to 6 decimals, so libm's and NumPy's last-bit differences
between platforms never change the bytes; replays compare within 1e-6 (samples within 2e-6). Deterministic; run from
anywhere.
"""
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/loudness/social-loudness-cases.json'
LIMITER_DESTINATION = ROOT / 'shared/fixtures/loudness/social-limiter-cases.json'

RATE = 48000
TARGET_LUFS = -14.0
CEILING_DBTP = -1.0
MAXIMUM_BOOST_DB = 12.0
MAXIMUM_CUT_DB = -20.0
MAXIMUM_REDUCTION_DB = 9.0
LOOKAHEAD_SECONDS = 0.005
RELEASE_SECONDS = 0.08
RELEASE_FLOOR_DB = 0.01
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
    """(gainDb, limit, limiting): limit is none, gainLimit, reductionCap or silent; limiting is whether the true peak
    after the gain is over the ceiling, so the limiter has work. The limiter's largest reduction is then exactly
    true_peak + gain - ceiling (the envelope never exceeds the largest overshoot it detects), so the 9 dB cap is a bound
    on the gain, not a search."""
    if measured is None:
        return 0.0, 'silent', False
    wanted = TARGET_LUFS - measured
    gain = min(max(wanted, MAXIMUM_CUT_DB), MAXIMUM_BOOST_DB)
    limit = 'none' if gain == wanted else 'gainLimit'
    if true_peak is not None and gain > CEILING_DBTP + MAXIMUM_REDUCTION_DB - true_peak:
        gain, limit = CEILING_DBTP + MAXIMUM_REDUCTION_DB - true_peak, 'reductionCap'
    return gain, limit, true_peak is not None and true_peak + gain > CEILING_DBTP


def maximum_reduction(true_peak, gain, limiting):
    return true_peak + gain - CEILING_DBTP if limiting else 0.0


LANDING_TOLERANCE_LU = 0.5


def bounded(gain, true_peak):
    """(gain, limit) kept within -20 dB, +12 dB and the 9 dB reduction cap."""
    cap = CEILING_DBTP + MAXIMUM_REDUCTION_DB - true_peak
    bound = min(MAXIMUM_BOOST_DB, cap)
    if gain > bound:
        return bound, 'reductionCap' if cap <= MAXIMUM_BOOST_DB else 'gainLimit'
    return max(gain, MAXIMUM_CUT_DB), 'none'


def landing(true_peak, plan_gain, plan_limit, plan_limiting, trials):
    """Landing on target from offline simulations of the gain and the limiter, `trials` = [(gain, simulated LUFS)].
    Returns ('simulate', gain) for the next pre-pass or ('settled', gain, limit, limiting). Only an uncapped, limited
    plan moves. One simulation, one correction by target minus what it measured; when the limiter took more than
    0.5 LU, the corrected gain is simulated too and a secant step through the two lands it."""
    def settled(gain, limit):
        return 'settled', gain, limit, true_peak is not None and true_peak + gain > CEILING_DBTP
    if not plan_limiting or plan_limit != 'none':
        return settled(plan_gain, plan_limit)
    if not trials:
        return 'simulate', plan_gain
    first_gain, first = trials[0]
    if first is None:
        return settled(plan_gain, plan_limit)
    corrected, limit = bounded(first_gain + TARGET_LUFS - first, true_peak)
    if len(trials) == 1:
        if abs(TARGET_LUFS - first) <= LANDING_TOLERANCE_LU or corrected == first_gain:
            return settled(corrected, limit)
        return 'simulate', corrected
    second_gain, second = trials[1]
    if second is None:
        return settled(second_gain, limit)
    slope = (second - first) / (second_gain - first_gain)
    step = (TARGET_LUFS - second) / slope if slope > 0.05 else TARGET_LUFS - second
    return settled(*bounded(second_gain + step, true_peak))


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


# The limiter ---------------------------------------------------------------------------------------------------------

LOOKAHEAD = js_round(LOOKAHEAD_SECONDS * RATE)
ATTACK = [0.5 + 0.5 * math.cos(math.pi * index / LOOKAHEAD) for index in range(LOOKAHEAD + 1)]
RELEASE = math.exp(-1.0 / (RELEASE_SECONDS * RATE))
THRESHOLD = 10.0 ** (CEILING_DBTP / 20.0)


def overshoot(gained):
    """Per detection point n = 0 ... frames + 10: how far (dB) the largest of every channel's |sample n| and its four
    Annex 2 phase outputs reading samples n-11 ... n (silence outside) sits above the ceiling, else 0."""
    count = len(gained[0]) + 11
    peak = np.zeros(count)
    for channel in gained:
        padded = np.concatenate([np.zeros(11), channel, np.zeros(11)])
        peak[:len(channel)] = np.maximum(peak[:len(channel)], np.abs(channel))
        for phase in range(4):
            output = np.zeros(count)
            for tap, coefficient in enumerate(TRUE_PEAK_PHASES[phase]):
                output = output + coefficient * padded[11 - tap:11 - tap + count]
            peak = np.maximum(peak, np.abs(output))
    over = peak > THRESHOLD
    return np.where(over, 20.0 * np.log10(np.where(over, peak, 1.0)) - CEILING_DBTP, 0.0)


def envelope(gained):
    """The reduction (dB, >= 0) of every frame: hold each overshoot over the 12 inputs its detection point reads, take
    the raised-cosine attack over the 5 ms lookahead before it, then the 80 ms exponential release, which ends below
    0.01 dB."""
    frames = len(gained[0])
    over = np.concatenate([overshoot(gained), np.zeros(LOOKAHEAD)])
    held = np.zeros(frames + LOOKAHEAD)
    for tap in range(12):
        held = np.maximum(held, over[tap:tap + frames + LOOKAHEAD])
    attack = held[:frames].copy()
    for index in np.nonzero(held)[0]:
        first = max(0, index - LOOKAHEAD)
        if first >= frames:
            continue
        last = min(index, frames - 1)
        shape = np.array([ATTACK[index - frame] for frame in range(first, last + 1)])
        attack[first:last + 1] = np.maximum(attack[first:last + 1], shape * held[index])
    reduction = np.zeros(frames)
    previous = 0.0
    for frame, value in enumerate(attack.tolist()):
        released = previous * RELEASE
        if released < RELEASE_FLOOR_DB:
            released = 0.0
        previous = value if value > released else released
        reduction[frame] = previous
    return reduction


def limited(channels, gain, limiting):
    """The export's samples at `gain`: Float32(sample * 10^(gain/20) * 10^(-reduction/20)), and the reduction."""
    gained = [channel.astype(np.float64) * 10.0 ** (gain / 20.0) for channel in channels]
    reduction = envelope(gained) if limiting else np.zeros(len(channels[0]))
    factor = np.where(reduction > 0, 10.0 ** (-reduction / 20.0), 1.0)
    return [(channel * factor).astype(np.float32) for channel in gained], reduction


CASES = []
LIMITER_CASES = []


def rule_case(case_id, measured, true_peak_dbtp, expected_limit, expected_limiting):
    gain, limit, limiting = decide(measured, true_peak_dbtp)
    assert (limit, limiting) == (expected_limit, expected_limiting), (case_id, limit, limiting)
    CASES.append({'id': case_id, 'kind': 'rule', 'measuredLufs': r6(measured), 'truePeakDbtp': r6(true_peak_dbtp),
                  'expected': {'gainDb': r6(gain), 'limit': limit, 'capped': limit == 'reductionCap',
                               'limiting': limiting,
                               'limiterMaxReductionDb': r6(maximum_reduction(true_peak_dbtp, gain, limiting))}})


def measure(channels):
    energies, step = step_energies(channels)
    return energies, step, integrated(energies, step), amplitude_db(max(true_peak(channel) for channel in channels))


def signal_case(case_id, left, right, expected_limit, check=None, expected_limiting=False):
    channels = [render_channel(left), render_channel(right)]
    assert len(channels[0]) == len(channels[1])
    energies, step, measured, peak = measure(channels)
    gain, limit, limiting = decide(measured, peak)
    assert (limit, limiting) == (expected_limit, expected_limiting), (case_id, measured, peak, gain, limit, limiting)
    gained = integrated(energies, step, gain)
    if check:
        check(measured, peak, gain, gained)
    CASES.append({'id': case_id, 'kind': 'signal', 'rate': RATE, 'frames': len(channels[0]),
                  'channels': [left, right],
                  'expected': {'measuredLufs': r6(measured), 'truePeakDbtp': r6(peak), 'gainDb': r6(gain),
                               'limit': limit, 'capped': limit == 'reductionCap', 'limiting': limiting,
                               'limiterMaxReductionDb': r6(maximum_reduction(peak, gain, limiting)),
                               'gainedLufs': r6(gained),
                               'gainedTruePeakDbtp': r6(None if peak is None else peak + gain)}})


def probe_frames(reduction, extra):
    frames = len(reduction)
    chosen = {js_round(index * (frames - 1) / 31) for index in range(32)}
    active = np.nonzero(reduction)[0]
    if len(active):
        top = int(np.argmax(reduction))
        for offset in [-260, -241, -240, -239, -200, -120, -60, -12, -6, -1, 0, 1, 6, 12, 60, 240, 960, 2400, 4800, 9600]:
            chosen.add(top + offset)
        chosen.update([int(active[0]) - 1, int(active[0]), int(active[-1]), int(active[-1]) + 1])
    chosen.update(extra)
    return sorted(frame for frame in chosen if 0 <= frame < frames)


def probes(output, reduction, extra=()):
    return [[frame, r6(float(reduction[frame])), r6(float(output[0][frame])), r6(float(output[1][frame]))]
            for frame in probe_frames(reduction, extra)]


def limiter_result(channels, energies, step, peak, gain, limiting):
    output, reduction = limited(channels, gain, limiting)
    if limiting:
        _, _, output_lufs, output_peak = measure(output)
    else:
        output_lufs, output_peak = integrated(energies, step, gain), None if peak is None else peak + gain
    largest = float(reduction.max()) if len(reduction) else 0.0
    assert abs(largest - maximum_reduction(peak, gain, limiting)) < 1e-9, (largest, peak, gain)
    count = int(np.count_nonzero(reduction))
    return output, reduction, output_lufs, output_peak, largest, count


def export_case(case_id, left, right, expected_limit, expected_limiting, expected_trials, check=None):
    """The whole rule on one mix: measure, plan, simulate and land, export."""
    channels = [render_channel(left), render_channel(right)]
    frames = len(channels[0])
    energies, step, measured, peak = measure(channels)
    plan_gain, plan_limit, plan_limiting = decide(measured, peak)
    trials = []
    while True:
        step_result = landing(peak, plan_gain, plan_limit, plan_limiting, trials)
        if step_result[0] == 'settled':
            break
        trials.append((step_result[1], limiter_result(channels, energies, step, peak, step_result[1], True)[2]))
    _, gain, limit, limiting = step_result
    assert (limit, limiting, len(trials)) == (expected_limit, expected_limiting, expected_trials), \
        (case_id, measured, peak, gain, limit, limiting, trials)
    output, reduction, output_lufs, output_peak, largest, count = limiter_result(channels, energies, step, peak, gain,
                                                                                 limiting)
    assert largest <= MAXIMUM_REDUCTION_DB + 1e-9 and (output_peak is None or output_peak <= CEILING_DBTP + 1e-6)
    if limit == 'none':
        assert abs(output_lufs - TARGET_LUFS) <= 0.5, (case_id, output_lufs)
    if not limiting:
        scale = 10.0 ** (gain / 20.0)
        assert all(np.array_equal(out, (channel.astype(np.float64) * scale).astype(np.float32))
                   for out, channel in zip(output, channels))
    if check:
        check(measured, peak, plan_gain, trials, gain, output_lufs, largest, count / frames)
    LIMITER_CASES.append({
        'id': case_id, 'kind': 'export', 'rate': RATE, 'frames': frames, 'channels': [left, right],
        'expected': {'measuredLufs': r6(measured), 'truePeakDbtp': r6(peak),
                     'plan': {'gainDb': r6(plan_gain), 'limit': plan_limit, 'limiting': plan_limiting},
                     'trials': [[r6(trial_gain), r6(trial_lufs)] for trial_gain, trial_lufs in trials],
                     'gainDb': r6(gain), 'limit': limit,
                     'capped': limit == 'reductionCap', 'limiting': limiting, 'outputLufs': r6(output_lufs),
                     'outputTruePeakDbtp': r6(output_peak), 'limiterMaxReductionDb': r6(largest),
                     'limitedFrames': count, 'limitedPercent': r6(100.0 * count / frames)},
        'probes': probes(output, reduction)})


def envelope_case(case_id, left, right, gain, extra):
    """The limiter alone at a fixed gain, probed densely around the overshoot."""
    channels = [render_channel(left), render_channel(right)]
    frames = len(channels[0])
    output, reduction = limited(channels, gain, True)
    output_peak = amplitude_db(max(true_peak(channel) for channel in output))
    assert output_peak <= CEILING_DBTP + 1e-6, output_peak
    count = int(np.count_nonzero(reduction))
    LIMITER_CASES.append({
        'id': case_id, 'kind': 'envelope', 'rate': RATE, 'frames': frames, 'channels': [left, right],
        'gainDb': gain,
        'expected': {'outputTruePeakDbtp': r6(output_peak), 'limiterMaxReductionDb': r6(float(reduction.max())),
                     'limitedFrames': count, 'limitedPercent': r6(100.0 * count / frames)},
        'probes': probes(output, reduction, extra)})


# The rule's edges.
rule_case('rule-at-target', -14.0, -6.0, 'none', False)
rule_case('rule-quiet-boost', -20.7, -9.0, 'none', False)
rule_case('rule-boost-limit', -30.0, -20.0, 'gainLimit', False)
rule_case('rule-boost-limit-edge', -26.0, -13.0, 'none', False)
rule_case('rule-cut', -8.5, -0.2, 'none', False)
rule_case('rule-cut-limit', 10.0, 12.0, 'gainLimit', False)
# The true peak after the gain is over the ceiling: the limiter takes the overshoot, the gain stays.
rule_case('rule-limited', -20.0, -3.0, 'none', True)
rule_case('rule-ceiling-edge', -20.0, -7.0, 'none', False)
rule_case('rule-limited-at-boost-limit', -40.0, -5.0, 'gainLimit', True)
rule_case('rule-limited-negative-peak-room', -16.0, 2.0, 'none', True)
# The limiter would reduce more than 9 dB: the gain stops at ceiling + 9 - true peak and the clip lands quieter.
rule_case('rule-reduction-cap', -28.0, 0.0, 'reductionCap', True)
rule_case('rule-reduction-cap-edge', -24.0, -2.0, 'none', True)
rule_case('rule-reduction-cap-hot-peak', -12.0, 12.0, 'reductionCap', True)
rule_case('rule-silent', None, None, 'silent', False)
rule_case('rule-silent-with-peak', None, -75.0, 'silent', False)
rule_case('rule-silent-with-hot-peak', None, 3.0, 'silent', False)


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


def reduction_capped(measured, peak, gain, output):
    assert abs(peak + gain - CEILING_DBTP - MAXIMUM_REDUCTION_DB) < 1e-12 and output < TARGET_LUFS - 1.0, (peak, gain, output)


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
# Quiet speech with sharp clicks 26 dB over it: the 9 dB reduction cap, not the boost limit, sets the gain.
CLICKY = []
for index in range(8):
    CLICKY += [noise(301 + index, -24.0, 14400, 'hann'), silence(4800), noise(401 + index, -2.0, 96), silence(4704)]
signal_case('speech-clicks-reduction-cap', CLICKY, bursts(501, -24.0, 8, 14400, 9600), 'reductionCap', reduction_capped,
            True)
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


# Speech with transients: syllables (300 ms Hann noise bursts at `body` peak) and 150 ms gaps; every third syllable
# starts with a 5 ms plosive `plosive` dB over the body, and every fourth carries a 2 ms click `click` dB over it
# 40 ms after the syllable, as real recordings have.
def talk(seed, body, plosive, click, syllables=12):
    parts = []
    for index in range(syllables):
        if index % 3 == 0:
            parts.append(noise(seed + 500 + index, body + plosive, 240, 'hann'))
        parts.append(noise(seed + index, body, 14400, 'hann'))
        if index % 4 == 1:
            parts += [silence(1920), noise(seed + 900 + index, body + click, 96, 'hann'), silence(1920)]
        parts.append(silence(7200))
    return parts


def pads(parts, frames):
    """`parts` padded with silence to `frames`, so both channels have one length."""
    count = sum(part['samples'] for part in parts)
    return parts + [silence(frames - count)] if frames > count else parts


def stereo(left, right):
    frames = max(sum(part['samples'] for part in left), sum(part['samples'] for part in right))
    return pads(left, frames), pads(right, frames)


def lands(measured, peak, plan_gain, trials, gain, output, largest, share):
    assert abs(output - TARGET_LUFS) <= 0.5 and trials[0][1] < TARGET_LUFS, (output, trials)


def lands_quieter(measured, peak, plan_gain, trials, gain, output, largest, share):
    assert abs(largest - MAXIMUM_REDUCTION_DB) < 1e-9 and output < TARGET_LUFS - 0.5, (largest, output)


def pure_gain(measured, peak, plan_gain, trials, gain, output, largest, share):
    assert not trials and largest == 0.0 and share == 0.0 and abs(output - TARGET_LUFS) < 1e-9, (trials, output)


# Mild transients: the gain alone reaches -14 with the true peak under the ceiling; samples are only scaled.
export_case('talk-pure-gain', *stereo(talk(1101, -16.0, 3.0, 4.0), talk(1201, -16.0, 3.0, 4.0)), 'none', False, 0,
            pure_gain)
# Clicks 14 dB over the body: the limiter takes them; it took under 0.5 LU, so one correction lands it.
export_case('talk-clicks-limited', *stereo(talk(1901, -18.0, 4.0, 14.0), talk(2001, -18.0, 4.0, 14.0)), 'none', True,
            1, lands)
# Plosives 12 dB and clicks 14 dB over the body: the release ducks each syllable after its plosive, the limiter takes
# more than 0.5 LU, and the second simulation's secant step lands it.
export_case('talk-plosives-limited', *stereo(talk(1301, -18.0, 12.0, 14.0), talk(1401, -18.0, 12.0, 14.0)), 'none', True,
            2, lands)
# Clicks 30 dB over quiet speech would need more than 9 dB of reduction: the gain stops there and the clip lands quieter.
export_case('talk-reduction-cap', *stereo(talk(1501, -34.0, 20.0, 30.0), talk(1601, -34.0, 16.0, 18.0)), 'reductionCap',
            True, 0, lands_quieter)
# Speech already louder than -14 is cut; the cut leaves the true peak under the ceiling, so the limiter has no work.
export_case('talk-loud-cut', *stereo(talk(1701, -2.0, 2.0, 2.0), talk(1801, -2.0, 2.0, 2.0)), 'none', False, 0,
            pure_gain)
# Digital silence: 0 dB and no limiting.
export_case('talk-silence', [silence(3 * RATE)], [silence(3 * RATE)], 'silent', False, 0)

# One 2 ms click 4 dB over the ceiling in the left channel, alone, at 0 dB: the attack starts 5 ms before the 12 inputs
# its detection reads, holds over them and releases over 80 ms.
CLICK_AT = 9600
CLICK_ALONE = [silence(CLICK_AT), noise(2001, 3.0, 96, 'hann'), silence(RATE - CLICK_AT - 96)]
envelope_case('click-envelope', CLICK_ALONE, [silence(RATE)], 0.0,
              list(range(CLICK_AT - 270, CLICK_AT + 120, 6)) + list(range(CLICK_AT + 120, CLICK_AT + 30000, 480)))


def counted(cases):
    counts = {}
    for case in cases:
        counts[case['kind']] = counts.get(case['kind'], 0) + 1
    return counts


document = {
    'format': 'voxclip-social-loudness-cases/2',
    'description': 'Social loudness (ADR-R47, amended 2026-11-08): BS.1770-4 integrated loudness with EBU R128 gating '
                   'and the Annex 2 true peak of stereo Float32 signals, and the plan: -14 LUFS, the gain within '
                   '-20...+12 dB and lowered until the true-peak limiter would reduce at most 9 dB, 0 dB and no '
                   'limiting when the loudness is undefined. gainedLufs and gainedTruePeakDbtp are after the plan\'s '
                   'gain alone, before the limiter and the landing correction (social-limiter-cases.json). Floats '
                   'rounded to 6 decimals; replays compare within 1e-6.',
    'constants': {'targetLufs': TARGET_LUFS, 'ceilingDbtp': CEILING_DBTP, 'maximumBoostDb': MAXIMUM_BOOST_DB,
                  'maximumCutDb': MAXIMUM_CUT_DB, 'maximumReductionDb': MAXIMUM_REDUCTION_DB,
                  'absoluteGateLufs': ABSOLUTE_GATE_LUFS, 'relativeGateLu': RELATIVE_GATE_LU, 'blockSeconds': 0.4,
                  'stepSeconds': STEP_SECONDS},
    'caseCount': len(CASES),
    'counts': counted(CASES),
    'cases': CASES,
}
DESTINATION.parent.mkdir(parents=True, exist_ok=True)
DESTINATION.write_text(json.dumps(document, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')

limiter_document = {
    'format': 'voxclip-social-limiter-cases/1',
    'description': 'The social-loudness true-peak limiter (ADR-R47, amended 2026-11-08): after the gain, every frame\'s '
                   'reduction holds the overshoot of each Annex 2 detection point over the 12 inputs it reads, rises '
                   'over the 5 ms lookahead before it as a raised cosine, and releases exponentially over 80 ms, '
                   'ending below 0.01 dB; one reduction for both channels. export cases run the whole rule (measure, '
                   'plan, simulate and land, export); envelope cases run the limiter alone at gainDb. probes are '
                   '[frame, reductionDb, left, right] of the output. Floats rounded to 6 decimals; replays compare '
                   'within 1e-6, samples within 2e-6, limitedFrames within 2.',
    'constants': {'targetLufs': TARGET_LUFS, 'ceilingDbtp': CEILING_DBTP, 'maximumReductionDb': MAXIMUM_REDUCTION_DB,
                  'lookaheadSeconds': LOOKAHEAD_SECONDS, 'lookaheadFrames': LOOKAHEAD,
                  'releaseSeconds': RELEASE_SECONDS, 'releaseFloorDb': RELEASE_FLOOR_DB, 'detectionTaps': 12,
                  'landingToleranceLu': LANDING_TOLERANCE_LU},
    'caseCount': len(LIMITER_CASES),
    'counts': counted(LIMITER_CASES),
    'cases': LIMITER_CASES,
}
LIMITER_DESTINATION.write_text(json.dumps(limiter_document, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
