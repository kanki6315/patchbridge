#!/usr/bin/env python3
"""Report which QC parameters the phone can edit, and why the rest are read-only.

Reads a captured ModelRepo.xml offline and classifies every parameter with the same
rules the bridge uses. Parameters marked hidden in the catalog aren't shown on the QC,
so they're counted separately. Never opens USB.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src'))
from patchbridge.metadata import normalize_parameter  # noqa: E402

DEFAULT_CATALOG = ROOT / 'hardware-results/2026-10-20/live-ModelRepo.xml'
EDITABLE = 'Editable'


def classify(xml):
    """One row per parameter: category, model, name, type, hidden, status, mapping."""
    rows = []
    for category in ET.fromstring(xml).findall('Category'):
        for model in category.findall('Model'):
            parameters = {str(i): dict(p.attrib) for i, p in enumerate(model.findall('Parameter'))}
            for index, parameter in enumerate(model.findall('Parameter')):
                raw = dict(parameter.attrib)
                control = normalize_parameter(raw, parameters)
                rows.append({'category': category.get('name'), 'model': model.get('name'),
                             'model_id': model.get('id'), 'index': index, 'name': raw.get('name', ''),
                             'type': raw.get('type', ''), 'hidden': raw.get('hidden') == 'true',
                             'status': EDITABLE if control['editable'] else control['reason'],
                             'mapping': control.get('mapping') or control['kind']})
    return rows


def summarize(rows, top):
    visible = [r for r in rows if not r['hidden']]
    models = defaultdict(list)
    for row in visible:
        models[(row['category'], row['model'])].append(row)
    categories = defaultdict(Counter)
    for row in visible:
        categories[row['category']]['total'] += 1
        categories[row['category']]['editable'] += row['status'] == EDITABLE
    gaps = sorted(((sum(r['status'] != EDITABLE for r in params), len(params), category, model)
                   for (category, model), params in models.items()), reverse=True)
    return {
        'parameters': len(rows), 'hidden': len(rows) - len(visible), 'visible': len(visible),
        'editable': sum(r['status'] == EDITABLE for r in visible),
        'models': len(models),
        'fully_editable_models': sum(all(r['status'] == EDITABLE for r in p) for p in models.values()),
        'status': Counter(r['status'] for r in visible).most_common(),
        'mappings': Counter(r['mapping'] for r in visible if r['status'] == EDITABLE).most_common(),
        'categories': sorted(([name, c['editable'], c['total']] for name, c in categories.items()),
                             key=lambda item: item[1] / item[2]),
        'largest_gaps': [{'category': c, 'model': m, 'read_only': gap, 'visible': total}
                         for gap, total, c, m in gaps[:top]],
    }


def percent(part, whole):
    return f'{100 * part / whole:.0f}%' if whole else '–'


def markdown(summary):
    s = summary
    lines = [
        '# Editor gap report', '',
        f"{s['visible']} visible parameters across {s['models']} models "
        f"({s['hidden']} more are hidden on the QC and not counted).", '',
        f"- Editable: **{s['editable']} ({percent(s['editable'], s['visible'])})**",
        f"- Fully editable models: {s['fully_editable_models']} of {s['models']}", '',
        '## Why parameters are read-only', '', '| Parameters | Share | Status |', '|---:|---:|---|',
        *(f'| {n} | {percent(n, s["visible"])} | {status} |' for status, n in s['status']), '',
        '## Editable by mapping', '', '| Parameters | Mapping |', '|---:|---|',
        *(f'| {n} | {mapping} |' for mapping, n in s['mappings']), '',
        '## By category (least editable first)', '', '| Category | Editable | Visible | Share |', '|---|---:|---:|---:|',
        *(f'| {name} | {e} | {t} | {percent(e, t)} |' for name, e, t in s['categories']), '',
        '## Models with the most read-only parameters', '', '| Model | Category | Read-only | Visible |', '|---|---|---:|---:|',
        *(f"| {g['model']} | {g['category']} | {g['read_only']} | {g['visible']} |" for g in s['largest_gaps']), '',
    ]
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--catalog', type=Path, default=DEFAULT_CATALOG, help='Captured ModelRepo.xml')
    parser.add_argument('--model', help='List every parameter of models whose name contains this text')
    parser.add_argument('--top', type=int, default=25, help='Models listed under largest gaps')
    parser.add_argument('--json', action='store_true', help='Print JSON instead of Markdown')
    args = parser.parse_args(argv)
    if not args.catalog.is_file():
        parser.error(f'{args.catalog} not found; pass --catalog with a captured ModelRepo.xml')
    rows = classify(args.catalog.read_bytes())
    if args.model:
        rows = [r for r in rows if args.model.lower() in r['model'].lower()]
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for r in rows:
                hidden = ' (hidden)' if r['hidden'] else ''
                print(f"{r['model']} #{r['index']} {r['name']} [{r['type']}]{hidden}: {r['status']}")
        return
    summary = summarize(rows, args.top)
    print(json.dumps(summary, indent=2) if args.json else markdown(summary))


if __name__ == '__main__':
    main()
