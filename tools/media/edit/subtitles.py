"""SRT/VTT writer adapted from the author's A10 trailer tooling (tutorial edit.py)."""
from html import escape
from .model import number


def timestamp(seconds, vtt=False):
    milliseconds = round(number(seconds, 'subtitle time') * 1000)
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    seconds, milliseconds = divmod(milliseconds, 1000)
    return f'{hours:02}:{minutes:02}:{seconds:02}{"." if vtt else ","}{milliseconds:03}'


def subtitles(cues, vtt=False):
    blocks = ['WEBVTT\n'] if vtt else []
    previous_end = 0
    for i, cue in enumerate(cues, 1):
        start, end = number(cue['start'], 'cue start'), number(cue['end'], 'cue end')
        if end <= start or start < previous_end or round(end * 1000) <= round(start * 1000):
            raise ValueError('subtitle cues must be ordered, nonoverlapping, and at least 1 ms')
        text = ' '.join(cue['text'].split())
        if not text:
            raise ValueError('subtitle text is empty')
        text = escape(text, quote=False) if vtt else text.replace('<', '').replace('>', '')
        blocks.append(f'{i}\n{timestamp(start, vtt)} --> {timestamp(end, vtt)}\n{text}\n')
        previous_end = end
    return '\n'.join(blocks)
