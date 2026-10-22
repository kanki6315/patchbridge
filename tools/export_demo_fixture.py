"""Derive the app's demo preset from the captured editor fixture; never opens USB."""
import copy
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
NAME = 'Dirty Riffage'
# The row 2 Volume utility adds nothing to the demo, so it's left out, as on the design boards.
DROPPED = {'1:2'}
# Like the scene parameter boards, the Dual Chorus varies Mix and Tone by scene, and Expression 1
# sweeps its Depth from 20 to 80 %. The values are illustrative; the capture has neither.
CHORUS = '2:6'
PER_SCENE = {'0': [0.45, 0.30, 0.25, 0.525, 0.20, None, 0.60, 0.35],
             '5': [0.62, 0.415, 0.38, 0.555, 0.44, None, 0.70, 0.58]}
PEDAL = {'3': {'pedal': 1, 'heel': 0.2, 'toe': 0.8}}


def demo(captured):
    fixture = copy.deepcopy(captured)
    snapshot = fixture['snapshot']
    snapshot['name'] = NAME
    snapshot['blocks'] = [b for b in snapshot['blocks'] if b['id'] not in DROPPED]
    chorus = next(b for b in snapshot['blocks'] if b['id'] == CHORUS)
    for parameter, values in PER_SCENE.items():
        for scene, value in zip('ABCDEFGH', values):
            if value is not None:  # Scene F keeps the captured value.
                chorus['scenes'][scene]['parameters'][parameter] = value
    chorus['scene_parameters'] = sorted(set(chorus['scene_parameters']) | set(PER_SCENE))
    chorus['expression_parameters'] = {**chorus['expression_parameters'], **PEDAL}
    chorus['editable_parameters'] = [p for p in chorus['editable_parameters'] if p not in PEDAL]
    used = {b['model_id'] for b in snapshot['blocks']}
    models = fixture['catalog']['models']
    fixture['catalog']['models'] = {key: value for key, value in models.items() if key in used}
    return fixture


def write(captured):
    (root / 'tests/fixtures/demo-preset.json').write_text(json.dumps(demo(captured), indent=2) + '\n')


if __name__ == '__main__':
    write(json.loads((root / 'tests/fixtures/qc-editor.json').read_text()))
    print(f'Wrote the {NAME} demo preset.')
