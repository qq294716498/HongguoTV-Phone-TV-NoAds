import unittest

from verify_windows_package import validate_release_imports


class WindowsReleaseImportsTest(unittest.TestCase):
    def test_release_and_system_imports_are_accepted(self):
        validate_release_imports({'kernel32.dll', 'vcruntime140.dll', 'msvcp140.dll',
                                  'vcruntime140_1.dll', 'api-ms-win-crt-runtime-l1-1-0.dll'})

    def test_angle_debug_dependencies_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'debug runtime'):
            validate_release_imports({'kernel32.dll', 'msvcp140d.dll', 'ucrtbased.dll',
                                      'vcruntime140d.dll'})

    def test_debug_runtime_is_rejected_independent_of_case_or_optional_suffix(self):
        for name in ['UCRTBASED.DLL', 'VCRUNTIME140D.DLL', 'msvcp140_1d.dll', 'concrt140d.dll']:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, name):
                validate_release_imports({name})


if __name__ == '__main__':
    unittest.main()
