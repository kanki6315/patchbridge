"""Project captured QC evidence into generic editor wire fixtures; never opens USB."""
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
from patchbridge.metadata import normalize_models

root = Path(__file__).resolve().parents[1]
source = root / 'hardware-results/2026-10-20'
xml = (source / 'live-ModelRepo.xml').read_bytes()
spec = json.loads((source / 'initial-preset.json').read_text())
models = {}
for category in ET.fromstring(xml).findall('Category'):
    for model in category.findall('Model'):
        models[model.get('id')] = {'name': model.get('name'), 'category': category.get('name'),
                                 'parameters': {str(i): dict(p.attrib) for i, p in enumerate(model.findall('Parameter'))}}
catalog_id = hashlib.sha256(xml).hexdigest()
blocks = []
for row, chain in enumerate(spec['chains']):
    for column, block in enumerate(chain['models']):
        if not block['hash']:
            continue
        scenes = {chr(65+s): {'parameters': {}} for s in range(8)}
        editable = []
        definitions = models.get(str(block['hash']), {}).get('parameters', {})
        for index, param in enumerate(block['params']):
            values = param['values']
            if (values and all(v[0] is not None for v in values) and not param['scene_mode']
                    and not param['expression'] and definitions.get(str(index), {}).get('type') in ('float', 'switch', 'rotarySwitch')):
                editable.append(str(index))
            for scene in range(8):
                value_index = scene if param['scene_mode'] else 0
                if value_index < len(values):
                    scenes[chr(65+scene)]['parameters'][str(index)] = next((v for v in values[value_index] if v is not None), None)
        blocks.append({'id': f'{row}:{column}', 'model_id': str(block['hash']), 'position': [row, column],
                       'scenes': scenes, 'editable_parameters': editable})
used = {b['model_id'] for b in blocks}
fixture = {'catalog': {'id': catalog_id, 'metadata_version': 1,
                       'models': normalize_models({key: value for key, value in models.items() if key in used})},
           'snapshot': {'preset_id': 'captured:My Presets:16', 'catalog_id': catalog_id,
                        'name': spec['name'], 'scene_labels': spec.get('scene_labels', []),
                        'scene_colors': spec.get('scene_colors', []), 'scene': 'F', 'dirty': True, 'blocks': blocks}}
(root / 'tests/fixtures/qc-editor.json').write_text(json.dumps(fixture, indent=2) + '\n')
print(f'Exported {len(blocks)} blocks and {len(used)} model definitions from captured evidence.')
