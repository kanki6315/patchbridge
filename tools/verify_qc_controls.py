"""Reversible representative effect controls and scene selection readback."""
import json
from pathlib import Path
from qc_mcp.transport import QuadCortex
from qc_mcp import preset
qc=QuadCortex()
results=[]
try:
 qc.open()
 assert qc.firmware=='4.1.1'
 bp=qc.get_current_preset()
 assert bp.name=='Tremonti w Mic'
 for row,col,idx,model,target,label in [(1,2,1,16006,0.0,'Volume curve switch'),(2,6,7,7001,7/13,'Chorus sync-note selector'),(2,6,2,7001,0.43,'Chorus nonlinear rate')]:
  before=qc.get_current_preset()
  assert before.chains[row].models[col].hash==model
  param=before.chains[row].models[col].params[idx]
  assert not param.scene_mode and not param.expression
  original=preset.describe(before)['chains'][row]['models'][col]['params'][idx]['values']
  try:
   qc.set_param(row,col,idx,target)
   after=qc.get_current_preset()
   actual=after.chains[row].models[col].params[idx].param_values[0].float_value
   record={'control':label,'requested':target,'readback':actual,'confirmed':abs(target-actual)<1e-6}
  finally:
   qc.set_param_typed(row,col,idx,original)
   restored=qc.get_current_preset()
   record['restored']=preset.describe(restored)['chains'][row]['models'][col]['params'][idx]['values']==original
   results.append(record)
   assert record['restored']
 scene=qc.read_state('Scene').selected_scene
 try:
  target=(scene+1)%8
  qc.set_scene(target)
  actual=qc.read_state('Scene').selected_scene
  results.append({'control':'scene selection','before':scene,'requested':target,'readback':actual,'confirmed':actual==target})
 finally:
  qc.set_scene(scene)
  results[-1]['restored']=qc.read_state('Scene').selected_scene==scene
finally:
 qc.close()
 Path('hardware-results/2026-10-20/controls-probe.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
