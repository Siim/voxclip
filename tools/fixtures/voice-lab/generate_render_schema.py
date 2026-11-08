"""Extend the shared project schema with explicit Voice Lab v3 recipe values."""
import copy
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
path = root / 'shared/schemas/project.schema.json'
s = json.loads(path.read_text())
# Later project versions retain the v3 Voice Lab contract and own additional root fields.
# Refresh only this generator's definitions; never downgrade their schema or reorder its rules.
versions = sorted(set(s['properties']['schemaVersion']['enum']) | {1, 2, 3})
version_title = ', '.join(map(str, versions[:-1])) + ' or ' + str(versions[-1])
s['title'] = 'VoxClip project file (.voxclip), schemaVersion ' + version_title
s['properties']['schemaVersion']['enum'] = versions
s['properties']['voiceLab']['oneOf'] = [{'$ref': '#/$defs/voiceLabV1'}, {'$ref': '#/$defs/voiceLabV2'}, {'$ref': '#/$defs/voiceLabV3'}]
voice_versions = [version for version in versions if version >= 3]
version_condition = {'const': 3} if voice_versions == [3] else {'enum': voice_versions}
voice_rule = {'if': {'properties': {'schemaVersion': version_condition}}, 'then': {'properties': {'voiceLab': {'$ref': '#/$defs/voiceLabV3'}}}}
for index, item in enumerate(s['allOf']):
    if item.get('then', {}).get('properties', {}).get('voiceLab', {}).get('$ref') == '#/$defs/voiceLabV3':
        s['allOf'][index] = voice_rule
        break
else:
    s['allOf'].append(voice_rule)
d = s['$defs']
string = {'type': 'string', 'minLength': 1}
idref = {'$ref': '#/$defs/id'}
num = {'type': 'number'}
integer = {'type': 'integer', 'minimum': 0}
nullable = lambda value: {'oneOf': [{'type': 'null'}, value]}
obj = lambda fields, required=None: {'type': 'object', 'additionalProperties': False, 'required': required or list(fields), 'properties': fields}
d['voiceLabCleanAudio'] = obj({'mode': {'enum': ['off', 'on']}, 'assetId': nullable(idref), 'mix': nullable({'type': 'number', 'minimum': 0, 'maximum': 1})})
d['voiceLabVoiceReference'] = obj({'id': idref, 'provider': string, 'voiceId': string, 'consentRecordId': idref, 'displayName': string, 'status': {'enum': ['active', 'deleted']}})
# endGainDb (optional, Mac since 2026-11-03): the loop's gain at the window's end, ramped linearly in dB from gainDb.
d['voiceLabRoomTone'] = obj({'sourceStartSample': integer, 'sourceEndSample': integer, 'gainDb': num, 'endGainDb': num},
                            required=['sourceStartSample', 'sourceEndSample', 'gainDb'])
d['voiceLabVideoAsset'] = obj({'id': idref, 'file': {'type': 'string', 'pattern': '^[0-9a-f-]{36}/[a-z0-9][a-z0-9_-]{0,63}\\.mp4$'},
                               'sha256': {'type': 'string', 'pattern': '^[0-9a-f]{64}$'}, 'durationSeconds': {'type': 'number', 'exclusiveMinimum': 0},
                               'frameRate': {'type': 'number', 'exclusiveMinimum': 0}, 'width': {'type': 'integer', 'minimum': 1}, 'height': {'type': 'integer', 'minimum': 1}})
d['voiceLabSeam'] = obj({'kind': {'enum': ['none', 'gap', 'hard', 'synthToSynth']}, 'fadeSamples': integer, 'sourceHandleSamples': integer, 'assetHandleFrames': integer})
d['voiceLabSeams'] = obj({'in': {'$ref': '#/$defs/voiceLabSeam'}, 'out': {'$ref': '#/$defs/voiceLabSeam'}})
d['voiceLabChunk'] = obj({'sourceStartSample': integer, 'sourceEndSample': integer, 'requestId': idref, 'seed': {'type': 'integer', 'minimum': 0, 'maximum': 4294967295}, 'assetId': idref, 'assetSha256': {'type': 'string', 'pattern': '^[0-9a-f]{64}$'}, 'assembledStartFrame': integer, 'assembledEndFrame': integer})
video_fields = {'mode': {'enum': ['source', 'cut', 'retimed', 'zoomCover', 'lipsync']}, 'sourceStartSample': integer, 'sourceEndSample': integer, 'outputSamples': integer,
                'retimeFactor': num, 'zoom': num, 'faceX': {'type': 'number', 'minimum': 0, 'maximum': 1}, 'faceY': {'type': 'number', 'minimum': 0, 'maximum': 1},
                'assetId': idref, 'provider': string, 'model': string, 'requestId': idref, 'windowStartSample': integer, 'windowEndSample': integer, 'syncMode': {'enum': ['remap', 'cut_off']}}
for key in set(video_fields) - {'mode', 'sourceStartSample', 'sourceEndSample', 'outputSamples'}:
    video_fields[key] = nullable(video_fields[key])
# Every key is written, with null for the fields a mode does not use, so both Cores read every saved recipe.
d['voiceLabVideoRecipe'] = obj(video_fields)
# A pause's jump cut holds one or two cuts; a whole-clip revoice's picture holds the clip's own cuts (ADR-R46), up to
# VoiceLabNaturalPacing.MAXIMUM_EDITED_CUTS. Both Cores check the count per form (validCuts).
d['voiceLabVideoRecipe']['properties']['cuts'] = {
    'type': 'array', 'minItems': 1, 'maxItems': 512,
    'items': obj({'startSample': integer, 'endSample': {'type': 'integer', 'minimum': 1}})}
d['voiceLabVideoRecipe']['allOf'] = [
    {'if': {'properties': {'mode': {'const': 'cut'}}}, 'then': {'required': ['cuts', 'zoom', 'faceX', 'faceY']}},
    {'if': {'properties': {'mode': {'const': 'retimed'}}}, 'then': {'required': ['retimeFactor']}},
    {'if': {'properties': {'mode': {'const': 'zoomCover'}}}, 'then': {'required': ['retimeFactor', 'zoom', 'faceX', 'faceY']}},
    {'if': {'properties': {'mode': {'const': 'lipsync'}}}, 'then': {'required': ['assetId', 'provider', 'model', 'requestId', 'windowStartSample', 'windowEndSample', 'syncMode']}}
]
d['voiceLabJoinAdvisory'] = obj({'seams': {'type': 'array', 'minItems': 1, 'maxItems': 2,
                                        'items': obj({'side': {'enum': ['left', 'right']}, 'excessLu': {'type': 'number', 'exclusiveMinimum': 2}})},
                                'acceptedAt': {'$ref': '#/$defs/timestamp'}})
d['voiceLabRenderQA'] = obj({'transcriptTokens': nullable(integer), 'transcriptExact': nullable({'type': 'boolean'}), 'transcriptMatch': nullable({'type': 'number', 'minimum': 0, 'maximum': 1}),
                              'lufsJumpLu': num, 'peakDbfs': num, 'speakerScore': nullable({'type': 'number', 'minimum': 0, 'maximum': 1}),
                              'speakerThreshold': nullable({'type': 'number', 'minimum': 0, 'maximum': 1}), 'speakerModel': nullable(string), 'speakerPassed': nullable({'type': 'boolean'}),
                              'joinAdvisory': {'$ref': '#/$defs/voiceLabJoinAdvisory'},
                              'shortSpeech': obj({'mode': {'enum': ['pooled', 'unmeasured']}, 'recordId': string,
                                                  'consentMethod': {'enum': ['recordedStatement', 'projectAttestation']},
                                                  'voicedFrames': integer, 'takeCount': {'type': 'integer', 'minimum': 1}})},
                             required=['transcriptTokens', 'transcriptExact', 'transcriptMatch', 'lufsJumpLu', 'peakDbfs',
                                       'speakerScore', 'speakerThreshold', 'speakerModel', 'speakerPassed'])
d['voiceLabRenderQA']['properties']['shortSpeech']['allOf'] = [
    {'if': {'properties': {'mode': {'const': 'pooled'}}},
     'then': {'properties': {'voicedFrames': {'minimum': 48000}, 'takeCount': {'minimum': 2}}},
     'else': {'properties': {'voicedFrames': {'maximum': 47999}}}}
]
d['voiceLabCost'] = obj({'quoteId': idref, 'usd': nullable({'type': 'number', 'minimum': 0})})
d['voiceLabSegment']['properties']['provenance']['properties']['pace'] = {'type': 'number', 'minimum': 0.7, 'maximum': 1.2}
d['voiceLabRenderRecipe'] = obj({'audio': d['voiceLabSegment']['properties']['audio'], 'words': d['voiceLabSegment']['properties']['words'], 'outDuration': {'type': 'number', 'exclusiveMinimum': 0}, 'seed': {'type': 'integer', 'minimum': 0, 'maximum': 4294967295},
                                 'chunks': {'type': 'array', 'minItems': 1, 'items': {'$ref': '#/$defs/voiceLabChunk'}}, 'roomTone': nullable({'$ref': '#/$defs/voiceLabRoomTone'}),
                                 'seams': {'$ref': '#/$defs/voiceLabSeams'}, 'video': {'$ref': '#/$defs/voiceLabVideoRecipe'}, 'qa': {'$ref': '#/$defs/voiceLabRenderQA'},
                                 'provenance': d['voiceLabSegment']['properties']['provenance'], 'cost': {'$ref': '#/$defs/voiceLabCost'}, 'voiceSource': {'enum': ['own', 'stock']},
                                 'voiceRefId': nullable(idref), 'consentVerifiedAt': nullable({'$ref': '#/$defs/timestamp'})})
d['voiceLabRenderRecipe']['properties']['provenance'] = copy.deepcopy(d['voiceLabRenderRecipe']['properties']['provenance'])
d['voiceLabRenderRecipe']['properties']['provenance']['required'].append('region')
d['voiceLabRenderRecipe']['properties']['provenance']['properties']['region'] = string
segment = copy.deepcopy(d['voiceLabSegment'])
segment['required'].append('scope')
segment['properties']['scope'] = {'enum': ['passage', 'fullTake']}
# The user's own microphone take of a Rewrite phrase (voice-lab.md §8.13): text and words as a tts segment has.
segment['properties']['kind'] = {'enum': ['tts', 'voiceChanger', 'recorded']}
tts_rule = next(rule for rule in segment['allOf'] if rule['if']['properties'].get('kind') == {'const': 'tts'})
segment['allOf'].insert(segment['allOf'].index(tts_rule) + 1, {'if': {'properties': {'kind': {'const': 'recorded'}}}, 'then': copy.deepcopy(tts_rule['then'])})
segment['properties']['provenance'] = copy.deepcopy(d['voiceLabRenderRecipe']['properties']['provenance'])
segment['properties']['groupId'] = idref
segment['allOf'].append({'if': {'properties': {'scope': {'const': 'fullTake'}}}, 'then': {'required': ['groupId']}})
segment['properties']['candidates']['items']['properties']['recipe'] = {'$ref': '#/$defs/voiceLabRenderRecipe'}
segment['properties']['candidates']['items']['allOf'] = [{'if': {'properties': {'rejected': {'type': 'null'}}}, 'then': {'required': ['recipe']}}]
d['voiceLabSegmentV3'] = segment
d['voiceLabV3'] = obj({'assets': d['voiceLabV2']['properties']['assets'], 'segments': {'type': 'array', 'items': {'$ref': '#/$defs/voiceLabSegmentV3'}},
                           'cleanAudio': {'$ref': '#/$defs/voiceLabCleanAudio'}, 'voices': {'type': 'array', 'items': {'$ref': '#/$defs/voiceLabVoiceReference'}},
                           'videoAssets': {'type': 'array', 'items': {'$ref': '#/$defs/voiceLabVideoAsset'}}})
d['voiceLabSpeakingRateSamples'] = {
    'type': 'object', 'additionalProperties': {
        'type': 'array', 'maxItems': 10, 'items': obj({
            'id': {'type': 'string', 'minLength': 1},
            'ratio': {'type': 'number', 'exclusiveMinimum': 0}})}}
for version in ('voiceLabV1', 'voiceLabV2', 'voiceLabV3'):
    d[version]['properties']['speakingRateSamples'] = {'$ref': '#/$defs/voiceLabSpeakingRateSamples'}
# A whole-clip revoice (ADR-R46): one voice over a clip's segments, its picture retimed within 8% and lip synced.
d['voiceLabWholeClipRevoice'] = obj({
    'id': {'type': 'string', 'pattern': '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'},
    'clipId': {'type': 'string', 'pattern': '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'},
    'segmentIds': {'type': 'array', 'minItems': 1, 'uniqueItems': True, 'items': {'type': 'string', 'minLength': 1}},
    'script': {'type': 'string', 'minLength': 1, 'maxLength': 20000},
    'consentRecordId': {'type': 'string', 'minLength': 1},
    'videoRetime': {'type': 'number', 'minimum': 0.92, 'maximum': 1.08},
    'lipsyncModel': {'enum': ['fal-ai/sync-lipsync/v2:lipsync-2', 'fal-ai/sync-lipsync/v3']},
    'usd': {'type': ['number', 'null'], 'minimum': 0},
    'match': {'oneOf': [{'type': 'null'}, obj({'take': {'type': 'number', 'minimum': -1, 'maximum': 1},
                                                 'anchorBaseline': {'type': ['number', 'null'], 'minimum': -1, 'maximum': 1},
                                                 'realSpeech': {'type': ['number', 'null'], 'minimum': -1, 'maximum': 1}})]},
    'createdAt': {'type': 'string', 'format': 'date-time'}})
d['voiceLabV3']['properties']['wholeClipRevoices'] = {'type': 'array', 'minItems': 1, 'items': {'$ref': '#/$defs/voiceLabWholeClipRevoice'}}
d['voiceLabMicroPause'] = obj({'wordStartSeconds': {'type': 'number', 'minimum': -290, 'maximum': 290},
                              'wordEndSeconds': {'type': 'number', 'minimum': -290, 'maximum': 290}})
d['voiceLabEdgeGainWord'] = obj({'gainDb': {'type': 'number', 'minimum': 0, 'maximum': 6},
                               'wordSeconds': {'$ref': '#/$defs/voiceLabMicroPause'}})
d['voiceLabEdgeGain'] = obj({'in': {'$ref': '#/$defs/voiceLabEdgeGainWord'}, 'out': {'$ref': '#/$defs/voiceLabEdgeGainWord'}}, required=[])
del d['voiceLabEdgeGain']['required']
d['voiceLabEdgeGain']['minProperties'] = 1
d['voiceLabSeam']['properties']['microPause'] = {'$ref': '#/$defs/voiceLabMicroPause'}
d['voiceLabSeam']['allOf'] = [{'if': {'required': ['microPause']}, 'then': {'properties': {'kind': {'const': 'hard'}}}}]
d['voiceLabRenderRecipe']['properties']['edgeGain'] = {'$ref': '#/$defs/voiceLabEdgeGain'}
path.write_text(json.dumps(s, indent=2, ensure_ascii=False) + '\n')
