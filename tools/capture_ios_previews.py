#!/usr/bin/env python3
"""Record the shared Debug-only native story on booted portrait simulators."""
import argparse, json, signal, subprocess, time
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, required=True)
p.add_argument('--iphone', required=True)
p.add_argument('--duo', required=True, help='Duo simulator')
p.add_argument('--duo-display', default='primary-1', choices=['primary', 'primary-1'])
p.add_argument('--ipad', required=True)
p.add_argument('--layouts', nargs='+', default=['iphone', 'duo', 'ipad'])
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
bundle = 'com.arjunakankipati.patchbridge'
def sim(*args, check=True):
    return subprocess.run(['xcrun', 'simctl', *args], check=check, capture_output=True, text=True)
manifest_path = a.output / 'capture.json'
manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
for family, device, display in [('iphone', a.iphone, 'primary'), ('duo', a.duo, a.duo_display), ('ipad', a.ipad, 'primary')]:
    if family not in a.layouts: continue
    sim('bootstatus', device, '-b')
    sim('install', device, str(a.app.resolve()))
    sim('status_bar', device, 'override', '--time', '2026-10-21T20:00:00.000Z', '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3', '--cellularMode', 'active', '--cellularBars', '4', '--batteryState', 'discharging', '--batteryLevel', '100')
    sim('terminate', device, bundle, check=False)
    # Warm launch avoids first-run dialogs during the take.
    sim('launch', device, bundle, '--screenshots', '--stage')
    time.sleep(3)
    sim('terminate', device, bundle)
    raw = a.output / (family + '.mov')
    with (a.output / (family + '.log')).open('w') as log:
        proc = subprocess.Popen(['xcrun', 'simctl', 'io', device, 'recordVideo', '--codec=h264', '--display='+display, '--mask=ignored', '--force', str(raw.resolve())], stdout=log, stderr=log)
        try:
            time.sleep(1)
            started = time.monotonic()
            sim('launch', device, bundle, '--screenshots', '--stage', '--preview-story')
            launch_elapsed = time.monotonic() - started
            time.sleep(33)
        finally:
            proc.send_signal(signal.SIGINT)
            proc.wait(timeout=30)
    manifest[family] = {'device': device, 'display': display, 'source': raw.name, 'trim_start': 4 + launch_elapsed, 'duration': 28}
    (a.output / 'capture.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print('Recorded ' + family, flush=True)
