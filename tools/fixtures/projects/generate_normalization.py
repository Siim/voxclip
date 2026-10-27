#!/usr/bin/env python3
"""Generate the legacy project text-normalization case (editing section 10.1)."""
import copy
import json
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FOLDER = ROOT / 'shared/fixtures/projects/normalization'
FOLDER.mkdir(exist_ok=True)
project = json.loads((FOLDER.parent / 'interview-take.voxclip').read_text())
project['transcript']['words'][0]['text'] = chr(0xAC00) + chr(0x11A8)
project['transcript']['words'][1]['text'] = chr(0x1100) + chr(0x1176)
project['transcript']['words'][2]['text'] = chr(0x1113) + chr(0x1161)
project['transcript']['words'][3]['text'] = chr(0x16D68)
project['edits']['corrections']['w5'] = chr(0xAC00) + chr(0x11AB)
expected = copy.deepcopy(project)
for word in expected['transcript']['words']:
    word['text'] = unicodedata.normalize('NFC', word['text'])
expected['edits']['corrections'] = {
    key: unicodedata.normalize('NFC', value) for key, value in expected['edits']['corrections'].items()
}
for name, document in [('legacy-nfc.voxclip', project), ('legacy-nfc.expected.json', expected)]:
    (FOLDER / name).write_text(json.dumps(document, ensure_ascii=True, indent=2) + '\n')
