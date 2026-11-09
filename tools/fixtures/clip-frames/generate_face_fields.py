#!/usr/bin/env python3
"""Generate the Windows face fields' shared vectors (ADR-R48 Windows, package W2).

Writes shared/fixtures/clip-frames/frame-face-fields-cases.json (schema voxclip-frame-face-fields-cases/1), a new file of its own
so no existing replay's keys or counts change. It holds the pure steps between the two face models and a FrameFace:
YuNet's input size and output decoding (synthetic output tensors, NMS, the largest face), the roll-aligned crop (roll,
affines, round trips, bilinear resampling), the crop's sharpness and exposure stats, the mesh landmarks to FrameFace fields
(synthetic landmark sets: open, closed and half-closed eyes, turned, tipped, level) and the capture quality with its gates.
C# FrameFaceFieldsVectorTests replays every case with exact keys and counts; there is no Mac twin (the Mac uses Vision).

This is a reference implementation of apps/windows/src/VoxClip.Core/Domain/Frames (YuNetDecoder, RotatedCrop, FaceMeshFields),
in the C# order of IEEE operations. The fitted constants are read from shared/catalog/frame-models.json's calibration block,
their one home, and echoed into the file. Pure IEEE arithmetic only (+, -, *, /, sqrt, floor), so the bytes are the same on
every platform: atan2, exp and ln are computed here by fixed series rather than libm, and the C# replay (Math.Atan2, Exp, Log)
compares numbers within 1e-9 relative. check_drift.py lists the file as EXACT. Run from anywhere.
"""
import json
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CATALOGUE = ROOT / 'shared/catalog/frame-models.json'
DESTINATION = ROOT / 'shared/fixtures/clip-frames/frame-face-fields-cases.json'

STRIDES = [8, 16, 32]
SCORE_THRESHOLD = 0.6
NMS_THRESHOLD = 0.3
LONG_SIDE = 640
ALIGNMENT = 32
CROP_SIZE = 256
EXPANSION = 1.5
LANDMARK_COUNT = 478
RIGHT_EYE = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
LEFT_EYE = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]
RIGHT_EYE_OUTER, LEFT_EYE_OUTER, FOREHEAD, CHIN = 33, 263, 10, 152
CLOSED_BELOW = 0.20
YAW_LIMIT = 0.35
PITCH_LIMIT = 0.35


# MARK: Pure IEEE transcendental functions (fixed series, no libm)

PI = 3.141592653589793
LN2 = 0.6931471805599453
SQRT_HALF = 0.7071067811865476


def p_atan(x):
    negative = x < 0
    x = -x if negative else x
    invert = x > 1
    if invert:
        x = 1.0 / x
    for _ in range(4):
        x = x / (1.0 + math.sqrt(1.0 + x * x))
    square = x * x
    term = x
    total = 0.0
    for n in range(12):
        total = total + term / (2 * n + 1) if n % 2 == 0 else total - term / (2 * n + 1)
        term = term * square
    result = total * 16.0
    if invert:
        result = PI / 2 - result
    return -result if negative else result


def p_atan2(y, x):
    if x > 0:
        return p_atan(y / x)
    if x < 0:
        return p_atan(y / x) + PI if y >= 0 else p_atan(y / x) - PI
    return PI / 2 if y > 0 else -PI / 2 if y < 0 else 0.0


def p_exp(x):
    k = math.floor(x / LN2 + 0.5)
    r = x - k * LN2
    term = 1.0
    total = 1.0
    for n in range(1, 25):
        term = term * r / n
        total = total + term
    return math.ldexp(total, int(k))


def p_ln(x):
    mantissa, exponent = math.frexp(x)
    if mantissa < SQRT_HALF:
        mantissa = mantissa * 2.0
        exponent -= 1
    z = (mantissa - 1.0) / (mantissa + 1.0)
    square = z * z
    term = z
    total = 0.0
    for n in range(30):
        total = total + term / (2 * n + 1)
        term = term * square
    return 2.0 * total + exponent * LN2


def check_series():
    for value in [-3.7, -1.0, -0.3, 0.0, 1e-9, 0.2, 0.9, 1.0, 1.1, 5.0, 300.0]:
        assert abs(p_atan(value) - math.atan(value)) <= 1e-15 * max(1.0, abs(math.atan(value))), value
    for y, x in [(1, 2), (-1, 2), (1, -2), (-1, -2), (0, -1), (3, 0), (-3, 0)]:
        assert abs(p_atan2(y, x) - math.atan2(y, x)) <= 1e-15 * 4, (y, x)
    for value in [-4.0, -0.7, 0.0, 0.3, 1.5, 2.25, 10.0]:
        assert abs(p_exp(value) - math.exp(value)) <= 1e-14 * math.exp(value), value
    for value in [1e-3, 0.5, 1.0, 2.0, 30.0, 150.0, 400.0, 1e6]:
        assert abs(p_ln(value) - math.log(value)) <= 1e-14 * max(1.0, abs(math.log(value))), value


# MARK: Arithmetic as C# does it

def clamp(value, low, high):
    return low if value < low else high if value > high else value


def rounded(value):
    """Math.Round(value, MidpointRounding.AwayFromZero) for non-negative values."""
    whole = math.floor(value)
    return whole + 1 if value - whole >= 0.5 else whole


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def exact_f32(value):
    assert f32(value) == value, value
    return value


# MARK: YuNet

def yunet_input(width, height, long_side=LONG_SIDE):
    scale = long_side / max(width, height)
    content_width = max(1, int(rounded(width * scale)))
    content_height = max(1, int(rounded(height * scale)))

    def pad(side):
        return (side + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
    return {'width': pad(content_width), 'height': pad(content_height), 'contentWidth': content_width,
            'contentHeight': content_height, 'scale': scale}


def area(face):
    return face['width'] * face['height']


def iou(a, b):
    width = min(a['x'] + a['width'], b['x'] + b['width']) - max(a['x'], b['x'])
    height = min(a['y'] + a['height'], b['y'] + b['height']) - max(a['y'], b['y'])
    intersection = max(0.0, width) * max(0.0, height)
    union = area(a) + area(b) - intersection
    return intersection / union if union > 0 and a['width'] > 0 and a['height'] > 0 and b['width'] > 0 and b['height'] > 0 else 0.0


def dense_outputs(width, height, cells):
    outputs = {}
    for stride in STRIDES:
        count = (width // stride) * (height // stride)
        outputs[f'cls_{stride}'] = [0.0] * count
        outputs[f'obj_{stride}'] = [0.0] * count
        outputs[f'bbox_{stride}'] = [0.0] * (count * 4)
        outputs[f'kps_{stride}'] = [0.0] * (count * 10)
    assert len({(cell['stride'], cell['row'], cell['column']) for cell in cells}) == len(cells), 'two cells share a grid index'
    for cell in cells:
        stride = cell['stride']
        index = cell['row'] * (width // stride) + cell['column']
        outputs[f'cls_{stride}'][index] = cell['cls']
        outputs[f'obj_{stride}'][index] = cell['obj']
        outputs[f'bbox_{stride}'][index * 4:index * 4 + 4] = cell['bbox']
        outputs[f'kps_{stride}'][index * 10:index * 10 + 10] = cell['kps']
    return outputs


def decode(outputs, width, height):
    candidates = []
    for stride in STRIDES:
        columns = width // stride
        rows = height // stride
        cls, obj = outputs[f'cls_{stride}'], outputs[f'obj_{stride}']
        bbox, kps = outputs[f'bbox_{stride}'], outputs[f'kps_{stride}']
        for row in range(rows):
            for column in range(columns):
                cell = row * columns + column
                score = math.sqrt(clamp(cls[cell], 0.0, 1.0) * clamp(obj[cell], 0.0, 1.0))
                if not score >= SCORE_THRESHOLD:
                    continue
                centre_x = (column + bbox[cell * 4]) * stride
                centre_y = (row + bbox[cell * 4 + 1]) * stride
                face_width = p_exp(bbox[cell * 4 + 2]) * stride
                face_height = p_exp(bbox[cell * 4 + 3]) * stride
                points = [[(kps[cell * 10 + point * 2] + column) * stride, (kps[cell * 10 + point * 2 + 1] + row) * stride]
                          for point in range(5)]
                candidates.append({'x': centre_x - face_width / 2, 'y': centre_y - face_height / 2, 'width': face_width,
                                   'height': face_height, 'points': points, 'score': score})
    ordered = sorted(candidates, key=lambda face: -face['score'])  # stable: grid order among equals
    kept = []
    for face in ordered:
        if all(iou(face, other) <= NMS_THRESHOLD for other in kept):
            kept.append(face)
    return kept


def largest_index(faces):
    best = None
    for index, face in enumerate(faces):
        if best is None or area(face) > area(faces[best]):
            best = index
    return best


def picture_rect(face, content_width, content_height):
    left = clamp(face['x'] / content_width, 0.0, 1.0)
    top = clamp(face['y'] / content_height, 0.0, 1.0)
    right = clamp((face['x'] + face['width']) / content_width, 0.0, 1.0)
    bottom = clamp((face['y'] + face['height']) / content_height, 0.0, 1.0)
    return {'height': bottom - top, 'width': right - left, 'x': left, 'y': top}


def cell(stride, row, column, cls, obj, bbox, kps):
    return {'stride': stride, 'row': row, 'column': column, 'cls': exact_f32(cls), 'obj': exact_f32(obj),
            'bbox': [exact_f32(value) for value in bbox], 'kps': [exact_f32(value) for value in kps]}


FACE_KPS = [-0.375, -0.25, 0.375, -0.25, 0.0, 0.125, -0.25, 0.5, 0.25, 0.5]


def decode_cases():
    cases = [
        ('one-face', 64, 64, 64, 60, [cell(8, 3, 4, 0.9375, 0.875, [0.5, 0.25, 1.5, 1.75], FACE_KPS)], None),
        ('below-threshold', 64, 64, 64, 64, [cell(8, 2, 2, 0.5, 0.5, [0.5, 0.5, 1.0, 1.0], FACE_KPS),
                                             cell(8, 5, 5, 0.625, 0.625, [0.5, 0.5, 1.0, 1.0], FACE_KPS)], None),
        ('clamped-scores', 64, 64, 64, 64, [cell(8, 1, 1, 1.25, 0.75, [0.25, 0.75, 1.25, 1.25], FACE_KPS),
                                            cell(8, 6, 6, 0.9375, -0.5, [0.5, 0.5, 1.0, 1.0], FACE_KPS)], None),
        ('nms-drops-the-overlap', 64, 64, 64, 64, [cell(8, 3, 3, 0.75, 0.875, [0.5, 0.5, 1.5, 1.5], FACE_KPS),
                                                   cell(8, 3, 4, 0.9375, 0.9375, [0.0, 0.5, 1.5, 1.5], FACE_KPS)], None),
        ('largest-is-not-the-best-score', 64, 64, 64, 64, [cell(8, 1, 1, 0.9375, 0.9375, [0.5, 0.5, 0.75, 0.75], FACE_KPS),
                                                           cell(8, 5, 5, 0.75, 0.75, [0.5, 0.5, 1.5, 1.75], FACE_KPS)], None),
        ('nms-before-largest', 64, 64, 64, 64, [cell(8, 3, 3, 0.9375, 0.9375, [0.5, 0.5, 1.25, 1.25], FACE_KPS),
                                                cell(8, 3, 4, 0.75, 0.875, [-0.5, 0.5, 1.5, 1.5], FACE_KPS),
                                                cell(8, 7, 0, 0.875, 0.875, [0.5, 0.5, 0.5, 0.5], FACE_KPS)], None),
        ('coarse-strides', 64, 64, 64, 64, [cell(16, 1, 2, 0.875, 0.9375, [0.5, 0.25, 1.0, 1.25], FACE_KPS),
                                            cell(32, 1, 0, 0.9375, 0.875, [0.25, 0.5, 0.25, 0.5], FACE_KPS)], None),
        ('equal-faces-keep-grid-order', 64, 64, 64, 64, [cell(8, 6, 6, 0.875, 0.875, [0.5, 0.5, 0.75, 0.75], FACE_KPS),
                                                         cell(8, 1, 1, 0.875, 0.875, [0.5, 0.5, 0.75, 0.75], FACE_KPS)], None),
        ('no-face', 64, 64, 64, 64, [], None),
        ('wide-input', 96, 64, 96, 54, [cell(8, 2, 9, 0.9375, 0.9375, [0.5, 0.5, 1.5, 1.5], FACE_KPS),
                                        cell(16, 2, 1, 0.875, 0.875, [0.5, 0.0, 0.75, 1.0], FACE_KPS)], None),
        ('edge-clamped-rect', 64, 64, 64, 48, [cell(8, 0, 0, 0.9375, 0.9375, [0.0, 0.0, 1.5, 1.5], FACE_KPS)], None),
        ('not-a-multiple-of-32', 60, 64, 60, 64, [], 'size'),
        ('short-output', 64, 64, 64, 64, [cell(8, 3, 4, 0.9375, 0.875, [0.5, 0.25, 1.5, 1.75], FACE_KPS)], 'kps_8'),
    ]
    rows = []
    for case_id, width, height, content_width, content_height, cells, error in cases:
        row = {'id': case_id, 'inputWidth': width, 'inputHeight': height, 'contentWidth': content_width,
               'contentHeight': content_height, 'cells': cells}
        if error is not None:
            row['truncate'] = None if error == 'size' else error
            row['expect'] = {'error': True}
        else:
            faces = decode(dense_outputs(width, height, cells), width, height)
            largest = largest_index(faces)
            row['truncate'] = None
            row['expect'] = {'error': False, 'faces': faces, 'largest': largest,
                             'largestRect': None if largest is None else picture_rect(faces[largest], content_width, content_height)}
        rows.append(row)
    return rows


def input_size_cases():
    sizes = [('landscape-720p', 1280, 720), ('portrait', 720, 1280), ('full-hd', 1920, 1080), ('square', 1080, 1080),
             ('half-rounds-up', 1280, 721), ('half-rounds-up-below', 1280, 719), ('narrow', 1000, 333), ('tiny', 3, 1)]
    return [{'id': case_id, 'frameWidth': width, 'frameHeight': height, 'expect': yunet_input(width, height)}
            for case_id, width, height in sizes]


# MARK: Rotated crop

def crop_from_face(face, scale, crop_size=CROP_SIZE, expansion=EXPANSION):
    points = face['points']
    dx = (points[1][0] - points[0][0]) * scale
    dy = (points[1][1] - points[0][1]) * scale
    length = math.sqrt(dx * dx + dy * dy)
    side = max(face['width'], face['height']) * expansion * scale
    centre = [(face['x'] + face['width'] / 2) * scale, (face['y'] + face['height'] / 2) * scale]
    if not length > 0 or not side > 0:
        return None
    return {'roll': p_atan2(dy, dx), 'centre': centre, 'side': side, 'cropSize': crop_size, 'cos': dx / length, 'sin': dy / length}


def to_frame(crop, u, v):
    k = crop['side'] / crop['cropSize']
    half = crop['cropSize'] / 2.0
    du = u - half
    dv = v - half
    return [crop['centre'][0] + k * (crop['cos'] * du - crop['sin'] * dv), crop['centre'][1] + k * (crop['sin'] * du + crop['cos'] * dv)]


def to_crop(crop, x, y):
    k = crop['side'] / crop['cropSize']
    half = crop['cropSize'] / 2.0
    dx = x - crop['centre'][0]
    dy = y - crop['centre'][1]
    return [half + (crop['cos'] * dx + crop['sin'] * dy) / k, half + (crop['cos'] * dy - crop['sin'] * dx) / k]


def crop_to_frame(crop):
    k = crop['side'] / crop['cropSize']
    origin = to_frame(crop, 0.0, 0.0)
    return [k * crop['cos'], -(k * crop['sin']), origin[0], k * crop['sin'], k * crop['cos'], origin[1]]


def frame_to_crop(crop):
    k = crop['side'] / crop['cropSize']
    origin = to_crop(crop, 0.0, 0.0)
    return [crop['cos'] / k, crop['sin'] / k, origin[0], -crop['sin'] / k, crop['cos'] / k, origin[1]]


def detector_face(x, y, width, height, points):
    return {'x': x, 'y': y, 'width': width, 'height': height, 'points': points, 'score': 0.9}


def crop_cases():
    nose_mouth = [[130.0, 125.0], [118.0, 140.0], [142.0, 140.0]]
    cases = [
        ('level', detector_face(100.0, 80.0, 60.0, 80.0, [[115.0, 110.0], [145.0, 110.0], *nose_mouth]), 2.0),
        ('second-eye-lower', detector_face(100.0, 80.0, 60.0, 80.0, [[115.0, 105.0], [145.0, 120.0], *nose_mouth]), 2.0),
        ('second-eye-higher', detector_face(100.0, 80.0, 60.0, 80.0, [[115.0, 120.0], [145.0, 104.0], *nose_mouth]), 2.0),
        ('upside-down', detector_face(100.0, 80.0, 60.0, 80.0, [[145.0, 110.0], [115.0, 112.5], *nose_mouth]), 2.0),
        ('wide-box', detector_face(40.5, 30.25, 90.0, 70.0, [[60.0, 50.0], [100.0, 58.0], *nose_mouth]), 1.0),
        ('frame-scale', detector_face(310.0, 120.0, 48.0, 56.0, [[322.0, 138.0], [346.0, 137.0], *nose_mouth]), 3.0),
        ('same-eye-points', detector_face(100.0, 80.0, 60.0, 80.0, [[130.0, 110.0], [130.0, 110.0], *nose_mouth]), 2.0),
        ('empty-box', detector_face(100.0, 80.0, 0.0, 0.0, [[115.0, 110.0], [145.0, 110.0], *nose_mouth]), 2.0),
    ]
    crop_points = [[0.0, 0.0], [256.0, 256.0], [128.0, 128.0], [64.25, 190.5], [255.5, 0.5]]
    mesh_points = [[128.0, 128.0, 0.0], [90.5, 110.0, -12.0], [170.0, 200.25, 7.5]]
    rows = []
    for case_id, face, scale in cases:
        crop = crop_from_face(face, scale)
        row = {'id': case_id, 'face': face, 'scale': scale}
        if crop is None:
            row['expect'] = None
        else:
            k = crop['side'] / crop['cropSize']
            frame_points = [to_frame(crop, u, v) for u, v in crop_points]
            row['expect'] = {
                **crop, 'cropToFrame': crop_to_frame(crop), 'frameToCrop': frame_to_crop(crop),
                'cropPoints': crop_points, 'framePoints': frame_points,
                'meshPoints': mesh_points, 'meshInFrame': [[*to_frame(crop, x, y), z * k] for x, y, z in mesh_points],
                'eyesInCrop': [to_crop(crop, point[0] * scale, point[1] * scale) for point in face['points'][:2]],
            }
        rows.append(row)
    return rows


def sample(crop, rgb, width, height, row_bytes):
    def clamp_index(index, count):
        return 0 if index <= 0 else count - 1 if index >= count - 1 else int(index)
    size = crop['cropSize']
    output = []
    for v in range(size):
        for u in range(size):
            x, y = to_frame(crop, u + 0.5, v + 0.5)
            x = x - 0.5
            y = y - 0.5
            left = math.floor(x)
            top = math.floor(y)
            fx = x - left
            fy = y - top
            x0, x1 = clamp_index(left, width), clamp_index(left + 1, width)
            y0, y1 = clamp_index(top, height), clamp_index(top + 1, height)
            for channel in range(3):
                top_left = float(rgb[y0 * row_bytes + x0 * 3 + channel])
                top_right = float(rgb[y0 * row_bytes + x1 * 3 + channel])
                bottom_left = float(rgb[y1 * row_bytes + x0 * 3 + channel])
                bottom_right = float(rgb[y1 * row_bytes + x1 * 3 + channel])
                upper = top_left + (top_right - top_left) * fx
                lower = bottom_left + (bottom_right - bottom_left) * fx
                output.append(f32((upper + (lower - upper) * fy) / 255))
    return output


def pixels(width, height, row_bytes, seed):
    state = seed
    data = []
    for _ in range(height):
        for _ in range(row_bytes):
            state = (state * 1103515245 + 12345) % 2147483648
            data.append(state >> 23)
    assert len(data) == row_bytes * height and all(0 <= value < 256 for value in data)
    return data


def sample_cases():
    cases = [
        ('level-inside', detector_face(2.0, 1.0, 3.0, 2.0, [[2.5, 2.0], [4.5, 2.0], [3.5, 2.5], [3.0, 2.75], [4.0, 2.75]]), 1.0, 4, 1.0, 11),
        ('rolled', detector_face(1.5, 1.0, 4.0, 3.0, [[2.0, 1.5], [5.0, 3.0], [3.5, 2.5], [3.0, 3.5], [4.0, 3.5]]), 1.0, 4, 1.0, 29),
        ('edges-repeat', detector_face(-1.0, -1.0, 4.0, 4.0, [[0.0, 0.0], [2.0, 0.5], [1.0, 1.0], [0.5, 2.0], [1.5, 2.0]]), 1.0, 4, 1.5, 47),
    ]
    width, height, row_bytes = 7, 5, 24
    rows = []
    for case_id, face, scale, crop_size, expansion, seed in cases:
        data = pixels(width, height, row_bytes, seed)
        crop = crop_from_face(face, scale, crop_size, expansion)
        rows.append({'id': case_id, 'face': face, 'scale': scale, 'cropSize': crop_size, 'expansion': expansion,
                     'image': {'width': width, 'height': height, 'rowBytes': row_bytes, 'bytes': data},
                     'expect': sample(crop, data, width, height, row_bytes)})
    return rows


# MARK: Crop stats, mesh fields and quality

def crop_stats(rgb, size, gates):
    grey = [255.0 * (0.299 * rgb[index * 3] + 0.587 * rgb[index * 3 + 1] + 0.114 * rgb[index * 3 + 2]) for index in range(size * size)]
    start = size // 4
    end = size - size // 4
    count = (end - start) * (end - start)
    laplacians = []
    luma = 0.0
    clipped = 0
    for y in range(start, end):
        for x in range(start, end):
            centre = grey[y * size + x]
            laplacians.append(grey[(y - 1) * size + x] + grey[(y + 1) * size + x] + grey[y * size + x - 1] + grey[y * size + x + 1]
                              - 4.0 * centre)
            luma = luma + centre
            if centre < gates['clippedBelow'] or centre > gates['clippedAbove']:
                clipped += 1
    mean = 0.0
    for value in laplacians:
        mean = mean + value
    mean = mean / count
    variance = 0.0
    for value in laplacians:
        variance = variance + (value - mean) * (value - mean)
    return {'sharpnessVariance': variance / count, 'meanLuma': luma / count, 'clippedFraction': clipped / count}


def crop_stat_cases(gates):
    size = 8

    def crop(value_at):
        values = []
        for y in range(size):
            for x in range(size):
                values.extend(exact_f32(channel) for channel in value_at(x, y))
        return values
    cases = [
        ('flat', crop(lambda x, y: (0.5, 0.5, 0.5))),
        ('checker', crop(lambda x, y: (0.25, 0.25, 0.25) if (x + y) % 2 == 0 else (0.75, 0.75, 0.75))),
        ('colour-gradient', crop(lambda x, y: (x / 8, y / 8, (x + y) / 16))),
        ('dark-noise', crop(lambda x, y: ((x * 7 + y * 3) % 5 / 64, (x * 5 + y) % 3 / 64, 0.0))),
        ('clipped-highlights', crop(lambda x, y: (1.0, 1.0, 1.0) if x < 5 else (0.5, 0.5, 0.5))),
        ('crushed-shadows', crop(lambda x, y: (0.0, 0.0, 0.0) if y >= 4 else (0.25, 0.375, 0.5))),
    ]
    rows = [{'id': case_id, 'size': size, 'rgb': rgb, 'expect': crop_stats(rgb, size, gates)} for case_id, rgb in cases]
    rows.append({'id': 'too-small', 'size': 3, 'rgb': [0.5] * 27, 'expect': None})
    rows.append({'id': 'wrong-length', 'size': 8, 'rgb': [0.5] * 191, 'expect': None})
    return rows


def ratio(points):
    if len(points) < 3:
        return None
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    width = max(xs) - min(xs)
    height = max(ys) - min(ys)
    return height / width if width > 0 else None


def minus(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def pose(mesh):
    across = minus(mesh[LEFT_EYE_OUTER], mesh[RIGHT_EYE_OUTER])
    down = minus(mesh[CHIN], mesh[FOREHEAD])
    length = dot(across, across)
    if not length > 0:
        return None
    along = dot(down, across) / length
    upright = [down[0] - along * across[0], down[1] - along * across[1], down[2] - along * across[2]]
    if not dot(upright, upright) > 0:
        return None
    return p_atan2(across[2], across[0]), p_atan2(-upright[2], upright[1])


def remap(score, quantile_map):
    if not quantile_map:
        return score
    from_x, from_y = 0.0, 0.0
    for x, y in [*quantile_map, [1.0, 1.0]]:
        if score <= x:
            return from_y + (score - from_x) * (y - from_y) / (x - from_x)
        from_x, from_y = x, y
    return 1.0


def sharpness(variance, quality):
    if not variance > 0:
        return 0.0
    low = p_ln(quality['sharpness'][0])
    return clamp((p_ln(variance) - low) / (p_ln(quality['sharpness'][1]) - low), 0.0, 1.0)


def quality_parts(eyes, yaw, pitch, face_width, crop, calibration, quantile_map=None):
    if eyes is None or yaw is None or pitch is None:
        return None
    quality = calibration['quality']
    gates = quality['gates']
    closed_at, open_at = quality['eyesOpen']
    eyes_open = clamp((eyes - closed_at) / (open_at - closed_at), 0.0, 1.0)
    facing = clamp(1 - max(abs(yaw), abs(pitch - quality['pitch0'])) / quality['facingSpan'], 0.0, 1.0)
    sharp = sharpness(crop['sharpnessVariance'], quality)
    gate = 1.0 if (face_width >= gates['minimumFaceWidth'] and crop['meanLuma'] >= gates['luma'][0] and
                   crop['meanLuma'] <= gates['luma'][1] and crop['clippedFraction'] <= gates['clippedFraction']) else 0.0
    score = clamp(gate * (quality['w0'] + quality['w1'] * eyes_open * facing + quality['w2'] * sharp), 0.0, 1.0)
    mapped = remap(score, quality['quantileMap'] if quantile_map is None else quantile_map)
    return {'eyesOpen': eyes_open, 'facing': facing, 'sharp': sharp, 'gate': gate, 'score': score, 'quality': clamp(mapped, 0.0, 1.0)}


def linear(row, value):
    return row['a'] * value + row['b']


def mean(left, right):
    values = [value for value in (left, right) if value is not None]
    total = 0.0
    for value in values:
        total = total + value
    return total / len(values) if values else None


def face_json(rect, quality, left, right, yaw, pitch):
    eyes = 'unknown' if mean(left, right) is None else 'closed' if mean(left, right) < CLOSED_BELOW else 'open'
    value = {}
    if quality is not None:
        value['captureQuality'] = quality
    value['eyes'] = eyes
    if left is not None:
        value['leftEyeAspect'] = left
    if pitch is not None:
        value['pitch'] = pitch
    value['rect'] = rect
    if right is not None:
        value['rightEyeAspect'] = right
    if yaw is not None:
        value['yaw'] = yaw
    return value


def facing_camera(yaw, pitch):
    if yaw is None and pitch is None:
        return None
    if yaw is not None and abs(yaw) > YAW_LIMIT:
        return False
    if pitch is not None and abs(pitch) > PITCH_LIMIT:
        return False
    return True


def mesh_fields(case, calibration):
    mesh = [list(case['fill']) for _ in range(case['count'])]
    for index, point in case['points'].items():
        mesh[int(index)] = point
    raw_left = ratio([mesh[index][:2] for index in LEFT_EYE])
    raw_right = ratio([mesh[index][:2] for index in RIGHT_EYE])
    left = None if raw_left is None else linear(calibration['eyeAspect'], raw_left)
    right = None if raw_right is None else linear(calibration['eyeAspect'], raw_right)
    angles = pose(mesh)
    yaw = None if angles is None else linear(calibration['yaw'], angles[0])
    pitch = None if angles is None else linear(calibration['pitch'], angles[1])
    parts = quality_parts(mean(left, right), yaw, pitch, case['faceWidthPixels'], case['crop'], calibration)
    # A face narrower than eyesFromWidth reports its eyes unknown (W8); the quality above keeps the measured eyes.
    if case['faceWidthPixels'] < calibration['eyesFromWidth']:
        left = right = None
    return {'rawLeftEye': raw_left, 'rawRightEye': raw_right, 'meshYaw': None if angles is None else angles[0],
            'meshPitch': None if angles is None else angles[1], 'quality': parts,
            'face': face_json(case['rect'], None if parts is None else parts['quality'], left, right, yaw, pitch),
            'facesCamera': facing_camera(yaw, pitch)}


# The 16 contour directions, 22.5 degrees apart, from square roots only.
C1 = math.sqrt(2.0 + math.sqrt(2.0)) / 2.0
S1 = math.sqrt(2.0 - math.sqrt(2.0)) / 2.0
C2 = math.sqrt(0.5)
DIRECTIONS = [(1.0, 0.0), (C1, S1), (C2, C2), (S1, C1), (0.0, 1.0), (-S1, C1), (-C2, C2), (-C1, S1),
              (-1.0, 0.0), (-C1, -S1), (-C2, -C2), (-S1, -C1), (0.0, -1.0), (S1, -C1), (C2, -C2), (C1, -S1)]


def synthetic_mesh(left_open, right_open, yaw_tan=0.0, pitch_tan=0.0, chin_x=0.0):
    """Landmarks in upright crop pixels: each eye an ellipse 26 px wide whose height over width is its openness (contour index 0 the
    outer corner, 4 the lower lid, 8 the inner corner, 12 the upper lid), forehead and chin on the midline, turned by the pitch
    and then the yaw (tan of each angle), projected orthographically about the crop's centre. chin_x moves the chin sideways, so
    the forehead-to-chin line is not perpendicular to the eye line and the pose must orthogonalise it. Unlisted landmarks are the
    fill."""
    canonical = {}
    for indices, centre_x, outward, openness in [(RIGHT_EYE, -27.0, -1.0, right_open), (LEFT_EYE, 27.0, 1.0, left_open)]:
        for index, (cos, sin) in zip(indices, DIRECTIONS):
            canonical[index] = [centre_x + outward * 13.0 * cos, -18.0 + 13.0 * openness * sin, 0.0]
    canonical[FOREHEAD] = [0.0, -75.0, 6.0]
    canonical[CHIN] = [chin_x, 80.0, 6.0]
    pitch_cos = 1.0 / math.sqrt(1.0 + pitch_tan * pitch_tan)
    pitch_sin = pitch_tan * pitch_cos
    yaw_cos = 1.0 / math.sqrt(1.0 + yaw_tan * yaw_tan)
    yaw_sin = yaw_tan * yaw_cos
    points = {}
    for index in sorted(canonical):
        x, y, z = canonical[index]
        y, z = y * pitch_cos - z * pitch_sin, y * pitch_sin + z * pitch_cos
        x, z = x * yaw_cos + z * yaw_sin, z * yaw_cos - x * yaw_sin
        points[str(index)] = [128.0 + x, 128.0 + y, z]
    return points


def mesh_cases(calibration):
    rect = {'height': 0.35, 'width': 0.2, 'x': 0.4, 'y': 0.3}
    crop = {'sharpnessVariance': 150.0, 'meanLuma': 120.0, 'clippedFraction': 0.01}
    cases = [
        ('level-open', synthetic_mesh(0.30, 0.30)),
        ('closed', synthetic_mesh(0.06, 0.06)),
        ('half-closed', synthetic_mesh(0.17, 0.17)),
        ('one-eye-closed', synthetic_mesh(0.30, 0.02)),
        ('turned-yaw-negative', synthetic_mesh(0.30, 0.30, yaw_tan=0.6)),
        ('turned-yaw-positive', synthetic_mesh(0.30, 0.30, yaw_tan=-0.6)),
        ('slightly-turned', synthetic_mesh(0.30, 0.30, yaw_tan=0.15)),
        ('tipped-back', synthetic_mesh(0.30, 0.30, pitch_tan=-0.5)),
        ('tipped-down', synthetic_mesh(0.30, 0.30, pitch_tan=0.5)),
        ('slightly-tipped', synthetic_mesh(0.30, 0.30, pitch_tan=0.1)),
        ('turned-and-tipped', synthetic_mesh(0.28, 0.27, yaw_tan=0.2, pitch_tan=-0.15)),
        ('skewed-midline', synthetic_mesh(0.30, 0.30, yaw_tan=0.3, pitch_tan=0.2, chin_x=24.0)),
    ]
    rows = []
    for case_id, points in cases:
        rows.append({'id': case_id, 'count': LANDMARK_COUNT, 'fill': [128.0, 128.0, 0.0], 'points': points, 'rect': rect,
                     'faceWidthPixels': 180.0, 'crop': crop})
    flat = synthetic_mesh(0.30, 0.30)
    for index in LEFT_EYE:
        flat[str(index)] = list(flat[str(LEFT_EYE[0])])
    rows.append({'id': 'one-eye-unmeasured', 'count': LANDMARK_COUNT, 'fill': [128.0, 128.0, 0.0], 'points': flat, 'rect': rect,
                 'faceWidthPixels': 180.0, 'crop': crop})
    no_pose = synthetic_mesh(0.30, 0.30)
    no_pose[str(CHIN)] = list(no_pose[str(FOREHEAD)])
    rows.append({'id': 'no-pose', 'count': LANDMARK_COUNT, 'fill': [128.0, 128.0, 0.0], 'points': no_pose, 'rect': rect,
                 'faceWidthPixels': 180.0, 'crop': crop})
    rows.append({'id': 'small-face-eyes-unknown', 'count': LANDMARK_COUNT, 'fill': [128.0, 128.0, 0.0], 'points': synthetic_mesh(0.30, 0.30),
                 'rect': rect, 'faceWidthPixels': calibration['eyesFromWidth'] - 0.5, 'crop': crop})
    rows.append({'id': 'eyes-at-the-width', 'count': LANDMARK_COUNT, 'fill': [128.0, 128.0, 0.0], 'points': synthetic_mesh(0.30, 0.30),
                 'rect': rect, 'faceWidthPixels': calibration['eyesFromWidth'], 'crop': crop})
    small = synthetic_mesh(0.30, 0.30)
    rows.append({'id': 'small-face-gated', 'count': LANDMARK_COUNT, 'fill': [128.0, 128.0, 0.0], 'points': small, 'rect': rect,
                 'faceWidthPixels': 32.0, 'crop': crop})
    for row in rows:
        row['expect'] = mesh_fields(row, calibration)
    rows.append({'id': 'wrong-count', 'count': LANDMARK_COUNT - 1, 'fill': [128.0, 128.0, 0.0], 'points': {}, 'rect': rect,
                 'faceWidthPixels': 180.0, 'crop': crop, 'expect': None})
    return rows


INSIDE_SCREEN_SHARE = 0.5


def inside_screen(face, screens):
    area = max(0.0, face['width']) * max(0.0, face['height'])
    if not area > 0:
        return False
    for screen in screens:
        width = min(face['x'] + face['width'], screen['x'] + screen['width']) - max(face['x'], screen['x'])
        height = min(face['y'] + face['height'], screen['y'] + screen['height']) - max(face['y'], screen['y'])
        if width > 0 and height > 0 and width * height >= INSIDE_SCREEN_SHARE * area:
            return True
    return False


def speaker_order(faces, content_width, content_height, screens, speaker_score):
    """SpeakerFace.ReadingOrder: outside every screen first, then confident (score >= speaker_score), then the larger, then the
    given order. Returns the faces' indices."""
    keyed = [(inside_screen(picture_rect(face, content_width, content_height), screens), face['score'] < speaker_score, -area(face), index)
             for index, face in enumerate(faces)]
    return [index for *_, index in sorted(keyed)]


def speaker_cases(calibration):
    """The speaker's reading order on boxes in a 640 x 384 detector input (content 640 x 360), with the catalogue's speakerScore."""
    def box(x, y, width, height, score):
        return {'x': x, 'y': y, 'width': width, 'height': height, 'score': score}
    confident = calibration['speakerScore'] + 0.05
    weak = calibration['speakerScore'] - 0.05
    slide = {'x': 0.5, 'y': 0.0, 'width': 0.5, 'height': 0.6}
    cases = [
        ('one-face', [box(100, 80, 120, 150, confident)], []),
        ('largest-first', [box(100, 80, 60, 75, confident), box(300, 60, 120, 150, confident)], []),
        ('equal-boxes-keep-the-decoders-order', [box(100, 80, 100, 120, confident + 0.01), box(400, 80, 100, 120, confident)], []),
        ('weak-graphic-face-behind-a-title', [box(40, 20, 280, 300, weak), box(420, 60, 95, 130, confident)], []),
        ('at-the-speaker-score', [box(40, 20, 280, 300, calibration['speakerScore']), box(420, 60, 95, 130, 0.99)], []),
        ('only-weak-faces', [box(40, 20, 90, 100, weak), box(420, 60, 140, 160, weak - 0.1)], []),
        ('face-on-a-screen', [box(360, 40, 180, 170, confident), box(60, 120, 90, 110, confident)], [slide]),
        ('mostly-on-a-screen', [box(260, 40, 160, 170, confident), box(60, 120, 90, 110, confident)], [slide]),
        ('partly-on-a-screen', [box(200, 40, 160, 170, confident), box(60, 120, 90, 110, confident)], [slide]),
        ('screen-and-weak', [box(360, 40, 180, 170, confident), box(60, 120, 90, 110, weak), box(200, 200, 40, 50, confident)], [slide]),
        ('every-face-on-a-screen', [box(340, 20, 60, 70, confident), box(420, 60, 120, 150, confident)], [slide]),
    ]
    rows = []
    for case_id, faces, screens in cases:
        order = speaker_order(faces, 640, 360, screens, calibration['speakerScore'])
        # The face count when the mesh confirms the first box read: it and every later confident box (SpeakerFace.FaceCount).
        count = 1 + sum(1 for index in order[1:] if faces[index]['score'] >= calibration['speakerScore'])
        rows.append({'id': case_id, 'faces': faces, 'contentWidth': 640, 'contentHeight': 360, 'screens': screens,
                     'speakerScore': calibration['speakerScore'], 'expect': order, 'expectCount': count})
    return rows


def quality_cases(calibration):
    good = {'sharpnessVariance': 200.0, 'meanLuma': 120.0, 'clippedFraction': 0.01}

    def crop(**changes):
        return {**good, **changes}
    cases = [
        ('clear', 0.28, 0.02, 0.05, 200.0, good, None),
        ('closed', 0.10, 0.02, 0.05, 200.0, good, None),
        ('half-open', 0.19, 0.0, 0.0, 200.0, good, None),
        ('turned', 0.28, 0.45, 0.0, 200.0, good, None),
        ('turned-past-the-span', 0.28, -0.7, 0.0, 200.0, good, None),
        ('tipped-back', 0.28, 0.0, -0.3, 200.0, good, None),
        ('blurred', 0.28, 0.0, 0.0, 200.0, crop(sharpnessVariance=10.0), None),
        ('sharpness-floor', 0.28, 0.0, 0.0, 200.0, crop(sharpnessVariance=30.0), None),
        ('sharpness-ceiling', 0.28, 0.0, 0.0, 200.0, crop(sharpnessVariance=400.0), None),
        ('very-sharp', 0.28, 0.0, 0.0, 200.0, crop(sharpnessVariance=1000.0), None),
        ('flat-crop', 0.28, 0.0, 0.0, 200.0, crop(sharpnessVariance=0.0), None),
        ('small-face', 0.28, 0.0, 0.0, 39.5, good, None),
        ('size-at-the-gate', 0.28, 0.0, 0.0, 40.0, good, None),
        ('too-dark', 0.28, 0.0, 0.0, 200.0, crop(meanLuma=39.9), None),
        ('dark-at-the-gate', 0.28, 0.0, 0.0, 200.0, crop(meanLuma=40.0), None),
        ('too-bright', 0.28, 0.0, 0.0, 200.0, crop(meanLuma=220.5), None),
        ('bright-at-the-gate', 0.28, 0.0, 0.0, 200.0, crop(meanLuma=220.0), None),
        ('too-clipped', 0.28, 0.0, 0.0, 200.0, crop(clippedFraction=0.26), None),
        ('clipped-at-the-gate', 0.28, 0.0, 0.0, 200.0, crop(clippedFraction=0.25), None),
        ('no-eyes', None, 0.0, 0.0, 200.0, good, None),
        ('no-yaw', 0.28, None, 0.0, 200.0, good, None),
        ('no-pitch', 0.28, 0.0, None, 200.0, good, None),
        ('quantile-map', 0.28, 0.02, 0.05, 200.0, good, [[0.3, 0.25], [0.5, 0.45]]),
        ('quantile-map-top-segment', 0.30, 0.0, 0.0, 200.0, crop(sharpnessVariance=400.0), [[0.3, 0.25], [0.5, 0.45]]),
        ('quantile-map-gated', 0.28, 0.0, 0.0, 30.0, good, [[0.3, 0.25], [0.5, 0.45]]),
    ]
    rows = []
    for case_id, eyes, yaw, pitch, width, stats, quantile_map in cases:
        row = {'id': case_id, 'eyeAspect': eyes, 'yaw': yaw, 'pitch': pitch, 'faceWidthPixels': width, 'crop': stats,
               'quantileMap': quantile_map}
        row['expect'] = quality_parts(eyes, yaw, pitch, width, stats, calibration, quantile_map)
        rows.append(row)
    return rows


def generated():
    check_series()
    catalogue = json.loads(CATALOGUE.read_text(encoding='utf-8'))
    calibration = catalogue['models'][0]['calibration']
    sections = {
        'inputSizes': input_size_cases(),
        'decodes': decode_cases(),
        'crops': crop_cases(),
        'samples': sample_cases(),
        'cropStats': crop_stat_cases(calibration['quality']['gates']),
        'meshes': mesh_cases(calibration),
        'qualities': quality_cases(calibration),
        'speakers': speaker_cases(calibration),
    }
    return {
        'schema': 'voxclip-frame-face-fields-cases/1',
        'description': 'The pure steps from YuNet\'s and Face Mesh V2\'s outputs to a FrameFace on Windows (ADR-R48 Windows, packages '
                       'W2 and W8: the speaker\'s reading order and the small-face eyes), on synthetic tensors and landmark sets, with the calibration of shared/catalog/frame-models.json. '
                       'Generated by tools/fixtures/clip-frames/generate_face_fields.py; C# FrameFaceFieldsVectorTests replays every '
                       'case, comparing numbers within 1e-9 relative.',
        'constants': {
            'strides': STRIDES, 'scoreThreshold': SCORE_THRESHOLD, 'nmsThreshold': NMS_THRESHOLD, 'longSide': LONG_SIDE,
            'alignment': ALIGNMENT, 'cropSize': CROP_SIZE, 'expansion': EXPANSION, 'landmarkCount': LANDMARK_COUNT,
            'rightEyeContour': RIGHT_EYE, 'leftEyeContour': LEFT_EYE, 'rightEyeOuter': RIGHT_EYE_OUTER, 'leftEyeOuter': LEFT_EYE_OUTER,
            'forehead': FOREHEAD, 'chin': CHIN,
        },
        'calibration': calibration,
        'caseCount': sum(len(cases) for cases in sections.values()),
        'counts': {key: len(cases) for key, cases in sections.items()},
        **sections,
    }


def main():
    DESTINATION.write_text(json.dumps(generated(), indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
