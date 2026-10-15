import hashlib
import json
import os
import re
import subprocess
import zipfile
from pathlib import Path


def run(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT)


def main():
    root = Path(__file__).resolve().parents[1]
    version = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(),
                        re.MULTILINE).group(1)
    name, build = version.split('+')
    if name != '0.1.10' or build != '34':
        raise SystemExit('Unexpected release version')
    tools = Path(os.environ['ANDROID_HOME']) / 'build-tools'
    sdk = max(tools.iterdir(), key=lambda p: tuple(int(n) for n in re.findall(r'\d+', p.name)))
    certificate = '55c3c3395a00e56e99b8bfd580b14c99618da74db19692a2e42606eb05c47ba9'
    output = root / 'dist/android'
    results = []
    for abi, offset in [('arm64-v8a', 2000), ('armeabi-v7a', 1000), ('x86_64', 4000)]:
        apk = output / f'HongguoTV-{name}-{abi}.apk'
        badging = run(str(sdk / 'aapt'), 'dump', 'badging', str(apk))
        expected = f"package: name='com.hongguo.tv' versionCode='{offset + int(build)}' versionName='{name}'"
        if not badging.startswith(expected) or "sdkVersion:'26'" not in badging or 'application-debuggable' in badging:
            raise SystemExit('APK identity or release mode mismatch: ' + abi)
        signed = run(str(sdk / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk))
        digests = set(re.findall(r'certificate SHA-256 digest: ([a-fA-F0-9:]+)', signed))
        if digests != {certificate} or 'Number of signers: 1' not in signed:
            raise SystemExit('APK release certificate mismatch: ' + abi)
        run(str(sdk / 'zipalign'), '-c', '-P', '16', '4', str(apk))
        with zipfile.ZipFile(apk) as archive:
            if archive.testzip() is not None:
                raise SystemExit('APK CRC validation failed: ' + abi)
            native_abis = {p.split('/')[1] for p in archive.namelist()
                           if re.fullmatch(r'lib/[^/]+/[^/]+\.so', p)}
            if native_abis != {abi}:
                raise SystemExit('APK ABI mismatch: ' + abi)
        results.append(dict(name=apk.name, bytes=apk.stat().st_size,
                            sha256=hashlib.file_digest(apk.open('rb'), 'sha256').hexdigest(),
                            package='com.hongguo.tv', version=name,
                            code=offset + int(build), abi=abi, certificate=certificate,
                            crcVerified=True, zipAlignmentVerified=True))
    (output / 'APK-validation.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
