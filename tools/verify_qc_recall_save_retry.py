"""Explicitly authorized single RecallPreset SAVE reproduction; no write retries."""
raise SystemExit("Disabled after the second confirmed device error/restart. RecallPreset SAVE is unsupported.")
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from qc_mcp.transport import QuadCortex

out = Path('hardware-results/2026-10-20') / ('recall-save-retry-' + datetime.now(timezone.utc).strftime('%H%M%S'))
out.mkdir(parents=True)
qc = QuadCortex()
result = {'save_command': 'RecallPreset UPDATE reason=SAVE, no preset payload'}
try:
    qc.open()
    result['firmware'] = qc.firmware
    assert qc.firmware == '4.1.1'
    bp = qc.get_current_preset()
    assert bp is not None and bp.name == 'Tremonti w Mic'
    assert bp.chains[0].models[3].hash == 1
    pos = qc.read_state('SetlistPosition')
    assert pos is not None and pos.folder_key == '/media/p4/Presets/My Presets' and pos.position == 16
    param = bp.chains[0].models[3].params[0]
    assert not param.scene_mode and not param.expression
    before = param.param_values[0].float_value
    assert abs(before - 0.38) < 1e-6, 'Gain changed since confirmation; stopping'
    (out / 'before.bin').write_bytes(bp.SerializeToString())
    qc.set_param(0, 3, 0, 0.39)
    changed = qc.get_current_preset()
    assert changed is not None
    actual = changed.chains[0].models[3].params[0].param_values[0].float_value
    assert abs(actual - 0.39) < 1e-6
    result.update(before_gain=before*10, requested_gain=3.9, edit_confirmed=True)
    print('GAIN 3.9 confirmed. Sending RecallPreset SAVE ONCE now.', flush=True)
    qc.save_preset()
    result['save_sent'] = True
    time.sleep(1)
    dirty = qc.read_state('PresetDirty')
    result['dirty_after_save'] = dirty.is_dirty if dirty else None
    after = qc.get_current_preset()
    result['preset_readable_after_save'] = after is not None
    if after is not None:
        result['preset_after_save'] = after.name
        (out / 'after.bin').write_bytes(after.SerializeToString())
        if after.chains[0].models[3].hash == 1:
            result['gain_after_save'] = after.chains[0].models[3].params[0].param_values[0].float_value*10
except Exception as error:
    result['error'] = repr(error)
finally:
    # Release HID without sending the usual Connection teardown frame after failure.
    qc._stop_heartbeat()
    qc.io.close()
    (out / 'result.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
print('Evidence:', out)
