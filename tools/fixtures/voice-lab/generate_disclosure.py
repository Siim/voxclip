#!/usr/bin/env python3
import json
from pathlib import Path


def intervals(duration, segments):
    expanded = [[0, min(3, duration)]] + [[max(0, start - .5), min(duration, end + .5)] for start, end in segments]
    result = []
    for start, end in sorted(expanded):
        if result and start - result[-1][1] < 1:
            result[-1][1] = max(end, result[-1][1])
        else:
            result.append([start, end])
    return result


cases = [
    ('named-42-seconds', 42, [[12.1, 13.8], [13.9, 14.2]]),
    ('expanded-gap-0.9', 42, [[12, 13], [14.9, 16]]),
    ('expanded-gap-1.1', 42, [[12, 13], [15.1, 16]]),
    ('clamp-near-clip-end', 42, [[41, 41.8]]),
]
output = [{'id': name, 'duration': duration, 'segments': segments, 'expected': intervals(duration, segments)} for name, duration, segments in cases]
path = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/disclosure-intervals.json'
path.write_text(json.dumps({'schema': 'voxclip-disclosure-intervals/1', 'cases': output}, indent=2) + '\n')
