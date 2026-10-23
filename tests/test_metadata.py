import unittest
from patchbridge.metadata import normalize_parameter

class MetadataTests(unittest.TestCase):
    def test_explicit_linear_and_numeric_skew(self):
        for skew, exponent in [('LIN_SKEW', 1), ('0.6', 0.6)]:
            c = normalize_parameter({'type': 'float', 'name': 'Rate', 'min': '0.5', 'max': '6.5', 'skew': skew})
            self.assertTrue(c['editable'])
            self.assertEqual(c['exponent'], exponent)
            self.assertEqual(c['verification'], 'not_hardware_calibrated')

    def test_integer_controls_move_in_whole_steps(self):
        semitones = {'type': 'float', 'name': 'SEMITONES', 'min': '-12', 'max': '12', 'steps': '25',
                     'skew': 'LIN_SKEW', 'showAsInteger': 'true'}
        self.assertEqual(normalize_parameter(semitones)['step'], 1.0)
        # No step without showAsInteger, without whole spacing, or on a curved taper.
        for changes in ({'showAsInteger': 'false'}, {'steps': '49'}, {'steps': ''}, {'skew': '0.5'}):
            self.assertNotIn('step', normalize_parameter({**semitones, **changes}), changes)

    def test_implicit_tapers_use_hardware_calibration(self):
        for patch, exponent in [({}, 1.0), ({'skew': 'LOG_SKEW'}, 0.3)]:
            c = normalize_parameter({'type': 'float', 'min': '20', 'max': '10000'} | patch)
            self.assertTrue(c['editable'])
            self.assertEqual((c['mapping'], c['exponent'], c['mapping_source']), ('power', exponent, 'hardware_calibration'))
        self.assertEqual(normalize_parameter({'type': 'float', 'min': '0', 'max': '1', 'skew': '0.6'})['mapping_source'],
                         'device_metadata')

    def test_unknown_mapping_never_gets_guessed(self):
        base = {'type': 'float', 'min': '0', 'max': '10'}
        for patch in [{'skew': 'CUSTOM_SKEW'}, {'skew': '-1'}, {'skew': 'nan'},
                      {'skew': 'LIN_SKEW', 'min': 'MIN_GAIN'}, {'skew': 'LIN_SKEW', 'max': '0'}]:
            self.assertFalse(normalize_parameter(base | patch)['editable'])

    def test_options_keep_labels_and_wire_values(self):
        c = normalize_parameter({'type': 'switch', 'steps': '2', 'stepNames': 'Chorus,Vibe'})
        self.assertEqual(c['kind'], 'enum')
        self.assertEqual(c['options'], [{'label': 'Chorus', 'value': 0}, {'label': 'Vibe', 'value': 1}])
        for patch in [{'stepNames': 'Off,'}, {'steps': '3'}, {'toggleOn': '6'}]:
            self.assertFalse(normalize_parameter({'type': 'switch', 'steps': '2', 'stepNames': 'Off,On'} | patch)['editable'])

    def test_unknown_and_string_types_are_read_only(self):
        for kind in ['string', 'grMeter', 'future-type']:
            self.assertFalse(normalize_parameter({'type': kind})['editable'])

    def test_pass_three_calibration_rules(self):
        combo = normalize_parameter({'type': 'comboBox', 'steps': '3', 'stepNames': 'Normal,Vibrato,Bright'})
        self.assertEqual([o['value'] for o in combo['options']], [0, 0.5, 1])
        fader = normalize_parameter({'type': 'fader', 'min': '-12', 'max': '12', 'steps': '241'})
        self.assertEqual((fader['editable'], fader['exponent']), (True, 1.0))
        switch = normalize_parameter({'type': 'switch', 'steps': '2'})
        self.assertEqual((switch['options'], switch['mapping_source']),
                         ([{'label': 'Off', 'value': 0}, {'label': 'On', 'value': 1}], 'hardware_calibration'))
        self.assertFalse(normalize_parameter({'type': 'switch', 'steps': '3'})['editable'])
        send = normalize_parameter({'type': 'float', 'min': 'MIN_FXLOOP_OUT_GAIN_DB', 'max': 'MAX_FXLOOP_OUT_GAIN_DB', 'min_string': 'OFF'})
        self.assertEqual((send['minimum'], send['maximum'], send['minimum_label']), (-40, 0, 'OFF'))
        for unmeasured in ['MIN_CABSIM_DB', 'MIN_MIXER_DB']:
            self.assertFalse(normalize_parameter({'type': 'float', 'min': unmeasured, 'max': unmeasured.replace('MIN', 'MAX')})['editable'])

    def test_conditional_controls_follow_their_two_step_switch(self):
        params = {'0': {'type': 'switch', 'name': 'SYNC', 'steps': '2', 'stepNames': 'Off,On'},
                  '1': {'type': 'float', 'name': 'SYNC NOTE', 'min': '0', 'max': '1', 'toggleOn': '0'},
                  '2': {'type': 'float', 'name': 'DELAY TIME', 'min': '0', 'max': '1', 'toggleOff': '0'},
                  '3': {'type': 'comboBox', 'name': 'KEY', 'steps': '3', 'stepNames': 'A,B,C'},
                  '4': {'type': 'float', 'name': 'TAP', 'min': '0', 'max': '1', 'toggleOn': '3'},
                  '5': {'type': 'float', 'name': 'PAN', 'min': '0', 'max': '1', 'toggleOn': '0,3'},
                  '6': {'type': 'float', 'name': 'LEVEL', 'min': 'MIN_MIXER_DB', 'max': 'MAX_MIXER_DB', 'toggleOn': '0'}}
        self.assertEqual(normalize_parameter(params['1'], params)['active_when'], {'parameter': '0', 'values': [1.0]})
        self.assertEqual(normalize_parameter(params['2'], params)['active_when'], {'parameter': '0', 'values': [0.0]})
        for index in ('4', '5', '6'):
            self.assertFalse(normalize_parameter(params[index], params)['editable'], index)
        self.assertFalse(normalize_parameter(params['1'])['editable'])  # Without the model, the switch is unknown.

    def test_multi_step_conditionals_use_toggle_step(self):
        params = {'0': {'type': 'comboBox', 'name': 'MOD SOURCE', 'steps': '4', 'stepNames': 'LFO,LFO St,+Env,-Env'},
                  '1': {'type': 'float', 'name': 'LFO RATE', 'min': '0', 'max': '1', 'toggleOn': '0', 'toggleStep': '0,1'},
                  '2': {'type': 'float', 'name': 'ROOT', 'min': '0', 'max': '1', 'toggleOff': '0', 'toggleStep': '2'},
                  '3': {'type': 'float', 'name': 'BAD', 'min': '0', 'max': '1', 'toggleOn': '0', 'toggleStep': '7'}}
        self.assertEqual(normalize_parameter(params['1'], params)['active_when']['values'], [0, 1 / 3])
        self.assertEqual(normalize_parameter(params['2'], params)['active_when']['values'], [0, 1 / 3, 1])
        self.assertFalse(normalize_parameter(params['3'], params)['editable'])

    def test_led_float_and_empty_skew_are_linear(self):
        led = normalize_parameter({'type': 'floatWithLed', 'min': '-40', 'max': '0', 'min_string': 'OFF', 'steps': '401'})
        self.assertEqual((led['editable'], led['exponent'], led['minimum_label']), (True, 1.0, 'OFF'))
        decay = normalize_parameter({'type': 'float', 'min': '0', 'max': '100', 'skew': ''})
        self.assertEqual((decay['exponent'], decay['mapping_source']), (1.0, 'hardware_calibration'))

    def test_hidden_parameters_are_never_editable(self):
        # Transpose's MIX: a valid float the QC never shows.
        mix = {'type': 'float', 'name': 'MIX', 'min': '0', 'max': '100', 'skew': 'LIN_SKEW', 'hidden': 'true'}
        for raw in [mix, {'type': 'empty', 'name': 'DUMMY1'}]:
            control = normalize_parameter(raw)
            self.assertEqual((control['hidden'], control['editable'], control['reason']),
                             (True, False, 'Hidden on the QC.'), raw)
        self.assertNotIn('hidden', normalize_parameter(dict(mix, hidden='false')))
        switch = {'type': 'switch', 'steps': '2'}
        rate = normalize_parameter({'type': 'float', 'min': '0', 'max': '1', 'toggleOff': '0', 'hidden': 'true'},
                                   {'0': switch})
        self.assertNotIn('active_when', rate)

    def test_meters_are_shown_read_only_and_unsupported_controls_stay_visible(self):
        for raw in [{'type': 'grMeter', 'name': 'GAIN REDUCTION'}, {'type': 'meter'}]:
            control = normalize_parameter(raw)
            self.assertEqual((control['kind'], control['editable']), ('meter', False), raw)
            self.assertNotIn('hidden', control)
        cab = normalize_parameter({'type': 'float', 'min': 'MIN_CABSIM_DB', 'max': '0'})
        self.assertFalse(cab['editable'])
        self.assertNotIn('hidden', cab)

    def test_int_commands_stay_read_only(self):
        c = normalize_parameter({'type': 'int', 'name': 'EXPORT MODEL', 'min': '0', 'max': '1', 'steps': '2'})
        self.assertFalse(c['editable'])
        self.assertIn('Device command', c['reason'])

    def test_toggle_button_uses_its_labels(self):
        c = normalize_parameter({'type': 'toggleButton', 'min': '0', 'max': '1', 'steps': '2', 'stepNames': 'RELEASE,FREEZE'})
        self.assertEqual(c['options'], [{'label': 'RELEASE', 'value': 0}, {'label': 'FREEZE', 'value': 1}])

    def test_declared_lookup_table(self):
        raw = {'type': 'float', 'units': 'Hz', 'min': '20', 'max': '200',
               'xValues': '0,0.5,1', 'yValues': '20,60,200'}
        c = normalize_parameter(raw)
        self.assertEqual((c['mapping'], c['points'], c['minimum'], c['maximum']),
                         ('table', [[0, 20], [0.5, 60], [1, 200]], 20, 200))
        for patch in [{'yValues': '20,60'}, {'xValues': '0,0.6,0.5'}, {'yValues': '20,10,200'},
                      {'xValues': '0.1,0.5,1'}, {'max': '250'}, {'yValues': '20,x,200'}, {'xValues': None}]:
            bad = {k: v for k, v in (raw | patch).items() if v is not None}
            c = normalize_parameter(bad)
            self.assertFalse(c['editable'])
            self.assertEqual(c['reason'], 'Inconsistent lookup table.')
