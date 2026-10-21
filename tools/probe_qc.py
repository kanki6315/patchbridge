"""Read-only QC evidence capture; run with vendor/qc-mcp/src on PYTHONPATH."""
import json
import platform
from pathlib import Path
from google.protobuf.json_format import MessageToDict
from qc_mcp.transport import QuadCortex
from qc_mcp import preset, catalog

out = Path('hardware-results/2026-10-20')
out.mkdir(parents=True, exist_ok=True)
qc = QuadCortex()
report = {'host': platform.platform(), 'architecture': platform.machine()}
try:
    qc.open()
    report.update(firmware=qc.firmware, device_type=qc.device_type,
                  protocol=qc.protocol_version, verified=qc.protocol_version_verified)
    print(json.dumps(report), flush=True)
    if qc.firmware != '4.1.1' or not qc.protocol_version_verified:
        raise RuntimeError('Firmware gate failed')
    bp = qc.get_current_preset()
    if bp is None:
        raise RuntimeError('Preset read returned no data')
    (out / 'initial-preset.bin').write_bytes(bp.SerializeToString())
    spec = preset.describe(bp)
    (out / 'initial-preset.json').write_text(json.dumps(spec, indent=2))
    report['preset_name'] = bp.name
    # The vendored qc-mcp has no bundled catalog; names come from the device's own.
    repo = qc.read_state('ModelRepo', timeout_ms=10000)
    if repo is None:
        raise RuntimeError('Catalog read returned no data')
    catalog.load_from_bytes(repo.model_repo_payload)
    report['blocks'] = [{'row': row, 'column': column, 'hash': m.hash,
                         'metadata': catalog.lookup(m.hash)}
                        for row, ch in enumerate(bp.chains)
                        for column, m in enumerate(ch.models) if m.hash]
    for name in ('Scene', 'SetlistPosition', 'PresetDirty'):
        obj = qc.read_state(name)
        report[name] = MessageToDict(obj, preserving_proto_field_name=True) if obj else None
    (out / 'model-repo-message.json').write_text(json.dumps(MessageToDict(repo, preserving_proto_field_name=True), indent=2))
    report['model_repo_fields'] = [f.name for f, v in repo.ListFields()]
    report['write_errors'] = qc.write_errors
    report['last_write_error'] = qc.last_write_error
finally:
    qc.close()
    (out / 'read-probe.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
