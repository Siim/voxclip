import json
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

root = Path(__file__).resolve().parents[3]
cases = []
for name, model, pace in [
    ('tts_default', 'eleven_multilingual_v2', None),
    ('tts_explicit_default', 'eleven_multilingual_v2', 1.0),
    ('tts_slow', 'eleven_multilingual_v2', 0.8),
    ('tts_fast', 'eleven_multilingual_v2', 1.15),
    ('tts_round_half_up', 'eleven_multilingual_v2', 0.805),
    ('tts_round_to_default', 'eleven_multilingual_v2', 0.995),
    ('tts_minimum', 'eleven_multilingual_v2', 0.7),
    ('tts_maximum', 'eleven_multilingual_v2', 1.2),
    ('tts_below_range', 'eleven_multilingual_v2', 0.5),
    ('tts_before_rounding_low', 'eleven_multilingual_v2', 0.6999),
    ('tts_before_rounding_high', 'eleven_multilingual_v2', 1.2001),
    ('dialogue_default', 'eleven_v4', None),
    ('dialogue_explicit_default', 'eleven_v4', 1.0),
    ('dialogue_nondefault', 'eleven_v4', 0.8),
    ('dialogue_rounded_default_refused', 'eleven_v4', 0.999),
]:
    dialogue = model == 'eleven_v4'
    refused = pace is not None and (not 0.7 <= pace <= 1.2 or dialogue and pace != 1)
    row = {'case': name, 'modelId': model, 'pace': pace, 'expected': 'invalidInput' if refused else 'ok'}
    if not refused:
        payload = {'apply_text_normalization': 'auto', 'model_id': model, 'seed': 7}
        settings = {'stability': 0.5, 'similarity' if dialogue else 'similarity_boost': 0.8}
        if dialogue:
            payload.update(inputs=[{'text': 'Hi', 'voice_id': 'voice123'}], language_code='en', settings=settings)
        else:
            if pace is not None and pace != 1:
                settings['speed'] = float(Decimal(str(pace)).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP))
                if settings['speed'] == 1:
                    settings['speed'] = 1
            payload.update(text='Hi', voice_settings=settings)
        row['path'] = '/v1/text-to-dialogue/with-timestamps' if dialogue else '/v1/text-to-speech/voice123/with-timestamps'
        row['canonicalJSON'] = json.dumps(payload, sort_keys=True, separators=(',', ':'))
        row['exactBytes'] = dialogue or pace is not None and pace != 1
        row['receiptPace'] = settings.get('speed', 1)
    cases.append(row)
document = {'schema': 'voxclip-voice-lab-pace-cases/1', 'version': 1, 'caseCount': len(cases), 'cases': cases}
(root / 'shared/fixtures/voice-lab/pace-cases.json').write_text(json.dumps(document, indent=2) + '\n')
