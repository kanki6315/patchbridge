import io
import json
import os
import subprocess
import sys
import unittest

from patchbridge.helper import Coordinator, MAX_FRAME_BYTES, serve
from patchbridge.simulator import SimulatedAdapter


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.adapter = SimulatedAdapter()
        self.bridge = Coordinator(self.adapter)
        self.call("connect")

    def call(self, operation, payload=None, **overrides):
        state = self.bridge.state or {}
        request = {
            "version": 1, "type": "request", "id": "test",
            "operation": operation, "payload": payload or {},
            **self.bridge.context(), "preset_id": state.get("preset_id"),
            "scene": state.get("scene"),
        }
        request.update(overrides)
        return self.bridge.handle(request)[0]

    def edit(self, value=7.0, parameter="gain", **overrides):
        return self.call("set_parameter", {
            "block_id": "amp-1", "parameter_id": parameter, "value": value,
        }, **overrides)

    def gain(self):
        return self.bridge.state["blocks"][0]["scenes"]["A"]["parameters"]["gain"]

    def test_catalog_subset_and_simulator_metadata(self):
        catalog = self.call("catalog", {"model_ids": ["sim-amp", "unknown"]})["result"]
        self.assertEqual(set(catalog["models"]), {"sim-amp"})
        self.assertEqual(catalog["id"], self.bridge.state["catalog_id"])
        self.assertEqual(catalog["metadata_version"], 1)
        gain = catalog["models"]["sim-amp"]["parameters"]["gain"]["control"]
        self.assertEqual((gain["encoding"], gain["maximum"]), ("native", 10))
        self.assertEqual(self.call("catalog", {"model_ids": []})["result"]["models"], {})
        for invalid in ("sim-amp", [1], ["x"] * 129, [""]):
            self.assertEqual(self.call("catalog", {"model_ids": invalid})["error"]["code"], "invalid_request")

    def test_save_reload_and_unsaved_edits(self):
        self.assertEqual(self.edit()["status"], "confirmed")
        self.call("save")
        self.edit(2)
        self.assertEqual(self.call("select_preset", {"preset_id": "2"})["error"]["code"], "unsaved_changes")
        self.assertEqual(self.call("select_preset", {"preset_id": "2", "discard": True})["status"], "confirmed")
        self.call("select_preset", {"preset_id": "1"})
        self.assertEqual(self.gain(), 7)
        self.assertFalse(self.bridge.state["dirty"])

    def test_scene_change_rejects_queued_edit(self):
        old_revision = self.bridge.revision
        self.call("select_scene", {"scene": "B"})
        result = self.edit(revision=old_revision, scene="A")
        self.assertEqual(result["error"]["code"], "stale_context")
        self.assertEqual(self.gain(), 5)
        self.edit(8)
        self.assertEqual(self.gain(), 5)
        self.assertEqual(self.bridge.state["blocks"][0]["scenes"]["B"]["parameters"]["gain"], 8)

    def test_preset_and_revision_must_match(self):
        for overrides in ({"preset_id": "2"}, {"revision": 9}, {"revision": False}):
            self.assertEqual(self.edit(**overrides)["error"]["code"], "stale_context")
        self.assertEqual(self.gain(), 5)

    def test_reconnect_does_not_accept_old_session(self):
        old_session = self.bridge.session
        self.call("disconnect")
        self.assertEqual(self.edit()["error"]["code"], "disconnected")
        self.call("connect")
        self.assertNotEqual(old_session, self.bridge.session)
        self.assertEqual(self.edit(session_id=old_session)["error"]["code"], "stale_session")

    def test_validation_does_not_mutate_state(self):
        for value, parameter in [(True, "gain"), (11, "gain"), (float("nan"), "gain"),
                                 ("unknown", "mode"), (1, "bright"), (0, "frequency"),
                                 (None, "missing")]:
            self.assertEqual(self.edit(value, parameter)["status"], "error")
        self.assertEqual(self.gain(), 5)
        self.assertEqual(self.bridge.revision, 0)
        for value, parameter in [(True, "bright"), ("lead", "mode"), (1000, "frequency")]:
            self.assertEqual(self.edit(value, parameter)["status"], "confirmed")

    def test_disconnect_during_write_invalidates_session(self):
        self.adapter.disconnect()
        self.assertEqual(self.edit()["error"]["code"], "disconnected")
        self.assertIsNone(self.bridge.session)

    def test_uncertain_write_invalidates_session(self):
        def fail(*args):
            raise RuntimeError("Lost readback")
        self.adapter.execute = fail
        with self.assertLogs(level="ERROR"):
            result = self.edit()
        self.assertEqual(result["error"]["code"], "adapter_failure")
        self.assertIsNone(self.bridge.session)
        self.assertEqual(self.edit()["error"]["code"], "disconnected")

    def test_unconfirmed_write_keeps_the_session_but_requires_a_snapshot(self):
        from patchbridge.adapter import BridgeError
        session, revision = self.bridge.session, self.bridge.revision
        def unsettled(*args):
            raise BridgeError("not_confirmed", "The QC moved during the switch.")
        original, self.adapter.execute = self.adapter.execute, unsettled
        result = self.call("select_scene", {"scene": "B"})
        self.assertEqual(result["error"]["code"], "not_confirmed")
        self.assertEqual(self.bridge.session, session)
        self.assertEqual(self.bridge.revision, revision + 1)
        self.adapter.execute = original
        # The old context is refused until the caller takes a snapshot.
        self.assertEqual(self.edit(revision=revision)["error"]["code"], "stale_context")
        self.call("snapshot")
        self.assertEqual(self.edit()["status"], "confirmed")

    def test_snapshot_at_a_known_revision_carries_no_state(self):
        revision = self.bridge.revision
        self.assertEqual(self.call("snapshot", {"known_revision": revision})["result"], {"unchanged": True})
        self.assertIn("state", self.call("snapshot", {"known_revision": revision - 1})["result"])
        self.assertIn("state", self.call("snapshot", {"known_revision": True})["result"])
        self.edit()
        self.assertIn("state", self.call("snapshot", {"known_revision": revision})["result"])

    def test_busy_device_keeps_the_session_and_says_when_to_retry(self):
        from patchbridge.adapter import BridgeError
        session, revision = self.bridge.session, self.bridge.revision
        def busy():
            raise BridgeError("device_busy", "Changing preset.")
        self.adapter.snapshot = busy
        result = self.call("snapshot")
        self.assertEqual(result["error"]["code"], "device_busy")
        self.assertEqual(result["retry_after"], 1)
        self.assertEqual((self.bridge.session, self.bridge.revision), (session, revision))

    def test_subscription_events_follow_confirmation(self):
        self.call("subscribe")
        messages = self.bridge.handle({
            "version": 1, "type": "request", "id": "edit", "operation": "set_bypass",
            **self.bridge.context(), "preset_id": "1", "scene": "A",
            "payload": {"block_id": "amp-1", "value": True},
        })
        self.assertEqual([m["type"] for m in messages], ["response", "event"])
        self.assertEqual(messages[0]["revision"], messages[1]["revision"])
        self.assertTrue(messages[1]["state"]["blocks"][0]["scenes"]["A"]["bypass"])

    def test_framing_recovers_and_eof_releases_device(self):
        good = json.dumps({"version": 1, "type": "request", "id": "ok",
                           "operation": "capabilities"}).encode() + b"\n"
        source = io.BytesIO(b"bad\n" + b"x" * (MAX_FRAME_BYTES + 10) + b"\n"
                            + b"\xff\n" + good + b'{"partial":')
        destination = io.BytesIO()
        serve(source, destination, self.bridge)
        messages = [json.loads(line) for line in destination.getvalue().splitlines()]
        self.assertEqual([m["status"] for m in messages],
                         ["error", "error", "error", "confirmed", "error"])
        self.assertEqual(messages[3]["id"], "ok")
        self.assertFalse(self.adapter.connected)

    def test_actual_process_stdout_is_protocol_only(self):
        request = {"version": 1, "type": "request", "id": "connect", "operation": "connect"}
        result = subprocess.run(
            [sys.executable, "-m", "patchbridge.helper", "--adapter", "simulated"],
            input=json.dumps(request) + "\n", text=True, capture_output=True,
            timeout=5, env=os.environ.copy(), check=True,
        )
        messages = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["result"]["device"]["compatibility"], "simulation_only")
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
