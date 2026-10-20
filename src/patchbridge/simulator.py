"""Deterministic simulation; contains no real QC protocol or metadata."""

from copy import deepcopy
import math
from typing import Any

from .adapter import BridgeError


class SimulatedAdapter:
    def __init__(self):
        self.connected = False
        self.saved = {str(i): self._preset(str(i)) for i in range(1, 5)}
        self.state = deepcopy(self.saved["1"])

    @staticmethod
    def _preset(slot: str) -> dict[str, Any]:
        return {
            "preset_id": slot, "name": f"Simulation {slot}", "scene": "A",
            "dirty": False, "catalog_id": "sim-catalog-2",
            "blocks": [{
                "id": "amp-1", "model_id": "sim-amp", "position": [0, 0],
                "editable_parameters": ["gain", "frequency"],
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

    def snapshot(self) -> dict[str, Any]:
        self._require_connection()
        return deepcopy(self.state)

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
                scene["parameters"][parameter] = value
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
