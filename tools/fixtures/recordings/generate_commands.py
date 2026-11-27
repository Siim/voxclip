#!/usr/bin/env python3
"""Derive recording shortcut vectors from the five-part plan oracle."""
import json

from generate import OUTPUT, write


def main():
    plans = json.loads((OUTPUT / 'plan-cases.json').read_text())
    plan = next(case for case in plans['cases'] if case['id'] == 'five-part-a1-b1-b2-a2-b3')
    project = json.loads((OUTPUT / plan['project']).read_text())
    primary = project['transcript']['words']
    companion = project['media']['spokenSources'][0]
    recording_b = project['media']['source']['contentKey']
    recording_a = companion['sourceKey']
    opening_a, notes_b, tracker_b, punchline_a, ending_b = plan['clip']['parts']

    def span(part):
        return [part['startWordId'], part['endWordId']]

    def before(word_id):
        return primary[next(index for index, word in enumerate(primary) if word['id'] == word_id) - 1]['id']

    def after(word_id):
        return primary[next(index for index, word in enumerate(primary) if word['id'] == word_id) + 1]['id']

    started = [[primary[0]['id'], notes_b['endWordId']], [tracker_b['startWordId'], ending_b['endWordId']]]
    left_out = [after(notes_b['endWordId']), before(tracker_b['startWordId'])]
    companion_ids = [companion['wordIdPrefix'] + word['id'] for word in companion['transcript']['words']]
    middle_a = companion_ids[companion_ids.index(opening_a['endWordId']) + 1:companion_ids.index(punchline_a['startWordId'])]
    write('command-cases.json', dict(
        schema='voxclip-recording-commands/1', project=plan['project'], recordingA=recording_a, recordingB=recording_b,
        started=started, swapped=[span(opening_a), span(notes_b), started[-1]], leftOut=left_out,
        putBack=[[started[0][0], started[-1][1]]], placement=tracker_b['endWordId'],
        middle=[[primary[0]['id'], left_out[1]], [middle_a[0], middle_a[-1]], span(ending_b)],
        final=dict(ranges=[span(part) for part in plan['clip']['parts']], parts=plan['parts'],
                   kept=plan['kept'], outputSamples=plan['outputSamples'], partSeams=plan['partSeams'],
                   recordingSeams=plan['recordingSeams'])))


if __name__ == '__main__':
    main()
