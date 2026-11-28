#!/usr/bin/env python3
"""Generate shared/fixtures/looks/look-cases.json (format voxclip-look-cases/1): the look rules both Cores replay (looks spec
2026-11-28, sections 8.3 and 9.6), from shared/looks/clip-looks.json.

- `match`: a clip's colour state against the library. A look is applied when the clip's look, colorAdjustments and
  colorGrade equal its base, adjustments and grade, leaving out the amount, the preset and the Fix; a known `preset` with
  other values is that look edited; an unknown preset, or values no look has, is Custom.
- `setLookPreset`: `ClipControlsProject.settingLookPreset` on the clip-controls fixture project, after storing `before`
  (when given) with `ClipControlsProject.setting`; `after` is the clip's stored entry (null when none). The look's values are
  expanded with `preset` (none for As filmed, which has no look to blend) and `amount` clamped to 0-100 (100 for As
  filmed); the Fix stays unless the case gives one; the clip's other controls stay; a neutral grade is not stored.

Swift ClipLookRuleTests and C# ClipLookRuleTests replay it. Deterministic; run from anywhere.
"""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DESTINATION = ROOT / 'shared/fixtures/looks/look-cases.json'
SLIDERS = ['exposure', 'temperature', 'tint', 'highlights', 'shadows', 'vibrance', 'fade', 'vignette', 'grain']
FIX = ['exposure', 'temperature', 'tint']
ADJUSTMENTS = ['brightness', 'contrast', 'saturation', 'warmth']
DEFAULTS = {'clipId': 'clip-main', 'speed': 1, 'shape': None, 'look': 'original', 'gainDb': 0, 'fadeInSeconds': 0,
            'fadeOutSeconds': 0, 'muteSource': False, 'flipHorizontal': False, 'rotationDegrees': 0}


def library():
    return {look['id']: look for look in json.loads((ROOT / 'shared/looks/clip-looks.json').read_text())['looks']}


def grade(**values):
    """A colorGrade as the Cores write it: preset and amount (never 100) when present, all nine sliders, then the toning."""
    result = {key: values.pop(key) for key in ('preset', 'amount') if key in values and values[key] is not None}
    if result.get('amount') == 100:
        del result['amount']
    result.update({name: values.pop(name, 0) for name in SLIDERS})
    result.update({key: values.pop(key) for key in ('curve', 'splitTone') if values.get(key) is not None})
    for key in ('preset', 'amount', 'curve', 'splitTone'):
        values.pop(key, None)
    assert not values, values
    return result


def neutral(value):
    return all(value[name] == 0 for name in SLIDERS) and 'amount' not in value and 'curve' not in value and 'splitTone' not in value


def entry(**fields):
    result = {**DEFAULTS, **{key: value for key, value in fields.items() if key not in ('colorAdjustments', 'colorGrade')}}
    adjustments = fields.get('colorAdjustments')
    if adjustments and any(adjustments.get(name, 0) for name in ADJUSTMENTS):
        result['colorAdjustments'] = {name: adjustments.get(name, 0) for name in ADJUSTMENTS}
    if fields.get('colorGrade') is not None and not neutral(fields['colorGrade']):
        result['colorGrade'] = fields['colorGrade']
    return result


def is_default(controls):
    return controls == DEFAULTS


def look_values(controls):
    """The colour state a tile compares: look, adjustments and the grade without preset, amount and Fix."""
    value = controls.get('colorGrade')
    values = {name: 0 for name in SLIDERS if name not in FIX}
    toning = {}
    if value:
        values.update({name: value[name] for name in SLIDERS if name not in FIX})
        toning = {key: value[key] for key in ('curve', 'splitTone') if key in value}
    return controls['look'], {name: controls.get('colorAdjustments', {}).get(name, 0) for name in ADJUSTMENTS}, values, toning


def preset_values(look):
    values = {name: look['grade'].get(name, 0) for name in SLIDERS if name not in FIX}
    toning = {key: look['grade'][key] for key in ('curve', 'splitTone') if key in look['grade']}
    return look['base'], {name: look['adjustments'].get(name, 0) for name in ADJUSTMENTS}, values, toning


def match(looks, controls):
    named = (controls.get('colorGrade') or {}).get('preset')
    state = look_values(controls)
    if named is not None:
        if named not in looks:
            return None, None, 'Custom'
        look = looks[named]
        applied = preset_values(look) == state
        return named, 'applied' if applied else 'edited', look['label'] if applied else look['label'] + ', edited'
    for look in looks.values():
        if preset_values(look) == state:
            return look['id'], 'applied', look['label']
    return None, None, 'Custom'


def apply_look(looks, controls, identity, amount, fix):
    look = looks[identity]
    blendless = look['base'] == 'original' and not any(look['adjustments'].values()) and not look['grade']
    kept = fix if fix is not None else {name: (controls.get('colorGrade') or {}).get(name, 0) for name in FIX}
    values = {name: look['grade'].get(name, 0) for name in SLIDERS if name not in FIX}
    result = {key: value for key, value in controls.items() if key not in ('look', 'colorAdjustments', 'colorGrade')}
    return entry(**result, look=look['base'], colorAdjustments=look['adjustments'], colorGrade=grade(
        preset=None if blendless else identity, amount=100 if blendless else min(100, max(0, amount)),
        **{name: kept.get(name, 0) for name in FIX}, **values,
        curve=look['grade'].get('curve'), splitTone=look['grade'].get('splitTone')))


def generated():
    looks = library()
    warm_print = looks['warmPrint']
    split = warm_print['grade']['splitTone']
    curve = warm_print['grade']['curve']
    printed = dict(look='original', colorAdjustments=warm_print['adjustments'])
    match_inputs = [
        ('defaults', entry()),
        ('muted', entry(look='muted')),
        ('black-and-white', entry(look='bw')),
        ('clean-pop', entry(colorAdjustments=looks['cleanPop']['adjustments'])),
        ('clean-pop-moved', entry(colorAdjustments={**looks['cleanPop']['adjustments'], 'contrast': 23})),
        ('vintage-fade-over-warm', entry(look='warm', colorAdjustments=looks['vintageFade']['adjustments'])),
        ('fix-only', entry(colorGrade=grade(exposure=20, temperature=-12))),
        ('warm-print-at-seventy-with-a-fix', entry(**printed, colorGrade=grade(
            preset='warmPrint', amount=70, temperature=-12, highlights=-12, fade=20, grain=20, curve=curve, splitTone=split))),
        ('warm-print-values-without-a-preset', entry(**printed, colorGrade=grade(highlights=-12, fade=20, grain=20, curve=curve, splitTone=split))),
        ('reference-task-edits-warm-print', entry(**printed, colorGrade=grade(
            preset='warmPrint', amount=70, highlights=-15, vibrance=20, fade=20, grain=20, curve=curve, splitTone=split))),
        ('toning-removed-edits-warm-print', entry(**printed, colorGrade=grade(preset='warmPrint', highlights=-12, fade=20, grain=20))),
        ('golden-hour-values', entry(look='warm', colorAdjustments=looks['goldenHour']['adjustments'],
                                     colorGrade=grade(highlights=-20, shadows=15, vibrance=25, vignette=20))),
        ('muted-at-seventy', entry(look='muted', colorGrade=grade(preset='muted', amount=70))),
        ('muted-preset-over-warm', entry(look='warm', colorGrade=grade(preset='muted', amount=70))),
        ('soft-black-and-white', entry(look='bw', colorAdjustments={'contrast': -15}, colorGrade=grade(highlights=-10, fade=25))),
        ('unknown-preset', entry(colorGrade=grade(preset='futureLook9', vibrance=25))),
        ('values-no-look-has', entry(colorGrade=grade(vibrance=26))),
        ('fixed-classic-look', entry(colorAdjustments=looks['softLight']['adjustments'], colorGrade=grade(tint=8))),
    ]
    matches = []
    for identity, controls in match_inputs:
        look, state, name = match(looks, controls)
        matches.append({'id': identity, 'controls': controls, 'look': look, 'state': state, 'name': name})

    main = {'clipId': 'clip-main', 'speed': 1.25, 'shape': '9:16', 'look': 'muted', 'gainDb': -3.5,
            'fadeInSeconds': 0.5, 'fadeOutSeconds': 1, 'muteSource': False, 'flipHorizontal': True, 'rotationDegrees': 90}
    fixed = entry(colorGrade=grade(exposure=20))
    printed_entry = apply_look(looks, DEFAULTS, 'warmPrint', 70, None)
    set_inputs = [
        ('classic-look-stores-no-grade', None, 'cleanPop', 100, None),
        ('as-filmed-on-defaults-stores-nothing', None, 'original', 100, None),
        ('warm-print-at-seventy', None, 'warmPrint', 70, None),
        ('golden-hour-keeps-the-other-controls', main, 'goldenHour', 80, None),
        ('muted-keeps-the-fix', fixed, 'muted', 100, None),
        ('as-filmed-keeps-the-fix', fixed, 'original', 100, None),
        ('as-filmed-has-no-amount', None, 'original', 50, None),
        ('a-given-fix-replaces-the-clips', fixed, 'warmPrint', 70, {'exposure': 0, 'temperature': -12, 'tint': 4}),
        ('a-classic-look-after-warm-print-clears-the-grade', printed_entry, 'cleanPop', 100, None),
        ('muted-at-seventy', None, 'muted', 70, None),
        ('amount-over-100-is-100', None, 'tealAmber', 150, None),
        ('amount-under-0-is-0', None, 'moody', -5, None),
        ('sepia-over-black-and-white', main, 'sepia', 90, None),
    ]
    settings = []
    for identity, before, look, amount, fix in set_inputs:
        after = apply_look(looks, before or DEFAULTS, look, amount, fix)
        case = {'id': identity, 'before': before, 'look': look, 'amount': amount, 'fix': fix,
                'after': None if is_default(after) else after}
        # The fixture project is v4. The harness stores `before` first; a grade frames the project at v8, and once no grade
        # is left the writer lowers the frame to 6, the timeline edit version (editing section 10.4).
        case['schemaVersion'] = 8 if after.get('colorGrade') else 6 if (before or {}).get('colorGrade') else 4
        settings.append(case)
    unknown = {'id': 'an-unknown-look-is-refused', 'before': None, 'look': 'sunset', 'amount': 100, 'fix': None, 'refused': True}
    return {'format': 'voxclip-look-cases/1', 'looks': 'looks/clip-looks.json',
            'project': 'fixtures/clip-controls/clip-controls-project.voxclip',
            'match': matches, 'setLookPreset': settings + [unknown]}


def dump(document):
    lines = ['{']
    keys = list(document)
    for index, key in enumerate(keys):
        value = document[key]
        comma = ',' if index < len(keys) - 1 else ''
        if isinstance(value, list):
            lines.append(f'  {json.dumps(key)}: [')
            lines += ['    ' + json.dumps(item, ensure_ascii=False) + (',' if i < len(value) - 1 else '') for i, item in enumerate(value)]
            lines.append('  ]' + comma)
        else:
            lines.append(f'  {json.dumps(key)}: {json.dumps(value, ensure_ascii=False)}{comma}')
    return '\n'.join(lines + ['}']) + '\n'


def main():
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    text = dump(generated())
    assert json.loads(text) == generated()
    DESTINATION.write_text(text)


if __name__ == '__main__':
    main()
