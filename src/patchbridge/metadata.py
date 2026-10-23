"""Versioned control descriptions. Never infer symbolic ranges or option names.

Details the firmware leaves implicit use rules measured on CorOS 4.1.1 hardware
(hardware-results/2026-10-20/calibration-probe*.json): a float or fader with no skew
is linear, LOG_SKEW is a power curve with skew 0.3, lookup tables are linear between
points, comboBox uses the switch encoding, an unlabeled two-step switch is Off/On,
and the range constants in MEASURED_RANGES have the values shown on the QC. A control
with toggleOn/toggleOff naming a switch is active at the switch's toggleStep positions
(toggleOn) or the other positions (toggleOff); without toggleStep, a two-step switch's
toggleOn means 1 and toggleOff 0. A control is active only while its switch is too.
Inactive controls are greyed out on the QC and read-only here. floatWithLed is a float,
and an empty skew is linear. A linear showAsInteger control moves in its declared whole steps.
"""
import math

# Measured on CorOS 4.1.1: 7 of 7 untapered floats were linear, and LOG_SKEW
# controls matched skew 0.3 at every reading.
CALIBRATED_SKEW = {None: 1.0, '': 1.0, 'LOG_SKEW': 0.3}

OPTION_TYPES = ('switch', 'rotarySwitch', 'toggleButton', 'comboBox')
NUMBER_TYPES = ('float', 'fader', 'floatWithLed')
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


def _controller(raw, parameters):
    """The switch a toggleOn/toggleOff control depends on, as (index, normalized values where it is active)."""
    ref = raw.get('toggleOn') or raw.get('toggleOff')
    if parameters is None or not ref or not ref.strip().isdigit():
        return None
    switch = parameters.get(ref.strip())
    try:
        count = int(switch.get('steps', '')) if switch else 0
    except ValueError:
        count = 0
    if not switch or switch.get('type') not in OPTION_TYPES or not 2 <= count <= 1024:
        return None
    listed = raw.get('toggleStep')
    if listed:
        try:
            on = {int(step) for step in listed.split(',')}
        except ValueError:
            return None
        if not on <= set(range(count)):
            return None
    elif count == 2:
        on = {1}
    else:
        return None  # A multi-step switch without toggleStep has no measured meaning.
    active = on if raw.get('toggleOn') else set(range(count)) - on
    return ref.strip(), [step / (count - 1) for step in sorted(active)]


# Meters the QC draws but the player never edits.
METER_TYPES = ('grMeter', 'meter')


def normalize_parameter(raw, parameters=None):
    """parameters: the model's raw parameters by index, needed to resolve conditional controls.

    Three cases stay distinct. Hidden parameters (hidden="true", or an empty layout slot)
    are internal values the QC never shows: they are marked hidden, never editable, and the
    phone leaves them out. Meters are shown read-only. Anything else the QC shows but we
    can't edit yet is unsupported: listed, read-only, with a reason.
    """
    control = _normalize(raw, parameters)
    if raw.get('hidden') == 'true' or raw.get('type') == 'empty':
        control.pop('active_when', None)
        control.update(hidden=True, editable=False, reason='Hidden on the QC.')
    return control


def _normalize(raw, parameters):
    controller = _controller(raw, parameters)
    if controller is not None:
        control = _normalize({k: v for k, v in raw.items() if k not in ('toggleOn', 'toggleOff')}, None)
        if control['editable']:
            control['active_when'] = {'parameter': controller[0], 'values': controller[1]}
        return control
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
    if kind in METER_TYPES:
        control.update(kind='meter', reason='Meter, not a control.')
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
    step = _integer_step(raw, low, high, exponent)
    if step is not None:
        control['step'] = step  # Only whole values, e.g. Transpose SEMITONES.
    return control


def _integer_step(raw, low, high, exponent):
    """The spacing of a linear showAsInteger control whose declared steps land on whole numbers."""
    if raw.get('showAsInteger') != 'true' or exponent != 1.0:
        return None
    try:
        count = int(raw.get('steps', ''))
    except ValueError:
        return None
    if not 2 <= count <= 1024:
        return None
    step = (high - low) / (count - 1)
    if step < 1 or step != round(step) or low != round(low):
        return None
    return step


def normalize_models(models):
    """Add controls without removing original firmware fields used by adapters."""
    for model in models.values():
        for definition in model['parameters'].values():
            definition['control'] = normalize_parameter(definition, model['parameters'])
    return models
