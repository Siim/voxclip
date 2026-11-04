"""The Voice Lab generator must preserve later project formats and frozen wire keys."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ProjectSchemaGenerationTests(unittest.TestCase):
    def test_hard_join_fields_are_optional(self):
        schema = json.loads((ROOT / 'shared/schemas/project.schema.json').read_bytes())
        for definition, field in [('voiceLabSeam', 'microPause'), ('voiceLabRenderRecipe', 'edgeGain')]:
            self.assertNotIn(field, schema['$defs'][definition]['required'])
            self.assertIn(field, schema['$defs'][definition]['properties'])
        self.assertNotIn('required', schema['$defs']['voiceLabEdgeGain'])
        self.assertEqual(1, schema['$defs']['voiceLabEdgeGain']['minProperties'])

    def test_pace_is_optional_in_every_provenance_shape(self):
        schema = json.loads((ROOT / 'shared/schemas/project.schema.json').read_bytes())
        for name in ['voiceLabSegment', 'voiceLabSegmentV3', 'voiceLabRenderRecipe']:
            provenance = schema['$defs'][name]['properties']['provenance']
            self.assertNotIn('pace', provenance['required'])
            self.assertEqual(provenance['properties']['pace'], {'type': 'number', 'minimum': 0.7, 'maximum': 1.2})

    def test_short_speech_is_optional_and_uses_record_id_wire_key(self):
        schema = json.loads((ROOT / 'shared/schemas/project.schema.json').read_bytes())
        qa = schema['$defs']['voiceLabRenderQA']
        self.assertNotIn('shortSpeech', qa['required'])
        evidence = qa['properties']['shortSpeech']
        self.assertEqual(set(evidence['required']), {'mode', 'recordId', 'consentMethod', 'voicedFrames', 'takeCount'})
        self.assertNotIn('recordID', evidence['properties'])

    def test_lip_synced_video_records_either_sync_mode(self):
        schema = json.loads((ROOT / 'shared/schemas/project.schema.json').read_bytes())
        sync = schema['$defs']['voiceLabVideoRecipe']['properties']['syncMode']['oneOf']
        self.assertIn({'enum': ['remap', 'cut_off']}, sync)

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
