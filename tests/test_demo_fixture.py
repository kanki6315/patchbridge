"""The app's demo preset stays derived from the captured fixture."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('export_demo_fixture', ROOT / 'tools/export_demo_fixture.py')
export_demo_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export_demo_fixture)


class DemoFixtureTests(unittest.TestCase):
    def setUp(self):
        self.captured = json.loads((ROOT / 'tests/fixtures/qc-editor.json').read_text())
        self.demo = json.loads((ROOT / 'tests/fixtures/demo-preset.json').read_text())

    def test_committed_demo_matches_the_captured_fixture(self):
        self.assertEqual(export_demo_fixture.demo(self.captured), self.demo,
                         'Run python3 tools/export_demo_fixture.py to regenerate the demo preset.')

    def test_demo_renames_the_preset_and_drops_the_volume_utility(self):
        snapshot = self.demo['snapshot']
        self.assertEqual(snapshot['name'], 'Dirty Riffage')
        self.assertNotIn('1:2', {b['id'] for b in snapshot['blocks']})
        self.assertEqual(len(snapshot['blocks']), len(self.captured['snapshot']['blocks']) - 1)
        self.assertEqual(set(self.demo['catalog']['models']), {b['model_id'] for b in snapshot['blocks']})
        self.assertEqual(snapshot['catalog_id'], self.demo['catalog']['id'])


if __name__ == '__main__':
    unittest.main()
