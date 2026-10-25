"""USB input wait behavior without opening hardware."""
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'vendor/qc-mcp/src'))
if sys.platform == 'darwin':
    from qc_mcp.iohid import IOHIDTransport


@unittest.skipUnless(sys.platform == 'darwin', 'IOKit is macOS-only')
class InputWaitTests(unittest.TestCase):
    def test_buffered_reports_return_immediately_and_are_drained_once(self):
        io = IOHIDTransport()
        io._rx.append((1, b'report'))
        with patch.object(io._rx_ready, 'wait', side_effect=AssertionError('unnecessary wait')):
            self.assertEqual(io.read_reports(10), [(1, b'report')])
        self.assertEqual(io.read_reports(0), [])

    def test_input_notification_wakes_waiting_reader(self):
        io = IOHIDTransport()
        waiting = threading.Event()
        original = io._rx_ready.wait

        def wait(timeout=None):
            waiting.set()
            return original(timeout)

        result = []
        with patch.object(io._rx_ready, 'wait', side_effect=wait):
            reader = threading.Thread(target=lambda: result.extend(io.read_reports(5)))
            reader.start()
            try:
                self.assertTrue(waiting.wait(1))
                with io._rx_ready:
                    io._rx.append((1, b'report'))
                    io._rx_ready.notify()
                reader.join(1)
                self.assertFalse(reader.is_alive(), 'input should wake the reader before timeout')
                self.assertEqual(result, [(1, b'report')])
            finally:
                reader.join(6)

    def test_empty_read_times_out(self):
        self.assertEqual(IOHIDTransport().read_reports(.001), [])

    def test_removed_device_fails_reads_and_writes_at_once(self):
        io = IOHIDTransport()
        io.dev = object()  # Never reaches IOKit: the removal check comes first.
        io.removed = True
        with self.assertRaisesRegex(RuntimeError, 'removed'):
            io.set_report(0, b'chunk')
        with patch.object(io._rx_ready, 'wait', side_effect=AssertionError('unnecessary wait')):
            with self.assertRaisesRegex(RuntimeError, 'removed'):
                io.read_reports(10)

    def test_removal_wakes_waiting_reader(self):
        io = IOHIDTransport()
        errors = []

        def read():
            try:
                io.read_reports(5)
            except RuntimeError as error:
                errors.append(error)
        reader = threading.Thread(target=read)
        reader.start()
        with io._rx_ready:
            io.removed = True
            io._rx_ready.notify_all()
        reader.join(1)
        self.assertFalse(reader.is_alive(), 'removal should wake the reader before timeout')
        self.assertEqual(len(errors), 1)
