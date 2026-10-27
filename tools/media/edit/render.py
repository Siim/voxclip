"""Concat/overlay graph adapted from the author's A10 trailer tooling, animatic_v2.py.

Overlay frames are rendered offline, including loupes sampled from the actual edit.
Uses FFmpeg's built-in MPEG-4 encoder by default (no GPL codec dependency).
"""
import json
import math
import os
import stat
from pathlib import Path
import subprocess
import tempfile
from PIL import Image
from .art import contact_sheet
from .audio import executable, mix_narration, probe, run
from .model import events_by_step, number, resolve_beats, timeline_events
from .overlays import KINDS, render_overlay
from .subtitles import subtitles


def clip_filter(index, duration, width, height, fps=60, focus=.5, focusY=.5):
    """Crop to cover, including 9:16; reject a target that would upscale."""
    for name, value in [('focus', focus), ('focusY', focusY)]:
        number(value, name)
        if value > 1:
            raise ValueError(f'{name} must be <= 1')
    return (f'[{index}:v]scale=w=min(iw\\,{width}):h=min(ih\\,{height}):force_original_aspect_ratio=increase,'
            f'crop={width}:{height}:(iw-ow)*{focus}:(ih-oh)*{focusY},setsar=1,fps={fps},'
            f'trim=duration={duration:.9f},setpts=PTS-STARTPTS,format=rgba[v{index}]')


def render(spec, output, work, events=(), encoder='mpeg4'):
    width, height = spec.get('size', [1920, 1080])
    fps = spec.get('fps', 60)
    if any(type(v) is not int or v < 2 or v % 2 for v in (width, height)) or type(fps) is not int or not 1 <= fps <= 60:
        raise ValueError('size must be positive even integers; fps must be 1..60')
    events_by_step(events)
    clips = resolve_beats(spec['clips'], spec.get('words', []), events)
    if not clips:
        raise ValueError('edit needs clips')
    duration = sum(clip['duration'] for clip in clips)
    cursor_events = timeline_events(clips, events)
    # Every cut is frame-aligned, so concat cannot accumulate rounding drift.
    for clip in clips:
        if abs(clip['duration'] * fps - round(clip['duration'] * fps)) > .00001:
            raise ValueError('clip durations must align to output frames')
    overlays = spec.get('overlays', [])
    for overlay in overlays:
        if overlay['kind'] not in KINDS or not 0 <= number(overlay['start'], 'overlay start') < number(overlay['end'], 'overlay end') <= duration:
            raise ValueError('invalid overlay kind or interval')
        if 'zoom' in overlay:
            number(overlay['zoom'], 'zoom', .1)
    work, output = Path(work).resolve(), Path(output).resolve()
    if work.exists() and any(work.iterdir()):
        raise ValueError('work directory must be empty (one directory per render)')
    work.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg = executable('ffmpeg')
    inputs, filters = [], []
    for i, clip in enumerate(clips):
        source = Path(clip['source']).resolve()
        if not source.is_file():
            raise ValueError(f'missing source: {source}')
        info = probe(source)
        stream = next(stream for stream in info['streams'] if stream['codec_type'] == 'video')
        if width > stream['width'] or height > stream['height']:
            raise ValueError('output would upscale the source; use a smaller size')
        if float(info['format']['duration']) + 1 / fps < clip['sourceStart'] + clip['duration']:
            raise ValueError('source is shorter than requested beat')
        inputs += ['-ss', str(clip['sourceStart']), '-t', str(clip['duration']), '-i', str(source)]
        filters.append(clip_filter(i, clip['duration'], width, height, fps, clip.get('focus', .5), clip.get('focusY', .5)))
    filters.append(''.join(f'[v{i}]' for i in range(len(clips))) + f'concat=n={len(clips)}:v=1:a=0[base]')
    graph = ';'.join(filters)
    audio = mix_narration(clips, duration, work, spec.get('audio'))
    captions = {ext: subtitles(spec.get('cues', []), ext == 'vtt') for ext in ['srt', 'vtt']}
    frame_count = round(duration * fps)
    samples = []
    decode_log = work / 'decode.stderr.log'
    with decode_log.open('w+b') as stderr:
        decoder = subprocess.Popen([ffmpeg, '-v', 'error', '-nostdin', '-threads', '2', *inputs,
                                    '-filter_complex_threads', '1', '-filter_complex', graph, '-map', '[base]',
                                    '-frames:v', str(frame_count), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-threads', '1', '-'], stdout=subprocess.PIPE, stderr=stderr)
        def decode_error(message):
            stderr.flush()
            return RuntimeError(message + ':\n' + '\n'.join(decode_log.read_text().splitlines()[-20:]))
        try:
            for index in range(frame_count):
                raw = decoder.stdout.read(width * height * 3)
                if len(raw) != width * height * 3:
                    decoder.wait()
                    raise decode_error('FFmpeg ended before the requested edit duration')
                base = Image.frombytes('RGB', (width, height), raw)
                overlay = render_overlay(base, index / fps, overlays, cursor_events)
                overlay.save(work / f'overlay-{index:06}.png', compress_level=1)
                if index in {0, frame_count // 2, frame_count - 1}:
                    samples.append(Image.alpha_composite(base.convert('RGBA'), overlay).convert('RGB'))
            decoder.stdout.close()
            if decoder.wait() != 0:
                raise decode_error('FFmpeg source decode failed')
        finally:
            if decoder.poll() is None:
                decoder.kill()
                decoder.wait()
            decoder.stdout.close()
    overlay_index = len(clips)
    final_graph = graph + f';[base][{overlay_index}:v]overlay=0:0:shortest=1:format=auto,format=yuv420p[out]'
    args = [ffmpeg, '-v', 'error', '-nostdin', '-y', '-threads', '2', *inputs,
            '-framerate', str(fps), '-i', str(work / 'overlay-%06d.png')]
    audio_index = overlay_index + 1
    if audio:
        args += ['-i', str(audio)]
    args += ['-filter_complex_threads', '1', '-filter_complex', final_graph, '-map', '[out]']
    if audio:
        args += ['-map', f'{audio_index}:a', '-af', f'apad,atrim=duration={duration}', '-c:a', 'aac', '-b:a', '192k']
    else:
        args += ['-an']
    args += ['-c:v', encoder]
    args += ['-q:v', '2', '-flags', '+bitexact'] if encoder == 'mpeg4' else ['-b:v', '8M']
    args += ['-threads', '2', '-frames:v', str(frame_count), '-map_metadata', '-1', '-fflags', '+bitexact', '-movflags', '+faststart']
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.' + output.stem + '-', suffix=output.suffix, delete=False) as pending:
        pending_path = Path(pending.name)
    try:
        run(args + [str(pending_path)])
        if output.exists():
            mode = stat.S_IMODE(output.stat().st_mode)
        else:
            mask = os.umask(0)
            os.umask(mask)
            mode = 0o666 & ~mask
        pending_path.chmod(mode)
        pending_path.replace(output)
    finally:
        pending_path.unlink(missing_ok=True)
    (work / 'timeline.json').write_text(json.dumps(clips, indent=2) + '\n')
    contact_sheet(samples, ['First', 'Middle', 'Last']).save(output.with_suffix('.contact.png'), optimize=True)
    for extension in ['srt', 'vtt']:
        output.with_suffix('.' + extension).write_text(captions[extension], encoding='utf-8')
    return probe(output)
