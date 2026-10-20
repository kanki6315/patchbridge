"""Reversible numeric edit/readback on the inspected disposable preset."""
import base64
import json
import time
from pathlib import Path
from qc_mcp.transport import QuadCortex
from qc_mcp import catalog, preset

out = Path('hardware-results/2026-10-20')
results = {}
qc = QuadCortex()
original = None
try:
    qc.open()
    assert qc.firmware == '4.1.1'
    bp = qc.get_current_preset()
    assert bp is not None and bp.name == 'Tremonti w Mic'
    assert bp.chains[0].models[3].hash == 1
    param = bp.chains[0].models[3].params[0]
    assert not param.scene_mode and not param.expression
    assert all(v.WhichOneof('value') == 'float_value' for v in param.param_values)
    original = preset.describe(bp)['chains'][0]['models'][3]['params'][0]['values']
    (out / 'before-write.bin').write_bytes(bp.SerializeToString())
    repo = json.loads((out / 'model-repo-message.json').read_text())
    results['live_catalog_models'] = catalog.load_from_bytes(base64.b64decode(repo['model_repo_payload']))
    results['tested_metadata'] = catalog.lookup(1)
    before = param.param_values[0].float_value
    target = before + 0.01 if before < 0.98 else before - 0.01
    start = time.monotonic()
    qc.set_param(0, 3, 0, target)
    after = qc.get_current_preset()
    assert after is not None
    actual = after.chains[0].models[3].params[0].param_values[0].float_value
    results.update(before=before, requested=target, readback=actual,
                   edit_readback_seconds=time.monotonic()-start,
                   confirmed=abs(actual-target)<1e-6,
                   raw_last_write_error=qc.last_write_error,
                   unsigned_last_write_error=hex(qc.last_write_error & 0xffffffff) if qc.last_write_error else None)
    print(json.dumps(results), flush=True)
finally:
    try:
        if original is not None:
            qc.set_param_typed(0, 3, 0, original)
            restored = qc.get_current_preset()
            results['restored'] = restored is not None and preset.describe(restored)['chains'][0]['models'][3]['params'][0]['values'] == original
    finally:
        qc.close()
        (out / 'write-probe.json').write_text(json.dumps(results, indent=2))
print('Restored:', results.get('restored'))
