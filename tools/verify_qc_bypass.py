"""Reversible bypass off/on through USBAdapter, watched for qc-mcp's queue growing.

Run with Cortex Control and the Patchbridge Mac app closed and the disposable preset
(Tremonti w Mic, My Presets 16) loaded. A monitor thread samples the length
of qc-mcp's pending list. If it grows past PENDING_CAP, or memory past RSS_CAP, the
monitor counts the queued message types, saves them and exits. A watchdog also ends the
run. Nothing is saved on the QC.
  PYTHONPATH=src:vendor/qc-mcp/src .venv-hardware/bin/python tools/verify_qc_bypass.py [block_id]
"""
import collections
import datetime
import json
import os
import resource
import sys
import threading
import time
from pathlib import Path
import qc_mcp.protocol as P
from patchbridge.usb import USBAdapter

WATCHDOG, PENDING_CAP, RSS_CAP, TALLY = 120, 20000, 1.5e9, 5000
r = {'started': datetime.datetime.now().isoformat(timespec='seconds'), 'steps': [], 'samples': []}
out = Path('hardware-results') / datetime.date.today().isoformat() / 'bypass-probe.json'
adapter = USBAdapter()
t0 = time.time()


def save():
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(r, indent=2))


def step(name):
    r['steps'].append([round(time.time() - t0, 2), name])
    print(f'+{time.time() - t0:6.2f}s  {name}', flush=True)


def tally(items):
    types, sizes = collections.Counter(), collections.Counter()
    for item in items:
        name = P.COMMANDS.get(item[0], str(item[0]))
        types[name] += 1
        sizes[name] += len(item[2] or b'')
    return {name: {'count': n, 'average_bytes': sizes[name] // n} for name, n in types.most_common(12)}


def monitor():
    while True:
        time.sleep(0.25)
        qc = adapter.qc
        if qc is None:
            continue
        pending, raw = len(qc._pending), len(qc.io._rx)
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        r['samples'].append([round(time.time() - t0, 2), pending, raw, rss])
        if pending > PENDING_CAP or rss > RSS_CAP:
            r['flood'] = {'at': round(time.time() - t0, 2), 'pending': pending, 'raw_reports': raw, 'rss': rss,
                          'last_step': r['steps'][-1] if r['steps'] else None,
                          'newest': tally(qc._pending[-TALLY:]), 'oldest': tally(qc._pending[:TALLY])}
            save()
            print(json.dumps(r['flood'], indent=2), flush=True)
            print('Flood: exiting. Run tools/probe_qc_stream.py to check the block.', flush=True)
            os._exit(3)


def watchdog():
    r['watchdog'] = True
    save()
    print('Watchdog: exiting. Run tools/probe_qc_stream.py to check the block.', flush=True)
    os._exit(4)


threading.Thread(target=monitor, daemon=True).start()
threading.Timer(WATCHDOG, watchdog).start()
try:
    step('connect')
    adapter.connect()
    step('snapshot')
    state = adapter.snapshot()
    assert state['name'] == 'Tremonti w Mic', f"Load the disposable preset first, not {state['name']!r}"
    scene = state['scene']
    block_id = sys.argv[1] if len(sys.argv) > 1 else '0:2'
    before = next(b for b in state['blocks'] if b['id'] == block_id)['scenes'][scene]['bypass']
    assert before is False, 'Pick a block that is on in the active scene.'
    try:
        step('set_bypass off')
        after = adapter.execute('set_bypass', {'block_id': block_id, 'value': True})
        r['off_confirmed'] = next(b for b in after['blocks'] if b['id'] == block_id)['scenes'][scene]['bypass'] is True
        step(f"off confirmed: {r['off_confirmed']}")
    finally:
        step('set_bypass on')
        after = adapter.execute('set_bypass', {'block_id': block_id, 'value': False})
        r['on_confirmed'] = next(b for b in after['blocks'] if b['id'] == block_id)['scenes'][scene]['bypass'] is False
        step(f"on confirmed: {r['on_confirmed']}")
except Exception as error:
    r['error'] = f'{type(error).__name__}: {error}'
    step(r['error'])
finally:
    step('disconnect')
    adapter.disconnect()
    step('done')
    save()
    os._exit(0 if 'error' not in r else 1)
