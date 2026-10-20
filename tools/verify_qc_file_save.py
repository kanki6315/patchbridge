"""One File CREATE save, followed by a reversible reload verification."""
import json
import time
from pathlib import Path
from qc_mcp.transport import QuadCortex
from qc_mcp import preset
qc=QuadCortex()
r={}
try:
 qc.open()
 assert qc.firmware=='4.1.1'
 bp=qc.get_current_preset()
 assert bp is not None and bp.name=='Tremonti w Mic'
 assert bp.chains[0].models[3].hash==1
 position=qc.read_state('SetlistPosition')
 assert position.folder_key=='/media/p4/Presets/My Presets' and position.position==16
 Path('hardware-results/2026-10-20/before-file-save.bin').write_bytes(bp.SerializeToString())
 original=preset.describe(bp)['chains'][0]['models'][3]['params'][0]['values']
 r['before_gain']=original[0][0]
 print('Sending File CREATE save now',flush=True)
 qc.write_preset_file(position.folder_key,position.position,bp.name)
 time.sleep(1)
 after=qc.get_current_preset()
 r['readable_after_save']=after is not None
 if after is None: raise RuntimeError('Read failed after save; no further writes')
 r['dirty_after_save']=qc.read_state('PresetDirty').is_dirty
 baseline=original[0][0]
 target=baseline+0.01 if baseline<0.98 else baseline-0.01
 try:
  qc.set_param(0,3,0,target)
  changed=qc.get_current_preset()
  assert changed is not None
  r['temporary_edit_confirmed']=abs(changed.chains[0].models[3].params[0].param_values[0].float_value-target)<1e-6
  assert r['temporary_edit_confirmed']
  qc.recall(folder_key=position.folder_key,position=position.position)
  time.sleep(0.5)
  loaded=qc.get_current_preset()
  assert loaded is not None
  r['saved_value_recovered']=preset.describe(loaded)['chains'][0]['models'][3]['params'][0]['values']==original
 finally:
  current=qc.get_current_preset()
  if current is not None and current.name==bp.name and current.chains[0].models[3].hash==1:
   if preset.describe(current)['chains'][0]['models'][3]['params'][0]['values']!=original:
    qc.set_param_typed(0,3,0,original)
    current=qc.get_current_preset()
   r['restored']=current is not None and preset.describe(current)['chains'][0]['models'][3]['params'][0]['values']==original
except Exception as e:
 r['error']=str(e)
finally:
 qc.close()
 Path('hardware-results/2026-10-20/file-save-probe.json').write_text(json.dumps(r,indent=2))
print(json.dumps(r,indent=2))
