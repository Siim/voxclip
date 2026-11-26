#!/usr/bin/env python3
"""Generate the shared music-mix vectors (doc/spec/music.md section 4).

Writes shared/fixtures/music/music-mix-cases.json (format voxclip-music-mix-cases/1): the music bed's levels and timing,
computed here by a straight port of Mac Core MusicMix.swift, so a second implementation can replay them. A new file of its
own, so neither Core's existing music replays change. Both platforms replay every category: Windows Core MusicMixVectorTests
and Media MusicBedTests, Mac Core MusicMixVectorTests and Media MusicBedVectorTests (the beds through MusicBedPlan). Floats are rounded to 9 decimals, so libm's last-bit differences between platforms
never change the bytes; replays compare within 1e-9 (1e-6 for float32 bed samples). Deterministic; run from anywhere.
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/music/music-mix-cases.json'

FRAME_SECONDS = 0.01
DUCK_DB = -12.0
ATTACK_SECONDS = 0.15
RELEASE_SECONDS = 0.4
LOOP_CROSSFADE_SECONDS = 1.0
FALLBACK_SPEECH_DB = -20.0
SILENCE_FLOOR_DB = -120.0
MAXIMUM_BOOST_DB = 12.0
MINIMUM_BED_DB = -60.0
BRIDGE_GAP_SECONDS = 0.25
MINIMUM_SPEECH_SECONDS = 0.05


def rounded(value):
    """Swift's .rounded(): half away from zero."""
    return math.floor(value + 0.5) if value >= 0 else -math.floor(-value + 0.5)


def r9(value):
    return round(value, 9) + 0.0


def frame_levels(mono, rate):
    size = max(1, int(rounded(rate * FRAME_SECONDS)))
    levels, total, count = [], 0.0, 0
    for sample in mono:
        total += sample * sample
        count += 1
        if count == size:
            mean = total / count
            levels.append(max(SILENCE_FLOOR_DB, 10 * math.log10(mean)) if mean > 0 else SILENCE_FLOOR_DB)
            total, count = 0.0, 0
    if count:
        mean = total / count
        levels.append(max(SILENCE_FLOOR_DB, 10 * math.log10(mean)) if mean > 0 else SILENCE_FLOOR_DB)
    return levels


def replace_runs(flags, value, limit, replacement, interior_only):
    start = 0
    while start < len(flags):
        end = start
        while end < len(flags) and flags[end] == flags[start]:
            end += 1
        interior = start > 0 and end < len(flags)
        if flags[start] == value and end - start < limit and (interior or not interior_only):
            for index in range(start, end):
                flags[index] = replacement
        start = end


def speech_activity(levels):
    audible = sorted(level for level in levels if level > -80)
    if not audible:
        return [False] * len(levels)
    index = min(len(audible) - 1, int(rounded((len(audible) - 1) * 0.9)))
    threshold = max(-50.0, audible[index] - 25)
    active = [level >= threshold for level in levels]
    replace_runs(active, True, int(rounded(MINIMUM_SPEECH_SECONDS / FRAME_SECONDS)), False, False)
    replace_runs(active, False, int(rounded(BRIDGE_GAP_SECONDS / FRAME_SECONDS)), True, True)
    return active


def power_mean_db(levels, include):
    total, count = 0.0, 0
    for level, included in zip(levels, include):
        if included:
            total += 10 ** (level / 10)
            count += 1
    return 10 * math.log10(total / count) if count and total > 0 else None


def music_level_db(levels):
    return power_mean_db(levels, [level > -70 for level in levels])


def bed_gain_db(speech, music, gain):
    speech = FALLBACK_SPEECH_DB if speech is None else speech
    music = speech if music is None else music
    return min(MAXIMUM_BOOST_DB, max(MINIMUM_BED_DB, speech + gain - music))


def ducking_gains_db(activity, ducking=True, depth=DUCK_DB):
    if not ducking or True not in activity:
        return [0.0] * len(activity)
    attack = max(1.0, ATTACK_SECONDS / FRAME_SECONDS)
    release = max(1.0, RELEASE_SECONDS / FRAME_SECONDS)
    count = len(activity)
    until_next, since_last = [math.inf] * count, [math.inf] * count
    nxt = math.inf
    for index in range(count - 1, -1, -1):
        nxt = 0 if activity[index] else nxt + 1
        until_next[index] = nxt
    last = math.inf
    for index in range(count):
        last = 0 if activity[index] else last + 1
        since_last[index] = last
    return [min(depth * max(0, 1 - until_next[i] / attack), depth * max(0, 1 - since_last[i] / release)) for i in range(count)]


def duck_factor(gains, seconds):
    if not gains:
        return 1.0
    position = seconds / FRAME_SECONDS - 0.5
    lower = max(0, min(len(gains) - 1, math.floor(position)))
    upper = min(len(gains) - 1, lower + 1)
    fraction = max(0.0, min(1.0, position - lower))
    return 10 ** ((gains[lower] + (gains[upper] - gains[lower]) * fraction) / 20)


def fade_factor(seconds, duration, fade_in, fade_out):
    factor = 1.0
    if fade_in > 0:
        factor = min(factor, max(0.0, seconds / fade_in))
    if fade_out > 0:
        factor = min(factor, max(0.0, (duration - seconds) / fade_out))
    return min(1.0, factor)


def loop_pieces(track, offset, output, crossfade):
    if track < 4 or output <= 0 or offset < 0 or offset >= track:
        return []
    pieces = [dict(sourceStart=offset, outputStart=0, count=min(track - offset, output), fadeIn=0, fadeOut=0)]
    end = pieces[0]['count']
    crossfade = max(1, min(crossfade, track // 4))
    while end < output:
        overlap = min(crossfade, pieces[-1]['count'] // 2)
        start = end - overlap
        count = min(track, output - start)
        pieces[-1]['fadeOut'] = overlap
        pieces.append(dict(sourceStart=0, outputStart=start, count=count, fadeIn=overlap, fadeOut=0))
        end = start + count
    return pieces


def piece_weight(piece, index):
    weight = 1.0
    if piece['fadeIn'] > 0 and index < piece['fadeIn']:
        weight *= math.sin(math.pi / 2 * (index + 0.5) / piece['fadeIn'])
    tail = piece['count'] - index
    if piece['fadeOut'] > 0 and tail <= piece['fadeOut']:
        weight *= math.sin(math.pi / 2 * (tail - 0.5) / piece['fadeOut'])
    return weight


def tone(frames, amplitude, period, phase=0):
    """A deterministic integer-period triangle wave, exact in binary at these amplitudes."""
    values = []
    for index in range(frames):
        position = ((index + phase) % period) / period
        values.append(amplitude * (4 * position - 1 if position < 0.5 else 3 - 4 * position))
    return values


def speech_levels_case(name, pattern):
    """Levels from a pattern of (seconds, dB) runs at 10 ms frames."""
    levels = []
    for seconds, level in pattern:
        levels += [level] * int(rounded(seconds / FRAME_SECONDS))
    return name, levels


def bed(entry, track, speech, output_frames, rate):
    """The Windows MusicBed.Create + Mix arithmetic in double precision: the per-frame gain and the stereo sample."""
    track_frames = len(track) // 2
    offset = int(rounded(entry['startOffsetSeconds'] * rate))
    pieces = loop_pieces(track_frames, min(offset, max(0, track_frames - 1)), output_frames, int(LOOP_CROSSFADE_SECONDS * rate))
    first = pieces[0]['sourceStart']
    power = [math.sqrt((track[2 * (i + first)] ** 2 + track[2 * (i + first) + 1] ** 2) / 2) for i in range(track_frames - first)]
    music = music_level_db(frame_levels(power, rate))
    activity = speech_activity(speech)
    speech_db = power_mean_db(speech, activity)
    bed_db = bed_gain_db(speech_db, music, entry['gainDb'])
    ducking = ducking_gains_db(activity, entry['ducking'])
    duration = output_frames / rate
    gains, samples = [], []
    for frame in range(output_frames):
        left = right = 0.0
        for piece in pieces:
            if piece['outputStart'] <= frame < piece['outputStart'] + piece['count']:
                index = frame - piece['outputStart']
                weight = piece_weight(piece, index)
                source = 2 * (piece['sourceStart'] + index)
                left += track[source] * weight
                right += track[source + 1] * weight
        seconds = frame / rate
        gain = 10 ** (bed_db / 20) * fade_factor(seconds, duration, entry['fadeInSeconds'], entry['fadeOutSeconds']) * duck_factor(ducking, seconds)
        gains.append(gain)
        samples.append((left * gain, right * gain))
    return dict(pieces=pieces, musicDb=music, speechDb=speech_db, bedGainDb=bed_db, gains=gains, samples=samples)


def main():
    rate = 1000
    mono = tone(95, 0.5, 20) + [0.0] * 20 + tone(30, 0.125, 8)
    level_cases = [dict(id='triangle-silence-quiet', sampleRate=rate, mono=mono, levels=[r9(v) for v in frame_levels(mono, rate)]),
                   dict(id='partial-frame', sampleRate=48_000, mono=[0.25] * 3, levels=[r9(v) for v in frame_levels([0.25] * 3, 48_000)])]

    activity_cases = []
    for name, levels in [
        speech_levels_case('two-phrases-bridged', [(0.3, -90), (0.6, -18), (0.2, -60), (0.5, -20), (0.4, -90)]),
        speech_levels_case('blip-dropped', [(0.2, -90), (0.03, -10), (0.5, -90), (0.4, -22), (0.1, -90)]),
        speech_levels_case('long-gap-kept', [(0.4, -21), (0.3, -95), (0.4, -21)]),
        speech_levels_case('edge-gap-not-bridged', [(0.1, -95), (0.5, -19), (0.1, -95)]),
        speech_levels_case('floor-at-minus-50', [(0.5, -45), (0.5, -55), (0.5, -40)]),
        ('silent', [-120.0] * 40),
    ]:
        active = speech_activity(levels)
        gains = ducking_gains_db(active)
        activity_cases.append(dict(id=name, levels=levels, activity=active, speechDb=None if power_mean_db(levels, active) is None else r9(power_mean_db(levels, active)),
                                   duckingDb=[r9(g) for g in gains], duckingOff=[r9(g) for g in ducking_gains_db(active, False)],
                                   duckFactors=[dict(seconds=s, factor=r9(duck_factor(gains, s))) for s in [0.0, 0.004, 0.155, 0.3, 0.305, 0.9, 1.1, 1.5, 9.0]]))

    bed_gain_cases = [dict(speechDb=s, musicDb=m, gainDb=g, bedGainDb=r9(bed_gain_db(s, m, g)))
                      for s, m, g in [(-18.0, -12.0, -20.0), (None, -14.0, -20.0), (-22.0, None, -20.0), (-20.0, -70.0, 0.0),
                                      (-40.0, 0.0, -40.0), (-16.5, -9.25, -6.0)]]
    music_level_cases = [dict(levels=levels, musicDb=None if music_level_db(levels) is None else r9(music_level_db(levels)))
                         for levels in [[-12.0, -15.0, -90.0], [-80.0, -75.0], [-6.0]]]
    fade_cases = [dict(seconds=s, duration=d, fadeIn=i, fadeOut=o, factor=r9(fade_factor(s, d, i, o)))
                  for s, d, i, o in [(0, 10, 0.5, 1.5), (0.25, 10, 0.5, 1.5), (5, 10, 0.5, 1.5), (9.25, 10, 0.5, 1.5), (10, 10, 0.5, 1.5),
                                     (0.1, 1, 0, 0), (0.2, 0.6, 0.5, 0.5), (3, 10, 0, 1.5)]]
    loop_cases = []
    for track, offset, output, crossfade in [(1000, 0, 400, 100), (1000, 700, 600, 100), (300, 0, 1000, 100), (300, 250, 1000, 100),
                                             (10, 0, 25, 100), (3, 0, 10, 1), (100, 100, 10, 5), (100, 0, 0, 5)]:
        pieces = loop_pieces(track, offset, output, crossfade)
        # Each piece's weight at its edges, the last fade-in frame, its middle and the first fade-out frame.
        indices = [sorted({0, 1, max(0, p['fadeIn'] - 1), p['count'] // 2, p['count'] - p['fadeOut'], p['count'] - 1}) for p in pieces]
        loop_cases.append(dict(trackFrames=track, offsetFrames=offset, outputFrames=output, crossfadeFrames=crossfade, pieces=pieces,
                               weightAt=indices, weights=[[r9(piece_weight(p, i)) for i in at] for p, at in zip(pieces, indices)]))

    bed_cases = []
    for name, entry, track, speech, output in [
        ('trim-ducked-faded', dict(gainDb=-20.0, ducking=True, fadeInSeconds=0.05, fadeOutSeconds=0.1, startOffsetSeconds=0.1),
         [v for pair in zip(tone(800, 0.5, 16), tone(800, 0.25, 16, 4)) for v in pair],
         [-90.0] * 10 + [-18.0] * 20 + [-90.0] * 20, 500),
        ('loop-no-ducking', dict(gainDb=-10.0, ducking=False, fadeInSeconds=0.0, fadeOutSeconds=0.0, startOffsetSeconds=0.0),
         [v for pair in zip(tone(120, 0.5, 12), tone(120, 0.5, 12)) for v in pair],
         [-120.0] * 30, 300),
    ]:
        result = bed(entry, track, speech, output, rate)
        picks = [0, 1, 25, 49, 50, 99, 100, 101, 150, 199, 250, 299, output - 1]
        picks = sorted({p for p in picks if p < output})
        bed_cases.append(dict(id=name, sampleRate=rate, entry=entry, trackStereo=track, speechLevels=speech, outputFrames=output,
                              pieces=result['pieces'], musicDb=r9(result['musicDb']),
                              speechDb=None if result['speechDb'] is None else r9(result['speechDb']), bedGainDb=r9(result['bedGainDb']),
                              frames=picks, gains=[r9(result['gains'][p]) for p in picks],
                              samples=[[r9(result['samples'][p][0]), r9(result['samples'][p][1])] for p in picks]))

    timeline_rate = 100
    first = dict(id='slip', anchorSeconds=1, lengthSeconds=2.5, songFromSeconds=0.5, loop=False, gainDb=0,
                 fadeInSeconds=1, fadeOutSeconds=0.5, gainPoints=[dict(t=0.25, db=-12), dict(t=0.75, db=0)])
    second = dict(id='loop', anchorSeconds=5, lengthSeconds=6, songFromSeconds=1, loop=True, gainDb=0,
                  fadeInSeconds=0, fadeOutSeconds=0)
    track_frames, speed = 400, 2
    first_start = round(first['anchorSeconds'] / speed * timeline_rate)
    second_start = round(second['anchorSeconds'] / speed * timeline_rate)
    first_count = round(first['lengthSeconds'] * timeline_rate)
    overlap = first_start + first_count - second_start
    first_piece = dict(sourceStart=50, outputStart=0, count=first_count, fadeIn=0, fadeOut=0)
    second_pieces = loop_pieces(track_frames, 100, 600, timeline_rate)
    spans = [dict(first_piece, outputStart=first_start, fadeOut=overlap),
             dict(sourceStart=100, outputStart=second_start, count=600, fadeIn=overlap, fadeOut=0)]
    probe_frames = [0, 50, 75, 100, 225, 250, 275, 299, 300, 449, 499, 549, 849, 850]
    probe_samples = []
    for frame in probe_frames:
        mix = 0.0
        for segment, span, pieces in zip([first, second], spans, [[first_piece], second_pieces]):
            local = frame - span['outputStart']
            if not 0 <= local < span['count']:
                continue
            time = local / timeline_rate
            db = -12 + min(1, max(0, (time - 0.25) / 0.5)) * 12 if segment is first else 0
            gain = 10 ** ((-40 + db) / 20) * fade_factor(time, segment['lengthSeconds'], segment['fadeInSeconds'], segment['fadeOutSeconds'])
            for piece in pieces:
                relative = local - piece['outputStart']
                if 0 <= relative < piece['count']:
                    mix += gain * piece_weight(span, local) * piece_weight(piece, relative)
        probe_samples.append(r9(mix))
    timeline = [dict(sampleRate=timeline_rate, trackFrames=track_frames, speed=speed, segments=[first, second],
                     starts=[first_start, second_start], fades=[[0, overlap], [overlap, 0]], pieces=[[first_piece], second_pieces],
                     itemSeconds=[0.125, 0.5, 1.75, 2.25],
                     itemGains=[r9(10 ** (db / 20) * fade_factor(t, 2.5, 1, 0.5))
                                for t, db in [(0.125, -12), (0.5, -6), (1.75, 0), (2.25, 0)]],
                     crossfadeFrame=20, crossfadeWeight=r9(math.sin(math.pi / 2 * 20.5 / overlap)),
                     mixProbe=dict(outputFrames=1_000, trackSample=0.25, gainDb=-20, frames=probe_frames, samples=probe_samples),
                     activity=[False, True, True, False], depthDb=-6,
                     duckingDb=[r9(db) for db in ducking_gains_db([False, True, True, False], depth=-6)])]
    def span(source, start, count, fade_in=0, fade_out=0):
        return dict(sourceStart=source, outputStart=start, count=count, fadeIn=fade_in, fadeOut=fade_out)

    spliced = [span(5, 0, 50, fade_out=20), span(9, 30, 23, 20, 3), span(2, 50, 3, 3), span(0, 60, 5)]
    probes = [[0, 30, 40, 49], [0, 10, 20, 21, 22], [0, 1, 2], [0, 4]]
    # Sounds keep every sample: an edge overlap within the hand-off crossfades; a sound inside another just adds.
    whole = [span(0, 0, 40, fade_out=10), span(0, 30, 30, 10), span(0, 45, 5)]
    whole_probes = [[0, 30, 39], [0, 9, 29], [0, 4]]
    crossfades = [dict(sampleRate=10, spans=[span(5, 0, 60), span(9, 30, 25), span(2, 50, 3), span(0, 60, 5)],
                       expected=spliced, weightAt=probes,
                       weights=[[r9(piece_weight(piece, index)) for index in indices] for piece, indices in zip(spliced, probes)]),
                  dict(sampleRate=10, keepWhole=True, spans=[span(0, 0, 40), span(0, 30, 30), span(0, 45, 5)],
                       expected=whole, weightAt=whole_probes,
                       weights=[[r9(piece_weight(piece, index)) for index in indices] for piece, indices in zip(whole, whole_probes)])]
    document = dict(format='voxclip-music-mix-cases/1',
                    description='Music bed levels and timing (doc/spec/music.md section 4): 10 ms levels, speech activity, ducking, '
                                'bed gain, fades, trims and loops, and two whole beds. Generated by tools/fixtures/music/generate_music_mix.py.',
                    constants=dict(frameSeconds=FRAME_SECONDS, duckDb=DUCK_DB, attackSeconds=ATTACK_SECONDS, releaseSeconds=RELEASE_SECONDS,
                                   loopCrossfadeSeconds=LOOP_CROSSFADE_SECONDS, fallbackSpeechDb=FALLBACK_SPEECH_DB, silenceFloorDb=SILENCE_FLOOR_DB,
                                   maximumBoostDb=MAXIMUM_BOOST_DB, minimumBedDb=MINIMUM_BED_DB, bridgeGapSeconds=BRIDGE_GAP_SECONDS,
                                   minimumSpeechSeconds=MINIMUM_SPEECH_SECONDS),
                    levels=level_cases, activity=activity_cases, bedGain=bed_gain_cases, musicLevel=music_level_cases, fades=fade_cases,
                    loops=loop_cases, beds=bed_cases, timeline=timeline, crossfadeSpans=crossfades)
    document['caseCount'] = sum(len(document[key]) for key in ['levels', 'activity', 'bedGain', 'musicLevel', 'fades', 'loops', 'beds', 'timeline', 'crossfadeSpans'])
    DESTINATION.write_text(json.dumps(document, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
