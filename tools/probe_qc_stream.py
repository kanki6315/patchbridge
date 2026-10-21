"""Read-only, bounded look at what the QC is streaming, then one preset read.

Counts incoming message types for a few seconds without keeping them, so a flood can't
grow memory, and exits on its own after WATCHDOG seconds. Writes nothing to the QC.
  PYTHONPATH=vendor/qc-mcp/src .venv-hardware/bin/python tools/probe_qc_stream.py [row:col]
"""
import collections
import json
import os
import sys
import threading
import time
from qc_mcp.transport import QuadCortex
import qc_mcp.protocol as P

WATCHDOG, SAMPLE, DECODE_CAP, SANE_PER_SECOND = 40, 3.0, 5000, 2000
threading.Timer(WATCHDOG, lambda: (print('Watchdog: exiting', flush=True), os._exit(3))).start()
block = sys.argv[1] if len(sys.argv) > 1 else '0:2'
row, column = map(int, block.split(':'))
qc = QuadCortex()
r = {'block': block}
try:
    qc.open()
    r['firmware'] = qc.firmware
    counts, decoded, reports = collections.Counter(), 0, 0
    end = time.time() + SAMPLE
    while time.time() < end:
        for _id, data in qc.io.read_reports(0.05):
            reports += 1
            for raw in qc._rx.feed(data, has_report_id=True):
                if decoded < DECODE_CAP:
                    counts[P.COMMANDS.get(P.decode_message(raw)[0], 'unknown')] += 1
                decoded += 1
    r.update(reports_per_second=round(reports / SAMPLE), messages_per_second=round(decoded / SAMPLE),
             message_types=dict(counts.most_common(12)))
    qc._pending.clear()
    if decoded / SAMPLE < SANE_PER_SECOND:
        bp = qc.get_current_preset()
        scene = qc.read_state('Scene').selected_scene
        flags = [f.bypass for f in bp.bypass[row].colBypass[column].sceneBypass[:8]]
        r.update(preset=bp.name, scene=chr(65 + scene), model=bp.chains[row].models[column].hash,
                 bypass_by_scene={chr(65 + i): f for i, f in enumerate(flags)})
    else:
        r['skipped_preset_read'] = 'Stream rate too high to read safely.'
finally:
    qc.close()
    print(json.dumps(r, indent=2), flush=True)
    os._exit(0)
