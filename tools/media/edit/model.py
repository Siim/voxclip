"""Word/event alignment adapted from the author's A10 trailer tooling.

The beat model originates in A10 tools/tutorial/edit.py; UI events replace game logs.
All timestamps are seconds from capture start; targetFrame is a pixel rect [x,y,w,h].
"""
import math


def number(value, name, minimum=0):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < minimum:
        raise ValueError(f'{name} must be finite and >= {minimum}')
    return value


def events_by_step(events):
    result = {}
    previous = -1
    for event in events:
        step = event['step']
        if not isinstance(step, str) or not step or step in result:
            raise ValueError('event steps must be nonempty and unique')
        timestamp = number(event['timestamp'], 'event timestamp')
        if timestamp < previous:
            raise ValueError('events must be ordered by timestamp')
        frame = event['targetFrame']
        if len(frame) != 4:
            raise ValueError('targetFrame needs x,y,width,height')
        for value in frame:
            number(value, 'targetFrame coordinate')
        if min(frame[2:]) <= 0:
            raise ValueError('targetFrame width/height must be positive')
        result[step] = dict(event)
        previous = timestamp
    return result


def resolve_beats(beats, words, events):
    """Align word.start to event.timestamp - lead; reject a word outside its beat.

    Full narration duration is checked before mixing.
    """
    by_step = events_by_step(events)
    timeline, output_start = [], 0.0
    for beat in beats:
        duration = number(beat['duration'], 'duration', .001)
        source_start = number(beat.get('sourceStart', 0), 'sourceStart')
        narration_start = None
        if 'align' in beat:
            align = beat['align']
            word = words[align['word']]
            start = number(word['start'], 'word start')
            end = number(word['end'], 'word end')
            if end <= start:
                raise ValueError('word end must follow start')
            narration_start = by_step[align['step']]['timestamp'] - number(align.get('lead', 0), 'lead') - start
            if narration_start < source_start or narration_start + end > source_start + duration:
                raise ValueError('aligned narration falls outside its beat')
        timeline.append({**beat, 'outputStart': output_start, 'sourceStart': source_start, 'narrationStart': narration_start})
        output_start += duration
    return timeline


def timeline_events(clips, events):
    """Move captured events into the edited timeline, including repeated source ranges."""
    events_by_step(events)
    mapped = []
    for index, clip in enumerate(clips):
        start = clip['sourceStart']
        end = start + clip['duration']
        for event in events:
            if start <= event['timestamp'] < end:
                mapped.append({**event, 'step': f'{event["step"]}@{index}',
                               'timestamp': clip['outputStart'] + event['timestamp'] - start})
    return sorted(mapped, key=lambda event: event['timestamp'])
