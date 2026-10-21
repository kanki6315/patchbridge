import unittest
from patchbridge.metadata import normalize_parameter

class MetadataTests(unittest.TestCase):
    def test_explicit_linear_and_numeric_skew(self):
        for skew, exponent in [('LIN_SKEW', 1), ('0.6', 0.6)]:
            c = normalize_parameter({'type': 'float', 'name': 'Rate', 'min': '0.5', 'max': '6.5', 'skew': skew})
            self.assertTrue(c['editable'])
            self.assertEqual(c['exponent'], exponent)
            self.assertEqual(c['verification'], 'not_hardware_calibrated')

    def test_implicit_tapers_use_hardware_calibration(self):
        for patch, exponent in [({}, 1.0), ({'skew': 'LOG_SKEW'}, 0.3)]:
            c = normalize_parameter({'type': 'float', 'min': '20', 'max': '10000'} | patch)
            self.assertTrue(c['editable'])
            self.assertEqual((c['mapping'], c['exponent'], c['mapping_source']), ('power', exponent, 'hardware_calibration'))
        self.assertEqual(normalize_parameter({'type': 'float', 'min': '0', 'max': '1', 'skew': '0.6'})['mapping_source'],
                         'device_metadata')

    def test_unknown_mapping_never_gets_guessed(self):
        base = {'type': 'float', 'min': '0', 'max': '10'}
        for patch in [{'skew': ''}, {'skew': 'CUSTOM_SKEW'}, {'skew': '-1'}, {'skew': 'nan'},
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
