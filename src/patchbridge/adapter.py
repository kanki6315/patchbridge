"""Adapter contract: implementations return confirmed state, never send receipts."""

from typing import Any, Protocol


class BridgeError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class Adapter(Protocol):
    def connect(self) -> dict[str, Any]: ...
    def disconnect(self) -> None: ...
    def snapshot(self) -> dict[str, Any]: ...
    def catalog(self) -> dict[str, Any]: ...
    def execute(self, operation: str, payload: dict[str, Any]) -> dict[str, Any]:
        """Return read-back state, or raise BridgeError if confirmation fails."""
        ...
