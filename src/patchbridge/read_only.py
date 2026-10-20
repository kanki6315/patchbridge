"""Read-only policy shared by live USB and offline captured-state hosts."""
from .adapter import BridgeError

READ_OPERATIONS = frozenset({'connect', 'disconnect', 'identify', 'capabilities', 'snapshot', 'catalog', 'subscribe'})


class ReadOnlyAdapter:
    operations = READ_OPERATIONS
    read_only = True

    def __init__(self, adapter):
        self.adapter = adapter

    def connect(self):
        return {**self.adapter.connect(), 'access_mode': 'read_only'}

    def disconnect(self):
        self.adapter.disconnect()

    def snapshot(self):
        return self.adapter.snapshot()

    def catalog(self):
        return self.adapter.catalog()

    def execute(self, operation, payload):
        raise BridgeError('read_only', 'This session permits reads only. Editing and saving are disabled.')
