"""Versioned control descriptions. Never infer symbolic ranges or option names.

Details the firmware leaves implicit use rules measured on CorOS 4.1.1 hardware
(hardware-results/2026-10-20/calibration-probe*.json): a float or fader with no skew
is linear, LOG_SKEW is a power curve with skew 0.3, lookup tables are linear between
points, comboBox uses the switch encoding, an unlabeled two-step switch is Off/On,
and the range constants in MEASURED_RANGES have the values shown on the QC.
"""
import math

# Measured on CorOS 4.1.1: 7 of 7 untapered floats were linear, and LOG_SKEW
# controls matched skew 0.3 at every reading.
CALIBRATED_SKEW = {None: 1.0, 'LOG_SKEW': 0.3}

OPTION_TYPES = ('switch', 'rotarySwitch', 'toggleButton', 'comboBox')
NUMBER_TYPES = ('float', 'fader')
# Types whose values the USB adapter may write when their control is editable.
WRITABLE_TYPES = (*NUMBER_TYPES, *OPTION_TYPES)
# Symbolic range constants read off the QC at normalized 0 and 1; all were linear.
MEASURED_RANGES = {'MIN_EQ_DB': -12.0, 'MAX_EQ_DB': 12.0,
                   'MIN_FXLOOP_OUT_GAIN_DB': -40.0, 'MAX_FXLOOP_OUT_GAIN_DB': 0.0,
                   'MIN_FXLOOP_IN_GAIN_DB': -40.0, 'MAX_FXLOOP_IN_GAIN_DB': 12.0}


def _number(value):
    try:
        number = float(value)
        return number if math.isfinite(number) else None
    except (ValueError, TypeError):
        return None


def _table(raw, low, high):
    """Declared xValues/yValues points, or None if they are not a usable increasing table."""
    try:
        xs = [float(x) for x in raw['xValues'].split(',')]
        ys = [float(y) for y in raw['yValues'].split(',')]
    except (KeyError, ValueError, AttributeError):
        return None
    if len(xs) != len(ys) or not 2 <= len(xs) <= 64 or not all(map(math.isfinite, xs + ys)):
        return None
    if xs[0] != 0 or xs[-1] != 1 or (ys[0], ys[-1]) != (low, high):
        return None
    if any(b <= a for a, b in zip(xs, xs[1:])) or any(b <= a for a, b in zip(ys, ys[1:])):
        return None
    return [[x, y] for x, y in zip(xs, ys)]


def normalize_parameter(raw):
    control = {'kind': 'unknown', 'encoding': 'qc_normalized', 'name': raw.get('name', 'Unknown parameter'),
               'unit': raw.get('units') or '', 'editable': False,
               'mapping_source': 'device_metadata', 'verification': 'not_hardware_calibrated'}
    kind = raw.get('type')
    if kind == 'string':
        control.update(kind='text', reason='String writes are not validated.')
        return control
    if kind == 'int':
        # Every int in CorOS 4.1.1 is a device command, routing or calibration setting, or hidden.
        control['reason'] = 'Device command or internal setting, not a tone control.'
        return control
    if kind not in WRITABLE_TYPES:
        control['reason'] = 'Unsupported parameter type.'
        return control
    if raw.get('toggleOn') is not None or raw.get('toggleOff') is not None:
        control['reason'] = 'Conditional control dependencies are not yet implemented.'
        return control
    if kind in OPTION_TYPES:
        try:
            count = int(raw.get('steps', '0'))
        except (TypeError, ValueError):
            count = 0
        labels = raw.get('stepNames', '').split(',')
        if count == 2 and not raw.get('stepNames'):
            # Every unlabeled two-step switch measured showed Off at 0 and On at 1.
            labels = ['Off', 'On']
            control['mapping_source'] = 'hardware_calibration'
        if count < 2 or count > 1024 or len(labels) != count or any(not label.strip() for label in labels):
            control['reason'] = 'Missing or inconsistent option labels.'
            return control
        control.update(kind='enum', editable=True,
                       options=[{'label': label.strip(), 'value': i / (count - 1)} for i, label in enumerate(labels)])
        return control
    low, high = (MEASURED_RANGES.get(raw.get(end), _number(raw.get(end))) for end in ('min', 'max'))
    if raw.get('min') in MEASURED_RANGES or raw.get('max') in MEASURED_RANGES:
        control['mapping_source'] = 'hardware_calibration'
    if low is None or high is None or high <= low:
        control['reason'] = 'Missing, symbolic, or invalid range.'
        return control
    if raw.get('min_string'):
        control['minimum_label'] = raw['min_string']  # Shown instead of the minimum, e.g. OFF.
    if 'xValues' in raw or 'yValues' in raw:
        points = _table(raw, low, high)
        if points is None:
            control['reason'] = 'Inconsistent lookup table.'
            return control
        control.update(kind='number', editable=True, minimum=low, maximum=high,
                       mapping='table', points=points)
        return control
    skew = raw.get('skew')
    if skew in CALIBRATED_SKEW:
        exponent = CALIBRATED_SKEW[skew]
        control['mapping_source'] = 'hardware_calibration'
    else:
        exponent = 1.0 if skew == 'LIN_SKEW' else _number(skew)
    if exponent is None or exponent <= 0:
        control['reason'] = 'Unresolved taper; no conversion is assumed.'
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
