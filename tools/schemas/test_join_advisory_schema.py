import copy
import json
import pathlib
import unittest

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]


class JoinAdvisorySchemaTests(unittest.TestCase):
    def test_shared_cases(self):
        fixtures = ROOT / 'shared/fixtures/voice-lab'
        document = json.loads((fixtures / 'join-advisory-cases.json').read_text())
        self.assertEqual(document['caseCount'], len(document['cases']))
        registry, schemas = load_registry()
        validator = Draft202012Validator(schemas['project.schema.json'], registry=registry, format_checker=FormatChecker())
        base = json.loads((fixtures / document['baseProject']).read_text())
        for case in document['cases']:
            for version in (3, 4):
                with self.subTest(case=case['name'], version=version):
                    project = copy.deepcopy(base)
                    project['schemaVersion'] = version
                    segment = project['voiceLab']['segments'][0]
                    qa = segment['candidates'][0]['recipe']['qa']
                    qa.update(case['qa'])
                    for key in segment['qa']:
                        segment['qa'][key] = qa[key]
                    self.assertEqual(case['schemaValid'], not list(validator.iter_errors(project)))


if __name__ == '__main__':
    unittest.main()
