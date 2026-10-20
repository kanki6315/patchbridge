"""Observe a physical gain change for up to 45 seconds, without writing."""
import json
import time
from pathlib import Path
from qc_mcp.transport import QuadCortex
qc=QuadCortex()
result={}
try:
 qc.open()
 start=time.monotonic()
 initial=0.3577812612056732
 while time.monotonic()-start < 45:
  bp=qc.get_current_preset()
  if bp is None: raise RuntimeError('No preset readback')
  if bp.name != 'Tremonti w Mic' or bp.chains[0].models[3].hash != 1: raise RuntimeError('Preset changed')
  value=bp.chains[0].models[3].params[0].param_values[0].float_value
  if abs(value-initial)>1e-6:
   result={'observed_change':True,'before':initial,'after':value,'method':'preset polling','elapsed_seconds':time.monotonic()-start}
   break
  time.sleep(0.35)
 else: result={'observed_change':False,'method':'preset polling','window_seconds':45}
finally:
 qc.close()
 Path('hardware-results/2026-10-20/physical-probe.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result))
