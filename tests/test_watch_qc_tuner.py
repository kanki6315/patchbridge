"""Tuner probe capture and summary against a fake QC; never opens USB."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('watch_qc_tuner', ROOT / 'tools/watch_qc_tuner.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

NAMES = {6: 'Tuner', 26: 'CPULoad'}


def tuner(frequency, mute=False, meter=0.5):
    return SimpleNamespace(action=1, input_port_id=0, frequency=frequency, mute=mute,
                           enable_meter=True, meter=meter)


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
    def test_capture_keeps_tuner_rows_and_counts_other_streams(self):
        qc = FakeQC([
            [(6, tuner(110.0), b'', b''), (26, object(), b'', b'')],
            [(6, None, b'', b''), (6, tuner(0.0, mute=True, meter=0.1), b'', b'')],
            [(6, tuner(82.4, mute=False, meter=0.9), b'', b'')],
            [(6, tuner(82.5), b'', b'')],
        ])
        qc._pending = [(6, tuner(999.0), b'', b'')]  # stale, queued before listening
        phase = watch.capture(qc, 1.0, NAMES, clock=qc.clock)
        self.assertEqual(phase['counts'], {'Tuner': 5, 'CPULoad': 1})
        self.assertEqual([r['frequency'] for r in phase['tuner']], [110.0, 0.0, 82.4, 82.5])
        self.assertEqual(phase['tuner'][0]['t'], 0.25)

        summary = watch.summarize(phase)
        self.assertEqual(summary['tuner_messages'], 4)
        self.assertEqual(summary['tuner_undecoded'], 1)
        self.assertEqual(summary['rate_hz'], 4.0)
        self.assertEqual(summary['frequency_range'], [82.4, 110.0])
        self.assertEqual(summary['zero_frequency_messages'], 1)
        self.assertEqual(summary['meter_range'], [0.1, 0.9])
        self.assertEqual(summary['mute_values'], [False, True])
        self.assertEqual(summary['mute_changes'], 2)
        self.assertEqual(summary['other_streams'], {'CPULoad': 1})

    def test_silent_phase_reports_no_tuner_stream(self):
        qc = FakeQC([[(26, object(), b'', b'')]])
        summary = watch.summarize(watch.capture(qc, 0.5, NAMES, clock=qc.clock))
        self.assertEqual(summary['tuner_messages'], 0)
        self.assertIsNone(summary['frequency_range'])
        self.assertIsNone(summary['largest_gap_s'])


if __name__ == '__main__':
    unittest.main()
