import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock
from patchbridge.adapter import BridgeError
from patchbridge.captured import CapturedAdapter
from patchbridge.helper import Coordinator, WRITES
from patchbridge.read_only import ReadOnlyAdapter, READ_OPERATIONS


class ReadOnlyTests(unittest.TestCase):
    def test_helper_rejects_all_writes_before_adapter_access(self):
        underlying = Mock()
        coordinator = Coordinator(ReadOnlyAdapter(underlying))
        for operation in WRITES:
            response = coordinator.handle({'version': 1, 'type': 'request', 'id': operation,
                'operation': operation, 'payload': {'read_only': False, 'access_mode': 'read_write'}})[0]
            self.assertEqual(response['error']['code'], 'read_only')
        self.assertEqual(underlying.mock_calls, [])
        with self.assertRaises(BridgeError):
            coordinator.adapter.execute('save', {})
        underlying.execute.assert_not_called()
        capabilities = coordinator.handle({'version': 1, 'type': 'request', 'id': 'c', 'operation': 'capabilities'})[0]
        self.assertEqual(set(capabilities['result']['operations']), READ_OPERATIONS)
        self.assertEqual(capabilities['result']['access_mode'], 'read_only')

    def test_fixture_changes_removal_and_reconnect(self):
        original = json.loads((Path(__file__).parent / 'fixtures/qc-editor.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.json'
            path.write_text(json.dumps(original))
            adapter = ReadOnlyAdapter(CapturedAdapter(path)); coordinator = Coordinator(adapter)
            def call(operation):
                return coordinator.handle({'version': 1, 'type': 'request', 'id': operation,
                    'operation': operation, **coordinator.context()})[0]
            first = call('connect')
            self.assertEqual(first['result']['device']['access_mode'], 'read_only')
            original['snapshot']['scene'] = 'B'; path.write_text(json.dumps(original))
            changed = call('snapshot')
            self.assertEqual(changed['revision'], 1)
            self.assertEqual(changed['result']['state']['scene'], 'B')
            original['offline_fault'] = 'disconnect'; path.write_text(json.dumps(original))
            self.assertEqual(call('snapshot')['error']['code'], 'disconnected')
            self.assertIsNone(coordinator.session)
            del original['offline_fault']; path.write_text(json.dumps(original))
            self.assertNotEqual(call('connect')['session_id'], first['session_id'])
