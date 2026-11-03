import argparse
import json
import math
import struct
from pathlib import Path


def review_document():
    def single(value):
        return struct.unpack('<f', struct.pack('<f', value))[0]

    def tone(frame):
        period, fade = 21600, 2400
        index = frame % period
        if 0 <= frame < period or index >= fade:
            return single(0.01)
        phase = index / (fade - 1)
        return single(single(single(0.01) * single(math.cos(math.pi * phase / 2))) +
                      single(single(0.01) * single(math.sin(math.pi * phase / 2))))

    def sample(frame):
        if frame < 0 or frame >= 33600:
            local = frame if frame < 0 else frame - 33600
            weight = math.sin(math.pi * min(1, abs(local) / 960) / 2)
            return single(single(single(0.2) * single(weight)) +
                          single(tone(frame) * single(math.sqrt(max(0, 1 - weight * weight)))))
        seconds = frame / 48000
        incoming = math.sin(math.pi * min(1, max(0, (seconds - 0.14 + 0.025) / 0.025)) / 2)
        fraction = min(1, max(0, (seconds - 0.7 + 0.14 + 0.025) / 0.025))
        outgoing = 0 if fraction >= 1 else math.cos(math.pi * fraction / 2)
        return single(single(single(0.5) * single(incoming * outgoing)) + tone(frame))

    offsets = [-960, -720, -480, -240, -1, 0, 4800, 5520, 5820, 6120, 6420, 6720,
               9600, 14400, 16800, 19200, 21600, 22200, 22800, 23400, 23999, 24000,
               25680, 25980, 26280, 26580, 26880, 31200, 33599, 33600, 33840, 34080, 34320, 34559, 34560]
    return {
        'schema': 'voxclip-hard-join-review/1',
        'bedWeights': [{'seconds': seconds, 'expected': 1} for seconds in
                       [0, 0.115, 0.1275, 0.14, 0.2, 0.44, 0.445, 0.45, 1, 1.835, 1.8475, 1.86, 1.99]],
        'sourceFades': [{'rate': rate, 'availableFrames': round(seconds * rate),
                         'fadeFrames': min(round(0.02 * rate), round(seconds * rate) // 2)}
                        for rate in [24000, 48000] for seconds in [0.004, 0.02, 0.039, 0.04, 0.08]],
        'takeEdge': {'rate': 24000, 'frames': 120, 'amplitude': 0.25,
                     'samples': [{'offset': offset, 'incoming': round(0.25 * math.sin(math.pi / 2 * offset / 120), 12),
                                  'outgoing': round(0.25 * math.cos(math.pi / 2 * (offset + 1) / 120), 12)}
                                 for offset in [0, 29, 59, 89, 119]]},
        'microRecipe': {'rate': 48000, 'durationSeconds': 0.7, 'sourceAmplitude': 0.2, 'takeAmplitude': 0.5, 'bedAmplitude': 0.01, 'sampleTolerance': 0.00001,
                        'incoming': {'wordStartSeconds': 0.14, 'wordEndSeconds': 0.3},
                        'outgoing': {'wordStartSeconds': -0.4, 'wordEndSeconds': -0.14},
                        'samples': [{'frame': offset, 'expected': round(sample(offset), 9)} for offset in offsets]},
    }


def document():
    half_power = 0.7071067811865476
    fades = [
        {'id': 'generated-in-silent', 'curve': 'generated', 'seconds': 0.10, 'expected': 0},
        {'id': 'generated-in-start', 'curve': 'generated', 'seconds': 0.115, 'expected': 0},
        {'id': 'generated-in-mid', 'curve': 'generated', 'seconds': 0.1275, 'expected': half_power},
        {'id': 'generated-onset-untouched', 'curve': 'generated', 'seconds': 0.14, 'expected': 1},
        {'id': 'generated-out-start', 'curve': 'generated', 'seconds': 1.835, 'expected': 1},
        {'id': 'generated-out-mid', 'curve': 'generated', 'seconds': 1.8475, 'expected': half_power},
        {'id': 'generated-acoustic-end', 'curve': 'generated', 'seconds': 1.86, 'expected': 0},
        {'id': 'generated-pause', 'curve': 'generated', 'seconds': 1.9, 'expected': 0},
        {'id': 'source-in-start', 'curve': 'source-in', 'seconds': -0.02, 'expected': 1},
        {'id': 'source-in-mid', 'curve': 'source-in', 'seconds': -0.01, 'expected': half_power},
        {'id': 'source-in-end', 'curve': 'source-in', 'seconds': 0, 'expected': 0},
        {'id': 'source-out-start', 'curve': 'source-out', 'seconds': 0, 'expected': 0},
        {'id': 'source-out-mid', 'curve': 'source-out', 'seconds': 0.01, 'expected': half_power},
        {'id': 'source-out-end', 'curve': 'source-out', 'seconds': 0.02, 'expected': 1},
    ]
    gains = [{'seconds': seconds, 'expectedDb': expected} for seconds, expected in
             [(0.13, 0), (0.14, 6), (0.42, 6), (0.43, 3), (0.44, 0),
              (1.55, 0), (1.56, 0), (1.57, 3), (1.58, 6), (1.86, 6), (1.87, 0)]]
    validation = [
        {'id': 'legacy', 'kind': 'hard', 'microPause': None, 'gainDb': None, 'valid': True},
        {'id': 'hard-pause', 'kind': 'hard', 'microPause': {'wordStartSeconds': -0.44, 'wordEndSeconds': -0.14}, 'gainDb': None, 'valid': True},
        {'id': 'hard-gain', 'kind': 'hard', 'microPause': {'wordStartSeconds': -0.44, 'wordEndSeconds': -0.14}, 'gainDb': 6, 'valid': True},
        {'id': 'gap-refuses-pause', 'kind': 'gap', 'microPause': {'wordStartSeconds': -0.44, 'wordEndSeconds': -0.14}, 'gainDb': None, 'valid': False},
        {'id': 'short-pause', 'kind': 'hard', 'microPause': {'wordStartSeconds': -0.44, 'wordEndSeconds': -0.10}, 'gainDb': None, 'valid': False},
        {'id': 'reversed-word', 'kind': 'hard', 'microPause': {'wordStartSeconds': -0.14, 'wordEndSeconds': -0.44}, 'gainDb': None, 'valid': False},
        {'id': 'outside-patch', 'kind': 'hard', 'microPause': {'wordStartSeconds': -3, 'wordEndSeconds': -0.14}, 'gainDb': None, 'valid': False},
        {'id': 'gain-above-cap', 'kind': 'hard', 'microPause': {'wordStartSeconds': -0.44, 'wordEndSeconds': -0.14}, 'gainDb': 6.01, 'valid': False},
        {'id': 'negative-gain', 'kind': 'hard', 'microPause': {'wordStartSeconds': -0.44, 'wordEndSeconds': -0.14}, 'gainDb': -0.01, 'valid': False},
        {'id': 'gain-without-pause', 'kind': 'hard', 'microPause': None, 'gainDb': 1, 'valid': False},
    ]
    return {
        'schema': 'voxclip-hard-join/1',
        'caseCount': len(fades) + len(gains) + len(validation) + 7,
        'rates': [24000, 48000],
        'durationSeconds': 2,
        'incoming': {'wordStartSeconds': 0.14, 'wordEndSeconds': 0.44},
        'outgoing': {'wordStartSeconds': -0.44, 'wordEndSeconds': -0.14},
        'fades': fades,
        'gains': gains,
        'validation': validation,
        'reserve': {'windowSeconds': 1, 'speechSeconds': 0.9, 'legacyOutputSeconds': 1,
                    'outputSeconds': 1.18, 'padSeconds': 0.14, 'pace': 1.2, 'fits': True},
        'roomTone': {'runAmplitude': 0.000005, 'pauseAmplitude': 0.0005, 'gainDb': 40, 'toleranceLu': 2},
        'joinCheck': {'pauseSeconds': [0.14, 0.24], 'speechStepDb': 0, 'excessLu': 0},
        'acoustic': {'alignedStart': 0.2, 'alignedEnd': 0.7, 'audioStart': 0.15, 'audioEnd': 0.8, 'searchLimitSeconds': 0.12},
        'gating': [{'amplitude': 0.1, 'gain': False, 'advisory': False},
                   {'amplitude': 0.07, 'gain': True, 'advisory': False},
                   {'amplitude': 0.01, 'gain': True, 'advisory': True}],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/hard-join-cases.json'
    rendered = json.dumps(document(), indent=2) + '\n'
    if args.check:
        if path.read_text() != rendered:
            raise SystemExit('hard-join-cases.json differs; regenerate it')
        print('hard-join-cases.json: identical')
    else:
        path.write_text(rendered)
    path = path.with_name('hard-join-review-cases.json')
    rendered = json.dumps(review_document(), indent=2) + '\n'
    if args.check:
        if path.read_text() != rendered:
            raise SystemExit('hard-join-review-cases.json differs; regenerate it')
        print('hard-join-review-cases.json: identical')
    else:
        path.write_text(rendered)
