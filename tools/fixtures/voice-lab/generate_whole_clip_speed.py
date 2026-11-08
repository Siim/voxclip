#!/usr/bin/env python3
"""Generate the whole clip's picture speed-up (ADR-R46 "Your own pace", 2026-11-08, voice-lab section 8.14 item 4).

Writes shared/fixtures/voice-lab/whole-clip-speed-cases.json (format voxclip-whole-clip-speed/1), a file of its own so the
twins' replays of the older whole-clip files keep their key sets. The voice is kept as generated; a shorter voice first speeds
the clip's picture up evenly, to at most 1.2x (the user's cap), and the pause layout and the trim take the rest.
- pictureSpeed: the clip as edited / the voice, clamped to 1...1.2; 1 for an unusable input.
- spedCopy: the Fit line's verdict once the picture is sped up, with the factor to two decimals.
- validRetime: the record's videoRetime range, 0.92...1.2.
- spedCuts: the edited cut recipe (zoom 1) with and without a retimeFactor: kept source / output within 1e-6 of a factor above
  1 and at most 1.2, or no factor and kept == output.
- mapping: a sped cut piece's source-to-output and output-to-source mapping, scaled evenly by output / kept.
An independent stdlib reference of the Mac WholeClipRevoice.swift, VoiceLabNaturalPacing.validEditedCuts and
VoiceLabOutputPlan.mapTime/sourceTime; both Cores replay every case (Swift WholeClipSpeedReplayTests, C#
WholeClipSpeedReplayTests). Pure IEEE binary64, byte-exact in check_drift.py.
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/whole-clip-speed-cases.json'

MAXIMUM_PICTURE_SPEED = 1.2
FIT_TOLERANCE = 0.08
EDITED_CUT_ZOOM = 1.0
CUT_PUNCH_IN = 1.06
RATE = 48_000
TIMES = chr(0xD7)


def picture_speed(voice, video):
    if not (math.isfinite(voice) and math.isfinite(video) and voice > 0 and video > 0):
        return 1.0
    return min(MAXIMUM_PICTURE_SPEED, max(1.0, video / voice))


def speed_label(speed):
    return '%.2f' % (speed if math.isfinite(speed) else 1.0) + TIMES


def sped_copy(speed, laid_out):
    return 'picture ' + speed_label(speed) + (" and laid out on the clip's pauses" if laid_out else ' to fit')


def valid_retime(value):
    return math.isfinite(value) and value >= 1 - FIT_TOLERANCE - 1e-9 and value <= MAXIMUM_PICTURE_SPEED + 1e-9


def valid_sped_cuts(case):
    cuts = case['cuts']
    if not (1 <= len(cuts) <= 512) or case['outputSamples'] <= 0 or case['zoom'] != EDITED_CUT_ZOOM:
        return False
    cursor, removed = case['sourceStartSample'], 0
    for start, end in cuts:
        if start < cursor or end <= start or end > case['sourceEndSample']:
            return False
        removed += end - start
        cursor = end
    kept = case['sourceEndSample'] - case['sourceStartSample'] - removed
    factor = case['retimeFactor']
    if factor is None:
        return kept == case['outputSamples']
    measured = kept / case['outputSamples']
    return math.isfinite(factor) and factor > 1 and factor <= MAXIMUM_PICTURE_SPEED and abs(factor - measured) <= 1e-6


def js_round(value):
    """EditingPrimitives.jsRound: the floor, plus one when the fraction is at least a half."""
    lower = math.floor(value)
    return lower + 1 if value - lower >= 0.5 else lower


def map_time(piece, cuts, source):
    """Source seconds inside the sped piece to output seconds, as VoiceLabOutputPlan.mapTime."""
    sample = js_round(source * RATE)
    removed = sum(max(0, min(sample, end) - start) for start, end in cuts)
    kept = sample - piece['sourceStartSample'] - removed
    total_kept = piece['sourceEndSample'] - piece['sourceStartSample'] - sum(end - start for start, end in cuts)
    output = piece['outputEndSample'] - piece['outputStartSample']
    if total_kept == output:
        return (piece['outputStartSample'] + kept) / RATE
    return (float(piece['outputStartSample']) + float(kept) * float(output) / float(total_kept)) / RATE


def source_time(piece, cuts, edited):
    """Output seconds inside the sped piece to source seconds, as VoiceLabOutputPlan.sourceTime."""
    sample = float(js_round(edited * RATE))
    total_kept = piece['sourceEndSample'] - piece['sourceStartSample'] - sum(end - start for start, end in cuts)
    output = piece['outputEndSample'] - piece['outputStartSample']
    offset = sample - float(piece['outputStartSample'])
    kept = offset if total_kept == output else offset * float(total_kept) / float(output)
    source = float(piece['sourceStartSample']) + kept
    for start, end in cuts:
        if source >= start:
            source += float(end - start)
    return source / RATE


def speed_cases():
    pairs = [(20.2, 31.3), (27.0, 31.4), (28.0, 31.3), (31.3, 31.3), (32.0, 31.3), (26.0, 31.2), (26.1, 31.3),
             (10.0, 31.3), (0.0, 31.3), (-1.0, 31.3), (20.2, 0.0)]
    return [{'voiceSeconds': voice, 'videoSeconds': video, 'speed': picture_speed(voice, video)} for voice, video in pairs]


def copy_cases():
    return [{'speed': speed, 'laidOut': laid, 'copy': sped_copy(speed, laid)}
            for speed, laid in [(1.2, True), (31.3 / 28.0, False), (1.005, False), (1.199999, True), (1.0049, True)]]


def retime_cases():
    return [{'value': value, 'valid': valid_retime(value)} for value in [0.92, 0.919, 1.0, 1.08, 1.1, 1.2, 1.2000001, 1.21]]


def sped_cut_cases():
    def case(identity, output, factor, cuts, zoom=EDITED_CUT_ZOOM, start=0, end=192_000):
        row = {'id': identity, 'sourceStartSample': start, 'sourceEndSample': end, 'outputSamples': output,
               'retimeFactor': factor, 'zoom': zoom, 'cuts': cuts}
        row['valid'] = valid_sped_cuts(row)
        return row
    one = [[96_000, 144_000]]
    return [
        case('plain', 144_000, None, one),
        case('sped-cap', 120_000, 1.2, one),
        case('sped-even', 128_000, 144_000 / 128_000, one),
        case('missing-factor', 120_000, None, one),
        case('wrong-factor', 120_000, 1.1, one),
        case('past-the-cap', 117_000, 144_000 / 117_000, one),
        case('declared-one', 144_000, 1.0, one),
        case('slower', 150_000, 144_000 / 150_000, one),
        case('punch-in-zoom', 120_000, 1.2, one, zoom=CUT_PUNCH_IN),
        case('two-cuts', 100_000, 120_000 / 100_000, [[24_000, 48_000], [96_000, 144_000]]),
        case('trim-end', 110_000, 132_000 / 110_000, [[132_000, 192_000]]),
    ]


def mapping_cases():
    sped = {'sourceStartSample': 48_000, 'sourceEndSample': 240_000, 'outputStartSample': 48_000, 'outputEndSample': 168_000}
    plain = {'sourceStartSample': 48_000, 'sourceEndSample': 240_000, 'outputStartSample': 48_000, 'outputEndSample': 120_000}
    rows = []
    for identity, piece, cuts in [('sped', sped, [[144_000, 192_000]]), ('plain', plain, [[96_000, 216_000]])]:
        sources = [1.0, 1.5, 2.0, 2.75, 3.0, 3.5, 4.0, 4.5, 4.999]
        edited = [e for e in [1.0, 1.25, 1.8, 2.0, 2.5, 3.2, 3.49] if js_round(e * RATE) < piece['outputEndSample']]
        rows.append({'id': identity, 'piece': piece, 'cuts': cuts,
                     'mapTime': [{'source': s, 'output': map_time(piece, cuts, s)} for s in sources],
                     'sourceTime': [{'edited': e, 'source': source_time(piece, cuts, e)} for e in edited]})
    return rows


def main():
    document = {
        'format': 'voxclip-whole-clip-speed/1',
        'constants': {'maximumPictureSpeed': MAXIMUM_PICTURE_SPEED, 'fitTolerance': FIT_TOLERANCE, 'sampleRate': RATE},
        'pictureSpeed': speed_cases(),
        'spedCopy': copy_cases(),
        'validRetime': retime_cases(),
        'spedCuts': sped_cut_cases(),
        'mapping': mapping_cases(),
    }
    OUT.write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
