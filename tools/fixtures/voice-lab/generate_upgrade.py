#!/usr/bin/env python3
"""Build shared Voice Lab v3 upgrade and voice-reference cases (voice-lab.md §6, §10.1, §10.5).

Inputs come from existing fixtures, which this script reads but never changes. Expected
results come from the small independent model below, so the file needs no clock, no
randomness and no provider output. Both native Core suites replay every case.
"""
import copy
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / 'shared/fixtures'
OUT = FIXTURES / 'voice-lab/upgrade-cases.json'

ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:-]{0,63}')
PROVIDER_VOICE_ID = re.compile(r'[A-Za-z0-9_-]{1,128}')
# Swift whitespacesAndNewlines and .NET char.IsWhiteSpace: Zs, tab, LF-CR, NEL, LS and PS.
WHITESPACE = '\t\n\v\f\r \x85\xa0                　'


class Refused(Exception):
    """A transition refusal named by its shared error case."""


class Invalid:
    """A refusal from Core validation of a result that this model accepts, so the case declares its error."""

    def __init__(self, error):
        self.error = error


def load(path):
    return json.loads((FIXTURES / path).read_text(encoding='utf-8'))


def upgrade(project):
    if project['schemaVersion'] == 3:
        return project
    if project['voiceLab']['segments']:
        raise Refused('legacySegmentsNeedReview')
    result = copy.deepcopy(project)
    result['schemaVersion'] = 3
    result['voiceLab'] = {'assets': copy.deepcopy(project['voiceLab'].get('assets', [])), 'segments': [],
                          'cleanAudio': {'mode': 'off', 'assetId': None, 'mix': None}, 'voices': [], 'videoAssets': []}
    return result


def add_voice(project, reference):
    if project['schemaVersion'] != 3:
        raise Refused('requiresVersion3')
    voice = dict(reference, displayName=reference['displayName'].strip(WHITESPACE))
    voices = project['voiceLab']['voices']
    valid = (ID.fullmatch(voice['id']) and all(item['id'] != voice['id'] for item in voices)
             and ID.fullmatch(voice['consentRecordId']) and voice['provider'] == 'elevenlabs'
             and PROVIDER_VOICE_ID.fullmatch(voice['voiceId']) and voice['status'] == 'active'
             and 1 <= len(voice['displayName']) <= 60
             and not any(item['status'] == 'active' and item['provider'] == voice['provider']
                         and item['voiceId'] == voice['voiceId'] for item in voices))
    if not valid:
        raise Refused('invalidVoice')
    result = copy.deepcopy(project)
    result['voiceLab']['voices'].append(voice)
    return result


def mark_deleted(project, voice_id):
    if project['schemaVersion'] != 3:
        raise Refused('requiresVersion3')
    if not any(item['id'] == voice_id for item in project['voiceLab']['voices']):
        raise Refused('missingVoice')
    result = copy.deepcopy(project)
    for item in result['voiceLab']['voices']:
        if item['id'] == voice_id:
            item['status'] = 'deleted'
    return result


def accept(project, take):
    result = copy.deepcopy(upgrade(project))
    segment = take['segment']
    if not 0 <= segment['selectedCandidateIndex'] < len(segment['candidates']):
        raise Refused('invalidCandidate')
    added = [asset['id'] for asset in take['assets']]
    if len(set(added)) != len(added) or set(added) & {asset['id'] for asset in result['voiceLab']['assets']}:
        raise Refused('invalidAsset')
    if any(item['id'] == segment['id'] for item in result['voiceLab']['segments']):
        raise Refused('invalidSegment')
    # Every unrejected own-voice candidate, selected or not, needs an active consent reference.
    for candidate in segment['candidates']:
        recipe = candidate.get('recipe')
        if candidate['rejected'] is None and recipe and recipe['voiceSource'] == 'own':
            voice = next((item for item in result['voiceLab']['voices'] if item['id'] == recipe['voiceRefId']), None)
            if voice is None or voice['status'] != 'active':
                raise Refused('consentUnverified')
    result['voiceLab']['assets'] += copy.deepcopy(take['assets'])
    result['voiceLab']['segments'].append(copy.deepcopy(segment))
    return result


def replaced(project, version, voice_lab):
    result = copy.deepcopy(project)
    result['schemaVersion'] = version
    result['voiceLab'] = voice_lab
    return result


interview = load('projects/interview-take.voxclip')
legacy = load('voice-lab/passage-project.voxclip')
render = load('voice-lab/passage-render-v3.voxclip')
changer = load('voice-lab/voice-changer-half-render-v3.voxclip')
extended = copy.deepcopy(interview)
extended['extensions'] = {'org.example.fork': {'nested': [7, True, None], 'text': 'õäöü'}}
projects = {
    'interview-v1': interview,
    'interview-v1-extensions': extended,
    # The voice-lab source fixtures share every field except schemaVersion and voiceLab.
    'voice-lab-v1': replaced(render, 1, {'segments': []}),
    'voice-lab-v2-empty': replaced(legacy, 2, {'assets': [], 'segments': []}),
    'voice-lab-v2-one-asset': replaced(legacy, 2, {'assets': legacy['voiceLab']['assets'][:1], 'segments': []}),
    'voice-lab-v2-segment': legacy,
    'passage-render-v3': render,
}
takes = {
    'own-passage': {'segment': render['voiceLab']['segments'][0], 'assets': render['voiceLab']['assets']},
    'stock-changer': {'segment': changer['voiceLab']['segments'][0], 'assets': changer['voiceLab']['assets']},
    # The version 2 passage has no scope and no candidate recipes.
    'legacy-passage': {'segment': legacy['voiceLab']['segments'][0], 'assets': legacy['voiceLab']['assets']},
}
REJECTED = 'Rejected in review'


def changer_variant(index, change, rejected=None, base='stock-changer'):
    """A take with one candidate's recipe changed; in stock-changer, index 0 is selected and index 1 is the alternative."""
    take = copy.deepcopy(takes[base])
    candidate = take['segment']['candidates'][index]
    candidate['rejected'] = rejected
    change(candidate['recipe'])
    return take


# Each refusing take breaks one project.schema.json rule that render policy leaves unchecked.
takes.update({
    'changer-rejected-alternative': changer_variant(1, lambda recipe: None, REJECTED),
    'changer-rejected-empty-chunks': changer_variant(1, lambda recipe: recipe.update(chunks=[]), REJECTED),
    'changer-rejected-no-region': changer_variant(1, lambda recipe: recipe['provenance'].update(region=None), REJECTED),
    'changer-rejected-unsafe-quote': changer_variant(1, lambda recipe: recipe['cost'].update(quoteId='bad id'), REJECTED),
    'changer-rejected-negative-cost': changer_variant(1, lambda recipe: recipe['cost'].update(usd=-5), REJECTED),
    'changer-rejected-empty-model': changer_variant(1, lambda recipe: recipe['provenance'].update(model=''), REJECTED),
    'changer-alternative-provider-pattern': changer_variant(1, lambda recipe: recipe['provenance'].update(provider='Eleven Labs')),
    'changer-negative-transcript-tokens': changer_variant(0, lambda recipe: recipe['qa'].update(transcriptTokens=-1)),
    'changer-speaker-threshold-above-one': changer_variant(0, lambda recipe: recipe['qa'].update(speakerThreshold=1.5)),
    'changer-empty-speaker-model': changer_variant(0, lambda recipe: recipe['qa'].update(speakerModel='')),
})
# Selecting an alternative copies its provenance into the segment, whose rule refuses an endpoint URL.
takes['changer-alternative-endpoint-url'] = changer_variant(
    1, lambda recipe: recipe['provenance'].update(endpoint='https://api.elevenlabs.io/v1/speech-to-speech/fixture'))
# Two defects pin the check order. A peak at or above 0 dBFS fails render policy only; a speaker threshold above 1 or
# an empty speaker model fails the shape check only. The first take puts them on different candidates, the second on one.
takes['changer-two-candidate-defects'] = changer_variant(
    1, lambda recipe: recipe['qa'].update(peakDbfs=0.5), base='changer-speaker-threshold-above-one')
takes['changer-one-candidate-two-defects'] = changer_variant(1, lambda recipe: recipe['qa'].update(peakDbfs=0.5, speakerModel=''))


def own_voice(recipe):
    """Turns a stock recipe into an own-voice take of `voice-fixture`, verified a minute before generation."""
    recipe.update(voiceSource='own', voiceRefId='voice-fixture', consentVerifiedAt='2026-10-25T12:09:00Z')
    recipe['provenance'].update(consentRecordId='consent-fixture', voiceId='fixture-voice')


# Stock-selected segments whose alternative is an own-voice take, unrejected or rejected.
takes['changer-own-alternative'] = changer_variant(1, own_voice)
takes['changer-rejected-own-alternative'] = changer_variant(1, own_voice, REJECTED)


def voice(**changes):
    reference = {'id': 'voice-fixture', 'provider': 'elevenlabs', 'voiceId': 'fixture-voice',
                 'consentRecordId': 'consent-fixture', 'displayName': 'Fixture voice', 'status': 'active'}
    reference.update(changes)
    return reference


UPGRADE = {'op': 'upgradeToV3'}
ADD = {'op': 'addVoiceReference', 'voice': voice()}
DELETE = {'op': 'markVoiceDeleted', 'id': 'voice-fixture'}
OWN = {'op': 'accept', 'take': 'own-passage'}
STOCK = {'op': 'accept', 'take': 'stock-changer'}


def add(**changes):
    return {'op': 'addVoiceReference', 'voice': voice(**changes)}


# Two references share one ID. No transition writes this, so only loading the project can meet it.
projects['voice-lab-v3-duplicate-voice-ids'] = replaced(render, 3, {
    'assets': [], 'segments': [], 'cleanAudio': {'mode': 'off', 'assetId': None, 'mix': None},
    'voices': [voice(), voice(voiceId='other-voice')], 'videoAssets': []})


def accepting(take):
    return {'op': 'accept', 'take': take}


def video(mode, **values):
    recipe = {'mode': mode, 'sourceStartSample': 48000, 'sourceEndSample': 96000, 'outputSamples': 48000,
              'retimeFactor': None, 'zoom': None, 'faceX': None, 'faceY': None, 'assetId': None, 'provider': None,
              'model': None, 'requestId': None, 'windowStartSample': None, 'windowEndSample': None, 'syncMode': None}
    recipe.update(values)
    return recipe


# One render-recipe video object per mode, with every key and null for the fields the mode does not use.
VIDEO_RECIPES = {
    'source': video('source'),
    'retimed': video('retimed', outputSamples=40000, retimeFactor=1.2),
    'zoomCover': video('zoomCover', outputSamples=40000, retimeFactor=1.2, zoom=1.5, faceX=0.25, faceY=0.75),
    'lipsync': video('lipsync', assetId='lipsync-take', provider='sync', model='lipsync-2', requestId='lipsync-request-1',
                     windowStartSample=24000, windowEndSample=120000, syncMode='remap'),
}


# (id, input project, steps, expected): a project name, None for a refusal this model makes, or Invalid(error)
CASES = [
    ('upgrade-v1-empty', 'interview-v1', [UPGRADE], 'interview-v3'),
    ('upgrade-v1-extensions', 'interview-v1-extensions', [UPGRADE], 'interview-v3-extensions'),
    ('upgrade-v2-one-asset', 'voice-lab-v2-one-asset', [UPGRADE], 'voice-lab-v3-one-asset'),
    ('upgrade-v2-segment', 'voice-lab-v2-segment', [UPGRADE], None),
    ('upgrade-v3-identity', 'passage-render-v3', [UPGRADE], 'passage-render-v3'),
    ('upgrade-voice-lab-v1', 'voice-lab-v1', [UPGRADE], 'voice-lab-v3-empty'),
    ('add-voice', 'voice-lab-v3-empty', [ADD], 'voice-lab-v3-active-voice'),
    ('add-voice-trims-display-name', 'voice-lab-v3-empty', [add(displayName=' \tFixture voice\n')], 'voice-lab-v3-active-voice'),
    ('add-voice-to-v1', 'voice-lab-v1', [ADD], None),
    ('add-voice-to-v2', 'voice-lab-v2-empty', [ADD], None),
    ('add-duplicate-active-voice', 'voice-lab-v3-active-voice', [add(id='voice-other')], None),
    ('add-duplicate-reference-id', 'voice-lab-v3-active-voice', [add(voiceId='other-voice')], None),
    ('add-display-name-0-scalars', 'voice-lab-v3-empty', [add(displayName='')], None),
    ('add-display-name-only-whitespace', 'voice-lab-v3-empty', [add(displayName=' \t\n')], None),
    ('add-display-name-61-scalars', 'voice-lab-v3-empty', [add(displayName='a' * 61)], None),
    ('add-display-name-61-decomposed-scalars', 'voice-lab-v3-empty', [add(displayName='õ' * 30 + 'a')], None),
    ('add-display-name-60-estonian-scalars', 'voice-lab-v3-empty', [add(displayName='õäöü' * 15)], 'voice-lab-v3-estonian-voice'),
    ('add-invalid-reference-id', 'voice-lab-v3-empty', [add(id='../voice')], None),
    ('add-empty-consent-record', 'voice-lab-v3-empty', [add(consentRecordId='')], None),
    ('add-other-provider', 'voice-lab-v3-empty', [add(provider='stock')], None),
    ('add-unsafe-provider-voice-id', 'voice-lab-v3-empty', [add(voiceId='../voices')], None),
    ('add-deleted-reference', 'voice-lab-v3-empty', [add(status='deleted')], None),
    ('delete-voice-without-takes', 'voice-lab-v3-active-voice', [DELETE], 'voice-lab-v3-deleted-voice'),
    ('add-same-provider-voice-after-delete', 'voice-lab-v3-deleted-voice',
     [add(id='voice-new', consentRecordId='consent-new', displayName='New voice')], 'voice-lab-v3-readded-voice'),
    ('own-voice-accept-while-active', 'voice-lab-v3-active-voice', [OWN], 'passage-render-v3-active'),
    ('delete-voice-keeps-accepted-take', 'passage-render-v3-active', [DELETE], 'passage-render-v3'),
    ('delete-voice-twice', 'passage-render-v3-active', [DELETE, DELETE], 'passage-render-v3'),
    ('delete-missing-voice', 'passage-render-v3', [{'op': 'markVoiceDeleted', 'id': 'voice-missing'}], None),
    ('delete-voice-in-v2', 'voice-lab-v2-segment', [DELETE], None),
    ('own-voice-accept-after-delete', 'voice-lab-v3-active-voice', [DELETE, OWN], None),
    ('own-voice-accept-into-v1', 'voice-lab-v1', [OWN], None),
    # Consent covers every unrejected own-voice candidate, not only the selected one.
    ('accept-own-alternative-while-active', 'voice-lab-v3-active-voice', [accepting('changer-own-alternative')], 'voice-lab-v3-own-alternative'),
    ('accept-own-alternative-after-delete', 'voice-lab-v3-deleted-voice', [accepting('changer-own-alternative')], None),
    ('accept-rejected-own-alternative-after-delete', 'voice-lab-v3-deleted-voice', [accepting('changer-rejected-own-alternative')],
     'voice-lab-v3-rejected-own-alternative'),
    ('accept-into-v1', 'voice-lab-v1', [STOCK], 'voice-lab-v3-stock-changer'),
    ('accept-into-segment-free-v2', 'voice-lab-v2-empty', [STOCK], 'voice-lab-v3-stock-changer'),
    ('accept-into-v2-with-segment', 'voice-lab-v2-segment', [STOCK], None),
    # A version 3 segment must record its scope and recipes (§10.5).
    ('accept-recipe-less-take-into-v1', 'voice-lab-v1', [accepting('legacy-passage')], Invalid('missingRenderPolicy')),
    # Every stored recipe, rejected or not, must match the schema; a rejected alternative with a valid recipe is kept.
    ('accept-rejected-alternative', 'voice-lab-v1', [accepting('changer-rejected-alternative')], 'voice-lab-v3-rejected-alternative'),
    ('accept-rejected-recipe-empty-chunks', 'voice-lab-v1', [accepting('changer-rejected-empty-chunks')], Invalid('invalidSegment')),
    ('accept-rejected-recipe-no-region', 'voice-lab-v1', [accepting('changer-rejected-no-region')], Invalid('invalidSegment')),
    ('accept-rejected-recipe-unsafe-quote', 'voice-lab-v1', [accepting('changer-rejected-unsafe-quote')], Invalid('invalidSegment')),
    ('accept-rejected-recipe-negative-cost', 'voice-lab-v1', [accepting('changer-rejected-negative-cost')], Invalid('invalidSegment')),
    ('accept-rejected-recipe-empty-model', 'voice-lab-v1', [accepting('changer-rejected-empty-model')], Invalid('invalidSegment')),
    ('accept-alternative-provider-pattern', 'voice-lab-v1', [accepting('changer-alternative-provider-pattern')], Invalid('invalidSegment')),
    ('accept-negative-transcript-tokens', 'voice-lab-v1', [accepting('changer-negative-transcript-tokens')], Invalid('invalidSegment')),
    ('accept-speaker-threshold-above-one', 'voice-lab-v1', [accepting('changer-speaker-threshold-above-one')], Invalid('invalidSegment')),
    ('accept-empty-speaker-model', 'voice-lab-v1', [accepting('changer-empty-speaker-model')], Invalid('invalidSegment')),
    # Render policy refuses an unrejected alternative that the segment endpoint rule would refuse once selected.
    ('accept-alternative-endpoint-url', 'voice-lab-v1', [accepting('changer-alternative-endpoint-url')], Invalid('invalidSegment')),
    # For each candidate in order, render policy runs on an unrejected candidate before the shape check; the first failure wins.
    ('accept-two-defects-earlier-candidate-first', 'voice-lab-v1', [accepting('changer-two-candidate-defects')], Invalid('invalidSegment')),
    ('accept-two-defects-policy-before-shape', 'voice-lab-v1', [accepting('changer-one-candidate-two-defects')], Invalid('qaRejected')),
    ('upgrade-add-accept-delete', 'voice-lab-v1', [UPGRADE, ADD, OWN, DELETE], 'passage-render-v3'),
    # Without steps, a case pins the refusal of loading its input.
    ('load-duplicate-voice-reference-ids', 'voice-lab-v3-duplicate-voice-ids', [], Invalid('consentUnverified')),
]

cases = []
for case_id, source, steps, expected in CASES:
    value = projects[source]
    record = {'id': case_id, 'input': source, 'steps': steps}
    index = 0
    try:
        for index, step in enumerate(steps):
            if step['op'] == 'upgradeToV3':
                value = upgrade(value)
            elif step['op'] == 'addVoiceReference':
                value = add_voice(value, step['voice'])
            elif step['op'] == 'markVoiceDeleted':
                value = mark_deleted(value, step['id'])
            else:
                value = accept(value, takes[step['take']])
    except Refused as refusal:
        if expected is not None or index != len(steps) - 1:
            raise SystemExit(f'{case_id}: unexpected {refusal}')
        record['error'] = str(refusal)
    else:
        if expected is None:
            raise SystemExit(f'{case_id}: expected a refusal')
        if isinstance(expected, Invalid):
            record['error'] = expected.error
        else:
            if expected in projects and projects[expected] != value:
                raise SystemExit(f'{case_id}: result differs from {expected}')
            projects[expected] = value
            record['expected'] = expected
    cases.append(record)

document = {'schema': 'voxclip-voice-lab-upgrade-cases/1', 'projects': projects, 'takes': takes, 'cases': cases,
            'videoRecipes': VIDEO_RECIPES}
OUT.write_text(json.dumps(document, indent=2, ensure_ascii=False, sort_keys=True) + '\n', encoding='utf-8')
