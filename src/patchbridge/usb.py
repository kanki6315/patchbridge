"""Direct CorOS 4.1.1 adapter. RecallPreset SAVE is intentionally unsupported."""
from copy import deepcopy
import hashlib
import io
import json
import math
import tarfile
import xml.etree.ElementTree as ET

from .adapter import BridgeError
from .metadata import OPTION_TYPES, WRITABLE_TYPES, normalize_models

OPERATIONS = {'connect', 'disconnect', 'identify', 'capabilities', 'snapshot',
              'catalog', 'subscribe', 'set_parameter', 'save'}


class USBAdapter:
    operations = OPERATIONS

    def __init__(self, factory=None):
        self.factory = factory
        self.qc = None
        self.state = None
        self.metadata = None

    def connect(self):
        if self.factory is None:
            from qc_mcp.transport import QuadCortex
            self.factory = QuadCortex
        self.qc = self.factory()
        try:
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
        qc, self.qc = self.qc, None
        self.state = None
        self.metadata = None
        if qc is not None:
            qc.close()

    def catalog(self):
        if self.qc is None:
            raise BridgeError('disconnected', 'No USB session.')
        return deepcopy(self.metadata)

    def snapshot(self):
        if self.qc is None:
            raise BridgeError('disconnected', 'No USB session.')
        pos = self.qc.read_state('SetlistPosition')
        scene = self.qc.read_state('Scene')
        bp = self.qc.get_current_preset()
        dirty = self.qc.read_state('PresetDirty')
        end_pos = self.qc.read_state('SetlistPosition')
        end_scene = self.qc.read_state('Scene')
        if any(x is None for x in (pos, scene, bp, dirty, end_pos, end_scene)):
            raise RuntimeError('USB state read timed out; reconnect required.')
        def identity(p):
            return (p.folder_key, p.position, p.is_factory,
                    getattr(p, 'is_downloads', False), getattr(p, 'is_plugin', False))
        if identity(pos) != identity(end_pos) or scene.selected_scene != end_scene.selected_scene:
            raise RuntimeError('Device context changed during snapshot; reconnect required.')
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
                editable = []
                definitions = self.metadata['models'].get(str(model.hash), {}).get('parameters', {})
                for index, param in enumerate(model.params):
                    definition = definitions.get(str(index), {})
                    numeric = all(v.WhichOneof('value') == 'float_value' for v in param.param_values)
                    if (numeric and param.param_values and not param.scene_mode and not param.expression
                            and definition.get('type') in WRITABLE_TYPES):
                        editable.append(str(index))
                    for s in range(8):
                        if not param.param_values:
                            continue
                        if param.scene_mode and s >= len(param.param_values):
                            continue  # Missing scene data must not masquerade as a value.
                        v = param.param_values[s if param.scene_mode else 0]
                        field = v.WhichOneof('value')
                        scenes[chr(65+s)]['parameters'][str(index)] = getattr(v, field) if field else None
                blocks.append({'id': f'{row}:{column}', 'position': [row, column],
                               'model_id': str(model.hash), 'scenes': scenes,
                               'editable_parameters': editable})
        state = {'preset_id': json.dumps(self.position, separators=(',', ':')),
                 'scene_labels': list(getattr(bp, 'scene_labels', [])),
                 'scene_colors': list(getattr(bp, 'scene_colors', [])),
                 'name': bp.name, 'scene': chr(65+scene.selected_scene),
                 'dirty': dirty.is_dirty, 'blocks': blocks, 'value_encoding': 'qc_normalized',
                 'catalog_id': self.metadata.get('id'),
                 'content_hash': hashlib.sha256(bp.SerializeToString()).hexdigest()}
        self.state = deepcopy(state)
        return state

    def execute(self, operation, payload):
        if operation not in {'set_parameter', 'save'}:
            raise BridgeError('unsupported_operation', 'Operation not yet validated for the USB adapter.')
        expected = deepcopy(self.state)
        current = self.snapshot()
        # Re-read before every write to reject device-side edits since the caller's snapshot.
        if current != expected:
            self.state = expected
            raise BridgeError('stale_context', 'Device changed; request a fresh snapshot.')
        if operation == 'set_parameter':
            block = next((b for b in current['blocks'] if b['id'] == payload.get('block_id')), None)
            parameter = payload.get('parameter_id')
            if block is None or not isinstance(parameter, str) or parameter not in block['editable_parameters']:
                raise BridgeError('unsupported_parameter', 'Parameter is unknown, scene-assigned or expression-controlled.')
            value = payload.get('value')
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1:
                raise BridgeError('invalid_value', 'USB values must be normalized numbers in [0, 1].')
            definition = self.metadata['models'][block['model_id']]['parameters'][parameter]
            if definition.get('type') in OPTION_TYPES:
                steps = int(definition.get('steps', '0'))
                if steps < 2 or abs(value*(steps-1)-round(value*(steps-1))) > 1e-5:
                    raise BridgeError('invalid_value', 'Value must select a declared option step.')
            self.qc.set_param(*block['position'], int(parameter), value)
            after = self.snapshot()
            actual = next((b for b in after['blocks'] if b['id'] == block['id']), None)
            if (after['preset_id'] != current['preset_id'] or after['scene'] != current['scene']
                    or actual is None or actual['model_id'] != block['model_id']
                    or abs(actual['scenes'][after['scene']]['parameters'][parameter]-value) > 1e-5):
                raise RuntimeError('Write could not be confirmed; reconnect required.')
            return after
        folder, position, factory, downloads, plugin = self.position
        if factory or downloads or plugin or folder != '/media/p4/Presets/My Presets' or not current['name']:
            raise BridgeError('unsupported_operation', 'Only an existing named My Presets slot can be saved.')
        self.qc.write_preset_file(folder, position, current['name'])
        # Never invoke qc.save_preset(): RecallPreset SAVE restarted the test device twice.
        after = self.snapshot()
        comparable = {k: v for k, v in current.items() if k != 'dirty'}
        if after['dirty'] or {k: v for k, v in after.items() if k != 'dirty'} != comparable:
            raise RuntimeError('Save not confirmed; reconnect required. No automatic retry.')
        return after
