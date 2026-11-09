#!/usr/bin/env python3
"""Generate the Windows quad finder's vectors (ADR-R48 Windows, package W4).

Writes shared/fixtures/clip-frames/frame-quad-cases.json (schema voxclip-frame-quad-cases/1), a new file of its own so no
existing replay's keys or counts change. Windows has no VNDetectRectanglesRequest, so the C# Core finds screens with a pure
quad finder (QuadFinder.cs) on Vision's settings: at most 6, aspect 0.3-1, size >= 0.1 of the frame's short side,
confidence >= 0.6 and corners within 25 degrees of square. This file holds drawn grey frames and the quads drawn in them:

- `frames`: grey pictures drawn here with exact arithmetic (integers and Fractions; a rotation is a Pythagorean pair, never
  sin or cos), stored run-length encoded ("value*count" tokens over the rows, top-left first) with the SHA-256 of their bytes;
- `quads`: per frame, the drawn quads the finder must find (corners and bounding box, normalized, top-left origin, within
  `tolerance`), the drawn shapes it must not find, and how many it may return;
- `scans`: line boxes and quads through FrameScreens.detect (the shared twin, as tools/fixtures/clip-frames/
  generate_frame_decisions.py implements it) to the observation's textRects and screens. A case names a frame (the finder's
  quads go in) or lists quad boxes (exact).

The finder's own numbers are not pinned: only where the drawn quads are, and which ones Vision's settings keep. C#
FrameQuadVectorTests replays every case; there is no Mac twin, because the Mac reads Vision. Integer and exact rational
arithmetic only, then one float() per printed number, so byte-identical on every platform (check_drift.py lists it as EXACT).
Run from anywhere.
"""
import hashlib
import importlib.util
import json
import math
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-frames/frame-quad-cases.json'

sys.dont_write_bytecode = True
_SPEC = importlib.util.spec_from_file_location('frame_decisions', Path(__file__).resolve().parent / 'generate_frame_decisions.py')
DECISIONS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(DECISIONS)

MAXIMUM_OBSERVATIONS = 6
MINIMUM_ASPECT_RATIO = 0.3
MAXIMUM_ASPECT_RATIO = 1
MINIMUM_SIZE = 0.1
MINIMUM_CONFIDENCE = 0.6
QUADRATURE_TOLERANCE = 25
WORKING_LONG_SIDE = 640
# A found corner or bounding-box edge may sit this far (normalized, per axis) from the drawn one: 6.4 px on the 640 px
# working frame, about two pixels of blur and threshold plus the box average.
TOLERANCE = 0.01
# A scan's screen coverage compares within this share of the drawn one (found quads sit a pixel or two off).
COVERAGE_TOLERANCE = 0.08


# MARK: Drawing

class Canvas:
    def __init__(self, width, height, value):
        self.width, self.height = width, height
        self.pixels = bytearray([value]) * (width * height)

    def span(self, y, x0, x1, value):
        x0, x1 = max(0, x0), min(self.width, x1)
        if x1 > x0:
            start = y * self.width
            self.pixels[start + x0:start + x1] = bytes([value]) * (x1 - x0)

    def polygon(self, corners, value):
        """A convex polygon (Fraction or int corners): the pixels whose centres lie inside, left-closed on each row."""
        corners = [(Fraction(x), Fraction(y)) for x, y in corners]
        top = max(0, math.floor(min(y for _, y in corners)))
        bottom = min(self.height, math.ceil(max(y for _, y in corners)) + 1)
        for row in range(top, bottom):
            centre = Fraction(2 * row + 1, 2)
            crossings = []
            for index, (ax, ay) in enumerate(corners):
                bx, by = corners[(index + 1) % len(corners)]
                if ay == by or not (min(ay, by) <= centre < max(ay, by)):
                    continue
                crossings.append(ax + (centre - ay) * (bx - ax) / (by - ay))
            if len(crossings) < 2:
                continue
            left, right = min(crossings), max(crossings)
            self.span(row, math.ceil(left - Fraction(1, 2)), math.ceil(right - Fraction(1, 2)), value)

    def rect(self, x, y, width, height, value):
        for row in range(max(0, y), min(self.height, y + height)):
            self.span(row, x, x + width, value)

    def ellipse(self, cx, cy, rx, ry, value):
        """Centre (cx, cy) and radii in pixels (ints): the pixels whose centres lie inside, by an integer test."""
        for row in range(max(0, cy - ry - 1), min(self.height, cy + ry + 1)):
            dy = 2 * row + 1 - 2 * cy
            for x in range(max(0, cx - rx - 1), min(self.width, cx + rx + 1)):
                dx = 2 * x + 1 - 2 * cx
                if (dx * ry) ** 2 + (dy * rx) ** 2 <= (2 * rx * ry) ** 2:
                    self.pixels[row * self.width + x] = value

    def rounded(self, x, y, width, height, radius, value):
        if radius == 0:
            self.rect(x, y, width, height, value)
            return
        self.rect(x + radius, y, width - 2 * radius, height, value)
        self.rect(x, y + radius, width, height - 2 * radius, value)
        for cx, cy in ((x + radius, y + radius), (x + width - radius, y + radius), (x + radius, y + height - radius),
                       (x + width - radius, y + height - radius)):
            self.ellipse(cx, cy, radius, radius, value)

    def shade(self, x, y, width, height, value_at):
        for row in range(max(0, y), min(self.height, y + height)):
            for column in range(max(0, x), min(self.width, x + width)):
                self.pixels[row * self.width + column] = value_at(column, row)

    def blurred(self):
        """A 3x3 box blur, edges repeated, rounded down: the decoder's softness, in integers."""
        width, height, source = self.width, self.height, self.pixels
        rows = []
        for row in range(height):
            line = source[row * width:(row + 1) * width]
            padded = [line[0]] + list(line) + [line[-1]]
            rows.append([padded[i] + padded[i + 1] + padded[i + 2] for i in range(width)])
        result = bytearray(width * height)
        for row in range(height):
            up, down = rows[max(0, row - 1)], rows[min(height - 1, row + 1)]
            middle = rows[row]
            result[row * width:(row + 1) * width] = bytes((up[i] + middle[i] + down[i]) // 9 for i in range(width))
        self.pixels = result
        return self

    def encoded(self):
        tokens, previous, count = [], self.pixels[0], 0
        for value in self.pixels:
            if value == previous:
                count += 1
                continue
            tokens.append(f'{previous}*{count}')
            previous, count = value, 1
        tokens.append(f'{previous}*{count}')
        return ' '.join(tokens)


def rotated(points, centre, cos, sin):
    cx, cy = centre
    return [(cx + (x - cx) * cos - (y - cy) * sin, cy + (x - cx) * sin + (y - cy) * cos) for x, y in points]


def box_corners(x, y, width, height):
    return [(x, y), (x + width, y), (x + width, y + height), (x, y + height)]


# MARK: The frames

# A rotation of about 2.86 degrees as an exact Pythagorean pair: t = 1/40, cos = (1 - t^2) / (1 + t^2), sin = 2t / (1 + t^2).
TILT_COS, TILT_SIN = Fraction(1599, 1601), Fraction(80, 1601)
# The Mac's phoneScreen() (FrameAnalyzerTests): 1280x720, grey 0.55, the phone at (780, 120, 260, 480) at 0.02, its screen
# inset (14, 22) at 0.97 and six lines of black 26 pt Helvetica-Bold from x 810, baselines 200, 260 ... 500 (top-left).
# Words are drawn as bars, 13 px a character and 19 px tall: OCR reports lines, not glyphs.
PHONE_LINES = [[7, 4], [7, 5], [5, 5, 3], [3, 2, 3], [3, 3], [9, 3]]


def phone_frame(tilt):
    canvas = Canvas(1280, 720, 140)
    phone = box_corners(780, 120, 260, 480)
    screen = box_corners(794, 142, 232, 436)
    centre = (Fraction(910), Fraction(360))
    turn = (lambda points: rotated(points, centre, TILT_COS, TILT_SIN)) if tilt else (lambda points: [(Fraction(x), Fraction(y)) for x, y in points])
    canvas.polygon(turn(phone), 5)
    canvas.polygon(turn(screen), 247)
    lines = []
    for index, words in enumerate(PHONE_LINES):
        baseline = 200 + 60 * index
        x = 810
        bars = []
        for characters in words:
            bar = turn(box_corners(x, baseline - 19, 13 * characters, 19))
            canvas.polygon(bar, 0)
            bars.extend(bar)
            x += 13 * characters + 7
        lines.append(bounds(bars, 1280, 720))
    return canvas.blurred(), [corners(turn(phone), 1280, 720), corners(turn(screen), 1280, 720)], lines


def laptop_frame():
    canvas = Canvas(640, 360, 150)
    canvas.shade(0, 0, 640, 360, lambda x, y: 150 + y * 30 // 360)
    lid = [(200, 60), (440, 60), (452, 230), (188, 230)]
    screen = [(210, 70), (430, 70), (440, 220), (200, 220)]
    canvas.polygon([(188, 230), (452, 230), (500, 290), (140, 290)], 100)
    canvas.polygon(lid, 25)
    canvas.polygon(screen, 210)
    for row in range(5):
        canvas.rect(236, 92 + row * 22, 120 - 12 * row, 6, 70)
    canvas.rect(380, 90, 20, 20, 90)
    return canvas.blurred(), [corners(lid, 640, 360), corners(screen, 640, 360)], []


def portrait_frame():
    """No rectangle: a face-like ellipse with eyes and a mouth, shoulders cut by the frame, on soft gradients."""
    canvas = Canvas(640, 360, 0)
    canvas.shade(0, 0, 640, 360, lambda x, y: 90 + y * 70 // 360 + x * 20 // 640)
    canvas.ellipse(320, 400, 210, 120, 60)
    face_top = 70
    for row in range(face_top, 290):
        dy = 2 * row + 1 - 2 * 180
        for x in range(240, 400):
            dx = 2 * x + 1 - 2 * 320
            if (dx * 110) ** 2 + (dy * 78) ** 2 <= (2 * 78 * 110) ** 2:
                canvas.pixels[row * 640 + x] = 200 - (row - face_top) * 40 // 220
    canvas.ellipse(290, 160, 14, 7, 40)
    canvas.ellipse(350, 160, 14, 7, 40)
    canvas.ellipse(320, 230, 26, 9, 110)
    return canvas.blurred(), [], []


class Lcg:
    """Numerical Recipes' 32-bit LCG: the same draws everywhere."""

    def __init__(self, seed):
        self.state = seed

    def next(self, low, high):
        self.state = (1664525 * self.state + 1013904223) % 2 ** 32
        return low + (self.state >> 8) % (high - low + 1)


def clutter_frame():
    canvas = Canvas(640, 360, 120)
    target = (430, 200, 150, 110)
    random = Lcg(2026)

    def clear(x0, y0, x1, y1):
        return x1 < target[0] - 12 or x0 > target[0] + target[2] + 12 or y1 < target[1] - 12 or y0 > target[1] + target[3] + 12

    shapes = 0
    while shapes < 36:
        kind = random.next(0, 4)
        x, y = random.next(0, 620), random.next(0, 340)
        value = random.next(0, 1) * 160 + random.next(0, 60)
        if kind == 0:
            radius = random.next(8, 40)
            if not clear(x - radius, y - radius, x + radius, y + radius):
                continue
            canvas.ellipse(x, y, radius, radius, value)
        elif kind == 1:
            dx, dy = random.next(20, 70), random.next(20, 70)
            if not clear(x - dx, y, x + dx, y + dy):
                continue
            canvas.polygon([(x, y), (x + dx, y + dy), (x - dx, y + dy)], value)
        elif kind == 2:
            length, thick = random.next(60, 220), random.next(3, 9)
            if random.next(0, 1):
                if not clear(x, y, x + length, y + thick):
                    continue
                canvas.rect(x, y, length, thick, value)
            else:
                if not clear(x, y, x + thick, y + length):
                    continue
                canvas.rect(x, y, thick, length, value)
        elif kind == 3:
            side = random.next(8, 30)
            if not clear(x, y, x + side, y + side):
                continue
            canvas.rect(x, y, side, side, value)
        else:
            # A kite whose left corner is under 58 degrees: never a square turned 45 degrees, which is a real rectangle.
            dx = random.next(72, 110)
            if not clear(x, y - 40, x + dx + 40, y + 40):
                continue
            canvas.polygon([(x, y), (x + dx, y - 40), (x + dx + 40, y), (x + dx, y + 40)], value)
        shapes += 1
    canvas.rect(*target, 235)
    return canvas.blurred(), [corners(box_corners(*target), 640, 360)], []


def pair_frame(first, second, background=100, value=220):
    """Two shapes on a plain ground: each a list of corners."""
    canvas = Canvas(640, 360, background)
    canvas.polygon(first, value)
    canvas.polygon(second, value)
    return canvas.blurred()


def confidence_frame():
    """A rectangle whose top and bottom fade into the ground (only two sides have edges) and a sharp twin."""
    canvas = Canvas(640, 360, 180)
    soft = (60, 120, 200, 120)
    canvas.shade(*soft, lambda x, y: 180 - 150 * (soft[3] - abs(2 * (y - soft[1]) + 1 - soft[3])) // soft[3])
    sharp = (360, 120, 200, 120)
    canvas.rect(*sharp, 30)
    return canvas.blurred(), corners(box_corners(*sharp), 640, 360), corners(box_corners(*soft), 640, 360)


# The count frame: eight rounded rectangles, the rounder the less edge along each side, so the less confident.
COUNT_RADII = [16, 0, 36, 8, 4, 30, 12, 20]


def count_frame():
    canvas = Canvas(640, 360, 60)
    shapes = []
    for index, radius in enumerate(COUNT_RADII):
        x, y = 15 + 160 * (index % 4), 20 + 180 * (index // 4)
        canvas.rounded(x, y, 130, 140, radius, 220)
        shapes.append((radius, corners(box_corners(x, y, 130, 140), 640, 360)))
    kept = sorted(shapes, key=lambda pair: pair[0])
    return canvas.blurred(), [shape for _, shape in kept[:MAXIMUM_OBSERVATIONS]], [shape for _, shape in kept[MAXIMUM_OBSERVATIONS:]]


# MARK: Numbers

def number(value):
    """One float() of an exact value: correctly rounded, so the same on every platform."""
    return float(Fraction(value))


def corners(points, width, height):
    xs = [Fraction(x) / width for x, _ in points]
    ys = [Fraction(y) / height for _, y in points]
    left, top, right, bottom = min(xs), min(ys), max(xs), max(ys)
    return {'corners': [[number(x), number(y)] for x, y in zip(xs, ys)],
            'box': DECISIONS.rect(number(left), number(top), number(right - left), number(bottom - top))}


def bounds(points, width, height):
    return corners(points, width, height)['box']


def frame_entry(identity, canvas, note):
    return {'id': identity, 'note': note, 'width': canvas.width, 'height': canvas.height,
            'sha256': hashlib.sha256(bytes(canvas.pixels)).hexdigest(), 'runs': canvas.encoded()}


def quad_case(identity, frame, expected, rejected, maximum, note):
    return {'id': identity, 'frame': frame, 'note': note, 'expected': expected, 'rejected': rejected, 'maximumCount': maximum}


def scan_case(identity, note, lines, frame=None, quads=None, expected=None):
    case = {'id': identity, 'note': note, 'lines': lines}
    if frame is not None:
        case['frame'] = frame
    else:
        case['quads'] = quads
    case['screens'] = expected
    return case


def generated():
    upright, upright_quads, upright_lines = phone_frame(tilt=False)
    tilted, tilted_quads, tilted_lines = phone_frame(tilt=True)
    laptop, laptop_quads, _ = laptop_frame()
    portrait, _, _ = portrait_frame()
    clutter, clutter_quads, _ = clutter_frame()
    small, fine = box_corners(100, 150, 30, 40), box_corners(400, 150, 44, 60)
    size = pair_frame(small, fine)
    thin, wide = box_corners(60, 80, 200, 48), box_corners(360, 200, 160, 56)
    aspect = pair_frame(thin, wide)
    skewed = [(60, 240), (180, 240), (249, 130), (129, 130)]
    leaning = [(360, 240), (480, 240), (509, 130), (389, 130)]
    skew = pair_frame(skewed, leaning)
    confidence, sharp, soft = confidence_frame()
    count, count_kept, count_dropped = count_frame()
    frames = [
        frame_entry('phone-upright', upright, "The Mac's drawn phone screen, at its place, words as bars, 3x3 blurred."),
        frame_entry('phone-tilted', tilted, 'The same phone turned about 2.86 degrees about its centre.'),
        frame_entry('laptop', laptop, 'A laptop lid in slight perspective, on a wall gradient, its keyboard deck touching the lid.'),
        frame_entry('portrait', portrait, 'No rectangle: a face-like ellipse, eyes, mouth and shoulders on soft gradients.'),
        frame_entry('clutter', clutter, 'One rectangle among circles, triangles, lines, small squares and kites.'),
        frame_entry('size', size, 'A rectangle too small (short side 30 px < 36) and one large enough (44 px).'),
        frame_entry('aspect', aspect, 'A rectangle too thin (48/200 = 0.24) and one wide enough (56/160 = 0.35).'),
        frame_entry('skew', skew, 'A parallelogram 32.1 degrees off square and one 14.8 degrees off.'),
        frame_entry('confidence', confidence, 'A rectangle whose top and bottom fade (edges on two sides only) and a sharp twin.'),
        frame_entry('count', count, f'Eight rounded rectangles, corner radii {COUNT_RADII} px: the six squarest are kept.'),
    ]
    quads = [
        quad_case('phone-upright', 'phone-upright', upright_quads, [], 2, 'The phone and its screen.'),
        quad_case('phone-tilted', 'phone-tilted', tilted_quads, [], 2, 'Still both when turned.'),
        quad_case('laptop', 'laptop', laptop_quads, [], 2, 'The lid and its screen; the deck is skewed past 25 degrees.'),
        quad_case('portrait', 'portrait', [], [], 0, 'An ellipse fills pi/4 of the quad around it; gradients have no edges.'),
        quad_case('clutter', 'clutter', clutter_quads, [], 1, 'Only the rectangle.'),
        quad_case('too-small', 'size', [corners(fine, 640, 360)], [corners(small, 640, 360)], 1, 'minimumSize 0.1.'),
        quad_case('too-thin', 'aspect', [corners(wide, 640, 360)], [corners(thin, 640, 360)], 1, 'minimumAspectRatio 0.3.'),
        quad_case('too-skewed', 'skew', [corners(leaning, 640, 360)], [corners(skewed, 640, 360)], 1, 'quadratureTolerance 25.'),
        quad_case('low-confidence', 'confidence', [sharp], [soft], 1, 'minimumConfidence 0.6: two sides of four is 0.5.'),
        quad_case('at-most-six', 'count', count_kept, count_dropped, MAXIMUM_OBSERVATIONS, 'maximumObservations 6, the most confident first.'),
    ]
    detect = DECISIONS.detect_screens
    phone_box = upright_quads[0]['box']
    screen_box = upright_quads[1]['box']
    inner = DECISIONS.rect(0.62, 0.3, 0.16, 0.4)
    lines_in = [DECISIONS.rect(0.63, 0.33 + i * 0.07, 0.12, 0.03) for i in range(7)]
    page = [DECISIONS.rect(0.08, 0.1 + i * 0.05, 0.3, 0.03) for i in range(8)]
    outside = [DECISIONS.rect(0.1, 0.33 + i * 0.07, 0.12, 0.03) for i in range(5)]
    tiny = [DECISIONS.rect(0.63, 0.33 + i * 0.1, 0.01, 0.005) for i in range(3)]
    scans = [
        scan_case('phone-framed', "The drawn phone's six lines with the finder's quads: framed screens with a rectangle source.",
                  upright_lines, frame='phone-upright', expected=detect([phone_box, screen_box], upright_lines)),
        scan_case('phone-tilted-framed', 'The turned phone, the same.', tilted_lines, frame='phone-tilted',
                  expected=detect([q['box'] for q in tilted_quads], tilted_lines)),
        scan_case('phone-no-rectangles', 'The same six lines with no rectangle source: under the 8-box cluster rule, so no screen.',
                  upright_lines, quads=[], expected=detect([], upright_lines)),
        scan_case('portrait-no-quads', 'Lines on the no-rectangle frame: no quad, so only a cluster could be a screen.',
                  lines_in[:5], frame='portrait', expected=detect([], lines_in[:5])),
    ]
    for count_lines in (3, 5, 7):
        chosen = lines_in[:count_lines]
        scans.append(scan_case(f'{count_lines}-lines-in-a-quad', f'{count_lines} lines are a screen only because a quad holds them.',
                               chosen, quads=[inner], expected=detect([inner], chosen)))
        scans.append(scan_case(f'{count_lines}-lines-alone', f'The same {count_lines} lines without the quad.', chosen, quads=[],
                               expected=detect([], chosen)))
    scans += [
        scan_case('2-lines-in-a-quad', 'Two lines are too few (minimumBoxes 3).', lines_in[:2], quads=[inner],
                  expected=detect([inner], lines_in[:2])),
        scan_case('tiny-lines', 'Three lines covering under 4 % of the quad.', tiny, quads=[inner], expected=detect([inner], tiny)),
        scan_case('lines-outside', 'Lines beside the quad, not in it.', outside, quads=[inner], expected=detect([inner], outside)),
        scan_case('page-cluster', 'Eight lines with no quad: a dense-text cluster, not framed.', page, quads=[],
                  expected=detect([], page)),
        scan_case('quad-and-cluster', 'A framed screen and a cluster in one frame.', lines_in[:4] + page, quads=[inner],
                  expected=detect([inner], lines_in[:4] + page)),
    ]
    sections = {'quads': quads, 'scans': scans}
    return {
        'schema': 'voxclip-frame-quad-cases/1',
        'description': "The Windows quad finder (ADR-R48 Windows, W4) on drawn grey frames, and line boxes plus quads through "
                       "FrameScreens.detect. Generated by tools/fixtures/clip-frames/generate_frame_quads.py; C# "
                       "FrameQuadVectorTests replays every case.",
        'settings': {'maximumObservations': MAXIMUM_OBSERVATIONS, 'minimumAspectRatio': MINIMUM_ASPECT_RATIO,
                     'maximumAspectRatio': MAXIMUM_ASPECT_RATIO, 'minimumSize': MINIMUM_SIZE,
                     'minimumConfidence': MINIMUM_CONFIDENCE, 'quadratureTolerance': QUADRATURE_TOLERANCE,
                     'workingLongSide': WORKING_LONG_SIDE},
        'tolerance': TOLERANCE,
        'coverageTolerance': COVERAGE_TOLERANCE,
        'caseCount': sum(len(cases) for cases in sections.values()),
        'counts': {key: len(cases) for key, cases in sections.items()},
        'frames': frames,
        **sections,
    }


def main():
    DESTINATION.write_text(json.dumps(generated(), indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
