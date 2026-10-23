"""Matching guards for the measured CorOS startup and directory fast paths."""
import sys
from pathlib import Path
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'vendor/qc-mcp/src'))
try:
    from qc_mcp import transport, protocol as P
    P.message_class('File')
    AVAILABLE = True
except (ImportError, FileNotFoundError):
    AVAILABLE = False


@unittest.skipUnless(AVAILABLE, 'Local USB protobuf dependencies/descriptors required')
class SyncTransportTests(unittest.TestCase):
    def setUp(self):
        self.qc = transport.QuadCortex(io=Mock())
        self.qc.attached = False
        self.qc._hb_stop = object()
        self.qc.firmware = '4.1.1'
        self.qc.send = Mock()

    def item(self, name, **fields):
        obj = P.message_class(name)(**fields)
        return (P.NAME_TO_CMD[name], obj, b'raw', obj.SerializeToString())

    def test_catalog_discards_queued_reply_and_accepts_fresh_unnumbered_payload(self):
        old = self.item('ModelRepo', model_repo_payload=b'old')
        new = self.item('ModelRepo', model_repo_payload=b'new')
        self.qc._pending = [old]
        self.qc._collect = Mock(side_effect=lambda seconds: self.qc._pending.append(new) if seconds else None)
        result = self.qc.read_state('ModelRepo')
        self.assertEqual(result.model_repo_payload, b'new')
        self.assertEqual(self.qc._pending, [])

    def test_version_ack_is_not_complete_metadata(self):
        replies = [self.item('Version', action=P.ACTION['UPDATE']),
                   self.item('Version', zenos_git_hash='4.1.1')]
        self.qc._collect = Mock(side_effect=lambda seconds: self.qc._pending.append(replies.pop(0)) if seconds else None)
        self.assertEqual(self.qc.read_state('Version').zenos_git_hash, '4.1.1')
        self.assertEqual(self.qc._collect.call_count, 3)

    def test_wrong_nonzero_id_does_not_take_metadata_fast_path(self):
        wrong = self.item('ModelRepo', request_id=42, model_repo_payload=b'wrong')
        def collect(seconds):
            if seconds:
                self.qc._pending.append(wrong if self.qc._collect.call_count == 2 else
                    self.item('ModelRepo', request_id=self.qc._req_id, model_repo_payload=b'correct'))
        self.qc._collect = Mock(side_effect=collect)
        self.assertEqual(self.qc.read_state('ModelRepo').model_repo_payload, b'correct')
        self.assertEqual(self.qc._collect.call_count, 3)

    def test_scene_still_waits_for_matching_id(self):
        def collect(seconds):
            self.qc._pending.append(self.item('Scene', request_id=0 if self.qc._collect.call_count == 1 else self.qc._req_id,
                                               selected_scene=1 if self.qc._collect.call_count == 1 else 2))
        self.qc._collect = Mock(side_effect=collect)
        self.assertEqual(self.qc.read_state('Scene').selected_scene, 2)
        self.assertEqual(self.qc._collect.call_count, 2)

    def test_shared_session_does_not_accept_unnumbered_catalog_early(self):
        self.qc.shared = True
        def collect(seconds):
            self.qc._pending.append(self.item('ModelRepo',
                request_id=0 if self.qc._collect.call_count == 1 else self.qc._req_id,
                model_repo_payload=b'other' if self.qc._collect.call_count == 1 else b'ours'))
        self.qc._collect = Mock(side_effect=collect)
        self.assertEqual(self.qc.read_state('ModelRepo').model_repo_payload, b'ours')
        self.assertEqual(self.qc._collect.call_count, 2)

    def directory_reply(self, request, *, count=256, wrong_id=False, wrong_folder=False):
        reply = P.message_class('File')(request_id=request.request_id + int(wrong_id), type=0)
        reply.folder.key = 'other' if wrong_folder else request.folder.key
        for _ in range(count):
            reply.folder.files.add()
        return (P.NAME_TO_CMD['File'], reply, b'raw')

    def test_targeted_directory_returns_complete_slot_table(self):
        self.qc.request = Mock(side_effect=lambda cmd, request, **kw: self.directory_reply(request))
        result = self.qc.list_directory(folder_key='/media/p4/Presets/My Presets')
        self.assertEqual(len(result['presets'][0]['files']), 256)
        self.qc.send.assert_not_called()

    def test_targeted_directory_rejects_partial_stale_or_wrong_folder(self):
        for fields in ({'count': 255}, {'wrong_id': True}, {'wrong_folder': True}):
            with self.subTest(fields=fields):
                self.qc.request = Mock(side_effect=lambda cmd, request, **kw: self.directory_reply(request, **fields))
                with self.assertRaises(transport.QCError):
                    self.qc.list_directory(folder_key='/media/p4/Presets/My Presets')
