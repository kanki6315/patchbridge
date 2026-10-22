"""Version 1 newline-delimited JSON process protocol."""

import argparse
import json
import logging
import sys
from typing import Any, BinaryIO
from uuid import uuid4

from .adapter import Adapter, BridgeError
from .simulator import SimulatedAdapter
from .read_only import READ_OPERATIONS, ReadOnlyAdapter
from . import tuner as tuning

VERSION = 1
MAX_FRAME_BYTES = 65536
WRITES = {"set_parameter", "set_bypass", "select_scene", "select_preset", "save", "save_as"}
OPERATIONS = {"connect", "disconnect", "identify", "capabilities", "snapshot", "catalog",
              "subscribe"} | WRITES | tuning.OPERATIONS


class Coordinator:
    """Single consumer owns all adapter access, including writes and readback."""

    def __init__(self, adapter: Adapter):
        self.adapter = adapter
        self.session: str | None = None
        self.device: dict[str, Any] | None = None
        self.state: dict[str, Any] | None = None
        self.revision = 0
        self.subscribed = False

    def close(self):
        try:
            self.adapter.disconnect()
        finally:
            self.session = None
            self.device = None
            self.state = None
            self.subscribed = False

    def context(self) -> dict[str, Any]:
        return {"session_id": self.session, "revision": self.revision}

    def handle(self, request: Any) -> list[dict[str, Any]]:
        request_id = request.get("id") if isinstance(request, dict) else None
        response: dict[str, Any] = {"version": VERSION, "type": "response",
                                    "id": request_id if isinstance(request_id, str) else None}
        events = []
        try:
            if not isinstance(request, dict):
                raise BridgeError("invalid_request", "Request must be an object.")
            if (type(request.get("version")) is not int or request["version"] != VERSION
                    or request.get("type") != "request"):
                raise BridgeError("invalid_request", "Expected a version 1 request.")
            if not isinstance(request_id, str) or not 1 <= len(request_id) <= 128:
                raise BridgeError("invalid_request", "id must contain 1–128 characters.")
            operation = request.get("operation")
            payload = request.get("payload", {})
            if not isinstance(operation, str) or operation not in OPERATIONS:
                raise BridgeError("unsupported_operation", "Unknown operation.")
            if not isinstance(payload, dict):
                raise BridgeError("invalid_request", "payload must be an object.")
            if getattr(self.adapter, "read_only", False) and operation not in READ_OPERATIONS:
                raise BridgeError("read_only", "This session permits reads only. Editing and saving are disabled.")
            if operation == "capabilities":
                supported = getattr(self.adapter, "operations", OPERATIONS)
                result = {"operations": sorted(supported), "protocol_version": VERSION,
                          "confirmation": "readback", "device_events": False,
                          "access_mode": "read_only" if getattr(self.adapter, "read_only", False) else "read_write"}
            elif operation == "connect":
                if self.session is not None:
                    raise BridgeError("already_connected", "Disconnect before starting another session.")
                try:
                    self.device = self.adapter.connect()
                    self.state = self.adapter.snapshot()
                except Exception:
                    self.close()
                    raise
                self.session = str(uuid4())
                self.revision = 0
                result = {"device": self.device, "state": self.state}
            else:
                if self.session is None:
                    raise BridgeError("disconnected", "No active device session.")
                if request.get("session_id") != self.session:
                    raise BridgeError("stale_session", "Request belongs to another session.")
                if operation == "disconnect":
                    self.close()
                    result = {}
                elif operation == "identify":
                    result = self.device
                elif operation == "catalog":
                    model_ids = payload.get("model_ids")
                    if model_ids is not None and (
                            not isinstance(model_ids, list) or len(model_ids) > 128
                            or any(not isinstance(item, str) or not 1 <= len(item) <= 128
                                   for item in model_ids)):
                        raise BridgeError("invalid_request", "model_ids must be at most 128 bounded strings.")
                    result = self.adapter.catalog()
                    if model_ids is not None:
                        result = {**result, "models": {key: value for key, value in result["models"].items()
                                                      if key in model_ids}}

                elif operation == "subscribe":
                    self.subscribed = True
                    result = {"state": self.state}
                elif operation in tuning.OPERATIONS:
                    # The tuner doesn't touch the preset, so it needs no revision context.
                    if operation not in getattr(self.adapter, "operations", OPERATIONS):
                        raise BridgeError("unsupported_operation", "This adapter has no tuner.")
                    if operation == "tuner":
                        tuner = self.adapter.tuner(payload.get("mode"))
                    elif operation == "tuner_read":
                        tuner = self.adapter.tuner_read(payload.get("after", 0))
                    else:
                        tuner = self.adapter.set_tuner_mute(payload.get("value"))
                    result = {"tuner": tuner}
                elif operation == "snapshot":
                    state = self.adapter.snapshot()
                    if state != self.state:
                        self.revision += 1
                    self.state = state
                    result = {"state": state}
                else:
                    assert self.state is not None
                    if (type(request.get("revision")) is not int
                            or request["revision"] != self.revision
                            or request.get("preset_id") != self.state["preset_id"]
                            or request.get("scene") != self.state["scene"]):
                        raise BridgeError("stale_context", "Refresh state before editing.")
                    self.state = self.adapter.execute(operation, payload)
                    self.revision += 1
                    result = {"state": self.state}
                if self.subscribed and (operation in WRITES or operation == "snapshot"):
                    events.append({"version": VERSION, "type": "event", "event": "state",
                                   **self.context(), "state": self.state})
            response.update(status="confirmed", result=result)
        except BridgeError as error:
            if error.code == "disconnected":
                self.close()
            elif error.code == "not_confirmed" and self.session is not None:
                # A write reached the QC but its readback didn't settle. The session survives,
                # but no request may build on the old state: the caller must take a snapshot.
                self.revision += 1
            response.update(status="error", error={"code": error.code, "message": str(error)})
            if error.code == "device_busy":
                # The QC is mid scene or preset change and nothing was written. Ask again soon.
                response["retry_after"] = 1
        except Exception:
            logging.exception("Adapter failure; invalidating session")
            try:
                self.close()
            except Exception:
                logging.exception("Adapter cleanup failed")
            response.update(status="error", error={
                "code": "adapter_failure", "message": "Session invalidated; reconnect and reload state."})
        response.update(self.context())
        return [response, *events]


def serve(source: BinaryIO, destination: BinaryIO, coordinator: Coordinator) -> None:
    try:
        while True:
            line = source.readline(MAX_FRAME_BYTES + 1)
            if not line:
                break
            try:
                if len(line) > MAX_FRAME_BYTES:
                    while line and not line.endswith(b"\n"):
                        line = source.readline(MAX_FRAME_BYTES + 1)
                    raise ValueError("Frame exceeds 65536 bytes.")
                if not line.endswith(b"\n"):
                    raise ValueError("Incomplete frame.")
                request = json.loads(line, parse_constant=lambda _: (_ for _ in ()).throw(
                    ValueError("Non-finite JSON number.")))
                messages = coordinator.handle(request)
            except (ValueError, UnicodeError):
                messages = [{"version": VERSION, "type": "response", "id": None,
                             "status": "error", "error": {
                                 "code": "invalid_frame", "message": "Expected bounded UTF-8 JSON followed by newline."}}]
            for message in messages:
                destination.write(json.dumps(message, allow_nan=False, separators=(",", ":")).encode() + b"\n")
                destination.flush()
    finally:
        coordinator.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", choices=["simulated", "usb", "usb-read-only", "captured-read-only"], required=True)
    parser.add_argument("--fixture", help="Local qc-editor JSON, used only by captured-read-only")
    args = parser.parse_args()
    if (args.adapter == "captured-read-only") != bool(args.fixture):
        parser.error("--fixture is required only for captured-read-only")
    logging.basicConfig(stream=sys.stderr, level=logging.INFO)
    try:
        if args.adapter in ("usb", "usb-read-only"):
            from .usb import USBAdapter
            adapter = USBAdapter()
            if args.adapter == "usb-read-only":
                adapter = ReadOnlyAdapter(adapter)
        elif args.adapter == "captured-read-only":
            from .captured import CapturedAdapter
            adapter = ReadOnlyAdapter(CapturedAdapter(args.fixture))
        else:
            adapter = SimulatedAdapter()
        serve(sys.stdin.buffer, sys.stdout.buffer, Coordinator(adapter))
    except (KeyboardInterrupt, BrokenPipeError):
        pass


if __name__ == "__main__":
    main()
