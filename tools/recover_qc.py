import json
from pathlib import Path
from qc_mcp.transport import QuadCortex
from qc_mcp import preset
qc=QuadCortex()
r={}
try:
 qc.open()
 r['firmware']=qc.firmware
 bp=qc.get_current_preset()
 r['readable']=bp is not None
 if bp is not None:
  r['preset']=bp.name
  assert bp.name=='Tremonti w Mic' and bp.chains[0].models[3].hash==1
  original=preset.BinaryPreset()
  original.ParseFromString(Path('hardware-results/2026-10-20/before-save.bin').read_bytes())
  values=preset.describe(original)['chains'][0]['models'][3]['params'][0]['values']
  qc.set_param_typed(0,3,0,values)
  after=qc.get_current_preset()
  r['restored']=after is not None and preset.describe(after)['chains'][0]['models'][3]['params'][0]['values']==values
finally:
 qc.close()
 Path('hardware-results/2026-10-20/recovery-probe.json').write_text(json.dumps(r,indent=2))
print(json.dumps(r))
