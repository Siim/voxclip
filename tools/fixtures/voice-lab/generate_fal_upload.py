import json
from pathlib import Path


root = Path(__file__).resolve().parents[3]
vector = {"bytes": 94_371_841, "parts": [10_485_760] * 9 + [1]}
(root / "shared/fixtures/voice-lab/fal-upload-case.json").write_text(json.dumps(vector) + "\n")
