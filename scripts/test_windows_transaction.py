import ctypes
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
import time
import uuid
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def wait_for(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise TimeoutError('Update condition was not reached')


def records(directory, target):
    target.write_text(''.join(
        f'{hashlib.sha256(file.read_bytes()).hexdigest()}\t{file.relative_to(directory).as_posix()}\n'
        for file in sorted(directory.rglob('*')) if file.is_file()), encoding='utf-8')


def compile_fixtures(directory):
    for build in [37, 38, 39]:
        resource = directory / f'fixture-{build}.o'
        subprocess.run(['windres.exe', f'-DTEST_BUILD={build}',
                        str(root / 'windows/updater/test_fixture.rc'), str(resource)], check=True)
        subprocess.run(['g++.exe', '-std=c++17', '-municode', '-static', f'-DTEST_BUILD={build}',
                        str(root / 'windows/updater/test_fixture.cpp'), str(resource),
                        '-o', str(directory / f'fixture-{build}.exe')], check=True)


def transaction(base, fixtures, mode, real=False):
    base.mkdir()
    nonce = uuid.uuid4().hex
    install = base / 'with spaces 中文'
    stage = base / f'.hongguo-stage-{nonce}'
    backup = base / f'.hongguo-backup-{nonce}'
    support = base / 'support'
    environment = os.environ.copy()
    if real:
        environment['APPDATA'] = str(base / 'appdata')
        environment['LOCALAPPDATA'] = str(base / 'localappdata')
        environment['HONGGUOTV_DISABLE_IMAGES'] = '1'
        support = Path(os.environ['APPDATA']) / '红果TV' / '红果TV'
    tx = support / 'windows-updates' / nonce
    tx.mkdir(parents=True)
    install.mkdir()
    stage.mkdir()
    build = 38 if real else 39
    old_build = 37 if real else 38
    if real:
        version = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M).group(1).split('+')[0]
        package = root / 'dist/windows' / f'HongguoTV-{version}-windows-x64.zip'
        with zipfile.ZipFile(package) as archive:
            archive.extractall(stage)
    else:
        shutil.copyfile(fixtures / 'fixture-39.exe', stage / 'HongguoTV.exe')
    shutil.copyfile(fixtures / f'fixture-{old_build}.exe', install / 'HongguoTV.exe')
    (tx / 'test-mode').write_text(mode, encoding='ascii')
    config = support / 'shared_preferences.json'
    original = '{"flutter.localSnapshot.v1":"preserved"}' if not real else '{}'
    existing_config = config.read_bytes() if config.exists() else None
    config.write_text(original, encoding='utf-8')
    shutil.copyfile(config, tx / 'preferences-backup.json')
    records(install, tx / 'old-files.tsv')
    records(stage, tx / 'new-files.tsv')
    helper = tx / 'HongguoTV-updater.exe'
    shutil.copyfile(root / 'build/windows/x64/runner/Release/HongguoTV-updater.exe', helper)
    parent = subprocess.Popen([str(install / 'HongguoTV.exe'), '--hold', str(tx)], env=environment)
    second = subprocess.Popen([str(install / 'HongguoTV.exe'), '--hold', str(tx)], env=environment) if mode == 'second-instance' else None
    plan = tx / 'plan.txt'
    fields = {'root': str(install), 'stage': str(stage), 'backup': str(backup),
              'nonce': nonce, 'pid': parent.pid, 'build': build, 'oldBuild': old_build,
              'version': '0.1.14', 'oldVersion': '0.1.14', 'config': str(config)}
    if mode == 'version':
        fields['build'] = 40
    if mode == 'semantic':
        fields['version'] = '0.1.15'
    plan.write_text('\n'.join(f'{key}={value}' for key, value in fields.items()), encoding='utf-8')
    handle = None
    process = None
    try:
        if mode == 'tamper':
            with (stage / 'HongguoTV.exe').open('ab') as stream:
                stream.write(b'tamper')
        if mode == 'architecture':
            executable = stage / 'HongguoTV.exe'
            content = bytearray(executable.read_bytes())
            offset = int.from_bytes(content[60:64], 'little')
            content[offset + 4:offset + 6] = bytes.fromhex('4c01')
            executable.write_bytes(content)
            records(stage, tx / 'new-files.tsv')
        if mode == 'unowned':
            (install / 'personal-file.txt').write_text('preserve this file')
        if mode == 'junction':
            target = base / 'external'
            target.mkdir()
            (target / 'personal-file.txt').write_text('preserve this file')
            subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(stage / 'link'), str(target)],
                           check=True, capture_output=True)
        if mode == 'busy':
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.restype = ctypes.c_void_p
            kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong,
                                          ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
            handle = kernel.CreateFileW(str(install / 'HongguoTV.exe'), 0x80000000, 1, None, 3, 0, None)
            if handle in [None, ctypes.c_void_p(-1).value]:
                raise RuntimeError('Cannot create busy file fixture')
        process = subprocess.Popen([str(helper), str(plan)], env=environment, cwd=tx)
        wait_for(lambda: (tx / 'ready.txt').exists() or (tx / 'status.txt').exists())
        if (tx / 'ready.txt').exists():
            (tx / 'stop-old').touch()
            parent.wait(timeout=10)
        code = process.wait(timeout=90)
        status = (tx / 'status.txt').read_text(encoding='utf-8')
        if mode == 'success':
            assert code == 0 and status.startswith('complete'), status
            assert backup.is_dir() and install.is_dir()
            assert config.exists()
            if not real:
                wait_for(lambda: (tx / 'child-39').exists())
                assert config.read_text(encoding='utf-8') == original
        elif mode in ['crash', 'hang']:
            assert code == 1 and 'rolled back' in status, status
            wait_for(lambda: (tx / 'child-38').exists())
            assert config.read_text(encoding='utf-8') == original
            assert hashlib.sha256((install / 'HongguoTV.exe').read_bytes()).digest() == hashlib.sha256((fixtures / 'fixture-38.exe').read_bytes()).digest()
        else:
            assert code == 1 and status.startswith('failed') and not backup.exists(), status
            if mode == 'unowned':
                assert (install / 'personal-file.txt').read_text() == 'preserve this file'
        return {'case': 'real-client-startup-ack' if real else mode, 'ok': True, 'status': status,
                'configurationPreserved': True, 'architecture': 'x64'}
    finally:
        (tx / 'stop-old').touch()
        (tx / 'stop-new').touch()
        if parent.poll() is None:
            parent.terminate()
            parent.wait(timeout=5)
        if second:
            second.wait(timeout=5)
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        if handle:
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            kernel.CloseHandle(handle)
        if real:
            pid_file = tx / 'started-pids.txt'
            if pid_file.exists():
                for child_pid in pid_file.read_text().splitlines():
                    subprocess.run(['taskkill', '/F', '/PID', child_pid], capture_output=True)
            if existing_config is not None:
                config.write_bytes(existing_config)
            else:
                config.unlink(missing_ok=True)
        time.sleep(0.5)


def main():
    if platform.system() != 'Windows':
        raise SystemExit('Windows runner required')
    results = []
    with tempfile.TemporaryDirectory(prefix='hongguo-update-') as temporary:
        base = Path(temporary)
        compile_fixtures(base)
        for mode in ['success', 'crash', 'hang', 'busy', 'tamper', 'version', 'semantic', 'architecture', 'unowned', 'junction', 'second-instance']:
            results.append(transaction(base / mode, base, mode))
            print(json.dumps(results[-1]))
        results.append(transaction(base / 'real', base, 'success', real=True))
        print(json.dumps(results[-1]))
    report = root / 'dist/windows/Windows-update-transaction.json'
    report.write_text(json.dumps({'ok': True, 'cases': results, 'signed': False,
                                 'elevated': False, 'publicReleaseTested': False}, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
