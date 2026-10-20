import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('preflight', Path(__file__).parents[1] / 'tools/preflight.py')
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def test_failure_details_are_not_exported_and_later_checks_can_run(self):
        def bad(): raise ValueError('PRIVATE PRESET /Users/private/secret')
        failed = preflight.run_check('package', bad)
        good = preflight.run_check('next', lambda: None)
        report = preflight.make_report([failed, good])
        self.assertEqual(report['result'], 'blocked')
        self.assertEqual(good['status'], 'passed')
        self.assertNotIn('PRIVATE', json.dumps(report))
        self.assertNotIn('/Users', json.dumps(report))

    def test_pass_does_not_claim_hardware_compatibility(self):
        report = preflight.make_report([{'check': 'offline', 'status': 'passed'}])
        self.assertEqual(report['result'], 'offline_checks_passed')
        self.assertFalse(report['hardware_validated'])
        self.assertTrue(report['not_tested'])
        self.assertEqual(preflight.make_report([])['result'], 'blocked')

    def test_export_is_private_and_replaceable(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'report.json'
            preflight.save_report(preflight.make_report([]), path)
            preflight.save_report(preflight.make_report([{'check': 'x', 'status': 'passed'}]), path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(list(path.parent.iterdir())), 1)

    def test_stale_build_input_fails_provenance(self):
        from unittest.mock import patch
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'app'
            manifest = app / 'Contents/Resources/build-manifest.json'
            manifest.parent.mkdir(parents=True)
            paths = ['tools/package_mac.py', 'mac/helper_launcher.c', 'mac/main.swift',
                     'src/patchbridge/read_only.py', 'swift/Sources/PatchbridgeCore/Diagnostics.swift']
            inputs = {}
            for relative in paths:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original')
                inputs[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
            manifest.write_text(json.dumps({'build_inputs': inputs, 'bundled_usb': {
                'qc_mcp_commit': 'f634ecd3dcf426090b90bc4cc176e4b500494b9e', 'protobuf': '7.36.2', 'hardware_enabled': True}}))
            with patch.object(preflight, 'ROOT', root), patch.object(preflight, 'APP', app):
                preflight.freshness()
                (root / paths[0]).write_text('changed')
                with self.assertRaises(ValueError): preflight.freshness()
