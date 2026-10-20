"""Exercise the release workflow with stub build/signing tools; never contacts Apple."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy(ROOT / 'release.sh', self.root)
        (self.root / 'tools').mkdir()
        shutil.copy(ROOT / 'tools/test_destination.py', self.root / 'tools')
        (self.root / 'ios').mkdir()
        shutil.copy(ROOT / 'ios/project.yml', self.root / 'ios/project.yml')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.events = self.root / 'events.jsonl'
        stub = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['EVENTS'], 'a') as f: f.write(json.dumps([name, *args]) + '\\n')
if name == 'git':
    if args[:1] == ['status']:
        if os.environ.get('DIRTY') == '1': print(' M changed.swift')
    elif args[:2] == ['rev-parse', '--short']: print('abc1234')
    elif args[:2] == ['rev-parse', '--verify']: sys.exit(1)
if name == 'xcodebuild' and args and args[0] == os.environ.get('FAIL_STAGE'): sys.exit(37)
if name == 'swift' and os.environ.get('FAIL_STAGE') == 'swift': sys.exit(37)
if name == 'xcrun': print(os.environ['SIMULATORS'])
if name == 'xcodebuild' and args[0] == '-showdestinations':
    print(os.environ['DESTINATIONS'])
'''
        for name in ['git', 'xcodegen', 'xcodebuild', 'swift', 'xcrun']:
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        (self.root / 'tests').mkdir()
        (self.root / 'tests/test_placeholder.py').write_text(
            'import unittest\n'
            'class Placeholder(unittest.TestCase):\n'
            '    def test_placeholder(self): pass\n'
        )
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('ASC_', 'RELEASE_', 'DEVELOPMENT_TEAM', 'TEST_DESTINATION'))}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ['PATH'], DEVELOPER_DIR=str(self.root), EVENTS=str(self.events))
        self.phone_id = '61DF595A-B275-4365-A863-DBBBAB8D5169'
        self.env['SIMULATORS'] = json.dumps({
            'devicetypes': [{'identifier': 'phone', 'productFamily': 'iPhone'}],
            'devices': {'iOS-27': [{
                'udid': self.phone_id, 'name': 'Patchbridge iPhone Review',
                'isAvailable': True, 'deviceTypeIdentifier': 'phone',
            }]},
        })
        self.env['DESTINATIONS'] = (
            f'{{ platform:iOS Simulator, arch:arm64, id:{self.phone_id}, '
            'OS:27.0, name:Patchbridge iPhone Review }'
        )

    def run_release(self, *args):
        return subprocess.run(['bash', str(self.root / 'release.sh'), '--build', '42', *args], env=self.env, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []

    def export_options(self):
        with (self.root / 'build/release/0.1-42/ExportOptions.plist').open('rb') as f:
            return plistlib.load(f)

    def test_export_without_upload_or_tag(self):
        result = self.run_release('--no-upload', '--skip-tests')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.export_options()['destination'], 'export')
        self.assertEqual(self.export_options()['signingStyle'], 'automatic')
        self.assertFalse(any(call[:2] == ['git', 'tag'] for call in self.calls()))
        archive = next(c for c in self.calls() if c[:2] == ['xcodebuild', 'archive'])
        self.assertIn('ios/Patchbridge.xcodeproj', archive)
        self.assertIn('CURRENT_PROJECT_VERSION=42', archive)

    def test_successful_upload_tags_only_after_export(self):
        result = self.run_release('--skip-tests')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.export_options()['destination'], 'upload')
        calls = self.calls()
        export = next(i for i, c in enumerate(calls) if c[:2] == ['xcodebuild', '-exportArchive'])
        tag = next(i for i, c in enumerate(calls) if c[:2] == ['git', 'tag'])
        self.assertGreater(tag, export)
        self.assertIn('ios/v0.1-42', calls[tag])

    def test_failed_build_or_test_never_uploads_or_tags(self):
        for stage in ['swift', 'test', 'archive', '-exportArchive']:
            with self.subTest(stage=stage):
                shutil.rmtree(self.root / 'build', ignore_errors=True)
                self.events.unlink(missing_ok=True)
                self.env['FAIL_STAGE'] = stage
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                calls = self.calls()
                self.assertFalse(any(c[:2] == ['git', 'tag'] for c in calls))
                if stage != '-exportArchive':
                    self.assertFalse(any(c[:2] == ['xcodebuild', '-exportArchive'] for c in calls))

    def test_dirty_requires_opt_in_and_never_tags(self):
        self.env['DIRTY'] = '1'
        self.assertNotEqual(self.run_release('--skip-tests').returncode, 0)
        self.assertFalse(any(c[0] == 'xcodebuild' for c in self.calls()))
        self.assertEqual(self.run_release('--skip-tests', '--allow-dirty').returncode, 0)
        self.assertFalse(any(c[:2] == ['git', 'tag'] for c in self.calls()))

    def test_api_profile_and_bundle_are_in_export_options(self):
        key = self.root / 'fake.p8'
        key.write_text('test placeholder; not a key')
        (self.root / 'asc_profile.py').write_text('print("Patchbridge & Test App Store")\n')
        self.env.update(ASC_KEY_ID='TEST', ASC_ISSUER_ID='TEST', ASC_KEY_PATH=str(key))
        result = self.run_release('--skip-tests', '--no-upload')
        self.assertEqual(result.returncode, 0, result.stderr)
        options = self.export_options()
        self.assertEqual(options['signingStyle'], 'manual')
        self.assertEqual(options['provisioningProfiles'], {'com.arjunakankipati.patchbridge': 'Patchbridge & Test App Store'})

    def test_bad_build_number_cannot_start_build(self):
        result = self.run_release('--build', '202610201234')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == 'xcodebuild' for c in self.calls()))

    def test_renamed_simulator_selected_by_id(self):
        result = self.run_release('--no-upload')
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[:2] == ['xcodebuild', 'test'])
        self.assertEqual(call[call.index('-destination') + 1],
                         f'platform=iOS Simulator,id={self.phone_id}')

    def test_destination_override_skips_discovery(self):
        self.env['TEST_DESTINATION'] = 'platform=iOS Simulator,id=explicit-device'
        result = self.run_release('--no-upload')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0] == 'xcrun' for c in self.calls()))
        call = next(c for c in self.calls() if c[:2] == ['xcodebuild', 'test'])
        self.assertIn(self.env['TEST_DESTINATION'], call)

    def test_missing_compatible_phone_stops_before_tests_and_archive(self):
        self.env['DESTINATIONS'] = ''
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No available iPhone simulator', result.stderr)
        self.assertFalse(any(c[0] == 'swift' or c[:2] == ['xcodebuild', 'archive']
                             for c in self.calls()))
