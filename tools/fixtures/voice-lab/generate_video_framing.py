#!/usr/bin/env python3
"""Changed-duration video framing vectors (voice-lab.md ADR-R38): output-frame source mapping, span zoom/anchor and crop
rectangles for Match video (zoomCover, 1.12x) and quiet-boundary cuts (1.06x punch-in after the first cut).

The expectations are computed here with the same IEEE operations, in the same order, as both renderers: Mac
CompositionVideoSpan/CompositionFrameGeometry and Windows VoiceLabVideoFraming/FrameComposer. Crop rectangles are in
top-left coordinates. Run from anywhere; `--check` compares exact bytes."""
import argparse
import json
import math
from pathlib import Path

RATE = 48000
MATCH_ZOOM = 1.12
PUNCH_IN = 1.06


def js_round(value):
    lower = math.floor(value)
    return lower + 1 if value - lower >= 0.5 else lower


def source_piece(source_start, source_end, output_start):
    return {'kind': 'source', 'sourceStartSample': source_start, 'sourceEndSample': source_end,
            'outputStartSample': output_start, 'outputEndSample': output_start + source_end - source_start, 'video': None}


def synth_piece(source_start, source_end, output_start, output_samples, video):
    return {'kind': 'synth', 'sourceStartSample': source_start, 'sourceEndSample': source_end,
            'outputStartSample': output_start, 'outputEndSample': output_start + output_samples, 'video': video}


def match(source, output, face_x=0.5, face_y=0.5):
    return {'mode': 'zoomCover', 'retimeFactor': source / output, 'zoom': MATCH_ZOOM, 'faceX': face_x, 'faceY': face_y,
            'cuts': None}


def cut(cuts):
    return {'mode': 'cut', 'retimeFactor': None, 'zoom': PUNCH_IN, 'faceX': 0.5, 'faceY': 0.5, 'cuts': cuts}


def spans(pieces):
    result = []
    for piece in pieces:
        video = piece['video']
        if video is not None and video['mode'] == 'cut':
            source_start, output_start = piece['sourceStartSample'], piece['outputStartSample']
            for index, (start, end) in enumerate(video['cuts']):
                count = start - source_start
                result.append([source_start, start, output_start, output_start + count, 1.0 if index == 0 else PUNCH_IN, 0.5, 0.5])
                source_start, output_start = end, output_start + count
            result.append([source_start, piece['sourceEndSample'], output_start, piece['outputEndSample'], PUNCH_IN, 0.5, 0.5])
        elif video is not None and video['mode'] == 'zoomCover':
            result.append([piece['sourceStartSample'], piece['sourceEndSample'], piece['outputStartSample'],
                           piece['outputEndSample'], video['zoom'], video['faceX'], video['faceY']])
        else:
            result.append([piece['sourceStartSample'], piece['sourceEndSample'], piece['outputStartSample'],
                           piece['outputEndSample'], 1.0, 0.5, 0.5])
    return result


def source_time(pieces, edited):
    output_samples = pieces[-1]['outputEndSample']
    sample = min(float(output_samples), max(0.0, float(js_round(edited * RATE))))
    for piece in pieces:
        if sample >= piece['outputEndSample']:
            continue
        video = piece['video']
        if video is not None and video['mode'] == 'cut':
            value = piece['sourceStartSample'] + sample - piece['outputStartSample']
            for start, end in video['cuts']:
                if value >= start:
                    value += end - start
            return value / RATE
        fraction = (sample - piece['outputStartSample']) / (piece['outputEndSample'] - piece['outputStartSample'])
        return (piece['sourceStartSample'] + fraction * (piece['sourceEndSample'] - piece['sourceStartSample'])) / RATE
    return pieces[-1]['sourceEndSample'] / RATE


def frames(pieces, fps):
    table = spans(pieces)
    output_samples = pieces[-1]['outputEndSample']
    rows = []
    for index in range(output_samples * fps // RATE):
        edited = index / fps
        span = table[0]
        for candidate in table:
            if edited >= candidate[2] / RATE:
                span = candidate
        rows.append([index, source_time(pieces, edited), span[4], span[5], span[6]])
    return rows


def frame_case(case_id, fps, total, pieces):
    return {'id': case_id, 'fps': fps, 'totalSourceSamples': total, 'pieces': pieces,
            'spans': spans(pieces), 'frames': frames(pieces, fps)}


def crop_case(case_id, source, output, zoom, face_x, face_y):
    source_width, source_height = source
    output_width, output_height = output
    aspect = output_width / output_height
    height = min(float(source_height), source_width / aspect)
    width = height * aspect
    aspect_crop = [(source_width - width) / 2, (source_height - height) / 2, width, height]
    crop_width, crop_height = aspect_crop[2] / zoom, aspect_crop[3] / zoom
    center_x = 0 + source_width * face_x
    center_y = 0 + source_height * face_y
    crop = [min(0 + source_width - crop_width, max(0.0, center_x - crop_width / 2)),
            min(0 + source_height - crop_height, max(0.0, center_y - crop_height / 2)), crop_width, crop_height]
    return {'id': case_id, 'source': list(source), 'output': list(output), 'zoom': zoom, 'faceX': face_x, 'faceY': face_y,
            'aspectCrop': aspect_crop, 'crop': crop}


def document():
    frame_cases = [
        frame_case('source-only-unchanged', 30, 144000, [source_piece(0, 48000, 0), source_piece(96000, 144000, 48000)]),
        frame_case('match-video-slower', 30, 144000, [source_piece(0, 48000, 0),
                                                      synth_piece(48000, 96000, 48000, 60000, match(48000, 60000)),
                                                      source_piece(96000, 144000, 108000)]),
        frame_case('match-video-faster-off-center', 25, 144000, [source_piece(0, 48000, 0),
                                                                synth_piece(48000, 108000, 48000, 48000, match(60000, 48000, 0.3, 0.7)),
                                                                source_piece(108000, 144000, 96000)]),
        frame_case('cut-one-span', 30, 192000, [source_piece(0, 48000, 0),
                                                synth_piece(48000, 163200, 48000, 48000, cut([[72000, 139200]])),
                                                source_piece(163200, 192000, 96000)]),
        frame_case('cut-two-spans', 24, 288000, [synth_piece(0, 240000, 0, 192000, cut([[24000, 48000], [120000, 144000]])),
                                                 source_piece(240000, 288000, 192000)]),
    ]
    crop_cases = [
        crop_case('landscape-to-vertical-match', (1920, 1080), (1080, 1920), MATCH_ZOOM, 0.5, 0.5),
        crop_case('same-aspect-punch-in', (1920, 1080), (1920, 1080), PUNCH_IN, 0.5, 0.5),
        crop_case('portrait-to-square-off-center', (1080, 1920), (1080, 1080), MATCH_ZOOM, 0.3, 0.7),
        crop_case('corner-face-clamps-inside-source', (1280, 720), (720, 1280), MATCH_ZOOM, 1.0, 0.0),
        crop_case('uhd-downscale-punch-in', (3840, 2160), (1920, 1080), PUNCH_IN, 0.5, 0.5),
    ]
    return {
        'schema': 'voxclip-video-framing/1',
        'sampleRate': RATE,
        'matchZoom': MATCH_ZOOM,
        'cutPunchIn': PUNCH_IN,
        'frameCaseCount': len(frame_cases), 'frameCases': frame_cases,
        'cropCaseCount': len(crop_cases), 'cropCases': crop_cases,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/video-framing-cases.json'
    rendered = json.dumps(document(), indent=1) + '\n'
    if args.check:
        if path.read_text() != rendered:
            raise SystemExit('video-framing-cases.json differs; regenerate it')
        print('video-framing-cases.json: identical')
    else:
        path.write_text(rendered)
