#!/usr/bin/env python3
"""Exact, synthetic Eleven v4 take wire contract; never calls a provider."""
import base64
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/voice-lab/dialogue-cases.json'
VOICE = 'voice123'
BODY = {'inputs': [{'text': 'Hi', 'voice_id': VOICE}], 'model_id': 'eleven_v4',
        'language_code': 'en', 'settings': {'stability': 0.5, 'similarity': 0.8},
        'seed': 4294967295, 'apply_text_normalization': 'auto'}
WIRE = json.dumps(BODY, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
REPLY = {'audio_base64': base64.b64encode(bytes(960)).decode(),
         'alignment': {'characters': ['H', 'i'], 'character_start_times_seconds': [0, 0.01],
                       'character_end_times_seconds': [0.01, 0.02]},
         'normalized_alignment': None,
         'voice_segments': [{'voice_id': VOICE, 'start_time_seconds': 0, 'end_time_seconds': 0.02,
                             'character_start_index': 0, 'character_end_index': 2, 'dialogue_input_index': 0}]}
responses = []

def case(name, error=None, *, alignment='unchanged', segment=None, remove=None, empty=False):
    reply = copy.deepcopy(REPLY)
    if alignment != 'unchanged':
        reply['alignment'] = alignment
    if segment:
        reply['voice_segments'][0].update(segment)
    if empty:
        reply['voice_segments'] = []
    if remove:
        del reply[remove]
    responses.append({'case': name, 'response': reply, 'expected': error or 'success'})

case('valid')
case('alignment_null', 'invalidAlignment', alignment=None)
case('alignment_missing', 'invalidAlignment', remove='alignment')
case('alignment_malformed', 'invalidAlignment', alignment={'characters': ['H', 'i']})
case('alignment_wrong_text', 'invalidAlignment', alignment={**REPLY['alignment'], 'characters': ['N', 'o']})
case('segments_wrong_voice', 'malformedResponse', segment={'voice_id': 'other123'})
case('segments_wrong_input', 'malformedResponse', segment={'dialogue_input_index': 1})
case('segments_negative_start', 'malformedResponse', segment={'character_start_index': -1})
case('segments_past_text', 'malformedResponse', segment={'character_end_index': 3})
case('segments_reversed_text', 'malformedResponse', segment={'character_start_index': 2, 'character_end_index': 1})
case('segments_fractional_index', 'malformedResponse', segment={'character_end_index': 1.5})
case('segments_boolean_index', 'malformedResponse', segment={'dialogue_input_index': False})
case('segments_negative_time', 'malformedResponse', segment={'start_time_seconds': -0.001})
case('segments_past_audio', 'malformedResponse', segment={'end_time_seconds': 0.08})
case('segments_within_tolerance', segment={'end_time_seconds': 0.03})
case('alignment_null_and_wrong_voice', 'invalidAlignment', alignment=None, segment={'voice_id': 'other123'})
case('segments_reversed_time', 'malformedResponse', segment={'start_time_seconds': 0.02, 'end_time_seconds': 0.01})
case('segments_empty', 'malformedResponse', empty=True)
case('segments_missing', 'malformedResponse', remove='voice_segments')
# Normalized text never rescues missing original-text alignment.
responses[1]['response']['normalized_alignment'] = copy.deepcopy(REPLY['alignment'])
# Character indices count Unicode scalars, including an astral character as one.
scalar_reply = copy.deepcopy(REPLY)
scalar_reply['alignment']['characters'] = ['\U0001f399', 'i']
responses.append({'case': 'valid_astral_scalar', 'text': '\U0001f399i', 'response': scalar_reply, 'expected': 'success'})
# A required field missing from a later segment also refuses the entire reply.
missing = copy.deepcopy(REPLY)
missing['voice_segments'].append(copy.deepcopy(missing['voice_segments'][0]))
del missing['voice_segments'][1]['voice_id']
responses.append({'case': 'later_segment_missing_voice', 'response': missing, 'expected': 'malformedResponse'})

routes = []
for model, route in [('eleven_v4', 'textToDialogue'), ('eleven_v4_turbo', None),
                     ('eleven_v3', 'textToSpeech'), ('eleven_multilingual_v2', 'textToSpeech'),
                     ('future_speech_model', 'textToSpeech'), ('eleven_multilingual_sts_v2', 'textToSpeech')]:
    for can_speak in (True, False):
        routes.append({'modelId': model, 'can_do_text_to_speech': can_speak,
                       'route': route if can_speak else None})
document = {'schema': 'voxclip-voice-lab-dialogue-cases/1', 'version': 1,
            'discovery': {
                'models': [{'model_id': row['modelId'], 'name': row['modelId'],
                            'can_do_text_to_speech': row['can_do_text_to_speech'],
                            'languages': [{'language_id': 'en'}]} for row in routes if row['can_do_text_to_speech']],
                'voices': {'voices': [{'voice_id': VOICE, 'name': 'Fixture voice', 'category': 'premade'}], 'has_more': False}},
            'requests': [{'case': 'single_input_no_context', 'operation': 'textToSpeech',
                          'input': {'voiceId': VOICE, 'modelId': 'eleven_v4', 'language': 'en', 'text': 'Hi',
                                    'seed': 4294967295, 'previousText': 'Never sent before', 'nextText': 'Never sent after'},
                          'request': {'method': 'POST', 'path': '/v1/text-to-dialogue/with-timestamps',
                                      'query': {'output_format': 'pcm_24000'},
                                      'headers': {'xi-api-key': '[REDACTED]', 'content-type': 'application/json'},
                                      'json': BODY, 'bodyUTF8': WIRE, 'bodyLength': len(WIRE.encode()),
                                      'bodySha256': hashlib.sha256(WIRE.encode()).hexdigest()}}],
            'responseInput': {'voiceId': VOICE, 'modelId': 'eleven_v4', 'language': 'en', 'text': 'Hi', 'seed': 0},
            'responses': responses, 'routes': routes}
OUT.write_text(json.dumps(document, indent=2, ensure_ascii=True) + '\n')
print(f'{OUT.relative_to(ROOT)}: {len(responses)} responses, {len(routes)} routes')
