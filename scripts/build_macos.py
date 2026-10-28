import hashlib
import json
import plistlib
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version_line = next(line for line in (root / 'pubspec.yaml').read_text().splitlines() if line.startswith('version:'))
version, build = version_line.split(':', 1)[1].strip().split('+')
subprocess.run(['python3', 'scripts/build_native.py', '--platform', 'darwin'], cwd=root, check=True)
subprocess.run(['flutter', 'build', 'macos', '--release'], cwd=root, check=True)
app = root / 'build/macos/Build/Products/Release/HongguoTV.app'
core = app / 'Contents/Frameworks/libduanju_core.dylib'
core.write_bytes((root / 'native/build/darwin/libduanju_core.dylib').read_bytes())
subprocess.run(['install_name_tool', '-id', '@rpath/libduanju_core.dylib', str(core)], check=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
if info['CFBundleShortVersionString'] != version or info['CFBundleVersion'] != build:
    raise SystemExit('macOS version mismatch')
if info.get('FLTEnableImpeller') is not False:
    raise SystemExit('macOS must use the validated Skia Metal renderer')
architectures = {}
minimum_versions = {}
for binary in sorted(app.rglob('*')):
    if not binary.is_file() or binary.is_symlink():
        continue
    with binary.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        continue
    archs = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    if set(archs) != {'arm64', 'x86_64'}:
        raise SystemExit('Universal binary missing architecture: ' + str(binary))
    architectures[str(binary.relative_to(app))] = archs
    current_command = ''
    minimums = []
    for line in subprocess.check_output(['otool', '-l', str(binary)], text=True).splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == 'cmd':
            current_command = fields[1]
        if len(fields) == 2 and ((current_command == 'LC_BUILD_VERSION' and fields[0] == 'minos') or
                                 (current_command == 'LC_VERSION_MIN_MACOSX' and fields[0] == 'version')):
            components = tuple(map(int, fields[1].split('.')))
            if components + (0,) * (3 - len(components)) > (13, 0, 0):
                raise SystemExit('Bundled library requires newer macOS: ' + str(binary))
            minimums.append(fields[1])
    minimum_versions[str(binary.relative_to(app))] = minimums

output = root / 'dist/macos'
output.mkdir(parents=True, exist_ok=True)
package = output / f'HongguoTV-{version}-macos-universal.zip'
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(package)], check=True)
digest = hashlib.sha256(package.read_bytes()).hexdigest()
(output / 'SHA256SUMS.txt').write_text(digest + '  ' + package.name + '\n')
(output / 'macOS-validation.json').write_text(json.dumps({
    'ok': True, 'version': version, 'build': int(build), 'architectures': architectures,
    'renderer': 'Skia Metal', 'signature': 'ad-hoc', 'notarized': False, 'minimumMacOS': '13.0',
    'nativeMinimumVersions': minimum_versions,
    'package': package.name, 'sha256': digest, 'bytes': package.stat().st_size,
}, indent=2) + '\n')
