import json
import struct
import unittest
from pathlib import Path
from generate_fitted_assets import encode, header, vectors


class FittedAssetsTests(unittest.TestCase):
    def test_committed_vectors_match_independent_generator(self):
        path = Path(__file__).resolve().parents[2] / 'shared/fixtures/voice-lab/fitted-asset-cases.json'
        self.assertEqual(path.read_text(), json.dumps(vectors(), indent=2) + '\n')

    def test_integer_join_conversion_uses_ties_to_even_and_full_range(self):
        self.assertEqual(encode(0.5 / 32768, 16, False), struct.pack('<h', 0))
        self.assertEqual(encode(1.5 / 32768, 16, False), struct.pack('<h', 2))
        self.assertEqual(encode(-1, 16, False), struct.pack('<h', -32768))
        self.assertEqual(encode(2, 16, False), struct.pack('<h', 32767))

    def test_odd_data_has_a_riff_pad_but_not_a_data_chunk_pad(self):
        result = header(bytes(3), 24000, 1, 24, False)
        self.assertEqual(len(result), 44)
        self.assertEqual(struct.unpack_from('<I', result, 4)[0], 40)
        self.assertEqual(struct.unpack_from('<I', result, 40)[0], 3)


if __name__ == '__main__':
    unittest.main()
