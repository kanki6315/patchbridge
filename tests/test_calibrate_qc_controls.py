"""Calibration probe exercised against a fake QC; never opens USB."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('calibrate', ROOT / 'tools/calibrate_qc_controls.py')
calibrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibrate)


def values(value):
    return [[value, None, None] for _ in range(8)]


def param(value, scene_mode=False, expression=0):
    return {'scene_mode': scene_mode, 'expression': expression, 'values': values(value)}


MODELS = {'7': {'name': 'Test Drive', 'category': 'Guitar Overdrive', 'parameters': {
    '0': {'type': 'float', 'name': 'GAIN', 'min': '0', 'max': '10'},
    '1': {'type': 'float', 'name': 'TONE', 'min': '0', 'max': '10'},
    '2': {'type': 'float', 'name': 'BIAS', 'min': '0', 'max': '10', 'hidden': 'true'},
    '3': {'type': 'toggleButton', 'name': 'FREEZE', 'min': '0', 'max': '1', 'steps': '2', 'stepNames': 'RELEASE,FREEZE'},
    '4': {'type': 'float', 'name': 'LEVEL', 'min': '0', 'max': '10'},
}}}


class FakeQC:
    def __init__(self, name='Tremonti w Mic'):
        self.state = {'name': name, 'chains': [{'models': [
            {'hash': 7, 'params': [param(0.4), param(0.5, scene_mode=True), param(0.1), param(0.0), param(0.6, expression=2)]}]}]}
        self.writes, self.restores, self.closed = [], [], False

    def get_current_preset(self):
        return self.state

    def set_param(self, row, column, index, value):
        self.writes.append((row, column, index, value))
        self.state['chains'][row]['models'][column]['params'][index]['values'] = values(value)

    def set_param_typed(self, row, column, index, original):
        self.restores.append((row, column, index))
        self.state['chains'][row]['models'][column]['params'][index]['values'] = deepcopy(original)

    def close(self):
        self.closed = True


class CalibrationTests(unittest.TestCase):
    def run_probe(self, qc, answers, groups='no_taper,toggle'):
        answers = iter(answers)
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'probe.json'
            with redirect_stdout(io.StringIO()):
                calibrate.main(['--groups', groups, '--settle', '0', '--output', str(output)],
                               connect=lambda: (qc, deepcopy, MODELS), ask=lambda prompt: next(answers))
            return json.loads(output.read_text()) if output.exists() else None

    def test_candidates_skip_hidden_scene_and_expression_parameters(self):
        chosen = calibrate.choose(FakeQC().state, MODELS, 5, ['no_taper', 'toggle'])
        self.assertEqual([(t['name'], t['group']) for t in chosen], [('GAIN', 'no_taper'), ('FREEZE', 'toggle')])

    def test_model_filter_limits_targets(self):
        self.assertEqual(calibrate.choose(FakeQC().state, MODELS, 5, ['no_taper'], ['other']), [])
        self.assertEqual(len(calibrate.choose(FakeQC().state, MODELS, 5, ['no_taper'], ['test drive'])), 1)

    def test_linear_readings_are_recorded_and_every_value_restored(self):
        qc = FakeQC()
        saved = self.run_probe(qc, ['yes', '0', '2.5', '5.0', '7.5', '10', 'FREEZE', 'RELEASE'])
        gain, freeze = saved['results']
        self.assertEqual([r['normalized'] for r in gain['readings']], calibrate.NUMERIC_POINTS)
        self.assertEqual(calibrate.analyze(gain), {'linear_max_error': 0.0, 'linear_matches': True,
                                                  'declared_max_error': 0.0, 'declared_matches': True, 'readings': 5})
        self.assertEqual(calibrate.analyze(freeze), {'labels_match': True, 'latched': True})
        self.assertTrue(gain['target']['restored'] and freeze['target']['restored'])
        self.assertEqual(qc.state['chains'][0]['models'][0]['params'][0]['values'], values(0.4))
        self.assertEqual(qc.restores, [(0, 0, 0), (0, 0, 3)])
        self.assertTrue(qc.closed)

    def test_curved_readings_do_not_match_linear(self):
        saved = self.run_probe(FakeQC(), ['yes', '0', '0.6', '2.5', '5.6', '10'], groups='no_taper')
        verdict = calibrate.analyze(saved['results'][0])
        self.assertFalse(verdict['linear_matches'])
        self.assertAlmostEqual(verdict['linear_max_error'], 0.25)

    def test_quitting_mid_parameter_restores_it(self):
        qc = FakeQC()
        saved = self.run_probe(qc, ['yes', '0', 'q'])
        self.assertIsNone(saved)
        self.assertEqual(qc.restores, [(0, 0, 0)])
        self.assertEqual(qc.state['chains'][0]['models'][0]['params'][0]['values'], values(0.4))

    def test_other_preset_is_never_written(self):
        qc = FakeQC(name='My Live Rig')
        with self.assertRaises(SystemExit):
            self.run_probe(qc, ['yes'])
        self.assertEqual(qc.writes, [])
        self.assertTrue(qc.closed)

    def test_declining_the_prompt_never_connects(self):
        def connect():
            raise AssertionError('connected')
        with redirect_stdout(io.StringIO()):
            calibrate.main([], connect=connect, ask=lambda prompt: 'no')

    def test_table_points_include_midpoints_and_readings_parse_units(self):
        raw = {'type': 'float', 'min': '20', 'max': '200', 'xValues': '0,0.5,1', 'yValues': '20,60,200'}
        target = {'group': 'table', 'raw': raw, 'control': calibrate.normalize_parameter(raw)}
        self.assertEqual(calibrate.points_for(target), [0, 0.25, 0.5, 0.75, 1])
        self.assertEqual(calibrate.predict(target, 0.75), {'linear': 155, 'declared': 130})
        for text, number in [('2.0 kHz', 2000), ('-12 dB', -12), ('1,200 Hz', 1200), ('5', 5), ('OFF', None), ('', None)]:
            self.assertEqual(calibrate.parse_reading(text), number, text)

    def test_pass_three_groups(self):
        def target(raw):
            return {'group': calibrate.group(raw, calibrate.normalize_parameter(raw)), 'raw': raw,
                    'control': calibrate.normalize_parameter(raw)}
        combo = target({'type': 'comboBox', 'min': '0', 'max': '2', 'steps': '3', 'stepNames': 'Normal,Vibrato,Bright'})
        switch = target({'type': 'switch', 'min': '0', 'max': '1', 'steps': '2'})
        fader = target({'type': 'fader', 'min': '0', 'max': '10'})
        symbolic = target({'type': 'float', 'min': 'MIN_EQ_DB', 'max': 'MAX_EQ_DB'})
        self.assertEqual([t['group'] for t in (combo, switch, fader, symbolic)], ['combo', 'unlabeled_switch', 'fader', 'symbolic'])
        self.assertEqual(calibrate.points_for(combo), [0, 0.5, 1])
        self.assertEqual(calibrate.predict(combo, 0.5), {'declared': 'Vibrato'})
        self.assertEqual(calibrate.predict(fader, 0.5), {'linear': 5, 'declared': 5})
        readings = [{'normalized': n, 'readback': n, 'shown': f'{v} dB', 'shown_number': v}
                    for n, v in zip(calibrate.NUMERIC_POINTS, [-12, -6, 0, 6, 12])]
        self.assertEqual(calibrate.analyze({'target': symbolic, 'readings': readings}),
                         {'inferred_range': [-12, 12], 'linear_max_error': 0.0, 'linear_matches': True})
        send = target({'type': 'float', 'min': 'MIN_FXLOOP_OUT_GAIN_DB', 'max': 'MAX_FXLOOP_OUT_GAIN_DB', 'min_string': 'OFF'})
        off = [{'normalized': n, 'readback': n, 'shown': v, 'shown_number': calibrate.parse_reading(v)}
               for n, v in zip(calibrate.NUMERIC_POINTS, ['Off', '-30.0 db', '-20.0 db', '-10.0 db', '0.0 db'])]
        self.assertEqual(calibrate.analyze({'target': send, 'readings': off})['inferred_range'], [-40, 0])
        self.assertEqual(calibrate.analyze({'target': switch, 'readings': [
            {'normalized': 0, 'readback': 0.0, 'shown': 'off'}, {'normalized': 1, 'readback': 1.0, 'shown': 'on'}]}),
            {'shown': ['off', 'on'], 'latched': True})
        self.assertIsNone(calibrate.group({'type': 'switch', 'steps': '2', 'toggleOn': '3'}, {'editable': False}))

    def test_conditional_switch_shows_which_controls_appear(self):
        models = {'9': {'name': 'Sync Delay', 'category': 'Delay', 'parameters': {
            '0': {'type': 'switch', 'name': 'SYNC', 'steps': '2', 'stepNames': 'Off,On'},
            '1': {'type': 'float', 'name': 'SYNC NOTE', 'min': '0', 'max': '1', 'toggleOn': '0'},
            '2': {'type': 'float', 'name': 'DELAY TIME', 'min': '0', 'max': '1', 'toggleOff': '0'},
            '3': {'type': 'float', 'name': 'MIX', 'min': '0', 'max': '100'}}}}
        qc = FakeQC()
        qc.state['chains'][0]['models'][0] = {'hash': 9, 'params': [param(0.0), param(0.2), param(0.3), param(0.5)]}
        answers = iter(['yes', '2', '1'])
        with tempfile.TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()):
            output = Path(tmp) / 'probe.json'
            calibrate.main(['--groups', 'conditional', '--settle', '0', '--output', str(output)],
                           connect=lambda: (qc, deepcopy, models), ask=lambda prompt: next(answers))
            record, = json.loads(output.read_text())['results']
        self.assertEqual([d['name'] for d in record['target']['dependents']], ['SYNC NOTE', 'DELAY TIME'])
        self.assertEqual([r['active'] for r in record['readings']], [['DELAY TIME'], ['SYNC NOTE']])
        self.assertEqual(calibrate.analyze(record), {'rule_matches': True, 'inverted_matches': False, 'latched': True})
        self.assertEqual(qc.state['chains'][0]['models'][0]['params'][0]['values'], values(0.0))

    def test_capture_blocks_use_the_capture_name(self):
        model = {'name': 'Eltron 30', 'parameters': {'0': {'name': 'BASS'}, '1': {'name': 'file_name'}}}
        block = {'params': [param(0.5), {'values': [[None, None, '1e64c27a1335d9061530283b7c6b22c16f1a7abe0398ba36dfc77e6f462be2c2OG TS808']]}]}
        self.assertEqual(calibrate.block_name(block, model), 'OG TS808 (capture)')
        self.assertEqual(calibrate.block_name({'params': [param(0.5)]}, model), 'Eltron 30')


if __name__ == '__main__':
    unittest.main()
