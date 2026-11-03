import copy
import json
import pathlib
import unittest

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]


class HardJoinSchemaTests(unittest.TestCase):
    def setUp(self):
        registry, schemas = load_registry()
        self.validator = Draft202012Validator(schemas['project.schema.json'], registry=registry, format_checker=FormatChecker())
        self.base = json.loads((ROOT / 'shared/fixtures/voice-lab/passage-render-v3.voxclip').read_text())

    def project(self):
        project = copy.deepcopy(self.base)
        recipe = project['voiceLab']['segments'][0]['candidates'][0]['recipe']
        recipe['seams']['out']['kind'] = 'hard'
        recipe['seams']['out']['microPause'] = {'wordStartSeconds': -0.4, 'wordEndSeconds': -0.14}
        recipe['edgeGain'] = {'out': {'gainDb': 3, 'wordSeconds': copy.deepcopy(recipe['seams']['out']['microPause'])}}
        return project, recipe

    def test_legacy_and_optional_fields_validate(self):
        self.assertFalse(list(self.validator.iter_errors(self.base)))
        for version in (3, 4):
            project, recipe = self.project()
            project['schemaVersion'] = version
            self.assertFalse(list(self.validator.iter_errors(project)))
            del recipe['edgeGain']
            self.assertFalse(list(self.validator.iter_errors(project)))

    def test_rejects_invalid_fields(self):
        for invalid in ('gain-high', 'gain-negative', 'empty-gain', 'gap-pause', 'outside', 'unknown'):
            with self.subTest(invalid=invalid):
                project, recipe = self.project()
                if invalid == 'gain-high':
                    recipe['edgeGain']['out']['gainDb'] = 6.01
                elif invalid == 'gain-negative':
                    recipe['edgeGain']['out']['gainDb'] = -0.01
                elif invalid == 'empty-gain':
                    recipe['edgeGain'] = {}
                elif invalid == 'gap-pause':
                    recipe['seams']['out']['kind'] = 'gap'
                elif invalid == 'outside':
                    recipe['seams']['out']['microPause']['wordStartSeconds'] = -291
                else:
                    recipe['seams']['out']['microPause']['unexpected'] = 1
                self.assertTrue(list(self.validator.iter_errors(project)))


if __name__ == '__main__':
    unittest.main()
