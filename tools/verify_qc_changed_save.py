"""Save a changed Myth Drive gain with File CREATE; leave it saved for inspection."""
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from qc_mcp.transport import QuadCortex

out = Path('hardware-results/2026-10-20') / ('changed-file-save-' + datetime.now(timezone.utc).strftime('%H%M%S'))
out.mkdir(parents=True)
qc = QuadCortex()
result = {'save_command': 'File CREATE'}

def read():
    bp = qc.get_current_preset()
    if bp is None:
        raise RuntimeError('Preset read timed out; stopping writes')
    if bp.name != 'Tremonti w Mic' or bp.chains[0].models[3].hash != 1:
        raise RuntimeError('Unexpected preset or block; stopping writes')
    return bp

def gain(bp):
    return bp.chains[0].models[3].params[0].param_values[0].float_value

try:
    qc.open()
    assert qc.firmware == '4.1.1'
    bp = read()
    pos = qc.read_state('SetlistPosition')
    assert pos is not None and pos.folder_key == '/media/p4/Presets/My Presets' and pos.position == 16 and not pos.is_factory
    param = bp.chains[0].models[3].params[0]
    assert not param.scene_mode and not param.expression
    assert all(v.WhichOneof('value') == 'float_value' for v in param.param_values)
    (out / 'before.bin').write_bytes(bp.SerializeToString())
    before = gain(bp)
    target = 0.38 if abs(before - 0.38) > 1e-5 else 0.40
    result.update(before_gain=before*10, requested_gain=target*10)
    qc.set_param(0, 3, 0, target)
    changed = read()
    assert abs(gain(changed) - target) < 1e-6
    result['edit_confirmed'] = True
    dirty = qc.read_state('PresetDirty')
    result['dirty_before_save'] = dirty.is_dirty if dirty else None
    print(f'Gain changed from {before*10:.3f} to {target*10:.1f}; sending File CREATE now', flush=True)
    qc.write_preset_file(pos.folder_key, pos.position, bp.name)
    time.sleep(1)
    after = read()
    assert abs(gain(after) - target) < 1e-6
    dirty = qc.read_state('PresetDirty')
    result['dirty_after_save'] = dirty.is_dirty if dirty else None
    # Displace the working value, then demand the newly saved value from storage.
    qc.set_param(0, 3, 0, before)
    assert abs(gain(read()) - before) < 1e-6
    result['working_value_displaced'] = True
    qc.recall(folder_key=pos.folder_key, position=pos.position)
    time.sleep(0.5)
    loaded = read()
    result['reloaded_gain'] = gain(loaded)*10
    result['changed_value_persisted'] = abs(gain(loaded) - target) < 1e-6
    (out / 'after-reload.bin').write_bytes(loaded.SerializeToString())
except Exception as error:
    result['error'] = repr(error)
finally:
    qc.close()
    (out / 'result.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
print('Evidence:', out)
