#!/usr/bin/env python3
"""Generate shared/fixtures/clip-render/clip-grade-cases.json (format voxclip-clip-grade-cases/1): the colour grade both
Cores' ClipGradeRecipe and ClipColorFix.measure reproduce (looks spec 2026-11-28, sections 5, 6 and 11.1; doc/design.md
section 6.9).

The reference chain is the maths note's Appendix A with the spec's two changes: Amount mixes over the Fix output f, not the
input o, and Whites and Blacks are deferred (stage T1's end knots stay at 0 and 1). It runs in double precision on 8-bit
inputs:

    o (bytes / 255) -> P Fix -> f -> L base look -> A colorAdjustments (no clamp between L and A, as Core Image) -> clamp
      -> T1 highlights/shadows -> T2 vibrance -> T3 preset curves -> T4 split tone -> T5 fade -> clamp -> g
      -> out = f + a (g - f), a = amount / 100 (a = 1: g; a = 0: f, skipping L, A and T)
    later, after the motion crop and footage: F1 vignette, then F2 grain, on the graded bytes / 255

Bytes are floor(255 clamp01(v) + 0.5). Categories: the swatches, the Fix's gains and shoulder (E1, E2), each control alone
(E1-E5, `controls`), the monotone curves (knots, tangents, coefficients), vignette weights (E6), PCG pairs and frame hashes,
grain cells and exact totals (E7), frame indices, the context-demo grain hole, the finish on bytes, the whole chain (E8), the
24 looks on every swatch at 100% and 70%, colorAdjustments and the four Mac presets alone, the spec's section 4.3 skin table,
and Auto and the light facts on synthetic frames. The generator asserts the spec's and the maths note's published numbers.

Swift ClipGradeRecipeTests (Core) and C# ClipGradeVectorTests (Core) replay every category: bytes and integers exactly,
floats within 1e-9 (curve coefficients 1e-12). pow and log2 make the floats libm-dependent in the last bit, so
check_drift.py compares this file with its float tolerance. Synthetic numbers only, never footage. Deterministic; run from
anywhere.
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-render/clip-grade-cases.json'
LOOKS = ROOT / 'shared/looks/clip-looks.json'

W = (0.2126, 0.7152, 0.0722)
M32 = 0xFFFFFFFF
SEED = 0x9E3779B9
SLIDERS = ['exposure', 'temperature', 'tint', 'highlights', 'shadows', 'vibrance', 'fade', 'vignette', 'grain']
ADJUSTMENTS = ['brightness', 'contrast', 'saturation', 'warmth']
DEFAULTS = {'clipId': 'clip-main', 'speed': 1, 'shape': None, 'look': 'original', 'gainDb': 0, 'fadeInSeconds': 0,
            'fadeOutSeconds': 0, 'muteSource': False, 'flipHorizontal': False, 'rotationDegrees': 0}

# The maths note's E-inputs as stored bytes, plus the spec's deep and very deep skin swatches (section 4.3).
SWATCHES = {
    'grey': [128, 128, 128], 'skin': [217, 158, 128], 'highlight': [235, 235, 235], 'white': [255, 255, 255],
    'shadow': [13, 13, 13], 'blue': [26, 51, 230], 'dullBlue': [102, 115, 140], 'red': [230, 26, 26],
    'deepSkin': [120, 78, 58], 'veryDeepSkin': [72, 46, 34],
}


def luma(c):
    return W[0] * c[0] + W[1] * c[1] + W[2] * c[2]


def clamp01(v):
    return min(1.0, max(0.0, v))


def smoothstep(e0, e1, v):
    t = clamp01((v - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)


def byte(v):
    return int(math.floor(255 * clamp01(v) + 0.5))


def unit(rgb8):
    return [c / 255 for c in rgb8]


def round_half_away(v):
    return int(math.floor(abs(v) + 0.5)) * (1 if v >= 0 else -1)


# ---------------- stage P: the Fix ----------------
def primary_gains(exposure, temperature, tint):
    t, k = temperature / 100, tint / 100
    raw = [2 ** (0.25 * t + 0.10 * k), 2 ** (-0.20 * k), 2 ** (-0.25 * t + 0.10 * k)]
    n = luma(raw)
    e = 2 ** (0.009 * exposure)
    return [r / n * e for r in raw]


def shoulder(g):
    """Per-channel shoulder constants (u_max, alpha), or None when the gain doesn't brighten."""
    if g <= 1:
        return None
    u_max = (g - 0.8) / 0.2
    return [u_max, 1 - 1 / u_max]


def primary_channel(x, g, constants):
    z = g * clamp01(x)
    if constants is None or z <= 0.8:
        return z
    u = (z - 0.8) / 0.2
    return 0.8 + 0.2 * u / (1 + constants[1] * u)


# ---------------- stages L and A: today's ClipLookRecipe numbers ----------------
def saturation_matrix(s, scale=1.0):
    return [[scale * ((1 - s) * W[c] + (s if r == c else 0)) for c in range(3)] for r in range(3)]


def look_recipe(look):
    if look == 'original':
        return None
    if look == 'muted':
        return saturation_matrix(0.65, 0.96), [0.04] * 3, None
    if look == 'warm':
        return [[1.06, 0, 0], [0, 1.01, 0], [0, 0, 0.9]], [0.01] * 3, None
    if look == 'bw':
        return saturation_matrix(0.0), [0, 0, 0], [0, 0.7, 0.9, -0.6]
    raise ValueError(look)


def adjustments_recipe(a):
    if not any(a.get(name, 0) for name in ADJUSTMENTS):
        return None
    contrast = 1 + a.get('contrast', 0) * 0.005
    saturation = 1 + a.get('saturation', 0) * 0.01
    warmth = a.get('warmth', 0) * 0.0018
    offset = a.get('brightness', 0) * 0.0016 + (1 - contrast) * 0.5
    gains = [1 + warmth, 1.0, 1 - warmth]
    matrix = [[v * g for v in row] for row, g in zip(saturation_matrix(saturation, contrast), gains)]
    return matrix, [offset * g for g in gains], None


def run_recipe(recipe, x):
    """A matrix and bias, then the optional cubic after a clamp; no clamp after, as Core Image."""
    if recipe is None:
        return list(x)
    matrix, bias, cubic = recipe
    out = []
    for r in range(3):
        v = bias[r]
        for c in range(3):
            v += matrix[r][c] * x[c]
        if cubic:
            v = clamp01(v)
            q = v * v
            v = cubic[0] + cubic[1] * v + cubic[2] * q + cubic[3] * q * v
        out.append(v)
    return out


# ---------------- stage T ----------------
def segments(Y):
    h = 0.25
    d = [(Y[i + 1] - Y[i]) / h for i in range(4)]
    m = [d[0], 0.0, 0.0, 0.0, d[3]]
    for i in range(1, 4):
        m[i] = 2 * d[i - 1] * d[i] / (d[i - 1] + d[i]) if d[i - 1] > 0 and d[i] > 0 else 0.0
    segs = [[Y[i], h * m[i], 3 * (Y[i + 1] - Y[i]) - 2 * h * m[i] - h * m[i + 1], 2 * (Y[i] - Y[i + 1]) + h * m[i] + h * m[i + 1]]
            for i in range(4)]
    return m, segs


def evaluate(segs, v):
    v = clamp01(v)
    i = min(3, int(math.floor(4 * v)))
    t = 4 * v - i
    c0, c1, c2, c3 = segs[i]
    return c0 + t * (c1 + t * (c2 + t * c3))


def tone_knots(highlights, shadows):
    return [0.0, 0.25 + 0.12 * shadows / 100, 0.5, 0.75 + 0.12 * highlights / 100, 1.0]


def curve_knots(values):
    return [v / 1000 for v in values]


def vibrance(y, amount):
    v = amount / 100
    l = luma(y)
    c = max(y) - min(y)
    r, g, b = y
    sk = 0.0
    if r >= g >= b and c > 0:
        q = ((g - b) / c - 0.45) / 0.35
        sk = max(0.0, 1 - q * q) * smoothstep(0.02, 0.10, c)
    w = (1 - c) * (1 - c) * (1 - 0.6 * sk) if v >= 0 else (0.5 + 0.5 * c) * (1 - 0.6 * sk)
    k = 1 + v * w
    for ch in y:
        d = ch - l
        if d > 1e-6:
            k = min(k, (1 - l) / d)
        elif d < -1e-6:
            k = min(k, l / -d)
    return [l + k * (ch - l) for ch in y]


def hue_vector(hue):
    hp = (hue % 360) / 60
    i = int(math.floor(hp)) % 6
    f = hp - math.floor(hp)
    rgb = [(1, f, 0), (1 - f, 1, 0), (0, 1, f), (0, 1 - f, 1), (f, 0, 1), (1, 0, 1 - f)][i]
    l = luma(rgb)
    return [ch - l for ch in rgb]


def split_constants(split):
    shadow = [0.12 * split['shadowSaturation'] / 100 * c for c in hue_vector(split['shadowHue'])]
    highlight = [0.12 * split['highlightSaturation'] / 100 * c for c in hue_vector(split['highlightHue'])]
    return shadow, highlight, 0.25 * split['balance'] / 100


def split_tone(y, constants):
    shadow, highlight, balance = constants
    t = clamp01(luma(y) + balance)
    ws, wh = (1 - t) * (1 - t), t * t
    return [y[i] + ws * shadow[i] + wh * highlight[i] for i in range(3)]


def fade(y, amount):
    strength = 0.0015 * amount
    out = []
    for v in y:
        c = clamp01(v)
        out.append(c + strength * (1 - c) * (1 - c) * (1 - c))
    return out


# ---------------- the whole grade (before F) ----------------
def grade_values(grade):
    return {name: (grade or {}).get(name, 0) for name in SLIDERS}


def chain(rgb8, look='original', adjustments=None, grade=None, override=None, stages=None):
    """The graded colour before F, in double; `stages` collects each stage's output for the published walk-throughs."""
    values = grade_values(grade)
    grade = grade or {}
    a = grade.get('amount', 100) / 100
    o = unit(rgb8)
    if values['exposure'] or values['temperature'] or values['tint']:
        gains = primary_gains(values['exposure'], values['temperature'], values['tint'])
        f = [primary_channel(o[c], gains[c], shoulder(gains[c])) for c in range(3)]
    else:
        f = [clamp01(v) for v in o]
    if stages is not None:
        stages['P'] = f
    if a == 0:
        return f
    y = run_recipe(look_recipe(override or look), f)
    if stages is not None:
        stages['L'] = y
    y = run_recipe(adjustments_recipe(adjustments or {}), y)
    if stages is not None:
        stages['A'] = y
    y = [clamp01(v) for v in y]
    if values['highlights'] or values['shadows']:
        segs = segments(tone_knots(values['highlights'], values['shadows']))[1]
        l = luma(y)
        delta = evaluate(segs, l) - l
        y = [v + delta for v in y]
        if stages is not None:
            stages['T1'] = y
    if values['vibrance']:
        y = vibrance(y, values['vibrance'])
        if stages is not None:
            stages['T2'] = y
    curve = grade.get('curve')
    if curve:
        if 'master' in curve:
            segs = segments(curve_knots(curve['master']))[1]
            y = [evaluate(segs, v) for v in y]
        for index, name in enumerate(['red', 'green', 'blue']):
            if name in curve:
                segs = segments(curve_knots(curve[name]))[1]
                y[index] = evaluate(segs, y[index])
    if grade.get('splitTone'):
        y = split_tone(y, split_constants(grade['splitTone']))
    if values['fade']:
        y = fade(y, values['fade'])
    g = [clamp01(v) for v in y]
    if a == 1:
        return g
    return [f[i] + a * (g[i] - f[i]) for i in range(3)]


# ---------------- stage F ----------------
def vignette_weight(x, y, width, height):
    nx = (2 * x + 1 - width) / width
    ny = (2 * y + 1 - height) / height
    q = (nx * nx * width + ny * ny * height) / (width + height)
    t = clamp01((q - 0.16) / 0.84)
    return q, t * t * (3 - 2 * t)


def pcg(v):
    state = (v * 747796405 + 2891336453) & M32
    word = (((state >> ((state >> 28) + 4)) ^ state) * 277803737) & M32
    return ((word >> 22) ^ word) & M32


def frame_hash(n):
    return pcg((n ^ SEED) & M32)


def frame_index(seconds, fps):
    return int(math.floor(seconds * fps + 0.5)) & M32


def cell_size(width, height):
    return 2 if min(width, height) >= 720 else 1


def grain_cell(x, y, width, height):
    s = cell_size(width, height)
    qx, qy = 2 * x + 1 - s, 2 * y + 1 - s
    i0, j0 = qx // (2 * s), qy // (2 * s)
    fx, fy = 4 * (qx - 2 * s * i0) // (2 * s), 4 * (qy - 2 * s * j0) // (2 * s)
    return s, i0 + 1, j0 + 1, fx, fy


def grain_total(x, y, width, height, hashed):
    _, a, b, fx, fy = grain_cell(x, y, width, height)

    def value(i, j):
        return (pcg((i + pcg((j + hashed) & M32)) & M32) >> 16) - 32768

    total = ((4 - fx) * value(a, b) + fx * value(a + 1, b)) * (4 - fy) + ((4 - fx) * value(a, b + 1) + fx * value(a + 1, b + 1)) * fy
    assert abs(total) <= 2 ** 19
    return total


def demo_rect(width, height, motion, placement):
    """The context demo's rendered rectangle in output pixels: its placement (normalised, top-left) mapped through the motion
    crop and clamped to the frame. Grain skips pixels whose centre lies inside it."""
    scale, ax, ay = motion['scale'], motion['anchorX'], motion['anchorY']
    crop_w, crop_h = width / scale, height / scale
    crop_x, crop_y = (width - crop_w) * ax, (height - crop_h) * ay
    x0 = (placement['x'] * width - crop_x) * scale
    y0 = (placement['y'] * height - crop_y) * scale
    x1 = ((placement['x'] + placement['width']) * width - crop_x) * scale
    y1 = ((placement['y'] + placement['height']) * height - crop_y) * scale
    return [min(float(width), max(0.0, x0)), min(float(height), max(0.0, y0)), min(float(width), max(0.0, x1)),
            min(float(height), max(0.0, y1))]


def grain_skipped(x, y, rect):
    if rect is None:
        return False
    cx, cy = x + 0.5, y + 0.5
    return rect[0] <= cx < rect[2] and rect[1] <= cy < rect[3]


def finish(rgb8, x, y, width, height, n, vignette=0, grain=0, amount=100, hole=None):
    a = amount / 100
    v = unit(rgb8)
    if a == 0 or (vignette == 0 and grain == 0):
        return v
    vignette_strength = 0.006 * vignette * a
    grain_strength = 0.0012 * grain * a
    if vignette_strength > 0:
        factor = 1 - vignette_strength * vignette_weight(x, y, width, height)[1]
        v = [c * factor for c in v]
    if grain_strength > 0 and not grain_skipped(x, y, hole):
        l = luma(v)
        m = 0.25 + 3 * l * (1 - l)
        g = grain_total(x, y, width, height, frame_hash(n)) / 2 ** 20
        v = [c + grain_strength * m * g for c in v]
    return v


# ---------------- Auto (ClipColorFix.measure) and the light facts ----------------
def pixels(frame):
    rgb = frame['rgb']
    return [unit(rgb[i:i + 3]) for i in range(0, len(rgb), 3)]


def face_pixels(frame):
    face = frame.get('face')
    if face is None:
        return []
    w, h = frame['width'], frame['height']
    x0, x1 = face['x'] * w, (face['x'] + face['width']) * w
    y0, y1 = face['y'] * h, (face['y'] + face['height']) * h
    found = []
    for index, value in enumerate(pixels(frame)):
        cx, cy = index % w + 0.5, index // w + 0.5
        if x0 <= cx < x1 and y0 <= cy < y1:
            found.append(value)
    return found


def median(values):
    ordered = sorted(values)
    n = len(ordered)
    return ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2


def percentile95(values):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def chroma(c):
    return max(c) - min(c)


def is_neutral(c, auto):
    l = luma(c)
    return chroma(c) < auto['neutralChroma'] and auto['neutralLumaMin'] <= l <= auto['neutralLumaMax']


def neutral_means(values, auto):
    neutral = [c for c in values if is_neutral(c, auto)]
    if not neutral:
        return None
    sums = [0.0, 0.0, 0.0]
    for c in neutral:
        for i in range(3):
            sums[i] += c[i]
    return [s / len(neutral) for s in sums]


def dead_zone(value, limit, zone):
    bounded = min(limit, max(-limit, value))
    assert abs(abs(bounded) % 1 - 0.5) > 1e-6, value  # off a rounding edge, since log2 differs by a last bit across platforms
    point = round_half_away(bounded)
    return 0 if abs(point) <= zone else point


def measure(frames, auto):
    frames = frames[:int(auto['frames'])]
    every = [c for frame in frames for c in pixels(frame)]
    if not every:
        return {'exposure': 0, 'temperature': 0, 'tint': 0}
    means = neutral_means(every, auto)
    temperature = tint = 0
    if means is not None:
        r, g, b = means
        t = 2 * math.log2(b / r)
        k = math.log2(g * g / (r * b)) / 0.6
        temperature = dead_zone(auto['balanceScale'] * t, auto['balanceLimit'], auto['balanceDeadZone'])
        tint = dead_zone(auto['balanceScale'] * k, auto['balanceLimit'], auto['balanceDeadZone'])
    faces = [c for frame in frames for c in face_pixels(frame)]
    if faces:
        middle, target = median([luma(c) for c in faces]), auto['faceTarget']
    else:
        middle, target = median([luma(c) for c in every]), auto['frameTarget']
    raw = auto['exposureStrength'] * math.log2(target / middle) / 0.009 if middle > 0 else math.inf
    exposure = dead_zone(raw, auto['exposureLimit'], auto['exposureDeadZone'])
    if faces and sum(1 for c in faces if luma(c) > auto['faceClipLuma']) / len(faces) > auto['faceClipShare']:
        exposure = min(exposure, 0)
    return {'exposure': exposure, 'temperature': temperature, 'tint': tint}


def light_facts(frame, auto, light):
    values = pixels(frame)
    lumas = [luma(c) for c in values]
    face = face_pixels(frame)
    face_lumas = [luma(c) for c in face]
    facts = {'medianLuma': median(lumas), 'p95Luma': percentile95(lumas),
             'faceMeanLuma': sum(face_lumas) / len(face_lumas) if face else None,
             'faceMedianLuma': median(face_lumas) if face else None,
             'faceClippedShare': sum(1 for c in face if max(c) >= light['clippedChannel']) / len(face) if face else None,
             'neutralMeans': neutral_means(values, auto),
             'meanChroma': sum(chroma(c) for c in values) / len(values)}
    notes = []
    if facts['faceMedianLuma'] is not None and facts['faceMedianLuma'] < light['dimFaceLuma']:
        notes.append('face a little dark')
    if facts['faceClippedShare'] is not None and facts['faceClippedShare'] > light['clippedShare']:
        notes.append(f"highlights clipped {round_half_away(facts['faceClippedShare'] * 100)}%")
    if facts['neutralMeans'] is not None:
        r, g, b = facts['neutralMeans']
        if r - b > light['warmCool']:
            notes.append('warm-yellow cast')
        elif b - r > light['warmCool']:
            notes.append('cool-blue cast')
        if g - (r + b) / 2 > light['greenMagenta']:
            notes.append('green cast')
        elif (r + b) / 2 - g > light['greenMagenta']:
            notes.append('magenta cast')
    if facts['meanChroma'] < light['lowColor']:
        notes.append('low color')
    elif facts['meanChroma'] > light['highColor']:
        notes.append('high color')
    facts['notes'] = notes
    facts['line'] = 'light: ' + (' · '.join(notes) if notes else 'even')
    return facts


# ---------------- vectors ----------------
def entry(look='original', adjustments=None, grade=None):
    """A clipControls entry as a project stores it: every slider key of a colorGrade, amount omitted at 100."""
    result = {**DEFAULTS, 'look': look}
    if adjustments and any(adjustments.get(name, 0) for name in ADJUSTMENTS):
        result['colorAdjustments'] = {name: adjustments.get(name, 0) for name in ADJUSTMENTS}
    if grade:
        stored = {}
        if grade.get('preset'):
            stored['preset'] = grade['preset']
        if grade.get('amount', 100) != 100:
            stored['amount'] = grade['amount']
        stored.update({name: grade.get(name, 0) for name in SLIDERS})
        for key in ('curve', 'splitTone'):
            if key in grade:
                stored[key] = grade[key]
        neutral = all(stored[name] == 0 for name in SLIDERS) and 'amount' not in stored and 'curve' not in stored and 'splitTone' not in stored
        if not neutral:
            result['colorGrade'] = stored
    return result


def look_controls(look, amount):
    grade = dict(look['grade'])
    if amount != 100:
        grade['amount'] = amount
    if look['id'] != 'original':
        grade['preset'] = look['id']
    return entry(look['base'], look['adjustments'], grade)


def check_bytes(case, label, grade=None):
    """A byte computed through pow (the Fix's gains) must not sit on a rounding edge, so libm's last-bit differences between
    platforms round the same way. Every other stage is basic IEEE arithmetic in a fixed order, identical everywhere."""
    values = grade_values(grade)
    if not (values['exposure'] or values['temperature'] or values['tint']):
        return
    for value in case:
        scaled = 255 * clamp01(value) + 0.5
        if 0 < clamp01(value) < 1:
            assert abs(scaled - round(scaled)) > 1e-6, (label, value)


def graded_case(label, rgb8, look='original', adjustments=None, grade=None, override=None, floats=True):
    out = chain(rgb8, look, adjustments, grade, override)
    check_bytes(out, label, grade)
    case = {'id': label, 'controls': entry(look, adjustments, grade)}
    if override:
        case['override'] = override
    case['input'] = rgb8
    if floats:
        case['output'] = out
    case['bytes'] = [byte(v) for v in out]
    return case


def primaries():
    fixes = [('exposure +50', 50, 0, 0), ('exposure -50', -50, 0, 0), ('temperature +60 tint -20', 0, 60, -20),
             ('temperature +100', 0, 100, 0), ('temperature -100', 0, -100, 0), ('tint +100', 0, 0, 100),
             ('every Fix', 30, -45, 25)]
    result = []
    for label, exposure, temperature, tint in fixes:
        gains = primary_gains(exposure, temperature, tint)
        result.append({'id': label, 'fix': {'exposure': exposure, 'temperature': temperature, 'tint': tint}, 'gains': gains,
                       'shoulders': [shoulder(g) for g in gains]})
    return result


def control_cases():
    cases = []
    for name in ['grey', 'skin', 'highlight', 'white', 'shadow']:
        cases.append(graded_case(f'E1 exposure +50 {name}', SWATCHES[name], grade={'exposure': 50}))
    for name in ['grey', 'white']:
        cases.append(graded_case(f'E1 exposure -50 {name}', SWATCHES[name], grade={'exposure': -50}))
    for name in ['grey', 'blue', 'white', 'skin']:
        cases.append(graded_case(f'E2 temperature +60 tint -20 {name}', SWATCHES[name], grade={'temperature': 60, 'tint': -20}))
    for name in ['grey', 'skin', 'shadow', 'highlight', 'white', 'dullBlue']:
        cases.append(graded_case(f'E3 highlights -60 shadows +40 {name}', SWATCHES[name], grade={'highlights': -60, 'shadows': 40}))
    for amount in [80, -60]:
        for name in ['skin', 'dullBlue', 'red', 'blue', 'grey']:
            cases.append(graded_case(f'E4 vibrance {amount:+d} {name}', SWATCHES[name], grade={'vibrance': amount}))
    for name in ['shadow', 'grey', 'highlight', 'white']:
        cases.append(graded_case(f'E5 fade 50 {name}', SWATCHES[name], grade={'fade': 50}))
    split = {'shadowHue': 200, 'shadowSaturation': 40, 'highlightHue': 35, 'highlightSaturation': 30, 'balance': 0}
    for name in ['shadow', 'grey', 'highlight']:
        cases.append(graded_case(f'E5 split tone {name}', SWATCHES[name], grade={'splitTone': split}))
    cases.append(graded_case('split tone balance +60 skin', SWATCHES['skin'],
                             grade={'splitTone': {**split, 'balance': 60}}))
    cases.append(graded_case('channel curves skin', SWATCHES['skin'],
                             grade={'curve': {'red': [0, 270, 520, 770, 1000], 'blue': [60, 260, 480, 720, 940]}}))
    cases.append(graded_case('master and green curves dull blue', SWATCHES['dullBlue'],
                             grade={'curve': {'master': [40, 270, 500, 730, 950], 'green': [0, 250, 500, 800, 1000]}}))
    cases.append(graded_case('flat curve segment grey', SWATCHES['grey'], grade={'curve': {'master': [0, 300, 300, 700, 1000]}}))
    cases.append(graded_case('every T control skin', SWATCHES['skin'],
                             grade={'highlights': 30, 'shadows': -20, 'vibrance': 40, 'fade': 30, 'curve': {'master': [20, 240, 510, 760, 980]},
                                    'splitTone': {'shadowHue': 220, 'shadowSaturation': 30, 'highlightHue': 30, 'highlightSaturation': 20, 'balance': -40}}))
    cases.append(graded_case('amount 0 keeps the Fix skin', SWATCHES['skin'], look='bw', grade={'temperature': 30, 'amount': 0}))
    cases.append(graded_case('amount 0 without a Fix red', SWATCHES['red'], look='warm', adjustments={'contrast': 40}, grade={'amount': 0}))
    cases.append(graded_case('muted at 70 skin', SWATCHES['skin'], look='muted', grade={'preset': 'muted', 'amount': 70}))
    cases.append(graded_case('timed B&W over Warm Print values skin', SWATCHES['skin'], adjustments={'saturation': -10, 'warmth': 26},
                             grade={'highlights': -12, 'fade': 20, 'amount': 70}, override='bw'))
    cases.append(graded_case('Fix on B&W blue', SWATCHES['blue'], look='bw', grade={'temperature': 50, 'tint': -30}))
    cases.append(graded_case('warm over highlight, unclamped into contrast', SWATCHES['highlight'], look='warm',
                             adjustments={'contrast': 40}))
    return cases


def curve_cases():
    knots = [('highlights -60 shadows +40', tone_knots(-60, 40)), ('highlights +100 shadows -100', tone_knots(100, -100)),
             ('highlights -100 shadows +100', tone_knots(-100, 100)), ('highlights -20 shadows +15', tone_knots(-20, 15)),
             ('Warm Print master', curve_knots([0, 245, 500, 760, 965])), ('Matte Film master', curve_knots([40, 270, 500, 730, 950])),
             ('flat segment', curve_knots([0, 300, 300, 700, 1000])), ('all flat', curve_knots([500, 500, 500, 500, 500]))]
    samples = [-0.1, 0, 0.05, 0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 0.95, 1, 1.2]
    result = []
    for label, Y in knots:
        tangents, segs = segments(Y)
        result.append({'id': label, 'knots': Y, 'tangents': tangents, 'segments': segs,
                       'samples': [[v, evaluate(segs, v)] for v in samples]})
    return result


def vignette_cases():
    points = [(1080, 1920, 540, 960), (1080, 1920, 0, 960), (1080, 1920, 540, 0), (1080, 1920, 0, 0), (1080, 1920, 270, 480),
              (1080, 1920, 5, 7), (1080, 1920, 1079, 1919), (1920, 1080, 0, 540), (1920, 1080, 960, 0), (1080, 1350, 0, 675),
              (1080, 1350, 540, 0), (1080, 1080, 0, 540), (144, 144, 10, 20), (160, 90, 159, 0)]
    result = []
    for width, height, x, y in points:
        q, s = vignette_weight(x, y, width, height)
        result.append({'width': width, 'height': height, 'x': x, 'y': y, 'q': q, 's': s})
    return result


def grain_cases():
    points = [(1080, 1920, 5, 7, 0), (1080, 1920, 0, 0, 0), (1080, 1920, 1, 0, 0), (1080, 1920, 0, 1, 0), (1080, 1920, 1079, 1919, 0),
              (1080, 1920, 0, 0, 1), (1080, 1920, 5, 7, 1), (1080, 1920, 2, 3, 29), (1920, 1080, 1919, 1079, 7),
              (1080, 1080, 540, 540, 300), (640, 360, 0, 0, 0), (640, 360, 17, 33, 2), (719, 1280, 718, 1279, 12345)]
    result = []
    for width, height, x, y, n in points:
        s, a, b, fx, fy = grain_cell(x, y, width, height)
        total = grain_total(x, y, width, height, frame_hash(n))
        result.append({'width': width, 'height': height, 'x': x, 'y': y, 'n': n, 'cellSize': s, 'a': a, 'b': b,
                       'fx4': fx, 'fy4': fy, 'total': total})
    return result


def finish_cases():
    rows = [
        ('E6 vignette 50 centre', [128] * 3, 1080, 1920, 540, 960, 0, {'vignette': 50}),
        ('E6 vignette 50 left middle', [128] * 3, 1080, 1920, 0, 960, 0, {'vignette': 50}),
        ('E6 vignette 50 top middle', [128] * 3, 1080, 1920, 540, 0, 0, {'vignette': 50}),
        ('E6 vignette 50 corner', [128] * 3, 1080, 1920, 0, 0, 0, {'vignette': 50}),
        ('E6 vignette 50 landscape left middle', [128] * 3, 1920, 1080, 0, 540, 0, {'vignette': 50}),
        ('E7 grain 50 (5,7)', [128] * 3, 1080, 1920, 5, 7, 0, {'grain': 50}),
        ('E7 grain 50 (0,0)', [128] * 3, 1080, 1920, 0, 0, 0, {'grain': 50}),
        ('E7 grain 50 (1,0)', [128] * 3, 1080, 1920, 1, 0, 0, {'grain': 50}),
        ('E7 grain 50 (0,1)', [128] * 3, 1080, 1920, 0, 1, 0, {'grain': 50}),
        ('E7 grain 50 last pixel', [128] * 3, 1080, 1920, 1079, 1919, 0, {'grain': 50}),
        ('E7 grain 50 (5,7) frame 1', [128] * 3, 1080, 1920, 5, 7, 1, {'grain': 50}),
        ('E8 Golden Hour finish at 100%', [242, 159, 107], 1080, 1920, 5, 7, 0, {'vignette': 20}),
        ('E8 Golden Hour finish at 60%', [234, 158, 113], 1080, 1920, 5, 7, 0, {'vignette': 20, 'amount': 60}),
        ('E8 Matte Film finish at 100%', [196, 154, 131], 1080, 1920, 5, 7, 0, {'vignette': 15, 'grain': 30}),
        ('E8 Matte Film finish at 60%', [205, 155, 130], 1080, 1920, 5, 7, 0, {'vignette': 15, 'grain': 30, 'amount': 60}),
        ('Throwback finish corner frame 12', [227, 158, 122], 1080, 1920, 3, 2, 12, {'vignette': 40, 'grain': 45}),
        ('grain 100 on a dark pixel', [20, 18, 16], 1920, 1080, 700, 400, 3, {'grain': 100}),
        ('amount 0 skips the finish', [128] * 3, 1080, 1920, 0, 0, 0, {'vignette': 80, 'grain': 80, 'amount': 0}),
        ('grain inside the demo hole', [128] * 3, 1080, 1920, 5, 7, 0, {'vignette': 50, 'grain': 50, 'hole': [0, 0, 1080, 1920]}),
        ('grain beside the demo hole', [128] * 3, 1080, 1920, 5, 7, 0, {'vignette': 50, 'grain': 50, 'hole': [6, 0, 1080, 1920]}),
    ]
    result = []
    for label, rgb8, width, height, x, y, n, controls in rows:
        vignette, grain, amount, hole = controls.get('vignette', 0), controls.get('grain', 0), controls.get('amount', 100), controls.get('hole')
        out = finish(rgb8, x, y, width, height, n, vignette, grain, amount, hole)
        case = {'id': label, 'vignette': vignette, 'grain': grain, 'amount': amount, 'width': width, 'height': height,
                'x': x, 'y': y, 'n': n}
        if hole is not None:
            case['hole'] = hole
        case.update({'input': rgb8, 'output': out, 'bytes': [byte(v) for v in out]})
        result.append(case)
    return result


def demo_cases():
    rows = [
        ('no motion: the whole frame', 1080, 1920, {'scale': 1, 'anchorX': 0.5, 'anchorY': 0.5}, {'x': 0, 'y': 0, 'width': 1, 'height': 1}),
        ('a zoom keeps the whole frame', 1080, 1920, {'scale': 1.2, 'anchorX': 0.3, 'anchorY': 0.7}, {'x': 0, 'y': 0, 'width': 1, 'height': 1}),
        ('an inset under a centred zoom', 1080, 1920, {'scale': 1.25, 'anchorX': 0.5, 'anchorY': 0.5},
         {'x': 0.25, 'y': 0.5, 'width': 0.5, 'height': 0.25}),
        ('an inset under a corner zoom', 1920, 1080, {'scale': 1.35, 'anchorX': 0, 'anchorY': 1},
         {'x': 0.6, 'y': 0.05, 'width': 0.375, 'height': 0.5}),
    ]
    probes = [(0, 0), (5, 7), (539, 959), (1079, 1919), (300, 1000), (700, 1500), (1500, 100), (1919, 1079), (1000, 300)]
    result = []
    for label, width, height, motion, placement in rows:
        rect = demo_rect(width, height, motion, placement)
        inside = [[x, y, grain_skipped(x, y, rect)] for x, y in probes if x < width and y < height]
        for x, y, _ in inside:
            for edge, centre in ((rect[0], x + 0.5), (rect[2], x + 0.5), (rect[1], y + 0.5), (rect[3], y + 0.5)):
                assert abs(edge - centre) > 1e-6, (label, x, y)
        result.append({'id': label, 'width': width, 'height': height, 'motion': motion, 'placement': placement, 'rect': rect,
                       'probes': inside})
    return result


def chain_cases():
    golden = {'highlights': -20, 'shadows': 15, 'vibrance': 25, 'vignette': 20}
    result = []
    for amount in (100, 60):
        for name in ('skin', 'highlight', 'dullBlue'):
            stages = {}
            grade = {**golden, 'temperature': 20, 'amount': amount}
            out = chain(SWATCHES[name], 'warm', {'brightness': 4, 'contrast': 10}, grade, stages=stages)
            check_bytes(out, name, grade)
            case = {'id': f'E8 Golden Hour {amount}% {name}', 'controls': entry('warm', {'brightness': 4, 'contrast': 10}, grade),
                    'input': SWATCHES[name], 'stages': {key: stages[key] for key in ('P', 'L', 'A', 'T1', 'T2')},
                    'output': out, 'bytes': [byte(v) for v in out]}
            result.append(case)
    return result


def look_cases(looks):
    result = []
    for look in looks:
        for amount in (100, 70):
            controls = look_controls(look, amount)
            bytes_ = {}
            for name, rgb8 in SWATCHES.items():
                out = chain(rgb8, controls['look'], controls.get('colorAdjustments'), controls.get('colorGrade'))
                bytes_[name] = [byte(v) for v in out]
            result.append({'look': look['id'], 'amount': amount, 'controls': controls, 'bytes': bytes_})
    return result


def adjustment_cases():
    rows = [('brightness +25 contrast +20 saturation -50 warmth +50', {'brightness': 25, 'contrast': 20, 'saturation': -50, 'warmth': 50}, 'original'),
            ('brightness -40', {'brightness': -40}, 'original'), ('contrast -100', {'contrast': -100}, 'original'),
            ('saturation +100', {'saturation': 100}, 'original'), ('warmth -100', {'warmth': -100}, 'original'),
            ('Clean Pop values over Warm', {'brightness': 8, 'contrast': 22, 'saturation': 18}, 'warm'),
            ('contrast +40 over Muted', {'contrast': 40}, 'muted'), ('warmth +35 over B&W', {'warmth': 35}, 'bw')]
    result = []
    for label, adjustments, base in rows:
        bytes_ = {}
        for name, rgb8 in SWATCHES.items():
            out = chain(rgb8, base, adjustments)
            bytes_[name] = [byte(v) for v in out]
        result.append({'id': label, 'controls': entry(base, adjustments), 'bytes': bytes_})
    return result


# The spec's section 4.3 skin table: bytes at 100% on mid, deep and very deep skin.
SKIN_TABLE = {
    'naturalBoost': [[222, 158, 126], [122, 76, 54], [72, 43, 30]],
    'softSkin': [[214, 153, 122], [127, 84, 64], [81, 55, 42]],
    'evenLight': [[209, 150, 121], [129, 88, 68], [85, 59, 47]],
    'studioClean': [[219, 157, 126], [120, 75, 54], [69, 41, 28]],
    'brightAiry': [[212, 162, 137], [132, 96, 79], [93, 71, 60]],
    'boldPop': [[228, 161, 127], [126, 77, 53], [75, 43, 29]],
    'goldenHour': [[236, 160, 112], [137, 84, 54], [84, 51, 33]],
    'peachTone': [[225, 157, 124], [125, 77, 55], [76, 46, 32]],
    'warmPrint': [[219, 158, 122], [123, 80, 60], [74, 50, 39]],
    'matteFilm': [[196, 154, 131], [120, 92, 79], [82, 67, 60]],
    'throwback': [[227, 158, 122], [127, 80, 58], [79, 50, 37]],
    'tealAmber': [[219, 161, 130], [113, 76, 58], [62, 43, 33]],
    'cinematicSoft': [[210, 156, 128], [116, 78, 60], [68, 44, 33]],
    'moody': [[208, 162, 138], [102, 69, 53], [54, 33, 24]],
    'softBW': [[168, 168, 168], [86, 86, 86], [55, 55, 55]],
    'sepia': [[188, 174, 158], [91, 81, 71], [54, 46, 37]],
}


def skin_cases(looks):
    by_id = {look['id']: look for look in looks}
    result = []
    for look_id, expected in SKIN_TABLE.items():
        controls = look_controls(by_id[look_id], 100)
        found = [[byte(v) for v in chain(SWATCHES[name], controls['look'], controls.get('colorAdjustments'), controls.get('colorGrade'))]
                 for name in ('skin', 'deepSkin', 'veryDeepSkin')]
        assert found == expected, (look_id, found, expected)
        result.append({'look': look_id, 'controls': controls, 'mid': expected[0], 'deep': expected[1], 'veryDeep': expected[2]})
    return result


def frame(width, height, fill, rects=(), face=None):
    """A synthetic frame: one colour with rectangles painted over it (x, y, w, h in pixels, colour)."""
    grid = [list(fill) for _ in range(width * height)]
    for x0, y0, w, h, colour in rects:
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                grid[y * width + x] = list(colour)
    result = {'width': width, 'height': height, 'rgb': [c for pixel in grid for c in pixel]}
    if face is not None:
        result['face'] = face
    return result


def measure_cases(auto, light):
    face = {'x': 0.3, 'y': 0.25, 'width': 0.4, 'height': 0.5}
    grey_card = frame(10, 8, (107, 107, 107))
    warm_room = frame(10, 8, (140, 128, 120), [(0, 0, 10, 2, (200, 120, 60))])
    green_room = frame(10, 8, (112, 128, 110), [(0, 6, 10, 2, (40, 90, 160))])
    dim_face = frame(10, 8, (90, 90, 92), [(3, 2, 4, 4, (88, 60, 48))], face)
    bright_face = frame(20, 16, (128, 128, 128), [(6, 4, 8, 8, (120, 92, 80)), (6, 4, 1, 1, (255, 250, 245))], face)
    clipped_face = frame(10, 8, (128, 128, 128), [(3, 2, 4, 4, (110, 80, 64)), (3, 2, 2, 1, (250, 246, 244))], face)
    colourful = frame(10, 8, (220, 40, 40), [(0, 4, 10, 4, (30, 60, 220))])
    slight_cast = frame(10, 8, (109, 107, 106))
    cool_room = frame(12, 6, (70, 78, 90), [(0, 0, 6, 3, (40, 48, 70))])
    no_face_second = frame(10, 8, (60, 60, 62))
    rows = [
        ('grey at the frame target', [grey_card]),
        ('warm room', [warm_room]),
        ('green cast', [green_room]),
        ('dim face, raised to the limit', [dim_face]),
        ('one bright face pixel still lets exposure rise', [bright_face]),
        ('clipped face is never raised', [clipped_face]),
        ('no neutral pixels', [colourful]),
        ('a cast inside the dead zone', [slight_cast]),
        ('cool room, temperature at its limit', [cool_room]),
        ('faces pooled, frames without one ignored for exposure', [dim_face, no_face_second, bright_face]),
        ('only the first eight frames', [grey_card] * 8 + [frame(10, 8, (20, 20, 20))]),
        ('no frames', []),
    ]
    result = []
    for label, frames in rows:
        case = {'id': label, 'frames': frames, 'fix': measure(frames, auto),
                'facts': [light_facts(f, auto, light) for f in frames]}
        result.append(case)
    return result


def published_numbers(looks):
    """The maths note's and the spec's published numbers, so a change to the chain fails here first."""
    def run(name, **kwargs):
        return [byte(v) for v in chain(SWATCHES[name], **kwargs)]
    assert run('grey', grade={'exposure': 50}) == [175] * 3
    assert run('skin', grade={'exposure': 50}) == [247, 214, 175]
    assert run('highlight', grade={'exposure': 50}) == [251] * 3
    assert run('shadow', grade={'exposure': 50}) == [18] * 3
    assert run('grey', grade={'exposure': -50}) == [94] * 3
    assert run('white', grade={'exposure': -50}) == [187] * 3
    tt = {'temperature': 60, 'tint': -20}
    assert run('grey', grade=tt) == [136, 128, 110] and run('blue', grade=tt) == [28, 51, 198]
    assert run('white', grade=tt) == [255, 254, 220] and run('skin', grade=tt) == [227, 157, 110]
    assert [round(g, 6) for g in primary_gains(0, 100, 0)] == [1.155986, 0.972065, 0.817406]
    assert [round(g, 6) for g in primary_gains(0, -100, 0)] == [0.858202, 1.020580, 1.213681]
    assert run('skin', grade={'vibrance': 80}) == [225, 156, 122] and run('dullBlue', grade={'vibrance': 80}) == [95, 116, 155]
    assert run('red', grade={'vibrance': 80}) == [235, 25, 25] and run('grey', grade={'vibrance': 80}) == [128] * 3
    assert run('skin', grade={'vibrance': -60}) == [208, 160, 136] and run('red', grade={'vibrance': -60}) == [143, 49, 49]
    assert run('shadow', grade={'fade': 50}) == [29] * 3 and run('grey', grade={'fade': 50}) == [130] * 3
    split = {'splitTone': {'shadowHue': 200, 'shadowSaturation': 40, 'highlightHue': 35, 'highlightSaturation': 30, 'balance': 0}}
    assert run('shadow', grade=split) == [7, 14, 18] and run('highlight', grade=split) == [238, 235, 230]
    assert [round(v, 6) for v in hue_vector(200)] == [-0.549, 0.117667, 0.451]
    for (x, y, factor_byte) in [(540, 960, 128), (0, 960, 123), (540, 0, 105), (0, 0, 90), (270, 480, 127)]:
        assert byte(finish([128] * 3, x, y, 1080, 1920, 0, vignette=50)[0]) == factor_byte
    assert [pcg(v) for v in (0, 1, 2, 12345, 0xFFFFFFFF)] == [0x07BB2FE2, 0xA8BEEA3C, 0x7A7ECC88, 0xF45EAD0E, 0xE62A4902]
    assert frame_hash(0) == 0x9031965F and frame_hash(1) == 0x1591135A
    assert grain_total(5, 7, 1080, 1920, frame_hash(0)) == 241046 and grain_total(0, 0, 1080, 1920, frame_hash(0)) == -25165
    for (x, y, n, total) in [(1, 0, 0, -103842), (0, 1, 0, -217298), (1079, 1919, 0, -336726), (0, 0, 1, 18860), (5, 7, 1, -267334)]:
        assert grain_total(x, y, 1080, 1920, frame_hash(n)) == total
    assert byte(finish([128] * 3, 5, 7, 1080, 1920, 0, grain=50)[0]) == 132
    golden = dict(look='warm', adjustments={'brightness': 4, 'contrast': 10},
                  grade={'temperature': 20, 'highlights': -20, 'shadows': 15, 'vibrance': 25})
    assert run('skin', **golden) == [242, 159, 107]
    assert run('skin', **{**golden, 'grade': {**golden['grade'], 'amount': 60}}) == [234, 158, 113]
    assert run('highlight', **golden) == [255, 245, 207]
    assert [byte(v) for v in finish([242, 159, 107], 5, 7, 1080, 1920, 0, vignette=20)] == [213, 140, 94]
    by_id = {look['id']: look for look in looks}
    matte = look_controls(by_id['matteFilm'], 100)
    matte60 = look_controls(by_id['matteFilm'], 60)
    for name, at100, at60 in [('skin', [196, 154, 131], [205, 155, 130]), ('shadow', [36, 40, 41], [27, 29, 30]),
                              ('highlight', [219, 218, 215], [226, 225, 223]), ('dullBlue', [110, 120, 137], [107, 118, 138])]:
        assert run(name, look='original', adjustments=matte.get('colorAdjustments'), grade=matte['colorGrade']) == at100, name
        assert run(name, look='original', adjustments=matte60.get('colorAdjustments'), grade=matte60['colorGrade']) == at60, name
    assert [byte(v) for v in finish([196, 154, 131], 5, 7, 1080, 1920, 0, vignette=15, grain=30)] == [180, 142, 121]
    assert [byte(v) for v in finish([205, 155, 130], 5, 7, 1080, 1920, 0, vignette=15, grain=30, amount=60)] == [195, 148, 124]
    warm_print = by_id['warmPrint']
    edits = {**warm_print['grade'], 'vibrance': 20, 'highlights': -15, 'amount': 70}
    assert run('skin', adjustments=warm_print['adjustments'], grade=edits) == [219, 158, 122]
    assert run('skin', adjustments=warm_print['adjustments'], grade={**warm_print['grade'], 'amount': 70}) == [218, 158, 123]
    classic = {'cleanPop': [240, 163, 123], 'softLight': [217, 167, 142], 'coolFilm': [204, 164, 145], 'vintageFade': [202, 158, 134],
               'warm': [233, 162, 118], 'muted': [202, 165, 147], 'bw': [174, 174, 174]}
    for look_id, expected in classic.items():
        controls = look_controls(by_id[look_id], 100)
        assert run('skin', look=controls['look'], adjustments=controls.get('colorAdjustments'), grade=controls.get('colorGrade')) == expected


def generated():
    document = json.loads(LOOKS.read_text(encoding='utf-8'))
    looks = document['looks']
    auto, light = document['measure']['auto'], document['measure']['light']
    published_numbers(looks)
    hashes = [0, 1, 2, 29, 12345, 0xFFFFFFFF]
    return {
        'format': 'voxclip-clip-grade-cases/1',
        'looks': 'looks/clip-looks.json',
        'tolerance': {'bytes': 0, 'floats': 1e-9, 'coefficients': 1e-12},
        'swatches8': SWATCHES,
        'primary': primaries(),
        'controls': control_cases(),
        'curves': curve_cases(),
        'vignette': vignette_cases(),
        'pcg': [[v, pcg(v)] for v in (0, 1, 2, 12345, 0x9E3779B9, 0xFFFFFFFF)],
        'frameHash': [[n, frame_hash(n)] for n in hashes],
        'frameIndex': [{'seconds': s, 'fps': fps, 'n': frame_index(s, fps)} for s, fps in
                       ((0, 30), (0.5, 30), (1 / 30, 30), (0.016, 30), (0.017, 30), (2.5, 29.97), (10.01, 60), (59.99, 25), (1.234, 24))],
        'grain': grain_cases(),
        'demo': demo_cases(),
        'finish': finish_cases(),
        'chains': chain_cases(),
        'looksOnSwatches': look_cases(looks),
        'adjustments': adjustment_cases(),
        'skinCheck': skin_cases(looks),
        'measure': measure_cases(auto, light),
    }


def dump(document):
    lines = ['{']
    keys = list(document)
    for index, key in enumerate(keys):
        value = document[key]
        comma = ',' if index < len(keys) - 1 else ''
        if isinstance(value, list):
            lines.append(f'  {json.dumps(key)}: [')
            lines += ['    ' + json.dumps(item, ensure_ascii=False) + (',' if i < len(value) - 1 else '') for i, item in enumerate(value)]
            lines.append('  ]' + comma)
        else:
            lines.append(f'  {json.dumps(key)}: {json.dumps(value, ensure_ascii=False)}{comma}')
    return '\n'.join(lines + ['}']) + '\n'


def main():
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    document = generated()
    text = dump(document)
    assert json.loads(text) == document
    DESTINATION.write_text(text, encoding='utf-8')


if __name__ == '__main__':
    main()
