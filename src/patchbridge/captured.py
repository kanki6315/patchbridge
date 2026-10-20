"""Offline fixture host; never imports the USB transport. Faults are local test inputs."""
from copy import deepcopy
import json
import os
from pathlib import Path
import time
from .adapter import BridgeError


class CapturedAdapter:
    def __init__(self, fixture):
        self.fixture = Path(fixture)
        self.connected = False

    def _read(self):
        if not self.connected:
            raise BridgeError('disconnected', 'Captured fixture session is disconnected.')
        document = json.loads(self.fixture.read_text())
        fault = document.get('offline_fault')
        if fault == 'disconnect':
            raise BridgeError('disconnected', 'Simulated USB removal.')
        if fault == 'crash':
            os._exit(70)  # Dedicated offline subprocess only; never selected in live USB mode.
        if fault == 'slow':
            time.sleep(3)
        return document

    def connect(self):
        self.connected = True
        document = self._read()
        return {'id': 'captured-qc', 'name': 'Captured QC (offline)', 'firmware': 'captured-4.1.1',
                'compatibility': 'offline_fixture_only', 'catalog_id': document['catalog']['id']}

    def disconnect(self):
        self.connected = False

    def snapshot(self):
        return deepcopy(self._read()['snapshot'])

    def catalog(self):
        return deepcopy(self._read()['catalog'])

    def execute(self, operation, payload):
        raise BridgeError('read_only', 'Captured fixtures cannot be written.')
