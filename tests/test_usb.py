from copy import deepcopy
from pathlib import Path
from unittest import TestCase, skipUnless
from unittest.mock import Mock

from patchbridge.adapter import BridgeError
from patchbridge.helper import Coordinator
from patchbridge.usb import USBAdapter


class USBWriteTests(TestCase):
    def setUp(self):
        self.adapter = USBAdapter()
        self.adapter.qc = Mock()
        self.adapter.position = ('/media/p4/Presets/My Presets', 16, False, False, False)
        self.state = {'preset_id': 'slot', 'name': 'Disposable', 'scene': 'F',
                      'dirty': True, 'blocks': []}
        self.adapter.state = deepcopy(self.state)

    def test_save_uses_file_create_and_preserves_slot_name(self):
        clean = dict(self.state, dirty=False)
        self.adapter.snapshot = Mock(side_effect=[self.state, clean])
        self.assertEqual(self.adapter.execute('save', {}), clean)
        self.adapter.qc.write_preset_file.assert_called_once_with(
            '/media/p4/Presets/My Presets', 16, 'Disposable')
        self.adapter.qc.save_preset.assert_not_called()

    def test_dirty_save_is_not_confirmed_or_retried(self):
        self.adapter.snapshot = Mock(return_value=self.state)
        with self.assertRaisesRegex(RuntimeError, 'Save not confirmed'):
            self.adapter.execute('save', {})
        self.adapter.qc.write_preset_file.assert_called_once()
        self.adapter.qc.save_preset.assert_not_called()

    def test_clean_flag_with_changed_preset_is_not_save_success(self):
        self.adapter.snapshot = Mock(side_effect=[self.state, dict(self.state, dirty=False, preset_id='other')])
        with self.assertRaises(RuntimeError):
            self.adapter.execute('save', {})

    def test_physical_change_rejected_before_write(self):
        self.adapter.snapshot = Mock(return_value=dict(self.state, scene='G'))
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('save', {})
        self.assertEqual(caught.exception.code, 'stale_context')
        self.assertFalse(self.adapter.qc.mock_calls)

    def test_factory_save_rejected(self):
        self.adapter.position = ('Factory', 0, True, False, False)
        self.adapter.snapshot = Mock(return_value=self.state)
        with self.assertRaises(BridgeError):
            self.adapter.execute('save', {})
        self.assertFalse(self.adapter.qc.mock_calls)

    def test_unsupported_operations_do_not_touch_device(self):
        for op in ('save_as', 'select_scene', 'recall_preset_save'):
            with self.assertRaises(BridgeError):
                self.adapter.execute(op, {})
        self.assertFalse(self.adapter.qc.mock_calls)

    def test_usb_capabilities_only_advertise_implemented_operations(self):
        response = Coordinator(self.adapter).handle({
            'version': 1, 'type': 'request', 'id': '1', 'operation': 'capabilities',
        })[0]
        self.assertIn('save', response['result']['operations'])
        self.assertIn('set_bypass', response['result']['operations'])
        self.assertNotIn('save_as', response['result']['operations'])

    def test_parameter_write_requires_readback(self):
        block = {'id': '0:3', 'position': [0, 3], 'model_id': '1',
                 'editable_parameters': ['0'],
                 'scenes': {'F': {'parameters': {'0': 0.38}}}}
        self.state['blocks'] = [block]
        self.adapter.state = deepcopy(self.state)
        self.adapter.metadata = {'models': {'1': {'parameters': {'0': {'type': 'float'}}}}}
        self.adapter.snapshot = Mock(return_value=self.state)
        with self.assertRaisesRegex(RuntimeError, 'Write could not be confirmed'):
            self.adapter.execute('set_parameter', {
                'block_id': '0:3', 'parameter_id': '0', 'value': 0.39,
            })
        self.adapter.qc.set_param.assert_called_once_with(0, 3, 0, 0.39)

    def test_toggle_button_writes_only_declared_steps(self):
        block = {'id': '0:3', 'position': [0, 3], 'model_id': '1', 'editable_parameters': ['0'],
                 'scenes': {'F': {'parameters': {'0': 0.0}}}}
        self.state['blocks'] = [block]
        self.adapter.state = deepcopy(self.state)
        self.adapter.metadata = {'models': {'1': {'parameters': {'0': {
            'type': 'toggleButton', 'steps': '2', 'stepNames': 'RELEASE,FREEZE'}}}}}
        frozen = deepcopy(self.state); frozen['blocks'][0]['scenes']['F']['parameters']['0'] = 1.0
        self.adapter.snapshot = Mock(side_effect=[self.state, frozen])
        self.adapter.execute('set_parameter', {'block_id': '0:3', 'parameter_id': '0', 'value': 1.0})
        self.adapter.qc.set_param.assert_called_once_with(0, 3, 0, 1.0)
        self.adapter.state = deepcopy(self.state)
        self.adapter.snapshot = Mock(return_value=self.state)
        with self.assertRaises(BridgeError):
            self.adapter.execute('set_parameter', {'block_id': '0:3', 'parameter_id': '0', 'value': 0.5})
        self.adapter.qc.set_param.assert_called_once()

    def bypass_block(self, bypassed):
        return {'id': '0:3', 'position': [0, 3], 'model_id': '1', 'editable_parameters': [],
                'scenes': {'F': {'bypass': bypassed, 'parameters': {}}}}

    def test_bypass_writes_active_scene_flag_and_reads_it_back(self):
        self.state['blocks'] = [self.bypass_block(False)]
        self.adapter.state = deepcopy(self.state)
        off = dict(self.state, blocks=[self.bypass_block(True)])
        self.adapter.snapshot = Mock(side_effect=[self.state, off])
        self.assertEqual(self.adapter.execute('set_bypass', {'block_id': '0:3', 'value': True}), off)
        self.adapter.qc.set_block_bypass.assert_called_once_with(0, 3, True)

    def test_bypass_requires_readback(self):
        self.state['blocks'] = [self.bypass_block(False)]
        self.adapter.state = deepcopy(self.state)
        self.adapter.snapshot = Mock(return_value=self.state)
        with self.assertRaisesRegex(RuntimeError, 'Bypass could not be confirmed'):
            self.adapter.execute('set_bypass', {'block_id': '0:3', 'value': True})
        self.adapter.qc.set_block_bypass.assert_called_once()

    def test_bypass_rejects_unknown_block_and_non_boolean(self):
        self.state['blocks'] = [self.bypass_block(False)]
        self.adapter.state = deepcopy(self.state)
        self.adapter.snapshot = Mock(return_value=self.state)
        for payload in ({'block_id': '1:0', 'value': True}, {'block_id': '0:3', 'value': 1},
                        {'block_id': '0:3'}):
            with self.assertRaises(BridgeError) as caught:
                self.adapter.execute('set_bypass', payload)
            self.assertEqual(caught.exception.code, 'invalid_value')
        self.adapter.qc.set_block_bypass.assert_not_called()

    def test_failed_preflight_does_not_advance_accepted_state(self):
        original = deepcopy(self.adapter.state)
        def refresh():
            self.adapter.state = dict(self.state, scene='G')
            return self.adapter.state
        self.adapter.snapshot = Mock(side_effect=refresh)
        for _ in range(2):
            with self.assertRaises(BridgeError):
                self.adapter.execute('save', {})
            self.assertEqual(self.adapter.state, original)
        self.assertFalse(self.adapter.qc.mock_calls)


VENDORED = Path(__file__).resolve().parents[1] / 'vendor' / 'qc-mcp' / 'src'
try:
    import google.protobuf  # noqa: F401
    PROTOBUF = True
except ImportError:
    PROTOBUF = False


class RequestQueueTests(TestCase):
    def test_reads_drop_streamed_broadcasts_and_keep_the_rest(self):
        import threading
        from types import SimpleNamespace
        from patchbridge.usb import drop_broadcasts
        tempo, undo, reply = (33, None, b't', b''), (40, None, b'u', b''), (2, object(), b'r', b'pb')
        qc = SimpleNamespace(_io_lock=threading.RLock(), _pending=[tempo, undo, tempo])
        qc.request = lambda command: reply[:3]
        drop_broadcasts(qc, lambda: SimpleNamespace(COMMANDS={2: 'PresetDirty', 33: 'GlobalTempo', 40: 'UndoRedo'}))
        self.assertEqual(qc.request('PresetDirty'), reply[:3])
        self.assertEqual(qc._pending, [undo])

    @skipUnless(PROTOBUF, 'The vendored qc-mcp transport needs protobuf')
    def test_vendored_request_neither_copies_the_queue_nor_keeps_the_reply(self):
        """Upstream qc-mcp f634ecd doubled its queue on every read."""
        import sys
        import threading
        from types import SimpleNamespace
        sys.path.insert(0, str(VENDORED))
        from qc_mcp.transport import QuadCortex
        qc = QuadCortex.__new__(QuadCortex)
        qc._io_lock, qc._pending = threading.RLock(), [(40, None, b'u', b'')]
        sent = []
        qc.send = lambda command, message=None, data=None: sent.append(message.request_id)
        qc._collect = lambda seconds: qc._pending.append((2, SimpleNamespace(request_id=sent[-1]), b'r', b'reply'))
        for i in range(1, 9):
            qc.request(2, SimpleNamespace(request_id=i))
        self.assertEqual(qc._pending, [(40, None, b'u', b'')])
