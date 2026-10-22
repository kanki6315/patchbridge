"""Read-only policy shared by live USB and offline captured-state hosts."""
from .adapter import BridgeError
from . import tuner as tuning

# Starting and reading the tuner are reads: they change neither the preset nor a kept setting.
# Mute is a QC setting, so it stays out. Listing presets reads the directory and loads nothing.
READ_OPERATIONS = frozenset({'connect', 'disconnect', 'identify', 'capabilities', 'snapshot', 'catalog',
                             'subscribe', 'list_presets'}) | tuning.READ_OPERATIONS
# Reads only some adapters have.
OPTIONAL_READS = tuning.READ_OPERATIONS | {'list_presets'}


class ReadOnlyAdapter:
    read_only = True

    def __init__(self, adapter):
        self.adapter = adapter
        supported = getattr(adapter, 'operations', frozenset())
        supported = supported if isinstance(supported, (set, frozenset)) else frozenset()
        self.operations = frozenset(op for op in READ_OPERATIONS
                                    if op not in OPTIONAL_READS or op in supported)

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

    def list_presets(self):
        return self.adapter.list_presets()

    def tuner(self, mode):
        return self.adapter.tuner(mode)

    def tuner_read(self, after):
        return self.adapter.tuner_read(after)
