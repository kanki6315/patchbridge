"""Recorded-preset shape tests without protobuf, HID, or a connected QC."""
from copy import deepcopy
import io
import json
from pathlib import Path
import tarfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import Mock

from patchbridge.adapter import BridgeError
from patchbridge.usb import USBAdapter

FIXTURE = Path(__file__).parents[1] / 'hardware-results/2026-10-20/initial-preset.json'


class Value:
    def __init__(self, values):
        self.fields = dict(zip(('float_value', 'int_value', 'string_value'), values))
        self.__dict__.update(self.fields)
    def WhichOneof(self, field):
        return next((key for key, value in self.fields.items() if value is not None), None)


def preset(spec):
    def model(data):
        return NS(hash=data['hash'], column=data['column'], params=[NS(
            scene_mode=p['scene_mode'], expression=p['expression'],
            param_values=[Value(v) for v in p['values']]) for p in data['params']])
    return NS(name=spec['name'], chains=[NS(row=ch['row'], models=[model(m) for m in ch['models']])
                                       for ch in spec['chains']],
              SerializeToString=lambda: json.dumps(spec, sort_keys=True).encode())


@unittest.skipUnless(FIXTURE.exists(), "Raw QC capture is local-only; see README.md")
class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.spec = json.loads(FIXTURE.read_text())
        self.qc = Mock()
        self.qc.get_current_preset.side_effect = lambda: preset(self.spec)
        self.pos = NS(folder_key='/media/p4/Presets/My Presets', position=16, is_factory=False)
        self.scene = NS(selected_scene=5)
        self.qc.read_state.side_effect = lambda name: {
            'SetlistPosition': self.pos, 'Scene': self.scene,
            'PresetDirty': NS(is_dirty=True),
        }[name]
        self.adapter = USBAdapter()
        self.adapter.qc = self.qc
        self.adapter.metadata = {'models': {'1': {'parameters': {'0': {'type': 'float'}}}}}

    def test_recorded_snapshot_uses_array_addresses_and_scene(self):
        state = self.adapter.snapshot()
        self.assertEqual(state['scene'], 'F')
        self.assertEqual(len(state['blocks']), 16)
        block = next(b for b in state['blocks'] if b['id'] == '0:3')
        self.assertEqual(block['model_id'], '1')
        self.assertIn('0', block['editable_parameters'])
        self.assertAlmostEqual(block['scenes']['F']['parameters']['0'], 0.3577812612)
        state['blocks'].clear()
        self.assertEqual(len(self.adapter.state['blocks']), 16)

    def test_hidden_routing_change_invalidates_pending_save(self):
        self.adapter.snapshot()
        self.spec['chains'][0]['out_portid'] += 1
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('save', {})
        self.assertEqual(caught.exception.code, 'stale_context')
        self.qc.write_preset_file.assert_not_called()

    def test_missing_scene_value_not_copied_from_another_scene(self):
        param = self.spec['chains'][0]['models'][3]['params'][0]
        param['scene_mode'] = True
        param['values'] = [[0.2, None, None]]
        block = next(b for b in self.adapter.snapshot()['blocks'] if b['id'] == '0:3')
        self.assertNotIn('0', block['scenes']['F']['parameters'])
        self.assertNotIn('0', block['editable_parameters'])

    def test_timeout_and_context_change_are_not_snapshots(self):
        self.qc.get_current_preset.side_effect = lambda: None
        with self.assertRaises(RuntimeError):
            self.adapter.snapshot()
        self.qc.get_current_preset.side_effect = lambda: preset(self.spec)
        self.qc.read_state.side_effect = [self.pos, self.scene, NS(is_dirty=False),
                                        NS(folder_key='other', position=1, is_factory=False), self.scene]
        with self.assertRaises(RuntimeError):
            self.adapter.snapshot()

    def test_expression_parameter_is_read_only(self):
        self.spec['chains'][0]['models'][3]['params'][0]['expression'] = 1
        block = next(b for b in self.adapter.snapshot()['blocks'] if b['id'] == '0:3')
        self.assertNotIn('0', block['editable_parameters'])

    def test_all_scene_assignments_preserve_distinct_values_but_remain_read_only(self):
        param = self.spec['chains'][0]['models'][3]['params'][0]
        param['scene_mode'] = True
        param['values'] = [[i / 10, None, None] for i in range(8)]
        block = next(b for b in self.adapter.snapshot()['blocks'] if b['id'] == '0:3')
        self.assertNotIn('0', block['editable_parameters'])
        for index in range(8):
            self.assertEqual(block['scenes'][chr(65 + index)]['parameters']['0'], index / 10)

    def test_unknown_model_and_mixed_types_are_preserved_read_only(self):
        model = self.spec['chains'][0]['models'][3]
        model['hash'] = 999999
        model['params'][0]['values'] = [[None, None, 'custom string']]
        block = next(b for b in self.adapter.snapshot()['blocks'] if b['id'] == '0:3')
        self.assertEqual(block['editable_parameters'], [])
        self.assertEqual(block['scenes']['F']['parameters']['0'], 'custom string')

    def test_invalid_scene_fails_instead_of_producing_editor_state(self):
        for scene in (-1, 8, 99):
            self.scene.selected_scene = scene
            with self.assertRaises(RuntimeError): self.adapter.snapshot()


class ConnectionTests(unittest.TestCase):
    def test_wrong_firmware_closes_without_reading_catalog(self):
        qc = Mock(firmware='4.2.0', protocol_version_verified=True)
        adapter = USBAdapter(factory=lambda: qc)
        with self.assertRaises(BridgeError):
            adapter.connect()
        qc.close.assert_called_once()
        qc.read_state.assert_not_called()
        self.assertIsNone(adapter.qc)

    def test_catalog_preserves_option_names_and_symbolic_ranges(self):
        xml = b'<Root><Category name="Test"><Model id="1" name="Model"><Parameter type="switch" min="MIN" max="MAX" steps="2" stepNames="Off,On"/></Model></Category></Root>'
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            info = tarfile.TarInfo('ModelRepo.xml'); info.size = len(xml)
            archive.addfile(info, io.BytesIO(xml))
        qc = Mock(firmware='4.1.1', protocol_version_verified=True)
        qc.read_state.return_value = NS(model_repo_payload=data.getvalue())
        adapter = USBAdapter(factory=lambda: qc)
        adapter.connect()
        parameter = adapter.catalog()['models']['1']['parameters']['0']
        self.assertEqual(parameter['stepNames'], 'Off,On')
        self.assertEqual(parameter['min'], 'MIN')
        self.assertIn(-536850432, qc.io.BENIGN_WRITE_CODES)
        adapter.disconnect()

class SceneMetadataTests(unittest.TestCase):
    def test_scene_names_and_argb_colors_are_carried_without_recoloring(self):
        adapter = USBAdapter()
        adapter.qc = Mock()
        adapter.metadata = {'id': 'catalog', 'models': {}}
        adapter.qc.get_current_preset.return_value = NS(
            name='Preset', chains=[], scene_labels=['', 'RHYTHM'],
            scene_colors=[0xff0071ce, 0xffff7000], SerializeToString=lambda: b'preset')
        position = NS(folder_key='My Presets', position=16, is_factory=False)
        adapter.qc.read_state.side_effect = lambda name: {
            'SetlistPosition': position, 'Scene': NS(selected_scene=1),
            'PresetDirty': NS(is_dirty=False),
        }[name]
        snapshot = adapter.snapshot()
        self.assertEqual(snapshot['scene_labels'], ['', 'RHYTHM'])
        self.assertEqual(snapshot['scene_colors'], [0xff0071ce, 0xffff7000])
