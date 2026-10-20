"""Bundled USB validation with captured files and an in-memory HID substitute only."""
import io
import json
from pathlib import Path
import sys
import tarfile


def verify(root):
    from qc_mcp import backend, transport, iohid, protocol as P, preset
    from google.protobuf import __version__ as protobuf_version
    from google.protobuf.internal import api_implementation
    from .usb import USBAdapter
    from .helper import Coordinator

    def forbidden(*args, **kwargs):
        raise AssertionError('Offline verification attempted hardware access')
    # Import resolves system libraries but never enumerates/opens a device. Block all
    # real construction/open paths before exercising the protocol with an injected IO.
    backend.open_hid = backend.open_bridge = forbidden
    transport.open_hid = transport.open_bridge = forbidden
    iohid.IOHIDTransport.open = forbidden
    for name in ('IOHIDManagerCreate', 'IOHIDManagerOpen', 'IOHIDManagerCopyDevices',
                 'IOHIDDeviceOpen', 'IOHIDDeviceSetReport'):
        setattr(iohid.IOKit, name, forbidden)
    checks = []
    assert protobuf_version == '7.36.2' and api_implementation.Type() == 'upb'
    P.set_version('4.1.1')
    raw = (root / 'hardware-results/2026-10-20/initial-preset.bin').read_bytes()
    xml = (root / 'hardware-results/2026-10-20/live-ModelRepo.xml').read_bytes()
    fixture = json.loads((root / 'tests/fixtures/qc-editor.json').read_text())
    bp = preset.BinaryPreset(); bp.ParseFromString(raw)
    assert preset.describe(bp) == json.loads((root / 'hardware-results/2026-10-20/initial-preset.json').read_text())
    checks.append('real protobuf decodes captured BinaryPreset')
    packed = io.BytesIO()
    with tarfile.open(fileobj=packed, mode='w:gz') as archive:
        member = tarfile.TarInfo('ModelRepo.xml'); member.size = len(xml)
        archive.addfile(member, io.BytesIO(xml))

    class MemoryHID:
        def __init__(self):
            self.receiver = P.Reassembler(); self.messages = []; self.dirty = True
            self.scene = 5; self.drop_edits = False; self.drop_saves = False; self.closed = False
        def set_report(self, report_id, data, include_id=True):
            assert report_id == P.REPORT_HOST_TO_QC and include_id
            for wire in self.receiver.feed(data):
                cmd, payload, _ = P.decode_message(wire)
                name = P.COMMANDS[cmd]; message = P.message_class(name)(); message.ParseFromString(payload)
                self.messages.append((name, message))
                if name == 'Grid':
                    assert message.action == P.ACTION['UPDATE']
                    chain = message.preset.chains[0]; model = chain.models[0]; param = model.params[0]
                    if not self.drop_edits:
                        bp.chains[chain.row].models[model.column].params[param.index].param_values[0].CopyFrom(param.param_values[0])
                        self.dirty = True
                elif name == 'File':
                    assert message.action == P.ACTION['CREATE']
                    assert message.folder.key == '/media/p4/Presets/My Presets'
                    assert message.folder.files[0].index == 16 and message.folder.files[0].name == bp.name
                    assert not message.HasField("preset_payload")
                    if not self.drop_saves: self.dirty = False
                else:
                    raise AssertionError('Unexpected command, including forbidden RecallPreset SAVE: ' + name)
            return -536850432  # Signed benign IOKit return observed on the QC.
        def close(self): self.closed = True

    hid = MemoryHID()
    class CapturedQC(transport.QuadCortex):
        def __init__(self):
            super().__init__(io=hid)
            self.firmware = '4.1.1'; self.protocol_version_verified = True
            self.timeout = False
        def open(self): pass  # Deliberately no handshake or heartbeat.
        def close(self): hid.close()
        def get_current_preset(self): return None if self.timeout else bp
        def read_state(self, name, timeout_ms=2500):
            message = P.message_class(name)()
            if name == 'ModelRepo': message.model_repo_payload = packed.getvalue()
            elif name == 'SetlistPosition':
                message.folder_key = '/media/p4/Presets/My Presets'; message.position = 16
            elif name == 'Scene': message.selected_scene = hid.scene
            elif name == 'PresetDirty': message.is_dirty = hid.dirty
            else: raise AssertionError(name)
            return message
        save_preset = forbidden

    qc = CapturedQC(); adapter = USBAdapter(factory=lambda: qc); coordinator = Coordinator(adapter)
    def call(operation, payload=None):
        state = coordinator.state or {}
        return coordinator.handle({'version': 1, 'type': 'request', 'id': 'offline', 'operation': operation,
            **coordinator.context(), 'preset_id': state.get('preset_id'), 'scene': state.get('scene'), 'payload': payload or {}})[0]
    try:
        connected = call('connect'); assert connected['status'] == 'confirmed', connected
        state = connected['result']['state']
        assert state['blocks'] == fixture['snapshot']['blocks'] and state['scene'] == 'F'
        assert state['catalog_id'] == fixture['catalog']['id']
        catalog = call('catalog', {'model_ids': list(fixture['catalog']['models'])})['result']
        assert catalog['models'] == fixture['catalog']['models'] and catalog['metadata_version'] == 1
        checks.append('captured snapshot and normalized catalog match generic editor fixture')
        edit = {'block_id': '0:3', 'parameter_id': '0', 'value': 0.38}
        result = call('set_parameter', edit); assert result['status'] == 'confirmed', result
        assert abs(bp.chains[0].models[3].params[0].param_values[0].float_value - 0.38) < 1e-5
        assert qc.write_errors == 0
        checks.append('real Grid encoding, fake HID reassembly, normalized edit readback')
        result = call('save'); assert result['status'] == 'confirmed' and not result['result']['state']['dirty'], result
        assert [name for name, _ in hid.messages] == ['Grid', 'File']
        checks.append('real File CREATE encoding; no RecallPreset SAVE')
        count = len(hid.messages); hid.scene = 6
        assert call('set_parameter', edit)['error']['code'] == 'stale_context'
        assert len(hid.messages) == count
        hid.scene = 5; call('snapshot')
        bp.chains[0].out_portid += 1
        assert call('save')['error']['code'] == 'stale_context' and len(hid.messages) == count
        checks.append('physical scene/routing changes rejected before writes')
        call('snapshot')
        hid.drop_saves = True; hid.dirty = True; call('snapshot')
        result = call('save'); assert result['error']['code'] == 'adapter_failure' and result['session_id'] is None
        assert hid.closed and len(hid.messages) == count + 1
        checks.append('unconfirmed save invalidates session with no retry')
        hid.drop_saves = False; hid.closed = False; call('connect')
        hid.drop_edits = True
        result = call('set_parameter', dict(edit, value=0.61))
        assert result['error']['code'] == 'adapter_failure' and result['session_id'] is None
        checks.append('unconfirmed parameter readback invalidates session')
        hid.drop_edits = False; call('connect'); qc.timeout = True
        result = call('snapshot'); assert result['error']['code'] == 'adapter_failure' and hid.closed
        checks.append('read timeout invalidates session')
    finally:
        coordinator.close()
    from .read_only import ReadOnlyAdapter
    from .helper import WRITES
    qc.timeout = False
    readonly = Coordinator(ReadOnlyAdapter(USBAdapter(factory=lambda: qc)))
    try:
        response = readonly.handle({'version': 1, 'type': 'request', 'id': 'read-only', 'operation': 'connect'})[0]
        assert response['status'] == 'confirmed' and response['result']['device']['access_mode'] == 'read_only'
        count = len(hid.messages)
        for operation in WRITES:
            response = readonly.handle({'version': 1, 'type': 'request', 'id': operation,
                'operation': operation, **readonly.context()})[0]
            assert response['error']['code'] == 'read_only'
        assert len(hid.messages) == count
        checks.append('read-only USB policy rejects every mutation before HID writes')
    finally:
        readonly.close()
    return {'status': 'passed' , 'hardware_access': False, 'protobuf': protobuf_version,
            'checks': checks, 'blocks': len(state['blocks']), 'models': len(catalog['models'])}


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Expected repository fixture root')
    print(json.dumps(verify(Path(sys.argv[1]).resolve()), indent=2))


if __name__ == '__main__':
    main()
