"""Two-pass loudnorm adapted from the author's A10 trailer tooling, animatic_v2.py.

No radio/game chain, provider calls, hard-coded binaries or third-party DSP code.
"""
import json
import math
from pathlib import Path
import shutil
import subprocess


def executable(name):
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f'{name} is required on PATH')
    return found


def run(args):
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        tail = '\n'.join((error.stderr or '').splitlines()[-20:])
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {error.returncode}):\n{tail}') from error


def loudnorm(source, output):
    ffmpeg = executable('ffmpeg')
    target = 'loudnorm=I=-16:TP=-1:LRA=11'
    measured = run([ffmpeg, '-hide_banner', '-nostdin', '-i', str(source), '-af', target + ':print_format=json', '-f', 'null', '-'])
    values = json.loads(measured.stderr[measured.stderr.rindex('{'):measured.stderr.rindex('}') + 1])
    if not all(math.isfinite(float(values[key])) for key in ['input_i', 'input_tp', 'input_lra', 'input_thresh', 'target_offset']):
        raise ValueError('audio is silent or cannot be measured')
    options = ':'.join(f'{dest}={values[src]}' for dest, src in (
        ('measured_I', 'input_i'), ('measured_TP', 'input_tp'), ('measured_LRA', 'input_lra'),
        ('measured_thresh', 'input_thresh'), ('offset', 'target_offset')))
    run([ffmpeg, '-hide_banner', '-nostdin', '-y', '-i', str(source), '-af', target + ':' + options + ':linear=true,aresample=48000',
         '-map_metadata', '-1', '-c:a', 'pcm_s24le', str(output)])
    return values


def probe(path):
    return json.loads(run([executable('ffprobe'), '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(Path(path))]).stdout)


def mix_narration(clips, duration, work, bed=None):
    """Place aligned narration in output time; optional pre-edited music/audio bed."""
    inputs, filters, labels = [], [], []
    tracks = [(bed, 0, duration)] if bed else []
    for clip in clips:
        if not clip.get('narration'):
            continue
        if clip['narrationStart'] is None:
            raise ValueError('narration requires word/event alignment')
        delay = clip['narrationStart'] - clip['sourceStart']
        narration_duration = float(probe(clip['narration'])['format']['duration'])
        if not math.isfinite(narration_duration) or delay < 0 or delay + narration_duration > clip['duration'] + 1e-6:
            raise ValueError(f"narration does not fit its beat: {delay:g}s delay + {narration_duration:g}s audio > {clip['duration']:g}s beat")
        tracks.append((clip['narration'], clip['outputStart'] + delay, clip['duration'] - delay))
    if not tracks:
        return None
    for index, (path, start, length) in enumerate(tracks):
        inputs += ['-i', str(path)]
        label = f'a{index}'
        filters.append(f'[{index}:a]atrim=duration={length},asetpts=PTS-STARTPTS,aresample=48000,aformat=channel_layouts=stereo,adelay={round(start * 1000)}:all=1,apad=whole_dur={duration}[{label}]')
        labels.append(f'[{label}]')
    filters.append(''.join(labels) + f'amix=inputs={len(labels)}:normalize=0,atrim=duration={duration}[mix]')
    raw = Path(work) / 'mix.wav'
    run([executable('ffmpeg'), '-v', 'error', '-nostdin', '-y', *inputs, '-filter_complex', ';'.join(filters), '-map', '[mix]', '-c:a', 'pcm_s24le', str(raw)])
    target = Path(work) / 'audio.wav'
    loudnorm(raw, target)
    return target
