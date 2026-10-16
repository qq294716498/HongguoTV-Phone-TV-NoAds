import hashlib
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

from verify_windows_package import ico_images

root = Path(__file__).resolve().parents[1]


class WindowsIdentityTests(unittest.TestCase):
    def test_android_actual_icon_reference_and_windows_multi_size_identity_match(self):
        android = root / 'android/app/src/main/res'
        namespace = '{http://schemas.android.com/apk/res/android}'
        application = ET.parse(root / 'android/app/src/main/AndroidManifest.xml').getroot().find('application')
        self.assertEqual(application.attrib[namespace + 'icon'], '@drawable/app_icon')
        drawable = ET.parse(android / 'drawable/app_icon.xml').getroot()
        self.assertEqual(drawable.attrib[namespace + 'src'], '@drawable/hongguo_logo')
        identity = json.loads((root / 'assets/app_identity/identity.json').read_text())
        brand = (root / identity['androidBrandSource']).read_bytes()
        self.assertEqual(hashlib.sha256(brand).hexdigest(), identity['brandSha256'])
        self.assertEqual(brand, (root / 'assets/app_identity/app-icon.png').read_bytes())
        icon = (root / 'windows/runner/resources/app_icon.ico').read_bytes()
        self.assertEqual(hashlib.sha256(icon).hexdigest(), identity['windowsIcoSha256'])
        frames = ico_images(icon)
        self.assertEqual([width for width, _, _ in frames], [16, 20, 24, 32, 40, 48, 64, 128, 256])
        for width, height, data in frames:
            self.assertEqual(width, height)
            self.assertTrue(data.startswith(b'\x89PNG\r\n\x1a\n'))

    def test_bundled_avatar_has_verified_public_profile_identity(self):
        identity = json.loads((root / 'assets/app_identity/identity.json').read_text())
        self.assertEqual(identity['githubLogin'], 'qq294716498')
        self.assertEqual(identity['githubId'], 47776530)
        self.assertEqual(identity['avatarSource'], 'https://avatars.githubusercontent.com/u/47776530?v=4')
        avatar = (root / 'assets/app_identity/github-avatar.png').read_bytes()
        self.assertEqual(hashlib.sha256(avatar).hexdigest(), identity['avatarSha256'])
        self.assertTrue(avatar.startswith(b'\x89PNG\r\n\x1a\n'))


if __name__ == '__main__':
    unittest.main()
