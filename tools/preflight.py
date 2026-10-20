#!/usr/bin/env python3
"""Offline-only release preflight. Never invokes live USB, BLE, or network tools."""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'dist/Patchbridge Offline.app'


class CheckFailure(ValueError):
    pass


def run_check(name, action):
    started = time.monotonic()
    try:
        action()
        status = 'passed'; reason = None
    except (Exception, SystemExit) as error:
        # Do not export exception strings, paths, subprocess output, or fixture contents.
        status = 'failed'
        allowed = {'dependency_pin_mismatch', 'runtime_policy_mismatch', 'build_provenance_missing', 'build_inputs_changed'}
        reason = str(error) if isinstance(error, CheckFailure) and str(error) in allowed else (
            'check_timeout' if isinstance(error, subprocess.TimeoutExpired) else
            'missing_input' if isinstance(error, FileNotFoundError) else 'check_failed')
    result = {'check': name, 'status': status, 'duration_ms': round((time.monotonic() - started) * 1000)}
    if reason: result['reason_code'] = reason
    return result


def command(args, timeout=120, env=None):
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen(args, cwd=ROOT, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        if code:
            raise RuntimeError('Check failed')


def freshness():
    manifest = json.loads((APP / 'Contents/Resources/build-manifest.json').read_text())
    if manifest['bundled_usb']['qc_mcp_commit'] != 'f634ecd3dcf426090b90bc4cc176e4b500494b9e':
        raise CheckFailure('dependency_pin_mismatch')
    if manifest['bundled_usb']['protobuf'] != '7.36.2' or manifest['bundled_usb']['hardware_enabled'] is not False:
        raise CheckFailure('runtime_policy_mismatch')
    inputs = manifest.get('build_inputs', {})
    required = {'tools/package_mac.py', 'mac/helper_launcher.c', 'mac/main.swift',
                'src/patchbridge/read_only.py', 'swift/Sources/PatchbridgeCore/Diagnostics.swift'}
    if not required.issubset(inputs):
        raise CheckFailure('build_provenance_missing')
    for relative, expected in inputs.items():
        path = (ROOT / relative).resolve()
        if not path.is_relative_to(ROOT.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise CheckFailure('build_inputs_changed')


def make_report(checks):
    passed = all(check['status'] == 'passed' for check in checks) and bool(checks)
    return {'schema_version': 1, 'offline_only': True, 'preset_contents_included': False,
            'result': 'offline_checks_passed' if passed else 'blocked',
            'hardware_validated': False, 'checks': checks,
            'not_tested': ['Physical USB enumeration and firmware identification',
                           'Read-only comparison against the connected QC display',
                           'Physical unplug/reconnect and Bluetooth recovery',
                           'Parameter display calibration and hardware writes',
                           'Designed screen integration and distribution signing'],
            'next_step': 'Schedule a user-present read-only hardware session; live USB remains disabled in the app.'
                         if passed else 'Resolve failed checks and rebuild before hardware testing.'}


def save_report(report, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.preflight-', dir=destination.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(report, stream, indent=2); stream.write('\n')
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, default=ROOT / 'dist/Preflight.json')
    args = parser.parse_args()
    environment = dict(os.environ, PATCHBRIDGE_TEST_BUNDLE='1', PYTHON_BIN=sys.executable)
    checks = []
    tasks = [
        ('package_provenance_and_pinned_dependencies', freshness),
        ('app_signature', lambda: command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)])),
        ('relocated_runtime_schemas_read_only_policy_and_private_export',
         lambda: command([sys.executable, 'tools/check_mac_package.py'])),
        ('fixture_matrix_and_process_recovery',
         lambda: command(['sh', 'tools/check_offline.sh'], timeout=180, env=environment)),
    ]
    for name, action in tasks:
        print('Checking ' + name + '…', flush=True)
        if len(checks) >= 2 and any(check['status'] != 'passed' for check in checks[:2]):
            checks.append({'check': name, 'status': 'not_run', 'reason': 'Package provenance/signature prerequisite failed.'})
        else:
            checks.append(run_check(name, action))
        print(checks[-1]['status'].upper(), flush=True)
    report = make_report(checks)
    save_report(report, args.report)
    print(report['result'] + '; hardware remains untested.', flush=True)
    return 0 if report['result'] == 'offline_checks_passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
