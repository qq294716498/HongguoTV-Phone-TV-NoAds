import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class TelevisionBackTests(unittest.TestCase):
    def test_back_key_pairs_repeats_cancellation_and_reset(self):
        if not shutil.which('javac') or not shutil.which('java'):
            self.skipTest('JDK required for native television key regression')
        root = Path(__file__).resolve().parents[1] / 'android/app/src'
        source = root / 'main/java/com/hongguo/tv/TelevisionBackKey.java'
        test = root / 'test/java/com/hongguo/tv/TelevisionBackKeyTest.java'
        with tempfile.TemporaryDirectory() as output:
            subprocess.run(['javac', '-d', output, str(source), str(test)], check=True)
            subprocess.run(['java', '-cp', output, 'com.hongguo.tv.TelevisionBackKeyTest'], check=True)


if __name__ == '__main__':
    unittest.main()
