"""Tuner probe capture and summary against a fake QC; never opens USB."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('watch_qc_tuner', ROOT / 'tools/watch_qc_tuner.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

NAMES = {6: 'Tuner', 26: 'CPULoad', 27: 'ShowTuner'}


class Message:
    """Stands in for a protobuf message: ListFields() returns only what was set."""
    def __init__(self, **fields):
        self.fields = fields

    def ListFields(self):
        return [(SimpleNamespace(name=k), v) for k, v in self.fields.items()]


def pitch(hz):
    return Message(action=1, meter=hz)


def state(mute=False):
    return Message(action=1, input_port_id=1, frequency=0.0, mute=mute)


class FakeQC:
    """Each _collect() advances the clock 0.25 s and queues the next batch."""
    def __init__(self, batches):
        self.batches, self.now, self._pending = list(batches), 0.0, []

    def clock(self):
        return self.now

    def _collect(self, seconds):
        self.now += seconds
        if self.batches:
            self._pending.extend(self.batches.pop(0))


class TunerProbeTests(unittest.TestCase):
    def test_capture_splits_state_from_pitch_and_counts_other_streams(self):
        qc = FakeQC([
            [(6, state(), b'', b''), (26, object(), b'', b'')],
            [(6, None, b'', b''), (6, pitch(73.4), b'', b''), (6, state(mute=True), b'', b'')],
            [(6, pitch(0.0), b'', b'')],
            [(6, pitch(196.07), b'', b''), (27, Message(action=1, show=True), b'', b'')],
        ])
        qc._pending = [(6, pitch(999.0), b'', b'')]  # stale, queued before listening
        phase = watch.capture(qc, 1.0, NAMES, clock=qc.clock)
        self.assertEqual(phase['counts'], {'Tuner': 6, 'CPULoad': 1, 'ShowTuner': 1})
        self.assertEqual(phase['show_tuner'], [{'t': 1.0, 'action': 1, 'show': True}])
        self.assertEqual(phase['tuner'][1], {'t': 0.5, 'action': 1, 'meter': 73.4})

        summary = watch.summarize(phase)
        self.assertEqual(summary['tuner_undecoded'], 1)
        self.assertEqual((summary['pitch_messages'], summary['state_messages']), (3, 2))
        self.assertEqual(summary['pitch_rate_hz'], 3.0)
        self.assertEqual(summary['pitch_range_hz'], [73.4, 196.07])
        self.assertEqual(summary['zero_pitch_messages'], 1)
        self.assertEqual(summary['largest_pitch_gap_s'], 0.25)
        self.assertEqual(summary['frequency_values'], [0.0])
        self.assertEqual((summary['mute_values'], summary['mute_changes']), ([False, True], 1))
        self.assertEqual(summary['input_ports'], [1])
        self.assertEqual(summary['other_streams'], {'CPULoad': 1, 'ShowTuner': 1})

    def test_silent_phase_reports_no_pitch(self):
        qc = FakeQC([[(26, object(), b'', b'')]])
        summary = watch.summarize(watch.capture(qc, 0.5, NAMES, clock=qc.clock))
        self.assertEqual(summary['pitch_messages'], 0)
        self.assertIsNone(summary['pitch_range_hz'])
        self.assertIsNone(summary['largest_pitch_gap_s'])

    def test_live_sequence_matches_cortex_control(self):
        P = SimpleNamespace(ACTION={'UPDATE': 1, 'READ': 3},
                            message_class=lambda name: lambda **fields: (name, fields))
        ids = iter(range(8, 20))
        start = watch.live_tuner(P, lambda: next(ids), True)
        stop = watch.live_tuner(P, lambda: next(ids), False)
        self.assertEqual([m for _, m in start], [
            ('ShowTuner', {'action': 1, 'request_id': 8, 'show': True}),
            ('Tuner', {'action': 1, 'request_id': 9, 'enable_meter': True}),
            ('Tuner', {'action': 3}),
        ])
        self.assertEqual([m for _, m in stop], [
            ('ShowTuner', {'action': 1, 'request_id': 10, 'show': False}),
            ('Tuner', {'action': 1, 'request_id': 11, 'enable_meter': False}),
        ])


if __name__ == '__main__':
    unittest.main()
