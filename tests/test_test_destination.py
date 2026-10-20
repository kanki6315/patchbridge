"""Simulator selection must use device types, availability and scheme support."""
import unittest

from tools.test_destination import select_destination


class DestinationTests(unittest.TestCase):
    def test_filters_devices_and_prefers_project_then_newest_os(self):
        devices = []
        lines = []
        for n, (name, family, available, version) in enumerate([
            ('Custom phone', 'iPhone', True, '27.0'),
            ('New phone', 'iPhone', True, '27.1'),
            ('Patchbridge Review', 'iPhone', True, '26.5'),
            ('Patchbridge iPad', 'iPad', True, '28.0'),
            ('Patchbridge unavailable', 'iPhone', False, '28.0'),
            ('Patchbridge incompatible', 'iPhone', True, '28.0'),
        ]):
            udid = f'00000000-0000-0000-0000-{n:012d}'
            devices.append(dict(name=name, deviceTypeIdentifier=family,
                                isAvailable=available, udid=udid))
            if 'incompatible' in name:
                lines.append('Ineligible destinations for the "Patchbridge" scheme:')
            lines.append(f'{{ platform:iOS Simulator, arch:arm64, id:{udid}, OS:{version}, name:{name} }}')
        inventory = dict(devicetypes=[
            dict(identifier=family, productFamily=family) for family in ['iPhone', 'iPad']
        ], devices={'runtime': devices})
        destinations = '\n'.join(lines)
        self.assertEqual(select_destination(inventory, destinations)['name'], 'Patchbridge Review')
        devices[2]['isAvailable'] = False
        self.assertEqual(select_destination(inventory, destinations)['name'], 'New phone')
