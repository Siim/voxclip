#!/usr/bin/env python3
"""Generate the shared clip-render vectors (doc/design.md sections 6.8 and 6.9, doc/spec/ai.md section 18.5).

Writes shared/fixtures/clip-render/clip-render-cases.json (format voxclip-clip-render-cases/1): the Mac renderer's decisions
a second renderer must reproduce, so Windows' clip controls and Ask Claude effects render as the Mac's do. A new file of
its own, so neither Core's existing replays change. The look goldens are the Mac's ClipControlsRenderTests pixels (Core
Image on the synthetic 4 x 2 frame); `recipe` is ClipLookRecipe's arithmetic on the 8-bit swatches. C# replays every
category (ClipRenderVectorTests in Core and Media), and Swift does (ClipRenderVectorReplayTests in Media). Deterministic;
run from anywhere.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/clip-render/clip-render-cases.json'

LUMA = [0.2126, 0.7152, 0.0722]


def saturation(s, scale=1.0):
    return [[scale * ((1 - s) * LUMA[column] + (s if row == column else 0)) for column in range(3)] for row in range(3)]


RECIPES = {
    'muted': (saturation(0.65, 0.96), [0.04, 0.04, 0.04], None),
    'warm': ([[1.06, 0, 0], [0, 1.01, 0], [0, 0, 0.9]], [0.01, 0.01, 0.01], None),
    'bw': (saturation(0), [0, 0, 0], [0, 0.7, 0.9, -0.6]),
}

# The Mac test's synthetic frame, read top-left first: mid-grey, saturated red, a skin tone, near-black; white, blue, green,
# light grey.
SWATCHES = [[0.5, 0.5, 0.5], [0.9, 0.1, 0.1], [0.85, 0.62, 0.5], [0.05, 0.05, 0.05],
            [1, 1, 1], [0.1, 0.2, 0.9], [0.2, 0.7, 0.3], [0.8, 0.8, 0.8]]

# apps/macos/Tests/VoxClipMediaTests/Pipeline/ClipControlsRenderTests.swift `goldens` (Core Image, +/-1 for GPU rounding).
MAC_GOLDENS = {
    'original': [[128, 128, 128], [229, 26, 26], [217, 158, 128], [13, 13, 13], [255, 255, 255], [26, 51, 229], [51, 178, 77], [204, 204, 204]],
    'muted': [[133, 133, 133], [177, 49, 49], [202, 165, 146], [22, 22, 22], [255, 255, 255], [46, 62, 173], [90, 170, 106], [206, 206, 206]],
    'warm': [[138, 131, 117], [246, 28, 25], [232, 162, 117], [16, 15, 14], [255, 255, 232], [30, 54, 209], [57, 183, 71], [219, 209, 186]],
    'bw': [[128, 128, 128], [62, 62, 62], [174, 174, 174], [9, 9, 9], [255, 255, 255], [51, 51, 51], [146, 146, 146], [211, 211, 211]],
}


def byte(value):
    return int(value * 255 + 0.5)


def apply(look, rgb):
    matrix, bias, curve = RECIPES[look]
    result = []
    for row in range(3):
        value = bias[row] + sum(matrix[row][column] * rgb[column] for column in range(3))
        value = min(1.0, max(0.0, value))
        if curve:
            squared = value * value
            value = curve[0] + curve[1] * value + curve[2] * squared + curve[3] * squared * value
        result.append(min(1.0, max(0.0, value)))
    return result


def map_anchor(flip, degrees, x, y):
    x = 1 - x if flip else x
    if degrees == 90:
        return 1 - y, x
    if degrees == 180:
        return 1 - x, 1 - y
    if degrees == 270:
        return y, 1 - x
    return x, y


def map_rect(flip, degrees, rect):
    first = map_anchor(flip, degrees, rect['x'], rect['y'])
    second = map_anchor(flip, degrees, rect['x'] + rect['width'], rect['y'] + rect['height'])
    x, y = min(first[0], second[0]), min(first[1], second[1])
    return {'x': round(x, 12), 'y': round(y, 12), 'width': round(max(first[0], second[0]) - x, 12),
            'height': round(max(first[1], second[1]) - y, 12)}


def generated():
    # The 8-bit swatches as a frame stores them, then each recipe on those bytes.
    stored = [[byte(channel) / 255 for channel in swatch] for swatch in SWATCHES]
    recipe = {look: [[byte(channel) for channel in apply(look, swatch)] for swatch in stored] for look in RECIPES}
    orient = [
        {'flip': False, 'rotation': 0, 'size': [4, 2], 'topLeft': [128, 128, 128]},
        {'flip': True, 'rotation': 0, 'size': [4, 2], 'topLeft': [13, 13, 13]},
        {'flip': False, 'rotation': 90, 'size': [2, 4], 'topLeft': [255, 255, 255]},
        {'flip': False, 'rotation': 180, 'size': [4, 2], 'topLeft': [204, 204, 204]},
        {'flip': False, 'rotation': 270, 'size': [2, 4], 'topLeft': [13, 13, 13]},
    ]
    boxes = [{'x': 0.1, 'y': 0.15, 'width': 0.25, 'height': 0.4}, {'x': 0.05, 'y': 0.1, 'width': 0.3, 'height': 0.8}]
    map_rects = [{'flip': flip, 'rotation': degrees, 'rect': box, 'expected': map_rect(flip, degrees, box)}
                 for box in boxes for flip in (False, True) for degrees in (0, 90, 180, 270)]
    frames = [
        {'source': [1920, 1080], 'aspect': 'source', 'shape': None, 'rotation': 0, 'size': [1920, 1080]},
        {'source': [1920, 1080], 'aspect': 'source', 'shape': None, 'rotation': 90, 'size': [1080, 1920]},
        {'source': [1920, 1080], 'aspect': '16:9', 'shape': None, 'rotation': 270, 'size': [1920, 1080]},
        {'source': [1920, 1080], 'aspect': '16:9', 'shape': '4:5', 'rotation': 0, 'size': [1080, 1350]},
        {'source': [1920, 1080], 'aspect': 'source', 'shape': '9:16', 'rotation': 90, 'size': [1080, 1920]},
        {'source': [1280, 720], 'aspect': '1:1', 'shape': '1:1', 'rotation': 0, 'size': [1080, 1080]},
    ]
    bitrates = [
        {'shape': '4:5', 'quality': 'standard', 'fps': 30, 'bitrate': 6_500_000},
        {'shape': '4:5', 'quality': 'high', 'fps': 60, 'bitrate': 14_625_000},
        {'shape': '1:1', 'quality': 'standard', 'fps': 30, 'bitrate': 6_000_000},
        {'shape': '9:16', 'quality': 'high', 'fps': 30, 'bitrate': 12_000_000},
    ]
    speeds = [
        {'speed': 1.25, 'rate': 48000, 'editedSamples': 96000, 'renderedSamples': 76800, 'fps': 30, 'frames': 48},
        {'speed': 0.75, 'rate': 48000, 'editedSamples': 96000, 'renderedSamples': 128000, 'fps': 30, 'frames': 80},
        {'speed': 2, 'rate': 48000, 'editedSamples': 96001, 'renderedSamples': 48001, 'fps': 30, 'frames': 30},
        {'speed': 1.25, 'rate': 48000, 'editedSamples': 768720, 'renderedSamples': 614976, 'fps': 30, 'frames': 384},
    ]
    return {
        'schema': 'voxclip-clip-render-cases/1',
        'description': 'The Mac renderer\'s clip-control and Ask Claude effect decisions a second renderer reproduces. '
                       'Generated by tools/fixtures/clip-render/generate_clip_render.py; do not hand-edit.',
        'looks': {'swatches': SWATCHES, 'macGoldens': MAC_GOLDENS, 'recipe': recipe, 'tolerance': 1, 'recipeTolerance': 2},
        'orient': orient,
        'mapRect': map_rects,
        'frames': frames,
        'bitrates': bitrates,
        'speed': speeds,
        'effectsAtSpeed': {
            'speed': 1.25, 'rate': 48000, 'sourceSeconds': 2, 'renderedSamples': 76800,
            'bleep': {'start': 0.5, 'end': 1.0}, 'rampSeconds': 0.010, 'toneHz': 1000, 'toneAmplitude': 0.25,
            'toneFirst': 0.39, 'toneLast': 0.81, 'toneTolerance': 0.001,
            'voiceSilent': [0.4, 0.8], 'silenceTolerance': 0.010,
            'pop': {'start': 1.2, 'durationSeconds': 0.12}, 'popFirst': 0.96, 'popTolerance': 0.002,
            'title': {'start': 0.5, 'end': 1.0, 'shown': [0.46, 0.7], 'hidden': [0.38, 0.82, 1.2], 'shownAtOneX': [0.82]},
            'editedAudioSamples': 96000,
        },
        'srt': [{'speed': 1, 'page': [1, 2], 'cue': '00:00:01,000 --> 00:00:02,000'},
                {'speed': 1.25, 'page': [1, 2], 'cue': '00:00:00,800 --> 00:00:01,600'}],
        'mask': [{'text': 'damn', 'masked': '××××'}, {'text': 'heck!', 'masked': '××××!'},
                 {'text': "it's", 'masked': "××'×"}, {'text': '42%', 'masked': '××%'},
                 {'text': 'õun', 'masked': '×××'}],
    }


def main():
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    DESTINATION.write_text(json.dumps(generated(), indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
