import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('release_metadata', Path(__file__).resolve().parents[1] / 'Scripts/release_metadata.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.project = {'objects': {
            'testRelease': {'isa': 'XCBuildConfiguration', 'name': 'Release', 'buildSettings': {'MARKETING_VERSION': '1.0', 'CURRENT_PROJECT_VERSION': '1'}},
            'target': {'isa': 'PBXNativeTarget', 'name': 'macshot', 'buildConfigurationList': 'configs'},
            'configs': {'buildConfigurations': ['appRelease']},
            'appRelease': {'isa': 'XCBuildConfiguration', 'name': 'Release', 'buildSettings': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.itvx.macshot', 'MARKETING_VERSION': '4.3.0', 'CURRENT_PROJECT_VERSION': '900003'}}}}

    def test_ignores_test_target_settings_that_appear_first(self):
        self.assertEqual(module.release_metadata(self.project), ('4.3.0', '900003'))

    def test_rejects_wrong_identity_or_downgraded_build(self):
        for key, value in [('PRODUCT_BUNDLE_IDENTIFIER', 'com.other.app'), ('CURRENT_PROJECT_VERSION', '1'), ('CURRENT_PROJECT_VERSION', 'beta'), ('MARKETING_VERSION', 'bad')]:
            project = copy.deepcopy(self.project)
            project['objects']['appRelease']['buildSettings'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                module.release_metadata(project)

    def test_rejects_missing_or_ambiguous_app_target(self):
        self.project['objects']['duplicate'] = self.project['objects']['target']
        with self.assertRaises(ValueError): module.release_metadata(self.project)
        del self.project['objects']['duplicate']
        del self.project['objects']['target']
        with self.assertRaises(ValueError): module.release_metadata(self.project)

if __name__ == '__main__': unittest.main()
