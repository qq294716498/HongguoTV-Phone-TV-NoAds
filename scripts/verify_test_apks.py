import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CERTIFICATE = '55c3c3395a00e56e99b8bfd580b14c99618da74db19692a2e42606eb05c47ba9'
ARCHITECTURES = {'arm64-v8a': (2000, 2, 183), 'armeabi-v7a': (1000, 1, 40)}
LIBRARIES = ('libduanju_core.so', 'libflutter.so', 'libapp.so', 'libmpv.so', 'libffmpegkit.so')


def run(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT)


def validate_apks(directory, package_version, tools, identity):
    match = re.fullmatch(r'(\d+\.\d+\.\d+-test\.\d+)\+([1-9]\d{0,2})', package_version)
    if not match:
        raise ValueError('Only explicitly marked test versions are accepted')
    version, build = match.group(1), int(match.group(2))
    expected_names = {f'HongguoTV-{version}-{abi}.apk' for abi in ARCHITECTURES}
    if {path.name for path in directory.glob('*.apk')} != expected_names:
        raise ValueError('Expected exactly the two ARM test APKs')
    results = []
    for abi, (offset, elf_class, machine) in ARCHITECTURES.items():
        apk = directory / f'HongguoTV-{version}-{abi}.apk'
        badging = run(str(tools / 'aapt'), 'dump', 'badging', str(apk))
        expected = f"package: name='com.hongguo.tv' versionCode='{offset + build}' versionName='{version}'"
        if (not badging.startswith(expected) or "sdkVersion:'26'" not in badging
                or "application-label:'红果TV（测试）'" not in badging
                or 'application-debuggable' in badging or 'application-testOnly' in badging):
            raise ValueError('Test APK identity, label or release mode mismatch: ' + abi)
        signed = run(str(tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk))
        digests = {value.replace(':', '').lower() for value in re.findall(
            r'certificate SHA-256 digest: ([a-fA-F0-9:]+)', signed)}
        if digests != {CERTIFICATE} or not re.search(r'^Number of signers: 1$', signed, re.M):
            raise ValueError('Original signing certificate mismatch: ' + abi)
        run(str(tools / 'zipalign'), '-c', '-P', '16', '4', str(apk))
        with zipfile.ZipFile(apk) as archive:
            if archive.testzip() is not None:
                raise ValueError('APK CRC mismatch: ' + abi)
            native_abis = {name.split('/')[1] for name in archive.namelist()
                           if re.fullmatch(r'lib/[^/]+/[^/]+\.so', name)}
            if native_abis != {abi}:
                raise ValueError('APK contains unexpected architectures: ' + abi)
            for library in LIBRARIES:
                header = archive.read(f'lib/{abi}/{library}')[:20]
                if (len(header) < 20 or header[:4] != b'\x7fELF' or header[4] != elf_class
                        or header[5] != 1 or struct.unpack('<H', header[18:20])[0] != machine):
                    raise ValueError('Native library architecture mismatch: ' + library)
            for filename, key in [('github-avatar.png', 'avatarSha256'), ('app-icon.png', 'brandSha256')]:
                data = archive.read('assets/flutter_assets/assets/app_identity/' + filename)
                if hashlib.sha256(data).hexdigest() != identity[key]:
                    raise ValueError('Identity asset mismatch: ' + filename)
        results.append({
            'name': apk.name, 'bytes': apk.stat().st_size,
            'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
            'package': 'com.hongguo.tv', 'version': version, 'code': offset + build,
            'abi': abi, 'certificate': CERTIFICATE, 'testBuild': True,
            'crcVerified': True, 'zipAlignmentVerified': True,
            'nativeArchitecturesVerified': True, 'identityAssetsVerified': True,
        })
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, default=ROOT / 'dist/android')
    options = parser.parse_args()
    package_version = re.search(r'^version:\s*(\S+)', (ROOT / 'pubspec.yaml').read_text(), re.M).group(1)
    tools = Path(os.environ['ANDROID_HOME']) / 'build-tools'
    sdk = max(tools.iterdir(), key=lambda path: tuple(int(n) for n in re.findall(r'\d+', path.name)))
    identity = json.loads((ROOT / 'assets/app_identity/identity.json').read_text())
    results = validate_apks(options.directory, package_version, sdk, identity)
    commit = run('git', 'rev-parse', 'HEAD').strip()
    if os.environ.get('GITHUB_SHA', commit) != commit:
        raise ValueError('Built source does not match the workflow commit')
    report = {
        'version': package_version, 'sourceCommit': commit, 'testBuild': True,
        'allSources': True, 'baselineCommit': 'ed4c541c56e3afaf326c7f9d312157db99746d61',
        'publicReleaseCreated': False, 'updatesPublished': False, 'apks': results,
        'realDeviceAvSyncVerified': False, 'realDevicePlaybackVerified': False,
    }
    (options.directory / 'APK-test-validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
