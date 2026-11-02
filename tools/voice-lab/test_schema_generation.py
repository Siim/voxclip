"""The Voice Lab generator must preserve later project formats and frozen wire keys."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ProjectSchemaGenerationTests(unittest.TestCase):
    def test_render_schema_regeneration_preserves_v4_byte_for_byte(self):
        relative = Path('tools/fixtures/voice-lab/generate_render_schema.py')
        schema_relative = Path('shared/schemas/project.schema.json')
        expected = (ROOT / schema_relative).read_bytes()
        self.assertIn(4, json.loads(expected)['properties']['schemaVersion']['enum'])
        with tempfile.TemporaryDirectory(prefix='voxclip-schema-generation-') as directory:
            root = Path(directory)
            script = root / relative
            script.parent.mkdir(parents=True)
            script.write_bytes((ROOT / relative).read_bytes())
            schema = root / schema_relative
            schema.parent.mkdir(parents=True)
            schema.write_bytes(expected)
            for _ in range(2):
                subprocess.run([sys.executable, str(script)], cwd=root, check=True)
                self.assertEqual(expected, schema.read_bytes())


if __name__ == '__main__':
    unittest.main()
