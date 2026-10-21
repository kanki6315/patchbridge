#!/usr/bin/env python3
"""Calibrate parameter display curves on a connected QC, with the user reading its screen.

For each chosen parameter in the current preset, writes a few normalized values, asks
what the QC displays, then restores the original value. Results are saved after every
parameter and compared with linear and declared mappings, so we can decide whether
parameters without a declared taper are linear. Run only on the disposable preset with
Cortex Control closed. The preset is left unsaved; reload it on the QC to discard.

  calibrate_qc_controls.py --plan        # list targets from the captured preset, no USB
  calibrate_qc_controls.py               # user-present hardware run
  calibrate_qc_controls.py --analyze F   # summarize a saved run
"""
import argparse
import datetime as dt
import json
import math
import re
from pathlib import Path
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src'))
from patchbridge.metadata import normalize_parameter  # noqa: E402

CAPTURED = ROOT / 'hardware-results/2026-10-20'
DISPOSABLE = 'Tremonti w Mic'
NUMERIC_POINTS = [0, 0.25, 0.5, 0.75, 1]
# How close a reading must be to a prediction, as a share of the parameter's range.
TOLERANCE = 0.02


def steps(raw):
    try:
        count = int(raw.get('steps', ''))
    except ValueError:
        return 0
    return count if 2 <= count <= 16 else 0


def numeric_range(raw):
    try:
        low, high = float(raw['min']), float(raw['max'])
    except (KeyError, ValueError):
        return None
    return (low, high) if math.isfinite(low) and math.isfinite(high) and high > low else None


def group(raw, control):
    """Which calibration question a parameter answers, or None if it isn't a candidate."""
    kind = raw.get('type')
    if raw.get('toggleOn') is not None or raw.get('toggleOff') is not None:
        return None
    if kind == 'toggleButton' and control['editable']:
        return 'toggle'
    labels = [label for label in raw.get('stepNames', '').split(',') if label.strip()]
    if kind == 'comboBox' and steps(raw) and len(labels) == steps(raw):
        return 'combo'
    if kind in ('switch', 'rotarySwitch') and steps(raw) and not labels:
        return 'unlabeled_switch'
    if kind not in ('float', 'fader'):
        return None
    if numeric_range(raw) is None:
        # Named range constants such as MIN_EQ_DB; readings at 0 and 1 reveal their values.
        return 'symbolic' if raw.get('min') and raw.get('max') else None
    if kind == 'fader':
        return 'fader'
    if control.get('mapping') == 'table':
        return 'table'
    skew = raw.get('skew')
    if skew is None:
        return 'no_taper'
    if skew == 'LOG_SKEW':
        return 'log'
    if skew == 'LIN_SKEW' or control.get('exponent') == 1:
        return 'linear'
    return 'power' if control['editable'] else None


def points_for(target):
    if target['group'] == 'toggle':
        return [option['value'] for option in target['control']['options']]
    if target['group'] in ('combo', 'unlabeled_switch'):
        count = steps(target['raw'])
        return [i / (count - 1) for i in range(count)]
    if target['group'] == 'table':
        # Table points and the midpoints between them test the linear interpolation.
        xs = [x for x, _ in target['control']['points']]
        return sorted({*xs, *((a + b) / 2 for a, b in zip(xs, xs[1:]))})
    return NUMERIC_POINTS


def predict(target, normalized):
    """Display values implied by a linear reading and by the declared mapping."""
    control, raw = target['control'], target['raw']
    if target['group'] == 'toggle':
        # The QC's button text is the action: it offers the other option.
        label = next(o['label'] for o in control['options'] if abs(o['value'] - normalized) > 1e-9)
        return {'declared': label}
    if target['group'] == 'combo':
        labels = [label.strip() for label in raw['stepNames'].split(',')]
        return {'declared': labels[round(normalized * (len(labels) - 1))]}
    if target['group'] in ('unlabeled_switch', 'symbolic'):
        return {}
    low, high = float(raw['min']), float(raw['max'])
    result = {'linear': low + (high - low) * normalized}
    if control.get('mapping') == 'power':
        result['declared'] = low + (high - low) * normalized ** (1 / control['exponent'])
    elif control.get('mapping') == 'table':
        pts = control['points']
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            if normalized <= x1:
                result['declared'] = y0 + (y1 - y0) * (normalized - x0) / (x1 - x0)
                break
    return result


def catalog_from_xml(xml):
    models = {}
    for category in ET.fromstring(xml).findall('Category'):
        for model in category.findall('Model'):
            models[model.get('id')] = {'name': model.get('name'), 'category': category.get('name'),
                                       'parameters': {str(i): dict(p.attrib) for i, p in enumerate(model.findall('Parameter'))}}
    return models


def block_name(block, model):
    """A Neural Capture's own name ("OG TS808") rather than its catalog name ("Eltron 30")."""
    for index, raw in model['parameters'].items():
        if raw.get('name') == 'file_name' and int(index) < len(block['params']):
            text = (block['params'][int(index)]['values'] or [[None, None, None]])[0][2]
            if text:
                return f"{re.sub(r'^[0-9a-f]{64}', '', text)} (capture)"
    return model['name']


def choose(described, models, per_group, groups, names=()):
    """Candidates from the described preset: numeric, global (not per-scene) and not on an expression pedal."""
    found = {}
    for row, chain in enumerate(described['chains']):
        for column, block in enumerate(chain['models']):
            model = models.get(str(block['hash'])) if block['hash'] else None
            if not model or (names and not any(n.lower() in model['name'].lower() for n in names)):
                continue
            for index, param in enumerate(block['params']):
                raw = model['parameters'].get(str(index))
                values = param['values']
                if (not raw or raw.get('hidden') == 'true' or param['scene_mode'] or param['expression']
                        or not values or any(v[0] is None for v in values)):
                    continue
                control = normalize_parameter(raw)
                name = group(raw, control)
                if name in groups:
                    found.setdefault(name, []).append({
                        'group': name, 'row': row, 'column': column, 'index': index,
                        'model_id': str(block['hash']), 'model': block_name(block, model), 'category': model['category'],
                        'name': raw.get('name', ''), 'unit': raw.get('units') or '', 'raw': raw, 'control': control})
    chosen = []
    for name in groups:
        candidates, seen = found.get(name, []), set()
        # Spread each group across as many different models as possible.
        ordered = [c for c in candidates if not (c['model_id'] in seen or seen.add(c['model_id']))]
        ordered += [c for c in candidates if c not in ordered]
        chosen += ordered[:per_group]
    return chosen


def suggestions(models, groups, limit=3):
    """Models that would cover each group, for groups the loaded preset can't."""
    found = {}
    for model in models.values():
        for raw in model['parameters'].values():
            name = group(raw, normalize_parameter(raw)) if raw.get('hidden') != 'true' else None
            if name in groups and model['name'] not in found.setdefault(name, []) and len(found[name]) < limit:
                found[name].append(model['name'])
    return found


def describe_target(t):
    return f"{t['model']} › {t['name']} [{t['group']}] at row {t['row'] + 1}, column {t['column'] + 1}"


def parse_reading(text):
    """The first number on the screen, scaled for a k suffix ("2.0 kHz" is 2000)."""
    match = re.match(r'\s*([-+]?\d*\.?\d+)\s*(k)?', text.replace(',', ''), re.I)
    if not match:
        return None
    number = float(match.group(1)) * (1000 if match.group(2) else 1)
    return number if math.isfinite(number) else None


def probe(qc, describe, target, ask, settle):
    """Write each point, record the user's reading and the device readback, then restore."""
    row, column, index = target['row'], target['column'], target['index']
    def current():
        bp = qc.get_current_preset()
        if bp is None:
            raise RuntimeError('Preset read timed out.')
        return bp, describe(bp)
    bp, before = current()
    block = before['chains'][row]['models'][column]
    if str(block['hash']) != target['model_id'] or before['name'] != target['preset']:
        raise RuntimeError('The preset changed on the QC; stopping without writing.')
    original = block['params'][index]['values']
    readings = []
    try:
        for normalized in points_for(target):
            qc.set_param(row, column, index, normalized)
            time.sleep(settle)
            _, after = current()
            readback = after['chains'][row]['models'][column]['params'][index]['values'][0][0]
            answer = ask(f"  QC shows for {target['name']} at {normalized:.4f}: ")
            if answer.strip().lower() == 'q':
                raise KeyboardInterrupt
            readings.append({'normalized': normalized, 'readback': readback, 'shown': answer.strip(),
                             'shown_number': parse_reading(answer), 'predicted': predict(target, normalized)})
    finally:
        qc.set_param_typed(row, column, index, original)
        _, restored = current()
        target['restored'] = restored['chains'][row]['models'][column]['params'][index]['values'] == original
    return readings


def analyze(record):
    """Largest gap between readings and each prediction, as a share of the parameter's range."""
    t, readings = record['target'], record['readings']
    held = all(abs(r['readback'] - r['normalized']) < 1e-6 for r in readings if r['readback'] is not None)
    if t['group'] in ('toggle', 'combo'):
        shown = [r['shown'].upper() for r in readings]
        expected = [r['predicted']['declared'].upper() for r in readings]
        return {'labels_match': shown == expected, 'latched': held}
    if t['group'] == 'unlabeled_switch':
        return {'shown': [r['shown'] for r in readings], 'latched': held}
    if t['group'] == 'symbolic':
        ends = {r['normalized']: r['shown_number'] for r in readings}
        low, high = ends.get(0), ends.get(1)
        if low is None and t['raw'].get('min_string') and ends.get(0.5) is not None and high is not None:
            # The minimum shows a label such as OFF; extend the line through 0.5 and 1 to find it.
            low = 2 * ends[0.5] - high
        if low is None or high is None or high <= low:
            return {'inferred_range': None}
        errors = [abs(r['shown_number'] - (low + (high - low) * r['normalized'])) / (high - low)
                  for r in readings if r['shown_number'] is not None]
        return {'inferred_range': [low, high], 'linear_max_error': round(max(errors), 4),
                'linear_matches': max(errors) <= TOLERANCE}
    span = float(t['raw']['max']) - float(t['raw']['min'])
    result = {}
    for model in ('linear', 'declared'):
        errors = [abs(r['shown_number'] - r['predicted'][model]) / span for r in record['readings']
                  if r['shown_number'] is not None and model in r['predicted']]
        if errors:
            result[f'{model}_max_error'] = round(max(errors), 4)
            result[f'{model}_matches'] = max(errors) <= TOLERANCE
    result['readings'] = sum(r['shown_number'] is not None for r in record['readings'])
    return result


def report(results):
    lines = []
    for record in results:
        verdict = analyze(record)
        lines.append(f"{describe_target(record['target'])}: " + ', '.join(f'{k}={v}' for k, v in verdict.items()))
    return '\n'.join(lines)


def main(argv=None, connect=None, ask=input):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--plan', action='store_true', help='List targets from the captured preset without USB')
    parser.add_argument('--analyze', type=Path, help='Summarize a saved calibration file')
    parser.add_argument('--groups', default='no_taper,log,power,linear,table,toggle,combo,fader,unlabeled_switch,symbolic',
                        help='Comma-separated groups to probe')
    parser.add_argument('--per-group', type=int, default=3)
    parser.add_argument('--models', default='', help='Comma-separated model names to limit targets to')
    parser.add_argument('--settle', type=float, default=0.3, help='Seconds to wait after each write')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(argv)
    groups = args.groups.split(',')
    names = [n.strip() for n in args.models.split(',') if n.strip()]
    if args.analyze:
        print(report(json.loads(args.analyze.read_text())['results']))
        return
    if args.plan:
        models = catalog_from_xml((CAPTURED / 'live-ModelRepo.xml').read_bytes())
        described = json.loads((CAPTURED / 'initial-preset.json').read_text())
        targets = choose(described, models, args.per_group, groups, names)
        for t in targets:
            print(f"{describe_target(t)}: {len(points_for(t))} points")
        missing = [g for g in groups if g not in {t['group'] for t in targets}]
        for name, examples in suggestions(models, missing).items():
            print(f"No {name} parameters in this preset. Add one of: {', '.join(examples)}")
        return
    print('Use the disposable preset with Cortex Control closed. Values are restored, never saved.')
    if ask(f'Is "{DISPOSABLE}" loaded on the QC? Type yes to continue: ').strip().lower() != 'yes':
        return
    if connect is None:
        from patchbridge.usb import USBAdapter
        from qc_mcp import preset
        def connect():
            adapter = USBAdapter()
            adapter.connect()  # Checks CorOS 4.1.1 and reads the live catalog.
            return adapter.qc, preset.describe, adapter.metadata['models']
    print('Connecting and reading the QC catalog (up to 10 seconds)...', flush=True)
    qc, describe, models = connect()
    output = args.output or ROOT / 'hardware-results' / dt.date.today().isoformat() / 'calibration-probe.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    results = []
    try:
        bp = qc.get_current_preset()
        described = describe(bp)
        if described['name'] != DISPOSABLE:
            raise SystemExit(f'Loaded preset is "{described["name"]}", not "{DISPOSABLE}"; nothing was written.')
        targets = choose(described, models, args.per_group, groups, names)
        print(f'{len(targets)} parameters. Type what the QC screen shows, blank to skip, q to stop.')
        for number, target in enumerate(targets, 1):
            target['preset'] = DISPOSABLE
            print(f'\n[{number}/{len(targets)}] {describe_target(target)}. Open this block on the QC.')
            hint = {'toggle': 'Type the button text, and note whether it stays on or springs back.',
                    'combo': 'Type the option name shown.',
                    'unlabeled_switch': 'Type what the switch shows, for example on, off, lit or unlit.',
                    'symbolic': 'This range is unknown; type the exact value and unit shown.'}.get(target['group'])
            if hint:
                print(f'  {hint}')
            try:
                readings = probe(qc, describe, target, ask, args.settle)
            except KeyboardInterrupt:
                print('\nStopped; the current parameter was restored.')
                break
            finally:
                if 'restored' in target:
                    if not target['restored']:
                        print('  WARNING: the original value did not read back; check this parameter on the QC.')
            results.append({'target': target, 'readings': readings})
            output.write_text(json.dumps({'firmware': '4.1.1', 'preset': DISPOSABLE, 'results': results}, indent=2) + '\n')
    finally:
        qc.close()
    if results:
        print(f'\nSaved {output}\n{report(results)}')
    print('The preset is unsaved. Reload it on the QC to discard the probe edits.')


if __name__ == '__main__':
    main()
