"""Read-only USB sync benchmark. Quit Patchbridge/Cortex Control before running.

PYTHONPATH=src:vendor/qc-mcp/src python tools/benchmark_sync.py --output results.json
Reports timings and sizes only, never preset contents or device identifiers.
"""
import argparse
from collections import defaultdict
from contextlib import contextmanager
import json
import math
from pathlib import Path
import statistics
import time

from patchbridge.usb import USBAdapter
from qc_mcp import transport


def summary(values):
    ordered = sorted(values)
    return {'count': len(values), 'median_ms': statistics.median(values),
            'p95_ms': ordered[math.ceil(len(ordered) * .95) - 1],
            'min_ms': ordered[0], 'max_ms': ordered[-1]}


class Measurements:
    def __init__(self):
        self.phase = 'startup'
        self.values = defaultdict(lambda: defaultdict(list))

    @contextmanager
    def measure(self, name):
        start = time.perf_counter()
        try:
            yield
        finally:
            self.values[self.phase][name].append((time.perf_counter() - start) * 1000)

    def wrap(self, obj, method, label):
        original = getattr(obj, method)

        def timed(*args, **kwargs):
            with self.measure(label(*args, **kwargs)):
                return original(*args, **kwargs)
        setattr(obj, method, timed)

    def report(self):
        return {phase: {name: summary(values) for name, values in steps.items()}
                for phase, steps in self.values.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--poll-ms', type=float, nargs='+', default=[10, 5, 1, 10])
    parser.add_argument('--directory', action='store_true', help='Also time the optional preset directory read')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1 or any(not math.isfinite(p) or p <= 0 for p in args.poll_ms):
        parser.error('samples and poll intervals must be positive')
    metrics = Measurements()
    report = {'samples_per_condition': args.samples, 'conditions': [],
              'scope': 'USB adapter and in-process serialization; excludes BLE and phone rendering'}

    def factory():
        qc = transport.QuadCortex()
        metrics.wrap(qc, 'open', lambda *a, **k: 'open_handshake_version')
        metrics.wrap(qc, 'read_state', lambda name, **k: 'read_' + name)
        metrics.wrap(qc, 'get_current_preset', lambda *a, **k: 'read_preset')
        return qc

    adapter = USBAdapter(factory=factory)
    original_poll = transport.REPLY_POLL_S
    try:
        with metrics.measure('connect_total'):
            identity = adapter.connect()
        report['firmware'] = identity['firmware']
        with metrics.measure('first_snapshot'):
            state = adapter.snapshot()
        report['block_count'] = len(state['blocks'])
        print('Connected; startup measured.', flush=True)
        for index, poll_ms in enumerate(args.poll_ms):
            transport.REPLY_POLL_S = poll_ms / 1000
            metrics.phase = f'{index + 1}:poll_{poll_ms:g}ms'
            changed = 0
            cpu_start = time.process_time()
            wall_start = time.perf_counter()
            for _ in range(args.samples):
                previous = state
                with metrics.measure('snapshot_total'):
                    state = adapter.snapshot()
                with metrics.measure('state_comparison'):
                    changed += state != previous
                with metrics.measure('json_encode'):
                    encoded = json.dumps(state, separators=(',', ':')).encode()
                with metrics.measure('json_decode'):
                    json.loads(encoded)
            report['conditions'].append({'phase': metrics.phase,
                'cpu_seconds': time.process_time() - cpu_start,
                'wall_seconds': time.perf_counter() - wall_start,
                'state_changes': changed, 'snapshot_bytes': len(encoded),
                'pending_messages': len(adapter.qc._pending),
                'write_errors': adapter.qc.write_errors})
            print(json.dumps({'phase': metrics.phase,
                              'snapshot': metrics.report()[metrics.phase]['snapshot_total']}), flush=True)
        metrics.phase = 'catalog'
        with metrics.measure('catalog_copy'):
            catalog = adapter.catalog()
        with metrics.measure('catalog_json_encode'):
            report['catalog_bytes'] = len(json.dumps(catalog, separators=(',', ':')).encode())
        if args.directory:
            metrics.phase = 'directory'
            with metrics.measure('list_presets'):
                report['preset_count'] = len(adapter.list_presets()['entries'])
    except Exception as error:
        report['error_type'] = type(error).__name__
        raise
    finally:
        transport.REPLY_POLL_S = original_poll
        try:
            adapter.disconnect()
        finally:
            report['timings'] = metrics.report()
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
