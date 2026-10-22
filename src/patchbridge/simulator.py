"""Deterministic simulation; contains no real QC protocol or metadata."""

from copy import deepcopy
import math
import time
from typing import Any

from .adapter import BridgeError
from . import tuner as tuning

# Open strings the simulated tuner cycles through: (Hz, cents off at the pluck).
STRINGS = [(82.41, 22), (110.0, -16), (146.83, 9), (196.0, -26), (246.94, 12), (329.63, -8)]
RING, GAP, STEP = 4.5, 1.5, 0.1


class SimulatedAdapter:
    operations = frozenset({"connect", "disconnect", "identify", "capabilities", "snapshot", "catalog",
                            "subscribe", "list_presets", "set_parameter", "set_bypass", "select_scene", "select_preset",
                            "save", "save_as"}) | tuning.OPERATIONS

    def __init__(self, clock=time.monotonic):
        self.connected = False
        self.clock = clock
        self.tuning = tuning.TunerBuffer(clock)
        self.generated = 0.0
        self.saved = {str(i): self._preset(str(i)) for i in range(1, 5)}
        self.state = deepcopy(self.saved["1"])

    @staticmethod
    def _preset(slot: str) -> dict[str, Any]:
        return {
            "preset_id": slot, "name": f"Simulation {slot}", "scene": "A",
            "location": {"source": "My Presets", "number": int(slot)},
            "dirty": False, "catalog_id": "sim-catalog-2",
            "blocks": [{
                "id": "amp-1", "model_id": "sim-amp", "position": [0, 0],
                "editable_parameters": ["gain", "frequency"],
                # Gain has its own value per scene; frequency is shared by both.
                "scene_parameters": ["gain"], "expression_parameters": {},
                "scenes": {scene: {"bypass": False, "parameters": {
                    "gain": 5.0, "bright": False, "mode": "clean",
                    "frequency": 440.0,
                }} for scene in ("A", "B")},
            }],
        }

    def _require_connection(self):
        if not self.connected:
            raise BridgeError("disconnected", "Connect before accessing the device.")

    def connect(self) -> dict[str, Any]:
        self.connected = True
        return {
            "id": "simulated-qc", "name": "Simulated QC",
            "firmware": "simulation", "catalog_id": "sim-catalog-2",
            "compatibility": "simulation_only",
        }

    def disconnect(self) -> None:
        self.connected = False
        self.tuning.reset()

    def tuner(self, mode: Any) -> dict[str, Any]:
        self._require_connection()
        tuning.validate_mode(mode)
        if mode == "off":
            self.tuning.reset()
        else:
            if self.tuning.state()["mode"] == "off":
                self.tuning.reset(mode)
                self.tuning.report(muted=False, input_port=1)
                self.generated = self.clock()
            self.tuning.set_mode(mode)
        return self.tuning.state()

    def tuner_read(self, after: Any) -> dict[str, Any]:
        self._require_connection()
        tuning.validate_after(after)
        if self.tuning.state()["mode"] != "off":
            # Readings arrive about ten times a second while a string rings, and none while quiet.
            now = self.clock()
            self.generated = max(self.generated, now - 1)
            while self.generated + STEP <= now:
                self.generated += STEP
                t = (self.generated - self.tuning.started) % ((RING + GAP) * len(STRINGS))
                hz, start = STRINGS[int(t // (RING + GAP))]
                ringing = t % (RING + GAP)
                if ringing < RING:
                    settle = 1 - math.exp(-ringing / 1.0)
                    cents = start * (1 - settle) + 1.2 * math.sin(ringing * 3.5) * (1 - 0.7 * settle)
                    self.tuning.add(hz * 2 ** (cents / 1200))
        return self.tuning.state(after)

    def set_tuner_mute(self, value: Any) -> dict[str, Any]:
        self._require_connection()
        if type(value) is not bool:
            raise BridgeError("invalid_value", "Mute must be a boolean.")
        if self.tuning.state()["mode"] != "open":
            raise BridgeError("tuner_closed", "Open the tuner before changing mute.")
        self.tuning.report(muted=value)
        return self.tuning.state()

    def snapshot(self) -> dict[str, Any]:
        self._require_connection()
        return deepcopy(self.state)

    def list_presets(self) -> dict[str, Any]:
        self._require_connection()
        return {"source": "My Presets", "slots": 256, "entries": [
            {"preset_id": slot, "number": int(slot), "name": preset["name"]}
            for slot, preset in sorted(self.saved.items(), key=lambda item: int(item[0]))]}

    def catalog(self) -> dict[str, Any]:
        self._require_connection()
        catalog = {"id": "sim-catalog-2", "metadata_version": 1, "models": {"sim-amp": {
            "name": "Simulated amp", "parameters": {
                "gain": {"type": "number", "min": 0, "max": 10, "scale": "linear"},
                "bright": {"type": "boolean"},
                "mode": {"type": "enum", "options": ["clean", "crunch", "lead"]},
                "frequency": {"type": "number", "min": 20, "max": 20000,
                              "scale": "logarithmic", "unit": "Hz"},
            },
        }}}

        for name, parameter in catalog["models"]["sim-amp"]["parameters"].items():
            numeric = parameter["type"] == "number"
            parameter["control"] = {
                "kind": "number" if numeric else "unknown", "encoding": "native",
                "name": name, "unit": parameter.get("unit", ""), "editable": numeric,
                "minimum": parameter.get("min"), "maximum": parameter.get("max"),
                "mapping": "identity" if numeric else None,
                "reason": None if numeric else "Native discrete controls are not yet supported.",
                "verification": "simulation_only",
            }
        return catalog

    def execute(self, operation: str, payload: dict[str, Any]) -> dict[str, Any]:
        self._require_connection()
        if operation in ("set_parameter", "set_bypass"):
            block = next((b for b in self.state["blocks"]
                          if b["id"] == payload.get("block_id")), None)
            if block is None:
                raise BridgeError("invalid_value", "Unknown block.")
            scene = block["scenes"][self.state["scene"]]
            value = payload.get("value")
            if operation == "set_bypass":
                if type(value) is not bool:
                    raise BridgeError("invalid_value", "Bypass must be a boolean.")
                scene["bypass"] = value
            else:
                parameter = payload.get("parameter_id")
                definitions = self.catalog()["models"][block["model_id"]]["parameters"]
                if not isinstance(parameter, str) or parameter not in definitions:
                    raise BridgeError("unsupported_parameter", "Unknown parameter.")
                definition = definitions[parameter]
                kind = definition["type"]
                valid = (
                    (kind == "boolean" and type(value) is bool)
                    or (kind == "enum" and value in definition["options"])
                    or (kind == "number" and type(value) in (int, float)
                        and math.isfinite(value)
                        and definition["min"] <= value <= definition["max"])
                )
                if not valid:
                    raise BridgeError("invalid_value", "Value does not match parameter metadata.")
                targets = [scene] if parameter in block["scene_parameters"] else block["scenes"].values()
                for target in targets:
                    target["parameters"][parameter] = value
            self.state["dirty"] = True
        elif operation == "select_scene":
            if payload.get("scene") not in ("A", "B"):
                raise BridgeError("invalid_value", "Unknown scene.")
            self.state["scene"] = payload["scene"]
        elif operation in ("select_preset", "save_as"):
            slot = payload.get("preset_id")
            if not isinstance(slot, str) or slot not in self.saved:
                raise BridgeError("invalid_value", "Unknown preset slot.")
            if operation == "select_preset":
                # Like the QC adapter: loading over unsaved edits must say it discards them.
                if self.state["dirty"] and payload.get("discard") is not True:
                    raise BridgeError("unsaved_changes", "The current preset has unsaved edits.")
                self.state = deepcopy(self.saved[slot])
            else:
                self.state["preset_id"] = slot
                self.state["dirty"] = False
                self.saved[slot] = deepcopy(self.state)
        elif operation == "save":
            self.state["dirty"] = False
            self.saved[self.state["preset_id"]] = deepcopy(self.state)
        else:
            raise BridgeError("unsupported_operation", f"Unsupported operation: {operation}")
        return self.snapshot()
