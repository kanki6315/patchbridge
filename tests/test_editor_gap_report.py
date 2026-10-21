"""Gap report classification on a small catalog; never opens USB."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gap_report', ROOT / 'tools/editor_gap_report.py')
gap_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gap_report)

XML = b'''<Models><Category name="Drive">
<Model id="1" name="Easy"><Parameter type="float" name="GAIN" min="0" max="10" skew="LIN_SKEW"/>
<Parameter type="switch" name="MODE" steps="2" stepNames="A,B"/></Model>
<Model id="2" name="Hard"><Parameter type="float" name="TONE" min="0" max="10" skew=""/>
<Parameter type="float" name="BIAS" min="0" max="10" hidden="true"/>
<Parameter type="float" name="FREQ" min="20" max="200" xValues="0,1" yValues="20,200"/></Model>
</Category></Models>'''


class GapReportTests(unittest.TestCase):
    def test_hidden_parameters_are_excluded_and_reasons_counted(self):
        summary = gap_report.summarize(gap_report.classify(XML), top=5)
        self.assertEqual((summary['parameters'], summary['hidden'], summary['visible'], summary['editable']), (5, 1, 4, 3))
        self.assertEqual(summary['fully_editable_models'], 1)
        self.assertEqual(dict(summary['status'])['Unresolved taper; no conversion is assumed.'], 1)
        self.assertEqual(dict(summary['mappings']), {'power': 1, 'enum': 1, 'table': 1})
        self.assertEqual(summary['largest_gaps'][0], {'category': 'Drive', 'model': 'Hard', 'read_only': 1, 'visible': 2})
        self.assertIn('**3 (75%)**', gap_report.markdown(summary))


if __name__ == '__main__':
    unittest.main()
