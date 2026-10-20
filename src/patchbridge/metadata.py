"""Versioned control descriptions. Never infer skew, symbolic ranges, or option names."""
import math


def _number(value):
    try:
        number = float(value)
        return number if math.isfinite(number) else None
    except (ValueError, TypeError):
        return None


def normalize_parameter(raw):
    control = {'kind': 'unknown', 'encoding': 'qc_normalized', 'name': raw.get('name', 'Unknown parameter'),
               'unit': raw.get('units') or '', 'editable': False,
               'mapping_source': 'device_metadata', 'verification': 'not_hardware_calibrated'}
    kind = raw.get('type')
    if kind == 'string':
        control.update(kind='text', reason='String writes are not validated.')
        return control
    if kind not in ('float', 'switch', 'rotarySwitch'):
        control['reason'] = 'Unsupported parameter type.'
        return control
    if raw.get('toggleOn') is not None or raw.get('toggleOff') is not None:
        control['reason'] = 'Conditional control dependencies are not yet implemented.'
        return control
    if kind in ('switch', 'rotarySwitch'):
        try:
            count = int(raw.get('steps', '0'))
        except (TypeError, ValueError):
            count = 0
        labels = raw.get('stepNames', '').split(',')
        if count < 2 or count > 1024 or len(labels) != count or any(not label.strip() for label in labels):
            control['reason'] = 'Missing or inconsistent option labels.'
            return control
        control.update(kind='enum', editable=True,
                       options=[{'label': label.strip(), 'value': i / (count - 1)} for i, label in enumerate(labels)])
        return control
    low, high = _number(raw.get('min')), _number(raw.get('max'))
    if low is None or high is None or high <= low:
        control['reason'] = 'Missing, symbolic, or invalid range.'
        return control
    skew = raw.get('skew')
    exponent = 1.0 if skew == 'LIN_SKEW' else _number(skew)
    if exponent is None or exponent <= 0:
        control['reason'] = 'Missing or unresolved taper; no conversion is assumed.'
        return control
    control.update(kind='number', editable=True, minimum=low, maximum=high,
                   mapping='power', exponent=exponent)
    return control


def normalize_models(models):
    """Add controls without removing original firmware fields used by adapters."""
    for model in models.values():
        for definition in model['parameters'].values():
            definition['control'] = normalize_parameter(definition)
    return models
