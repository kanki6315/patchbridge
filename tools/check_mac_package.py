#!/usr/bin/env python3
"""Offline relocation, isolation, lifecycle and missing-helper checks. Never starts the UI/radio."""
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / 'dist' / 'Patchbridge.app'
    if not source.is_dir():
        raise SystemExit('Build first: /opt/homebrew/bin/python3 tools/package_mac.py')
    with tempfile.TemporaryDirectory(prefix='patchbridge moved ') as directory:
        temporary = Path(directory)
        app = temporary / 'Moved App.app'
        shutil.copytree(source, app)
        home = temporary / 'empty-home'; home.mkdir()
        # These files would break startup if cwd/PYTHONPATH/user imports were honored.
        (temporary / 'sitecustomize.py').write_text('raise RuntimeError("ambient Python imported")\n')
        (temporary / 'patchbridge.py').write_text('raise RuntimeError("ambient helper imported")\n')
        env = {'PATH': '/nonexistent', 'HOME': str(home), 'LANG': 'en_US.UTF-8',
               'PYTHONHOME': '/nonexistent', 'PYTHONPATH': str(temporary),
               'PYTHONUSERBASE': str(temporary)}
        host = app / 'Contents' / 'MacOS' / 'Patchbridge'
        helper = host.with_name('patchbridge-helper')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == 'com.arjunakankipati.patchbridge'
        assert info['CFBundleIconName'] == 'AppIcon'
        assert info['NSBluetoothAlwaysUsageDescription']
        assert (app / 'Contents/Resources/AppIcon.icns').is_file()
        assert (app / 'Contents/Resources/Assets.car').is_file()
        # Starting the USB helper alone must not open a device; only a connect request does.
        idle_usb = subprocess.run([str(helper), '--usb'], input='', env=env, cwd=temporary,
                                  text=True, capture_output=True, timeout=10)
        assert idle_usb.returncode == 0 and not idle_usb.stdout
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        subprocess.run([str(host), '--self-test'], env=env, cwd=temporary, check=True, timeout=20)
        fixtures = temporary / 'captured inputs'
        for name in ('hardware-results/2026-10-20/initial-preset.bin',
                     'hardware-results/2026-10-20/initial-preset.json',
                     'hardware-results/2026-10-20/live-ModelRepo.xml', 'tests/fixtures/qc-editor.json'):
            target = fixtures / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        checked = subprocess.run([str(helper), '--verify-usb-fixtures', str(fixtures)],
                                 env=env, cwd=temporary, text=True, capture_output=True, timeout=20)
        assert checked.returncode == 0, checked.stderr
        report = json.loads(checked.stdout)
        assert report['status'] == 'passed' and report['hardware_access'] is False
        assert len(report['checks']) == 9 and report['blocks'] == 16 and report['models'] == 11
        print('PASS: bundled USB/protobuf closure; 9 captured-fixture checks through in-memory HID')
        rejected = subprocess.run([str(helper), '--adapter', 'usb'], env=env, cwd=temporary,
                                  capture_output=True, text=True, timeout=10)
        assert rejected.returncode == 64 and 'Expected --usb' in rejected.stderr
        descriptors = app / 'Contents/Resources/Helper/qc_mcp/descriptors/qc_descriptors-4.1.pb'
        original = descriptors.read_bytes()
        descriptors.unlink()
        broken = subprocess.run([str(helper), '--verify-usb-fixtures', str(fixtures)],
                                env=env, cwd=temporary, capture_output=True, text=True, timeout=20)
        assert broken.returncode != 0, 'Missing bundled schema did not fail'
        descriptors.write_bytes(original)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        report_path = temporary / 'troubleshooting.json'
        subprocess.run([str(host), '--export-report', str(report_path)], env=env, cwd=temporary, check=True, timeout=20)
        exported = json.loads(report_path.read_text())
        assert exported['schemaVersion'] == 1 and exported['presetContentsIncluded'] is False
        assert any(event['event'] == 'requestConfirmed' for event in exported['events'])
        assert all(secret not in report_path.read_text() for secret in (str(temporary), 'Tremonti', 'amp-1', '7.5', 'session_id'))
        assert report_path.stat().st_mode & 0o777 == 0o600
        request = json.dumps({'version': 1, 'type': 'request', 'id': 'offline', 'operation': 'connect'}) + '\n'
        # EOF must stop the isolated helper without any parent or terminal intervention.
        result = subprocess.run([str(helper)], input=request, text=True, capture_output=True,
                                env=env, cwd=temporary, check=True, timeout=10)
        response = json.loads(result.stdout)
        assert response['status'] == 'confirmed', result
        assert response['result']['device']['compatibility'] == 'simulation_only'
        assert not list(app.rglob('*.pyc')), 'Runtime wrote into signed bundle'
        # A broken package must fail rather than using a developer's installed Python.
        helper.rename(helper.with_name('disabled-helper'))
        result = subprocess.run([str(host), '--self-test'], env=env, cwd=temporary,
                                capture_output=True, text=True, timeout=10)
        assert result.returncode != 0, 'Missing helper silently fell back to an external runtime'
        assert 'failed' in result.stderr, result
        subprocess.run([str(host), '--export-report', str(report_path)], env=env, cwd=temporary, check=True, timeout=20)
        exported = json.loads(report_path.read_text())
        assert any(event['event'] == 'helperStartFailed' for event in exported['events'])
        print('PASS: private report export succeeds even when bundled helper is missing')
        print('PASS: moved signed bundle; empty PATH; hostile Python environment ignored; EOF exit; missing helper fails closed')


if __name__ == '__main__':
    main()
