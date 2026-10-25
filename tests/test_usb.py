from copy import deepcopy
from pathlib import Path
from unittest import TestCase, skipUnless
from unittest.mock import Mock

from patchbridge.adapter import BridgeError
from patchbridge.helper import Coordinator
from types import SimpleNamespace as NS

from patchbridge import usb
from patchbridge.usb import Unsettled, USBAdapter


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
        for op in ('save_as', 'recall_preset_save'):
            with self.assertRaises(BridgeError):
                self.adapter.execute(op, {})
        self.assertFalse(self.adapter.qc.mock_calls)

    def test_usb_capabilities_only_advertise_implemented_operations(self):
        response = Coordinator(self.adapter).handle({
            'version': 1, 'type': 'request', 'id': '1', 'operation': 'capabilities',
        })[0]
        self.assertIn('save', response['result']['operations'])
        self.assertIn('set_bypass', response['result']['operations'])
        self.assertIn('select_scene', response['result']['operations'])
        self.assertIn('select_preset', response['result']['operations'])
        self.assertIn('list_presets', response['result']['operations'])
        self.assertNotIn('save_as', response['result']['operations'])

    def test_parameter_write_requires_readback(self):
        block = {'id': '0:3', 'position': [0, 3], 'model_id': '1',
                 'editable_parameters': ['0'],
                 'scenes': {'F': {'parameters': {'0': 0.38}}}}
        self.state['blocks'] = [block]
        self.adapter.state = deepcopy(self.state)
        self.adapter.metadata = {'models': {'1': {'parameters': {'0': {'type': 'float'}}}}}
        self.adapter.snapshot = Mock(return_value=self.state)
        with self.assertRaisesRegex(BridgeError, 'Write could not be confirmed') as caught:
            self.adapter.execute('set_parameter', {
                'block_id': '0:3', 'parameter_id': '0', 'value': 0.39,
            })
        self.assertEqual(caught.exception.code, 'not_confirmed')
        self.adapter.qc.set_param.assert_called_once_with(0, 3, 0, 0.39)

    def scene_block(self, values):
        return {'id': '0:3', 'position': [0, 3], 'model_id': '1', 'editable_parameters': ['0'],
                'scene_parameters': ['0'], 'expression_parameters': {},
                'scenes': {s: {'parameters': {'0': v}} for s, v in zip('ABCDEFGH', values)}}

    def test_scene_assigned_write_changes_only_the_active_scene(self):
        self.state['blocks'] = [self.scene_block([0.1] * 8)]
        self.adapter.state = deepcopy(self.state)
        self.adapter.metadata = {'models': {'1': {'parameters': {'0': {'type': 'float'}}}}}
        after = deepcopy(self.state); after['blocks'] = [self.scene_block([0.1] * 5 + [0.8] + [0.1] * 2)]
        self.adapter.snapshot = Mock(side_effect=[self.state, after])
        self.assertEqual(self.adapter.execute('set_parameter', {
            'block_id': '0:3', 'parameter_id': '0', 'value': 0.8}), after)
        self.adapter.qc.set_param.assert_called_once_with(0, 3, 0, 0.8)

    def test_scene_assigned_write_that_reaches_other_scenes_is_not_confirmed(self):
        self.state['blocks'] = [self.scene_block([0.1] * 8)]
        self.adapter.state = deepcopy(self.state)
        self.adapter.metadata = {'models': {'1': {'parameters': {'0': {'type': 'float'}}}}}
        for wide in (self.scene_block([0.8] * 8), dict(self.scene_block([0.1] * 5 + [0.8] + [0.1] * 2), scene_parameters=[])):
            self.adapter.state = deepcopy(self.state)
            after = deepcopy(self.state); after['blocks'] = [wide]
            self.adapter.snapshot = Mock(side_effect=[self.state, after])
            with self.assertRaises(BridgeError) as caught:
                self.adapter.execute('set_parameter', {'block_id': '0:3', 'parameter_id': '0', 'value': 0.8})
            self.assertEqual(caught.exception.code, 'not_confirmed')

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

    def test_whole_step_control_writes_only_whole_steps(self):
        # Transpose SEMITONES: -12...12 in 25 steps, so only whole semitones.
        block = {'id': '0:3', 'position': [0, 3], 'model_id': '1', 'editable_parameters': ['0'],
                 'scenes': {'F': {'parameters': {'0': 0.5}}}}
        self.state['blocks'] = [block]
        self.adapter.state = deepcopy(self.state)
        self.adapter.metadata = {'models': {'1': {'parameters': {'0': {
            'type': 'float', 'steps': '25', 'control': {'step': 1.0}}}}}}
        up = deepcopy(self.state); up['blocks'][0]['scenes']['F']['parameters']['0'] = 13 / 24
        self.adapter.snapshot = Mock(side_effect=[self.state, up])
        self.adapter.execute('set_parameter', {'block_id': '0:3', 'parameter_id': '0', 'value': 13 / 24})
        self.adapter.qc.set_param.assert_called_once_with(0, 3, 0, 13 / 24)
        self.adapter.state = deepcopy(self.state)
        self.adapter.snapshot = Mock(return_value=self.state)
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('set_parameter', {'block_id': '0:3', 'parameter_id': '0', 'value': 12.5 / 24})
        self.assertEqual(caught.exception.code, 'invalid_value')
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
        with self.assertRaisesRegex(BridgeError, 'Bypass could not be confirmed') as caught:
            self.adapter.execute('set_bypass', {'block_id': '0:3', 'value': True})
        self.assertEqual(caught.exception.code, 'not_confirmed')
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

    @skipUnless(PROTOBUF, 'The vendored qc-mcp transport needs protobuf')
    def test_vendored_reads_poll_quickly(self):
        """The HID backend sleeps each whole poll, so the poll sets every read's floor."""
        import sys
        import threading
        from types import SimpleNamespace
        sys.path.insert(0, str(VENDORED))
        from qc_mcp.transport import QuadCortex
        qc = QuadCortex.__new__(QuadCortex)
        qc._io_lock, qc._pending = threading.RLock(), []
        qc.send = lambda command, message=None, data=None: None
        polls = []
        qc._collect = lambda seconds: (polls.append(seconds),
                                       qc._pending.append((2, SimpleNamespace(request_id=1), b'r', b'reply')))
        qc.request(2, SimpleNamespace(request_id=1))
        self.assertLessEqual(max(polls), 0.02)


class CompactTests(TestCase):
    def test_float32_noise_is_trimmed_and_other_values_kept(self):
        from patchbridge.usb import compact
        self.assertEqual(compact(0.30000001192092896), 0.3)
        self.assertEqual(compact(0.6666666865348816), 0.6666667)
        self.assertEqual((compact(1), compact(True), compact('x')), (1, True, 'x'))


class Clock:
    def __init__(self):
        self.now = 0.0
    def __call__(self):
        return self.now
    def sleep(self, seconds):
        self.now += seconds


class SceneSwitchTests(TestCase):
    def setUp(self):
        self.clock = Clock()
        self.adapter = USBAdapter(clock=self.clock, sleep=self.clock.sleep)
        self.adapter.qc = Mock()
        self.state = {'preset_id': 'slot', 'name': 'Disposable', 'scene': 'F', 'dirty': True, 'blocks': []}
        self.adapter.state = deepcopy(self.state)

    def test_switch_writes_waits_for_the_qc_and_reads_back(self):
        switched = dict(self.state, scene='B')
        self.adapter.snapshot = Mock(side_effect=[self.state, switched])
        self.adapter.qc.read_state.side_effect = [NS(selected_scene=5), NS(selected_scene=1)]
        self.assertEqual(self.adapter.execute('select_scene', {'scene': 'B'}), switched)
        self.adapter.qc.set_scene.assert_called_once_with(1)

    def test_active_scene_is_not_written_again(self):
        self.adapter.snapshot = Mock(return_value=self.state)
        self.assertEqual(self.adapter.execute('select_scene', {'scene': 'F'}), self.state)
        self.adapter.qc.set_scene.assert_not_called()

    def test_unknown_scene_is_refused_before_the_write(self):
        self.adapter.snapshot = Mock(return_value=self.state)
        for scene in ('I', 'b', 'AB', 2, None):
            with self.assertRaises(BridgeError) as caught:
                self.adapter.execute('select_scene', {'scene': scene})
            self.assertEqual(caught.exception.code, 'invalid_value')
        self.adapter.qc.set_scene.assert_not_called()

    def test_switch_the_qc_never_reports_is_unknown_not_refused(self):
        self.adapter.snapshot = Mock(return_value=self.state)
        self.adapter.qc.read_state.return_value = NS(selected_scene=5)
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('select_scene', {'scene': 'B'})
        self.assertEqual(caught.exception.code, 'not_confirmed')
        self.adapter.qc.set_scene.assert_called_once_with(1)

    def test_switch_that_lands_elsewhere_is_unknown(self):
        self.adapter.snapshot = Mock(side_effect=[self.state, dict(self.state, scene='C')])
        self.adapter.qc.read_state.return_value = NS(selected_scene=1)
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('select_scene', {'scene': 'B'})
        self.assertEqual(caught.exception.code, 'not_confirmed')

    def test_busy_qc_refuses_before_anything_is_written(self):
        self.adapter.snapshot = Mock(side_effect=BridgeError('device_busy', 'Busy.'))
        for operation, payload in (('select_scene', {'scene': 'B'}), ('set_bypass', {'block_id': '0:0', 'value': True})):
            with self.assertRaises(BridgeError) as caught:
                self.adapter.execute(operation, payload)
            self.assertEqual(caught.exception.code, 'device_busy')
        self.assertFalse(self.adapter.qc.mock_calls)

    def test_busy_readback_after_a_write_is_unknown(self):
        self.adapter.snapshot = Mock(side_effect=[self.state, BridgeError('device_busy', 'Busy.')])
        self.adapter.qc.read_state.return_value = NS(selected_scene=1)
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('select_scene', {'scene': 'B'})
        self.assertEqual(caught.exception.code, 'not_confirmed')


class PresetSwitchTests(TestCase):
    def setUp(self):
        self.clock = Clock()
        self.adapter = USBAdapter(clock=self.clock, sleep=self.clock.sleep)
        self.adapter.qc = Mock()
        self.current = USBAdapter.preset_id(16)
        self.target = USBAdapter.preset_id(14)
        self.state = {'preset_id': self.current, 'name': 'Disposable', 'scene': 'F', 'dirty': False, 'blocks': []}
        self.adapter.state = deepcopy(self.state)
        self.adapter.qc.list_directory.return_value = {'presets': [
            {'key': 'cloud-0-1', 'name': 'Downloads', 'is_factory': False, 'is_downloads': True, 'files': []},
            {'key': usb.MY_PRESETS, 'name': 'My Presets', 'is_factory': False, 'is_downloads': False,
             'files': [{'index': i, 'name': {14: 'Blues Lead', 16: 'Disposable'}.get(i, '')} for i in range(256)]}]}

    def test_listing_names_used_slots_with_their_snapshot_ids(self):
        listed = self.adapter.list_presets()
        self.assertEqual(listed['slots'], 256)
        self.assertEqual(listed['entries'], [
            {'preset_id': self.target, 'number': 15, 'name': 'Blues Lead'},
            {'preset_id': self.current, 'number': 17, 'name': 'Disposable'}])
        self.assertFalse(self.adapter.qc.recall.called)

    def test_switch_recalls_waits_for_the_slot_and_reads_back(self):
        self.adapter.list_presets()
        loaded = dict(self.state, preset_id=self.target, name='Blues Lead')
        self.adapter.snapshot = Mock(side_effect=[self.state, loaded])
        self.adapter.qc.read_state.side_effect = [NS(folder_key=usb.MY_PRESETS, position=16, is_factory=False),
                                                  NS(folder_key=usb.MY_PRESETS, position=14, is_factory=False)]
        self.assertEqual(self.adapter.execute('select_preset', {'preset_id': self.target}), loaded)
        self.adapter.qc.recall.assert_called_once_with(usb.MY_PRESETS, 14, False)

    def test_unlisted_empty_or_foreign_slots_are_refused_before_the_recall(self):
        self.adapter.snapshot = Mock(return_value=self.state)
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('select_preset', {'preset_id': self.target})
        self.assertEqual(caught.exception.code, 'invalid_value')
        self.adapter.list_presets()
        for target in (USBAdapter.preset_id(13), USBAdapter.preset_id(300), '["/opt/factory",1,true,false,false]', 'x', 3, None):
            with self.assertRaises(BridgeError) as caught:
                self.adapter.execute('select_preset', {'preset_id': target})
            self.assertEqual(caught.exception.code, 'invalid_value')
        self.adapter.qc.recall.assert_not_called()

    def test_unsaved_edits_need_an_explicit_discard(self):
        self.adapter.list_presets()
        dirty = dict(self.state, dirty=True)
        self.adapter.state = deepcopy(dirty)
        self.adapter.snapshot = Mock(return_value=dirty)
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('select_preset', {'preset_id': self.target})
        self.assertEqual(caught.exception.code, 'unsaved_changes')
        self.adapter.qc.recall.assert_not_called()
        self.adapter.qc.read_state.return_value = NS(folder_key=usb.MY_PRESETS, position=14, is_factory=False)
        self.adapter.snapshot = Mock(side_effect=[dirty, dict(self.state, preset_id=self.target)])
        self.adapter.execute('select_preset', {'preset_id': self.target, 'discard': True})
        self.adapter.qc.recall.assert_called_once()

    def test_switch_the_qc_never_reports_is_unknown(self):
        self.adapter.list_presets()
        self.adapter.snapshot = Mock(return_value=self.state)
        self.adapter.qc.read_state.return_value = NS(folder_key=usb.MY_PRESETS, position=16, is_factory=False)
        with self.assertRaises(BridgeError) as caught:
            self.adapter.execute('select_preset', {'preset_id': self.target})
        self.assertEqual(caught.exception.code, 'not_confirmed')

    def test_listing_without_my_presets_keeps_the_session(self):
        self.adapter.qc.list_directory.return_value = {'presets': []}
        with self.assertRaises(BridgeError) as caught:
            self.adapter.list_presets()
        self.assertEqual(caught.exception.code, 'not_confirmed')

    def test_helper_lists_without_revision_context(self):
        bridge = Coordinator(self.adapter)
        bridge.session, bridge.state = 's', self.state
        response = bridge.handle({'version': 1, 'type': 'request', 'id': '1', 'operation': 'list_presets', 'session_id': 's'})[0]
        self.assertEqual(response['status'], 'confirmed')
        self.assertEqual(len(response['result']['presets']['entries']), 2)


class SettleTests(TestCase):
    """Scene and preset changes on the QC must not end the session."""
    def setUp(self):
        self.clock = Clock()
        self.adapter = USBAdapter(clock=self.clock, sleep=self.clock.sleep)
        self.adapter.qc = Mock()
        self.reads = 0

    def unsettled(self, times):
        def read():
            self.reads += 1
            if self.reads <= times:
                raise Unsettled('mid-change')
            return {'scene': 'B'}
        self.adapter._snapshot_once = read

    def test_snapshot_waits_out_a_short_change(self):
        self.unsettled(3)
        self.assertEqual(self.adapter.snapshot(), {'scene': 'B'})
        self.assertIsNone(self.adapter.unsettled_since)

    def test_long_change_is_busy_and_keeps_the_session(self):
        self.unsettled(1000)
        with self.assertRaises(BridgeError) as caught:
            self.adapter.snapshot()
        self.assertEqual(caught.exception.code, 'device_busy')
        self.assertLessEqual(self.clock.now, usb.SETTLE_BUDGET + usb.SETTLE_PAUSE)

    def test_qc_that_never_settles_needs_a_reconnect(self):
        self.unsettled(10000)
        with self.assertRaises(RuntimeError):
            for _ in range(10):
                try:
                    self.adapter.snapshot()
                except BridgeError:
                    self.clock.now += 1
        self.assertGreaterEqual(self.clock.now, usb.UNSETTLED_LIMIT)

    def test_removed_qc_fails_at_once_instead_of_looking_busy(self):
        def read():
            raise RuntimeError('the device was removed')
        self.adapter._snapshot_once = read
        with self.assertRaisesRegex(RuntimeError, 'removed'):
            self.adapter.snapshot()
        self.assertEqual(self.clock.now, 0)

    def test_unanswered_reads_and_moving_context_are_unsettled(self):
        position = NS(folder_key='/media/p4/Presets/My Presets', position=16, is_factory=False)
        self.adapter.qc.read_state.side_effect = lambda name: None
        with self.assertRaises(Unsettled):
            self.adapter._snapshot_once()
        scenes = iter([NS(selected_scene=5), NS(selected_scene=1)])
        self.adapter.qc.read_state.side_effect = lambda name: {
            'SetlistPosition': position, 'PresetDirty': NS(is_dirty=False)}.get(name) or next(scenes)
        with self.assertRaisesRegex(Unsettled, 'changed during snapshot'):
            self.adapter._snapshot_once()
