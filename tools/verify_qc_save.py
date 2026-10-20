"""Save/readback test on the inspected disposable slot, restoring the starting gain."""
raise SystemExit("Disabled: RecallPreset SAVE restarted the QC. Use File CREATE through the USB adapter.")
import json
import time
from pathlib import Path
from qc_mcp.transport import QuadCortex
from qc_mcp import preset
qc=QuadCortex()
result={}
original=None
position=None
try:
 qc.open()
 assert qc.firmware=='4.1.1'
 bp=qc.get_current_preset()
 assert bp.name=='Tremonti w Mic' and bp.chains[0].models[3].hash==1
 position=qc.read_state('SetlistPosition')
 assert position.folder_key=='/media/p4/Presets/My Presets' and position.position==16 and not position.is_factory
 original=preset.describe(bp)['chains'][0]['models'][3]['params'][0]['values']
 Path('hardware-results/2026-10-20/before-save.bin').write_bytes(bp.SerializeToString())
 baseline=original[0][0]
 target=baseline+0.01 if baseline<0.98 else baseline-0.01
 qc.set_param(0,3,0,target)
 assert abs(qc.get_current_preset().chains[0].models[3].params[0].param_values[0].float_value-target)<1e-6
 qc.save_preset()
 time.sleep(0.7)
 result['dirty_after_save']=qc.read_state('PresetDirty').is_dirty
 qc.set_param(0,3,0,baseline)
 assert abs(qc.get_current_preset().chains[0].models[3].params[0].param_values[0].float_value-baseline)<1e-6
 qc.recall(folder_key=position.folder_key,position=position.position)
 time.sleep(0.5)
 loaded=qc.get_current_preset()
 actual=loaded.chains[0].models[3].params[0].param_values[0].float_value
 result.update(requested_saved=target,readback_after_recall=actual,confirmed=abs(actual-target)<1e-6,method='save, alter working value, recall same slot')
finally:
 try:
  if original is not None:
   current=qc.get_current_preset()
   assert current.name=='Tremonti w Mic' and current.chains[0].models[3].hash==1
   qc.set_param_typed(0,3,0,original)
   qc.save_preset()
   time.sleep(0.7)
   qc.recall(folder_key=position.folder_key,position=position.position)
   time.sleep(0.5)
   restored=qc.get_current_preset()
   result['restored_and_saved']=preset.describe(restored)['chains'][0]['models'][3]['params'][0]['values']==original
 finally:
  qc.close()
  Path('hardware-results/2026-10-20/save-probe.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
