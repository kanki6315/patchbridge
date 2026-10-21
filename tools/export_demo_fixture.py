"""Derive the app's demo preset from the captured editor fixture; never opens USB."""
import copy
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
NAME = 'Dirty Riffage'
# The row 2 Volume utility adds nothing to the demo, so it's left out, as on the design boards.
DROPPED = {'1:2'}


def demo(captured):
    fixture = copy.deepcopy(captured)
    snapshot = fixture['snapshot']
    snapshot['name'] = NAME
    snapshot['blocks'] = [b for b in snapshot['blocks'] if b['id'] not in DROPPED]
    used = {b['model_id'] for b in snapshot['blocks']}
    models = fixture['catalog']['models']
    fixture['catalog']['models'] = {key: value for key, value in models.items() if key in used}
    return fixture


def write(captured):
    (root / 'tests/fixtures/demo-preset.json').write_text(json.dumps(demo(captured), indent=2) + '\n')


if __name__ == '__main__':
    write(json.loads((root / 'tests/fixtures/qc-editor.json').read_text()))
    print(f'Wrote the {NAME} demo preset.')
