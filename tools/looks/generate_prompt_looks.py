#!/usr/bin/env python3
"""Write the `looks` list of shared/prompts/clip-autopilot.json from shared/looks/clip-looks.json (looks spec 2026-11-28,
section 9.2): one entry per look the pickers offer (not `hidden`), in the library's display order, each with the line the
planner's system prompt lists:

    id: label (category[, strong]): line. Use when: pickWhen. Start at amount.

The prompt file carries the generated text, so its hash and version cover every word Claude reads; both Cores check that
its IDs are exactly the library's visible looks. Only the `looks` block is rewritten; the rest of the file stays as it is.
`--check` exits non-zero when the committed block differs (check_drift.py runs the generator). Run from anywhere.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOOKS = ROOT / 'shared/looks/clip-looks.json'
PROMPT = ROOT / 'shared/prompts/clip-autopilot.json'
BLOCK = re.compile(r'\n  "looks": \[\n.*?\n  \],\n', re.DOTALL)


def entries():
    library = json.loads(LOOKS.read_text(encoding='utf-8'))
    categories = {category['id']: category['label'] for category in library['categories']}
    result = []
    for look in library['looks']:
        if look.get('hidden'):
            continue
        kind = categories[look['category']] + (', strong' if look['strength'] == 'strong' else '')
        planner = look['planner']
        line = (f"{look['id']}: {look['label']} ({kind}): {look['line']}. Use when: {planner['pickWhen']}. "
                f"Start at {planner['amount']}.")
        result.append({'id': look['id'], 'line': line})
    return result


def rendered(text):
    block = json.dumps(entries(), indent=2, ensure_ascii=False).replace('\n', '\n  ')
    replaced, count = BLOCK.subn(lambda _: f'\n  "looks": {block},\n', text, count=1)
    if count != 1:
        raise SystemExit(f'{PROMPT}: no top-level "looks" block to replace')
    return replaced


def main():
    text = PROMPT.read_text(encoding='utf-8')
    result = rendered(text)
    json.loads(result)
    if '--check' in sys.argv[1:]:
        if result != text:
            print(f'::error::{PROMPT.relative_to(ROOT)} looks differ from {LOOKS.relative_to(ROOT)}; run {Path(__file__).name}')
            return 1
        return 0
    if result != text:
        PROMPT.write_text(result, encoding='utf-8')
    return 0


if __name__ == '__main__':
    sys.exit(main())
