"""Tuner operations through the helper, the simulator and the USB adapter, without hardware."""
import json
from pathlib import Path
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from patchbridge import usb
from patchbridge.captured import CapturedAdapter
from patchbridge.helper import Coordinator
from patchbridge.read_only import ReadOnlyAdapter
from patchbridge.simulator import SimulatedAdapter
from patchbridge.usb import USBAdapter


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


def request(coordinator, operation, payload=None, **fields):
    return coordinator.handle({'version': 1, 'type': 'request', 'id': operation, 'operation': operation,
                               'payload': payload or {}, **coordinator.context(), **fields})[0]


class SimulatedTunerTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.bridge = Coordinator(SimulatedAdapter(self.clock))
        request(self.bridge, 'connect')

    def test_capabilities_advertise_the_tuner(self):
        operations = request(self.bridge, 'capabilities')['result']['operations']
        self.assertTrue({'tuner', 'tuner_read', 'set_tuner_mute'} <= set(operations))

    def test_readings_are_numbered_so_two_readers_share_the_stream(self):
        started = request(self.bridge, 'tuner', {'mode': 'live'})['result']['tuner']
        self.assertEqual((started['mode'], started['muted'], started['input']), ('live', False, 1))
        self.clock.now += 0.55
        first = request(self.bridge, 'tuner_read', {'after': 0})['result']['tuner']
        self.assertEqual([r['seq'] for r in first['readings']], [1, 2, 3, 4, 5])
        self.assertTrue(all(70 < r['hz'] < 90 for r in first['readings']))
        again = request(self.bridge, 'tuner_read', {'after': 0})['result']['tuner']
        self.assertEqual(again['readings'], first['readings'])
        later = request(self.bridge, 'tuner_read', {'after': first['seq']})['result']['tuner']
        self.assertEqual(later['readings'], [])

    def test_tuner_needs_a_session_but_no_preset_context(self):
        response = request(self.bridge, 'tuner', {'mode': 'open'}, revision=99, scene='Z')
        self.assertEqual(response['status'], 'confirmed')
        self.assertEqual(self.bridge.revision, 0)
        self.assertEqual(request(self.bridge, 'tuner', {'mode': 'open'}, session_id='other')['error']['code'], 'stale_session')

    def test_invalid_requests_are_refused(self):
        self.assertEqual(request(self.bridge, 'tuner', {'mode': 'loud'})['error']['code'], 'invalid_value')
        self.assertEqual(request(self.bridge, 'tuner_read', {'after': -1})['error']['code'], 'invalid_value')
        self.assertEqual(request(self.bridge, 'tuner_read', {'after': True})['error']['code'], 'invalid_value')
        self.assertEqual(request(self.bridge, 'set_tuner_mute', {'value': 1})['error']['code'], 'invalid_value')

    def test_mute_only_while_the_tuner_is_open(self):
        request(self.bridge, 'tuner', {'mode': 'live'})
        self.assertEqual(request(self.bridge, 'set_tuner_mute', {'value': True})['error']['code'], 'tuner_closed')
        request(self.bridge, 'tuner', {'mode': 'open'})
        self.assertTrue(request(self.bridge, 'set_tuner_mute', {'value': True})['result']['tuner']['muted'])
        off = request(self.bridge, 'tuner', {'mode': 'off'})['result']['tuner']
        self.assertEqual((off['mode'], off['muted']), ('off', None))


class ReadOnlyTunerTests(unittest.TestCase):
    def test_captured_fixture_has_no_tuner(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.json'
            path.write_text((Path(__file__).parent / 'fixtures/qc-editor.json').read_text())
            bridge = Coordinator(ReadOnlyAdapter(CapturedAdapter(path)))
            request(bridge, 'connect')
            self.assertNotIn('tuner', request(bridge, 'capabilities')['result']['operations'])
            self.assertEqual(request(bridge, 'tuner', {'mode': 'live'})['error']['code'], 'unsupported_operation')

    def test_read_only_usb_starts_the_tuner_but_never_mutes(self):
        bridge = Coordinator(ReadOnlyAdapter(SimulatedAdapter(Clock())))
        request(bridge, 'connect')
        self.assertEqual(request(bridge, 'tuner', {'mode': 'open'})['status'], 'confirmed')
        self.assertEqual(request(bridge, 'set_tuner_mute', {'value': True})['error']['code'], 'read_only')


class Fields:
    """Stands in for a decoded protobuf message: only the fields the QC set."""
    def __init__(self, **fields):
        self.fields = fields

    def ListFields(self):
        return [(SimpleNamespace(name=k), v) for k, v in self.fields.items()]


PROTOCOL = SimpleNamespace(ACTION={'UPDATE': 1, 'READ': 3},
                           COMMANDS={6: 'Tuner', 13: 'Scene', 27: 'ShowTuner', 33: 'GlobalTempo'},
                           message_class=lambda name: lambda **fields: fields)


class FakeQC:
    def __init__(self):
        self._io_lock = threading.RLock()
        self._pending = []
        self.incoming = []
        self.sent = []
        self.ids = iter(range(1, 1000))

    def next_request_id(self):
        return next(self.ids)

    def send(self, name, message):
        self.sent.append((name, message))

    def _collect(self, seconds):
        with self._io_lock:
            self._pending.extend(self.incoming)
            self.incoming = []
        time.sleep(0.002)

    def close(self):
        pass


class USBTunerTests(unittest.TestCase):
    def setUp(self):
        self.adapter = USBAdapter(protocol=PROTOCOL)
        self.qc = self.adapter.qc = FakeQC()

    def tearDown(self):
        self.adapter._stop_reader()

    def wait_for(self, condition):
        deadline = time.monotonic() + 2
        while not condition():
            self.assertLess(time.monotonic(), deadline, 'timed out')
            time.sleep(0.005)

    def test_modes_send_cortex_controls_sequence(self):
        self.adapter.tuner('open')
        self.assertEqual(self.qc.sent, [
            ('ShowTuner', {'action': 1, 'request_id': 1, 'show': True}),
            ('Tuner', {'action': 1, 'request_id': 2, 'enable_meter': True}),
            ('Tuner', {'action': 3})])
        self.qc.sent.clear()
        self.adapter.tuner('live')
        self.assertEqual(self.qc.sent[0], ('ShowTuner', {'action': 1, 'request_id': 3, 'show': False}))
        self.qc.sent.clear()
        state = self.adapter.tuner('off')
        self.assertEqual(self.qc.sent, [
            ('ShowTuner', {'action': 1, 'request_id': 5, 'show': False}),
            ('Tuner', {'action': 1, 'request_id': 6, 'enable_meter': False})])
        self.assertEqual(state['mode'], 'off')
        self.assertIsNone(self.adapter.reader)

    def test_reader_keeps_pitch_and_state_and_drops_streamed_broadcasts(self):
        scene = (13, Fields(selected_scene=5), b'', b'')
        self.qc.incoming = [
            (6, Fields(action=1, input_port_id=1, frequency=0.0, mute=False), b'', b''),
            (6, Fields(action=1, meter=73.67), b'', b''),
            (33, Fields(bpm=120), b'', b''),
            scene,
            (6, None, b'', b''),
        ]
        self.adapter.tuner('live')
        self.wait_for(lambda: self.adapter.tuning.seq == 1)
        state = self.adapter.tuner_read(0)
        self.assertEqual((state['mode'], state['input'], state['muted']), ('live', 1, False))
        self.assertEqual([r['hz'] for r in state['readings']], [73.67])
        with self.qc._io_lock:
            self.assertEqual(self.qc._pending, [scene])

    def test_mute_waits_for_the_qcs_echo(self):
        self.adapter.tuner('open')
        def echo():
            time.sleep(0.05)
            self.qc.incoming.append((6, Fields(action=1, request_id=3, mute=True), b'', b''))
        threading.Thread(target=echo).start()
        self.assertTrue(self.adapter.set_tuner_mute(True)['muted'])
        self.assertEqual(self.qc.sent[-1], ('Tuner', {'action': 1, 'request_id': 3, 'mute': True}))

    def test_unconfirmed_mute_is_an_error(self):
        self.adapter.tuner('open')
        with patch.object(usb, 'MUTE_TIMEOUT', 0.05):
            with self.assertRaises(usb.BridgeError) as caught:
                self.adapter.set_tuner_mute(True)
        self.assertEqual(caught.exception.code, 'not_confirmed')

    def test_disconnect_turns_the_tuner_off(self):
        self.adapter.tuner('live')
        self.qc.sent.clear()
        self.adapter.disconnect()
        self.assertEqual([name for name, _ in self.qc.sent], ['ShowTuner', 'Tuner'])
        self.assertIsNone(self.adapter.reader)


if __name__ == '__main__':
    unittest.main()
