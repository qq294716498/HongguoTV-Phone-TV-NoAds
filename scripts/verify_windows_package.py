import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

import pefile

root = Path(__file__).resolve().parents[1]


def main():
    if platform.system() != 'Windows':
        raise SystemExit('Windows runner required')
    version, build = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE).group(1).split('+')
    package = root / 'dist/windows' / f'HongguoTV-{version}-windows-x64.zip'
    expected_version = tuple(map(int, version.split('-')[0].split('.'))) + (int(build),)
    records = []
    with tempfile.TemporaryDirectory(prefix='hongguotv-verify-') as temporary:
        bundle = Path(temporary)
        with zipfile.ZipFile(package) as archive:
            for name in archive.namelist():
                if Path(name).is_absolute() or '..' in Path(name).parts:
                    raise ValueError('Unsafe package path')
            archive.extractall(bundle)
        required = ['HongguoTV.exe', 'duanju_core.dll', 'flutter_windows.dll',
                    'libffmpegkit.dll', 'libmpv-2.dll', 'msvcp140.dll',
                    'vcruntime140.dll', 'vcruntime140_1.dll', 'libEGL.dll',
                    'libGLESv2.dll', 'd3dcompiler_47.dll', 'data/icudtl.dat',
                    'data/app.so', 'data/flutter_assets/AssetManifest.bin',
                    'data/flutter_assets/assets/danmaku_emoji/2764-fe0f.png',
                    'data/flutter_assets/assets/danmaku_emoji/LICENSE.txt',
                    'data/flutter_assets/assets/video_enhancement/manifest.json']
        missing = [name for name in required if not (bundle / name).is_file()]
        if missing:
            raise ValueError('Missing package files: ' + ', '.join(missing))
        bundled = {file.name.lower() for file in bundle.iterdir() if file.is_file()}
        system = Path(os.environ['SystemRoot']) / 'System32'
        for file in sorted(bundle.rglob('*')):
            if not file.is_file():
                continue
            record = {'path': file.relative_to(bundle).as_posix(), 'bytes': file.stat().st_size,
                      'sha256': hashlib.file_digest(file.open('rb'), 'sha256').hexdigest()}
            if file.suffix.lower() in {'.dll', '.exe'} or file.name == 'app.so':
                with pefile.PE(str(file)) as binary:
                    if binary.FILE_HEADER.Machine != 0x8664:
                        raise ValueError('Expected x64 PE: ' + file.name)
                    imports = set()
                    for attribute in ['DIRECTORY_ENTRY_IMPORT', 'DIRECTORY_ENTRY_DELAY_IMPORT']:
                        imports.update(entry.dll.decode('ascii').lower() for entry in getattr(binary, attribute, []))
                    missing_imports = [name for name in imports if name not in bundled
                                       and not name.startswith(('api-ms-win-', 'ext-ms-win-'))
                                       and not (system / name).is_file()]
                    if missing_imports:
                        raise ValueError(file.name + ' missing imported DLLs: ' + ', '.join(missing_imports))
                    record.update(machine='AMD64', imports=sorted(imports))
                    if file.name == 'HongguoTV.exe':
                        info = binary.VS_FIXEDFILEINFO[0]
                        actual = (info.FileVersionMS >> 16, info.FileVersionMS & 65535,
                                  info.FileVersionLS >> 16, info.FileVersionLS & 65535)
                        if actual != expected_version:
                            raise ValueError(f'Wrong executable version: {actual}')
            records.append(record)
        subprocess.run([sys.executable, '-c',
                        'import ctypes, os, sys; from pathlib import Path; '
                        'p=Path(sys.argv[1]); handle=os.add_dll_directory(str(p)); '
                        '[ctypes.WinDLL(str(p/name)) for name in '
                        '["duanju_core.dll", "libmpv-2.dll", "libffmpegkit.dll"]]',
                        str(bundle)], check=True, timeout=30)
    result = {'ok': True, 'version': version, 'build': int(build), 'architecture': 'x64',
              'package': package.name, 'bytes': package.stat().st_size,
              'sha256': hashlib.file_digest(package.open('rb'), 'sha256').hexdigest(),
              'dllImportsResolved': True, 'nativeLibrariesLoaded': True, 'files': records}
    (package.parent / 'Windows-validation.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(f'Validated {package.name}: {len(records)} files, x64, version {version}+{build}')


if __name__ == '__main__':
    main()
