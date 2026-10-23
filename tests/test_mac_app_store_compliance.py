"""Reject unpatched or incomplete cached runtimes before packaging."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'package_mac', Path(__file__).resolve().parents[1] / 'tools/package_mac.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class AppStoreRuntimeTests(unittest.TestCase):
    def test_cached_runtime_must_have_patched_url_parser(self):
        with tempfile.TemporaryDirectory() as temporary:
            stdlib = Path(temporary)
            with self.assertRaisesRegex(SystemExit, 'rebuild'):
                package.verify_app_store_stdlib(stdlib)
            (stdlib / 'urllib').mkdir()
            parser = stdlib / 'urllib/parse.py'
            parser.write_text("uses_netloc = ['https', 'itms-services']\n")
            with self.assertRaisesRegex(SystemExit, 'rebuild'):
                package.verify_app_store_stdlib(stdlib)
            parser.write_text("uses_netloc = ['https']\n")
            package.verify_app_store_stdlib(stdlib)
