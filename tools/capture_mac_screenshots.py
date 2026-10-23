#!/usr/bin/env python3
"""Render five 2880x1800 macOS previews from native views and offline website fixtures."""
import argparse
from pathlib import Path
import subprocess
import zipfile
import plistlib
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['HelperClient', 'Diagnostics', 'DeviceSession', 'SharedUSBSession', 'DeviceIdentity',
           'MacBridgeModel', 'GenericEditor', 'MacDesktopServices', 'Chunks',
           'BLEPeripheral', 'CentralRouter', 'LiveBridgeBackend']

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'output/mac-screenshots')
    parser.add_argument('--prepare-replay', action='store_true', help='Build a native fixture app for manual screen recording')
    args = parser.parse_args()
    build = ROOT / 'build/mac-screenshots'
    build.mkdir(parents=True, exist_ok=True)
    binary = build / 'PatchbridgeScreenshotRenderer'
    subprocess.run(['xcrun', 'swiftc', '-D', 'DEBUG', '-target', 'arm64-apple-macosx26.0',
                    '-module-cache-path', '/private/tmp/patchbridge-screenshot-module-cache',
                    '-framework', 'AppKit',
                    *[str(ROOT / f'swift/Sources/PatchbridgeCore/{name}.swift') for name in SOURCES],
                    str(ROOT / 'mac/ScreenshotPreview.swift'), str(ROOT / 'mac/main.swift'),
                    '-o', str(binary)], check=True)
    if args.prepare_replay:
        bundle = build / 'Patchbridge.app'
        executable = bundle / 'Contents/MacOS/Patchbridge'
        executable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, executable)
        with (bundle / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleExecutable': 'Patchbridge', 'CFBundleIdentifier': 'com.arjunakankipati.patchbridge',
                          'CFBundleName': 'Patchbridge', 'CFBundlePackageType': 'APPL',
                          'NSHighResolutionCapable': True}, f)
        # The fixture launcher reads paths compiled beside its executable, not personal preferences.
        (bundle / 'Contents/Resources').mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'tests/fixtures/demo-preset.json', bundle / 'Contents/Resources/recording-fixture.json')
        print(f'Prepared recording fixture: {bundle}')
        return
    subprocess.run([str(binary), '--render-screenshots', str(ROOT / 'tests/fixtures/demo-preset.json'),
                    str(args.output.resolve())], check=True)
    subprocess.run(['node', str(ROOT / 'tools/render_mac_previews.mjs'), str(args.output.resolve())], check=True)
    previews = sorted(args.output.glob('0*.png'))
    if len(previews) != 5:
        raise RuntimeError('Expected exactly five previews')
    with zipfile.ZipFile(str(args.output) + '.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for preview in previews:
            archive.write(preview, preview.name)
        archive.write(ROOT / 'docs/MAC_SCREENSHOTS.md', 'README.md')
    print(f'Packaged {len(previews)} previews: {args.output}.zip')

if __name__ == '__main__':
    main()
