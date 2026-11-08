import copy
import json
import pathlib
import unittest

from jsonschema import Draft202012Validator, FormatChecker
from validate import load_registry

ROOT = pathlib.Path(__file__).resolve().parents[2]


class NaturalPacingSchemaTests(unittest.TestCase):
    def setUp(self):
        registry, schemas = load_registry()
        self.validator = Draft202012Validator(schemas['project.schema.json'], registry=registry, format_checker=FormatChecker())
        self.base = json.loads((ROOT / 'shared/fixtures/voice-lab/passage-render-v3.voxclip').read_text())

    def project(self):
        project = copy.deepcopy(self.base)
        video = project['voiceLab']['segments'][0]['candidates'][0]['recipe']['video']
        video.update(mode='cut', outputSamples=660, zoom=1.06, faceX=0.5, faceY=0.5,
                     cuts=[{'startSample': 2800, 'endSample': 2840}])
        return project, video

    def test_legacy_omits_cuts_and_new_cut_round_trips(self):
        self.assertFalse(list(self.validator.iter_errors(self.base)))
        project, _ = self.project()
        self.assertFalse(list(self.validator.iter_errors(json.loads(json.dumps(project)))))

    def test_cut_requires_its_spans(self):
        project, video = self.project()
        del video['cuts']
        self.assertTrue(list(self.validator.iter_errors(project)))

    def test_cut_spans_are_bounded_and_strictly_shaped(self):
        for invalid in ([], None, [{'startSample': 2800}],
                        [{'startSample': -1, 'endSample': 2840}],
                        [{'startSample': 2800, 'endSample': 2840, 'unknown': True}],
                        # A whole clip's edited picture holds up to 512 cuts (ADR-R46, the schema's cuts.maxItems).
                        [{'startSample': 2800, 'endSample': 2840}] * 513):
            with self.subTest(invalid=invalid):
                project, video = self.project()
                video['cuts'] = invalid
                self.assertTrue(list(self.validator.iter_errors(project)))


if __name__ == '__main__':
    unittest.main()
