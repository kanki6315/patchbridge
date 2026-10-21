"""Tuner stream state shared by adapters: the QC's tuner mode and mute, and numbered pitch readings.

Readings carry increasing sequence numbers, so several phones can each read the stream
from their own position without taking readings away from one another.
"""
import threading
import time

from .adapter import BridgeError

MODES = ('off', 'live', 'open')
OPERATIONS = frozenset({'tuner', 'tuner_read', 'set_tuner_mute'})
# Starting and reading the tuner don't change the preset or any setting the QC keeps.
READ_OPERATIONS = frozenset({'tuner', 'tuner_read'})
KEPT = 64
RETURNED = 32


def validate_mode(mode):
    if mode not in MODES:
        raise BridgeError('invalid_value', 'mode must be off, live or open.')
    return mode


def validate_after(after):
    if type(after) is not int or after < 0:
        raise BridgeError('invalid_value', 'after must be a non-negative integer.')
    return after


class TunerBuffer:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.reset()

    def reset(self, mode='off'):
        with self.lock:
            self.mode = mode
            self.muted = None
            self.input = None
            self.seq = 0
            self.reports = 0
            self.readings = []
            self.started = self.clock()

    def set_mode(self, mode):
        with self.lock:
            self.mode = mode

    def add(self, hz):
        """One pitch reading in Hz. Zero means the QC heard no note."""
        with self.lock:
            self.seq += 1
            self.readings.append({'seq': self.seq, 'hz': round(max(0.0, float(hz)), 3),
                                  'ms': int((self.clock() - self.started) * 1000)})
            del self.readings[:-KEPT]

    def report(self, muted=None, input_port=None):
        """The QC's own tuner state: sent when the tuner starts and whenever mute changes."""
        with self.changed:
            if muted is not None:
                self.muted = bool(muted)
            if input_port is not None:
                self.input = int(input_port)
            self.reports += 1
            self.changed.notify_all()

    def wait_for_mute(self, value, after_reports, timeout):
        """True once a state report newer than `after_reports` shows mute at `value`."""
        deadline = self.clock() + timeout
        with self.changed:
            while not (self.reports > after_reports and self.muted == value):
                remaining = deadline - self.clock()
                if remaining <= 0:
                    return False
                self.changed.wait(remaining)
            return True

    def state(self, after=None):
        with self.lock:
            state = {'mode': self.mode, 'muted': self.muted, 'input': self.input, 'seq': self.seq}
            if after is not None:
                state['readings'] = [r for r in self.readings if r['seq'] > after][-RETURNED:]
            return state
