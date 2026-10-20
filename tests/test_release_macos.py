"""Release gates exercised without signing, credentials, Apple services, or uploads."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_macos', ROOT / 'tools/release_macos.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class MacReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ios').mkdir()
        shutil.copy(ROOT / 'ios/project.yml', self.root / 'ios/project.yml')
        (self.root / 'dist/Patchbridge.app').mkdir(parents=True)
        self.calls = []
        self.dirty = False
        self.fail = None
        self.duplicate = False
        self.env = patch.dict(os.environ, {'DEVELOPER_DIR': str(self.root), 'MAC_ASC_USERNAME': 'test@example.invalid',
                                          'MAC_ASC_PASSWORD_KEYCHAIN': 'test-reference'}, clear=True)
        self.env.start(); self.addCleanup(self.env.stop)
        for target, value in [('ROOT', self.root), ('run', self.run_tool), ('verify_app', self.verify)]:
            mock = patch.object(release, target, value); mock.start(); self.addCleanup(mock.stop)
        process = patch.object(release.subprocess, 'run', side_effect=lambda *a, **kw: self.calls.append(('tests',)))
        process.start(); self.addCleanup(process.stop)

    def verify(self, *args):
        self.calls.append(('verify',))
        if self.fail == 'verify': raise ValueError('bad signature')

    def run_tool(self, *args, capture=False):
        args = tuple(map(str, args)); self.calls.append(args)
        if self.fail and self.fail in args: raise subprocess.CalledProcessError(1, args)
        if args[:2] == ('git', 'status'): return ' M changed' if self.dirty else ''
        if args[:2] == ('git', 'rev-parse'): return 'abc123'
        if args[:3] == ('git', 'tag', '--list'): return 'duplicate' if self.duplicate else ''
        if args[0] == 'xcodebuild' and args[1] == '-exportArchive':
            export = Path(args[args.index('-exportPath') + 1]); export.mkdir()
            (export / 'Patchbridge.pkg').write_text('stub')
        if args[:2] == ('pkgutil', '--expand-full'):
            (Path(args[-1]) / 'Payload/Patchbridge.app').mkdir(parents=True)
        if 'asc_profile.py' in args: return 'Patchbridge Mac App Store'
        return ''

    def invoke(self, *args):
        release.main(['--build', '42', '--skip-tests', *args])

    def uploaded(self): return any(c[:3] == ('xcrun', 'altool', '--upload-app') for c in self.calls)
    def tagged(self): return any(c[:3] == ('git', 'tag', '-a') for c in self.calls)

    def test_default_uploads_verified_package_then_tags(self):
        self.invoke()
        verified = self.calls.index(('verify',))
        upload = next(i for i,c in enumerate(self.calls) if c[:3] == ('xcrun','altool','--upload-app'))
        tag = next(i for i,c in enumerate(self.calls) if c[:3] == ('git','tag','-a'))
        self.assertLess(verified, upload); self.assertLess(upload, tag)
        self.assertIn('macos/v0.1-42', self.calls[tag])
        options = plistlib.loads((self.root / 'build/release-macos/0.1-42/ExportOptions.plist').read_bytes())
        self.assertEqual(options['destination'], 'export') # Upload only the inspected package.

    def test_no_upload_exports_without_credentials_or_tag(self):
        os.environ.pop('MAC_ASC_USERNAME'); os.environ.pop('MAC_ASC_PASSWORD_KEYCHAIN')
        self.invoke('--no-upload')
        self.assertFalse(self.uploaded()); self.assertFalse(self.tagged())

    def test_dirty_requires_opt_in_and_never_tags(self):
        self.dirty = True
        with self.assertRaises(ValueError): self.invoke()
        self.invoke('--allow-dirty')
        self.assertTrue(self.uploaded()); self.assertFalse(self.tagged())

    def test_failures_never_upload_or_tag(self):
        for stage in ['tools/package_mac.py', 'archive', '-exportArchive', '--check-signature', 'verify']:
            with self.subTest(stage=stage):
                shutil.rmtree(self.root / 'build', ignore_errors=True)
                self.calls.clear(); self.fail = stage
                with self.assertRaises((ValueError, subprocess.CalledProcessError)): self.invoke()
                self.assertFalse(self.uploaded()); self.assertFalse(self.tagged())

    def test_upload_failure_never_tags(self):
        self.fail = '--upload-app'
        with self.assertRaises(subprocess.CalledProcessError): self.invoke()
        self.assertFalse(self.tagged())

    def test_bad_build_duplicate_tag_and_existing_output_fail_closed(self):
        with self.assertRaises(ValueError): self.invoke('--build', '202610201234')
        self.duplicate = True
        with self.assertRaises(ValueError): self.invoke()
        self.duplicate = False
        (self.root / 'build/release-macos/0.1-42').mkdir(parents=True)
        with self.assertRaises(ValueError): self.invoke()
        self.assertFalse(self.uploaded())

    def test_api_key_uses_mac_profile_and_manual_export(self):
        key = self.root / 'fake.p8'; key.write_text('not a key')
        os.environ.update(ASC_KEY_ID='TEST', ASC_ISSUER_ID='ISSUER', ASC_KEY_PATH=str(key))
        self.invoke('--no-upload')
        profile = next(c for c in self.calls if 'asc_profile.py' in c)
        self.assertIn('mac', profile)
        options = plistlib.loads((self.root / 'build/release-macos/0.1-42/ExportOptions.plist').read_bytes())
        self.assertEqual(options['provisioningProfiles'], {'com.arjunakankipati.patchbridge': 'Patchbridge Mac App Store'})
        self.assertEqual(options['signingStyle'], 'manual')

    def test_regular_test_path_runs_before_archive(self):
        release.main(['--build', '42', '--no-upload'])
        self.assertLess(self.calls.index(('tests',)), next(i for i,c in enumerate(self.calls) if c[:2] == ('xcodebuild','archive')))

    def test_upload_requires_auth_before_build(self):
        os.environ.pop('MAC_ASC_USERNAME')
        with self.assertRaises(ValueError): self.invoke()
        self.assertFalse(any('tools/package_mac.py' in c for c in self.calls))


class ExportVerificationTests(unittest.TestCase):
    def test_wrong_version_fails_before_codesign(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'App.app'; (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.arjunakankipati.patchbridge'}))
            with self.assertRaisesRegex(ValueError, 'CFBundleVersion'):
                release.verify_app(app, 'TEAM', 'com.arjunakankipati.patchbridge', '0.1', '42')

    def test_export_requires_sandbox_inheritance_and_distribution_team(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'App.app'; (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/embedded.provisionprofile').write_bytes(b'stub')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.test', 'CFBundleVersion': '42', 'CFBundleShortVersionString': '0.1'}))
            host = {'com.apple.security.app-sandbox': True, 'com.apple.security.device.usb': True,
                    'com.apple.security.device.bluetooth': True, 'com.apple.security.files.user-selected.read-write': True}
            helper = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
            def signed(*args, capture=False):
                if '--entitlements' in args:
                    return plistlib.dumps(host if args[-1] == app else helper).decode()
                return ''
            def identity(*args, **kwargs):
                return subprocess.CompletedProcess([], 0, stderr='TeamIdentifier=TEAM\nAuthority=Apple Distribution: Test (TEAM)\n')
            with patch.object(release, 'run', side_effect=signed), patch.object(release.subprocess, 'run', side_effect=identity):
                release.verify_app(app, 'TEAM', 'com.test', '0.1', '42')
                helper['com.apple.security.device.usb'] = True
                with self.assertRaisesRegex(ValueError, 'only sandbox'):
                    release.verify_app(app, 'TEAM', 'com.test', '0.1', '42')
                helper.pop('com.apple.security.device.usb')
                host['com.apple.security.get-task-allow'] = True
                with self.assertRaisesRegex(ValueError, 'debugging'):
                    release.verify_app(app, 'TEAM', 'com.test', '0.1', '42')
                host.pop('com.apple.security.get-task-allow')
                with self.assertRaisesRegex(ValueError, 'team'):
                    release.verify_app(app, 'OTHERTEAM', 'com.test', '0.1', '42')
