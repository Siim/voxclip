#!/usr/bin/env python3
"""Calibrate the Windows faces against the Mac's Apple Vision (ADR-R48 Windows, package W7). See README.md here.

  python3 -I tools/frames/calibrate/calibrate.py measure        # fetch, decode, hash, run both pipelines; numbers only
  python3 -I tools/frames/calibrate/calibrate.py fit            # fit on the fit split, check on the validation split
  python3 -I tools/frames/calibrate/calibrate.py write          # the catalogue's calibration block (enabled only on a pass)

The frames are US federal public-domain NASA video named in manifest.json (nasa_id, asset URL, seconds and every decoded
frame's SHA-256). They are decoded into the work folder in batches, one subject at a time, fed to both pipelines and deleted.
Only the paired numbers stay (in the work folder, never in the repository). A frame whose bytes differ from its pin is refused.

Needs numpy and scipy, ffmpeg and ffprobe, the Mac package's tests built (swift build --build-tests in apps/macos) and the
runner built (dotnet build -c Release in windows-runner). The fit itself (fit_constants, evaluate) is pure and deterministic.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
from datetime import date

import numpy as np
from scipy.optimize import nnls

sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MANIFEST = HERE / 'manifest.json'
CATALOGUE = ROOT / 'shared' / 'catalog' / 'frame-models.json'
MODELS = ROOT / 'apps' / 'windows' / 'models' / 'frames'
MACOS = ROOT / 'apps' / 'macos'
RUNNER = HERE / 'windows-runner'
RUNNER_DLL = RUNNER / 'bin' / 'Release' / 'net10.0' / 'voxclip-face-calibration.dll'
WORK = pathlib.Path(os.environ.get('VOXCLIP_CALIBRATION_WORK', '/tmp/voxclip-w7'))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The shared pure decisions (the reference both Cores replay byte for byte) and W2's face-field maths.
DECISIONS = load('generate_frame_decisions', ROOT / 'tools' / 'fixtures' / 'clip-frames' / 'generate_frame_decisions.py')
FIELDS = load('generate_face_fields', ROOT / 'tools' / 'fixtures' / 'clip-frames' / 'generate_face_fields.py')

# The study's fixed parts of the formula (windows-frame-analyzer.md, "Proposed Windows score"); the fit leaves them alone.
EYES_OPEN = [0.12, 0.26]
FACING_SPAN = 0.6
# The study's sharpness range, kept fixed. A 16-point grid (low 5-30, high 200-3000) chosen by the NNLS residual was tried on
# 2026-11-09: it raised the fit split's agreement but lowered the held-out subjects' (quality >= 0.25: 0.817 to 0.791), so the fit
# keeps the study's range. The code takes a grid so a later set can try again.
SHARPNESS_GRID = [[30, 400]]
# Frames whose two face boxes overlap less than this are two different faces (a detector picked another face) and stay out of the fit.
SAME_FACE_IOU = 0.3
FIXED_GATES = {'minimumFaceWidth': 40, 'luma': [40, 220], 'clippedBelow': 5, 'clippedAbove': 250, 'clippedFraction': 0.25}
QUANTILES = [10, 25, 50, 75, 90]
# A gate is fitted only when at least this many fit-split faces fall past its fixed value (study, step d).
GATE_EVIDENCE = 30
# Acceptance on the validation split (study, "Calibration so 0.4, 0.25 and the 0.15 margin mean the same").
ACCEPTANCE = {'eyes': 0.98, 'opening': 0.95, 'facing': 0.95, 'quality025': 0.95, 'quality040': 0.85, 'coverRegretP90': 0.06}
COVER_WINDOW = 24
# The speaker rule (W8, SpeakerFace): a box scoring at least speakerScore is a confident detection, which goes before a weak one.
# Fitted as the fit split's lowest speaker score (the box the Mac's face overlaps) rounded down to SPEAKER_STEP.
SPEAKER_STEP = 0.05
# Small faces (W8): the eyes are reported unknown below eyesFromWidth. Fitted on the fit split in bands of EYE_BAND px (from
# EYE_BANDS_FROM): the cut is the top of the highest band, with at least GATE_EVIDENCE faces, whose eye agreement with Vision is
# below the fit split's agreement over all its faces; 0 when none is.
EYE_BAND = 20
EYE_BANDS_FROM = 20
EYE_BANDS_TO = 200
# Eyes "near the line": Vision's mean ratio within this of the 0.20 closed line, where Vision's own consecutive frames disagree
# (a diagnostic only).
EYE_LINE_BAND = 0.02
# The per-recording quality offset tried (W8): q' = q - lambda * (the recording's median q - the fit split's mean Vision median).
# lambda is fitted on the fit split over this grid (the best mean of the two quality lines; ties: the smaller lambda).
RECORDING_OFFSETS = [0.0, 0.25, 0.5, 0.75, 1.0]


# MARK: Manifest, decoding and hashing

def manifest():
    return json.loads(MANIFEST.read_text(encoding='utf-8'))


def manifest_sha256():
    return hashlib.sha256(MANIFEST.read_bytes()).hexdigest()


def frame_size(video, edge):
    width, height = video['width'], video['height']
    scale = edge / max(width, height)
    if scale > 1:
        raise SystemExit(f"{video['nasaId']} is {width}x{height}, smaller than the {edge} px the calibration decodes")
    even = lambda value: int(round(value * scale / 2)) * 2
    return (edge, even(height)) if width >= height else (even(width), edge)


def decode(video, segment, decoding):
    """Every frame of one segment, as raw RGB24 bytes at the manifest's size: ffmpeg seeks to the start (accurate seek), takes
    the duration at the segment's fps and scales with the pinned, bit-exact swscale flags. Four decoding threads at most, so a
    run leaves the machine usable; the hashes show the bytes don't depend on it."""
    width, height = frame_size(video, decoding['edge'])
    duration = segment['end'] - segment['start']
    command = ['ffmpeg', '-v', 'error', '-nostdin', '-threads', '4', '-ss', f"{segment['start']:.3f}", '-i', video['url'], '-t', f'{duration:.3f}',
               '-an', '-sn', '-vf', f"fps={segment['fps']},scale={width}:{height}:flags={decoding['scaler']}",
               '-sws_flags', decoding['swsFlags'], '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-']
    data = subprocess.run(command, capture_output=True, check=True, timeout=1800).stdout
    size = width * height * 3
    if len(data) % size:
        raise SystemExit(f"{video['nasaId']} {segment['start']}: ffmpeg returned a partial frame")
    return width, height, [data[index:index + size] for index in range(0, len(data), size)]


def fetch(subject, folder, decoding):
    """Decodes a subject's frames into folder and returns them as {sha256, path, width, height, time, video, segment}. Refuses
    (SystemExit) a frame whose SHA-256 is not the manifest's."""
    folder.mkdir(parents=True, exist_ok=True)
    frames = []
    for video in subject['videos']:
        for number, segment in enumerate(video['segments']):
            width, height, decoded = decode(video, segment, decoding)
            hashes = [hashlib.sha256(frame).hexdigest() for frame in decoded]
            if hashes != segment['frames']:
                wrong = sum(1 for a, b in zip(hashes, segment['frames']) if a != b) + abs(len(hashes) - len(segment['frames']))
                raise SystemExit(f"{video['nasaId']} at {segment['start']} s: {wrong} of {len(segment['frames'])} decoded frames are "
                                 f"not the pinned bytes (ffmpeg {ffmpeg_version()} vs {decoding['ffmpeg']}). Refusing to calibrate.")
            for index, (frame, sha) in enumerate(zip(decoded, hashes)):
                path = folder / f'{sha}.rgb'
                path.write_bytes(frame)
                frames.append({'sha256': sha, 'path': str(path), 'width': width, 'height': height,
                               'time': round(segment['start'] + index / segment['fps'], 3), 'video': video['nasaId'], 'segment': number})
    return frames


def ffmpeg_version():
    first = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, check=True).stdout.split('\n', 1)[0]
    return first.split()[2]


# MARK: The two pipelines

def macos_reference():
    version = subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True, check=True).stdout.strip()
    build = subprocess.run(['sw_vers', '-buildVersion'], capture_output=True, text=True, check=True).stdout.strip()
    return f'macOS {version} ({build})'


def environment():
    env = {key: value for key, value in os.environ.items() if not key.startswith(('VSTEST_', 'TESTINGPLATFORM_', 'XUNIT_'))}
    env.update({'VOXCLIP_NO_KEYCHAIN': '1', 'VOXCLIP_SHARED_DIR': str(ROOT / 'shared'), 'VOXCLIP_DATA_DIR': str(WORK / 'data')})
    return env


def run_mac(frames, folder):
    job, out = folder / 'mac-job.json', folder / 'mac.jsonl'
    job.write_text(json.dumps({'out': str(out), 'frames': [{k: f[k] for k in ('sha256', 'path', 'width', 'height')} for f in frames]}))
    env = environment() | {'VOXCLIP_CALIBRATION_FRAMES': str(job)}
    result = subprocess.run(['nice', '-n', '10', 'swift', 'test', '--skip-build', '--filter', 'CalibrationVisionHarness'], cwd=MACOS,
                            env=env, capture_output=True, text=True)
    if result.returncode or not out.exists():
        raise SystemExit('The Mac harness failed:\n' + result.stdout[-3000:] + result.stderr[-3000:])
    return {line['sha256']: line for line in map(json.loads, out.read_text().splitlines())}


def run_windows(frames, folder):
    job, out = folder / 'windows-job.json', folder / 'windows.jsonl'
    job.write_text(json.dumps({'out': str(out), 'models': str(MODELS),
                               'frames': [{k: f[k] for k in ('sha256', 'path', 'width', 'height')} for f in frames]}))
    result = subprocess.run(['nice', '-n', '10', 'dotnet', str(RUNNER_DLL), str(job)], env=environment(), capture_output=True, text=True)
    if result.returncode:
        raise SystemExit('The Windows runner failed:\n' + result.stdout[-3000:] + result.stderr[-3000:])
    return {line['sha256']: line for line in map(json.loads, out.read_text().splitlines())}


def measure(args):
    data = manifest()
    paired = WORK / 'paired'
    paired.mkdir(parents=True, exist_ok=True)
    for subject in data['subjects']:
        if args.subject and subject['id'] not in args.subject:
            continue
        target = paired / f"{subject['id']}.jsonl"
        if target.exists() and not args.again:
            continue
        free = shutil.disk_usage(WORK).free / 2**30
        if free < 10:
            raise SystemExit(f'Only {free:.1f} GiB free: stopping before {subject["id"]}.')
        folder = WORK / 'frames' / subject['id']
        try:
            frames = fetch(subject, folder, data['decoding'])
            mac = run_mac(frames, folder)
            windows = run_windows(frames, folder)
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        with target.open('w', encoding='utf-8') as out:
            for frame in frames:
                row = {key: frame[key] for key in ('sha256', 'time', 'video', 'segment')}
                row['subject'] = subject['id']
                row['mac'] = {key: value for key, value in mac[frame['sha256']].items() if key != 'sha256'}
                row['windows'] = {key: value for key, value in windows[frame['sha256']].items() if key != 'sha256'}
                out.write(json.dumps(row, sort_keys=True) + '\n')
        print(f"{subject['id']}: {len(frames)} frames", flush=True)
    (WORK / 'reference.json').write_text(json.dumps({'macos': macos_reference(), 'ffmpeg': ffmpeg_version(),
                                                      'machine': platform.machine()}))


def pin(args):
    """Records the decoded frames' SHA-256 in the manifest (for new segments only; never overwrites a pin)."""
    data = manifest()
    data['decoding']['ffmpeg'] = ffmpeg_version()
    for subject in data['subjects']:
        pending = [s for v in subject['videos'] for s in v['segments'] if not s.get('frames')]
        if not pending:
            continue
        for video in subject['videos']:
            for segment in video['segments']:
                if segment.get('frames'):
                    continue
                _, _, decoded = decode(video, segment, data['decoding'])
                segment['frames'] = [hashlib.sha256(frame).hexdigest() for frame in decoded]
        MANIFEST.write_text(json.dumps(data, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
        print(subject['id'], sum(len(s['frames']) for v in subject['videos'] for s in v['segments']), flush=True)


def paired_rows():
    rows = []
    for path in sorted((WORK / 'paired').glob('*.jsonl')):
        rows.extend(json.loads(line) for line in path.read_text(encoding='utf-8').splitlines())
    return rows


# MARK: The fit (pure)

def mean_of(*values):
    present = [value for value in values if value is not None]
    return sum(present) / len(present) if present else None


def iou(a, b):
    width = min(a['x'] + a['width'], b['x'] + b['width']) - max(a['x'], b['x'])
    height = min(a['y'] + a['height'], b['y'] + b['height']) - max(a['y'], b['y'])
    inside = max(0.0, width) * max(0.0, height)
    union = a['width'] * a['height'] + b['width'] * b['height'] - inside
    return inside / union if union > 0 else 0.0


def faces_in_both(rows):
    """Frames where both pipelines found the same face (boxes overlapping at least SAME_FACE_IOU) with its eyes and pose measured."""
    both = []
    for row in rows:
        mac, win = row['mac'].get('face'), row['windows'].get('face')
        if not mac or not win or mac.get('captureQuality') is None or mac.get('yaw') is None or mac.get('pitch') is None:
            continue
        if iou(mac['rect'], win['rect']) < SAME_FACE_IOU:
            continue
        mac_eyes = mean_of(mac.get('leftEyeAspect'), mac.get('rightEyeAspect'))
        win_eyes = mean_of(win.get('rawLeftEye'), win.get('rawRightEye'))
        if mac_eyes is None or win_eyes is None or win.get('meshYaw') is None:
            continue
        both.append((row, mac_eyes, win_eyes))
    return both


def least_squares(x, y):
    a, b = np.polyfit(np.asarray(x, float), np.asarray(y, float), 1)
    return {'a': float(a), 'b': float(b)}


def gate_mask(width, luma, clipped, gates):
    return (width >= gates['minimumFaceWidth']) & (luma >= gates['luma'][0]) & (luma <= gates['luma'][1]) & \
           (clipped <= gates['clippedFraction'])


def quality_terms(eyes, yaw, pitch, sharp_variance, pitch0, sharpness):
    eyes_open = np.clip((eyes - EYES_OPEN[0]) / (EYES_OPEN[1] - EYES_OPEN[0]), 0, 1)
    facing = np.clip(1 - np.maximum(np.abs(yaw), np.abs(pitch - pitch0)) / FACING_SPAN, 0, 1)
    with np.errstate(divide='ignore'):
        sharp = np.clip((np.log(np.maximum(sharp_variance, 1e-300)) - math.log(sharpness[0])) /
                        (math.log(sharpness[1]) - math.log(sharpness[0])), 0, 1)
    sharp = np.where(sharp_variance > 0, sharp, 0.0)
    return eyes_open, facing, sharp


def fit_constants(rows):
    """Steps (a)-(e) of the study on rows (the fit split). Deterministic: least squares, NNLS and fixed grids only."""
    both = faces_in_both(rows)
    if len(both) < 20:
        raise ValueError('Too few frames with a face in both pipelines to fit.')
    mac = [row['mac']['face'] for row, _, _ in both]
    win = [row['windows']['face'] for row, _, _ in both]
    vision_eyes = np.array([m for _, m, _ in both])
    mesh_eyes = np.array([w for _, _, w in both])
    # (a) the eye-ratio map, (b) the yaw and pitch maps.
    eye_map = least_squares(mesh_eyes, vision_eyes)
    yaw_map = least_squares([w['meshYaw'] for w in win], [m['yaw'] for m in mac])
    pitch_map = least_squares([w['meshPitch'] for w in win], [m['pitch'] for m in mac])
    eyes = eye_map['a'] * mesh_eyes + eye_map['b']
    yaw = yaw_map['a'] * np.array([w['meshYaw'] for w in win]) + yaw_map['b']
    pitch = pitch_map['a'] * np.array([w['meshPitch'] for w in win]) + pitch_map['b']
    target = np.array([m['captureQuality'] for m in mac])
    variance = np.array([w['sharpnessVariance'] for w in win])
    width = np.array([w['faceWidthPixels'] for w in win])
    luma = np.array([w['meanLuma'] for w in win])
    clipped = np.array([w['clippedFraction'] for w in win])

    def weights_for(pitch0, sharpness, inside):
        eyes_open, facing, sharp = quality_terms(eyes, yaw, pitch, variance, pitch0, sharpness)
        design = np.column_stack([np.ones_like(eyes_open), eyes_open * facing, sharp])[inside]
        solution, residual = nnls(design, target[inside])
        return solution, residual

    # (b, c) pitch0, the camera-height offset of the facing term, on a fixed 0.01 rad grid, and the sharpness range on its grid,
    # with the NNLS weights at each; the least residual wins (ties: the smaller |pitch0|, then the grid's order).
    inside = gate_mask(width, luma, clipped, FIXED_GATES)
    grid = [round(value, 2) for value in np.arange(-0.30, 0.3001, 0.01)]
    candidates = [(p0, number, sharpness) for number, sharpness in enumerate(SHARPNESS_GRID) for p0 in grid]
    pitch0, _, sharpness = min(candidates, key=lambda c: (round(weights_for(c[0], c[2], inside)[1], 9), abs(c[0]), c[1]))
    weights, _ = weights_for(pitch0, sharpness, inside)
    w0, w1, w2 = (float(value) for value in weights)

    # (d) the gates: fitted only where the set has faces past the fixed gate; else the study's fixed gate stays.
    eyes_open, facing, sharp = quality_terms(eyes, yaw, pitch, variance, pitch0, sharpness)
    ungated = np.clip(w0 + w1 * eyes_open * facing + w2 * sharp, 0, 1)
    gates = json.loads(json.dumps(FIXED_GATES))
    notes = {}

    def sse(candidate):
        return float(np.sum((np.where(gate_mask(width, luma, clipped, candidate), ungated, 0.0) - target) ** 2))

    evidence = {
        'minimumFaceWidth': int(np.sum(width < FIXED_GATES['minimumFaceWidth'])),
        'lumaLow': int(np.sum(luma < FIXED_GATES['luma'][0])),
        'lumaHigh': int(np.sum(luma > FIXED_GATES['luma'][1])),
        'clippedFraction': int(np.sum(clipped > FIXED_GATES['clippedFraction'])),
    }
    searches = {
        'minimumFaceWidth': ([float(v) for v in range(0, 121, 5)], lambda g, v: g.__setitem__('minimumFaceWidth', v)),
        'lumaLow': ([float(v) for v in range(0, 101, 5)], lambda g, v: g['luma'].__setitem__(0, v)),
        'lumaHigh': ([float(v) for v in range(180, 256, 5)], lambda g, v: g['luma'].__setitem__(1, v)),
        'clippedFraction': ([round(v, 2) for v in np.arange(0.05, 1.0001, 0.05)], lambda g, v: g.__setitem__('clippedFraction', v)),
    }
    for name, count in evidence.items():
        if count < GATE_EVIDENCE:
            notes[name] = f'kept fixed: {count} fit faces past the fixed gate (fewer than {GATE_EVIDENCE})'
            continue
        values, setter = searches[name]

        def cost(value):
            candidate = json.loads(json.dumps(gates))
            setter(candidate, value)
            return sse(candidate)
        best = min(values, key=lambda value: (round(cost(value), 9), values.index(value)))
        setter(gates, best)
        notes[name] = f'fitted: {count} fit faces past the fixed gate'
    gated = np.where(gate_mask(width, luma, clipped, gates), ungated, 0.0)

    # (e) the quantile remap: the score's p10..p90 onto Vision's.
    windows_q = np.percentile(gated, QUANTILES)
    vision_q = np.percentile(target, QUANTILES)
    quantile_map = []
    for x, y in zip(windows_q, vision_q):
        x, y = round(float(x), 4), round(float(y), 4)
        if quantile_map and (x <= quantile_map[-1][0] or y <= quantile_map[-1][1]):
            continue
        if 0 < x < 1 and 0 < y < 1:
            quantile_map.append([x, y])
    rounded = lambda row: {key: round(value, 4) for key, value in row.items()}
    return {
        'eyeAspect': rounded(eye_map), 'yaw': rounded(yaw_map), 'pitch': rounded(pitch_map),
        'quality': {'w0': round(w0, 4), 'w1': round(w1, 4), 'w2': round(w2, 4), 'eyesOpen': EYES_OPEN, 'facingSpan': FACING_SPAN,
                    'pitch0': pitch0, 'sharpness': sharpness, 'quantileMap': quantile_map, 'gates': gates},
        'gateNotes': notes, 'gateEvidence': evidence, 'faces': len(both),
    }


# MARK: The speaker, small faces and the per-recording offset (W8)

def speaker_face(row, speaker_score):
    """The Windows face SpeakerFace's reading order picks from the frame's boxes without screens (the calibration has no OCR): the
    confident boxes (score >= speaker_score) before the weak, the larger first, equal areas in the decoder's order (which the
    runner's largest-first dump keeps), the first the mesh measured. The count is SpeakerFace.FaceCount: the speaker and the confident
    boxes after it. Returns (face count, face or None)."""
    boxes = row['windows'].get('candidates', [])
    order = sorted(range(len(boxes)), key=lambda i: (boxes[i]['detectorScore'] < speaker_score, i))
    for position, index in enumerate(order):
        if boxes[index]['measured']:
            return 1 + sum(1 for later in order[position + 1:] if boxes[later]['detectorScore'] >= speaker_score), boxes[index]['measured']
    return 0, None


def with_speaker(rows, speaker_score):
    """rows with each Windows face replaced by speaker_face's pick (a copy; the rows themselves are left alone)."""
    out = []
    for row in rows:
        count, face = speaker_face(row, speaker_score)
        windows = {key: value for key, value in row['windows'].items() if key != 'face'}
        windows['faceCount'] = count
        if face is not None:
            windows['face'] = face
        out.append({**row, 'windows': windows})
    return out


def check_speaker(rows, speaker_score):
    """The frames whose recorded Windows face (the shipped path's, measured with the catalogue's speakerScore) is not
    speaker_face's pick: the twin and SpeakerFace must agree on every frame."""
    return [row['sha256'] for row in rows
            if (row['windows']['faceCount'], row['windows'].get('face')) != speaker_face(row, speaker_score)]


def fit_speaker_score(rows):
    """The fit split's lowest speaker score (the measured box the Mac's face overlaps), rounded down to SPEAKER_STEP, with the
    evidence: how many speakers and other measured boxes the fit split has, and how many of the others score at least the cut."""
    speakers, others = [], []
    for row in rows:
        mac = row['mac'].get('face')
        for box in row['windows'].get('candidates', []):
            if not box['measured']:
                continue
            (speakers if mac and iou(box['rect'], mac['rect']) >= SAME_FACE_IOU else others).append(box['detectorScore'])
    if not speakers:
        raise ValueError('No speaker boxes to fit the speaker score from.')
    cut = math.floor(min(speakers) / SPEAKER_STEP + 1e-9) * SPEAKER_STEP
    return round(cut, 4), {'speakers': len(speakers), 'lowestSpeaker': round(min(speakers), 4), 'others': len(others),
                           'othersFromCut': sum(1 for score in others if score >= cut)}


def eye_states(row, calibration):
    """Vision's and Windows' eye state (closed below 0.20) on the same face, with Windows' face width, or None."""
    mac, win = row['mac'].get('face'), row['windows'].get('face')
    if not mac or not win or iou(mac['rect'], win['rect']) < SAME_FACE_IOU:
        return None
    vision = mean_of(mac.get('leftEyeAspect'), mac.get('rightEyeAspect'))
    mesh = mean_of(*(None if win.get(key) is None else FIELDS.linear(calibration['eyeAspect'], win[key]) for key in ('rawLeftEye', 'rawRightEye')))
    if vision is None or mesh is None:
        return None
    return vision < DECISIONS.CLOSED_BELOW, mesh < DECISIONS.CLOSED_BELOW, win['faceWidthPixels']


def fit_eyes_from_width(rows, calibration):
    """The width below which Windows reports the eyes unknown, from the fit split's eye agreement in EYE_BAND px bands, and the bands."""
    states = [state for state in (eye_states(row, calibration) for row in rows) if state is not None]
    overall = sum(1 for a, b, _ in states if a == b) / len(states)
    bands, cut = [], 0
    for low in range(EYE_BANDS_FROM, EYE_BANDS_TO, EYE_BAND):
        inside = [(a, b) for a, b, width in states if low <= width < low + EYE_BAND]
        share = sum(1 for a, b in inside if a == b) / len(inside) if inside else None
        bands.append({'from': low, 'faces': len(inside), 'eyes': None if share is None else round(share, 4)})
        if len(inside) >= GATE_EVIDENCE and share < overall:
            cut = low + EYE_BAND
    return cut, {'overall': round(overall, 4), 'bands': bands}


def recording_key(row):
    return row['subject'], row['video']


def recording_offset(rows, calibration, strength, target):
    """The Windows observations of rows with the per-recording offset of the given strength: each recording's own measured
    qualities give its median (only that recording's frames), and every quality moves by strength x (target - median)."""
    observations = {row['sha256'] + str(row['time']): windows_observation(row, calibration) for row in rows}
    qualities = {}
    for row in rows:
        face = observations[row['sha256'] + str(row['time'])].get('face')
        if face and face.get('captureQuality') is not None:
            qualities.setdefault(recording_key(row), []).append(face['captureQuality'])
    medians = {key: float(np.median(values)) for key, values in qualities.items()}
    for row in rows:
        face = observations[row['sha256'] + str(row['time'])].get('face')
        if face and face.get('captureQuality') is not None and strength:
            face['captureQuality'] = min(1.0, max(0.0, face['captureQuality'] - strength * (medians[recording_key(row)] - target)))
    return observations


def fit_recording_offset(rows, calibration):
    """The offset's strength on the fit split: the target is the mean of the fit recordings' Vision medians; each strength on the
    grid is scored by the mean of the two quality lines on the fit split (ties: the smaller). Returns (strength, target, tried)."""
    medians = {}
    for row in rows:
        face = row['mac'].get('face')
        if face and face.get('captureQuality') is not None:
            medians.setdefault(recording_key(row), []).append(face['captureQuality'])
    target = round(float(np.mean([np.median(values) for values in medians.values()])), 4)
    tried = []
    for strength in RECORDING_OFFSETS:
        numbers = evaluate(rows, calibration, recording_offset(rows, calibration, strength, target))
        tried.append({'strength': strength, 'quality025': round(numbers['quality025']['share'], 4),
                      'quality040': round(numbers['quality040']['share'], 4), 'opening': round(numbers['opening']['share'], 4)})
    best = max(tried, key=lambda t: (round((t['quality025'] + t['quality040']) / 2, 9), -t['strength']))
    return best['strength'], target, tried


# MARK: Observations and the shared decisions

def calibration_from(constants):
    return {'eyeAspect': constants['eyeAspect'], 'yaw': constants['yaw'], 'pitch': constants['pitch'], 'quality': constants['quality'],
            'speakerScore': constants.get('speakerScore', 0.0), 'eyesFromWidth': constants.get('eyesFromWidth', 0)}


def mac_observation(row):
    face = row['mac'].get('face')
    value = None
    if face:
        value = DECISIONS.face(face['rect'], face.get('captureQuality'), face.get('leftEyeAspect'), face.get('rightEyeAspect'),
                               face.get('yaw'), face.get('pitch'))
    return DECISIONS.observation(row['time'], value, row['mac']['faceCount'])


def windows_observation(row, calibration):
    """The Windows FrameObservation the shipped path makes with this calibration, from its raw numbers (W2's maths)."""
    face = row['windows'].get('face')
    value = None
    if face:
        left = None if face.get('rawLeftEye') is None else FIELDS.linear(calibration['eyeAspect'], face['rawLeftEye'])
        right = None if face.get('rawRightEye') is None else FIELDS.linear(calibration['eyeAspect'], face['rawRightEye'])
        yaw = None if face.get('meshYaw') is None else FIELDS.linear(calibration['yaw'], face['meshYaw'])
        pitch = None if face.get('meshPitch') is None else FIELDS.linear(calibration['pitch'], face['meshPitch'])
        crop = {key: face[key] for key in ('sharpnessVariance', 'meanLuma', 'clippedFraction')}
        parts = FIELDS.quality_parts(FIELDS.mean(left, right), yaw, pitch, face['faceWidthPixels'], crop, calibration)
        # A face narrower than eyesFromWidth reports its eyes unknown; its quality still uses the measured eyes (FaceMeshFields).
        if face['faceWidthPixels'] < calibration.get('eyesFromWidth', 0):
            left = right = None
        value = DECISIONS.face(face['rect'], None if parts is None else parts['quality'], left, right, yaw, pitch)
    return DECISIONS.observation(row['time'], value, row['windows']['faceCount'])


def by_video(rows):
    groups = {}
    for row in rows:
        groups.setdefault((row['subject'], row['video'], row['segment']), []).append(row)
    return {key: sorted(group, key=lambda r: r['time']) for key, group in groups.items()}


def percentile(values, q):
    return float(np.percentile(np.asarray(values, float), q)) if values else None


def agreement(pairs):
    return {'agree': sum(1 for a, b in pairs if a == b), 'of': len(pairs), 'share': (sum(1 for a, b in pairs if a == b) / len(pairs)) if pairs else None}


def evaluate(rows, calibration, windows=None):
    """Every acceptance number for rows through the shared decisions, on both platforms' observations (windows: the Windows
    observations by frame key, when not windows_observation's).

    The eyes line counts the frames where both platforms state open or closed. A frame where Windows says unknown and Vision
    states a value is not in it: it is reported as eyesUnknown, and eyesStrict counts it the way the decisions read it (unknown is
    not an open look: it agrees with Vision's closed and disagrees with Vision's open). The opening and cover lines run on every
    frame, so they carry what an unknown costs."""
    mac = {row['sha256'] + str(row['time']): mac_observation(row) for row in rows}
    win = windows if windows is not None else {row['sha256'] + str(row['time']): windows_observation(row, calibration) for row in rows}
    key = lambda row: row['sha256'] + str(row['time'])
    baselines = {}
    for group, members in by_video(rows).items():
        video = (group[0], group[1])
        baselines.setdefault(video, (DECISIONS.pitch_baseline([mac[key(r)] for r in rows if (r['subject'], r['video']) == video]),
                                     DECISIONS.pitch_baseline([win[key(r)] for r in rows if (r['subject'], r['video']) == video])))
    presence, eyes, facing, q25, q40, quality_pairs = [], [], [], [], [], []
    strict, away_from_line, unknown = [], [], 0
    for row in rows:
        m, w = mac[key(row)], win[key(row)]
        mac_base, win_base = baselines[(row['subject'], row['video'])]
        presence.append((m.get('face') is not None, w.get('face') is not None))
        if not m.get('face') or not w.get('face'):
            continue
        if m['face']['eyes'] != 'unknown':
            stated = w['face']['eyes'] != 'unknown'
            unknown += not stated
            strict.append((m['face']['eyes'] == 'open', w['face']['eyes'] == 'open'))
            if stated:
                eyes.append((m['face']['eyes'], w['face']['eyes']))
                vision = mean_of(m['face'].get('leftEyeAspect'), m['face'].get('rightEyeAspect'))
                if abs(vision - DECISIONS.CLOSED_BELOW) > EYE_LINE_BAND:
                    away_from_line.append((m['face']['eyes'], w['face']['eyes']))
        mf, wf = DECISIONS.faces_camera(m['face'], mac_base), DECISIONS.faces_camera(w['face'], win_base)
        if mf is not None and wf is not None:
            facing.append((mf, wf))
        mq, wq = m['face'].get('captureQuality'), w['face'].get('captureQuality')
        if mq is not None and wq is not None:
            q25.append((mq >= 0.25, wq >= 0.25))
            q40.append((mq >= 0.40, wq >= 0.40))
            quality_pairs.append((mq, wq))
    # Opening: every 10 fps frame with 0.6 s of frames either side is a clip start; the scan is the 13 frames around it and the
    # silence before it runs back the full 0.6 s (OpeningFrame.choose, as the study simulated it).
    opening, regrets, moves = [], [], [0, 0]
    for group, members in by_video(rows).items():
        video = (group[0], group[1])
        mac_base, win_base = baselines[video]
        mac_frames = [mac[key(r)] for r in members]
        win_frames = [win[key(r)] for r in members]
        for index in range(6, len(members) - 6):
            start = members[index]['time']
            if abs(members[index + 6]['time'] - start - 0.6) > 0.051 or abs(start - members[index - 6]['time'] - 0.6) > 0.051:
                continue
            clip = {'start': start, 'leadInFloor': max(0.0, start - 0.6)}
            a = DECISIONS.choose_opening(clip, mac_frames[index - 6:index + 7], mac_base)
            b = DECISIONS.choose_opening(clip, win_frames[index - 6:index + 7], win_base)
            moves[0] += a is not None and a['shift'] != 0
            moves[1] += b is not None and b['shift'] != 0
            opening.append((None if a is None else round(a['time'], 6), None if b is None else round(b['time'], 6)))
        # Cover: CoverFrame.pick over consecutive 24-frame windows; the regret is how much worse Windows' pick scores than the
        # Mac's under Vision's own scoring (a pick Vision can't use scores 0).
        for begin in range(0, len(members) - COVER_WINDOW + 1, COVER_WINDOW):
            mac_window, win_window = mac_frames[begin:begin + COVER_WINDOW], win_frames[begin:begin + COVER_WINDOW]
            best = DECISIONS.cover_pick(mac_window, mac_base)
            chosen = DECISIONS.cover_pick(win_window, win_base)
            if best is None and chosen is None:
                regrets.append(0.0)
                continue
            if best is None:
                regrets.append(0.0)
                continue
            if chosen is None:
                regrets.append(best['score'])
                continue
            picked = next(f for f in mac_window if f['time'] == chosen['time'])
            score = DECISIONS.cover_score(picked, mac_window, mac_base)
            regrets.append(best['score'] - (score if score is not None else 0.0))
    mac_q = [a for a, _ in quality_pairs]
    win_q = [b for _, b in quality_pairs]
    return {
        'frames': len(rows),
        'facePresence': agreement(presence),
        'facesInBoth': len(quality_pairs),
        'visionClosed': sum(1 for a, _ in eyes if a == 'closed'),
        'eyes': agreement(eyes),
        'eyesUnknown': unknown,
        'eyesStrict': agreement(strict),
        'eyesAwayFromLine': agreement(away_from_line),
        'facing': agreement(facing),
        'quality025': agreement(q25),
        'quality040': agreement(q40),
        'qualityPearson': float(np.corrcoef(mac_q, win_q)[0, 1]) if len(quality_pairs) > 2 and np.std(win_q) > 0 else None,
        'qualityMae': float(np.mean(np.abs(np.subtract(mac_q, win_q)))) if quality_pairs else None,
        'qualityMedian': [percentile(mac_q, 50), percentile(win_q, 50)],
        'opening': agreement(opening),
        'openingMoves': {'mac': moves[0], 'windows': moves[1]},
        'coverWindows': len(regrets),
        'coverRegretMedian': percentile(regrets, 50),
        'coverRegretP90': percentile(regrets, 90),
    }


def passes(numbers):
    """The acceptance lines this evaluation fails (empty when it passes)."""
    failed = []
    for name in ('eyes', 'opening', 'facing', 'quality025', 'quality040'):
        share = numbers[name]['share']
        if share is None or share < ACCEPTANCE[name]:
            failed.append(name)
    if numbers['coverRegretP90'] is None or numbers['coverRegretP90'] > ACCEPTANCE['coverRegretP90']:
        failed.append('coverRegretP90')
    return failed


def wide(row, pixels=100):
    face = row['windows'].get('face')
    return face is None or face['faceWidthPixels'] >= pixels


def same_face(row):
    mac, win = row['mac'].get('face'), row['windows'].get('face')
    return mac is None or win is None or iou(mac['rect'], win['rect']) >= SAME_FACE_IOU


def split_rows(rows, split):
    subjects = {s['id'] for s in manifest()['subjects'] if s['split'] == split}
    return [row for row in rows if row['subject'] in subjects]


def fit(args):
    rows = paired_rows()
    measured_with = json.loads(CATALOGUE.read_text(encoding='utf-8'))['models'][0]['calibration'].get('speakerScore', 0.0)
    differing = check_speaker(rows, measured_with)
    if differing:
        raise SystemExit(f'{len(differing)} frame(s) were measured with a face speaker_face does not pick at speakerScore {measured_with}, '
                         f'e.g. {differing[0]}: the twin and SpeakerFace differ. Fix the twin.')
    # (W8) The speaker score from the fit split's boxes; then every row's Windows face is the speaker rule's pick at that score.
    speaker_score, speaker_evidence = fit_speaker_score(split_rows(rows, 'fit'))
    largest = with_speaker(rows, 0.0)
    rows = with_speaker(rows, speaker_score)
    fit_rows, validation = split_rows(rows, 'fit'), split_rows(rows, 'validation')
    constants = fit_constants(fit_rows)
    constants['speakerScore'], constants['speakerEvidence'] = speaker_score, speaker_evidence
    eyes_from, eye_bands = fit_eyes_from_width(fit_rows, calibration_from(constants))
    constants['eyesFromWidth'], constants['eyeBands'] = eyes_from, eye_bands
    calibration = calibration_from(constants)
    strength, target, tried = fit_recording_offset(fit_rows, calibration)
    constants['recordingOffset'] = {'strength': strength, 'target': target, 'tried': tried}
    report = {'constants': constants, 'fit': evaluate(fit_rows, calibration), 'validation': evaluate(validation, calibration), 'perSubject': {}}
    for subject in sorted({row['subject'] for row in validation}):
        report['perSubject'][subject] = evaluate([row for row in validation if row['subject'] == subject], calibration)
    # The acceptance after each W8 change, from W7's path (the largest face, eyes at every size) on (validation and fit).
    w7 = calibration | {'speakerScore': 0.0, 'eyesFromWidth': 0}
    speaker_only = calibration | {'eyesFromWidth': 0}
    report['steps'] = {
        'w7': {split: evaluate(split_rows(largest, split), w7) for split in ('fit', 'validation')},
        'speaker': {split: evaluate(split_rows(rows, split), speaker_only) for split in ('fit', 'validation')},
        'smallFaces': {split: evaluate(split_rows(rows, split), calibration) for split in ('fit', 'validation')},
    }
    # Diagnostics only (the acceptance is on every validation frame): the same split without faces under 100 px wide at 1,280,
    # and without frames where the two pipelines measured different faces.
    report['diagnostics'] = {
        'validationFacesFrom100px': evaluate([row for row in validation if wide(row)], calibration),
        'validationSameFace': evaluate([row for row in validation if same_face(row)], calibration),
    }
    report['failed'] = passes(report['validation'])
    (WORK / 'report.json').write_text(json.dumps(report, indent=1))
    print_report(report)


def share(row):
    return '—' if row['share'] is None else f"{row['share']:.3f} ({row['agree']}/{row['of']})"


def print_report(report):
    c = report['constants']
    print('constants:', json.dumps({k: c[k] for k in ('eyeAspect', 'yaw', 'pitch', 'quality', 'speakerScore', 'eyesFromWidth')}))
    print('gates:', json.dumps(c['gateNotes']))
    print('speaker:', json.dumps(c['speakerEvidence']))
    print('eye bands (fit):', json.dumps(c['eyeBands']))
    print('recording offset (fit):', json.dumps(c['recordingOffset']))
    header = f"{'set':12s} {'frames':>6s} {'faces':>6s} {'closed':>6s} {'eyes':>18s} {'facing':>18s} {'q>=0.25':>18s} " \
             f"{'q>=0.40':>18s} {'opening':>18s} {'regret p90':>10s} {'pearson':>7s}"
    print(header)
    steps = [(f'{name[:6]} {split[:3]}', numbers) for name, by in report['steps'].items() for split, numbers in by.items()]
    rows = steps + [('fit', report['fit']), ('validation', report['validation'])] + sorted(report['perSubject'].items()) + \
        [('val >=100px', report['diagnostics']['validationFacesFrom100px']), ('val same', report['diagnostics']['validationSameFace'])]
    for name, n in rows:
        pearson = '—' if n['qualityPearson'] is None else f"{n['qualityPearson']:.2f}"
        regret = '—' if n['coverRegretP90'] is None else f"{n['coverRegretP90']:.3f}"
        print(f"{name:12s} {n['frames']:6d} {n['facesInBoth']:6d} {n['visionClosed']:6d} {share(n['eyes']):>18s} {share(n['facing']):>18s} "
              f"{share(n['quality025']):>18s} {share(n['quality040']):>18s} {share(n['opening']):>18s} {regret:>10s} {pearson:>7s}")
    for name in ('fit', 'validation'):
        n = report[name]
        print(f"{name} eyes: unknown {n['eyesUnknown']}, strict {share(n['eyesStrict'])}, away from the line {share(n['eyesAwayFromLine'])}")
    print('failed:', report['failed'] or 'none')


# MARK: The catalogue

def block(value, indent):
    """JSON in the catalogue's style: an object of objects spreads one key per line; a short object or array stays on one line."""
    inline = json.dumps(value, ensure_ascii=False, separators=(', ', ': '))
    if not isinstance(value, dict) or len(inline) + indent <= 120 or indent >= 12:
        return inline
    pad = ' ' * (indent + 2)
    items = [f'{pad}{json.dumps(key)}: {block(item, indent + 2)}' for key, item in value.items()]
    return '{\n' + ',\n'.join(items) + '\n' + ' ' * indent + '}'


def gates_sentence(constants):
    names = {'minimumFaceWidth': 'narrower than the size gate', 'lumaLow': 'darker than the low luma gate',
             'lumaHigh': 'brighter than the high luma gate', 'clippedFraction': 'more clipped than the clipping gate'}
    fixed = [name for name, note in constants['gateNotes'].items() if note.startswith('kept fixed')]
    fitted = [name for name in constants['gateNotes'] if name not in fixed]
    parts = []
    if fixed:
        parts.append('The study\'s fixed gates stay for ' + ', '.join(f"{name} ({constants['gateEvidence'][name]} fit faces {names[name]})"
                                                                     for name in fixed) + f': a gate is fitted only from {GATE_EVIDENCE} faces past it.')
    if fitted:
        parts.append('Fitted gates: ' + ', '.join(fitted) + '.')
    parts.append('The sharpness range, eyes-open span and facing span are the study\'s; pitch0 and the weights are fitted.')
    parts.append(f"speakerScore is the fit split's lowest speaker score ({constants['speakerEvidence']['lowestSpeaker']}) rounded down to "
                 f"{SPEAKER_STEP}; eyesFromWidth is the top of the highest {EYE_BAND} px band of fit faces, with at least {GATE_EVIDENCE} "
                 "faces, whose eye agreement is below the fit split's overall (evaluation.eyeBands). The per-recording quality offset "
                 f"was fitted too and chose strength {constants['recordingOffset']['strength']} (evaluation.recordingOffset), so none is applied.")
    return ' '.join(parts)


def write(args):
    report = json.loads((WORK / 'report.json').read_text())
    reference = json.loads((WORK / 'reference.json').read_text())
    data = manifest()
    text = CATALOGUE.read_text(encoding='utf-8')
    catalogue = json.loads(text)
    c = report['constants']
    passed = not report['failed']
    subjects = data['subjects']
    rounded = lambda n: {key: (round(value, 4) if isinstance(value, float) else value) for key, value in n.items()}
    share4 = lambda line: None if line['share'] is None else round(line['share'], 4)
    numbers = lambda n: {
        'frames': n['frames'], 'facesInBoth': n['facesInBoth'], 'visionClosed': n['visionClosed'],
        'facePresence': share4(n['facePresence']), 'eyes': share4(n['eyes']), 'facing': share4(n['facing']),
        'quality025': share4(n['quality025']), 'quality040': share4(n['quality040']),
        'opening': share4(n['opening']), 'openingScans': n['opening']['of'], 'openingMoves': n['openingMoves'],
        'coverWindows': n['coverWindows'], 'coverRegretMedian': round(n['coverRegretMedian'], 4), 'coverRegretP90': round(n['coverRegretP90'], 4),
        'qualityPearson': None if n['qualityPearson'] is None else round(n['qualityPearson'], 4),
        'qualityMae': None if n['qualityMae'] is None else round(n['qualityMae'], 4),
        'eyesUnknown': n['eyesUnknown'], 'eyesStrict': share4(n['eyesStrict']),
        'eyesAwayFromLine': share4(n['eyesAwayFromLine'])}
    if c['recordingOffset']['strength']:
        raise SystemExit('The fit chose a per-recording quality offset, which the Windows app does not apply yet: add it first.')
    model = catalogue['models'][0]
    model['calibration'] = {
        # Only a passing calibration is "calibrated": the schema and FrameModelCatalog refuse to enable a provisional one, so a
        # failed run keeps its fitted constants and numbers but can't be switched on by the enabled flag alone.
        'status': 'calibrated' if passed else 'provisional',
        'basis': ('' if passed else 'Provisional: the acceptance against the Mac failed (see evaluation.failed), so this calibration '
                  'cannot be enabled. ') + (f"Fitted by tools/frames/calibrate (W7, W8) on {sum(1 for s in subjects if s['split'] == 'fit')} subjects of US federal "
                  f"public-domain NASA video and checked on {sum(1 for s in subjects if s['split'] == 'validation')} held-out subjects "
                  f"(split by subject; manifest tools/frames/calibrate/manifest.json, SHA-256 {manifest_sha256()}); no frames are kept. "
                  + gates_sentence(c)),
        'date': date.today().isoformat(),
        'reference': (f"Apple Vision, {reference['macos']}, AppleFrameVision request set with M1: VNDetectFaceRectanglesRequest revision 3, "
                      'then VNDetectFaceLandmarksRequest and VNDetectFaceCaptureQualityRequest on its largest face, beside VNRecognizeTextRequest '
                      '(fast) and VNDetectRectanglesRequest'),
        'eyeAspect': c['eyeAspect'], 'yaw': c['yaw'], 'pitch': c['pitch'], 'quality': c['quality'],
        'speakerScore': c['speakerScore'], 'eyesFromWidth': c['eyesFromWidth'],
        'evaluation': {
            'manifestSha256': manifest_sha256(),
            'acceptance': ACCEPTANCE,
            'passed': passed,
            'failed': report['failed'],
            'eyesCounting': ('eyes counts the frames where both platforms state open or closed; eyesUnknown is how many Vision-stated '
                             'frames Windows reports unknown (faces under eyesFromWidth), eyesStrict counts those as the decisions read '
                             'them (not an open look), and eyesAwayFromLine leaves out frames whose Vision ratio is within '
                             f'{EYE_LINE_BAND} of the 0.20 line. The opening and cover lines run on every frame.'),
            'speaker': c['speakerEvidence'],
            'eyeBands': c['eyeBands'],
            'recordingOffset': c['recordingOffset'],
            'steps': {name: {split: numbers(n) for split, n in by.items()} for name, by in report['steps'].items()},
            'fit': numbers(report['fit']),
            'validation': numbers(report['validation']),
            'perSubject': {subject: numbers(n) for subject, n in sorted(report['perSubject'].items())},
            'diagnostics': {name: numbers(n) for name, n in report['diagnostics'].items()},
        },
    }
    enabled_note = (
        'On: the calibration against the Mac (W7, W8) passed every acceptance line on the held-out subjects. The licence decision is made: '
        'the user accepted YuNet\'s training-data terms (WIDER FACE) on 2026-11-09, and both files are bundled in the Windows app.'
        if passed else
        'Off: the calibration against the Mac (W7, W8) failed ' + ', '.join(report['failed']) + ' on the held-out subjects (see '
        'calibration.evaluation). The licence decision is made: the user accepted YuNet\'s training-data terms (WIDER FACE) on '
        '2026-11-09, and both files are bundled in the Windows app. While off, nothing loads these models outside tests and the '
        'developer override (VOXCLIP_FRAME_FACES=1).')
    # Only enabled, enabledNote and the calibration block change; the rest of the file keeps its bytes.
    text = re.sub(r'^  "enabled": (true|false),\n', lambda _: f'  "enabled": {json.dumps(passed)},\n', text, count=1, flags=re.M)
    text = re.sub(r'^  "enabledNote": .*,\n', lambda _: f'  "enabledNote": {json.dumps(enabled_note, ensure_ascii=False)},\n', text, count=1, flags=re.M)
    start = text.index('      "calibration": {')
    end = text.index('\n      }\n', start) + len('\n      }')
    text = text[:start] + '      "calibration": ' + block(model['calibration'], 6) + text[end:]
    if json.loads(text)['models'][0]['calibration'] != model['calibration']:
        raise SystemExit('The calibration block did not round-trip.')
    CATALOGUE.write_text(text, encoding='utf-8')
    print('enabled' if passed else 'not enabled: ' + ', '.join(report['failed']))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    run = commands.add_parser('measure', help='decode, hash and run both pipelines, one subject at a time')
    run.add_argument('--subject', action='append', help='only these subject ids')
    run.add_argument('--again', action='store_true', help='measure subjects that already have numbers')
    commands.add_parser('pin', help='record the SHA-256 of segments that have none yet (building the manifest)')
    commands.add_parser('fit', help='fit on the fit split and report the acceptance numbers')
    commands.add_parser('write', help='write the calibration block into shared/catalog/frame-models.json')
    args = parser.parse_args()
    {'measure': measure, 'pin': pin, 'fit': fit, 'write': write}[args.command](args)


if __name__ == '__main__':
    main()
