"""Read-only reconnect after the failed save experiment."""
import json
from pathlib import Path
from qc_mcp.transport import QuadCortex
from qc_mcp import preset
qc=QuadCortex()
r={}
try:
 qc.open()
 r['firmware']=qc.firmware
 if qc.firmware:
  bp=qc.get_current_preset()
  r['readable']=bp is not None
  if bp is not None:
   r['preset']=bp.name
   Path('hardware-results/2026-10-20/after-reboot.bin').write_bytes(bp.SerializeToString())
   Path('hardware-results/2026-10-20/after-reboot.json').write_text(json.dumps(preset.describe(bp),indent=2))
   if bp.chains[0].models[3].hash==1:
    r['myth_drive_gain_normalized']=bp.chains[0].models[3].params[0].param_values[0].float_value
finally:
 qc.close()
 Path('hardware-results/2026-10-20/reboot-probe.json').write_text(json.dumps(r,indent=2))
print(json.dumps(r))
