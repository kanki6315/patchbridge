#!/usr/bin/env python3
"""Listen to the QC's tuner stream without sending it any tuner or edit commands.

Answers what a phone tuner needs to know before any USB tuner writes: whether Tuner
messages stream while the tuner is closed, how often they arrive, what frequency and
meter hold, and whether mute follows the toggle on the device. Runs guided phases
and saves every decoded Tuner message plus a per-phase summary.

Close Cortex Control first. Opening the QC uses qc-mcp's usual handshake, version
read and heartbeat, as the other read-only probes do; nothing else is sent.
Run with qc-mcp installed (the usb extra) or its src on PYTHONPATH.
"""
import argparse
from collections import Counter
from datetime import date
import json
from pathlib import Path
import platform
import time

ROOT = Path(__file__).resolve().parents[1]
FIELDS = ('action', 'input_port_id', 'frequency', 'mute', 'enable_meter', 'meter')
PHASES = [
    ('closed', 'Leave the tuner closed. Play a few open strings, then let them ring out.'),
    ('open', 'Open the tuner on the QC. Play a few open strings, then let them ring out.'),
    ('mute', 'With the tuner open, flip its mute toggle on and off a few times.'),
]


def capture(qc, seconds, names, clock=time.monotonic):
    """Every message the QC streams for `seconds`: counts by command and decoded Tuner rows.

    latest_broadcast() keeps one command and leaves the rest queued, so drain the raw
    queue instead; the counts also show what else streams beside the tuner.
    """
    counts, tuner, undecoded = Counter(), [], 0
    qc._pending.clear()
    start = clock()
    while clock() - start < seconds:
        qc._collect(0.25)
        pending, qc._pending = qc._pending, []
        for cmd, obj, _raw, _pb in pending:
            name = names.get(cmd, str(cmd))
            counts[name] += 1
            if name != 'Tuner':
                continue
            if obj is None:
                undecoded += 1
                continue
            row = {'t': round(clock() - start, 3)}
            row.update({f: getattr(obj, f) for f in FIELDS if hasattr(obj, f)})
            tuner.append(row)
    return {'seconds': seconds, 'counts': dict(counts), 'tuner': tuner, 'tuner_undecoded': undecoded}


def summarize(phase):
    """Rate, frequency and meter ranges, and mute changes for one captured phase."""
    rows, seconds = phase['tuner'], phase['seconds']
    freqs = [r['frequency'] for r in rows if r.get('frequency')]
    meters = [r['meter'] for r in rows if 'meter' in r]
    mutes = [r['mute'] for r in rows if 'mute' in r]
    gaps = [b['t'] - a['t'] for a, b in zip(rows, rows[1:])]

    def span(values):
        return [min(values), max(values)] if values else None
    return {
        'tuner_messages': len(rows),
        'tuner_undecoded': phase['tuner_undecoded'],
        'rate_hz': round(len(rows) / seconds, 2) if seconds else None,
        'largest_gap_s': round(max(gaps), 3) if gaps else None,
        'frequency_range': span(freqs),
        'zero_frequency_messages': len(rows) - len(freqs),
        'meter_range': span(meters),
        'mute_values': sorted(set(mutes)),
        'mute_changes': sum(a != b for a, b in zip(mutes, mutes[1:])),
        'enable_meter_values': sorted({r['enable_meter'] for r in rows if 'enable_meter' in r}),
        'input_ports': sorted({r['input_port_id'] for r in rows if 'input_port_id' in r}),
        'actions': sorted({r['action'] for r in rows if 'action' in r}),
        'other_streams': {k: v for k, v in phase['counts'].items() if k != 'Tuner'},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--seconds', type=float, default=20, help='listening time per phase')
    parser.add_argument('--phases', nargs='+', choices=[p for p, _ in PHASES],
                        default=[p for p, _ in PHASES])
    parser.add_argument('--out', type=Path,
                        default=ROOT / f'hardware-results/{date.today().isoformat()}/tuner-probe.json')
    args = parser.parse_args()

    from qc_mcp.transport import QuadCortex
    import qc_mcp.protocol as P
    report = {'host': platform.platform(), 'phases': {}}
    qc = QuadCortex()
    try:
        qc.open()
        report.update(firmware=qc.firmware, protocol=qc.protocol_version,
                      verified=qc.protocol_version_verified, riding=getattr(qc, 'riding', False))
        print(json.dumps({k: report[k] for k in ('firmware', 'verified', 'riding')}), flush=True)
        if qc.firmware != '4.1.1' or not qc.protocol_version_verified:
            raise RuntimeError('Firmware gate failed')
        for name, instruction in PHASES:
            if name not in args.phases:
                continue
            input(f'\n[{name}] {instruction}\nPress Return to listen for {args.seconds:g} s. ')
            phase = capture(qc, args.seconds, P.COMMANDS)
            phase['summary'] = summarize(phase)
            report['phases'][name] = phase
            print(json.dumps(phase['summary'], indent=2), flush=True)
        report['write_errors'] = qc.write_errors
    finally:
        qc.close()
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2))
        print(f'\nSaved {args.out}')


if __name__ == '__main__':
    main()
