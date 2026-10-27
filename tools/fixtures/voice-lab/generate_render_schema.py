"""Extend the shared project schema with explicit Voice Lab v3 recipe values."""
import copy
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
path = root / 'shared/schemas/project.schema.json'
s = json.loads(path.read_text())
s['title'] = 'VoxClip project file (.voxclip), schemaVersion 1, 2 or 3'
s['properties']['schemaVersion']['enum'] = [1, 2, 3]
s['properties']['voiceLab']['oneOf'] = [{'$ref': '#/$defs/voiceLabV1'}, {'$ref': '#/$defs/voiceLabV2'}, {'$ref': '#/$defs/voiceLabV3'}]
s['allOf'] = [item for item in s['allOf'] if item.get('if', {}).get('properties', {}).get('schemaVersion', {}).get('const') != 3]
s['allOf'].append({'if': {'properties': {'schemaVersion': {'const': 3}}}, 'then': {'properties': {'voiceLab': {'$ref': '#/$defs/voiceLabV3'}}}})
d = s['$defs']
string = {'type': 'string', 'minLength': 1}
idref = {'$ref': '#/$defs/id'}
num = {'type': 'number'}
integer = {'type': 'integer', 'minimum': 0}
nullable = lambda value: {'oneOf': [{'type': 'null'}, value]}
obj = lambda fields, required=None: {'type': 'object', 'additionalProperties': False, 'required': required or list(fields), 'properties': fields}
d['voiceLabCleanAudio'] = obj({'mode': {'enum': ['off', 'on']}, 'assetId': nullable(idref), 'mix': nullable({'type': 'number', 'minimum': 0, 'maximum': 1})})
d['voiceLabVoiceReference'] = obj({'id': idref, 'provider': string, 'voiceId': string, 'consentRecordId': idref, 'displayName': string, 'status': {'enum': ['active', 'deleted']}})
d['voiceLabRoomTone'] = obj({'sourceStartSample': integer, 'sourceEndSample': integer, 'gainDb': num})
d['voiceLabVideoAsset'] = obj({'id': idref, 'file': {'type': 'string', 'pattern': '^[0-9a-f-]{36}/[a-z0-9][a-z0-9_-]{0,63}\\.mp4$'},
                               'sha256': {'type': 'string', 'pattern': '^[0-9a-f]{64}$'}, 'durationSeconds': {'type': 'number', 'exclusiveMinimum': 0},
                               'frameRate': {'type': 'number', 'exclusiveMinimum': 0}, 'width': {'type': 'integer', 'minimum': 1}, 'height': {'type': 'integer', 'minimum': 1}})
d['voiceLabSeam'] = obj({'kind': {'enum': ['none', 'gap', 'hard', 'synthToSynth']}, 'fadeSamples': integer, 'sourceHandleSamples': integer, 'assetHandleFrames': integer})
d['voiceLabSeams'] = obj({'in': {'$ref': '#/$defs/voiceLabSeam'}, 'out': {'$ref': '#/$defs/voiceLabSeam'}})
d['voiceLabChunk'] = obj({'sourceStartSample': integer, 'sourceEndSample': integer, 'requestId': idref, 'seed': {'type': 'integer', 'minimum': 0, 'maximum': 4294967295}, 'assetId': idref, 'assetSha256': {'type': 'string', 'pattern': '^[0-9a-f]{64}$'}, 'assembledStartFrame': integer, 'assembledEndFrame': integer})
video_fields = {'mode': {'enum': ['source', 'retimed', 'zoomCover', 'lipsync']}, 'sourceStartSample': integer, 'sourceEndSample': integer, 'outputSamples': integer,
                'retimeFactor': num, 'zoom': num, 'faceX': {'type': 'number', 'minimum': 0, 'maximum': 1}, 'faceY': {'type': 'number', 'minimum': 0, 'maximum': 1},
                'assetId': idref, 'provider': string, 'model': string, 'requestId': idref, 'windowStartSample': integer, 'windowEndSample': integer, 'syncMode': {'enum': ['remap']}}
for key in set(video_fields) - {'mode', 'sourceStartSample', 'sourceEndSample', 'outputSamples'}:
    video_fields[key] = nullable(video_fields[key])
# Every key is written, with null for the fields a mode does not use, so both Cores read every saved recipe.
d['voiceLabVideoRecipe'] = obj(video_fields)
d['voiceLabVideoRecipe']['allOf'] = [
    {'if': {'properties': {'mode': {'const': 'retimed'}}}, 'then': {'required': ['retimeFactor']}},
    {'if': {'properties': {'mode': {'const': 'zoomCover'}}}, 'then': {'required': ['retimeFactor', 'zoom', 'faceX', 'faceY']}},
    {'if': {'properties': {'mode': {'const': 'lipsync'}}}, 'then': {'required': ['assetId', 'provider', 'model', 'requestId', 'windowStartSample', 'windowEndSample', 'syncMode']}}
]
d['voiceLabRenderQA'] = obj({'transcriptTokens': nullable(integer), 'transcriptExact': nullable({'type': 'boolean'}), 'transcriptMatch': nullable({'type': 'number', 'minimum': 0, 'maximum': 1}),
                              'lufsJumpLu': num, 'peakDbfs': num, 'speakerScore': nullable({'type': 'number', 'minimum': 0, 'maximum': 1}),
                              'speakerThreshold': nullable({'type': 'number', 'minimum': 0, 'maximum': 1}), 'speakerModel': nullable(string), 'speakerPassed': nullable({'type': 'boolean'})})
d['voiceLabCost'] = obj({'quoteId': idref, 'usd': nullable({'type': 'number', 'minimum': 0})})
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
segment['properties']['provenance'] = copy.deepcopy(d['voiceLabRenderRecipe']['properties']['provenance'])
segment['properties']['groupId'] = idref
segment['allOf'].append({'if': {'properties': {'scope': {'const': 'fullTake'}}}, 'then': {'required': ['groupId']}})
segment['properties']['candidates']['items']['properties']['recipe'] = {'$ref': '#/$defs/voiceLabRenderRecipe'}
segment['properties']['candidates']['items']['allOf'] = [{'if': {'properties': {'rejected': {'type': 'null'}}}, 'then': {'required': ['recipe']}}]
d['voiceLabSegmentV3'] = segment
d['voiceLabV3'] = obj({'assets': d['voiceLabV2']['properties']['assets'], 'segments': {'type': 'array', 'items': {'$ref': '#/$defs/voiceLabSegmentV3'}},
                           'cleanAudio': {'$ref': '#/$defs/voiceLabCleanAudio'}, 'voices': {'type': 'array', 'items': {'$ref': '#/$defs/voiceLabVoiceReference'}},
                           'videoAssets': {'type': 'array', 'items': {'$ref': '#/$defs/voiceLabVideoAsset'}}})
path.write_text(json.dumps(s, indent=2, ensure_ascii=False) + '\n')
