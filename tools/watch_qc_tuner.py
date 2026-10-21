#!/usr/bin/env python3
"""Listen to the QC's tuner stream; optionally start it the way Cortex Control does.

Answers what a phone tuner needs to know: whether Tuner messages stream on their own,
how often pitch arrives, and whether mute follows the toggle on the device. Runs
guided phases and saves every decoded Tuner message plus a per-phase summary.

Pitch arrives in the Tuner `meter` field, in Hz, about ten times a second while a note
rings; `frequency` stayed 0 in every capture. The QC only streams it after a host
sends Cortex Control's start sequence (captured 2026-10-20): ShowTuner show, Tuner
UPDATE enable_meter, then Tuner READ. The QC's own screen doesn't change.

Close Cortex Control first. Opening the QC uses qc-mcp's usual handshake, version
read and heartbeat, as the other read-only probes do; by default nothing else is
sent. --live adds one phase that sends the start sequence, listens, then always
sends ShowTuner without show, as Cortex Control does when its tuner closes, plus a
Tuner UPDATE clearing enable_meter, since ShowTuner alone left pitch streaming.
--print-writes shows those messages and exits without opening USB.
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
PHASES = [
    ('closed', 'Leave the tuner closed. Play a few open strings, then let them ring out.'),
    ('open', 'Open the tuner on the QC. Play a few open strings, then let them ring out.'),
    ('mute', 'With the tuner open, flip its mute toggle on and off a few times.'),
]
LIVE_PHASE = ('live', 'Leave the tuner closed on the QC; its screen will not change. After Return the probe\n'
                      'starts the tuner stream; play a few open strings, then let them ring out.')
OFF_SECONDS = 3


def live_tuner(P, next_id, on):
    """Cortex Control's tuner messages. Its READ carries no request_id, so this one
    doesn't either. Cortex Control stops with ShowTuner alone (no `show`, read as
    false), but pitch kept streaming after that, so stopping also clears enable_meter."""
    show = P.message_class('ShowTuner')(action=P.ACTION['UPDATE'], request_id=next_id(), show=on)
    tuner = P.message_class('Tuner')
    meter = tuner(action=P.ACTION['UPDATE'], request_id=next_id(), enable_meter=on)
    if not on:
        return [('ShowTuner', show), ('Tuner', meter)]
    return [('ShowTuner', show), ('Tuner', meter), ('Tuner', tuner(action=P.ACTION['READ']))]


def describe_write(P, command, message):
    """What the probe sends: the fields, the protobuf payload and the full framed message."""
    from google.protobuf.json_format import MessageToDict
    payload = message.SerializeToString()
    return {'command': command,
            'fields': MessageToDict(message, preserving_proto_field_name=True),
            'payload_hex': payload.hex(), 'message_hex': P.encode_message(command, payload).hex()}


def present(obj):
    """Only the fields the QC set: pitch rows carry just `meter`, state rows no `meter`."""
    return {f.name: v for f, v in obj.ListFields()}


def capture(qc, seconds, names, clock=time.monotonic):
    """Every message the QC streams for `seconds`: counts by command and decoded Tuner rows.

    latest_broadcast() keeps one command and leaves the rest queued, so drain the raw
    queue instead; the counts also show what else streams beside the tuner.
    """
    counts, tuner, shown, undecoded = Counter(), [], [], 0
    qc._pending.clear()
    start = clock()
    while clock() - start < seconds:
        qc._collect(0.25)
        pending, qc._pending = qc._pending, []
        for cmd, obj, _raw, _pb in pending:
            name = names.get(cmd, str(cmd))
            counts[name] += 1
            if name == 'ShowTuner' and obj is not None:
                shown.append({'t': round(clock() - start, 3), **present(obj)})
            if name != 'Tuner':
                continue
            if obj is None:
                undecoded += 1
                continue
            tuner.append({'t': round(clock() - start, 3), **present(obj)})
    return {'seconds': seconds, 'counts': dict(counts), 'tuner': tuner, 'tuner_undecoded': undecoded,
            'show_tuner': shown}


def summarize(phase):
    """Pitch rate and range, the state rows' port and mute, and gaps in the pitch stream."""
    rows, seconds = phase['tuner'], phase['seconds']
    pitch = [r for r in rows if 'meter' in r]
    hz = [r['meter'] for r in pitch if r['meter'] > 0]
    mutes = [r['mute'] for r in rows if 'mute' in r]
    gaps = [b['t'] - a['t'] for a, b in zip(pitch, pitch[1:])]

    def span(values):
        return [round(min(values), 2), round(max(values), 2)] if values else None
    return {
        'tuner_messages': len(rows),
        'tuner_undecoded': phase['tuner_undecoded'],
        'pitch_messages': len(pitch),
        'pitch_rate_hz': round(len(pitch) / seconds, 2) if seconds else None,
        'pitch_range_hz': span(hz),
        'zero_pitch_messages': len(pitch) - len(hz),
        'largest_pitch_gap_s': round(max(gaps), 3) if gaps else None,
        'state_messages': len(rows) - len(pitch),
        'frequency_values': sorted({r['frequency'] for r in rows if 'frequency' in r}),
        'mute_values': sorted(set(mutes)),
        'mute_changes': sum(a != b for a, b in zip(mutes, mutes[1:])),
        'input_ports': sorted({r['input_port_id'] for r in rows if 'input_port_id' in r}),
        'show_tuner': phase['show_tuner'],
        'other_streams': {k: v for k, v in phase['counts'].items() if k != 'Tuner'},
    }


def send_writes(qc, P, report, writes):
    for command, message in writes:
        entry = describe_write(P, command, message)
        errors = qc.write_errors
        qc.send(command, message)
        entry['write_errors'] = qc.write_errors - errors
        report['writes'].append(entry)
        print(f'Sent {command} {entry["fields"]}: {entry["payload_hex"]}', flush=True)


def live_phase(qc, P, report, seconds):
    """Start the stream, listen, then always stop it and listen briefly to see it end."""
    name, instruction = LIVE_PHASE
    input(f'\n[{name}] {instruction}\nPress Return to start it and listen for {seconds:g} s. ')
    try:
        send_writes(qc, P, report, live_tuner(P, qc.next_request_id, True))
        phase = capture(qc, seconds, P.COMMANDS)
        phase['summary'] = summarize(phase)
        report['phases'][name] = phase
        print(json.dumps(phase['summary'], indent=2), flush=True)
    finally:
        send_writes(qc, P, report, live_tuner(P, qc.next_request_id, False))
    phase = capture(qc, OFF_SECONDS, P.COMMANDS)
    phase['summary'] = summarize(phase)
    report['phases'][f'{name}_off'] = phase
    print(f'\n[{name}_off] {phase["summary"]["pitch_messages"]} pitch messages in '
          f'{OFF_SECONDS} s after stopping. Keep playing during this window to tell a stop from silence.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--seconds', type=float, default=20, help='listening time per phase')
    parser.add_argument('--phases', nargs='*', choices=[p for p, _ in PHASES],
                        default=[p for p, _ in PHASES], help='listen-only phases; pass none to skip them')
    parser.add_argument('--live', action='store_true',
                        help="add a phase that starts the tuner stream with Cortex Control's sequence, then stops it")
    parser.add_argument('--print-writes', action='store_true',
                        help='print the messages --live sends and exit without opening USB')
    parser.add_argument('--out', type=Path,
                        default=ROOT / f'hardware-results/{date.today().isoformat()}/tuner-probe.json')
    args = parser.parse_args()

    import qc_mcp.protocol as P
    if args.print_writes:
        P.set_version('4.1.1')
        ids = iter(range(1, 100))
        for label, on in (('start', True), ('stop', False)):
            print(label, json.dumps([describe_write(P, *w) for w in live_tuner(P, lambda: next(ids), on)], indent=2))
        print('request_id is the next one in the session at run time, so its bytes change.')
        return
    from qc_mcp.transport import QuadCortex
    report = {'host': platform.platform(), 'phases': {}, 'writes': []}
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
        if args.live:
            live_phase(qc, P, report, args.seconds)
        report['write_errors'] = qc.write_errors
    finally:
        qc.close()
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2))
        print(f'\nSaved {args.out}')


if __name__ == '__main__':
    main()
