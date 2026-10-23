"""Direct CorOS 4.1.1 adapter. RecallPreset SAVE is intentionally unsupported."""
from copy import deepcopy
import hashlib
import io
import json
import logging
import math
import tarfile
import threading
import time
import xml.etree.ElementTree as ET

from .adapter import BridgeError
from .metadata import OPTION_TYPES, WRITABLE_TYPES, normalize_models
from . import tuner as tuning

OPERATIONS = {'connect', 'disconnect', 'identify', 'capabilities', 'snapshot',
              'catalog', 'subscribe', 'list_presets', 'set_parameter', 'set_bypass', 'select_scene',
              'select_preset', 'save'} | tuning.OPERATIONS
# Broadcasts the QC streams on its own while a session is live. The tuner reader drops them
# so they don't pile up between requests; anything else stays queued for the next request.
STREAMED = {'KeepAlive', 'CPULoad', 'GlobalTempo', 'IOMeter', 'GridModelMeter', 'ModuleStats'}
MUTE_TIMEOUT = 1.5
# While the QC changes scene or loads a preset, its replies stop for a moment or describe the
# old and new context halfway. A snapshot retries for SETTLE_BUDGET seconds and then reports
# device_busy, which keeps the session. Only UNSETTLED_LIMIT seconds of no settled read at all,
# across requests, means the QC is really gone and the session must be reopened.
SETTLE_BUDGET = 5.0
SETTLE_PAUSE = 0.25
UNSETTLED_LIMIT = 20.0
SCENE_TIMEOUT = 3.0
SCENES = 'ABCDEFGH'
# Loading a preset takes longer than a scene: the QC rebuilds the whole grid.
PRESET_TIMEOUT = 8.0
MY_PRESETS = '/media/p4/Presets/My Presets'
MY_PRESETS_SLOTS = 256


class Unsettled(Exception):
    """The QC is mid-change: a read went unanswered or the context moved during the read."""


def active(definitions, parameter, values, depth=0):
    """False while a conditional control's switch is elsewhere, or that switch is itself inactive."""
    rule = definitions.get(parameter, {}).get('control', {}).get('active_when')
    if not rule:
        return True
    value = values.get(rule['parameter'])
    return (depth < 8 and type(value) in (int, float) and any(abs(value - v) < 1e-6 for v in rule['values'])
            and active(definitions, rule['parameter'], values, depth + 1))


def compact(value):
    """The QC stores floats as float32; as doubles they print as 0.30000001192092896.
    Seven significant digits is all float32 holds and roughly halves the snapshot the
    phone receives over Bluetooth."""
    return float(f'{value:.7g}') if type(value) is float else value


def drop_broadcasts(qc, protocol):
    """qc-mcp queues every message a read doesn't consume, and the QC streams some on its
    own (GlobalTempo about four times a second), so a long session's queue grows without
    end and every read scans it. Nothing here reads them; drop them after each read."""
    original = qc.request

    def request(*args, **kwargs):
        with qc._io_lock:
            result = original(*args, **kwargs)
            commands = protocol().COMMANDS
            qc._pending = [t for t in qc._pending if commands.get(t[0]) not in STREAMED]
            return result
    qc.request = request


class USBAdapter:
    operations = OPERATIONS

    def __init__(self, factory=None, protocol=None, clock=time.monotonic, sleep=time.sleep):
        self.factory = factory
        self.protocol = protocol
        self.clock = clock
        self.sleep = sleep
        self.unsettled_since = None
        self.qc = None
        self.state = None
        self.metadata = None
        # The last My Presets listing, by wire position. Only a listed, named slot can be loaded.
        self.listed = None
        self.tuning = tuning.TunerBuffer()
        self.reader = None
        self.reader_stop = None

    def connect(self):
        if self.factory is None:
            from qc_mcp.transport import QuadCortex
            self.factory = QuadCortex
        self.qc = self.factory()
        try:
            drop_broadcasts(self.qc, self._protocol)
            # ctypes returns a signed IOReturn; accept both representations.
            self.qc.io.BENIGN_WRITE_CODES = frozenset({0, 0xe0005000, -536850432})
            self.qc.open()
            if self.qc.firmware != '4.1.1' or not self.qc.protocol_version_verified:
                raise BridgeError('unsupported_firmware', 'USB adapter requires verified CorOS 4.1.1.')
            repo = self.qc.read_state('ModelRepo', timeout_ms=10000)
            if repo is None:
                raise RuntimeError('Live catalog read timed out.')
            with tarfile.open(fileobj=io.BytesIO(repo.model_repo_payload), mode='r:*') as archive:
                member = archive.getmember('ModelRepo.xml')
                if not member.isfile() or member.size > 16 * 1024 * 1024:
                    raise RuntimeError('Catalog exceeds size limit.')
                xml = archive.extractfile(member).read()
            models = {}
            for category in ET.fromstring(xml).findall('Category'):
                for model in category.findall('Model'):
                    models[model.get('id')] = {
                        'name': model.get('name'), 'category': category.get('name'),
                        # Retain symbolic ranges, skew, stepNames and dependencies.
                        'parameters': {str(i): dict(p.attrib)
                                       for i, p in enumerate(model.findall('Parameter'))},
                    }
            self.metadata = {'id': hashlib.sha256(xml).hexdigest(), 'models': normalize_models(models), 'metadata_version': 1,
                             'value_encoding': 'qc_normalized', 'source': 'device'}
            return {'id': 'usb-qc', 'name': 'Quad Cortex', 'firmware': self.qc.firmware,
                    'catalog_id': self.metadata['id'], 'compatibility': 'partially_verified',
                    'save_method': 'File CREATE'}
        except Exception:
            self.disconnect()
            raise

    def disconnect(self):
        if self.qc is not None and self.tuning.state()['mode'] != 'off':
            try:
                self.tuner('off')
            except Exception:
                logging.exception('Could not turn the tuner off before closing USB')
        self._stop_reader()
        qc, self.qc = self.qc, None
        self.state = None
        self.metadata = None
        self.listed = None
        self.unsettled_since = None
        self.tuning.reset()
        if qc is not None:
            qc.close()

    # Tuner. Captured from Cortex Control on CorOS 4.1.1: ShowTuner show, then Tuner UPDATE
    # enable_meter, then Tuner READ starts a stream of pitch in Tuner.meter (Hz, about ten a
    # second while a note rings). ShowTuner without show alone leaves it streaming, so stopping
    # also clears enable_meter. The QC's own screen never changes.
    def _protocol(self):
        if self.protocol is None:
            import qc_mcp.protocol as protocol
            self.protocol = protocol
        return self.protocol

    def _send(self, name, **fields):
        P = self._protocol()
        self.qc.send(name, P.message_class(name)(**fields))

    def tuner(self, mode):
        if self.qc is None:
            raise BridgeError('disconnected', 'No USB session.')
        tuning.validate_mode(mode)
        P = self._protocol()
        update, read = P.ACTION['UPDATE'], P.ACTION['READ']
        # Mute only applies while the tuner is shown; the live tuner never shows it, so it never mutes.
        self._send('ShowTuner', action=update, request_id=self.qc.next_request_id(), show=mode == 'open')
        self._send('Tuner', action=update, request_id=self.qc.next_request_id(), enable_meter=mode != 'off')
        if mode == 'off':
            self._stop_reader()
            self.tuning.reset()
        else:
            self._send('Tuner', action=read)
            self.tuning.set_mode(mode)
            self._start_reader()
        return self.tuning.state()

    def tuner_read(self, after):
        if self.qc is None:
            raise BridgeError('disconnected', 'No USB session.')
        return self.tuning.state(tuning.validate_after(after))

    def set_tuner_mute(self, value):
        if self.qc is None:
            raise BridgeError('disconnected', 'No USB session.')
        if type(value) is not bool:
            raise BridgeError('invalid_value', 'Mute must be a boolean.')
        if self.tuning.state()['mode'] != 'open':
            raise BridgeError('tuner_closed', 'Open the tuner before changing mute.')
        before = self.tuning.reports
        P = self._protocol()
        self._send('Tuner', action=P.ACTION['UPDATE'], request_id=self.qc.next_request_id(), mute=value)
        # The QC echoes every mute change; only that echo confirms it.
        if not self.tuning.wait_for_mute(value, before, MUTE_TIMEOUT):
            raise BridgeError('not_confirmed', 'The QC did not confirm the mute change.')
        return self.tuning.state()

    def _start_reader(self):
        if self.reader is not None:
            return
        self.reader_stop = threading.Event()
        self.reader = threading.Thread(target=self._read_tuner, args=(self.qc, self.reader_stop),
                                       name='tuner-reader', daemon=True)
        self.reader.start()

    def _stop_reader(self):
        reader, stop = self.reader, self.reader_stop
        self.reader = self.reader_stop = None
        if stop is not None:
            stop.set()
        if reader is not None and reader is not threading.current_thread():
            reader.join(timeout=1)

    def _read_tuner(self, qc, stop):
        """Pumps USB between requests. Holding the transport's lock only per pass lets requests
        interleave, and a request's replies arrive while it holds the lock, never here."""
        P = self._protocol()
        while not stop.is_set():
            try:
                with qc._io_lock:
                    qc._collect(0.05)
                    kept = []
                    for item in qc._pending:
                        name = P.COMMANDS.get(item[0])
                        if name == 'Tuner':
                            if item[1] is not None:
                                self._tuner_message(item[1])
                        elif name not in STREAMED:
                            kept.append(item)
                    qc._pending = kept
            except Exception:
                logging.exception('Tuner reader stopped')
                return
            stop.wait(0.01)

    def _tuner_message(self, message):
        fields = {field.name: value for field, value in message.ListFields()}
        if 'meter' in fields:
            self.tuning.add(fields['meter'])
        elif 'mute' in fields or 'input_port_id' in fields:
            self.tuning.report(muted=fields.get('mute'), input_port=fields.get('input_port_id'))

    def catalog(self):
        if self.qc is None:
            raise BridgeError('disconnected', 'No USB session.')
        return deepcopy(self.metadata)

    def _timeouts(self):
        """qc-mcp raises QCError when a read gets no reply at all."""
        try:
            from qc_mcp.transport import QCError
        except ImportError:
            return ()
        return (QCError,)

    def _read(self, read, *args):
        try:
            value = read(*args)
        except self._timeouts() as error:
            raise Unsettled(str(error)) from error
        if value is None:
            raise Unsettled('USB state read timed out.')
        return value

    def snapshot(self, budget=SETTLE_BUDGET):
        """A settled snapshot. A QC that is changing scene or preset gets a few seconds to
        settle; after that this raises device_busy, and the caller asks again later."""
        if self.qc is None:
            raise BridgeError('disconnected', 'No USB session.')
        started = self.clock()
        while True:
            try:
                state = self._snapshot_once()
            except Unsettled as error:
                now = self.clock()
                if self.unsettled_since is None:
                    self.unsettled_since = started
                if now - self.unsettled_since >= UNSETTLED_LIMIT:
                    self.unsettled_since = None
                    raise RuntimeError(f'QC stopped answering for {UNSETTLED_LIMIT:.0f} s; reconnect required.') from error
                if now - started >= budget:
                    raise BridgeError('device_busy', 'The QC is changing scene or preset. Try again in a moment.') from error
                self.sleep(SETTLE_PAUSE)
                continue
            self.unsettled_since = None
            return state

    def _snapshot_once(self):
        pos = self._read(self.qc.read_state, 'SetlistPosition')
        scene = self._read(self.qc.read_state, 'Scene')
        bp = self._read(self.qc.get_current_preset)
        dirty = self._read(self.qc.read_state, 'PresetDirty')
        end_pos = self._read(self.qc.read_state, 'SetlistPosition')
        end_scene = self._read(self.qc.read_state, 'Scene')
        def identity(p):
            return (p.folder_key, p.position, p.is_factory,
                    getattr(p, 'is_downloads', False), getattr(p, 'is_plugin', False))
        if identity(pos) != identity(end_pos) or scene.selected_scene != end_scene.selected_scene:
            raise Unsettled('Device context changed during snapshot.')
        if not 0 <= scene.selected_scene < 8:
            raise RuntimeError('Invalid scene reported by device.')
        self.position = identity(pos)
        blocks = []
        for row, chain in enumerate(bp.chains):
            for column, model in enumerate(chain.models):
                if not model.hash:
                    continue
                scenes = {chr(65+s): {'parameters': {}} for s in range(8)}
                # Like chains/models, bypass reads use array positions; the
                # embedded row/column fields may all be zero. Preserve each
                # scene's flag even when sceneMode is false: recorded reads
                # still carry distinct flags in that case.
                try:
                    bypass = bp.bypass[row].colBypass[column].sceneBypass
                    bypass[scene.selected_scene]
                except (AttributeError, IndexError):
                    raise RuntimeError('Active-scene bypass state is missing; reconnect required.')
                for s, flag in enumerate(bypass[:8]):
                    scenes[chr(65+s)]['bypass'] = flag.bypass
                editable, assigned, pedals = [], [], {}
                definitions = self.metadata['models'].get(str(model.hash), {}).get('parameters', {})
                for index, param in enumerate(model.params):
                    definition = definitions.get(str(index), {})
                    numeric = all(v.WhichOneof('value') == 'float_value' for v in param.param_values)
                    # Hidden and unsupported controls are never written, whatever the phone sends.
                    # A scene-assigned value is written to the active scene only; an expression
                    # owns its value, so it stays read-only.
                    if param.scene_mode:
                        assigned.append(str(index))
                    if param.expression:
                        pedals[str(index)] = {'pedal': int(param.expression),
                                              'heel': float(param.expression_min),
                                              'toe': float(param.expression_max)}
                    complete = not param.scene_mode or len(param.param_values) >= 8
                    if (numeric and param.param_values and complete and not param.expression
                            and definition.get('type') in WRITABLE_TYPES
                            and definition.get('control', {}).get('editable')):
                        editable.append(str(index))
                    for s in range(8):
                        if not param.param_values:
                            continue
                        if param.scene_mode and s >= len(param.param_values):
                            continue  # Missing scene data must not masquerade as a value.
                        v = param.param_values[s if param.scene_mode else 0]
                        field = v.WhichOneof('value')
                        scenes[chr(65+s)]['parameters'][str(index)] = compact(getattr(v, field)) if field else None
                # A conditional control is writable only while its switch makes it active.
                current = scenes[chr(65+scene.selected_scene)]['parameters']
                editable = [p for p in editable if active(definitions, p, current)]
                blocks.append({'id': f'{row}:{column}', 'position': [row, column],
                               'model_id': str(model.hash), 'scenes': scenes,
                               'editable_parameters': editable,
                               'scene_parameters': assigned, 'expression_parameters': pedals})
        state = {'preset_id': json.dumps(self.position, separators=(',', ':')),
                 'scene_labels': list(getattr(bp, 'scene_labels', [])),
                 'scene_colors': list(getattr(bp, 'scene_colors', [])),
                 'name': bp.name, 'scene': chr(65+scene.selected_scene),
                 **({'location': {'source': 'My Presets', 'number': self.position[1] + 1}}
                    if self._in_my_presets(self.position) else {}),
                 'dirty': dirty.is_dirty, 'blocks': blocks, 'value_encoding': 'qc_normalized',
                 'catalog_id': self.metadata.get('id'),
                 'content_hash': hashlib.sha256(bp.SerializeToString()).hexdigest()}
        self.state = deepcopy(state)
        return state

    @staticmethod
    def _in_my_presets(position):
        folder, _, factory, downloads, plugin = position
        return folder == MY_PRESETS and not (factory or downloads or plugin)

    @staticmethod
    def preset_id(position):
        """The preset_id a snapshot reports for a My Presets slot, by wire position."""
        return json.dumps((MY_PRESETS, position, False, False, False), separators=(',', ':'))

    def list_presets(self):
        """My Presets, read with a targeted File READ. Every named
        slot is listed with the preset_id a snapshot reports once it is loaded. Display numbers
        are the wire position plus one, unverified against the QC's own screen."""
        if self.qc is None:
            raise BridgeError('disconnected', 'No USB session.')
        directory = self.qc.list_directory(folder_key=MY_PRESETS, timeout_ms=5000)
        folders = directory.get('presets', []) if isinstance(directory, dict) else []
        folder = next((f for f in folders if f.get('key') == MY_PRESETS), None) or next(
            (f for f in folders if f.get('name') == 'My Presets'
             and not f.get('is_factory') and not f.get('is_downloads')), None)
        if folder is None:
            raise BridgeError('not_confirmed', 'The QC did not list My Presets. Try again.')
        files = folder.get('files', [])[:MY_PRESETS_SLOTS]
        self.listed = {f['index']: f['name'] for f in files
                       if isinstance(f.get('index'), int) and isinstance(f.get('name'), str) and f['name'].strip()}
        return {'source': 'My Presets', 'slots': MY_PRESETS_SLOTS,
                'entries': [{'preset_id': self.preset_id(index), 'number': index + 1, 'name': name}
                            for index, name in sorted(self.listed.items())]}

    def _await_preset(self, position):
        """SetlistPosition READ until the QC reports the recalled slot."""
        deadline = self.clock() + PRESET_TIMEOUT
        while self.clock() < deadline:
            try:
                pos = self._read(self.qc.read_state, 'SetlistPosition')
                if (pos.folder_key, pos.position, pos.is_factory) == (MY_PRESETS, position, False):
                    return True
            except Unsettled:
                pass
            self.sleep(0.1)
        return False

    def _readback(self):
        """The snapshot after a write. The write already happened, so a QC that is still busy
        means the outcome is unknown, not that the write was refused."""
        try:
            return self.snapshot()
        except BridgeError as error:
            if error.code != 'device_busy':
                raise
            raise BridgeError('not_confirmed', 'The QC did not settle after the change; its outcome is unknown.') from error

    def _await_scene(self, index):
        """Scene READ until the QC reports `index` active. A plain read races the switch."""
        deadline = self.clock() + SCENE_TIMEOUT
        while self.clock() < deadline:
            try:
                scene = self._read(self.qc.read_state, 'Scene')
                if scene.selected_scene == index:
                    return True
            except Unsettled:
                pass
            self.sleep(0.05)
        return False

    def execute(self, operation, payload):
        if operation not in {'set_parameter', 'set_bypass', 'select_scene', 'select_preset', 'save'}:
            raise BridgeError('unsupported_operation', 'Operation not yet validated for the USB adapter.')
        expected = deepcopy(self.state)
        # A QC that is still settling refuses here, before anything is written: Not applied.
        current = self.snapshot()
        # Re-read before every write to reject device-side edits since the caller's snapshot.
        if current != expected:
            self.state = expected
            raise BridgeError('stale_context', 'Device changed; request a fresh snapshot.')
        if operation == 'select_scene':
            target = payload.get('scene')
            if not isinstance(target, str) or len(target) != 1 or target not in SCENES:
                raise BridgeError('invalid_value', 'Scene must be a letter from A to H.')
            if target == current['scene']:
                return current
            index = SCENES.index(target)
            self.qc.set_scene(index)
            # Changing scene never touches dirty on the QC; readback reports whatever the QC says.
            if not self._await_scene(index):
                raise BridgeError('not_confirmed', 'The QC did not report the new scene; its outcome is unknown.')
            after = self._readback()
            if after['preset_id'] != current['preset_id'] or after['scene'] != target:
                raise BridgeError('not_confirmed', 'The QC moved elsewhere during the switch; its outcome is unknown.')
            return after
        if operation == 'select_preset':
            target = payload.get('preset_id')
            try:
                folder, position, *flags = json.loads(target) if isinstance(target, str) else ()
            except (ValueError, TypeError):
                folder, position, flags = None, None, None
            if (folder != MY_PRESETS or type(position) is not int or flags != [False, False, False]
                    or not 0 <= position < MY_PRESETS_SLOTS):
                raise BridgeError('invalid_value', 'Only a My Presets slot can be loaded.')
            if not self.listed or position not in self.listed:
                # An empty slot would load a blank preset; only what the last listing named is allowed.
                raise BridgeError('invalid_value', 'That slot is empty or not listed yet. Refresh the list.')
            if current['dirty'] and payload.get('discard') is not True:
                raise BridgeError('unsaved_changes', 'The current preset has unsaved edits.')
            if target == current['preset_id'] and not current['dirty']:
                return current
            self.qc.recall(MY_PRESETS, position, False)
            if not self._await_preset(position):
                raise BridgeError('not_confirmed', 'The QC did not report the new preset; its outcome is unknown.')
            after = self._readback()
            if after['preset_id'] != target:
                raise BridgeError('not_confirmed', 'The QC moved elsewhere during the switch; its outcome is unknown.')
            return after
        if operation == 'set_parameter':
            block = next((b for b in current['blocks'] if b['id'] == payload.get('block_id')), None)
            parameter = payload.get('parameter_id')
            if block is None or not isinstance(parameter, str) or parameter not in block['editable_parameters']:
                raise BridgeError('unsupported_parameter', 'Parameter is unknown, hidden, unsupported, expression-controlled or inactive.')
            value = payload.get('value')
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1:
                raise BridgeError('invalid_value', 'USB values must be normalized numbers in [0, 1].')
            definition = self.metadata['models'][block['model_id']]['parameters'][parameter]
            if definition.get('type') in OPTION_TYPES:
                steps = int(definition.get('steps', '0'))
                if steps < 2 or abs(value*(steps-1)-round(value*(steps-1))) > 1e-5:
                    raise BridgeError('invalid_value', 'Value must select a declared option step.')
            elif definition.get('control', {}).get('step'):
                steps = int(definition['steps'])
                if abs(value*(steps-1)-round(value*(steps-1))) > 1e-5:
                    raise BridgeError('invalid_value', 'Value must land on a whole step.')
            # A plain write lands on the active scene once a parameter is scene-assigned, and on
            # every scene otherwise. No scene_mode flag, as in Cortex Control.
            self.qc.set_param(*block['position'], int(parameter), value)
            after = self._readback()
            actual = next((b for b in after['blocks'] if b['id'] == block['id']), None)
            scoped = parameter in block.get('scene_parameters', [])
            if (after['preset_id'] != current['preset_id'] or after['scene'] != current['scene']
                    or actual is None or actual['model_id'] != block['model_id']
                    or scoped != (parameter in actual.get('scene_parameters', []))
                    or abs(actual['scenes'][after['scene']]['parameters'][parameter]-value) > 1e-5
                    # Other scenes keep their own values; a change there means the write went wide.
                    or (scoped and any(actual['scenes'][s]['parameters'].get(parameter)
                                       != block['scenes'][s]['parameters'].get(parameter)
                                       for s in SCENES if s != current['scene']))):
                # A scene or preset change on the QC can land mid-write. Keep the session; the
                # caller resyncs and the edit is never retried.
                raise BridgeError('not_confirmed', 'Write could not be confirmed; its outcome is unknown.')
            return after
        if operation == 'set_bypass':
            block = next((b for b in current['blocks'] if b['id'] == payload.get('block_id')), None)
            if block is None:
                raise BridgeError('invalid_value', 'Unknown block.')
            value = payload.get('value')
            if type(value) is not bool:
                raise BridgeError('invalid_value', 'Bypass must be a boolean.')
            # Like Cortex Control's bypass button: one flag for the active scene. A block whose
            # bypass isn't assigned to scenes shares that flag, so other scenes may follow.
            self.qc.set_block_bypass(*block['position'], value)
            after = self._readback()
            actual = next((b for b in after['blocks'] if b['id'] == block['id']), None)
            if (after['preset_id'] != current['preset_id'] or after['scene'] != current['scene']
                    or actual is None or actual['model_id'] != block['model_id']
                    or actual['scenes'][after['scene']].get('bypass') is not value):
                raise BridgeError('not_confirmed', 'Bypass could not be confirmed; its outcome is unknown.')
            return after
        folder, position, factory, downloads, plugin = self.position
        if factory or downloads or plugin or folder != '/media/p4/Presets/My Presets' or not current['name']:
            raise BridgeError('unsupported_operation', 'Only an existing named My Presets slot can be saved.')
        self.qc.write_preset_file(folder, position, current['name'])
        # Never invoke qc.save_preset(): RecallPreset SAVE restarted the test device twice.
        after = self._readback()
        comparable = {k: v for k, v in current.items() if k != 'dirty'}
        if after['dirty'] or {k: v for k, v in after.items() if k != 'dirty'} != comparable:
            raise RuntimeError('Save not confirmed; reconnect required. No automatic retry.')
        return after
