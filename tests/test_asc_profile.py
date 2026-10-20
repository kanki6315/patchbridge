"""Provisioning profile platform selection without Apple/network/keychain access."""
import base64
import hashlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('asc_profile', ROOT / 'asc_profile.py')
profile = importlib.util.module_from_spec(spec); spec.loader.exec_module(profile)


class ProfileTests(unittest.TestCase):
    def test_ios_and_mac_profile_types_and_extensions(self):
        for platform, kind, portal, extension in [('ios','IOS_APP_STORE','IOS','.mobileprovision'), ('mac','MAC_APP_STORE','MAC_OS','.provisionprofile')]:
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                api = Mock()
                der = b'test certificate'
                api.get_all.side_effect = [[{'id':'cert','attributes':{'certificateContent':base64.b64encode(der).decode(),'serialNumber':'123'}}], [], []]
                api.call.side_effect = [{'data':{'id':'bundle'}}, {'data':{'attributes':{'name':'Test profile','profileContent':base64.b64encode(b'profile').decode()}}}]
                with patch.object(profile, 'Client', return_value=api), patch.object(profile, 'jwt', return_value='test'), \
                     patch.object(profile, 'local_distribution_identities', return_value={hashlib.sha1(der).hexdigest().upper():der}), \
                     patch.object(profile, 'PROFILE_DIRS', [directory]), \
                     patch.object(profile.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=b'<key>UUID</key><string>test-uuid</string>')), \
                     patch('sys.argv', ['asc_profile.py','--platform',platform,'--key-id','key','--issuer-id','issuer','--key-path','fake','--team','TEAM','--bundle-id','com.test','--name','Test']), redirect_stdout(io.StringIO()):
                    profile.main()
                self.assertEqual(api.call.call_args_list[0].args[2]['data']['attributes']['platform'], portal)
                self.assertEqual(api.call.call_args_list[1].args[2]['data']['attributes']['profileType'], kind)
                self.assertTrue((Path(directory) / ('test-uuid'+extension)).is_file())
