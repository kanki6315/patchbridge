#!/usr/bin/env python3
"""Capture seven matching native screens per device layout using the website's offline Dirty Riffage fixture.

Build Debug first; supply booted iPhone, iPad and Duo simulator UDIDs.
All simulated edits stay local. No Bluetooth connection is started.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iphone', required=True)
parser.add_argument('--ipad', required=True)
parser.add_argument('--duo', required=True)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--layouts', nargs='+', choices=['iphone', 'ipad', 'duo-folded', 'duo-unfolded'], default=['iphone', 'ipad', 'duo-folded'], help='Duo posture must match the requested layout in Device Hub')
parser.add_argument('--features', nargs='*', help='Optionally recapture only the numbered feature prefixes, e.g. 02 07')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
bundle = 'com.arjunakankipati.patchbridge'

def sim(*command, check=True):
    return subprocess.run(['xcrun', 'simctl', *command], check=check)

for device in (args.iphone, args.ipad, args.duo):
    sim('install', device, str(args.app.resolve()))
    sim('status_bar', device, 'override', '--time', '2026-10-21T20:00:00.000Z',
        '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3',
        '--cellularMode', 'active', '--cellularBars', '4',
        '--batteryState', 'discharging', '--batteryLevel', '100')

# Keep feature names and launch states identical across all three device families.
shots = [
    ('01-overview', 'Preset overview', []),
    ('02-editor', 'Parameter editor', ['--editor']),
    ('03-exact-value', 'Exact-value entry', ['--editor', '--exact-value']),
    ('04-tuner', 'Full tuner', ['--tuner']),
    ('05-daylight', 'Daylight overview', ['--daylight']),
    ('06-save-confirmation', 'Save confirmation', ['--save-confirmation']),
    ('07-preset-live-tuner', 'Preset with live tuner', ['--live-tuner']),
]
manifest = {'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'clock': '4:00 PM America/New_York',
            'fixture': 'tests/fixtures/demo-preset.json',
            'mode': 'Debug screenshot fixture; normal connected UI; local writes only',
            'screenshots': []}
for family, device, display in [('iphone', args.iphone, 'primary'), ('ipad', args.ipad, 'primary'),
                                 ('duo-folded', args.duo, 'primary'), ('duo-unfolded', args.duo, 'primary-1')]:
    if family not in args.layouts:
        continue
    folder = args.output / family
    folder.mkdir(exist_ok=True)
    for name, title, flags in shots:
        file = folder / (name + '.png')
        if not args.features or name[:2] in args.features or not file.exists():
            sim('terminate', device, bundle, check=False)
            sim('launch', device, bundle, '--screenshots', '--stage', *flags)
            time.sleep(3)  # Finish launch and native sheet/popover animations.
            sim('io', device, 'screenshot', '--display', display, '--mask', 'black', str(file.resolve()))
        manifest['screenshots'].append({'device': family, 'feature': title,
                                        'file': str(file.relative_to(args.output)), 'arguments': flags})
manifest_path = args.output / 'manifest.json'
if manifest_path.exists():
    previous = json.loads(manifest_path.read_text())
    manifest['screenshots'] += [item for item in previous['screenshots'] if item['device'] not in args.layouts]
(args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
