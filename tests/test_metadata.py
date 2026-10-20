import unittest
from patchbridge.metadata import normalize_parameter

class MetadataTests(unittest.TestCase):
    def test_explicit_linear_and_numeric_skew(self):
        for skew, exponent in [('LIN_SKEW', 1), ('0.6', 0.6)]:
            c = normalize_parameter({'type': 'float', 'name': 'Rate', 'min': '0.5', 'max': '6.5', 'skew': skew})
            self.assertTrue(c['editable'])
            self.assertEqual(c['exponent'], exponent)
            self.assertEqual(c['verification'], 'not_hardware_calibrated')

    def test_unknown_mapping_never_gets_guessed(self):
        base = {'type': 'float', 'min': '0', 'max': '10'}
        for patch in [{}, {'skew': 'LOG_SKEW'}, {'skew': '-1'}, {'skew': 'nan'},
                      {'skew': 'LIN_SKEW', 'min': 'MIN_GAIN'}, {'skew': 'LIN_SKEW', 'max': '0'}]:
            self.assertFalse(normalize_parameter(base | patch)['editable'])

    def test_options_keep_labels_and_wire_values(self):
        c = normalize_parameter({'type': 'switch', 'steps': '2', 'stepNames': 'Chorus,Vibe'})
        self.assertEqual(c['kind'], 'enum')
        self.assertEqual(c['options'], [{'label': 'Chorus', 'value': 0}, {'label': 'Vibe', 'value': 1}])
        for patch in [{'stepNames': ''}, {'steps': '3'}, {'toggleOn': '6'}]:
            self.assertFalse(normalize_parameter({'type': 'switch', 'steps': '2', 'stepNames': 'Off,On'} | patch)['editable'])

    def test_unknown_and_string_types_are_read_only(self):
        for kind in ['string', 'grMeter', 'future-type']:
            self.assertFalse(normalize_parameter({'type': kind})['editable'])
