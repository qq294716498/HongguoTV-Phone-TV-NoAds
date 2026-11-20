import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


class UpdaterArtifactContractTests(unittest.TestCase):
    def test_all_source_android_artifacts_match_updater_contract(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            (fixture / 'scripts').mkdir()
            for name in ['app_build.py', 'package_release.py']:
                shutil.copy2(root / 'scripts' / name, fixture / 'scripts' / name)
            (fixture / 'pubspec.yaml').write_text('version: 0.1.6+28\n')
            apks = fixture / 'build/app/outputs/flutter-apk'
            apks.mkdir(parents=True)
            for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
                with zipfile.ZipFile(apks / f'app-{abi}-release.apk', 'w') as archive:
                    for library in ['libduanju_core.so', 'libflutter.so', 'libapp.so', 'libmpv.so', 'libffmpegkit.so']:
                        archive.writestr(f'lib/{abi}/{library}', b'synthetic fixture')
            subprocess.run([sys.executable, str(fixture / 'scripts/package_release.py'),
                            '--platform', 'android', '--all-sources'], check=True, capture_output=True)
            artifacts = fixture / 'dist/android'
            expected = {f'HongguoTV-0.1.6-{abi}.apk' for abi in ['arm64-v8a', 'armeabi-v7a']}
            self.assertEqual({p.name for p in artifacts.glob('*.apk')}, expected)
            self.assertEqual({line.split('  ')[1] for line in (artifacts / 'SHA256SUMS.txt').read_text().splitlines()}, expected)
            subprocess.run([sys.executable, str(fixture / 'scripts/package_release.py'),
                            '--platform', 'android', '--abi', 'arm64-v8a'], check=True, capture_output=True)
            self.assertTrue((artifacts / 'HongguoTV-0.1.6-arm64-v8a.apk').is_file())
            self.assertNotIn('armeabi-v7a', (artifacts / 'SHA256SUMS.txt').read_text())


if __name__ == '__main__':
    unittest.main()
